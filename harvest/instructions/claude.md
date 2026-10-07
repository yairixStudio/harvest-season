## Backlog — small tasks for later
When you notice a small, non-urgent task outside the current scope (missing test, cleanup, TODO, doc gap, dependency bump), or the user says "add to backlog" / "later" / "not now" / "תוסיף לבקלוג" / "לא עכשיו": don't do it now and don't drop it — record it with the `backlog` skill (`claude-harvest add ...`, which writes the project's `BACKLOG.md` in the fixed format and registers the project). If `claude-harvest` isn't found, run `~/.claude/harvest/bin/harvest.py` with the same arguments.

Record it as `open` only when the user is present and agreed; when you run unattended (scheduled task, headless `claude -p`, harvest agent) record `proposed` — agents never queue work for other agents.

The Harvest Season widget in the menu bar launches the harvest (`harvest-season` skill) a set number of hours before the weekly quota reset, or on demand: it does `open` items on separate `backlog/*` branches that are never pushed. Only the user approves proposals and merges branches.
