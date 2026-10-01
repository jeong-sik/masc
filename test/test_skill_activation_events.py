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
        session = "trace-ascii"
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

    def test_field_order_permutations_match_shared_server_revision(self):
        expected = json.loads((REPO_ROOT / "test/fixtures/skill-ledger-revision.json").read_text())
        def reverse_objects(value):
            if isinstance(value, dict):
                return {key: reverse_objects(child) for key, child in reversed(list(value.items()))}
            if isinstance(value, list):
                return [reverse_objects(child) for child in value]
            return value
        permuted = reverse_objects(expected)
        before = copy.deepcopy(permuted)
        self.assertEqual(events.ledger_revision(permuted), expected["revision"])
        self.assertEqual(permuted, before)
        raw = log_fixture.event_log(permuted)
        folded = events.fold_event_log(raw)
        self.assertEqual(folded["revision"], expected["revision"])
        self.assertEqual(json.dumps(folded, ensure_ascii=False), json.dumps(expected, ensure_ascii=False))
        reordered = copy.deepcopy(expected)
        reordered["activations"].reverse()
        self.assertNotEqual(events.ledger_revision(reordered), expected["revision"])

    def test_the_row_still_being_appended_is_left_out(self):
        expected = ledger()
        raw = log_fixture.event_log(expected) + b'{"kind":"activation_rec'

        self.assertEqual(events.fold_event_log(raw), expected)

    def test_an_empty_log_has_recorded_nothing(self):
        self.assertIsNone(events.fold_event_log(b""))

    # The server creates a log with its header and first event in one atomic
    # step, so bytes with no newline at all are not a log it wrote.
    def test_a_log_whose_first_row_has_no_newline_is_refused(self):
        with self.assertRaises(events.SkillLedgerError) as caught:
            events.fold_event_log(b'{"schema":"masc.skill-activation-events/v1"')

        self.assertIs(caught.exception.fault, Fault.UNTERMINATED_HEADER_ROW)

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

    # Yojson escapes U+007F the way it escapes the C0 controls, so the
    # revision hashes the escaped form.
    def test_revision_escapes_del_as_the_server_does(self):
        value = ledger()
        value["activations"] = [activation("call-\x7f", 7)]
        value["transition_rejections"] = []
        canonical = json.dumps({key: value[key] for key in
            ("workspace_key", "session_id", "activations", "transition_rejections")},
            ensure_ascii=False, separators=(",", ":")).replace("\x7f", "\\u007f")

        self.assertEqual(
            events.ledger_revision(value), hashlib.sha256(canonical.encode()).hexdigest()
        )

    def test_complete_rows_cannot_omit_any_evidence_field(self):
        # All rows are newline-terminated: these are corrupt evidence, not a
        # writer's partial tail. Exercise the public reader used by proof tools.
        recorded = log_fixture.recorded_row(activation("call-a", 7))
        delivered = log_fixture.delivery_row("call-a", delivery("model_response", 8))
        acted = log_fixture.action_row(["call-a"], action(CALL_ONE, 8))
        rejected = log_fixture.rejection_row(ledger()["transition_rejections"][0])
        cases = [
            ([header()], recorded, ("activation",)),
            ([header()], recorded, ("activation", "identity")),
            ([header()], recorded, ("activation", "invocation")),
            ([header()], recorded, ("activation", "invocation", "origin")),
            ([header()], recorded, ("activation", "invocation", "served_content")),
            ([header(), recorded], delivered, ("deliveries", 0, "delivery")),
            ([header(), recorded], delivered, ("deliveries", 0, "delivery", "boundary")),
            ([header(), recorded, delivered], acted, ("action",)),
            ([header(), recorded, delivered], acted, ("action", "identity")),
            ([header(), recorded], rejected, ("rejection",)),
        ]
        for prefix, event, path in cases:
            obj = event
            for key in path:
                obj = obj[key]
            for field in (*obj, "unexpected"):
                changed = copy.deepcopy(event)
                target = changed
                for key in path:
                    target = target[key]
                if field == "unexpected":
                    target[field] = None
                else:
                    del target[field]
                with self.subTest(path=path, field=field):
                    with self.assertRaises(events.SkillLedgerError) as caught:
                        events.fold_event_log(log_fixture.encode_rows(prefix + [changed]))
                    self.assertIs(caught.exception.fault, Fault.MALFORMED_EVENT)
                    self.assertEqual(caught.exception.row, len(prefix) + 1)

    def test_nested_invalid_evidence_is_refused_before_projection(self):
        recorded = log_fixture.recorded_row(activation("call-a", 7))
        delivered = log_fixture.delivery_row("call-a", delivery("model_response", 8))
        acted = log_fixture.action_row(["call-a"], action(CALL_ONE, 8))
        rejected = log_fixture.rejection_row(ledger()["transition_rejections"][0])
        cases = [
            (recorded, ("activation", "identity", "source_id"), ["..", "bad/name", 1]),
            (recorded, ("activation", "identity", "package_id"), ["", ".", "a/b", "a\\b", "a\0b"]),
            (recorded, ("activation", "identity", "name"), ["Review", " bad", "a_b", "a--b", "-a", "a-", "a" * 65]),
            (recorded, ("activation", "content_revision"), ["d" * 63, "D" * 64, None]),
            (recorded, ("activation", "snapshot_revision"), ["f" * 65, "g" * 64]),
            (recorded, ("activation", "runtime_id"), [" ", None]),
            (recorded, ("activation", "skill_tool_use_id"), ["\t", 12]),
            (recorded, ("activation", "agent_core_turn"), [-1, True, 7.0, 1 << 62]),
            (recorded, ("activation", "turn_ref"), ["other#7", SESSION + "#0", SESSION + "#bad", SESSION + "#-1"]),
            (recorded, ("activation", "activated_at"), ["today", "2026-02-30T00:00:00Z", "2026-09-29t00:00:00z", "2026-09-29T24:00:00Z", "2026-09-29T00:00:00+24:00"]),
            (recorded, ("activation", "invocation", "kind"), ["unknown", "composition"]),
            (recorded, ("activation", "invocation", "origin"), [
                {"kind": "session_composition"},
                {"kind": "task_instruction", "task_ids": []},
                {"kind": "task_instruction", "task_ids": ["task-1", "task-1"]},
                {"kind": "task_instruction", "task_ids": ["bad/id"]},
                {"kind": "task_instruction", "task_ids": [None]},
            ]),
            (recorded, ("activation", "invocation", "served_content", "bytes"), [-1, False, 1.5]),
            (recorded, ("activation", "invocation", "served_content", "sha256"), ["not-a-hash"]),
            (recorded, ("activation", "invocation", "served_content"), [
                {"kind": "skill_resource", "relative_path": path, "bytes": 1, "sha256": "e" * 64}
                for path in ("/abs", "../escape", "a//b", "a/./b", "a\\b", "a\0b")
            ]),
            (delivered, ("deliveries", 0, "delivery", "boundary", "kind"), ["unknown", None]),
            (delivered, ("deliveries", 0, "delivery", "boundary", "agent_core_turn"), [-1, True]),
            (delivered, ("deliveries", 0, "delivery", "runtime_id"), [" "]),
            (delivered, ("deliveries", 0, "delivery", "content_bytes"), [-1, True]),
            (delivered, ("deliveries", 0, "delivery", "content_sha256"), ["E" * 64]),
            (delivered, ("deliveries", 0, "delivery", "delivered_at"), ["not-time"]),
            (acted, ("action", "identity"), [
                {}, {"kind": "call_id", "call_id": " "},
                {"kind": "provider_step", "conversation_id": "c", "step_index": -1},
                {"kind": "provider_step", "conversation_id": "c", "step_index": True},
                {"kind": "provider_step", "conversation_id": " ", "step_index": 0},
            ]),
            (acted, ("action", "tool_name"), ["bad/tool", ".."]),
            (acted, ("action", "runtime_id"), [" "]),
            (acted, ("action", "agent_core_turn"), [-1, True]),
            (acted, ("action", "observed_at"), ["not-time"]),
            (rejected, ("rejection", "kind"), ["unknown"]),
            (rejected, ("rejection", "skill_tool_use_id"), [" "]),
            (rejected, ("rejection", "activation_turn_ref"), ["other#7", "broken"]),
            (rejected, ("rejection", "observed_turn_ref"), ["other#8", "broken"]),
            (rejected, ("rejection", "observed_agent_core_turn"), [-1, True]),
            (rejected, ("rejection", "observed_at"), ["not-time"]),
        ]
        for event, path, values in cases:
            prefix = [header()] if event is recorded else [header(), recorded]
            if event is acted:
                prefix.append(delivered)
            for value in values:
                changed = copy.deepcopy(event)
                target = changed
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.subTest(path=path, value=value):
                    with self.assertRaises(events.SkillLedgerError) as caught:
                        events.fold_event_log(log_fixture.encode_rows(prefix + [changed]))
                    self.assertIs(caught.exception.fault, Fault.MALFORMED_EVENT)
                    self.assertEqual(caught.exception.row, len(prefix) + 1)

    def test_all_invocation_and_rejection_variants_preserve_valid_evidence(self):
        for kind in ("instruction", "composition"):
            for scope in ("session", "task"):
                recorded = activation("call-a", 7)
                origin = {"kind": f"{scope}_{kind}"}
                if scope == "task":
                    origin["task_ids"] = ["task-1", "ns:task_2"]
                invocation = {"kind": kind, "origin": origin}
                if kind == "instruction":
                    invocation["served_content"] = {
                        "kind": "skill_resource", "relative_path": "docs/한글.md",
                        "bytes": 0, "sha256": "e" * 64,
                    }
                else:
                    invocation["tool_name"] = "keeper_status"
                recorded["invocation"] = invocation
                recorded["identity"]["name"] = "한글-é"
                recorded["identity"]["package_id"] = "Review package"
                rejections = []
                for rejection_kind in ("delivery_order", "delivery_conflict", "action_before_delivery"):
                    rejection = copy.deepcopy(ledger()["transition_rejections"][0])
                    rejection["kind"] = rejection_kind
                    if rejection_kind == "delivery_order":
                        rejection["activation_agent_core_turn"] = 7
                    if rejection_kind == "action_before_delivery":
                        rejection.update(action_identity=STEP_ZERO, tool_name="keeper_status")
                    rejections.append(rejection)
                rows = [header(), log_fixture.recorded_row(recorded)]
                rows.extend(log_fixture.rejection_row(r) for r in rejections)
                with self.subTest(kind=kind, scope=scope):
                    folded = events.fold_event_log(log_fixture.encode_rows(rows))
                    self.assertEqual(folded["activations"], [recorded])
                    self.assertEqual(folded["transition_rejections"], rejections)

    def test_variant_specific_evidence_fields_are_validated(self):
        recorded = log_fixture.recorded_row(activation("call-a", 7))
        order = copy.deepcopy(ledger()["transition_rejections"][0])
        order.update(kind="delivery_order", activation_agent_core_turn=7)
        before = copy.deepcopy(ledger()["transition_rejections"][0])
        before.update(kind="action_before_delivery", action_identity=STEP_ZERO,
                      tool_name="keeper_status")
        composition = copy.deepcopy(recorded)
        composition["activation"]["invocation"] = {
            "kind": "composition", "origin": {"kind": "session_composition"},
            "tool_name": "keeper_status"}
        cases = [
            (log_fixture.rejection_row(order), ("rejection", "activation_agent_core_turn"), -1),
            (log_fixture.rejection_row(before), ("rejection", "action_identity", "step_index"), -1),
            (log_fixture.rejection_row(before), ("rejection", "tool_name"), "bad/tool"),
            (composition, ("activation", "invocation", "tool_name"), "bad/tool"),
        ]
        for event, path, invalid in cases:
            for missing in (False, True):
                changed = copy.deepcopy(event)
                target = changed
                for key in path[:-1]:
                    target = target[key]
                if missing:
                    del target[path[-1]]
                else:
                    target[path[-1]] = invalid
                prefix = [header()] if event is composition else [header(), recorded]
                with self.subTest(path=path, missing=missing):
                    with self.assertRaises(events.SkillLedgerError):
                        events.fold_event_log(log_fixture.encode_rows(prefix + [changed]))

    def test_server_timestamp_forms_remain_readable(self):
        for stamp in ("0000-01-01T00:00:00Z", "9999-12-31T23:59:59Z",
                      "2026-08-27T00:00:60Z", "2026-08-27T00:00:01.1234567890123+09:00",
                      "2026-08-27T00:00:00-00:00"):
            recorded = activation("call-a", 7)
            recorded["activated_at"] = stamp
            with self.subTest(stamp=stamp):
                folded = events.fold_event_log(log_fixture.encode_rows([
                    header(), log_fixture.recorded_row(recorded)]))
                self.assertEqual(folded["activations"][0]["activated_at"], stamp)

    def test_invalid_trace_ids_cannot_start_a_ledger(self):
        for session in ("trace-é", "a" * 65, ".", "a/b", "", 1):
            with self.subTest(session=session):
                with self.assertRaises(events.SkillLedgerError) as caught:
                    events.fold_event_log(log_fixture.encode_rows([
                        log_fixture.header_row(WORKSPACE, session)]))
                self.assertIs(caught.exception.fault, Fault.MALFORMED_HEADER)

    def test_projection_enforces_server_ledger_wide_invariants(self):
        original = ledger()
        duplicate = copy.deepcopy(original)
        duplicate["activations"].append(activation("call-a", 11))
        orphan = copy.deepcopy(original)
        orphan["transition_rejections"][0]["skill_tool_use_id"] = "absent-call"
        mismatch = copy.deepcopy(original)
        mismatch["transition_rejections"][0]["activation_turn_ref"] = f"{SESSION}#9"
        # These are the exact of_projection_yojson error codes. A different
        # turn does not make a repeated call identity a new activation.
        for value, fault in (
            (duplicate, Fault.DUPLICATE_SKILL_TOOL_USE_ID),
            (orphan, Fault.ORPHAN_TRANSITION_REJECTION),
            (mismatch, Fault.TRANSITION_REJECTION_ACTIVATION_MISMATCH),
        ):
            with self.subTest(fault=fault):
                before = copy.deepcopy(value)
                with self.assertRaises(events.SkillLedgerError) as caught:
                    events.ledger_revision(value)
                self.assertIs(caught.exception.fault, fault)
                self.assertIsNone(caught.exception.row)
                self.assertEqual(value, before)

    def test_projection_shape_faults_have_no_event_log_row(self):
        fixture = json.loads((REPO_ROOT / "test/fixtures/skill-ledger-revision.json").read_text())
        for name in ("activations", "transition_rejections"):
            changed = copy.deepcopy(fixture)
            changed[name][0]["extra"] = 1
            with self.subTest(projection=name):
                with self.assertRaises(events.SkillLedgerError) as caught:
                    events.ledger_revision(changed)
                self.assertIs(caught.exception.fault, Fault.MALFORMED_LEDGER)
                self.assertIsNone(caught.exception.row)
                self.assertFalse(str(caught.exception).startswith("row "))

    def test_projection_preserves_specific_invariant_fault_without_a_row(self):
        value = ledger()
        value["activations"][0]["delivery"]["boundary"]["agent_core_turn"] = 1
        with self.assertRaises(events.SkillLedgerError) as caught:
            events.ledger_revision(value)
        self.assertIs(caught.exception.fault, Fault.INVALID_DELIVERY_AGENT_CORE_TURN)
        self.assertIsNone(caught.exception.row)

    def test_revision_of_a_ledger_without_its_identity_is_refused(self):
        value = ledger()
        del value["workspace_key"]

        with self.assertRaises(events.SkillLedgerError) as caught:
            events.ledger_revision(value)

        self.assertIs(caught.exception.fault, Fault.MALFORMED_LEDGER)
        self.assertIsNone(caught.exception.row)


if __name__ == "__main__":
    unittest.main()
