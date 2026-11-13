# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0", "tinker==0.39.0", "tinker-cookbook==0.6.1", "tml-renderers==0.4.1", "torch>=2.10"]
# ///
# pyright: strict
"""Train the LoRA candidate on the teacher answers that matched their labels.

    uv run scripts/tinker/librarian/train_sft.py \
        --requests artifacts/tinker/librarian/train-audited/requests.jsonl \
        --teacher artifacts/tinker/librarian/teacher \
        --out artifacts/tinker/librarian/train-A --budget 70

What is trained on comes from `sft_examples.plan`: every answer accepted in the
teacher's folder with its request, the reasoning effort the examples are
rendered at, and the steps of one pass. An example is three messages: the
request and the schema instruction from the user, as MASC's exact lane and the
verdict's run send them, and the answer from the assistant. The loss is on the
answer only. The answer has no thinking part, so the candidate is trained to
start its answer at once, where the base model writes a thinking part first.
The effort is the one the teacher answered at, the value the binding's
`reasoning-effort` sends; the tml_v0 renderer would otherwise render 0.9.

The run refuses to start unless pass_lines.json has the bytes it was fixed
with, sets a number for every gate and names the candidate in `choice.order`
(`eval_admission.ready_to_train`), so the gates exist before any weights
change. It also refuses while a file the pass lines pin has other bytes
(`eval_admission.load_pass_lines`), so the prompts it trains on are the ones the
verdict renders. A cost estimate above --budget stops the run before training.

Each example is trained on once, so a step's loss is measured before the
weights saw its examples. Requests of one memory share that memory's facts, so
it is not the loss on memories the weights have not seen. A failure during the
pass leaves no checkpoint.

Output: <out>/config.json (with the sha256 of the files the pass lines do not
pin and the versions of the training packages), <out>/steps.jsonl, and
<out>/summary.json with the sampler path, which the verdict reads. After the
summary is written the run also saves the weights with the optimizer state, for
STATE_TTL_S, and writes that checkpoint's path to <out>/state.json: a further
pass would go on from it.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import sys
import time
from pathlib import Path
from typing import cast

import tinker
from tinker_cookbook import model_info, renderers
from tinker_cookbook.renderers.base import Message
from tinker_cookbook.renderers.tml_v0 import TmlV0Renderer
from tinker_cookbook.supervised.common import (
    compute_mean_nll,
    datum_from_model_input_weights,
)
from tinker_cookbook.tokenizer_utils import get_tokenizer

import sft_examples as X
from eval_admission import PASS_LINES, load_pass_lines, ready_to_train, schema_instruction, sha256_file

# sha256 of pass_lines.json as fixed on 2026-11-12, before any training run.
PASS_LINES_SHA256 = "dd68db8da7d357377af6509e435007f867a5b8e261c5a416a8576b0dc36dc7b1"
MODEL = "thinkingmachines/Inkling-2-Small:peft:262144"
# The candidate pass_lines.json `choice.order` names; `verdict` ties it to this run's summary.
CANDIDATE = "A"
RANK = 8
LEARNING_RATE = 2e-4
CHECKPOINT = f"masc-librarian-admission-{CANDIDATE}"
CHECKPOINT_TTL_S = 30 * 86400
STATE_TTL_S = 7 * 86400
# USD per million training tokens on the 256K ID (models_and_pricing, 2026-11-08).
TRAIN_PRICE = 3.00
# The files that decide what is trained on and that pass_lines.json does not pin, beside this one.
UNPINNED = ("train_sft.py", "sft_examples.py", "teacher_sample.py")
PACKAGES = ("tinker", "tinker-cookbook", "tml-renderers")

type JsonObject = dict[str, object]


def renderer_of(model: str) -> TmlV0Renderer:
    name = model_info.get_recommended_renderer_name(model)
    renderer = renderers.get_renderer(name, get_tokenizer(model))
    if not isinstance(renderer, TmlV0Renderer):
        raise SystemExit(f"{model} renders with {name}; only tml_v0 takes the reasoning effort this script sets")
    return renderer


def messages_of(example: X.Example, instruction: str) -> list[Message]:
    """The example as the renderer takes it: the request and the schema instruction from the user,
    then the answer from the assistant."""
    return [{"role": "user", "content": example.request},
            {"role": "user", "content": instruction},
            {"role": "assistant", "content": example.answer}]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--requests", required=True)
    ap.add_argument("--teacher", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--budget", type=float, required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if hashlib.sha256(PASS_LINES.read_bytes()).hexdigest() != PASS_LINES_SHA256:
        raise SystemExit("pass_lines.json is not the fixed one; fix and commit the pass lines first")
    ready_to_train(load_pass_lines(), CANDIDATE)
    plan = X.plan(Path(cast(str, args.requests)), Path(cast(str, args.teacher)))
    out = Path(cast(str, args.out))
    out.mkdir(parents=True, exist_ok=True)
    renderer = renderer_of(MODEL)
    instruction = schema_instruction()
    datums: list[tinker.Datum] = []
    for example in plan.examples:
        model_input, weights = renderer.build_supervised_example(
            messages_of(example, instruction), train_on_what=renderers.TrainOnWhat.ALL_ASSISTANT_MESSAGES,
            effort=plan.effort)
        datums.append(datum_from_model_input_weights(model_input, weights, None, reduction="mean"))
    lengths = sorted(d.model_input.length for d in datums)
    total = sum(lengths)
    estimate = total * TRAIN_PRICE / 1e6
    here = Path(__file__).resolve().parent
    config: JsonObject = {
        "model": MODEL, "candidate": CANDIDATE, "examples": len(datums), "effort": plan.effort, "rank": RANK,
        "learning_rate": LEARNING_RATE, "batch": X.BATCH, "steps": len(plan.steps), "seed": X.SEED,
        "tokens": {"total": total, "p50": lengths[len(lengths) // 2], "max": lengths[-1]},
        "estimate_usd": round(estimate, 2), "budget_usd": cast(float, args.budget),
        "pass_lines_sha256": PASS_LINES_SHA256, "teacher": plan.teacher,
        "code_sha256": {name: sha256_file(here / name) for name in UNPINNED},
        "packages": {name: importlib.metadata.version(name) for name in PACKAGES}}
    (out / "config.json").write_text(json.dumps(config, indent=1) + "\n", encoding="utf-8")
    print("CONFIG", json.dumps(config), flush=True)
    if args.dry_run or estimate > cast(float, args.budget):
        return 0 if args.dry_run else 2

    trainer = tinker.ServiceClient().create_lora_training_client(base_model=MODEL, rank=RANK, seed=X.SEED).result()
    adam = tinker.AdamParams(learning_rate=LEARNING_RATE, beta1=0.9, beta2=0.95, eps=1e-8)
    spent = 0.0
    with (out / "steps.jsonl").open("w", encoding="utf-8") as fh:
        for number, positions in enumerate(plan.steps):
            batch = [datums[i] for i in positions]
            tokens = sum(d.model_input.length for d in batch)
            t0 = time.monotonic()
            fwd = trainer.forward_backward(batch, loss_fn="cross_entropy")
            opt = trainer.optim_step(adam_params=adam)
            result = fwd.result()
            opt.result()
            nll = compute_mean_nll([o["logprobs"] for o in result.loss_fn_outputs],
                                   [d.loss_fn_inputs["weights"] for d in batch])
            spent += tokens * TRAIN_PRICE / 1e6
            step = {"step": number, "examples": len(batch), "tokens": tokens, "train_mean_nll": round(nll, 5),
                    "wall_s": round(time.monotonic() - t0, 2), "spent_usd": round(spent, 4)}
            fh.write(json.dumps(step) + "\n")
            fh.flush()
            print("STEP", json.dumps(step), flush=True)
    saved = trainer.save_weights_for_sampler(name=CHECKPOINT, ttl_seconds=CHECKPOINT_TTL_S).result()
    print("SAVED", saved.path, flush=True)
    summary: JsonObject = {**config, "sampler_path": saved.path, "checkpoint_ttl_s": CHECKPOINT_TTL_S,
                           "spent_usd": round(spent, 4)}
    (out / "summary.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf-8")
    # The summary the verdict reads is on disk before this call, so its failure leaves the run usable.
    state = trainer.save_state(name=f"{CHECKPOINT}-state", ttl_seconds=STATE_TTL_S).result()
    (out / "state.json").write_text(json.dumps({"state_path": state.path, "ttl_s": STATE_TTL_S}, indent=1) + "\n",
                                    encoding="utf-8")
    print("STATE", state.path, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
