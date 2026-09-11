#!/usr/bin/env python3
"""Collect live Lane Add-on lifecycle evidence without claiming full acceptance.

Uses existing Browser/MSX bindings only. No browser creation, navigation, MSX
input, CI polling, deployment, or automatic interpretation of Keeper activity.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


class QualificationError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def private_write(path: Path, data: bytes):
    with path.open("xb") as stream:
        path.chmod(0o600)
        stream.write(data)


class Evidence:
    def __init__(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True)
        if any(directory.iterdir()):
            raise QualificationError("output directory must be empty to preserve earlier evidence")
        directory.chmod(0o700)
        self.root = directory
        self.lock = threading.Lock()
        self.index = 0
        self.events = []

    def record(self, event: dict, raw: bytes = b"") -> dict:
        with self.lock:
            self.index += 1
            name = f"{self.index:05d}-response.bin"
            private_write(self.root / name, raw)
            record = {**event, "body_path": name, "body_bytes": len(raw),
                      "body_sha256": hashlib.sha256(raw).hexdigest()}
            self.events.append(record)
            with (self.root / "events.jsonl").open("a", encoding="utf-8") as output:
                (self.root / "events.jsonl").chmod(0o600)
                output.write(json.dumps(record, ensure_ascii=False, allow_nan=False) + "\n")
            return record

    def json(self, name: str, value: dict):
        private_write(self.root / name, (json.dumps(value, ensure_ascii=False, indent=2,
                                                   allow_nan=False) + "\n").encode())


class API:
    def __init__(self, base_url: str, evidence: Evidence, *, token: str | None,
                 timeout: float, max_response_bytes: int):
        parsed = urllib.parse.urlsplit(base_url)
        if (parsed.scheme not in {"http", "https"} or not parsed.hostname
                or parsed.username or parsed.password or parsed.query or parsed.fragment
                or parsed.path not in {"", "/"}):
            raise QualificationError("base URL must be an HTTP(S) origin without credentials or query")
        self.base = base_url.rstrip("/")
        self.evidence = evidence
        self.timeout = timeout
        self.max_response_bytes = max_response_bytes
        self.headers = {"Accept": "application/json"}
        if token is not None:
            self.headers["Authorization"] = "Bearer " + token
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, method: str, path: str, body: dict | None = None, *, stage: str):
        headers = dict(self.headers)
        encoded = None
        if body is not None:
            encoded = json.dumps(body, allow_nan=False).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=encoded, headers=headers, method=method)
        start = time.perf_counter_ns()
        stamp = time.time()
        status, raw, failure = None, b"", None
        try:
            try:
                response = self.opener.open(request, timeout=self.timeout)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                status = response.status
                raw = response.read(self.max_response_bytes + 1)
            if len(raw) > self.max_response_bytes:
                failure = "response exceeds measurement envelope; captured prefix only"
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            failure = type(error).__name__
        event = self.evidence.record({"kind": "http", "stage": stage, "method": method,
            "path": path, "origin": self.base, "request_body": body, "observed_at": stamp,
            "duration_ms": (time.perf_counter_ns() - start) / 1_000_000,
            "status": status, "error": failure}, raw)
        if failure or status is None or not 200 <= status < 300:
            raise QualificationError(f"{method} {path}: request failed; inspect {event['body_path']}")
        try:
            return json.loads(raw)
        except json.JSONDecodeError as error:
            raise QualificationError(f"{method} {path}: response is not JSON; inspect {event['body_path']}") from error


def current_instance(api: API, instance_id: str, stage: str):
    snapshot = api.request("GET", "/api/v1/lane-addons?" + urllib.parse.urlencode({"instance_id": instance_id}),
                           stage=stage)
    matches = [row for row in snapshot.get("instances", []) if row.get("instance_id") == instance_id]
    if len(matches) != 1:
        raise QualificationError("inspect did not contain exactly the owned instance")
    return matches[0], snapshot


def await_instance(api: API, instance_id: str, predicate, *, stage: str,
                   wait_seconds: float, poll_interval: float):
    deadline = time.monotonic() + wait_seconds
    while True:
        instance, snapshot = current_instance(api, instance_id, stage)
        if predicate(instance):
            return instance, snapshot
        if instance.get("phase", {}).get("kind") == "failed":
            raise QualificationError("owned Add-on reports failure; inspect recorded response")
        if time.monotonic() >= deadline:
            raise QualificationError("operator observation deadline elapsed; instance remains unqualified")
        threading.Event().wait(min(poll_interval, max(0, deadline - time.monotonic())))


class HealthMeasurements:
    def __init__(self, api: API, interval: float):
        self.api = api
        self.interval = interval
        self.stop = threading.Event()
        self.stage = "active"
        self.thread = threading.Thread(target=self.collect, daemon=True)

    def sample(self, stage: str):
        try:
            self.api.request("GET", "/health", stage=stage)
        except QualificationError:
            pass  # The recorded failed request remains part of the sample.

    def collect(self):
        while not self.stop.is_set():
            self.sample(self.stage)
            self.stop.wait(self.interval)

    def finish(self):
        self.stop.set()
        self.thread.join(self.api.timeout + 2)
        if self.thread.is_alive():
            raise QualificationError("health measurement request has not finished")


def latency_summary(events: list[dict]) -> dict:
    groups = {}
    for event in events:
        if event.get("kind") == "http" and event.get("path") == "/health":
            groups.setdefault(event["stage"], []).append(event)
    result = {}
    for stage, samples in groups.items():
        values = sorted(event["duration_ms"] for event in samples)
        result[stage] = {"samples": len(values), "successful_http_reads": sum(
            event["error"] is None and event["status"] is not None and 200 <= event["status"] < 300
            for event in samples), "p50_ms": values[math.ceil(len(values) * .5) - 1],
            "p95_ms": values[math.ceil(len(values) * .95) - 1], "max_ms": values[-1]}
    return result


def docker_absence(command: str, container_id: str, evidence: Evidence, timeout: float) -> bool:
    def run(arguments):
        result = subprocess.run([command, *arguments], capture_output=True, timeout=timeout, check=False)
        evidence.record({"kind": "docker", "arguments": arguments, "exit_code": result.returncode,
                         "observed_at": time.time()}, result.stdout + b"\nSTDERR\n" + result.stderr)
        return result
    # An inspect failure alone could be a disconnected daemon, not absence.
    inspect = run(["container", "inspect", "--format", "{{json .Id}}", container_id])
    if inspect.returncode == 0:
        return False
    daemon = run(["info", "--format", "{{json .ID}}"])
    remaining = run(["container", "ls", "--all", "--no-trunc", "--filter", "id=" + container_id,
                     "--format", "{{json .ID}}"])
    return daemon.returncode == 0 and remaining.returncode == 0 and not remaining.stdout.strip()


def positive(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive and finite")
    return parsed


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--base-url", required=True)
    p.add_argument("--manifest", action="append", required=True,
                   help="absolute package manifest path as seen by the MASC server; repeat for each package")
    p.add_argument("--binding", action="append", required=True, type=Path,
                   help="local binding JSON paired by position with --manifest")
    p.add_argument("--output-dir", required=True, type=Path)
    p.add_argument("--token-file", type=Path, help="existing bearer credential; value is never printed or journaled")
    p.add_argument("--run-id", default=None)
    p.add_argument("--wait-seconds", type=positive, default=60,
                   help="operator's finite observation wait, not a Keeper or production lifecycle limit")
    p.add_argument("--poll-interval", type=positive, default=.5)
    p.add_argument("--http-timeout", type=positive, default=15)
    p.add_argument("--health-samples", type=int, default=10)
    p.add_argument("--health-interval", type=positive, default=.25)
    p.add_argument("--max-response-bytes", type=int, default=8 * 1024 * 1024)
    p.add_argument("--docker", help="optional Docker executable in the server daemon context")
    p.add_argument("--keeper-name", help="explicitly deliver selected Add-on evidence to this existing Keeper")
    p.add_argument("--deliver-addon-id", help="required with --keeper-name; only this package's relation rows are sent")
    return p


def run(args) -> int:
    if len(args.manifest) != len(args.binding):
        raise QualificationError("each --manifest needs one corresponding --binding")
    if args.health_samples < 1 or args.max_response_bytes < 1:
        raise QualificationError("measurement sample count and response envelope must be positive")
    if bool(args.keeper_name) != bool(args.deliver_addon_id):
        raise QualificationError("--keeper-name and --deliver-addon-id must be supplied together")
    if any(not Path(path).is_absolute() for path in args.manifest):
        raise QualificationError("manifest paths must be absolute server paths")
    bindings = [json.loads(path.read_text()) for path in args.binding]
    if any(not isinstance(binding, dict) for binding in bindings):
        raise QualificationError("binding files must contain objects")
    token = args.token_file.read_text().strip() if args.token_file else None
    if token == "" or (token is not None and ("\n" in token or "\r" in token)):
        raise QualificationError("token file must contain one nonempty credential")
    evidence = Evidence(args.output_dir)
    api = API(args.base_url, evidence, token=token, timeout=args.http_timeout,
              max_response_bytes=args.max_response_bytes)
    run_id = args.run_id or "lane-qualification-" + str(uuid.uuid4())
    manifest_refs = [{"server_path": path,
                      "local_sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest()
                      if Path(path).is_file() else None} for path in args.manifest]
    evidence.json("run.json", {"run_id": run_id, "origin": api.base, "manifests": manifest_refs,
        "binding_sha256": [hashlib.sha256(path.read_bytes()).hexdigest() for path in args.binding],
        "started_at": time.time(), "keeper_delivery_requested": args.keeper_name is not None,
        "performance_tolerance": None, "existing_browser_and_machine_only": True})
    primary = HealthMeasurements(api, args.health_interval)
    owned, results, errors = [], [], []
    try:
        api.request("GET", "/health?full=1", stage="identity_before")
        for _ in range(args.health_samples):
            primary.sample("baseline")
            primary.stop.wait(args.health_interval)
        primary.thread.start()
        for manifest, binding in zip(args.manifest, bindings):
            primary.stage = "attaching"
            attached = api.request("POST", "/api/v1/lane-addons/attach",
                                   {"manifest_path": manifest, "run_id": run_id, "binding": binding}, stage="attach")
            instance_id = attached.get("instance_id")
            if not isinstance(instance_id, str) or not instance_id:
                raise QualificationError("attach returned no instance identity; inspect run_id manually")
            owned.append(instance_id)
            result = {"instance_id": instance_id, "addon_id": attached.get("addon_id"),
                      "container_id": attached.get("container_id"), "detached": False}
            results.append(result)
            primary.stage = "observing"
            ready, snapshot = await_instance(api, instance_id,
                lambda item: isinstance(item.get("observation_seq"), int) and item["observation_seq"] > 0,
                stage="inspect", wait_seconds=args.wait_seconds, poll_interval=args.poll_interval)
            result.update({"container_id": ready.get("container_id"),
                           "observation_seq": ready["observation_seq"]})
            rows = [row for row in snapshot.get("rows", [])
                    if row.get("lane_id", "").split("/", 1)[0] == instance_id]
            result["row_count"] = len(rows)
            if rows:
                selected = [row for row in rows if row.get("kind") == "relation"] or rows
                body = {"instance_id": instance_id, "row_ids": [row["id"] for row in selected]}
                result["selected_row_ids"] = body["row_ids"]
                if args.keeper_name and attached.get("addon_id") == args.deliver_addon_id:
                    if not all(row.get("kind") == "relation" for row in selected):
                        raise QualificationError("selected package has no relation rows to deliver")
                    body["keeper_name"] = args.keeper_name
                result["frozen_evidence"] = api.request("POST", "/api/v1/lane-addons/evidence", body, stage="evidence")
            primary.stage = "slice"
            api.request("GET", "/api/v1/lane-addons/slice?" + urllib.parse.urlencode({"run_id": run_id}), stage="slice")
            api.request("POST", "/api/v1/lane-addons/observe", {"instance_id": instance_id}, stage="observe")
            await_instance(api, instance_id, lambda item: item.get("observation_seq", 0) > ready["observation_seq"],
                           stage="inspect_refresh", wait_seconds=args.wait_seconds, poll_interval=args.poll_interval)
    except (QualificationError, OSError, ValueError, subprocess.SubprocessError) as error:
        errors.append(str(error))
    finally:
        primary.stage = "detaching"
        for instance_id in owned:
            result = next(row for row in results if row["instance_id"] == instance_id)
            try:
                before, _ = current_instance(api, instance_id, "inspect_before_detach")
                result["container_id"] = before.get("container_id") or result.get("container_id")
            except QualificationError as error:
                errors.append("pre-cleanup inspection: " + str(error))
            try:
                api.request("POST", "/api/v1/lane-addons/detach", {"instance_id": instance_id}, stage="detach")
                await_instance(api, instance_id, lambda item: item.get("phase", {}).get("kind") == "detached",
                               stage="inspect_detach", wait_seconds=args.wait_seconds, poll_interval=args.poll_interval)
                result["detached"] = True
                retained = api.request("GET", "/api/v1/lane-addons/slice?" + urllib.parse.urlencode({"run_id": run_id}),
                                       stage="slice_after_detach")
                retained_ids = {row["id"] for row in retained.get("rows", [])}
                result["rows_survive_detach"] = all(row_id in retained_ids
                    for row_id in result.get("selected_row_ids", []))
                if not result["rows_survive_detach"]:
                    errors.append("selected rows were missing from the retained slice after detach")
                if args.docker and result.get("container_id"):
                    result["docker_absent"] = docker_absence(args.docker, result["container_id"], evidence, args.http_timeout)
                    if not result["docker_absent"]:
                        errors.append("owned container absence was not independently confirmed")
            except (QualificationError, OSError, subprocess.SubprocessError) as error:
                errors.append("cleanup: " + str(error))
        if primary.thread.ident is not None:
            try:
                primary.finish()
            except QualificationError as error:
                errors.append(str(error))
    summary = {"run_id": run_id, "status": "measurements_collected" if not errors else "incomplete",
        "full_v0_qualification": False, "instances": results, "errors": errors,
        "health_latency": latency_summary(evidence.events),
        "unassessed": ["actual Keeper evidence consumption and corrective action",
                       "independent same-document verification after correction",
                       "MSX controller progress and noninterference under faults",
                       "TUI and Dashboard screenshots", "user-approved performance tolerance",
                       "independent retained source bytes and hashes after source rotation"],
        "note": "Health GET completion measures server responsiveness, not Keeper or game progress."}
    evidence.json("summary.json", summary)
    print(json.dumps({"status": summary["status"], "full_v0_qualification": False,
                      "summary": str(evidence.root / "summary.json")}, ensure_ascii=False))
    return 0 if not errors else 1


if __name__ == "__main__":
    try:
        raise SystemExit(run(parser().parse_args()))
    except (QualificationError, OSError, ValueError) as error:
        raise SystemExit(str(error))
