#!/usr/bin/env python3
"""Measure baseline and differential TUI frames through a real ttyd WebSocket."""

from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from hashlib import sha256
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import socket
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time
from typing import Any, Iterator, cast

from PIL import Image
from playwright.sync_api import Browser, Page, sync_playwright


WORKTREE = Path(__file__).resolve().parents[1]
SUPPORT_PATH = WORKTREE / "scripts/capture-tui-keeper-chat.py"
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
KEY_ACTIONS = (
    ("type-a-1", "A", "A"),
    ("type-b-1", "B", "AB"),
    ("type-a-2", "A", "ABA"),
    ("type-b-2", "B", "ABAB"),
    ("type-a-3", "A", "ABABA"),
)


def load_support() -> Any:
    spec = importlib.util.spec_from_file_location("tui_capture_support", SUPPORT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load capture support: {SUPPORT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return cast(Any, module)


support = load_support()


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def digest_bytes(value: bytes) -> str:
    return sha256(value).hexdigest()


def digest_file(path: Path) -> str:
    return digest_bytes(path.read_bytes())


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise AssertionError(detail)


def git_text(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=WORKTREE, text=True).strip()


@dataclass(frozen=True)
class ObservedFrame:
    direction: str
    observed_at: float
    payload: bytes
    payload_kind: str


def observe_frame(
    frames: list[ObservedFrame], direction: str, payload: str | bytes
) -> None:
    raw = payload if isinstance(payload, bytes) else payload.encode("utf-8")
    frames.append(
        ObservedFrame(
            direction=direction,
            observed_at=time.monotonic(),
            payload=raw,
            payload_kind="binary" if isinstance(payload, bytes) else "text",
        )
    )


def wait_for_quiet(
    page: Page,
    frames: list[ObservedFrame],
    *,
    start: int,
    require_received: bool,
    quiet_seconds: float = 0.25,
    timeout_seconds: float = 5.0,
) -> list[ObservedFrame]:
    deadline = time.monotonic() + timeout_seconds
    last_count = len(frames)
    stable_since = time.monotonic()
    while time.monotonic() < deadline:
        page.wait_for_timeout(25)
        count = len(frames)
        if count != last_count:
            last_count = count
            stable_since = time.monotonic()
        window = frames[start:]
        received = any(frame.direction == "received" for frame in window)
        if (received or not require_received) and (
            time.monotonic() - stable_since >= quiet_seconds
        ):
            return window
    raise TimeoutError("WebSocket stream did not reach the required quiet window")


def process_descendants(root_pid: int) -> list[dict[str, object]]:
    lines = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,pgid=,command="], text=True
    ).splitlines()
    parsed: list[dict[str, object]] = []
    for line in lines:
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        pid, parent_pid, process_group, command = fields
        parsed.append(
            {
                "pid": int(pid),
                "parent_pid": int(parent_pid),
                "process_group": int(process_group),
                "command": command,
            }
        )
    descendants: list[dict[str, object]] = []
    frontier = {root_pid}
    seen: set[int] = set()
    while frontier:
        next_frontier: set[int] = set()
        for row in parsed:
            pid = cast(int, row["pid"])
            parent_pid = cast(int, row["parent_pid"])
            if parent_pid in frontier and pid not in seen:
                descendants.append(row)
                seen.add(pid)
                next_frontier.add(pid)
        frontier = next_frontier
    return descendants


def exact_tui_child(root_pid: int, executable: Path) -> dict[str, object]:
    expected = executable.resolve()
    deadline = time.monotonic() + 5.0
    last_descendants: list[dict[str, object]] = []
    while time.monotonic() < deadline:
        last_descendants = process_descendants(root_pid)
        matches = [
            row
            for row in last_descendants
            if Path(cast(str, row["command"]).split(None, 1)[0]).resolve() == expected
        ]
        if len(matches) == 1:
            return matches[0]
        time.sleep(0.05)
    raise AssertionError(
        f"expected one exact TUI child {str(expected)!r}: {last_descendants!r}"
    )


def compare_png_pixels(left: Path, right: Path) -> dict[str, object]:
    with Image.open(left) as left_image, Image.open(right) as right_image:
        require(left_image.size == right_image.size, "PNG dimensions differ")
        left_rgb = left_image.convert("RGB")
        right_rgb = right_image.convert("RGB")
        left_bytes = left_rgb.tobytes()
        right_bytes = right_rgb.tobytes()
    require(len(left_bytes) == len(right_bytes), "PNG pixel buffers differ")
    different_pixels = 0
    maximum_channel_delta = 0
    channel_delta_total = 0
    for offset in range(0, len(left_bytes), 3):
        pixel_changed = False
        for channel in range(3):
            delta = abs(left_bytes[offset + channel] - right_bytes[offset + channel])
            maximum_channel_delta = max(maximum_channel_delta, delta)
            channel_delta_total += delta
            pixel_changed = pixel_changed or delta != 0
        different_pixels += int(pixel_changed)
    pixel_count = len(left_bytes) // 3
    return {
        "left": left.name,
        "right": right.name,
        "width_px": left_rgb.width,
        "height_px": left_rgb.height,
        "pixel_count": pixel_count,
        "different_pixels": different_pixels,
        "different_pixel_percent": round((different_pixels / pixel_count) * 100, 6),
        "maximum_absolute_channel_delta": maximum_channel_delta,
        "mean_absolute_channel_delta": round(channel_delta_total / len(left_bytes), 9),
    }


@contextmanager
def built_binary(
    commit: str,
    label: str,
    output: Path,
    records: list[dict[str, object]],
) -> Iterator[tuple[Path, dict[str, object]]]:
    source_temp = tempfile.TemporaryDirectory(prefix=f".source-{label}-", dir=output)
    build_temp = tempfile.TemporaryDirectory(prefix=f".build-{label}-", dir=output)
    source_dir = Path(source_temp.name)
    build_dir = Path(build_temp.name)
    archive_path = output / f".{label}.tar"
    try:
        with archive_path.open("xb") as archive_handle:
            result = subprocess.run(
                ["git", "archive", "--format=tar", commit],
                cwd=WORKTREE,
                stdout=archive_handle,
            )
        require(result.returncode == 0, f"{label} git archive failed")
        archive_hash = digest_file(archive_path)
        with tarfile.open(archive_path, mode="r") as archive:
            archive.extractall(path=source_dir, filter="data")
        archive_path.unlink()
        wrapper = source_dir / "scripts/dune-local.sh"
        require(wrapper.is_file(), f"{label} source archive is incomplete")
        require(not any(build_dir.iterdir()), f"{label} build dir is not fresh")
        executable = build_dir / "default/bin/masc_tui.exe"
        build_args = [
            "build",
            "--build-dir",
            str(build_dir),
            "bin/masc_tui.exe",
        ]
        environment = support.safe_env(support.BUILD_ENV_KEYS)
        started_at = utc_now()
        started = time.monotonic()
        build = subprocess.run(
            [str(wrapper), *build_args],
            cwd=source_dir,
            capture_output=True,
            env=environment,
        )
        record: dict[str, object] = {
            "label": label,
            "source_snapshot": {
                "kind": "git_archive",
                "commit": commit,
                "tar_sha256": archive_hash,
            },
            "command": ["scripts/dune-local.sh", *build_args],
            "started_at": started_at,
            "finished_at": utc_now(),
            "duration_ms": round((time.monotonic() - started) * 1000, 3),
            "returncode": build.returncode,
            "stdout_sha256": digest_bytes(build.stdout),
            "stderr_sha256": digest_bytes(build.stderr),
            "stdout_utf8": build.stdout.decode("utf-8"),
            "stderr_utf8": build.stderr.decode("utf-8"),
            "inherited_environment_keys": sorted(environment),
        }
        records.append(record)
        require(build.returncode == 0, f"{label} focused build failed")
        require(
            executable.is_file() and not executable.is_symlink(),
            f"{label} executable missing or non-regular",
        )
        record["executable_bytes"] = executable.stat().st_size
        record["executable_sha256"] = digest_file(executable)
        yield executable, record
    finally:
        if archive_path.exists():
            archive_path.unlink()
        build_temp.cleanup()
        source_temp.cleanup()


@contextmanager
def measured_ttyd_session(
    browser: Browser,
    *,
    base: Path,
    api_port: int,
    executable: Path,
    source_dir: Path,
    metadata: dict[str, object],
) -> Iterator[tuple[Page, subprocess.Popen[bytes], list[ObservedFrame]]]:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        web_port = int(sock.getsockname()[1])
    environment = support.safe_env(support.SAFE_ENV_KEYS)
    environment.update(
        {
            "MASC_BASE_PATH": str(base),
            "MASC_HOST": "127.0.0.1",
            "MASC_TUI_SYNC": "off",
            "TERM": "xterm-256color",
            "NO_PROXY": "127.0.0.1,localhost",
            "no_proxy": "127.0.0.1,localhost",
        }
    )
    command = [
        str(support.TTYD),
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
        "-t",
        "cursorBlink=false",
        "-T",
        "xterm-256color",
        str(executable),
        "--base-path",
        str(base),
        "--workspace",
        "differential-frame-evidence",
        "--port",
        str(api_port),
        "--refresh",
        "60",
    ]
    log = tempfile.TemporaryFile()
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        cwd=source_dir,
        env=environment,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    context = None
    frames: list[ObservedFrame] = []
    web_socket_urls: list[str] = []
    try:
        support.wait_port(web_port, process)
        context = browser.new_context(
            viewport={"width": 860, "height": 496}, device_scale_factor=1
        )
        page = context.new_page()

        def on_web_socket(web_socket: Any) -> None:
            web_socket_urls.append(cast(str, web_socket.url))
            web_socket.on(
                "framereceived",
                lambda payload: observe_frame(frames, "received", payload),
            )
            web_socket.on(
                "framesent", lambda payload: observe_frame(frames, "sent", payload)
            )

        page.on("websocket", on_web_socket)
        page.goto(f"http://127.0.0.1:{web_port}", wait_until="domcontentloaded")
        page.wait_for_selector(".xterm-helper-textarea", timeout=10_000)
        page.wait_for_function(
            "window.term && window.term.cols === 99 && window.term.rows === 30",
            timeout=10_000,
        )
        support.wait_text(page, "MASC Overview")
        page.wait_for_timeout(3_000)
        require(len(web_socket_urls) == 1, f"WebSocket count: {web_socket_urls}")
        yield page, process, frames
    finally:
        try:
            if context is not None:
                context.close()
        finally:
            try:
                support.stop_process(process)
            finally:
                log.seek(0)
                log_bytes = log.read()
                log.close()
                metadata.update(
                    {
                        "command": command,
                        "duration_ms": round((time.monotonic() - started) * 1000, 3),
                        "returncode": process.returncode,
                        "log_bytes": len(log_bytes),
                        "log_sha256": digest_bytes(log_bytes),
                        "log_utf8": log_bytes.decode("utf-8", errors="replace"),
                        "web_socket_urls": web_socket_urls,
                        "child_environment_keys": sorted(environment),
                        "observed_application_messages": [
                            {
                                "direction": frame.direction,
                                "offset_ms": round(
                                    (frame.observed_at - started) * 1000, 3
                                ),
                                "payload_kind": frame.payload_kind,
                                "application_payload_bytes": len(frame.payload),
                                "application_payload_sha256": digest_bytes(
                                    frame.payload
                                ),
                                "application_payload_base64": base64.b64encode(
                                    frame.payload
                                ).decode("ascii"),
                            }
                            for frame in frames
                        ],
                    }
                )


def terminal_state(page: Page) -> dict[str, object]:
    cursor = support.cursor_position(page)
    visible = support.screen_text(page)
    input_row = support.buffer_line(page, cursor["y"])
    dimensions = page.evaluate("({cols: window.term.cols, rows: window.term.rows})")
    return {
        "visible_text": visible,
        "visible_text_sha256": digest_bytes(visible.encode("utf-8")),
        "input_row_text": input_row,
        "input_row_text_sha256": digest_bytes(input_row.encode("utf-8")),
        "cursor_zero_based": cursor,
        "cursor_visible": support.cursor_visible(page),
        "terminal_columns": dimensions["cols"],
        "terminal_rows": dimensions["rows"],
    }


def serialize_window(
    frames: list[ObservedFrame],
    *,
    action_started: float,
    label: str,
    expected_browser_payload: bytes | None,
) -> dict[str, object]:
    received = [frame for frame in frames if frame.direction == "received"]
    sent = [frame for frame in frames if frame.direction == "sent"]
    require(received != [], f"{label} emitted no server-to-browser frame")
    require(
        all(frame.payload.startswith(b"0") for frame in received),
        f"{label} contains a non-output ttyd application message",
    )
    require(
        all(frame.payload_kind == "binary" for frame in received),
        f"{label} server payload was not binary",
    )
    require(
        all(frame.payload_kind == "binary" for frame in sent),
        f"{label} browser payload was not binary",
    )
    if expected_browser_payload is None:
        require(sent == [], f"{label} unexpectedly sent browser input")
    else:
        require(len(sent) == 1, f"{label} browser input message count: {len(sent)}")
        require(
            sent[0].payload == expected_browser_payload,
            f"{label} browser input payload: {sent[0].payload!r}",
        )

    def frame_record(frame: ObservedFrame) -> dict[str, object]:
        return {
            "direction": frame.direction,
            "offset_ms": round((frame.observed_at - action_started) * 1000, 3),
            "payload_kind": frame.payload_kind,
            "application_payload_bytes": len(frame.payload),
            "application_payload_sha256": digest_bytes(frame.payload),
            "application_payload_base64": base64.b64encode(frame.payload).decode(
                "ascii"
            ),
        }

    received_bytes = sum(len(frame.payload) for frame in received)
    terminal_payload = b"".join(frame.payload[1:] for frame in received)
    terminal_bytes = len(terminal_payload)
    cursor_address_rows = sorted(
        {
            int(match.group(1))
            for match in re.finditer(rb"\x1b\[(\d+);(\d+)H", terminal_payload)
        }
    )
    return {
        "label": label,
        "server_to_browser_messages": len(received),
        "server_to_browser_application_payload_bytes": received_bytes,
        "terminal_ansi_payload_bytes_after_ttyd_type_byte": terminal_bytes,
        "ttyd_command_prefix_bytes": len(received),
        "browser_to_server_messages": len(sent),
        "browser_to_server_application_payload_bytes": sum(
            len(frame.payload) for frame in sent
        ),
        "first_server_message_ms": round(
            (received[0].observed_at - action_started) * 1000, 3
        ),
        "last_server_message_ms": round(
            (received[-1].observed_at - action_started) * 1000, 3
        ),
        "all_server_messages_binary": all(
            frame.payload_kind == "binary" for frame in received
        ),
        "ttyd_output_type_byte_verified": True,
        "contains_clear_screen_csi_2j": b"\x1b[2J" in terminal_payload,
        "cursor_address_rows_one_based": cursor_address_rows,
        "frames": [frame_record(frame) for frame in frames],
    }


def apply_key(page: Page, key: str) -> None:
    page.locator(".xterm-helper-textarea").focus()
    if len(key) == 1:
        page.keyboard.type(key)
    else:
        page.keyboard.press(key)


def aggregate(windows: list[dict[str, object]]) -> dict[str, object]:
    byte_counts = [
        cast(int, window["server_to_browser_application_payload_bytes"])
        for window in windows
    ]
    first_latencies = [
        cast(float, window["first_server_message_ms"]) for window in windows
    ]
    last_latencies = [
        cast(float, window["last_server_message_ms"]) for window in windows
    ]
    return {
        "sample_count": len(windows),
        "application_payload_bytes_total": sum(byte_counts),
        "application_payload_bytes_min": min(byte_counts),
        "application_payload_bytes_median": statistics.median(byte_counts),
        "application_payload_bytes_max": max(byte_counts),
        "first_server_message_ms_median": statistics.median(first_latencies),
        "last_server_message_ms_median": statistics.median(last_latencies),
    }


def measure_binary(
    browser: Browser,
    *,
    label: str,
    executable: Path,
    output: Path,
    include_forced_redraw: bool,
    api_port: int,
    state: Any,
    partial: dict[str, object],
) -> dict[str, object]:
    base_temp = tempfile.TemporaryDirectory(prefix=f".base-{label}-", dir=output)
    base = Path(base_temp.name)
    session_metadata: dict[str, object] = {}
    screenshots: list[dict[str, object]] = []
    partial.update(
        {
            "label": label,
            "key_windows": [],
            "screenshots": screenshots,
            "ttyd": session_metadata,
        }
    )
    try:
        support.prepare_base(base)
        with state.lock:
            http_records_before_session = len(state.records)
        with measured_ttyd_session(
            browser,
            base=base,
            api_port=api_port,
            executable=executable,
            source_dir=WORKTREE,
            metadata=session_metadata,
        ) as (page, process, frames):
            support.open_message(page)
            wait_for_quiet(
                page,
                frames,
                start=len(frames),
                require_received=False,
                quiet_seconds=0.5,
            )
            initial = terminal_state(page)
            partial["initial_terminal_state"] = initial
            initial_cursor = cast(dict[str, int], initial["cursor_zero_based"])
            with state.lock:
                http_records_before_windows = len(state.records)
            windows: list[dict[str, object]] = []
            partial["key_windows"] = windows
            for index, (action_label, key, expected_input) in enumerate(KEY_ACTIONS):
                start = len(frames)
                action_started = time.monotonic()
                apply_key(page, key)
                expected_x = initial_cursor["x"] + len(expected_input)
                support.wait_cursor(page, expected_x, initial_cursor["y"])
                observed = wait_for_quiet(
                    page,
                    frames,
                    start=start,
                    require_received=True,
                )
                window = serialize_window(
                    observed,
                    action_started=action_started,
                    label=f"{label}-{index + 1}-{action_label}",
                    expected_browser_payload=b"0" + key.encode("utf-8"),
                )
                window["key"] = key
                window["expected_input"] = expected_input
                state_after_key = terminal_state(page)
                require(
                    expected_input in cast(str, state_after_key["input_row_text"]),
                    f"{label} input row omitted {expected_input!r}",
                )
                window["terminal_state"] = state_after_key
                windows.append(window)
            final_state = terminal_state(page)
            partial["final_terminal_state"] = final_state
            final_cursor = cast(dict[str, int], final_state["cursor_zero_based"])
            screenshots.append(
                support.capture(
                    page,
                    output,
                    f"01-{label}-ababa.png"
                    if label == "baseline"
                    else f"02-{label}-ababa.png",
                    "Message to: alpha",
                    expected_cursor=(final_cursor["x"], final_cursor["y"]),
                    input_row_markers=("ABABA",),
                )
            )
            forced_redraw = None
            if include_forced_redraw:
                tui_child = exact_tui_child(process.pid, executable)
                start = len(frames)
                action_started = time.monotonic()
                os.kill(cast(int, tui_child["pid"]), signal.SIGWINCH)
                observed = wait_for_quiet(
                    page,
                    frames,
                    start=start,
                    require_received=True,
                )
                forced_redraw = serialize_window(
                    observed,
                    action_started=action_started,
                    label=f"{label}-forced-same-geometry-redraw",
                    expected_browser_payload=None,
                )
                forced_redraw["trigger"] = {
                    "signal": "SIGWINCH",
                    "target": tui_child,
                }
                forced_redraw["terminal_state"] = terminal_state(page)
                partial["forced_redraw"] = forced_redraw
                screenshots.append(
                    support.capture(
                        page,
                        output,
                        "03-candidate-sigwinch-full-redraw.png",
                        "Message to: alpha",
                        expected_cursor=(final_cursor["x"], final_cursor["y"]),
                        input_row_markers=("ABABA",),
                    )
                )
            with state.lock:
                http_records_after_windows = len(state.records)
        with state.lock:
            http_records_after_session = len(state.records)
            session_http_records = [
                dict(record)
                for record in state.records[
                    http_records_before_session:http_records_after_session
                ]
            ]
        require(
            http_records_after_windows == http_records_before_windows,
            f"{label} had HTTP activity during measurement windows",
        )
        result = {
            "label": label,
            "initial_terminal_state": initial,
            "key_windows": windows,
            "aggregate": aggregate(windows),
            "final_terminal_state": final_state,
            "forced_redraw": forced_redraw,
            "screenshots": screenshots,
            "http_records": session_http_records,
            "http_records_during_measurement_windows": (
                http_records_after_windows - http_records_before_windows
            ),
            "ttyd": session_metadata,
        }
        partial.clear()
        partial.update(result)
        return result
    finally:
        base_temp.cleanup()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--baseline-commit", required=True)
    parser.add_argument("--candidate-commit", required=True)
    parser.add_argument("--target-pr", required=True, type=int)
    args = parser.parse_args()
    output = Path(tempfile.mkdtemp(prefix="masc-tui-differential-frame-capture-"))
    script_hash = digest_file(Path(__file__).resolve())
    support_hash = digest_file(SUPPORT_PATH)
    build_records: list[dict[str, object]] = []
    partial_runtime: dict[str, object] = {
        "baseline": {},
        "candidate": {},
    }
    evidence: dict[str, object] = {
        "schema": "masc.tui_differential_frame_capture.v1",
        "target_pr": args.target_pr,
        "output_dir": str(output),
        "started_at": utc_now(),
        "measurement_boundary": (
            "Playwright WebSocket application-message payload bytes; includes the "
            "one-byte ttyd message type per application message and excludes "
            "WebSocket framing, TLS, TCP, IP, and link-layer overhead"
        ),
        "builds": build_records,
        "partial_runtime": partial_runtime,
    }
    code = 0
    try:
        for label, commit in (
            ("expected head", args.expected_head),
            ("baseline commit", args.baseline_commit),
            ("candidate commit", args.candidate_commit),
        ):
            require(COMMIT_RE.fullmatch(commit) is not None, f"invalid {label}")
            subprocess.run(
                ["git", "cat-file", "-e", f"{commit}^{{commit}}"],
                cwd=WORKTREE,
                check=True,
            )
        require(args.target_pr > 0, "target PR must be positive")
        require(git_text("rev-parse", "HEAD") == args.expected_head, "HEAD mismatch")
        require(git_text("status", "--porcelain=v1") == "", "dirty checkout")
        require(SUPPORT_PATH.is_file(), "missing Keeper chat capture support")
        require(Path(support.TTYD).is_file(), f"missing ttyd: {support.TTYD}")
        require(
            git_text("merge-base", args.baseline_commit, args.candidate_commit)
            == args.baseline_commit,
            "candidate is not based on baseline",
        )
        require(
            git_text("merge-base", args.candidate_commit, args.expected_head)
            == args.candidate_commit,
            "evidence driver is not based on candidate",
        )
        evidence["source"] = {
            "driver_head": args.expected_head,
            "driver_branch": git_text("branch", "--show-current"),
            "driver_script_sha256": script_hash,
            "support_script_sha256": support_hash,
            "baseline_commit": args.baseline_commit,
            "candidate_commit": args.candidate_commit,
            "ttyd_version": support.run_text(str(support.TTYD), "--version"),
            "playwright_version": support.package_version("playwright"),
            "pillow_version": support.package_version("Pillow"),
        }

        with built_binary(args.baseline_commit, "baseline", output, build_records) as (
            baseline_executable,
            baseline_build,
        ):
            with built_binary(
                args.candidate_commit, "candidate", output, build_records
            ) as (
                candidate_executable,
                candidate_build,
            ):
                with sync_playwright() as playwright:
                    browser = playwright.chromium.launch(headless=True)
                    try:
                        cast(dict[str, object], evidence["source"])[
                            "chromium_version"
                        ] = browser.version
                        fixture_state = support.Fixture("success")
                        with support.fixture_server(fixture_state) as api_port:
                            baseline = measure_binary(
                                browser,
                                label="baseline",
                                executable=baseline_executable,
                                output=output,
                                include_forced_redraw=False,
                                api_port=api_port,
                                state=fixture_state,
                                partial=cast(
                                    dict[str, object], partial_runtime["baseline"]
                                ),
                            )
                            candidate = measure_binary(
                                browser,
                                label="candidate",
                                executable=candidate_executable,
                                output=output,
                                include_forced_redraw=True,
                                api_port=api_port,
                                state=fixture_state,
                                partial=cast(
                                    dict[str, object], partial_runtime["candidate"]
                                ),
                            )
                        http = fixture_state.summary()
                        require(
                            http["errors"] == [],
                            f"fixture errors: {http['errors']}",
                        )
                        require(http["chat_stream_post_count"] == 0, "chat POST")
                        require(http["chat_operation_get_count"] == 0, "operation GET")
                        evidence["http"] = http
                    finally:
                        browser.close()
                for executable, build_record in (
                    (baseline_executable, baseline_build),
                    (candidate_executable, candidate_build),
                ):
                    require(
                        executable.is_file(), "executable disappeared after capture"
                    )
                    require(
                        executable.stat().st_size == build_record["executable_bytes"],
                        "executable size changed after capture",
                    )
                    require(
                        digest_file(executable) == build_record["executable_sha256"],
                        "executable hash changed after capture",
                    )
                    build_record["verified_unchanged_after_capture"] = True
        evidence["measurements"] = {
            "baseline": baseline,
            "candidate": candidate,
        }
        baseline_first = cast(
            dict[str, object], cast(list[object], baseline["key_windows"])[0]
        )
        candidate_first = cast(
            dict[str, object], cast(list[object], candidate["key_windows"])[0]
        )
        baseline_bytes = cast(
            int, baseline_first["server_to_browser_application_payload_bytes"]
        )
        candidate_bytes = cast(
            int, candidate_first["server_to_browser_application_payload_bytes"]
        )
        baseline_total = cast(
            int,
            cast(dict[str, object], baseline["aggregate"])[
                "application_payload_bytes_total"
            ],
        )
        candidate_total = cast(
            int,
            cast(dict[str, object], candidate["aggregate"])[
                "application_payload_bytes_total"
            ],
        )
        require(
            candidate_bytes < baseline_bytes, "first-key byte count did not improve"
        )
        require(candidate_total < baseline_total, "five-key byte count did not improve")
        baseline_windows = cast(list[dict[str, object]], baseline["key_windows"])
        candidate_windows = cast(list[dict[str, object]], candidate["key_windows"])
        require(
            len(baseline_windows) == len(candidate_windows) == len(KEY_ACTIONS),
            "key-window count mismatch",
        )
        baseline_initial = cast(dict[str, object], baseline["initial_terminal_state"])
        initial_cursor = cast(dict[str, int], baseline_initial["cursor_zero_based"])
        expected_input_row = initial_cursor["y"] + 1
        for baseline_window, candidate_window in zip(
            baseline_windows, candidate_windows, strict=True
        ):
            require(
                baseline_window["terminal_state"] == candidate_window["terminal_state"],
                f"terminal state mismatch: {baseline_window['label']}",
            )
            require(
                baseline_window["contains_clear_screen_csi_2j"] is True,
                f"baseline did not clear: {baseline_window['label']}",
            )
            require(
                candidate_window["contains_clear_screen_csi_2j"] is False,
                f"candidate cleared: {candidate_window['label']}",
            )
            require(
                candidate_window["cursor_address_rows_one_based"]
                == [expected_input_row],
                f"candidate touched another row: {candidate_window['label']}",
            )
            candidate_window_bytes = cast(
                int, candidate_window["server_to_browser_application_payload_bytes"]
            )
            baseline_window_bytes = cast(
                int, baseline_window["server_to_browser_application_payload_bytes"]
            )
            require(
                candidate_window_bytes * 3 < baseline_window_bytes,
                f"candidate did not beat 3x gate: {candidate_window['label']}",
            )
        require(
            candidate_total * 3 < baseline_total,
            "candidate aggregate did not beat 3x gate",
        )
        require(
            baseline["final_terminal_state"] == candidate["final_terminal_state"],
            "baseline and candidate terminal states differ",
        )
        forced = cast(dict[str, object], candidate["forced_redraw"])
        require(
            forced["terminal_state"] == candidate["final_terminal_state"],
            "forced redraw changed terminal state",
        )
        require(
            forced["contains_clear_screen_csi_2j"] is True,
            "forced redraw omitted CSI 2J",
        )
        terminal_rows = cast(
            int,
            cast(dict[str, object], candidate["final_terminal_state"])["terminal_rows"],
        )
        require(
            forced["cursor_address_rows_one_based"]
            == list(range(1, terminal_rows + 1)),
            "forced redraw did not address every terminal row",
        )
        forced_bytes = cast(int, forced["server_to_browser_application_payload_bytes"])
        require(
            all(
                cast(int, window["server_to_browser_application_payload_bytes"]) * 3
                < forced_bytes
                for window in candidate_windows
            ),
            "candidate incremental window did not beat forced redraw by 3x",
        )
        evidence["comparison"] = {
            "first_key_baseline_application_payload_bytes": baseline_bytes,
            "first_key_candidate_application_payload_bytes": candidate_bytes,
            "first_key_baseline_over_candidate_ratio": round(
                baseline_bytes / candidate_bytes, 3
            ),
            "first_key_candidate_reduction_percent": round(
                (1 - (candidate_bytes / baseline_bytes)) * 100, 3
            ),
            "five_key_baseline_application_payload_bytes": baseline_total,
            "five_key_candidate_application_payload_bytes": candidate_total,
            "five_key_baseline_over_candidate_ratio": round(
                baseline_total / candidate_total, 3
            ),
            "five_key_candidate_reduction_percent": round(
                (1 - (candidate_total / baseline_total)) * 100, 3
            ),
            "candidate_forced_redraw_application_payload_bytes": forced_bytes,
            "terminal_state_equal": True,
        }
        screenshot_records = [
            *cast(list[dict[str, object]], baseline["screenshots"]),
            *cast(list[dict[str, object]], candidate["screenshots"]),
        ]
        screenshot_paths = sorted(output.glob("*.png"))
        require(len(screenshot_paths) == 3, "expected exactly three screenshots")
        require(
            sorted(path.name for path in screenshot_paths)
            == sorted(cast(str, record["file"]) for record in screenshot_records),
            "screenshot record set differs from disk",
        )
        for path in screenshot_paths:
            record = next(
                record for record in screenshot_records if record["file"] == path.name
            )
            require(path.stat().st_size == record["bytes"], f"size drift: {path.name}")
            require(digest_file(path) == record["sha256"], f"hash drift: {path.name}")
        screenshot_by_name = {path.name: path for path in screenshot_paths}
        pixel_comparisons = [
            compare_png_pixels(
                screenshot_by_name["01-baseline-ababa.png"],
                screenshot_by_name["02-candidate-ababa.png"],
            ),
            compare_png_pixels(
                screenshot_by_name["02-candidate-ababa.png"],
                screenshot_by_name["03-candidate-sigwinch-full-redraw.png"],
            ),
            compare_png_pixels(
                screenshot_by_name["01-baseline-ababa.png"],
                screenshot_by_name["03-candidate-sigwinch-full-redraw.png"],
            ),
        ]
        for comparison in pixel_comparisons:
            require(
                cast(int, comparison["maximum_absolute_channel_delta"]) <= 1,
                f"PNG channel delta exceeded tolerance: {comparison}",
            )
            require(
                cast(float, comparison["different_pixel_percent"]) <= 2.0,
                f"PNG changed-pixel ratio exceeded tolerance: {comparison}",
            )
        cast(dict[str, object], evidence["comparison"])[
            "screenshot_pixel_comparisons"
        ] = pixel_comparisons
        require(git_text("rev-parse", "HEAD") == args.expected_head, "HEAD changed")
        require(git_text("status", "--porcelain=v1") == "", "checkout dirtied")
        require(
            digest_file(Path(__file__).resolve()) == script_hash,
            "driver script changed",
        )
        require(digest_file(SUPPORT_PATH) == support_hash, "support script changed")
        require(
            len(build_records) == 2
            and all(
                record.get("verified_unchanged_after_capture") is True
                for record in build_records
            ),
            "built executable rehash was incomplete",
        )
        evidence.pop("partial_runtime", None)
        evidence["verified"] = {
            "clean_exact_driver_head": True,
            "immutable_baseline_and_candidate_archives": True,
            "fresh_focused_builds": True,
            "real_ttyd_chromium_websocket": True,
            "raw_application_messages_preserved": True,
            "five_key_windows_per_binary": True,
            "same_geometry_forced_redraw": True,
            "terminal_state_equal": True,
            "three_screenshots_rehashed_and_pixel_compared": True,
            "driver_support_and_binaries_rehashed_after_capture": True,
        }
        evidence["status"] = "passed"
    except Exception as error:  # noqa: BLE001 - persist structured failure evidence
        code = 1
        evidence["status"] = "failed"
        failure: dict[str, object] = {
            "type": type(error).__name__,
            "detail": str(error),
        }
        evidence["failure"] = failure
        evidence["partial_screenshots"] = [
            {
                "file": path.name,
                "bytes": path.stat().st_size,
                "sha256": digest_file(path),
            }
            for path in sorted(output.glob("*.png"))
        ]
        try:
            failure["driver_head_after_failure"] = git_text("rev-parse", "HEAD")
            failure["driver_status_after_failure"] = git_text(
                "status", "--porcelain=v1"
            ).splitlines()
        except Exception as diagnostic_error:  # noqa: BLE001
            failure["git_diagnostic_error"] = str(diagnostic_error)
        try:
            failure["driver_script_sha256_after_failure"] = digest_file(
                Path(__file__).resolve()
            )
            failure["support_script_sha256_after_failure"] = digest_file(SUPPORT_PATH)
        except Exception as diagnostic_error:  # noqa: BLE001
            failure["script_diagnostic_error"] = str(diagnostic_error)
    evidence["finished_at"] = utc_now()
    evidence_path = output / "evidence.json"
    evidence_path.write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(
        json.dumps(
            {
                "status": evidence["status"],
                "output_dir": str(output),
                "evidence_sha256": digest_file(evidence_path),
            }
        )
    )
    return code


if __name__ == "__main__":
    raise SystemExit(main())
