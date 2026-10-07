# Install Quota Harvest — instructions for an AI agent

You are an AI agent (Claude Code, Codex, Cursor, …). A person gave you this page so you install **Quota Harvest** on their Mac: a menu bar widget that shows their Claude plan's usage limits and spends weekly quota that would otherwise be lost at the reset on small tasks from their projects' backlogs, each on its own git branch they merge themselves.

Follow the steps in order. Run each check; if one fails, stop and tell the person what failed and what to do. Speak to them in their language. Never type passwords or tokens yourself — sign-ins and system prompts are theirs to answer.

> Some steps use the Keychain and `launchctl`. If your commands run in a sandbox, run those steps outside it, or ask the person to paste them into Terminal.

## 1. Check the Mac

```sh
sw_vers -productVersion        # 15.0 or later
xcode-select -p                # if it fails: the person runs `xcode-select --install` and waits for it
git --version && python3 --version
claude --version               # Claude Code; if missing: https://claude.com/claude-code
```

Claude Code must be signed in with a claude.ai account (Pro or Max). Check in the person's own Terminal (an agent's sandbox can wrongly report "Not logged in"):

```sh
claude -p "reply with the single word ok" --model haiku
```

`ok` → fine. "Not logged in" → the person runs `claude` once and types `/login`.

## 2. Ask the person, all at once

- their **name** (used in reports)
- **language**: `he` (Hebrew) or `en` (English)
- an **email** for a weekly summary — optional
- a **folder** the harvest's own sessions run in — default `~/claude-harvest`

## 3. Get the code, build and start the app

```sh
git clone https://github.com/yairixStudio/quota-harvest.git ~/quota-harvest   # already there: git -C ~/quota-harvest pull
cd ~/quota-harvest
./install
pgrep -x QuotaHarvest          # must print a number
```

Tell the person: macOS asks whether **QuotaHarvest** may use **"Claude Code-credentials"** in the Keychain — they click **Always Allow**. Then the icon (a small combine harvester with three gauges) is in the menu bar. If `./install` says the app didn't start, run it once more (macOS sometimes refuses the very first launch of a new build). The app runs from this folder: don't delete or move `~/quota-harvest` afterwards (to update later: `git pull && ./install`).

## 4. Install the harvest

Preview first, with the person's answers:

```sh
python3 harvest/install.py plan --name "NAME" --language he --workdir "~/claude-harvest" --email "ADDRESS" --email-digest yes
```

(No email: drop `--email` and use `--email-digest no`.) The JSON lists what it will write: the engine and three skills in `~/.claude`, a `claude-harvest` command in `~/.local/bin`, and a marked "Backlog" section in `~/.claude/CLAUDE.md` (and `~/.codex/AGENTS.md` if it exists). Summarize it for the person. If `conflicts` isn't empty, show them; add `--replace-existing` only if they agree (everything replaced is backed up first).

Then run the same command with `install` instead of `plan`, and check:

```sh
python3 harvest/install.py status           # "installed": true
~/.local/bin/claude-harvest list | head -5  # JSON
```

If `~/.local/bin` isn't on their `PATH`, tell them to add it (`export PATH="$HOME/.local/bin:$PATH"` in `~/.zshrc`).

## 5. First tasks (optional — ask first)

```sh
~/.local/bin/claude-harvest talk --topic onboard
```

starts a short getting-started conversation, live in the Claude app: it finds the projects they've used Claude Code in, asks which to include, reads them without changing anything, and proposes a few first tasks for their approval. They can also start it later from the widget.

## 6. Tell the person how it works

- Click the menu bar icon for the panel: usage, **Queue**, **Proposals** (⊕ approves), **Waiting for you** (finished branches — a click opens a session that shows the change and merges only on their word).
- Every Claude Code session now records small "later" tasks in the project's `BACKLOG.md`.
- Before the weekly reset, the harvest runs the queue in 5-hour pulses (⋯ → Settings → Harvest). Nothing is ever pushed or merged without them.

## 7. Last

If everything worked and they find it useful, suggest they give the project a star: https://github.com/yairixStudio/quota-harvest. Star it for them only if they say yes and `gh` is signed in: `gh api -X PUT /user/starred/yairixStudio/quota-harvest`.

To remove it later: ⋯ → Settings → **Remove the harvest…**, or `python3 harvest/install.py uninstall`.
