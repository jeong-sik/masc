"""Tinker SFT pipeline check for Inkling 2 Small.

Trains a LoRA on a hidden record-encoding rule through the tinker-cookbook
renderer for Inkling 2 (not hand-made templates or byte tokens), saves a
sampler checkpoint, and scores one fixed held-out set through the
OpenAI-compatible endpoint twice: on the base model, then on the trained
`tinker://` checkpoint. Both scorings use the request shape MASC exact lanes
send to this row: the schema instruction as the last user message,
reasoning_effort "low", no temperature and no max_tokens.

The pass lines in PASS are fixed before any paid call. The API key comes from
TINKER_API_KEY and is never written. Output goes only to --out. Every prompt
and answer is synthetic, so rows keep the short answer text.

    python -I sft_pipeline_check.py --out <new dir> --dry-run
    python -I sft_pipeline_check.py --out <new dir> --budget 1.0
"""

import argparse
import json
import os
import random
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

MODEL = "thinkingmachines/Inkling-2-Small"
BASE_URL = "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1"
# OpenAI-compatible docs: "low" -> 0.2. Training uses the value serving will use.
EFFORT_NAME = "low"
EFFORT_VALUE = 0.2
RANK = 8
LEARNING_RATE = 2e-4
BATCH = 32
EPOCHS = 5
SEED = 20261108
CHECKPOINT_TTL_S = 3 * 86400
EVAL_WORKERS = 8
# USD per million tokens, https://tinker-docs.thinkingmachines.ai/tinker/models/models_and_pricing/ (2026-11-08).
PRICE = {"prefill": 0.30, "cached": 0.03, "sample": 1.00, "train": 1.50}
# Estimate ceiling per scored request when nothing has been measured yet.
EST_EVAL_TOKENS = {"prompt": 160, "completion": 1200}
PASS = {"base_accuracy_max": 0.10, "trained_accuracy_min": 0.80, "last_over_first_nll_max": 0.5}

INSTRUCTION = ("Return exactly one JSON value matching this JSON Schema. Do not use Markdown "
               "code fences or include any explanation. JSON Schema: %s")
SCHEMA = {"type": "object", "properties": {"code": {"type": "string"}},
          "required": ["code"], "additionalProperties": False}
TRAIN_NAMES = ("alice", "bruno", "chloe", "daniel", "elena", "felix", "grace", "hiro", "irene", "jonas",
               "karin", "lucas", "mina", "nora", "oscar", "paula", "quinn", "rafael", "sofia", "tomas",
               "ursula", "victor", "wendy", "xavier", "yuna", "zoltan", "amara", "boris", "celia", "dmitri",
               "esther", "farid", "greta", "hector", "ines", "jasper", "kenji", "leila", "marco", "nadia")
UNSEEN_NAMES = ("odette", "pavel", "quentin", "rosalind", "sven", "tamsin", "umberto", "vesna", "wilbur", "ximena")
TRAIN_CITIES = ("seoul", "busan", "tokyo", "osaka", "paris", "lyon", "berlin", "munich", "madrid", "lisbon",
                "dublin", "oslo", "vienna", "prague", "warsaw", "athens", "cairo", "nairobi", "lima", "quito",
                "denver", "boston", "toronto", "sydney")
UNSEEN_CITIES = ("hanoi", "manila", "zagreb", "tbilisi", "accra", "bogota", "perth", "geneva")
N_TRAIN = 160
N_EVAL_SEEN_POOL = 20
N_EVAL_UNSEEN_POOL = 20


def encode(name: str, age: int, city: str) -> str:
    return f"{name.upper()}#{age:03d}#{city[:3].upper()}"


def build_records() -> tuple[list[dict], list[dict]]:
    rng = random.Random(SEED)
    train: dict[tuple, dict] = {}
    while len(train) < N_TRAIN:
        rec = (rng.choice(TRAIN_NAMES), rng.randint(1, 99), rng.choice(TRAIN_CITIES))
        train.setdefault(rec, {"name": rec[0], "age": rec[1], "city": rec[2], "split": "train"})
    evals: dict[tuple, dict] = {}
    while len(evals) < N_EVAL_SEEN_POOL:
        rec = (rng.choice(TRAIN_NAMES), rng.randint(1, 99), rng.choice(TRAIN_CITIES))
        if rec not in train:
            evals.setdefault(rec, {"name": rec[0], "age": rec[1], "city": rec[2], "split": "seen_pool"})
    while len(evals) < N_EVAL_SEEN_POOL + N_EVAL_UNSEEN_POOL:
        rec = (rng.choice(UNSEEN_NAMES), rng.randint(1, 99), rng.choice(UNSEEN_CITIES))
        evals.setdefault(rec, {"name": rec[0], "age": rec[1], "city": rec[2], "split": "unseen_pool"})
    return list(train.values()), list(evals.values())


def prompt_messages(rec: dict) -> list[dict]:
    task = f"Encode this record.\nRecord: {rec['name']} {rec['age']} {rec['city']}"
    schema = json.dumps(SCHEMA, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return [{"role": "user", "content": task}, {"role": "user", "content": INSTRUCTION % schema}]


def target_text(rec: dict) -> str:
    return json.dumps({"code": encode(rec["name"], rec["age"], rec["city"])}, separators=(",", ":"))


def score(rec: dict, content: str) -> dict:
    text = content.strip()
    try:
        value = json.loads(text)
    except ValueError:
        return {"bare": False, "exact": False}
    code = value.get("code") if isinstance(value, dict) else None
    return {"bare": True, "exact": code == encode(rec["name"], rec["age"], rec["city"])}


def eval_cost(usage: dict) -> float:
    prompt, cached = usage.get("prompt_tokens") or 0, usage.get("cached_tokens") or 0
    return ((prompt - cached) * PRICE["prefill"] + cached * PRICE["cached"]
            + (usage.get("completion_tokens") or 0) * PRICE["sample"]) / 1e6


def score_set(client, model: str, records: list[dict], phase: str) -> list[dict]:
    from openai import APIConnectionError, APIStatusError, APITimeoutError

    def one(item):
        index, rec = item
        t0 = time.time()
        miss = {"phase": phase, "index": index, "split": rec["split"], "exact": False, "bare": False, "cost_usd": 0.0}
        try:
            raw = client.chat.completions.with_raw_response.create(
                model=model, messages=prompt_messages(rec), extra_body={"reasoning_effort": EFFORT_NAME})
            data = json.loads(raw.http_response.text)
            status = raw.http_response.status_code
        except APIStatusError as e:
            return {**miss, "status": e.status_code, "error_head": e.response.text[:200],
                    "wall_s": round(time.time() - t0, 2)}
        except (APIConnectionError, APITimeoutError) as e:
            return {**miss, "status": 0, "error_head": type(e).__name__, "wall_s": round(time.time() - t0, 2)}
        except ValueError as e:
            return {**miss, "status": -1, "error_head": f"unreadable body: {e}"[:200],
                    "wall_s": round(time.time() - t0, 2)}
        choice = (data.get("choices") or [{}])[0]
        message = choice.get("message") or {}
        usage = data.get("usage") or {}
        cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens") or 0
        flat = {"prompt_tokens": usage.get("prompt_tokens"), "completion_tokens": usage.get("completion_tokens"),
                "cached_tokens": cached}
        content = message.get("content") or ""
        return {"phase": phase, "index": index, "split": rec["split"], "status": status,
                "finish_reason": choice.get("finish_reason"), **flat,
                "reasoning_chars": len(message.get("reasoning_content") or ""),
                "answer": content[:200], "expected": encode(rec["name"], rec["age"], rec["city"]),
                **score(rec, content), "wall_s": round(time.time() - t0, 2), "cost_usd": round(eval_cost(flat), 6)}
    with ThreadPoolExecutor(max_workers=EVAL_WORKERS) as pool:
        return list(pool.map(one, enumerate(records)))


def accuracy(rows: list[dict], split: str | None = None) -> float:
    sel = [r for r in rows if split is None or r["split"] == split]
    return round(sum(1 for r in sel if r["exact"]) / len(sel), 4) if sel else 0.0


def build_datums(renderer, train: list[dict]):
    from tinker_cookbook import renderers
    from tinker_cookbook.supervised.common import datum_from_model_input_weights
    datums = []
    for rec in train:
        msgs = prompt_messages(rec) + [{"role": "assistant", "content": target_text(rec)}]
        model_input, weights = renderer.build_supervised_example(
            msgs, train_on_what=renderers.TrainOnWhat.ALL_ASSISTANT_MESSAGES, effort=EFFORT_VALUE)
        datums.append(datum_from_model_input_weights(model_input, weights, None, reduction="mean"))
    return datums


def estimate(datums, n_eval: int) -> dict:
    per_epoch = sum(d.model_input.length for d in datums)
    train_usd = per_epoch * EPOCHS * PRICE["train"] / 1e6
    eval_usd = 2 * n_eval * (EST_EVAL_TOKENS["prompt"] * PRICE["prefill"]
                             + EST_EVAL_TOKENS["completion"] * PRICE["sample"]) / 1e6
    return {"train_tokens_per_epoch": per_epoch, "train_tokens_total": per_epoch * EPOCHS,
            "train_usd": round(train_usd, 4), "eval_usd_ceiling": round(eval_usd, 4),
            "total_usd_estimate": round(train_usd + eval_usd, 4)}


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--budget", type=float, default=1.0)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=False)

    from tinker_cookbook import model_info, renderers
    from tinker_cookbook.tokenizer_utils import get_tokenizer
    tokenizer = get_tokenizer(MODEL)
    renderer = renderers.get_renderer(model_info.get_recommended_renderer_name(MODEL), tokenizer)
    train, evals = build_records()
    datums = build_datums(renderer, train)
    est = estimate(datums, len(evals))
    lengths = sorted(d.model_input.length for d in datums)
    config = {"model": MODEL, "effort": [EFFORT_NAME, EFFORT_VALUE], "rank": RANK, "learning_rate": LEARNING_RATE,
              "batch": BATCH, "epochs": EPOCHS, "seed": SEED, "n_train": len(train),
              "n_eval": {"seen_pool": N_EVAL_SEEN_POOL, "unseen_pool": N_EVAL_UNSEEN_POOL},
              "datum_tokens": {"min": lengths[0], "p50": lengths[len(lengths) // 2], "max": lengths[-1]},
              "pass": PASS, "estimate": est, "budget_usd": args.budget}
    write_json(out / "config.json", config)
    print("CONFIG", json.dumps(config))
    sample = prompt_messages(train[0]) + [{"role": "assistant", "content": target_text(train[0])}]
    model_input, _ = renderer.build_supervised_example(sample, effort=EFFORT_VALUE)
    print("RENDERED", repr(tokenizer.decode(model_input.to_ints()))[:900])
    if args.dry_run:
        return 0
    if est["total_usd_estimate"] > args.budget:
        print("estimate exceeds budget; not starting", file=sys.stderr)
        return 2

    import tinker
    from openai import OpenAI
    from tinker_cookbook.supervised.common import compute_mean_nll
    client = OpenAI(base_url=BASE_URL, api_key=os.environ["TINKER_API_KEY"])
    spent = 0.0
    rows: list[dict] = []

    before = score_set(client, MODEL, evals, "base")
    rows += before
    spent += sum(r["cost_usd"] for r in before)
    print("BASE", accuracy(before), "spent", round(spent, 4), flush=True)

    # Keep enough budget to score the trained checkpoint once.
    after_reserve = len(evals) * (EST_EVAL_TOKENS["prompt"] * PRICE["prefill"]
                                  + EST_EVAL_TOKENS["completion"] * PRICE["sample"]) / 1e6
    service = tinker.ServiceClient()
    trainer = service.create_lora_training_client(base_model=MODEL, rank=RANK, seed=SEED).result()
    rng = random.Random(SEED + 1)
    steps: list[dict] = []
    stopped = None
    for epoch in range(EPOCHS):
        order = list(range(len(datums)))
        rng.shuffle(order)
        for start in range(0, len(order), BATCH):
            batch = [datums[i] for i in order[start:start + BATCH]]
            tokens = sum(d.model_input.length for d in batch)
            step_usd = tokens * PRICE["train"] / 1e6
            if spent + step_usd + after_reserve > args.budget:
                stopped = f"budget before epoch {epoch} batch {start // BATCH}"
                break
            t0 = time.time()
            fwd = trainer.forward_backward(batch, loss_fn="cross_entropy")
            opt = trainer.optim_step(tinker.AdamParams(learning_rate=LEARNING_RATE, beta1=0.9, beta2=0.95, eps=1e-8))
            result = fwd.result()
            opt.result()
            nll = compute_mean_nll([o["logprobs"] for o in result.loss_fn_outputs],
                                   [d.loss_fn_inputs["weights"] for d in batch])
            spent += step_usd
            steps.append({"step": len(steps), "epoch": epoch, "tokens": tokens, "train_mean_nll": round(nll, 5),
                          "wall_s": round(time.time() - t0, 2), "cost_usd": round(step_usd, 6)})
            print("STEP", json.dumps(steps[-1]), flush=True)
        if stopped:
            break
    saved = trainer.save_weights_for_sampler(name="masc-sft-pipeline-check", ttl_seconds=CHECKPOINT_TTL_S).result()
    sampler_path = saved.path
    print("SAVED", sampler_path, flush=True)

    after: list[dict] = []
    if not stopped:
        after = score_set(client, sampler_path, evals, "trained")
        rows += after
        spent += sum(r["cost_usd"] for r in after)

    first, last = (steps[0]["train_mean_nll"], steps[-1]["train_mean_nll"]) if steps else (None, None)
    nll_ratio = round(last / first, 4) if first else None
    summary = {
        "sampler_path": sampler_path, "checkpoint_ttl_s": CHECKPOINT_TTL_S, "stopped": stopped,
        "steps": len(steps), "first_nll": first, "last_nll": last, "last_over_first_nll": nll_ratio,
        "base": {"accuracy": accuracy(before), "seen_pool": accuracy(before, "seen_pool"),
                 "unseen_pool": accuracy(before, "unseen_pool"), "bare": sum(r["bare"] for r in before)},
        "trained": {"accuracy": accuracy(after), "seen_pool": accuracy(after, "seen_pool"),
                    "unseen_pool": accuracy(after, "unseen_pool"), "bare": sum(r["bare"] for r in after)},
        "spent_usd": round(spent, 4), "pass_lines": PASS,
        "pass": {"base_accuracy_max": accuracy(before) <= PASS["base_accuracy_max"],
                 "trained_accuracy_min": bool(after) and accuracy(after) >= PASS["trained_accuracy_min"],
                 "last_over_first_nll_max": nll_ratio is not None
                 and nll_ratio <= PASS["last_over_first_nll_max"]},
    }
    with (out / "rows.jsonl").open("w") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    with (out / "steps.jsonl").open("w") as f:
        for step in steps:
            f.write(json.dumps(step) + "\n")
    write_json(out / "summary.json", summary)
    print("SUMMARY", json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
