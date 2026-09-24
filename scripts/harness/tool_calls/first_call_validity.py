#!/usr/bin/env python3
"""Measure how often a model's first call to one tool is one masc accepts.

A Keeper that sends a malformed first call spends a turn reading the error and
calling again, and some models never recover. This harness puts a tool
definition in front of a model with one situation that calls for the tool,
takes the model's first tool call, and judges it:

* the JSON-schema subset masc emits (type, properties, required,
  additionalProperties, items, enum), every error rather than the first;
* the rules a tool's handler checks after the schema, for tools that have them
  (``TOOL_RULES``).

Lanes are the ``<provider>.<model>`` names in masc's runtime.toml. The
endpoint, the model's API name and temperature, the credential's environment
variable and the lane's ``max-concurrent`` all come from that file. Only
``openai-compatible-http`` providers with ``env`` credentials can be called
from here; the subscription CLIs (claude-code, codex, antigravity) wrap tools
in their own way and need their own rig.

The tool definition is the one masc served. ``--from-wire-capture NAME`` takes
it from the newest request in ``.masc/wire-capture`` that carried it, so a
baseline is never a hand copy. A variant under test is a JSON file of the same
shape: ``{"name", "description", "input_schema"}``.

Transport failures (rate limits, timeouts) are the harness's, not the
model's: they are recorded but left out of every rate.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
from dataclasses import dataclass
import json
import os
from pathlib import Path
import sys
import threading
import time
import tomllib
from typing import Callable, Union
import urllib.error
import urllib.request

JsonValue = Union[None, bool, int, float, str, list["JsonValue"], dict[str, "JsonValue"]]
JsonObject = dict[str, JsonValue]

OPENAI_COMPATIBLE = "openai-compatible-http"
REQUEST_TIMEOUT_S = 240.0
MAX_ATTEMPTS = 6
MAX_BACKOFF_S = 60.0
USER_AGENT = "masc-first-call-validity/1"

SYSTEM_PROMPT = (
    "You are a masc Keeper. You work through tools. The situation below needs "
    "the tool you were given. Call it once, now, without explaining."
)


class HarnessError(RuntimeError):
    pass


# ------------------------------------------------------------------ lanes


@dataclass(frozen=True, slots=True)
class Lane:
    name: str
    endpoint: str
    api_model: str
    credential_env: str
    max_concurrent: int
    temperature: float | None


def _table(value: object, where: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise HarnessError(f"{where} is not a table")
    return {str(k): v for k, v in value.items()}


def resolve_lane(runtime: dict[str, object], lane_name: str) -> Lane:
    provider_key, sep, model_key = lane_name.partition(".")
    if not sep or not model_key:
        raise HarnessError(f"lane {lane_name!r} is not <provider>.<model>")
    providers = _table(runtime.get("providers"), "[providers]")
    if provider_key not in providers:
        raise HarnessError(f"lane {lane_name}: no [providers.{provider_key}]")
    provider = _table(providers[provider_key], f"[providers.{provider_key}]")
    protocol = provider.get("protocol")
    if protocol != OPENAI_COMPATIBLE:
        raise HarnessError(f"lane {lane_name}: protocol {protocol!r} is not callable from here")
    endpoint = provider.get("endpoint")
    if not isinstance(endpoint, str):
        raise HarnessError(f"lane {lane_name}: provider has no endpoint")
    credentials = _table(provider.get("credentials"), f"[providers.{provider_key}.credentials]")
    if credentials.get("type") != "env" or not isinstance(credentials.get("key"), str):
        raise HarnessError(f"lane {lane_name}: only env credentials are read here")
    lanes_of_provider = _table(runtime.get(provider_key), f"[{provider_key}]")
    if model_key not in lanes_of_provider:
        raise HarnessError(f"lane {lane_name}: no [{provider_key}.{model_key}] lane")
    lane_table = _table(lanes_of_provider[model_key], f"[{provider_key}.{model_key}]")
    models = _table(runtime.get("models"), "[models]")
    if model_key not in models:
        raise HarnessError(f"lane {lane_name}: no [models.{model_key}]")
    model = _table(models[model_key], f"[models.{model_key}]")
    api_model = model.get("api-name")
    if not isinstance(api_model, str):
        raise HarnessError(f"lane {lane_name}: [models.{model_key}] has no api-name")
    temperature = model.get("temperature")
    if temperature is not None and not isinstance(temperature, (int, float)):
        raise HarnessError(f"lane {lane_name}: [models.{model_key}] temperature is not a number")
    max_concurrent = lane_table.get("max-concurrent")
    if not isinstance(max_concurrent, int) or max_concurrent < 1:
        raise HarnessError(f"lane {lane_name}: max-concurrent must be a positive integer")
    return Lane(
        name=lane_name,
        endpoint=endpoint.rstrip("/"),
        api_model=api_model,
        credential_env=str(credentials["key"]),
        max_concurrent=max_concurrent,
        temperature=None if temperature is None else float(temperature),
    )


# ------------------------------------------------------------------ tool definitions


@dataclass(frozen=True, slots=True)
class ToolDefinition:
    name: str
    description: str
    input_schema: JsonObject


def tool_of_json(value: JsonValue, where: str) -> ToolDefinition:
    if not isinstance(value, dict):
        raise HarnessError(f"{where}: a tool definition is an object")
    name, description, schema = value.get("name"), value.get("description"), value.get("input_schema")
    if not isinstance(name, str) or not isinstance(description, str) or not isinstance(schema, dict):
        raise HarnessError(f"{where}: needs string name, string description, object input_schema")
    return ToolDefinition(name, description, schema)


def tool_from_wire_capture(masc_dir: Path, tool_name: str) -> ToolDefinition:
    """The definition of [tool_name] in the newest captured request that carried it."""
    captures = sorted((masc_dir / "wire-capture").glob("*/*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    seen: set[str] = set()
    for capture in captures:
        lines = capture.read_text(encoding="utf-8").splitlines()
        for line in reversed(lines):
            if "tools_ref" not in line:
                continue
            record = json.loads(line)
            if not isinstance(record, dict) or record.get("kind") != "request":
                continue
            blob = ((record.get("tools_ref") or {}).get("_blob") or {}).get("sha256")
            if not isinstance(blob, str) or blob in seen:
                continue
            seen.add(blob)
            blob_path = masc_dir / "tool_blobs" / blob[:2] / blob
            if not blob_path.exists():
                continue
            tools = json.loads(blob_path.read_text(encoding="utf-8"))
            for tool in tools if isinstance(tools, list) else []:
                if isinstance(tool, dict) and tool.get("name") == tool_name:
                    return tool_of_json(tool, f"{blob_path}")
    raise HarnessError(f"no captured request under {masc_dir / 'wire-capture'} carried {tool_name}")


# ------------------------------------------------------------------ judging


def _type_matches(expected: str, value: JsonValue) -> bool:
    match expected:
        case "object":
            return isinstance(value, dict)
        case "array":
            return isinstance(value, list)
        case "string":
            return isinstance(value, str)
        case "boolean":
            return isinstance(value, bool)
        case "integer":
            return isinstance(value, int) and not isinstance(value, bool)
        case "number":
            return isinstance(value, (int, float)) and not isinstance(value, bool)
        case _:
            raise HarnessError(f"schema type {expected!r} is outside the subset masc emits")


def schema_errors(schema: JsonObject, value: JsonValue, path: str = "$") -> list[str]:
    """Every violation of the JSON-schema subset masc emits, not only the first."""
    expected = schema.get("type")
    if isinstance(expected, str) and not _type_matches(expected, value):
        return [f"{path}: expected {expected}, got {type(value).__name__}"]
    errors: list[str] = []
    members = schema.get("enum")
    if isinstance(members, list) and value not in members:
        errors.append(f"{path}: {value!r} is not one of {members}")
    if isinstance(value, dict):
        properties = schema.get("properties")
        props = properties if isinstance(properties, dict) else {}
        required = schema.get("required")
        for field in required if isinstance(required, list) else []:
            if isinstance(field, str) and field not in value:
                errors.append(f"{path}.{field}: missing")
        if schema.get("additionalProperties") is False:
            errors.extend(f"{path}.{field}: not in the schema" for field in value if field not in props)
        for field, sub in props.items():
            if field in value and isinstance(sub, dict):
                errors.extend(schema_errors(sub, value[field], f"{path}.{field}"))
    if isinstance(value, list):
        items = schema.get("items")
        if isinstance(items, dict):
            for index, item in enumerate(value):
                errors.extend(schema_errors(items, item, f"{path}[{index}]"))
    return errors


def _blank(value: JsonValue) -> bool:
    return not isinstance(value, str) or value.strip() == ""


def masc_ask_rule_errors(args: JsonObject) -> list[str]:
    """The checks Keeper_ask's smart constructors make after the schema
    (lib/keeper/keeper_ask.ml [choice], [question], [ask]). A question needs
    choices or free text, and ids are unique within their list. An id the
    call leaves out is numbered by position the way the handler numbers it,
    so only a supplied id can be blank or a duplicate."""
    questions = args.get("questions")
    if not isinstance(questions, list):
        return []
    errors: list[str] = [] if questions else ["questions: empty"]
    question_ids: list[str] = []
    for qi, question in enumerate(questions):
        if not isinstance(question, dict):
            continue
        qid = question.get("question_id", f"q{qi + 1}")
        if _blank(qid):
            errors.append(f"questions[{qi}].question_id: blank")
        question_ids.append(str(qid))
        for field in ("header", "prompt"):
            if field in question and _blank(question[field]):
                errors.append(f"questions[{qi}].{field}: blank")
        choices = question.get("choices")
        choice_list = choices if isinstance(choices, list) else []
        if not choice_list and question.get("free_text") is not True:
            errors.append(f"questions[{qi}]: neither choices nor free_text")
        choice_ids: list[str] = []
        for ci, choice in enumerate(choice_list):
            if not isinstance(choice, dict):
                continue
            cid = choice.get("choice_id", f"c{ci + 1}")
            if _blank(cid):
                errors.append(f"questions[{qi}].choices[{ci}].choice_id: blank")
            if "label" in choice and _blank(choice["label"]):
                errors.append(f"questions[{qi}].choices[{ci}].label: blank")
            choice_ids.append(str(cid))
        if len(set(choice_ids)) != len(choice_ids):
            errors.append(f"questions[{qi}]: duplicate choice_id")
    if len(set(question_ids)) != len(question_ids):
        errors.append("questions: duplicate question_id")
    return errors


TOOL_RULES: dict[str, Callable[[JsonObject], list[str]]] = {"masc_ask": masc_ask_rule_errors}


@dataclass(frozen=True, slots=True)
class Verdict:
    outcome: str  # valid | invalid | unparseable | no_call
    errors: tuple[str, ...]


def judge(tool: ToolDefinition, arguments: JsonValue | None, parsed: bool) -> Verdict:
    if arguments is None:
        return Verdict("no_call", ())
    if not parsed or not isinstance(arguments, dict):
        return Verdict("unparseable", (repr(arguments)[:200],))
    errors = schema_errors(tool.input_schema, arguments)
    rules = TOOL_RULES.get(tool.name)
    if rules is not None:
        errors += rules(arguments)
    return Verdict("valid" if not errors else "invalid", tuple(errors))


# ------------------------------------------------------------------ calling


@dataclass(frozen=True, slots=True)
class Scenario:
    scenario_id: str
    user: str


@dataclass(frozen=True, slots=True)
class PriorCall:
    """An earlier call the conversation already holds, for measuring whether a
    changed schema is followed or the history is copied."""

    user: str
    arguments: JsonObject
    result: str


def _messages(scenario: Scenario, prior: PriorCall | None, tool_name: str) -> list[JsonValue]:
    messages: list[JsonValue] = [{"role": "system", "content": SYSTEM_PROMPT}]
    if prior is not None:
        call: JsonObject = {
            "id": "call_prior",
            "type": "function",
            "function": {"name": tool_name, "arguments": json.dumps(prior.arguments, ensure_ascii=False)},
        }
        messages += [
            {"role": "user", "content": prior.user},
            {"role": "assistant", "content": None, "tool_calls": [call]},
            {"role": "tool", "tool_call_id": "call_prior", "content": prior.result},
        ]
    messages.append({"role": "user", "content": scenario.user})
    return messages


def first_tool_call(lane: Lane, tool: ToolDefinition, scenario: Scenario, prior: PriorCall | None) -> tuple[JsonValue | None, bool]:
    """The first tool call's arguments and whether they parsed as JSON; (None, True) when the model made no call."""
    body: JsonObject = {
        "model": lane.api_model,
        "messages": _messages(scenario, prior, tool.name),
        "tools": [{"type": "function", "function": {"name": tool.name, "description": tool.description, "parameters": tool.input_schema}}],
        "tool_choice": "auto",
    }
    # The model's declared temperature, as masc sends it. Some providers bind
    # the accepted temperature to the thinking state, and sampling at another
    # temperature measures a different model.
    if lane.temperature is not None:
        body["temperature"] = lane.temperature
    request = urllib.request.Request(
        f"{lane.endpoint}/chat/completions",
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
            "Authorization": f"Bearer {os.environ[lane.credential_env]}",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_S) as response:
        payload = json.loads(response.read())
    message = payload["choices"][0]["message"]
    calls = message.get("tool_calls") or []
    if not calls:
        return None, True
    raw = calls[0]["function"].get("arguments")
    if isinstance(raw, dict):
        return raw, True
    try:
        return json.loads(raw), True
    except (TypeError, json.JSONDecodeError):
        return raw, False


# Rate limits a retry cannot outwait: the account is out of quota or credit.
TERMINAL_HTTP = frozenset({400, 401, 402, 403, 404})


def trial(lane: Lane, tool: ToolDefinition, scenario: Scenario, prior: PriorCall | None, rep: int) -> JsonObject:
    started = time.monotonic()
    failure = ""
    for attempt in range(MAX_ATTEMPTS):
        try:
            arguments, parsed = first_tool_call(lane, tool, scenario, prior)
            verdict = judge(tool, arguments, parsed)
            return {
                "lane": lane.name,
                "scenario": scenario.scenario_id,
                "rep": rep,
                "outcome": verdict.outcome,
                "errors": list(verdict.errors),
                "arguments": arguments,
                "seconds": round(time.monotonic() - started, 2),
            }
        except urllib.error.HTTPError as error:
            failure = f"HTTP {error.code}: {error.read()[:300].decode(errors='replace')}"
            if error.code in TERMINAL_HTTP:
                break
        except (urllib.error.URLError, TimeoutError, OSError, KeyError, json.JSONDecodeError) as error:
            failure = f"{type(error).__name__}: {error}"
        time.sleep(min(MAX_BACKOFF_S, 8.0 * 2**attempt))
    return {
        "lane": lane.name,
        "scenario": scenario.scenario_id,
        "rep": rep,
        "outcome": "transport_error",
        "errors": [failure],
        "arguments": None,
        "seconds": round(time.monotonic() - started, 2),
    }


# ------------------------------------------------------------------ report


def summarize(rows: list[JsonObject]) -> list[str]:
    """One line per (variant, lane): valid calls over judged calls."""
    counts: dict[tuple[str, str], dict[str, int]] = {}
    for row in rows:
        key = (str(row.get("variant")), str(row.get("lane")))
        bucket = counts.setdefault(key, {})
        outcome = str(row.get("outcome"))
        bucket[outcome] = bucket.get(outcome, 0) + 1
    lines = []
    for (variant, lane), bucket in sorted(counts.items()):
        judged = sum(n for outcome, n in bucket.items() if outcome != "transport_error")
        valid = bucket.get("valid", 0)
        rate = f"{valid / judged:6.1%}" if judged else "     -"
        lines.append(f"{variant:<12} {lane:<40} {valid:>3}/{judged:<3} {rate}  {json.dumps(bucket, sort_keys=True)}")
    return lines


def load_scenarios(path: Path) -> list[Scenario]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise HarnessError(f"{path}: scenarios are a list")
    scenarios = []
    for item in raw:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not isinstance(item.get("user"), str):
            raise HarnessError(f"{path}: each scenario has a string id and a string user")
        scenarios.append(Scenario(item["id"], item["user"]))
    return scenarios


def load_prior(path: Path) -> PriorCall:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or not isinstance(raw.get("user"), str) or not isinstance(raw.get("arguments"), dict) or not isinstance(raw.get("result"), str):
        raise HarnessError(f"{path}: needs string user, object arguments, string result")
    return PriorCall(raw["user"], raw["arguments"], raw["result"])


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--tool-json", type=Path, help="a tool definition file")
    source.add_argument("--from-wire-capture", metavar="TOOL", help="take TOOL's definition from the newest capture")
    parser.add_argument("--variant-name", help="label for this definition in the results (default: file stem or 'served')")
    parser.add_argument("--scenarios", type=Path)
    parser.add_argument("--lanes", help="comma-separated runtime.toml lanes, <provider>.<model>")
    parser.add_argument("--masc-dir", type=Path, default=Path(".masc"), help="the workspace's .masc directory")
    parser.add_argument("--runtime-toml", type=Path, help="default: <masc-dir>/config/runtime.toml")
    parser.add_argument("--prior-call", type=Path, help="an earlier call the conversation already holds")
    parser.add_argument("--reps", type=int, default=5)
    parser.add_argument("--out", type=Path, required=True, help="JSONL, appended")
    parser.add_argument("--summary-only", action="store_true", help="print the summary of --out and exit")
    args = parser.parse_args(argv)

    if args.summary_only:
        rows = [json.loads(line) for line in args.out.read_text(encoding="utf-8").splitlines() if line]
        print("\n".join(summarize(rows)))
        return 0

    if args.scenarios is None or args.lanes is None or (args.tool_json is None and args.from_wire_capture is None):
        raise HarnessError("a run needs --scenarios, --lanes, and --tool-json or --from-wire-capture")
    runtime_path = args.runtime_toml or args.masc_dir / "config" / "runtime.toml"
    with runtime_path.open("rb") as handle:
        runtime = tomllib.load(handle)
    lanes = [resolve_lane(runtime, name.strip()) for name in args.lanes.split(",") if name.strip()]
    for lane in lanes:
        if lane.credential_env not in os.environ:
            raise HarnessError(f"lane {lane.name}: environment has no {lane.credential_env}")
    if args.tool_json is not None:
        tool = tool_of_json(json.loads(args.tool_json.read_text(encoding="utf-8")), str(args.tool_json))
        variant = args.variant_name or args.tool_json.stem
    else:
        tool = tool_from_wire_capture(args.masc_dir, args.from_wire_capture)
        variant = args.variant_name or "served"
    scenarios = load_scenarios(args.scenarios)
    prior = load_prior(args.prior_call) if args.prior_call else None

    gates = {lane.name: threading.Semaphore(lane.max_concurrent) for lane in lanes}

    def gated(lane: Lane, scenario: Scenario, rep: int) -> JsonObject:
        with gates[lane.name]:
            return trial(lane, tool, scenario, prior, rep)

    jobs = [(lane, scenario, rep) for lane in lanes for scenario in scenarios for rep in range(args.reps)]
    workers = sum(lane.max_concurrent for lane in lanes)
    rows: list[JsonObject] = []
    with cf.ThreadPoolExecutor(max_workers=workers) as pool, args.out.open("a", encoding="utf-8") as out:
        for future in cf.as_completed([pool.submit(gated, *job) for job in jobs]):
            row = future.result()
            row["variant"] = variant
            row["prior_call"] = prior is not None
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
            out.flush()
            rows.append(row)
            errors = row.get("errors")
            detail = "; ".join(map(str, errors)) if isinstance(errors, list) else ""
            print(f"{variant} {row['lane']} {row['scenario']} {row['outcome']} {detail[:120]}", file=sys.stderr)
    print("\n".join(summarize(rows)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except HarnessError as error:
        print(f"first_call_validity: {error}", file=sys.stderr)
        sys.exit(2)
