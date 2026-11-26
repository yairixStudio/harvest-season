## Backlog — small tasks for later (the home is Clockwize)
Where something is recorded depends on where the folder lives. Before you record anything from a folder, ask which client and project it belongs to: `clockwize whereami <folder>` (or the `where_am_i` tool).

- What you notice outside your task (a missing test, cleanup, TODO, doc gap, dependency bump, a proposal, something the owner should decide): record it in Clockwize as an idea, not as a task and not in a file:

    clockwize add-idea --client <id> [--project <id>] --title "<short>" --content "<what, where, why, what is open>" --kind idea|proposal --status awaiting_decision --source agent

- The user says "add to backlog" / "later" / "not now" / "תוסיף לבקלוג" / "לא עכשיו": record a Clockwize task assigned to AI, so Harvest pulls it by itself and runs it with leftover quota. A task tied to a time ("check this in a month", "next week", "בעוד חודש") gets that date as its day, in the user's words.
- A folder with no home in Clockwize (`whereami` says none or unknown, or the tool can't be reached): `BACKLOG.md` stays the place, through `claude-harvest add "<project root>" --status <open|proposed> ...` (see the `backlog` skill). In a folder that belongs to a client, `claude-harvest add` refuses: record it in Clockwize.
- Unattended: ideas only, never a task assigned to AI. If `claude-harvest` isn't found, run `~/.claude/harvest/bin/harvest.py` with the same arguments.
- Never edit BACKLOG.md by hand — the command keeps the format the harvester depends on.

The harvest (Harvest Season, on Claude Code) pulls the tasks assigned to AI from Clockwize and runs them with leftover plan quota before the weekly reset, each on a separate `backlog/*` branch that is never pushed. Only the user approves proposals and merges branches (unless the owner switched on auto-merge for a project's tests, docs and lint changes).
