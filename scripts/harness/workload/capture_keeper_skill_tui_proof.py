#!/usr/bin/env python3
"""Capture the TUI half of an exact Keeper Skill-use proof bundle."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import subprocess
import time
from typing import Any, Iterator
from urllib.parse import quote, urlsplit, urlunsplit
from urllib.request import Request

import proof_http


REQUIRED_PRODUCER_ARTIFACTS = {
    "health.json",
    "dashboard-tools.json",
    "skill-activations.json",
    "tui-build-evidence.json",
    "masc_tui.exe",
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class CaptureError(RuntimeError):
    pass


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise CaptureError(detail)


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def digest_bytes(value: bytes) -> str:
    return sha256(value).hexdigest()


def require_expected_digest(payload: bytes, expected_sha256: str, context: str) -> None:
    require(
        SHA256_RE.fullmatch(expected_sha256) is not None,
        f"expected {context} SHA is not sha256",
    )
    require(
        digest_bytes(payload) == expected_sha256,
        f"{context} does not match the expected SHA",
    )


def canonical_local_base_url(value: str) -> str:
    parsed = urlsplit(value)
    require(parsed.scheme == "http", "masc-tui proof requires a local HTTP runtime")
    require(parsed.hostname is not None, "proof base URL has no host")
    require(
        parsed.username is None and parsed.password is None,
        "proof base URL must not contain credentials",
    )
    require(
        parsed.query == "" and parsed.fragment == "",
        "proof base URL has query or fragment",
    )
    path = parsed.path.rstrip("/")
    return urlunsplit(("http", parsed.netloc, path, "", ""))


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


def scrubbed_probe_environment() -> dict[str, str]:
    return {
        key: os.environ[key]
        for key in ("PATH", "LANG", "LC_ALL", "TERM")
        if key in os.environ
    }


def decode_object(payload: bytes, context: str) -> dict[str, Any]:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            require(key not in result, f"{context} repeats field {key}")
            result[key] = value
        return result

    try:
        decoded = json.loads(payload, object_pairs_hook=reject_duplicates)
    except json.JSONDecodeError as error:
        raise CaptureError(f"invalid JSON in {context}: {error}") from error
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
    child = value.get(field)
    require(
        isinstance(child, int) and not isinstance(child, bool),
        f"{context}.{field} is not an integer",
    )
    return child


def read_token(path: Path) -> str:
    require(not path.is_symlink(), "token file must not be a symlink")
    try:
        require(stat.S_ISREG(path.stat().st_mode), "token file must be regular")
        token = path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise CaptureError(f"cannot read token file: {error}") from error
    require(token != "", "token file is empty")
    require("\r" not in token and "\n" not in token, "token file has multiple lines")
    return token


def auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def read_json_url(url: str, timeout: float, token: str) -> dict[str, Any]:
    request = Request(
        url, headers={"Accept": "application/json", **auth_headers(token)}
    )
    try:
        with proof_http.open_no_redirect(request, timeout=timeout) as response:
            return decode_object(response.read(), f"response from {url}")
    except OSError as error:
        raise CaptureError(f"cannot read {url}: {error}") from error


def action_marker(action: dict[str, Any]) -> str:
    identity = object_field(action, "identity", "proof action")
    kind = identity.get("kind")
    if kind == "call_id":
        return "call=" + string_field(identity, "call_id", "proof action identity")
    if kind == "provider_step":
        conversation = string_field(
            identity, "conversation_id", "proof action identity"
        )
        index = identity.get("step_index")
        require(
            isinstance(index, int) and not isinstance(index, bool) and index >= 0,
            "proof action step_index is invalid",
        )
        return f"step={conversation}:{index}"
    raise CaptureError("proof action identity is unsupported")


def validate_bundle(
    *,
    evidence: dict[str, Any],
    dashboard_payload: bytes,
    dashboard: dict[str, Any],
    source_head: str,
    source_tree: str,
    tracked_checkout_clean: bool,
) -> dict[str, Any]:
    require(
        evidence.get("schema") == "masc.keeper-skill-use-proof.v2",
        "input is not a Keeper Skill-use proof bundle",
    )
    source = object_field(evidence, "source", "evidence")
    expected_sha = string_field(source, "expected_sha", "evidence.source")
    expected_tree = string_field(source, "collector_tree", "evidence.source")
    require(
        source_head == expected_sha, "capture source HEAD differs from proof source"
    )
    require(
        source_tree == expected_tree, "capture source tree differs from proof source"
    )
    require(
        source.get("tracked_checkout_clean") is True, "producer checkout was not clean"
    )
    require(tracked_checkout_clean, "capture checkout has tracked changes")
    artifacts = object_field(evidence, "artifacts", "evidence")
    dashboard_artifact = object_field(
        artifacts, "dashboard-tools.json", "evidence.artifacts"
    )
    require(
        dashboard_artifact.get("bytes") == len(dashboard_payload),
        "dashboard-tools.json byte count differs from proof manifest",
    )
    require(
        dashboard_artifact.get("sha256") == digest_bytes(dashboard_payload),
        "dashboard-tools.json SHA differs from proof manifest",
    )

    proof = object_field(evidence, "proof", "evidence")
    keeper = string_field(proof, "keeper", "evidence.proof")
    session_id = string_field(proof, "session_id", "evidence.proof")
    ledger_revision = string_field(proof, "ledger_revision", "evidence.proof")
    skill_tool_use_id = string_field(proof, "skill_tool_use_id", "evidence.proof")
    actions = list_field(proof, "actions", "evidence.proof")
    require(actions != [], "proof has no action identity for the TUI")
    action_markers = [
        action_marker(action) for action in actions if isinstance(action, dict)
    ]
    require(len(action_markers) == len(actions), "proof contains a non-object action")

    projection = object_field(dashboard, "skill_activations", "dashboard tools")
    ledger = object_field(projection, "ledger", "dashboard tools Skill projection")
    require(
        projection.get("keeper_name") == keeper,
        "dashboard tools belongs to another Keeper",
    )
    require(
        ledger.get("session_id") == session_id,
        "dashboard tools session differs from proof",
    )
    require(
        ledger.get("revision") == ledger_revision,
        "dashboard tools ledger differs from proof",
    )
    exact = [
        activation
        for activation in list_field(ledger, "activations", "Skill ledger")
        if isinstance(activation, dict)
        and activation.get("skill_tool_use_id") == skill_tool_use_id
    ]
    require(len(exact) == 1, f"dashboard tools has {len(exact)} exact activation rows")
    require(
        exact[0].get("actions") == actions,
        "proof action identities differ from the exact Dashboard activation",
    )
    surface = object_field(dashboard, "effective_keeper_surface", "dashboard tools")
    require(
        surface.get("keeper_name") == keeper,
        "effective surface belongs to another Keeper",
    )

    runtime = object_field(evidence, "runtime", "evidence")
    return {
        "expected_sha": expected_sha,
        "source_tree": expected_tree,
        "base_url": canonical_local_base_url(
            string_field(runtime, "base_url", "evidence.runtime")
        ),
        "base_path": string_field(runtime, "effective_base_path", "evidence.runtime"),
        "keeper": keeper,
        "session_id": session_id,
        "ledger_revision": ledger_revision,
        "skill_tool_use_id": skill_tool_use_id,
        "activation": exact[0],
        "actions": actions,
        "action_markers": action_markers,
    }


def verify_producer_artifacts(
    evidence: dict[str, Any], producer_root: Path
) -> dict[str, dict[str, Any]]:
    artifacts = object_field(evidence, "artifacts", "evidence")
    require(
        set(artifacts) == REQUIRED_PRODUCER_ARTIFACTS,
        "producer artifact set differs from the required v1 set",
    )
    verified: dict[str, dict[str, Any]] = {}
    root = producer_root.resolve()
    require(not (root / "INCOMPLETE").exists(), "producer proof bundle is incomplete")
    for name, expected in artifacts.items():
        require(
            isinstance(name, str) and Path(name).name == name,
            "producer artifact name is not one path component",
        )
        require(
            isinstance(expected, dict), f"producer artifact {name} is not an object"
        )
        path = (root / name).resolve()
        require(path.parent == root, f"producer artifact escapes its root: {name}")
        payload = path.read_bytes()
        require(
            expected.get("bytes") == len(payload),
            f"producer artifact byte mismatch: {name}",
        )
        require(
            expected.get("sha256") == digest_bytes(payload),
            f"producer artifact SHA mismatch: {name}",
        )
        verified[name] = {"bytes": len(payload), "sha256": digest_bytes(payload)}

    dashboard_capture = object_field(evidence, "dashboard", "evidence")
    screenshot_name = string_field(dashboard_capture, "path", "evidence.dashboard")
    require(
        Path(screenshot_name).name == screenshot_name,
        "Dashboard screenshot path is not one component",
    )
    screenshot_path = (root / screenshot_name).resolve()
    require(
        screenshot_path.parent == root, "Dashboard screenshot escapes producer root"
    )
    screenshot = screenshot_path.read_bytes()
    require(
        dashboard_capture.get("bytes") == len(screenshot),
        "Dashboard screenshot byte count differs from proof manifest",
    )
    require(
        dashboard_capture.get("sha256") == digest_bytes(screenshot),
        "Dashboard screenshot SHA differs from proof manifest",
    )
    verified[screenshot_name] = {
        "bytes": len(screenshot),
        "sha256": digest_bytes(screenshot),
    }
    health = decode_object((root / "health.json").read_bytes(), "producer health.json")
    validate_live_server(evidence, health)
    dashboard = decode_object(
        (root / "dashboard-tools.json").read_bytes(),
        "producer dashboard-tools.json",
    )
    ledger = decode_object(
        (root / "skill-activations.json").read_bytes(),
        "producer skill-activations.json",
    )
    projection = object_field(dashboard, "skill_activations", "producer dashboard")
    require(
        projection.get("ledger") == ledger,
        "producer Dashboard ledger differs from durable ledger artifact",
    )
    return verified


def validate_tui_executable(
    evidence: dict[str, Any], producer_root: Path, timeout: float
) -> tuple[Path, bytes, dict[str, Any]]:
    source = object_field(evidence, "source", "evidence")
    build = object_field(source, "tui_build", "evidence.source")
    expected_manifest_sha = string_field(
        build, "manifest_sha256", "evidence.source.tui_build"
    )
    expected_binary_sha = string_field(
        build, "executable_sha256", "evidence.source.tui_build"
    )
    expected_binary_bytes = build.get("executable_bytes")
    require(
        isinstance(expected_binary_bytes, int)
        and not isinstance(expected_binary_bytes, bool)
        and expected_binary_bytes > 0,
        "evidence.source.tui_build.executable_bytes is invalid",
    )
    root = producer_root.resolve()
    manifest_path = root / "tui-build-evidence.json"
    manifest_payload = manifest_path.read_bytes()
    require(
        digest_bytes(manifest_payload) == expected_manifest_sha,
        "TUI build evidence SHA differs from producer proof",
    )
    manifest = decode_object(manifest_payload, "producer TUI build evidence")
    require(
        manifest.get("schema") == "masc.tui-build-evidence/v1",
        "producer TUI build evidence schema is unsupported",
    )
    manifest_source = object_field(manifest, "source", "TUI build evidence")
    require(
        manifest_source.get("head")
        == string_field(source, "expected_sha", "evidence.source"),
        "TUI build source HEAD differs from proof source",
    )
    require(
        manifest_source.get("tree")
        == string_field(source, "collector_tree", "evidence.source"),
        "TUI build source tree differs from proof source",
    )
    require(
        manifest_source.get("tracked_checkout_clean") is True,
        "TUI build source checkout was not clean",
    )
    artifact = object_field(manifest, "artifact", "TUI build evidence")
    require(
        artifact.get("path") == "masc_tui.exe",
        "TUI build artifact path is not canonical",
    )
    require(
        artifact.get("sha256") == expected_binary_sha
        and artifact.get("bytes") == expected_binary_bytes,
        "TUI build artifact identity differs from producer proof",
    )
    executable = root / "masc_tui.exe"
    require(executable.is_file(), f"TUI executable is missing: {executable}")
    require(not executable.is_symlink(), "TUI executable must not be a symlink")
    payload = executable.read_bytes()
    require(
        len(payload) == expected_binary_bytes
        and digest_bytes(payload) == expected_binary_sha,
        "TUI executable differs from trusted build evidence",
    )
    # The executable is invoked only after its full digest is bound to the
    # out-of-band-approved build evidence carried by the producer proof.
    probe = subprocess.run(
        [str(executable), "--help"],
        cwd=producer_root,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
        env=scrubbed_probe_environment(),
    )
    require(probe.returncode == 0, "TUI executable --help probe failed")
    require(
        "masc-tui [OPTIONS]" in probe.stdout,
        "TUI executable --help probe returned another program",
    )
    return executable, payload, manifest


def validate_live_server(
    evidence: dict[str, Any], health: dict[str, Any]
) -> dict[str, str]:
    source = object_field(evidence, "source", "evidence")
    runtime = object_field(evidence, "runtime", "evidence")
    build = object_field(health, "build", "live health")
    paths = object_field(health, "paths", "live health")
    require(health.get("health_detail") == "full", "live health response is not full")
    expected_sha = string_field(source, "expected_sha", "evidence.source")
    require(
        build.get("binary_commit") == expected_sha,
        "live server binary changed after proof",
    )
    require(
        build.get("binary_commit_source") == "embedded",
        "live server binary is not embedded",
    )
    expected_started_at = string_field(source, "server_started_at", "evidence.source")
    expected_instance = string_field(
        source, "server_runtime_instance_id", "evidence.source"
    )
    require(
        build.get("runtime_instance_id") == expected_instance,
        "live server process identity changed after proof",
    )
    require(
        build.get("started_at") == expected_started_at,
        "live server process changed after proof",
    )
    expected_base = string_field(runtime, "effective_base_path", "evidence.runtime")
    expected_root = string_field(runtime, "effective_masc_root", "evidence.runtime")
    require(
        paths.get("effective_base_path") == expected_base,
        "live server base path changed after proof",
    )
    require(
        paths.get("effective_masc_root") == expected_root,
        "live MASC root changed after proof",
    )
    return {
        "binary_commit": expected_sha,
        "binary_commit_source": "embedded",
        "runtime_instance_id": expected_instance,
        "started_at": expected_started_at,
        "effective_base_path": expected_base,
        "effective_masc_root": expected_root,
    }


def validate_live_dashboard(
    selected: dict[str, Any], dashboard: dict[str, Any]
) -> None:
    projection = object_field(dashboard, "skill_activations", "live dashboard")
    ledger = object_field(projection, "ledger", "live dashboard Skill projection")
    require(
        projection.get("keeper_name") == selected["keeper"],
        "live dashboard Keeper changed",
    )
    require(
        ledger.get("session_id") == selected["session_id"],
        "live dashboard session changed",
    )
    require(
        ledger.get("revision") == selected["ledger_revision"],
        "live dashboard ledger changed",
    )
    exact = [
        activation
        for activation in list_field(ledger, "activations", "live Skill ledger")
        if isinstance(activation, dict)
        and activation.get("skill_tool_use_id") == selected["skill_tool_use_id"]
    ]
    require(len(exact) == 1, f"live dashboard has {len(exact)} exact activation rows")
    require(
        exact[0].get("actions") == selected["actions"],
        "live dashboard actions changed after proof",
    )


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_port(port: int, process: subprocess.Popen[bytes], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            output = (
                process.stdout.read().decode(errors="replace") if process.stdout else ""
            )
            raise CaptureError(
                f"ttyd exited before listen: {process.returncode}: {output}"
            )
        with socket.socket() as sock:
            sock.settimeout(0.25)
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.1)
    raise CaptureError("ttyd did not listen before the configured timeout")


def safe_environment(base_path: str, host: str, token: str) -> dict[str, str]:
    keys = (
        "PATH",
        "LANG",
        "LC_ALL",
        "TMPDIR",
        "TZ",
        "CAML_LD_LIBRARY_PATH",
        "OPAM_SWITCH_PREFIX",
    )
    environment = {key: os.environ[key] for key in keys if key in os.environ}
    environment.update(
        {
            "MASC_BASE_PATH": base_path,
            "MASC_HOST": host,
            "MASC_TUI_SYNC": "off",
            "MASC_TOKEN": token,
            "TERM": "xterm-256color",
            "NO_PROXY": "127.0.0.1,localhost",
            "no_proxy": "127.0.0.1,localhost",
        }
    )
    return environment


@contextmanager
def ttyd_session(
    *,
    browser: Any,
    ttyd: Path,
    executable: Path,
    base_path: str,
    host: str,
    api_port: int,
    cols: int,
    rows: int,
    timeout: float,
    token: str,
) -> Iterator[Any]:
    web_port = free_port()
    command = [
        str(ttyd),
        "-p",
        str(web_port),
        "-i",
        "127.0.0.1",
        "-W",
        "-t",
        "rendererType=dom",
        "-t",
        "fontSize=14",
        "-t",
        "fontFamily=Menlo",
        "-T",
        "xterm-256color",
        str(executable),
        "--base-path",
        base_path,
        "--workspace",
        Path(base_path).name,
        "--port",
        str(api_port),
        "--refresh",
        "60",
    ]
    process = subprocess.Popen(
        command,
        cwd=Path(__file__).resolve().parents[3],
        env=safe_environment(base_path, host, token),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    context = None
    try:
        wait_port(web_port, process, timeout)
        context = browser.new_context(
            viewport={"width": int(cols * 8.5) + 24, "height": rows * 17 + 24},
            device_scale_factor=1,
        )
        page = context.new_page()
        page.goto(
            f"http://127.0.0.1:{web_port}",
            wait_until="domcontentloaded",
            timeout=int(timeout * 1000),
        )
        page.wait_for_selector(".xterm-helper-textarea", timeout=int(timeout * 1000))
        page.wait_for_function(
            "() => Boolean(window.term)", timeout=int(timeout * 1000)
        )
        page.evaluate(
            "size => window.term.resize(size.cols, size.rows)",
            {"cols": cols, "rows": rows},
        )
        page.wait_for_function(
            "size => window.term && window.term.cols === size.cols && window.term.rows === size.rows",
            arg={"cols": cols, "rows": rows},
            timeout=int(timeout * 1000),
        )
        yield page
    finally:
        if context is not None:
            context.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


def screen_text(page: Any) -> str:
    return page.locator(".xterm-screen").inner_text()


def press(page: Any, key: str) -> None:
    page.locator(".xterm-helper-textarea").focus()
    page.keyboard.press(key)


def wait_screen(page: Any, marker: str, timeout: float) -> None:
    page.wait_for_function(
        "marker => document.querySelector('.xterm-screen')?.innerText.includes(marker)",
        arg=marker,
        timeout=int(timeout * 1000),
    )


def selected_surface_from_screen(value: str) -> str | None:
    for line in value.splitlines():
        for token in line.split():
            if token.startswith("▸") and len(token) > 1:
                return token[1:]
    return None


def goto_tools(page: Any, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    current = selected_surface_from_screen(screen_text(page))
    require(current is not None, "TUI did not expose its selected surface")
    visited = [current]
    while time.monotonic() < deadline:
        press(page, "Tab")
        observed = current
        while observed == current and time.monotonic() < deadline:
            page.wait_for_timeout(50)
            selected = selected_surface_from_screen(screen_text(page))
            if selected is not None:
                observed = selected
        require(observed != current, "TUI surface selection did not advance")
        if observed == "Tools":
            wait_screen(page, "MASC Tools", max(0.001, deadline - time.monotonic()))
            return
        require(observed not in visited, "TUI completed a surface cycle without Tools")
        visited.append(observed)
        current = observed
    raise CaptureError("TUI did not reach the Tools surface")


def selected_keeper_from_screen(value: str) -> str | None:
    prefix = "Effective Keeper Surface — "
    for line in value.splitlines():
        normalized = line.strip(" │")
        if not normalized.startswith(prefix):
            continue
        remainder = normalized[len(prefix) :]
        if remainder in ("not loaded", "no Keeper selected"):
            return None
        endings = [
            index for marker in (" (", " — ") if (index := remainder.find(marker)) >= 0
        ]
        name = remainder[: min(endings)] if endings else remainder
        return name if name != "" else None
    return None


def selected_tools_pane_from_screen(value: str) -> str | None:
    for line in value.splitlines():
        if "MASC Tools" not in line:
            continue
        for token in line.split():
            pane_token = token.lstrip("|")
            if not pane_token.startswith("▸"):
                continue
            pane = pane_token[1:]
            return pane if pane != "" else None
    return None


def select_tools_activations(page: Any, timeout: float) -> list[str]:
    deadline = time.monotonic() + timeout
    current = selected_tools_pane_from_screen(screen_text(page))
    while current is None and time.monotonic() < deadline:
        page.wait_for_timeout(50)
        current = selected_tools_pane_from_screen(screen_text(page))
    if current is None:
        raise CaptureError("TUI did not expose its selected Tools pane")
    visited = [current]
    while current != "activations" and time.monotonic() < deadline:
        press(page, "p")
        next_pane = current
        while next_pane == current and time.monotonic() < deadline:
            page.wait_for_timeout(50)
            observed = selected_tools_pane_from_screen(screen_text(page))
            if observed is not None:
                next_pane = observed
        require(next_pane != current, "TUI Tools pane selection did not advance")
        if next_pane in visited:
            raise CaptureError("TUI completed a Tools pane cycle without activations")
        visited.append(next_pane)
        current = next_pane
    require(
        current == "activations",
        "TUI did not select the activations pane before timeout",
    )
    return visited


def select_exact_keeper(page: Any, keeper: str, timeout: float) -> list[str]:
    deadline = time.monotonic() + timeout
    current = selected_keeper_from_screen(screen_text(page))
    while current is None and time.monotonic() < deadline:
        page.wait_for_timeout(50)
        current = selected_keeper_from_screen(screen_text(page))
    if current is None:
        raise CaptureError("TUI did not load an initial exact Keeper surface")
    visited = [current]
    while current != keeper and time.monotonic() < deadline:
        press(page, "]")
        next_keeper = current
        while next_keeper == current and time.monotonic() < deadline:
            page.wait_for_timeout(50)
            observed = selected_keeper_from_screen(screen_text(page))
            if observed is not None:
                next_keeper = observed
        require(next_keeper != current, "TUI Keeper selection did not advance")
        if next_keeper in visited:
            raise CaptureError(f"TUI completed a Keeper cycle without {keeper}")
        visited.append(next_keeper)
        current = next_keeper
    require(current == keeper, "TUI did not select the exact Keeper before timeout")
    return visited


def exact_receipt_block(value: str, skill_tool_use_id: str) -> str | None:
    lines = value.splitlines()
    id_marker = f"id={skill_tool_use_id}"
    normalized_lines = [line.strip(" │") for line in lines]
    token_lines = [line.split() for line in normalized_lines]
    starts = [index for index, tokens in enumerate(token_lines) if id_marker in tokens]
    if len(starts) != 1:
        return None
    id_line = starts[0]
    if id_line == 0 or not normalized_lines[id_line - 1].startswith("exact="):
        return None
    start = id_line - 1
    end = next(
        (
            index
            for index in range(start + 1, len(lines))
            if normalized_lines[index].startswith("exact=")
        ),
        len(lines),
    )
    return "\n".join(lines[start:end])


def receipt_block_contains(value: str, skill_tool_use_id: str, action: str) -> bool:
    block = exact_receipt_block(value, skill_tool_use_id)
    if block is None:
        return False
    return any(action in line.strip(" │").split() for line in block.splitlines()[1:])


def exact_reference_line(activation: dict[str, Any]) -> str:
    identity = object_field(activation, "identity", "Skill activation")
    reference = {
        "identity": {
            field: string_field(identity, field, "Skill activation identity")
            for field in ("source_id", "package_id", "name")
        },
        "content_revision": string_field(
            activation, "content_revision", "Skill activation"
        ),
    }
    return "exact=" + json.dumps(reference, ensure_ascii=False, separators=(",", ":"))


def receipt_matches_activation(
    block: str, activation: dict[str, Any], actions: list[Any]
) -> bool:
    lines = [line.strip(" │") for line in block.splitlines()]
    if not lines:
        return False
    expected_reference = exact_reference_line(activation)
    content_marker = '"content_revision":"'
    if (
        not expected_reference.startswith(lines[0])
        or content_marker not in lines[0]
        or lines[0].endswith(content_marker)
    ):
        return False
    invoked_tokens = {
        f"turn={integer_field(activation, 'agent_core_turn', 'Skill activation')}",
        f"id={string_field(activation, 'skill_tool_use_id', 'Skill activation')}",
        f"runtime={string_field(activation, 'runtime_id', 'Skill activation')}",
        f"at={string_field(activation, 'activated_at', 'Skill activation')}",
    }
    if sum(invoked_tokens <= set(line.split()) for line in lines[1:]) != 1:
        return False
    for index, action_value in enumerate(actions):
        if not isinstance(action_value, dict):
            return False
        expected_action_tokens = {
            action_marker(action_value),
            f"turn={integer_field(action_value, 'agent_core_turn', f'action {index}')}",
            f"runtime={string_field(action_value, 'runtime_id', f'action {index}')}",
            f"tool={string_field(action_value, 'tool_name', f'action {index}')}",
            f"at={string_field(action_value, 'observed_at', f'action {index}')}",
        }
        if sum(expected_action_tokens <= set(line.split()) for line in lines[1:]) != 1:
            return False
    return True


def tools_surface_is_connected(value: str) -> bool:
    return any(
        line.strip().startswith("MASC Tools ") and line.rstrip().endswith("[connected]")
        for line in value.splitlines()
    )


def ledger_projection_matches(line: str, session_id: str, ledger_revision: str) -> bool:
    normalized = line.strip(" │")
    return normalized == f"session={session_id}  ledger={ledger_revision}"


def scroll_to_skill_receipt(
    page: Any,
    *,
    keeper: str,
    session_id: str,
    ledger_revision: str,
    skill_tool_use_id: str,
    activation: dict[str, Any],
    actions: list[Any],
    action: str,
    timeout: float,
) -> tuple[str, dict[str, str]]:
    deadline = time.monotonic() + timeout
    observations: dict[str, str] = {}
    while time.monotonic() < deadline:
        visible = screen_text(page)
        normalized_lines = [line.strip(" │") for line in visible.splitlines()]
        if "skill_header" not in observations:
            header_prefix = f"Skill Use — {keeper} ("
            header = next(
                (
                    line
                    for line in normalized_lines
                    if line.startswith(header_prefix) and line.endswith(" receipts)")
                ),
                None,
            )
            if header is not None:
                observations["skill_header"] = header
        if "session_line" not in observations:
            session_line = next(
                (
                    line
                    for line in normalized_lines
                    if ledger_projection_matches(line, session_id, ledger_revision)
                ),
                None,
            )
            if session_line is not None:
                observations["session_line"] = session_line
        receipt = exact_receipt_block(visible, skill_tool_use_id)
        if (
            receipt is not None
            and receipt_block_contains(visible, skill_tool_use_id, action)
            and receipt_matches_activation(receipt, activation, actions)
        ):
            observations["receipt_block"] = receipt
        if len(observations) == 3 and receipt is not None:
            return visible, observations
        press(page, "j")
        page.wait_for_timeout(25)
        advanced = screen_text(page)
        if advanced == visible:
            required = {"skill_header", "session_line", "receipt_block"}
            missing = sorted(required - observations.keys())
            raise CaptureError(f"TUI reached the bottom before observations: {missing}")
    raise CaptureError("TUI Skill receipt observations did not complete before timeout")


def write_json(path: Path, value: Any) -> bytes:
    payload = (
        json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    ).encode()
    path.write_bytes(payload)
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proof", required=True, type=Path)
    parser.add_argument("--expected-proof-sha256", required=True)
    parser.add_argument("--token-file", required=True, type=Path)
    parser.add_argument("--ttyd", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--cols", type=int, default=180)
    parser.add_argument("--rows", type=int, default=42)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    require(args.timeout > 0, "timeout must be positive")
    require(args.cols > 0 and args.rows > 0, "terminal size must be positive")
    require(not args.out.exists(), f"output path already exists: {args.out}")
    token = read_token(args.token_file)
    repo = Path(__file__).resolve().parents[3]
    source_before = source_snapshot(repo)
    proof_payload = args.proof.read_bytes()
    require_expected_digest(proof_payload, args.expected_proof_sha256, "producer proof")
    evidence = decode_object(proof_payload, f"proof manifest {args.proof}")
    dashboard_path = args.proof.parent / "dashboard-tools.json"
    dashboard_payload = dashboard_path.read_bytes()
    dashboard = decode_object(dashboard_payload, f"dashboard artifact {dashboard_path}")
    selected = validate_bundle(
        evidence=evidence,
        dashboard_payload=dashboard_payload,
        dashboard=dashboard,
        source_head=source_before["head"],
        source_tree=source_before["tree"],
        tracked_checkout_clean=source_before["tracked_changes"] == [],
    )
    verified_producer_artifacts = verify_producer_artifacts(evidence, args.proof.parent)
    executable, executable_payload, build_evidence = validate_tui_executable(
        evidence, args.proof.parent, args.timeout
    )

    parsed = urlsplit(selected["base_url"])
    api_port = parsed.port or 80
    health_before = read_json_url(
        f"{selected['base_url']}/health?full=1", args.timeout, token
    )
    server_identity = validate_live_server(evidence, health_before)
    live_dashboard_url = (
        f"{selected['base_url']}/api/v1/dashboard/tools?keeper="
        f"{quote(selected['keeper'], safe='')}"
    )
    live_dashboard_before = read_json_url(live_dashboard_url, args.timeout, token)
    validate_live_dashboard(selected, live_dashboard_before)

    ttyd_value = args.ttyd
    if ttyd_value is None:
        found = shutil.which("ttyd")
        ttyd_value = Path(found) if found is not None else None
    if ttyd_value is None:
        raise CaptureError("ttyd executable is missing")
    ttyd_path = Path(ttyd_value)
    require(ttyd_path.is_file(), "ttyd executable is missing")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as error:
        raise CaptureError("Playwright is required for TUI capture") from error

    args.out.mkdir(parents=True)
    incomplete = args.out / "INCOMPLETE"
    incomplete.write_text(
        "This directory is not evidence until tui-evidence.json exists and this marker is removed.\n",
        encoding="utf-8",
    )
    screenshot = args.out / "tui-skill-use.png"
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        try:
            with ttyd_session(
                browser=browser,
                ttyd=ttyd_path,
                executable=executable,
                base_path=selected["base_path"],
                host=parsed.hostname,
                api_port=api_port,
                cols=args.cols,
                rows=args.rows,
                timeout=args.timeout,
                token=token,
            ) as page:
                wait_screen(page, "MASC Overview", args.timeout)
                goto_tools(page, args.timeout)
                visited_keepers = select_exact_keeper(
                    page, selected["keeper"], args.timeout
                )
                visited_tools_panes = select_tools_activations(page, args.timeout)
                visible, observations = scroll_to_skill_receipt(
                    page,
                    keeper=selected["keeper"],
                    session_id=selected["session_id"],
                    ledger_revision=selected["ledger_revision"],
                    skill_tool_use_id=selected["skill_tool_use_id"],
                    activation=selected["activation"],
                    actions=selected["actions"],
                    action=selected["action_markers"][0],
                    timeout=args.timeout,
                )
                require(
                    tools_surface_is_connected(visible),
                    "TUI Tools surface is not connected before screenshot",
                )
                require(
                    receipt_block_contains(
                        visible,
                        selected["skill_tool_use_id"],
                        selected["action_markers"][0],
                    ),
                    "TUI action identity is not inside the exact Skill receipt block",
                )
                receipt_before = exact_receipt_block(
                    visible, selected["skill_tool_use_id"]
                )
                require(
                    receipt_before is not None, "exact TUI Skill receipt is missing"
                )
                screen = page.locator(".xterm-screen")
                screen.screenshot(path=str(screenshot))
                after_screenshot = screen_text(page)
                require(
                    tools_surface_is_connected(after_screenshot),
                    "TUI Tools surface disconnected while taking the screenshot",
                )
                require(
                    exact_receipt_block(after_screenshot, selected["skill_tool_use_id"])
                    == receipt_before,
                    "exact TUI Skill receipt changed while taking the screenshot",
                )
                terminal = page.evaluate(
                    "() => ({cols: window.term.cols, rows: window.term.rows})"
                )
        finally:
            browser.close()

    health_after = read_json_url(
        f"{selected['base_url']}/health?full=1", args.timeout, token
    )
    require(
        validate_live_server(evidence, health_after) == server_identity,
        "live server identity changed after TUI capture",
    )
    live_dashboard_after = read_json_url(live_dashboard_url, args.timeout, token)
    validate_live_dashboard(selected, live_dashboard_after)
    source_after = source_snapshot(repo)
    require(
        source_after == source_before,
        "capture source checkout changed during TUI proof",
    )

    screenshot_payload = screenshot.read_bytes()
    result = {
        "schema": "masc.keeper-skill-tui-proof.v2",
        "captured_at": utc_now(),
        "source": {
            "expected_sha": selected["expected_sha"],
            "capture_head": source_before["head"],
            "capture_tree": source_before["tree"],
            "executable_path": str(executable.resolve()),
            "executable_bytes": len(executable_payload),
            "executable_sha256": digest_bytes(executable_payload),
            "build_evidence_sha256": digest_bytes(
                (args.proof.parent / "tui-build-evidence.json").read_bytes()
            ),
            "build_evidence_schema": build_evidence["schema"],
            "tracked_checkout_clean": True,
        },
        "proof": {
            "manifest": str(args.proof.resolve()),
            "manifest_sha256": digest_bytes(proof_payload),
            "keeper": selected["keeper"],
            "session_id": selected["session_id"],
            "ledger_revision": selected["ledger_revision"],
            "skill_tool_use_id": selected["skill_tool_use_id"],
            "action_markers": selected["action_markers"],
            "captured_action_marker": selected["action_markers"][0],
        },
        "server": server_identity,
        "selection": {
            "visited_keepers": visited_keepers,
            "visited_tools_panes": visited_tools_panes,
        },
        "producer_artifacts": verified_producer_artifacts,
        "terminal": terminal,
        "observations": observations,
        "visible_text": visible,
        "visible_text_sha256": digest_bytes(visible.encode()),
        "screenshot": {
            "path": screenshot.name,
            "bytes": len(screenshot_payload),
            "sha256": digest_bytes(screenshot_payload),
        },
    }
    result_payload = write_json(args.out / "tui-evidence.json", result)
    require(
        source_snapshot(repo) == source_before,
        "capture source checkout changed while finalizing TUI proof",
    )
    incomplete.unlink()
    print(
        json.dumps(
            {
                "status": "passed",
                "evidence": str(args.out / "tui-evidence.json"),
                "sha256": digest_bytes(result_payload),
                "keeper": selected["keeper"],
                "skill_tool_use_id": selected["skill_tool_use_id"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CaptureError, OSError) as error:
        print(f"capture-keeper-skill-tui-proof: {error}")
        raise SystemExit(1) from error
