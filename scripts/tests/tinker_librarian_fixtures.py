# pyright: strict
"""Synthetic admission prompt fixtures for the keeper-librarian admission tests.

An invented Keeper, memory and candidates. Nothing here comes from a MASC store.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import admission_request as R

MAIN = (
    "You organize Keeper memory.\n"
    "Budget: {{facts_budget}}\n"
    "Limits: `{{memory_limits}}`\n"
    "{{working_contexts_rule}}\n\n"
    "### Keeper\n{{keeper_id}}\n\n"
    "### Instructions\n{{keeper_instructions}}\n\n"
    "### Memory\n{{current_memory}}\n\n"
    "### Working context\n{{working_context}}\n\n"
    "### Goals\n{{goal_context}}\n\n"
    "### Past tasks\n{{historical_task_contexts}}\n\n"
    "### Conversation\n{{conversation_history}}\n\n"
    "### Counterpart\n{{counterpart_observations}}\n\n"
    "### Tools\n{{turn_tool_observations}}\n\n"
    "### Continuity\n{{continuity}}\nAnswer with JSON."
)


ADMISSION_POLICY = "Judge each candidate: incorporated, already_represented, not_durable or deferred."


RULE = "Group unprocessed input by situation."


RETIREMENT_POLICY = "These candidates match memories removed before."


M1 = "Releases ship on Fridays."


M2 = "QA signs off in the #qa channel."


M3 = "Hotfixes skip the release freeze."


NEW = "Releases ship on Thursdays now."


COMMENT = "c-" + "0123456789abcdef" * 2


def make_template(retirement: str | None = None) -> R.AdmissionTemplate:
    template = R.make_template(MAIN, ADMISSION_POLICY, RULE, retirement)
    assert isinstance(template, R.AdmissionTemplate), template
    return template


def make_prompt(
    template: R.AdmissionTemplate | None = None,
    instructions: str = "Keep release notes short.",
    retirement: R.RetirementSection | None = None,
) -> R.AdmissionPrompt:
    memory = R.CurrentMemory(
        (
            R.CurrentFact(
                M1,
                "release_schedule",
                "injected",
                R.Transcript(),
                "2026-11-01T09:00:00Z",
                "2026-11-02T09:00:00Z",
            ),
            R.CurrentFact(
                M2,
                "process",
                "injected",
                R.Board("p-release", COMMENT),
                "2026-11-01T09:00:00Z",
                "2026-11-01T09:00:00Z",
            ),
            R.CurrentFact(
                M3,
                "process",
                "authored",
                R.PremisePaths((("m1", None),)),
                "2026-11-03T10:30:00Z",
                "2026-11-03T10:30:00Z",
            ),
        )
    )
    candidates = (
        R.Candidate(
            "r1",
            7,
            R.ProposedFact(
                NEW,
                "release_schedule",
                1762588800.5,
                1762588800.5,
                R.Origin("authored", "trace-1"),
                R.Transcript(),
            ),
        ),
        R.Candidate(
            "r2",
            8,
            R.ProposedFact(
                M2,
                "process",
                1762588801.0,
                1762588801.0,
                R.Origin("authored", ""),
                R.Board("p-release", None),
            ),
        ),
        R.Candidate(
            "r3",
            9,
            R.ProposedFact(
                "Freeze starts Wednesday noon.",
                "release_schedule",
                1762588802.25,
                1762588802.25,
                R.Origin("injected", "trace-3"),
                R.Derived((R.Derivation("calendar", ("sha256:" + "a" * 64,)),)),
            ),
        ),
    )
    return R.AdmissionPrompt(
        template=template if template is not None else make_template(),
        keeper_id="release-steward",
        keeper_instructions=instructions,
        facts_budget=R.facts_budget_for(524288, memory),
        memory_limits=R.memory_limits_for(30, 30, memory),
        goal_context='{"status":"no_task"}',
        current_memory=memory,
        candidates=candidates,
        retirement=retirement,
    )
