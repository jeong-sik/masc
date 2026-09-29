"""Folding a Skill activation event log into the ledger the Dashboard serves."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import unittest

import skill_activation_event_log_fixture as log_fixture


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = (
    REPO_ROOT / "scripts" / "harness" / "workload" / "skill_activation_events.py"
)
sys.path.insert(0, str(SCRIPT_PATH.parent))


def load_module():
    spec = importlib.util.spec_from_file_location(
        "skill_activation_events", SCRIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


events = load_module()
Fault = events.SkillLedgerFault
WORKSPACE = "c" * 64
SESSION = "trace-one"


def delivery(kind, turn):
    return {
        "boundary": {"kind": kind, "agent_core_turn": turn},
        "runtime_id": "runtime-one",
        "delivered_at": "2026-08-27T00:00:02Z",
        "content_bytes": 12,
        "content_sha256": "e" * 64,
    }


def action(identity, turn):
    return {
        "identity": identity,
        "tool_name": "keeper_status",
        "runtime_id": "runtime-one",
        "agent_core_turn": turn,
        "observed_at": "2026-08-27T00:00:03Z",
    }


def activation(skill_tool_use_id, turn, *, delivered=None, actions=()):
    return {
        "identity": {
            "source_id": "workspace",
            "package_id": "review",
            "name": "review",
        },
        "content_revision": "d" * 64,
        "snapshot_revision": "f" * 64,
        "turn_ref": f"{SESSION}#{turn}",
        "runtime_id": "runtime-one",
        "skill_tool_use_id": skill_tool_use_id,
        "agent_core_turn": turn,
        "invocation": {
            "kind": "instruction",
            "origin": {"kind": "session_instruction"},
            "served_content": {"kind": "skill_body", "bytes": 12, "sha256": "e" * 64},
        },
        "delivery": delivered,
        "actions": list(actions),
        "activated_at": "2026-08-27T00:00:01Z",
    }


CALL_ONE = {"kind": "call_id", "call_id": "action-one"}
STEP_ZERO = {
    "kind": "provider_step",
    "conversation_id": "conversation",
    "step_index": 0,
}


def ledger():
    value = {
        "schema": "masc.skill-activations/v5",
        "workspace_key": WORKSPACE,
        "session_id": SESSION,
        "revision": "",
        "activations": [
            activation(
                "call-a",
                7,
                delivered=delivery("model_response", 8),
                actions=[action(CALL_ONE, 8), action(STEP_ZERO, 9)],
            ),
            activation(
                "call-b",
                9,
                delivered=delivery("official_client_result_handoff", 9),
                actions=[action(CALL_ONE, 9)],
            ),
            activation("call-c", 10),
        ],
        "transition_rejections": [
            {
                "kind": "delivery_conflict",
                "skill_tool_use_id": "call-a",
                "activation_turn_ref": f"{SESSION}#7",
                "observed_turn_ref": f"{SESSION}#8",
                "observed_agent_core_turn": 8,
                "observed_at": "2026-08-27T00:00:04Z",
            }
        ],
    }
    value["revision"] = events.ledger_revision(value)
    return value


def header():
    return log_fixture.header_row(WORKSPACE, SESSION)


class SkillActivationEventsTest(unittest.TestCase):
    def test_folding_the_log_of_a_ledger_returns_that_ledger(self):
        expected = ledger()

        folded = events.fold_event_log(log_fixture.event_log(expected))

        self.assertEqual(folded, expected)
        self.assertEqual(
            list(folded),
            [
                "schema",
                "workspace_key",
                "session_id",
                "revision",
                "activations",
                "transition_rejections",
            ],
        )
        self.assertEqual(
            [list(item) for item in folded["activations"]],
            [list(item) for item in expected["activations"]],
        )
        self.assertEqual(folded["revision"], events.ledger_revision(folded))

    def test_a_header_alone_is_an_empty_ledger_hashed_as_compact_utf8(self):
        session = "trace-é"
        raw = log_fixture.encode_rows([log_fixture.header_row(WORKSPACE, session)])

        folded = events.fold_event_log(raw)

        canonical = (
            '{"workspace_key":"' + WORKSPACE + '","session_id":"' + session + '",'
            '"activations":[],"transition_rejections":[]}'
        )
        self.assertEqual(folded["activations"], [])
        self.assertEqual(folded["transition_rejections"], [])
        self.assertEqual(
            folded["revision"], hashlib.sha256(canonical.encode()).hexdigest()
        )

    def test_the_row_still_being_appended_is_left_out(self):
        expected = ledger()
        raw = log_fixture.event_log(expected) + b'{"kind":"activation_rec'

        self.assertEqual(events.fold_event_log(raw), expected)

    def test_a_log_without_a_complete_row_has_recorded_nothing(self):
        self.assertIsNone(events.fold_event_log(b""))
        self.assertIsNone(
            events.fold_event_log(b'{"schema":"masc.skill-activation-events/v1"')
        )

    def test_one_action_observed_for_two_activations_reaches_both(self):
        first = activation("call-a", 7)
        second = activation("call-b", 7)
        shared = action(CALL_ONE, 8)
        raw = log_fixture.encode_rows(
            [
                header(),
                log_fixture.recorded_row(first),
                log_fixture.recorded_row(second),
                log_fixture.delivery_row("call-a", delivery("model_response", 8)),
                log_fixture.delivery_row("call-b", delivery("model_response", 8)),
                log_fixture.action_row(["call-a", "call-b"], shared),
            ]
        )

        folded = events.fold_event_log(raw)

        first_actions = folded["activations"][0]["actions"]
        second_actions = folded["activations"][1]["actions"]
        self.assertEqual(first_actions, [shared])
        self.assertEqual(second_actions, [shared])
        self.assertIsNot(first_actions[0], second_actions[0])

    def test_rows_the_ledger_rules_refuse_raise_a_typed_fault(self):
        recorded = log_fixture.recorded_row(activation("call-a", 7))
        delivered = log_fixture.delivery_row("call-a", delivery("model_response", 8))
        acted = log_fixture.action_row(["call-a"], action(CALL_ONE, 8))
        rejection = copy.deepcopy(ledger()["transition_rejections"][0])
        wrong_schema = header()
        wrong_schema["schema"] = "masc.skill-activation-events/v0"
        extra_field = copy.deepcopy(recorded)
        extra_field["observed_at"] = "2026-08-27T00:00:00Z"
        mismatched_rejection = copy.deepcopy(rejection)
        mismatched_rejection["activation_turn_ref"] = f"{SESSION}#6"
        wrong_kind = header()
        wrong_kind["kind"] = "activation_recorded"
        wrong_key = header()
        wrong_key["workspace_key"] = "C" * 64
        extra_header_field = header()
        extra_header_field["created_at"] = "2026-08-27T00:00:00Z"
        twice_delivered = copy.deepcopy(delivered)
        twice_delivered["deliveries"] *= 2
        surrogate = copy.deepcopy(recorded)
        surrogate["activation"]["runtime_id"] = "runtime-\udc00"

        def rows(*values):
            return log_fixture.encode_rows(list(values))

        cases = [
            (
                "a delivery for an unrecorded activation",
                rows(header(), delivered),
                Fault.UNKNOWN_EVENT_ACTIVATION,
                2,
            ),
            (
                "an activation recorded twice",
                rows(header(), recorded, recorded),
                Fault.DUPLICATE_SKILL_TOOL_USE_ID,
                3,
            ),
            (
                "a second delivery",
                rows(header(), recorded, delivered, delivered),
                Fault.DELIVERY_ALREADY_OBSERVED,
                4,
            ),
            (
                "an action before any delivery",
                rows(header(), recorded, acted),
                Fault.ACTION_TARGET_NOT_DELIVERED,
                3,
            ),
            (
                "an empty row between rows",
                rows(header()) + b"\n" + rows(recorded),
                Fault.BLANK_EVENT_ROW,
                2,
            ),
            (
                "another header schema",
                rows(wrong_schema, recorded),
                Fault.UNSUPPORTED_SCHEMA,
                1,
            ),
            (
                "an activation recorded with its delivery",
                rows(
                    header(),
                    {
                        "kind": "activation_recorded",
                        "activation": activation(
                            "call-a", 7, delivered=delivery("model_response", 8)
                        ),
                    },
                ),
                Fault.ACTIVATION_RECORDED_WITH_EVIDENCE,
                2,
            ),
            (
                "a model response in the activation's own turn",
                rows(
                    header(),
                    recorded,
                    log_fixture.delivery_row("call-a", delivery("model_response", 7)),
                ),
                Fault.INVALID_DELIVERY_AGENT_CORE_TURN,
                3,
            ),
            (
                "an action before the delivery's turn",
                rows(
                    header(),
                    recorded,
                    delivered,
                    log_fixture.action_row(["call-a"], action(CALL_ONE, 7)),
                ),
                Fault.INVALID_ACTION_AGENT_CORE_TURN,
                4,
            ),
            (
                "the same action identity twice",
                rows(header(), recorded, delivered, acted, acted),
                Fault.DUPLICATE_ACTION_IDENTITY,
                5,
            ),
            (
                "a rejection for an unrecorded activation",
                rows(header(), log_fixture.rejection_row(rejection)),
                Fault.ORPHAN_TRANSITION_REJECTION,
                2,
            ),
            (
                "a rejection naming another turn",
                rows(
                    header(), recorded, log_fixture.rejection_row(mismatched_rejection)
                ),
                Fault.TRANSITION_REJECTION_ACTIVATION_MISMATCH,
                3,
            ),
            (
                "an unknown event kind",
                rows(header(), {"kind": "activation_forgotten"}),
                Fault.INVALID_EVENT_KIND,
                2,
            ),
            (
                "an event with a field the writer never writes",
                rows(header(), extra_field),
                Fault.MALFORMED_EVENT,
                2,
            ),
            (
                "a row repeating a field",
                rows(header()) + b'{"kind":"activation_recorded","kind":"x"}\n',
                Fault.DUPLICATE_FIELD,
                2,
            ),
            (
                "a row that is not JSON",
                rows(header()) + b"{not json}\n",
                Fault.MALFORMED_ROW,
                2,
            ),
            (
                "an official-client handoff before its activation's turn",
                rows(
                    header(),
                    recorded,
                    log_fixture.delivery_row(
                        "call-a", delivery("official_client_result_handoff", 6)
                    ),
                ),
                Fault.INVALID_DELIVERY_AGENT_CORE_TURN,
                3,
            ),
            (
                "one row delivering an activation twice",
                rows(header(), recorded, twice_delivered),
                Fault.DELIVERY_ALREADY_OBSERVED,
                3,
            ),
            (
                "one row naming an action target twice",
                rows(
                    header(),
                    recorded,
                    delivered,
                    log_fixture.action_row(["call-a", "call-a"], action(CALL_ONE, 8)),
                ),
                Fault.DUPLICATE_ACTION_IDENTITY,
                4,
            ),
            (
                "an action for an unrecorded activation",
                rows(
                    header(),
                    recorded,
                    delivered,
                    log_fixture.action_row(["call-z"], action(CALL_ONE, 8)),
                ),
                Fault.UNKNOWN_EVENT_ACTIVATION,
                4,
            ),
            (
                "a header of another kind",
                rows(wrong_kind),
                Fault.INVALID_EVENT_KIND,
                1,
            ),
            (
                "a header whose workspace key is not lowercase hex",
                rows(wrong_key),
                Fault.MALFORMED_HEADER,
                1,
            ),
            (
                "a header with a field the writer never writes",
                rows(extra_header_field),
                Fault.MALFORMED_HEADER,
                1,
            ),
            (
                "an empty row at the end",
                rows(header(), recorded) + b"\n",
                Fault.BLANK_EVENT_ROW,
                3,
            ),
            (
                "an escaped unpaired surrogate",
                rows(header()) + json.dumps(surrogate).encode() + b"\n",
                Fault.MALFORMED_LEDGER,
                None,
            ),
        ]
        for name, raw, fault, row in cases:
            with self.subTest(name):
                with self.assertRaises(events.SkillLedgerError) as caught:
                    events.fold_event_log(raw)
                self.assertIs(caught.exception.fault, fault)
                self.assertEqual(caught.exception.row, row)

    def test_revision_of_a_ledger_without_its_identity_is_refused(self):
        value = ledger()
        del value["workspace_key"]

        with self.assertRaises(events.SkillLedgerError) as caught:
            events.ledger_revision(value)

        self.assertIs(caught.exception.fault, Fault.MALFORMED_LEDGER)
        self.assertIsNone(caught.exception.row)


if __name__ == "__main__":
    unittest.main()
