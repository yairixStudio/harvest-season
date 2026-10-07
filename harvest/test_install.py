#!/usr/bin/env python3
"""Tests for install.py, each in a throwaway HOME (with a space in its path, as many are).
Run: python3 harvest/test_install.py"""

import hashlib
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
        self.assertTrue(os.path.isfile(self.h(".claude", "skills", "harvest-season", "references", "digest-email.md")))
        self.assertIn("# Harvest Season", self.read(".claude", "harvest", "README.md"), "README in the chosen language")
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
        self.assertFalse(os.path.exists(self.h(".claude", "skills", "harvest-season")))
        self.assertFalse(os.path.exists(self.h(".claude", "harvest", "bin", "harvest.py")))
        self.assertNotIn(MARK, self.read(".claude", "CLAUDE.md"))
        self.assertTrue(os.path.exists(self.h(".claude", "harvest", "projects.md")), "state stays without --purge")
        self.assertFalse(self.inst("status")["installed"])

    def test_codex_gets_the_block_when_codex_is_there(self):
        os.makedirs(self.h(".codex"))
        self.inst("install", "--language", "he")
        self.assertEqual(self.read(".codex", "AGENTS.md").count(MARK), 1)
        self.assertIn("# עונת הקציר", self.read(".claude", "harvest", "README.md"))
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
        self.assertIn("# Harvest Season", self.read(".claude", "harvest", "README.md"), "README follows the language")

    # The upgrade from Quota Harvest — the app's name before Harvest Season, when the harvest skill was
    # harvest-quota and the instruction blocks named both.
    OLD_BEGIN = ("<!-- claude-harvest:begin — managed by the Quota Harvest installer; "
                 "edit it in the quota-harvest repository (harvest/instructions/), then reinstall -->")
    OLD_SKILL = {("SKILL.md",): "---\nname: harvest-quota\n---\nthe harvest, by its old name\n",
                 ("references", "talk-prompt.md"): "the old talk prompt\n",
                 ("references", "digest-email.md"): "the old digest\n"}

    def old_skill_path(self, *parts):
        return self.h(".claude", "skills", "harvest-quota", *parts)

    def make_quota_harvest_home(self, edit=None):
        """A home as the Quota Harvest installer left it: the harvest skill under its old name, recorded in
        the manifest with a hash per file, and both instruction blocks in the old wording. `edit`: one of
        the old skill's files, changed by hand since."""
        os.makedirs(self.h(".codex"))
        self.inst("install", "--language", "en")
        shutil.rmtree(self.h(".claude", "skills", "harvest-season"))
        manifest_path = self.h(".claude", "harvest", "install-manifest.json")
        manifest = json.loads(slurp(manifest_path))
        manifest["files"] = {p: d for p, d in manifest["files"].items() if os.sep + "harvest-season" + os.sep not in p}
        for parts, text in self.OLD_SKILL.items():
            self.write(text, ".claude", "skills", "harvest-quota", *parts)
            manifest["files"][self.old_skill_path(*parts)] = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if edit:
            with open(self.old_skill_path(*edit), "a", encoding="utf-8") as f:
                f.write("my own note\n")
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(manifest, f)
        old_block = (self.OLD_BEGIN + "\n## Backlog — small tasks for later\nThe Quota Harvest widget launches the "
                     "harvest (`harvest-quota` skill).\n<!-- claude-harvest:end -->")
        self.write("# Global instructions\n\nmine before\n\n" + old_block + "\n\n## Mine after\nkept\n", ".claude", "CLAUDE.md")
        self.write(old_block + "\n", ".codex", "AGENTS.md")

    def test_an_upgrade_from_quota_harvest_moves_the_skill_and_rewrites_the_blocks(self):
        self.make_quota_harvest_home()
        p = self.inst("plan")
        self.assertTrue(p["ok"], p["conflicts"])
        new_skill = [f for f in p["files"] if os.sep + "harvest-season" + os.sep in f["path"]]
        self.assertTrue(new_skill and all(f["action"] == "create" for f in new_skill), new_skill)
        self.assertEqual([b["change"] for b in p["blocks"]], ["replace", "replace"])

        r = self.inst("install")
        self.assertTrue(r["ok"])
        self.assertEqual(sorted(r["retired"]), sorted(self.old_skill_path(*parts) for parts in self.OLD_SKILL))
        self.assertFalse(os.path.exists(self.old_skill_path()), "the old skill's folder goes, empty folders and all")
        self.assertIn("name: harvest-season", self.read(".claude", "skills", "harvest-season", "SKILL.md"))
        with open(os.path.join(r["backups"], ".claude", "skills", "harvest-quota", "SKILL.md"), encoding="utf-8") as f:
            self.assertEqual(f.read(), self.OLD_SKILL[("SKILL.md",)], "what goes is backed up first")
        for rel in ((".claude", "CLAUDE.md"), (".codex", "AGENTS.md")):
            text = self.read(*rel)
            self.assertEqual(text.count(MARK), 1, rel)
            self.assertIn("managed by the Harvest Season installer", text)
            self.assertNotIn("Quota Harvest", text)
            self.assertNotIn("harvest-quota", text)
        claude_md = self.read(".claude", "CLAUDE.md")
        self.assertTrue(claude_md.startswith("# Global instructions\n\nmine before\n\n" + MARK), claude_md)
        self.assertTrue(claude_md.endswith("\n\n## Mine after\nkept\n"), claude_md)
        self.assertIn("`harvest-season` skill", claude_md)

        manifest = json.loads(self.read(".claude", "harvest", "install-manifest.json"))
        self.assertFalse([path for path in manifest["files"] if "harvest-quota" in path])
        self.assertEqual(self.inst("status")["modified"], [])
        names = {x["name"] for x in self.engine("prompts")["prompts"]}
        self.assertTrue({"task", "scan", "talk", "onboard", "digest"} <= names, "the engine reads the renamed skill's texts")
        again = self.inst("install")
        self.assertEqual((again["changed"], again["retired"]), ([], []), "a second install changes nothing")
        self.assertEqual([b["change"] for b in again["blocks"]], ["none", "none"])

    def test_an_old_skill_file_edited_by_hand_stays_with_its_folder(self):
        self.make_quota_harvest_home(edit=("references", "talk-prompt.md"))
        r = self.inst("install")
        self.assertTrue(r["ok"], "an edited file the new version doesn't have is no conflict: it just stays")
        self.assertEqual(sorted(r["retired"]), sorted([self.old_skill_path("SKILL.md"),
                                                       self.old_skill_path("references", "digest-email.md")]))
        self.assertEqual(slurp(self.old_skill_path("references", "talk-prompt.md")), "the old talk prompt\nmy own note\n")
        self.assertFalse(os.path.exists(self.old_skill_path("SKILL.md")), "no skill by the old name is left to load")
        self.assertTrue(os.path.isfile(self.h(".claude", "skills", "harvest-season", "SKILL.md")))

    def test_uninstall_of_an_older_install_takes_the_old_skill_folder_too(self):
        self.make_quota_harvest_home()
        u = self.inst("uninstall")
        self.assertEqual(u["keptEditedByHand"], [])
        self.assertFalse(os.path.exists(self.old_skill_path()))
        self.assertFalse(os.path.exists(self.h(".claude", "skills", "backlog")))
        self.assertNotIn(MARK, self.read(".claude", "CLAUDE.md"))
        self.assertNotIn(MARK, self.read(".codex", "AGENTS.md"))


if __name__ == "__main__":
    unittest.main()
