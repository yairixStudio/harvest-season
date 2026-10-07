#!/usr/bin/env python3
"""Quota-harvest engine: every deterministic step of the backlog harvest, shared by the widget and the harvest agent.

The copy in ~/.claude/harvest/bin is installed from the quota-harvest repository (harvest/home/bin):
edit it there and reinstall (`./install`, or `python3 harvest/install.py install`) — the installer refuses to
overwrite a copy edited in place."""

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

HOME = os.path.expanduser(os.environ.get("HARVEST_HOME", "~/.claude/harvest"))
# A new BACKLOG.md starts from the template in the owner's language (BACKLOG.template.<he|en>.md).
TEMPLATE_DIR = os.path.expanduser(os.environ.get("HARVEST_TEMPLATE_DIR", "~/.claude/skills/backlog"))
PROJECTS = os.path.join(HOME, "projects.md")
CONFIG = os.path.join(HOME, "config.json")
USAGE = os.path.join(HOME, "usage.json")
STATUS = os.path.join(HOME, "status.json")
CALIB = os.path.join(HOME, "calibration.md")
LOCK = os.path.join(HOME, ".lock")
WORKTREES = os.path.join(HOME, "worktrees")
LAUNCH = os.path.join(HOME, "launch.json")
TASK_RESULTS = os.path.join(HOME, "task-results")
SKILL_REFS = os.path.expanduser(os.environ.get("HARVEST_SKILL_REFS", "~/.claude/skills/harvest-quota/references"))
WORKTREE_PREFIX = "harvest-"
HISTORY = os.path.join(HOME, "history.jsonl")
TALK = os.path.join(HOME, "talk.json")
# The owner's own order for the queue (dragged in the widget): task keys "<project>::<title>", first to run first.
QUEUE_ORDER = os.path.join(HOME, "queue-order.json")
MERGED_RE = re.compile(r"merged (\d{4}-\d{2}-\d{2})")
DONE_LIST_DAYS = 30
DONE_LIST_MAX = 40

STATUSES = ("open", "proposed", "blocked", "done", "dropped")
MODEL_BY_COMPLEXITY = {"low": "sonnet", "medium": "opus", "high": "fable"}
DEFAULT_TOKENS = {"low": 100000, "medium": 200000, "high": 400000}
DEFAULT_CONFIG = {"auto": True, "leadHours": 8}
# Who the harvest works for, written by the installer (and `settings --set`). Everything personal
# lives here, not in the code or the skills: the owner's name and language (reports, session
# names, notifications), the digest email, the folder the coordinator runs in, the models.
SETTINGS = os.path.join(HOME, "settings.json")
LANGUAGES = ("he", "en")
# A model with a weekly quota of its own (Fable) gives way to another once that quota reaches atPct:
# before a task starts, and — with switchMidTask — in the middle of one, the session going on with its
# conversation intact. An empty "to" means: no fallback, such tasks wait for the quota to reset.
DEFAULT_FALLBACK = {"fable": {"to": "opus", "atPct": 85}}
DEFAULT_SETTINGS = {"ownerName": "", "language": "en", "email": "", "emailDigest": False,
                    "workdir": "~/claude-harvest", "models": dict(MODEL_BY_COMPLEXITY),
                    # Projects the owner wants no proposals for: never scanned, and agents can't propose there.
                    "noProposals": [],
                    "fallback": DEFAULT_FALLBACK, "switchMidTask": True,
                    # Points the harvest leaves unused: in the 5-hour window, so the owner can keep working,
                    # and in the week (anything more than a little would vanish at the reset anyway).
                    "fiveReserve": 15, "weeklyReserve": 2}

SEED_TOKENS_PER_WEEKLY_PCT = 120000
SEED_TOKENS_PER_FIVE_PCT = 30000
# Observed 2026-09-27: one 5-hour window is worth ~1/3.8 of the weekly window.
WEEKLY_PER_FIVE = 3.8
MIN_CALIBRATION_POINTS = 3

FIT_FACTOR = 1.5     # a task starts only if 1.5x its estimate fits the budget
CUTOFF_GUARD_MIN = 20
TOKENS_PER_MINUTE = 8000
USAGE_MAX_AGE_S = 15 * 60
LOCK_MAX_AGE_S = 6 * 3600
# What a session costs is its context, paid again on every turn: turns × (the project's starting
# context + the conversation's growth). The starting context is measured per project from its own
# sessions (system prompt, tools, connectors, CLAUDE.md…); turns and growth are learned from past
# sessions. Until something is measured, these defaults stand in:
DEFAULT_TURNS = {"low": 6, "medium": 12, "high": 24, "scan": 10}
DEFAULT_GROWTH_PER_TURN = 2000
DEFAULT_COMMON_BASE = 38000        # a session's starting context before any project files
CHARS_PER_TOKEN = 3.0              # rough, for sizing CLAUDE.md files (Hebrew-heavy text runs lower)
CONTEXT = os.path.join(HOME, "context.json")
CONTEXT_FILES = ("CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md")
MAX_SCANS_PER_RUN = 3
ARCHIVE_AFTER_DAYS = 35
AUTO_SLACK_H = 0.5

KEY_LINE = re.compile(r"^- ([a-z_]+):[ \t]?(.*)$")
BRANCH_RE = re.compile(r"(backlog(?:-archive|-stopped)?/[A-Za-z0-9._/-]+)")
DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")


# ---------- small helpers ----------

def now():
    return datetime.now(timezone.utc)


def iso(d):
    return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    if not s or not isinstance(s, str):
        return None
    s = re.sub(r"\.\d+", "", s.strip()).replace("Z", "+00:00")
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def today():
    return datetime.now().strftime("%Y-%m-%d")


def cycle_id(resets_at):
    """The API's reset time jitters by fractions of a second between reads (00:59:59.9 vs 01:00:00.2)."""
    d = parse_iso(resets_at)
    return iso((d + timedelta(minutes=30)).replace(minute=0, second=0)) if d else None


def emit(obj, code=0):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, indent=1) + "\n")
    sys.exit(code)


def fail(msg, code=2, **extra):
    emit(dict({"ok": False, "error": msg}, **extra), code)


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def settings():
    s = dict(DEFAULT_SETTINGS, models=dict(MODEL_BY_COMPLEXITY), noProposals=[],
             fallback={k: dict(v) for k, v in DEFAULT_FALLBACK.items()})
    saved = read_json(SETTINGS, {}) or {}
    for k in DEFAULT_SETTINGS:
        if k in saved and saved[k] is not None:
            s[k] = dict(s[k], **saved[k]) if k in ("models", "fallback") and isinstance(saved[k], dict) else saved[k]
    if s["language"] not in LANGUAGES:
        s["language"] = "en"
    return s


# Everything the engine writes that a person reads (session names, results in BACKLOG.md,
# the watch view), in the owner's language.
TEXT = {
    "owner_answer": {"he": "תשובת הבעלים (%s): %s", "en": "Owner's answer (%s): %s"},
    "no_commit": {"he": "הסוכן דיווח שסיים אבל לא נוצר אף קומיט", "en": "the agent reported done but made no commit"},
    "needs_decision": {"he": "צריך החלטה", "en": "needs a decision"},
    "failed_twice": {"he": "%s · נכשל פעמיים: %s", "en": "%s · failed twice: %s"},
    "failed": {"he": "%s · נכשל: %s", "en": "%s · failed: %s"},
    "paused": {"he": "%s · נעצר ב%s · ממשיך מ-%s", "en": "%s · paused at %s · continues from %s"},
    "paused_empty": {"he": "%s · נעצר ב%s · יתחיל מחדש", "en": "%s · paused at %s · starts over"},
    "limit_five": {"he": "מגבלת 5 השעות", "en": "the 5-hour limit"},
    "limit_weekly": {"he": "המגבלה השבועית", "en": "the weekly limit"},
    "limit_model": {"he": "מגבלת %s", "en": "the %s limit"},
    "limit_auth": {"he": "ניתוק מהחשבון", "en": "a sign-out"},
    "talk_name": {"he": "קציר · מה מחכה לך · %s", "en": "Harvest · what waits for you · %s"},
    "onboard_name": {"he": "קציר · היכרות · %s", "en": "Harvest · getting started · %s"},
    "mode_auto": {"he": "אוטומטי", "en": "automatic"},
    "mode_manual": {"he": "ידני", "en": "manual"},
    "run_name": {"he": "קציר מכסה · %s · %s", "en": "Quota harvest · %s · %s"},
    "task_name": {"he": "קציר · %s", "en": "Harvest · %s"},
    "no_report": {"he": "הסשן נסגר בלי לדווח תוצאה", "en": "the session closed without reporting a result"},
    "scan_name": {"he": "קציר · סריקת הצעות", "en": "Harvest · proposal scan"},
    "watch_title": {"he": "קציר מכסה — צפייה בשיחה %s\n%s\n", "en": "Quota harvest — watching %s\n%s\n"},
    "no_transcript": {"he": "(עוד אין תמליל)", "en": "(no transcript yet)"},
    "run_ended": {"he": "\n— הריצה הסתיימה —", "en": "\n— the run has ended —"},
    "removed": {"he": "%s · הוסר על ידי הבעלים", "en": "%s · removed by the owner"},
    "no_proposals": {"he": "%s · הוסר — בלי הצעות לפרויקט הזה", "en": "%s · removed — no proposals for this project"},
}
# A failed task's result starts with this marker in either language; a second failure blocks it.
FAILED_MARKERS = (" · נכשל", " · failed")
# A task a usage limit stopped: not a failure, and its next attempt goes on from the branch in the result.
PAUSED_MARKERS = (" · נעצר ב", " · paused at ")


def task_key(t):
    return t["project"] + "::" + t["title"]


def manual_order():
    return [k for k in (read_json(QUEUE_ORDER, {}) or {}).get("keys", []) if isinstance(k, str)]


def ordered_queue(tasks):
    """The order queued tasks run in — and are shown in: first those the owner placed by hand, in their order;
    then the rest by priority, the bigger task first within a priority (it fits best early, while the budget
    is widest)."""
    place = {k: i for i, k in enumerate(manual_order())}
    return sorted(tasks, key=lambda t: (0, place[task_key(t)], 0) if task_key(t) in place
                  else (1, t["priority"], -t["tokens"]))


def proposals_off(repo):
    """Whether the owner turned proposals off for this project (settings `noProposals`)."""
    real = os.path.realpath(repo)
    return any(os.path.realpath(os.path.expanduser(p)) == real for p in settings()["noProposals"])


def tr(key, *args):
    text = TEXT[key].get(settings()["language"]) or TEXT[key]["en"]
    return text % args if args else text


def write_text(path, text):
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    mode = stat.S_IMODE(os.stat(path).st_mode) if os.path.exists(path) else 0o644
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".harvest-tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def write_json(path, obj):
    write_text(path, json.dumps(obj, ensure_ascii=False, indent=1) + "\n")


def git(repo, *args):
    return subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True)


def is_git(repo):
    return os.path.isdir(repo) and git(repo, "rev-parse", "--git-dir").returncode == 0


def branch_exists(repo, branch):
    return git(repo, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch).returncode == 0


def base_branch(repo):
    r = git(repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
    if r.returncode == 0 and r.stdout.strip():
        b = r.stdout.strip().split("/", 1)[-1]
        if branch_exists(repo, b):
            return b
    for b in ("main", "master"):
        if branch_exists(repo, b):
            return b
    return git(repo, "branch", "--show-current").stdout.strip() or "HEAD"


def commits_ahead(repo, base, branch):
    r = git(repo, "rev-list", "--count", base + ".." + branch)
    try:
        return int(r.stdout.strip())
    except ValueError:
        return 0


def alive(pid):
    try:
        os.kill(int(pid), 0)
    except (ProcessLookupError, ValueError, TypeError):
        return False
    except PermissionError:
        return True
    return True


def runner_pid():
    env = os.environ.get("HARVEST_RUNNER_PID")
    if env and env.isdigit():
        return int(env)
    shell = os.getppid()
    r = subprocess.run(["ps", "-o", "ppid=", "-p", str(shell)], capture_output=True, text=True)
    try:
        return int(r.stdout.strip())
    except ValueError:
        return shell


def display_name(path):
    base = os.path.basename(path.rstrip("/"))
    if base.lower() in ("app", "src", "code", "site", "web"):
        return os.path.basename(os.path.dirname(path.rstrip("/"))) + "/" + base
    return base


def slugify(title, project):
    words = re.findall(r"[A-Za-z0-9]+", title.lower())
    slug = "-".join(words)[:40].strip("-")
    if len(words) < 2:
        h = hashlib.sha1((project + "::" + title).encode("utf-8")).hexdigest()[:6]
        slug = (slug + "-" if slug else "task-") + h
    return slug


def tokens_of(value, complexity):
    m = re.search(r"(\d+(?:\.\d+)?)\s*([kKmM]?)", value or "")
    if not m:
        return DEFAULT_TOKENS.get(complexity, 200000)
    n, unit = float(m.group(1)), m.group(2).lower()
    return int(n * 1000) if unit == "k" else int(n * 1000000) if unit == "m" else int(n)


def int_or(value, default):
    try:
        return int(str(value).strip())
    except (ValueError, TypeError):
        return default


# ---------- registry, config, status ----------

def projects():
    try:
        with open(PROJECTS, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    return [l.strip() for l in lines if l.strip() and not l.strip().startswith("#")]


def register(repo):
    if repo in projects():
        return False
    text = ""
    if os.path.exists(PROJECTS):
        with open(PROJECTS, encoding="utf-8") as f:
            text = f.read()
    if text and not text.endswith("\n"):
        text += "\n"
    write_text(PROJECTS, text + repo + "\n")
    return True


def config():
    cfg = dict(DEFAULT_CONFIG)
    cfg.update({k: v for k, v in (read_json(CONFIG, {}) or {}).items() if k in DEFAULT_CONFIG})
    return cfg


def status():
    st = read_json(STATUS, {}) or {}
    st.setdefault("state", "idle")
    return st


def save_status(st):
    write_json(STATUS, st)


def read_lock():
    if not os.path.exists(LOCK):
        return None
    lk = read_json(LOCK, None)
    if not isinstance(lk, dict):
        lk = {"pid": None, "at": iso(datetime.fromtimestamp(os.path.getmtime(LOCK), timezone.utc))}
    return lk


def lock_is_live(lk):
    if not lk:
        return False
    at = parse_iso(lk.get("at"))
    if at and (now() - at).total_seconds() > LOCK_MAX_AGE_S:
        return False
    return alive(lk.get("pid")) if lk.get("pid") else bool(at)


# ---------- usage limits a session ran into ----------

LIMIT_MODEL_RE = re.compile(r"\b(fable|opus|sonnet|haiku)\b[^.·\n]{0,20}\blimit\b")


def classify_limit(text):
    """Which limit a Claude Code rate-limit message is about: the 5-hour window ("session limit"), the
    all-models week ("weekly limit"), or one model's own quota ("Fable limit") — only the last leaves
    another model to go on with. Anything unknown counts as the 5-hour window: stop now, retry after it."""
    t = (text or "").lower()
    if "session limit" in t:
        return {"kind": "five"}
    if "weekly limit" in t:
        return {"kind": "weekly"}
    m = LIMIT_MODEL_RE.search(t)
    if m:
        return {"kind": "model", "model": m.group(1)}
    return {"kind": "five"}


def limit_key(hit):
    return "model:" + hit["model"] if hit["kind"] == "model" else hit["kind"]


def limit_until(hit, usage):
    """When the limit a session hit lifts, from usage.json's reset times (never from the message's wording);
    without one, a safe guess: 5 hours, or a week."""
    at = parse_iso(hit.get("at")) or now()
    u = usage or {}
    if hit["kind"] == "five":
        r = parse_iso((u.get("session") or {}).get("resetsAt"))
        return r if r and r > at else at + timedelta(hours=5)
    if hit["kind"] == "model":
        scoped = u.get("scoped") or {}
        r = parse_iso(scoped.get("resetsAt"))
        if str(scoped.get("label", "")).lower().startswith(hit["model"]) and r and r > at:
            return r
    r = parse_iso((u.get("weekly") or {}).get("resetsAt"))
    return r if r and r > at else at + timedelta(days=7)


def record_limit(hit, usage):
    st = status()
    st.setdefault("limits", {})[limit_key(hit)] = {"at": hit.get("at") or iso(now()),
                                                   "until": iso(limit_until(hit, usage)), "text": hit.get("text")}
    save_status(st)


def limit_active(st, key):
    lim = (st.get("limits") or {}).get(key)
    return bool(lim) and (parse_iso(lim.get("until")) or now()) > now()


def limit_label(hit):
    if hit["kind"] == "model":
        return tr("limit_model", hit["model"].capitalize())
    return tr("limit_" + hit["kind"])


# ---------- usage and calibration ----------

def normalize_usage(raw):
    """Accepts the widget's usage.json, or get_usage output (whole result, its `plan`, or the windows list)."""
    if isinstance(raw, dict) and "weekly" in raw:
        if not isinstance(raw.get("weekly"), dict) or raw["weekly"].get("pct") is None:
            return None
        if not isinstance(raw.get("session"), dict) or raw["session"].get("pct") is None:
            raw = dict(raw, session={"pct": 0, "resetsAt": None})  # no active 5-hour window = nothing used
        return raw
    windows = raw
    if isinstance(raw, dict):
        windows = (raw.get("plan") or raw).get("windows")
    if not isinstance(windows, list):
        return None
    u = {"fetchedAt": iso(now()), "source": "get_usage"}
    for w in windows:
        label = str(w.get("label", ""))
        m = {"pct": float(w.get("percentUsed", 0)), "resetsAt": w.get("resetsAt")}
        if label.lower().startswith("5-hour"):
            u["session"] = m
        elif "all models" in label.lower():
            u["weekly"] = m
        elif label.lower().startswith("weekly"):
            u["scoped"] = dict(m, label=label.split("·")[-1].strip())
    return u if "weekly" in u and "session" in u else None


def load_usage(inline=None):
    if inline:
        try:
            u = normalize_usage(json.loads(inline))
        except ValueError:
            return None, "usage-json is not valid JSON"
        return (u, None) if u else (None, "usage-json has no 5-hour/weekly windows")
    u = read_json(USAGE, None)
    if not u:
        return None, "usage.json missing (is the Quota Harvest widget running?)"
    fetched = parse_iso(u.get("fetchedAt"))
    if not fetched:
        return None, "usage.json has no fetchedAt"
    age = (now() - fetched).total_seconds()
    if age > USAGE_MAX_AGE_S:
        return None, "usage.json is %d min old" % (age // 60)
    u = normalize_usage(u)
    return (u, None) if u else (None, "usage.json has no 5-hour/weekly windows")


def ratio():
    rows = []
    try:
        with open(CALIB, encoding="utf-8") as f:
            for line in f:
                c = [x.strip() for x in line.strip().strip("|").split("|")]
                if len(c) >= 10 and DATE_RE.match(c[0]):
                    try:
                        rows.append([float(c[5]), float(c[6]), float(c[7]), float(c[8]), float(c[9])])
                    except ValueError:
                        pass
    except OSError:
        pass

    def calc(i, j):
        pairs = [(r[0], r[j] - r[i]) for r in rows if r[j] - r[i] >= 0]
        points = sum(d for _, d in pairs)
        return int(sum(t for t, _ in pairs) / points) if points >= MIN_CALIBRATION_POINTS else None

    five, weekly = calc(1, 2), calc(3, 4)
    source = "measured"
    if weekly is None and five is not None:
        weekly, source = int(five * WEEKLY_PER_FIVE), "derived-from-5h"
    if five is None:
        five, source = SEED_TOKENS_PER_FIVE_PCT, "seed"
    if weekly is None:
        weekly = SEED_TOKENS_PER_WEEKLY_PCT
    return {"weekly": weekly, "five": five, "rows": len(rows), "source": source}


def append_calibration(project, task, model, est, actual, before, after):
    if not os.path.exists(CALIB):
        write_text(CALIB, "# Calibration\n\n| date | project | task | model | est_tokens | actual_tokens | 5h_before | 5h_after | weekly_before | weekly_after |\n|---|---|---|---|---|---|---|---|---|---|\n")
    b, a = before or {}, after or {}

    def pct(u, key):
        v = (u.get(key) or {}).get("pct")
        return "" if v is None else str(int(round(v)))

    row = "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" % (
        today(), display_name(project), task, model, est, actual,
        pct(b, "session"), pct(a, "session"), pct(b, "weekly"), pct(a, "weekly"))
    with open(CALIB, encoding="utf-8") as f:
        text = f.read()
    write_text(CALIB, text + ("" if text.endswith("\n") else "\n") + row)


# ---------- BACKLOG.md ----------

def backlog_path(repo):
    return os.path.join(repo, "BACKLOG.md")


def parse_backlog(repo):
    try:
        with open(backlog_path(repo), encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None, []
    lines = text.split("\n")
    tasks, cur = [], None
    for i, line in enumerate(lines):
        if line.startswith("## "):
            cur = {"title": line[3:].strip(), "line": i, "end": len(lines), "fields": {}, "lines": {}}
            if tasks:
                tasks[-1]["end"] = i
            tasks.append(cur)
        elif cur is not None:
            m = KEY_LINE.match(line)
            if m and m.group(1) not in cur["fields"]:
                cur["fields"][m.group(1)] = m.group(2).strip()
                cur["lines"][m.group(1)] = i
    return lines, tasks


def find_task(repo, title):
    lines, tasks = parse_backlog(repo)
    if lines is None:
        fail("no BACKLOG.md in " + repo)
    for t in tasks:
        if t["title"] == title.strip():
            return lines, t
    fail("task not found: " + title, project=repo)


def set_fields(repo, title, updates):
    lines, t = find_task(repo, title)
    write_fields(repo, lines, t, updates)


def write_fields(repo, lines, t, updates):
    """Sets `updates` in the task section `t` of the parsed BACKLOG.md `lines` and writes the file."""
    insert_at = max([t["line"]] + list(t["lines"].values())) + 1
    for key, value in updates.items():
        text = "- %s: %s" % (key, value) if value != "" else "- %s:" % key
        if key in t["lines"]:
            lines[t["lines"][key]] = text
        else:
            lines.insert(insert_at, text)
            insert_at += 1
    write_text(backlog_path(repo), "\n".join(lines))


def task_view(repo, t, r):
    f = t["fields"]
    complexity = f.get("complexity") or "medium"
    hint = tokens_of(f.get("tokens"), complexity) if f.get("tokens") else 0
    tokens, parts = estimate_tokens(repo, complexity, hint)
    result = f.get("result", "")
    v = {
        "project": repo, "projectName": display_name(repo), "title": t["title"],
        "status": f.get("status") or "open", "priority": int_or(f.get("priority"), 2),
        "complexity": complexity, "tokens": tokens, "pct": round(tokens / float(r["weekly"]), 2),
        "estimate": parts,
        "details": f.get("details", ""), "added": f.get("added", ""), "result": result,
        "line": t["line"], "cleared": bool(f.get("cleared")),
    }
    date = DATE_RE.search(result) or DATE_RE.search(v["added"])
    if date:
        try:
            v["ageDays"] = (datetime.now().date() - datetime.strptime(date.group(1), "%Y-%m-%d").date()).days
        except ValueError:
            pass
    if v["status"] == "done":
        parts = [x.strip() for x in result.split("·")]
        rest = [x for x in parts if x and not DATE_RE.fullmatch(x) and not BRANCH_RE.fullmatch(x)
                and not re.fullmatch(r"\d+k", x) and not x.startswith("archived") and not MERGED_RE.fullmatch(x)]
        v["summary"] = " · ".join(rest)
        b = BRANCH_RE.search(result)
        if b:
            v["branch"] = b.group(1)
            if v["branch"].startswith("backlog-") or "archived" in result:
                v["branchState"] = "archived"
            elif MERGED_RE.search(result):
                v["branchState"] = "merged"
            else:
                v["branchState"] = branch_state(repo, v["branch"])
    if v["status"] == "blocked":
        v["question"] = DATE_RE.sub("", result, count=1).strip(" ·-")
    return v


def context_file_tokens(repo):
    """Tokens of the project files Claude Code loads into every session there (CLAUDE.md and kin)."""
    chars = 0
    for rel in CONTEXT_FILES:
        path = os.path.join(repo, rel)
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                chars += len(f.read())
        except OSError:
            pass
    return int(chars / CHARS_PER_TOKEN)


def context_data():
    ctx = read_json(CONTEXT, {}) or {}
    ctx.setdefault("projects", {})
    ctx.setdefault("sessions", [])
    return ctx


def median(values):
    values = sorted(values)
    if not values:
        return None
    mid = len(values) // 2
    return values[mid] if len(values) % 2 else (values[mid - 1] + values[mid]) / 2.0


def common_base(ctx):
    """Starting context without project files: measured bases minus what their projects add."""
    diffs = [p["base"] - context_file_tokens(repo) for repo, p in ctx["projects"].items() if p.get("base")]
    return int(median(diffs)) if diffs else DEFAULT_COMMON_BASE


def project_base(repo, ctx):
    measured = (ctx["projects"].get(repo) or {}).get("base")
    if measured:
        return int(measured), "measured"
    return common_base(ctx) + context_file_tokens(repo), "predicted"


def learned(ctx, kind):
    recent = [x for x in ctx["sessions"] if x.get("kind") == kind][-10:]
    turns = median([x["turns"] for x in recent if x.get("turns")])
    grows = [(x["last"] - x["first"]) / float(x["turns"] - 1)
             for x in ctx["sessions"][-20:] if x.get("turns", 0) >= 2 and x.get("last") and x.get("first")]
    growth = median(grows)
    return (turns or DEFAULT_TURNS.get(kind, 12), "learned" if turns else "default",
            growth if growth is not None else DEFAULT_GROWTH_PER_TURN)


def estimate_tokens(repo, kind, hint=0, ctx=None):
    """turns × (starting context + growth), or the author's hint when that is larger."""
    ctx = ctx or context_data()
    base, base_source = project_base(repo, ctx)
    turns, turns_source, growth = learned(ctx, kind)
    model = int(turns * (base + growth * (turns - 1) / 2.0))
    parts = {"base": base, "baseSource": base_source, "turns": turns, "turnsSource": turns_source,
             "growth": int(growth), "model": model, "hint": hint}
    return max(model, hint or 0), parts


def session_stats(transcript):
    """The main thread of a session: API calls, first and last context size, and total tokens (with subagents)."""
    turns, first, last, seen = 0, None, None, set()
    try:
        with open(transcript, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                msg = d.get("message") or {}
                if d.get("type") != "assistant" or d.get("isSidechain") or not isinstance(msg, dict):
                    continue
                key = msg.get("id") or d.get("uuid")
                if key in seen:
                    continue
                seen.add(key)
                u = msg.get("usage") or {}
                size = sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens",
                                                         "cache_creation_input_tokens"))
                turns += 1
                first = size if first is None else first
                last = size
    except OSError:
        pass
    return {"turns": turns, "first": first or 0, "last": last or 0, "total": transcript_tokens(transcript)}


def record_session(repo, kind, stats):
    """Keeps what a finished session measured: the project's starting context and the session's shape."""
    if not stats.get("turns"):
        return
    ctx = context_data()
    ctx["projects"][repo] = {"base": stats["first"], "measuredAt": iso(now()), "contextFiles": context_file_tokens(repo)}
    ctx["sessions"] = (ctx["sessions"] + [dict(stats, project=repo, kind=kind, at=iso(now()))])[-60:]
    write_json(CONTEXT, ctx)


def append_history(entry):
    with open(HISTORY, "a", encoding="utf-8") as f:
        f.write(json.dumps(dict(entry, at=iso(now())), ensure_ascii=False) + "\n")


def history():
    out = []
    try:
        with open(HISTORY, encoding="utf-8") as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def live_launch_session():
    lk = read_json(LAUNCH, {}) or {}
    return lk.get("sessionId") if lk.get("sessionId") and not lk.get("endedAt") and alive(lk.get("launcherPid")) else None


def branch_state(repo, branch):
    if not branch_exists(repo, branch):
        return "gone"
    base = base_branch(repo)
    return "merged" if git(repo, "merge-base", "--is-ancestor", branch, base).returncode == 0 else "unmerged"


def all_tasks(r):
    out, infos = [], []
    for repo in projects():
        info = {"path": repo, "name": display_name(repo), "exists": os.path.isdir(repo), "proposalsOff": proposals_off(repo)}
        if info["exists"]:
            info["git"] = is_git(repo)
            lines, tasks = parse_backlog(repo)
            info["backlog"] = lines is not None
            for t in tasks:
                out.append(task_view(repo, t, r))
        infos.append(info)
    return out, infos


# ---------- commands ----------

def done_list(tasks):
    """The widget's done list: done tasks of the last DONE_LIST_DAYS days the owner hasn't cleared,
    newest first, at most DONE_LIST_MAX."""
    done = [t for t in tasks if t["status"] == "done" and not t["cleared"] and t.get("ageDays", 0) <= DONE_LIST_DAYS]
    done.sort(key=lambda t: t.get("ageDays", 0))
    return done[:DONE_LIST_MAX]


def cmd_list(a):
    r = ratio()
    tasks, infos = all_tasks(r)
    by_priority = lambda t: (t["priority"], t.get("added", ""))
    sessions = {}
    for h in history():
        if h.get("sessionId"):
            sessions[(h.get("project"), h.get("title"))] = h["sessionId"]
    for t in tasks:
        if t["status"] == "done":
            t["sessionId"] = sessions.get((t["project"], t["title"]))
    lk = read_lock()
    placed = set(manual_order())
    extra = {"all": tasks} if a.all else {}
    emit(dict(extra, **{
        "now": iso(now()),
        "projects": infos,
        "queue": [dict(t, placed=task_key(t) in placed) for t in ordered_queue([t for t in tasks if t["status"] == "open"])],
        "proposals": sorted([t for t in tasks if t["status"] == "proposed"], key=by_priority),
        "needsYou": [t for t in tasks if t["status"] == "blocked"
                     or (t["status"] == "done" and t.get("branchState") == "unmerged")],
        "done": done_list(tasks),
        "ratio": r, "config": config(), "status": status(),
        "lock": dict(lk, live=lock_is_live(lk)) if lk else None,
        "usage": read_json(USAGE, None),
        "launch": read_json(LAUNCH, None),
        "settings": dict(settings(), configured=os.path.exists(SETTINGS)),
    }))


def clear_done(repo, title, undo=False):
    """Marks one done task cleared from the done list (or brings it back). The section is the done one
    with this title — a title can come back as a new task once the old one is done."""
    lines, tasks = parse_backlog(repo)
    if lines is None:
        fail("no BACKLOG.md in " + repo)
    matches = [t for t in tasks if t["title"] == title.strip() and t["fields"].get("status") == "done"
               and bool(t["fields"].get("cleared")) == undo]
    if not matches:
        fail(("no cleared done task: " if undo else "no done task to clear: ") + title, project=repo)
    write_fields(repo, lines, matches[-1], {"cleared": "" if undo else today()})
    return {"project": repo, "title": matches[-1]["title"]}


def cmd_clear_done(a):
    """Clears done tasks from the widget's done list: `- cleared: <date>` on the task, which stays in
    BACKLOG.md (`--undo` brings it back). Branches, history and "waiting for you" are untouched. Only the
    owner tidies the list: never from an unattended run."""
    if os.environ.get("HARVEST_UNATTENDED"):
        fail("only the owner clears the done list")
    if a.all:
        if a.project or a.title or a.undo:
            fail("--all takes no project, title or --undo")
        cleared = [clear_done(t["project"], t["title"]) for t in done_list(all_tasks(ratio())[0])]
    elif a.project and a.title:
        cleared = [clear_done(os.path.abspath(a.project), a.title, a.undo)]
    else:
        fail("give a project and a title, or --all")
    emit({"ok": True, "undo": bool(a.undo), "cleared": cleared})


def cmd_settings(a):
    """Print the settings (defaults filled in; `configured` = the installer wrote them); with --set
    key=value, change them first. Only the owner changes them: never from an unattended run."""
    if a.set:
        if os.environ.get("HARVEST_UNATTENDED"):
            fail("unattended runs cannot change the settings")
        saved = read_json(SETTINGS, {}) or {}
        for kv in a.set:
            k, eq, v = kv.partition("=")
            if not eq or k not in DEFAULT_SETTINGS:
                fail("use --set <key>=<value>; keys: " + ", ".join(DEFAULT_SETTINGS))
            if k == "noProposals":
                fail('use `claude-harvest proposals "<project>" on|off`')
            if k == "models":
                try:
                    v = json.loads(v)
                except ValueError:
                    fail('models takes JSON, e.g. {"high": "opus"}')
                if not isinstance(v, dict) or set(v) - set(MODEL_BY_COMPLEXITY):
                    fail("models maps " + ", ".join(MODEL_BY_COMPLEXITY) + " to model names")
            elif k == "fallback":
                try:
                    v = json.loads(v)
                except ValueError:
                    fail('fallback takes JSON, e.g. {"fable": {"to": "opus", "atPct": 85}}')
                ok = isinstance(v, dict) and all(
                    isinstance(e, dict) and isinstance(e.get("to", ""), str)
                    and isinstance(e.get("atPct", 100), (int, float)) and 1 <= e.get("atPct", 100) <= 100
                    for e in v.values())
                if not ok:
                    fail('fallback maps a model to {"to": <model or "">, "atPct": 1–100}')
                v = {m.lower(): {"to": e.get("to", "").lower(), "atPct": e.get("atPct", 100)} for m, e in v.items()}
            elif k in ("fiveReserve", "weeklyReserve"):
                if not v.strip().isdigit() or not 0 <= int(v) <= 60:
                    fail(k + " takes a whole number of points, 0–60")
                v = int(v)
            elif k in ("emailDigest", "switchMidTask"):
                v = v.strip().lower() in ("1", "true", "yes", "on")
            elif k == "language" and v not in LANGUAGES:
                fail("language is one of " + ", ".join(LANGUAGES))
            saved[k] = v
        write_json(SETTINGS, saved)
    emit(dict(settings(), configured=os.path.exists(SETTINGS)))


def cmd_proposals(a):
    """`proposals "<project>" off`: no proposals for this project any more — its current ones are dropped,
    scans skip it, and `add --status proposed` there is refused. `on` undoes that (dropped ones stay dropped).
    Only the owner: never from an unattended run."""
    if os.environ.get("HARVEST_UNATTENDED"):
        fail("unattended runs cannot change which projects get proposals")
    repo = os.path.abspath(os.path.expanduser(a.project))
    saved = read_json(SETTINGS, {}) or {}
    current = [p for p in (saved.get("noProposals") or []) if os.path.realpath(os.path.expanduser(p)) != os.path.realpath(repo)]
    dropped = []
    if a.state == "off":
        current.append(repo)
        _, tasks = parse_backlog(repo) if os.path.isdir(repo) else (None, [])
        for t in tasks:
            if (t["fields"].get("status") or "open") == "proposed":
                set_fields(repo, t["title"], {"status": "dropped", "result": tr("no_proposals", today())})
                dropped.append(t["title"])
    saved["noProposals"] = current
    write_json(SETTINGS, saved)
    emit({"ok": True, "project": repo, "proposals": a.state, "dropped": dropped})


def cmd_queue_order(a):
    """`queue-order <key>…`: the owner's order for the queue, first to run first — keys are "<project>::<title>"
    of queued tasks (others are dropped). Queued tasks not named keep the automatic order after them.
    `--reset` forgets the owner's order. Only the owner: never from an unattended run."""
    if os.environ.get("HARVEST_UNATTENDED"):
        fail("unattended runs cannot reorder the queue")
    if a.reset:
        if os.path.exists(QUEUE_ORDER):
            os.remove(QUEUE_ORDER)
    else:
        tasks, _ = all_tasks(ratio())
        queued = {task_key(t) for t in tasks if t["status"] == "open"}
        keys = []
        for k in a.keys:
            if k in queued and k not in keys:
                keys.append(k)
        write_json(QUEUE_ORDER, {"keys": keys})
    tasks, _ = all_tasks(ratio())
    emit({"ok": True, "manual": bool(manual_order()),
          "queue": [task_key(t) for t in ordered_queue([t for t in tasks if t["status"] == "open"])]})


def cmd_set_status(a):
    repo = os.path.abspath(a.project)
    if a.status not in STATUSES:
        fail("status must be one of " + ", ".join(STATUSES))
    _, t = find_task(repo, a.title)
    current = t["fields"].get("status") or "open"
    if os.environ.get("HARVEST_UNATTENDED") and a.status == "open" and current != "open":
        fail("unattended runs cannot queue tasks; only the owner approves them")
    updates = {"status": a.status}
    if a.result is not None:
        updates["result"] = a.result
    elif a.status == "dropped" and current == "proposed":
        updates["result"] = tr("removed", today())
    if a.answer:
        # The task prompt carries the details, so the owner's answer to a blocked question goes there.
        answer = tr("owner_answer", today(), " ".join(a.answer.split()))
        details = t["fields"].get("details", "")
        updates["details"] = details + " · " + answer if details else answer
    set_fields(repo, a.title, updates)
    # The done list opens the conversation that finished each task: remember the session that
    # marked this one done (Claude Code gives its shell commands CLAUDE_CODE_SESSION_ID).
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if a.status == "done" and session_id:
        append_history({"project": repo, "projectName": display_name(repo), "title": t["title"],
                        "outcome": "marked-done", "sessionId": session_id})
    emit({"ok": True, "project": repo, "title": a.title, "from": current, "to": a.status})


def cmd_link_session(a):
    """Records which Claude Code session did a task, for the done list: tasks finished before the
    harvest recorded it, or by hand in a session that didn't go through set-status."""
    repo = os.path.abspath(a.project)
    _, t = find_task(repo, a.title)
    if not re.match(r"^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$", a.session_id):
        fail("session id must be a Claude Code session uuid")
    append_history({"project": repo, "projectName": display_name(repo), "title": t["title"],
                    "outcome": "linked", "sessionId": a.session_id})
    emit({"ok": True, "project": repo, "title": t["title"], "sessionId": a.session_id})


def cmd_add(a):
    repo = os.path.abspath(a.project)
    if not os.path.isdir(repo):
        fail("project folder does not exist: " + repo)
    status_value = a.status
    downgraded = False
    if os.environ.get("HARVEST_UNATTENDED") and status_value == "open":
        status_value, downgraded = "proposed", True
    if status_value not in ("open", "proposed"):
        fail("new tasks are open or proposed")
    if status_value == "proposed" and proposals_off(repo):
        fail("the owner turned proposals off for this project — don't record proposals here", proposalsOff=True)
    if a.complexity not in MODEL_BY_COMPLEXITY:
        fail("complexity must be low, medium or high")
    path = backlog_path(repo)
    if not os.path.exists(path):
        try:
            template = os.path.join(TEMPLATE_DIR, "BACKLOG.template.%s.md" % settings()["language"])
            with open(template, encoding="utf-8") as f:
                write_text(path, f.read())
        except OSError:
            write_text(path, "# Backlog\n")
    lines, tasks = parse_backlog(repo)
    title = a.title.strip().replace("\n", " ")
    if any(t["title"] == title and (t["fields"].get("status") or "open") not in ("done", "dropped") for t in tasks):
        fail("a task with this title is already in the backlog", project=repo, title=title)
    tokens = a.tokens or DEFAULT_TOKENS[a.complexity]
    block = ["", "## " + title, "- status: " + status_value, "- added: " + today(),
             "- priority: %d" % a.priority, "- complexity: " + a.complexity, "- tokens: %d" % tokens,
             "- details: " + a.details.strip().replace("\n", " "), "- result:"]
    text = "\n".join(lines).rstrip("\n") + "\n" + "\n".join(block) + "\n"
    write_text(path, text)
    registered = register(repo)
    emit({"ok": True, "project": repo, "title": title, "status": status_value,
          "downgradedToProposed": downgraded, "registered": registered})


def model_full(model, usage, st, s):
    """Whether `model` should give way: its own weekly quota (usage `scoped`, e.g. Fable) reached the owner's
    point for it, or a session hit that model's limit this week (usage.json can be minutes behind)."""
    lim = (st.get("limits") or {}).get("model:" + model)
    if lim and (parse_iso(lim.get("until")) or now()) > now():
        return True
    scoped = (usage or {}).get("scoped") or {}
    if str(scoped.get("label", "")).lower().startswith(model):
        at = (s["fallback"].get(model) or {}).get("atPct", 100)
        return float(scoped.get("pct") or 0) >= float(at)
    return False


def fallback_model(model, usage, st=None, s=None):
    """`model`, or the first model down its fallback chain that isn't full; None when the chain runs out."""
    s, st = s or settings(), st if st is not None else status()
    seen = set()
    while model and model_full(model, usage, st, s):
        seen.add(model)
        model = (s["fallback"].get(model) or {}).get("to") or None
        if model in seen:
            return None
    return model


def pick_model(complexity, usage, st=None):
    s = settings()
    return fallback_model(s["models"].get(complexity) or MODEL_BY_COMPLEXITY.get(complexity, "opus"), usage, st, s)


def limit_fallback(hit, model):
    """After a session ran into a usage limit: the model it goes on with, or None to stop it. Only a model's
    own quota leaves another model (and only with switchMidTask); the 5-hour window and the week are shared.
    The limit is recorded either way, so plan and pick_model keep to it until it resets."""
    if hit["kind"] == "auth":
        return None
    u, _ = load_usage()
    record_limit(hit, u)
    s = settings()
    if hit["kind"] != "model" or not s["switchMidTask"]:
        return None
    return fallback_model(hit.get("model") or model, u or {}, status(), s)


def cmd_plan(a):
    cfg, r, st = config(), ratio(), status()
    u, err = load_usage(a.usage_json)
    res = {"harvest": False, "reason": None, "final": True, "next": None, "deferred": [],
           "usage": u, "ratio": r, "config": cfg, "mode": a.mode}
    if not u:
        res["reason"] = "usage-unreadable: " + err
        emit(res)
    t = now()
    reset = parse_iso(u["weekly"].get("resetsAt"))
    if not reset:
        res["reason"] = "usage-unreadable: weekly reset time unknown"
        emit(res)
    hours_left = (reset - t).total_seconds() / 3600
    res["weeklyResetsInHours"] = round(hours_left, 2)
    if a.mode == "auto" and hours_left > cfg["leadHours"] + AUTO_SLACK_H:
        res["reason"] = "too-early"
        emit(res)
    if hours_left * 60 <= CUTOFF_GUARD_MIN:
        res["reason"] = "cutoff-near"
        emit(res)

    s = settings()
    weekly_room = 100 - float(u["weekly"]["pct"]) - float(s["weeklyReserve"])
    five_room = 100 - float(u["session"]["pct"]) - float(s["fiveReserve"])
    # A limit a session ran into counts as full until it resets, whatever a few-minutes-old usage.json says.
    if limit_active(st, "weekly"):
        weekly_room = min(weekly_room, 0)
    if limit_active(st, "five"):
        five_room = min(five_room, 0)
    weekly_budget = max(0, weekly_room) * r["weekly"]
    five_budget = max(0, five_room) * r["five"]
    budget = min(weekly_budget, five_budget)
    res.update({"weeklyRoom": round(weekly_room, 1), "fiveRoom": round(five_room, 1),
                "budgetTokens": int(budget), "limitedBy": "5h" if five_budget < weekly_budget else "weekly"})

    tasks, infos = all_tasks(r)
    only = set(a.only or [])
    candidates = [x for x in tasks if x["status"] == "open" and (not only or x["project"] + "::" + x["title"] in only)]
    candidates = ordered_queue(candidates)
    minutes_left = (reset - t).total_seconds() / 60
    deferred_budget = False
    for c in candidates:
        need = c["tokens"] * FIT_FACTOR
        duration = max(10, c["tokens"] / TOKENS_PER_MINUTE)
        if minutes_left - duration < CUTOFF_GUARD_MIN:
            res["deferred"].append({"project": c["project"], "title": c["title"], "why": "cutoff"})
            continue
        if need > budget:
            res["deferred"].append({"project": c["project"], "title": c["title"], "why": "budget"})
            deferred_budget = True
            continue
        model = pick_model(c["complexity"], u, st)
        if not model:
            res["deferred"].append({"project": c["project"], "title": c["title"], "why": "model-full"})
            continue
        if res["next"] is None:
            res["next"] = {"kind": "task", "project": c["project"], "projectName": c["projectName"],
                           "title": c["title"], "details": c["details"], "priority": c["priority"],
                           "complexity": c["complexity"], "tokens": c["tokens"], "model": model}
    if res["next"] is None and a.mode == "auto" and not only and st.get("scansThisRun", 0) < MAX_SCANS_PER_RUN:
        open_or_proposed = {x["project"] for x in tasks if x["status"] in ("open", "proposed")}
        scanned = set(st.get("scannedThisRun", []))
        for info in infos:
            if info.get("git") and info["path"] not in open_or_proposed and info["path"] not in scanned \
                    and not proposals_off(info["path"]):
                scan_tokens = estimate_tokens(info["path"], "scan")[0]
                if scan_tokens * FIT_FACTOR <= budget:
                    res["next"] = {"kind": "scan", "project": info["path"], "projectName": info["name"],
                                   "tokens": scan_tokens, "model": "sonnet"}
                break
    if res["next"]:
        res["harvest"] = True
        emit(res)
    if not candidates:
        res["reason"] = "queue-empty"
    elif deferred_budget:
        res["reason"] = "5h-full" if five_budget < weekly_budget else "weekly-full"
    elif any(d["why"] == "model-full" for d in res["deferred"]):
        res["reason"] = "model-full"
    else:
        res["reason"] = "cutoff-near"
    session_reset = parse_iso(u["session"].get("resetsAt"))
    if limit_active(st, "five"):
        session_reset = parse_iso(st["limits"]["five"].get("until"))
    if res["reason"] == "5h-full" and session_reset and session_reset + timedelta(minutes=30) < reset:
        res["final"] = False
    emit(res)


def cmd_begin(a):
    lk = read_lock()
    if lock_is_live(lk):
        fail("another harvest run is active", 3, lock=lk)
    u, _ = load_usage(a.usage_json)
    write_json(LOCK, {"pid": runner_pid(), "at": iso(now()), "mode": a.mode})
    st = status()
    cycle = cycle_id((u or {}).get("weekly", {}).get("resetsAt"))
    if cycle and (st.get("cycle") or {}).get("id") != cycle:
        st["cycle"] = {"id": cycle, "done": [], "blocked": [], "failed": [], "runs": 0}
    if st.get("cycle"):
        st["cycle"]["runs"] = st["cycle"].get("runs", 0) + 1
    st.update({"state": "running", "mode": a.mode, "runStartedAt": iso(now()), "current": None,
               "doneThisRun": [], "scansThisRun": 0, "scannedThisRun": [], "usageAtStart": u})
    save_status(st)
    emit({"ok": True, "status": st})


def ensure_worktrees_ignored(repo):
    """Keep `.claude/worktrees/` out of the owner's `git status` — locally, never in a committed file."""
    if git(repo, "check-ignore", "-q", ".claude/worktrees/x").returncode == 0:
        return
    common = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    if not common:
        return
    path = os.path.join(common, "info", "exclude")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write("\n# Claude Code worktrees (quota harvest)\n.claude/worktrees/\n")


def worktree_dir(repo, name):
    """Claude Code's own place for a session's worktree — the Claude app files it under the project."""
    return os.path.join(repo, ".claude", "worktrees", WORKTREE_PREFIX + name)


def start_task(repo, title, model, usage_json):
    _, t = find_task(repo, title)
    if (t["fields"].get("status") or "open") != "open":
        fail("only open tasks can be started")
    if not is_git(repo):
        fail("not a git repository: " + repo)
    base = base_branch(repo)
    ensure_worktrees_ignored(repo)
    # A task a usage limit stopped goes on from its branch; anything else starts a fresh one.
    resumed = paused_branch(t["fields"].get("result", ""))
    if resumed and branch_exists(repo, resumed) and not os.path.exists(worktree_dir(repo, resumed[len("backlog/"):])):
        slug, branch = resumed[len("backlog/"):], resumed
        path = worktree_dir(repo, slug)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        r = git(repo, "worktree", "add", path, branch)
    else:
        resumed = None
        stem = slugify(title, repo)
        slug, n = stem, 2
        while branch_exists(repo, "backlog/" + slug) or os.path.exists(worktree_dir(repo, slug)):
            slug, n = "%s-%d" % (stem, n), n + 1
        path, branch = worktree_dir(repo, slug), "backlog/" + slug
        os.makedirs(os.path.dirname(path), exist_ok=True)
        r = git(repo, "worktree", "add", "-b", branch, path, base)
    if r.returncode:
        fail("git worktree add failed: " + r.stderr.strip())
    u, _ = load_usage(usage_json)
    current = {"project": repo, "projectName": display_name(repo), "title": title, "slug": slug,
               "branch": branch, "base": base, "worktree": path, "model": model,
               "tokens": tokens_of(t["fields"].get("tokens"), t["fields"].get("complexity")),
               "details": t["fields"].get("details", ""), "priority": int_or(t["fields"].get("priority"), 2),
               "complexity": t["fields"].get("complexity") or "medium",
               "startedAt": iso(now()), "usageBefore": u, "resumed": bool(resumed)}
    st = status()
    st["current"] = current
    save_status(st)
    return current


def cmd_worktree(a):
    cur = start_task(os.path.abspath(a.project), a.title, a.model, a.usage_json)
    emit({"ok": True, "path": cur["worktree"], "branch": cur["branch"], "base": cur["base"], "slug": cur["slug"]})


def paused_branch(result):
    """The branch a task a usage limit stopped goes on from (its result says so), else None."""
    if not any(m in (result or "") for m in PAUSED_MARKERS):
        return None
    b = BRANCH_RE.search(result)
    return b.group(1) if b and b.group(1).startswith("backlog/") else None


def snapshot_worktree(path):
    """Commits what a session left uncommitted when a usage limit stopped it, so the next attempt goes on
    from it — removing the worktree would lose it. A local branch, never pushed: hooks are skipped."""
    if not os.path.isdir(path) or not git(path, "status", "--porcelain").stdout.strip():
        return False
    git(path, "add", "-A")
    who = [] if git(path, "config", "user.email").stdout.strip() else [
        "-c", "user.name=Quota Harvest", "-c", "user.email=quota-harvest@localhost"]
    return git(path, *(who + ["commit", "-q", "--no-verify", "-m",
                              "WIP: stopped at a usage limit (quota harvest)"])).returncode == 0


def remove_worktree(repo, path):
    if os.path.exists(path):
        git(repo, "worktree", "remove", "--force", path)
    if os.path.exists(path):
        shutil.rmtree(path, ignore_errors=True)
    git(repo, "worktree", "prune")


def finish_task(repo, title, outcome, summary, question, tokens, usage_json, session_id, tests=None):
    st = status()
    cur = st.get("current") or {}
    if cur.get("project") != repo or cur.get("title") != title:
        fail("finish-task does not match the task that was started", current=cur)
    branch, base = cur["branch"], cur["base"]
    if outcome == "paused":
        snapshot_worktree(cur["worktree"])
    commits = commits_ahead(repo, base, branch)
    summary = (summary or "").strip().replace("\n", " ")
    if outcome == "done" and commits == 0:
        outcome, summary = "failed", tr("no_commit")
    remove_worktree(repo, cur["worktree"])
    _, t = find_task(repo, title)
    previous = t["fields"].get("result", "")
    k = "%dk" % round((tokens or 0) / 1000.0)
    if outcome == "paused":
        # Not a failure: the quota ran out, not the task. It goes back to the queue, on from its branch.
        if commits:
            updates = {"status": "open", "result": tr("paused", today(), summary, branch)}
        else:
            git(repo, "branch", "-D", branch)
            updates = {"status": "open", "result": tr("paused_empty", today(), summary)}
    elif outcome == "done":
        updates = {"status": "done", "result": "%s · %s · %s · %s" % (today(), branch, summary, k)}
    elif outcome == "blocked":
        question = (question or summary or tr("needs_decision")).replace("\n", " ")
        if commits:
            updates = {"status": "blocked", "result": "%s · %s · %s" % (today(), question, branch)}
        else:
            git(repo, "branch", "-D", branch)
            updates = {"status": "blocked", "result": "%s · %s" % (today(), question)}
    else:
        if commits:
            git(repo, "branch", "-m", branch, "backlog-stopped/%s-%s" % (cur["slug"], today()))
        else:
            git(repo, "branch", "-D", branch)
        if any(m in previous for m in FAILED_MARKERS):
            updates = {"status": "blocked", "result": tr("failed_twice", today(), summary)}
        else:
            updates = {"status": "open", "result": tr("failed", today(), summary)}
    set_fields(repo, title, updates)
    after, _ = load_usage(usage_json)
    append_calibration(repo, cur["slug"], cur.get("model") or "", cur.get("tokens") or "",
                       tokens or 0, cur.get("usageBefore"), after)
    record = {"project": repo, "projectName": display_name(repo), "title": title,
              "outcome": outcome if outcome in ("done", "paused") else updates["status"],
              "branch": branch if outcome == "done" or (outcome == "blocked" and commits) else None,
              "summary": summary, "tokens": tokens or 0}
    append_history(dict(record, sessionId=session_id, tests=tests))
    st = status()
    st["doneThisRun"] = st.get("doneThisRun", []) + [record]
    if st.get("cycle"):
        key = {"done": "done", "blocked": "blocked", "paused": "paused"}.get(record["outcome"], "failed")
        st["cycle"].setdefault(key, []).append(record)
    st["current"] = None
    save_status(st)
    return {"ok": True, "outcome": record["outcome"], "commits": commits, "backlog": updates,
            "branch": record["branch"], "summary": summary}


def cmd_finish_task(a):
    emit(finish_task(os.path.abspath(a.project), a.title, a.outcome, a.summary, a.question,
                     a.tokens, a.usage_json, live_launch_session()))


def cmd_finish_scan(a):
    repo = os.path.abspath(a.project)
    st = status()
    st["scansThisRun"] = st.get("scansThisRun", 0) + 1
    st["scannedThisRun"] = st.get("scannedThisRun", []) + [repo]
    save_status(st)
    after, _ = load_usage(a.usage_json)
    append_calibration(repo, "proposal scan", "sonnet", estimate_tokens(repo, "scan")[0], a.tokens or 0,
                       st.get("usageAtStart"), after)
    emit({"ok": True, "scans": st["scansThisRun"]})


def end_run(reason, final, emailed, report=None):
    """Closes the run: its summary in status.lastRun, the state idle, the lock released."""
    st = status()
    done = st.get("doneThisRun", [])
    st["lastRun"] = {
        "startedAt": st.get("runStartedAt"), "finishedAt": iso(now()), "mode": st.get("mode"),
        "done": sum(1 for d in done if d["outcome"] == "done"),
        "blocked": sum(1 for d in done if d["outcome"] == "blocked"),
        "paused": sum(1 for d in done if d["outcome"] == "paused"),
        "failed": sum(1 for d in done if d["outcome"] not in ("done", "blocked", "paused")),
        "scans": st.get("scansThisRun", 0), "stopReason": reason, "final": final,
        "emailed": emailed, "report": report,
    }
    st.update({"state": "idle", "current": None})
    save_status(st)
    lk = read_lock()
    if lk and (not lk.get("pid") or lk.get("pid") == runner_pid() or not alive(lk.get("pid"))):
        os.remove(LOCK)
    return st["lastRun"]


def cmd_end(a):
    # "skipped": the owner has no digest email set up — not a missing email.
    emit({"ok": True, "lastRun": end_run(a.reason, a.final == "yes",
                                         None if a.emailed == "skipped" else a.emailed == "yes", a.report)})


def relocate_missing():
    moved = []
    lines = []
    try:
        with open(PROJECTS, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except OSError:
        return moved
    found = None
    changed = False
    for i, line in enumerate(lines):
        p = line.strip()
        if not p or p.startswith("#") or os.path.isdir(p):
            continue
        if found is None:
            r = subprocess.run(["mdfind", "-name", "BACKLOG.md"], capture_output=True, text=True)
            found = [os.path.dirname(x) for x in r.stdout.splitlines() if x.endswith("/BACKLOG.md")]
        matches = [d for d in found if os.path.basename(d) == os.path.basename(p) and d not in lines]
        if len(matches) == 1:
            lines[i] = matches[0]
            moved.append({"from": p, "to": matches[0]})
            changed = True
    if changed:
        write_text(PROJECTS, "\n".join(lines))
    return moved


def cmd_maintain(a):
    report = {"ok": True, "staleLock": False, "interrupted": False, "worktrees": [], "archived": [], "relocated": []}
    lk = read_lock()
    if lk and not lock_is_live(lk):
        os.remove(LOCK)
        report["staleLock"] = True
    st = status()
    if st.get("state") == "running" and not lock_is_live(read_lock()):
        st["lastRun"] = {"startedAt": st.get("runStartedAt"), "finishedAt": iso(now()), "mode": st.get("mode"),
                         "done": sum(1 for d in st.get("doneThisRun", []) if d["outcome"] == "done"),
                         "stopReason": "interrupted", "final": False, "emailed": False}
        st.update({"state": "idle", "current": None})
        save_status(st)
        report["interrupted"] = True
    if not lock_is_live(read_lock()):
        leftovers = []
        if os.path.isdir(WORKTREES):
            leftovers += [os.path.join(WORKTREES, x) for x in sorted(os.listdir(WORKTREES))]
        for repo in projects():
            if not is_git(repo):
                continue
            for line in git(repo, "worktree", "list", "--porcelain").stdout.splitlines():
                if line.startswith("worktree ") and "/.claude/worktrees/" + WORKTREE_PREFIX in line:
                    leftovers.append(line[len("worktree "):])
        for path in leftovers:
            if not os.path.isdir(path):
                continue
            slug = os.path.basename(path)
            if slug.startswith(WORKTREE_PREFIX):
                slug = slug[len(WORKTREE_PREFIX):]
            entry = {"worktree": path}
            common = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
            repo = os.path.dirname(common) if common.endswith("/.git") else None
            branch = git(path, "branch", "--show-current").stdout.strip()
            if repo and branch:
                ahead = commits_ahead(repo, base_branch(repo), branch)
                remove_worktree(repo, path)
                if ahead:
                    target = "backlog-stopped/%s-%s" % (slug, today())
                    git(repo, "branch", "-m", branch, target)
                    entry["kept"] = target
                else:
                    git(repo, "branch", "-D", branch)
                    entry["deleted"] = branch
            elif repo:
                remove_worktree(repo, path)
            else:
                shutil.rmtree(path, ignore_errors=True)
            report["worktrees"].append(entry)
    r = ratio()
    tasks, _ = all_tasks(r)
    for t in tasks:
        if t["status"] == "done" and t.get("branchState") == "unmerged" and t.get("ageDays", 0) >= ARCHIVE_AFTER_DAYS:
            target = t["branch"].replace("backlog/", "backlog-archive/", 1)
            if git(t["project"], "branch", "-m", t["branch"], target).returncode == 0:
                set_fields(t["project"], t["title"], {"result": t["result"].replace(t["branch"], target) + " · archived " + today()})
                report["archived"].append({"project": t["project"], "title": t["title"], "branch": target})
    report["relocated"] = relocate_missing()
    emit(report)


# ---------- launching and watching a run ----------

WORKDIR = os.path.expanduser(os.environ.get("HARVEST_WORKDIR") or settings()["workdir"])
TTY_LOG_CAP = 2 * 1024 * 1024
IDLE_CLOSE_MIN = 45
ANSI_RE = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[=>()][0-9A-Za-z]?")


def claude_bin():
    for p in (os.path.expanduser("~/.local/bin/claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
        if os.access(p, os.X_OK):
            return p
    return shutil.which("claude")


def transcript_path(session_id, workdir=WORKDIR):
    slug = re.sub(r"[^A-Za-z0-9]", "-", workdir)
    return os.path.join(os.path.expanduser("~/.claude/projects"), slug, session_id + ".jsonl")


def screen_text(raw):
    """Terminal output as plain text for matching: escapes and whitespace removed, lowercased."""
    return re.sub(rb"\s+", b"", ANSI_RE.sub(b"", raw)).decode("utf-8", "replace").lower()


def trust_choice(raw):
    """On Claude Code's "trust this folder" screen, which option the ❯ pointer is on ("yes"/"no"), else None."""
    text = screen_text(raw)
    if "itrustthisfolder" not in text:
        return None
    pointer = text.rfind("\u276f")
    if pointer < 0:
        return "no"
    return "yes" if text[pointer + 1:].startswith("yes") else "no"


def session_activity(transcript):
    """Latest write to the run's transcript or any of its subagents' transcripts."""
    latest = 0.0
    try:
        latest = os.path.getmtime(transcript)
    except OSError:
        pass
    for root, _, files in os.walk(os.path.splitext(transcript)[0]):
        for name in files:
            try:
                latest = max(latest, os.path.getmtime(os.path.join(root, name)))
            except OSError:
                pass
    return latest


def build_prompt(mode, only, test):
    s = "Run the harvest-quota skill (invoke it with the Skill tool) in %s mode. " % mode.upper()
    s += ("The Quota Harvest widget launched you unattended at the start of the harvest window before the weekly quota reset."
          if mode == "auto" else
          "The Quota Harvest widget launched you unattended because the owner pressed \"run now\".")
    if only:
        s += " Scope: only these tasks — pass each to every plan call as --only: " + " ".join('"%s"' % o for o in only) + "."
    else:
        s += " Scope: every queued (open) task."
    if test:
        s += " TEST LAUNCH: do everything except sending the email and the push notification."
    s += (" This is an interactive session the owner may be watching live in the Claude app. Nobody will answer"
          " questions: never wait for input. After `claude-harvest end`, write the three-line summary and stop —"
          " the launcher closes the session.")
    return s


HOLD_MAX_MIN = 60
MAX_SWITCHES = 3


def scan_limit(transcript, pos):
    """A usage-limit error Claude Code wrote into the transcript after byte `pos` (a synthetic assistant
    message, `isApiErrorMessage` with error "rate_limit") → (hit or None, the new position). Only the
    transcript counts: the terminal also shows the session's own tool output, which may quote such text."""
    try:
        with open(transcript, "rb") as f:
            f.seek(pos)
            chunk = f.read()
    except OSError:
        return None, pos
    whole = chunk.rfind(b"\n") + 1
    hit = None
    for line in chunk[:whole].splitlines():
        if b'"isApiErrorMessage"' not in line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("isApiErrorMessage") is True and d.get("error") == "authentication_failed":
            # Claude Code signed out ("Not logged in · Please run /login"): nothing can go on until the
            # owner signs in again — stop, like a shared limit, but nothing to wait out.
            hit = {"kind": "auth", "text": "authentication_failed", "at": d.get("timestamp") or iso(now())}
        elif d.get("isApiErrorMessage") is True and d.get("error") in ("rate_limit", "consent_unanswered"):
            content = (d.get("message") or {}).get("content")
            text = content if isinstance(content, str) else " ".join(
                x.get("text", "") for x in content or [] if isinstance(x, dict))
            kind = classify_limit(text)
            # Newer Claude Code asks, at a model's own limit, whether to go on with paid usage credits;
            # unanswered (nobody is there), it writes "consent_unanswered" — still that model's limit.
            model = re.search(r"\b(fable|opus|sonnet|haiku)\b", text.lower())
            if d.get("error") == "consent_unanswered" and model:
                kind = {"kind": "model", "model": model.group(1)}
            hit = dict(kind, text=text[:200], at=d.get("timestamp") or iso(now()))
    return hit, pos + whole


def run_session(cwd, name, prompt, model, effort, remote_control, max_minutes, linger,
                is_done=None, on_update=None, extra_env=None, session_id=None, unattended=True,
                on_limit=None, hold=None):
    """Runs one interactive Claude Code session in a hidden terminal and returns its record. Interactive
    (not `-p`) so the Claude app lists it — under its project, by cwd — and Remote Control lets the app and
    the phone follow it live. It is closed with /exit `linger` seconds after is_done() turns true, after
    IDLE_CLOSE_MIN without a transcript write, or at max_minutes; SIGTERM/SIGHUP are forwarded to it.

    A usage limit the session runs into goes to on_limit(hit, model): a model name → the session is closed
    and resumed on that model, its conversation intact (`switches`); None → it is closed, and `limitHit`
    says which limit. hold() true postpones that close (the coordinator waits for the task it started).
    Closing on a limit or on idleness goes by signal, never by keys: a limit can open a dialog whose
    choices include paid usage credits."""
    import fcntl
    import pty
    import select
    import signal
    import struct
    import termios
    import time
    import uuid

    claude = claude_bin()
    if not claude:
        fail("claude not found")
    session_id = session_id or str(uuid.uuid4())
    started = now()
    # A launch from inside another Claude session (a desktop chat) inherits its markers — among them
    # CLAUDE_CODE_CHILD_SESSION, which turns transcript saving off and hides the session from the Claude app.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("CLAUDE", "MCP_")) and k != "ANTHROPIC_BASE_URL"}
    env["TERM"] = "xterm-256color"
    if unattended:
        env["HARVEST_UNATTENDED"] = "1"
    env.update(extra_env or {})

    info = {"sessionId": session_id, "name": name, "startedAt": iso(started), "launcherPid": os.getpid(),
            "claudePid": None, "workdir": cwd, "remoteControl": remote_control, "model": model,
            "transcript": transcript_path(session_id, cwd), "bridgeSessionId": None,
            "endedAt": None, "exitStatus": None, "switches": []}
    proc = {}

    def spawn(text, resume):
        args = [claude] + (["--resume", info["sessionId"]] if resume else ["--session-id", info["sessionId"]])
        args += ["--name", name, "--permission-mode", "auto", "--model", info["model"], "--effort", effort]
        if remote_control:
            args += ["--remote-control", name]
        args.append(text)
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(cwd)
                os.execve(claude, args, env)
            finally:
                os._exit(127)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
        proc.update(pid=pid, fd=fd, at=time.time(), registry=os.path.expanduser("~/.claude/sessions/%d.json" % pid),
                    trust="watch", moves=0, tail=b"")
        info.update(claudePid=pid, bridgeSessionId=None)
        if on_update:
            on_update(info)

    def forward(signum, frame):
        try:
            os.killpg(proc["pid"], signal.SIGTERM)
        except OSError:
            pass

    log_path = os.path.join(HOME, "logs", "run-%s-%s.tty" % (datetime.now().strftime("%Y%m%d-%H%M%S"), session_id[:8]))
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    log = open(log_path, "wb")
    written = [0]

    def pump(timeout):
        """Reads the terminal for up to `timeout` seconds; False once it has closed."""
        ready, _, _ = select.select([proc["fd"]], [], [], timeout)
        if proc["fd"] not in ready:
            return True
        try:
            data = os.read(proc["fd"], 65536)
        except OSError:
            data = b""
        if not data:
            return False
        if written[0] < TTY_LOG_CAP:
            log.write(data[:TTY_LOG_CAP - written[0]])
            written[0] += len(data)
        proc["tail"] = (proc["tail"] + data)[-6000:]
        # A new folder (each task's worktree) opens on "trust this folder?" with "No, exit"
        # preselected: move the pointer until it is on "Yes, I trust this folder", then confirm.
        if proc["trust"] != "done" and time.time() - proc["at"] < 120:
            choice = trust_choice(proc["tail"][-1500:])
            if choice == "yes":
                time.sleep(0.3)
                os.write(proc["fd"], b"\r")
                proc["trust"] = "done"
            elif choice == "no" and proc["moves"] < 3:
                time.sleep(0.5)
                os.write(proc["fd"], b"\x1b[B")
                proc["moves"] += 1
                proc["tail"] = b""
        return True

    def close():
        """Ends the running claude by signal — SIGKILL after 15 s — reading its terminal meanwhile so it can
        exit; returns its exit status."""
        forward(None, None)
        give_up = time.time() + 15
        while True:
            done, code = os.waitpid(proc["pid"], os.WNOHANG)
            if done == proc["pid"]:
                break
            if time.time() > give_up:
                try:
                    os.killpg(proc["pid"], signal.SIGKILL)
                except OSError:
                    pass
                code = os.waitpid(proc["pid"], 0)[1]
                break
            if not pump(0.2):
                time.sleep(0.2)
        try:
            os.close(proc["fd"])
        except OSError:
            pass
        return code

    spawn(prompt, False)
    old_term = signal.signal(signal.SIGTERM, forward)
    old_hup = signal.signal(signal.SIGHUP, forward)
    registry_checked = activity_checked = limit_checked = 0.0
    limit_pos, hit, held_since = 0, None, None
    ended_at = exit_sent_at = None
    deadline = time.time() + max_minutes * 60
    exit_code = None
    while True:
        open_ = pump(1.0)
        done, code = os.waitpid(proc["pid"], os.WNOHANG)
        if done == proc["pid"]:
            exit_code = code
            break
        if not open_:
            exit_code = close()
            break
        if not info["bridgeSessionId"] and time.time() - registry_checked > 2:
            registry_checked = time.time()
            reg = read_json(proc["registry"], {}) or {}
            # A resumed session normally keeps its id; should Claude Code start a copy, follow the copy.
            if reg.get("sessionId") and reg["sessionId"] != info["sessionId"]:
                info.update(sessionId=reg["sessionId"], transcript=transcript_path(reg["sessionId"], cwd))
                limit_pos = 0
            if remote_control and reg.get("bridgeSessionId"):
                info["bridgeSessionId"] = reg["bridgeSessionId"]
                if on_update:
                    on_update(info)
        finished = bool(is_done and is_done(started))
        if finished and exit_sent_at is None:
            ended_at = ended_at or time.time()
            if time.time() - ended_at >= linger:
                os.write(proc["fd"], b"/exit\r")
                exit_sent_at = time.time()
        if on_limit and not finished and exit_sent_at is None and time.time() - limit_checked > 5:
            limit_checked = time.time()
            if hit is None:
                hit, limit_pos = scan_limit(info["transcript"], limit_pos)
            if hit:
                held_since = held_since or time.time()
                if hold and time.time() - held_since < HOLD_MAX_MIN * 60 and hold():
                    continue
                nxt = on_limit(hit, info["model"])
                code = close()
                if nxt and nxt != info["model"] and len(info["switches"]) < MAX_SWITCHES:
                    info["switches"].append({"from": info["model"], "to": nxt, "at": iso(now()), "limit": hit.get("text")})
                    previous, info["model"] = info["model"], nxt
                    hit = held_since = None
                    spawn(fill_template("continue-prompt.md", {"from model": previous.capitalize(),
                                                              "to model": nxt.capitalize()}), True)
                    continue
                info["limitHit"] = hit
                exit_code = code
                break
        # Safety net: a session nobody and nothing has written to for a long time (the owner stopped it
        # from the Claude app and left, or it's stuck on a question) is closed, so it can't hold the
        # lock for hours; `maintain` then returns its task to the queue.
        if is_done and exit_sent_at is None and time.time() - activity_checked > 30:
            activity_checked = time.time()
            last = max(session_activity(info["transcript"]), proc["at"])
            if time.time() - last > IDLE_CLOSE_MIN * 60 and not (hold and hold()):
                info["closedIdle"] = True
                exit_code = close()
                break
        if exit_sent_at and time.time() - exit_sent_at > 30:
            forward(None, None)
        if time.time() > deadline:
            forward(None, None)
            deadline = time.time() + 30
    log.close()
    signal.signal(signal.SIGTERM, old_term)
    signal.signal(signal.SIGHUP, old_hup)
    info.update(endedAt=iso(now()), exitStatus=exit_code, ttyLog=log_path)
    if on_update:
        on_update(info)
    return info


def checkout_state(repo):
    """The owner's checkout: the branch that is out, and whether tracked files have uncommitted changes."""
    current = git(repo, "branch", "--show-current").stdout.strip()
    # BACKLOG.md is the engine's own file (it records every result), so its edits aren't the owner's work.
    changed = [l for l in git(repo, "status", "--porcelain", "--untracked-files=no").stdout.splitlines()
               if l[3:].strip('"') != "BACKLOG.md"]
    return current, bool(changed)


def branch_brief(repo, branch):
    """A finished task's branch at a glance, without touching anything: what it changes, whether it still
    merges cleanly into the main branch, and whether the owner's checkout is free to take it."""
    base = base_branch(repo)
    files = [f for f in git(repo, "diff", "--name-only", "%s...%s" % (base, branch)).stdout.splitlines() if f]
    behind = git(repo, "rev-list", "--count", "%s..%s" % (branch, base)).stdout.strip()
    clean = git(repo, "merge-tree", "--write-tree", base, branch).returncode == 0
    current, dirty = checkout_state(repo)
    return {"base": base, "files": files[:12], "fileCount": len(files),
            "stat": git(repo, "diff", "--shortstat", "%s...%s" % (base, branch)).stdout.strip(),
            "baseMovedBy": int(behind or 0), "mergesCleanly": clean,
            "checkout": {"branch": current, "uncommittedChanges": dirty},
            "readyToMerge": clean and current == base and not dirty}


def cmd_brief(a):
    """What the harvest left waiting for the owner, oldest first, compact enough to read instead of exploring
    the repositories: every unmerged harvest branch (with branch_brief) and every blocked question."""
    tasks, _ = all_tasks(ratio())
    tests = {}
    for h in history():
        if h.get("tests"):
            tests[(h.get("project"), h.get("title"))] = h["tests"]
    items = []
    for t in tasks:
        item = {k: t.get(k) for k in ("project", "projectName", "title", "status", "ageDays")}
        if t["status"] == "done" and t.get("branchState") == "unmerged":
            item.update(summary=t.get("summary"), branch=t["branch"], tests=tests.get((t["project"], t["title"])))
            item.update(branch_brief(t["project"], t["branch"]))
        elif t["status"] == "blocked":
            item.update(question=t.get("question"), details=t.get("details"))
        else:
            continue
        items.append(item)
    items.sort(key=lambda i: -(i.get("ageDays") or 0))
    emit({"count": len(items), "items": items})


def cmd_merge(a):
    """Merges a finished task's branch into the project's main branch and deletes it — on the owner's word
    only, and only when nothing of theirs is in the way: the checkout is on the main branch with no
    uncommitted changes, and the branch merges without conflicts. Refuses otherwise, touching nothing."""
    repo = os.path.abspath(a.project)
    _, t = find_task(repo, a.title)
    v = task_view(repo, t, ratio())
    branch = v.get("branch")
    if v["status"] != "done" or not branch:
        fail("only a done task with a harvest branch can be merged", project=repo, title=v["title"])
    if v.get("branchState") != "unmerged":
        fail("the branch is not waiting to be merged (%s)" % v.get("branchState"), branch=branch)
    base = base_branch(repo)
    current, dirty = checkout_state(repo)
    if current != base:
        fail("the project's checkout is on %s, not %s" % (current or "a detached commit", base), branch=branch,
             inTheWay="checkout-branch")
    if dirty:
        fail("the project's checkout has uncommitted changes", branch=branch, inTheWay="uncommitted-changes")
    if git(repo, "merge-tree", "--write-tree", base, branch).returncode != 0:
        fail("the branch conflicts with %s and needs updating first" % base, branch=branch, inTheWay="conflicts")
    m = git(repo, "merge", "--no-edit", branch)
    if m.returncode != 0:
        git(repo, "merge", "--abort")
        fail("the merge failed and was undone: " + (m.stderr or m.stdout).strip()[:300], branch=branch)
    head = git(repo, "rev-parse", "--short", "HEAD").stdout.strip()
    git(repo, "branch", "-d", branch)
    set_fields(repo, v["title"], {"result": v["result"] + " · merged " + today()})
    emit({"ok": True, "project": repo, "title": v["title"], "branch": branch, "base": base, "head": head})


TALK_TOPICS = {"waiting": ("talk_name", "talk-prompt.md"), "onboard": ("onboard_name", "onboard-prompt.md")}


def cmd_talk(a):
    """A conversation with the owner, who is present: an interactive session in the harvest folder, live in the
    Claude app, closed after IDLE_CLOSE_MIN without activity. --topic waiting (default): what the harvest left
    waiting for them. --topic onboard: getting started after the install — finds their projects and records
    first proposals. One at a time — while one is open, this reports it instead of starting another."""
    t = read_json(TALK, {}) or {}
    if t.get("sessionId") and not t.get("endedAt") and alive(t.get("launcherPid")):
        emit(dict(t, reused=True))
        return
    os.makedirs(WORKDIR, exist_ok=True)
    name_key, template = TALK_TOPICS[a.topic]
    name = tr(name_key, datetime.now().strftime("%d.%m %H:%M"))
    prompt = fill_template(template, {})
    info = run_session(WORKDIR, name, prompt, a.model, a.effort, True, a.max_minutes, 0,
                       is_done=lambda started: False, on_update=lambda i: write_json(TALK, dict(i, topic=a.topic)),
                       unattended=False)
    emit(info)


CLAUDE_PROJECTS = os.path.expanduser("~/.claude/projects")


def transcript_cwd(path, max_lines=60):
    """The working folder a Claude Code transcript was recorded in (its entries carry `cwd`)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i >= max_lines:
                    break
                if '"cwd"' not in line:
                    continue
                try:
                    cwd = json.loads(line).get("cwd")
                except ValueError:
                    continue
                if cwd:
                    return cwd
    except OSError:
        pass
    return None


def cmd_discover(a):
    """The git projects the owner actually works in, from Claude Code's history: each transcript folder's newest
    transcript names its working folder; worktrees fold into their project; the harvest folder and folders that
    are gone or not git repositories are left out. Newest activity first, with whether each is registered."""
    found = {}
    registered = {os.path.realpath(p) for p in projects()}
    workdir = os.path.realpath(WORKDIR)
    try:
        folders = [os.path.join(CLAUDE_PROJECTS, d) for d in os.listdir(CLAUDE_PROJECTS)]
    except OSError:
        folders = []
    for folder in folders:
        try:
            transcripts = [os.path.join(folder, n) for n in os.listdir(folder) if n.endswith(".jsonl")]
        except OSError:
            continue
        if not transcripts:
            continue
        transcripts.sort(key=lambda t: os.path.getmtime(t), reverse=True)
        cwd = next((c for c in (transcript_cwd(t) for t in transcripts[:3]) if c), None)
        if not cwd or not os.path.isdir(cwd):
            continue
        top = git(cwd, "rev-parse", "--show-toplevel")
        if top.returncode != 0:
            continue
        repo = top.stdout.strip()
        common = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
        if common.returncode == 0 and os.path.basename(common.stdout.strip()) == ".git":
            repo = os.path.dirname(common.stdout.strip())  # a worktree counts as its project
        if os.path.realpath(repo) == workdir or os.path.realpath(repo).startswith(workdir + os.sep):
            continue
        last = os.path.getmtime(transcripts[0])
        entry = found.setdefault(repo, {"path": repo, "name": display_name(repo), "sessions": 0, "lastActivity": 0})
        entry["sessions"] += len(transcripts)
        entry["lastActivity"] = max(entry["lastActivity"], last)
    rows = sorted(found.values(), key=lambda e: -e["lastActivity"])[:a.limit]
    for r in rows:
        r["lastActivity"] = iso(datetime.fromtimestamp(r["lastActivity"], timezone.utc))
        r["registered"] = os.path.realpath(r["path"]) in registered
        r["hasBacklog"] = os.path.exists(os.path.join(r["path"], "BACKLOG.md"))
    emit({"projects": rows})


def cmd_launch(a):
    """The harvest's coordinating session, in the harvest folder; each task then gets its own session in its
    project (run-task). Closed once the run has called `end`."""
    os.makedirs(a.workdir, exist_ok=True)
    label = tr("mode_auto") if a.mode == "auto" else tr("mode_manual")
    name = a.name or tr("run_name", datetime.now().strftime("%d.%m %H:%M"), label)
    prompt = a.prompt or build_prompt(a.mode, a.only or [], a.test)

    def run_ended(started):
        cur = status()
        finished = parse_iso((cur.get("lastRun") or {}).get("finishedAt"))
        return cur.get("state") == "idle" and finished is not None and finished >= started

    # launch.json has one writer, this launcher; status.json belongs to the run itself.
    def record(info):
        write_json(LAUNCH, dict(info, mode=a.mode))

    def task_running():
        """A task session the coordinator started is still at work (or being recorded): closing the coordinator
        now would take it down too, so a limit waits for it — the task stops at the same limit by itself."""
        cur = status().get("current") or {}
        return bool(cur) and (alive(cur.get("claudePid")) or alive(cur.get("launcherPid")))

    info = run_session(a.workdir, name, prompt, a.model, a.effort, a.remote_control, a.max_minutes, a.linger,
                       is_done=run_ended if a.auto_exit else None, on_update=record,
                       on_limit=limit_fallback, hold=task_running)
    hit = info.get("limitHit")
    if hit and status().get("state") == "running":
        # The coordinator itself ran out: the run ends here, saying why, so the widget's next pulse follows
        # once the 5-hour window resets (a stalled run would read as "interrupted" and end the chain).
        s = settings()
        weekly = hit["kind"] == "weekly"
        reason = "signed-out" if hit["kind"] == "auth" else "weekly-full" if weekly else "5h-full"
        info["lastRun"] = end_run(reason, weekly, False if s["emailDigest"] and s["email"] else None)
    emit(dict(info, mode=a.mode, ok=True))


def transcript_tokens(transcript):
    """Tokens a session used — its own turns and its subagents', each API message counted once."""
    total, seen = 0, set()
    files = [transcript]
    for root, _, names in os.walk(os.path.splitext(transcript)[0]):
        files += [os.path.join(root, n) for n in names if n.endswith(".jsonl")]
    for path in files:
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    msg = d.get("message") or {}
                    if d.get("type") != "assistant" or not isinstance(msg, dict):
                        continue
                    key = msg.get("id") or d.get("uuid")
                    if key in seen:
                        continue
                    seen.add(key)
                    u = msg.get("usage") or {}
                    total += sum(int(u.get(k) or 0) for k in ("input_tokens", "output_tokens",
                                                               "cache_creation_input_tokens",
                                                               "cache_read_input_tokens"))
        except OSError:
            pass
    return total


LANGUAGE_NAMES = {"he": "Hebrew", "en": "English"}


# The texts the owner may rewrite (Settings → Texts). The defaults stay where the installer put them; a
# customized text lives in PROMPTS_DIR (one writer: `prompts --set`, the owner only) and wins. `fills` are
# the placeholders the engine fills in — a customized text must keep them — and `keeps` the lines the
# harvest depends on (without the task-report step, no task could ever finish).
PROMPTS_DIR = os.path.join(HOME, "prompts")
PROMPTS = {
    "task": {"file": "task-agent-prompt.md", "keeps": ["claude-harvest task-report"],
             "fills": ["project path", "worktree path", "branch", "base", "title", "priority", "complexity",
                       "tokens", "details"]},
    "scan": {"file": "scan-agent-prompt.md", "fills": ["project path"], "keeps": ["claude-harvest task-report"]},
    "talk": {"file": "talk-prompt.md", "fills": [], "keeps": []},
    "onboard": {"file": "onboard-prompt.md", "fills": [], "keeps": []},
    # Read by the coordinator itself (the skill says so), whole.
    "digest": {"file": "digest-email.md", "fills": [], "keeps": [], "whole": True},
    "continue": {"file": "continue-prompt.md", "fills": ["from model", "to model"], "keeps": [],
                 "builtin": "[Quota harvest] The <from model> quota ran out in the middle of your work, so this session"
                            " goes on with <to model>. Continue exactly where you stopped (if you were changing files,"
                            " look at `git status` first) and finish as you were originally instructed."},
}


def default_prompt(key):
    p = PROMPTS[key]
    if "builtin" in p:
        return p["builtin"]
    with open(os.path.join(SKILL_REFS, p["file"]), encoding="utf-8") as f:
        text = f.read()
    if p.get("whole"):
        return text
    return text.split("```", 2)[1].strip("\n") if text.count("```") >= 2 else text


def custom_prompt_path(key):
    return os.path.join(PROMPTS_DIR, PROMPTS[key]["file"])


def prompt_text(key):
    """The text in force: the owner's version when there is one, else the default."""
    try:
        with open(custom_prompt_path(key), encoding="utf-8") as f:
            text = f.read()
        if text.strip():
            return text
    except OSError:
        pass
    return default_prompt(key)


def prompt_problems(key, text):
    p = PROMPTS[key]
    return (["<%s>" % k for k in p["fills"] if "<%s>" % k not in text]
            + [k for k in p["keeps"] if k not in text])


def fill_template(name, values):
    """A harvest prompt (the text between the ``` fences of a skill reference file, or the owner's version
    of it), with its <placeholders> filled — <owner language> always, from the settings."""
    s = settings()
    values = dict({"owner language": LANGUAGE_NAMES[s["language"]], "owner name": s["ownerName"] or "the owner"}, **values)
    key = next((k for k, p in PROMPTS.items() if p["file"] == name), None)
    if key:
        body = prompt_text(key)
    else:
        with open(os.path.join(SKILL_REFS, name), encoding="utf-8") as f:
            text = f.read()
        body = text.split("```", 2)[1].strip("\n") if text.count("```") >= 2 else text
    for k, value in values.items():
        body = body.replace("<%s>" % k, str(value))
    return body


def cmd_prompts(a):
    """The texts the owner may rewrite: each one's default, the text in force and what it must keep.
    --set <name> --file <path>: save the owner's version (refused when it drops a placeholder the engine
    fills or a line the harvest needs). --reset <name>: back to the default. Only the owner: never from an
    unattended run — an agent must not rewrite its own instructions."""
    if a.set or a.reset:
        if os.environ.get("HARVEST_UNATTENDED"):
            fail("unattended runs cannot change the harvest's texts")
        key = a.set or a.reset
        if key not in PROMPTS:
            fail("unknown text; one of " + ", ".join(PROMPTS))
        if a.reset:
            try:
                os.remove(custom_prompt_path(key))
            except OSError:
                pass
        else:
            if not a.file:
                fail("--set needs --file <path>")
            with open(a.file, encoding="utf-8") as f:
                text = f.read()
            missing = prompt_problems(key, text)
            if missing:
                fail("the text must keep: " + ", ".join(missing), missing=missing)
            if text.strip() == default_prompt(key).strip():
                try:
                    os.remove(custom_prompt_path(key))
                except OSError:
                    pass
            else:
                write_text(custom_prompt_path(key), text)
    out = []
    for key, p in PROMPTS.items():
        try:
            default = default_prompt(key)
        except OSError:
            continue
        out.append({"name": key, "file": p["file"], "default": default, "text": prompt_text(key),
                    "custom": os.path.exists(custom_prompt_path(key)),
                    "keeps": ["<%s>" % k for k in p["fills"]] + p["keeps"]})
    emit({"ok": True, "prompts": out, "folder": PROMPTS_DIR})


def update_current(extra):
    st = status()
    if st.get("current") is not None:
        st["current"].update(extra)
        save_status(st)


def cmd_run_task(a):
    """One task, start to finish: a worktree inside its project, a session there named "Harvest · <title>" (in the owner's language) that
    does the task and reports with task-report, then the result recorded (backlog, branch, calibration,
    history). Takes minutes — run it in the background and wait for it."""
    import uuid
    repo = os.path.abspath(a.project)
    cur = start_task(repo, a.title, a.model, a.usage_json)
    session_id = str(uuid.uuid4())
    os.makedirs(TASK_RESULTS, exist_ok=True)
    result_path = os.path.join(TASK_RESULTS, session_id + ".json")
    prompt = fill_template("task-agent-prompt.md", {
        "project path": repo, "worktree path": cur["worktree"], "branch": cur["branch"], "base": cur["base"],
        "title": a.title, "priority": cur["priority"], "complexity": cur["complexity"],
        "tokens": cur["tokens"], "details": cur["details"]})
    if cur.get("resumed"):
        prompt += ("\n\nAn earlier attempt at this task stopped at a usage limit. Its work is already on this branch"
                   " (`git log %s..HEAD`; the last commit may be a WIP snapshot the harvest made of uncommitted"
                   " changes). Go on from there instead of starting over." % cur["base"])
    effort = "high" if cur["complexity"] == "high" else "medium"

    def track(info):
        update_current({"sessionId": info["sessionId"], "sessionName": info["name"],
                        "bridgeSessionId": info["bridgeSessionId"], "claudePid": info["claudePid"],
                        "launcherPid": info["launcherPid"],
                        "model": "→".join([info["switches"][0]["from"]] + [x["to"] for x in info["switches"]])
                        if info["switches"] else info["model"]})

    info = run_session(cur["worktree"], tr("task_name", a.title), prompt, a.model, effort, True, a.max_minutes, 10,
                       is_done=lambda started: os.path.exists(result_path), on_update=track,
                       extra_env={"HARVEST_TASK_RESULT": result_path}, session_id=session_id,
                       on_limit=limit_fallback)
    res = read_json(result_path, None)
    if not res and info.get("limitHit"):
        res = {"status": "paused", "summary": limit_label(info["limitHit"])}
    res = res or {"status": "failed", "summary": tr("no_report")}
    stats = session_stats(info["transcript"])
    record_session(repo, cur["complexity"], stats)
    tokens = stats["total"]
    out = finish_task(repo, a.title, res.get("status", "failed"), res.get("summary"), res.get("question"),
                      tokens, a.usage_json, info["sessionId"], tests=res.get("tests"))
    emit(dict(out, sessionId=info["sessionId"], sessionName=info["name"], tokens=tokens, tests=res.get("tests"),
              question=res.get("question"), closedIdle=info.get("closedIdle", False),
              switches=info["switches"], limitHit=info.get("limitHit")))


def cmd_run_scan(a):
    """A proposal scan as its own read-only session in the project ("Harvest · proposal scan"), in a throwaway
    detached worktree; the proposals it records wait for the owner's approval."""
    import uuid
    repo = os.path.abspath(a.project)
    if not is_git(repo):
        fail("not a git repository: " + repo)
    ensure_worktrees_ignored(repo)
    path = worktree_dir(repo, "scan-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    r = git(repo, "worktree", "add", "--detach", path, base_branch(repo))
    if r.returncode:
        fail("git worktree add failed: " + r.stderr.strip())
    session_id = str(uuid.uuid4())
    os.makedirs(TASK_RESULTS, exist_ok=True)
    result_path = os.path.join(TASK_RESULTS, session_id + ".json")
    prompt = fill_template("scan-agent-prompt.md", {"project path": repo})
    info = run_session(path, tr("scan_name"), prompt, "sonnet", "medium", True, a.max_minutes, 10,
                       is_done=lambda started: os.path.exists(result_path),
                       extra_env={"HARVEST_TASK_RESULT": result_path}, session_id=session_id,
                       on_limit=limit_fallback)
    remove_worktree(repo, path)
    stats = session_stats(info["transcript"])
    record_session(repo, "scan", stats)
    tokens = stats["total"]
    st = status()
    st["scansThisRun"] = st.get("scansThisRun", 0) + 1
    st["scannedThisRun"] = st.get("scannedThisRun", []) + [repo]
    save_status(st)
    after, _ = load_usage(a.usage_json)
    append_calibration(repo, "proposal scan", "sonnet", estimate_tokens(repo, "scan")[0], tokens,
                       st.get("usageAtStart"), after)
    res = read_json(result_path, None) or {}
    emit({"ok": True, "sessionId": session_id, "tokens": tokens, "summary": res.get("summary"),
          "scans": st["scansThisRun"]})


def cmd_task_report(a):
    """The last step of a task or scan session: its result, for the harvest to record."""
    path = os.environ.get("HARVEST_TASK_RESULT")
    if not path:
        fail("task-report runs only inside a harvest task session")
    write_json(path, {"status": a.status, "summary": a.summary, "question": a.question,
                      "tests": a.tests, "at": iso(now())})
    emit({"ok": True, "status": a.status})


def cmd_watch(a):
    """Follows a run's transcript in readable form (the newest launch unless a session id is given)."""
    import time
    launch = read_json(LAUNCH, {}) or {}
    sid = a.session or launch.get("sessionId")
    if not sid:
        fail("no harvest run has been launched yet")
    path = transcript_path(sid, launch.get("workdir") or WORKDIR)
    print(tr("watch_title", launch.get("name") or sid, path), flush=True)
    for _ in range(60):
        if os.path.exists(path):
            break
        time.sleep(1)
    if a.once:
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    describe_event(line)
        except OSError:
            print(tr("no_transcript"))
        return
    pos, idle_since = 0, None
    while True:
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
        except OSError:
            chunk = ""
        for line in chunk.splitlines():
            describe_event(line)
        running = lock_is_live(read_lock()) or status().get("state") == "running"
        if chunk or running:
            idle_since = None
        else:
            idle_since = idle_since or time.time()
            if time.time() - idle_since > 20:
                print(tr("run_ended"), flush=True)
                return
        time.sleep(1)


def describe_event(line):
    try:
        d = json.loads(line)
    except ValueError:
        return
    msg = d.get("message") or {}
    stamp = (d.get("timestamp") or "")[11:19]
    sub = " ↳" if d.get("isSidechain") else ""
    if d.get("type") == "assistant":
        for b in msg.get("content") or []:
            if b.get("type") == "text" and b.get("text", "").strip():
                print("%s%s 💬 %s" % (stamp, sub, b["text"].strip()[:600]), flush=True)
            elif b.get("type") == "tool_use":
                inp = b.get("input") or {}
                what = inp.get("command") or inp.get("description") or inp.get("skill") or inp.get("file_path") or ""
                print("%s%s ▸ %s  %s" % (stamp, sub, b.get("name"), str(what).replace("\n", " ")[:160]), flush=True)


def main():
    ap = argparse.ArgumentParser(prog="harvest.py", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list")
    p.add_argument("--all", action="store_true", help="also every task of every project, under \"all\"")
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("clear-done")
    p.add_argument("project", nargs="?"); p.add_argument("title", nargs="?")
    p.add_argument("--undo", action="store_true"); p.add_argument("--all", action="store_true")
    p.set_defaults(fn=cmd_clear_done)

    p = sub.add_parser("queue-order")
    p.add_argument("keys", nargs="*", metavar="PROJECT::TITLE")
    p.add_argument("--reset", action="store_true")
    p.set_defaults(fn=cmd_queue_order)

    p = sub.add_parser("proposals")
    p.add_argument("project"); p.add_argument("state", choices=("on", "off"))
    p.set_defaults(fn=cmd_proposals)

    p = sub.add_parser("settings")
    p.add_argument("--set", action="append", metavar="KEY=VALUE")
    p.set_defaults(fn=cmd_settings)

    p = sub.add_parser("prompts")
    p.add_argument("--set", metavar="NAME"); p.add_argument("--file")
    p.add_argument("--reset", metavar="NAME")
    p.set_defaults(fn=cmd_prompts)

    p = sub.add_parser("set-status")
    p.add_argument("project"); p.add_argument("title"); p.add_argument("status")
    p.add_argument("--result")
    p.add_argument("--answer", help="the owner's answer to a blocked question, appended to details")
    p.set_defaults(fn=cmd_set_status)

    sub.add_parser("brief").set_defaults(fn=cmd_brief)

    p = sub.add_parser("merge")
    p.add_argument("project"); p.add_argument("title")
    p.set_defaults(fn=cmd_merge)

    p = sub.add_parser("discover")
    p.add_argument("--limit", type=int, default=20)
    p.set_defaults(fn=cmd_discover)

    p = sub.add_parser("talk")
    p.add_argument("--topic", choices=sorted(TALK_TOPICS), default="waiting")
    p.add_argument("--model", default="opus")
    p.add_argument("--effort", default="medium")
    p.add_argument("--max-minutes", type=int, default=240)
    p.set_defaults(fn=cmd_talk)

    p = sub.add_parser("link-session")
    p.add_argument("project"); p.add_argument("title"); p.add_argument("session_id")
    p.set_defaults(fn=cmd_link_session)

    p = sub.add_parser("add")
    p.add_argument("project")
    p.add_argument("--title", required=True); p.add_argument("--details", required=True)
    p.add_argument("--priority", type=int, default=2, choices=(1, 2, 3))
    p.add_argument("--complexity", default="low"); p.add_argument("--tokens", type=int)
    p.add_argument("--status", default="open")
    p.set_defaults(fn=cmd_add)

    p = sub.add_parser("plan")
    p.add_argument("--mode", choices=("auto", "manual"), default="manual")
    p.add_argument("--only", action="append", metavar="PROJECT::TITLE")
    p.add_argument("--usage-json")
    p.set_defaults(fn=cmd_plan)

    p = sub.add_parser("begin")
    p.add_argument("--mode", choices=("auto", "manual"), default="manual")
    p.add_argument("--usage-json")
    p.set_defaults(fn=cmd_begin)

    p = sub.add_parser("worktree")
    p.add_argument("project"); p.add_argument("title")
    p.add_argument("--model", default=""); p.add_argument("--usage-json")
    p.set_defaults(fn=cmd_worktree)

    p = sub.add_parser("finish-task")
    p.add_argument("project"); p.add_argument("title")
    p.add_argument("--outcome", choices=("done", "blocked", "failed", "paused"), required=True)
    p.add_argument("--summary", default=""); p.add_argument("--question")
    p.add_argument("--tokens", type=int, default=0); p.add_argument("--usage-json")
    p.set_defaults(fn=cmd_finish_task)

    p = sub.add_parser("finish-scan")
    p.add_argument("project"); p.add_argument("--tokens", type=int, default=0); p.add_argument("--usage-json")
    p.set_defaults(fn=cmd_finish_scan)

    p = sub.add_parser("end")
    p.add_argument("--reason", required=True); p.add_argument("--final", choices=("yes", "no"), default="yes")
    p.add_argument("--emailed", choices=("yes", "no", "skipped"), default="no"); p.add_argument("--report")
    p.set_defaults(fn=cmd_end)

    sub.add_parser("maintain").set_defaults(fn=cmd_maintain)

    p = sub.add_parser("launch")
    p.add_argument("--mode", choices=("auto", "manual"), default="manual")
    p.add_argument("--only", action="append", metavar="PROJECT::TITLE")
    p.add_argument("--test", action="store_true", help="skip email and push")
    p.add_argument("--model", default="opus"); p.add_argument("--effort", default="medium")
    p.add_argument("--workdir", default=WORKDIR)
    p.add_argument("--max-minutes", type=int, default=480)
    p.add_argument("--linger", type=int, default=20, help="seconds between `end` and closing the session")
    p.add_argument("--no-auto-exit", dest="auto_exit", action="store_false")
    p.add_argument("--remote-control", action="store_true", help="publish the run to Remote Control while it runs")
    p.add_argument("--prompt", help=argparse.SUPPRESS)
    p.add_argument("--name", help=argparse.SUPPRESS)
    p.set_defaults(fn=cmd_launch)

    p = sub.add_parser("run-task")
    p.add_argument("project"); p.add_argument("title")
    p.add_argument("--model", default="sonnet"); p.add_argument("--usage-json")
    p.add_argument("--max-minutes", type=int, default=180)
    p.set_defaults(fn=cmd_run_task)

    p = sub.add_parser("run-scan")
    p.add_argument("project"); p.add_argument("--usage-json")
    p.add_argument("--max-minutes", type=int, default=45)
    p.set_defaults(fn=cmd_run_scan)

    p = sub.add_parser("task-report")
    p.add_argument("--status", choices=("done", "blocked", "failed"), required=True)
    p.add_argument("--summary", required=True); p.add_argument("--question"); p.add_argument("--tests")
    p.set_defaults(fn=cmd_task_report)

    p = sub.add_parser("watch")
    p.add_argument("--session"); p.add_argument("--once", action="store_true")
    p.set_defaults(fn=cmd_watch)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
