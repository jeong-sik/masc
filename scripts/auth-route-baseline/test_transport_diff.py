"""Tests of transport_diff.py.

  python3 -m unittest discover -s scripts/auth-route-baseline
"""

from __future__ import annotations

import unittest

from transport_diff import Difference, differences

ROW: dict[str, object] = {
    "method": "GET",
    "route_path": "/health",
    "probed_path": "/health",
    "http1_none": 200,
    "http1_bad": 200,
    "h2_none": 200,
    "h2_bad": 200,
}


class TransportDiffTest(unittest.TestCase):
    def test_equal_statuses_are_no_difference(self) -> None:
        self.assertEqual(differences([ROW], "default"), ())

    def test_a_differing_status_names_the_route_and_credential(self) -> None:
        row = dict(ROW, h2_bad=404)
        self.assertEqual(
            differences([row], "strict"),
            (Difference("strict", "GET", "/health", "/health", "bad", 200, 404),),
        )

    def test_both_credentials_can_differ_on_one_route(self) -> None:
        row = dict(ROW, h2_none=404, h2_bad=404)
        self.assertEqual([d.credential for d in differences([row], "default")], ["none", "bad"])

    def test_a_decimal_text_status_is_read_as_a_number(self) -> None:
        row = dict(ROW, h2_none="200")
        self.assertEqual(differences([row], "default"), ())

    def test_a_status_that_is_not_a_number_is_an_error(self) -> None:
        with self.assertRaises(ValueError):
            differences([dict(ROW, h2_none="timeout")], "default")


if __name__ == "__main__":
    unittest.main()
