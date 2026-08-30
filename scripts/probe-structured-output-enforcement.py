#!/usr/bin/env python3
"""Measure whether a target enforces a JSON schema, and compare with what it declares.

A target that ACCEPTS `response_format: json_schema` and one that ENFORCES it
look identical under the usual probe, because the prompt already asks for the
right shape. #31808 recorded that trap for ollama.com: it "accepts a json_schema
and ignores it". Nothing measured it, so `supports-structured-output` was written
by hand and could drift from the wire without anything noticing.

This probe separates the two by making the prompt and the schema disagree. The
prompt asks for an extra key; the schema forbids it with
`additionalProperties: false` and `strict: true`. Whoever wins names the tier:

    extra key present  ->  the prompt won   ->  json_object_only
    extra key absent   ->  the schema won   ->  native_json_schema

Measured 2026-08-30, n=5 (n=3 local): glm-coding glm-5.3 and glm-5.3-flash and
ollama_cloud minimax-m3 all let the prompt win on every run; local Ollama with a
schema in `format` suppressed the extra key on every run.

Usage:
    python3 scripts/probe-structured-output-enforcement.py [--config PATH] [-n N]
                                                           [--target ID]...
                                                           [--include-undeclared]

Exit status is 1 when a declaration disagrees with the measurement, so this can
gate a capability edit. Targets whose credential env var is unset are skipped and
reported as such -- a missing key is not a drift.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tomllib
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

DEFAULT_BASE = os.environ.get("MASC_BASE_PATH", os.path.expanduser("~/me"))
DEFAULT_CONFIG = os.path.join(DEFAULT_BASE, ".masc", "config", "runtime.toml")

# The prompt asks for a key the schema forbids. Nothing else about the request
# is interesting; a bigger schema measures the same thing more slowly.
CONFLICT_PROMPT = (
    'Return a JSON object with two keys: "ok" set to true, and "note" set to '
    'the string "hello". Include both keys.'
)
CONFLICT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "properties": {"ok": {"type": "boolean"}},
    "required": ["ok"],
}

NATIVE = "native_json_schema"
OBJECT_ONLY = "json_object_only"
NONE = "no_structured_output"


@dataclass(frozen=True)
class Target:
    runtime_id: str
    provider: str
    protocol: str
    endpoint: str
    credential_env: str | None
    api_name: str
    declared: str


def declared_tier(caps: dict[str, Any]) -> str:
    """Mirror of Capabilities.structured_output_support."""
    if caps.get("supports-structured-output"):
        return NATIVE
    if caps.get("supports-response-format-json"):
        return OBJECT_ONLY
    return NONE


def load_targets(config_path: str) -> list[Target]:
    with open(config_path, "rb") as handle:
        config = tomllib.load(handle)

    providers = config.get("providers", {})
    models = config.get("models", {})

    targets: list[Target] = []
    for provider_name, provider in providers.items():
        endpoint = provider.get("endpoint")
        protocol = provider.get("protocol")
        if not endpoint or not protocol:
            continue
        credentials = provider.get("credentials") or {}
        credential_env = credentials.get("key") if credentials.get("type") == "env" else None

        # A binding is [<provider>.<model-key>]; the runtime id is the pair.
        bindings = config.get(provider_name)
        if not isinstance(bindings, dict):
            continue
        for model_key in bindings:
            model = models.get(model_key)
            if not isinstance(model, dict):
                continue
            api_name = model.get("api-name")
            if not api_name:
                continue
            targets.append(
                Target(
                    runtime_id=f"{provider_name}.{model_key}",
                    provider=provider_name,
                    protocol=protocol,
                    endpoint=endpoint,
                    credential_env=credential_env,
                    api_name=api_name,
                    declared=declared_tier(model.get("capabilities") or {}),
                )
            )
    return targets


def post_json(url: str, body: dict[str, Any], headers: dict[str, str], timeout: float):
    request = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", **headers}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"HTTP {error.code}: {error.read().decode()[:120]}") from None
    except Exception as error:  # noqa: BLE001 - the caller reports the text
        raise RuntimeError(f"{type(error).__name__}: {error}") from None


def ask(target: Target, timeout: float) -> str:
    """One conflict turn. Returns the assistant text."""
    if target.protocol == "ollama-http":
        payload = post_json(
            target.endpoint.rstrip("/") + "/api/chat",
            {
                "model": target.api_name,
                "messages": [{"role": "user", "content": CONFLICT_PROMPT}],
                "stream": False,
                "format": CONFLICT_SCHEMA,
                "options": {"num_predict": 400},
            },
            {},
            timeout,
        )
        return (payload.get("message") or {}).get("content") or ""

    if target.protocol == "openai-compatible-http":
        if not target.credential_env:
            raise RuntimeError("no env credential declared")
        key = os.environ.get(target.credential_env)
        if not key:
            raise RuntimeError(f"{target.credential_env} is unset")
        payload = post_json(
            target.endpoint.rstrip("/") + "/chat/completions",
            {
                "model": target.api_name,
                "messages": [{"role": "user", "content": CONFLICT_PROMPT}],
                "max_tokens": 400,
                "stream": False,
                "response_format": {
                    "type": "json_schema",
                    "json_schema": {
                        "name": "enforcement_probe",
                        "schema": CONFLICT_SCHEMA,
                        "strict": True,
                    },
                },
            },
            {"Authorization": f"Bearer {key}"},
            timeout,
        )
        message = (payload.get("choices") or [{}])[0].get("message") or {}
        text = message.get("content") or ""
        if not text and (message.get("reasoning_content") or message.get("thinking")):
            raise RuntimeError("content empty; the answer landed in the reasoning field")
        return text

    raise RuntimeError(f"protocol {target.protocol} is not probed by this script")


def read_verdict(text: str) -> str:
    text = (text or "").strip()
    if not text:
        return "empty"
    unfenced = re.sub(r"^```[a-z]*\n|\n```$", "", text).strip()
    try:
        value = json.loads(unfenced)
    except json.JSONDecodeError:
        return "not-json"
    if not isinstance(value, dict):
        return "not-object"
    if "note" in value:
        return "prompt-won"
    if set(value) == {"ok"}:
        return "schema-won"
    return "other"


def measure(target: Target, runs: int, timeout: float) -> tuple[str, dict[str, int]]:
    tally: dict[str, int] = {}
    for _ in range(runs):
        try:
            verdict = read_verdict(ask(target, timeout))
        except RuntimeError as error:
            verdict = str(error)
        tally[verdict] = tally.get(verdict, 0) + 1
    if tally.get("schema-won") == runs:
        return NATIVE, tally
    if tally.get("prompt-won", 0) + tally.get("schema-won", 0) == runs:
        # It answered every time and the prompt won at least once: the schema is
        # advisory here. One suppression out of five is not enforcement.
        return OBJECT_ONLY, tally
    return "unmeasured", tally


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("-n", "--runs", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=180.0)
    parser.add_argument(
        "--target",
        action="append",
        default=[],
        help="runtime id to probe; repeatable. Default: every declared-capable target.",
    )
    parser.add_argument(
        "--include-undeclared",
        action="store_true",
        help="also probe targets that declare no structured-output support.",
    )
    args = parser.parse_args()

    targets = load_targets(args.config)
    if args.target:
        wanted = set(args.target)
        targets = [t for t in targets if t.runtime_id in wanted]
        missing = wanted - {t.runtime_id for t in targets}
        for runtime_id in sorted(missing):
            print(f"  {runtime_id}: not in {args.config}", file=sys.stderr)
        if missing:
            return 2
    elif not args.include_undeclared:
        targets = [t for t in targets if t.declared != NONE]

    if not targets:
        print("no targets to probe", file=sys.stderr)
        return 2

    print(f"config: {args.config}")
    print(f"runs per target: {args.runs}\n")
    print(f"{'runtime':44s} {'declared':20s} {'measured':20s} detail")

    drifted: list[str] = []
    for target in sorted(targets, key=lambda t: t.runtime_id):
        measured, tally = measure(target, args.runs, args.timeout)
        detail = ", ".join(f"{count}/{args.runs} {name}" for name, count in
                           sorted(tally.items(), key=lambda item: -item[1]))
        flag = ""
        if measured != "unmeasured" and measured != target.declared:
            flag = "  <-- drift"
            drifted.append(f"{target.runtime_id}: declares {target.declared}, measures {measured}")
        print(f"{target.runtime_id:44s} {target.declared:20s} {measured:20s} {detail}{flag}")

    if drifted:
        print("\ndeclaration disagrees with the wire:")
        for line in drifted:
            print(f"  {line}")
        return 1
    print("\nevery declaration matches what the wire did.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
