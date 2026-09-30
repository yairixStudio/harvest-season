// Quota Harvest — a menu bar (or floating) panel with the Claude Code usage
// limits (the 5-hour session, the all-models weekly and the model-scoped weekly) and
// the owner's backlog quota harvester: the queued BACKLOG.md tasks across projects,
// approvals, and a harvest that starts a chosen number of hours before the weekly
// reset (or on demand), so quota that would lapse does queued work instead.
//
// Where the numbers come from: the signed-in Claude Code login (the Keychain first,
// then ~/.claude/.credentials.json) authorizes a GET of the usage endpoint behind
// claude.ai's usage settings page. A login that is about to lapse is renewed with
// Claude Code's own refresh grant and saved back where it was found, so the widget
// keeps working when Claude Code hasn't run for a while.
// Harvest data: every read and write goes through ~/.claude/harvest/bin/harvest.py.
//
// Build: swiftc -O -o QuotaHarvest QuotaHarvest.swift
// Run:   ./start   (right-click the panel for Refresh / Quit)

import AppKit
import Combine
import SwiftUI
import UserNotifications

// MARK: - Data

/// One limit as the usage endpoint reports it: the share used (0–100, as sent) and when it resets.
struct Metric { var pct: Double; var resetsAt: Date? }

/// What one poll brought back. `scoped` is the model-scoped weekly limit; `scopedLabel`
/// names its model ("Fable") when the response does.
struct Usage {
    var session, weekly, scoped: Metric?
    var scopedLabel: String?
}

/// A poll's result: the numbers, or why there are none — a `PollFailure`, or the transport's own error.
typealias PollResult = Result<Usage, Error>

/// Why a poll brought no numbers. `refresh()` turns each into the live dot's color and tip.
enum PollFailure: Error {
    /// No stored login could be read.
    case signedOut
    /// The endpoint answered with this status — neither 200 nor 429.
    case status(Int)
    /// 429, with the wait the server's `Retry-After` asked for when it sent one.
    case throttled(retryAfter: TimeInterval?)
    /// No HTTP response at all, or a body without a single readable limit.
    case unreadable
}

/// A JSON number as a Double. `JSONSerialization` hands every number over as `NSNumber`, so
/// integers and fractions both come through; anything else is nil.
func jsonNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber else { return nil }
    return number.doubleValue
}

// MARK: - Credentials

/// Claude Code keeps its login as one JSON blob: in the login Keychain under this service
/// name, or — where the Keychain isn't used — in this file.
private let loginKeychainService = "Claude Code-credentials"
private let loginFileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")

/// Current Claude Code files the OAuth fields under this key; early versions kept them at the top level.
private let nestedOAuthKey = "claudeAiOauth"

/// How long `security` may run before it is stopped. Reading the item can put up a macOS
/// permission prompt (the first time, or while the Keychain is locked); with nobody there to
/// answer it, an open-ended wait would stall this poll and every one after it.
private let securityDeadline: TimeInterval = 10

/// Which of the two places a login was read from — the only place it is ever written back to.
enum LoginStore { case keychain, file }

/// Claude Code's stored login, kept as the whole decoded object: a renewal writes all of it
/// back, so the fields this widget never reads (scopes, subscription type, …) survive as they are.
struct StoredLogin {
    var json: [String: Any]
    let store: LoginStore
    /// `nestedOAuthKey`, or nil for the old top-level layout.
    let oauthKey: String?

    /// The object that holds `accessToken`, `refreshToken` and `expiresAt`.
    var oauthFields: [String: Any] {
        guard let key = oauthKey else { return json }
        return json[key] as? [String: Any] ?? [:]
    }
    var accessToken: String? { oauthFields["accessToken"] as? String }
    var refreshToken: String? { oauthFields["refreshToken"] as? String }
    /// When the access token lapses, in epoch seconds (Claude Code stores milliseconds).
    var expirySeconds: Double? { jsonNumber(oauthFields["expiresAt"]).map { $0 / 1000 } }

    /// Due for renewal: the access token has lapsed, or will within `renewalMargin`. A login
    /// without `expiresAt` is never renewed ahead of time — only after a refused poll.
    func renewalDue(now: Date = Date()) -> Bool {
        guard let expiry = expirySeconds else { return false }
        return now.timeIntervalSince1970 >= expiry - renewalMargin
    }
}

/// The one place `/usr/bin/security` is spawned. Returns its output when it exits with 0 within
/// `securityDeadline`, else nil. Past the deadline it is asked to quit, and killed 2 s later if it
/// hasn't (at most 14 s in all). `stdinText`, when given, is written to its standard input, which
/// is then closed — `security -i` reads commands until end of input.
private func callSecurityTool(_ arguments: [String], stdinText: String? = nil) -> Data? {
    let tool = Process()
    tool.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    tool.arguments = arguments
    let output = Pipe()
    tool.standardOutput = output
    tool.standardError = Pipe()
    let input = stdinText == nil ? nil : Pipe()
    if let input { tool.standardInput = input }
    // Set before launch, so even a process that exits at once is seen to exit.
    let exited = DispatchSemaphore(value: 0)
    tool.terminationHandler = { _ in exited.signal() }
    do { try tool.run() } catch { return nil }
    if let writer = input?.fileHandleForWriting {
        if let bytes = stdinText?.data(using: .utf8) { writer.write(bytes) }
        writer.closeFile()   // even when there was nothing to write, or `security` waits forever
    }
    guard exited.wait(timeout: .now() + securityDeadline) == .success else {
        tool.terminate()
        if exited.wait(timeout: .now() + 2) == .timedOut {
            kill(tool.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
        return nil
    }
    return tool.terminationStatus == 0 ? output.fileHandleForReading.readDataToEndOfFile() : nil
}

/// The stored login's raw text and where it came from. The Keychain wins whenever it yields
/// something non-blank (even something unreadable); the file is only the fallback for a
/// Keychain read that timed out, failed or came back empty.
func loadLoginText() -> (text: String, store: LoginStore)? {
    if let output = callSecurityTool(["find-generic-password", "-s", loginKeychainService, "-w"]),
       let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
        return (text, .keychain)
    }
    guard let bytes = try? Data(contentsOf: loginFileURL), let text = String(data: bytes, encoding: .utf8) else { return nil }
    return (text, .file)
}

/// Decodes a stored login: a JSON object with the OAuth fields under `claudeAiOauth`, or — the
/// old layout — an `accessToken` at the top level. Anything else is no login at all.
func parseStoredLogin(_ text: String, store: LoginStore) -> StoredLogin? {
    guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
    if object[nestedOAuthKey] is [String: Any] { return StoredLogin(json: object, store: store, oauthKey: nestedOAuthKey) }
    if object["accessToken"] is String { return StoredLogin(json: object, store: store, oauthKey: nil) }
    return nil
}

/// Read fresh on every poll, so a login Claude Code renewed in the meantime is picked up.
func loadStoredLogin() -> StoredLogin? {
    guard let found = loadLoginText() else { return nil }
    return parseStoredLogin(found.text, store: found.store)
}

// MARK: - Token refresh

/// The OAuth token endpoint and client that issued Claude Code's login. The refresh grant is
/// the only request the refresh token ever goes into; neither token is logged, shown, or put in
/// an argument list.
private let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!
private let claudeCodeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

/// Renew this long before `expiresAt`, so the token doesn't lapse between the check and the poll.
private let renewalMargin: TimeInterval = 60

/// At most one renewal attempt a minute: a dead refresh token (revoked, signed out elsewhere)
/// must not turn polling into a stream of token requests. Used only on the fetch path, which
/// has one request out at a time.
private let renewalSpacing: TimeInterval = 60
private var lastRenewalAttempt = Date.distantPast

/// A successful refresh grant's answer.
struct RenewedTokens {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?
}

/// Reads the token endpoint's reply: a 200 whose JSON body carries a non-empty `access_token`,
/// plus `refresh_token` and `expires_in` when present. Anything else is nil.
func readRenewalReply(status: Int, body: Data?) -> RenewedTokens? {
    guard status == 200, let body,
          let reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
          let access = reply["access_token"] as? String, !access.isEmpty else { return nil }
    return RenewedTokens(accessToken: access, refreshToken: reply["refresh_token"] as? String,
                         expiresIn: jsonNumber(reply["expires_in"]))
}

/// The stored login JSON with a renewal folded in. Only three fields change: `accessToken`;
/// `refreshToken`, replaced by the rotated one (the old one stays only when the reply had none,
/// or an empty one); `expiresAt`, set to `now + expiresIn` in epoch milliseconds when the reply
/// gave a lifetime. Every other key, at either level, is left exactly as it was. Pure — no I/O.
func mergeRenewal(_ tokens: RenewedTokens, into json: [String: Any], oauthKey: String?, now: Date) -> [String: Any] {
    var fields = oauthKey.map { json[$0] as? [String: Any] ?? [:] } ?? json
    fields["accessToken"] = tokens.accessToken
    if let rotated = tokens.refreshToken, !rotated.isEmpty { fields["refreshToken"] = rotated }
    if let lifetime = tokens.expiresIn { fields["expiresAt"] = Int((now.timeIntervalSince1970 + lifetime) * 1000) }
    guard let key = oauthKey else { return fields }
    var merged = json
    merged[key] = fields
    return merged
}

/// Posts the refresh grant and waits for the answer — 15 s for the request, 20 s at most in all.
/// Blocking: background queue only.
private func requestRenewal(refreshToken: String) -> RenewedTokens? {
    var grant = URLRequest(url: tokenEndpoint, timeoutInterval: 15)
    grant.httpMethod = "POST"
    grant.setValue("application/json", forHTTPHeaderField: "Content-Type")
    grant.httpBody = try? JSONSerialization.data(withJSONObject: [
        "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": claudeCodeClientID,
    ])
    var answer: RenewedTokens?
    let answered = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: grant) { body, response, _ in
        answer = readRenewalReply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
        answered.signal()
    }.resume()
    _ = answered.wait(timeout: .now() + 20)
    return answer
}

/// Trades the stored refresh token for a new access token, saves the result back to the store it
/// came from and returns it. Nil when the last attempt was under a minute ago, there is no
/// refresh token, or the grant failed — the caller then carries on with the old token and the
/// normal error path (the red dot) reports what happens. Blocking: background queue only.
func renewLogin(_ login: StoredLogin) -> StoredLogin? {
    guard Date().timeIntervalSince(lastRenewalAttempt) >= renewalSpacing,
          let refreshToken = login.refreshToken, !refreshToken.isEmpty else { return nil }
    lastRenewalAttempt = Date()
    guard let tokens = requestRenewal(refreshToken: refreshToken) else { return nil }
    var renewed = login
    renewed.json = mergeRenewal(tokens, into: login.json, oauthKey: login.oauthKey, now: Date())
    saveLogin(renewed)
    return renewed
}

/// The `security -i` command that updates (or creates) the login item with `json`. Inside the
/// double quotes a backslash and a quote must be escaped; the tokens are base64url, so both occur
/// only in the JSON's own syntax.
func keychainUpdateCommand(json: String, account: String) -> String {
    let quoted = [("\\", "\\\\"), ("\"", "\\\"")].reduce(json) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    return "add-generic-password -U -a \"\(account)\" -s \"\(loginKeychainService)\" -w \"\(quoted)\"\n"
}

/// Writes a renewed login back to where it was read from — never to the other store. The grant
/// rotates the refresh token and voids the old one, so without this write Claude Code itself
/// would find its login dead.
func saveLogin(_ login: StoredLogin) {
    guard let bytes = try? JSONSerialization.data(withJSONObject: login.json, options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: bytes, encoding: .utf8) else { return }
    switch login.store {
    case .keychain:
        // On stdin, not as arguments: the login never shows up in a process list (`ps`).
        _ = callSecurityTool(["-i"], stdinText: keychainUpdateCommand(json: text, account: NSUserName()))
    case .file:
        try? bytes.write(to: loginFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: loginFileURL.path)
    }
}

// MARK: - Fetch + parse

/// A reset time as the API writes it: epoch seconds, or ISO 8601 with or without fractional seconds.
func parseDate(_ value: Any?) -> Date? {
    if let seconds = jsonNumber(value) { return Date(timeIntervalSince1970: seconds) }
    guard let text = value as? String else { return nil }
    let reader = ISO8601DateFormatter()
    for format: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
        reader.formatOptions = format
        if let date = reader.date(from: text) { return date }
    }
    return nil
}

/// An HTTP date as `Retry-After` may carry it ("Sun, 06 Nov 1994 08:49:37 GMT").
private func httpDate(_ text: String) -> Date? {
    let reader = DateFormatter()
    reader.locale = Locale(identifier: "en_US_POSIX")
    reader.timeZone = TimeZone(identifier: "GMT")
    reader.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return reader.date(from: text)
}

/// The wait a 429 asked for through `Retry-After` — delta-seconds or an HTTP date — never below 0.
func retryAfterDelay(_ response: HTTPURLResponse) -> TimeInterval? {
    let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !value.isEmpty else { return nil }
    let delay = Double(value) ?? httpDate(value)?.timeIntervalSinceNow
    return delay.map { max($0, 0) }
}

/// A bucket in the older, pre-`limits` shape (`five_hour`, `seven_day`, …): `utilization`
/// (or `used_percent`) and `resets_at` (or `resetsAt`).
private func legacyBucket(_ value: Any?) -> Metric? {
    guard let bucket = value as? [String: Any],
          let used = jsonNumber(bucket["utilization"]) ?? jsonNumber(bucket["used_percent"]) else { return nil }
    return Metric(pct: used, resetsAt: parseDate(bucket["resets_at"] ?? bucket["resetsAt"]))
}

/// Reads a usage response. The `limits` array is the current shape (`session`, `weekly_all`,
/// `weekly_scoped` with its model's name); the older top-level buckets fill in whatever it left
/// empty. Nil when not one limit could be read. Percentages are kept as sent: both shapes use
/// 0–100, and treating a small value as a 0–1 fraction once turned a real 1 % into 100 %.
func decodeUsage(_ body: Data) -> Usage? {
    guard let response = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
    var usage = Usage()
    for limit in response["limits"] as? [[String: Any]] ?? [] {
        guard let used = jsonNumber(limit["percent"]) else { continue }
        let reading = Metric(pct: used, resetsAt: parseDate(limit["resets_at"]))
        switch limit["kind"] as? String {
        case "session"?: usage.session = reading
        case "weekly_all"?: usage.weekly = reading
        case "weekly_scoped"?:
            usage.scoped = reading
            let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
            if let name = model?["display_name"] as? String { usage.scopedLabel = name }
        default: continue
        }
    }
    usage.session = usage.session ?? legacyBucket(response["five_hour"])
    usage.weekly = usage.weekly ?? legacyBucket(response["seven_day"])
    usage.scoped = usage.scoped
        ?? ["seven_day_fable", "seven_day_opus", "seven_day_sonnet"].lazy.compactMap { legacyBucket(response[$0]) }.first
    let anyLimit = usage.session != nil || usage.weekly != nil || usage.scoped != nil
    return anyLimit ? usage : nil
}

/// Where the fetch path's blocking work (the Keychain, a renewal) runs.
private let fetchQueue = DispatchQueue.global(qos: .utility)

/// The only two places the access token may be sent — both on api.anthropic.com.
enum AnthropicAPI: String {
    case usage = "https://api.anthropic.com/api/oauth/usage"
    case profile = "https://api.anthropic.com/api/oauth/profile"
}

/// The one place the access token is put on a request: a GET of one of the two endpoints above,
/// with the OAuth beta header they require and a 15 s timeout.
func authorizedGET(_ endpoint: AnthropicAPI, token: String) -> URLRequest {
    var request = URLRequest(url: URL(string: endpoint.rawValue)!, timeoutInterval: 15)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    return request
}

/// What a usage response amounts to: the numbers, or the failure `refresh()` reacts to.
func usageResult(_ response: URLResponse?, body: Data?) -> PollResult {
    guard let http = response as? HTTPURLResponse else { return .failure(PollFailure.unreadable) }
    switch http.statusCode {
    case 200:
        guard let usage = body.flatMap(decodeUsage) else { return .failure(PollFailure.unreadable) }
        return .success(usage)
    case 429:
        return .failure(PollFailure.throttled(retryAfter: retryAfterDelay(http)))
    case let other:
        return .failure(PollFailure.status(other))
    }
}

/// One GET of the usage endpoint; a transport error is passed on as it came. Completes on the main queue.
private func getUsage(token: String, completion: @escaping (PollResult) -> Void) {
    URLSession.shared.dataTask(with: authorizedGET(.usage, token: token)) { body, response, transportError in
        let outcome = transportError.map { PollResult.failure($0) } ?? usageResult(response, body: body)
        DispatchQueue.main.async { completion(outcome) }
    }.resume()
}

/// Polls usage with the stored login, renewed first when it is about to lapse — so most polls
/// never meet a 401. A failed renewal isn't fatal: the poll still goes out with the stored token.
/// If the endpoint turns the token down anyway (401/403: it went stale some other way), the login
/// is renewed once more and the poll retried once; the renewal's one-a-minute gate means this
/// can't loop. Completes on the main queue.
func fetchUsage(completion: @escaping (PollResult) -> Void) {
    fetchQueue.async {
        guard let stored = loadStoredLogin(), let storedToken = stored.accessToken else {
            DispatchQueue.main.async { completion(.failure(PollFailure.signedOut)) }
            return
        }
        let login = (stored.renewalDue() ? renewLogin(stored) : nil) ?? stored
        getUsage(token: login.accessToken ?? storedToken) { first in
            guard case .failure(PollFailure.status(let code)) = first, code == 401 || code == 403 else {
                completion(first)
                return
            }
            fetchQueue.async {
                guard let renewed = renewLogin(login), let token = renewed.accessToken else {
                    DispatchQueue.main.async { completion(first) }
                    return
                }
                getUsage(token: token, completion: completion)
            }
        }
    }
}

/// The header's account line from a profile response: "<name> · <organization>", or whichever of
/// the two it has (the name is `full_name`, else `display_name`, else `email`). Nil for neither.
func profileLine(from body: Data) -> String? {
    guard let profile = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
    let account = profile["account"] as? [String: Any] ?? [:]
    let person = ["full_name", "display_name", "email"].lazy.compactMap { account[$0] as? String }.first
    let organization = (profile["organization"] as? [String: Any])?["name"] as? String
    let parts = [person, organization].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// Fetches the account line with the stored token as it is (no renewal here), reading the body
/// whatever the status. Completes on the main queue.
func fetchAccountLine(completion: @escaping (String?) -> Void) {
    let finish = { (line: String?) in DispatchQueue.main.async { completion(line) } }
    fetchQueue.async {
        guard let token = loadStoredLogin()?.accessToken else { finish(nil); return }
        URLSession.shared.dataTask(with: authorizedGET(.profile, token: token)) { body, _, _ in
            finish(body.flatMap(profileLine(from:)))
        }.resume()
    }
}

// MARK: - Harvest

let homeURL = FileManager.default.homeDirectoryForCurrentUser
let harvestHome = homeURL.appendingPathComponent(".claude/harvest")
let harvestEngine = harvestHome.appendingPathComponent("bin/harvest.py")
/// The folder harvest sessions run in (a stable, non-hidden project folder): the engine's
/// `workdir` setting, kept current from every listing (`WidgetModel.listing`); the engine's
/// default until the first one.
var harvestWorkdir = homeURL.appendingPathComponent("claude-harvest")

/// The panel's language: the harvest settings' `language` once a listing has it, else the Mac's
/// first preferred language. Hebrew lays the panel out right to left.
var uiHebrew = UserDefaults.standard.string(forKey: "UILanguage").map { $0 == "he" }
    ?? (Locale.preferredLanguages.first?.hasPrefix("he") ?? false)
/// Set by a snapshot's `--he` / `--en`: the listing's language then leaves `uiHebrew` alone.
var uiLanguageForced = false
func L(_ he: String, _ en: String) -> String { uiHebrew ? he : en }
/// The harvest installer that ships with this widget: `harvest/install.py` in the app bundle's
/// Resources (`./install` copies it there), or beside a bare binary run from the repository.
var harvestInstaller: URL? {
    [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        .compactMap { $0?.appendingPathComponent("harvest/install.py") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

/// Runs the installer; its JSON output and exit code come back on the main queue.
func runInstaller(_ args: [String], completion: @escaping (Data?, Int32) -> Void) {
    guard let script = harvestInstaller else { completion(nil, -1); return }
    DispatchQueue.global(qos: .userInitiated).async {
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        installer.arguments = [script.path] + args
        installer.environment = harvestEnvironment(unattended: false)
        let output = Pipe()
        installer.standardOutput = output
        installer.standardError = FileHandle.nullDevice
        guard (try? installer.run()) != nil else {
            DispatchQueue.main.async { completion(nil, -1) }
            return
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        installer.waitUntilExit()
        DispatchQueue.main.async { completion(data.isEmpty ? nil : data, installer.terminationStatus) }
    }
}

/// What `install.py plan` says an install would do.
struct InstallPlan: Decodable {
    struct File: Decodable { var path: String; var action: String }
    struct Block: Decodable { var path: String; var change: String; var block: String }
    struct Conflict: Decodable { var path: String; var why: String }
    struct Values: Decodable {
        var ownerName: String?; var language: String?; var email: String?
        var emailDigest: Bool?; var workdir: String?
    }
    struct SettingsPart: Decodable { var values: Values; var action: String? }
    var ok: Bool
    var installed: Bool?
    var files: [File] = []
    var blocks: [Block] = []
    var conflicts: [Conflict] = []
    var settings: SettingsPart?
}

/// How the engine priced a task: turns × (the project's starting context + growth).
struct HEstimate: Decodable, Equatable {
    let base: Int?
    let baseSource: String?
    let turns: Int?
    let turnsSource: String?
}

struct HTask: Decodable, Identifiable, Equatable {
    let project: String
    let projectName: String
    let title: String
    let status: String
    let priority: Int
    let complexity: String
    let tokens: Int
    let pct: Double
    let details: String?
    let branch: String?
    let branchState: String?
    let ageDays: Int?
    let question: String?
    let summary: String?
    let sessionId: String?
    let estimate: HEstimate?
    /// In the queue: placed by the owner's drag rather than by the automatic order.
    let placed: Bool?
    var id: String { project + "::" + title }
}

struct HRun: Decodable, Equatable {
    let finishedAt: String?
    let mode: String?
    let done: Int?
    let stopReason: String?
    let final: Bool?
    let emailed: Bool?
}

/// The task running right now — its own session in its project ("קציר · <title>").
struct HCurrent: Decodable, Equatable {
    let projectName: String?
    let title: String?
    let model: String?
    let sessionId: String?
    let bridgeSessionId: String?
    let claudePid: Int?
}

struct HRecord: Decodable, Equatable {
    let outcome: String?
}

struct HStatus: Decodable, Equatable {
    let state: String?
    let current: HCurrent?
    let lastRun: HRun?
    let doneThisRun: [HRecord]?
}

struct HRatio: Decodable, Equatable {
    let weekly: Double
    let five: Double
}

struct HLock: Decodable, Equatable {
    let live: Bool?
}

/// The engine's launch.json: the newest harvest session and where to watch it.
struct HLaunch: Decodable, Equatable {
    let sessionId: String?
    let name: String?
    let mode: String?
    let bridgeSessionId: String?
    let launcherPid: Int?
    let claudePid: Int?
    let endedAt: String?
}

/// The engine's `list` output: the harvest state the panel renders.
/// Who the harvest works for — the engine's settings.json, as `list` reports it. `configured`
/// is false until the installer has written it.
struct HSettings: Decodable, Equatable {
    var language: String?
    var workdir: String?
    var configured: Bool?
    var ownerName: String?
    var email: String?
    var emailDigest: Bool?
    var models: [String: String]?
    var noProposals: [String]?
}

/// A registered project as `list` reports it.
struct HProject: Decodable, Equatable, Identifiable {
    var path: String
    var name: String
    var exists: Bool?
    var proposalsOff: Bool?
    var id: String { path }
}

struct HListing: Decodable, Equatable {
    var settings: HSettings?
    var projects: [HProject] = []
    var queue: [HTask] = []
    var proposals: [HTask] = []
    var needsYou: [HTask] = []
    var done: [HTask] = []
    var ratio: HRatio?
    var status: HStatus?
    var lock: HLock?
    var launch: HLaunch?
}

struct HarvestConfig: Equatable {
    var auto = true
    var leadHours = 8
}

func loadHarvestConfig() -> HarvestConfig {
    var c = HarvestConfig()
    if let data = try? Data(contentsOf: harvestHome.appendingPathComponent("config.json")),
       let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let auto = saved["auto"] as? Bool { c.auto = auto }
        if let lead = jsonNumber(saved["leadHours"]) { c.leadHours = min(max(Int(lead), 1), 24) }
    }
    return c
}

func writeJSONFile(_ obj: Any, to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
}

func saveHarvestConfig(_ c: HarvestConfig) {
    writeJSONFile(["auto": c.auto, "leadHours": c.leadHours],
                  to: harvestHome.appendingPathComponent("config.json"))
}

func isoString(_ d: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: d)
}

func jsonDate(_ d: Date?) -> Any {
    if let d = d { return isoString(d) }
    return NSNull()
}

/// The engine budgets every harvest from this file; the widget is its only
/// writer, refreshing it after each successful poll.
func writeUsageFile(_ u: Usage) {
    func metric(_ m: Metric?) -> Any {
        guard let m = m else { return NSNull() }
        return ["pct": m.pct, "resetsAt": jsonDate(m.resetsAt)] as [String: Any]
    }
    var obj: [String: Any] = [
        "fetchedAt": isoString(Date()), "source": "widget",
        "session": metric(u.session), "weekly": metric(u.weekly),
    ]
    if let f = u.scoped {
        obj["scoped"] = ["label": u.scopedLabel ?? "Fable", "pct": f.pct,
                         "resetsAt": jsonDate(f.resetsAt)] as [String: Any]
    }
    writeJSONFile(obj, to: harvestHome.appendingPathComponent("usage.json"))
}

/// GUI apps start with a minimal PATH; harvest runs need git, python3 and claude.
func harvestEnvironment(unattended: Bool) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    var seen = Set<String>()
    let dirs = [homeURL.path + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        + (env["PATH"] ?? "").split(separator: ":").map(String.init)
    env["PATH"] = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    if unattended {
        env["HARVEST_UNATTENDED"] = "1"
    } else {
        env.removeValue(forKey: "HARVEST_UNATTENDED")
    }
    return env
}

/// Runs the harvest engine off the main thread and completes on the main
/// queue with its JSON stdout (its errors are JSON too), or nil if it couldn't run.
func runEngine(_ args: [String], completion: @escaping (Data?) -> Void) {
    DispatchQueue.global(qos: .utility).async {
        let engine = Process()
        engine.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        engine.arguments = [harvestEngine.path] + args
        engine.environment = harvestEnvironment(unattended: false)
        let output = Pipe()
        engine.standardOutput = output
        engine.standardError = FileHandle.nullDevice
        guard (try? engine.run()) != nil else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // A BACKLOG.md in iCloud that isn't downloaded yet can stall a read.
        let watchdog = DispatchWorkItem { if engine.isRunning { engine.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        engine.waitUntilExit()
        watchdog.cancel()
        DispatchQueue.main.async { completion(data.isEmpty ? nil : data) }
    }
}

func claudeExecutable() -> String? {
    [homeURL.path + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// One harvest run: the engine's `launch` — an interactive Claude session in a
/// hidden terminal, published to Remote Control so the Claude app and phone can
/// follow it live — spawned in its own process group so Stop reaches it.
/// Starts the engine detached: in its own process group (so a stop reaches every
/// child), stdin from /dev/null, stdout and stderr into `log`, in the harvest folder.
func spawnEngine(_ args: [String], log: String, unattended: Bool) -> pid_t? {
    let python = "/usr/bin/python3"
    let env = harvestEnvironment(unattended: unattended).map { "\($0.key)=\($0.value)" }
    try? FileManager.default.createDirectory(at: harvestWorkdir, withIntermediateDirectories: true)
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    posix_spawn_file_actions_addchdir(&actions, harvestWorkdir.path)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attr, 0)
    let argv = ([python, harvestEngine.path] + args).map { strdup($0) } + [nil]
    let envp = env.map { strdup($0) } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    var child: pid_t = 0
    guard posix_spawn(&child, python, &actions, &attr, argv, envp) == 0 else { return nil }
    return child
}

final class HarvestRunner {
    private(set) var pid: pid_t = 0
    private var exitSource: DispatchSourceProcess?
    private var onExit: ((Int32) -> Void)?
    var isRunning: Bool { pid > 0 }

    func launch(mode: String, only: [HTask], test: Bool, onExit: @escaping (Int32) -> Void) -> Bool {
        guard pid == 0, claudeExecutable() != nil else { return false }
        let logs = harvestHome.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        pruneLogs(logs)
        let logPath = logs.appendingPathComponent(
            "launch-\(formatTime(Date(), "yyyyMMdd-HHmmss")).out").path
        var args = ["launch", "--mode", mode, "--remote-control"]
        for task in only { args += ["--only", "\(task.project)::\(task.title)"] }
        if test { args.append("--test") }
        guard let child = spawnEngine(args, log: logPath, unattended: true) else { return false }
        pid = child
        self.onExit = onExit

        // Keeps the Mac awake for exactly as long as the run lives.
        let caffeinate = Process()
        caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caffeinate.arguments = ["-i", "-w", String(child)]
        try? caffeinate.run()

        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.checkExited() }
        exitSource = source
        source.resume()
        checkExited()
        return true
    }

    /// Reaps the run once it has exited; safe to call at any time.
    func checkExited() {
        guard pid > 0 else { return }
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        guard r == pid || (r == -1 && errno == ECHILD) else { return }
        exitSource?.cancel()
        exitSource = nil
        pid = 0
        let done = onExit
        onExit = nil
        done?(status)
    }

    /// The launcher forwards SIGTERM to Claude's own process group (a terminal
    /// session is a group of its own); `claudePid` is the fallback if it can't.
    func stop(claudePid: Int?) {
        let target = pid
        guard target > 0 else { return }
        killpg(target, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard self?.pid == target else { return }
            if let c = claudePid, c > 1 { killpg(pid_t(c), SIGKILL) }
            killpg(target, SIGKILL)
        }
    }

    private func pruneLogs(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for prefix in ["run-", "launch-", "talk-"] {
            let runs = files.filter { $0.lastPathComponent.hasPrefix(prefix) }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in runs.dropFirst(20) { try? fm.removeItem(at: old) }
        }
    }
}

/// Opens a session in the Claude desktop app: a live Remote Control run by its
/// bridge id (`session_…`), or an imported one by `local_<session id>`.
func openInClaudeApp(_ sessionPath: String) {
    if let url = URL(string: "claude://claude.ai/epitaxy/" + sessionPath) { NSWorkspace.shared.open(url) }
}

/// Imports a finished run into the Claude app (a no-op once it's there) and
/// opens it: the full conversation, which the owner can keep talking to.
func openFinishedRun(_ sessionId: String) {
    if let url = URL(string: "claude://resume?session=" + sessionId) { NSWorkspace.shared.open(url) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { openInClaudeApp("local_" + sessionId) }
}

/// Opens a finished session's conversation in the Claude app. One the app
/// already has — started there, or imported before — opens as it is: its app
/// id can differ from the CLI session id, and importing it again would make a
/// copy. Any other is imported first.
func openSessionInApp(_ cliSessionId: String) {
    if let appId = appSessionId(forCli: cliSessionId) {
        openInClaudeApp(appId)
    } else {
        openFinishedRun(cliSessionId)
    }
}

/// The app's id (`local_…`) for a CLI session id, from the session records the
/// app keeps in Application Support; nil when it has none.
func appSessionId(forCli cliSessionId: String) -> String? {
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
    let needle = Data(cliSessionId.utf8)
    for case let url as URL in files where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
        guard let data = try? Data(contentsOf: url), data.range(of: needle) != nil,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["cliSessionId"] as? String == cliSessionId,
              let appId = obj["sessionId"] as? String else { continue }
        return appId
    }
    return nil
}

/// Follows the newest run in Terminal, one readable line per step.
func watchInTerminal() {
    let script = harvestHome.appendingPathComponent("bin/watch.command")
    let body = "#!/bin/zsh\nexec \"$HOME/.local/bin/claude-harvest\" watch\n"
    if (try? String(contentsOf: script, encoding: .utf8)) != body {
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }
    NSWorkspace.shared.open(script)
}

/// Opens a new Claude Code session in the desktop app, in `folder`, with the
/// prompt typed in and waiting for the owner to press Enter.
func openInClaude(folder: String, prompt: String) {
    var c = URLComponents()
    c.scheme = "claude"
    c.host = "code"
    c.path = "/new"
    c.queryItems = [URLQueryItem(name: "folder", value: folder), URLQueryItem(name: "q", value: prompt)]
    if let url = c.url { NSWorkspace.shared.open(url) }
}

/// The text goes in as osascript arguments, never spliced into the script.
/// True once the owner allowed the app's notifications (it needs the app bundle:
/// UNUserNotificationCenter crashes a bare binary, which is what ./start and the
/// snapshots run). Until then `notify` goes through osascript, whose
/// notifications can't be clicked through to anything.
var clickableNotifications = false

func notify(title: String, body: String, category: String? = nil, id: String? = nil) {
    if clickableNotifications {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category = category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id ?? UUID().uuidString, content: content, trigger: nil))
        return
    }
    let osascript = Process()
    osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    osascript.arguments = ["-e", "on run argv",
                           "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                           "-e", "end run", title, body]
    try? osascript.run()
}

let hebrewWeekdays = ["א׳", "ב׳", "ג׳", "ד׳", "ה׳", "ו׳", "ש׳"]
let englishWeekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

/// A time within the coming week: "16:00" today, "מחר 04:00" / "tomorrow 04:00", else "ב׳ 04:00" /
/// "Mon 04:00".
func whenText(_ date: Date) -> String {
    // Reset times jitter around the minute (03:59:59.9): show the minute they mean.
    let d = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    let cal = Calendar.current
    let hm = formatTime(d, "HH:mm")
    if cal.isDateInToday(d) { return hm }
    if cal.isDateInTomorrow(d) { return L("מחר ", "tomorrow ") + hm }
    let day = cal.component(.weekday, from: d) - 1
    return (uiHebrew ? hebrewWeekdays[day] : englishWeekdays[day]) + " " + hm
}

/// A countdown in whole seconds: "בעוד 3 ימים ו־07:42:15" / "in 3 days 07:42:15".
func countdownText(to date: Date, now: Date) -> String {
    let s = max(0, Int(date.timeIntervalSince(now)))
    let clock = String(format: "%02d:%02d:%02d", (s % 86400) / 3600, (s % 3600) / 60, s % 60)
    switch s / 86400 {
    case 0: return L("בעוד ", "in ") + clock
    case 1: return L("בעוד יום ו־", "in 1 day ") + clock
    case let days: return L("בעוד \(days) ימים ו־", "in \(days) days ") + clock
    }
}

/// Percent of the weekly quota: one decimal below 10 %, where most tasks live.
func pctText(_ p: Double) -> String {
    if p <= 0 { return "0%" }
    if p < 0.1 { return "<0.1%" }
    if p < 10 { return String(format: "%.1f%%", p) }
    return "\(Int(p.rounded()))%"
}

func stopReasonText(_ reason: String?) -> String? {
    guard let r = reason else { return nil }
    if r.hasPrefix("usage-unreadable") { return L("לא הצליח לקרוא את המכסה", "couldn't read the quota") }
    switch r {
    case "queue-empty": return L("התור התרוקן", "the queue ran out")
    case "5h-full": return L("חלון 5 השעות התמלא — ימשיך אחרי האיפוס שלו", "the 5-hour window filled up — it goes on after that resets")
    case "weekly-full": return L("המכסה השבועית נוצלה", "the weekly quota is used up")
    case "cutoff-near": return L("קרוב מדי לאיפוס", "too close to the reset")
    case "too-early": return L("מוקדם מדי לפני האיפוס", "too early before the reset")
    case "interrupted": return L("נעצר באמצע", "stopped midway")
    case "stopped-by-owner": return L("נעצר על ידך", "stopped by you")
    default: return r
    }
}

// MARK: - Views

/// The bars' normal fill: claude.ai's blue.
let claudeBlue = NSColor(srgbRed: 0.31, green: 0.47, blue: 0.9, alpha: 1)

/// The one place the warning thresholds live, for the bars and the menu bar gauges alike:
/// red from 90 %, orange from 70 %, and nil — no warning — below that.
func warningColor(_ percent: Double) -> NSColor? {
    switch percent {
    case 90...: return .systemRed
    case 70...: return .systemOrange
    default: return nil
    }
}

// Menu bar drawing. Shapes are drawn opaque inside a transparency layer and
// tinted once, so the translucent label colors don't add up where parts overlap.

private func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

private func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for q in points.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
    p.close()
    return p
}

private func segment(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat), width: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: a.0, y: a.1))
    p.line(to: NSPoint(x: b.0, y: b.1))
    p.lineWidth = width
    p.lineCapStyle = .round
    return p
}

/// A combine harvester driving left, in a 21 × 16 pt box: header and reel in
/// front, cab, grain tank with its unloading auger, two wheels. `reel` turns
/// the reel (radians).
func drawHarvester(at origin: NSPoint, color: NSColor, reel: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.black.setFill()
    NSColor.black.setStroke()
    NSBezierPath(roundedRect: NSRect(x: 7, y: 4.4, width: 11.8, height: 5.8), xRadius: 1.2, yRadius: 1.2).fill()
    polygon([(7.2, 10), (8.1, 15.4), (12.1, 15.4), (12.1, 10)]).fill()
    NSBezierPath(roundedRect: NSRect(x: 12.7, y: 8.6, width: 6.1, height: 4.4), xRadius: 1.3, yRadius: 1.3).fill()
    segment((17.4, 12), (20.3, 15.2), width: 1.4).stroke()
    polygon([(7.2, 7.8), (7.2, 4.8), (6, 3.1), (4, 3.1)]).fill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 1.2, width: 6.9, height: 2), xRadius: 0.6, yRadius: 0.6).fill()
    // Cut the cab window and the gaps that set the wheels and the reel apart.
    ctx.setBlendMode(.clear)
    polygon([(8.6, 10.9), (9.2, 14.5), (11.3, 14.5), (11.3, 10.9)]).fill()
    disc(10.6, 3.9, 4.6).fill()
    disc(16.7, 2.8, 3.5).fill()
    disc(3.3, 7.5, 3.5).fill()
    ctx.setBlendMode(.normal)
    disc(10.6, 3.9, 3.8).fill()
    disc(16.7, 2.8, 2.7).fill()
    ctx.setBlendMode(.clear)
    disc(10.6, 3.9, 1.3).fill()
    disc(16.7, 2.8, 0.9).fill()
    ctx.setBlendMode(.normal)
    let ring = disc(3.3, 7.5, 2.5)
    ring.lineWidth = 1
    ring.stroke()
    for k in 0..<3 {
        let a = reel + CGFloat(k) * .pi / 3
        segment((3.3 - 2.5 * cos(a), 7.5 - 2.5 * sin(a)), (3.3 + 2.5 * cos(a), 7.5 + 2.5 * sin(a)), width: 0.85).stroke()
    }
    color.setFill()
    ctx.setBlendMode(.sourceIn)
    NSRect(x: 0, y: 0, width: 21, height: 16).fill()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// A dashboard gauge in a 16 × 16 pt box: a 270° dial open at the bottom, the
/// used part over the track, a needle, and the limit's letter in the gap.
func drawGauge(at origin: NSPoint, pct: Double, tag: String) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let c = NSPoint(x: origin.x + 8, y: origin.y + 8)
    let r: CGFloat = 6.6, start: CGFloat = 225, sweep: CGFloat = 270
    let f = CGFloat(min(max(pct, 0), 100) / 100)
    func arc(to fraction: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r, startAngle: start, endAngle: start - sweep * fraction, clockwise: true)
        p.lineWidth = 1.8
        p.lineCapStyle = .round
        return p
    }
    let label = NSAttributedString(string: tag, attributes: [
        .font: NSFont.systemFont(ofSize: 6, weight: .bold),
        .foregroundColor: NSColor.secondaryLabelColor,
    ])
    label.draw(at: NSPoint(x: c.x - label.size().width / 2, y: origin.y - 1))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.tertiaryLabelColor.setStroke()
    arc(to: 1).stroke()
    // `.copy` replaces what's under it, so the used arc isn't mixed with the track.
    ctx.setBlendMode(.copy)
    let color = warningColor(pct) ?? .labelColor
    color.setStroke()
    color.setFill()
    if f > 0.005 { arc(to: f).stroke() }
    let a = (start - sweep * f) * .pi / 180
    segment((c.x, c.y), (c.x + (r - 2.4) * cos(a), c.y + (r - 2.4) * sin(a)), width: 1.2).stroke()
    disc(c.x, c.y, 1.2).fill()
    ctx.endTransparencyLayer()
}

/// The status item's image: the harvester, then one gauge per limit. Drawn on
/// demand, so it follows the menu bar's light or dark appearance.
func menuBarImage(gauges: [(tag: String, pct: Double)], reel: CGFloat) -> NSImage {
    let width: CGFloat = gauges.isEmpty ? 21 : 26 + CGFloat(gauges.count) * 19 - 3
    return NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
        drawHarvester(at: NSPoint(x: 0, y: 1), color: .labelColor, reel: reel)
        for (i, g) in gauges.enumerated() {
            drawGauge(at: NSPoint(x: 26 + CGFloat(i) * 19, y: 1), pct: g.pct, tag: g.tag)
        }
        return true
    }
}

/// `date` written in `pattern` (e.g. "HH:mm"), in the Mac's locale and time zone.
func formatTime(_ date: Date, _ pattern: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = pattern
    return formatter.string(from: date)
}

protocol WidgetActions: AnyObject {
    func refreshNow()
    func runAll()
    func runOne(_ task: HTask)
    func stopHarvest()
    func setQueued(_ task: HTask, _ queued: Bool)
    func openNeed(_ task: HTask)
    func setConfig(_ config: HarvestConfig)
    func toggleStartAtLogin(_ on: Bool)
    func setMenuBar(_ on: Bool)
    func openHarvestFolder()
    func watchRun()
    func watchTerminal()
    func openLastRun()
    func openDone(_ task: HTask)
    func talk()
    func showHelp()
    func showSetup()
    func startOnboarding()
    func showSettings()
    func removeProposal(_ task: HTask)
    func setProposals(project: String, name: String, on: Bool)
    func setLanguage(hebrew: Bool)
    func saveHarvestSettings(_ values: [String])
    func moveQueued(_ id: String, before target: String?)
    func resetQueueOrder()
}

final class WidgetModel: ObservableObject {
    @Published var session: Metric?
    @Published var weekly: Metric?
    @Published var scoped: Metric?
    @Published var scopedLabel = "Fable"
    @Published var userLine = ""
    @Published var dotColor: NSColor = .tertiaryLabelColor
    @Published var dotTip = L("ממתין לנתונים…", "Waiting for data…")
    /// Whether the harvest engine is installed; until it is, the panel shows only the usage and
    /// an invitation to set it up. True until the first check, so nothing flashes at start.
    @Published var harvestInstalled = true
    /// The queued task a dragged one would land above while it's held over it ("end" = the bottom).
    @Published var queueDropTarget: String?
    @Published var listing = HListing() {
        didSet {
            if let dir = listing.settings?.workdir, !dir.isEmpty {
                harvestWorkdir = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            }
            if !uiLanguageForced, let lang = listing.settings?.language { uiHebrew = lang == "he" }
        }
    }
    @Published var config = loadHarvestConfig()
    @Published var running = false
    /// ↻ turns while a manual refresh is on its way.
    @Published var refreshing = false
    /// The footer's line about the automatic harvest: a countdown to `autoNext`,
    /// or `autoNote` instead ("אוטומטי כבוי", "מתחיל עכשיו"). Set by the app from
    /// the same rules the trigger uses.
    @Published var autoNext: Date?
    @Published var autoNote: String?
    /// A widget-launched run whose launcher outlived a widget restart: shown and stoppable.
    @Published var detachedRun = false
    @Published var externalRun = false
    @Published var flash: String?
    @Published var startAtLogin = false
    @Published var inMenuBar = false
    @Published var now = Date()
    /// Off for snapshots, so rendering a preview never changes the owner's layout.
    var persistsLayout = true
    @Published var queueOpen = UserDefaults.standard.object(forKey: "QueueOpen") as? Bool ?? true {
        didSet { remember(queueOpen, "QueueOpen") }
    }
    @Published var proposalsOpen = UserDefaults.standard.bool(forKey: "ProposalsOpen") {
        didSet { remember(proposalsOpen, "ProposalsOpen") }
    }
    @Published var needsOpen = UserDefaults.standard.object(forKey: "NeedsOpen") as? Bool ?? true {
        didSet { remember(needsOpen, "NeedsOpen") }
    }
    @Published var scheduleOpen = UserDefaults.standard.bool(forKey: "ScheduleOpen") {
        didSet { remember(scheduleOpen, "ScheduleOpen") }
    }
    @Published var doneOpen = UserDefaults.standard.bool(forKey: "DoneOpen") {
        didSet { remember(doneOpen, "DoneOpen") }
    }
    weak var actions: WidgetActions?

    private func remember(_ open: Bool, _ key: String) {
        if persistsLayout { UserDefaults.standard.set(open, forKey: key) }
    }

    var harvestActive: Bool { running || detachedRun || externalRun }
    var ownRunActive: Bool { running || detachedRun }
    var lastRunInApp: Bool { listing.launch?.sessionId != nil && listing.launch?.endedAt != nil }
    var queuePct: Double { listing.queue.reduce(0) { $0 + $1.pct } }

    /// Weekly points one 5-hour window can deliver, keeping the engine's
    /// 15-point margin free, from the engine's calibration.
    var weeklyPointsPerWindow: Double {
        guard let r = listing.ratio, r.weekly > 0 else { return 85 / 3.8 }
        return 85 * r.five / r.weekly
    }
    var harvestWindows: Int { Int((Double(config.leadHours) / 5).rounded(.up)) }
    var harvestCapacity: Double {
        let room = 100 - (weekly?.pct ?? 100) - 2
        return max(0, min(room, Double(harvestWindows) * weeklyPointsPerWindow))
    }
}

struct PanelView: View {
    @ObservedObject var m: WidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            usage
            if m.harvestInstalled {
                section(L("בתור", "Queue"), summary: queueSummary, open: $m.queueOpen) { queueList }
                section(L("הצעות", "Proposals"), summary: proposalsSummary, open: $m.proposalsOpen) { proposalList }
                section(L("מחכה לך", "Waiting for you"), summary: "\(m.listing.needsYou.count)", open: $m.needsOpen,
                        highlight: !m.listing.needsYou.isEmpty) { needsList }
                section(L("בוצעו", "Done"), summary: doneSummary, open: $m.doneOpen) { doneList }
                footer
            } else {
                setupInvitation
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 12))
        .environment(\.layoutDirection, uiHebrew ? .rightToLeft : .leftToRight)
        .frame(maxHeight: .infinity, alignment: .top)
        // The panel becomes key to take clicks; that mustn't paint a focus ring
        // around its first button.
        .focusEffectDisabled()
    }

    // MARK: Header and usage

    var header: some View {
        HStack(spacing: 8) {
            Text("Claude").font(.system(size: 13, weight: .semibold))
            if !m.userLine.isEmpty {
                Text(m.userLine).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Circle().fill(Color(nsColor: m.dotColor)).frame(width: 7, height: 7).help(m.dotTip)
            Button { m.actions?.refreshNow() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                    .symbolEffect(.rotate, isActive: m.refreshing)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(L("רענן עכשיו", "Refresh now"))
            Menu {
                Button(L("הגדרות…", "Settings…")) { m.actions?.showSettings() }
                Divider()
                Button(L("פתח את תיקיית הקציר", "Open the harvest folder")) { m.actions?.openHarvestFolder() }
                Button(L("צפה בריצה בטרמינל", "Watch the run in Terminal")) { m.actions?.watchTerminal() }
                Divider()
                Button(L("עזרה — איך זה עובד", "Help — how it works")) { m.actions?.showHelp() }
                Button(L("צא מהווידג'ט", "Quit the widget")) { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.bottom, 9)
    }

    var usage: some View {
        VStack(alignment: .leading, spacing: 3) {
            UsageRow(label: L("5 ש׳", "5h"), metric: m.session)
            UsageRow(label: L("שבועי", "Weekly"), metric: m.weekly)
            UsageRow(label: m.scopedLabel, metric: m.scoped)
            if let line = resetLine {
                Text(line).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 2)
            }
        }
    }

    var resetLine: String? {
        var parts: [String] = []
        if let d = m.session?.resetsAt, d > m.now { parts.append(L("5 ש׳ מתאפס ", "5h resets ") + whenText(d)) }
        if let d = m.weekly?.resetsAt { parts.append(L("שבועי ", "weekly ") + whenText(d)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Sections

    func section<Content: View>(_ title: String, summary: String, open: Binding<Bool>,
                                highlight: Bool = false,
                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 7)
            Button { withAnimation(.easeOut(duration: 0.15)) { open.wrappedValue.toggle() } } label: {
                HStack(spacing: 6) {
                    Chevron(open: open.wrappedValue)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(summary).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(highlight ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                .frame(height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.wrappedValue { content().padding(.top, 3) }
        }
    }

    var queueSummary: String {
        m.listing.queue.isEmpty ? L("ריק", "empty") : "\(m.listing.queue.count) · \(pctText(m.queuePct))"
    }

    var proposalsSummary: String {
        let n = m.listing.proposals.count
        guard n > 0 else { return "0" }
        let room = m.harvestCapacity - m.queuePct
        return room >= 5 ? L("\(n) · מקום לעוד \(pctText(room))", "\(n) · room for \(pctText(room)) more") : "\(n)"
    }

    @ViewBuilder var queueList: some View {
        if m.listing.queue.isEmpty {
            EmptyLine(text: L("התור ריק — ⊕ ליד הצעה מכניס אותה לתור", "The queue is empty — ⊕ next to a proposal puts it in"))
        } else {
            PctCaption()
            Text(L("למעלה רצה ראשונה · גרור כדי לשנות את הסדר", "Top runs first · drag to change the order"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            if m.listing.queue.count > 8 {
                ScrollView { orderedQueue }.frame(height: 220)
            } else {
                orderedQueue
            }
            if m.listing.queue.contains(where: { $0.placed == true }) {
                Button(L("↺ חזרה לסדר האוטומטי (חשיבות, ואז גודל)", "↺ Back to the automatic order (priority, then size)")) {
                    m.actions?.resetQueueOrder()
                }
                .buttonStyle(.link).font(.system(size: 11)).padding(.top, 3)
            }
        }
    }

    /// The queue as one list in the order it runs. Each row can be dragged (by the grip, or anywhere
    /// on it) and dropped on another row to land above it, or below the last row to go last.
    var orderedQueue: some View {
        let manyProjects = Set(m.listing.queue.map(\.project)).count > 1
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(m.listing.queue) { t in
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .help(L("גרור כדי לשנות את סדר הביצוע", "Drag to change the order they run in"))
                    TaskRow(task: t, queued: true, onRun: { m.actions?.runOne(t) },
                            onToggle: { m.actions?.setQueued(t, $0) }, showProject: manyProjects)
                }
                .contentShape(Rectangle())
                .overlay(alignment: .top) { dropLine(m.queueDropTarget == t.id) }
                .draggable(t.id) {
                    Text(t.title).font(.system(size: 12)).padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                }
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first, id != t.id else { return false }
                    m.actions?.moveQueued(id, before: t.id)
                    return true
                } isTargeted: { over in
                    if over { m.queueDropTarget = t.id } else if m.queueDropTarget == t.id { m.queueDropTarget = nil }
                }
            }
            Color.clear.frame(height: 8).contentShape(Rectangle())
                .overlay(alignment: .top) { dropLine(m.queueDropTarget == "end") }
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    m.actions?.moveQueued(id, before: nil)
                    return true
                } isTargeted: { over in
                    if over { m.queueDropTarget = "end" } else if m.queueDropTarget == "end" { m.queueDropTarget = nil }
                }
        }
    }

    func dropLine(_ shown: Bool) -> some View {
        Rectangle().fill(shown ? Color.accentColor : Color.clear).frame(height: 2)
    }

    @ViewBuilder var proposalList: some View {
        if m.listing.proposals.isEmpty {
            EmptyLine(text: L("אין הצעות", "No proposals"))
        } else {
            PctCaption()
            ByProject(tasks: m.listing.proposals, header: { first in
                AnyView(Menu {
                    Button(L("בלי הצעות מהפרויקט הזה…", "No proposals from this project…")) {
                        m.actions?.setProposals(project: first.project, name: first.projectName, on: false)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L("אפשרויות לפרויקט הזה", "Options for this project")))
            }) { t in
                TaskRow(task: t, queued: false, onRun: nil, onToggle: { m.actions?.setQueued(t, $0) },
                        onRemove: { m.actions?.removeProposal(t) })
            }
        }
    }

    var doneSummary: String {
        let today = m.listing.done.filter { ($0.ageDays ?? 0) == 0 }.count
        return today > 0 ? L("\(today) היום · \(m.listing.done.count)", "\(today) today · \(m.listing.done.count)")
            : "\(m.listing.done.count)"
    }

    @ViewBuilder var doneList: some View {
        if m.listing.done.isEmpty {
            EmptyLine(text: L("עוד לא בוצעו משימות", "No tasks done yet"))
        } else {
            ByDay(tasks: m.listing.done) { t in
                DoneRow(task: t) { m.actions?.openDone(t) }
            }
        }
    }

    @ViewBuilder var needsList: some View {
        if m.listing.needsYou.isEmpty {
            EmptyLine(text: L("אין מה לבדוק", "Nothing to review"))
        } else {
            ByProject(tasks: m.listing.needsYou) { t in
                NeedRow(task: t) { m.actions?.openNeed(t) }
            }
            Button(L("לשיחה עם קלוד על כל אלה ←", "Talk these over with Claude →")) { m.actions?.talk() }
                .buttonStyle(.link).font(.system(size: 11)).padding(.top, 4)
                .help(L("קלוד מסביר מה מחכה לך ומה הוא ממליץ, וממזג רק באישורך",
                        "Claude explains what's waiting for you and what it recommends, and merges only with your approval"))
        }
    }

    // MARK: Footer

    /// The panel while the harvest isn't installed: what it is, and the way in.
    var setupInvitation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 7)
            Text(L("קציר מכסה", "Quota harvest")).font(.system(size: 12, weight: .semibold))
            Text(L("מכסה שבועית שלא נוצלה הולכת לאיבוד באיפוס. הקציר מנצל אותה על משימות קטנות מהפרויקטים שלך — כל אחת בענף משלה, ורק אתה ממזג.",
                   "Weekly quota you don't use is lost at the reset. The harvest spends it on small tasks from your projects — each on its own branch, and only you merge."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L("הגדר את הקציר…", "Set up the harvest…")) { m.actions?.showSetup() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.top, 7)
            if m.harvestActive { runningView } else { idleView }
            if let f = m.flash {
                Text(f).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    var runningView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PulsingDot(color: .systemGreen)
                Text(runningText).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if m.ownRunActive {
                    Button(L("צפה", "Watch")) { m.actions?.watchRun() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .help(L("פותח באפליקציית Claude את המשימה שרצה עכשיו — בתוך הפרויקט שלה. אפשר גם לכתוב לה",
                                "Opens the task running now in the Claude app — inside its project. You can write to it too"))
                    Button(L("עצור", "Stop")) { m.actions?.stopHarvest() }.controlSize(.small)
                }
            }
            ProgressView().progressViewStyle(.linear).controlSize(.small)
        }
    }

    var runningText: String {
        if !m.ownRunActive { return L("קציר רץ מסשן אחר", "A harvest is running from another session") }
        let finished = m.listing.status?.doneThisRun?.count ?? 0
        guard let c = m.listing.status?.current, let title = c.title else {
            return finished > 0 ? L("בוחר את המשימה הבאה · \(finished) הסתיימו", "Picking the next task · \(finished) done")
                : L("מתחיל את הקציר…", "Starting the harvest…")
        }
        var s = L("מריץ · \(c.projectName ?? "") · \(title)", "Running · \(c.projectName ?? "") · \(title)")
        if finished > 0 { s += L(" · \(finished) הסתיימו", " · \(finished) done") }
        return s
    }

    var idleView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { m.scheduleOpen.toggle() } } label: {
                    HStack(spacing: 6) {
                        Chevron(open: m.scheduleOpen)
                        Text(L("קציר", "Harvest")).font(.system(size: 12, weight: .semibold))
                        nextHarvestText.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 6)
                if !m.listing.queue.isEmpty {
                    // The queue's share is in its header; the countdown needs the room here.
                    Button { m.actions?.runAll() } label: { Text(L("הרץ עכשיו", "Run now")) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .help(L("מריץ עכשיו את כל התור (\(pctText(m.queuePct)) מהמכסה השבועית), בגבולות המכסה שנשארה",
                                "Runs the whole queue now (\(pctText(m.queuePct)) of the weekly quota), within the quota that's left"))
                }
            }
            if m.scheduleOpen { scheduleEditor }
            if let last = lastRunText {
                let line = Text(last).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if m.lastRunInApp {
                    Button { m.actions?.openLastRun() } label: { line.contentShape(Rectangle()) }
                        .buttonStyle(.plain).modifier(HoverHighlight())
                        .help(L("פותח באפליקציית Claude את שיחת הריצה — מה הסוכן עשה ולמה",
                                "Opens the run's conversation in the Claude app — what the agent did and why"))
                } else {
                    line
                }
            }
        }
    }

    /// The next automatic harvest as a live countdown; the time itself is in the tooltip.
    @ViewBuilder var nextHarvestText: some View {
        if let next = m.autoNext {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(next > ctx.date ? countdownText(to: next, now: ctx.date) : L("מתחיל עכשיו", "starting now"))
                    .monospacedDigit()
            }
            .help(L("הקציר הבא: ", "Next harvest: ") + whenText(next))
        } else {
            Text(m.autoNote ?? "–")
        }
    }

    var scheduleEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                leadText
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { m.config.auto }, set: { v in
                    var c = m.config
                    c.auto = v
                    m.actions?.setConfig(c)
                }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden().help(L("קציר אוטומטי", "Automatic harvest"))
            }
            // Continuous (no tick marks); the binding rounds to whole hours.
            Slider(value: Binding(get: { Double(m.config.leadHours) }, set: { v in
                var c = m.config
                c.leadHours = Int(v.rounded())
                m.actions?.setConfig(c)
            }), in: 1...24)
            .controlSize(.small)
            Text(capacityText).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.leading, 16)
    }

    /// "Starts **8h** before the reset", the hours in bold. A whole literal per language, not
    /// L() pieces: strings interpolated into a Text are isolated from one another, and with no
    /// Hebrew letter left outside them the sentence would lay out left to right, its order scrambled.
    var leadText: Text {
        uiHebrew ? Text("יוצא לדרך \(Text("\(m.config.leadHours) ש׳").fontWeight(.semibold)) לפני האיפוס")
            : Text("Starts \(Text("\(m.config.leadHours)h").fontWeight(.semibold)) before the reset")
    }

    var capacityText: String {
        let w = m.harvestWindows
        return L("\(w) \(w == 1 ? "חלון" : "חלונות") של 5 ש׳ · מספיק לכ־\(pctText(m.harvestCapacity)) · בתור \(pctText(m.queuePct))",
                 "\(w) × 5h \(w == 1 ? "window" : "windows") · enough for ~\(pctText(m.harvestCapacity)) · queued \(pctText(m.queuePct))")
    }

    var lastRunText: String? {
        guard let r = m.listing.status?.lastRun, let f = parseDate(r.finishedAt) else { return nil }
        var s = L("קציר אחרון ", "Last harvest ") + whenText(f) + L(" · \(r.done ?? 0) הסתיימו", " · \(r.done ?? 0) done")
        if let why = stopReasonText(r.stopReason) { s += " · " + why }
        return s
    }
}

/// Disclosure arrow: points along the reading direction when closed — left in the
/// right-to-left Hebrew panel, right in English — and down when open. Pinned to
/// left-to-right so SwiftUI doesn't mirror the symbol.
struct Chevron: View {
    let open: Bool
    /// Stored (not read in `body`), so a language change counts as a change to this view.
    var hebrew = uiHebrew
    var body: some View {
        Image(systemName: hebrew ? "chevron.left" : "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(open ? (hebrew ? -90 : 90) : 0))
            .frame(width: 10)
            .environment(\.layoutDirection, .leftToRight)
    }
}

struct PulsingDot: View {
    let color: NSColor
    @State private var dim = false
    var body: some View {
        Circle().fill(Color(nsColor: color)).frame(width: 7, height: 7)
            .opacity(dim ? 0.2 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct UsageRow: View {
    let label: String
    let metric: Metric?
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 44, alignment: .leading)
            UsageBar(value: metric?.pct ?? 0).frame(height: 5)
            Text(metric.map { "\(Int($0.pct.rounded()))%" } ?? "–")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .frame(height: 17)
        .help(metric?.resetsAt.map { L("מתאפס ", "Resets ") + whenText($0) } ?? "")
    }
}

struct UsageBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if value > 0.5 {
                    Capsule().fill(Color(nsColor: warningColor(value) ?? claudeBlue))
                        .frame(width: max(g.size.height, g.size.width * min(value, 100) / 100))
                }
            }
        }
    }
}

/// Rows grouped under a small project header, in the engine's order; long
/// lists scroll inside a fixed height so the panel stays compact.
/// A list that scrolls within a fixed height. The system's overlay scroller
/// always sits on the right and floats over the rows' buttons; this one hides it
/// and draws a slim indicator in a gutter of its own at the trailing edge — right
/// in English, left in Hebrew — so it never covers a row.
struct ScrollingList<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    struct Metrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 1
        var visible: CGFloat = 1
    }
    @State private var metrics = Metrics()

    var body: some View {
        HStack(spacing: 0) {
            ScrollView { content }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: Metrics.self) { g in
                    Metrics(offset: g.contentOffset.y, content: g.contentSize.height, visible: g.containerSize.height)
                } action: { _, new in metrics = new }
            GeometryReader { box in
                let ratio = min(1, metrics.visible / max(metrics.content, 1))
                let thumb = max(24, box.size.height * ratio)
                let travel = box.size.height - thumb
                let progress = min(max(metrics.offset / max(metrics.content - metrics.visible, 1), 0), 1)
                Capsule().fill(Color.secondary.opacity(0.4))
                    .frame(width: 3, height: thumb)
                    .offset(y: travel * progress)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .opacity(ratio < 1 ? 1 : 0)
            }
            .frame(width: 10)
        }
        .frame(height: height)
    }
}

struct ByProject<Row: View>: View {
    let tasks: [HTask]
    /// Something at the end of a project's name line (the proposals' ⋯ menu), given its first task.
    var header: ((HTask) -> AnyView)? = nil
    @ViewBuilder let row: (HTask) -> Row

    /// Projects in a fixed order, by name: a group never moves when one of its
    /// tasks leaves the list (the tasks themselves come sorted by priority).
    var projects: [String] {
        Set(tasks.map(\.projectName)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        if tasks.count > 7 {
            ScrollingList(height: 280) { rows }
        } else {
            rows
        }
    }

    var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(projects, id: \.self) { p in
                HStack(spacing: 4) {
                    Text(p).font(.system(size: 11)).foregroundStyle(.tertiary)
                    if let header = header, let first = tasks.first(where: { $0.projectName == p }) { header(first) }
                    Spacer(minLength: 4)
                }
                .frame(height: 20, alignment: .bottom)
                ForEach(tasks.filter { $0.projectName == p }) { t in row(t) }
            }
        }
    }
}

/// Completed tasks under היום / אתמול / השבוע / קודם, newest first.
struct ByDay<Row: View>: View {
    let tasks: [HTask]
    @ViewBuilder let row: (HTask) -> Row

    static func bucket(_ days: Int) -> String {
        switch days {
        case 0: return L("היום", "Today")
        case 1: return L("אתמול", "Yesterday")
        case 2...6: return L("השבוע", "This week")
        default: return L("קודם", "Earlier")
        }
    }

    var buckets: [String] {
        var seen = Set<String>()
        return tasks.map { Self.bucket($0.ageDays ?? 0) }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        if tasks.count > 8 {
            ScrollingList(height: 240) { rows }
        } else {
            rows
        }
    }

    var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(buckets, id: \.self) { b in
                Text(b).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(height: 18, alignment: .bottom)
                ForEach(tasks.filter { Self.bucket($0.ageDays ?? 0) == b }) { t in row(t) }
            }
        }
    }
}

/// A finished task: whether its branch waits for review or was merged. A click
/// opens the conversation that did it.
struct DoneRow: View {
    let task: HTask
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint).frame(width: 12)
                Text(task.title).lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(task.projectName).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    .frame(maxWidth: 90, alignment: .trailing)
            }
            .padding(.vertical, 3)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
        .help(tooltip)
    }

    var icon: String {
        switch task.branchState {
        case "unmerged": return "arrow.triangle.branch"
        case "merged": return "checkmark.circle.fill"
        case "archived": return "archivebox"
        default: return "checkmark.circle"
        }
    }

    var tint: AnyShapeStyle {
        switch task.branchState {
        case "unmerged": return AnyShapeStyle(Color.accentColor)
        case "merged": return AnyShapeStyle(Color.green)
        default: return AnyShapeStyle(.secondary)
        }
    }

    var tooltip: String {
        var lines = [task.title]
        if let s = task.summary, !s.isEmpty { lines.append(s) }
        switch task.branchState {
        case "unmerged": lines.append(L("הענף \(task.branch ?? "") מחכה לבדיקה ולמיזוג שלך",
                                        "Branch \(task.branch ?? "") is waiting for your review and merge"))
        case "merged": lines.append(L("מוזג", "Merged"))
        case "archived": lines.append(L("הועבר לארכיון", "Archived"))
        default: break
        }
        if task.sessionId != nil {
            lines.append(L("לחיצה: הסשן שביצע את זה, באפליקציית Claude", "Click: the session that did it, in the Claude app"))
        }
        return lines.joined(separator: "\n")
    }
}

/// A soft highlight behind a clickable row while the pointer is over it.
struct HoverHighlight: ViewModifier {
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(hover ? 0.07 : 0))
                .padding(.horizontal, -4))
            .onHover { hover = $0 }
    }
}

/// What the percentage next to a task means, above the queue and the proposals.
struct PctCaption: View {
    var body: some View {
        Text(L("האחוז: עלות משוערת בטוקנים, מתוך המכסה השבועית",
               "%: estimated token cost, of the weekly quota"))
            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 2)
    }
}

struct EmptyLine: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
            .frame(height: 20, alignment: .leading)
    }
}

struct TaskRow: View {
    let task: HTask
    let queued: Bool
    let onRun: (() -> Void)?
    let onToggle: (Bool) -> Void
    var onRemove: (() -> Void)? = nil
    /// The project's name under the title — the queue shows one list across projects.
    var showProject = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(task.title).lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                if showProject {
                    Text(task.projectName).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(pctText(task.pct)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .help(L("עלות משוערת: כ־\(task.tokens / 1000) אלף טוקנים, \(pctText(task.pct)) מהמכסה השבועית",
                        "Estimated cost: ~\(task.tokens / 1000)K tokens, \(pctText(task.pct)) of the weekly quota"))
            if let onRun = onRun {
                Button(action: onRun) { Image(systemName: "play.fill").font(.system(size: 8)) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .help(L("הרץ עכשיו רק את המשימה הזו", "Run just this task now"))
            }
            if let onRemove = onRemove {
                Button(action: onRemove) { Image(systemName: "trash").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("מחק את ההצעה — היא לא תוצע שוב", "Delete this proposal — it won't be proposed again"))
            }
            // Queue and unqueue with one icon each: ⊕ puts a proposal in the queue, ⊖ takes a task out.
            Button { onToggle(!queued) } label: {
                Image(systemName: queued ? "minus.circle" : "plus.circle").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(queued ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            .help(queued ? L("הוצא מהתור — חוזרת להצעות", "Take it out of the queue — back to the proposals")
                  : L("הכנס לתור — תרוץ בקציר הבא", "Put it in the queue — it runs in the next harvest"))
        }
        .padding(.vertical, 3)
        .frame(minHeight: 24)
        .help(tooltip)
    }

    var tooltip: String {
        var s = task.title
        if let d = task.details, !d.isEmpty { s += "\n" + d }
        s += L("\nמורכבות \(task.complexity) · ~\(task.tokens / 1000)k טוקנים",
               "\nComplexity \(task.complexity) · ~\(task.tokens / 1000)k tokens")
        if let e = task.estimate, let base = e.base, let turns = e.turns {
            let baseNote = e.baseSource == "measured" ? L("נמדד בפרויקט", "measured in the project")
                : L("משוער מ-CLAUDE.md", "estimated from CLAUDE.md")
            let turnsNote = e.turnsSource == "learned" ? L("לפי ריצות קודמות", "from earlier runs")
                : L("ברירת מחדל עד שיימדד", "a default until measured")
            s += L("\n≈ \(turns) סבבים (\(turnsNote)) × הקשר פתיחה ~\(base / 1000)k (\(baseNote))",
                   "\n≈ \(turns) turns (\(turnsNote)) × starting context ~\(base / 1000)k (\(baseNote))")
        }
        return s
    }
}

struct NeedRow: View {
    let task: HTask
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: task.status == "blocked" ? "questionmark.circle" : "arrow.triangle.branch")
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 12)
                Text(task.title).lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(age).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle((task.ageDays ?? 0) >= 14 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                Image(systemName: "arrow.up.forward.app").font(.system(size: 10)).foregroundStyle(Color.accentColor)
            }
            .padding(.vertical, 3)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.status == "blocked"
              ? L("חסום: ", "Blocked: ") + (task.question ?? "")
              : L("פתח סשן בקלוד שמציג את השינוי וממזג באישורך",
                  "Open a Claude session that shows the change and merges it with your approval"))
    }

    var age: String {
        switch task.ageDays ?? 0 {
        case 0: return L("היום", "today")
        case 1: return L("אתמול", "yesterday")
        case let d: return L("\(d) ימים", "\(d) days")
        }
    }
}

// MARK: Help

/// ⋯ → "עזרה": what every part of the panel means, in plain words for the owner — `topics` in
/// Hebrew, `englishTopics` in English, the same topics line for line. It must stay true to the
/// panel: a change to what a section, button or state does updates both lists in the same change
/// (AGENTS.md; check with `--snapshot-help --he` and `--en`).
struct HelpView: View {
    var scrolls = true
    /// Stored, so a language change counts as a change to this view.
    var hebrew = uiHebrew

    func T(_ he: String, _ en: String) -> String { hebrew ? he : en }

    static let topics: [(title: String, lines: [String])] = [
        ("מה זה", [
            "הווידג'ט מראה כמה ממכסת Claude כבר נוצלה, ומנהל את **הקציר**: ניצול של מכסה שבועית שהייתה הולכת לאיבוד באיפוס, על משימות קטנות מהבקלוג של הפרויקטים שלך.",
            "כל פרויקט מחזיק קובץ `BACKLOG.md`. הווידג'ט רק מציג אותו ומפעיל את המנוע — הוא לא עורך אותו בעצמו.",
        ]),
        ("המדדים למעלה", [
            "**5 ש׳** — חלון של חמש שעות. **שבועי** — כל המודלים. השורה השלישית — מכסה שבועית של מודל מסוים (למשל Fable).",
            "כחול עד 70%, כתום מ-70%, אדום מ-90%. מתחת: מתי כל מכסה מתאפסת.",
            "הנקודה הצבעונית: **ירוק** — מחובר. **צהוב** — יש תקלה והווידג'ט מנסה שוב לבד. **אדום** — צריך אותך: להתחבר מחדש ל-Claude Code. ↻ מרענן עכשיו.",
        ]),
        ("בתור", [
            "משימות שאישרת. הן ירוצו בקציר הבא.",
            "ליד כל משימה: כמה אחוזים מהמכסה השבועית היא צפויה לעלות. זו הערכה, והיא משתפרת עם כל ריצה.",
            "**▶** מריץ רק את המשימה הזאת, עכשיו. **⊖** מוציא אותה מהתור ומחזיר אותה להצעות — היא לא תרוץ עד שתכניס אותה שוב.",
            "בכותרת: כמה משימות, וכמה אחוזים כולן יחד.",
            "**הסדר ברשימה הוא סדר הביצוע** — העליונה רצה ראשונה. בלי התערבות שלך הסדר הוא לפי חשיבות, ובאותה חשיבות הגדולה קודם.",
            "**גרירה:** תופסים משימה (או את הידית ≡ שלידה) ומשחררים על משימה אחרת — היא נוחתת מעליה; מתחת לאחרונה — היא עוברת לסוף. **\"חזרה לסדר האוטומטי\"** מבטל את מה שגררת.",
        ]),
        ("הצעות", [
            "משימות שעוד לא אישרת: רעיונות שסוכן רשם כשעבד לבד, או משימות שהשהית. הן לא ירוצו.",
            "**⊕ = אישור**, והמשימה עוברת לתור. סוכן אף פעם לא מאשר משימה לעצמו.",
            "\"מקום לעוד X%\" בכותרת — כמה עוד ייכנס לקציר הבא אם תאשר.",
            "**פח** ליד הצעה מוחק אותה — והיא לא תוצע שוב. **⋯** ליד שם הפרויקט: **\"בלי הצעות מהפרויקט הזה\"** מסיר את כל ההצעות שלו, וסוכנים לא יציעו בו חדשות. מחזירים בהגדרות.",
        ]),
        ("מחכה לך", [
            "עבודה שהקציר גמר ומחכה לך: ענף עם שינויים שעוד לא מוזג, או שאלה שהסוכן נתקע עליה. ליד כל שורה — כמה זמן היא מחכה (כתום אחרי 14 יום).",
            "הסמלים: **ענף** — שינוי גמור שעוד לא מוזג. **סימן שאלה** — שאלה שהסוכן נתקע עליה. **חץ יוצא מריבוע** — נפתח באפליקציית Claude.",
            "**לחיצה על שורה** פותחת סשן באפליקציית Claude שמראה מה השתנה, וממזג רק אם תאשר. בשאלה — עונים לו שם.",
            "**\"לשיחה עם קלוד על כל אלה\"** בתחתית — שיחה אחת שעוברת על הכול וממליצה על כל פריט.",
            "כשמשהו מחכה יומיים ויותר מגיעה תזכורת (בין 10:00 ל-21:00). \"מחר\" דוחה אותה ביום. ענף שלא נגעת בו 35 יום עובר לארכיון — לא נמחק.",
        ]),
        ("בוצעו", [
            "מה שהושלם ב-30 הימים האחרונים: היום, אתמול, השבוע, קודם.",
            "הסמל: **ענף כחול** — מחכה לבדיקה שלך. **וי ירוק** — מוזג. **קופסה** — עבר לארכיון. **וי רגיל** — בוצע בלי ענף של קציר.",
            "**לחיצה על שורה** פותחת באפליקציית Claude את הסשן שעשה את העבודה.",
        ]),
        ("קציר (בתחתית)", [
            "ספירה לאחור עד שהקציר האוטומטי מתחיל. הוא יוצא לדרך כמה שעות לפני האיפוס השבועי — כמה, קובעים בסליידר (1–24 שעות) — ורק כשהמתג \"אוטומטי\" דלוק.",
            "**הרץ עכשיו** מריץ את כל התור מיד.",
            "בזמן ריצה: נקודה מהבהבת, המשימה הנוכחית, **צפה** (הסשן החי באפליקציית Claude) ו**עצור**. אפשר גם לכתוב לו מהאפליקציה או מהטלפון.",
            "כל משימה רצה בסשן משלה ובענף נפרד משלה בתוך הפרויקט. שום דבר לא נדחף לשרת ולא ממוזג — את זה רק אתה מאשר. משימה שלא תספיק להסתיים לפני האיפוס לא מתחילה.",
            "אחרי ריצה: שורת \"קציר אחרון\" — לחיצה פותחת את כל השיחה של הריצה.",
        ]),
        ("התפריט ⋯", [
            "**הגדרות…** · **פתח את תיקיית הקציר** (דוחות ולוגים) · **צפה בריצה בטרמינל** · **עזרה** — המסך הזה · **צא מהווידג'ט**.",
        ]),
        ("הגדרות", [
            "**כללי:** שפה, הפעלה בכניסה למחשב, ובשורת התפריט או כווידג'ט צף.",
            "**קציר:** קציר אוטומטי וכמה שעות לפני האיפוס, מודל לכל גודל משימה, שם, תיקייה ומייל לסיכום שבועי (שומרים בכפתור \"שמור\").",
            "**פרויקטים:** מתג \"הצעות\" לכל פרויקט רשום — כבוי = בלי הצעות ממנו. בתחתית: עזרה והסרת הקציר.",
        ]),
        ("הגדרה והתקנה", [
            "כשהקציר לא מותקן, הווידג'ט מראה רק את המדדים וכפתור **\"הגדר את הקציר…\"**.",
            "ההתקנה שואלת שם, שפה (עברית או אנגלית), תיקייה ומייל לסיכום שבועי (לא חובה) — ומראה בדיוק מה ייכתב לפני שהיא כותבת: המנוע, הסקילים, והנחיה לסוכנים ב-CLAUDE.md שמלמדת אותם לרשום משימות לבקלוג.",
            "כל קובץ שהיא מחליפה נשמר קודם בגיבוי. את ההגדרות משנים ב**הגדרות…** בתפריט ⋯; שם גם מסירים את הקציר — התור, ההיסטוריה והענפים נשארים.",
            "בסוף ההתקנה: **\"התחל שיחת היכרות\"** — שיחה חיה באפליקציית Claude שמוצאת את הפרויקטים שעבדת עליהם, שואלת על אילו לעבוד, ורושמת משימות ראשונות כהצעות.",
        ]),
        ("איך משימות נכנסות", [
            "כל סשן של Claude או Codex יכול לרשום משימה לבקלוג של הפרויקט — גם כשאתה אומר לו \"תוסיף לבקלוג\" או \"לא עכשיו\".",
            "כשאתה נוכח ומסכים היא נכנסת **לתור**. כשסוכן עובד לבד היא נכנסת **להצעות**.",
        ]),
    ]

    static let englishTopics: [(title: String, lines: [String])] = [
        ("What it is", [
            "The widget shows how much of your Claude quota is already used, and runs the **harvest**: it spends weekly quota that would otherwise be lost at the reset on small tasks from your projects' backlogs.",
            "Each project keeps a `BACKLOG.md` file. The widget only shows it and runs the engine — it never edits the file itself.",
        ]),
        ("The meters at the top", [
            "**5h** — the five-hour window. **Weekly** — all models. The third row — the weekly quota of one particular model (for example Fable).",
            "Blue below 70%, orange from 70%, red from 90%. Underneath: when each quota resets.",
            "The colored dot: **green** — connected. **Yellow** — something went wrong and the widget is retrying on its own. **Red** — it needs you: sign in to Claude Code again. ↻ refreshes now.",
        ]),
        ("Queue", [
            "Tasks you approved. They run in the next harvest.",
            "Next to each task: what share of the weekly quota it's expected to cost. It's an estimate, and it gets better with every run.",
            "**▶** runs just this task, now. **⊖** takes it out of the queue, back to the proposals — it won't run until you put it back.",
            "In the header: how many tasks, and how many percent they come to together.",
            "**The list's order is the order they run in** — the top one runs first. Left alone, it's by priority, and within a priority the bigger task first.",
            "**Dragging:** grab a task (or the ≡ grip next to it) and drop it on another one — it lands above it; below the last one — it goes last. **\"Back to the automatic order\"** undoes what you dragged.",
        ]),
        ("Proposals", [
            "Tasks you haven't approved yet: ideas an agent noted while working on its own, or tasks you paused. They don't run.",
            "**⊕ = approving it**, and the task moves to the queue. An agent never approves a task for itself.",
            "\"room for X% more\" in the header — how much more fits into the next harvest if you approve.",
            "**The trash can** next to a proposal deletes it — it won't be proposed again. **⋯** next to a project's name: **\"No proposals from this project\"** removes all its proposals, and agents won't propose new ones there. Turn it back on in Settings.",
        ]),
        ("Waiting for you", [
            "Work the harvest finished that is waiting for you: a branch with changes not merged yet, or a question the agent got stuck on. Next to each row — how long it has waited (orange after 14 days).",
            "The icons: **a branch** — finished changes not merged yet. **A question mark** — a question the agent got stuck on. **An arrow out of a square** — opens in the Claude app.",
            "**Clicking a row** opens a session in the Claude app that shows what changed, and merges only if you approve. For a question — you answer it there.",
            "**\"Talk these over with Claude\"** at the bottom — one conversation that goes through everything and recommends what to do with each item.",
            "When something has waited two days or more, a reminder comes (between 10:00 and 21:00). \"Tomorrow\" puts it off by a day. A branch you haven't touched for 35 days is archived — not deleted.",
        ]),
        ("Done", [
            "What was completed in the last 30 days: today, yesterday, this week, earlier.",
            "The icon: **blue branch** — waiting for your review. **Green check** — merged. **Box** — archived. **Plain check** — done without a harvest branch.",
            "**Clicking a row** opens the session that did the work in the Claude app.",
        ]),
        ("Harvest (at the bottom)", [
            "A countdown to the start of the automatic harvest. It starts a few hours before the weekly reset — how many, you set with the slider (1–24 hours) — and only while the \"automatic\" switch is on.",
            "**Run now** runs the whole queue right away.",
            "During a run: a blinking dot, the current task, **Watch** (the live session in the Claude app) and **Stop**. You can also write to it from the app or from your phone.",
            "Each task runs in its own session and on its own branch inside the project. Nothing is pushed to the server or merged — only you approve that. A task that wouldn't finish before the reset doesn't start.",
            "After a run: the \"Last harvest\" line — a click opens the run's whole conversation.",
        ]),
        ("The ⋯ menu", [
            "**Settings…** · **Open the harvest folder** (reports and logs) · **Watch the run in Terminal** · **Help** — this screen · **Quit the widget**.",
        ]),
        ("Settings", [
            "**General:** language, start at login, and the menu bar or a floating widget.",
            "**Harvest:** automatic harvest and how many hours before the reset, a model per task size, your name, the folder and an email for a weekly summary (kept with \"Save\").",
            "**Projects:** a \"Proposals\" switch per registered project — off = no proposals from it. At the bottom: help and removing the harvest.",
        ]),
        ("Setup and install", [
            "While the harvest isn't installed, the widget shows only the meters and a **\"Set up the harvest…\"** button.",
            "The install asks for a name, a language (Hebrew or English), a folder and an email for a weekly summary (optional) — and shows exactly what will be written before it writes anything: the engine, the skills, and an instruction for agents in CLAUDE.md that teaches them to record tasks in the backlog.",
            "Every file it replaces is backed up first. Change the settings in **Settings…** in the ⋯ menu; the harvest is removed from there too — the queue, the history and the branches stay.",
            "When the install is done: **\"Start the getting-started conversation\"** — a live session in the Claude app that finds the projects you've worked on, asks which ones to use, and records first tasks as proposals.",
        ]),
        ("How tasks get in", [
            "Any Claude or Codex session can add a task to the project's backlog — also when you tell it \"add to backlog\" or \"not now\".",
            "When you're there and agree, it goes into the **Queue**. When an agent works on its own, it goes into **Proposals**.",
        ]),
    ]

    var shownTopics: [(title: String, lines: [String])] { hebrew ? Self.topics : Self.englishTopics }

    var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(T("איך הווידג'ט עובד", "How the widget works")).font(.system(size: 17, weight: .semibold))
            ForEach(shownTopics, id: \.title) { topic in
                VStack(alignment: .leading, spacing: 5) {
                    Text(topic.title).font(.system(size: 13, weight: .semibold))
                    ForEach(topic.lines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.tertiary)
                            Text(LocalizedStringKey(line)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
    }

    var body: some View {
        Group {
            if scrolls { ScrollView { content } } else { content.fixedSize(horizontal: false, vertical: true) }
        }
        .font(.system(size: 12))
        .environment(\.layoutDirection, hebrew ? .rightToLeft : .leftToRight)
        .focusEffectDisabled()
    }
}

// MARK: Setup

/// The harvest's setup window (the panel's button while it isn't installed, or ⋯ → "הגדרת
/// הקציר"): a few details, then exactly what `install.py plan` says will be written, then the
/// install. Plain code installs — no agent. It follows the language picked in it, live.
final class SetupModel: ObservableObject {
    enum Step { case form, review, done }
    @Published var step = Step.form
    @Published var name = NSFullUserName()
    @Published var hebrew = uiHebrew
    @Published var email = ""
    @Published var digest = false
    @Published var workdir = "~/claude-harvest"
    @Published var replaceExisting = false
    @Published var installed = false
    @Published var plan: InstallPlan?
    @Published var busy = false
    @Published var error: String?
    var onChanged: (() -> Void)?
    var onUninstall: (() -> Void)?
    var onOnboard: (() -> Void)?

    func T(_ he: String, _ en: String) -> String { hebrew ? he : en }

    var args: [String] {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        var a = ["--name", name.trimmingCharacters(in: .whitespaces), "--language", hebrew ? "he" : "en",
                 "--workdir", workdir.trimmingCharacters(in: .whitespaces), "--email", trimmedEmail,
                 "--email-digest", digest && !trimmedEmail.isEmpty ? "yes" : "no"]
        if replaceExisting { a.append("--replace-existing") }
        return a
    }

    /// Opens on the form, filled from the settings when the harvest is installed already.
    func load() {
        step = .form; error = nil; plan = nil; replaceExisting = false; busy = true
        runInstaller(["plan"]) { [weak self] data, _ in
            guard let self else { return }
            self.busy = false
            guard let data = data, let p = try? JSONDecoder().decode(InstallPlan.self, from: data) else {
                self.error = self.T("המתקין של הקציר לא נמצא ליד הווידג'ט — בנה אותו מחדש עם ./install.",
                                    "The harvest installer isn't next to the widget — rebuild it with ./install.")
                return
            }
            self.installed = p.installed ?? false
            guard let v = p.settings?.values, p.settings?.action == "update" else { return }
            if let n = v.ownerName, !n.isEmpty { self.name = n }
            if let l = v.language { self.hebrew = l == "he" }
            if let e = v.email { self.email = e }
            if let d = v.emailDigest { self.digest = d }
            if let w = v.workdir, !w.isEmpty { self.workdir = w }
        }
    }

    func review() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { error = T("חסר שם.", "Your name is missing."); return }
        guard !workdir.trimmingCharacters(in: .whitespaces).isEmpty else { error = T("חסרה תיקייה.", "The folder is missing."); return }
        error = nil; busy = true
        runInstaller(["plan"] + args) { [weak self] data, _ in
            guard let self else { return }
            self.busy = false
            guard let data = data, let p = try? JSONDecoder().decode(InstallPlan.self, from: data) else {
                self.error = self.T("המתקין לא הצליח לבדוק מה לכתוב.", "The installer couldn't work out what to write.")
                return
            }
            self.plan = p
            self.step = .review
        }
    }

    func install() {
        error = nil; busy = true
        runInstaller(["install"] + args) { [weak self] data, code in
            guard let self else { return }
            self.busy = false
            if code == 0 {
                self.installed = true
                self.step = .done
                self.onChanged?()
            } else if code == 3, let data = data, let p = try? JSONDecoder().decode(InstallPlan.self, from: data) {
                self.plan = p
                self.error = self.T("יש התנגשויות — שום דבר לא נכתב.", "There are conflicts — nothing was written.")
            } else {
                self.error = self.T("ההתקנה נכשלה.", "The install failed.")
            }
        }
    }
}

struct SetupView: View {
    @ObservedObject var s: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(s.installed && s.step != .done ? s.T("הגדרת הקציר", "Harvest setup") : s.T("התקנת הקציר", "Install the harvest"))
                .font(.system(size: 17, weight: .semibold))
            switch s.step {
            case .form: form
            case .review: review
            case .done: done
            }
            if let e = s.error {
                Text(e).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
        .font(.system(size: 12))
        .environment(\.layoutDirection, s.hebrew ? .rightToLeft : .leftToRight)
        .disabled(s.busy)
        .focusEffectDisabled()
    }

    func field(_ title: String, _ note: String? = nil, @ViewBuilder _ control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold))
            control()
            if let note = note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(s.T("הקציר מנצל מכסה שבועית שהייתה הולכת לאיבוד באיפוס, על משימות קטנות מהבקלוג של הפרויקטים שלך. כל משימה רצה בענף משלה — שום דבר לא ממוזג בלי אישור שלך.",
                     "The harvest spends weekly quota that would be lost at the reset on small tasks from your projects' backlogs. Each task runs on its own branch — nothing is merged without your approval."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            field(s.T("שפה", "Language"), s.T("של הווידג'ט, הדוחות וההודעות.", "For the widget, the reports and the notifications.")) {
                Picker("", selection: $s.hebrew) {
                    Text("עברית").tag(true)
                    Text("English").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            field(s.T("השם שלך", "Your name")) {
                TextField("", text: $s.name).textFieldStyle(.roundedBorder)
            }
            field(s.T("תיקיית הקציר", "Harvest folder"),
                  s.T("שם רצות שיחות התיאום של הקציר; באפליקציית Claude הן מופיעות תחת התיקייה הזאת.",
                      "The harvest's coordinating sessions run here; the Claude app lists them under this folder.")) {
                TextField("", text: $s.workdir).textFieldStyle(.roundedBorder)
                    .environment(\.layoutDirection, .leftToRight)
            }
            field(s.T("סיכום שבועי במייל (לא חובה)", "Weekly summary by email (optional)"),
                  s.T("נשלח דרך חיבור Gmail ב-Claude — בלי חיבור כזה פשוט לא יישלח.",
                      "Sent through a Gmail connector in Claude — without one it just isn't sent.")) {
                HStack(spacing: 8) {
                    TextField(s.T("כתובת מייל", "Email address"), text: $s.email).textFieldStyle(.roundedBorder)
                        .environment(\.layoutDirection, .leftToRight)
                    Toggle(s.T("שלח", "Send"), isOn: $s.digest).toggleStyle(.switch).controlSize(.mini)
                        .disabled(s.email.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack(spacing: 8) {
                Button(s.T("המשך — מה ייכתב", "Next — what will be written")) { s.review() }
                    .buttonStyle(.borderedProminent)
                if s.busy { ProgressView().controlSize(.small) }
                Spacer()
                if s.installed {
                    Button(s.T("הסר את הקציר…", "Remove the harvest…")) { s.onUninstall?() }
                }
            }
        }
    }

    func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    var review: some View {
        let p = s.plan
        let files = p?.files ?? []
        let conflicts = p?.conflicts ?? []
        let created = files.filter { $0.action == "create" }.count
        let changed = files.filter { $0.action == "update" || $0.action == "replace" }.count
        let same = files.filter { $0.action == "keep" }.count
        let total = files.count + conflicts.filter { $0.path.contains("/.claude/harvest/") || $0.path.contains("/.claude/skills/") }.count
        return VStack(alignment: .leading, spacing: 10) {
            Text(s.T("זה מה שייכתב במחשב — ורק זה:", "This is what will be written on this Mac — and only this:"))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                bullet(s.T("המנוע והסקילים: \(total) קבצים — \(created) חדשים, \(changed) מתעדכנים, \(same) כבר זהים\(conflicts.isEmpty ? "" : ", והשאר למטה").",
                           "The engine and the skills: \(total) files — \(created) new, \(changed) updated, \(same) already identical\(conflicts.isEmpty ? "" : ", the rest below")."),
                       path: "~/.claude/harvest · ~/.claude/skills")
                bullet(s.T("קיצור לפקודת הקציר:", "A link to the harvest command:"), path: "~/.local/bin/claude-harvest")
                ForEach(p?.blocks ?? [], id: \.path) { b in
                    bullet(s.T("הנחיה לסוכנים — \(changeName(b.change)). כך הם יודעים לרשום משימות לבקלוג:",
                               "Agent instructions — \(changeName(b.change)). This is how they learn to record backlog tasks:"),
                           path: tilde(b.path))
                    ScrollView {
                        Text(b.block).font(.system(size: 10, design: .monospaced))
                            .multilineTextAlignment(s.hebrew ? .trailing : .leading)
                            .frame(maxWidth: .infinity, alignment: s.hebrew ? .trailing : .leading).textSelection(.enabled)
                    }
                    .frame(height: 90).padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                }
                bullet(s.T("ההגדרות שלך, והתיקייה שבה רצות שיחות הקציר:", "Your settings, and the folder the harvest's sessions run in:"),
                       path: "~/.claude/harvest/settings.json · " + tilde(s.workdir))
                bullet(s.T("כל קובץ שמוחלף נשמר קודם בגיבוי. התור, ההיסטוריה, הדוחות והענפים לא נוגעים.",
                           "Anything replaced is backed up first. Your queue, history, reports and branches are not touched."))
            }
            if let conflicts = p?.conflicts, !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.T("כבר יש כאן קבצים שלא הותקנו מכאן:", "Some files here weren't installed from here:"))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                    ForEach(conflicts.prefix(6), id: \.path) { c in
                        Text("• " + tilde(c.path)).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    if conflicts.count > 6 {
                        Text(s.T("ועוד \(conflicts.count - 6)…", "and \(conflicts.count - 6) more…")).font(.system(size: 11))
                    }
                    Toggle(s.T("להחליף אותם בגרסה הזאת (עותק של כל אחד נשמר בגיבוי)",
                               "Replace them with this version (each is backed up first)"),
                           isOn: Binding(get: { s.replaceExisting }, set: { s.replaceExisting = $0; s.review() }))
                }
            }
            HStack(spacing: 8) {
                Button(s.T("התקן", "Install")) { s.install() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(p?.conflicts.isEmpty ?? false) && !s.replaceExisting)
                Button(s.T("חזרה", "Back")) { s.step = .form }
                if s.busy { ProgressView().controlSize(.small) }
            }
        }
    }

    func changeName(_ change: String) -> String {
        switch change {
        case "add": return s.T("תתווסף", "added")
        case "none": return s.T("כבר מעודכנת", "already up to date")
        default: return s.T("תוחלף בגרסה המנוהלת", "replaced by the managed version")
        }
    }

    /// A line of the review; a path goes on its own line under it — a left-to-right path inside
    /// a Hebrew sentence gets scrambled, and a Text holding only a path can safely be laid out
    /// left to right.
    func bullet(_ text: String, path: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                if let path = path {
                    Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
    }

    var done: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.T("הקציר מותקן.", "The harvest is installed.")).font(.system(size: 13, weight: .semibold))
            Text(s.T("מעכשיו כל שיחה של Claude (וגם Codex) יודעת לרשום משימות קטנות לבקלוג של הפרויקט. משימות שתאשר יופיעו ב\"בתור\", ויקצרו לפני האיפוס השבועי.",
                     "From now on every Claude session (and Codex) knows how to record small tasks in the project's backlog. Tasks you approve show under \"Queue\" and are harvested before the weekly reset."))
                .fixedSize(horizontal: false, vertical: true)
            Text(s.T("הצעד הבא: שיחת היכרות קצרה באפליקציית Claude. היא מוצאת את הפרויקטים שעבדת עליהם, שואלת על אילו לעבוד, ומציעה משימות ראשונות — כולן כהצעות שאתה מאשר במתג.",
                     "Next: a short getting-started conversation in the Claude app. It finds the projects you've worked on, asks which ones to use, and suggests first tasks — all as proposals you approve with their switch."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(s.T("התחל שיחת היכרות", "Start the getting-started conversation")) {
                    s.onOnboard?()
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
                Button(s.T("אחר כך", "Later")) { NSApp.keyWindow?.close() }
            }
        }
    }
}

// MARK: Settings

/// ⋯ → "הגדרות…": everything the owner can set, in one window — the widget (language, start at
/// login, menu bar), the harvest (name, email, folder, automatic runs, models) and which
/// projects may get proposals. Toggles apply at once; the text fields with "Save".
final class SettingsModel: ObservableObject {
    @Published var name = ""
    @Published var email = ""
    @Published var digest = false
    @Published var workdir = ""
    @Published var models: [String: String] = [:]
    @Published var saved = false

    func load(_ settings: HSettings?) {
        name = settings?.ownerName ?? ""
        email = settings?.email ?? ""
        digest = settings?.emailDigest ?? false
        workdir = settings?.workdir ?? ""
        models = settings?.models ?? [:]
        saved = false
    }
}

struct SettingsView: View {
    @ObservedObject var m: WidgetModel
    @ObservedObject var s: SettingsModel
    var scrolls = true

    static let modelChoices = ["haiku", "sonnet", "opus", "fable"]

    var body: some View {
        Group {
            if scrolls { ScrollView { content } } else { content.fixedSize(horizontal: false, vertical: true) }
        }
        .font(.system(size: 12))
        .environment(\.layoutDirection, uiHebrew ? .rightToLeft : .leftToRight)
        .focusEffectDisabled()
    }

    func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).padding(.top, 6)
    }

    func row<Control: View>(_ title: String, _ note: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let note = note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
    }

    func field(_ title: String, _ text: Binding<String>, path: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            if path {
                TextField("", text: text).textFieldStyle(.roundedBorder).environment(\.layoutDirection, .leftToRight)
            } else {
                TextField("", text: text).textFieldStyle(.roundedBorder)
            }
        }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("הגדרות", "Settings")).font(.system(size: 17, weight: .semibold))

            heading(L("כללי", "General"))
            row(L("שפה", "Language"), L("של הווידג'ט, הדוחות וההודעות", "For the widget, the reports and the notifications")) {
                Picker("", selection: Binding(get: { uiHebrew }, set: { m.actions?.setLanguage(hebrew: $0) })) {
                    Text("עברית").tag(true)
                    Text("English").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            row(L("הפעל בכניסה למחשב", "Start at login")) {
                Toggle("", isOn: Binding(get: { m.startAtLogin }, set: { m.actions?.toggleStartAtLogin($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            row(L("בשורת התפריט", "In the menu bar"), L("כבוי — ווידג'ט צף על המסך", "Off — a floating widget on the screen")) {
                Toggle("", isOn: Binding(get: { m.inMenuBar }, set: { m.actions?.setMenuBar($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }

            Divider().padding(.top, 4)
            heading(L("קציר", "Harvest"))
            if m.harvestInstalled {
                harvest
            } else {
                Text(L("הקציר לא מותקן.", "The harvest isn't installed.")).foregroundStyle(.secondary)
                Button(L("הגדר את הקציר…", "Set up the harvest…")) { m.actions?.showSetup() }
            }

            if m.harvestInstalled {
                Divider().padding(.top, 4)
                heading(L("פרויקטים", "Projects"))
                Text(L("כבוי = בלי הצעות מהפרויקט: ההצעות שלו יוסרו, וסוכנים לא יציעו בו חדשות. משימות שכבר בתור נשארות.",
                       "Off = no proposals from the project: its proposals are removed and agents won't propose new ones. Queued tasks stay."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if m.listing.projects.isEmpty {
                    Text(L("עוד אין פרויקטים רשומים.", "No projects registered yet.")).foregroundStyle(.secondary)
                }
                ForEach(m.listing.projects) { p in
                    row(p.name + ((p.exists ?? true) ? "" : L(" (לא נמצא)", " (not found)"))) {
                        Toggle(L("הצעות", "Proposals"), isOn: Binding(get: { !(p.proposalsOff ?? false) },
                                                                        set: { m.actions?.setProposals(project: p.path, name: p.name, on: $0) }))
                            .toggleStyle(.switch).controlSize(.mini)
                    }
                    .help(p.path)
                }

                Divider().padding(.top, 4)
                HStack(spacing: 8) {
                    Button(L("עזרה", "Help")) { m.actions?.showHelp() }
                    Spacer()
                    Button(L("הסר את הקציר…", "Remove the harvest…")) { m.actions?.showSetup() }
                        .help(L("פותח את חלון ההתקנה, ושם אפשר להסיר", "Opens the setup window, where it can be removed"))
                }
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
    }

    var harvest: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(L("קציר אוטומטי", "Automatic harvest"),
                L("יוצא לדרך \(m.config.leadHours) ש׳ לפני האיפוס השבועי", "Starts \(m.config.leadHours)h before the weekly reset")) {
                HStack(spacing: 6) {
                    Stepper("", value: Binding(get: { m.config.leadHours },
                                               set: { var c = m.config; c.leadHours = min(24, max(1, $0)); m.actions?.setConfig(c) }),
                            in: 1...24).labelsHidden()
                    Toggle("", isOn: Binding(get: { m.config.auto }, set: { var c = m.config; c.auto = $0; m.actions?.setConfig(c) }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
            }
            row(L("מודל לפי גודל משימה", "Model by task size"), L("קטנה · בינונית · גדולה", "small · medium · large")) {
                HStack(spacing: 4) {
                    ForEach(["low", "medium", "high"], id: \.self) { size in
                        Picker("", selection: Binding(get: { s.models[size] ?? "" }, set: { value in
                            s.models[size] = value
                            let json = (try? JSONSerialization.data(withJSONObject: s.models)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                            m.actions?.saveHarvestSettings(["models=" + json])
                        })) {
                            ForEach(Self.modelChoices + ((s.models[size]).map { Self.modelChoices.contains($0) ? [] : [$0] } ?? []), id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
            field(L("השם שלך", "Your name"), $s.name)
            field(L("תיקיית הקציר", "Harvest folder"), $s.workdir, path: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("סיכום שבועי במייל", "Weekly summary by email"))
                HStack(spacing: 8) {
                    TextField(L("כתובת מייל", "Email address"), text: $s.email).textFieldStyle(.roundedBorder)
                        .environment(\.layoutDirection, .leftToRight)
                    Toggle(L("שלח", "Send"), isOn: $s.digest).toggleStyle(.switch).controlSize(.mini)
                        .disabled(s.email.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack(spacing: 8) {
                Button(L("שמור", "Save")) {
                    let email = s.email.trimmingCharacters(in: .whitespaces)
                    m.actions?.saveHarvestSettings(["ownerName=" + s.name.trimmingCharacters(in: .whitespaces),
                                                    "workdir=" + s.workdir.trimmingCharacters(in: .whitespaces),
                                                    "email=" + email,
                                                    "emailDigest=" + (s.digest && !email.isEmpty ? "yes" : "no")])
                    s.saved = true
                }
                .buttonStyle(.borderedProminent)
                if s.saved { Text(L("נשמר ✓", "Saved ✓")).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Start at login

/// "Start at login" is a LaunchAgent; whether its plist exists is the checkbox's state.
let loginAgentLabel = "dev.quota-harvest.widget"
let loginAgentPlist = homeURL.appendingPathComponent("Library/LaunchAgents/\(loginAgentLabel).plist")

/// This binary's absolute path, as launchd needs it: argv[0] when it's already absolute,
/// otherwise resolved against the working directory.
func absoluteExecutablePath() -> String {
    let invoked = CommandLine.arguments[0]
    guard !invoked.hasPrefix("/") else { return invoked }
    let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return workingDirectory.appendingPathComponent(invoked).standardizedFileURL.path
}

/// On: writes the agent — this binary, run at load — but doesn't load it now (`launchctl load`
/// would start a second widget next to this one), so it takes effect at the next login.
/// Off: unloads it (best-effort) and deletes the plist.
func applyStartAtLogin(_ on: Bool) {
    let fm = FileManager.default
    if on {
        let agent: [String: Any] = [
            "Label": loginAgentLabel, "ProgramArguments": [absoluteExecutablePath()], "RunAtLoad": true,
        ]
        try? fm.createDirectory(at: loginAgentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist = try? PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
        try? plist?.write(to: loginAgentPlist)
        return
    }
    let launchctl = Process()
    launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    launchctl.arguments = ["unload", loginAgentPlist.path]
    if (try? launchctl.run()) != nil { launchctl.waitUntilExit() }
    try? fm.removeItem(at: loginAgentPlist)
}

// MARK: - App

/// Poll pacing, in seconds. `basePoll` is the normal wait and the floor under every other one —
/// the usage endpoint 429s when it's asked more often; failures double the wait up to `maxPoll`.
let basePoll: TimeInterval = 300
let maxPoll: TimeInterval = 1800

/// `UserDefaults` key of the menu bar mode switch (on unless the user turned it off).
let inMenuBarDefaultsKey = "InMenuBar"
/// The floating panel's saved frame lives under this autosave name.
let floatingFrameName = "QuotaHarvest"

/// When the next usage poll may go out — plain bookkeeping without timers, so all the pacing
/// rules sit in one place: one request out at a time, 30 s between attempts (manual ones too),
/// a 429's cool-off that nothing may cut short, and a doubling wait after failures.
struct PollPacing {
    /// Between two attempts, however they were started (this debounces ↻).
    static let minGap: TimeInterval = 30
    /// An attempt still unanswered after this long is presumed lost (a `security` prompt nobody
    /// answers, a request that never completes) and stops holding back new ones.
    static let lostAfter: TimeInterval = 120

    /// The wait after the latest attempt.
    private(set) var wait = basePoll
    /// No scheduled poll before this; a manual one may go earlier.
    private(set) var dueAt = Date.distantPast
    /// A 429's hard stop: nothing goes out before it, manual polls included.
    private(set) var coolOffUntil: Date?
    private(set) var startedAt: Date?
    private(set) var inFlight = false

    enum Step: Equatable { case send, retry(after: TimeInterval), drop }

    /// Whether a poll may go out now: `.send` (and it counts as started), `.retry` once the
    /// returned wait is over, or `.drop` — one is already out and will schedule the next itself.
    mutating func begin(manual: Bool, now: Date) -> Step {
        if inFlight {
            guard let started = startedAt, now.timeIntervalSince(started) > Self.lostAfter else { return .drop }
            inFlight = false
        }
        if let started = startedAt, now.timeIntervalSince(started) < Self.minGap { return .retry(after: Self.minGap) }
        if let until = coolOffUntil, until > now { return .retry(after: until.timeIntervalSince(now)) }
        if !manual, dueAt > now { return .retry(after: dueAt.timeIntervalSince(now)) }
        inFlight = true
        startedAt = now
        return .send
    }

    enum Outcome { case fetched, failed, throttled(retryAfter: TimeInterval?) }

    /// Books how an attempt ended and returns the wait until the next poll: `basePoll` after
    /// numbers came back; after a failure, twice the last wait, up to `maxPoll`; after a 429, the
    /// server's `Retry-After` (else that doubled wait) kept within basePoll…maxPoll — and held as a
    /// cool-off.
    mutating func finish(_ outcome: Outcome, now: Date) -> TimeInterval {
        inFlight = false
        let doubled = min(wait * 2, maxPoll)
        switch outcome {
        case .fetched:
            wait = basePoll
            coolOffUntil = nil
        case .failed:
            wait = doubled
        case .throttled(let retryAfter):
            wait = min(max(retryAfter ?? doubled, basePoll), maxPoll)
            coolOffUntil = now.addingTimeInterval(wait)
        }
        dueAt = now.addingTimeInterval(wait)
        return wait
    }

    /// After the Mac wakes: forget the failure backoff (a 429 cool-off still stands).
    mutating func forgetBackoff() {
        wait = basePoll
        dueAt = .distantPast
    }

    /// The watchdog's question: has nothing been attempted for far longer than the slowest normal
    /// schedule, with nothing out and no cool-off running? Releases a lost attempt on the way.
    mutating func stalled(now: Date) -> Bool {
        if inFlight, let started = startedAt, now.timeIntervalSince(started) > Self.lostAfter { inFlight = false }
        if inFlight { return false }
        if let until = coolOffUntil, until > now { return false }
        guard let started = startedAt else { return true }
        return now.timeIntervalSince(started) > maxPoll + 5 * 60
    }
}

/// A stretchable rounded-rectangle mask for the panel's material. A layer
/// corner radius leaves the blurred backdrop — and with it the window's
/// shadow — square behind the rounded corners.
func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

/// The panel's window: borderless and non-activating, yet able to become key, so its switches
/// draw in their active colors; Esc goes to `onEscape`.
final class WidgetPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { return true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Just the window, with none of the widget's setup (snapshots render into one).
    convenience init(bareFrame frame: NSRect) {
        self.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }

    /// The widget's panel: floating, on every Space and over full-screen apps, dragged by its
    /// background, and transparent around the backdrop that gives it its shape and shadow.
    convenience init(frame: NSRect) {
        self.init(bareFrame: frame)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }

    /// Makes the content view a popover-material backdrop with `radius` corners, cut by
    /// `maskImage` (see `roundedMask`), and returns it.
    func installBackdrop(size: NSSize, radius: CGFloat) -> NSVisualEffectView {
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        backdrop.material = .popover
        backdrop.state = .active
        backdrop.blendingMode = .behindWindow
        backdrop.wantsLayer = true
        backdrop.maskImage = roundedMask(radius: radius)
        backdrop.layer?.cornerRadius = radius
        backdrop.layer?.masksToBounds = true
        backdrop.autoresizingMask = [.width, .height]
        contentView = backdrop
        return backdrop
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WidgetActions, UNUserNotificationCenterDelegate {
    let model = WidgetModel()
    let runner = HarvestRunner()
    var panel: WidgetPanel!
    var hostingView: NSHostingView<PanelView>!
    var sizeObserver: AnyCancellable?

    // Usage polling — `refresh()`, paced by `PollPacing`.
    var pacing = PollPacing()
    var pollTimer: Timer?
    /// When a poll last brought numbers; the harvest acts on fresh ones only.
    private(set) var lastSuccess: Date?
    /// Those numbers.
    private(set) var lastUsage: Usage?
    /// Held for the app's lifetime (`holdOffAppNap`).
    var appNapActivity: NSObjectProtocol?

    // Menu bar mode, the default: the panel stays hidden until the status item is clicked, then
    // drops down under it.
    private(set) var statusItem: NSStatusItem?
    var outsideClickMonitor: Any?
    /// The harvester's reel turns while a harvest runs.
    var reelAngle: CGFloat = 0
    var reelTimer: Timer?

    // Harvest state.
    var tickCount = 0
    var flashWork: DispatchWorkItem?
    /// The newest launch whose end has been handled (or that had already ended when the widget
    /// started), so every run's end is handled exactly once — even a run too short for a refresh
    /// to catch it while it was running.
    var handledLaunchId: String?
    var listingLoaded = false
    /// `--pretend-weekly-reset-in <minutes>`: test hook that moves the weekly
    /// reset close, so the automatic harvest can be exercised on any day.
    var pretendWeeklyReset: Date?
    var snapshotWindow: NSWindow?
    var helpWindow: NSWindow?
    var setupWindow: NSWindow?
    let setupModel = SetupModel()
    var settingsWindow: NSWindow?
    let settingsModel = SettingsModel()
    /// Which conversation `talk` is starting: "waiting" (the review) or "onboard".
    var talkTopic = "waiting"
    /// `kill -USR1 <pid>` toggles the panel; `kill -USR2 <pid>` runs the whole
    /// queue now, or stops the running harvest — for scripts and keyboard launchers.
    var toggleSignal: DispatchSourceSignal?
    var runSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ launch: Notification) {
        migrateDefaults()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--pretend-weekly-reset-in"), i + 1 < args.count,
           let minutes = Double(args[i + 1]) {
            pretendWeeklyReset = Date().addingTimeInterval(minutes * 60)
        }
        UserDefaults.standard.register(defaults: [inMenuBarDefaultsKey: true])
        model.actions = self
        model.startAtLogin = FileManager.default.fileExists(atPath: loginAgentPlist.path)
        model.inMenuBar = UserDefaults.standard.bool(forKey: inMenuBarDefaultsKey)
        if args.contains("--check-notifications") {
            // Diagnostics: what macOS answers this bundle's notification request, then exit.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                print("granted:", granted, "error:", error.map { String(describing: $0) } ?? "none")
                UNUserNotificationCenter.current().getNotificationSettings { s in
                    print("status:", s.authorizationStatus.rawValue, "alertStyle:", s.alertStyle.rawValue)
                    exit(0)
                }
            }
            return
        }
        if let i = args.firstIndex(of: "--write-iconset"), i + 1 < args.count {
            writeIconset(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot-menubar"), i + 1 < args.count {
            snapshotMenuBar(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot-settings"), i + 1 < args.count {
            snapshotSettings(to: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--snapshot-setup"), i + 1 < args.count {
            snapshotSetup(to: args[i + 1], review: args.contains("--review"))
            return
        }
        if let i = args.firstIndex(of: "--snapshot-help"), i + 1 < args.count {
            snapshotHelp(to: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: args[i + 1], expandAll: args.contains("--expand"))
            return
        }

        setupNotifications()
        holdOffAppNap()
        makePanel()
        refresh()
        refreshUserLine()
        runEngine(["maintain"]) { [weak self] _ in self?.refreshListing() }
        // The 30 s tick refreshes relative times, the harvest listing and the
        // automatic harvest trigger, and doubles as the poll watchdog:
        // scheduling is a chain (each attempt schedules the next), so a single
        // broken link would otherwise stop polling until the app is restarted.
        let tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick.tolerance = 5
        pollAgainAfterWake()
        closeDropDownOnOutsideClick()
        signal(SIGUSR1, SIG_IGN)
        let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1.setEventHandler { [weak self] in
            guard let self else { return }
            if self.statusItem != nil {
                self.toggleDropDown()
            } else if self.panel.isVisible {
                self.panel.orderOut(nil)
            } else {
                self.panel.makeKeyAndOrderFront(nil)
            }
        }
        usr1.resume()
        toggleSignal = usr1
        signal(SIGUSR2, SIG_IGN)
        let usr2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        usr2.setEventHandler { [weak self] in
            guard let self else { return }
            if self.runner.isRunning { self.stopHarvest() } else { self.runAll() }
        }
        usr2.resume()
        runSignal = usr2
    }

    /// An accessory app without a visible window is a prime App Nap candidate, and a napping
    /// process can have its one-shot poll timer held back for many minutes.
    func holdOffAppNap() {
        appNapActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "usage polling")
    }

    /// Timers don't run while the Mac sleeps, and App Nap can hold a missed one back well after
    /// wake, leaving stale numbers up. So on wake the failure backoff is dropped and a poll is
    /// asked for ~5 s later, once the network is back — through `refresh()`, so the in-flight
    /// guard, the 30 s debounce and a 429 cool-off all still apply.
    func pollAgainAfterWake() {
        let workspaceEvents = NSWorkspace.shared.notificationCenter
        workspaceEvents.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pacing.forgetBackoff()
            self?.schedulePoll(in: 5)
        }
    }

    /// The dropped-down panel closes when you click anywhere else.
    func closeDropDownOnOutsideClick() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.statusItem != nil, self.panel.isVisible else { return }
            self.panel.orderOut(nil)
        }
    }

    /// The header's account line.
    func refreshUserLine() {
        fetchAccountLine { [weak self] line in self?.model.userLine = line ?? "" }
    }

    func tick() {
        model.now = Date()
        pollWatchdog()
        runner.checkExited()
        tickCount += 1
        let every = (panel.isVisible || model.harvestActive) ? 1 : 4
        if tickCount % every == 0 { refreshListing() }
        updateAutoPlan()
        autoHarvestTick()
        refreshNotificationPermission()
        nudgeTick()
    }

    /// The right-click menu — built only here, the same in both modes except that menu bar mode
    /// also offers the way back to the floating panel.
    func makeContextMenu(inMenuBar: Bool) -> NSMenu {
        var entries = [NSMenuItem(title: L("רענן עכשיו", "Refresh now"), action: #selector(refreshClicked), keyEquivalent: "r")]
        if inMenuBar {
            entries.append(NSMenuItem(title: L("חזרה לווידג'ט צף", "Back to the floating widget"),
                                      action: #selector(returnToFloating), keyEquivalent: ""))
        }
        entries.append(.separator())
        entries.append(NSMenuItem(title: L("צא מהווידג'ט", "Quit the widget"), action: #selector(quitWidget), keyEquivalent: "q"))
        let contextMenu = NSMenu()
        for entry in entries {
            entry.target = self
            contextMenu.addItem(entry)
        }
        return contextMenu
    }

    /// Builds the panel and its SwiftUI content. Floating, it opens where it was left (the main
    /// screen's top-right corner the first time); in menu bar mode it stays hidden until the
    /// status item is clicked.
    func makePanel() {
        let startSize = NSSize(width: 300, height: 220)
        panel = WidgetPanel(frame: NSRect(origin: .zero, size: startSize))
        panel.onEscape = { [weak self] in
            // Esc closes the drop-down only; the floating panel stays.
            guard let self, self.statusItem != nil else { return }
            self.panel.orderOut(nil)
        }
        let backdrop = panel.installBackdrop(size: startSize, radius: 12)

        hostingView = NSHostingView(rootView: PanelView(m: model))
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.frame = backdrop.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.menu = makeContextMenu(inMenuBar: false)
        backdrop.addSubview(hostingView)
        // Everything the panel shows lives in the model, so re-measuring after
        // each model change keeps the panel exactly as tall as its content.
        // (The content is top-aligned in a flexible frame, so NSHostingView's
        // own intrinsic-size invalidation doesn't fire for height changes.)
        sizeObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitPanelToContent() }
        }
        fitPanelToContent()

        // After the fit, and from the starting size, as it has always been placed.
        autosaveFloatingFrame(true)
        if panel.frame.origin == .zero, let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - startSize.width - 16, y: visible.maxY - startSize.height - 16))
        }
        if UserDefaults.standard.bool(forKey: inMenuBarDefaultsKey) {
            autosaveFloatingFrame(false)
            showStatusItem()
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// With autosave on, the panel returns to its saved floating frame and records every move.
    /// It is off in menu bar mode, so dropping down under the status item never overwrites it.
    func autosaveFloatingFrame(_ on: Bool) {
        panel.setFrameAutosaveName(on ? floatingFrameName : "")
    }

    /// Keeps the top edge fixed, so the panel grows and shrinks downward from
    /// the menu bar as sections open and close.
    func fitPanelToContent() {
        guard let panel = panel, let host = hostingView else { return }
        let size = host.fittingSize
        guard size.height > 20 else { return }
        let h = ceil(size.height), w: CGFloat = 300
        guard abs(panel.frame.height - h) > 0.5 || abs(panel.frame.width - w) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - h, width: w, height: h), display: true)
        // The shadow is traced from the window's shape once; trace it again.
        panel.invalidateShadow()
    }

    // MARK: Menu bar mode

    /// Switches between the status item and the floating panel, and remembers the choice.
    func setMenuBarMode(_ inMenuBar: Bool) {
        UserDefaults.standard.set(inMenuBar, forKey: inMenuBarDefaultsKey)
        model.inMenuBar = inMenuBar
        guard inMenuBar else {
            hideStatusItem()
            autosaveFloatingFrame(true)
            panel.orderFrontRegardless()
            return
        }
        autosaveFloatingFrame(false)
        panel.orderOut(nil)
        showStatusItem()
    }

    /// Puts the status item in the menu bar (once): an image-only button that answers both
    /// left and right clicks.
    func showStatusItem() {
        if statusItem != nil { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        redrawStatusItem()
    }

    /// Takes the status item away and stops the reel (showStatusItem starts it again if a
    /// harvest is still running).
    func hideStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        reelTimer?.invalidate()
        reelTimer = nil
    }

    /// Left click drops the panel down (or closes it); right click opens the menu.
    @objc func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
        if rightClick {
            makeContextMenu(inMenuBar: true)
                .popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
        } else {
            toggleDropDown()
        }
    }

    @objc func returnToFloating() { setMenuBarMode(false) }

    /// Opens the panel under the status item — centered on it, 6 pt below, kept 8 pt inside the
    /// screen's edges — or closes it when it's open.
    func toggleDropDown() {
        guard !panel.isVisible else { panel.orderOut(nil); return }
        if let itemWindow = statusItem?.button?.window {
            let anchor = itemWindow.frame
            let width = panel.frame.width
            var left = anchor.midX - width / 2
            if let screen = itemWindow.screen?.visibleFrame {
                left = min(max(left, screen.minX + 8), screen.maxX - width - 8)
            }
            panel.setFrameTopLeftPoint(NSPoint(x: left, y: anchor.minY - 6))
        }
        panel.makeKeyAndOrderFront(nil)
        refreshListing()
    }

    /// Status item: a combine harvester and one dashboard gauge per limit —
    /// Session, the all-models weekly and the model-scoped weekly (e.g. Fable) —
    /// tinted with the bars' warning colors; the numbers are in the tooltip.
    /// While a harvest runs, a timer turns the harvester's reel four times a second.
    func redrawStatusItem() {
        guard let button = statusItem?.button else { return }
        let gauges = statusGauges()
        let figures = gauges.map { "\($0.name) \(Int($0.pct.rounded()))%" }.joined(separator: " · ")
        button.toolTip = gauges.isEmpty ? "Claude usage — waiting for data"
            : "Claude usage — " + figures + (model.harvestActive ? L(" — קציר רץ", " — harvest running") : "")
        drawStatusImage(on: button)
        if model.harvestActive {
            guard reelTimer == nil else { return }
            let spin = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, let button = self.statusItem?.button else { return }
                self.reelAngle += .pi / 12
                self.drawStatusImage(on: button)
            }
            spin.tolerance = 0.05
            reelTimer = spin
        } else if let spin = reelTimer {
            spin.invalidate()
            reelTimer = nil
            reelAngle = 0
        }
    }

    /// The status image at the reel's current angle, described for VoiceOver by the tooltip.
    func drawStatusImage(on button: NSStatusBarButton) {
        button.image = menuBarImage(gauges: statusGauges().map { ($0.tag, $0.pct) }, reel: reelAngle)
        button.image?.accessibilityDescription = button.toolTip
    }

    /// The limits the status item shows, in order; missing ones are left out.
    func statusGauges() -> [(tag: String, name: String, pct: Double)] {
        let scoped = model.scopedLabel
        let metrics: [(String, String, Metric?)] = [
            ("S", "Session", model.session),
            ("W", "All models", model.weekly),
            (String(scoped.prefix(1)), scoped, model.scoped),
        ]
        return metrics.compactMap { tag, name, m in m.map { (tag, name, $0.pct) } }
    }

    @objc func refreshClicked() { refreshNow() }
    @objc func quitWidget() { NSApp.terminate(nil) }

    // MARK: Polling

    /// Arms the one pending poll: a one-shot timer, re-armed after every attempt — never a fixed beat.
    func schedulePoll(in delay: TimeInterval) {
        pollTimer?.invalidate()
        // Jitter only ever lengthens the wait (a cool-off is never cut short) and keeps two
        // instances, or quick restarts, from firing on the same second.
        let wait = max(delay, 1) * .random(in: 1.0...1.15)
        let next = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in self?.refresh() }
        // A tolerance can only delay the fire, which the jitter already allows for.
        next.tolerance = min(wait * 0.1, 30)
        pollTimer = next
    }

    /// Last-resort recovery for the poll chain, where every attempt arms the next, so one lost
    /// link (a dropped timer, a callback that never came) would stop polling for good. Generous
    /// on purpose: it acts only after far longer than the slowest normal wait, and `refresh()`
    /// still applies every guard.
    func pollWatchdog() {
        if pacing.stalled(now: Date()) { refresh() }
    }

    /// The dot's tooltip text, kept unevaluated so a language change can show it again in
    /// the new language (`languageChanged`).
    var statusTip: () -> String = { L("ממתין לנתונים…", "Waiting for data…") }

    /// The live dot — the one place a problem shows: its color, and a tooltip that says what's
    /// going on. Nothing else in the panel changes.
    func setStatus(_ color: NSColor, _ tip: @escaping @autoclosure () -> String) {
        model.dotColor = color
        statusTip = tip
        showStatusTip()
    }

    func showStatusTip() {
        let tip = statusTip()
        guard let last = lastSuccess else { model.dotTip = tip; return }
        model.dotTip = L("\(tip) · עודכן \(formatTime(last, "HH:mm"))", "\(tip) · updated \(formatTime(last, "HH:mm"))")
    }

    /// Polls usage when the pacing allows it now, otherwise arms the timer for when it will.
    /// `manual` (↻, Refresh now) skips the scheduled wait — never the 30 s debounce, never a
    /// 429 cool-off.
    func refresh(manual: Bool = false) {
        switch pacing.begin(manual: manual, now: Date()) {
        case .drop:
            return
        case .retry(let delay):
            schedulePoll(in: delay)
        case .send:
            fetchUsage { [weak self] result in self?.pollEnded(result) }
        }
    }

    /// A poll's answer. Numbers go to the model, the status item, usage.json and the dot; a
    /// failure changes only the dot — the panel keeps the last numbers that arrived.
    func pollEnded(_ result: PollResult) {
        let outcome: PollPacing.Outcome
        do {
            show(try result.get())
            outcome = .fetched
        } catch {
            outcome = report(error)
        }
        schedulePoll(in: pacing.finish(outcome, now: Date()))
    }

    func show(_ fetched: Usage) {
        var usage = fetched
        if let pretend = pretendWeeklyReset {
            usage.weekly?.resetsAt = pretend
            usage.scoped?.resetsAt = pretend
        }
        model.session = usage.session
        model.weekly = usage.weekly
        model.scoped = usage.scoped
        if let label = usage.scopedLabel { model.scopedLabel = label }
        lastUsage = usage
        writeUsageFile(usage)
        redrawStatusItem()
        lastSuccess = Date()
        setStatus(.systemGreen, L("מחובר", "Connected"))
        updateAutoPlan()
        // Launched with a lapsed token, the profile fetch came back empty; now that a poll got
        // through (after a renewal), fill in the account line.
        if model.userLine.trimmingCharacters(in: .whitespaces).isEmpty { refreshUserLine() }
    }

    /// Shows what went wrong — on the dot only: yellow while it retries by itself, red when the
    /// user has to act — and tells the pacing which kind of failure it was.
    func report(_ error: Error) -> PollPacing.Outcome {
        switch error {
        case PollFailure.signedOut:
            setStatus(.systemRed, L("לא מחובר — הרץ claude כדי להתחבר", "Not signed in — run claude to sign in"))
        case PollFailure.status(let code) where code == 401 || code == 403:
            setStatus(.systemRed, L("ההתחברות פגה — פתח את Claude Code", "Sign-in expired — open Claude Code"))
        case PollFailure.throttled(let retryAfter):
            setStatus(.systemYellow, L("מושהה — Claude ביקש להאט", "Paused — Claude asked to slow down"))
            return .throttled(retryAfter: retryAfter)
        default:
            setStatus(.systemYellow, L("אין חיבור ל-Claude — מנסה שוב", "Can't reach Claude — trying again"))
        }
        return .failed
    }

    // MARK: Harvest

    func refreshListing(then: (() -> Void)? = nil) {
        let installed = FileManager.default.fileExists(atPath: harvestEngine.path)
        if model.harvestInstalled != installed { model.harvestInstalled = installed }
        runEngine(["list"]) { [weak self] data in
            guard let self else { return }
            if let data = data, let listing = try? JSONDecoder().decode(HListing.self, from: data) {
                let wasHebrew = uiHebrew
                if listing != self.model.listing { self.model.listing = listing }
                if uiHebrew != wasHebrew { self.languageChanged() }
                // A launcher still alive from a previous widget instance is still ours to
                // watch and stop; any other live lock is a run started elsewhere (a desktop
                // chat) — shown, never stopped.
                let detached = !self.runner.isRunning && listing.launch?.endedAt == nil
                    && (listing.launch?.launcherPid).map { kill(pid_t($0), 0) == 0 } == true
                let external = (listing.lock?.live ?? false) && !self.runner.isRunning && !detached
                let launchId = listing.launch?.sessionId
                let ended = listing.launch?.endedAt != nil
                if !self.listingLoaded {
                    self.listingLoaded = true
                    if ended { self.handledLaunchId = launchId }
                }
                let unhandledEnd = ended && launchId != nil && launchId != self.handledLaunchId && !self.runner.isRunning
                if detached != self.model.detachedRun || external != self.model.externalRun {
                    self.model.detachedRun = detached
                    self.model.externalRun = external
                    self.redrawStatusItem()
                }
                if unhandledEnd { self.runEnded() }
                self.updateAutoPlan()
            }
            then?()
        }
    }

    /// The listing brought another UI language — at launch whenever the harvest settings'
    /// language isn't the Mac's first one, or after the setup changed it. The panel follows by
    /// itself; this redoes what was made in the old language.
    func languageChanged() {
        hostingView?.menu = makeContextMenu(inMenuBar: false)
        showStatusTip()
        redrawStatusItem()
        registerNotificationCategories()
        if let window = helpWindow {
            window.title = L("עזרה — קציר מכסה", "Help — Quota harvest")
            (window.contentView as? NSHostingView<HelpView>)?.rootView = HelpView()
        }
    }

    /// ↻ turns until the numbers and the listing are back: at least one turn, so a
    /// quick answer (or a click inside the 30 s debounce) still shows it registered;
    /// at most 15 s.
    func refreshNow() {
        model.refreshing = true
        let started = Date()
        refresh(manual: true)
        refreshListing { [weak self] in self?.endRefreshSpin(started: started) }
    }

    func endRefreshSpin(started: Date) {
        let elapsed = -started.timeIntervalSinceNow
        if pacing.inFlight && elapsed < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.endRefreshSpin(started: started)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 0.8 - elapsed)) { [weak self] in
            self?.model.refreshing = false
        }
    }

    func runAll() { launchHarvest(mode: "manual", only: []) }
    func runOne(_ task: HTask) { launchHarvest(mode: "manual", only: [task]) }

    func launchHarvest(mode: String, only: [HTask]) {
        guard !runner.isRunning, !model.harvestActive else { flash(L("קציר כבר רץ", "A harvest is already running")); return }
        guard claudeExecutable() != nil else { flash(L("לא נמצא claude במחשב", "claude isn't installed on this Mac")); return }
        model.running = true
        redrawStatusItem()
        runEngine(["maintain"]) { [weak self] _ in
            guard let self else { return }
            let ok = self.runner.launch(mode: mode, only: only, test: self.pretendWeeklyReset != nil) {
                [weak self] status in self?.harvestEnded(status)
            }
            guard ok else {
                self.model.running = false
                self.redrawStatusItem()
                self.flash(L("ההפעלה נכשלה", "Couldn't start the harvest"))
                return
            }
            self.flash(nil)
            self.refreshListing()
        }
    }

    func harvestEnded(_ status: Int32) {
        model.running = false
        runEnded()
    }

    /// End of a run — one this widget spawned, or one a previous widget instance
    /// spawned and it only watched (detached).
    /// Straight from launch.json: the listing may not have caught up yet when a run ends.
    func newestLaunchId() -> String? {
        guard let data = try? Data(contentsOf: harvestHome.appendingPathComponent("launch.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["sessionId"] as? String
    }

    func runEnded() {
        handledLaunchId = newestLaunchId() ?? model.listing.launch?.sessionId
        // The 5-hour window that stopped this run; a follow-up may start once it resets.
        UserDefaults.standard.set(
            lastUsage?.session?.resetsAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
            forKey: "HarvestLastSessionReset")
        runEngine(["maintain"]) { [weak self] _ in
            self?.refreshListing { [weak self] in
                guard let self else { return }
                self.redrawStatusItem()
                let run = self.model.listing.status?.lastRun
                var body = L("\(run?.done ?? 0) משימות הסתיימו", run?.done == 1 ? "1 task done" : "\(run?.done ?? 0) tasks done")
                if let why = stopReasonText(run?.stopReason) { body += " · " + why }
                let waiting = self.model.listing.needsYou.count
                if waiting > 0 { body += L(" · \(waiting) מחכות לך", " · \(waiting) waiting for you") }
                // The weekly digest is the owner's sign the system is alive; say so if it didn't go out.
                let digestMissing = run?.mode == "auto" && run?.final == true && run?.emailed == false
                    && self.pretendWeeklyReset == nil
                if digestMissing {
                    body += L(" · מייל הסיכום לא נשלח — פרטים בדוח", " · the summary email wasn't sent — details in the report")
                }
                if !self.panel.isVisible || digestMissing { notify(title: L("קציר מכסה", "Quota harvest"), body: body) }
                self.flash(body)
                // A run the owner started by hand ends where they can read it: the Claude app.
                if self.model.listing.launch?.mode == "manual", self.model.lastRunInApp,
                   let sid = self.model.listing.launch?.sessionId {
                    openSessionInApp(sid)
                }
            }
        }
    }

    func stopHarvest() {
        let claudePid = model.listing.launch?.claudePid
        // The task session is a terminal session of its own: stop it directly too.
        if let taskPid = model.listing.status?.current?.claudePid, taskPid > 1 {
            killpg(pid_t(taskPid), SIGTERM)
        }
        if runner.isRunning {
            runner.stop(claudePid: claudePid)
        } else if model.detachedRun, let launcher = model.listing.launch?.launcherPid {
            kill(pid_t(launcher), SIGTERM)
        }
        flash(L("עוצר…", "Stopping…"))
    }

    /// Live: the Remote Control session in the Claude app (the owner can type into
    /// it too). Finished: the imported conversation. Otherwise: Terminal.
    func watchRun() {
        let launch = model.listing.launch
        if let task = model.listing.status?.current?.bridgeSessionId, launch?.endedAt == nil {
            openInClaudeApp(task)
        } else if let bridge = launch?.bridgeSessionId, launch?.endedAt == nil {
            openInClaudeApp(bridge)
        } else if model.lastRunInApp, let sid = launch?.sessionId {
            openSessionInApp(sid)
        } else {
            watchInTerminal()
            flash(L("הריצה מתחברת לאפליקציה — בינתיים בטרמינל", "The run is still connecting to the app — Terminal meanwhile"))
        }
        if statusItem != nil { panel.orderOut(nil) }
    }

    func watchTerminal() {
        watchInTerminal()
        if statusItem != nil { panel.orderOut(nil) }
    }

    func openDone(_ task: HTask) {
        if let sid = task.sessionId {
            openSessionInApp(sid)
        } else if task.branchState == "unmerged" {
            openNeed(task)
            return
        } else {
            flash(task.summary ?? task.title)
            return
        }
        if statusItem != nil { panel.orderOut(nil) }
    }

    func openLastRun() {
        guard let sid = model.listing.launch?.sessionId else { return }
        openSessionInApp(sid)
        if statusItem != nil { panel.orderOut(nil) }
    }

    /// A weekly cycle's id: its reset time rounded to the hour, because the API's
    /// reset time jitters across the hour mark.
    func harvestCycle(_ reset: Date) -> Int { Int((reset.timeIntervalSince1970 / 3600).rounded()) }

    /// When the automatic harvest starts next, and whether that is now — the one
    /// place for the rules, used by the trigger and by the footer's countdown:
    /// once per weekly cycle when the window opens (lead hours before the reset,
    /// until 20 min before it), again after each 5-hour reset while the last run
    /// stopped on a full window and the queue still has work (4 runs at most),
    /// otherwise next week's window.
    func autoHarvestPlan() -> (next: Date, due: Bool, followUp: Bool)? {
        guard model.config.auto, let raw = model.weekly?.resetsAt else { return nil }
        let reset = Date(timeIntervalSince1970: (raw.timeIntervalSince1970 / 60).rounded() * 60)
        let now = Date()
        let start = reset.addingTimeInterval(-Double(model.config.leadHours) * 3600)
        let cutoff = reset.addingTimeInterval(-20 * 60)
        let nextWeek = start.addingTimeInterval(7 * 24 * 3600)
        if now < start { return (start, false, false) }
        if now >= cutoff { return (nextWeek, false, false) }
        let d = UserDefaults.standard
        if d.integer(forKey: "HarvestCycle") != harvestCycle(raw) { return (now, true, false) }
        if d.integer(forKey: "HarvestCycleRuns") < 4,
           model.listing.status?.lastRun?.stopReason == "5h-full",
           !model.listing.queue.isEmpty {
            let after = Date(timeIntervalSince1970: d.double(forKey: "HarvestLastSessionReset") + 60)
            if after < cutoff { return (max(after, now), after <= now, true) }
        }
        return (nextWeek, false, false)
    }

    /// Launches the automatic harvest when its plan says it's due — on fresh numbers only.
    func autoHarvestTick() {
        guard model.harvestInstalled, !runner.isRunning, !model.harvestActive, let raw = model.weekly?.resetsAt,
              let fresh = lastSuccess, -fresh.timeIntervalSinceNow < 15 * 60,
              let plan = autoHarvestPlan(), plan.due else { return }
        let d = UserDefaults.standard
        if plan.followUp {
            d.set(d.integer(forKey: "HarvestCycleRuns") + 1, forKey: "HarvestCycleRuns")
        } else {
            d.set(harvestCycle(raw), forKey: "HarvestCycle")
            d.set(1, forKey: "HarvestCycleRuns")
        }
        launchHarvest(mode: "auto", only: [])
    }

    /// The footer's line about the next automatic harvest: a countdown, or a note.
    func updateAutoPlan() {
        var next: Date?, note: String?
        if !model.config.auto {
            note = L("אוטומטי כבוי", "automatic is off")
        } else if let plan = autoHarvestPlan() {
            let fresh = lastSuccess.map { -$0.timeIntervalSinceNow < 15 * 60 } ?? false
            if plan.due {
                note = fresh ? L("מתחיל עכשיו", "starting now") : L("ממתין לנתוני מכסה", "waiting for quota data")
            } else {
                next = plan.next
            }
        }
        if model.autoNext != next { model.autoNext = next }
        if model.autoNote != note { model.autoNote = note }
    }

    func setQueued(_ task: HTask, _ queued: Bool) {
        var l = model.listing
        if queued, let i = l.proposals.firstIndex(of: task) {
            l.proposals.remove(at: i)
            l.queue.append(task)
        } else if !queued, let i = l.queue.firstIndex(of: task) {
            l.queue.remove(at: i)
            l.proposals.insert(task, at: 0)
        }
        model.listing = l
        runEngine(["set-status", task.project, task.title, queued ? "open" : "proposed"]) { [weak self] _ in
            self?.refreshListing()
        }
    }

    func openNeed(_ task: HTask) {
        let prompt: String
        if task.status == "blocked" {
            prompt = L("משימת הבקלוג \"\(task.title)\" חסומה ומחכה להחלטה שלי: \(task.question ?? ""). "
                + "עזור לי להחליט, ואז עדכן אותה: claude-harvest set-status \"\(task.project)\" \"\(task.title)\" "
                + "open --answer \"<ההחלטה שלי>\" (חוזרת לתור עם התשובה), או dropped.",
                "The backlog task \"\(task.title)\" is blocked and waiting for my decision: \(task.question ?? ""). "
                + "Help me decide, then update it: claude-harvest set-status \"\(task.project)\" \"\(task.title)\" "
                + "open --answer \"<my decision>\" (it goes back to the queue with the answer), or dropped.")
        } else {
            prompt = L("סקור את הענף \(task.branch ?? "") — משימת בקלוג שהקציר השלים: \"\(task.title)\". "
                + "הראה לי בקצרה מה השתנה ולמה. אם אני מאשר: claude-harvest merge \"\(task.project)\" \"\(task.title)\" "
                + "— הוא ממזג לענף הראשי ומוחק את הענף, ומסרב כשהפרויקט תפוס או כשיש התנגשות; אז תגיד לי מה מפריע. בלי push.",
                "Review the branch \(task.branch ?? "") — a backlog task the harvest finished: \"\(task.title)\". "
                + "Show me briefly what changed and why. If I approve: claude-harvest merge \"\(task.project)\" \"\(task.title)\" "
                + "— it merges into the main branch and deletes the branch, and refuses when the project is busy or there's "
                + "a conflict; then tell me what's in the way. No push.")
        }
        openInClaude(folder: task.project, prompt: prompt)
        if statusItem != nil { panel.orderOut(nil) }
    }

    func setConfig(_ config: HarvestConfig) {
        guard config != model.config else { return }
        model.config = config
        saveHarvestConfig(config)
        updateAutoPlan()
    }

    func toggleStartAtLogin(_ on: Bool) {
        applyStartAtLogin(on)
        model.startAtLogin = on
    }

    func setMenuBar(_ on: Bool) { setMenuBarMode(on) }

    func openHarvestFolder() { NSWorkspace.shared.open(harvestHome) }

    /// The setup window — the panel's button while the harvest isn't installed, or ⋯ →
    /// "הגדרת הקציר". One window, reused; it sizes itself to its content.
    func showSetup() {
        if statusItem != nil { panel.orderOut(nil) }
        setupModel.onChanged = { [weak self] in self?.refreshListing() }
        setupModel.onUninstall = { [weak self] in self?.confirmUninstall() }
        setupModel.onOnboard = { [weak self] in self?.startOnboarding() }
        if setupWindow == nil {
            let host = NSHostingController(rootView: SetupView(s: setupModel))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            setupWindow = window
        }
        setupWindow?.title = L("הגדרת הקציר", "Harvest setup")
        setupModel.load()
        setupWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    /// ⋯ → "הגדרות…": one window, reused, filled from the latest listing.
    func showSettings() {
        if statusItem != nil { panel.orderOut(nil) }
        settingsModel.load(model.listing.settings)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(m: model, s: settingsModel))
            window.contentMinSize = NSSize(width: 460, height: 300)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.title = L("הגדרות — קציר מכסה", "Settings — Quota harvest")
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        refreshListing()
    }

    func saveHarvestSettings(_ values: [String]) {
        runEngine(["settings"] + values.flatMap { ["--set", $0] }) { [weak self] _ in self?.refreshListing() }
    }

    /// The language of the widget, the reports and the notifications. With the harvest installed it
    /// lives in the harvest settings (the listing brings it back); without, in the widget's defaults.
    func setLanguage(hebrew: Bool) {
        UserDefaults.standard.set(hebrew ? "he" : "en", forKey: "UILanguage")
        uiHebrew = hebrew
        languageChanged()
        model.objectWillChange.send()
        settingsWindow?.title = L("הגדרות — קציר מכסה", "Settings — Quota harvest")
        if model.harvestInstalled { saveHarvestSettings(["language=" + (hebrew ? "he" : "en")]) }
    }

    /// A dragged queued task lands above `target` (or last): the whole new order goes to the engine,
    /// which then runs the queue in it. Shown at once; the next listing confirms it.
    func moveQueued(_ id: String, before target: String?) {
        model.queueDropTarget = nil
        var queue = model.listing.queue
        guard let from = queue.firstIndex(where: { $0.id == id }) else { return }
        let task = queue.remove(at: from)
        let to = target.flatMap { t in queue.firstIndex(where: { $0.id == t }) } ?? queue.count
        queue.insert(task, at: to)
        guard queue.map(\.id) != model.listing.queue.map(\.id) else { return }
        var l = model.listing
        l.queue = queue
        model.listing = l
        runEngine(["queue-order"] + queue.map(\.id)) { [weak self] _ in self?.refreshListing() }
    }

    func resetQueueOrder() {
        runEngine(["queue-order", "--reset"]) { [weak self] _ in self?.refreshListing() }
    }

    /// A proposal's trash can: dropped at once (the engine keeps a note, so it isn't proposed again).
    func removeProposal(_ task: HTask) {
        var l = model.listing
        l.proposals.removeAll { $0 == task }
        model.listing = l
        flash(L("ההצעה הוסרה", "Proposal removed"))
        runEngine(["set-status", task.project, task.title, "dropped"]) { [weak self] _ in self?.refreshListing() }
    }

    /// Proposals for a project off (after a confirmation that says what goes) or back on.
    func setProposals(project: String, name: String, on: Bool) {
        if !on {
            let count = model.listing.proposals.filter { $0.project == project }.count
            let alert = NSAlert()
            alert.messageText = L("בלי הצעות מ\"\(name)\"?", "No proposals from \"\(name)\"?")
            alert.informativeText = count > 0
                ? L("\(count) ההצעות שלו יוסרו, וסוכנים לא יציעו בו חדשות. משימות שכבר בתור נשארות. אפשר להחזיר בהגדרות.",
                    "Its \(count) proposals are removed and agents won't propose new ones. Queued tasks stay. You can turn it back on in Settings.")
                : L("סוכנים לא יציעו בו משימות חדשות. אפשר להחזיר בהגדרות.",
                    "Agents won't propose new tasks there. You can turn it back on in Settings.")
            alert.addButton(withTitle: L("בלי הצעות", "No proposals"))
            alert.addButton(withTitle: L("ביטול", "Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { model.objectWillChange.send(); return }
            var l = model.listing
            l.proposals.removeAll { $0.project == project }
            model.listing = l
        }
        runEngine(["proposals", project, on ? "on" : "off"]) { [weak self] _ in self?.refreshListing() }
    }

    func confirmUninstall() {
        let hebrew = setupModel.hebrew
        let alert = NSAlert()
        alert.messageText = hebrew ? "להסיר את הקציר?" : "Remove the harvest?"
        alert.informativeText = hebrew
            ? "המנוע, הסקילים וההנחיה לסוכנים יוסרו. התור, ההיסטוריה, ההגדרות והענפים בפרויקטים נשארים."
            : "The engine, the skills and the agent instructions are removed. Your queue, history, settings and project branches stay."
        alert.addButton(withTitle: hebrew ? "הסר" : "Remove")
        alert.addButton(withTitle: hebrew ? "ביטול" : "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runInstaller(["uninstall"]) { [weak self] _, code in
            guard let self else { return }
            if code == 0 {
                self.setupWindow?.close()
            } else {
                self.setupModel.error = hebrew ? "ההסרה נכשלה." : "Removing it failed."
            }
            self.refreshListing()
        }
    }

    /// ⋯ → "עזרה": one ordinary window, reused, brought to the front.
    func showHelp() {
        if statusItem != nil { panel.orderOut(nil) }
        if helpWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = L("עזרה — קציר מכסה", "Help — Quota harvest")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HelpView())
            window.contentMinSize = NSSize(width: 460, height: 300)
            window.center()
            helpWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        helpWindow?.makeKeyAndOrderFront(nil)
    }

    func flash(_ text: String?) {
        flashWork?.cancel()
        model.flash = text
        guard text != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.model.flash = nil }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    // MARK: Reminder and conversation

    /// The widget ran as a bare binary before it became an app bundle, so its
    /// settings (menu bar mode, the harvest cycle, the panel's frame…) live in the
    /// old domain; they're copied into the bundle's once.
    /// Once, in the app bundle: settings saved under the names this app had before it was
    /// Quota Harvest (its earlier bundle id, and the bare binary's domain) move over — the
    /// switches, the language, the reminder's timing, and the floating panel's position.
    func migrateDefaults() {
        guard let id = Bundle.main.bundleIdentifier, id != "QuotaHarvest" else { return }
        let d = UserDefaults.standard
        guard !d.bool(forKey: "MigratedToQuotaHarvest") else { return }
        for old in ["com.empathy.claude-usage-widget", "ClaudeUsageWidget"] {
            for (key, value) in d.persistentDomain(forName: old) ?? [:] {
                let target = key == "NSWindow Frame ClaudeUsageWidget" ? "NSWindow Frame \(floatingFrameName)" : key
                if d.object(forKey: target) == nil { d.set(value, forKey: target) }
            }
        }
        d.set(true, forKey: "MigratedToQuotaHarvest")
    }

    func setupNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerNotificationCategories()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("notifications: granted=%d error=%@", granted ? 1 : 0, String(describing: error))
            DispatchQueue.main.async { clickableNotifications = granted }
        }
    }

    /// The reminder's buttons, in the UI language — registered again when it changes.
    func registerNotificationCategories() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(
            identifier: "waiting",
            actions: [UNNotificationAction(identifier: "talk", title: L("כן, בוא נדבר", "Yes, let's talk")),
                      UNNotificationAction(identifier: "later", title: L("מחר", "Tomorrow"))],
            intentIdentifiers: [])])
    }

    /// The permission as it stands now — the owner may allow it (or take it back)
    /// in System Settings at any time, and the first answer can come late.
    func refreshNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = [.authorized, .provisional].contains(settings.authorizationStatus)
            DispatchQueue.main.async {
                if allowed != clickableNotifications {
                    NSLog("notifications: permission now %d", allowed ? 1 : 0)
                    clickableNotifications = allowed
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    /// The reminder: a click on it (or "כן, בוא נדבר") opens the conversation, "מחר" snoozes it a day.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            if category == "waiting" {
                if action == "later" {
                    UserDefaults.standard.set(Date().addingTimeInterval(24 * 3600).timeIntervalSince1970,
                                              forKey: "NudgeSnoozeUntil")
                } else if action != UNNotificationDismissActionIdentifier {
                    self?.startTalk()
                }
            }
            completionHandler()
        }
    }

    /// When work the harvest did has waited 2+ days for the owner (unmerged
    /// branches, blocked questions), a notification offers to talk it over —
    /// every other day, daily once something has waited a week; between 10:00 and
    /// 21:00; not while a harvest runs or the conversation is open.
    func nudgeTick() {
        guard clickableNotifications, listingLoaded, !model.harvestActive, !talkInfo().alive else { return }
        let waiting = model.listing.needsYou
        let oldest = waiting.compactMap { $0.ageDays }.max() ?? 0
        guard oldest >= 2, (10..<21).contains(Calendar.current.component(.hour, from: Date())) else { return }
        let d = UserDefaults.standard, now = Date().timeIntervalSince1970
        let every: TimeInterval = oldest >= 7 ? 20 * 3600 : 44 * 3600
        guard now >= d.double(forKey: "NudgeSnoozeUntil"), now - d.double(forKey: "NudgeLast") >= every else { return }
        d.set(now, forKey: "NudgeLast")
        let branches = waiting.filter { $0.status == "done" }.count
        let questions = waiting.count - branches
        var what = branches == 0 ? "" : branches == 1 ? L("ענף אחד", "one branch") : L("\(branches) ענפים", "\(branches) branches")
        if questions > 0 {
            let q = questions == 1 ? L("שאלה אחת", "one question") : L("\(questions) שאלות", "\(questions) questions")
            what = what.isEmpty ? q : what + L(questions == 1 ? " ו" : " ו־", " and ") + q
        }
        let age = oldest >= 7 ? L("כבר יותר משבוע", "over a week") : L("\(oldest) ימים", "\(oldest) days")
        notify(title: L("קציר מכסה", "Quota harvest"),
               body: L("יש עבודה שעשיתי ועוד לא אישרת: \(what). הוותיק מחכה \(age). נדבר על זה?",
                       "There's work I did that you haven't approved yet: \(what). The oldest has waited \(age). Shall we talk it over?"),
               category: "waiting", id: "waiting")
    }

    var talkPid: pid_t = 0
    var talkReaper: DispatchSourceProcess?

    /// talk.json, written by the engine: the conversation's Remote Control id, and
    /// whether its launcher still runs.
    func talkInfo() -> (bridge: String?, alive: Bool) {
        guard let data = try? Data(contentsOf: harvestHome.appendingPathComponent("talk.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, false) }
        let pid = (obj["launcherPid"] as? NSNumber)?.int32Value ?? 0
        let alive = obj["endedAt"] as? String == nil && pid > 0 && kill(pid, 0) == 0
        return (obj["bridgeSessionId"] as? String, alive)
    }

    func talk() { startTalk() }

    /// After an install: the getting-started conversation (`claude-harvest talk --topic onboard`),
    /// opened in the Claude app the same way as the review conversation.
    func startOnboarding() { startTalk(topic: "onboard") }

    /// The owner's conversation about what the harvest left waiting: the open one,
    /// or a new one (`claude-harvest talk`), shown in the Claude app once it's live there.
    func startTalk(topic: String = "waiting") {
        let t = talkInfo()
        if t.alive, let bridge = t.bridge {
            openInClaudeApp(bridge)
            if statusItem != nil { panel.orderOut(nil) }
            return
        }
        if !t.alive {
            let log = harvestHome.appendingPathComponent(
                "logs/talk-\(formatTime(Date(), "yyyyMMdd-HHmmss")).out").path
            talkTopic = topic
            guard let pid = spawnEngine(["talk", "--topic", topic], log: log, unattended: false) else {
                flash(L("פתיחת השיחה נכשלה", "Couldn't open the conversation"))
                return
            }
            talkPid = pid
            let reaper = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            reaper.setEventHandler { [weak self] in
                var status: Int32 = 0
                waitpid(pid, &status, WNOHANG)
                self?.talkReaper?.cancel()
                self?.talkReaper = nil
                self?.talkPid = 0
            }
            talkReaper = reaper
            reaper.resume()
        }
        flash(L("פותח שיחה באפליקציית Claude…", "Opening a conversation in the Claude app…"))
        waitForTalk(until: Date().addingTimeInterval(45))
    }

    /// Opens the conversation as soon as Remote Control has it in the app. If it
    /// never gets there, the hidden one stops and the same conversation opens as a
    /// new desktop session with its request typed in — safe, since nothing happens
    /// in it before the owner approves.
    func waitForTalk(until deadline: Date) {
        let t = talkInfo()
        if t.alive, let bridge = t.bridge {
            flash(nil)
            openInClaudeApp(bridge)
            if statusItem != nil { panel.orderOut(nil) }
            return
        }
        if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.waitForTalk(until: deadline) }
            return
        }
        if talkPid > 0 { kill(-talkPid, SIGTERM) }
        flash(nil)
        if talkTopic == "onboard" {
            openInClaude(folder: harvestWorkdir.path, prompt: L("קרא את ~/.claude/skills/harvest-quota/references/onboard-prompt.md "
                + "ופעל לפי ההנחיות שבו (את השם והשפה תמצא ב-claude-harvest settings): התקנתי עכשיו את הקציר.",
                "Read ~/.claude/skills/harvest-quota/references/onboard-prompt.md "
                + "and follow it (my name and language are in claude-harvest settings): I've just installed the harvest."))
        } else {
            openInClaude(folder: harvestWorkdir.path, prompt: L("קרא את ~/.claude/skills/harvest-quota/references/talk-prompt.md "
                + "ופעל לפי ההנחיות שבו: ביקשתי לשוחח על העבודה שהקציר השאיר לאישורי.",
                "Read ~/.claude/skills/harvest-quota/references/talk-prompt.md "
                + "and follow its instructions: I asked to talk over the work the harvest left for my approval."))
        }
        if statusItem != nil { panel.orderOut(nil) }
    }

    // MARK: Snapshot

    /// `--write-iconset <dir>`: the app icon — the menu bar's harvester, white on a
    /// wheat-gold tile — in the PNG sizes `iconutil` turns into AppIcon.icns.
    func writeIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = points * scale
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                rep.size = NSSize(width: 1024, height: 1024)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                                        xRadius: 185, yRadius: 185)
                NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.80, blue: 0.38, alpha: 1),
                           ending: NSColor(srgbRed: 0.87, green: 0.50, blue: 0.16, alpha: 1))?.draw(in: tile, angle: -90)
                if let ctx = NSGraphicsContext.current?.cgContext {
                    let k: CGFloat = 30
                    ctx.saveGState()
                    ctx.translateBy(x: 512 - 21 * k / 2, y: 512 - 16 * k / 2)
                    ctx.scaleBy(x: k, y: k)
                    drawHarvester(at: .zero, color: .white, reel: 0.3)
                    ctx.restoreGState()
                }
                NSGraphicsContext.restoreGraphicsState()
                let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }

    /// The last numbers the running widget saved (usage.json), for snapshots.
    func loadSavedUsage() {
        guard let data = try? Data(contentsOf: harvestHome.appendingPathComponent("usage.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func metric(_ key: String) -> Metric? {
            guard let d = obj[key] as? [String: Any], let p = jsonNumber(d["pct"]) else { return nil }
            return Metric(pct: p, resetsAt: parseDate(d["resetsAt"]))
        }
        model.session = metric("session")
        model.weekly = metric("weekly")
        if let pretend = pretendWeeklyReset { model.weekly?.resetsAt = pretend }
        model.scoped = metric("scoped")
        if let s = obj["scoped"] as? [String: Any], let label = s["label"] as? String {
            model.scopedLabel = label
        }
    }

    /// `--he` / `--en` on a snapshot: render in that language, whatever the harvest settings say.
    func forceSnapshotLanguage() {
        let args = CommandLine.arguments
        if args.contains("--he") {
            uiHebrew = true
            uiLanguageForced = true
        } else if args.contains("--en") {
            uiHebrew = false
            uiLanguageForced = true
        }
    }

    /// `--snapshot-menubar <png> [--he|--en]`: renders the status item from usage.json on a
    /// light and a dark menu bar at 2x — plus a sample with warning colors —
    /// and exits.
    func snapshotMenuBar(to path: String) {
        forceSnapshotLanguage()
        loadSavedUsage()
        let rows: [[(tag: String, pct: Double)]] = [
            statusGauges().map { ($0.tag, $0.pct) },
            [("S", 76), ("W", 93), ("F", 0)],
        ]
        let size = NSSize(width: 2 * 110, height: CGFloat(rows.count) * 26)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { exit(1) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (col, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                NSColor(white: col == 0 ? 0.93 : 0.17, alpha: 1).setFill()
                NSRect(x: CGFloat(col) * 110, y: 0, width: 110, height: size.height).fill()
                for (i, gauges) in rows.enumerated() {
                    menuBarImage(gauges: gauges, reel: 0.3).draw(
                        at: NSPoint(x: CGFloat(col) * 110 + 8, y: size.height - CGFloat(i + 1) * 26 + 4),
                        from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// `--snapshot-setup <png> [--review] [--light] [--he|--en]`: renders the setup window — the
    /// form, or with --review what the installer's `plan` says for this Mac — and exits.
    func snapshotSetup(to path: String, review: Bool) {
        forceSnapshotLanguage()
        setupModel.hebrew = uiHebrew
        let render = {
            let host = NSHostingView(rootView: SetupView(s: self.setupModel)
                .background(Color(nsColor: .windowBackgroundColor)))
            self.renderSnapshot(host, width: 480, to: path)
        }
        if CommandLine.arguments.contains("--done") { setupModel.step = .done; setupModel.installed = true }
        guard review else { render(); return }
        runInstaller(["plan"] + setupModel.args) { data, _ in
            self.setupModel.plan = data.flatMap { try? JSONDecoder().decode(InstallPlan.self, from: $0) }
            self.setupModel.step = .review
            render()
        }
    }

    /// `--snapshot-settings <png> [--light] [--he|--en]`: the settings window, unscrolled, from the
    /// current listing — and exits.
    func snapshotSettings(to path: String) {
        let args = CommandLine.arguments
        if args.contains("--he") { uiHebrew = true; uiLanguageForced = true } else if args.contains("--en") { uiHebrew = false; uiLanguageForced = true }
        model.harvestInstalled = FileManager.default.fileExists(atPath: harvestEngine.path)
        model.startAtLogin = FileManager.default.fileExists(atPath: loginAgentPlist.path)
        model.inMenuBar = UserDefaults.standard.bool(forKey: inMenuBarDefaultsKey)
        runEngine(["list"]) { data in
            if let data = data, let listing = try? JSONDecoder().decode(HListing.self, from: data) { self.model.listing = listing }
            self.settingsModel.load(self.model.listing.settings)
            self.renderSnapshot(NSHostingView(rootView: SettingsView(m: self.model, s: self.settingsModel, scrolls: false)
                .background(Color(nsColor: .windowBackgroundColor))), width: 460, to: path)
        }
    }

    /// Lays `host` out offscreen at `width`, as tall as it wants, writes it as a PNG and exits.
    func renderSnapshot(_ host: NSView, width: CGFloat, to path: String) {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 2400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(
            named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        snapshotWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            window.setContentSize(NSSize(width: width, height: ceil(max(host.fittingSize.height, 100))))
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
    }

    /// `--snapshot-help <png> [--light] [--he|--en]`: renders the whole help screen, unscrolled,
    /// into a PNG and exits — for checking its text after a change.
    func snapshotHelp(to path: String) {
        forceSnapshotLanguage()
        renderSnapshot(NSHostingView(rootView: HelpView(scrolls: false)
            .background(Color(nsColor: .windowBackgroundColor))), width: 460, to: path)
    }

    /// `--snapshot <png> [--expand] [--light] [--he|--en]`: renders the panel from the
    /// current usage.json and backlog into a PNG and exits — for reviewing UI
    /// changes without touching the running widget.
    /// `--demo`: made-up numbers, account and backlog, so a picture of the panel shows nobody's
    /// real projects (the README's screenshot).
    func loadDemo() {
        let hour: TimeInterval = 3600
        model.session = Metric(pct: 34, resetsAt: Date().addingTimeInterval(2.4 * hour))
        model.weekly = Metric(pct: 71, resetsAt: Date().addingTimeInterval(52 * hour))
        model.scoped = Metric(pct: 18, resetsAt: Date().addingTimeInterval(52 * hour))
        model.userLine = L("דנה לוי · הסטודיו", "Dana Levi · Studio")
        model.harvestInstalled = true
        func task(_ project: String, _ title: String, _ status: String, _ pct: Double, extra: String = "") -> String {
            #"{"project":"/demo/\#(project)","projectName":"\#(project)","title":"\#(title)","status":"\#(status)","priority":2,"complexity":"low","tokens":90000,"pct":\#(pct)\#(extra)}"#
        }
        let he = uiHebrew
        let json = """
        {"queue":[\(task("recipes-app", he ? "בדיקות לחישוב המנות" : "Tests for the portion calculator", "open", 1.2)),
                  \(task("site", he ? "README לא תואם לפקודות ההתקנה" : "README doesn't match the install steps", "open", 0.4))],
         "proposals":[\(task("recipes-app", he ? "להסיר TODO ישן ב-sync" : "Resolve an old TODO in sync", "proposed", 0.6)),
                      \(task("site", he ? "שגיאות lint בטופס יצירת קשר" : "Lint errors in the contact form", "proposed", 0.3)),
                      \(task("site", he ? "תמונות בלי טקסט חלופי" : "Images without alt text", "proposed", 0.5))],
         "needsYou":[\(task("recipes-app", he ? "בדיקות יחידה למיון" : "Unit tests for sorting", "done", 0.8, extra: #","branch":"backlog/sort-tests","branchState":"unmerged","ageDays":1"#))],
         "done":[\(task("recipes-app", he ? "בדיקות יחידה למיון" : "Unit tests for sorting", "done", 0.8, extra: #","branch":"backlog/sort-tests","branchState":"unmerged","ageDays":1"#)),
                 \(task("site", he ? "תיקון קישורים שבורים" : "Fix broken links", "done", 0.3, extra: #","branch":"backlog/links","branchState":"merged","ageDays":2"#))],
         "projects":[{"path":"/demo/recipes-app","name":"recipes-app"},{"path":"/demo/site","name":"site"}],
         "settings":{"language":"\(he ? "he" : "en")","configured":true}}
        """
        do { model.listing = try JSONDecoder().decode(HListing.self, from: Data(json.utf8)) }
        catch { FileHandle.standardError.write(Data("demo listing: \(error)\n".utf8)) }
    }

    func snapshot(to path: String, expandAll: Bool) {
        forceSnapshotLanguage()
        loadSavedUsage()
        model.harvestInstalled = FileManager.default.fileExists(atPath: harvestEngine.path)
            && !CommandLine.arguments.contains("--not-installed")
        model.dotColor = .systemGreen
        model.persistsLayout = false
        if expandAll {
            model.queueOpen = true
            model.proposalsOpen = true
            model.needsOpen = true
            model.doneOpen = true
            model.scheduleOpen = true
        }
        if CommandLine.arguments.contains("--demo") {
            loadDemo()
            DispatchQueue.main.async { self.renderPanelSnapshot(to: path) }
            return
        }
        runEngine(["list"]) { [weak self] data in
            guard let self else { return }
            if let data = data, let listing = try? JSONDecoder().decode(HListing.self, from: data) {
                self.model.listing = listing
            }
            self.renderPanelSnapshot(to: path)
        }
    }

    func renderPanelSnapshot(to path: String) {
        self.updateAutoPlan()
        // cacheDisplay skips the window background, so the view paints its own.
        let host = NSHostingView(rootView: PanelView(m: self.model)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = WidgetPanel(bareFrame: NSRect(x: -10000, y: -10000, width: 300, height: 1400))
        window.appearance = NSAppearance(
            named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        self.snapshotWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let h = ceil(max(host.fittingSize.height, 100))
            window.setContentSize(NSSize(width: 300, height: h))
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
    }
}

// An accessory app — no Dock icon, no app menu — driven by AppDelegate.
NSApplication.shared.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
