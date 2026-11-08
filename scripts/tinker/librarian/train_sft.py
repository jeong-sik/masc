# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0", "tinker==0.39.0", "tinker-cookbook==0.6.1", "torch>=2.10"]
# ///
# pyright: strict
"""Train one LoRA branch on the teacher answers that matched their labels.

    uv run scripts/tinker/librarian/train_sft.py --branch A \
        --requests artifacts/tinker/librarian/synth-train/requests.jsonl \
        --accepted artifacts/tinker/librarian/teacher/accepted.jsonl \
        --out artifacts/tinker/librarian/train-A --budget 70

Branch A learns the answer only. Branch B learns the teacher's thinking and the
answer. Both render with reasoning effort 0.2, the value the binding's
`reasoning-effort = "low"` sends; the tml_v0 renderer would otherwise render
0.9. The run refuses to start unless pass_lines.json has the bytes it was fixed
with, so the gates exist before any weights change, and refuses requests from a
Keeper whose memories belong to E-synth (`synth_spec.EVAL_KEEPERS`). A cost
estimate above --budget stops the run before training.
Output: <out>/config.json, <out>/steps.jsonl, <out>/summary.json with the sampler path.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
import time
from pathlib import Path
from typing import Literal, cast

import tinker
from tinker_cookbook import model_info, renderers
from tinker_cookbook.renderers.base import ContentPart, Message, TextPart, ThinkingPart
from tinker_cookbook.renderers.tml_v0 import TmlV0Renderer
from tinker_cookbook.supervised.common import (
    compute_mean_nll,
    datum_from_model_input_weights,
)
from tinker_cookbook.tokenizer_utils import get_tokenizer

import admission_request as R
import synth_render
import synth_spec as S
from eval_admission import PASS_LINES, schema_instruction

# sha256 of pass_lines.json as fixed on 2026-11-09, before any training run.
PASS_LINES_SHA256 = "8f715ae56649da0ce57cad9ea3771ed34924ef41413c8d5274ef807cf77b8f02"
MODEL = "thinkingmachines/Inkling-2-Small:peft:262144"
EFFORT = 0.2
RANK = 8
LEARNING_RATE = 2e-4
BATCH = 8
EPOCHS = 2
SEED = 20261109
CHECKPOINT_TTL_S = 30 * 86400
# USD per million training tokens on the 256K ID (models_and_pricing, 2026-11-08).
TRAIN_PRICE = 3.00

type JsonObject = dict[str, object]
type Branch = Literal["A", "B"]


def assistant_content(branch: Branch, answer: str, reasoning: str | None) -> list[ContentPart]:
    text: TextPart = {"type": "text", "text": answer}
    match branch:
        case "A":
            return [text]
        case "B":
            if not reasoning:
                raise SystemExit("branch B needs the teacher's reasoning for every example")
            thinking: ThinkingPart = {"type": "thinking", "thinking": reasoning}
            return [thinking, text]


def examples(requests: Path, accepted: Path, n: int) -> list[tuple[JsonObject, JsonObject]]:
    """n accepted teacher answers with their requests, the same n for both branches."""
    by_id = {cast(str, cast(JsonObject, r["request"])["item_id"]): cast(JsonObject, r["request"])
             for r in (cast(JsonObject, json.loads(line)) for line in requests.read_text(encoding="utf-8").splitlines())}
    held_out = sorted({cast(str, cast(JsonObject, r["keeper"])["key"]) for r in by_id.values()} & S.EVAL_KEEPERS)
    if held_out:
        raise SystemExit(f"the requests hold E-synth Keepers {held_out}; train on the train split only")
    kept = sorted((cast(JsonObject, json.loads(line)) for line in accepted.read_text(encoding="utf-8").splitlines()),
                  key=lambda k: cast(str, k["item"]))
    random.Random(SEED).shuffle(kept)
    if len(kept) < n:
        raise SystemExit(f"{len(kept)} accepted answers, {n} needed")
    return [(by_id[cast(str, k["item"])], k) for k in kept[:n]]


def renderer_of(model: str) -> TmlV0Renderer:
    name = model_info.get_recommended_renderer_name(model)
    renderer = renderers.get_renderer(name, get_tokenizer(model))
    if not isinstance(renderer, TmlV0Renderer):
        raise SystemExit(f"{model} renders with {name}; only tml_v0 takes the reasoning effort this script sets")
    return renderer


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--branch", choices=["A", "B"], required=True)
    ap.add_argument("--requests", required=True)
    ap.add_argument("--accepted", required=True)
    ap.add_argument("--examples", type=int, default=200)
    ap.add_argument("--out", required=True)
    ap.add_argument("--budget", type=float, required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if hashlib.sha256(PASS_LINES.read_bytes()).hexdigest() != PASS_LINES_SHA256:
        raise SystemExit("pass_lines.json is not the fixed one; fix and commit the pass lines first")
    branch = cast(Branch, args.branch)
    out = Path(cast(str, args.out))
    out.mkdir(parents=True, exist_ok=True)
    renderer = renderer_of(MODEL)
    instruction = schema_instruction()
    datums: list[tinker.Datum] = []
    for request, kept in examples(Path(cast(str, args.requests)), Path(cast(str, args.accepted)),
                                  cast(int, args.examples)):
        messages: list[Message] = [
            {"role": "user", "content": R.render(synth_render.prompt_of(request))},
            {"role": "user", "content": instruction},
            {"role": "assistant", "content": assistant_content(branch, cast(str, kept["answer"]),
                                                               cast(str | None, kept["reasoning"]))}]
        model_input, weights = renderer.build_supervised_example(
            messages, train_on_what=renderers.TrainOnWhat.ALL_ASSISTANT_MESSAGES, effort=EFFORT)
        datums.append(datum_from_model_input_weights(model_input, weights, None, reduction="mean"))
    lengths = sorted(d.model_input.length for d in datums)
    per_epoch = sum(lengths)
    estimate = per_epoch * EPOCHS * TRAIN_PRICE / 1e6
    config: JsonObject = {
        "model": MODEL, "branch": branch, "examples": len(datums), "effort": EFFORT, "rank": RANK,
        "learning_rate": LEARNING_RATE, "batch": BATCH, "epochs": EPOCHS, "seed": SEED,
        "tokens": {"per_epoch": per_epoch, "p50": lengths[len(lengths) // 2], "max": lengths[-1]},
        "estimate_usd": round(estimate, 2), "budget_usd": cast(float, args.budget),
        "pass_lines_sha256": PASS_LINES_SHA256}
    (out / "config.json").write_text(json.dumps(config, indent=1) + "\n", encoding="utf-8")
    print("CONFIG", json.dumps(config), flush=True)
    if args.dry_run or estimate > cast(float, args.budget):
        return 0 if args.dry_run else 2

    trainer = tinker.ServiceClient().create_lora_training_client(base_model=MODEL, rank=RANK, seed=SEED).result()
    adam = tinker.AdamParams(learning_rate=LEARNING_RATE, beta1=0.9, beta2=0.95, eps=1e-8)
    rng = random.Random(SEED + 1)
    spent = 0.0
    with (out / "steps.jsonl").open("w", encoding="utf-8") as fh:
        for epoch in range(EPOCHS):
            order = list(range(len(datums)))
            rng.shuffle(order)
            for start in range(0, len(order), BATCH):
                batch = [datums[i] for i in order[start:start + BATCH]]
                tokens = sum(d.model_input.length for d in batch)
                t0 = time.monotonic()
                fwd = trainer.forward_backward(batch, loss_fn="cross_entropy")
                opt = trainer.optim_step(adam_params=adam)
                result = fwd.result()
                opt.result()
                nll = compute_mean_nll([o["logprobs"] for o in result.loss_fn_outputs],
                                       [d.loss_fn_inputs["weights"] for d in batch])
                spent += tokens * TRAIN_PRICE / 1e6
                step = {"epoch": epoch, "start": start, "tokens": tokens, "train_mean_nll": round(nll, 5),
                        "wall_s": round(time.monotonic() - t0, 2), "spent_usd": round(spent, 4)}
                fh.write(json.dumps(step) + "\n")
                fh.flush()
                print("STEP", json.dumps(step), flush=True)
    saved = trainer.save_weights_for_sampler(name=f"masc-librarian-admission-{branch}",
                                             ttl_seconds=CHECKPOINT_TTL_S).result()
    summary: JsonObject = {**config, "sampler_path": saved.path, "checkpoint_ttl_s": CHECKPOINT_TTL_S,
                           "spent_usd": round(spent, 4)}
    (out / "summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    print("SAVED", saved.path, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
