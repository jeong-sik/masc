#!/usr/bin/env python3
"""Host-side Thinking Machines Tinker post-training and checkpoint runner for MASC.

Bridges MASC verifiable signals (Keeper receipts, Task/Goal Verifier verdicts,
Board Karma) and `addons/tinker-trainer` dataset bundles with the Tinker API
(`cross_entropy`, `importance_sampling`, `ppo`, `cispo`, `dro`, `gspo`).
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import sys
import time
from typing import Any

SUPPORTED_LOSS_FUNCTIONS = frozenset({
    "cross_entropy",
    "importance_sampling",
    "ppo",
    "cispo",
    "dro",
    "gspo",
    "stable_reinforce",
})
RL_LOSS_FUNCTIONS = frozenset({
    "importance_sampling",
    "ppo",
    "cispo",
    "dro",
    "gspo",
    "stable_reinforce",
})
SUPPORTED_OPTIMIZERS = frozenset({"adamw", "dimuon"})
TURN_ROLES = frozenset({"exact_gate", "keeper_turn", "verifier_judge"})
VERIFIER_VERDICTS = frozenset({
    "Done",
    "Record_proof_proven",
    "Producer_must_act",
    "Record_proof_refuted",
    "Pending",
})


class TinkerRunnerError(ValueError):
    """Raised on invalid trajectory/datum inputs or missing runtime prerequisites."""


@dataclass(frozen=True)
class ShiftedDatum:
    """Autoregressive next-token prediction datum aligned to length N = T - 1."""

    trajectory_id: str
    loss_fn: str
    effort: float
    input_tokens: list[int]
    target_tokens: list[int]
    weights: list[float]
    logprobs: list[float] | None
    advantages: list[float] | None

    def validate(self) -> None:
        n = len(self.input_tokens)
        if n == 0:
            raise TinkerRunnerError("ShiftedDatum must have at least 1 transition token")
        if len(self.target_tokens) != n:
            raise TinkerRunnerError("target_tokens length must equal input_tokens length")
        if len(self.weights) != n:
            raise TinkerRunnerError("weights length must equal input_tokens length")
        if self.loss_fn in RL_LOSS_FUNCTIONS:
            if self.logprobs is None or len(self.logprobs) != n:
                raise TinkerRunnerError("RL loss requires logprobs of length N")
            if self.advantages is None or len(self.advantages) != n:
                raise TinkerRunnerError("RL loss requires advantages of length N")

    def to_dict(self) -> dict[str, Any]:
        self.validate()
        loss_fn_inputs: dict[str, list[int] | list[float]] = {
            "target_tokens": self.target_tokens,
        }
        if self.loss_fn in RL_LOSS_FUNCTIONS:
            assert self.logprobs is not None and self.advantages is not None
            loss_fn_inputs["logprobs"] = self.logprobs
            loss_fn_inputs["advantages"] = self.advantages
            if self.loss_fn == "gspo":
                loss_fn_inputs["sequence_ratio_mask"] = self.weights
        else:
            loss_fn_inputs["weights"] = self.weights
        return {
            "trajectory_id": self.trajectory_id,
            "loss_fn": self.loss_fn,
            "effort": self.effort,
            "model_input": {"input_tokens": self.input_tokens},
            "loss_fn_inputs": loss_fn_inputs,
        }

    def to_tinker_datum(self, types_mod: Any) -> Any:
        self.validate()
        n = len(self.input_tokens)
        loss_inputs: dict[str, Any] = {
            "target_tokens": types_mod.TensorData(
                data=self.target_tokens, dtype="int64", shape=[n]
            ),
        }
        if self.loss_fn in RL_LOSS_FUNCTIONS:
            assert self.logprobs is not None and self.advantages is not None
            loss_inputs["logprobs"] = types_mod.TensorData(
                data=self.logprobs, dtype="float32", shape=[n]
            )
            loss_inputs["advantages"] = types_mod.TensorData(
                data=self.advantages, dtype="float32", shape=[n]
            )
            if self.loss_fn == "gspo":
                loss_inputs["sequence_ratio_mask"] = types_mod.TensorData(
                    data=self.weights, dtype="float32", shape=[n]
                )
        else:
            loss_inputs["weights"] = types_mod.TensorData(
                data=self.weights, dtype="float32", shape=[n]
            )
        return types_mod.Datum(
            model_input=types_mod.ModelInput.from_ints(tokens=self.input_tokens),
            loss_fn_inputs=loss_inputs,
        )


def compute_dr_grpo_advantages(rewards: list[float]) -> list[float]:
    """Compute Dr. GRPO group-centered advantages without std normalization.

    Per Tinker RL Hyperparameters guidance (Dr. GRPO, Liu et al., 2025):
    mean-center rewards within a rollout group without dividing by std(rewards)
    to avoid difficulty bias and length bias. Constant-reward groups produce
    all-zero advantages and can be filtered upstream.
    """
    if not rewards:
        return []
    mean_r = sum(rewards) / len(rewards)
    return [round(r - mean_r, 6) for r in rewards]


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def format_inkling_assistant_turn(
    *,
    completion: str,
    reasoning: str | None,
    effort: float,
) -> str:
    if effort < 0.0 or effort >= 1.0:
        raise TinkerRunnerError(f"Inkling effort must be in [0.0, 1.0), got {effort}")
    tag = f"<thinking effort={effort:.2f}>"
    if effort == 0.0:
        return f"{tag}</thinking>\n{completion}"
    body = reasoning or ""
    return f"{tag}\n{body}\n</thinking>\n{completion}"


def deterministic_byte_tokens(text: str) -> list[int]:
    """Deterministic UTF-8 byte-level token IDs used for offline dry-run & tests
    when a HuggingFace tokenizer is not loaded."""
    encoded = text.encode("utf-8")
    if not encoded:
        raise TinkerRunnerError("Cannot tokenize empty text")
    return [b + 256 for b in encoded]


def build_shifted_datum(
    *,
    trajectory_id: str,
    prompt_tokens: list[int],
    completion_tokens: list[int],
    loss_fn: str,
    effort: float = 0.8,
    advantage: float = 1.0,
    completion_logprobs: list[float] | None = None,
) -> ShiftedDatum:
    """Build a Tinker-compatible shifted Datum from prompt and completion tokens.

    For full_sequence = prompt_tokens + completion_tokens (length T = P + C):
    - input_tokens  = full_sequence[:-1] (length N = P + C - 1)
    - target_tokens = full_sequence[1:]  (length N = P + C - 1)
    - weights       = [0.0] * (P - 1) + [1.0] * C
    """
    if loss_fn not in SUPPORTED_LOSS_FUNCTIONS:
        raise TinkerRunnerError(f"Unsupported loss_fn: {loss_fn}")
    if not prompt_tokens:
        raise TinkerRunnerError("prompt_tokens must be non-empty")
    if not completion_tokens:
        raise TinkerRunnerError("completion_tokens must be non-empty")
    if effort < 0.0 or effort >= 1.0:
        raise TinkerRunnerError(f"effort must be in [0.0, 1.0), got {effort}")

    p_len = len(prompt_tokens)
    c_len = len(completion_tokens)
    full_tokens = prompt_tokens + completion_tokens
    input_tokens = full_tokens[:-1]
    target_tokens = full_tokens[1:]
    weights = [0.0] * (p_len - 1) + [1.0] * c_len

    logprobs: list[float] | None = None
    advantages: list[float] | None = None
    if loss_fn in RL_LOSS_FUNCTIONS:
        if completion_logprobs is None:
            completion_logprobs = [-0.1] * c_len
        elif len(completion_logprobs) != c_len:
            raise TinkerRunnerError(
                f"completion_logprobs length ({len(completion_logprobs)}) "
                f"must match completion_tokens length ({c_len})"
            )
        logprobs = [0.0] * (p_len - 1) + [float(lp) for lp in completion_logprobs]
        advantages = [0.0] * (p_len - 1) + [float(advantage)] * c_len

    datum = ShiftedDatum(
        trajectory_id=trajectory_id,
        loss_fn=loss_fn,
        effort=round(effort, 2),
        input_tokens=input_tokens,
        target_tokens=target_tokens,
        weights=weights,
        logprobs=logprobs,
        advantages=advantages,
    )
    datum.validate()
    return datum


def datum_from_bundle_record(record: dict[str, Any], *, loss_fn_override: str | None = None) -> ShiftedDatum:
    trajectory_id = str(record["trajectory_id"])
    loss_fn = loss_fn_override or str(record.get("loss_fn", "cross_entropy"))
    effort = float(record.get("effort", 0.8))
    advantage = float(record.get("advantage", record.get("reward", 1.0)))
    messages = record.get("messages")
    if not isinstance(messages, list) or len(messages) < 2:
        raise TinkerRunnerError(f"Bundle record {trajectory_id} requires at least 2 messages")
    prompt_text = str(messages[0].get("content", ""))
    assistant_text = str(messages[1].get("content", ""))
    prompt_tokens = deterministic_byte_tokens(prompt_text)
    completion_tokens = deterministic_byte_tokens(assistant_text)

    raw_lps = record.get("sampling_logprobs")
    if isinstance(raw_lps, list) and len(raw_lps) == len(completion_tokens):
        completion_logprobs: list[float] | None = [float(x) for x in raw_lps]
    else:
        completion_logprobs = [-0.15] * len(completion_tokens) if loss_fn in RL_LOSS_FUNCTIONS else None

    return build_shifted_datum(
        trajectory_id=trajectory_id,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        loss_fn=loss_fn,
        effort=effort,
        advantage=advantage,
        completion_logprobs=completion_logprobs,
    )


def default_fixture_observations() -> list[dict[str, Any]]:
    """Synthetic MASC Keeper + Verifier + Karma observations for offline dry-run."""
    def ev(tag: str) -> list[dict[str, str]]:
        return [{"uri": f"masc://tinker/{tag}", "sha256": sha256_hex(tag)}]

    return [
        {
            "id": "receipt-traj-1",
            "kind": "keeper_receipt",
            "observed_at": 1000,
            "actor": "tinker.tinker-inkling-2-small",
            "evidence": ev("receipt-traj-1"),
            "trajectory_id": "traj-1",
            "keeper_id": "keeper-coder",
            "prompt": "Ensure normalize_openai_compat_request_path strips duplicate /v1.",
            "completion": "Verified versioned_base_prefix strips duplicate /v1 on Tinker oai/api/v1.",
            "turn_role": "keeper_turn",
            "reasoning": "Checking lib/runtime_model/runtime_provider_binding.ml.",
            "task_id": "task-101",
        },
        {
            "id": "verdict-traj-1",
            "kind": "verifier_verdict",
            "observed_at": 1005,
            "actor": "verifier",
            "evidence": ev("verdict-traj-1"),
            "trajectory_id": "traj-1",
            "verdict": "Done",
        },
        {
            "id": "receipt-traj-2",
            "kind": "keeper_receipt",
            "observed_at": 1010,
            "actor": "tinker.tinker-inkling-2-small",
            "evidence": ev("receipt-traj-2"),
            "trajectory_id": "traj-2",
            "keeper_id": "keeper-gate",
            "prompt": "{\"Classify\":\"exact_output_gate\"}",
            "completion": "{\"admitted\":true}",
            "turn_role": "exact_gate",
            "reasoning": None,
            "task_id": "task-102",
        },
        {
            "id": "verdict-traj-2",
            "kind": "verifier_verdict",
            "observed_at": 1012,
            "actor": "verifier",
            "evidence": ev("verdict-traj-2"),
            "trajectory_id": "traj-2",
            "verdict": "Record_proof_proven",
        },
        {
            "id": "receipt-traj-3",
            "kind": "keeper_receipt",
            "observed_at": 1020,
            "actor": "tinker.tinker-inkling-2-small",
            "evidence": ev("receipt-traj-3"),
            "trajectory_id": "traj-3",
            "keeper_id": "keeper-coder",
            "prompt": "Add provider without checking seed wizard gate.",
            "completion": "Added uncommented provider to config/runtime.toml.",
            "turn_role": "keeper_turn",
            "reasoning": "Skipping test_runtime_config_validity.ml check.",
            "task_id": "task-103",
        },
        {
            "id": "verdict-traj-3",
            "kind": "verifier_verdict",
            "observed_at": 1025,
            "actor": "verifier",
            "evidence": ev("verdict-traj-3"),
            "trajectory_id": "traj-3",
            "verdict": "Producer_must_act",
        },
    ]


def run_live_tinker_step(
    *,
    base_model: str,
    loss_fn: str,
    datums: list[ShiftedDatum],
    lora_rank: int,
    learning_rate: float,
    checkpoint_name: str,
    optimizer: str = "adamw",
    loss_fn_config: dict[str, float] | None = None,
    save_state: bool = False,
    service_client: Any | None = None,
) -> dict[str, Any]:
    """Execute one pipelined forward_backward + optim_step + save_weights_for_sampler on Tinker."""
    if not datums:
        raise TinkerRunnerError("Cannot run training step with empty datums")
    if optimizer not in SUPPORTED_OPTIMIZERS:
        raise TinkerRunnerError(f"Unsupported optimizer: {optimizer}")
    types_mod: Any | None = None
    if service_client is None:
        api_key = os.environ.get("TINKER_API_KEY", "").strip()
        if not api_key:
            raise TinkerRunnerError(
                "TINKER_API_KEY environment variable is required for --mode train"
            )
        try:
            import tinker  # type: ignore[import-not-found]
            from tinker import types as tinker_types  # type: ignore[import-not-found]
        except ImportError as exc:
            raise TinkerRunnerError(
                "The 'tinker' Python SDK is not installed. Run: pip install tinker"
            ) from exc
        service_client = tinker.ServiceClient()
        types_mod = tinker_types

    create_kwargs: dict[str, Any] = {
        "base_model": base_model,
        "rank": lora_rank,
    }
    if types_mod is not None:
        if optimizer == "dimuon":
            create_kwargs["optimizer_config"] = types_mod.DimuonOptimizerConfig()
        else:
            create_kwargs["optimizer_config"] = types_mod.AdamOptimizerConfig()
    elif optimizer != "adamw":
        create_kwargs["optimizer"] = optimizer

    client_or_future = service_client.create_lora_training_client(**create_kwargs)
    training_client = (
        client_or_future.result()
        if hasattr(client_or_future, "result") and callable(client_or_future.result)
        else client_or_future
    )
    if types_mod is not None:
        sdk_datums = [d.to_tinker_datum(types_mod) for d in datums]
        if optimizer == "dimuon":
            optim_params: Any = types_mod.DimuonParams(learning_rate=learning_rate)
        else:
            optim_params = types_mod.AdamParams(learning_rate=learning_rate)
    else:
        sdk_datums = [d.to_dict() for d in datums]
        optim_params = {"optimizer": optimizer, "learning_rate": learning_rate}

    # Submit both forward_backward and optim_step BEFORE awaiting either so both
    # land in the same worker-pool clock cycle (1 cycle instead of 3).
    if loss_fn_config is not None:
        fwdbwd_future = training_client.forward_backward(
            sdk_datums, loss_fn=loss_fn, loss_fn_config=loss_fn_config
        )
    else:
        fwdbwd_future = training_client.forward_backward(sdk_datums, loss_fn=loss_fn)
    optim_future = training_client.optim_step(optim_params)
    fwdbwd_result = fwdbwd_future.result()
    optim_future.result()
    save_future = training_client.save_weights_for_sampler(name=checkpoint_name)
    save_result = save_future.result()

    sampler_path = getattr(save_result, "path", None)
    if sampler_path is None and isinstance(save_result, dict):
        sampler_path = save_result.get("path")

    state_path: str | None = None
    if save_state and hasattr(training_client, "save_state"):
        state_res = training_client.save_state(name=checkpoint_name).result()
        raw_state = getattr(state_res, "path", None)
        if raw_state is None and isinstance(state_res, dict):
            raw_state = state_res.get("path")
        if raw_state is not None:
            state_path = str(raw_state)

    mean_loss = getattr(fwdbwd_result, "loss", None)
    if mean_loss is None:
        metrics = getattr(fwdbwd_result, "metrics", None)
        if isinstance(metrics, dict) and metrics:
            mean_loss = metrics.get("loss:sum", next(iter(metrics.values())))
        elif isinstance(fwdbwd_result, dict):
            mean_loss = fwdbwd_result.get("loss", 0.0)
    return {
        "sampler_path": str(sampler_path),
        "state_path": state_path,
        "mean_loss": float(mean_loss if mean_loss is not None else 0.0),
    }


def build_snapshot_envelope(
    *,
    run_id: str,
    base_model: str,
    loss_fn: str,
    optimizer: str = "adamw",
    step: int,
    mean_loss: float,
    status: str,
    sampler_path: str | None,
    state_path: str | None = None,
    eval_pass_rate: float | None,
    baseline_pass_rate: float | None,
    dataset_id: str,
    existing_observations: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    obs_list = list(existing_observations) if existing_observations is not None else default_fixture_observations()
    run_obs_id = f"run-{run_id}-{step}"
    run_obs: dict[str, Any] = {
        "id": run_obs_id,
        "kind": "tinker_run",
        "observed_at": int(time.time()),
        "actor": "tinker_runner",
        "evidence": [{"uri": sampler_path or f"masc://tinker/{run_obs_id}", "sha256": sha256_hex(run_obs_id)}],
        "run_id": run_id,
        "base_model": base_model,
        "loss_fn": loss_fn,
        "optimizer": optimizer,
        "step": step,
        "mean_loss": round(mean_loss, 6),
        "status": status,
        "sampler_path": sampler_path,
        "state_path": state_path,
        "eval_pass_rate": eval_pass_rate,
        "baseline_pass_rate": baseline_pass_rate,
        "dataset_id": dataset_id,
    }
    obs_list.append(run_obs)
    return {
        "source_id": "tinker-snapshot",
        "incarnation": run_id,
        "cursor": f"step:{step}",
        "complete": True,
        "detail": None,
        "observations": obs_list,
    }


def preflight_status() -> dict[str, Any]:
    api_key_present = bool(os.environ.get("TINKER_API_KEY", "").strip())
    try:
        import tinker  # type: ignore[import-not-found]  # noqa: F401
        sdk_installed = True
    except ImportError:
        sdk_installed = False
    return {
        "tinker_api_key_present": api_key_present,
        "tinker_sdk_installed": sdk_installed,
        "openai_compatible_endpoint": "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1",
        "recommended_model": "thinkingmachines/Inkling-2-Small",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="MASC host-side Thinking Machines Tinker post-training & checkpoint runner"
    )
    parser.add_argument(
        "--mode",
        choices=["preflight", "dry-run", "train"],
        default="dry-run",
        help="Execution mode (default: dry-run)",
    )
    parser.add_argument(
        "--base-model",
        default="thinkingmachines/Inkling-2-Small",
        help="Tinker base model ID",
    )
    parser.add_argument(
        "--loss-fn",
        choices=sorted(SUPPORTED_LOSS_FUNCTIONS),
        default="cispo",
        help="Tinker loss function",
    )
    parser.add_argument(
        "--optimizer",
        choices=sorted(SUPPORTED_OPTIMIZERS),
        default="adamw",
        help="LoRA optimizer (adamw or dimuon)",
    )
    parser.add_argument(
        "--loss-fn-config",
        default=None,
        help="Optional JSON dict of loss hyperparameters (e.g. '{\"clip_high_threshold\":4.0}')",
    )
    parser.add_argument(
        "--save-state",
        action="store_true",
        help="Also save full WEIGHTS + optimizer state via save_state()",
    )
    parser.add_argument(
        "--bundle",
        type=Path,
        default=None,
        help="Optional NDJSON dataset bundle exported from addons/tinker-trainer",
    )
    parser.add_argument(
        "--snapshot-out",
        type=Path,
        default=None,
        help="Path to write the MASC snapshot JSON for addons/tinker-trainer",
    )
    parser.add_argument("--run-id", default="tinker-run-01", help="Training run identifier")
    parser.add_argument("--step", type=int, default=1, help="Training step number")
    parser.add_argument("--lora-rank", type=int, default=32, help="LoRA adapter rank")
    parser.add_argument("--learning-rate", type=float, default=1e-4, help="Optimizer learning rate")
    parser.add_argument("--eval-pass-rate", type=float, default=0.88, help="Measured eval pass rate")
    parser.add_argument("--baseline-pass-rate", type=float, default=0.78, help="Baseline eval pass rate")
    args = parser.parse_args(argv)

    if args.mode == "preflight":
        print(json.dumps(preflight_status(), indent=2, sort_keys=True))
        return 0

    loss_fn_config: dict[str, float] | None = None
    if args.loss_fn_config is not None:
        raw_cfg = json.loads(args.loss_fn_config)
        if not isinstance(raw_cfg, dict):
            raise TinkerRunnerError("--loss-fn-config must be a JSON object")
        loss_fn_config = {str(k): float(v) for k, v in raw_cfg.items()}

    datums: list[ShiftedDatum] = []
    if args.bundle is not None:
        for line in args.bundle.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            record = json.loads(line)
            datums.append(datum_from_bundle_record(record, loss_fn_override=args.loss_fn))
    else:
        # Build from synthetic/default verifiable observations
        assistant_text = format_inkling_assistant_turn(
            completion="Verified versioned_base_prefix strips duplicate /v1.",
            reasoning="Checking lib/runtime_model/runtime_provider_binding.ml.",
            effort=0.8,
        )
        datums.append(
            build_shifted_datum(
                trajectory_id="traj-1",
                prompt_tokens=deterministic_byte_tokens("Check Tinker OpenAI path normalization."),
                completion_tokens=deterministic_byte_tokens(assistant_text),
                loss_fn=args.loss_fn,
                effort=0.8,
                advantage=1.0,
            )
        )

    state_path: str | None = None
    if args.mode == "dry-run":
        sampler_path = f"tinker://{args.run_id}:train:0/sampler_weights/{args.step:06d}"
        if args.save_state:
            state_path = f"tinker://{args.run_id}:train:0/weights/{args.step:06d}"
        mean_loss = 0.342
        status = "dry_run"
    else:
        live = run_live_tinker_step(
            base_model=args.base_model,
            loss_fn=args.loss_fn,
            datums=datums,
            lora_rank=args.lora_rank,
            learning_rate=args.learning_rate,
            checkpoint_name=f"{args.step:06d}",
            optimizer=args.optimizer,
            loss_fn_config=loss_fn_config,
            save_state=args.save_state,
        )
        sampler_path = live["sampler_path"]
        state_path = live.get("state_path")
        mean_loss = live["mean_loss"]
        status = "completed"

    envelope = build_snapshot_envelope(
        run_id=args.run_id,
        base_model=args.base_model,
        loss_fn=args.loss_fn,
        optimizer=args.optimizer,
        step=args.step,
        mean_loss=mean_loss,
        status=status,
        sampler_path=sampler_path,
        state_path=state_path,
        eval_pass_rate=args.eval_pass_rate,
        baseline_pass_rate=args.baseline_pass_rate,
        dataset_id="rlvr-latest" if args.loss_fn in RL_LOSS_FUNCTIONS else "sft-latest",
    )

    if args.snapshot_out is not None:
        args.snapshot_out.parent.mkdir(parents=True, exist_ok=True)
        args.snapshot_out.write_text(json.dumps(envelope, indent=2, sort_keys=True), encoding="utf-8")

    summary = {
        "mode": args.mode,
        "run_id": args.run_id,
        "base_model": args.base_model,
        "loss_fn": args.loss_fn,
        "optimizer": args.optimizer,
        "datum_count": len(datums),
        "sampler_path": sampler_path,
        "state_path": state_path,
        "snapshot_out": str(args.snapshot_out) if args.snapshot_out else None,
    }
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
