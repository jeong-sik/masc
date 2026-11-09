# pyright: strict
"""Tests for scripts/tinker/librarian/admission_request.py: prompt round trips.

Synthetic fixtures only (tinker_librarian_fixtures.py).
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import admission_request as R
import yojson_wire as W

from tinker_librarian_fixtures import (
    ADMISSION_POLICY,
    COMMENT,
    M1,
    M2,
    M3,
    MAIN,
    RETIREMENT_POLICY,
    RULE,
    make_prompt,
    make_template,
)


class PromptRoundTripTest(unittest.TestCase):
    def test_render_parse_round_trip(self) -> None:
        prompt = make_prompt()
        text = R.render(prompt)
        parsed = R.parse(text, prompt.template)
        assert isinstance(parsed, R.AdmissionPrompt), parsed
        self.assertEqual(parsed, prompt)
        self.assertEqual(R.render(parsed), text)

    def test_round_trip_with_retirement_section(self) -> None:
        template = make_template(RETIREMENT_POLICY)
        payload = '{"evidence_kind":"exact_identity_retirement_history","status":"unavailable","detail":"archive unreadable"}'
        prompt = make_prompt(template, retirement=R.RetirementSection(RETIREMENT_POLICY, payload))
        text = R.render(prompt)
        parsed = R.parse(text, template)
        assert isinstance(parsed, R.AdmissionPrompt), parsed
        self.assertEqual(parsed, prompt)

    def test_instructions_that_contain_the_next_heading(self) -> None:
        prompt = make_prompt(instructions="Copy this:\n\n### Memory\nnull\n\nand stop.")
        parsed = R.parse(R.render(prompt), prompt.template)
        assert isinstance(parsed, R.AdmissionPrompt), parsed
        self.assertEqual(parsed.keeper_instructions, prompt.keeper_instructions)

    def test_integral_times_write_as_floats(self) -> None:
        fact = R.ProposedFact(
            "x", "process", 1762588800, 1762588800, R.Origin("authored", "t"), R.Transcript()
        )
        self.assertIn(
            '"first_seen":1762588800.0,"last_seen":1762588800.0', W.write(R.proposed_fact_json(fact))
        )

    def test_parse_refuses_a_non_admission_section(self) -> None:
        text = R.render(make_prompt()).replace("[no messages]", "[turn=0] hello")
        self.assertIsInstance(R.parse(text, make_template()), R.ParseError)

    def test_template_from_markdown(self) -> None:
        markdown = (
            "---\nname: librarian\n---\n\n"
            + MAIN
            + "\n\n### working_contexts_rule\n"
            + RULE
            + "\n\n### admission_policy [primary: admission]\n"
            + ADMISSION_POLICY
            + "\n\n### retirement_policy\n"
            + RETIREMENT_POLICY
            + "\n"
        )
        loaded = R.template_from_markdown(markdown)
        self.assertEqual(loaded, make_template(RETIREMENT_POLICY))

    def test_derived_sections(self) -> None:
        prompt = make_prompt()
        lines = (
            f"- [category=release_schedule recorded=2026-11-01T09:00:00Z origin=injected basis=observed] {M1}",
            f"- [category=process recorded=2026-11-01T09:00:00Z origin=injected basis=observed board=p-release comment={COMMENT}] {M2}",
            f"- [category=process recorded=2026-11-03T10:30:00Z origin=authored basis=derived] {M3}",
        )
        size = len("\n".join(lines).encode("utf-8"))
        self.assertEqual(prompt.facts_budget, f"max=524288 bytes; current ordinary={size} bytes")
        self.assertIn(
            '"categories":[{"category":"process","count":2,"items_over_cap":0}', prompt.memory_limits
        )
        self.assertEqual(R.rfc3339_of_unix(1762588800.9), "2025-11-08T08:00:00Z")


if __name__ == "__main__":
    unittest.main()
