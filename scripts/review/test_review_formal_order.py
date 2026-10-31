#!/usr/bin/env python3
"""Ordering and ambiguity of published GitHub review records."""
import importlib.util
import itertools
from pathlib import Path
import unittest


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("formal_order", HERE / "review-formal-order.py")
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)
T1 = "2026-10-08T03:45:54Z"
T2 = "2026-10-09T03:45:54Z"


def review(rid, state, submitted, actor="reviewer"):
    return {"id": rid, "state": state, "submitted_at": submitted, "user": {"login": actor}}


class FormalOrderCases(unittest.TestCase):
    def test_publication_order_overrides_numeric_ids(self):
        rows = [review(90, "CHANGES_REQUESTED", T1), review(77, "APPROVED", T2)]
        self.assertEqual(M.ordered_rows(rows), [("reviewer", 77, "APPROVED"),
                                                 ("reviewer", 90, "CHANGES_REQUESTED")])

    def test_multiple_accounts_are_grouped_without_losing_their_order(self):
        rows = [review(1, "APPROVED", T1, "z"), review(2, "CHANGES_REQUESTED", T1, "a"),
                review(3, "APPROVED", T2, "a")]
        self.assertEqual(M.ordered_rows(rows), [("a", 3, "APPROVED"),
                                                 ("a", 2, "CHANGES_REQUESTED"),
                                                 ("z", 1, "APPROVED")])

    def test_case_variants_group_as_one_account_and_ties_refuse(self):
        old = review(2, "CHANGES_REQUESTED", T1, "Reviewer")
        latest = review(3, "APPROVED", T2, "reviewer")
        self.assertEqual(M.ordered_rows([old, latest]), [("reviewer", 3, "APPROVED"),
                                                        ("reviewer", 2, "CHANGES_REQUESTED")])
        with self.assertRaises(ValueError):
            M.ordered_rows([old, latest | {"submitted_at": T1}])
        old["user"]["id"] = 1
        latest["user"]["id"] = 2
        with self.assertRaises(ValueError):
            M.ordered_rows([old, latest])
        latest["user"] = {"login": "another-name", "id": 1}
        with self.assertRaises(ValueError):
            M.ordered_rows([old, latest])

    def test_older_ties_do_not_obscure_the_unique_latest_review(self):
        reviews = [review(1, "CHANGES_REQUESTED", T1), review(2, "APPROVED", T1),
                   review(3, "APPROVED", T2)]
        for permutation in itertools.permutations(reviews):
            with self.subTest(permutation=permutation):
                rows = M.ordered_rows(permutation)
                self.assertEqual(rows[0], ("reviewer", 3, "APPROVED"))
                self.assertEqual(set(rows[1:]), {("reviewer", 1, "CHANGES_REQUESTED"),
                                                 ("reviewer", 2, "APPROVED")})

    def test_latest_tie_still_refuses_after_earlier_unambiguous_history(self):
        reviews = [review(1, "APPROVED", T1), review(2, "CHANGES_REQUESTED", T2),
                   review(3, "APPROVED", T2)]
        for permutation in itertools.permutations(reviews):
            with self.subTest(permutation=permutation), self.assertRaises(ValueError):
                M.ordered_rows(permutation)

    def test_ambiguous_missing_or_invalid_publication_time_refuses(self):
        for rows in ([review(1, "CHANGES_REQUESTED", T1), review(2, "APPROVED", T1)],
                     [review(1, "APPROVED", None)], [review(1, "APPROVED", "bad")],
                     [review(1, "APPROVED", "2026-10-08T03:45:54")]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                M.ordered_rows(rows)

    def test_duplicate_ids_or_missing_account_refuse(self):
        for rows in ([review(1, "APPROVED", T1), review(1, "APPROVED", T2)],
                     [review(1, "APPROVED", T1, "")]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                M.ordered_rows(rows)


if __name__ == "__main__":
    unittest.main()
