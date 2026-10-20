#!/usr/bin/env python3
"""The capture-tui-* scripts hide a keeper name, and every prefix a column shows."""

from pathlib import Path
import sys
import unittest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts" / "lib"))

import tui_capture_redaction as redaction  # noqa: E402

LONG = "rw-e0-r9-20260820-review"  # the 24-cell name the Lanes frame leaked
OTHER = "taskmaster"


def apply(pairs, text):
    """What the page's redaction script does to one text node."""
    for source, target in pairs:
        text = text.replace(source, target)
    return text


class RedactionPairs(unittest.TestCase):
    def test_every_stand_in_keeps_the_width_of_what_it_covers(self):
        for source, target in redaction.redaction_pairs([LONG, OTHER]):
            self.assertEqual(len(source), len(target), (source, target))

    def test_the_full_name_goes_to_the_placeholder(self):
        pairs = redaction.redaction_pairs([LONG, OTHER])
        self.assertEqual(apply(pairs, LONG), redaction.placeholder_for(LONG, 1))

    def test_a_truncated_name_is_covered(self):
        pairs = redaction.redaction_pairs([LONG, OTHER])
        for cut in range(redaction.MIN_PREFIX_LEN, len(LONG)):
            shown = LONG[:cut] + "…"
            hidden = apply(pairs, shown)
            self.assertNotIn(LONG[: redaction.MIN_PREFIX_LEN], hidden, shown)
            self.assertEqual(len(hidden), len(shown), shown)

    def test_longer_matches_come_first(self):
        lengths = [
            len(source) for source, _ in redaction.redaction_pairs([LONG, OTHER])
        ]
        self.assertEqual(lengths, sorted(lengths, reverse=True))

    def test_a_prefix_that_is_another_keepers_name_is_left_to_that_keeper(self):
        longer, shorter = "code-reviewer-escalation", "code-reviewer"
        names = sorted([longer, shorter], key=len, reverse=True)
        pairs = redaction.redaction_pairs(names)
        sources = [source for source, _ in pairs]
        self.assertEqual(sources.count(shorter), 1)
        self.assertEqual(
            dict((source, target) for source, target in pairs)[shorter],
            redaction.placeholder_for(shorter, 2),
        )

    def test_a_prefix_two_keepers_share_has_one_stand_in(self):
        a, b = "rw-e0-r9-20260820-review", "rw-e0-r9-20260820-impl"
        names = sorted([a, b], key=len, reverse=True)
        sources = [source for source, _ in redaction.redaction_pairs(names)]
        self.assertEqual(len(sources), len(set(sources)))


class LeakedNames(unittest.TestCase):
    def test_a_surviving_full_name_is_reported(self):
        self.assertEqual(redaction.leaked_names([LONG], f"actor {LONG} ok"), [LONG])

    def test_a_surviving_truncated_name_is_reported(self):
        self.assertEqual(redaction.leaked_names([LONG], f"actor {LONG[:18]}…"), [LONG])

    def test_a_redacted_frame_reports_nothing(self):
        pairs = redaction.redaction_pairs([LONG, OTHER])
        frame = apply(pairs, f"{LONG}  {LONG[:18]}…  {LONG[:15]}~  {OTHER}")
        self.assertEqual(redaction.leaked_names([LONG, OTHER], frame), [])

    def test_a_short_prefix_is_not_a_name(self):
        self.assertEqual(redaction.leaked_names([LONG], "rw-e0-r9 is a label"), [])


if __name__ == "__main__":
    unittest.main()
