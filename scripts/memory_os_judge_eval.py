#!/usr/bin/env python3
"""memory_os_judge_eval.py — RFC-0247 §-1 P-1 step 0b: LLM-as-judge value eval.

Auto-labels memory-os facts durable | ephemeral | uncertain and reports the
noise_rate that the OCaml harness (test/eval_memory_os_value.ml) defines:

    noise_rate = ephemeral / (ephemeral + durable)   # uncertain excluded

ANTI-RIG (mirrors judge_accuracy in the OCaml harness; user directive 2026-06-16
"가짜 성공 테스트 금지"): the judge is validated against the hand-labelled GOLD set
FIRST. If it cannot reproduce the gold (accuracy < --min-accuracy), the run ABORTS
— a judge that can't distinguish the known cases must not be trusted on live data,
so it cannot silently flatter the score.

Modes:
  calibrate  — only run the gold check (cheap; proves the judge before any spend)
  measure    — sample N facts from the store, report noise_rate (+ the _shared tier)
  relabel    — judge ALL facts, write relabelled JSONL (retroactive cleanup of the
               pre-#21257 legacy backlog the producer can no longer fix)

The judge model is chosen by the masc runtime config (NOT hardcoded): [memory_os]
judge = "provider.model" if set, else the [runtime] default. The resolved provider's
config (endpoint / credentials / model) is read from runtime.toml and called over
openai-compatible HTTP. No external CLI fork — masc depends on its own runtime config,
not on a Second Brain shell tool (`sb glm-text`). store dir is --store-dir. Makes live
LLM calls — run on demand. Deterministic given fixed model output (temperature 0),
reproducible via the recorded label output.

This "judge" is the memory-os VALUE-EVAL judge (labels a fact durable/ephemeral). It
is NOT the keeper `verifier` persona (a keeper that approves tasks), and NOT the
[fusion] judge (RFC-0252, synthesizes a panel of model answers). Three distinct roles,
three distinct config keys: [runtime.assignments] verifier / [fusion] judge /
[memory_os] judge.

NOTE (boundary): the ideal home for the live judge is the OCaml harness
(test/eval_memory_os_value.ml) calling the OAS provider abstraction directly. This
Python path resolves the provider from runtime.toml and speaks raw HTTP instead, so
it does NOT inherit OAS transport (retry / stream). Acceptable for a 1-shot
off-server batch eval; revisit if the judge ever moves onto a hot path.
"""

from __future__ import annotations
import argparse
import glob
import json
import os
import sys
import tomllib
import urllib.error
import urllib.request
from dataclasses import dataclass

# GOLD: the single irreducible HUMAN-anchored calibration set — the one manual
# artifact left after moving all measurement to the LLM judge. It exists to keep the
# judge honest (anti-rig): a judge that cannot reproduce these labels is not trusted.
# Replacing it with LLM labels too would make the judge validate itself (circular);
# the only non-manual alternative is a SEPARATE stronger reference model labelling it
# (cross-model), which is a deliberate future option, not the default.
GOLD: list[tuple[str, str]] = [
    ("The rondo sandbox blocks Write/Read tools on the masc repo", "durable"),
    ("The Write tool has a destructive guard that blocks ${} expansion", "durable"),
    ("sed -i does not persist across Docker turn containers", "durable"),
    (
        "DUNE_CACHE=disabled is required to rebuild after cross-lib .mli changes",
        "durable",
    ),
    (
        "A continuation checkpoint was saved and the keeper remains scheduled",
        "ephemeral",
    ),
    ("No claimable or unclaimed tasks remain", "ephemeral"),
    ("Board curation was submitted", "ephemeral"),
    ("desire, intention, blocker, and need are all none", "ephemeral"),
    ("A continuation checkpoint was saved at turn 22", "ephemeral"),
]

JUDGE_SYSTEM = (
    "You classify each memory claim written by an autonomous agent as exactly one of:\n"
    "- durable: knowledge that would still be TRUE and USEFUL to a DIFFERENT agent on a "
    "later day, independent of the run that wrote it (a constraint, invariant, "
    "externally-verifiable fact, decision-with-rationale, or concrete code/config change).\n"
    "- ephemeral: lifecycle/coordination boilerplate that is true only right now (a "
    "checkpoint was saved, the keeper is scheduled/woken, the current task-queue/backlog "
    "state whether full or empty, a curation was submitted, heartbeat/status ticks, the "
    "agent's present desire/intention/blocker/need).\n"
    "- uncertain: genuinely cannot tell.\n"
    "Judge the claim's content, not its phrasing. Reply with ONLY a JSON array, one object "
    'per input line, in order: [{"i":1,"label":"durable"}, ...]. No prose, no markdown.'
)

VALID = {"durable", "ephemeral", "uncertain"}

# One-shot judge call; generous because the store can return a large batch.
JUDGE_TIMEOUT_SEC = 180


def _looks_like_answer_array(parsed: object) -> bool:
    return isinstance(parsed, list) and any(
        isinstance(obj, dict) and "i" in obj for obj in parsed
    )


@dataclass(frozen=True, slots=True)
class JudgeBackend:
    """Resolved openai-compatible endpoint for the judge model.

    Built from a runtime.toml [providers.<name>] block — the same config the masc
    runtime reads — so the judge cannot drift from the runtime's provider truth.
    """

    chat_url: str
    api_key: str
    model: str


def load_runtime_cfg(runtime_config: str) -> dict:
    try:
        with open(runtime_config, "rb") as f:
            return tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        sys.exit(f"cannot read runtime config {runtime_config!r}: {e}")


def _split_runtime_id(runtime_id: str) -> tuple[str, str]:
    """ "provider.model" -> (provider, model). Provider names contain no dot, so the
    FIRST dot splits; the model keeps its own dashes/dots."""
    if "." not in runtime_id:
        sys.exit(f"runtime id {runtime_id!r} is not in 'provider.model' form")
    provider, model = runtime_id.split(".", 1)
    return provider, model


def resolve_judge_target(cfg: dict) -> tuple[str, str, str]:
    """Decide which (provider, model) judges, returning (provider, model, source).

    Precedence (CLI override is applied by the caller, above this):
      1. [memory_os] judge = "provider.model"  — the memory-os value-eval judge,
         distinct from the keeper `verifier` persona and the [fusion] judge.
      2. [runtime] default = "provider.model"  — fallback to the runtime's default.
    Aborts if neither is set (no permissive guess about which model to trust)."""
    mo = cfg.get("memory_os")
    judge_id = mo.get("judge") if isinstance(mo, dict) else None
    if isinstance(judge_id, str) and judge_id:
        provider, model = _split_runtime_id(judge_id)
        return provider, model, "memory_os.judge"

    default_id = cfg.get("runtime", {}).get("default")
    if isinstance(default_id, str) and default_id:
        provider, model = _split_runtime_id(default_id)
        return provider, model, "runtime.default (fallback)"

    sys.exit(
        "no judge target: set [memory_os] judge or [runtime] default in the runtime "
        "config, or pass --judge-provider with --judge-model"
    )


def resolve_api_model_name(cfg: dict, model: str) -> str:
    models = cfg.get("models", {})
    model_cfg = models.get(model) if isinstance(models, dict) else None
    if isinstance(model_cfg, dict):
        api_name = model_cfg.get("api-name")
        if isinstance(api_name, str) and api_name.strip():
            return api_name.strip()
    return model


def resolve_backend(cfg: dict, provider_name: str, model: str) -> JudgeBackend:
    """Build a JudgeBackend from [providers.<provider_name>] in an already-loaded cfg.

    Aborts (sys.exit) on any missing/incompatible config rather than falling back to
    a permissive default — an unknown provider or empty credential must fail loudly,
    not silently route somewhere unintended.
    """
    provider = cfg.get("providers", {}).get(provider_name)
    if not isinstance(provider, dict):
        sys.exit(f"runtime config has no [providers.{provider_name}]")

    protocol = provider.get("protocol")
    if protocol != "openai-compatible-http":
        sys.exit(
            f"provider {provider_name!r} protocol={protocol!r}; "
            "judge needs an openai-compatible-http provider"
        )

    endpoint = str(provider.get("endpoint", "")).rstrip("/")
    if not endpoint:
        sys.exit(f"provider {provider_name!r} has no endpoint")

    creds = provider.get("credentials", {})
    if not isinstance(creds, dict) or creds.get("type") != "env":
        sys.exit(f"provider {provider_name!r} credentials must be type=env")
    key_env = creds.get("key", "")
    api_key = os.environ.get(key_env, "")
    if not api_key:
        sys.exit(f"credential env {key_env!r} for provider {provider_name!r} is empty")

    return JudgeBackend(
        chat_url=f"{endpoint}/chat/completions",
        api_key=api_key,
        model=resolve_api_model_name(cfg, model),
    )


def _chat(backend: JudgeBackend, system: str, user: str) -> str:
    """Single openai-compatible chat completion; returns the message content text."""
    body = json.dumps(
        {
            "model": backend.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": 0,
            "stream": False,
        }
    ).encode()
    req = urllib.request.Request(
        backend.chat_url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {backend.api_key}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=JUDGE_TIMEOUT_SEC) as resp:
        payload = json.loads(resp.read().decode())
    # Parse the response shape explicitly instead of chained index access. A
    # well-formed openai-compatible envelope can still carry choices=[] (no
    # completion produced); `["choices"][0]` would then raise IndexError, which
    # is not in run_judge's degrade tuple and would crash the always-on
    # calibrate gate. Map every malformed shape to one typed ValueError so the
    # caller can honor its "unparseable -> uncertain" contract.
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise ValueError("chat response carried no choices")
    first = choices[0]
    message = first.get("message") if isinstance(first, dict) else None
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, str):
        raise ValueError("chat response missing message.content text")
    return content


def _extract_json_array(text: str) -> str | None:
    """Return the first well-balanced top-level JSON array in [text].

    Mirrors a strict parser enough to avoid the greedy-regex trap that would
    match from an opening '[' all the way to the last ']' in the response. The
    model can also prefix prose like "[analysis]" before the real answer, so
    keep scanning until a balanced candidate parses as JSON array.
    """
    start = -1
    while True:
        start = text.find("[", start + 1)
        if start == -1:
            return None
        depth = 0
        in_str = False
        escape = False
        for i, ch in enumerate(text[start:], start):
            if escape:
                escape = False
                continue
            if ch == "\\":
                escape = True
                continue
            if ch == '"':
                in_str = not in_str
                continue
            if in_str:
                continue
            if ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
                if depth == 0:
                    candidate = text[start : i + 1]
                    try:
                        parsed = json.loads(candidate)
                    except Exception:
                        break
                    if _looks_like_answer_array(parsed):
                        return candidate
                    break
    return None


def _parse_index(raw_i, n: int) -> int | None:
    """Convert a judge index to a 0-based int position, or None if unusable.

    Accepts integers and whole-number floats (e.g. 1.0). Rejects booleans,
    non-numeric strings, and fractional floats so a malformed index never
    crashes the run.
    """
    if isinstance(raw_i, bool):
        return None
    if isinstance(raw_i, float):
        if not raw_i.is_integer():
            return None
        idx = int(raw_i) - 1
    elif isinstance(raw_i, int):
        idx = raw_i - 1
    else:
        try:
            idx = int(raw_i) - 1
        except Exception:
            return None
    if 0 <= idx < n:
        return idx
    return None


def run_judge(claims: list[str], backend: JudgeBackend) -> list[str]:
    """Label a batch of claims. Unparseable items default to 'uncertain' (never a
    silent durable/ephemeral guess)."""
    numbered = "\n".join(f"{i + 1}. {c}" for i, c in enumerate(claims))
    prompt = f"Classify these {len(claims)} claims:\n{numbered}"
    try:
        out = _chat(backend, JUDGE_SYSTEM, prompt)
    except (
        urllib.error.URLError,
        OSError,
        json.JSONDecodeError,
        KeyError,
        ValueError,
    ) as e:
        # ValueError covers both json.JSONDecodeError (subclass) and the typed
        # malformed-shape errors raised by _chat (empty choices, missing
        # content), so an empty-but-well-formed provider reply degrades to
        # 'uncertain' rather than crashing the calibrate gate.
        print(f"  judge call failed: {e}", file=sys.stderr)
        return ["uncertain"] * len(claims)
    labels = ["uncertain"] * len(claims)
    arr_text = _extract_json_array(out)
    if arr_text is None:
        return labels
    try:
        arr = json.loads(arr_text)
    except Exception:
        return labels
    if not isinstance(arr, list):
        return labels
    for obj in arr:
        if isinstance(obj, dict) and "i" in obj:
            idx = _parse_index(obj["i"], len(labels))
            lab = str(obj.get("label", "")).strip().lower()
            if idx is not None and lab in VALID:
                labels[idx] = lab
    return labels


def judge_all(claims: list[str], backend: JudgeBackend, batch: int) -> list[str]:
    out: list[str] = []
    for i in range(0, len(claims), batch):
        chunk = claims[i : i + batch]
        out.extend(run_judge(chunk, backend))
        print(f"  judged {min(i + batch, len(claims))}/{len(claims)}", file=sys.stderr)
    return out


def noise_rate(labels: list[str]) -> float:
    eph = labels.count("ephemeral")
    dur = labels.count("durable")
    return eph / (eph + dur) if (eph + dur) else 0.0


def calibrate(backend: JudgeBackend, min_acc: float) -> float:
    claims = [c for c, _ in GOLD]
    got = run_judge(claims, backend)
    correct = sum(1 for (got_l, (_, exp)) in zip(got, GOLD) if got_l == exp)
    acc = correct / len(GOLD)
    print(
        f"calibration: judge agreed with {correct}/{len(GOLD)} gold labels = {acc:.0%}"
    )
    for (claim, exp), g in zip(GOLD, got):
        flag = "ok" if g == exp else "MISS"
        print(f"  [{flag}] gold={exp:9} judge={g:9} | {claim[:70]}")
    if acc < min_acc:
        print(
            f"\nABORT: judge accuracy {acc:.0%} < --min-accuracy {min_acc:.0%}. "
            "Its live numbers are NOT trusted (anti-rig gate).",
            file=sys.stderr,
        )
    return acc


def load_facts(
    store_dir: str, *, include_shared: bool = True, only_shared: bool = False
) -> list[tuple[str, str]]:
    """Returns [(claim, producer_category)]."""
    facts = []
    for path in sorted(glob.glob(os.path.join(store_dir, "*.facts.jsonl"))):
        is_shared = os.path.basename(path).startswith("_shared")
        if only_shared and not is_shared:
            continue
        if not include_shared and is_shared:
            continue
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                claim = o.get("claim", "")
                cat = o.get("category")
                cat = cat if isinstance(cat, str) else (cat or {}).get("kind", "?")
                if claim:
                    facts.append((claim, cat))
    return facts


def deterministic_sample(items: list, n: int) -> list:
    """Stable stride sample — reproducible, no RNG."""
    if n <= 0 or n >= len(items):
        return items
    stride = len(items) / n
    return [items[int(i * stride)] for i in range(n)]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--mode", choices=["calibrate", "measure", "relabel"], default="calibrate"
    )
    ap.add_argument(
        "--store-dir",
        default=os.path.join(
            os.environ.get("MASC_BASE_PATH") or os.path.expanduser("~/me"),
            ".masc",
            "config",
            "keepers",
        ),
    )
    ap.add_argument(
        "--runtime-config",
        default=os.path.join(
            os.environ.get("MASC_BASE_PATH") or os.path.expanduser("~/me"),
            ".masc",
            "config",
            "runtime.toml",
        ),
        help="masc runtime.toml that defines the judge provider",
    )
    ap.add_argument(
        "--judge-provider",
        default=None,
        help="override the runtime.toml [providers.<name>] used as judge "
        "(default: [memory_os] judge, else [runtime] default). Requires --judge-model.",
    )
    ap.add_argument(
        "--judge-model",
        default=None,
        help="override the judge model (use with --judge-provider)",
    )
    ap.add_argument(
        "--sample", type=int, default=100, help="facts to judge in measure mode"
    )
    ap.add_argument("--batch", type=int, default=20)
    ap.add_argument("--min-accuracy", type=float, default=0.78)
    ap.add_argument("--out", default="", help="relabel mode: output JSONL path")
    args = ap.parse_args()

    cfg = load_runtime_cfg(args.runtime_config)
    if args.judge_provider or args.judge_model:
        if not (args.judge_provider and args.judge_model):
            sys.exit("--judge-provider and --judge-model must be given together")
        provider, model, source = args.judge_provider, args.judge_model, "cli"
    else:
        provider, model, source = resolve_judge_target(cfg)
    backend = resolve_backend(cfg, provider, model)
    print(
        f"judge: provider={provider} model={model} (source={source}) "
        f"via {backend.chat_url}",
        file=sys.stderr,
    )

    acc = calibrate(backend, args.min_accuracy)
    if acc < args.min_accuracy:
        return 2  # anti-rig: refuse to report live numbers with an untrustworthy judge
    if args.mode == "calibrate":
        return 0

    shared_facts = load_facts(args.store_dir, only_shared=True)
    keeper_facts = load_facts(args.store_dir, include_shared=False)

    if args.mode == "measure":
        if shared_facts:
            sl = judge_all([c for c, _ in shared_facts], backend, args.batch)
            print(
                f"\n_shared tier ({len(shared_facts)} facts): noise_rate = {noise_rate(sl):.0%} "
                f"(eph {sl.count('ephemeral')} / dur {sl.count('durable')} / unc {sl.count('uncertain')})"
            )
        sample = deterministic_sample(keeper_facts, args.sample)
        sl = judge_all([c for c, _ in sample], backend, args.batch)
        print(
            f"\nkeeper store sample ({len(sample)} of {len(keeper_facts)}): "
            f"noise_rate = {noise_rate(sl):.0%} "
            f"(eph {sl.count('ephemeral')} / dur {sl.count('durable')} / unc {sl.count('uncertain')})"
        )
        # producer-disagreement: how often the producer's category=fact is judged ephemeral
        mis = sum(
            1 for (_, cat), j in zip(sample, sl) if cat == "fact" and j == "ephemeral"
        )
        nfact = sum(1 for _, cat in sample if cat == "fact")
        if nfact:
            print(
                f"producer mislabel: {mis}/{nfact} of category=fact are judged ephemeral "
                f"= {mis / nfact:.0%}"
            )
        return 0

    if args.mode == "relabel":
        labels = judge_all([c for c, _ in keeper_facts], backend, args.batch)
        out_path = args.out or "memory_os_relabel.jsonl"
        with open(out_path, "w") as f:
            for (claim, cat), lab in zip(keeper_facts, labels):
                f.write(
                    json.dumps(
                        {"claim": claim, "producer_category": cat, "judge_label": lab}
                    )
                    + "\n"
                )
        print(
            f"\nwrote {len(labels)} relabelled rows -> {out_path}; "
            f"store noise_rate = {noise_rate(labels):.0%}"
        )
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
