#!/usr/bin/env python3
"""Install the backlog harvester from this repository into the user's home — no agent involved.

    python3 install.py plan      [options]   what install would do, as JSON (the widget shows it first)
    python3 install.py install   [options]   do it
    python3 install.py status                is it installed, from which version, anything changed by hand?
    python3 install.py uninstall [--purge]   take it out again; --purge also deletes the harvest's state

Options: --name <owner name> --language he|en --email <address> --email-digest yes|no
         --workdir <folder the harvest sessions run in> --replace-existing --force

What it writes (and records, with a hash per file, in ~/.claude/harvest/install-manifest.json):
  ~/.claude/harvest/bin/…              the engine (home/bin here), README.md in the owner's language
  ~/.claude/skills/<name>/…            the skills (skills/ here)
  ~/.local/bin/claude-harvest          a link to the engine
  ~/.claude/CLAUDE.md                  the "Backlog" instructions, between claude-harvest markers
  ~/.codex/AGENTS.md                   the same for Codex, only when ~/.codex exists
  ~/.claude/harvest/settings.json      the owner's settings — existing values kept unless given
It never touches the harvest's state (projects.md, history, status, calibration, logs, reports,
worktrees). A file it installed that has since been edited by hand is a conflict: it stops unless
--force. A file that exists but was never installed by it (an older hand-made setup) stops it unless
--replace-existing. Whatever it replaces or edits is copied to ~/.claude/harvest/backups/<time>/ first.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime

SRC = os.path.dirname(os.path.abspath(__file__))
VERSION = 1
BEGIN = ("<!-- claude-harvest:begin — managed by the Quota Harvest installer; "
         "edit it in the quota-harvest repository (harvest/instructions/), then reinstall -->")
END = "<!-- claude-harvest:end -->"
LEGACY_HEADING = "## Backlog — small tasks for later"
LANGUAGES = ("he", "en")
SKILLS = ("backlog", "harvest-quota", "check-usage")
EXECUTABLE = ("bin/harvest.py", "bin/watch.command")


def home(*parts):
    return os.path.join(os.path.expanduser("~"), *parts)


HARVEST = home(".claude", "harvest")
MANIFEST = os.path.join(HARVEST, "install-manifest.json")
SETTINGS = os.path.join(HARVEST, "settings.json")
LINK = home(".local", "bin", "claude-harvest")
BLOCK_FILES = {"claude": home(".claude", "CLAUDE.md"), "codex": home(".codex", "AGENTS.md")}


def emit(obj, code=0):
    print(json.dumps(obj, ensure_ascii=False, indent=1))
    sys.exit(code)


def read(path, binary=False):
    try:
        with open(path, "rb" if binary else "r", **({} if binary else {"encoding": "utf-8"})) as f:
            return f.read()
    except OSError:
        return None


def sha(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode("utf-8")).hexdigest()


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_bytes(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".install-tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def source_version():
    r = subprocess.run(["git", "-C", SRC, "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
    dirty = subprocess.run(["git", "-C", SRC, "status", "--porcelain", "--", "."], capture_output=True, text=True)
    rev = r.stdout.strip() if r.returncode == 0 else ""
    return rev + ("+changes" if rev and dirty.stdout.strip() else "")


# ---------- what the installation consists of ----------

def owned_files(language):
    """(target path, source bytes, mode) for every file the installer owns."""
    files = []
    for rel in ("bin/harvest.py", "bin/test_harvest.py", "bin/watch.command"):
        files.append((os.path.join(HARVEST, rel), read(os.path.join(SRC, "home", rel), True),
                      0o755 if rel in EXECUTABLE else 0o644))
    readme = os.path.join(SRC, "home", "README.%s.md" % language)
    files.append((os.path.join(HARVEST, "README.md"), read(readme, True), 0o644))
    for skill in SKILLS:
        root = os.path.join(SRC, "skills", skill)
        for folder, _, names in os.walk(root):
            for name in sorted(names):
                if name.startswith("."):
                    continue
                src = os.path.join(folder, name)
                files.append((home(".claude", "skills", skill, os.path.relpath(src, root)), read(src, True), 0o644))
    missing = [t for t, data, _ in files if data is None]
    if missing:
        emit({"ok": False, "error": "the repository is incomplete", "missing": missing}, 2)
    return files


def block_text(which):
    body = read(os.path.join(SRC, "instructions", which + ".md")).strip("\n")
    return "%s\n%s\n%s" % (BEGIN, body, END)


def with_block(text, block):
    """(new text, change) — change: add | replace | replace-legacy | none."""
    text = text or ""
    if BEGIN.split(" —")[0] in text and END in text:
        start = text.index(BEGIN.split(" —")[0])
        stop = text.index(END, start) + len(END)
        new = text[:start] + block + text[stop:]
        return new, ("none" if new == text else "replace")
    lines = text.split("\n")
    if LEGACY_HEADING in lines:
        # A hand-written Backlog section from before the installer: it becomes the marked block.
        i = lines.index(LEGACY_HEADING)
        j = next((k for k in range(i + 1, len(lines)) if lines[k].startswith("## ")), len(lines))
        tail = lines[j:]
        head = "\n".join(lines[:i]).rstrip("\n")
        new = (head + "\n\n" if head else "") + block + ("\n\n" + "\n".join(tail) if tail else "\n")
        return new, "replace-legacy"
    base = text.rstrip("\n")
    return (base + "\n\n" if base else "") + block + "\n", "add"


def without_block(text):
    if not text or BEGIN.split(" —")[0] not in text or END not in text:
        return text, False
    start = text.index(BEGIN.split(" —")[0])
    stop = text.index(END, start) + len(END)
    before, after = text[:start].rstrip("\n"), text[stop:].lstrip("\n")
    return (before + ("\n\n" + after if after else "\n") if before else after), True


def wanted_settings(a, current):
    s = dict(current)
    for key, value in (("ownerName", a.name), ("language", a.language), ("email", a.email), ("workdir", a.workdir)):
        if value is not None:
            s[key] = value
    if a.email_digest is not None:
        s["emailDigest"] = a.email_digest == "yes"
    s.setdefault("language", "en")
    s.setdefault("workdir", "~/claude-harvest")
    if s["language"] not in LANGUAGES:
        emit({"ok": False, "error": "language is one of " + ", ".join(LANGUAGES)}, 2)
    return s


def plan(a):
    manifest = read_json(MANIFEST, {"files": {}})
    known = manifest.get("files", {})
    settings = wanted_settings(a, read_json(SETTINGS, {}))
    actions, conflicts = [], []
    for target, data, mode in owned_files(settings["language"]):
        current = read(target, True)
        if current is None:
            actions.append({"path": target, "action": "create"})
        elif current == data:
            actions.append({"path": target, "action": "keep"})
        elif target in known and sha(current) == known[target]:
            actions.append({"path": target, "action": "update"})
        elif target in known and not a.force:
            conflicts.append({"path": target, "why": "edited since it was installed"})
        elif target not in known and not (a.replace_existing or a.force):
            conflicts.append({"path": target, "why": "exists and was not installed by this installer"})
        else:
            actions.append({"path": target, "action": "replace"})
    blocks = []
    for which, path in BLOCK_FILES.items():
        if which == "codex" and not os.path.isdir(os.path.dirname(path)):
            continue
        before = read(path)
        after, change = with_block(before, block_text(which))
        if change == "replace-legacy" and not (a.replace_existing or a.force):
            conflicts.append({"path": path, "why": "has a Backlog section written by hand; --replace-existing turns it into the managed block"})
        blocks.append({"path": path, "change": change, "block": block_text(which)})
    link = os.path.realpath(LINK) if os.path.lexists(LINK) else None
    engine = os.path.join(HARVEST, "bin", "harvest.py")
    link_action = "keep" if link == os.path.realpath(engine) else ("create" if link is None else "replace")
    if link_action == "replace" and not os.path.islink(LINK) and not (a.replace_existing or a.force):
        conflicts.append({"path": LINK, "why": "is a file, not the installer's link"})
    workdir = os.path.expanduser(settings["workdir"])
    return {
        "ok": not conflicts, "version": VERSION, "source": SRC, "sourceVersion": source_version(),
        "installed": os.path.exists(MANIFEST), "files": actions, "blocks": blocks,
        "link": {"path": LINK, "to": engine, "action": link_action},
        "settings": {"path": SETTINGS, "values": settings, "action": "update" if os.path.exists(SETTINGS) else "create"},
        "workdir": {"path": workdir, "action": "keep" if os.path.isdir(workdir) else "create"},
        "conflicts": conflicts,
        "untouched": "projects.md, history, status, calibration, logs, reports and worktrees are never touched",
    }


def cmd_plan(a):
    emit(plan(a))


def cmd_install(a):
    p = plan(a)
    if p["conflicts"]:
        emit(dict(p, ok=False, error="conflicts — nothing was written"), 3)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_root = os.path.join(HARVEST, "backups", stamp)

    def backup(path):
        if os.path.exists(path) and not os.path.islink(path):
            dest = os.path.join(backup_root, os.path.relpath(path, home()))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copy2(path, dest)

    manifest_files = {}
    previous = read_json(MANIFEST, {"files": {}}).get("files", {})
    settings = p["settings"]["values"]
    for target, data, mode in owned_files(settings["language"]):
        if read(target, True) != data:
            backup(target)
            write_bytes(target, data, mode)
        else:
            os.chmod(target, mode)
        manifest_files[target] = sha(data)
    # A file an earlier version installed that this one no longer has goes — unless edited by hand.
    retired = []
    for path, digest in previous.items():
        if path not in manifest_files and os.path.exists(path) and sha(read(path, True)) == digest:
            backup(path)
            os.remove(path)
            retired.append(path)
    for b in p["blocks"]:
        if b["change"] != "none":
            backup(b["path"])
            new, _ = with_block(read(b["path"]), b["block"])
            write_bytes(b["path"], new.encode("utf-8"))
    if p["link"]["action"] != "keep":
        backup(LINK)
        os.makedirs(os.path.dirname(LINK), exist_ok=True)
        if os.path.lexists(LINK):
            os.remove(LINK)
        os.symlink(p["link"]["to"], LINK)
    saved = read_json(SETTINGS, {})
    if saved != settings:
        backup(SETTINGS)
        write_bytes(SETTINGS, (json.dumps(settings, ensure_ascii=False, indent=1) + "\n").encode("utf-8"))
    os.makedirs(p["workdir"]["path"], exist_ok=True)
    write_bytes(MANIFEST, (json.dumps({
        "version": VERSION, "source": SRC, "sourceVersion": p["sourceVersion"],
        "installedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
        "files": manifest_files, "blocks": [b["path"] for b in p["blocks"]], "link": LINK,
    }, ensure_ascii=False, indent=1) + "\n").encode("utf-8"))
    changed = [f for f in p["files"] if f["action"] != "keep"]
    emit({"ok": True, "installed": True, "changed": changed, "retired": retired, "blocks": [{"path": b["path"], "change": b["change"]} for b in p["blocks"]],
          "backups": backup_root if os.path.isdir(backup_root) else None, "settings": settings})


def cmd_status(a):
    manifest = read_json(MANIFEST, None)
    if not manifest:
        emit({"installed": False, "legacy": os.path.exists(os.path.join(HARVEST, "bin", "harvest.py")),
              "sourceVersion": source_version()})
    modified = [path for path, digest in manifest.get("files", {}).items()
                if (read(path, True) is None) or sha(read(path, True)) != digest]
    blocks = {path: (BEGIN.split(" —")[0] in (read(path) or "")) for path in manifest.get("blocks", [])}
    emit({"installed": True, "version": manifest.get("version"), "sourceVersion": manifest.get("sourceVersion"),
          "availableVersion": source_version(), "installedAt": manifest.get("installedAt"),
          "modified": modified, "blocks": blocks, "settings": read_json(SETTINGS, {})})


def cmd_uninstall(a):
    manifest = read_json(MANIFEST, None)
    if not manifest:
        emit({"ok": False, "error": "not installed by this installer"}, 2)
    removed, kept = [], []
    for path, digest in manifest.get("files", {}).items():
        data = read(path, True)
        if data is None:
            continue
        if sha(data) == digest or a.force:
            os.remove(path)
            removed.append(path)
        else:
            kept.append(path)
    for skill in SKILLS:
        root = home(".claude", "skills", skill)
        for folder, _, _ in sorted(os.walk(root), key=lambda w: -len(w[0])):
            try:
                os.rmdir(folder)
            except OSError:
                pass
    for path in manifest.get("blocks", []):
        new, had = without_block(read(path))
        if had:
            write_bytes(path, new.encode("utf-8"))
    if os.path.islink(LINK):
        os.remove(LINK)
    os.remove(MANIFEST)
    if a.purge:
        shutil.rmtree(HARVEST, ignore_errors=True)
    emit({"ok": True, "removed": removed, "keptEditedByHand": kept, "purged": bool(a.purge)})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("plan", cmd_plan), ("install", cmd_install)):
        p = sub.add_parser(name)
        p.add_argument("--name"); p.add_argument("--language", choices=LANGUAGES); p.add_argument("--email")
        p.add_argument("--email-digest", choices=("yes", "no")); p.add_argument("--workdir")
        p.add_argument("--replace-existing", action="store_true"); p.add_argument("--force", action="store_true")
        p.set_defaults(fn=fn)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    p = sub.add_parser("uninstall")
    p.add_argument("--purge", action="store_true"); p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_uninstall)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
