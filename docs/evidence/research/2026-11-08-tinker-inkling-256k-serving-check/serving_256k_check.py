"""Does a LoRA trained on the 256K Inkling 2 Small ID serve with a 256K window?

The Tinker docs list `thinkingmachines/Inkling-2-Small:peft:262144` as a
trainable 262,144-token model, but do not say what window the OpenAI-compatible
endpoint gives a sampler checkpoint saved from it. MASC calls a checkpoint only
through that endpoint, so this script asks the endpoint directly.

Steps (one run, fixed before any paid call):
1. Create a rank-8 LoRA on the 256K ID. Save it for sampling before any step
   ("zero") and after one tiny step ("one").
2. Build two prompts with the Inkling tokenizer: about 100K and 230K tokens.
   A passphrase sits at the very start and another in the middle; the question
   is at the end. Left truncation loses the first passphrase.
3. Send each prompt through the OpenAI-compatible endpoint to: the "one"
   checkpoint, the "zero" checkpoint, and the 256K base ID by name. Send the
   100K prompt once to the 64K base ID as a control that must fail.
4. Compare the SDK logprobs of a fixed text under the zero checkpoint and the
   256K base, to see whether an untrained save equals the base model.

PASS: the "one" checkpoint answers both long prompts with HTTP 200, reports
prompt_tokens above 65,536 and within 1% of the local count, and names both
passphrases. The control is recorded, not judged.
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

MODEL_64K = "thinkingmachines/Inkling-2-Small"
MODEL_256K = "thinkingmachines/Inkling-2-Small:peft:262144"
BASE_URL = "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1"
EFFORT_NAME = "low"
EFFORT_VALUE = 0.2
RANK = 8
SEED = 20261108
CHECKPOINT_TTL_S = 3 * 86400
MAX_TOKENS = 2048
TARGETS = {"long_100k": 100_000, "long_230k": 230_000}
WINDOW_64K = 65_536
COUNT_TOLERANCE = 0.01
FIRST, SECOND = "TANGERINE-4417", "OBSIDIAN-2093"
# USD per million tokens, https://tinker-docs.thinkingmachines.ai/tinker/models/models_and_pricing/ (2026-11-08).
PRICE = {"prefill": 0.30, "sample": 1.00, "train_256k": 3.00}
BUDGET_USD = 2.0
QUESTION = ('What are the first and second passphrases in this document? Return exactly one JSON object '
            '{"first": string, "second": string} and nothing else.')


def filler_line(i: int) -> str:
    return (f"Record {i:06d}: inventory batch {i * 7919 % 100003} moved from shelf {i % 97} "
            f"to shelf {(i * 31) % 89} after count {(i * 13) % 1000}.")


def build_prompt(tokenizer, target: int) -> tuple[str, int]:
    def text_for(n_lines: int) -> str:
        half = n_lines // 2
        body = [filler_line(i) for i in range(n_lines)]
        body.insert(half, f"The second passphrase is {SECOND}.")
        return "\n".join([f"The first passphrase is {FIRST}."] + body + [QUESTION])

    lo, hi = 1, target  # a line is far more than one token
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if len(tokenizer.encode(text_for(mid))) <= target:
            lo = mid
        else:
            hi = mid - 1
    text = text_for(lo)
    return text, len(tokenizer.encode(text))


def needles(content: str) -> dict:
    try:
        value = json.loads(content.strip())
    except ValueError:
        return {"json": False, "first": FIRST in content, "second": SECOND in content}
    if not isinstance(value, dict):
        return {"json": False, "first": FIRST in content, "second": SECOND in content}
    return {"json": True, "first": value.get("first") == FIRST, "second": value.get("second") == SECOND}


def call(client, model: str, label: str, prompt_name: str, text: str, local_tokens: int) -> dict:
    from openai import APIConnectionError, APIStatusError, APITimeoutError
    t0 = time.time()
    base = {"target": label, "prompt": prompt_name, "local_tokens": local_tokens}
    try:
        raw = client.chat.completions.with_raw_response.create(
            model=model, messages=[{"role": "user", "content": text}], max_tokens=MAX_TOKENS,
            extra_body={"reasoning_effort": EFFORT_NAME})
        data = json.loads(raw.http_response.text)
        status = raw.http_response.status_code
    except APIStatusError as e:
        return {**base, "status": e.status_code, "error_head": e.response.text[:300], "wall_s": round(time.time() - t0, 2)}
    except (APIConnectionError, APITimeoutError) as e:
        return {**base, "status": 0, "error_head": type(e).__name__, "wall_s": round(time.time() - t0, 2)}
    choice = (data.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    usage = data.get("usage") or {}
    content = message.get("content") or ""
    return {**base, "status": status, "finish_reason": choice.get("finish_reason"),
            "prompt_tokens": usage.get("prompt_tokens"), "completion_tokens": usage.get("completion_tokens"),
            "cached_tokens": (usage.get("prompt_tokens_details") or {}).get("cached_tokens"),
            "reasoning_chars": len(message.get("reasoning_content") or ""), "answer_head": content[:200],
            **needles(content), "wall_s": round(time.time() - t0, 2)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=False)

    from tinker_cookbook import model_info, renderers
    from tinker_cookbook.supervised.common import datum_from_model_input_weights
    from tinker_cookbook.tokenizer_utils import get_tokenizer
    tokenizer = get_tokenizer(MODEL_64K)
    prompts = {name: build_prompt(tokenizer, target) for name, target in TARGETS.items()}
    plan = [("one", "long_100k"), ("one", "long_230k"), ("zero", "long_100k"), ("zero", "long_230k"),
            ("base_256k", "long_100k"), ("base_256k", "long_230k"), ("base_64k_control", "long_100k")]
    prefill = sum(prompts[p][1] for _, p in plan)
    estimate = round(prefill * PRICE["prefill"] / 1e6 + len(plan) * MAX_TOKENS * PRICE["sample"] / 1e6
                     + 4 * 64 * PRICE["train_256k"] / 1e6, 4)
    config = {"model_256k": MODEL_256K, "model_64k": MODEL_64K, "rank": RANK, "seed": SEED,
              "effort": [EFFORT_NAME, EFFORT_VALUE], "max_tokens": MAX_TOKENS,
              "prompt_tokens_local": {k: v[1] for k, v in prompts.items()}, "plan": plan,
              "estimate_usd": estimate, "budget_usd": BUDGET_USD}
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")
    print("CONFIG", json.dumps(config), flush=True)
    if args.dry_run:
        return 0
    if estimate > BUDGET_USD:
        print("estimate exceeds budget; not starting", file=sys.stderr)
        return 2

    import tinker
    from openai import OpenAI
    renderer = renderers.get_renderer(model_info.get_recommended_renderer_name(MODEL_64K), tokenizer)
    service = tinker.ServiceClient()
    trainer = service.create_lora_training_client(base_model=MODEL_256K, rank=RANK, seed=SEED).result()
    zero = trainer.save_weights_for_sampler(name="masc-256k-zero", ttl_seconds=CHECKPOINT_TTL_S).result().path
    print("SAVED zero", flush=True)
    examples = [[{"role": "user", "content": f"Say the word {w}."}, {"role": "assistant", "content": w}]
                for w in ("alpha", "bravo", "charlie", "delta")]
    datums = []
    for msgs in examples:
        model_input, weights = renderer.build_supervised_example(
            msgs, train_on_what=renderers.TrainOnWhat.ALL_ASSISTANT_MESSAGES, effort=EFFORT_VALUE)
        datums.append(datum_from_model_input_weights(model_input, weights, None, reduction="mean"))
    train_tokens = sum(d.model_input.length for d in datums)
    fwd = trainer.forward_backward(datums, loss_fn="cross_entropy")
    opt = trainer.optim_step(tinker.AdamParams(learning_rate=2e-4, beta1=0.9, beta2=0.95, eps=1e-8))
    fwd.result()
    opt.result()
    one = trainer.save_weights_for_sampler(name="masc-256k-one-step", ttl_seconds=CHECKPOINT_TTL_S).result().path
    print("SAVED one", flush=True)

    # 4. untrained save vs. 256K base, same text, SDK logprobs.
    probe = tinker.ModelInput.from_ints(tokenizer.encode("\n".join(filler_line(i) for i in range(12))))
    lp_zero = service.create_sampling_client(model_path=zero).result().compute_logprobs(probe).result()
    lp_base = service.create_sampling_client(base_model=MODEL_256K).result().compute_logprobs(probe).result()
    pairs = [(a, b) for a, b in zip(lp_zero, lp_base) if a is not None and b is not None]
    equivalence = {"tokens": len(pairs), "max_abs_diff": max((abs(a - b) for a, b in pairs), default=None)}
    print("EQUIVALENCE", json.dumps(equivalence), flush=True)

    client = OpenAI(base_url=BASE_URL, api_key=os.environ["TINKER_API_KEY"], timeout=900, max_retries=0)
    models = {"one": one, "zero": zero, "base_256k": MODEL_256K, "base_64k_control": MODEL_64K}
    rows = []
    for label, prompt_name in plan:
        text, local_tokens = prompts[prompt_name]
        row = call(client, models[label], label, prompt_name, text, local_tokens)
        rows.append(row)
        print("ROW", json.dumps(row), flush=True)
    with (out / "rows.jsonl").open("w") as fh:
        for row in rows:
            fh.write(json.dumps(row) + "\n")

    def served(row: dict) -> bool:
        pt = row.get("prompt_tokens") or 0
        return (row["status"] == 200 and pt > WINDOW_64K
                and abs(pt - row["local_tokens"]) <= COUNT_TOLERANCE * row["local_tokens"]
                and bool(row.get("first")) and bool(row.get("second")))

    verdict = {label: all(served(r) for r in rows if r["target"] == label) for label in ("one", "zero", "base_256k")}
    summary = {"pass": verdict["one"], "served_256k": verdict, "train_tokens": train_tokens,
               "equivalence": equivalence, "sampler_paths": {"zero": zero, "one": one}, "config": config}
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("SUMMARY", json.dumps({k: v for k, v in summary.items() if k != "sampler_paths"}), flush=True)
    return 0 if verdict["one"] else 1


if __name__ == "__main__":
    sys.exit(main())
