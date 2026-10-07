# Working on Quota Harvest

Rules for anyone changing this repository — people and coding agents. `CLAUDE.md` is a link to this file; edit this one. What the app does, in detail, is in `SPEC.md`: keep it true, and don't repeat it here.

## What is where

- `QuotaHarvest.swift` — the whole macOS app, one file: AppKit for the window, the menu bar item and the plumbing, SwiftUI for everything inside the panel and the other windows. No Xcode project, no package manager, no dependencies — keep it that way.
- `harvest/` — the harvest's other half, and its only source:
  - `home/bin/harvest.py` — the engine (Python, standard library only) and `test_harvest.py`
  - `skills/` — the Claude Code skills `backlog`, `harvest-quota`, `check-usage` and their prompts
  - `instructions/` — the "Backlog" sections that go into `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`
  - `install.py` — puts all of the above into the user's home and records a hash per file; `test_install.py`
- `install` — builds `QuotaHarvest.app`, bundles `harvest/` into it, runs it under launchd (label `dev.quota-harvest.widget`). `start` — runs a bare build from this folder, for development.
- `lproj/` — the app's name per language. `docs/` — the README's pictures.

## The installed copies are not the source

`~/.claude/harvest/bin`, `~/.claude/skills/{backlog,harvest-quota,check-usage}` and the marked blocks in `~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md` are copies the installer wrote. Never edit them: the next install sees the change as a conflict and stops. Change `harvest/` here, run the tests, then `./install` (it upgrades an installed harvest) or `python3 harvest/install.py install`.

Nothing personal goes into `harvest/`. Who the owner is — name, language, email, folder, models, projects without proposals — lives in `~/.claude/harvest/settings.json` (`claude-harvest settings`). Anything the engine writes for a person goes through its he/en table (`TEXT`, `tr()`); prompts use `<owner language>` / `<owner name>`.

## Checking a change

- The engine and the installer have tests; both must pass:
  `python3 harvest/home/bin/test_harvest.py` and `python3 harvest/test_install.py` (the latter only ever touches throwaway homes).
- The app has no test suite. Build it with zero warnings (`swiftc -O -o QuotaHarvest QuotaHarvest.swift`) and look at it — the snapshot flags render a window into a PNG and exit, from saved data, without touching the running app or the network:
  `--snapshot <png> [--expand] [--not-installed] [--demo]` (the panel; `--demo` uses made-up data, as in `docs/`), `--snapshot-menubar`, `--snapshot-help`, `--snapshot-settings`, `--snapshot-setup [--review] [--done]`, `--snapshot-tasks [--filter <tab>] [--select <row>] [--demo]` (the all-tasks window); each takes `--light` and `--he` / `--en`. Open the images and read them.
- Only one copy may run: two double the API polling and stack two panels. `./start` quits the previous bare build; the launchd copy is managed by `./install`.
- A running app: `kill -USR1 $(pgrep -x QuotaHarvest)` shows or hides the panel; `kill -USR2 …` runs the queue now or stops a run.
- `QuotaHarvest`, `QuotaHarvest.app` and `__pycache__` are build output — never commit them.

## How the code is written

- The panel's content is SwiftUI (`PanelView`, inside the AppKit `WidgetPanel`). Everything it shows lives in `WidgetModel`, and the panel re-measures itself after every change — new UI state goes in the model, not in a view's `@State`.
- One file, under its `// MARK:` sections (data, sign-in, renewal, fetching, harvest, views, start at login, app). Add to the section a thing belongs to.
- The Swift side never reads or edits `BACKLOG.md`, the status or the calibration — it asks the engine (`runEngine`) and shows the JSON. It writes only `usage.json` and `config.json`.
- One place for each sensitive job: `callSecurityTool` is the only code that runs `/usr/bin/security`; `authorizedGET` is the only code that sets the Bearer header; `warningColor` holds the 70 / 90 % thresholds; `makeContextMenu` builds the right-click menu.
- Decode the API defensively (`JSONSerialization`, optional casts): its shape has changed before. Prefer the `limits` array; keep the older fallbacks.
- Polling is gentle on purpose — the usage endpoint answers 429 when asked too often. One request at a time, the next one scheduled after each attempt, `Retry-After` and backoff honored (`PollPacing`, driven by `refresh()`), never more often than every 5 minutes (`basePoll`). No repeating timer, no quick retries.
- Problems never appear as text in the panel. The last numbers stay; only the live dot's color and tooltip change (`setStatus`): yellow — it will retry by itself; red — the user must act. The one exception is Claude Code missing or signed out (`SignInProblem`): nothing works until it's fixed, so the panel says so in a card with **Sign in** / **Check again**, the menu bar icon gets a red "!", and one notification goes out (the owner's call, 2026-10-07).

## Two languages

- Every string a person sees is `L("<Hebrew>", "<English>")` (the setup window: `s.T`). Hebrew lays out right to left, English left to right (`uiHebrew`: the harvest settings, else the widget's own `UILanguage`, else the Mac's language).
- A whole sentence per language — never build one `Text` out of `L()` pieces; Hebrew word order breaks.
- Never force `.leftToRight` on a `Text` that can contain Hebrew: the letters come out reversed. A path or command never sits inside a Hebrew sentence (directional marks didn't keep it in order); it gets its own `Text`, laid out left to right, as `SetupView.bullet(_:path:)` does.

## The help screen follows the app

⋯ → Help shows `HelpView`: every part of the app explained in plain words — `HelpView.topics` (Hebrew, no English jargon inside sentences) and `HelpView.englishTopics`, topic for topic. A change to what the app shows or does — a section, a button, a state, a menu item, what a number means — updates both lists in the same change, together with `SPEC.md`. Check with `--snapshot-help <png> --he` and `--en`.

## Safety

- Tokens are never logged or printed. The access token goes only to `api.anthropic.com`; the refresh token only to Anthropic's OAuth token endpoint, in the refresh grant.
- Writing renewed credentials back to the Keychain keeps them out of every argument list: `security -i`, with the command on stdin — never the JSON as an argument. Every other field of the stored credentials stays as it was (`mergeRenewal`).
- No analytics, no crash reporting, no network calls to anyone but Anthropic.
- Harvest runs are unattended: they keep `HARVEST_UNATTENDED=1`, their own process group (so Stop reaches every child) and `--permission-mode auto`. No flag that skips permissions; the app never pushes, merges or deletes.

## Commits

- `SPEC.md` changes with behavior, the help screen with anything visible, `README.md` / `README.he.md` with setup or features, and `docs/panel.png` / `docs/panel.he.png` after a visible change (`--snapshot … --demo --expand --light --en` / `--he`).
- Messages: a short imperative summary line; the body says why.
