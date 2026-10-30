#!/usr/bin/env python3
"""Measure how often a model's first call to one tool follows the tool's schema.

A Keeper that sends a malformed first call spends a turn reading the error and
calling again, and some models never recover. This harness puts a tool
definition in front of a model with one situation that calls for the tool,
takes the model's first tool call, and judges it:

* the JSON-schema keywords masc emits (type, properties, required,
  additionalProperties, items, enum and the numeric and length bounds) at
  every depth, every error rather than the first. A keyword outside that set
  stops the run rather than passing silently;
* the rules a tool's handler checks after the schema, for tools that have them
  (``TOOL_RULES``).

The schema is checked at every depth, which is what masc checks once nested
validation (#38391) lands. Before it, masc checks the top level and a
handler reads the nested fields it knows, so an extra or null nested field
that this harness counts as invalid can still run. Read the rate as "follows
the declared contract", not "was accepted today".

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
# A lane without max-concurrent has no client-side cap in masc; the harness
# still sends one request at a time on it rather than guessing a width.
DEFAULT_LANE_CONCURRENCY = 1

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
    max_tokens: int | None


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
    max_concurrent = lane_table.get("max-concurrent", DEFAULT_LANE_CONCURRENCY)
    if not isinstance(max_concurrent, int) or max_concurrent < 1:
        raise HarnessError(f"lane {lane_name}: max-concurrent must be a positive integer")
    max_tokens = lane_table.get("max-tokens", model.get("max-tokens"))
    if max_tokens is not None and (not isinstance(max_tokens, int) or max_tokens < 1):
        raise HarnessError(f"lane {lane_name}: max-tokens must be a positive integer")
    return Lane(
        name=lane_name,
        endpoint=endpoint.rstrip("/"),
        api_model=api_model,
        credential_env=str(credentials["key"]),
        max_concurrent=max_concurrent,
        temperature=None if temperature is None else float(temperature),
        max_tokens=max_tokens,
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


# Keywords this judge checks, plus the ones that only annotate.
CHECKED_KEYWORDS = frozenset(
    {"type", "properties", "required", "additionalProperties", "items", "enum",
     "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"}
)
ANNOTATION_KEYWORDS = frozenset({"description", "title", "default", "examples", "$schema"})


def _bound_errors(schema: JsonObject, value: JsonValue, path: str) -> list[str]:
    errors: list[str] = []
    number = value if isinstance(value, (int, float)) and not isinstance(value, bool) else None
    minimum, maximum = schema.get("minimum"), schema.get("maximum")
    if number is not None and isinstance(minimum, (int, float)) and number < minimum:
        errors.append(f"{path}: {number} is below {minimum}")
    if number is not None and isinstance(maximum, (int, float)) and number > maximum:
        errors.append(f"{path}: {number} is above {maximum}")
    sized = len(value) if isinstance(value, (str, list)) else None
    low = schema.get("minLength" if isinstance(value, str) else "minItems")
    high = schema.get("maxLength" if isinstance(value, str) else "maxItems")
    if sized is not None and isinstance(low, int) and sized < low:
        errors.append(f"{path}: length {sized} is below {low}")
    if sized is not None and isinstance(high, int) and sized > high:
        errors.append(f"{path}: length {sized} is above {high}")
    return errors


def schema_errors(schema: JsonObject, value: JsonValue, path: str = "$") -> list[str]:
    """Every violation of the keywords masc emits, not only the first."""
    unknown = set(schema) - CHECKED_KEYWORDS - ANNOTATION_KEYWORDS
    if unknown:
        raise HarnessError(f"schema at {path} uses {sorted(unknown)}, which this judge does not check")
    additional = schema.get("additionalProperties")
    if additional is not None and not isinstance(additional, bool):
        raise HarnessError(f"schema at {path}: additionalProperties as a schema is not checked here")
    expected = schema.get("type")
    if expected is not None and not isinstance(expected, str):
        raise HarnessError(f"schema at {path}: a list of types is not checked here")
    if isinstance(expected, str) and not _type_matches(expected, value):
        return [f"{path}: expected {expected}, got {type(value).__name__}"]
    errors: list[str] = _bound_errors(schema, value, path)
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


# OCaml's String.trim removes these five and nothing else.
OCAML_TRIM = " \t\n\r\x0c"


def _blank(value: JsonValue) -> bool:
    return not isinstance(value, str) or value.strip(OCAML_TRIM) == ""


def masc_ask_rule_errors(args: JsonObject) -> list[str]:
    """The checks lib/keeper/keeper_ask.ml's smart constructors make after the
    schema: at least one question, a header and a prompt that are not blank,
    choices or free text on every question, and labels that are not blank.
    Question and choice ids are the schema's business: the handler numbers
    them by position (lib/mcp_tool_runtime_ask.ml) and reads none a call
    sends."""
    questions = args.get("questions")
    if not isinstance(questions, list):
        return []
    errors: list[str] = [] if questions else ["questions: empty"]
    for qi, question in enumerate(questions):
        if not isinstance(question, dict):
            continue
        for field in ("header", "prompt"):
            if field in question and _blank(question[field]):
                errors.append(f"questions[{qi}].{field}: blank")
        choices = question.get("choices")
        choice_list = choices if isinstance(choices, list) else []
        if not choice_list and question.get("free_text") is not True:
            errors.append(f"questions[{qi}]: neither choices nor free_text")
        for ci, choice in enumerate(choice_list):
            if isinstance(choice, dict) and "label" in choice and _blank(choice["label"]):
                errors.append(f"questions[{qi}].choices[{ci}].label: blank")
    return errors


TOOL_RULES: dict[str, Callable[[JsonObject], list[str]]] = {"masc_ask": masc_ask_rule_errors}


@dataclass(frozen=True, slots=True)
class Verdict:
    outcome: str  # valid | invalid | unparseable | no_call
    errors: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class FirstCall:
    """The model's first tool call: the name it called, and its arguments as
    parsed JSON, or the raw text when they did not parse."""

    name: str
    arguments: JsonValue
    parsed: bool


def judge(tool: ToolDefinition, call: FirstCall | None) -> Verdict:
    if call is None:
        return Verdict("no_call", ())
    if call.name != tool.name:
        return Verdict("invalid", (f"called {call.name!r} instead of {tool.name!r}",))
    if not call.parsed or not isinstance(call.arguments, dict):
        return Verdict("unparseable", (repr(call.arguments)[:200],))
    arguments = call.arguments
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


def first_tool_call(lane: Lane, tool: ToolDefinition, scenario: Scenario, prior: PriorCall | None) -> FirstCall | None:
    """The model's first tool call, or None when it made none."""
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
    if lane.max_tokens is not None:
        body["max_tokens"] = lane.max_tokens
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
        return None
    function = calls[0]["function"]
    name = str(function.get("name"))
    raw = function.get("arguments")
    if isinstance(raw, dict):
        return FirstCall(name, raw, True)
    if not isinstance(raw, str):
        return FirstCall(name, raw, False)
    try:
        return FirstCall(name, json.loads(raw), True)
    except json.JSONDecodeError:
        return FirstCall(name, raw, False)


# Rate limits a retry cannot outwait: the account is out of quota or credit.
TERMINAL_HTTP = frozenset({401, 402, 403, 404})
# A 400 can be the provider refusing the model's own malformed call, so it is
# kept apart from transport failures and never re-sampled.
PROVIDER_REJECTED_HTTP = 400


def _row(lane: Lane, scenario: Scenario, rep: int, started: float, outcome: str, errors: list[str], arguments: JsonValue) -> JsonObject:
    return {
        "lane": lane.name,
        "scenario": scenario.scenario_id,
        "rep": rep,
        "outcome": outcome,
        "errors": list(errors),
        "arguments": arguments,
        "seconds": round(time.monotonic() - started, 2),
    }


def trial(lane: Lane, tool: ToolDefinition, scenario: Scenario, prior: PriorCall | None, rep: int) -> JsonObject:
    started = time.monotonic()
    failure = ""
    for attempt in range(MAX_ATTEMPTS):
        try:
            call = first_tool_call(lane, tool, scenario, prior)
        except urllib.error.HTTPError as error:
            failure = f"HTTP {error.code}: {error.read()[:300].decode(errors='replace')}"
            if error.code == PROVIDER_REJECTED_HTTP:
                return _row(lane, scenario, rep, started, "provider_rejected", [failure], None)
            if error.code in TERMINAL_HTTP:
                break
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as error:
            failure = f"{type(error).__name__}: {error}"
        except (KeyError, IndexError, AttributeError, TypeError) as error:
            # The response did not have the chat-completions shape.
            failure = f"malformed response: {type(error).__name__}: {error}"
        else:
            verdict = judge(tool, call)
            arguments = call.arguments if call is not None else None
            return _row(lane, scenario, rep, started, verdict.outcome, list(verdict.errors), arguments)
        if attempt < MAX_ATTEMPTS - 1:
            time.sleep(min(MAX_BACKOFF_S, 8.0 * 2**attempt))
    return _row(lane, scenario, rep, started, "transport_error", [failure], None)


# ------------------------------------------------------------------ report


# Outcomes that say nothing about the model's call and stay out of the rate.
NOT_JUDGED = frozenset({"transport_error", "provider_rejected"})


def summarize(rows: list[JsonObject]) -> list[str]:
    """One line per (variant, prior call or not, lane): valid calls over judged calls."""
    counts: dict[tuple[str, str], dict[str, int]] = {}
    for row in rows:
        variant = str(row.get("variant")) + ("+prior" if row.get("prior_call") else "")
        key = (variant, str(row.get("lane")))
        bucket = counts.setdefault(key, {})
        outcome = str(row.get("outcome"))
        bucket[outcome] = bucket.get(outcome, 0) + 1
    lines = []
    for (variant, lane), bucket in sorted(counts.items()):
        judged = sum(n for outcome, n in bucket.items() if outcome not in NOT_JUDGED)
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
        futures = [pool.submit(gated, *job) for job in jobs]
        for future in cf.as_completed(futures):
            try:
                row = future.result()
            except HarnessError:
                # A harness bug is the same on every job: stop paying for the rest.
                pool.shutdown(wait=False, cancel_futures=True)
                raise
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
