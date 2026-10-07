# Digest email

Sent once per weekly cycle, by the last automatic run (`final: true`) — and only when `claude-harvest settings` has `emailDigest: true` and an `email`. Otherwise send nothing and end the run with `--emailed skipped` (the widget then doesn't warn about a missing email). To: that `email`, via the Gmail connector's `send_message` (ToolSearch `gmail send_message` if deferred); no Gmail connector available → `--emailed no`, and say so in the report. In the owner's `language`: `htmlBody` wrapped in
`<div dir="rtl" style="font-family:-apple-system,Arial,sans-serif;line-height:1.55;max-width:640px">` for Hebrew (`dir="ltr"` for English); use `<h3>`, `<p>`, `<ul>`, `<code>`. No images, no attachments, no diffs, no customer data or secrets. Under ~35 lines — one weekly email the owner actually reads beats a long one they skip.

Sources: `claude-harvest list` → `needsYou`, `proposals`, `status.cycle` (done/blocked/failed this week, across runs), `usage`; plus this run's report.

The wording is given in both languages (he / en); use the owner's.

Subject: he `עונת הקציר · <dd.mm> · <N> מחכות לך` — or `עונת הקציר · <dd.mm> · שקט` when nothing happened and nothing waits. en `Harvest Season · <dd.mm> · <N> waiting for you` — or `Harvest Season · <dd.mm> · quiet`.

## Body — decisions first

**מחכה לך / Waiting for you (<N>)** — one line each:
- branch to review: he `<project> — <title>: <one-line meaning>. בווידג'ט: מחכה לך ← לחיצה פותחת סשן בקלוד שמציג את השינוי וממזג באישורך.` en `<project> — <title>: <one-line meaning>. In the widget: Waiting for you → a click opens a Claude session that shows the change and merges it on your approval.` At 14+ days add he `(שבועיים)` / en `(two weeks)`, and at 28+ days he `(חודש בלי מגע — בעוד שבוע יעבור לארכיון)` / en `(a month untouched — it moves to the archive in a week)`.
- blocked: he `<project> — <title>: חסום — <question>.` en `<project> — <title>: blocked — <question>.`
- proposals: he `<n> הצעות חדשות ב-<projects>. בווידג'ט: הדלק את המתג ליד מה שתרצה שירוץ.` en `<n> new proposals in <projects>. In the widget: turn on the switch next to what you want run.`

**מה נעשה השבוע / Done this week** — per project: title → the agent's SUMMARY → branch.

**מכסה / Quota** — he `נוצלו ~X נקודות שבועיות שהיו נעלמות באיפוס (מ-Y% ל-Z%). נדחו מחוסר תקציב/זמן: <n>.` en `Used ~X weekly points that would have vanished at the reset (from Y% to Z%). Deferred for lack of budget or time: <n>.`

**לתשומת לבך / Worth knowing** — only if non-empty: projects not found or without git, failures and why, tools that were unavailable.

## Quiet version
Nothing done and nothing waiting → the quiet subject and one paragraph:
he `השבוע לא היה מה לקצור — <reason: לא היו משימות בתור / המכסה נוצלה על ידך / הריצה התחילה אחרי האיפוס>. המערכת חיה.` Add `<n> הצעות מחכות לאישור בווידג'ט` if any exist.
en `Nothing to harvest this week — <reason: no queued tasks / you used the quota yourself / the run started after the reset>. The system is alive.` Add `<n> proposals wait for approval in the widget` if any exist.
