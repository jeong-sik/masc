#!/usr/bin/env python3
"""MASC Lane Add-on worker for Thinking Machines Tinker post-training & checkpoints."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
import tomllib
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from protocol import (  # noqa: E402
    INPUT_SCHEMA,
    InvalidInput,
    OUTPUT_SCHEMA,
    decode_json,
    encode_output,
    evidence as parse_evidence,
    number,
    object_value,
    optional_string,
    reply_id,
    sources_from_json,
    string,
    validate_json,
)

LOSS_FUNCTIONS = frozenset({
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
OPTIMIZERS = frozenset({"adamw", "dimuon"})
TURN_ROLES = frozenset({"exact_gate", "keeper_turn", "verifier_judge"})
VERIFIER_VERDICTS = frozenset({
    "Done",
    "Record_proof_proven",
    "Producer_must_act",
    "Record_proof_refuted",
    "Pending",
})
RUN_STATUSES = frozenset({"running", "completed", "failed", "dry_run"})
BINDING_KEYS = frozenset({
    "base_model",
    "target_loss",
    "optimizer",
    "default_effort",
    "min_eval_gain",
    "sources",
})

OBSERVE_INPUT_SCHEMA = {
    "type": "object",
    "required": ["binding", "sources"],
    "additionalProperties": False,
    "properties": {
        "context": {
            "type": "object",
            "required": ["instance_id", "incarnation"],
            "additionalProperties": False,
            "properties": {
                "instance_id": {"type": "string", "minLength": 1},
                "incarnation": {"type": "string", "minLength": 1},
            },
        },
        **INPUT_SCHEMA["properties"],
    },
}

ACTION_TOOL = {
    "name": "lane_act",
    "description": (
        "Prepare Tinker SFT/RLVR post-training datasets from verified Keeper "
        "trajectories, register Tinker sampler checkpoints, or export NDJSON bundles."
    ),
    "inputSchema": {
        "type": "object",
        "required": ["context", "request_id", "action"],
        "additionalProperties": False,
        "properties": {
            "context": {
                "type": "object",
                "required": ["instance_id", "incarnation"],
                "additionalProperties": False,
                "properties": {
                    "instance_id": {"type": "string", "minLength": 1},
                    "incarnation": {"type": "string", "minLength": 1},
                },
            },
            "request_id": {"type": "string", "minLength": 1},
            "action": {
                "type": "object",
                "oneOf": [
                    {
                        "type": "object",
                        "required": ["kind", "dataset_id"],
                        "additionalProperties": False,
                        "properties": {
                            "kind": {"type": "string", "enum": ["prepare_sft"]},
                            "dataset_id": {"type": "string", "minLength": 1},
                        },
                    },
                    {
                        "type": "object",
                        "required": ["kind", "dataset_id", "loss_fn"],
                        "additionalProperties": False,
                        "properties": {
                            "kind": {"type": "string", "enum": ["prepare_rlvr"]},
                            "dataset_id": {"type": "string", "minLength": 1},
                            "loss_fn": {
                                "type": "string",
                                "enum": sorted(RL_LOSS_FUNCTIONS),
                            },
                        },
                    },
                    {
                        "type": "object",
                        "required": [
                            "kind",
                            "checkpoint_id",
                            "run_id",
                            "sampler_path",
                            "step",
                        ],
                        "additionalProperties": False,
                        "properties": {
                            "kind": {"type": "string", "enum": ["register_checkpoint"]},
                            "checkpoint_id": {"type": "string", "minLength": 1},
                            "run_id": {"type": "string", "minLength": 1},
                            "sampler_path": {"type": "string", "minLength": 10},
                            "step": {"type": "integer", "minimum": 0},
                            "eval_pass_rate": {
                                "type": "number",
                                "minimum": 0.0,
                                "maximum": 1.0,
                            },
                            "baseline_pass_rate": {
                                "type": "number",
                                "minimum": 0.0,
                                "maximum": 1.0,
                            },
                        },
                    },
                    {
                        "type": "object",
                        "required": ["kind", "dataset_id"],
                        "additionalProperties": False,
                        "properties": {
                            "kind": {"type": "string", "enum": ["export_bundle"]},
                            "dataset_id": {"type": "string", "minLength": 1},
                        },
                    },
                ],
            },
        },
    },
    "annotations": {
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
}

TOOLS = [
    {
        "name": "lane_observe",
        "description": "Manage Tinker SFT/RLVR post-training datasets, runs and sampler checkpoints.",
        "inputSchema": OBSERVE_INPUT_SCHEMA,
        "outputSchema": OUTPUT_SCHEMA,
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    ACTION_TOOL,
]


def is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def domain_clock(domain: str, value: int | str) -> dict[str, str]:
    return {"domain": domain, "value": str(value)}


def make_row(
    *,
    id: str,
    lane_id: str,
    kind: str,
    title: str,
    observed_at: int,
    subject_id: str,
    clock: dict[str, str] | None,
    actor: str | None,
    fields: dict[str, Any],
    evidence: list[dict[str, str | None]],
    related_ids: list[str],
) -> dict[str, Any]:
    return {
        "id": id,
        "lane_id": lane_id,
        "kind": kind,
        "title": title,
        "observed_at": observed_at,
        "subject_id": subject_id,
        "clock": clock,
        "actor": actor,
        "fields": fields,
        "evidence": evidence,
        "related_ids": related_ids,
    }


def parse_effort(value: Any, label: str) -> float:
    effort = float(number(value, label))
    if effort < 0.0 or effort >= 1.0:
        raise InvalidInput(f"{label} must be in [0.0, 1.0)")
    return round(effort, 2)


def parse_rate(value: Any, label: str) -> float:
    rate = float(number(value, label))
    if rate < 0.0 or rate > 1.0:
        raise InvalidInput(f"{label} must be in [0.0, 1.0]")
    return round(rate, 4)


def parse_binding(raw: Any) -> dict[str, Any]:
    binding = object_value(raw, "binding")
    unknown = set(binding) - BINDING_KEYS
    if unknown:
        raise InvalidInput(f"binding contains unknown keys: {', '.join(sorted(unknown))}")
    base_model = string(binding.get("base_model"), "binding.base_model")
    target_loss = string(binding.get("target_loss"), "binding.target_loss")
    if target_loss not in LOSS_FUNCTIONS:
        raise InvalidInput(f"binding.target_loss is unsupported: {target_loss}")
    optimizer_raw = binding.get("optimizer")
    if optimizer_raw is None:
        optimizer = "dimuon" if target_loss == "cross_entropy" else "adamw"
    else:
        optimizer = string(optimizer_raw, "binding.optimizer")
        if optimizer not in OPTIMIZERS:
            raise InvalidInput(f"binding.optimizer must be one of {sorted(OPTIMIZERS)}")
    default_effort_raw = binding.get("default_effort")
    if default_effort_raw is None:
        default_effort = 0.8
    else:
        default_effort = parse_effort(default_effort_raw, "binding.default_effort")
    min_eval_gain_raw = binding.get("min_eval_gain")
    if min_eval_gain_raw is None:
        min_eval_gain = 0.0
    else:
        min_eval_gain = parse_rate(min_eval_gain_raw, "binding.min_eval_gain")
    return {
        "base_model": base_model,
        "target_loss": target_loss,
        "optimizer": optimizer,
        "default_effort": default_effort,
        "min_eval_gain": min_eval_gain,
    }


def parse_context(arguments: dict[str, Any]) -> tuple[str, str]:
    raw = arguments.get("context")
    if raw is None:
        return ("default", "default")
    ctx = object_value(raw, "context")
    if set(ctx) != {"instance_id", "incarnation"}:
        raise InvalidInput("context must contain exactly instance_id and incarnation")
    return (
        string(ctx.get("instance_id"), "context.instance_id"),
        string(ctx.get("incarnation"), "context.incarnation"),
    )


def validate_common_observation(
    obs: dict[str, Any], label: str
) -> tuple[str, int, str | None, list[dict[str, str | None]]]:
    obs_id = string(obs.get("id"), f"{label}.id")
    observed_at = obs.get("observed_at")
    if not is_int(observed_at) or observed_at < 0:
        raise InvalidInput(f"{label}.observed_at must be a non-negative integer")
    actor = optional_string(obs.get("actor"), f"{label}.actor")
    ev = parse_evidence(obs.get("evidence"))
    return obs_id, observed_at, actor, ev


def parse_keeper_receipt(obs: dict[str, Any]) -> dict[str, Any]:
    allowed = {
        "id",
        "kind",
        "observed_at",
        "actor",
        "evidence",
        "trajectory_id",
        "keeper_id",
        "prompt",
        "completion",
        "turn_role",
        "reasoning",
        "logprobs",
        "effort",
        "task_id",
    }
    if not set(obs).issubset(allowed):
        unknown = sorted(set(obs) - allowed)
        raise InvalidInput(f"keeper_receipt contains unknown keys: {', '.join(unknown)}")
    obs_id, observed_at, actor, ev = validate_common_observation(obs, "keeper_receipt")
    trajectory_id = string(obs.get("trajectory_id"), "keeper_receipt.trajectory_id")
    keeper_id = string(obs.get("keeper_id"), "keeper_receipt.keeper_id")
    prompt = string(obs.get("prompt"), "keeper_receipt.prompt")
    completion = string(obs.get("completion"), "keeper_receipt.completion")
    turn_role = string(obs.get("turn_role"), "keeper_receipt.turn_role")
    if turn_role not in TURN_ROLES:
        raise InvalidInput(f"keeper_receipt.turn_role must be one of {sorted(TURN_ROLES)}")
    reasoning = optional_string(obs.get("reasoning"), "keeper_receipt.reasoning")
    task_id = optional_string(obs.get("task_id"), "keeper_receipt.task_id")
    raw_logprobs = obs.get("logprobs")
    logprobs: list[float] | None = None
    if raw_logprobs is not None:
        if not isinstance(raw_logprobs, list) or not raw_logprobs:
            raise InvalidInput("keeper_receipt.logprobs must be a non-empty list of numbers when present")
        logprobs = [float(number(item, "keeper_receipt.logprobs[]")) for item in raw_logprobs]
    effort_raw = obs.get("effort")
    effort = parse_effort(effort_raw, "keeper_receipt.effort") if effort_raw is not None else None
    return {
        "id": obs_id,
        "observed_at": observed_at,
        "actor": actor,
        "evidence": ev,
        "trajectory_id": trajectory_id,
        "keeper_id": keeper_id,
        "prompt": prompt,
        "completion": completion,
        "turn_role": turn_role,
        "reasoning": reasoning,
        "logprobs": logprobs,
        "effort": effort,
        "task_id": task_id,
    }


def parse_verifier_verdict(obs: dict[str, Any]) -> dict[str, Any]:
    allowed = {
        "id",
        "kind",
        "observed_at",
        "actor",
        "evidence",
        "trajectory_id",
        "verdict",
        "score",
        "reason",
    }
    if not set(obs).issubset(allowed):
        unknown = sorted(set(obs) - allowed)
        raise InvalidInput(f"verifier_verdict contains unknown keys: {', '.join(unknown)}")
    obs_id, observed_at, actor, ev = validate_common_observation(obs, "verifier_verdict")
    trajectory_id = string(obs.get("trajectory_id"), "verifier_verdict.trajectory_id")
    verdict = string(obs.get("verdict"), "verifier_verdict.verdict")
    if verdict not in VERIFIER_VERDICTS:
        raise InvalidInput(f"verifier_verdict.verdict must be one of {sorted(VERIFIER_VERDICTS)}")
    score_raw = obs.get("score")
    if score_raw is not None:
        score = float(number(score_raw, "verifier_verdict.score"))
        if score < -1.0 or score > 1.0:
            raise InvalidInput("verifier_verdict.score must be in [-1.0, 1.0]")
    else:
        if verdict in {"Done", "Record_proof_proven"}:
            score = 1.0
        elif verdict in {"Producer_must_act", "Record_proof_refuted"}:
            score = -1.0
        else:
            score = 0.0
    reason = optional_string(obs.get("reason"), "verifier_verdict.reason")
    return {
        "id": obs_id,
        "observed_at": observed_at,
        "actor": actor,
        "evidence": ev,
        "trajectory_id": trajectory_id,
        "verdict": verdict,
        "score": round(score, 4),
        "reason": reason,
    }


def parse_karma_event(obs: dict[str, Any]) -> dict[str, Any]:
    allowed = {
        "id",
        "kind",
        "observed_at",
        "actor",
        "evidence",
        "trajectory_id",
        "karma_delta",
    }
    if not set(obs).issubset(allowed):
        unknown = sorted(set(obs) - allowed)
        raise InvalidInput(f"karma_event contains unknown keys: {', '.join(unknown)}")
    obs_id, observed_at, actor, ev = validate_common_observation(obs, "karma_event")
    trajectory_id = string(obs.get("trajectory_id"), "karma_event.trajectory_id")
    karma_delta = obs.get("karma_delta")
    if not is_int(karma_delta):
        raise InvalidInput("karma_event.karma_delta must be an integer")
    return {
        "id": obs_id,
        "observed_at": observed_at,
        "actor": actor,
        "evidence": ev,
        "trajectory_id": trajectory_id,
        "karma_delta": karma_delta,
    }


def parse_sampler_path(raw: Any, label: str) -> str:
    path = string(raw, label)
    if not path.startswith("tinker://"):
        raise InvalidInput(f"{label} must start with tinker://")
    return path


def parse_tinker_run(obs: dict[str, Any]) -> dict[str, Any]:
    allowed = {
        "id",
        "kind",
        "observed_at",
        "actor",
        "evidence",
        "run_id",
        "base_model",
        "loss_fn",
        "optimizer",
        "step",
        "mean_loss",
        "status",
        "sampler_path",
        "state_path",
        "eval_pass_rate",
        "baseline_pass_rate",
        "dataset_id",
    }
    if not set(obs).issubset(allowed):
        unknown = sorted(set(obs) - allowed)
        raise InvalidInput(f"tinker_run contains unknown keys: {', '.join(unknown)}")
    obs_id, observed_at, actor, ev = validate_common_observation(obs, "tinker_run")
    run_id = string(obs.get("run_id"), "tinker_run.run_id")
    base_model = string(obs.get("base_model"), "tinker_run.base_model")
    loss_fn = string(obs.get("loss_fn"), "tinker_run.loss_fn")
    if loss_fn not in LOSS_FUNCTIONS:
        raise InvalidInput(f"tinker_run.loss_fn must be one of {sorted(LOSS_FUNCTIONS)}")
    opt_raw = obs.get("optimizer")
    if opt_raw is None:
        optimizer = "dimuon" if loss_fn == "cross_entropy" else "adamw"
    else:
        optimizer = string(opt_raw, "tinker_run.optimizer")
        if optimizer not in OPTIMIZERS:
            raise InvalidInput(f"tinker_run.optimizer must be one of {sorted(OPTIMIZERS)}")
    step = obs.get("step")
    if not is_int(step) or step < 0:
        raise InvalidInput("tinker_run.step must be a non-negative integer")
    mean_loss = round(float(number(obs.get("mean_loss"), "tinker_run.mean_loss")), 6)
    status = string(obs.get("status"), "tinker_run.status")
    if status not in RUN_STATUSES:
        raise InvalidInput(f"tinker_run.status must be one of {sorted(RUN_STATUSES)}")
    sampler_raw = obs.get("sampler_path")
    sampler_path = parse_sampler_path(sampler_raw, "tinker_run.sampler_path") if sampler_raw is not None else None
    state_raw = obs.get("state_path")
    state_path = parse_sampler_path(state_raw, "tinker_run.state_path") if state_raw is not None else None
    eval_raw = obs.get("eval_pass_rate")
    eval_pass_rate = parse_rate(eval_raw, "tinker_run.eval_pass_rate") if eval_raw is not None else None
    base_raw = obs.get("baseline_pass_rate")
    baseline_pass_rate = parse_rate(base_raw, "tinker_run.baseline_pass_rate") if base_raw is not None else None
    dataset_id = optional_string(obs.get("dataset_id"), "tinker_run.dataset_id")
    return {
        "id": obs_id,
        "observed_at": observed_at,
        "actor": actor,
        "evidence": ev,
        "run_id": run_id,
        "base_model": base_model,
        "loss_fn": loss_fn,
        "optimizer": optimizer,
        "step": step,
        "mean_loss": mean_loss,
        "status": status,
        "sampler_path": sampler_path,
        "state_path": state_path,
        "eval_pass_rate": eval_pass_rate,
        "baseline_pass_rate": baseline_pass_rate,
        "dataset_id": dataset_id,
    }


def resolve_effort(receipt: dict[str, Any], default_effort: float) -> float:
    if receipt["effort"] is not None:
        return receipt["effort"]
    role = receipt["turn_role"]
    if role == "exact_gate":
        return 0.0
    if role == "verifier_judge":
        return 0.99
    return default_effort


def dedupe_evidence(items: list[dict[str, str | None]]) -> list[dict[str, str | None]]:
    seen: set[tuple[str, str | None]] = set()
    out: list[dict[str, str | None]] = []
    for item in items:
        key = (str(item["uri"]), item.get("sha256"))
        if key not in seen:
            seen.add(key)
            out.append(item)
    return out


def derive_trajectories(
    receipts: list[dict[str, Any]],
    verdicts: list[dict[str, Any]],
    karmas: list[dict[str, Any]],
    default_effort: float,
) -> list[dict[str, Any]]:
    verdicts_by_traj: dict[str, list[dict[str, Any]]] = {}
    for verdict in verdicts:
        verdicts_by_traj.setdefault(verdict["trajectory_id"], []).append(verdict)
    karmas_by_traj: dict[str, list[dict[str, Any]]] = {}
    for karma in karmas:
        karmas_by_traj.setdefault(karma["trajectory_id"], []).append(karma)

    derived: list[dict[str, Any]] = []
    for receipt in receipts:
        tid = receipt["trajectory_id"]
        matched_verdicts = verdicts_by_traj.get(tid, [])
        matched_karmas = karmas_by_traj.get(tid, [])
        net_karma = sum(k["karma_delta"] for k in matched_karmas)

        if matched_verdicts:
            latest_verdict = max(matched_verdicts, key=lambda v: (v["observed_at"], v["id"]))
            base_reward = latest_verdict["score"]
            verdict_name = latest_verdict["verdict"]
        else:
            verdict_name = "Unverified"
            if net_karma > 0:
                base_reward = 0.5
            elif net_karma < 0:
                base_reward = -0.5
            else:
                base_reward = 0.0

        # A negative verifier verdict must never be flipped positive by karma upvotes.
        if base_reward < 0.0:
            reward = base_reward
        elif base_reward > 0.0 and net_karma > 0:
            reward = min(1.0, round(base_reward + min(0.2, 0.05 * net_karma), 4))
        else:
            reward = base_reward

        effort = resolve_effort(receipt, default_effort)
        ev = list(receipt["evidence"])
        related_ids = [receipt["id"]]
        observed_at = receipt["observed_at"]
        for v in matched_verdicts:
            ev.extend(v["evidence"])
            related_ids.append(v["id"])
            observed_at = max(observed_at, v["observed_at"])
        for k in matched_karmas:
            ev.extend(k["evidence"])
            related_ids.append(k["id"])
            observed_at = max(observed_at, k["observed_at"])

        derived.append({
            "trajectory_id": tid,
            "keeper_id": receipt["keeper_id"],
            "task_id": receipt["task_id"],
            "turn_role": receipt["turn_role"],
            "effort": effort,
            "prompt": receipt["prompt"],
            "reasoning": receipt["reasoning"],
            "completion": receipt["completion"],
            "logprobs": receipt["logprobs"],
            "verdict": verdict_name,
            "karma_delta": net_karma,
            "reward": round(reward, 4),
            "observed_at": observed_at,
            "actor": receipt["actor"],
            "evidence": dedupe_evidence(ev),
            "related_ids": related_ids,
        })
    return derived


def build_datum_record(traj: dict[str, Any], *, base_model: str, loss_fn: str, advantage: float) -> dict[str, Any]:
    effort_tag = f"<thinking effort={traj['effort']:.2f}>"
    reasoning_text = traj["reasoning"] or ""
    assistant_body = (
        f"{effort_tag}\n{reasoning_text}\n</thinking>\n{traj['completion']}"
        if traj["effort"] > 0.0
        else f"{effort_tag}</thinking>\n{traj['completion']}"
    )
    record: dict[str, Any] = {
        "trajectory_id": traj["trajectory_id"],
        "base_model": base_model,
        "loss_fn": loss_fn,
        "turn_role": traj["turn_role"],
        "effort": traj["effort"],
        "reward": traj["reward"],
        "advantage": round(advantage, 4),
        "verdict": traj["verdict"],
        "messages": [
            {"role": "user", "content": traj["prompt"]},
            {"role": "assistant", "content": assistant_body},
        ],
        "loss_mask": {"prompt_weight": 0.0, "completion_weight": 1.0},
    }
    if traj["logprobs"] is not None:
        record["sampling_logprobs"] = traj["logprobs"]
    return record


def build_dataset_bundle(
    dataset_id: str,
    *,
    base_model: str,
    loss_fn: str,
    trajectories: list[dict[str, Any]],
) -> dict[str, Any]:
    if loss_fn == "cross_entropy":
        selected = [t for t in trajectories if t["reward"] > 0.0]
        datums = [
            build_datum_record(t, base_model=base_model, loss_fn=loss_fn, advantage=t["reward"])
            for t in selected
        ]
    else:
        selected = [t for t in trajectories if t["reward"] != 0.0]
        mean_reward = (
            sum(t["reward"] for t in selected) / len(selected)
            if selected
            else 0.0
        )
        datums = []
        for t in selected:
            adv = (t["reward"] - mean_reward) if len(selected) > 1 else t["reward"]
            if adv == 0.0:
                adv = t["reward"]
            datums.append(build_datum_record(t, base_model=base_model, loss_fn=loss_fn, advantage=adv))

    positive_count = sum(1 for t in selected if t["reward"] > 0.0)
    negative_count = sum(1 for t in selected if t["reward"] < 0.0)
    observed_at = max((t["observed_at"] for t in selected), default=0)
    ev: list[dict[str, str | None]] = []
    related_ids: list[str] = []
    for t in selected:
        ev.extend(t["evidence"])
        related_ids.extend(t["related_ids"])

    ndjson_lines = "".join(json.dumps(d, sort_keys=True) + "\n" for d in datums)
    bundle_sha256 = sha256_hex(ndjson_lines)
    if not ev:
        ev = [{"uri": f"tinker-dataset://{dataset_id}", "sha256": bundle_sha256}]
    else:
        ev = dedupe_evidence(ev)

    return {
        "dataset_id": dataset_id,
        "base_model": base_model,
        "loss_fn": loss_fn,
        "datum_count": len(datums),
        "positive_count": positive_count,
        "negative_count": negative_count,
        "bundle_sha256": bundle_sha256,
        "observed_at": observed_at,
        "datums": datums,
        "ndjson": ndjson_lines,
        "evidence": ev,
        "related_ids": list(dict.fromkeys(related_ids)),
    }


def readiness_verdict(
    eval_pass_rate: float | None,
    baseline_pass_rate: float | None,
    min_eval_gain: float,
) -> tuple[str, float | None]:
    if eval_pass_rate is None or baseline_pass_rate is None:
        return ("unverified", None)
    gain = round(eval_pass_rate - baseline_pass_rate, 4)
    if eval_pass_rate < baseline_pass_rate:
        return ("regressed", gain)
    if gain >= min_eval_gain:
        return ("promote_ready", gain)
    return ("insufficient_gain", gain)


class StateStore:
    def __init__(self, state_dir: Path | None) -> None:
        self.state_dir = state_dir
        self.instances: dict[str, dict[str, Any]] = {}
        if self.state_dir is not None:
            self.state_dir.mkdir(parents=True, exist_ok=True)
            state_file = self.state_dir / "state.json"
            if state_file.exists():
                loaded = json.loads(state_file.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    self.instances = loaded

    def instance(self, instance_id: str) -> dict[str, Any]:
        return self.instances.setdefault(
            instance_id,
            {
                "binding": None,
                "trajectories": [],
                "datasets": {},
                "checkpoints": {},
                "runs": [],
                "coverage": [],
            },
        )

    def save(self) -> None:
        if self.state_dir is None:
            return
        state_file = self.state_dir / "state.json"
        tmp_file = self.state_dir / "state.json.tmp"
        tmp_file.write_text(json.dumps(self.instances, indent=2, sort_keys=True), encoding="utf-8")
        tmp_file.replace(state_file)


def project_rows(slot: dict[str, Any]) -> list[dict[str, Any]]:
    binding = slot.get("binding") or {
        "base_model": "thinkingmachines/Inkling-2-Small",
        "target_loss": "cispo",
        "default_effort": 0.8,
        "min_eval_gain": 0.0,
    }
    trajectories: list[dict[str, Any]] = slot.get("trajectories", [])
    runs: list[dict[str, Any]] = slot.get("runs", [])
    datasets: dict[str, dict[str, Any]] = slot.get("datasets", {})
    checkpoints: dict[str, dict[str, Any]] = slot.get("checkpoints", {})

    rows: list[dict[str, Any]] = []

    if trajectories:
        corpus_bundle = build_dataset_bundle(
            "observed-corpus",
            base_model=binding["base_model"],
            loss_fn=binding["target_loss"],
            trajectories=trajectories,
        )
        rows.append(
            make_row(
                id="tinker:dataset:observed-corpus",
                lane_id="tinker/datasets",
                kind="value",
                title=f"Observed corpus ({corpus_bundle['datum_count']} datums)",
                observed_at=corpus_bundle["observed_at"],
                subject_id="observed-corpus",
                clock=domain_clock("tinker/datasets", corpus_bundle["datum_count"]),
                actor=None,
                fields={
                    "dataset_id": "observed-corpus",
                    "loss_fn": corpus_bundle["loss_fn"],
                    "base_model": corpus_bundle["base_model"],
                    "datum_count": corpus_bundle["datum_count"],
                    "positive_count": corpus_bundle["positive_count"],
                    "negative_count": corpus_bundle["negative_count"],
                    "bundle_sha256": corpus_bundle["bundle_sha256"],
                },
                evidence=corpus_bundle["evidence"],
                related_ids=corpus_bundle["related_ids"],
            )
        )

    for dataset_id in sorted(datasets):
        ds = datasets[dataset_id]
        rows.append(
            make_row(
                id=f"tinker:dataset:{dataset_id}",
                lane_id="tinker/datasets",
                kind="value",
                title=f"Dataset {dataset_id} ({ds['loss_fn']}, {ds['datum_count']} datums)",
                observed_at=ds["observed_at"],
                subject_id=dataset_id,
                clock=domain_clock(f"tinker/dataset/{dataset_id}", ds["datum_count"]),
                actor=None,
                fields={
                    "dataset_id": dataset_id,
                    "loss_fn": ds["loss_fn"],
                    "base_model": ds["base_model"],
                    "datum_count": ds["datum_count"],
                    "positive_count": ds["positive_count"],
                    "negative_count": ds["negative_count"],
                    "bundle_sha256": ds["bundle_sha256"],
                },
                evidence=ds["evidence"],
                related_ids=ds["related_ids"],
            )
        )

    all_checkpoints: dict[str, dict[str, Any]] = {}
    for run in runs:
        run_row_id = f"tinker:run:{run['run_id']}:{run['step']}"
        rows.append(
            make_row(
                id=run_row_id,
                lane_id="tinker/runs",
                kind="event",
                title=f"Run {run['run_id']} step {run['step']} ({run['status']})",
                observed_at=run["observed_at"],
                subject_id=run["run_id"],
                clock=domain_clock(f"tinker/run/{run['run_id']}/step", run["step"]),
                actor=run["actor"],
                fields={
                    "run_id": run["run_id"],
                    "base_model": run["base_model"],
                    "loss_fn": run["loss_fn"],
                    "step": run["step"],
                    "mean_loss": run["mean_loss"],
                    "status": run["status"],
                    "sampler_path": run["sampler_path"],
                    "dataset_id": run["dataset_id"],
                },
                evidence=run["evidence"],
                related_ids=[run["id"]],
            )
        )
        if run["sampler_path"] is not None:
            cid = f"{run['run_id']}@{run['step']}"
            all_checkpoints[cid] = {
                "checkpoint_id": cid,
                "run_id": run["run_id"],
                "sampler_path": run["sampler_path"],
                "step": run["step"],
                "eval_pass_rate": run["eval_pass_rate"],
                "baseline_pass_rate": run["baseline_pass_rate"],
                "observed_at": run["observed_at"],
                "actor": run["actor"],
                "evidence": run["evidence"],
                "related_ids": [run_row_id],
            }

    for cid in sorted(checkpoints):
        all_checkpoints[cid] = checkpoints[cid]

    for cid in sorted(all_checkpoints):
        ckpt = all_checkpoints[cid]
        ckpt_row_id = f"tinker:checkpoint:{cid}"
        rows.append(
            make_row(
                id=ckpt_row_id,
                lane_id="tinker/checkpoints",
                kind="value",
                title=f"Checkpoint {cid}",
                observed_at=ckpt["observed_at"],
                subject_id=cid,
                clock=domain_clock(f"tinker/checkpoint/{ckpt['run_id']}/step", ckpt["step"]),
                actor=ckpt["actor"],
                fields={
                    "checkpoint_id": cid,
                    "run_id": ckpt["run_id"],
                    "sampler_path": ckpt["sampler_path"],
                    "step": ckpt["step"],
                    "eval_pass_rate": ckpt["eval_pass_rate"],
                    "baseline_pass_rate": ckpt["baseline_pass_rate"],
                },
                evidence=ckpt["evidence"],
                related_ids=ckpt["related_ids"],
            )
        )
        verdict, gain = readiness_verdict(
            ckpt["eval_pass_rate"],
            ckpt["baseline_pass_rate"],
            binding["min_eval_gain"],
        )
        rows.append(
            make_row(
                id=f"tinker:readiness:{cid}",
                lane_id="tinker/readiness",
                kind="relation",
                title=f"Readiness {cid}: {verdict}",
                observed_at=ckpt["observed_at"],
                subject_id=cid,
                clock=domain_clock(f"tinker/readiness/{ckpt['run_id']}/step", ckpt["step"]),
                actor=None,
                fields={
                    "checkpoint_id": cid,
                    "run_id": ckpt["run_id"],
                    "verdict": verdict,
                    "eval_gain": gain,
                    "min_eval_gain": binding["min_eval_gain"],
                    "runtime_api_name": ckpt["sampler_path"],
                },
                evidence=ckpt["evidence"],
                related_ids=[ckpt_row_id, *ckpt["related_ids"]],
            )
        )

    return rows


def handle_observe(store: StateStore, raw_arguments: Any) -> dict[str, Any]:
    arguments = object_value(raw_arguments, "arguments")
    validate_json(arguments)
    instance_id, _ = parse_context(arguments)
    binding = parse_binding(arguments.get("binding"))
    sources = sources_from_json(arguments.get("sources"))

    receipts: list[dict[str, Any]] = []
    verdicts: list[dict[str, Any]] = []
    karmas: list[dict[str, Any]] = []
    runs: list[dict[str, Any]] = []
    coverage: list[dict[str, Any]] = []

    for src in sources:
        skipped: set[str] = set()
        for obs in src.observations:
            kind = obs.get("kind")
            if kind == "keeper_receipt":
                receipts.append(parse_keeper_receipt(obs))
            elif kind == "verifier_verdict":
                verdicts.append(parse_verifier_verdict(obs))
            elif kind == "karma_event":
                karmas.append(parse_karma_event(obs))
            elif kind == "tinker_run":
                runs.append(parse_tinker_run(obs))
            else:
                skipped.add(kind if isinstance(kind, str) and kind else "untyped")
        coverage.append(src.coverage(skipped))

    trajectories = derive_trajectories(receipts, verdicts, karmas, binding["default_effort"])
    slot = store.instance(instance_id)
    slot["binding"] = binding
    slot["trajectories"] = trajectories
    slot["runs"] = runs
    slot["coverage"] = coverage
    store.save()
    output = {"rows": project_rows(slot), "coverage": coverage}
    validate_json(output)
    return output


def handle_act(store: StateStore, raw_arguments: Any) -> dict[str, Any]:
    arguments = object_value(raw_arguments, "arguments")
    validate_json(arguments)
    if set(arguments) != {"context", "request_id", "action"}:
        raise InvalidInput("lane_act requires exactly context, request_id and action")
    instance_id, _ = parse_context(arguments)
    request_id = string(arguments.get("request_id"), "request_id")
    action = object_value(arguments.get("action"), "action")
    kind = string(action.get("kind"), "action.kind")

    slot = store.instance(instance_id)
    binding = slot.get("binding") or {
        "base_model": "thinkingmachines/Inkling-2-Small",
        "target_loss": "cispo",
        "default_effort": 0.8,
        "min_eval_gain": 0.0,
    }
    trajectories: list[dict[str, Any]] = slot.get("trajectories", [])

    if kind == "prepare_sft":
        if set(action) != {"kind", "dataset_id"}:
            raise InvalidInput("prepare_sft requires exactly kind and dataset_id")
        dataset_id = string(action.get("dataset_id"), "action.dataset_id")
        bundle = build_dataset_bundle(
            dataset_id,
            base_model=binding["base_model"],
            loss_fn="cross_entropy",
            trajectories=trajectories,
        )
        slot.setdefault("datasets", {})[dataset_id] = bundle
        store.save()
        body: dict[str, Any] = {
            "request_id": request_id,
            "action": "prepare_sft",
            "dataset_id": dataset_id,
            "loss_fn": "cross_entropy",
            "datum_count": bundle["datum_count"],
            "bundle_sha256": bundle["bundle_sha256"],
        }
    elif kind == "prepare_rlvr":
        if set(action) != {"kind", "dataset_id", "loss_fn"}:
            raise InvalidInput("prepare_rlvr requires exactly kind, dataset_id and loss_fn")
        dataset_id = string(action.get("dataset_id"), "action.dataset_id")
        loss_fn = string(action.get("loss_fn"), "action.loss_fn")
        if loss_fn not in RL_LOSS_FUNCTIONS:
            raise InvalidInput(f"prepare_rlvr.loss_fn must be one of {sorted(RL_LOSS_FUNCTIONS)}")
        bundle = build_dataset_bundle(
            dataset_id,
            base_model=binding["base_model"],
            loss_fn=loss_fn,
            trajectories=trajectories,
        )
        slot.setdefault("datasets", {})[dataset_id] = bundle
        store.save()
        body = {
            "request_id": request_id,
            "action": "prepare_rlvr",
            "dataset_id": dataset_id,
            "loss_fn": loss_fn,
            "datum_count": bundle["datum_count"],
            "positive_count": bundle["positive_count"],
            "negative_count": bundle["negative_count"],
            "bundle_sha256": bundle["bundle_sha256"],
        }
    elif kind == "register_checkpoint":
        allowed = {
            "kind",
            "checkpoint_id",
            "run_id",
            "sampler_path",
            "step",
            "eval_pass_rate",
            "baseline_pass_rate",
        }
        required = {"kind", "checkpoint_id", "run_id", "sampler_path", "step"}
        if not required.issubset(set(action)) or not set(action).issubset(allowed):
            raise InvalidInput("register_checkpoint has invalid fields")
        checkpoint_id = string(action.get("checkpoint_id"), "action.checkpoint_id")
        run_id = string(action.get("run_id"), "action.run_id")
        sampler_path = parse_sampler_path(action.get("sampler_path"), "action.sampler_path")
        step = action.get("step")
        if not is_int(step) or step < 0:
            raise InvalidInput("action.step must be a non-negative integer")
        eval_raw = action.get("eval_pass_rate")
        eval_pass_rate = parse_rate(eval_raw, "action.eval_pass_rate") if eval_raw is not None else None
        base_raw = action.get("baseline_pass_rate")
        baseline_pass_rate = parse_rate(base_raw, "action.baseline_pass_rate") if base_raw is not None else None
        digest = sha256_hex(f"{checkpoint_id}:{sampler_path}:{step}")
        ckpt = {
            "checkpoint_id": checkpoint_id,
            "run_id": run_id,
            "sampler_path": sampler_path,
            "step": step,
            "eval_pass_rate": eval_pass_rate,
            "baseline_pass_rate": baseline_pass_rate,
            "observed_at": step,
            "actor": None,
            "evidence": [{"uri": sampler_path, "sha256": digest}],
            "related_ids": [f"tinker:action:{request_id}"],
        }
        slot.setdefault("checkpoints", {})[checkpoint_id] = ckpt
        store.save()
        verdict, gain = readiness_verdict(eval_pass_rate, baseline_pass_rate, binding["min_eval_gain"])
        body = {
            "request_id": request_id,
            "action": "register_checkpoint",
            "checkpoint_id": checkpoint_id,
            "sampler_path": sampler_path,
            "verdict": verdict,
            "eval_gain": gain,
        }
    elif kind == "export_bundle":
        if set(action) != {"kind", "dataset_id"}:
            raise InvalidInput("export_bundle requires exactly kind and dataset_id")
        dataset_id = string(action.get("dataset_id"), "action.dataset_id")
        datasets = slot.get("datasets", {})
        if dataset_id not in datasets:
            raise InvalidInput(f"unknown prepared dataset_id: {dataset_id}")
        bundle = datasets[dataset_id]
        ndjson = bundle["ndjson"]
        body = {
            "request_id": request_id,
            "action": "export_bundle",
            "dataset_id": dataset_id,
            "datum_count": bundle["datum_count"],
            "bundle_sha256": bundle["bundle_sha256"],
            "artifacts": [
                {
                    "name": f"{dataset_id}.jsonl",
                    "content_type": "application/x-ndjson",
                    "encoding": "utf-8",
                    "sha256": bundle["bundle_sha256"],
                    "data": ndjson,
                }
            ],
        }
    else:
        raise InvalidInput(f"unsupported action kind: {kind}")

    rows = project_rows(slot)
    coverage = slot.get("coverage", [])
    payload = {
        "status": "confirmed",
        "result": body,
        "output": {"rows": rows, "coverage": coverage},
    }
    validate_json(payload)
    return payload


def tool_result(structured: dict[str, Any]) -> dict[str, Any]:
    validate_json(structured)
    return {
        "content": [{"type": "text", "text": encode_output(structured)}],
        "structuredContent": structured,
        "isError": False,
    }


def reply(request_id: Any, result: dict[str, Any]) -> str:
    return encode_output({"jsonrpc": "2.0", "id": request_id, "result": result})


def main() -> None:
    parser = argparse.ArgumentParser(description="Tinker post-training Lane Add-on worker")
    parser.add_argument("--state", type=Path, default=None, help="Persistent state directory")
    args = parser.parse_args()

    manifest = tomllib.loads((HERE / "lane.toml").read_text(encoding="utf-8"))
    max_reply_bytes = int(manifest["resources"]["max_reply_bytes"])
    store = StateStore(args.state)

    for line in sys.stdin.buffer:
        request_id = None
        try:
            request = object_value(decode_json(line.decode("utf-8")), "request")
            request_id = reply_id(request.get("id"))
            if "id" not in request or "method" not in request:
                continue
            method = request["method"]
            params = object_value(request.get("params", {}), "params")
            if method == "initialize":
                result = {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "masc-tinker-trainer", "version": manifest["revision"]},
                }
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                name = params.get("name")
                arguments = params.get("arguments")
                try:
                    if name == "lane_observe":
                        result = tool_result(handle_observe(store, arguments))
                    elif name == "lane_act":
                        result = tool_result(handle_act(store, arguments))
                    else:
                        raise InvalidInput("unknown tool")
                except InvalidInput as error:
                    result = {"content": [{"type": "text", "text": str(error)}], "isError": True}
            else:
                print(
                    encode_output({
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": {"code": -32601, "message": "Method not found"},
                    }),
                    flush=True,
                )
                continue
            encoded = reply(request_id, result)
            if method == "tools/call" and len((encoded + "\n").encode("utf-8")) > max_reply_bytes:
                encoded = reply(
                    request_id,
                    {
                        "content": [
                            {
                                "type": "text",
                                "text": "Observation exceeds the declared reply envelope; no output was accepted",
                            }
                        ],
                        "isError": True,
                    },
                )
        except (json.JSONDecodeError, UnicodeDecodeError):
            encoded = encode_output({
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": "Parse error"},
            })
        except InvalidInput as error:
            encoded = encode_output({
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32602, "message": str(error)},
            })
        print(encoded, flush=True)


if __name__ == "__main__":
    main()
