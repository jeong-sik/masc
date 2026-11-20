"""Tests for scripts/ci/pr_tui_value_strings.py.

`changes` is a required check, so a reader that miscounts a comment or a
character literal blocks every TUI pull request. These pin how literals are
read (RFC tui-hand-written-counts-fail-the-pr-check, section 6) and how one
pull request's changed files are chosen.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import unittest

CI_DIR = pathlib.Path(__file__).resolve().parents[1]
if str(CI_DIR) not in sys.path:
    sys.path.insert(0, str(CI_DIR))

import pr_tui_value_strings as check  # noqa: E402


def rules(source: str) -> list[tuple[int, str]]:
    findings = check.judge(check.lex(source))
    return [(hit.line, hit.rule.value) for hit in findings.hits]


class ReadsLiterals(unittest.TestCase):
    def test_each_rule_fails_its_shape_and_passes_a_neighbour(self) -> None:
        cases = [
            ('"%d more"', [(1, "cut-off")]),
            ('"(+%d)"', [(1, "cut-off"), (1, "plus")]),
            ('"tags 외 %d"', [(1, "cut-off")]),
            ('"제외 %d"', []),
            ('"%d items"', []),
            ('" +%d"', [(1, "plus")]),
            ('"[+%s]"', [(1, "plus")]),
            ('"a+%d"', []),
            ('"(-%d)"', [(1, "hyphen-minus")]),
            ('"%d-%d"', []),
        ]
        for source, expected in cases:
            with self.subTest(source=source):
                self.assertEqual(rules(source), expected)

    def test_a_string_inside_a_comment_is_not_read(self) -> None:
        self.assertEqual(rules('(* " +%d" *) let x = 1'), [])

    def test_comments_nest(self) -> None:
        self.assertEqual(rules('(* (* inner *) " +%d" *)'), [])

    def test_a_closing_mark_inside_a_commented_string_does_not_end_the_comment(self) -> None:
        self.assertEqual(rules('(* "*)" " +%d" *)'), [])

    def test_a_double_quote_character_does_not_open_a_string(self) -> None:
        self.assertEqual(rules("let q = '\"' in \" ok\""), [])
        self.assertEqual(rules("let q = '\"' ^ \" +%d\""), [(1, "plus")])

    def test_a_prime_in_a_name_does_not_open_a_character(self) -> None:
        self.assertEqual(rules("let x' = \" +%d\" in x'"), [(1, "plus")])

    def test_quoted_strings_are_read(self) -> None:
        self.assertEqual(rules("{| +%d |}"), [(1, "plus")])
        self.assertEqual(rules("{id| +%d |id}"), [(1, "plus")])

    def test_lines_count_escaped_newlines(self) -> None:
        self.assertEqual(rules('let a = "one\\\n  two"\nlet b = " +%d"'), [(3, "plus")])


class ReadsMarkers(unittest.TestCase):
    def test_a_marker_on_the_line_above_frees_the_literal(self) -> None:
        source = '(* tui-value: vim line argument *)\nPrintf.sprintf "edit +%d" n'
        findings = check.judge(check.lex(source))
        self.assertEqual((len(findings.hits), findings.marked), (0, 1))

    def test_a_marker_on_the_same_line_frees_the_literal(self) -> None:
        self.assertEqual(rules('" +%d" (* tui-value: line argument *)'), [])

    def test_a_marker_two_lines_up_frees_nothing(self) -> None:
        source = '(* tui-value: too far *)\n\n" +%d"'
        self.assertEqual(rules(source), [(3, "plus")])

    def test_a_marker_with_no_reason_fails(self) -> None:
        findings = check.judge(check.lex('(* tui-value: *)\n" +%d"'))
        self.assertEqual(len(findings.empty_markers), 1)
        self.assertEqual([hit.rule.value for hit in findings.hits], ["plus"])


def _git(cwd: pathlib.Path, *args: str) -> str:
    env = {
        "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
        "LC_ALL": "C",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.com",
    }
    done = subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
    )
    return done.stdout.strip()


class ReadsChangedFiles(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory(prefix="masc-test-tui-value-")
        self.addCleanup(tmp.cleanup)
        self.work = pathlib.Path(tmp.name)
        _git(self.work, "init", "-q", "-b", "main")
        self._write("bin/masc_tui_old.ml", 'let old = " +%d"\n')
        _git(self.work, "add", "-A")
        _git(self.work, "commit", "-q", "-m", "base")

    def _write(self, relpath: str, content: str) -> None:
        path = self.work / relpath
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def _commit(self, message: str) -> str:
        _git(self.work, "add", "-A")
        _git(self.work, "commit", "-q", "-m", message)
        return _git(self.work, "rev-parse", "HEAD")

    def test_only_changed_tui_sources_are_read(self) -> None:
        self._write("bin/other.ml", 'let x = " +%d"\n')
        self._write("bin/tui/shell/guard.mli", 'val x : string (* " +%d" *)\n')
        merge = self._commit("outside the scope")
        self.assertEqual(check.changed_tui_files(str(self.work), merge), ())
        self.assertEqual(check.check(str(self.work), merge), 0)

    def test_a_changed_file_is_read_whole(self) -> None:
        self._write("bin/masc_tui_old.ml", 'let old = " +%d"\nlet fine = 1\n')
        merge = self._commit("touch a file that already had a hit")
        self.assertEqual(check.check(str(self.work), merge), 1)

    def test_files_split_under_bin_tui_are_read(self) -> None:
        self._write("bin/tui/shell/quit.ml", 'let x = " +%d unsent"\n')
        merge = self._commit("moved module")
        self.assertEqual(check.changed_tui_files(str(self.work), merge), ("bin/tui/shell/quit.ml",))
        self.assertEqual(check.check(str(self.work), merge), 1)

    def test_a_removed_file_is_not_read(self) -> None:
        (self.work / "bin/masc_tui_old.ml").unlink()
        merge = self._commit("remove")
        self.assertEqual(check.check(str(self.work), merge), 0)


if __name__ == "__main__":
    unittest.main()
