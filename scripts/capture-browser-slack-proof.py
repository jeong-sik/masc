#!/usr/bin/env python3
"""Capture public Example Domain/empty Slack proof on an isolated scratch runtime.

Opens, navigates and closes automation Firefox. Use an absent live connection
or an isolated live profile containing only Example Domain. The preflight
rejects other live pages before any screenshot. Tokens stay in request headers and the child TUI environment.
The report stores selected provenance and timings, not raw health responses.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import urllib.error
import urllib.request

API = "/api/v1/dashboard/browser-lane"
EXAMPLE = "https://example.org/"


class CaptureError(RuntimeError):
    """Only fixed, non-sensitive diagnostic labels belong in this exception."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def require(condition, label):
    if not condition:
        raise CaptureError(label)


def scratch_identity(base, health):
    """Do not open/close a session until the measured server owns this scratch base."""
    temporary_roots = {Path(tempfile.gettempdir()).resolve(), Path("/tmp").resolve()}
    require(any(base != root and base.is_relative_to(root) for root in temporary_roots),
            "base_must_be_an_isolated_temporary_directory")
    reported = health.get("paths", {}).get("effective_base_path")
    require(isinstance(reported, str) and Path(reported).resolve() == base,
            "server_base_path_does_not_match_scratch_base")


def public_page(data, *, url=EXAMPLE):
    page = data.get("page")
    require(isinstance(page, dict), "public_page_missing")
    require(page.get("url") == url and page.get("title") == "Example Domain",
            "unexpected_public_page_identity")
    require("Example Domain" in page.get("text", ""), "public_page_text_missing")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--base-path", type=Path, required=True)
    parser.add_argument("--api-port", type=int, required=True)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--tui-source-commit", help="Artifact source commit; operator-supplied provenance")
    parser.add_argument("--cols", type=int, default=150)
    parser.add_argument("--rows", type=int, default=42)
    args = parser.parse_args()
    args.base_path = args.base_path.expanduser().resolve()
    args.repo = args.repo.expanduser().resolve()
    args.executable = args.executable.expanduser().resolve()
    require(1 <= args.api_port <= 65535, "invalid_api_port")
    require(args.cols > 0 and args.rows > 0, "invalid_terminal_size")
    spec = importlib.util.spec_from_file_location("tui_capture", args.repo / "scripts/capture-tui-lane-runs.py")
    cap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cap)
    token = cap.read_token_file(args.token_file)
    # No proxy or redirect may forward the operator bearer outside loopback.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    args.out.mkdir(parents=True, exist_ok=True)
    report = {
        "schema": "masc.browser_slack.capture.v1",
        "scope": "isolated scratch runtime; public Example Domain and empty Slack only",
        "api_port": args.api_port,
        "script_sha256": cap.sha256_file(Path(__file__)),
        "tui": {"sha256": cap.sha256_file(args.executable),
                "artifact_source_commit": args.tui_source_commit},
        "measurements": [], "screenshots": [], "display_observations": [],
        "authenticated_slack_content_measured": False,
        "live_native_host_binary_verified": False,
        "result": "failed",
    }

    def request(label, path, data=None):
        started = time.monotonic()
        req = urllib.request.Request(
            f"http://127.0.0.1:{args.api_port}{path}",
            data=None if data is None else json.dumps(data).encode(),
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            response = opener.open(req, timeout=65)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            status = response.status
            value = json.load(response)
        require(isinstance(value, dict), "response_not_json_object")
        report["measurements"].append({
            "label": label, "path": path, "status": status,
            "elapsed_ms": round((time.monotonic() - started) * 1000, 1),
            "ok": value.get("ok"),
            "request": {key: data[key] for key in ("app", "lane", "action") if data and key in data},
        })
        return status, value

    def good(label, path, data):
        status, value = request(label, path, data)
        require(status == 200 and value.get("ok") is True, label + "_failed")
        require("data" in value, label + "_data_missing")
        return value["data"]

    def wait(page, *markers, timeout=55):
        try:
            return cap.wait_text(page, *markers, timeout=timeout)
        except cap.WaitFailed:
            # The shared helper's exception contains the complete screen.
            # Preserve only a fixed failure label in public evidence.
            raise CaptureError("tui_expected_state_not_observed") from None

    def capture(page, name):
        text = cap.screen_text(page)
        require("[Fleet]" not in text and "no keeper selected" not in text.lower(),
                "browser_surface_is_not_full_width")
        page.locator(".xterm-screen").screenshot(path=str(args.out / (name + ".png")))
        (args.out / (name + ".txt")).write_text(text)
        report["screenshots"].append(name + ".png")
        report["display_observations"].append({
            "screenshot": name + ".png", "full_width": True,
            "global_disconnected_badge_visible": "[disconnected]" in text,
        })

    touched_session = False
    try:
        status, health = request("runtime_identity", "/health?full=1")
        require(status == 200, "health_failed")
        scratch_identity(args.base_path, health)
        build = health.get("build", {})
        report["server"] = {key: build.get(key) for key in (
            "release_version", "binary_commit", "binary_commit_source", "executable_sha256")}
        # Entering Browser/Slack in the TUI initially selects live, before the
        # automation key is pressed. Verify that this is a public fixture or
        # absent; a private live read is never copied into public evidence.
        status, live = request("live_fixture_check", API + "/read", {"lane": "live", "app": "browser"})
        if status == 400 and live.get("error") == "browser lane is disconnected":
            report["live_fixture"] = "disconnected"
        else:
            require(status == 200 and live.get("ok") is True, "live_fixture_check_failed")
            data = live.get("data", {})
            require(isinstance(data.get("tabs"), list) and data["tabs"]
                    and all(tab.get("url") == EXAMPLE for tab in data["tabs"]),
                    "live_fixture_contains_nonpublic_example_tabs")
            public_page(data)
            report["live_fixture"] = "public_example_only"
        opened = good("automation_open", API + "/session", {"action": "open"})
        require(isinstance(opened, dict), "automation_open_result_invalid")
        require(opened.get("reused") is not True, "automation_session_already_owned")
        touched_session = True
        require(opened.get("reused") is False, "automation_open_ownership_not_confirmed")
        good("automation_navigate", API + "/goto", {"url": EXAMPLE})
        for number in range(1, 6):
            public_page(good(f"automation_read_{number}", API + "/read",
                             {"lane": "automation", "app": "browser"}))
        slack = good("slack_empty", API + "/read", {"lane": "automation", "app": "slack"})
        require(slack.get("tabs") == [] and slack.get("page") is None, "slack_was_not_empty")

        from playwright.sync_api import sync_playwright
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            try:
                with cap.ttyd_session(browser, args.base_path, args.api_port, args.cols,
                                      args.rows, args.base_path.name, args.executable, token) as page:
                    cap.press(page, ":")
                    page.keyboard.type("go Browser Lane", delay=20)
                    cap.press(page, "Enter")
                    wait(page, "Browser Lane")
                    cap.press(page, "a")
                    wait(page, "Browser Lane", "automation", "Example Domain")
                    capture(page, "01-browser-native")
                    cap.press(page, "S")
                    wait(page, "Slack Lane")
                    cap.press(page, "a")
                    wait(page, "Slack Lane", "automation", "Read ", "No matching tabs")
                    capture(page, "02-slack-empty")
                    cap.press(page, "B")
                    cap.press(page, "a")
                    wait(page, "Browser Lane", "automation", "Example Domain")
                    cap.press(page, "x")
                    wait(page, "closed", timeout=70)
                    status, closed = request("closed_session_read", API + "/read",
                                             {"lane": "automation", "app": "browser"})
                    require(status == 400 and closed.get("ok") is False
                            and "Firefox session is closed" in closed.get("error", ""),
                            "closed_session_was_not_confirmed")
                    capture(page, "04-session-closed")
                    cap.press(page, "o")
                    wait(page, "Read ", timeout=70)
                    cap.press(page, "g")
                    page.keyboard.press("Control+u")
                    recovered_url = EXAMPLE + "?q=qq-browser-lane"
                    page.keyboard.type(recovered_url, delay=10)
                    cap.press(page, "Enter")
                    wait(page, "Example Domain", timeout=70)
                    public_page(good("recovered_session_read", API + "/read",
                                     {"lane": "automation", "app": "browser"}), url=recovered_url)
                    capture(page, "05-session-recovered")
            finally:
                browser.close()
        report["result"] = "passed"
    except CaptureError as error:
        report["error_kind"] = str(error)
    except Exception as error:
        report["error_kind"] = type(error).__name__
    finally:
        if touched_session:
            try:
                good("cleanup_close", API + "/session", {"action": "close"})
            except Exception as error:
                report["cleanup_error_kind"] = type(error).__name__
                report["result"] = "failed"
        (args.out / "measurement.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"result": report["result"], "measurements": len(report["measurements"]),
                      "screenshots": report["screenshots"]}))
    return 0 if report["result"] == "passed" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        # Argument/file/library errors must not serialize a bearer or a page.
        print(json.dumps({"result": "failed", "error_kind": type(error).__name__}))
        raise SystemExit(1)
