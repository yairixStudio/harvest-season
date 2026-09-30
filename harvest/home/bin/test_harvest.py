#!/usr/bin/env python3
"""Tests for harvest.py against throwaway git repos in a temporary HARVEST_HOME. Run: python3 test_harvest.py"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

ENGINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "harvest.py")
# In the repository the prompts sit beside the engine's source (harvest/skills/…): test those, not whatever
# copy happens to be installed. An installed engine has no such folder and falls back to its default.
REPO_REFS = os.path.normpath(os.path.join(os.path.dirname(ENGINE), "..", "..", "skills", "harvest-quota", "references"))
if os.path.isdir(REPO_REFS):
    os.environ.setdefault("HARVEST_SKILL_REFS", REPO_REFS)
    os.environ.setdefault("HARVEST_TEMPLATE_DIR", os.path.join(REPO_REFS, "..", "..", "backlog"))


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


class Harvest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="harvest-test-")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.repo = self.make_repo("alpha")
        self.env = dict(os.environ, HARVEST_HOME=self.home)
        self.env.pop("HARVEST_UNATTENDED", None)
        self.env.pop("HARVEST_RUNNER_PID", None)
        self.env.pop("CLAUDE_CODE_SESSION_ID", None)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def make_repo(self, name):
        path = os.path.join(self.tmp, name)
        os.makedirs(path)
        for args in (["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]):
            subprocess.run(["git", "-C", path] + args, check=True)
        with open(os.path.join(path, "README.md"), "w") as f:
            f.write("hello\n")
        subprocess.run(["git", "-C", path, "add", "README.md"], check=True)
        subprocess.run(["git", "-C", path, "commit", "-q", "-m", "init"], check=True)
        return path

    def run_engine(self, *args, env=None, code=0):
        r = subprocess.run(["python3", ENGINE] + list(args), capture_output=True, text=True, env=env or self.env)
        self.assertEqual(r.returncode, code, r.stdout + r.stderr)
        return json.loads(r.stdout)

    def usage(self, five=20, weekly=60, reset_in_h=6.0, session_reset_in_h=3.0, age_min=0):
        t = datetime.now(timezone.utc)
        u = {"fetchedAt": iso(t - timedelta(minutes=age_min)),
             "session": {"pct": five, "resetsAt": iso(t + timedelta(hours=session_reset_in_h))},
             "weekly": {"pct": weekly, "resetsAt": iso(t + timedelta(hours=reset_in_h))},
             "scoped": {"label": "Fable", "pct": 10, "resetsAt": iso(t + timedelta(hours=reset_in_h))}}
        with open(os.path.join(self.home, "usage.json"), "w") as f:
            json.dump(u, f)

    def add(self, title, **kw):
        args = ["add", self.repo, "--title", title, "--details", kw.get("details", "do it"),
                "--complexity", kw.get("complexity", "low"), "--status", kw.get("status", "open")]
        if "tokens" in kw:
            args += ["--tokens", str(kw["tokens"])]
        return self.run_engine(*args, env=kw.get("env"))

    def commit_in(self, path, name="x.txt"):
        with open(os.path.join(path, name), "w") as f:
            f.write("change\n")
        subprocess.run(["git", "-C", path, "add", name], check=True)
        subprocess.run(["git", "-C", path, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "work"], check=True)

    def test_add_registers_and_lists(self):
        out = self.add("Add a test for foo")
        self.assertTrue(out["registered"])
        listing = self.run_engine("list")
        self.assertEqual([t["title"] for t in listing["queue"]], ["Add a test for foo"])
        est = listing["queue"][0]["estimate"]
        # nothing measured yet: default turns for "low" × (common base + growth), over the author's 100k hint
        self.assertEqual((est["baseSource"], est["turnsSource"]), ("predicted", "default"))
        self.assertEqual(listing["queue"][0]["tokens"], 6 * (38000 + 2000 * 5 / 2))
        self.run_engine("add", self.repo, "--title", "Add a test for foo", "--details", "x", code=2)

    def test_hebrew_title_and_status_toggle(self):
        self.add("בדיקות ל-PowerController", status="proposed")
        self.run_engine("set-status", self.repo, "בדיקות ל-PowerController", "open")
        self.assertEqual(len(self.run_engine("list")["queue"]), 1)
        self.run_engine("set-status", self.repo, "בדיקות ל-PowerController", "proposed")
        self.assertEqual(len(self.run_engine("list")["proposals"]), 1)

    def test_unattended_cannot_queue(self):
        env = dict(self.env, HARVEST_UNATTENDED="1")
        out = self.add("Refactor bar", env=env)
        self.assertEqual(out["status"], "proposed")
        self.assertTrue(out["downgradedToProposed"])
        r = subprocess.run(["python3", ENGINE, "set-status", self.repo, "Refactor bar", "open"],
                           capture_output=True, text=True, env=env)
        self.assertNotEqual(r.returncode, 0)

    def test_plan_gates(self):
        self.add("Small task one", tokens=60000)
        self.usage(reset_in_h=30)
        self.assertEqual(self.run_engine("plan", "--mode", "auto")["reason"], "too-early")
        plan = self.run_engine("plan", "--mode", "manual")
        self.assertTrue(plan["harvest"])
        self.assertEqual(plan["next"]["model"], "sonnet")
        self.usage(reset_in_h=6)
        self.assertTrue(self.run_engine("plan", "--mode", "auto")["harvest"])
        self.usage(age_min=30)
        self.assertTrue(self.run_engine("plan")["reason"].startswith("usage-unreadable"))
        self.usage(reset_in_h=0.2)
        self.assertEqual(self.run_engine("plan")["reason"], "cutoff-near")

    def test_the_owner_can_order_the_queue(self):
        self.add("Urgent big", tokens=90000)
        self.run_engine("set-status", self.repo, "Urgent big", "open")
        self.add("Later small", tokens=60000)
        beta = self.make_repo("beta")
        self.run_engine("add", beta, "--title", "Other project", "--details", "d", "--complexity", "low", "--tokens", "70000")
        # Automatic order: priority, then the bigger estimate first — and plan runs the list's first task.
        queue = self.run_engine("list")["queue"]
        auto = [t["title"] for t in queue]
        self.assertEqual(sorted(queue, key=lambda t: (t["priority"], -t["tokens"])), queue)
        self.usage()
        self.assertEqual(self.run_engine("plan", "--mode", "manual")["next"]["title"], auto[0])
        self.assertNotEqual(auto[0], "Later small", "the test needs the dragged task not to be first already")
        # The owner drags "Later small" to the top; a key that isn't queued is ignored.
        r = self.run_engine("queue-order", self.repo + "::Later small", "/nowhere::Ghost")
        self.assertTrue(r["manual"])
        listing = self.run_engine("list")
        self.assertEqual([t["title"] for t in listing["queue"]], ["Later small", "Urgent big", "Other project"])
        self.assertEqual([t["placed"] for t in listing["queue"]], [True, False, False])
        self.assertEqual(self.run_engine("plan", "--mode", "manual")["next"]["title"], "Later small")
        # A full order across projects.
        self.run_engine("queue-order", beta + "::Other project", self.repo + "::Urgent big", self.repo + "::Later small")
        self.assertEqual([t["title"] for t in self.run_engine("list")["queue"]], ["Other project", "Urgent big", "Later small"])
        self.run_engine("queue-order", "--reset", env=dict(self.env, HARVEST_UNATTENDED="1"), code=2)
        self.assertFalse(self.run_engine("queue-order", "--reset")["manual"])
        self.assertEqual([t["title"] for t in self.run_engine("list")["queue"]], auto)

    def test_plan_five_hour_full_is_not_final(self):
        self.add("Big task here", complexity="high", tokens=400000)
        self.usage(five=84, weekly=40, reset_in_h=7, session_reset_in_h=2)
        plan = self.run_engine("plan", "--mode", "auto")
        self.assertFalse(plan["harvest"])
        self.assertEqual(plan["reason"], "5h-full")
        self.assertFalse(plan["final"])

    def test_only_filter(self):
        self.add("First thing to do")
        self.add("Second thing to do")
        self.usage()
        plan = self.run_engine("plan", "--only", self.repo + "::Second thing to do")
        self.assertEqual(plan["next"]["title"], "Second thing to do")

    def test_full_task_cycle(self):
        self.add("Write docs for alpha")
        self.usage()
        self.run_engine("begin", "--mode", "manual")
        self.run_engine("begin", "--mode", "manual", code=3)
        wt = self.run_engine("worktree", self.repo, "Write docs for alpha", "--model", "sonnet")
        self.assertEqual(wt["branch"], "backlog/write-docs-for-alpha")
        # Claude Code's place for session worktrees, so the Claude app files the session under the project,
        # kept out of the owner's git status.
        self.assertEqual(wt["path"], os.path.join(self.repo, ".claude", "worktrees", "harvest-write-docs-for-alpha"))
        self.assertEqual(subprocess.run(["git", "-C", self.repo, "check-ignore", "-q", ".claude/worktrees/x"]).returncode, 0)
        self.assertEqual(subprocess.run(["git", "-C", self.repo, "status", "--porcelain"], capture_output=True,
                                        text=True).stdout.strip(), "?? BACKLOG.md")
        self.commit_in(wt["path"])
        done = self.run_engine("finish-task", self.repo, "Write docs for alpha", "--outcome", "done",
                               "--summary", "נוסף תיעוד", "--tokens", "70000")
        self.assertEqual(done["outcome"], "done")
        self.assertFalse(os.path.exists(wt["path"]))
        listing = self.run_engine("list")
        need = listing["needsYou"][0]
        self.assertEqual((need["branch"], need["branchState"]), ("backlog/write-docs-for-alpha", "unmerged"))
        end = self.run_engine("end", "--reason", "queue-empty")
        self.assertEqual(end["lastRun"]["done"], 1)
        self.assertFalse(os.path.exists(os.path.join(self.home, ".lock")))
        with open(os.path.join(self.home, "calibration.md")) as f:
            self.assertIn("write-docs-for-alpha", f.read())
        subprocess.run(["git", "-C", self.repo, "merge", "-q", "backlog/write-docs-for-alpha"], check=True)
        self.assertEqual(self.run_engine("list")["needsYou"], [])

    def test_done_history_links_the_session(self):
        self.add("Document the API")
        self.usage()
        with open(os.path.join(self.home, "launch.json"), "w") as f:
            json.dump({"sessionId": "sess-1", "launcherPid": os.getpid(), "endedAt": None}, f)
        self.run_engine("begin")
        wt = self.run_engine("worktree", self.repo, "Document the API")
        self.commit_in(wt["path"])
        self.run_engine("finish-task", self.repo, "Document the API", "--outcome", "done",
                        "--summary", "נוסף תיעוד ל-API", "--tokens", "50000")
        done = self.run_engine("list")["done"]
        self.assertEqual(len(done), 1)
        self.assertEqual(done[0]["sessionId"], "sess-1")
        self.assertEqual(done[0]["summary"], "נוסף תיעוד ל-API")
        self.assertEqual(done[0]["branchState"], "unmerged")

    def test_set_status_done_links_the_calling_session(self):
        self.add("Clean up")
        env = dict(self.env, CLAUDE_CODE_SESSION_ID="11111111-2222-3333-4444-555555555555")
        self.run_engine("set-status", self.repo, "Clean up", "done", "--result", "בוצע ידנית", env=env)
        self.assertEqual(self.run_engine("list")["done"][0]["sessionId"], "11111111-2222-3333-4444-555555555555")

    def test_link_session(self):
        self.add("Old task")
        self.run_engine("set-status", self.repo, "Old task", "done")
        self.assertIsNone(self.run_engine("list")["done"][0]["sessionId"])
        sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        self.run_engine("link-session", self.repo, "Old task", sid)
        self.assertEqual(self.run_engine("list")["done"][0]["sessionId"], sid)
        self.run_engine("link-session", self.repo, "Old task", "not-a-session", code=2)

    def finished_branch(self, title, name="added.txt", content="change\n"):
        """A done task whose harvest branch waits for the owner."""
        self.add(title)
        self.usage()
        self.run_engine("begin", "--mode", "manual")
        wt = self.run_engine("worktree", self.repo, title)
        self.commit_file(wt["path"], name, content)
        self.run_engine("finish-task", self.repo, title, "--outcome", "done", "--summary", "נוסף קובץ", "--tokens", "5000")
        self.run_engine("end", "--reason", "queue-empty")
        return wt["branch"]

    def commit_file(self, path, name, content):
        with open(os.path.join(path, name), "w") as f:
            f.write(content)
        subprocess.run(["git", "-C", path, "add", name], check=True)
        subprocess.run(["git", "-C", path, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "edit " + name],
                       check=True)

    def test_brief_and_merge(self):
        branch = self.finished_branch("Add a file")
        # BACKLOG.md tracked and edited by the engine is not the owner's work in the way.
        with open(os.path.join(self.repo, "BACKLOG.md")) as f:
            self.commit_file(self.repo, "BACKLOG.md", f.read())
        with open(os.path.join(self.repo, "BACKLOG.md"), "a") as f:
            f.write("\n")
        item = self.run_engine("brief")["items"][0]
        self.assertEqual((item["branch"], item["fileCount"], item["mergesCleanly"], item["readyToMerge"]),
                         (branch, 1, True, True))
        with open(os.path.join(self.repo, "README.md"), "a") as f:
            f.write("the owner's edit\n")
        self.assertFalse(self.run_engine("brief")["items"][0]["readyToMerge"])
        refused = self.run_engine("merge", self.repo, "Add a file", code=2)
        self.assertEqual(refused["inTheWay"], "uncommitted-changes")
        subprocess.run(["git", "-C", self.repo, "checkout", "-q", "README.md"], check=True)
        self.assertTrue(self.run_engine("merge", self.repo, "Add a file")["ok"])
        self.assertTrue(os.path.exists(os.path.join(self.repo, "added.txt")))
        self.assertEqual(subprocess.run(["git", "-C", self.repo, "rev-parse", "--verify", "-q", branch],
                                        capture_output=True).returncode, 1)
        listing = self.run_engine("list")
        self.assertEqual(listing["needsYou"], [])
        self.assertEqual(listing["done"][0]["branchState"], "merged")
        self.assertEqual(listing["done"][0]["summary"], "נוסף קובץ")

    def test_merge_refuses_conflicts_and_another_branch(self):
        self.finished_branch("Rewrite the readme", name="README.md", content="the agent's words\n")
        self.commit_file(self.repo, "README.md", "the owner's words\n")
        self.assertFalse(self.run_engine("brief")["items"][0]["mergesCleanly"])
        self.assertEqual(self.run_engine("merge", self.repo, "Rewrite the readme", code=2)["inTheWay"], "conflicts")
        subprocess.run(["git", "-C", self.repo, "checkout", "-q", "-b", "owner-work"], check=True)
        self.assertEqual(self.run_engine("merge", self.repo, "Rewrite the readme", code=2)["inTheWay"], "checkout-branch")
        with open(os.path.join(self.repo, "README.md")) as f:
            self.assertEqual(f.read(), "the owner's words\n")

    def test_answer_requeues_with_the_owners_answer(self):
        self.add("Needs a decision", details="Pick a color")
        self.run_engine("set-status", self.repo, "Needs a decision", "blocked", "--result", "2026-09-30 · איזה צבע?")
        self.run_engine("set-status", self.repo, "Needs a decision", "open", "--answer", "כחול,\n כמו בלוגו")
        details = self.run_engine("list")["queue"][0]["details"]
        self.assertTrue(details.startswith("Pick a color · Owner's answer ("), details)
        self.assertTrue(details.endswith("כחול, כמו בלוגו"), details)

    def test_settings_default_set_and_language(self):
        s = self.run_engine("settings")
        self.assertFalse(s["configured"])
        self.assertEqual((s["language"], s["workdir"], s["emailDigest"]), ("en", "~/claude-harvest", False))
        self.assertEqual(s["models"], {"low": "sonnet", "medium": "opus", "high": "fable"})
        s = self.run_engine("settings", "--set", "language=he", "--set", "ownerName=Dana",
                            "--set", "emailDigest=yes", "--set", 'models={"high": "opus"}')
        self.assertTrue(s["configured"])
        self.assertEqual((s["language"], s["ownerName"], s["emailDigest"]), ("he", "Dana", True))
        self.assertEqual(s["models"]["high"], "opus")
        self.assertEqual(s["models"]["low"], "sonnet", "a partial models map keeps the other defaults")
        self.assertEqual(self.run_engine("list")["settings"]["language"], "he")
        self.assertIn("language is one of", self.run_engine("settings", "--set", "language=fr", code=2)["error"])
        self.assertIn("keys:", self.run_engine("settings", "--set", "color=red", code=2)["error"])
        unattended = dict(self.env, HARVEST_UNATTENDED="1")
        self.run_engine("settings", "--set", "language=en", env=unattended, code=2)
        # The owner's language reaches what the engine writes into BACKLOG.md.
        self.add("Needs a decision", details="Pick a color")
        self.run_engine("set-status", self.repo, "Needs a decision", "open", "--answer", "כחול")
        details = self.run_engine("list")["queue"][0]["details"]
        self.assertIn("תשובת הבעלים (", details)
        other = self.make_repo("gamma")
        self.run_engine("add", other, "--title", "A first task", "--details", "d")
        with open(os.path.join(other, "BACKLOG.md"), encoding="utf-8") as f:
            self.assertIn("משימות קטנות ולא דחופות", f.read(), "a new backlog starts from the Hebrew template")

    def test_done_without_commits_fails_then_blocks(self):
        self.add("Flaky task")
        self.usage()
        self.run_engine("begin")
        for expected in ("open", "blocked"):
            self.run_engine("worktree", self.repo, "Flaky task")
            out = self.run_engine("finish-task", self.repo, "Flaky task", "--outcome", "done", "--summary", "x")
            self.assertEqual(out["backlog"]["status"], expected)
        self.assertFalse(subprocess.run(["git", "-C", self.repo, "branch", "--list", "backlog/*"],
                                        capture_output=True, text=True).stdout.strip())

    def test_maintain_recovers_interrupted_run(self):
        self.add("Interrupted work")
        self.usage()
        dead = subprocess.Popen(["true"])
        dead.wait()
        env = dict(self.env, HARVEST_RUNNER_PID=str(dead.pid))
        self.run_engine("begin", env=env)
        wt = self.run_engine("worktree", self.repo, "Interrupted work", env=env)
        self.commit_in(wt["path"])
        rep = self.run_engine("maintain")
        self.assertTrue(rep["staleLock"] and rep["interrupted"])
        self.assertTrue(rep["worktrees"][0]["kept"].startswith("backlog-stopped/"))
        self.assertFalse(os.path.exists(wt["path"]))
        listing = self.run_engine("list")
        self.assertEqual(listing["status"]["state"], "idle")
        self.assertEqual(listing["queue"][0]["title"], "Interrupted work")

    def test_cycle_survives_reset_jitter(self):
        self.add("Cycle task")
        reset = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0) + timedelta(hours=6)
        for stamp in (reset - timedelta(milliseconds=98), reset + timedelta(milliseconds=264)):
            self.usage()
            path = os.path.join(self.home, "usage.json")
            with open(path) as f:
                u = json.load(f)
            u["weekly"]["resetsAt"] = stamp.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
            with open(path, "w") as f:
                json.dump(u, f)
            self.run_engine("begin", "--mode", "auto")
            self.run_engine("end", "--reason", "5h-full", "--final", "no")
        self.assertEqual(self.run_engine("list")["status"]["cycle"]["runs"], 2)

    def test_inactive_session_window_counts_as_empty(self):
        self.add("Night task")
        self.usage()
        path = os.path.join(self.home, "usage.json")
        with open(path) as f:
            u = json.load(f)
        u["session"] = None
        with open(path, "w") as f:
            json.dump(u, f)
        plan = self.run_engine("plan")
        self.assertTrue(plan["harvest"])
        self.assertEqual(plan["fiveRoom"], 85)
        u["weekly"] = None
        with open(path, "w") as f:
            json.dump(u, f)
        self.assertTrue(self.run_engine("plan")["reason"].startswith("usage-unreadable"))

    def test_launch_helpers(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("harvest", ENGINE)
        h = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(h)
        self.assertEqual(h.transcript_path("abc", "/Users/x/Programs/quota-harvest"),
                         os.path.expanduser("~/.claude/projects/-Users-x-Programs-quota-harvest/abc.jsonl"))
        auto = h.build_prompt("auto", [], True)
        self.assertIn("AUTO mode", auto)
        self.assertIn("every queued (open) task", auto)
        self.assertIn("TEST LAUNCH", auto)
        manual = h.build_prompt("manual", ["/p::T"], False)
        self.assertIn('--only: "/p::T"', manual)
        self.assertNotIn("TEST LAUNCH", manual)
        self.assertIn("never wait for input", manual)

    def test_session_activity_sees_subagents(self):
        import importlib.util, time
        spec = importlib.util.spec_from_file_location("harvest", ENGINE)
        h = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(h)
        t = os.path.join(self.tmp, "s1.jsonl")
        open(t, "w").close()
        os.utime(t, (1000, 1000))
        os.makedirs(os.path.join(self.tmp, "s1", "subagents"))
        sub = os.path.join(self.tmp, "s1", "subagents", "a.jsonl")
        open(sub, "w").close()
        self.assertGreater(h.session_activity(t), time.time() - 60)

    def test_trust_screen_pointer(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("harvest", ENGINE)
        h = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(h)
        no_first = (b"\x1b[2GQuick\x1b[8Gsafety\r\n\x1b[2G\x1b[38;5;153m\xe2\x9d\xaf\x1b[4GNo,\x1b[8Gexit\x1b[39m\r\n"
                    b"\x1b[4GYes,\x1b[9GI\x1b[11Gtrust\x1b[17Gthis\x1b[22Gfolder\r\n")
        yes_now = (b"\x1b[4GNo,\x1b[8Gexit\r\n\x1b[2G\xe2\x9d\xaf\x1b[4GYes,\x1b[9GI\x1b[11Gtrust"
                   b"\x1b[17Gthis\x1b[22Gfolder\r\n")
        self.assertEqual(h.trust_choice(no_first), "no")
        self.assertEqual(h.trust_choice(yes_now), "yes")
        self.assertIsNone(h.trust_choice(b"Welcome to Claude Code"))

    def test_task_report_needs_a_task_session(self):
        self.run_engine("task-report", "--status", "done", "--summary", "x", code=2)
        result = os.path.join(self.tmp, "r.json")
        env = dict(self.env, HARVEST_TASK_RESULT=result)
        self.run_engine("task-report", "--status", "blocked", "--summary", "צריך החלטה", "--question", "איזה צבע?", env=env)
        with open(result) as f:
            r = json.load(f)
        self.assertEqual((r["status"], r["question"]), ("blocked", "איזה צבע?"))

    def load_engine(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("harvest", ENGINE)
        h = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(h)
        return h

    def test_transcript_tokens_counts_each_message_once(self):
        h = self.load_engine()
        t = os.path.join(self.tmp, "sess.jsonl")
        usage = {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 1}
        with open(t, "w") as f:
            for mid in ("m1", "m1", "m2"):
                f.write(json.dumps({"type": "assistant", "message": {"id": mid, "usage": usage}}) + "\n")
            f.write(json.dumps({"type": "user", "message": {"content": "hi"}}) + "\n")
        os.makedirs(os.path.join(self.tmp, "sess", "subagents"))
        with open(os.path.join(self.tmp, "sess", "subagents", "a.jsonl"), "w") as f:
            f.write(json.dumps({"type": "assistant", "message": {"id": "s1", "usage": usage}}) + "\n")
        self.assertEqual(h.transcript_tokens(t), 3 * 116)

    def test_fill_template(self):
        refs = os.path.join(self.tmp, "refs")
        os.makedirs(refs)
        with open(os.path.join(refs, "t.md"), "w") as f:
            f.write("# Title\n\n```\nWork in <worktree path> on <title>. Keep <placeholder>.\n```\n")
        before = os.environ.get("HARVEST_SKILL_REFS")
        os.environ["HARVEST_SKILL_REFS"] = refs
        try:
            h = self.load_engine()
            body = h.fill_template("t.md", {"worktree path": "/w", "title": "T"})
        finally:
            if before is None:
                os.environ.pop("HARVEST_SKILL_REFS")
            else:
                os.environ["HARVEST_SKILL_REFS"] = before
        self.assertEqual(body, "Work in /w on T. Keep <placeholder>.")

    def test_real_templates_fill(self):
        h = self.load_engine()
        body = h.fill_template("task-agent-prompt.md", {
            "project path": "/p", "worktree path": "/p/.claude/worktrees/harvest-x", "branch": "backlog/x",
            "base": "main", "title": "T", "priority": 2, "complexity": "low", "tokens": 100000, "details": "D"})
        self.assertIn("/p/.claude/worktrees/harvest-x", body)
        self.assertIn("claude-harvest task-report", body)
        self.assertNotIn("<worktree path>", body)
        talk = h.fill_template("talk-prompt.md", {})
        self.assertIn("claude-harvest brief", talk)
        self.assertIn("claude-harvest merge", talk)
        if os.path.isdir(REPO_REFS):
            onboard = h.fill_template("onboard-prompt.md", {})
            self.assertIn("claude-harvest discover", onboard)
            self.assertIn("--status proposed", onboard)
            self.assertNotIn("<owner", onboard)

    def test_proposals_can_be_removed_one_by_one_or_per_project(self):
        self.add("Idea one", status="proposed")
        self.add("Idea two", status="proposed")
        self.add("Queued one")
        self.run_engine("set-status", self.repo, "Idea one", "dropped")
        listing = self.run_engine("list")
        self.assertEqual([t["title"] for t in listing["proposals"]], ["Idea two"])
        with open(os.path.join(self.repo, "BACKLOG.md"), encoding="utf-8") as f:
            self.assertIn("removed by the owner", f.read(), "a removed proposal keeps a note, so it isn't proposed again")
        r = self.run_engine("proposals", self.repo, "off")
        self.assertEqual(r["dropped"], ["Idea two"])
        listing = self.run_engine("list")
        self.assertEqual(listing["proposals"], [])
        self.assertEqual([t["title"] for t in listing["queue"]], ["Queued one"], "queued tasks are the owner's — kept")
        self.assertTrue(listing["projects"][0]["proposalsOff"])
        refused = self.run_engine("add", self.repo, "--status", "proposed", "--title", "Another idea", "--details", "d", code=2)
        self.assertTrue(refused["proposalsOff"])
        self.run_engine("add", self.repo, "--title", "Owner's own task", "--details", "d")  # open is still fine
        self.run_engine("proposals", self.repo, "off", env=dict(self.env, HARVEST_UNATTENDED="1"), code=2)
        self.run_engine("settings", "--set", "noProposals=x", code=2)
        self.run_engine("proposals", self.repo, "on")
        self.assertFalse(self.run_engine("list")["projects"][0]["proposalsOff"])
        self.run_engine("add", self.repo, "--status", "proposed", "--title", "Back again", "--details", "d")

    def test_discover_finds_the_projects_worked_in(self):
        fake_home = os.path.join(self.tmp, "Fake Home")
        store = os.path.join(fake_home, ".claude", "projects")
        worktree = os.path.join(self.tmp, "alpha-wt")
        subprocess.run(["git", "-C", self.repo, "worktree", "add", "-q", "-b", "side", worktree], check=True)
        plain = os.path.join(self.tmp, "not-git")
        os.makedirs(plain)
        beta = self.make_repo("beta")
        for slug, cwd in (("a", self.repo), ("b", worktree), ("c", plain), ("d", beta), ("e", "/gone/away")):
            os.makedirs(os.path.join(store, slug))
            with open(os.path.join(store, slug, "s.jsonl"), "w") as f:
                f.write(json.dumps({"type": "queue-operation"}) + "\n" + json.dumps({"type": "user", "cwd": cwd}) + "\n")
        os.utime(os.path.join(store, "d", "s.jsonl"), (1, 1))
        self.add("Something")  # registers alpha
        env = dict(self.env, HOME=fake_home)
        rows = self.run_engine("discover", env=env)["projects"]
        real = lambda p: os.path.realpath(p)
        self.assertEqual([real(r["path"]) for r in rows], [real(self.repo), real(beta)],
                         "worktree folded into its project, non-git and missing folders dropped, newest first")
        self.assertEqual(rows[0]["sessions"], 2)
        self.assertTrue(rows[0]["registered"])
        self.assertTrue(rows[0]["hasBacklog"])
        self.assertFalse(rows[1]["registered"])
        s = self.run_engine("settings", "--set", "workdir=" + beta, env=env)
        self.assertEqual([real(r["path"]) for r in self.run_engine("discover", env=env)["projects"]], [real(self.repo)],
                         "the harvest's own folder is not a project")

    def test_estimate_follows_the_projects_context(self):
        h = self.load_engine()
        with open(os.path.join(self.repo, "CLAUDE.md"), "w") as f:
            f.write("x" * 30000)
        os.environ["HARVEST_HOME"] = self.home
        try:
            h = self.load_engine()
            ctx = h.context_data()
            tokens, parts = h.estimate_tokens(self.repo, "low", 0, ctx)
            self.assertEqual((parts["base"], parts["baseSource"]), (38000 + 10000, "predicted"))
            ctx["projects"][self.repo] = {"base": 50000}
            ctx["sessions"] = [{"kind": "low", "turns": t, "first": 50000, "last": 50000 + 1000 * (t - 1)} for t in (4, 5, 6)]
            tokens, parts = h.estimate_tokens(self.repo, "low", 0, ctx)
            self.assertEqual((parts["base"], parts["baseSource"], parts["turns"], parts["turnsSource"], parts["growth"]),
                             (50000, "measured", 5, "learned", 1000))
            self.assertEqual(tokens, 5 * (50000 + 1000 * 4 / 2))
            big, _ = h.estimate_tokens(self.repo, "low", 900000, ctx)
            self.assertEqual(big, 900000)
        finally:
            os.environ.pop("HARVEST_HOME")

    def test_session_stats_and_record(self):
        os.environ["HARVEST_HOME"] = self.home
        try:
            h = self.load_engine()
            t = os.path.join(self.tmp, "s.jsonl")
            with open(t, "w") as f:
                for mid, size in (("a", 40000), ("a", 40000), ("b", 43000), ("c", 46000)):
                    f.write(json.dumps({"type": "assistant", "message": {"id": mid, "usage": {"cache_read_input_tokens": size, "output_tokens": 10}}}) + "\n")
                f.write(json.dumps({"type": "assistant", "isSidechain": True, "message": {"id": "z", "usage": {"cache_read_input_tokens": 99999}}}) + "\n")
            stats = h.session_stats(t)
            self.assertEqual((stats["turns"], stats["first"], stats["last"]), (3, 40000, 46000))
            h.record_session(self.repo, "low", stats)
            ctx = h.context_data()
            self.assertEqual(ctx["projects"][self.repo]["base"], 40000)
            self.assertEqual(ctx["sessions"][-1]["turns"], 3)
        finally:
            os.environ.pop("HARVEST_HOME")

    def test_list_reports_the_latest_launch(self):
        with open(os.path.join(self.home, "launch.json"), "w") as f:
            json.dump({"sessionId": "s1", "bridgeSessionId": "session_x", "endedAt": None}, f)
        self.assertEqual(self.run_engine("list")["launch"]["bridgeSessionId"], "session_x")

    def test_get_usage_shape_is_accepted(self):
        self.add("Uses desktop usage")
        t = datetime.now(timezone.utc)
        raw = {"plan": {"status": "ok", "windows": [
            {"label": "5-hour limit", "percentUsed": 10, "resetsAt": iso(t + timedelta(hours=2))},
            {"label": "Weekly · all models", "percentUsed": 50, "resetsAt": iso(t + timedelta(hours=5))},
            {"label": "Weekly · Fable", "percentUsed": 90, "resetsAt": iso(t + timedelta(hours=5))}]}}
        plan = self.run_engine("plan", "--mode", "auto", "--usage-json", json.dumps(raw))
        self.assertTrue(plan["harvest"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
