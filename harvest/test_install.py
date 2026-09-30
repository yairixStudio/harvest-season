#!/usr/bin/env python3
"""Tests for install.py, each in a throwaway HOME (with a space in its path, as many are).
Run: python3 harvest/test_install.py"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALL = os.path.join(HERE, "install.py")
MARK = "<!-- claude-harvest:begin"


def slurp(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class Install(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="harvest-install-")
        self.home = os.path.join(self.tmp, "Home Folder")
        os.makedirs(self.home)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("HARVEST_")}
        self.env["HOME"] = self.home

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def h(self, *parts):
        return os.path.join(self.home, *parts)

    def run_py(self, script, *args, code=0):
        r = subprocess.run(["python3", script] + list(args), capture_output=True, text=True, env=self.env)
        self.assertEqual(r.returncode, code, r.stdout + r.stderr)
        return json.loads(r.stdout)

    def inst(self, *args, code=0):
        return self.run_py(INSTALL, *args, code=code)

    def engine(self, *args, code=0):
        return self.run_py(self.h(".claude", "harvest", "bin", "harvest.py"), *args, code=code)

    def read(self, *parts):
        with open(self.h(*parts), encoding="utf-8") as f:
            return f.read()

    def write(self, text, *parts):
        os.makedirs(os.path.dirname(self.h(*parts)), exist_ok=True)
        with open(self.h(*parts), "w", encoding="utf-8") as f:
            f.write(text)

    def test_fresh_install_works_and_uninstall_leaves_nothing(self):
        workdir = os.path.join(self.tmp, "My Harvest")
        p = self.inst("plan", "--name", "Dana", "--language", "en", "--workdir", workdir)
        self.assertTrue(p["ok"])
        self.assertFalse(p["installed"])
        self.assertTrue(all(f["action"] == "create" for f in p["files"]))
        self.assertEqual([b["change"] for b in p["blocks"]], ["add"], "no ~/.codex: only CLAUDE.md")
        self.assertFalse(os.path.exists(self.h(".claude")), "plan writes nothing")

        r = self.inst("install", "--name", "Dana", "--language", "en", "--workdir", workdir)
        self.assertTrue(r["ok"])
        self.assertIsNone(r["backups"], "nothing existed, nothing to back up")
        self.assertTrue(os.access(self.h(".claude", "harvest", "bin", "harvest.py"), os.X_OK))
        self.assertEqual(os.path.realpath(self.h(".local", "bin", "claude-harvest")),
                         os.path.realpath(self.h(".claude", "harvest", "bin", "harvest.py")))
        self.assertTrue(os.path.isfile(self.h(".claude", "skills", "harvest-quota", "references", "digest-email.md")))
        self.assertIn("# Quota Harvest", self.read(".claude", "harvest", "README.md"), "README in the chosen language")
        claude_md = self.read(".claude", "CLAUDE.md")
        self.assertEqual(claude_md.count(MARK), 1)
        self.assertIn("## Backlog — small tasks for later", claude_md)
        self.assertTrue(os.path.isdir(workdir))

        s = self.engine("settings")
        self.assertTrue(s["configured"])
        self.assertEqual((s["ownerName"], s["language"], s["workdir"]), ("Dana", "en", workdir))

        repo = os.path.join(self.tmp, "Some Project")
        os.makedirs(repo)
        subprocess.run(["git", "init", "-q", repo], check=True)
        self.engine("add", repo, "--title", "Write a test", "--details", "done when it passes")
        self.assertIn("## Write a test", slurp(os.path.join(repo, "BACKLOG.md")))
        self.assertEqual(self.engine("list")["queue"][0]["title"], "Write a test")

        again = self.inst("install")
        self.assertEqual(again["changed"], [], "a second install changes nothing")
        self.assertEqual(again["blocks"][0]["change"], "none")
        st = self.inst("status")
        self.assertTrue(st["installed"])
        self.assertEqual(st["modified"], [])

        u = self.inst("uninstall")
        self.assertTrue(u["ok"])
        self.assertEqual(u["keptEditedByHand"], [])
        self.assertFalse(os.path.lexists(self.h(".local", "bin", "claude-harvest")))
        self.assertFalse(os.path.exists(self.h(".claude", "skills", "harvest-quota")))
        self.assertFalse(os.path.exists(self.h(".claude", "harvest", "bin", "harvest.py")))
        self.assertNotIn(MARK, self.read(".claude", "CLAUDE.md"))
        self.assertTrue(os.path.exists(self.h(".claude", "harvest", "projects.md")), "state stays without --purge")
        self.assertFalse(self.inst("status")["installed"])

    def test_codex_gets_the_block_when_codex_is_there(self):
        os.makedirs(self.h(".codex"))
        self.inst("install", "--language", "he")
        self.assertEqual(self.read(".codex", "AGENTS.md").count(MARK), 1)
        self.assertIn("# קציר מכסה", self.read(".claude", "harvest", "README.md"))
        self.inst("uninstall", "--purge")
        self.assertNotIn(MARK, self.read(".codex", "AGENTS.md"))
        self.assertFalse(os.path.exists(self.h(".claude", "harvest")))

    def test_an_older_hand_made_setup_needs_consent_and_is_backed_up(self):
        self.write("old engine\n", ".claude", "harvest", "bin", "harvest.py")
        self.write("old skill\n", ".claude", "skills", "backlog", "SKILL.md")
        self.write("state\n", ".claude", "harvest", "projects.md")
        self.write("# Global instructions\n\n## Summaries\nIn Hebrew.\n\n## Backlog — small tasks for later\n"
                   "old words\n\nmore old words\n", ".claude", "CLAUDE.md")
        p = self.inst("plan")
        self.assertFalse(p["ok"])
        whys = {os.path.relpath(c["path"], self.home): c["why"] for c in p["conflicts"]}
        self.assertIn(".claude/harvest/bin/harvest.py", whys)
        self.assertIn(".claude/CLAUDE.md", whys)
        r = self.inst("install", code=3)
        self.assertIn("nothing was written", r["error"])
        self.assertEqual(self.read(".claude", "harvest", "bin", "harvest.py"), "old engine\n")

        r = self.inst("install", "--replace-existing")
        self.assertTrue(r["ok"])
        claude_md = self.read(".claude", "CLAUDE.md")
        self.assertEqual(claude_md.count(MARK), 1)
        self.assertEqual(claude_md.count("## Backlog — small tasks for later"), 1)
        self.assertNotIn("old words", claude_md)
        self.assertTrue(claude_md.startswith("# Global instructions\n\n## Summaries\nIn Hebrew.\n\n" + MARK), claude_md)
        backup = r["backups"]
        with open(os.path.join(backup, ".claude", "harvest", "bin", "harvest.py"), encoding="utf-8") as f:
            self.assertEqual(f.read(), "old engine\n")
        with open(os.path.join(backup, ".claude", "CLAUDE.md"), encoding="utf-8") as f:
            self.assertIn("old words", f.read())
        self.assertEqual(self.read(".claude", "harvest", "projects.md"), "state\n", "state untouched")

    def test_a_file_edited_after_install_is_a_conflict(self):
        self.inst("install")
        path = self.h(".claude", "skills", "backlog", "SKILL.md")
        with open(path, "a", encoding="utf-8") as f:
            f.write("\nmy own note\n")
        self.assertEqual(self.inst("status")["modified"], [path])
        with open(os.path.join(HERE, "skills", "backlog", "SKILL.md"), encoding="utf-8") as f:
            original = f.read()
        # Same source, so install has nothing to do for it... unless the source moved on.
        p = self.inst("plan")
        self.assertTrue(any(c["path"] == path for c in p["conflicts"]), p)
        self.inst("install", code=3)
        self.assertTrue(self.inst("install", "--force")["ok"])
        self.assertEqual(slurp(path), original)
        u = self.inst("uninstall")
        self.assertEqual(u["keptEditedByHand"], [])

    def test_a_file_dropped_from_the_install_is_removed_unless_edited(self):
        self.inst("install")
        manifest_path = self.h(".claude", "harvest", "install-manifest.json")
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
        old_same, old_edited = self.h(".claude", "skills", "backlog", "old.md"), self.h(".claude", "skills", "backlog", "mine.md")
        self.write("from an earlier version\n", ".claude", "skills", "backlog", "old.md")
        self.write("edited\n", ".claude", "skills", "backlog", "mine.md")
        import hashlib
        manifest["files"][old_same] = hashlib.sha256(b"from an earlier version\n").hexdigest()
        manifest["files"][old_edited] = hashlib.sha256(b"as installed\n").hexdigest()
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(manifest, f)
        r = self.inst("install")
        self.assertEqual(r["retired"], [old_same])
        self.assertFalse(os.path.exists(old_same))
        self.assertTrue(os.path.exists(old_edited), "a file changed by hand stays")

    def test_settings_keep_what_is_not_given(self):
        self.inst("install", "--name", "Dana", "--language", "he", "--email", "d@example.com", "--email-digest", "yes")
        self.inst("install", "--language", "en")
        s = json.loads(self.read(".claude", "harvest", "settings.json"))
        self.assertEqual((s["ownerName"], s["language"], s["email"], s["emailDigest"]), ("Dana", "en", "d@example.com", True))
        self.assertIn("# Quota Harvest", self.read(".claude", "harvest", "README.md"), "README follows the language")


if __name__ == "__main__":
    unittest.main()
