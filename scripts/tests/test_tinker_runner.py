"""Unit and integration tests for scripts/tinker/tinker_runner.py."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "tinker"))
sys.path.insert(0, str(REPO_ROOT / "addons" / "tests"))

from stdio_fixture import run_stdio  # noqa: E402
import tinker_runner  # noqa: E402


class FakeFuture:
    def __init__(self, value: object) -> None:
        self._value = value

    def result(self) -> object:
        return self._value


class FakeTrainingClient:
    def __init__(self, base_model: str, rank: int, optimizer: str = "adamw") -> None:
        self.base_model = base_model
        self.rank = rank
        self.optimizer = optimizer
        self.forward_calls: list[tuple[list[dict], str, dict | None]] = []
        self.optim_calls: list[dict] = []

    def forward_backward(
        self,
        datums: list[dict],
        loss_fn: str,
        loss_fn_config: dict | None = None,
    ) -> FakeFuture:
        self.forward_calls.append((datums, loss_fn, loss_fn_config))
        return FakeFuture({"loss": 0.215})

    def optim_step(self, params: dict) -> FakeFuture:
        self.optim_calls.append(params)
        return FakeFuture({"step": 1})

    def save_weights_for_sampler(self, name: str) -> FakeFuture:
        return FakeFuture({"path": f"tinker://mock-run:train:0/sampler_weights/{name}"})

    def save_state(self, name: str) -> FakeFuture:
        return FakeFuture({"path": f"tinker://mock-run:train:0/weights/{name}"})


class FakeServiceClient:
    def __init__(self) -> None:
        self.clients: list[FakeTrainingClient] = []

    def create_lora_training_client(
        self,
        base_model: str,
        rank: int,
        optimizer: str = "adamw",
    ) -> FakeTrainingClient:
        client = FakeTrainingClient(base_model, rank, optimizer)
        self.clients.append(client)
        return client


class TinkerRunnerTest(unittest.TestCase):
    def test_shifted_datum_alignment_and_prompt_masking(self) -> None:
        prompt_tokens = [10, 11, 12, 13]  # P = 4
        completion_tokens = [20, 21, 22]  # C = 3
        datum = tinker_runner.build_shifted_datum(
            trajectory_id="t-1",
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            loss_fn="cross_entropy",
            effort=0.8,
        )
        # Total length T = 7 -> shifted length N = 6
        self.assertEqual(len(datum.input_tokens), 6)
        self.assertEqual(len(datum.target_tokens), 6)
        self.assertEqual(datum.input_tokens, [10, 11, 12, 13, 20, 21])
        self.assertEqual(datum.target_tokens, [11, 12, 13, 20, 21, 22])
        # First P-1 = 3 transitions are prompt->prompt (weight 0.0);
        # remaining C = 3 transitions predict completion tokens (weight 1.0)
        self.assertEqual(datum.weights, [0.0, 0.0, 0.0, 1.0, 1.0, 1.0])
        self.assertIsNone(datum.logprobs)
        self.assertIsNone(datum.advantages)
        self.assertEqual(
            set(datum.to_dict()["loss_fn_inputs"]),
            {"target_tokens", "weights"},
        )

    def test_rlvr_datum_keys_for_cispo_gspo_and_dr_grpo(self) -> None:
        datum_cispo = tinker_runner.build_shifted_datum(
            trajectory_id="t-rl",
            prompt_tokens=[1, 2, 3],
            completion_tokens=[4, 5],
            loss_fn="cispo",
            effort=0.0,
            advantage=-1.0,
            completion_logprobs=[-0.25, -0.50],
        )
        self.assertEqual(datum_cispo.weights, [0.0, 0.0, 1.0, 1.0])
        self.assertEqual(datum_cispo.logprobs, [0.0, 0.0, -0.25, -0.50])
        self.assertEqual(datum_cispo.advantages, [0.0, 0.0, -1.0, -1.0])
        # RL losses (cispo, ppo, dro, importance_sampling, stable_reinforce) omit 'weights'
        self.assertEqual(
            set(datum_cispo.to_dict()["loss_fn_inputs"]),
            {"target_tokens", "logprobs", "advantages"},
        )

        # GSPO additionally includes 'sequence_ratio_mask'
        datum_gspo = tinker_runner.build_shifted_datum(
            trajectory_id="t-gspo",
            prompt_tokens=[1, 2, 3],
            completion_tokens=[4, 5],
            loss_fn="gspo",
            effort=0.8,
            advantage=1.0,
            completion_logprobs=[-0.10, -0.20],
        )
        gspo_inputs = datum_gspo.to_dict()["loss_fn_inputs"]
        self.assertEqual(
            set(gspo_inputs),
            {"target_tokens", "logprobs", "advantages", "sequence_ratio_mask"},
        )
        self.assertEqual(gspo_inputs["sequence_ratio_mask"], [0.0, 0.0, 1.0, 1.0])

        # Dr. GRPO mean-centers rewards without std normalization
        advs = tinker_runner.compute_dr_grpo_advantages([1.0, 1.0, 0.0, 0.0])
        self.assertEqual(advs, [0.5, 0.5, -0.5, -0.5])

        with self.assertRaises(tinker_runner.TinkerRunnerError):
            tinker_runner.build_shifted_datum(
                trajectory_id="t-bad",
                prompt_tokens=[1, 2],
                completion_tokens=[3, 4],
                loss_fn="ppo",
                effort=1.0,  # invalid effort >= 1.0
            )

    def test_mock_live_training_step_and_addon_roundtrip(self) -> None:
        datum = tinker_runner.build_shifted_datum(
            trajectory_id="t-live",
            prompt_tokens=[101, 102],
            completion_tokens=[201, 202],
            loss_fn="cispo",
            effort=0.8,
            advantage=1.0,
            completion_logprobs=[-0.1, -0.2],
        )
        fake_service = FakeServiceClient()
        live = tinker_runner.run_live_tinker_step(
            base_model="thinkingmachines/Inkling-2-Small",
            loss_fn="cispo",
            datums=[datum],
            lora_rank=32,
            learning_rate=1e-3,
            checkpoint_name="000010",
            optimizer="dimuon",
            loss_fn_config={"clip_low_threshold": 0.0, "clip_high_threshold": 4.0},
            save_state=True,
            service_client=fake_service,
        )
        self.assertEqual(
            live["sampler_path"],
            "tinker://mock-run:train:0/sampler_weights/000010",
        )
        self.assertEqual(
            live["state_path"],
            "tinker://mock-run:train:0/weights/000010",
        )
        self.assertAlmostEqual(live["mean_loss"], 0.215)
        self.assertEqual(len(fake_service.clients), 1)
        self.assertEqual(fake_service.clients[0].rank, 32)
        self.assertEqual(fake_service.clients[0].optimizer, "dimuon")
        self.assertEqual(
            fake_service.clients[0].forward_calls[0][2],
            {"clip_low_threshold": 0.0, "clip_high_threshold": 4.0},
        )

        # Verify dry-run CLI emits a snapshot that addons/tinker-trainer/server.py accepts cleanly
        with tempfile.TemporaryDirectory() as tmpdir:
            snapshot_path = Path(tmpdir) / "latest_snapshot.json"
            rc = tinker_runner.main([
                "--mode",
                "dry-run",
                "--run-id",
                "dry-run-42",
                "--step",
                "15",
                "--snapshot-out",
                str(snapshot_path),
            ])
            self.assertEqual(rc, 0)
            envelope = json.loads(snapshot_path.read_text(encoding="utf-8"))

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
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": {
                        "name": "lane_observe",
                        "arguments": {
                            "context": {"instance_id": "i1", "incarnation": "i1"},
                            "binding": {
                                "base_model": "thinkingmachines/Inkling-2-Small",
                                "target_loss": "cispo",
                                "default_effort": 0.8,
                                "min_eval_gain": 0.05,
                            },
                            "sources": [envelope],
                        },
                    },
                },
            ]
            proc = run_stdio(
                [sys.executable, str(REPO_ROOT / "addons" / "tinker-trainer" / "server.py")],
                input="".join(json.dumps(r) + "\n" for r in requests),
                text=True,
                capture_output=True,
                check=True,
                timeout=10,
            )
            responses = [json.loads(line) for line in proc.stdout.splitlines()]
            observe_res = responses[-1]["result"]
            self.assertFalse(observe_res["isError"])
            lanes = {r["lane_id"] for r in observe_res["structuredContent"]["rows"]}
            self.assertEqual(
                lanes,
                {"tinker/datasets", "tinker/runs", "tinker/checkpoints", "tinker/readiness"},
            )


if __name__ == "__main__":
    unittest.main()
