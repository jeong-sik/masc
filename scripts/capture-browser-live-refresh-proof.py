#!/usr/bin/env python3
"""Observe successful automatic Slack empty-state reads through a loopback proxy.

Requires a scratch MASC server and a live Firefox profile containing only
https://example.org/. Saves no tokens, headers, private page bodies or sessions.
"""
import argparse
from contextlib import contextmanager
import http.server
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import time
import urllib.error
import urllib.request


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@contextmanager
def proxy(opener, upstream):
    events, lock = [], threading.Lock()
    started = time.monotonic()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            self.forward()

        def do_POST(self):
            self.forward()

        def forward(self):
            data = self.rfile.read(int(self.headers.get("Content-Length", "0"))) or None
            request = urllib.request.Request(upstream + self.path, data=data, method=self.command,
                headers={k: v for k, v in self.headers.items() if k.lower() not in {"host", "content-length", "connection"}})
            try:
                try:
                    response = opener.open(request, timeout=65)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    body, status = response.read(), response.status
                    content_type = response.headers.get("Content-Type", "application/json")
                if self.path == "/api/v1/dashboard/browser-lane/read":
                    requested, returned = json.loads(data), json.loads(body)
                    with lock:
                        events.append({"elapsed_ms": round((time.monotonic() - started) * 1000, 1),
                            "app": requested.get("app"), "lane": requested.get("lane"),
                            "status": status, "ok": returned.get("ok")})
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except (OSError, ValueError):
                # Never copy request headers or response bodies into error logs.
                self.close_connection = True

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def snapshot():
        with lock:
            return list(events)

    try:
        yield server.server_port, snapshot
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--base-path", type=Path, required=True)
    parser.add_argument("--api-port", type=int, required=True)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--refresh-seconds", type=int, default=2)
    parser.add_argument("--observation-seconds", type=int, default=7)
    args = parser.parse_args()
    repo, base = args.repo.resolve(), args.base_path.resolve()
    core = load("browser_proof", repo / "scripts/capture-browser-slack-proof.py")
    cap = load("tui_capture", repo / "scripts/capture-tui-lane-runs.py")
    core.require(args.refresh_seconds > 0 and args.observation_seconds > 0, "invalid_refresh_window")
    token = cap.read_token_file(args.token_file)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), core.NoRedirect())
    upstream = f"http://127.0.0.1:{args.api_port}"

    def request(path, data=None):
        req = urllib.request.Request(upstream + path, data=None if data is None else json.dumps(data).encode(),
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        with opener.open(req, timeout=65) as response:
            return json.load(response)

    health = request("/health?full=1")
    core.scratch_identity(base, health)
    fixture = request(core.API + "/read", {"lane": "live", "app": "browser"})
    core.require(fixture.get("ok") is True, "live_fixture_unavailable")
    data = fixture["data"]
    core.require(data.get("tabs") and all(tab.get("url") == core.EXAMPLE for tab in data["tabs"]),
                 "live_fixture_contains_nonpublic_example_tabs")
    core.public_page(data)
    report = {"result": "failed", "refresh_seconds": args.refresh_seconds,
        "observation_seconds": args.observation_seconds, "tui_sha256": cap.sha256_file(args.executable),
        "server_commit": health.get("build", {}).get("binary_commit"),
        "upstream_api_port": args.api_port, "authenticated_slack_content_measured": False,
        "measurement": "completed read responses through loopback proxy; native host binary identity supplied separately"}
    args.out.mkdir(parents=True, exist_ok=True)
    try:
        from playwright.sync_api import sync_playwright
        with tempfile.TemporaryDirectory(prefix="browser-refresh-tui-") as temporary:
            launcher = Path(temporary) / "tui"
            launcher.write_text("#!/usr/bin/env python3\nimport os,sys\na=sys.argv[1:]\na[a.index('--refresh')+1]="
                + repr(str(args.refresh_seconds)) + "\nos.execv(" + repr(str(args.executable.resolve()))
                + ", ['masc-tui']+a)\n")
            launcher.chmod(0o700)
            with proxy(opener, upstream) as (port, snapshot), sync_playwright() as playwright:
                browser = playwright.chromium.launch()
                try:
                    with cap.ttyd_session(browser, base, port, 150, 42, base.name, launcher, token) as page:
                        cap.press(page, ":")
                        page.keyboard.type("go Browser Lane")
                        cap.press(page, "Enter")
                        cap.wait_text(page, "Browser Lane", "Example Domain", timeout=55)
                        for app, key, name in [("browser", None, "06-browser-live-full-width"),
                                               ("slack", "S", "07-slack-live-auto-refresh")]:
                            if key:
                                cap.press(page, key)
                                cap.wait_text(page, "Slack Lane", "No matching tabs", timeout=55)
                                before = len(snapshot())
                                page.wait_for_timeout(args.observation_seconds * 1000)
                                events = snapshot()
                                successes = [event for event in events[before:] if event["app"] == app
                                    and event["lane"] == "live" and event["status"] == 200 and event["ok"] is True]
                                core.require(len(successes) >= 2, "automatic_successful_reads_not_observed")
                                report.update(automatic_slack_live_read_count=len(successes), events=events)
                            text = cap.screen_text(page)
                            core.require("[Fleet]" not in text and "no keeper selected" not in text.lower(), "not_full_width")
                            page.locator(".xterm-screen").screenshot(path=str(args.out / (name + ".png")))
                            (args.out / (name + ".txt")).write_text(text)
                finally:
                    browser.close()
        report["result"] = "passed"
    except Exception as error:
        report["error_kind"] = type(error).__name__
    finally:
        (args.out / "live-refresh.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"result": report["result"], "automatic_slack_live_read_count": report.get("automatic_slack_live_read_count")}))
    return 0 if report["result"] == "passed" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({"result": "failed", "error_kind": type(error).__name__}))
        raise SystemExit(1)
