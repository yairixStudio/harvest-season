---
name: backlog
description: Record small, non-urgent tasks in the project's BACKLOG.md so the harvest (Harvest Season) can do them with leftover plan quota before the weekly reset, and review that backlog. Use whenever you notice out-of-scope cleanup, a missing test, a TODO, a doc gap or a dependency bump you shouldn't do right now, and whenever the user says "add to backlog", "later", "not now", "תוסיף לבקלוג", "משימה לאחר כך", "לא עכשיו", or asks what is in the backlog ("מה יש בבקלוג", "what's waiting").
---
<!-- Installed copy, managed by the Harvest Season installer: edit harvest/skills/backlog/SKILL.md in the harvest-season repository, then reinstall. -->

If `claude-harvest` isn't found, run `~/.claude/harvest/bin/harvest.py` with the same arguments.

# Backlog

One `BACKLOG.md` per project root, fixed format, edited only through the harvest engine `claude-harvest` (in `~/.local/bin`) so the Harvest Season widget and the harvester always agree.

The Harvest Season widget in the menu bar shows every project's queue and launches the harvest a set number of hours before the weekly reset (or on demand). Each task runs in a fresh agent on its own `backlog/<slug>` branch, never pushed; the owner reviews and merges.

## Adding a task
    claude-harvest add "<project root>" --status <open|proposed> --priority <1|2|3> --complexity <low|medium|high> --tokens <estimate> --title "<short title>" --details "<what to do, which files, and what counts as done>"

It creates BACKLOG.md from the template if needed, registers the project in `~/.claude/harvest/projects.md`, and refuses duplicates. Tell the user in one line what you recorded.

- **Status**: `open` (queued, will run) only when the user is present in this session and agreed. Running unattended — a scheduled task, a headless `claude -p`, a harvest agent — use `proposed`: an agent never queues work for another agent (the engine enforces this in widget-launched runs).
- **Complexity** picks the model: low → Sonnet, medium → Opus, high → Fable. Unsure means medium.
- **Tokens** is an optional size hint. The engine prices every task from what it measures: turns × (the project's starting context — CLAUDE.md, connectors, system prompt — + the conversation's growth). Your hint only counts when it is larger, so give one for tasks you know are big.
- **Details** must let a fresh agent tell when it's done ("done when X passes / Y exists").

No project in this session (scratch folder) → ask which project the task belongs to.

## What belongs here
Done-checkable work that is safe unattended: tests, refactors inside a module, docs, lint/type fixes, dependency bumps covered by tests, small UI polish with a clear spec, TODO/FIXME cleanups. Not here: product decisions, deploys, data migrations, payments/auth/secrets, work the user wants to watch.

## Statuses
`open` queued · `proposed` not approved to run (an agent's idea, or paused by the owner) · `blocked` needs the decision written in `result` · `done` finished; `result` holds date · branch · plain-words summary · tokens · `dropped`.

The owner queues and pauses tasks with the switch in the widget (open ⇄ proposed). Agents never promote a proposal.

## Reviewing
"What's in the backlog" → `claude-harvest list`, then summarize in the user's language: queued, proposals, and what needs them (`needsYou`: branches to review, blocked questions). On the user's explicit instruction only:
- queue / pause: `claude-harvest set-status "<project>" "<title>" open|proposed`
- merge a finished branch: `claude-harvest merge "<project>" "<title>"` — it merges into the main branch and deletes the branch, and refuses (touching nothing) when the checkout is on another branch, has uncommitted changes, or the branch conflicts. `claude-harvest brief` shows what waits and whether each branch is ready.
- drop: `claude-harvest set-status "<project>" "<title>" dropped`, and `git branch -D backlog/<slug>` if a branch exists
