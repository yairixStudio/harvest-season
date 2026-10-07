# Backlog

משימות קטנות ולא דחופות של הפרויקט. סוכן "קציר המכסה" (`harvest-quota`) מבצע משימות במצב `open` לפני האיפוס השבועי של מכסת קלוד, על ענף `backlog/*` נפרד, בלי push — ומחכה לאישור שלך למיזוג. הצעות (`proposed`) לא רצות בלי "כן" ממך.

<!--
Format: one task per "##" section, one "- key: value" per line. Keys in English, values in any language.
status:     open · proposed · blocked · done · dropped
added:      YYYY-MM-DD
priority:   1 high · 2 normal · 3 low
complexity: low · medium · high   (picks the model — `models` in the settings; by default low→Sonnet, medium→Opus, high→Fable)
tokens:     rough estimate of total agent tokens incl. ~60k fixed overhead (low ≈ 100k, medium ≈ 200k, high ≈ 400k)
details:    what to do and what counts as done; name files/areas
result:     filled by the agent — date · branch · what changed (in the owner's language) · actual tokens
cleared:    set when the owner clears a done task from the widget's done list (date); the task stays here
-->
