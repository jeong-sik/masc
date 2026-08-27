#!/usr/bin/env python3
"""Capture one exact live Keeper Skill-use proof from the Dashboard projection.

The caller supplies the invocation identity.  This script never selects the
latest activation by time or guesses from Skill names.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from hashlib import sha256
import json
from pathlib import Path
import re
import stat
import subprocess
from typing import Any
import uuid
from urllib.parse import quote, urlsplit, urlunsplit
from urllib.request import Request

import proof_http


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
LEDGER_SCHEMA = "masc.skill-activations/v5"
DASHBOARD_SKILL_RECEIPTS_ROUTE = "#lab?section=tools"


class ProofError(RuntimeError):
    pass


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise ProofError(detail)


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def digest_bytes(value: bytes) -> str:
    return sha256(value).hexdigest()


def source_snapshot(repo: Path) -> dict[str, Any]:
    return {
        "head": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repo, text=True
        ).strip(),
        "tree": subprocess.check_output(
            ["git", "rev-parse", "HEAD^{tree}"], cwd=repo, text=True
        ).strip(),
        "tracked_changes": subprocess.check_output(
            ["git", "status", "--porcelain=v1", "--untracked-files=no"],
            cwd=repo,
            text=True,
        ).splitlines(),
    }


def runtime_instance_id(build: dict[str, Any], context: str) -> str:
    value = string_field(build, "runtime_instance_id", context)
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise ProofError(f"{context}.runtime_instance_id is not a UUID") from error
    require(
        parsed.version == 7 and str(parsed) == value,
        f"{context}.runtime_instance_id is not canonical UUIDv7",
    )
    return value


def validate_tui_build_evidence(
    *,
    manifest_path: Path,
    expected_manifest_sha256: str,
    expected_source_sha: str,
    expected_source_tree: str,
) -> tuple[dict[str, Any], bytes, bytes]:
    require(
        SHA256_RE.fullmatch(expected_manifest_sha256) is not None,
        "expected TUI build evidence SHA is not sha256",
    )
    manifest_raw = manifest_path.read_bytes()
    require(
        digest_bytes(manifest_raw) == expected_manifest_sha256,
        "TUI build evidence does not match the expected SHA",
    )
    manifest = decode_json(manifest_raw, f"TUI build evidence {manifest_path}")
    require(
        manifest.get("schema") == "masc.tui-build-evidence/v1",
        "TUI build evidence schema is unsupported",
    )
    source = object_field(manifest, "source", "TUI build evidence")
    require(
        source.get("head") == expected_source_sha,
        "TUI build source HEAD differs from collector source",
    )
    require(
        source.get("tree") == expected_source_tree,
        "TUI build source tree differs from collector source",
    )
    require(
        source.get("tracked_checkout_clean") is True,
        "TUI build source checkout was not clean",
    )
    artifact = object_field(manifest, "artifact", "TUI build evidence")
    artifact_name = string_field(artifact, "path", "TUI build evidence.artifact")
    require(
        artifact_name == "masc_tui.exe",
        "TUI build artifact path is not canonical",
    )
    artifact_path = (manifest_path.parent / artifact_name).resolve()
    require(
        artifact_path.parent == manifest_path.parent.resolve(),
        "TUI build artifact escapes its evidence root",
    )
    require(not artifact_path.is_symlink(), "TUI build artifact must not be a symlink")
    artifact_raw = artifact_path.read_bytes()
    require(
        artifact.get("bytes") == len(artifact_raw),
        "TUI build artifact byte count differs from build evidence",
    )
    require(
        artifact.get("sha256") == digest_bytes(artifact_raw),
        "TUI build artifact SHA differs from build evidence",
    )
    return manifest, manifest_raw, artifact_raw


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"JSON object repeats field {key}")
        result[key] = value
    return result


def decode_json(payload: bytes, context: str) -> dict[str, Any]:
    try:
        decoded = json.loads(payload, object_pairs_hook=reject_duplicate_keys)
    except ProofError as error:
        raise ProofError(f"{context}: {error}") from error
    except json.JSONDecodeError as error:
        raise ProofError(f"invalid JSON in {context}: {error}") from error
    require(isinstance(decoded, dict), f"{context} is not an object")
    return decoded


def object_field(value: Any, field: str, context: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{context} is not an object")
    child = value.get(field)
    require(isinstance(child, dict), f"{context}.{field} is not an object")
    return child


def list_field(value: Any, field: str, context: str) -> list[Any]:
    require(isinstance(value, dict), f"{context} is not an object")
    child = value.get(field)
    require(isinstance(child, list), f"{context}.{field} is not an array")
    return child


def string_field(value: Any, field: str, context: str) -> str:
    require(isinstance(value, dict), f"{context} is not an object")
    child = value.get(field)
    require(isinstance(child, str) and child != "", f"{context}.{field} is empty")
    return child


def integer_field(value: Any, field: str, context: str) -> int:
    require(isinstance(value, dict), f"{context} is not an object")
    child = value.get(field)
    require(
        isinstance(child, int) and not isinstance(child, bool) and child >= 0,
        f"{context}.{field} is not a nonnegative integer",
    )
    return child


def canonical_base_url(value: str) -> str:
    parsed = urlsplit(value)
    require(parsed.scheme in ("http", "https"), "base URL must use http or https")
    require(parsed.netloc != "", "base URL must have a host")
    require(
        parsed.username is None and parsed.password is None,
        "base URL must not contain credentials",
    )
    require(
        parsed.query == "" and parsed.fragment == "", "base URL has query or fragment"
    )
    path = parsed.path.rstrip("/")
    return urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


def read_token(path: Path) -> str:
    require(not path.is_symlink(), "token file must not be a symlink")
    try:
        require(stat.S_ISREG(path.stat().st_mode), "token file must be regular")
        token = path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise ProofError(f"cannot read token file: {error}") from error
    require(token != "", "token file is empty")
    require("\r" not in token and "\n" not in token, "token file has multiple lines")
    return token


def auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def dashboard_context_options() -> dict[str, Any]:
    return {
        "viewport": {"width": 1440, "height": 1000},
        "device_scale_factor": 1,
    }


def handle_dashboard_route(route: Any, *, base_url: str, token: str) -> None:
    request_url = route.request.url
    headers = proof_http.scoped_bearer_headers(
        base_url=base_url,
        request_url=request_url,
        headers=route.request.headers,
        token=token,
    )
    if not proof_http.same_origin(request_url, base_url):
        route.continue_(headers=headers)
        return
    response = route.fetch(headers=headers, max_redirects=0)
    if 300 <= response.status < 400:
        route.abort("blockedbyclient")
        return
    route.fulfill(response=response)


def read_json(url: str, timeout: float, token: str) -> tuple[dict[str, Any], bytes]:
    request = Request(
        url, headers={"Accept": "application/json", **auth_headers(token)}
    )
    try:
        with proof_http.open_no_redirect(request, timeout=timeout) as response:
            payload = response.read()
    except OSError as error:
        raise ProofError(f"cannot read {url}: {error}") from error
    return decode_json(payload, f"response from {url}"), payload


def reference_key(value: dict[str, Any], context: str) -> tuple[str, str, str, str]:
    identity = object_field(value, "identity", context)
    revision = string_field(value, "content_revision", context)
    require(
        SHA256_RE.fullmatch(revision) is not None,
        f"{context}.content_revision is not sha256",
    )
    return (
        string_field(identity, "source_id", f"{context}.identity"),
        string_field(identity, "package_id", f"{context}.identity"),
        string_field(identity, "name", f"{context}.identity"),
        revision,
    )


def scope_matches_activation(scope: dict[str, Any], activation: dict[str, Any]) -> bool:
    reference = object_field(scope, "reference", "scoped summary scope")
    return (
        string_field(scope, "snapshot_revision", "scoped summary scope")
        == string_field(activation, "snapshot_revision", "activation")
        and string_field(scope, "turn_ref", "scoped summary scope")
        == string_field(activation, "turn_ref", "activation")
        and string_field(scope, "invocation_runtime_id", "scoped summary scope")
        == string_field(activation, "runtime_id", "activation")
        and reference_key(reference, "scoped summary reference")
        == reference_key(activation, "activation")
    )


def empty_summary(invalid_transitions: int) -> dict[str, int]:
    return {
        "instruction_invocations": 0,
        "skill_bodies_served": 0,
        "skill_resources_served": 0,
        "instruction_provider_deliveries": 0,
        "instruction_official_client_handoffs": 0,
        "instruction_actions_observed": 0,
        "composition_invocations": 0,
        "composition_provider_deliveries": 0,
        "composition_official_client_handoffs": 0,
        "composition_actions_observed": 0,
        "invalid_transitions": invalid_transitions,
    }


def summarize(
    activations: list[dict[str, Any]], transition_rejections: list[dict[str, Any]]
) -> dict[str, int]:
    summary = empty_summary(len(transition_rejections))
    for activation in activations:
        invocation = object_field(activation, "invocation", "activation")
        provider_delivery = 0
        official_handoff = 0
        delivery = activation.get("delivery")
        if isinstance(delivery, dict):
            boundary = object_field(delivery, "boundary", "activation.delivery")
            if boundary.get("kind") == "model_response":
                provider_delivery = 1
            elif boundary.get("kind") == "official_client_result_handoff":
                official_handoff = 1
        action_count = len(list_field(activation, "actions", "activation"))
        if invocation.get("kind") == "instruction":
            served = object_field(invocation, "served_content", "activation.invocation")
            summary["instruction_invocations"] += 1
            if served.get("kind") == "skill_body":
                summary["skill_bodies_served"] += 1
            elif served.get("kind") == "skill_resource":
                summary["skill_resources_served"] += 1
            summary["instruction_provider_deliveries"] += provider_delivery
            summary["instruction_official_client_handoffs"] += official_handoff
            summary["instruction_actions_observed"] += action_count
        elif invocation.get("kind") == "composition":
            summary["composition_invocations"] += 1
            summary["composition_provider_deliveries"] += provider_delivery
            summary["composition_official_client_handoffs"] += official_handoff
            summary["composition_actions_observed"] += action_count
    return summary


def runtime_counts(runtime_ids: list[str]) -> list[dict[str, Any]]:
    counts: list[dict[str, Any]] = []
    for runtime_id in runtime_ids:
        known = next(
            (entry for entry in counts if entry["runtime_id"] == runtime_id), None
        )
        if known is None:
            counts.append({"runtime_id": runtime_id, "count": 1})
        else:
            known["count"] += 1
    return counts


def scope_key(activation: dict[str, Any]) -> tuple[str, ...]:
    source_id, package_id, name, content_revision = reference_key(
        activation, "activation"
    )
    return (
        string_field(activation, "snapshot_revision", "activation"),
        string_field(activation, "turn_ref", "activation"),
        string_field(activation, "runtime_id", "activation"),
        source_id,
        package_id,
        name,
        content_revision,
    )


def scoped_summaries(
    activations: list[dict[str, Any]], transition_rejections: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    grouped: list[tuple[tuple[str, ...], list[dict[str, Any]]]] = []
    for activation in activations:
        key = scope_key(activation)
        known = next((items for known_key, items in grouped if known_key == key), None)
        if known is None:
            grouped.append((key, [activation]))
        else:
            known.append(activation)

    results: list[dict[str, Any]] = []
    for key, scoped_activations in grouped:
        invocation_ids = {
            string_field(activation, "skill_tool_use_id", "activation")
            for activation in scoped_activations
        }
        scoped_rejections = [
            rejection
            for rejection in transition_rejections
            if rejection.get("skill_tool_use_id") in invocation_ids
        ]
        provider_runtimes: list[str] = []
        handoff_runtimes: list[str] = []
        action_runtimes: list[str] = []
        for activation in scoped_activations:
            delivery = activation.get("delivery")
            if isinstance(delivery, dict):
                boundary = object_field(delivery, "boundary", "activation.delivery")
                runtime_id = string_field(delivery, "runtime_id", "activation.delivery")
                if boundary.get("kind") == "model_response":
                    provider_runtimes.append(runtime_id)
                elif boundary.get("kind") == "official_client_result_handoff":
                    handoff_runtimes.append(runtime_id)
            for action in list_field(activation, "actions", "activation"):
                require(isinstance(action, dict), "activation action is not an object")
                action_runtimes.append(string_field(action, "runtime_id", "action"))
        (
            snapshot_revision,
            turn_ref,
            runtime_id,
            source_id,
            package_id,
            name,
            revision,
        ) = key
        results.append(
            {
                "scope": {
                    "snapshot_revision": snapshot_revision,
                    "turn_ref": turn_ref,
                    "invocation_runtime_id": runtime_id,
                    "reference": {
                        "identity": {
                            "source_id": source_id,
                            "package_id": package_id,
                            "name": name,
                        },
                        "content_revision": revision,
                    },
                },
                "summary": summarize(scoped_activations, scoped_rejections),
                "provider_delivery_runtime_counts": runtime_counts(provider_runtimes),
                "official_client_handoff_runtime_counts": runtime_counts(
                    handoff_runtimes
                ),
                "action_runtime_counts": runtime_counts(action_runtimes),
            }
        )
    return results


def ledger_revision(ledger: dict[str, Any]) -> str:
    canonical = {
        "workspace_key": string_field(ledger, "workspace_key", "skill ledger"),
        "session_id": string_field(ledger, "session_id", "skill ledger"),
        "activations": list_field(ledger, "activations", "skill ledger"),
        "transition_rejections": list_field(
            ledger, "transition_rejections", "skill ledger"
        ),
    }
    payload = json.dumps(canonical, ensure_ascii=False, separators=(",", ":")).encode()
    return digest_bytes(payload)


def validate_proof(
    *,
    health: dict[str, Any],
    dashboard: dict[str, Any],
    durable_ledger: dict[str, Any],
    keeper: str,
    expected_source_sha: str,
    skill_tool_use_id: str,
) -> dict[str, Any]:
    require(
        GIT_COMMIT_RE.fullmatch(expected_source_sha) is not None,
        "expected source SHA is invalid",
    )
    require(health.get("health_detail") == "full", "health response is not full")
    build = object_field(health, "build", "health")
    require(
        string_field(build, "binary_commit_source", "health.build") == "embedded",
        "live binary commit is not embedded",
    )
    require(
        string_field(build, "binary_commit", "health.build") == expected_source_sha,
        "live binary commit does not match expected source SHA",
    )
    source_fingerprint = string_field(build, "source_fingerprint", "health.build")
    require(
        SHA256_RE.fullmatch(source_fingerprint) is not None,
        "live source fingerprint is not SHA-256",
    )
    executable_sha256 = string_field(build, "executable_sha256", "health.build")
    require(
        SHA256_RE.fullmatch(executable_sha256) is not None,
        "live executable digest is not SHA-256",
    )
    runtime_instance_id(build, "health.build")
    string_field(build, "started_at", "health.build")

    surface = object_field(dashboard, "effective_keeper_surface", "dashboard")
    require(
        surface.get("status") == "available",
        "effective Keeper surface is not available",
    )
    require(
        surface.get("keeper_name") == keeper,
        "effective Keeper surface belongs to another Keeper",
    )

    projection = object_field(dashboard, "skill_activations", "dashboard")
    require(
        projection.get("status") == "available",
        "Skill activation projection is not available",
    )
    require(
        projection.get("keeper_name") == keeper,
        "Skill activation projection belongs to another Keeper",
    )
    ledger = object_field(projection, "ledger", "skill_activations")
    require(
        ledger.get("schema") == LEDGER_SCHEMA,
        f"Skill ledger schema is not {LEDGER_SCHEMA}",
    )
    require(
        durable_ledger == ledger, "Dashboard ledger does not equal the durable ledger"
    )
    require(
        string_field(ledger, "revision", "skill ledger") == ledger_revision(ledger),
        "Skill ledger revision does not match its canonical content",
    )
    activations = list_field(ledger, "activations", "skill ledger")
    require(
        all(isinstance(activation, dict) for activation in activations),
        "Skill ledger contains a non-object activation",
    )
    typed_activations = [
        activation for activation in activations if isinstance(activation, dict)
    ]
    rejections = list_field(ledger, "transition_rejections", "skill ledger")
    require(
        all(isinstance(rejection, dict) for rejection in rejections),
        "Skill ledger contains a non-object transition rejection",
    )
    typed_rejections = [
        rejection for rejection in rejections if isinstance(rejection, dict)
    ]
    require(typed_rejections == [], "Skill ledger has rejected transitions")
    require(
        object_field(projection, "summary", "skill_activations")
        == summarize(typed_activations, typed_rejections),
        "Dashboard session summary does not match the Skill ledger",
    )
    expected_scoped = scoped_summaries(typed_activations, typed_rejections)
    require(
        list_field(projection, "scoped_summaries", "skill_activations")
        == expected_scoped,
        "Dashboard scoped summaries do not match the Skill ledger",
    )

    matches = [
        activation
        for activation in typed_activations
        if activation.get("skill_tool_use_id") == skill_tool_use_id
    ]
    require(len(matches) == 1, f"expected one exact activation, found {len(matches)}")
    activation = matches[0]
    invocation = object_field(activation, "invocation", "activation")
    require(
        invocation.get("kind") == "instruction",
        "exact activation is not keeper_skill instruction use",
    )
    served = object_field(invocation, "served_content", "activation.invocation")
    require(
        served.get("kind") == "skill_body",
        "exact activation did not serve a Skill body",
    )
    require(
        integer_field(served, "bytes", "served Skill body") > 0,
        "served Skill body is empty",
    )
    served_digest = string_field(served, "sha256", "served Skill body")
    require(
        SHA256_RE.fullmatch(served_digest) is not None,
        "served Skill body digest is invalid",
    )

    delivery = activation.get("delivery")
    require(isinstance(delivery, dict), "exact activation has no verified delivery")
    boundary = object_field(delivery, "boundary", "activation.delivery")
    require(
        boundary.get("kind") in ("model_response", "official_client_result_handoff"),
        "exact activation has an unsupported delivery boundary",
    )
    require(
        integer_field(delivery, "content_bytes", "activation.delivery")
        == integer_field(served, "bytes", "served Skill body"),
        "delivered Skill content byte count differs from the served body",
    )
    require(
        string_field(delivery, "content_sha256", "activation.delivery")
        == served_digest,
        "delivered Skill content digest differs from the served body",
    )
    actions = list_field(activation, "actions", "activation")
    require(len(actions) >= 1, "exact activation has no later model-selected action")
    for index, action in enumerate(actions):
        require(
            isinstance(action, dict), f"activation.actions[{index}] is not an object"
        )
        identity = object_field(action, "identity", f"activation.actions[{index}]")
        require(
            identity.get("kind") in ("call_id", "provider_step"),
            f"activation.actions[{index}] has unsupported identity",
        )

    scoped = [
        item
        for item in expected_scoped
        if isinstance(item, dict)
        and scope_matches_activation(
            object_field(item, "scope", "scoped summary"), activation
        )
    ]
    require(len(scoped) == 1, f"expected one exact scoped summary, found {len(scoped)}")
    scoped_summary = object_field(scoped[0], "summary", "scoped summary")
    require(
        integer_field(scoped_summary, "instruction_invocations", "scoped summary") >= 1,
        "scoped invocation count is zero",
    )
    require(
        integer_field(scoped_summary, "instruction_actions_observed", "scoped summary")
        >= 1,
        "scoped action count is zero",
    )
    require(
        integer_field(scoped_summary, "invalid_transitions", "scoped summary") == 0,
        "scoped summary has invalid transitions",
    )
    delivery_count = integer_field(
        scoped_summary, "instruction_provider_deliveries", "scoped summary"
    ) + integer_field(
        scoped_summary, "instruction_official_client_handoffs", "scoped summary"
    )
    require(delivery_count >= 1, "scoped delivery count is zero")

    return {
        "keeper": keeper,
        "skill_tool_use_id": skill_tool_use_id,
        "workspace_key": string_field(ledger, "workspace_key", "skill ledger"),
        "session_id": string_field(ledger, "session_id", "skill ledger"),
        "ledger_revision": string_field(ledger, "revision", "skill ledger"),
        "source_fingerprint": source_fingerprint,
        "executable_sha256": executable_sha256,
        "reference": {
            "source_id": reference_key(activation, "activation")[0],
            "package_id": reference_key(activation, "activation")[1],
            "name": reference_key(activation, "activation")[2],
            "content_revision": reference_key(activation, "activation")[3],
        },
        "snapshot_revision": string_field(
            activation, "snapshot_revision", "activation"
        ),
        "turn_ref": string_field(activation, "turn_ref", "activation"),
        "invocation_runtime_id": string_field(activation, "runtime_id", "activation"),
        "delivery": delivery,
        "actions": actions,
        "scoped_summary": scoped[0],
    }


def capture_dashboard_page(
    *,
    page: Any,
    dashboard_url: str,
    keeper: str,
    skill_tool_use_id: str,
    ledger_revision: str,
    screenshot: Path,
) -> None:
    page.goto(dashboard_url, wait_until="networkidle", timeout=60_000)
    keeper_select = page.get_by_role("combobox", name="Keeper", exact=True)
    require(
        keeper_select.count() == 1,
        "Dashboard does not contain exactly one Keeper selector",
    )
    keeper_select.select_option(value=keeper)
    require(
        keeper_select.input_value() == keeper,
        "Dashboard did not select the exact Keeper value",
    )
    panel = page.locator('[data-testid="skill-activation-ledger"]')
    panel.wait_for(state="visible", timeout=30_000)
    page.wait_for_function(
        """([selector, keeper, revision]) => {
          const panel = document.querySelector(selector);
          return panel !== null
            && panel.getAttribute('data-keeper-name') === keeper
            && panel.getAttribute('data-ledger-revision') === revision;
        }""",
        arg=[
            '[data-testid="skill-activation-ledger"]',
            keeper,
            ledger_revision,
        ],
        timeout=30_000,
    )
    require(
        panel.get_attribute("data-keeper-name") == keeper,
        "Dashboard panel belongs to another Keeper after selection",
    )
    require(
        panel.get_attribute("data-ledger-revision") == ledger_revision,
        "Dashboard advanced to another ledger revision during capture",
    )
    rows = panel.locator('[data-testid="skill-activation-row"]')
    row_ids = rows.evaluate_all(
        "rows => rows.map(row => row.getAttribute('data-skill-tool-use-id'))"
    )
    require(
        row_ids.count(skill_tool_use_id) == 1,
        "Dashboard does not contain exactly one exact Skill invocation row",
    )
    matching_rows = [
        row
        for row in rows.element_handles()
        if row.get_attribute("data-skill-tool-use-id") == skill_tool_use_id
    ]
    require(
        len(matching_rows) == 1,
        "Dashboard exact Skill invocation row became ambiguous",
    )
    exact_row = matching_rows[0]
    exact_row.scroll_into_view_if_needed()
    require(
        exact_row.is_visible(),
        "Dashboard exact Skill invocation row is not visible for capture",
    )
    require(
        panel.get_attribute("data-keeper-name") == keeper,
        "Dashboard panel changed Keeper before taking the screenshot",
    )
    require(
        panel.get_attribute("data-ledger-revision") == ledger_revision,
        "Dashboard ledger revision changed before taking the screenshot",
    )
    require(
        exact_row.get_attribute("data-skill-tool-use-id") == skill_tool_use_id,
        "Dashboard exact Skill invocation row changed before capture",
    )
    panel.screenshot(path=str(screenshot))
    require(
        panel.get_attribute("data-keeper-name") == keeper,
        "Dashboard panel changed Keeper while taking the screenshot",
    )
    require(
        panel.get_attribute("data-ledger-revision") == ledger_revision,
        "Dashboard ledger revision changed while taking the screenshot",
    )
    require(
        exact_row.get_attribute("data-skill-tool-use-id") == skill_tool_use_id,
        "Dashboard exact Skill invocation row changed while taking the screenshot",
    )
    after_row_ids = rows.evaluate_all(
        "rows => rows.map(row => row.getAttribute('data-skill-tool-use-id'))"
    )
    require(
        after_row_ids == row_ids,
        "Dashboard activation rows changed while taking the screenshot",
    )


def capture_dashboard(
    *,
    base_url: str,
    keeper: str,
    skill_tool_use_id: str,
    ledger_revision: str,
    output: Path,
    token: str,
) -> dict[str, Any]:
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as error:
        raise ProofError("Playwright is required for Dashboard capture") from error

    screenshot = output / "dashboard-skill-use.png"
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        context = None
        try:
            context = browser.new_context(**dashboard_context_options())
            context.route(
                "**/*",
                lambda route: handle_dashboard_route(
                    route, base_url=base_url, token=token
                ),
            )
            page = context.new_page()
            capture_dashboard_page(
                page=page,
                dashboard_url=(
                    f"{base_url}/dashboard/{DASHBOARD_SKILL_RECEIPTS_ROUTE}"
                ),
                keeper=keeper,
                skill_tool_use_id=skill_tool_use_id,
                ledger_revision=ledger_revision,
                screenshot=screenshot,
            )
        finally:
            if context is not None:
                context.close()
            browser.close()
    payload = screenshot.read_bytes()
    return {
        "path": screenshot.name,
        "bytes": len(payload),
        "sha256": digest_bytes(payload),
        "route": DASHBOARD_SKILL_RECEIPTS_ROUTE,
        "keeper": keeper,
        "ledger_revision": ledger_revision,
        "exact_row": skill_tool_use_id,
    }


def write_json(path: Path, value: Any) -> bytes:
    payload = (
        json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    ).encode()
    path.write_bytes(payload)
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--token-file", required=True, type=Path)
    parser.add_argument("--keeper", required=True)
    parser.add_argument("--expected-source-sha", required=True)
    parser.add_argument("--tui-build-evidence", required=True, type=Path)
    parser.add_argument("--expected-tui-build-evidence-sha256", required=True)
    parser.add_argument("--skill-tool-use-id", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()

    base_url = canonical_base_url(args.base_url)
    token = read_token(args.token_file)
    require(args.timeout > 0, "timeout must be positive")
    require(not args.out.exists(), f"output path already exists: {args.out}")
    repo = Path(__file__).resolve().parents[3]
    source_before = source_snapshot(repo)
    require(
        source_before["tracked_changes"] == [],
        f"collector checkout has tracked changes: {source_before['tracked_changes']}",
    )
    require(
        source_before["head"] == args.expected_source_sha,
        "collector source HEAD does not match expected source SHA",
    )
    tui_build, tui_build_raw, tui_executable_raw = validate_tui_build_evidence(
        manifest_path=args.tui_build_evidence,
        expected_manifest_sha256=args.expected_tui_build_evidence_sha256,
        expected_source_sha=args.expected_source_sha,
        expected_source_tree=source_before["tree"],
    )

    health, health_raw = read_json(f"{base_url}/health?full=1", args.timeout, token)
    dashboard_url = (
        f"{base_url}/api/v1/dashboard/tools?keeper={quote(args.keeper, safe='')}"
    )
    dashboard, dashboard_raw = read_json(dashboard_url, args.timeout, token)
    projection = object_field(dashboard, "skill_activations", "dashboard")
    ledger = object_field(projection, "ledger", "skill_activations")
    session_id = string_field(ledger, "session_id", "skill ledger")
    require(Path(session_id).name == session_id, "session id is not one path component")
    paths = object_field(health, "paths", "health")
    effective_base_path = string_field(paths, "effective_base_path", "health.paths")
    effective_masc_root = string_field(paths, "effective_masc_root", "health.paths")
    masc_root = Path(effective_masc_root)
    ledger_path = masc_root / "traces" / session_id / "skill-activations.json"
    try:
        durable_raw = ledger_path.read_bytes()
    except OSError as error:
        raise ProofError(
            f"cannot read durable Skill ledger {ledger_path}: {error}"
        ) from error
    durable_ledger = decode_json(durable_raw, f"durable Skill ledger {ledger_path}")

    proof = validate_proof(
        health=health,
        dashboard=dashboard,
        durable_ledger=durable_ledger,
        keeper=args.keeper,
        expected_source_sha=args.expected_source_sha,
        skill_tool_use_id=args.skill_tool_use_id,
    )

    args.out.mkdir(parents=True)
    incomplete = args.out / "INCOMPLETE"
    incomplete.write_text(
        "This directory is not evidence until evidence.json exists and this marker is removed.\n",
        encoding="utf-8",
    )
    health_file = write_json(args.out / "health.json", health)
    dashboard_file = write_json(args.out / "dashboard-tools.json", dashboard)
    (args.out / "skill-activations.json").write_bytes(durable_raw)
    (args.out / "tui-build-evidence.json").write_bytes(tui_build_raw)
    copied_tui = args.out / "masc_tui.exe"
    copied_tui.write_bytes(tui_executable_raw)
    copied_tui.chmod(
        copied_tui.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
    )
    dashboard_capture = capture_dashboard(
        base_url=base_url,
        keeper=args.keeper,
        skill_tool_use_id=args.skill_tool_use_id,
        ledger_revision=proof["ledger_revision"],
        output=args.out,
        token=token,
    )
    source_after = source_snapshot(repo)
    require(
        source_after == source_before,
        "collector source checkout changed during proof capture",
    )
    evidence = {
        "schema": "masc.keeper-skill-use-proof.v2",
        "generated_at": utc_now(),
        "source": {
            "expected_sha": args.expected_source_sha,
            "collector_head": source_before["head"],
            "collector_tree": source_before["tree"],
            "tracked_checkout_clean": True,
            "binary_commit": object_field(health, "build", "health").get(
                "binary_commit"
            ),
            "binary_commit_source": object_field(health, "build", "health").get(
                "binary_commit_source"
            ),
            "source_fingerprint": proof["source_fingerprint"],
            "executable_sha256": proof["executable_sha256"],
            "server_started_at": string_field(
                object_field(health, "build", "health"),
                "started_at",
                "health.build",
            ),
            "server_runtime_instance_id": runtime_instance_id(
                object_field(health, "build", "health"), "health.build"
            ),
            "tui_build": {
                "manifest_sha256": digest_bytes(tui_build_raw),
                "executable_sha256": digest_bytes(tui_executable_raw),
                "executable_bytes": len(tui_executable_raw),
                "producer": object_field(
                    object_field(tui_build, "build", "TUI build evidence"),
                    "producer",
                    "TUI build evidence.build",
                ),
            },
        },
        "runtime": {
            "base_url": base_url,
            "effective_base_path": effective_base_path,
            "effective_masc_root": effective_masc_root,
        },
        "proof": proof,
        "durability": {
            "ledger_path": str(ledger_path),
            "ledger_sha256": digest_bytes(durable_raw),
            "ledger_bytes": len(durable_raw),
            "dashboard_projection_equals_ledger": True,
        },
        "dashboard": dashboard_capture,
        "artifacts": {
            "health.json": {
                "bytes": len(health_file),
                "sha256": digest_bytes(health_file),
            },
            "dashboard-tools.json": {
                "bytes": len(dashboard_file),
                "sha256": digest_bytes(dashboard_file),
            },
            "skill-activations.json": {
                "bytes": len(durable_raw),
                "sha256": digest_bytes(durable_raw),
            },
            "tui-build-evidence.json": {
                "bytes": len(tui_build_raw),
                "sha256": digest_bytes(tui_build_raw),
            },
            "masc_tui.exe": {
                "bytes": len(tui_executable_raw),
                "sha256": digest_bytes(tui_executable_raw),
            },
        },
        "responses": {
            "health_sha256": digest_bytes(health_raw),
            "dashboard_tools_sha256": digest_bytes(dashboard_raw),
        },
        "boundary": {
            "tui_capture": "required separately from the same server, Keeper session, and invocation id",
            "private_reasoning": "not claimed; later action proves ordering and context availability only",
        },
    }
    evidence_raw = write_json(args.out / "evidence.json", evidence)
    require(
        source_snapshot(repo) == source_before,
        "collector source checkout changed while finalizing proof",
    )
    incomplete.unlink()
    print(
        json.dumps(
            {
                "status": "passed",
                "evidence": str(args.out / "evidence.json"),
                "sha256": digest_bytes(evidence_raw),
                "keeper": args.keeper,
                "skill_tool_use_id": args.skill_tool_use_id,
                "actions": len(proof["actions"]),
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ProofError as error:
        print(f"keeper-skill-use-proof: {error}")
        raise SystemExit(1) from error
