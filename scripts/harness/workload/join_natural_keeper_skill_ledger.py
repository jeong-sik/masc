#!/usr/bin/env python3
"""Join one natural Keeper producer receipt to its exact Skill ledger scope.

The producer receipt supplies the turn reference.  This collector never picks
the latest activation, compares Skill names, or treats an id prefix as an
identity.  Zero and multiple exact-turn matches remain explicit observations.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import stat
import subprocess
import sys
from typing import Any, cast
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request

import keeper_skill_use_proof as proof
import proof_http
import produce_natural_keeper_skill_proof as natural_producer


JOIN_SCHEMA = "masc.natural-keeper-skill-ledger-join/v2"
HISTORICAL_PROJECTION_SCHEMA = "masc.dashboard.skill-activations/v1"


class JoinError(RuntimeError):
    pass


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise JoinError(detail)


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def required_string(value: Any, field: str, context: str) -> str:
    require(isinstance(value, dict), f"{context} is not an object")
    child = value.get(field)
    require(isinstance(child, str) and child != "", f"{context}.{field} is empty")
    return cast(str, child)


def required_object(value: Any, field: str, context: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{context} is not an object")
    child = value.get(field)
    require(isinstance(child, dict), f"{context}.{field} is not an object")
    return cast(dict[str, Any], child)


def required_list(value: Any, field: str, context: str) -> list[Any]:
    require(isinstance(value, dict), f"{context} is not an object")
    child = value.get(field)
    require(isinstance(child, list), f"{context}.{field} is not an array")
    return cast(list[Any], child)


def require_exact_fields(
    value: dict[str, Any], expected: set[str], context: str
) -> None:
    require(
        set(value) == expected,
        f"{context} fields differ: expected={sorted(expected)} actual={sorted(value)}",
    )


def read_token(path: Path | None) -> str | None:
    if path is None:
        return None
    require(not path.is_symlink(), "token file must not be a symlink")
    try:
        require(stat.S_ISREG(path.stat().st_mode), "token file must be regular")
        token = path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise JoinError(f"cannot read token file: {error}") from error
    require(token != "", "token file is empty")
    require("\r" not in token and "\n" not in token, "token file has multiple lines")
    return token


def request_json(
    url: str, *, token: str | None, timeout: float
) -> tuple[dict[str, Any], bytes]:
    headers = {"Accept": "application/json"}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(url, headers=headers)
    try:
        with proof_http.open_no_redirect(request, timeout=timeout) as response:
            raw = response.read()
    except (HTTPError, URLError, OSError) as error:
        raise JoinError(f"cannot read {url}: {error}") from error
    try:
        return proof.decode_json(raw, f"response from {url}"), raw
    except proof.ProofError as error:
        raise JoinError(str(error)) from error


def load_receipt(path: Path, expected_sha256: str) -> tuple[dict[str, Any], bytes]:
    require(
        proof.SHA256_RE.fullmatch(expected_sha256) is not None,
        "expected producer receipt SHA is not sha256",
    )
    require(not path.is_symlink(), "producer receipt must not be a symlink")
    try:
        require(stat.S_ISREG(path.stat().st_mode), "producer receipt must be regular")
        raw = path.read_bytes()
    except OSError as error:
        raise JoinError(f"cannot read producer receipt: {error}") from error
    require(
        proof.digest_bytes(raw) == expected_sha256,
        "producer receipt does not match the expected SHA",
    )
    try:
        return proof.decode_json(raw, f"producer receipt {path}"), raw
    except proof.ProofError as error:
        raise JoinError(str(error)) from error


def validate_receipt(
    receipt: dict[str, Any],
    *,
    receipt_raw: bytes,
    expected_receipt_sha256: str,
    source: dict[str, Any],
) -> dict[str, Any]:
    require(
        proof.SHA256_RE.fullmatch(expected_receipt_sha256) is not None,
        "expected producer receipt SHA is not sha256",
    )
    require(
        proof.digest_bytes(receipt_raw) == expected_receipt_sha256,
        "producer receipt does not match the expected SHA",
    )
    try:
        decoded_receipt = proof.decode_json(receipt_raw, "producer receipt bytes")
    except proof.ProofError as error:
        raise JoinError(str(error)) from error
    require(
        decoded_receipt == receipt, "producer receipt object differs from its bytes"
    )
    require(
        receipt.get("schema") == natural_producer.RECEIPT_SCHEMA,
        "producer schema is unsupported",
    )
    require_exact_fields(
        receipt,
        {
            "schema",
            "captured_at",
            "source",
            "keeper",
            "submitted_by",
            "keeper_admission",
            "keeper_declarative_runtime_id",
            "actual_invocation_runtime_id",
            "operation",
            "message",
            "skill_tool_use_id",
            "ledger_lookup",
            "unresolved_identity",
            "producer_calls",
            "server",
        },
        "producer receipt",
    )
    receipt_source = required_object(receipt, "source", "producer receipt")
    require_exact_fields(
        receipt_source,
        {"head", "tree", "tracked_checkout_clean"},
        "producer receipt.source",
    )
    head = required_string(receipt_source, "head", "producer receipt.source")
    tree = required_string(receipt_source, "tree", "producer receipt.source")
    require(
        proof.GIT_COMMIT_RE.fullmatch(head) is not None,
        "producer source HEAD is invalid",
    )
    require(
        proof.GIT_COMMIT_RE.fullmatch(tree) is not None,
        "producer source tree is invalid",
    )
    require(
        receipt_source.get("tracked_checkout_clean") is True,
        "producer source checkout was not clean",
    )
    require(source.get("tracked_changes") == [], "join source checkout is not clean")
    require(source.get("head") == head, "join source HEAD differs from producer")
    require(source.get("tree") == tree, "join source tree differs from producer")

    keeper = required_string(receipt, "keeper", "producer receipt")
    submitted_by = required_string(receipt, "submitted_by", "producer receipt")
    require(
        receipt.get("keeper_admission") == "exact_existing",
        "producer did not target one exact existing Keeper",
    )
    required_string(receipt, "keeper_declarative_runtime_id", "producer receipt")
    require(
        receipt.get("actual_invocation_runtime_id") is None,
        "producer unexpectedly asserted actual invocation runtime",
    )
    operation = required_object(receipt, "operation", "producer receipt")
    require_exact_fields(
        operation,
        {
            "operation_id",
            "acceptance",
            "state",
            "turn_ref",
            "status_observations",
            "typed_terminal_record",
            "expected_operation_input_digest",
        },
        "producer operation",
    )
    operation_id = required_string(operation, "operation_id", "producer operation")
    require(operation.get("state") == "Succeeded", "producer operation did not succeed")
    acceptance = required_object(operation, "acceptance", "producer operation")
    try:
        accepted_operation_id = natural_producer.validate_acceptance(acceptance)
    except natural_producer.ProducerError as error:
        raise JoinError(f"producer acceptance is invalid: {error}") from error
    require(
        accepted_operation_id == operation_id,
        "producer acceptance operation id differs",
    )
    turn_ref = required_string(operation, "turn_ref", "producer operation")
    terminal = required_object(operation, "typed_terminal_record", "producer operation")
    try:
        terminal_state = natural_producer.validate_operation(terminal, operation_id)
    except natural_producer.ProducerError as error:
        raise JoinError(f"producer terminal operation is invalid: {error}") from error
    require(terminal_state == "Succeeded", "terminal operation did not succeed")
    require(terminal.get("outcome_ref") == turn_ref, "terminal turn reference differs")
    try:
        trace_id, _ = natural_producer.parse_turn_ref(turn_ref)
        natural_producer.validate_direct_message_source(
            terminal.get("source"), keeper=keeper, submitted_by=submitted_by
        )
    except natural_producer.ProducerError as error:
        raise JoinError(f"producer operation identity is invalid: {error}") from error
    expected_input_digest = required_string(
        operation, "expected_operation_input_digest", "producer operation"
    )
    require(
        proof.SHA256_RE.fullmatch(expected_input_digest) is not None,
        "producer expected operation input digest is invalid",
    )
    require(
        terminal.get("execution_digest") == expected_input_digest,
        "producer terminal execution digest differs from expected input",
    )

    lookup = required_object(receipt, "ledger_lookup", "producer receipt")
    require_exact_fields(
        lookup,
        {"keeper", "turn_ref", "skill_tool_use_id"},
        "producer ledger lookup",
    )
    require(lookup.get("keeper") == keeper, "producer ledger Keeper differs")
    require(
        lookup.get("turn_ref") == turn_ref, "producer ledger turn reference differs"
    )
    require(
        lookup.get("skill_tool_use_id") is None
        and receipt.get("skill_tool_use_id") is None,
        "producer receipt unexpectedly selected a Skill invocation",
    )
    calls = required_object(receipt, "producer_calls", "producer receipt")
    require_exact_fields(calls, {"masc_keeper_msg"}, "producer calls")
    require(calls.get("masc_keeper_msg") == 1, "producer did not submit exactly once")
    message = required_object(receipt, "message", "producer receipt")
    require_exact_fields(message, {"bytes", "sha256"}, "producer message")
    require(
        isinstance(message.get("bytes"), int)
        and not isinstance(message.get("bytes"), bool)
        and message.get("bytes", -1) > 0,
        "producer message byte count is invalid",
    )
    require(
        isinstance(message.get("sha256"), str)
        and proof.SHA256_RE.fullmatch(cast(str, message.get("sha256"))) is not None,
        "producer message SHA is invalid",
    )
    unresolved = required_object(receipt, "unresolved_identity", "producer receipt")
    require_exact_fields(
        unresolved, {"kind", "operation_schema"}, "producer unresolved identity"
    )
    server = required_object(receipt, "server", "producer receipt")
    require_exact_fields(
        server,
        {
            "binary_commit",
            "source_fingerprint",
            "executable_sha256",
            "executable_provenance_path",
            "executable_provenance_sha256",
            "runtime_instance_id",
            "started_at",
            "effective_base_path",
            "effective_masc_root",
        },
        "producer server",
    )
    producer_instance_id = required_string(
        server, "runtime_instance_id", "producer server"
    )
    try:
        natural_producer.validate_runtime_instance_id(producer_instance_id)
    except natural_producer.ProducerError as error:
        raise JoinError(f"producer runtime instance id is invalid: {error}") from error
    return {
        "source": {"head": head, "tree": tree},
        "server": {
            "binary_commit": required_string(
                server, "binary_commit", "producer server"
            ),
            "source_fingerprint": required_string(
                server, "source_fingerprint", "producer server"
            ),
            "executable_sha256": required_string(
                server, "executable_sha256", "producer server"
            ),
            "executable_provenance_path": required_string(
                server, "executable_provenance_path", "producer server"
            ),
            "executable_provenance_sha256": required_string(
                server, "executable_provenance_sha256", "producer server"
            ),
            "runtime_instance_id": producer_instance_id,
            "started_at": required_string(server, "started_at", "producer server"),
            "effective_base_path": required_string(
                server, "effective_base_path", "producer server"
            ),
            "effective_masc_root": required_string(
                server, "effective_masc_root", "producer server"
            ),
        },
        "keeper": keeper,
        "submitted_by": submitted_by,
        "operation_id": operation_id,
        "turn_ref": turn_ref,
        "trace_id": trace_id,
    }


def health_identity(
    health: dict[str, Any], *, expected_source_head: str
) -> dict[str, str]:
    require(health.get("health_detail") == "full", "health response is not full")
    build = required_object(health, "build", "health")
    paths = required_object(health, "paths", "health")
    require(
        build.get("binary_commit_source") == "embedded",
        "server binary commit is not embedded",
    )
    identity = {
        "binary_commit": required_string(build, "binary_commit", "health.build"),
        "source_fingerprint": required_string(
            build, "source_fingerprint", "health.build"
        ),
        "executable_sha256": required_string(
            build, "executable_sha256", "health.build"
        ),
        "executable_provenance_path": required_string(
            build, "executable_provenance_path", "health.build"
        ),
        "executable_provenance_sha256": required_string(
            build, "executable_provenance_sha256", "health.build"
        ),
        "runtime_instance_id": required_string(
            build, "runtime_instance_id", "health.build"
        ),
        "started_at": required_string(build, "started_at", "health.build"),
        "effective_base_path": required_string(
            paths, "effective_base_path", "health.paths"
        ),
        "effective_masc_root": required_string(
            paths, "effective_masc_root", "health.paths"
        ),
    }
    try:
        natural_producer.validate_runtime_instance_id(identity["runtime_instance_id"])
    except natural_producer.ProducerError as error:
        raise JoinError(f"health runtime instance id is invalid: {error}") from error
    require(
        identity["binary_commit"] == expected_source_head,
        "server binary differs from producer source",
    )
    require(
        proof.SHA256_RE.fullmatch(identity["source_fingerprint"]) is not None,
        "server source fingerprint is invalid",
    )
    require(
        proof.SHA256_RE.fullmatch(identity["executable_sha256"]) is not None,
        "server executable digest is invalid",
    )
    require(
        Path(identity["executable_provenance_path"]).is_absolute(),
        "server executable provenance path is invalid",
    )
    require(
        proof.SHA256_RE.fullmatch(identity["executable_provenance_sha256"]) is not None,
        "server executable provenance digest is invalid",
    )
    return identity


def validate_dashboard_ledger(
    dashboard: dict[str, Any],
    *,
    durable_ledger: dict[str, Any],
    keeper: str,
) -> dict[str, Any]:
    projection = required_object(dashboard, "skill_activations", "dashboard")
    require(
        projection.get("status") == "available",
        "Skill ledger projection is unavailable",
    )
    require(projection.get("keeper_name") == keeper, "Skill ledger Keeper differs")
    ledger = required_object(projection, "ledger", "Skill ledger projection")
    require(
        ledger.get("schema") == proof.LEDGER_SCHEMA,
        "Skill ledger schema is unsupported",
    )
    require(ledger == durable_ledger, "Dashboard ledger differs from durable ledger")
    require(
        required_string(ledger, "revision", "Skill ledger")
        == proof.ledger_revision(ledger),
        "Skill ledger revision differs from canonical content",
    )
    activations = required_list(ledger, "activations", "Skill ledger")
    rejections = required_list(ledger, "transition_rejections", "Skill ledger")
    require(
        all(isinstance(item, dict) for item in activations),
        "Skill ledger has untyped activation",
    )
    require(
        all(isinstance(item, dict) for item in rejections),
        "Skill ledger has untyped rejection",
    )
    typed_activations = cast(list[dict[str, Any]], activations)
    typed_rejections = cast(list[dict[str, Any]], rejections)
    require(
        required_object(projection, "summary", "Skill ledger projection")
        == proof.summarize(typed_activations, typed_rejections),
        "Dashboard Skill summary differs from ledger",
    )
    require(
        required_list(projection, "scoped_summaries", "Skill ledger projection")
        == proof.scoped_summaries(typed_activations, typed_rejections),
        "Dashboard scoped Skill summaries differ from ledger",
    )
    return ledger


def validate_current_skill_projection(
    dashboard: dict[str, Any],
    *,
    durable_ledger: dict[str, Any],
    keeper: str,
    trace_id: str,
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    if "skill_activations" not in dashboard:
        return {"status": "missing"}, None
    projection_value = dashboard["skill_activations"]
    require(
        isinstance(projection_value, dict),
        "current Skill projection is not an object",
    )
    projection = cast(dict[str, Any], projection_value)
    status = required_string(projection, "status", "current Skill projection")
    require(
        status in {"available", "unavailable", "no_session"},
        f"current Skill projection status is unsupported: {status}",
    )
    projection_keeper = required_string(
        projection, "keeper_name", "current Skill projection"
    )
    require(projection_keeper == keeper, "Skill ledger Keeper differs")
    observation: dict[str, Any] = {
        "status": status,
        "keeper_name": projection_keeper,
    }
    if status == "unavailable":
        observation.update(
            {
                "reason": required_string(
                    projection, "reason", "current Skill projection"
                ),
                "detail": required_string(
                    projection, "detail", "current Skill projection"
                ),
            }
        )
        return observation, None
    if status == "no_session":
        return observation, None

    current = required_object(projection, "ledger", "current Skill projection")
    current_session = required_string(current, "session_id", "Skill ledger projection")
    expected_current = durable_ledger if current_session == trace_id else current
    validated = validate_dashboard_ledger(
        dashboard,
        durable_ledger=expected_current,
        keeper=keeper,
    )
    observation.update(
        {
            "session_id": current_session,
            "revision": required_string(validated, "revision", "Skill ledger"),
        }
    )
    return observation, validated


def validate_effective_keeper_surface(
    dashboard: dict[str, Any],
    *,
    keeper: str,
    expected_runtime_id: str,
) -> dict[str, Any]:
    if "effective_keeper_surface" not in dashboard:
        return {"status": "missing"}
    surface_value = dashboard["effective_keeper_surface"]
    require(
        isinstance(surface_value, dict),
        "effective Keeper surface is not an object",
    )
    surface = cast(dict[str, Any], surface_value)
    status = required_string(surface, "status", "effective Keeper surface")
    require(
        status in {"available", "unavailable", "warming"},
        f"effective Keeper surface status is unsupported: {status}",
    )
    surface_keeper = required_string(surface, "keeper_name", "effective Keeper surface")
    require(surface_keeper == keeper, "effective Keeper surface differs")
    observation: dict[str, Any] = {
        "status": status,
        "keeper_name": surface_keeper,
    }
    if status == "warming":
        return observation
    if status == "unavailable":
        observation.update(
            {
                "reason": required_string(
                    surface, "reason", "effective Keeper surface"
                ),
                "detail": required_string(
                    surface, "detail", "effective Keeper surface"
                ),
            }
        )
        return observation

    runtime_id = required_string(surface, "runtime_id", "effective Keeper surface")
    require(
        runtime_id == expected_runtime_id,
        "effective Keeper surface runtime differs",
    )
    delivery = required_object(surface, "tool_delivery", "effective Keeper surface")
    require(
        delivery.get("status") == "delivered",
        "effective Keeper surface did not deliver tools",
    )
    observation.update(
        {
            "runtime_id": runtime_id,
            "tool_delivery": {"status": "delivered"},
        }
    )
    return observation


def validate_durable_ledger(ledger: dict[str, Any], *, trace_id: str) -> dict[str, Any]:
    require(
        ledger.get("schema") == proof.LEDGER_SCHEMA,
        "durable Skill ledger schema is unsupported",
    )
    require(
        required_string(ledger, "session_id", "durable Skill ledger") == trace_id,
        "durable Skill ledger session differs from producer Turn_ref",
    )
    require(
        required_string(ledger, "revision", "durable Skill ledger")
        == proof.ledger_revision(ledger),
        "durable Skill ledger revision differs from canonical content",
    )
    activations = required_list(ledger, "activations", "durable Skill ledger")
    required_list(ledger, "transition_rejections", "durable Skill ledger")
    for activation in activations:
        require(
            isinstance(activation, dict),
            "durable Skill ledger has untyped activation",
        )
        turn_ref = required_string(activation, "turn_ref", "durable activation")
        try:
            activation_trace, _ = natural_producer.parse_turn_ref(turn_ref)
        except natural_producer.ProducerError as error:
            raise JoinError(
                f"durable activation Turn_ref is invalid: {error}"
            ) from error
        require(
            activation_trace == trace_id,
            "durable activation Turn_ref belongs to another session",
        )
    return ledger


def validate_historical_projection(
    projection: dict[str, Any],
    *,
    durable_ledger: dict[str, Any],
    trace_id: str,
) -> dict[str, Any]:
    require_exact_fields(
        projection,
        {
            "schema",
            "status",
            "trace_id",
            "ledger",
            "summary",
            "scoped_summaries",
        },
        "historical Skill projection",
    )
    require(
        projection.get("schema") == HISTORICAL_PROJECTION_SCHEMA,
        "historical Skill projection schema is unsupported",
    )
    require(
        projection.get("status") == "available",
        "historical Skill projection is unavailable",
    )
    require(
        required_string(projection, "trace_id", "historical Skill projection")
        == trace_id,
        "historical Skill projection trace differs from producer Turn_ref",
    )
    ledger = required_object(projection, "ledger", "historical Skill projection")
    require(
        ledger == durable_ledger,
        "typed historical Skill projection differs from durable ledger",
    )
    activations = required_list(ledger, "activations", "historical Skill ledger")
    rejections = required_list(
        ledger, "transition_rejections", "historical Skill ledger"
    )
    typed_activations = cast(list[dict[str, Any]], activations)
    typed_rejections = cast(list[dict[str, Any]], rejections)
    require(
        required_object(projection, "summary", "historical Skill projection")
        == proof.summarize(typed_activations, typed_rejections),
        "historical Skill summary differs from typed ledger",
    )
    require(
        required_list(projection, "scoped_summaries", "historical Skill projection")
        == proof.scoped_summaries(typed_activations, typed_rejections),
        "historical scoped Skill summaries differ from typed ledger",
    )
    return ledger


def typed_match(activation: dict[str, Any], *, turn_ref: str) -> dict[str, Any]:
    require(activation.get("turn_ref") == turn_ref, "activation turn reference differs")
    source_id, package_id, name, content_revision = proof.reference_key(
        activation, "activation"
    )
    invocation = required_object(activation, "invocation", "activation")
    delivery = activation.get("delivery")
    require(
        delivery is None or isinstance(delivery, dict),
        "activation.delivery is not typed",
    )
    actions = required_list(activation, "actions", "activation")
    require(
        all(isinstance(action, dict) for action in actions),
        "activation has untyped action",
    )
    return {
        "skill_tool_use_id": required_string(
            activation, "skill_tool_use_id", "activation"
        ),
        "turn_ref": turn_ref,
        "snapshot_revision": required_string(
            activation, "snapshot_revision", "activation"
        ),
        "reference": {
            "identity": {
                "source_id": source_id,
                "package_id": package_id,
                "name": name,
            },
            "content_revision": content_revision,
        },
        "invocation_runtime_id": required_string(
            activation, "runtime_id", "activation"
        ),
        "invocation": invocation,
        "delivery": delivery,
        "actions": actions,
    }


def exact_turn_join(*, ledger: dict[str, Any], turn_ref: str) -> dict[str, Any]:
    activations = required_list(ledger, "activations", "Skill ledger")
    matches = [
        typed_match(cast(dict[str, Any], activation), turn_ref=turn_ref)
        for activation in activations
        if isinstance(activation, dict) and activation.get("turn_ref") == turn_ref
    ]
    count = len(matches)
    if count == 0:
        return {
            "kind": "no_skill_observed",
            "match_count": count,
            "matches": matches,
        }
    elif count == 1:
        return {
            "kind": "exact_skill_invocation",
            "match_count": count,
            "selected_skill_tool_use_id": matches[0]["skill_tool_use_id"],
            "matches": matches,
        }
    return {
        "kind": "multiple_skill_activations",
        "match_count": count,
        "selection": {
            "kind": "operator_selection_required",
            "candidate_skill_tool_use_ids": [
                match["skill_tool_use_id"] for match in matches
            ],
        },
        "matches": matches,
    }


def validate_join(
    *,
    receipt: dict[str, Any],
    receipt_raw: bytes,
    expected_receipt_sha256: str,
    source_before: dict[str, Any],
    source_after: dict[str, Any],
    health_before: dict[str, Any],
    health_after: dict[str, Any],
    dashboard_before: dict[str, Any],
    dashboard_after: dict[str, Any],
    historical_before: dict[str, Any],
    historical_after: dict[str, Any],
    durable_ledger: dict[str, Any],
    durable_ledger_after: dict[str, Any],
    durable_ledger_raw: bytes,
    durable_ledger_after_raw: bytes,
) -> dict[str, Any]:
    producer = validate_receipt(
        receipt,
        receipt_raw=receipt_raw,
        expected_receipt_sha256=expected_receipt_sha256,
        source=source_before,
    )
    require(
        source_after == source_before, "join source checkout changed during collection"
    )
    before_identity = health_identity(
        health_before, expected_source_head=producer["source"]["head"]
    )
    after_identity = health_identity(
        health_after, expected_source_head=producer["source"]["head"]
    )
    require(
        before_identity == producer["server"],
        "current server differs from producer server",
    )
    require(after_identity == before_identity, "server restarted during ledger join")
    durable = validate_durable_ledger(durable_ledger, trace_id=producer["trace_id"])
    try:
        decoded_durable = proof.decode_json(
            durable_ledger_raw, "durable Skill ledger bytes before join"
        )
        decoded_durable_after = proof.decode_json(
            durable_ledger_after_raw, "durable Skill ledger bytes after join"
        )
    except proof.ProofError as error:
        raise JoinError(str(error)) from error
    require(
        decoded_durable == durable_ledger,
        "durable Skill ledger object differs from its bytes before join",
    )
    require(
        decoded_durable_after == durable_ledger_after,
        "durable Skill ledger object differs from its bytes after join",
    )
    ledger = validate_historical_projection(
        historical_before,
        durable_ledger=durable,
        trace_id=producer["trace_id"],
    )
    require(
        durable_ledger_after == durable_ledger,
        "durable Skill ledger changed during join",
    )
    require(
        durable_ledger_after_raw == durable_ledger_raw,
        "durable Skill ledger bytes changed during join",
    )
    after_historical_ledger = validate_historical_projection(
        historical_after,
        durable_ledger=durable_ledger_after,
        trace_id=producer["trace_id"],
    )
    require(
        after_historical_ledger == ledger,
        "typed historical Skill projection changed during join",
    )
    expected_runtime_id = required_string(
        receipt, "keeper_declarative_runtime_id", "producer receipt"
    )
    surface_before = validate_effective_keeper_surface(
        dashboard_before,
        keeper=producer["keeper"],
        expected_runtime_id=expected_runtime_id,
    )
    surface_after = validate_effective_keeper_surface(
        dashboard_after,
        keeper=producer["keeper"],
        expected_runtime_id=expected_runtime_id,
    )
    projection_before, current_before = validate_current_skill_projection(
        dashboard_before,
        durable_ledger=ledger,
        keeper=producer["keeper"],
        trace_id=producer["trace_id"],
    )
    projection_after, current_after = validate_current_skill_projection(
        dashboard_after,
        durable_ledger=durable_ledger_after,
        keeper=producer["keeper"],
        trace_id=producer["trace_id"],
    )
    current_ledgers = [
        current for current in (current_before, current_after) if current is not None
    ]
    if current_before is not None and current_after is not None:
        require(
            current_after == current_before,
            "Dashboard ledger changed during join",
        )

    result = exact_turn_join(ledger=ledger, turn_ref=producer["turn_ref"])
    projection_statuses = [projection_before["status"], projection_after["status"]]
    if projection_statuses == ["available", "available"]:
        projected_session = required_string(
            current_ledgers[0], "session_id", "Skill ledger projection"
        )
        dashboard_equals_durable = projected_session == producer["trace_id"]
        dashboard_projection_kind = (
            "exact_session"
            if dashboard_equals_durable
            else "current_session_differs_historical_exact"
        )
    else:
        dashboard_equals_durable = False
        if projection_statuses[0] == projection_statuses[1]:
            dashboard_projection_kind = (
                f"current_projection_{projection_statuses[0]}_historical_exact"
            )
        else:
            dashboard_projection_kind = "current_projection_changed_historical_exact"
    return {
        "producer": producer,
        "server": before_identity,
        "ledger": {
            "schema": ledger["schema"],
            "workspace_key": required_string(ledger, "workspace_key", "Skill ledger"),
            "session_id": required_string(ledger, "session_id", "Skill ledger"),
            "revision": required_string(ledger, "revision", "Skill ledger"),
            "dashboard_equals_durable": dashboard_equals_durable,
            "dashboard_projection_kind": dashboard_projection_kind,
        },
        "current_surface": {
            "before": surface_before,
            "after": surface_after,
        },
        "current_projection": {
            "before": projection_before,
            "after": projection_after,
        },
        "result": result,
    }


def read_durable_ledger(
    *, effective_masc_root: str, session_id: str
) -> tuple[dict[str, Any], bytes, Path]:
    require(
        Path(session_id).name == session_id,
        "Skill session id is not one path component",
    )
    require(
        session_id not in (".", ".."), "Skill session id is not a valid path component"
    )
    traces_root = (Path(effective_masc_root) / "traces").resolve(strict=True)
    ledger_path = traces_root / session_id / "skill-activations.json"
    require(not ledger_path.is_symlink(), "durable Skill ledger must not be a symlink")
    try:
        resolved = ledger_path.resolve(strict=True)
        require(
            resolved.parent.parent == traces_root,
            "durable Skill ledger escapes traces root",
        )
        require(
            stat.S_ISREG(resolved.stat().st_mode),
            "durable Skill ledger must be regular",
        )
        raw = resolved.read_bytes()
    except OSError as error:
        raise JoinError(f"cannot read durable Skill ledger: {error}") from error
    try:
        return proof.decode_json(raw, f"durable Skill ledger {resolved}"), raw, resolved
    except proof.ProofError as error:
        raise JoinError(str(error)) from error


def write_json(path: Path, value: Any) -> bytes:
    raw = (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode()
    path.write_bytes(raw)
    return raw


def write_artifacts(
    root: Path, payloads: dict[str, bytes]
) -> dict[str, dict[str, Any]]:
    artifacts: dict[str, dict[str, Any]] = {}
    for name, payload in payloads.items():
        require(Path(name).name == name, "artifact name is not one path component")
        path = root / name
        path.write_bytes(payload)
        stored = path.read_bytes()
        require(stored == payload, f"stored artifact bytes differ: {name}")
        artifacts[name] = {
            "bytes": len(stored),
            "sha256": proof.digest_bytes(stored),
        }
    return artifacts


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--producer-receipt", type=Path, required=True)
    parser.add_argument("--expected-producer-receipt-sha256", required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--token-file", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=10.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        base_url = proof.canonical_base_url(args.base_url)
        require(args.timeout > 0, "timeout must be positive")
        token = read_token(args.token_file)
        receipt, receipt_raw = load_receipt(
            args.producer_receipt, args.expected_producer_receipt_sha256
        )
        require(not args.out.exists(), f"output path already exists: {args.out}")
        args.out.mkdir(parents=True)
        incomplete = args.out / "INCOMPLETE"
        incomplete.write_text(
            "natural Keeper Skill ledger join is incomplete\n", encoding="utf-8"
        )
        repo = Path(__file__).resolve().parents[3]
        source_before = proof.source_snapshot(repo)
        producer = validate_receipt(
            receipt,
            receipt_raw=receipt_raw,
            expected_receipt_sha256=args.expected_producer_receipt_sha256,
            source=source_before,
        )
        health_url = f"{base_url}/health?full=1"
        dashboard_url = (
            f"{base_url}/api/v1/dashboard/tools?keeper="
            f"{quote(producer['keeper'], safe='')}"
        )
        historical_url = (
            f"{base_url}/api/v1/dashboard/skill-activations?trace_id="
            f"{quote(producer['trace_id'], safe='')}"
        )
        health_before, health_raw = request_json(
            health_url, token=token, timeout=args.timeout
        )
        dashboard_before, dashboard_raw = request_json(
            dashboard_url, token=token, timeout=args.timeout
        )
        historical_before, historical_raw = request_json(
            historical_url, token=token, timeout=args.timeout
        )
        identity = health_identity(
            health_before, expected_source_head=producer["source"]["head"]
        )
        durable, durable_raw, durable_path = read_durable_ledger(
            effective_masc_root=identity["effective_masc_root"],
            session_id=producer["trace_id"],
        )
        dashboard_after, dashboard_after_raw = request_json(
            dashboard_url, token=token, timeout=args.timeout
        )
        historical_after, historical_after_raw = request_json(
            historical_url, token=token, timeout=args.timeout
        )
        durable_after, durable_after_raw, durable_path_after = read_durable_ledger(
            effective_masc_root=identity["effective_masc_root"],
            session_id=producer["trace_id"],
        )
        require(durable_path_after == durable_path, "durable Skill ledger path changed")
        health_after, health_after_raw = request_json(
            health_url, token=token, timeout=args.timeout
        )
        source_after = proof.source_snapshot(repo)
        joined = validate_join(
            receipt=receipt,
            receipt_raw=receipt_raw,
            expected_receipt_sha256=args.expected_producer_receipt_sha256,
            source_before=source_before,
            source_after=source_after,
            health_before=health_before,
            health_after=health_after,
            dashboard_before=dashboard_before,
            dashboard_after=dashboard_after,
            historical_before=historical_before,
            historical_after=historical_after,
            durable_ledger=durable,
            durable_ledger_after=durable_after,
            durable_ledger_raw=durable_raw,
            durable_ledger_after_raw=durable_after_raw,
        )
        artifact_payloads = {
            "producer-receipt.json": receipt_raw,
            "health-before.json": health_raw,
            "health-after.json": health_after_raw,
            "dashboard-tools-before.json": dashboard_raw,
            "dashboard-tools-after.json": dashboard_after_raw,
            "historical-skill-activations-before.json": historical_raw,
            "historical-skill-activations-after.json": historical_after_raw,
            "durable-skill-activations-before.json": durable_raw,
            "durable-skill-activations-after.json": durable_after_raw,
            "source-before.json": (
                json.dumps(source_before, indent=2, sort_keys=True) + "\n"
            ).encode(),
            "source-after.json": (
                json.dumps(source_after, indent=2, sort_keys=True) + "\n"
            ).encode(),
        }
        artifacts = write_artifacts(args.out, artifact_payloads)
        joined.update(
            {
                "schema": JOIN_SCHEMA,
                "generated_at": utc_now(),
                "inputs": {
                    "producer_receipt_sha256": proof.digest_bytes(receipt_raw),
                    "base_url": base_url,
                },
                "durability": {"ledger_path": str(durable_path)},
                "source_snapshots_equal": source_after == source_before,
                "artifacts": artifacts,
            }
        )
        evidence_raw = write_json(args.out / "join.json", joined)
        require(
            proof.source_snapshot(repo) == source_after,
            "join source checkout changed while finalizing artifacts",
        )
        incomplete.unlink()
        print(
            json.dumps(
                {
                    "status": "observed",
                    "evidence": str(args.out / "join.json"),
                    "sha256": proof.digest_bytes(evidence_raw),
                    "match_count": joined["result"]["match_count"],
                    "result_kind": joined["result"]["kind"],
                },
                sort_keys=True,
            )
        )
        return 0
    except (
        JoinError,
        proof.ProofError,
        FileExistsError,
        FileNotFoundError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"natural-keeper-skill-ledger-join: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
