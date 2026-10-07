# Quota Harvest — what it does

The contract for the app's behavior: when behavior changes, this changes with it. Quota Harvest is a macOS menu bar panel for a Claude Code user. It shows the same usage figures as claude.ai's usage page for the signed-in account — the 5-hour window, the weekly limit across models, and the weekly limit of one model family (currently "Fable") — and runs the backlog harvest described under "Harvest".

## Signing in with Claude Code's credentials

Where they come from, in order:

1. The login Keychain's generic password named `Claude Code-credentials`, read with `/usr/bin/security find-generic-password -w`. The read gets 10 s, then a terminate, then a kill (14 s at most), so a Keychain prompt nobody answers can't hang the app. A timeout, an error or an empty value moves on to (2).
2. The file `~/.claude/.credentials.json`.

Both hold JSON with the OAuth fields inside `claudeAiOauth` (older files: at the top level) — `accessToken`, `refreshToken`, `expiresAt` (epoch milliseconds) — next to other fields such as `scopes`. The app keeps the whole object, fields it doesn't know included, and reads it again before every poll, so a token Claude Code renews is used at once. The access token is sent only as a Bearer header to `api.anthropic.com`; the refresh token only in the renewal below; neither is ever logged or displayed.

### Renewing an expired token

Before a poll, if the access token has expired or expires within 60 s, the app renews it: `POST https://console.anthropic.com/v1/oauth/token` with `{grant_type: "refresh_token", refresh_token, client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`, 15 s timeout.

- The new `accessToken`, the new `refreshToken` (the old one only when the response has none) and `expiresAt` = now + `expires_in` are merged into the stored JSON, every other field untouched, and written back to the same place they were read from — never the other one. The old refresh token stops working once a new one is issued, so the write-back must happen. To the Keychain it goes through `security -i` with its command on stdin, so the JSON never appears in an argument list (same time limits as the read); to the file, as an atomic replace with mode `0600`.
- A 401 or 403 from the usage endpoint leads to one renewal and one retry.
- One renewal attempt per 60 s at most. If it fails, the poll goes ahead with the old token and the dot reports the problem (red, "sign-in expired — open Claude Code").

## What it asks Anthropic

Every request carries `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`, and gives up after 15 s.

`GET https://api.anthropic.com/api/oauth/usage`, every 5 minutes (see "Polling"):

- First choice, the `limits` array. Each entry has `kind`, `percent` (0–100), `resets_at` (ISO 8601) and possibly `scope.model.display_name`: `session` fills the 5-hour row, `weekly_all` the weekly row, `weekly_scoped` the third row, which takes that display name as its label when there is one.
- Whatever `limits` didn't provide comes from the older top-level fields: `five_hour`, `seven_day`, and the first present of `seven_day_fable`, `seven_day_opus`, `seven_day_sonnet` — each with `utilization` (or `used_percent`) and `resets_at` (or `resetsAt`). Dates may be ISO 8601 with or without fractions of a second, or epoch numbers. A response without a single figure counts as a failure.
- Percentages are used as they come, 0–100. A value is never "corrected" from a supposed 0–1 fraction — that once showed a real 1 % as 100 %.

`GET https://api.anthropic.com/api/oauth/profile`, once at start: the account line reads `"<name> · <organization>"` — the name from `account.full_name`, else `display_name`, else `email`; the organization from `organization.name`; either alone if the other is missing. If the line is still empty after a successful poll, the profile is asked again.

## The panel

A borderless panel (`WidgetPanel`) that doesn't activate the app but can take key focus — so its switches are drawn in their live colors, and Esc closes it when it dropped down from the menu bar. 300 pt wide, exactly as tall as what's in it: measured again after every change in the model, keeping its top edge in place. It floats above other windows, on every Space and over full-screen apps; the app has no Dock icon (accessory). Its background is the popover material cut to 12 pt rounded corners by a mask image (a layer corner radius alone would leave the blur and the shadow square), the shadow redrawn after each resize, no focus rings.

Inside is SwiftUI (`PanelView`), in the UI language — `uiHebrew`: the harvest settings' language once a listing has it, else the app's own `UILanguage` setting, else the Mac's first preferred language. Hebrew runs right to left, English left to right; every string is `L(he, en)`. When the language changes, the panel follows, and `languageChanged` rebuilds what was made in the old language: the right-click menu, the dot's tooltip, the reminder's buttons, an open help window.

The floating panel's position is saved under the autosave name `QuotaHarvest` (at first: the top-right of the main screen). Right-click: Refresh now · (from the menu bar) back to a floating widget · Quit.

From top to bottom:

1. The header: "Claude", the account line, the live dot, ↻ (it spins until both the figures and the listing are back — at least 0.8 s, at most 15 s), and the ⋯ menu: Settings…, open the harvest folder, watch the run in Terminal, Help ("עזרה — איך זה עובד"), Quit.
2. The usage rows — 5 hours, weekly, the model's weekly (labeled as the API names it) — and under them one quiet line with the 5-hour and weekly reset times, to the minute (the API's times wobble around it).
3. The harvest's sections, each collapsible, open or closed as last left — see "Harvest".
4. The footer: the harvest's schedule and "run now", or the run in progress with Stop.

A usage row is a label, a bar and a whole percentage. The bar is blue below 70 %, orange from 70 %, red from 90 %. With a known reset time its tooltip says when (`מתאפס <day> HH:mm` / `resets <day> HH:mm`); without data it shows "–" and an empty bar.

Trouble shows only in the live dot — its color and tooltip — never as text in the panel:

- gray "waiting for data…" before the first answer; green "connected" after one.
- yellow, it will try again by itself: "paused — Claude asked to slow down" (429), or "can't reach Claude — trying again" (offline, a 5xx, an answer it can't read).
- red, it needs the user: "not signed in — run claude to sign in", or "sign-in expired — open Claude Code".

After a successful fetch the tooltip adds `· updated HH:mm`. (Each in Hebrew or English, with the rest of the panel.)

### Help

⋯ → "עזרה — איך זה עובד" opens one ordinary window (titled, closable,
resizable, reused, brought to the front; the drop-down panel hides first in menu
bar mode) with `HelpView`: the widget explained in plain words in the UI language,
one topic per part of the panel — what it is, the usage rows and the live dot, בתור,
הצעות, מחכה לך, בוצעו, the harvest footer, the ⋯ menu, and how tasks get into the
backlog. `HelpView.topics` (Hebrew) and `HelpView.englishTopics` (English, the same
topics line for line) are the text; they must describe the panel as it is, so every
behavior change updates both. `--snapshot-help <png> [--light] [--he|--en]` renders
it unscrolled and exits.

## In the menu bar, or floating

In the menu bar by default (`UserDefaults` key `InMenuBar`, default true); switched in Settings.

- **In the menu bar**: one status item image (`menuBarImage`), about 80 pt wide — a combine harvester whose reel turns while a harvest runs, then a small gauge per limit: 5 hours · weekly · the model's weekly. Each gauge is a 270° dial showing the used part, with a needle and a letter (S / W / F) in the gap at the bottom; part and needle turn orange from 70 % and red from 90 %. A limit with no data is left out; the tooltip has the exact figures. It is drawn when needed, so it matches a light or dark menu bar. A click opens the panel under the item, kept inside the screen; a click anywhere else closes it. Right-click: Refresh now · Move back to a floating widget · Quit.
- **Floating**: no status item; the panel sits where it was last left. While the panel drops down from the menu bar its position isn't saved, so the floating position is never overwritten.

## Harvest

Spends plan quota that would vanish at the weekly reset on the owner's queued
BACKLOG.md tasks. Every harvest read and write goes through the engine
`~/.claude/harvest/bin/harvest.py` (JSON out); the widget never parses
BACKLOG.md itself. Files under `~/.claude/harvest/`, one writer each:

- `usage.json` — written by the widget after every successful poll (the engine
  budgets from it; older than 15 min = unreadable). An inactive 5-hour window is
  written as null and read as 0 %.
- `config.json` — written by the widget: `auto` (bool), `pulses` (0 = automatic, 1–6), `batteryGuard` (bool,
  default true) and `minBattery` (5–80, default 10), and `leadHours`
  (pulses × 5 + 1, automatic counting as 6 — the engine refuses an auto run started earlier than that).
  A file from before pulses (`leadHours` only) reads as ⌈leadHours / 5⌉ pulses.
- `status.json`, `calibration.md`, `history.jsonl`, `launch.json`, `.lock`,
  `worktrees/`, BACKLOG.md edits — written by the engine only. `logs/run-*.jsonl` — each run's stream-json
  output, newest 20 kept.

Panel sections (from `harvest.py list`, refreshed every 30 s while the panel is
open or a harvest runs, else every 2 min):

- A task row: the action before the text (▶ run it now in the queue, ⊕ put it in the queue
  for a proposal), then the title, the estimated cost, and the removal at the far end (⊖
  out of the queue, the trash can for a proposal). Above the rows, a two-word header over
  the cost column ("עלות משוערת" / "Est. cost"); each figure's tooltip has the tokens.
- **בתור** — `open` tasks as one list in the order they run (`ordered_queue` in the
  engine, used by both `list` and `plan`): first those the owner placed by dragging, in
  their order (`queue-order.json`, `claude-harvest queue-order <key>…`, keys
  `<project>::<title>`), then the rest by priority and, within a priority, the bigger
  estimate first. Each row shows its project under the title and can be grabbed anywhere and dragged (`.draggable` / `.dropDestination`, the target shown by
  an accent line — `WidgetModel.queueDropTarget`) onto another row to land above it, or
  below the last to go last; the whole new order is sent at once. "↺ Back to the automatic
  order" (shown while any task is `placed`) runs `queue-order --reset`. Refused in
  unattended runs. More than 8 rows scroll in 220 pt. Each row: title, cost as % of the weekly
  quota (the engine's estimate ÷ its calibrated tokens-per-point; the estimate is
  turns × (the project's starting context + growth) — measured per project from its
  sessions, predicted from its CLAUDE.md size until then; the tooltip shows both parts), ▶ to run only that
  task now, and ⊖ (take it out of the queue). Header: count · total %.
- **הצעות** — `proposed` tasks, with ⊕ (put it in the queue). ⊕ / ⊖ run
  `set-status open|proposed`. Header: count, plus "מקום לעוד X%" when the next
  harvest could absorb at least 5 more points.
  Each proposal has a trash can (`set-status … dropped`; the engine notes "removed by the owner" in
  its result, so it isn't proposed again) and each project line a ⋯ menu with "No
  proposals from this project…" (confirmation naming how many go, then `proposals
  "<project>" off`: its proposals are dropped, scans skip it and `add --status proposed`
  there is refused; `on` in Settings undoes it).
- **מחכה לך** — `blocked` tasks and `done` tasks whose `backlog/*` branch is not
  merged into the project's main branch, with their age (orange at 14+ days).
  Clicking opens `claude://code/new?folder=<project>&q=<prompt>`: a new desktop
  session that reviews and, on approval, merges the branch (or resolves the
  blocking question).
- **בוצעו** — `done` tasks of the last 30 days (at most 40), newest first under
  היום / אתמול / השבוע / קודם: title, project, and an icon for the branch (blue
  branch = waiting for review, green check = merged, archive box = archived,
  plain check = no harvest branch). The whole row is a button (highlighted under
  the pointer) that opens the session that did the task in the Claude app. The
  engine links it in `history.jsonl`: `finish-task` records the task's session,
  `set-status … done` the calling session (`CLAUDE_CODE_SESSION_ID`), and
  `link-session` backfills older tasks. Opening goes through `openSessionInApp`:
  a session the app already has — found by `cliSessionId` in its records under
  `~/Library/Application Support/Claude/claude-code-sessions` — opens by its own
  `local_…` id (a desktop session's id can differ from its CLI id, and importing
  it again would copy it); any other is imported first. A task with no session
  falls back to its branch's review session. Header: "N היום · total".
- Rows give titles up to two lines. Projects are grouped by name, in a fixed order, so a group never moves
  when one of its tasks leaves the list; the proposals' ⋯ sits right after the project's name. Above the
  queue and the proposals one muted line says what the % is (estimated token cost, of the weekly quota); a
  task's % has the token estimate in its tooltip.
- Lists of more than 7 tasks (בוצעו: 8) scroll inside a 280 pt (240 pt) frame — `ScrollingList`: the
  system scroller is hidden (it always sits on the right, over the rows' buttons) and a slim indicator is
  drawn in a 10 pt gutter of its own at the trailing edge — right in English, left in Hebrew.

Footer, idle: "קציר" + a live countdown to the next automatic start ("בעוד 4
ימים ו־07:33:32", ticking each second while shown; the time itself in the
tooltip) — or "מתחיל עכשיו", "ממתין לנתוני מכסה", "אוטומטי כבוי". The countdown
and the trigger share one plan (`autoHarvestPlan`): the window's start (weekly
reset − `leadHours`), a follow-up after the 5-hour reset while the last run
stopped on a full window, or next week's window. Then "הרץ עכשיו" (the queue's share in its tooltip) when the
queue isn't empty, and the last run's summary, which opens that run's
conversation in the Claude app. Expanded: the auto switch, the pulses
("2 פעימות לפני האיפוס" / "אוטומטי · 3 פעימות…", `PulsesPicker`: a segmented אוטומטי · 1–6, shared with
Settings) and what they buy: N five-hour windows, capacity = min(weekly room − weeklyReserve, N × weekly
points per window), a window being worth (100 − fiveReserve) × ratio.five / ratio.weekly weekly points.
Automatic = ⌈min(weekly room, queued %) / points per window⌉, 1–6.
Running: pulsing dot, the current task, Stop, an indeterminate bar. A run started
elsewhere (a live lock this widget didn't take) shows as "קציר רץ מסשן אחר"
without Stop.

Launching a run: `harvest.py maintain`, then `harvest.py launch --mode <auto|manual>
--remote-control [--only <project>::<title>]… [--test]` via `posix_spawn` in its own
process group, PATH extended with `~/.local/bin` and Homebrew, output to
`logs/launch-*.out`; `caffeinate -i -w <launcher pid>` keeps the Mac awake for
exactly as long as the run lives. The engine's launcher starts an interactive
`claude` (fixed `--session-id`, `--name "קציר מכסה · <dd.mm HH:mm> · <mode>"`,
`--permission-mode auto --model opus --effort medium --remote-control`) in a
hidden pseudo-terminal in `~/Programs/quota-harvest`, with every inherited
`CLAUDE*`/`MCP_*` marker removed and `HARVEST_UNATTENDED=1` (the engine then
refuses to queue tasks). Interactive + Remote Control is what makes the run
visible: the Claude desktop app and the phone app list it live and let the owner
type into it (headless `claude -p` runs are hidden from both). The launcher
records `launch.json` (session id, name, Remote Control bridge id, pids, end
time), answers the one-time "trust this folder" prompt, and types `/exit` about
20 s after the run calls `end` — or after 45 min without a write to the run's
or its subagents' transcripts (the owner stopped it from the app and left), so a
session can't hold the lock for hours. The owner's "stop" typed into the session
makes the run call `end --reason stopped-by-owner` ("נעצר על ידך").

Each task then runs as a session of its own: the coordinator calls
`harvest.py run-task`, which creates the task's worktree at
`<project>/.claude/worktrees/harvest-<slug>` (Claude Code's worktree location, so
the Claude app files the session under that project; `.claude/worktrees/` is
added to the repo's `.git/info/exclude`) and starts "קציר · <task title>" there
the same way, with the project's CLAUDE.md, memory, settings and hooks. The
task session reports with `harvest.py task-report`; the launcher then closes it
and the engine records the result (history keeps the task session's id).
Proposal scans run likewise ("קציר · סריקת הצעות", a throwaway detached
worktree). New folders open on Claude Code's "trust this folder?" screen with
"No, exit" preselected; the launcher moves the pointer to "Yes" before Enter.

Watching: **צפה** (running) opens the running task's session
(`claude://claude.ai/epitaxy/<bridge id>`, from `status.current`), or the
coordinator's before the first task starts. A finished run is imported with
`claude://resume?session=<session id>` and opened at
`claude://claude.ai/epitaxy/local_<session id>` — a regular desktop session with
the whole conversation (the last-run line in the footer; automatic when a run
started with "run now" ends). ⋯ → "צפה בריצה בטרמינל" follows the transcript in Terminal
(`claude-harvest watch`).

Stop sends SIGTERM to the running task session's group and to the launcher's
group (the launcher forwards it to the coordinator's terminal session), SIGKILL
after 8 s. A launcher that outlived a
widget restart is still shown as ours, watchable and stoppable. On exit:
`maintain` (recovers lock, worktrees, partial branches), refresh, a macOS
notification when the panel is hidden (and always when an automatic cycle ended
without its digest email).

Automatic runs (checked every 30 s) come in **pulses**, one 5-hour window each: when `auto` is on, usage
is under 15 min old, and the weekly reset is between 20 min and pulses × 5 h + 30 min away — once per weekly
cycle (cycle id = reset time rounded to the hour, since the API's reset time jitters across the hour mark;
the number of pulses is fixed then, `HarvestCyclePulses`), and again after each 5-hour reset while the last
run stopped with `5h-full` and the queue isn't empty (at most that many runs per cycle). The next pulse waits
for `HarvestLastSessionReset` (the 5-hour reset known when the run ended) and for `status.limits.five.until`
(a 5-hour limit a session ran into), whichever is later. A run that ended `interrupted` (the Mac slept, the
session stalled) — unless the owner pressed Stop during it (`HarvestStoppedAt`) — is resumed at once while the
queue has work and the reset is over 20 min away, at most twice a cycle (`HarvestCycleRetries`, not counted as
pulses), with a notification. The battery guard (`batteryGuard`, on by default) holds an automatic start while the
Mac runs on battery at or below `minBattery` % (`powerState`, IOKit): the footer says "ממתין לחשמל — הסוללה על
N%" and one notification per cycle asks to plug in. "Run now" is never held.

Usage limits mid-run (engine, `run_session`): Claude Code writes a limit it hits into the session's transcript
(a synthetic assistant message, `isApiErrorMessage`, `error: "rate_limit"`: "You've hit your session limit…",
"…weekly limit…", "You've reached your Fable limit…"); the launcher reads it there — never from the terminal,
which also shows the session's own tool output. The limit is recorded in `status.limits` (`five`, `weekly`,
`model:<name>`, each with `until` from usage.json's reset times) and `plan` / the model choice keep to it until
then. A model's own limit, with `switchMidTask`, closes the session (by signal: the limit can open a dialog
whose choices include paid usage credits, so no keys are ever sent) and resumes it — `claude --resume <id>
--model <fallback>` with the "continue" text — in the same worktree, conversation intact (at most 3
switches). The shared 5-hour or weekly limit closes it at once: `run-task` records the outcome `paused` —
uncommitted work committed as "WIP: stopped at a usage limit (quota harvest)", the `backlog/<slug>` branch
kept, the task back to open with "· paused at … · continues from <branch>" (no strike), and its next attempt
reuses the branch. The coordinator's own limit waits for a running task to stop, then ends the run with
`5h-full` / `weekly-full`, so the next pulse follows. The 45-minute idle close is a signal too.

### Signed out

Without a signed-in Claude Code nothing works — no fresh figures, no harvest — so this one problem is spelled
out (`SignInProblem`: not installed / signed out / expired). Two sources: the widget's own poll (no stored login
→ signed out; 401/403 after a renewal → expired) and `claude auth status --json` (the harvest runs the command
line, which can be signed out on its own), checked at launch, every 30 min, after "Check again", and every 30 s
for 15 min after "Sign in". While it's set: a red card under the usage rows ("Claude Code לא מחובר", what it
stops, when the figures shown were last updated, **התחבר** / **בדוק שוב**); the menu bar image gets a red "!"
after the gauges and its tooltip says why; one notification (category `signin`, at most twice a day — a click
starts signing in); the automatic harvest doesn't start (footer: "לא יתחיל — Claude Code לא מחובר") and "Run
now" explains instead of launching. **התחבר** writes `quota-harvest-sign-in.command` to the temporary folder
(`claude auth login`, then `claude auth status --text`) and opens it in Terminal; with Claude Code missing it
opens claude.com/claude-code. Back signed in, the card clears and a poll goes out at once. At launch the panel
and gauges show usage.json's figures (their time in the card and the dot's tooltip) until a poll comes back —
a restart never blanks them; those figures never count as fresh for the harvest. A session that finds itself
signed out mid-run (`authentication_failed` in its transcript) is closed at once: a task is `paused` ("· paused
at a sign-out"), the coordinator ends the run as `signed-out`. `--snapshot … --signed-out` renders the card; `--snapshot-menubar` draws the "!" in its third row.

### Settings

⋯ → "הגדרות…" opens one window with five tabs (`SettingsView`, reused, filled from the
latest listing): **General** — language (he/en: `setLanguage`, stored in the harvest settings
when installed, else in the widget's `UILanguage` default; the panel, menus and help follow
at once), start at login, menu bar mode (these two moved here from the ⋯ menu). **Harvest**
(installed) — automatic runs, pulses (`PulsesPicker`, `config.json`), the next harvest and the capacity, and
"kept free for you": the 5-hour reserve (0–60, step 5) and the weekly one (0–30), `settings --set
fiveReserve=… / weeklyReserve=…` on each step — and "Battery": "Don't start on a low battery" (`batteryGuard`) and
"Starts only above N % or when the Mac is plugged in" (5–80, step 5). **Models** — a model per task size (`settings --set models=…`),
and for the model with its own weekly quota (`scopedLabel`, Fable): the percent it gives way at (50–100, step
5), the model it gives way to or "None — the tasks wait for the reset" (`fallback`), and "Mid-task too"
(`switchMidTask`). **Projects** — a "Proposals" switch per registered project (`proposals … on|off`, off
confirmed as above). **Texts** — the harvest's texts (`harvest.py prompts`): a sidebar list (task, proposal
scan, what waits for you, getting started, weekly summary email, going on with another model; a blue dot =
customized, orange = unsaved), an editor (monospaced, left to right), what must stay in the text (the
placeholders the engine fills, the task-report step), Save (`prompts --set <name> --file <tmp>`; a refusal
shows what is missing), Discard changes, Restore the default (`prompts --reset`). The owner's versions live in
`~/.claude/harvest/prompts/`, the installed defaults stay untouched; unattended runs can't change them.
General also holds name, email + weekly digest and folder (saved with "Save"), Help and "Remove the
harvest…" (the setup window). Not installed: only General, with "Set up the harvest…". The tabs are a
toolbar-like row of symbols in SwiftUI (so they follow the app's language and direction), each over a
`.formStyle(.grouped)` form; the window is titled after the tab and takes on its height
(`NSHostingController`, `.preferredContentSize`). `--snapshot-settings <png> [--tab
general|harvest|models|projects|texts] [--he|--en] [--light]` renders one tab.

### Setup

The harvest is optional. `WidgetModel.harvestInstalled` = the engine file exists
(`~/.claude/harvest/bin/harvest.py`, checked on every listing refresh; true until the first
check). While it's false the panel shows only the header and the usage rows, then
`setupInvitation`: a line on what the harvest does and **Set up the harvest…**; automatic
runs never start.

The setup window (`SetupModel` / `SetupView`, an ordinary window sized to its content;
also ⋯ → "הגדרת הקציר…") runs the installer bundled with the app —
`Resources/harvest/install.py`, copied there by `./install`, or `harvest/install.py`
beside a bare binary — never an agent. Steps: **form** (language he/en — the window
follows it live —, name, harvest folder, optional email with a weekly-digest switch;
filled from the settings when installed) → **review** (`install.py plan` with those
values: how many files are new / updated / identical, the `claude-harvest` link, each
marked instructions block with its full text and whether it's added or replaces a
hand-written section, the settings file and folder; conflicts — files that exist but
weren't installed by it, or were edited since — listed, and installing needs "replace
them (each is backed up)", which re-plans with `--replace-existing`) → **done**: "Start the getting-started
conversation" runs `claude-harvest talk --topic onboard` — the review conversation's flow
(`startTalk(topic:)`: opened in the Claude app once its bridge id appears; after 45 s
without one, stopped and opened as a new desktop session asked to follow
`references/onboard-prompt.md`) — or "Later". When
installed, the form offers "Remove the harvest…" (confirm → `install.py uninstall`: the
owned files, the link and the blocks go; queue, history, settings and branches stay).
Everything in the window goes through `L()`/`T()` in both languages; a path is never
inside a sentence — it gets its own line, laid out left to right (a Hebrew sentence
scrambles an embedded path, and a `layoutDirection` override on Hebrew text reverses its
letters). `--snapshot-setup <png> [--review] [--he|--en]
[--light]` renders it.

The installer (`harvest/install.py`, standard library only): `plan` / `install` /
`status` / `uninstall [--purge]`; it owns the engine, the skills, the link, the two
marked blocks (`<!-- claude-harvest:begin … -->` … `<!-- claude-harvest:end -->`; a
legacy unmarked "## Backlog — small tasks for later" section becomes the block) and
writes `settings.json` (given values over existing ones) and
`install-manifest.json` (sha256 per file). It never touches the harvest's state.
`./install` upgrades a harvest the installer installed (not a hand-made one) and
reports conflicts without writing.

### Reminder and conversation

Work the harvest did that waits for the owner — unmerged `backlog/*` branches
and blocked questions (`needsYou`) — gets a clickable macOS notification
(`UNUserNotificationCenter`, category `waiting`): "יש עבודה שעשיתי ועוד לא
אישרת: N ענפים ושאלה אחת. הוותיק מחכה X ימים. נדבר על זה?". When: the oldest
item has waited 2+ days; every other day, daily once it has waited a week;
between 10:00 and 21:00; not while a harvest runs or the conversation is open
(`nudgeTick`, keys `NudgeLast`, `NudgeSnoozeUntil`). A click on it, or its
"כן, בוא נדבר" action, opens the conversation; "מחר" snoozes it 24 h. The panel
opens the same conversation from the bottom of **מחכה לך** ("לשיחה עם קלוד על כל
אלה ←").

The conversation is `harvest.py talk`, spawned detached like a run: an
interactive session "קציר · מה מחכה לך · dd.mm HH:MM" in the harvest folder,
published through Remote Control, not unattended (the owner is present), closed
after 45 min without activity; one at a time (`talk.json`). The widget opens it
in the Claude app as soon as its bridge id appears; after 45 s without one it
stops it and opens `claude://code/new` with the same request typed in. The
session follows `references/talk-prompt.md`: it reads `harvest.py brief` (per
branch: files, merge readiness via `git merge-tree`, whether the owner's checkout
is free), explains in Hebrew with a recommendation per item, and acts only on the
owner's word — `harvest.py merge` (refuses when the checkout is on another
branch, has uncommitted changes other than BACKLOG.md, or the branch conflicts),
dropping a task, or `set-status … open --answer` for a blocked question.

Notifications need the app bundle — `QuotaHarvest.app`, bundle id
`dev.quota-harvest.widget`, named "Quota Harvest" / "קציר מכסה" by language (`lproj/`),
`LSUIElement` — which `./install` builds, signs ad hoc, registers and points the
launch agent at. Once, `migrateDefaults` carries over the settings saved under the
app's earlier names (an earlier bundle id and the bare binary's domain), the
floating position included. The permission is re-read every tick. A bare binary
(`./start`, snapshots) never touches `UNUserNotificationCenter` and posts
through osascript instead.

Automation hooks: `kill -USR1 <pid>` toggles the panel; `kill -USR2 <pid>` runs
the whole queue now, or stops the running harvest. `--pretend-weekly-reset-in
<minutes>` (tests only) moves the weekly reset close so the automatic path can
be exercised any day; runs then skip email and push. `--snapshot <png>
[--expand] [--light] [--he|--en]` renders the panel offscreen from the current data and
exits, without touching saved layout; `--snapshot-menubar <png> [--he|--en]` does the same
for the status item (light and dark, plus a sample with warning colors). On every
snapshot `--he` / `--en` force the language, whatever the harvest settings say.
`--write-iconset <dir>` renders the app icon (the harvester on a wheat-gold
tile) for `iconutil`; `--check-notifications` prints what macOS answers the
bundle's notification request, and exits.

## Polling

Slow on purpose: the figures change over hours, and the usage endpoint answers 429 to anyone who asks too often.

- One poll at start; after that, each attempt schedules the next one (a one-shot timer — never a repeating beat): 5 minutes after a success, longer after a failure, plus 0–15 % random spread that never makes a cool-off shorter.
- Never two requests at once. ↻ or Refresh now skips the rest of the wait, but at most once per 30 s.
- A 429 waits as long as the server's `Retry-After` says (seconds or an HTTP date), held between 5 and 30 minutes — or, without it, the backoff below; nothing at all is sent until then, manual refreshes included. Any other failure doubles the wait (5 → 10 → 20 → 30 minutes, no more); a success brings it back to 5.
- When the Mac wakes (`NSWorkspace.didWakeNotification`) the wait goes back to 5 minutes and a poll follows about 5 s later — through the same checks, so a 429 cool-off still holds.
- A request that has been out for more than 2 minutes no longer blocks the next. The 30 s tick doubles as a watchdog: if nothing has been *tried* for longer than the longest wait plus 5 minutes, and no 429 cool-off is running, it calls `refresh()` — with every check, never faster than normal. (The pacing itself is `PollPacing`.)
- App Nap would otherwise delay a windowless accessory app's timers by minutes, so the app holds a `beginActivity(.userInitiated)` for as long as it runs. Timer tolerance may only make a timer later, never earlier.
- A failure never touches the panel's figures: the bars, the percentages and the footer keep the last good answer; only the dot changes.

## Start at login

The switch (in Settings) is on when `~/Library/LaunchAgents/dev.quota-harvest.widget.plist` exists. Turning it on writes that file — `RunAtLoad` true, `ProgramArguments` the app's absolute path — without loading it (loading would start a second copy right away), so it takes effect at the next login. Turning it off unloads the job, as far as that works, and deletes the file. `./install` writes the same job and starts it; it also removes the login item the app had under its earlier name.

## Out of scope

The rest of the usage response — extra-usage credits, spending, other scopes and buckets — isn't shown. There is no sign-in inside the app: when the refresh token itself no longer works, the user signs in again through Claude Code.
