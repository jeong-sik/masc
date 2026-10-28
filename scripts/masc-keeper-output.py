#!/usr/bin/env python3
"""Watch redacted Keeper Execute output from a MASC server.

This is an observation client. Reconnecting repeats a read, never an Execute.
The server's in-memory history is bounded, and a new snapshot can replay rows.
"""
from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request


def safe_text(value: object) -> str:
    text = str(value)
    return "".join(ch if not unicodedata.category(ch).startswith("C") else "�" for ch in text)


class Output:
    def __init__(self, path: str | None):
        self.lock = threading.Lock()
        self.log = None
        if path:
            flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
            fd = os.open(path, flags, 0o600)
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
                os.close(fd)
                raise ValueError("the JSONL log must be a private regular file (mode 0600)")
            self.log = os.fdopen(fd, "a", encoding="utf-8")

    def message(self, keeper: str, message: str) -> None:
        with self.lock:
            print(f"[{safe_text(keeper)}] {safe_text(message)}", flush=True)

    def event(self, keeper: str, event: dict) -> None:
        with self.lock:
            if self.log:
                self.log.write(json.dumps({"keeper": keeper, "event": event}, ensure_ascii=True) + "\n")
                self.log.flush()
            kind = event.get("type")
            if kind == "snapshot":
                first = event.get("first_retained_seq")
                if isinstance(first, int) and first > 1:
                    print(f"[{safe_text(keeper)}] earlier events before seq {first} are no longer retained", flush=True)
                active = event.get("active_count")
                state = f"{active} active" if isinstance(active, int) and active else ("closed" if event.get("closed") else "open")
                print(f"[{safe_text(keeper)}] snapshot: {state}", flush=True)
                for line in event.get("lines", []):
                    if isinstance(line, dict):
                        self._line(keeper, line)
            elif kind == "line" and isinstance(event.get("line"), dict):
                self._line(keeper, event["line"])
            elif kind == "gap":
                print(f"[{safe_text(keeper)}] missing output events {safe_text(event.get('missing_from_seq'))}–{safe_text(event.get('missing_to_seq'))}", flush=True)
            elif kind == "task_opened":
                print(f"[{safe_text(keeper)}] opened stream={safe_text(event.get('stream_id'))} task={safe_text(event.get('task_id'))}", flush=True)
            elif kind == "task_closed":
                status = json.dumps(event.get("status"), ensure_ascii=True, separators=(",", ":"))
                print(f"[{safe_text(keeper)}] closed stream={safe_text(event.get('stream_id'))} status={safe_text(status)} active={safe_text(event.get('active_count', '?'))}", flush=True)
            elif kind == "no_task":
                print(f"[{safe_text(keeper)}] no Execute output observed in this server process", flush=True)
            elif kind == "error":
                print(f"[{safe_text(keeper)}] {safe_text(event.get('message', 'stream error'))}", flush=True)

    @staticmethod
    def _line(keeper: str, line: dict) -> None:
        print(f"[{safe_text(keeper)} #{safe_text(line.get('stream_id', '?'))} {safe_text(line.get('stream', '?'))} task={safe_text(line.get('task_id'))}] {safe_text(line.get('text', ''))}", flush=True)

    def close(self) -> None:
        if self.log:
            self.log.close()


def stream_events(response):
    data = []
    for raw in response:
        line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
        if not line:
            if data:
                try:
                    event = json.loads("\n".join(data))
                except json.JSONDecodeError as exc:
                    raise ValueError("invalid SSE JSON") from exc
                if not isinstance(event, dict):
                    raise ValueError("invalid SSE event")
                yield event
                data = []
        elif line.startswith("data:"):
            data.append(line[5:].removeprefix(" "))
    if data:
        raise ValueError("stream ended in the middle of an SSE frame")


def watch(keeper, server, headers, output, stop, reconnect, failed):
    url = server + "/api/v1/dashboard/execute-output/" + urllib.parse.quote(keeper, safe="")
    while not stop.is_set():
        try:
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=45) as response:
                if response.headers.get_content_type() != "text/event-stream":
                    raise ValueError("server did not return an event stream")
                for event in stream_events(response):
                    if stop.is_set():
                        return
                    if event.get("keeper") != keeper.lower():
                        raise ValueError("event belongs to another Keeper")
                    output.event(keeper, event)
            output.message(keeper, "connection ended; execution state is unconfirmed")
        except urllib.error.HTTPError as exc:
            output.message(keeper, f"server refused output stream (HTTP {exc.code})")
            failed.set()
            return
        except (OSError, ValueError, urllib.error.URLError) as exc:
            output.message(keeper, f"output unavailable: {exc}; execution state is unconfirmed")
            if not reconnect:
                failed.set()
                return
        if not reconnect:
            return
        output.message(keeper, "reconnecting; the next snapshot may repeat retained output")
        stop.wait(2.0)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("keepers", nargs="+", help="Keeper names to observe")
    parser.add_argument("--server", required=True, help="MASC server URL, e.g. http://127.0.0.1:8935")
    parser.add_argument("--agent", default=os.environ.get("MASC_AGENT_NAME", "masc-tui"), help="identity matching MASC_TOKEN")
    parser.add_argument("--jsonl", help="append received events to this private 0600 JSONL file")
    parser.add_argument("--no-reconnect", action="store_true", help="exit when the connection ends")
    args = parser.parse_args(argv)
    parsed = urllib.parse.urlsplit(args.server)
    if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.username:
        parser.error("--server must be an http(s) origin without credentials or a path")
    keepers = [name.strip().lower() for name in args.keepers]
    if any(not name for name in keepers) or len(set(keepers)) != len(keepers):
        parser.error("Keeper names must be nonempty and unique")
    token = os.environ.get("MASC_TOKEN", "").strip()
    if any(ch in args.agent for ch in "\r\n") or any(ch in token for ch in "\r\n"):
        parser.error("agent and token must be single-line values")
    headers = {"Accept": "text/event-stream", "X-MASC-Agent": args.agent}
    if token:
        headers["Authorization"] = "Bearer " + token
    try:
        output = Output(args.jsonl)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    stop, failed = threading.Event(), threading.Event()
    workers = [threading.Thread(target=watch, args=(name, args.server.rstrip("/"), headers, output, stop, not args.no_reconnect, failed), daemon=True) for name in keepers]
    try:
        for worker in workers:
            worker.start()
        while any(worker.is_alive() for worker in workers):
            time.sleep(0.1)
    except KeyboardInterrupt:
        stop.set()
    finally:
        stop.set()
        output.close()
    return 1 if failed.is_set() else 0


if __name__ == "__main__":
    raise SystemExit(main())
