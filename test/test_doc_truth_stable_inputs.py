"""Run the real doc/version checks in an isolated checkout with mutable tags."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SITE_DOCS = ("docs-site/src/content/docs/getting-started/quickstart.md",
             "docs-site/src/content/docs/ko/getting-started/quickstart.md")
INSTALL_DOCS = ("README.md", "README.ko.md", "docs/INSTALL.md",
                "docs/INSTALL.ko.md") + SITE_DOCS


def checkout(destination):
    # Local shared objects avoid copying history; refs and working files
    # belong to this fixture. No original checkout/tag is modified.
    subprocess.run(["git", "clone", "--quiet", "--shared", "--no-tags",
                    "--single-branch", str(ROOT), str(destination)], check=True)
    for name in ("check-doc-truth.sh", "check-version-truth.sh", "bump-version.sh",
                 "changelog-fragments.py"):
        shutil.copy2(ROOT / "scripts" / name, destination / "scripts" / name)
    return destination


def first_group(pattern, text):
    match = re.search(pattern, text)
    assert match is not None, pattern
    return match.group(1)


def package_version(repo):
    return first_group(r"(?m)^\(version ([^)]+)\)", (repo / "dune-project").read_text())


def run_script(repo, env, script, *args):
    return subprocess.run(["bash", "scripts/" + script, *args], cwd=repo,
                          env=env, text=True, capture_output=True)


class StableDocumentationInputs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="masc-doc-truth-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.repo = checkout(Path(cls.temporary.name) / "checkout")
        cls.env = {key: value for key, value in os.environ.items()
                   if not key.startswith("GIT_") and key != "GITHUB_REF"}

    def run_script(self, script, *args):
        return run_script(self.repo, self.env, script, *args)

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

    def test_bump_moves_every_install_pin_to_the_candidate(self):
        # A separate checkout: the bump rewrites a dozen files this class's
        # other tests read.
        with tempfile.TemporaryDirectory(prefix="masc-bump-") as parent:
            repo = checkout(Path(parent) / "checkout")
            current = package_version(repo)
            major, minor, patch = current.split(".")
            candidate = f"{major}.{minor}.{int(patch) + 1}"
            fragment = repo / "changelog.d" / "999999.md"
            fragment.parent.mkdir(exist_ok=True)
            fragment.write_text("### Fixed\n\n- Fixture fragment (#999999).\n")
            bumped = subprocess.run(["bash", "scripts/bump-version.sh", candidate],
                                    cwd=repo, env=self.env, text=True, capture_output=True)
            self.assertEqual(bumped.returncode, 0, bumped.stdout + bumped.stderr)
            # The bump folds pending fragments into [Unreleased].
            self.assertFalse(fragment.exists())
            self.assertIn("- Fixture fragment (#999999).",
                          (repo / "CHANGELOG.md").read_text())

            for name in INSTALL_DOCS:
                pins = re.findall(r"(?m)^TAG=v(.+)$", (repo / name).read_text())
                self.assertEqual(pins, [candidate], name)
            for name in ("README.md", "README.ko.md"):
                text = (repo / name).read_text()
                self.assertEqual(re.findall(r"releases/tag/v([0-9.]+)", text), [candidate], name)
            for name in SITE_DOCS:
                versions = set(re.findall(r"[0-9]+\.[0-9]+\.[0-9]+", (repo / name).read_text()))
                self.assertEqual(versions, {candidate}, name)

            # The bump leaves a TBD changelog stub, which the version check
            # refuses; a release fills it before tagging.
            changelog = repo / "CHANGELOG.md"
            filled, count = re.subn(r"(?m)^- TBD$", "- Fixture entry.",
                                    changelog.read_text(), count=1)
            self.assertEqual(count, 1)
            changelog.write_text(filled)
            accepted = run_script(repo, self.env, "check-doc-truth.sh")
            self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)

            # The candidate is not the published release, so the pin stands
            # only with the availability notice beside it.
            notice = f"> Installation target: v{candidate} (check tag availability on GitHub Releases)."
            readme = repo / "README.md"
            self.assertIn(notice, readme.read_text())
            readme.write_text(readme.read_text().replace(notice, ""))
            refused = run_script(repo, self.env, "check-doc-truth.sh")
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("Installation target:", refused.stderr)

    def test_a_pin_on_the_published_release_still_needs_the_notice(self):
        # The bump rewrites the notice rather than adding it, so a README that
        # lost it while pinned to a published release must fail here instead
        # of at the next bump. On a release branch the bump has already moved
        # the pin to the candidate, so pin the README to the published release
        # here rather than assuming the branch already does.
        readme = self.repo / "README.md"
        original = readme.read_text()
        published = first_group(r"(?m)^> Latest published GitHub release: v([^ ]+)",
                                (self.repo / "ROADMAP.md").read_text())
        notice = f"> Installation target: v{published} (check tag availability on GitHub Releases)."
        pinned = re.sub(r"(?m)^TAG=v[^ ]+$", f"TAG=v{published}", original)
        pinned = re.sub(r"(?m)^> Installation target: v[^ ]+ .*$", notice, pinned)
        try:
            readme.write_text(pinned)
            self.assertEqual(pinned.count(notice), 1)
            readme.write_text(pinned.replace(notice, ""))
            refused = self.run_script("check-doc-truth.sh")
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("Installation target:", refused.stderr)
        finally:
            readme.write_text(original)

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
        version = package_version(self.repo)
        good = self.run_script("check-version-truth.sh", "--tag", "v" + version)
        self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
        bad = self.run_script("check-version-truth.sh", "--tag", "v999.0.0")
        self.assertNotEqual(bad.returncode, 0, bad.stdout + bad.stderr)
        self.assertIn("tag v999.0.0 != package version", bad.stderr)


if __name__ == "__main__":
    unittest.main()
