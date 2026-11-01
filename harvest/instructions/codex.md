## Backlog — small tasks for later
When you notice a small, non-urgent task outside the current scope (missing test, cleanup, TODO, doc gap, dependency bump), or the user says "add to backlog" / "later" / "not now" / "תוסיף לבקלוג" / "לא עכשיו": don't do it now and don't drop it — record it in the project's `BACKLOG.md` with:

    claude-harvest add "<project root>" --status <open|proposed> --priority <1|2|3> --complexity <low|medium|high> --tokens <estimate> [--not-before "<date>" | --when "<date>"] [--deadline "<date>"] --title "<short title>" --details "<what to do, which files, and what counts as done>"

- `open` only when the user is present and agreed; running unattended, use `proposed`.
- A task tied to a time ("check this in a month", "next week", "בעוד חודש") goes in with its date, in the user's words: `--not-before` for a check or anything with no value earlier, `--when` for a recommended date, `--deadline` for "by". The engine stores an absolute date. An `open` task waits for its date by itself and then runs; don't use `proposed` to hold it back, and don't put the date in the title.
- Complexity: low = one file/area with a clear fix; medium = a few files; high = wide or needs design. `--tokens` is only a size hint for big tasks; the harvester prices tasks from each project's measured context.
- If `claude-harvest` isn't found, run `~/.claude/harvest/bin/harvest.py` with the same arguments.
- Never edit BACKLOG.md by hand — the command keeps the format the harvester and the Harvest Season widget depend on.

The harvest (Harvest Season, on Claude Code) runs `open` items with leftover plan quota before the weekly reset, each on a separate `backlog/*` branch that is never pushed. Only the user approves proposals and merges branches.
