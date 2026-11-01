# Backlog

משימות קטנות ולא דחופות של הפרויקט. סוכן "קציר המכסה" (`harvest-quota`) מבצע משימות במצב `open` לפני האיפוס השבועי של מכסת קלוד, על ענף `backlog/*` נפרד, בלי push — ומחכה לאישור שלך למיזוג. הצעות (`proposed`) לא רצות בלי "כן" ממך.

<!--
Format: one task per "##" section, one "- key: value" per line. Keys in English, values in any language.
status:     open · proposed · blocked · done · dropped
added:      YYYY-MM-DD
scheduled:  YYYY-MM-DD the recommended date, empty for any time; the harvest takes it from a few days before (earlyDays).
            "YYYY-MM-DD strict" = not a day earlier, for work with no value before it. Set by `claude-harvest add --when/--not-before`
deadline:   YYYY-MM-DD the last useful day, empty for none; it moves the task up as it nears
priority:   1 high · 2 normal · 3 low
complexity: low · medium · high   (picks the model: low→Sonnet, medium→Opus, high→Fable)
tokens:     rough estimate of total agent tokens incl. ~60k fixed overhead (low ≈ 100k, medium ≈ 200k, high ≈ 400k)
details:    what to do and what counts as done; name files/areas
result:     filled by the agent — date · branch · what changed (Hebrew, for the owner) · actual tokens
-->

## A bare build in the repo folder picks up the app's Info.plist
- status: done
- added: 2026-09-30
- priority: 3
- complexity: medium
- tokens: 200000
- details: A bare QuotaHarvest built in the repository folder (./start, --snapshot runs) finds the Info.plist next to it and so runs with the app's bundle id dev.quota-harvest.widget — its UserDefaults, and migrateDefaults, act on the installed app's settings, which SPEC says a bare binary never touches. Done when a bare build uses its own defaults domain (e.g. check Bundle.main.bundleURL ends in .app before trusting bundleIdentifier, in migrateDefaults, notifications and anything keyed on it), and snapshots still render.
- result: 2026-10-18 · backlog/a-bare-build-in-the-repo-folder-picks-up · A copy of the app built in the project folder (./start, snapshots) no longer reads or changes the installed app's settings (language, switches, window positions): it keeps its own. Before merging, run ./install once and check that the installed app still has its name, icon and clickable notifications. The bundle's Info.plist moved to app/. · 998k

## Cost-based model fallback: switch before a task when the model's own quota can't cover it
- status: blocked
- added: 2026-10-07
- scheduled:
- deadline:
- priority: 2
- complexity: medium
- tokens: 200000
- details: Today pick_model in harvest/home/bin/harvest.py switches from a model with its own weekly quota (Fable) only at the owner's fixed percent (settings fallback.atPct). Add a cost check: before a task starts, also switch when the task's estimate doesn't fit in what is left of that model's quota. That needs tokens per point of the model-scoped window, which nothing records yet: add scoped_before/scoped_after columns to calibration.md (append_calibration, from usage.scoped), keep ratio() tolerant of old 10-column rows, and compute tokens-per-scoped-point the way calc() does for 5h/weekly. Use the cost check only once at least 3 rows measured it; until then the percent alone decides. Done when: python3 harvest/home/bin/test_harvest.py passes with new tests (old calibration rows still parse; with 3+ measured rows a task whose estimate exceeds the scoped room picks the fallback while one that fits keeps the model; with fewer rows only atPct decides), SPEC.md and harvest/home/README.*.md describe it, and Settings → Models notes it in one line (both languages).
- result: 2026-10-18 · blocked (engine bug, not the task): both attempts were cut off mid-work because running test_harvest.py inside the task session wrote a fake result {status: done, summary: 'x'} into the real ~/.claude/harvest/task-results/<sessionId>.json — a test leaks the session id / result path from the environment despite the temp HARVEST_HOME. The engine then closed the session and dropped the worktree. Fix the test isolation first (or run this task by hand), then set it back to open. Last attempt resumable: claude --resume b19079e2-eb7a-4e1a-ba74-c6535f9179f5

## A listing the widget can't read should show as trouble, not as an empty panel
- status: proposed
- added: 2026-11-01
- scheduled:
- deadline:
- priority: 2
- complexity: low
- tokens: 100000
- details: refreshListing in HarvestSeason.swift drops a JSONDecoder failure silently (try?), so one value of an unexpected type blanks every section with no sign of trouble: on 2026-11-01 a half value of estimate.turns had left the queue, proposals and Done looking empty. Keep the last good listing on a failed decode and turn the live dot yellow with the reason in its tooltip (setStatus, as AGENTS.md says problems show). Done when feeding a listing with a wrong type keeps the last rows, the dot says so, and a snapshot shows it.
- result:
