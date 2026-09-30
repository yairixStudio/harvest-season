---
name: check-usage
description: Check the account's Claude Code plan usage limits — the 5-hour window, the weekly window(s) and when each resets — with the desktop app's built-in usage tool. Use whenever the user asks how much quota or usage is left, when a limit resets, whether they are close to the limit, or says "כמה מכסה נשארה לי", "בדוק שימוש", "מתי מתאפס", "5 hour limit", "weekly limit", "usage left". Not for a session's context-window token breakdown (that is explain-usage).
---
<!-- Installed copy, managed by the Quota Harvest installer: edit harvest/skills/check-usage/SKILL.md in the quota-harvest repository, then reinstall. -->

# Check usage

The Claude desktop app exposes the account's plan limits to every session through the MCP tool `mcp__ccd_session_mgmt__get_usage` — read-only, no side effects, safe to call any time. It is the same data as the app's usage card: no web page, no unofficial endpoint, no guessing from local token counts.

## Steps
1. If the tool is only listed as deferred, load it: ToolSearch with query `select:mcp__ccd_session_mgmt__get_usage`.
2. Call it with no arguments (`session_id` defaults to `self`; the plan limits are the account's either way).
3. Report each entry of `plan.windows`: label, percent used and remaining, `resetsIn`. Convert `resetsAt` to local time when it helps (`date`). Answer in the user's language — Hebrew when asked in Hebrew.
4. Mention `plan.extraUsage` only when `enabled` is true or the user asks about extra/overage spend.

## Reading the result
- `plan.status: ok` → numbers are valid. Labels look like `5-hour limit`, `Weekly · all models`, `Weekly · <model>` (a model with its own weekly cap, e.g. Fable).
- `not_applicable` → API key / Bedrock / Vertex / gateway account: plan windows don't exist. Say so; don't invent numbers.
- `unavailable` → couldn't be read now; relay the `note` (it says whether retrying helps).
- The `context` part is this session's context window — unrelated to plan quota, don't mix them.

If the tool doesn't exist in the environment (plain CLI outside the desktop app), say so and point to `/usage` in the CLI or the app's usage card. Never estimate plan quota from local token counts — they miss other devices and claude.ai.

## Example answer (Hebrew)
```
תוכנית Max
· חלון 5 שעות: 55% בשימוש (נותרו 45%) — מתאפס בעוד 2h 36m (21:00)
· שבועי, כל המודלים: 51% — מתאפס בעוד 9h 36m (שני 04:00)
· שבועי Fable: 10%
```
