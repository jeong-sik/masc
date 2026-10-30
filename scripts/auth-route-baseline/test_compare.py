"""Tests of the rules in compare.py and logs_tail_diff.py.

  python3 -m unittest discover -s scripts/auth-route-baseline
"""

from __future__ import annotations

import hashlib
import re
import tempfile
import unittest
from pathlib import Path

import compare
import logs_tail_diff


class JudgeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.counter = 0

    def response(self, body: str | None, status: int = 200, headers: dict[str, str] | None = None) -> compare.Response:
        """A response whose body is kept in a file, or not kept when `body` is None."""
        path = None
        if body is not None:
            self.counter += 1
            path = self.dir / f"{self.counter}.txt"
            path.write_text(body, encoding="utf-8")
        digest = hashlib.sha256((body or "").encode()).hexdigest()
        return compare.Response(status=status, headers=headers or {}, body_sha256=digest, body_path=path)

    def test_same_body_has_no_problem(self) -> None:
        verdict = compare.judge(self.response('{"a":1}'), self.response('{"a":1}'), None, [])
        self.assertEqual(verdict.problems, [])
        self.assertEqual(verdict.body, "same")

    def test_status_change_is_a_problem(self) -> None:
        verdict = compare.judge(self.response("{}", status=200), self.response("{}", status=403), None, [])
        self.assertEqual(verdict.problems, ["status 200 -> 403"])

    def test_header_change_is_a_problem_unless_the_before_runs_disagree_on_it(self) -> None:
        old = self.response("{}", headers={"x-mode": "1"})
        new = self.response("{}", headers={"x-mode": "2"})
        steady = self.response("{}", headers={"x-mode": "1"})
        moving = self.response("{}", headers={"x-mode": "3"})
        self.assertEqual(compare.judge(old, new, steady, []).problems, ["headers differ: ['x-mode']"])
        self.assertEqual(compare.judge(old, new, moving, []).problems, [])

    def test_response_whose_status_moves_between_before_runs_is_skipped(self) -> None:
        verdict = compare.judge(self.response("{}", status=200), self.response("{}", status=500), self.response("{}", status=503), [])
        self.assertTrue(verdict.skipped)
        self.assertEqual(verdict.problems, [])

    def test_body_the_before_runs_agree_on_must_be_the_same_after(self) -> None:
        old = self.response('{"a":1,"b":1}')
        new = self.response('{"a":2,"b":1}')
        verdict = compare.judge(old, new, self.response('{"a":1,"b":1}'), [])
        self.assertEqual(verdict.problems, ["fields differ: ['.a']"])

    def test_ignored_field_may_differ_where_the_before_runs_agree(self) -> None:
        old = self.response('{"a":1,"b":1}')
        new = self.response('{"a":2,"b":1}')
        ignore = [re.compile(r"^\.a$")]
        verdict = compare.judge(old, new, self.response('{"a":1,"b":1}'), ignore)
        self.assertEqual(verdict.problems, [])
        self.assertEqual(verdict.body, "fields")

    def test_ignored_field_does_not_hide_another_field(self) -> None:
        old = self.response('{"a":1,"b":1}')
        new = self.response('{"a":2,"b":2}')
        verdict = compare.judge(old, new, self.response('{"a":1,"b":1}'), [re.compile(r"^\.a$")])
        self.assertEqual(verdict.problems, ["fields differ: ['.b']"])

    def test_array_index_is_written_as_brackets_in_a_rule(self) -> None:
        old = self.response('{"rows":[{"ms":1},{"ms":2}]}')
        new = self.response('{"rows":[{"ms":5},{"ms":6}]}')
        verdict = compare.judge(old, new, self.response('{"rows":[{"ms":1},{"ms":2}]}'), [re.compile(r"^\.rows\[\]\.ms$")])
        self.assertEqual(verdict.problems, [])

    def test_field_that_exists_on_one_side_only_is_a_difference(self) -> None:
        old = self.response('{"a":1}')
        new = self.response('{"a":1,"extra":true}')
        verdict = compare.judge(old, new, self.response('{"a":1}'), [])
        self.assertEqual(verdict.problems, ["fields differ: ['.extra']"])

    def test_body_that_is_not_kept_differs_when_the_hashes_differ(self) -> None:
        verdict = compare.judge(self.response(None), self.response("other"), None, [])
        self.assertEqual(verdict.problems, ["body differs"])

    def test_fields_that_moved_between_the_before_runs_are_not_compared(self) -> None:
        old = self.response('{"a":1,"b":1}')
        noise = self.response('{"a":2,"b":1}')
        new = self.response('{"a":3,"b":2}')
        verdict = compare.judge(old, new, noise, [])
        self.assertEqual(verdict.problems, ["fields differ: ['.b']"])
        self.assertEqual(verdict.fields_checked, 1)

    def test_body_that_is_not_json_is_not_compared_when_the_before_runs_disagree(self) -> None:
        verdict = compare.judge(self.response("<p>1</p>"), self.response("<p>3</p>"), self.response("<p>2</p>"), [])
        self.assertEqual(verdict.problems, [])
        self.assertEqual(verdict.body, "unverified")


class IgnoreRuleTest(unittest.TestCase):
    def test_a_rule_without_scope_applies_to_every_route(self) -> None:
        rule = compare.parse_ignore_rule(r"^\.uptime$")
        self.assertTrue(rule.applies_to("GET", "/a"))
        self.assertTrue(rule.applies_to("POST", "/b"))

    def test_a_rule_with_scope_applies_to_that_method_and_route_only(self) -> None:
        rule = compare.parse_ignore_rule(r"GET /api/v1/x :: ^\.total$")
        self.assertEqual(rule.pattern.pattern, r"^\.total$")
        self.assertTrue(rule.applies_to("GET", "/api/v1/x"))
        self.assertFalse(rule.applies_to("GET", "/api/v1/y"))
        self.assertFalse(rule.applies_to("POST", "/api/v1/x"))

    def test_a_scope_without_a_route_is_refused(self) -> None:
        with self.assertRaises(SystemExit):
            compare.parse_ignore_rule("GET :: ^x$")
        with self.assertRaises(SystemExit):
            compare.parse_ignore_rule("GET x :: ^x$")

    def test_the_rules_this_repo_ships_all_parse(self) -> None:
        text = (Path(__file__).parent / "volatile_fields.txt").read_text(encoding="utf-8")
        rules = [compare.parse_ignore_rule(line.strip()) for line in text.splitlines() if line.strip() and not line.startswith("#")]
        self.assertGreater(len(rules), 0)
        self.assertTrue(any(rule.scope is not None for rule in rules))


class LogsTailDiffTest(unittest.TestCase):
    def test_rejection_lines_agree_as_far_as_both_windows_reach(self) -> None:
        self.assertTrue(logs_tail_diff.same_where_both_reach(["a", "b", "c"], ["a", "b"]))
        self.assertTrue(logs_tail_diff.same_where_both_reach([], ["a"]))

    def test_a_different_rejection_line_is_found(self) -> None:
        self.assertFalse(logs_tail_diff.same_where_both_reach(["a", "x"], ["a", "b"]))

    def test_only_rejection_lines_are_taken(self) -> None:
        messages = ["HTTP auth rejected: h1 /a -> 401", "periodic task gc", "HTTP auth rejected: h2 /b -> 403"]
        self.assertEqual(
            logs_tail_diff.rejections(messages),
            ["HTTP auth rejected: h1 /a -> 401", "HTTP auth rejected: h2 /b -> 403"],
        )

    def test_one_sided_lines_are_marked_by_side(self) -> None:
        self.assertEqual(logs_tail_diff.one_sided(["a", "b", "c"], ["a", "x", "c"]), ["- b", "+ x"])
        self.assertEqual(logs_tail_diff.one_sided(["a"], ["a"]), [])


if __name__ == "__main__":
    unittest.main()
