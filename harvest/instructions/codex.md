## Backlog — small tasks for later
When you notice a small, non-urgent task outside the current scope (missing test, cleanup, TODO, doc gap, dependency bump), or the user says "add to backlog" / "later" / "not now" / "תוסיף לבקלוג" / "לא עכשיו": don't do it now and don't drop it — record it in the project's `BACKLOG.md` with:

    claude-harvest add "<project root>" --status <open|proposed> --priority <1|2|3> --complexity <low|medium|high> --tokens <estimate> --title "<short title>" --details "<what to do, which files, and what counts as done>"

- `open` only when the user is present and agreed; running unattended, use `proposed`.
- Complexity: low = one file/area with a clear fix; medium = a few files; high = wide or needs design. `--tokens` is only a size hint for big tasks; the harvester prices tasks from each project's measured context.
- If `claude-harvest` isn't found, run `~/.claude/harvest/bin/harvest.py` with the same arguments.
- Never edit BACKLOG.md by hand — the command keeps the format the harvester and the Harvest Season widget depend on.

The harvest (Harvest Season, on Claude Code) runs `open` items with leftover plan quota before the weekly reset, each on a separate `backlog/*` branch that is never pushed. Only the user approves proposals and merges branches.
