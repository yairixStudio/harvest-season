# Backlog

משימות קטנות ולא דחופות של הפרויקט. "עונת הקציר" (`harvest-season`) מבצעת משימות במצב `open` לפני האיפוס השבועי של מכסת קלוד, על ענף `backlog/*` נפרד, בלי push — ומחכה לאישור שלך למיזוג. הצעות (`proposed`) לא רצות בלי "כן" ממך. משימה עם תאריך עתידי מחכה לתאריך שלה ומגיעה לקציר בעצמה.

<!--
Format: one task per "##" section, one "- key: value" per line. Keys in English, values in any language.
status:     open · proposed · blocked · done · dropped
added:      YYYY-MM-DD
scheduled:  YYYY-MM-DD the recommended date, empty for any time; the harvest takes it from a few days before (earlyDays).
            "YYYY-MM-DD strict" = not a day earlier, for work with no value before it. Set by `claude-harvest add --when/--not-before`
deadline:   YYYY-MM-DD the last useful day, empty for none; it moves the task up as it nears
priority:   1 high · 2 normal · 3 low
complexity: low · medium · high   (picks the model — `models` in the settings; by default low→Sonnet, medium→Opus, high→Fable)
tokens:     rough estimate of total agent tokens incl. ~60k fixed overhead (low ≈ 100k, medium ≈ 200k, high ≈ 400k)
details:    what to do and what counts as done; name files/areas
result:     filled by the agent — date · branch · what changed (in the owner's language) · actual tokens
cleared:    set when the owner clears a done task from the widget's done list (date); the task stays here
-->
