# Quota Harvest

Spends Claude Code plan quota that would otherwise vanish at the weekly reset on small tasks from your projects.

**The files here are installed from the widget's repository** (`harvest/` in the repo, by `harvest/install.py`). Don't edit them here: change them in the repo and install again — an edit here counts as a conflict at the next install.

## Getting started
After the install, in the setup window: **"Start the getting-started conversation"** — a live session in the Claude app ("Harvest · getting started", `claude-harvest talk --topic onboard`) that finds the projects you worked on with Claude Code (`claude-harvest discover`), asks which ones to work on, reads them without touching them, and records up to 3 first tasks per project — as proposals, which you approve with their switch.

## The idea in one line
There is one queue. It runs by itself a few hours before the weekly reset (you choose how many, with the slider), or right away at a click.

## Where it lives
- **The menu bar widget** (the `quota-harvest` repository) — the interface: usage bars, **Queue** / **Proposals** / **Waiting for you**, the slider, "Run now", "Stop". Opens at login.
- **The engine** `bin/harvest.py` (on the command line: `claude-harvest`) — every deterministic step: reading and editing `BACKLOG.md`, budget, task choice, git worktrees and branches, calibration, status, the lock and recovery after a stop. Tests: `python3 bin/test_harvest.py`.
- **The skills** in `~/.claude/skills/`: `harvest-quota` (the harvest itself), `backlog` (recording tasks), `check-usage` (checking quota).
- **`~/.claude/CLAUDE.md`** and **`~/.codex/AGENTS.md`** — every Claude session, and Codex too, knows how to record tasks in the backlog.

## How a harvest runs
1. The widget starts a coordinating session ("Quota harvest · …" in the harvest folder) — an interactive Claude Code session in a hidden terminal (`claude-harvest launch`, in the harvest folder — `workdir` in the settings), published through Remote Control — **you can watch it live in the Claude app and on your phone**, and write to it. The Mac stays awake until it ends.
2. The agent asks the engine: what is queued, how much quota is left, what fits. A task that can't finish before the reset doesn't start.
3. Each task: **its own session inside its own project**, named "Harvest · <task title>" — it appears in the app under that project, with the project's CLAUDE.md and memory. It works in a worktree inside the project, on its own `backlog/<slug>` branch. The model follows the complexity (low → Sonnet, medium → Opus, high → Fable; when the Fable quota is full → Opus; change it with `models` in the settings). No push, no merge.
4. At the end: a report in `reports/`, and the task moves to "Waiting for you". An automatic run sends one summary email a week — only when an email is set up (`emailDigest`).

## Watching
- **Watch** (while running) — jumps to the live session in the Claude app.
- **The "last harvest" line** (after a run) — a click opens the run's coordinating session in the app, with everything the agent did. A run you started with "Run now" opens there by itself when it ends.
- ⋯ → **Watch the run in Terminal** — a live view in Terminal, one line per step.
- **Done** — everything finished in the last 30 days, by today / yesterday / this week. Blue branch = waiting for your review, green check = merged. A click on a row opens the session that did it in the Claude app: the engine records it in `history.jsonl` — the task's session in a harvest, the session that called `set-status … done` when a task was marked by hand, and `claude-harvest link-session "<project>" "<title>" <session id>` to link one by hand.

## What it needs from you
- **Turning a proposal on** (the switch) = approval. Agents never approve for themselves.
- **"Waiting for you"** → a click opens a Claude session that shows what changed and merges on your approval.
- **Reminder:** when harvest work has waited two days or more, a notification asks "I did work you haven't approved yet… shall we talk about it?". Every other day, daily from a week on, between 10:00 and 21:00. A click opens a live session in the app, "Harvest · what waits for you" (`claude-harvest talk`). Claude explains each branch with a recommendation and merges only on your approval (`claude-harvest merge`). The merge refuses when the project is on another branch, has unsaved changes, or conflicts. "Tomorrow" snoozes the reminder a day. The same session opens from the bottom of "Waiting for you" in the panel.
- A branch untouched for 35 days moves to `backlog-archive/*` (not deleted).

## Settings
`settings.json` — the owner's name, language (`he` / `en`), email and `emailDigest`, the harvest folder (`workdir`) and a model per complexity (`models`). The installer writes it; to see or change it: `claude-harvest settings [--set key=value]` (an automatic run can't change it).

## Files here (one writer each)
- `settings.json` — the settings (above). `install-manifest.json` — what the installer wrote, with a hash per file. `backups/` — a copy of everything the installer replaced.
- `projects.md` — the registered projects (one path per line, `#` = disabled).
- `usage.json`, `config.json` — written by the widget.
- `status.json`, `calibration.md`, `history.jsonl` (task history), `launch.json` (the last run), `context.json` (each project's measured starting context and the turns tasks took), `.lock`, `worktrees/` — written by the engine.
- `reports/` — a report per run. `logs/` — each run's full log (the last 20).

## Without the mouse
`kill -USR1 $(pgrep -x QuotaHarvest)` opens/closes the panel · `kill -USR2 …` runs the queue now or stops a run.
