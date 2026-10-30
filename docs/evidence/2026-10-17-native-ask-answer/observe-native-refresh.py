#!/usr/bin/env python3
"""Manual native refresh comparison on one isolated backend/workspace.

Capture HTTP facts and PTY cells for human inspection. Never assert screen text,
layout or row order. All questions are explicit persisted synthetic fixtures;
this observes reading/display, not Keeper question creation or real-model work.
Optional final-health response interventions exercise the actual enclosing
request's refusal path. A captured frame is not an automated UI verdict.
"""
import argparse
import codecs
import fcntl
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def durable(path, contents):
    temporary = path.with_suffix(".writing")
    with temporary.open("wb") as channel:
        os.chmod(temporary, 0o600)
        channel.write(contents)
        channel.flush()
        os.fsync(channel.fileno())
    temporary.replace(path)


def transport_logs(base):
    directory = base / ".masc" / "logs"
    return sorted(path for path in directory.rglob("*")
                  if path.is_file() and path.suffix in (".log", ".jsonl"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, required=True)
    parser.add_argument("--baseline-tui", type=Path, required=True)
    parser.add_argument("--candidate-tui", type=Path, required=True)
    parser.add_argument("--support", type=Path, required=True)
    parser.add_argument("--frame-renderer", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--columns", type=int, required=True)
    parser.add_argument("--rows", type=int, required=True)
    parser.add_argument("--health-delay", type=float, required=True)
    parser.add_argument("--sibling-delay", type=float, required=True)
    parser.add_argument("--final-health", choices=("same", "foreign", "booting", "failed"),
                        default="same", help="Response intervention after the warm question read")
    parser.add_argument("--only-arm", choices=("baseline", "candidate"))
    parser.add_argument("--submit-answer", action="store_true",
                        help="Observe native answer recording; requires a single isolated arm")
    args = parser.parse_args()
    if args.submit_answer and args.only_arm is None:
        parser.error("answer observation requires --only-arm to preserve a fresh durable queue")
    arms = [("baseline", args.baseline_tui), ("candidate", args.candidate_tui)]
    if args.only_arm is not None:
        arms = [(arm, binary) for arm, binary in arms if arm == args.only_arm]
    output = args.output.resolve()
    output.mkdir(mode=0o700)
    base = output / "workspace"
    base.mkdir(mode=0o700)
    sys.path.insert(0, str(args.support / "pty-python-dependencies"))
    spec = importlib.util.spec_from_file_location("native_frame_support", args.frame_renderer)
    support = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(support)
    import pyte

    env = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR", "LANG") if key in os.environ}
    env.update(MASC_BASE_PATH=str(base), XDG_CONFIG_HOME=str(base / "xdg"),
               TERM="xterm-256color", COLORTERM="truecolor")
    manifest = {"scope": "manual isolated native enclosing-refresh comparison", "base": str(base),
        "viewport": [args.columns, args.rows], "observer_sha256": digest(Path(__file__)),
        "frame_renderer_sha256": digest(args.frame_renderer),
        "health_delay_seconds": args.health_delay, "sibling_delay_seconds": args.sibling_delay,
        "final_health_intervention": args.final_health,
        "intervention_scope": "proxy response only after warm original Ask response; backend/workspace remain unchanged",
        "capture_status_scope": "captured means collection finished, not a workspace-admission or UI PASS",
        "native_answer_submission_requested": args.submit_answer,
        "keeper_action_observed": False,
        "input_scope": "one real backend and canonical workspace; synthetic persisted question appended before warm refresh, reset between arms",
        "frame_scope": "native PTY cell state rendered with pyte/fonts; no physical paint clock or UI assertions",
        "latency_distribution": None, "real_model_speedup": None,
        "expected_arms": [arm for arm, _ in arms], "environment_keys": sorted(env), "binaries": {}}
    for arm in manifest["expected_arms"]:
        (output / arm).mkdir(mode=0o700)
        dump(output / arm / "observation.json", {"arm": arm, "status": "unfinished"})
    dump(output / "manifest.json", manifest)
    server = proxy = None
    try:
        for role, binary, flag in (("server", args.server, "build-commit"),
                                  ("baseline", args.baseline_tui, "--build-commit"),
                                  ("candidate", args.candidate_tui, "--build-commit")):
            result = subprocess.run([str(binary), flag], env=env, capture_output=True, text=True, timeout=15)
            manifest["binaries"][role] = {"path": str(binary.resolve()), "sha256": digest(binary),
                "source": result.stdout.strip(), "returncode": result.returncode, "stderr": result.stderr}
            if result.returncode:
                raise RuntimeError(role + " embedded identity failed")
        dump(output / "manifest.json", manifest)
        result = subprocess.run([str(args.server), "init", "--base-path", str(base)], env=env,
                                capture_output=True, text=True, timeout=30)
        dump(output / "init.json", {"returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
        if result.returncode:
            raise RuntimeError("isolated initialization failed")
        profiles = base / ".masc/config/keepers"
        profiles.mkdir(parents=True, exist_ok=True)
        profile = '[keeper]\nactivation_mode = "manual"\nsandbox_profile = "docker"\nsandbox_image = "base"\nnetwork_mode = "inherit"\ninstructions = "Isolated native Ask observation. Remain manual."\n'
        (profiles / "probe-one.toml").write_text(profile)
        metadata = base / ".masc/keepers"
        metadata.mkdir(parents=True, exist_ok=True)
        meta = json.loads((args.support / "keeper-meta-fixture.json").read_text())
        dump(metadata / "probe-one.json", {**meta, "name": "probe-one", "trace_id": "trace-native-ask", "paused": False})
        with (base / ".masc/config/runtime.toml").open("a") as channel:
            channel.write('\n[tui]\nopening = "overview"\n')
        ask_dir = base / ".masc/keeper_ask"
        ask_dir.mkdir(mode=0o700, exist_ok=True)
        ask_log = ask_dir / "probe-one.jsonl"
        durable(ask_log, b"")
        event = {"event": "asked", "ask": {"ask_id": "native-ask-choice", "keeper_name": "probe-one",
            "asked_at": time.time(), "context": "진행 중인 결과를 보존했습니다. 다음 방향을 골라 주세요.",
            "turn_id": None, "task_id": None, "goal_id": None,
            "continuation": {"kind": "unrouted", "reason": "isolated native Ask read observation"},
            "questions": [{"question_id": "next-work", "header": "다음 작업",
                "prompt": "기존 작업을 이어갈까요, 새 작업으로 전환할까요?", "mode": "single",
                "choices": [{"choice_id": "continue", "label": "기존 작업 계속", "description": "지금까지 만든 결과에서 이어갑니다."},
                            {"choice_id": "new", "label": "새 작업 시작", "description": "현재 결과를 남겨 두고 다음 일을 시작합니다."}],
                "free_text": {"kind": "allowed", "hint": "다른 방향도 적을 수 있습니다."}}]}}
        fixture = (json.dumps(event, ensure_ascii=False) + "\n").encode()
        (output / "ask-fixture.jsonl").write_bytes(fixture)
        manifest["fixture_sha256"] = hashlib.sha256(fixture).hexdigest()
        manifest["profile_sha256"] = hashlib.sha256(profile.encode()).hexdigest()
        manifest["meta_fixture_sha256"] = digest(args.support / "keeper-meta-fixture.json")
        port = support.free_port()
        server_log = (output / "server.log").open("wb")
        server = subprocess.Popen([str(args.server), "start", "--base-path", str(base), "--port", str(port),
            "--host", "127.0.0.1"], env=env, cwd=base, stdout=server_log, stderr=subprocess.STDOUT, start_new_session=True)
        health = None
        for _ in range(600):
            if server.poll() is not None:
                raise RuntimeError("isolated backend exited during startup")
            try:
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.5)
                connection.request("GET", "/health?full=1")
                response = connection.getresponse()
                health = json.loads(response.read())
                connection.close()
                if health.get("paths", {}).get("effective_base_path") != str(base):
                    raise RuntimeError("isolated backend names another workspace")
                if health.get("startup", {}).get("state_ready") is True:
                    break
            except (OSError, http.client.HTTPException, json.JSONDecodeError):
                pass
            time.sleep(0.1)
        else:
            raise RuntimeError("startup observation window ended; no readiness proof")
        dump(output / "health.json", health)
        context = {"arm": None, "warm": False, "asks_returned": threading.Event(),
                   "answer_recorded": threading.Event()}
        observations = []
        observations_lock = threading.Lock()
        started = time.monotonic()

        class Proxy(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def log_message(self, *unused):
                pass
            def exchange(self):
                entered = time.monotonic()
                arm, warm = context["arm"], context["warm"]
                path = urlsplit(self.path).path
                delayed = warm and ((path == "/health" and context["asks_returned"].is_set()) or
                    path in ("/api/v1/dashboard/briefing", "/api/v1/operator"))
                entry = {"arm": arm, "warm": warm, "method": self.command, "target": self.path,
                    "path": path, "delayed": delayed, "started_ms": (entered-started)*1000, "state": "entered"}
                with observations_lock:
                    entry["request"] = len(observations)+1
                    observations.append(entry)
                if delayed:
                    time.sleep(args.health_delay if path == "/health" else args.sibling_delay)
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
                try:
                    headers = {key: value for key, value in self.headers.items()
                        if key.lower() not in ("host", "connection", "content-length")}
                    length = int(self.headers.get("Content-Length", 0))
                    body = self.rfile.read(length) if length else None
                    if path == "/api/v1/keepers/ask-answer" and body is not None:
                        entry["answer_request"] = json.loads(body)
                        entry["request_body_sha256"] = hashlib.sha256(body).hexdigest()
                    conn.request(self.command, self.path, body=body, headers=headers)
                    response = conn.getresponse()
                    if "text/event-stream" in response.getheader("Content-Type", ""):
                        self.send_response(response.status)
                        self.send_header("Content-Type", "text/event-stream")
                        self.send_header("Connection", "close")
                        self.end_headers()
                        while part := response.readline():
                            self.wfile.write(part)
                            self.wfile.flush()
                        entry["state"] = "stream_closed"
                        return
                    payload = response.read()
                    delivered_status = response.status
                    if (path == "/health" and warm and context["asks_returned"].is_set()
                            and args.final_health != "same" and response.status == 200):
                        entry.update(upstream_status=response.status,
                                     upstream_response_sha256=hashlib.sha256(payload).hexdigest(),
                                     health_intervention=args.final_health)
                        if args.final_health == "failed":
                            delivered_status = 503
                            payload = json.dumps({"error": "controlled final identity read failure"}).encode()
                        else:
                            value = json.loads(payload)
                            if args.final_health == "foreign":
                                value["paths"]["effective_base_path"] = str(base / "foreign")
                                value["paths"]["effective_masc_root"] = str(base / "foreign/.masc")
                            else:
                                value["startup"]["state_ready"] = False
                            payload = json.dumps(value, ensure_ascii=False).encode()
                    entry.update(status=delivered_status, response_bytes=len(payload),
                                 response_sha256=hashlib.sha256(payload).hexdigest())
                    if path == "/api/v1/keepers/ask-answer":
                        entry["answer_response"] = json.loads(payload)
                        answer = entry["answer_response"]
                        if (answer.get("recorded") is True
                                and answer.get("ask_id") == "native-ask-choice"):
                            context["answer_recorded"].set()
                    if path == "/api/v1/keepers/asks":
                        value = json.loads(payload)
                        entry["ask_ids"] = [row["ask_id"] for row in value.get("asks", [])]
                        allowed_ids = [["native-ask-choice"]] if warm else [[]]
                        if warm and args.submit_answer and context["answer_recorded"].is_set():
                            # A committed answer removes this question from the
                            # open list. A concurrent earlier snapshot may still
                            # carry its original row; neither is another Ask.
                            allowed_ids.append([])
                        entry["fixture_matches"] = response.status == 200 and entry["ask_ids"] in allowed_ids and value.get("workspace") == {
                                "base_path": str(base), "masc_root": str(base / ".masc")}
                        dump(output / arm / ("asks-warm.json" if warm else "asks-cold.json"), value)
                        if warm:
                            context["asks_returned"].set()
                    self.send_response(delivered_status)
                    for key, value in response.getheaders():
                        if key.lower() not in ("content-length", "transfer-encoding", "connection"):
                            self.send_header(key, value)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    self.wfile.flush()
                    entry["state"] = "returned"
                except (OSError, http.client.HTTPException, json.JSONDecodeError) as error:
                    entry["error"] = type(error).__name__
                    entry["state"] = "failed"
                finally:
                    entry["finished_ms"] = (time.monotonic()-started)*1000
                    conn.close()
            do_GET = exchange
            do_POST = exchange

        proxy = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
        proxy.daemon_threads = True
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        for arm, binary in arms:
            directory = output / arm
            receipt = {"arm": arm, "status": "started", "base": str(base),
                "fixture_sha256": manifest["fixture_sha256"], "captures": {}, "actions": []}
            dump(directory / "observation.json", receipt)
            context.update(arm=arm, warm=False, asks_returned=threading.Event(),
                           answer_recorded=threading.Event())
            durable(ask_log, b"")
            offsets = {path: path.stat().st_size for path in transport_logs(base)}
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", args.rows, args.columns, 0, 0))
            tui = subprocess.Popen([str(binary), "--base-path", str(base), "--port", str(proxy.server_port),
                "--refresh", "3600"], env=env, cwd=base, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            class Screen(pyte.Screen):
                def write_process_input(self, data):
                    os.write(master, data.encode())
                def report_device_status(self, mode, **kwargs):
                    if not kwargs.get("private"):
                        super().report_device_status(mode)
            screen = Screen(args.columns, args.rows)
            stream = pyte.Stream(screen)
            decoder = codecs.getincrementaldecoder("utf-8")("replace")
            begin = time.monotonic()
            actions = [(3, "work", b"\t"), (3.3, "approvals", b"p"), (6, "refresh", b"r"), (9.2, "answer-draft", b"a")]
            if args.submit_answer:
                actions += [(9.7, "choose-first", b"1"), (10, "arm-answer", b"\r"),
                            (10.3, "confirm-answer", b"\r")]
            snapshots = [(5.5, "cold"), (6.1, "warm-0.1"), (6.5, "warm-0.5"),
                         (7, "warm-1"), (8.5, "warm-2.5"), (9.5, "draft-3.5"), (15.5, "warm-9.5")]
            try:
                with (directory / "native.ansi").open("wb") as raw, (directory / "frames.jsonl").open("w") as frames:
                    while time.monotonic()-begin < 16:
                        elapsed = time.monotonic()-begin
                        if tui.poll() is not None:
                            raise RuntimeError("native TUI exited during capture")
                        while actions and elapsed >= actions[0][0]:
                            _, action, keys = actions.pop(0)
                            if action == "refresh":
                                durable(ask_log, fixture)
                                context["warm"] = True
                                receipt["warm_refresh_sent_ms"] = (time.monotonic()-started)*1000
                            os.write(master, keys)
                            receipt["actions"].append({"action": action, "keys_hex": keys.hex(),
                                "since_arm_started_ms": (time.monotonic()-begin)*1000,
                                "since_collector_started_ms": (time.monotonic()-started)*1000})
                        if select.select([master], [], [], 0.02)[0]:
                            data = os.read(master, 1024*1024)
                            raw.write(data)
                            stream.feed(decoder.decode(data))
                            frames.write(json.dumps({"elapsed_ms": (time.monotonic()-begin)*1000,
                                "native_ansi_bytes": raw.tell(),
                                "rows": screen.display}, ensure_ascii=False)+"\n")
                        while snapshots and elapsed >= snapshots[0][0]:
                            _, name = snapshots.pop(0)
                            captured = (time.monotonic()-started)*1000
                            receipt["captures"][name] = {"since_arm_started_ms": (time.monotonic()-begin)*1000,
                                "native_ansi_bytes": raw.tell(),
                                "since_warm_action_ms": captured-receipt["warm_refresh_sent_ms"]
                                if "warm_refresh_sent_ms" in receipt else None}
                            (directory / (name+".txt")).write_text("\n".join(screen.display)+"\n")
                            support.frame_image(screen, directory / (name+".png"))
                receipt["status"] = "captured"
            except Exception as error:
                receipt.update(status="failed", error_type=type(error).__name__, error=str(error))
            finally:
                support.stop(tui)
                os.close(master)
                selected = []
                for path in transport_logs(base):
                    with path.open("rb") as channel:
                        channel.seek(offsets.get(path, 0))
                        selected += [line.decode(errors="replace").rstrip() for line in channel
                            if b"tui_asks_early" in line or b"tui_http_refresh=" in line]
                dump(directory / "transport-observations.json", selected)
                dump(directory / "observation.json", receipt)
                print(json.dumps({"arm": arm, "status": receipt["status"]}), flush=True)
        dump(output / "manifest.json", manifest)
    finally:
        support.stop(server)
        if proxy is not None:
            proxy.shutdown()
            proxy.server_close()
            for arm in manifest["expected_arms"]:
                with observations_lock:
                    rows = [dict(row) for row in observations if row["arm"] == arm]
                dump(output / arm / "http-observations.json", rows)
                receipt_path = output / arm / "observation.json"
                receipt = json.loads(receipt_path.read_text())
                receipt["delivered_health_interventions"] = sum(
                    row.get("health_intervention") == args.final_health and row["state"] == "returned"
                    for row in rows) if args.final_health != "same" else 0
                if args.submit_answer:
                    saved = output / arm / "durable-after"
                    saved.mkdir(mode=0o700)
                    files = [ask_log]
                    files += sorted((base / ".masc/keepers/probe-one").glob("event-queue*"))
                    receipt["durable_after"] = []
                    for source in files:
                        if source.is_file():
                            contents = source.read_bytes()
                            (saved / source.name).write_bytes(contents)
                            receipt["durable_after"].append({"relative_source": str(source.relative_to(base)),
                                "saved_as": "durable-after/"+source.name,
                                "bytes": len(contents), "sha256": hashlib.sha256(contents).hexdigest()})
                    receipt["answer_requests"] = [row for row in rows
                        if row["path"] == "/api/v1/keepers/ask-answer"]
                asks = [row for row in rows if row["path"] == "/api/v1/keepers/asks"]
                receipt["fixture_verified"] = bool(asks) and any(row["warm"] for row in asks) and all(
                    row.get("fixture_matches") is True and row["state"] == "returned" for row in asks)
                if receipt["status"] == "captured" and not receipt["fixture_verified"]:
                    receipt["status"] = "fixture_unverified"
                dump(receipt_path, receipt)
    return 0 if all(json.loads((output / arm / "observation.json").read_text())["status"] == "captured"
                    for arm in manifest["expected_arms"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
