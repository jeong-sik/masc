"""MCP subprocess tests for addons/tinker-trainer."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from stdio_fixture import run_stdio  # noqa: E402

ADDONS = Path(__file__).resolve().parents[1]
SERVER = ADDONS / "tinker-trainer" / "server.py"
ROW_FIELDS = {
    "id",
    "lane_id",
    "kind",
    "title",
    "observed_at",
    "subject_id",
    "clock",
    "actor",
    "fields",
    "evidence",
    "related_ids",
}


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def ref(name: str) -> dict[str, str]:
    return {"uri": f"artifact://tinker/{name}", "sha256": digest(name)}


def default_binding(**overrides: object) -> dict[str, object]:
    base: dict[str, object] = {
        "base_model": "thinkingmachines/Inkling-2-Small",
        "target_loss": "cispo",
        "default_effort": 0.8,
        "min_eval_gain": 0.05,
    }
    base.update(overrides)
    return base


def source(observations: list[dict], *, complete: bool = True, detail: str | None = None) -> dict:
    return {
        "source_id": "tinker-snapshot",
        "incarnation": "run-1",
        "cursor": "seq:10",
        "complete": complete,
        "detail": detail,
        "observations": observations,
    }


def receipt_obs(
    traj_id: str,
    *,
    role: str = "keeper_turn",
    prompt: str = "Fix the failing parser check.",
    completion: str = "Updated parser to reject trailing tokens.",
    reasoning: str | None = "Inspecting token stream bounds.",
    logprobs: list[float] | None = None,
    effort: float | None = None,
    observed_at: int = 100,
) -> dict:
    payload: dict[str, object] = {
        "id": f"receipt-{traj_id}",
        "kind": "keeper_receipt",
        "observed_at": observed_at,
        "actor": "tinker.tinker-inkling-2-small",
        "evidence": [ref(f"receipt-{traj_id}")],
        "trajectory_id": traj_id,
        "keeper_id": "keeper-alpha",
        "prompt": prompt,
        "completion": completion,
        "turn_role": role,
        "reasoning": reasoning,
        "task_id": f"task-{traj_id}",
    }
    if logprobs is not None:
        payload["logprobs"] = logprobs
    if effort is not None:
        payload["effort"] = effort
    return payload


def verdict_obs(traj_id: str, verdict: str, *, observed_at: int = 105) -> dict:
    return {
        "id": f"verdict-{traj_id}",
        "kind": "verifier_verdict",
        "observed_at": observed_at,
        "actor": "verifier",
        "evidence": [ref(f"verdict-{traj_id}")],
        "trajectory_id": traj_id,
        "verdict": verdict,
    }


def karma_obs(traj_id: str, delta: int, *, observed_at: int = 110) -> dict:
    return {
        "id": f"karma-{traj_id}-{observed_at}",
        "kind": "karma_event",
        "observed_at": observed_at,
        "actor": "board",
        "evidence": [ref(f"karma-{traj_id}")],
        "trajectory_id": traj_id,
        "karma_delta": delta,
    }


def run_obs(
    run_id: str = "run-01",
    *,
    step: int = 20,
    mean_loss: float = 0.412,
    status: str = "completed",
    sampler_path: str | None = "tinker://run-01:train:0/sampler_weights/000020",
    eval_pass_rate: float | None = 0.88,
    baseline_pass_rate: float | None = 0.78,
) -> dict:
    payload: dict[str, object] = {
        "id": f"run-{run_id}-{step}",
        "kind": "tinker_run",
        "observed_at": 200 + step,
        "actor": "tinker_runner",
        "evidence": [ref(f"run-{run_id}-{step}")],
        "run_id": run_id,
        "base_model": "thinkingmachines/Inkling-2-Small",
        "loss_fn": "cispo",
        "step": step,
        "mean_loss": mean_loss,
        "status": status,
        "sampler_path": sampler_path,
        "eval_pass_rate": eval_pass_rate,
        "baseline_pass_rate": baseline_pass_rate,
        "dataset_id": "rlvr-latest",
    }
    return payload


class TinkerTrainerTest(unittest.TestCase):
    def rpc_session(self, calls: list[dict], *, state_dir: str | None = None) -> list[dict]:
        requests = [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "clientInfo": {"name": "test", "version": "1"},
                    "capabilities": {},
                },
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        ]
        next_id = 3
        for call in calls:
            requests.append({
                "jsonrpc": "2.0",
                "id": next_id,
                "method": "tools/call",
                "params": call,
            })
            next_id += 1
        cmd = [sys.executable, str(SERVER)]
        if state_dir is not None:
            cmd.extend(["--state", state_dir])
        proc = run_stdio(
            cmd,
            input="".join(json.dumps(r) + "\n" for r in requests),
            text=True,
            capture_output=True,
            check=True,
            timeout=10,
        )
        self.assertEqual(proc.stderr, "")
        responses = [json.loads(line) for line in proc.stdout.splitlines()]
        tools = responses[1]["result"]["tools"]
        self.assertEqual([t["name"] for t in tools], ["lane_observe", "lane_act"])
        return [r["result"] for r in responses[2:]]

    def test_observe_joins_verdicts_karma_and_projects_readiness(self) -> None:
        observations = [
            receipt_obs("t1", role="keeper_turn", logprobs=[-0.2, -0.1]),
            verdict_obs("t1", "Done"),
            receipt_obs("t2", role="exact_gate"),
            verdict_obs("t2", "Producer_must_act"),
            karma_obs("t2", 10),  # Positive karma must NOT flip a negative Verifier verdict!
            run_obs("run-01", step=20, eval_pass_rate=0.88, baseline_pass_rate=0.78),
        ]
        results = self.rpc_session([
            {
                "name": "lane_observe",
                "arguments": {
                    "context": {"instance_id": "inst-1", "incarnation": "inst-1"},
                    "binding": default_binding(),
                    "sources": [source(observations)],
                },
            }
        ])
        res = results[0]
        self.assertFalse(res["isError"])
        output = res["structuredContent"]
        rows = output["rows"]
        for r in rows:
            self.assertEqual(set(r), ROW_FIELDS)
        by_lane = {r["lane_id"]: r for r in rows}
        self.assertEqual(
            set(by_lane),
            {"tinker/datasets", "tinker/runs", "tinker/checkpoints", "tinker/readiness"},
        )
        ds_fields = by_lane["tinker/datasets"]["fields"]
        self.assertEqual(ds_fields["datum_count"], 2)
        self.assertEqual(ds_fields["positive_count"], 1)
        self.assertEqual(ds_fields["negative_count"], 1)

        readiness_fields = by_lane["tinker/readiness"]["fields"]
        self.assertEqual(readiness_fields["verdict"], "promote_ready")
        self.assertAlmostEqual(readiness_fields["eval_gain"], 0.10)
        self.assertEqual(
            readiness_fields["runtime_api_name"],
            "tinker://run-01:train:0/sampler_weights/000020",
        )

    def test_prepare_sft_rlvr_export_and_state_persistence(self) -> None:
        with tempfile.TemporaryDirectory() as state_dir:
            observations = [
                receipt_obs("t-pos", role="verifier_judge", reasoning="Proof holds."),
                verdict_obs("t-pos", "Record_proof_proven"),
                receipt_obs("t-gate", role="exact_gate", reasoning=None),
                verdict_obs("t-gate", "Done"),
                receipt_obs("t-neg", role="keeper_turn", reasoning="Missed edge case."),
                verdict_obs("t-neg", "Record_proof_refuted"),
            ]
            ctx = {"instance_id": "inst-1", "incarnation": "inst-1"}
            results = self.rpc_session(
                [
                    {
                        "name": "lane_observe",
                        "arguments": {
                            "context": ctx,
                            "binding": default_binding(),
                            "sources": [source(observations)],
                        },
                    },
                    {
                        "name": "lane_act",
                        "arguments": {
                            "context": ctx,
                            "request_id": "req-sft",
                            "action": {"kind": "prepare_sft", "dataset_id": "sft-v1"},
                        },
                    },
                    {
                        "name": "lane_act",
                        "arguments": {
                            "context": ctx,
                            "request_id": "req-rlvr",
                            "action": {
                                "kind": "prepare_rlvr",
                                "dataset_id": "rlvr-v1",
                                "loss_fn": "cispo",
                            },
                        },
                    },
                    {
                        "name": "lane_act",
                        "arguments": {
                            "context": ctx,
                            "request_id": "req-export",
                            "action": {"kind": "export_bundle", "dataset_id": "rlvr-v1"},
                        },
                    },
                ],
                state_dir=state_dir,
            )
            self.assertFalse(results[1]["isError"])
            sft_res = results[1]["structuredContent"]["result"]
            # Only the 2 positive trajectories belong in SFT
            self.assertEqual(sft_res["datum_count"], 2)

            rlvr_res = results[2]["structuredContent"]["result"]
            # All 3 verified trajectories (2 positive, 1 negative) belong in RLVR
            self.assertEqual(rlvr_res["datum_count"], 3)
            self.assertEqual(rlvr_res["positive_count"], 2)
            self.assertEqual(rlvr_res["negative_count"], 1)

            export_res = results[3]["structuredContent"]["result"]
            artifacts = export_res["artifacts"]
            self.assertEqual(len(artifacts), 1)
            self.assertEqual(artifacts[0]["content_type"], "application/x-ndjson")
            lines = [json.loads(line) for line in artifacts[0]["data"].splitlines()]
            self.assertEqual(len(lines), 3)
            by_tid = {item["trajectory_id"]: item for item in lines}
            # verifier_judge gets effort=0.99, exact_gate gets effort=0.0, keeper_turn gets default_effort=0.8
            self.assertEqual(by_tid["t-pos"]["effort"], 0.99)
            self.assertIn("<thinking effort=0.99>", by_tid["t-pos"]["messages"][1]["content"])
            self.assertEqual(by_tid["t-gate"]["effort"], 0.0)
            self.assertIn("<thinking effort=0.00></thinking>", by_tid["t-gate"]["messages"][1]["content"])
            self.assertEqual(by_tid["t-neg"]["effort"], 0.8)
            self.assertLess(by_tid["t-neg"]["advantage"], 0.0)

            # Restart worker with the same state_dir and register a checkpoint
            restarted = self.rpc_session(
                [
                    {
                        "name": "lane_act",
                        "arguments": {
                            "context": ctx,
                            "request_id": "req-ckpt",
                            "action": {
                                "kind": "register_checkpoint",
                                "checkpoint_id": "ckpt-step-50",
                                "run_id": "run-02",
                                "sampler_path": "tinker://run-02:train:0/sampler_weights/000050",
                                "step": 50,
                                "eval_pass_rate": 0.72,
                                "baseline_pass_rate": 0.78,
                            },
                        },
                    }
                ],
                state_dir=state_dir,
            )
            ckpt_payload = restarted[0]["structuredContent"]
            self.assertEqual(ckpt_payload["result"]["verdict"], "regressed")
            dataset_ids = [
                r["fields"]["dataset_id"]
                for r in ckpt_payload["output"]["rows"]
                if r["lane_id"] == "tinker/datasets"
            ]
            self.assertIn("sft-v1", dataset_ids)
            self.assertIn("rlvr-v1", dataset_ids)

    def test_malformed_observations_and_unknown_kinds(self) -> None:
        ctx = {"instance_id": "inst-err", "incarnation": "inst-err"}
        # Unknown observation kinds are reported in coverage without fabricating rows
        res_unknown = self.rpc_session([
            {
                "name": "lane_observe",
                "arguments": {
                    "context": ctx,
                    "binding": default_binding(),
                    "sources": [
                        source(
                            [{"kind": "foreign_event", "id": "f1"}],
                            complete=False,
                            detail="partial snapshot",
                        )
                    ],
                },
            }
        ])[0]
        self.assertFalse(res_unknown["isError"])
        self.assertEqual(res_unknown["structuredContent"]["rows"], [])
        cov = res_unknown["structuredContent"]["coverage"][0]
        self.assertFalse(cov["complete"])
        self.assertIn("foreign_event", cov["detail"])

        # Malformed known observations fail with isError=True and no default fallback
        bad_effort = receipt_obs("t-bad", effort=1.0)  # effort must be < 1.0
        res_bad = self.rpc_session([
            {
                "name": "lane_observe",
                "arguments": {
                    "context": ctx,
                    "binding": default_binding(),
                    "sources": [source([bad_effort])],
                },
            }
        ])[0]
        self.assertTrue(res_bad["isError"])
        self.assertNotIn("structuredContent", res_bad)


if __name__ == "__main__":
    unittest.main()
