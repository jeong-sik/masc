"""Run the real doc/version checks in an isolated checkout with mutable tags."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StableDocumentationInputs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="masc-doc-truth-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.repo = Path(cls.temporary.name) / "checkout"
        # Local shared objects avoid copying history; refs and working files
        # belong to this fixture. No original checkout/tag is modified.
        subprocess.run(["git", "clone", "--quiet", "--shared", "--no-tags",
                        "--single-branch", str(ROOT), str(cls.repo)], check=True)
        for name in ("check-doc-truth.sh", "check-version-truth.sh"):
            shutil.copy2(ROOT / "scripts" / name, cls.repo / "scripts" / name)
        cls.env = {key: value for key, value in os.environ.items()
                   if not key.startswith("GIT_") and key != "GITHUB_REF"}

    def run_script(self, script, *args):
        return subprocess.run(["bash", "scripts/" + script, *args], cwd=self.repo,
                              env=self.env, text=True, capture_output=True)

    def test_tags_do_not_change_the_same_checkout_verdict(self):
        tags = subprocess.check_output(["git", "tag", "--list"], cwd=self.repo, text=True)
        self.assertEqual(tags, "")
        before = self.run_script("check-doc-truth.sh")
        self.assertEqual(before.returncode, 0, before.stdout + before.stderr)
        for name in ("v999.0.0", "v-unrelated-product", "another-product-v1000"):
            subprocess.run(["git", "tag", name], cwd=self.repo, check=True)
        after = self.run_script("check-doc-truth.sh")
        self.assertEqual((after.returncode, after.stdout, after.stderr),
                         (before.returncode, before.stdout, before.stderr))

    def test_candidate_install_pin_requires_explicit_availability_notice(self):
        site_docs = ("docs-site/src/content/docs/getting-started/quickstart.md",
                     "docs-site/src/content/docs/ko/getting-started/quickstart.md")
        names = ("README.md", "README.ko.md", "docs/INSTALL.md",
                 "docs/INSTALL.ko.md") + site_docs
        publication_docs = ("ROADMAP.md", "docs/PRODUCT-OPERATING-PLAN.md")
        originals = {name: (self.repo / name).read_text()
                     for name in names + publication_docs}
        version = re.search(r"(?m)^\(version ([^)]+)\)",
                            (self.repo / "dune-project").read_text()).group(1)
        notice = f"> Installation target: v{version} (check tag availability on GitHub Releases)."
        # Model an unpublished candidate independently of today's release.
        # The check requires the prior publication to name a real changelog row.
        prior_versions = [value for value in re.findall(
            r"(?m)^## \[([0-9][^]]*)\]", (self.repo / "CHANGELOG.md").read_text())
                          if value != version]
        self.assertTrue(prior_versions, "fixture needs a previous changelog release")
        try:
            for name, text in originals.items():
                if name in publication_docs:
                    text, count = re.subn(
                        r"(?m)^(> Latest published GitHub release: )v[^ ]+",
                        lambda match: match.group(1) + "v" + prior_versions[0], text)
                    self.assertEqual(count, 1)
                text = re.sub(r"(?m)^TAG=v[^ ]+$", "TAG=v" + version, text)
                if name in site_docs:
                    # The site pages carry the version in prose and a heading
                    # as well as the pin, and name only one version.
                    text = re.sub(r"[0-9]+\.[0-9]+\.[0-9]+", version, text)
                if name.startswith("README") and notice not in text:
                    text = notice + "\n\n" + text
                (self.repo / name).write_text(text)
            accepted = self.run_script("check-doc-truth.sh")
            self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
            readme = self.repo / "README.md"
            readme.write_text(readme.read_text().replace(notice, ""))
            refused = self.run_script("check-doc-truth.sh")
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("Installation target:", refused.stderr)
        finally:
            for name, text in originals.items():
                (self.repo / name).write_text(text)

    def test_checked_in_version_mismatch_still_fails(self):
        path = self.repo / "dune-project"
        original = path.read_text()
        try:
            changed, count = re.subn(r"(?m)^\(version [^)]+\)", "(version 999.0.0)", original)
            self.assertEqual(count, 1)
            path.write_text(changed)
            result = self.run_script("check-doc-truth.sh")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("version truth check failed:", result.stderr)
            self.assertIn("dune-project (999.0.0)", result.stderr)
        finally:
            path.write_text(original)

    def test_explicit_release_tag_still_must_match_package(self):
        version = re.search(r"(?m)^\(version ([^)]+)\)",
                            (self.repo / "dune-project").read_text()).group(1)
        good = self.run_script("check-version-truth.sh", "--tag", "v" + version)
        self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
        bad = self.run_script("check-version-truth.sh", "--tag", "v999.0.0")
        self.assertNotEqual(bad.returncode, 0, bad.stdout + bad.stderr)
        self.assertIn("tag v999.0.0 != package version", bad.stderr)


if __name__ == "__main__":
    unittest.main()
