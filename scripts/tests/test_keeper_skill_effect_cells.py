"""What a Keeper Skill proof bundle passes once selection, effect and state are counted apart.

Each case builds the Keeper's tool-calls answer and Memory files the way the
server lays them out, collects them with the proof collector, and judges the
collected directory with the offline verifier.
"""

from __future__ import annotations

from hashlib import sha256
import json
import pathlib
import sys
import tempfile
import unittest
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/harness/workload"))

import keeper_skill_effect_cells as cells  # noqa: E402
import keeper_skill_use_proof as collector  # noqa: E402
import verify_keeper_skill_proof_bundle as verifier  # noqa: E402

KEEPER = "sound"
TRACE = "trace-abc"
KEEPER_TURN = 3
TURN_REF = f"{TRACE}#{KEEPER_TURN}"
WRITE_CALL_ID = "call-write"
CLAIM = "evidence-marker says 7f3a"
MEMORY_ID = "sha256:" + sha256(CLAIM.encode()).hexdigest()
TOOL_CALLS_URL = f"http://127.0.0.1:8935/api/v1/keepers/{KEEPER}/tool-calls?limit=200"
ACTIONS: list[Any] = [
    {
        "identity": {"kind": "call_id", "call_id": "call-read"},
        "tool_name": "keeper_fs_read",
        "runtime_id": "rt",
        "agent_core_turn": 2,
        "observed_at": "2026-11-14T00:00:01Z",
    },
    {
        "identity": {"kind": "call_id", "call_id": WRITE_CALL_ID},
        "tool_name": cells.MEMORY_WRITE_TOOL,
        "runtime_id": "rt",
        "agent_core_turn": 3,
        "observed_at": "2026-11-14T00:00:02Z",
    },
]
SELECTION: dict[str, Any] = {
    "schema": cells.SCENARIO_SCHEMA,
    "requires": "action_selected",
}
EFFECT: dict[str, Any] = {
    "schema": cells.SCENARIO_SCHEMA,
    "requires": "external_effect_applied",
    "effect": {"kind": "current_memory_write"},
}
DURABLE: dict[str, Any] = {
    **EFFECT,
    "requires": "requested_postcondition_observed",
    "postcondition": {"kind": "keeper_memory_retained"},
}
WRITTEN_RECEIPT: dict[str, Any] = {
    "ok": True,
    "error_kind": "none",
    "identity_disposition": "inserted",
    "rows_written": 1,
    "revision": 1,
    "recorded_at": "2026-11-14T00:00:03Z",
    "outcome": cells.MEMORY_WRITE_CURRENT_OUTCOME,
    "store": "current_memory_snapshot",
    "memory_id": MEMORY_ID,
}


def jsonl(rows: list[dict[str, Any]]) -> bytes:
    return b"".join(json.dumps(row).encode() + b"\n" for row in rows)


def fact(claim: str) -> dict[str, Any]:
    return {
        "claim": claim,
        "category": "fact",
        "first_seen": 1.0,
        "last_seen": 1.0,
        "origin": {"kind": "authored", "trace_id": TRACE},
        "basis": {"kind": "observed", "observation": {"kind": "transcript"}},
    }


def change(
    added: list[dict[str, Any]], removed: list[dict[str, Any]], retained: int
) -> dict[str, Any]:
    return {"added": added, "removed": removed, "retained": retained, "invalidated": []}


def tool_call_row(call_id: str, tool: str, output: str) -> dict[str, Any]:
    return {
        "ts": 3.0,
        "record_kind": "tool_call",
        "keeper": KEEPER,
        "tool": tool,
        "input": {},
        "output": output,
        "duration_ms": 4.0,
        "tool_use_id": call_id,
        "trace_id": TRACE,
        "session_id": TRACE,
        "keeper_turn_id": KEEPER_TURN,
    }


class Workspace:
    """One server workspace: the Keeper's tool calls and Memory files."""

    def __init__(self, root: pathlib.Path) -> None:
        self.keepers_dir = root / "base" / ".masc" / "config" / "keepers"
        self.out = root / "proof"
        self.keepers_dir.mkdir(parents=True)
        self.out.mkdir()
        self.out = self.out.resolve(strict=True)
        self.tool_calls = b""
        self.calls(receipt=WRITTEN_RECEIPT)

    def calls(self, *, receipt: dict[str, Any]) -> None:
        answer = {
            "keeper": KEEPER,
            "count": 2,
            "source": "tool_call_io",
            "entries": [
                tool_call_row("call-read", "keeper_fs_read", "marker 7f3a"),
                tool_call_row(WRITE_CALL_ID, cells.MEMORY_WRITE_TOOL, json.dumps(receipt)),
            ],
        }
        self.tool_calls = json.dumps(answer).encode()

    def memory(self, *, librarian_removed: bool, write_trace: str = TRACE) -> None:
        written: dict[str, Any] = {
            "outcome": "committed",
            "commit_effect": "rewritten",
            "recorded_at": 3.0,
            "revision": 1,
            "source": {"kind": "explicit_write", "trace_id": write_trace},
            "change": change([fact(CLAIM)], [], 0),
            "revision_links": [],
        }
        rows: list[dict[str, Any]] = [written]
        current: dict[str, Any] = {
            "revision": 1,
            "updated_at": 3.0,
            "source": {"kind": "explicit_write", "trace_id": write_trace},
            "facts": [fact(CLAIM)],
            "change": change([fact(CLAIM)], [], 0),
        }
        if librarian_removed:
            rows.append(
                {
                    "outcome": "committed",
                    "commit_effect": "rewritten",
                    "recorded_at": 4.0,
                    "revision": 2,
                    "source": {"kind": "librarian", "trace_id": "librarian-trace"},
                    "change": change([], [fact(CLAIM)], 0),
                    "revision_links": [],
                }
            )
            current = {
                "revision": 2,
                "updated_at": 4.0,
                "source": {"kind": "librarian", "trace_id": "librarian-trace"},
                "facts": [],
                "change": change([], [fact(CLAIM)], 0),
            }
        (self.keepers_dir / f"{KEEPER}.memory-journal.jsonl").write_bytes(jsonl(rows))
        (self.keepers_dir / f"{KEEPER}.memory-current.json").write_text(
            json.dumps(current)
        )

    def collect(self, scenario: dict[str, Any]) -> dict[str, Any]:
        decoded = cells.decode_scenario(scenario)
        reads_memory = not isinstance(decoded, cells.SelectionScenario)
        observed, authorities = collector.collect_effect_authorities(
            scenario=decoded,
            keeper=KEEPER,
            turn_ref=TURN_REF,
            actions=ACTIONS,
            tool_calls=(TOOL_CALLS_URL, self.tool_calls) if reads_memory else None,
            memory_current_path=self.keepers_dir / f"{KEEPER}.memory-current.json"
            if reads_memory
            else None,
            out=self.out,
        )
        receipt = {"scenario": {"bytes": 1, "sha256": "1" * 64, "declaration": scenario}}
        receipt_raw = json.dumps(receipt).encode()
        return {
            "receipt": receipt,
            "receipt_raw": receipt_raw,
            "proof": {
                "scenario": {
                    "producer_receipt_sha256": sha256(receipt_raw).hexdigest(),
                    "declaration": scenario,
                },
                "authorities": authorities,
                "cells": observed,
            },
        }

    def verify(self, bundle: dict[str, Any]) -> dict[str, Any]:
        verified, _artifacts = verifier.verify_effect_cells(
            proof=bundle["proof"],
            proof_root=self.out,
            receipt=bundle["receipt"],
            receipt_raw=bundle["receipt_raw"],
            keeper=KEEPER,
            turn_ref=TURN_REF,
            actions=ACTIONS,
        )
        return verified


class KeeperSkillEffectCellsTest(unittest.TestCase):
    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.workspace = Workspace(pathlib.Path(self._temp.name))

    def tearDown(self) -> None:
        self._temp.cleanup()

    def test_durable_scenario_fails_when_the_librarian_removed_the_applied_write(
        self,
    ) -> None:
        self.workspace.memory(librarian_removed=True)
        bundle = self.workspace.collect(DURABLE)

        with self.assertRaises(verifier.VerificationError) as raised:
            self.workspace.verify(bundle)

        detail = str(raised.exception)
        self.assertIn("scenario requires requested_postcondition_observed", detail)
        self.assertIn('"removed_in_revision": 2', detail)
        self.assertIn('"removed_by": "librarian"', detail)
        recorded = bundle["proof"]["cells"]
        self.assertEqual(recorded["action_selected"]["observed"], 1)
        self.assertEqual(recorded["external_effect_applied"]["observed"], 1)
        self.assertEqual(recorded["requested_postcondition_observed"]["observed"], 0)

    def test_effect_scenario_passes_on_the_same_workspace(self) -> None:
        self.workspace.memory(librarian_removed=True)

        verified = self.workspace.verify(self.workspace.collect(EFFECT))

        effect = verified["external_effect_applied"]
        self.assertEqual((effect["required"], effect["observed"]), (True, 1))
        self.assertEqual(
            effect["evidence"],
            {
                "status": "applied",
                "call_id": WRITE_CALL_ID,
                "memory_id": MEMORY_ID,
                "revision": 1,
            },
        )
        state = verified["requested_postcondition_observed"]
        self.assertEqual((state["required"], state["observed"]), (False, None))
        self.assertFalse(
            (self.workspace.out / cells.EVIDENCE_MEMORY_CURRENT).exists(),
            "an effect scenario does not read the current snapshot",
        )

    def test_durable_scenario_passes_while_the_write_is_still_current(self) -> None:
        self.workspace.memory(librarian_removed=False)

        verified = self.workspace.verify(self.workspace.collect(DURABLE))

        state = verified["requested_postcondition_observed"]
        self.assertEqual((state["required"], state["observed"]), (True, 1))
        self.assertEqual(state["evidence"]["memory_id"], MEMORY_ID)

    def test_effect_scenario_fails_when_the_write_was_refused(self) -> None:
        self.workspace.calls(
            receipt={"ok": False, "error_kind": "persistence_failed", "rows_written": 0}
        )
        self.workspace.memory(librarian_removed=False)

        with self.assertRaises(verifier.VerificationError) as raised:
            self.workspace.verify(self.workspace.collect(EFFECT))

        self.assertIn("scenario requires external_effect_applied", str(raised.exception))
        self.assertIn('"status": "write_not_current"', str(raised.exception))

    def test_a_receipt_without_its_commit_in_this_trace_is_no_effect(self) -> None:
        # The receipt names revision 1, but the journal's revision 1 is another
        # trace's write: the store does not confirm this call's effect.
        self.workspace.memory(librarian_removed=False, write_trace="other-trace")

        with self.assertRaises(verifier.VerificationError) as raised:
            self.workspace.verify(self.workspace.collect(EFFECT))

        self.assertIn('"status": "commit_not_journaled"', str(raised.exception))

    def test_selection_scenario_reads_no_effect_authority(self) -> None:
        verified = self.workspace.verify(self.workspace.collect(SELECTION))

        self.assertEqual(verified["action_selected"]["observed"], len(ACTIONS))
        self.assertEqual(verified["external_effect_applied"]["observed"], None)
        self.assertEqual(list(self.workspace.out.iterdir()), [])

    def test_cells_edited_after_collection_are_refused(self) -> None:
        self.workspace.memory(librarian_removed=True)
        bundle = self.workspace.collect(DURABLE)
        claimed = bundle["proof"]["cells"]["requested_postcondition_observed"]
        claimed["observed"] = 1

        with self.assertRaises(verifier.VerificationError) as raised:
            self.workspace.verify(bundle)

        self.assertIn("proof cells differ from raw authority", str(raised.exception))

    def test_memory_files_are_the_ones_the_server_reports(self) -> None:
        store = self.workspace.keepers_dir / f"{KEEPER}.memory-current.json"
        answer: dict[str, Any] = {
            "keeper": KEEPER,
            "memory_os": {"keeper": KEEPER, "snapshot_store": str(store)},
        }

        self.assertEqual(collector.memory_snapshot_store(answer, KEEPER), store)
        answer["memory_os"]["snapshot_store"] = str(store.with_name("other.memory-current.json"))
        with self.assertRaises(collector.ProofError):
            collector.memory_snapshot_store(answer, KEEPER)

    def test_an_effect_kind_without_an_authority_here_is_refused(self) -> None:
        with self.assertRaises(cells.CellError):
            cells.decode_scenario(
                {**EFFECT, "effect": {"kind": "gate_replay", "tool_name": "Execute"}}
            )


if __name__ == "__main__":
    unittest.main()
