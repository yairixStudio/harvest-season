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
