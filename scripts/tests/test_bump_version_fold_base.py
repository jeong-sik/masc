"""bump-version.sh scans for missing fragments from the last release's fold.

Each case builds a throwaway git repository shaped like a release this
repository actually cut, runs the real script there and reads its verdict.
No tag or commit touches the checkout the test runs from.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
EDITED_FILES = (
    'README.md',
    'README.ko.md',
    'ROADMAP.md',
    'docs/PRODUCT-OPERATING-PLAN.md',
    'docs/spec/SPEC-INDEX.md',
    'docs/INSTALL.md',
    'docs/INSTALL.ko.md',
    'docs-site/src/content/docs/getting-started/quickstart.md',
    'docs-site/src/content/docs/ko/getting-started/quickstart.md',
)
CHANGELOG = '# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-01-01\n\n### Fixed\n- First.\n'


class Repo:
    def __init__(self, root: Path):
        self.root = root
        self.env = {
            'PATH': os.environ['PATH'],
            'HOME': str(root),
            'GIT_CONFIG_GLOBAL': os.devnull,
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_AUTHOR_NAME': 'release test',
            'GIT_AUTHOR_EMAIL': 'release-test@example.invalid',
            'GIT_COMMITTER_NAME': 'release test',
            'GIT_COMMITTER_EMAIL': 'release-test@example.invalid',
        }
        self.git('init', '--quiet', '--initial-branch=main')
        (root / 'scripts').mkdir()
        for name in ('bump-version.sh', 'changelog-fragments.py'):
            shutil.copy2(SCRIPTS / name, root / 'scripts' / name)
        for name in EDITED_FILES:
            self.write(name, 'placeholder\n')
        self.write('CHANGELOG.md', CHANGELOG)
        self.write('changelog.d/README.md', 'fragments\n')
        self.write('dune-project', '(lang dune 3.0)\n(version 0.1.0)\n')
        self.commit('chore: start the repository')

    def git(self, *args: str) -> str:
        return subprocess.run(
            ['git', *args], cwd=self.root, env=self.env, text=True,
            capture_output=True, check=True).stdout.strip()

    def write(self, name: str, text: str) -> None:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')

    def commit(self, subject: str) -> str:
        self.git('add', '--all')
        self.git('commit', '--quiet', '--allow-empty', '-m', subject)
        return self.git('rev-parse', 'HEAD')

    def merge_pull_request(self, number: int, fragment: bool) -> str:
        """One squash on the current branch, the way a pull request lands."""
        self.write(f'src/change-{number}.txt', f'change {number}\n')
        if fragment:
            self.write(f'changelog.d/{number}.md', f'### Fixed\n\n- Change {number} (#{number}).\n')
        return self.commit(f'fix: change {number} (#{number})')

    def fold(self, version: str, subject: str) -> str:
        """What a bump leaves behind: the new version and no fragments."""
        self.write('dune-project', f'(lang dune 3.0)\n(version {version})\n')
        for path in (self.root / 'changelog.d').glob('[0-9]*.md'):
            path.unlink()
        return self.commit(subject)

    def tag_on_side_branch(self, tag: str, start: str) -> None:
        """Tag a release-branch commit that main never contains."""
        self.git('checkout', '--quiet', '-b', f'release/{tag}', start)
        self.write('release-notes.txt', f'{tag}\n')
        self.commit(f'chore(release): candidate for {tag}')
        self.git('tag', tag)
        self.git('checkout', '--quiet', 'main')

    def bump(self, version: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ['bash', 'scripts/bump-version.sh', version], cwd=self.root,
            env=self.env, text=True, capture_output=True)

    def version_line(self) -> str:
        return (self.root / 'dune-project').read_text(encoding='utf-8').splitlines()[1]


class BumpVersionFoldBaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix='masc-bump-fold-base-test-')
        self.addCleanup(directory.cleanup)
        self.repo = Repo(Path(directory.name))

    def assert_bumped(self, result: subprocess.CompletedProcess, version: str) -> None:
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.repo.version_line(), f'(version {version})')

    def assert_refused(self, result: subprocess.CompletedProcess, kept: str) -> None:
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.repo.version_line(), f'(version {kept})')
        self.assertEqual(self.repo.git('status', '--porcelain'), '')

    def test_pull_request_merged_between_the_cut_and_a_late_fold_is_reported(self):
        # v0.70.0: the release branch left main, main kept merging, and the
        # fold reached main later under a subject of its own. #2 merged after
        # the cut, so no release folded it, and it has no fragment.
        repo = self.repo
        cut = repo.merge_pull_request(1, fragment=True)
        repo.tag_on_side_branch('v0.2.0', cut)
        repo.merge_pull_request(2, fragment=False)
        repo.fold('0.2.0', 'Backport v0.2.0 release fold to main (#3)')
        repo.merge_pull_request(4, fragment=True)

        result = repo.bump('0.3.0')

        self.assert_refused(result, kept='0.2.0')
        self.assertIn('#2 fix: change 2 (#2)', result.stderr)
        self.assertNotIn('#1', result.stderr)
        self.assertNotIn('#4', result.stderr)

    def test_pull_request_merged_after_the_fold_but_before_the_tag_is_reported(self):
        # v0.71.0: the fold landed on main first and the release branch was
        # cut from a later main commit. #3 sits between the two and has no
        # fragment.
        repo = self.repo
        repo.merge_pull_request(1, fragment=True)
        repo.fold('0.2.0', 'chore(release): bump version to 0.2.0 and fold changelog.d (#2)')
        after_fold = repo.merge_pull_request(3, fragment=False)
        repo.tag_on_side_branch('v0.2.0', after_fold)
        repo.merge_pull_request(4, fragment=True)

        result = repo.bump('0.3.0')

        self.assert_refused(result, kept='0.2.0')
        self.assertIn('#3 fix: change 3 (#3)', result.stderr)
        self.assertNotIn('#4', result.stderr)

    def test_tag_on_the_fold_commit_itself_starts_the_scan_after_it(self):
        repo = self.repo
        repo.merge_pull_request(1, fragment=True)
        repo.fold('0.2.0', 'chore(release): bump version to 0.2.0 (#2)')
        repo.git('tag', 'v0.2.0')
        repo.merge_pull_request(3, fragment=True)

        self.assert_bumped(repo.bump('0.3.0'), '0.3.0')

    def test_commit_that_replaced_the_version_is_not_taken_for_the_fold(self):
        # The next version is written before the release branch is cut, so
        # the newest commit touching the v0.2.0 version line is the one that
        # removed it. The scan still starts at the v0.2.0 fold and sees #3.
        repo = self.repo
        repo.merge_pull_request(1, fragment=True)
        repo.fold('0.2.0', 'chore(release): bump version to 0.2.0 (#2)')
        repo.merge_pull_request(3, fragment=False)
        replaced = repo.fold('0.3.0', 'chore(release): bump version to 0.3.0 (#4)')
        repo.tag_on_side_branch('v0.2.0', replaced)

        result = repo.bump('0.3.0')

        self.assert_refused(result, kept='0.3.0')
        self.assertIn('#3 fix: change 3 (#3)', result.stderr)

    def test_release_not_folded_onto_this_branch_stops_the_bump(self):
        # The tag exists on the release branch only; nothing on main set the
        # version, so there is no fold to scan from.
        repo = self.repo
        cut = repo.merge_pull_request(1, fragment=True)
        repo.tag_on_side_branch('v0.2.0', cut)
        repo.merge_pull_request(2, fragment=True)

        result = repo.bump('0.3.0')

        self.assert_refused(result, kept='0.1.0')
        self.assertIn("'(version 0.2.0)'", result.stderr)
        self.assertIn('v0.2.0', result.stderr)
        self.assertNotIn('missing-fragment base', result.stderr)


    def test_fold_and_cut_on_separate_lines_of_history_stop_the_bump(self):
        # The tag sits on a branch that left before the fold and was merged
        # back as a second parent: neither commit is an ancestor of the other.
        repo = self.repo
        start = repo.merge_pull_request(1, fragment=True)
        repo.fold('0.2.0', 'chore(release): bump version to 0.2.0 (#2)')
        repo.git('checkout', '--quiet', '-b', 'side', start)
        repo.write('side.txt', 'side\n')
        joined = repo.commit('chore: side work')
        repo.tag_on_side_branch('v0.2.0', joined)
        repo.git('merge', '--quiet', '--no-ff', '-m', 'merge side', joined)

        result = repo.bump('0.3.0')

        self.assert_refused(result, kept='0.2.0')
        self.assertIn('separate lines of history', result.stderr)


    def test_tag_sharing_no_commit_with_this_branch_stops_the_bump(self):
        repo = self.repo
        repo.merge_pull_request(1, fragment=True)
        repo.fold('0.2.0', 'chore(release): bump version to 0.2.0 (#2)')
        repo.git('checkout', '--quiet', '--orphan', 'unrelated')
        repo.commit('chore: unrelated root')
        repo.git('tag', 'v0.2.0')
        repo.git('checkout', '--quiet', 'main')

        result = repo.bump('0.3.0')

        self.assert_refused(result, kept='0.2.0')
        self.assertIn('share no commit', result.stderr)


if __name__ == '__main__':
    unittest.main()
