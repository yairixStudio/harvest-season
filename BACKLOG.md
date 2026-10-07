# Backlog

משימות קטנות ולא דחופות של הפרויקט. סוכן "קציר המכסה" (`harvest-quota`) מבצע משימות במצב `open` לפני האיפוס השבועי של מכסת קלוד, על ענף `backlog/*` נפרד, בלי push — ומחכה לאישור שלך למיזוג. הצעות (`proposed`) לא רצות בלי "כן" ממך.

<!--
Format: one task per "##" section, one "- key: value" per line. Keys in English, values in any language.
status:     open · proposed · blocked · done · dropped
added:      YYYY-MM-DD
priority:   1 high · 2 normal · 3 low
complexity: low · medium · high   (picks the model: low→Sonnet, medium→Opus, high→Fable)
tokens:     rough estimate of total agent tokens incl. ~60k fixed overhead (low ≈ 100k, medium ≈ 200k, high ≈ 400k)
details:    what to do and what counts as done; name files/areas
result:     filled by the agent — date · branch · what changed (Hebrew, for the owner) · actual tokens
-->

## A bare build in the repo folder picks up the app's Info.plist
- status: proposed
- added: 2026-09-30
- priority: 3
- complexity: medium
- tokens: 200000
- details: A bare QuotaHarvest built in the repository folder (./start, --snapshot runs) finds the Info.plist next to it and so runs with the app's bundle id dev.quota-harvest.widget — its UserDefaults, and migrateDefaults, act on the installed app's settings, which SPEC says a bare binary never touches. Done when a bare build uses its own defaults domain (e.g. check Bundle.main.bundleURL ends in .app before trusting bundleIdentifier, in migrateDefaults, notifications and anything keyed on it), and snapshots still render.
- result:

## Cost-based model fallback: switch before a task when the model's own quota can't cover it
- status: open
- added: 2026-10-07
- priority: 2
- complexity: medium
- tokens: 200000
- details: Today pick_model in harvest/home/bin/harvest.py switches from a model with its own weekly quota (Fable) only at the owner's fixed percent (settings fallback.atPct). Add a cost check: before a task starts, also switch when the task's estimate doesn't fit in what is left of that model's quota. That needs tokens per point of the model-scoped window, which nothing records yet: add scoped_before/scoped_after columns to calibration.md (append_calibration, from usage.scoped), keep ratio() tolerant of old 10-column rows, and compute tokens-per-scoped-point the way calc() does for 5h/weekly. Use the cost check only once at least 3 rows measured it; until then the percent alone decides. Done when: python3 harvest/home/bin/test_harvest.py passes with new tests (old calibration rows still parse; with 3+ measured rows a task whose estimate exceeds the scoped room picks the fallback while one that fits keeps the model; with fewer rows only atPct decides), SPEC.md and harvest/home/README.*.md describe it, and Settings → Models notes it in one line (both languages).
- result:
