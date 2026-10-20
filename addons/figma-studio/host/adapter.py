#!/usr/bin/env python3
"""Host adapter from an isolated Lane Addon to the independent Figma Studio v1 API."""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import json
from pathlib import Path
import sqlite3
import stat
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request

from mcp_client import ApplicationRefused, McpClient, NoRedirect, RequestTooLarge, TransportError, encode, request_timeout
from private_state import PrivateState

PROTOCOL = "figma-studio/1"
REQUIRED = {"native.capture", "native.apply", "snapshot.read", "operation.readback", "rest.capture"}
DOCUMENT_FIELDS = ("name", "page_id", "selection", "editor_type", "mode", "can_edit")


class ServiceRefused(RuntimeError):
    pass


class FigmaApi:
    def __init__(self, url, token, *, timeout: float = 30, max_bytes=33554432):
        address = urllib.parse.urlsplit(url)
        if address.scheme != "http" or address.hostname != "127.0.0.1" or address.username or address.password or address.path not in ("", "/") or address.query or address.fragment:
            raise ValueError("Use the local Figma service root URL without credentials")
        if not token:
            raise ValueError("Configure the independent service's client credential")
        self.url, self.token = url.rstrip("/"), token
        self.timeout, self.max_bytes = request_timeout(timeout), max_bytes
        self.opener = urllib.request.build_opener(NoRedirect())

    def call(self, path, body):
        payload = encode(body)
        if len(payload) > self.max_bytes:
            raise RequestTooLarge("Figma API request exceeds its envelope")
        request = urllib.request.Request(self.url + path, data=payload, headers={
            "Content-Type": "application/json", "Authorization": "Bearer " + self.token,
        })
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                raw = response.read(self.max_bytes + 1)
        except urllib.error.HTTPError as error:
            try:
                detail = json.loads(error.read(self.max_bytes)).get("error", "Request refused")
            except (OSError, http.client.HTTPException) as interrupted:
                raise TransportError("Figma service error response was interrupted") from interrupted
            except (ValueError, AttributeError):
                detail = "Request refused"
            finally:
                error.close()
            raise ServiceRefused(f"Figma service HTTP {error.code}: {detail}") from error
        except (OSError, http.client.HTTPException) as error:
            raise TransportError("Figma service request outcome is unknown") from error
        if len(raw) > self.max_bytes:
            raise TransportError("Figma service response exceeds its envelope")
        try:
            value = json.loads(raw)
        except ValueError as error:
            raise TransportError("Figma service returned invalid JSON") from error
        if not isinstance(value, dict):
            raise TransportError("Figma service did not return an object")
        return value

    def info(self):
        value = self.call("/v1/info", {})
        capabilities = value.get("capabilities")
        if value.get("protocol") != PROTOCOL or not isinstance(capabilities, list) or not all(isinstance(item, str) for item in capabilities) or not REQUIRED.issubset(capabilities):
            raise ServiceRefused("Unsupported Figma service protocol or capabilities")
        if not isinstance(value.get("service_id"), str) or not value["service_id"]:
            raise ServiceRefused("Figma service omitted its incarnation identity")
        maximum = value.get("max_request_bytes")
        if type(maximum) is not int or maximum <= 0:
            raise ServiceRefused("Figma service omitted its request envelope")
        self.max_bytes = maximum
        return value

    def readback(self, identity):
        raw = bytearray()
        digest, total = None, None
        while True:
            chunk = self.call("/v1/readback", {"operation_id": identity, "offset": len(raw)})
            if chunk.get("encoding") != "json-utf8" or chunk.get("offset") != len(raw):
                raise TransportError("Figma readback encoding or offset mismatch")
            if digest is None:
                digest, total = chunk.get("sha256"), chunk.get("total_bytes")
                if not isinstance(digest, str) or type(total) is not int or total <= 0:
                    raise TransportError("Figma readback omitted its digest or length")
            if (chunk.get("sha256"), chunk.get("total_bytes")) != (digest, total):
                raise TransportError("Figma readback changed during retrieval")
            try:
                part = base64.b64decode(chunk["data_base64"], validate=True)
            except (ValueError, KeyError, TypeError) as error:
                raise TransportError("Figma readback has invalid byte encoding") from error
            if not part or total is None or len(raw) + len(part) > total:
                raise TransportError("Figma readback made no progress or exceeded its length")
            raw.extend(part)
            if chunk.get("next_offset") is None:
                break
            if chunk["next_offset"] != len(raw):
                raise TransportError("Figma readback next offset mismatch")
        if len(raw) != total or hashlib.sha256(raw).hexdigest() != digest:
            raise TransportError("Figma readback digest or length mismatch")
        try:
            result = json.loads(raw)
        except ValueError as error:
            raise TransportError("Figma readback contains invalid JSON") from error
        if not isinstance(result, dict) or type(result.get("ok")) is not bool or not isinstance(result.get("payload"), dict):
            raise TransportError("Figma readback has invalid result shape")
        return result


def compact_result(result, fits):
    """Retain changed-node identities when a service result exceeds MCP framing."""
    payload = result["payload"]
    completed = payload.get("completed", []) if isinstance(payload, dict) else []
    if not isinstance(completed, list):
        completed = []
    total = payload.get("completed_count") if isinstance(payload, dict) else None
    if type(total) is not int or total < len(completed):
        omitted = payload.get("completed_omitted", 0) if isinstance(payload, dict) else 0
        total = len(completed) + (omitted if type(omitted) is int and omitted >= 0 else 0)
    identities = [{"index": row.get("index", index), **{key: row[key] for key in ("op", "node_id") if isinstance(row.get(key), str)}}
                  if isinstance(row, dict) else {"index": index} for index, row in enumerate(completed)]

    def receipt(count):
        return {**result, "ok": False, "payload": {
            "status": "outcome_unknown", "error": "Readback exceeds the MCP envelope; inspect the document",
            "completed_count": total, "completed": identities[:count],
            "completed_omitted": total - count, "details_omitted": True,
        }}

    if not fits(receipt(0)):
        raise RequestTooLarge("MCP cannot hold the operation receipt")
    low, high = 0, len(identities)
    while low < high:
        mid = (low + high + 1) // 2
        if fits(receipt(mid)):
            low = mid
        else:
            high = mid - 1
    return receipt(low)


class Adapter:
    def __init__(self, client, figma, directory):
        self.client, self.figma = client, figma
        self.lease = PrivateState(directory)
        try:
            self.db = sqlite3.connect(self.lease.database("adapter.sqlite3"))
            self._initialize()
        except BaseException:
            if hasattr(self, "db"):
                self.db.close()
            self.lease.close()
            raise

    def close(self):
        try:
            self.db.close()
        finally:
            self.lease.close()

    def _initialize(self):
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("""CREATE TABLE IF NOT EXISTS deliveries (
            id TEXT NOT NULL, boot TEXT NOT NULL, service TEXT NOT NULL,
            kind TEXT NOT NULL, command TEXT NOT NULL, state TEXT NOT NULL, result TEXT,
            PRIMARY KEY(kind,id))""")
        self.db.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        binding = hashlib.sha256(encode([self.client.url, self.client.token, self.figma.url, self.figma.token])).hexdigest()
        old = self.db.execute("SELECT value FROM metadata WHERE key='binding'").fetchone()
        if old and old[0] != binding:
            raise ValueError("Adapter state belongs to different endpoints or credentials; use a new state directory")
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO metadata VALUES ('binding',?)", (binding,))

    def remember(self, command, boot, service, kind):
        identity = command["id"]
        prior = self.db.execute("SELECT * FROM deliveries WHERE kind=? AND id=?", (kind, identity)).fetchone()
        if prior:
            if (prior["boot"], prior["service"], prior["kind"], prior["command"]) != (boot, service, kind, json.dumps(command, sort_keys=True)):
                raise ServiceRefused("Operation identity was reused across different input or incarnations")
            return False
        with self.db:
            self.db.execute("INSERT INTO deliveries VALUES (?,?,?,?,?,'submitted',NULL)",
                            (identity, boot, service, kind, json.dumps(command, sort_keys=True)))
        return True

    def store_result(self, kind, identity, result):
        with self.db:
            self.db.execute("UPDATE deliveries SET state='result',result=? WHERE kind=? AND id=?",
                            (json.dumps(result, sort_keys=True), kind, identity))

    def close_dead_session_jobs(self, boot, service, live):
        """Close submitted jobs whose session vanished from a status poll.

        A job stays submitted while its service-side operation is prepared or
        dispatched; without liveness, a dead session's jobs wait forever and
        could execute late after a reconnect. A current-boot, current-service
        plugin job whose session is absent from this poll is closed with a
        failure instead of being left submitted. Rest jobs carry no session,
        and other boots/services keep their read-reconciliation path.
        """
        rows = self.db.execute(
            "SELECT * FROM deliveries WHERE state='submitted' AND kind!='rest' AND boot=? AND service=?",
            (boot, service)).fetchall()
        for row in rows:
            try:
                session = json.loads(row["command"]).get("session_id")
            except ValueError:
                session = None
            if session not in live:
                self.store_result(row["kind"], row["id"],
                                  self.failure("Figma session is no longer live; job closed without execution"))

    @staticmethod
    def failure(error):
        return {"ok": False, "payload": {"status": "outcome_unknown", "error": str(error)}}

    def deliver(self, row):
        result = json.loads(row["result"])
        command = json.loads(row["command"])
        args = {"kind": "rest_result" if row["kind"] == "rest" else "result",
                "worker_boot_id": row["boot"], "operation_id": row["id"], **result}
        if row["kind"] != "rest":
            args["session_id"] = command["session_id"]

        def compact(fits):
            shortened = compact_result(args, fits)
            # Retain the exact payload before network delivery; a lost ACK
            # cannot turn a previously accepted compact receipt into a new one.
            self.store_result(row["kind"], row["id"], {"ok": shortened["ok"], "payload": shortened["payload"]})
            return shortened

        try:
            self.client.call("masc_figma_relay", args, compact=compact)
        except ApplicationRefused:
            # The host proved this old delivery cannot change its current owner.
            with self.db:
                self.db.execute("UPDATE deliveries SET state='obsolete' WHERE kind=? AND id=?", (row["kind"], row["id"]))
            return
        with self.db:
            self.db.execute("UPDATE deliveries SET state='acknowledged' WHERE kind=? AND id=?", (row["kind"], row["id"]))

    def collect(self):
        for row in self.db.execute("SELECT * FROM deliveries WHERE state='submitted'").fetchall():
            if row["kind"] == "rest":
                # A lost synchronous REST reply cannot authorize another request.
                self.store_result(row["kind"], row["id"], self.failure("REST response was not retained; inspect service snapshots"))
                continue
            try:
                operation = self.figma.call("/v1/operation", {"operation_id": row["id"]})
            except ServiceRefused as error:
                self.store_result(row["kind"], row["id"], self.failure(error))
                continue
            if operation.get("service_id") != row["service"]:
                self.store_result(row["kind"], row["id"], self.failure("Figma operation incarnation mismatch"))
            elif operation.get("state") in ("prepared", "dispatched"):
                continue
            else:
                result = operation.get("result") or {}
                raw = self.figma.readback(row["id"]) if result.get("readback_available") else None
                self.store_result(row["kind"], row["id"], raw if isinstance(raw, dict) else self.failure(result.get("reason", "Figma operation has no completed readback")))
        for row in self.db.execute("SELECT * FROM deliveries WHERE state='result'").fetchall():
            self.deliver(row)

    def step(self):
        # Version negotiation precedes any host dequeue or external write.
        info = self.figma.info()
        status = self.client.call("masc_figma_relay", {"kind": "status"})
        boot = status["worker_boot_id"]
        self.client.max_bytes = status["max_request_bytes"]
        self.collect()
        sessions = self.figma.call("/v1/status", {}).get("sessions", [])
        live = set()
        for session in sessions:
            if not isinstance(session, dict) or not all(key in session for key in (*DOCUMENT_FIELDS, "session_id")):
                raise ServiceRefused("Figma service session is missing its document context")
            live.add(session["session_id"])
            document = {key: session[key] for key in DOCUMENT_FIELDS}
            self.client.call("masc_figma_relay", {"kind": "session", "worker_boot_id": boot,
                             "session_id": session["session_id"], "document": document})
            answer = self.client.call("masc_figma_relay", {"kind": "poll", "worker_boot_id": boot,
                                      "session_id": session["session_id"]})
            command = answer.get("command")
            if command is None:
                continue
            if self.remember(command, boot, info["service_id"], "plugin"):
                request = {key: value for key, value in command.items() if key != "id"}
                try:
                    self.figma.call("/v1/operations", {**request, "service_id": info["service_id"],
                                    "operation_id": command["id"]})
                except ServiceRefused as error:
                    self.store_result("plugin", command["id"], self.failure(error))
                # Transport uncertainty remains submitted and is reconciled by reads.
        self.close_dead_session_jobs(boot, info["service_id"], live)
        answer = self.client.call("masc_figma_relay", {"kind": "rest_poll", "worker_boot_id": boot})
        command = answer.get("command")
        if command is not None and self.remember(command, boot, info["service_id"], "rest"):
            try:
                payload = self.figma.call("/v1/rest-capture", {key: value for key, value in command.items() if key != "id"})
                payload.pop("snapshot_id", None)
                if payload.get("preview"):
                    payload["preview"].pop("sha256", None)
                result = {"ok": True, "payload": payload}
            except (ServiceRefused, TransportError) as error:
                result = self.failure(error)
            self.store_result("rest", command["id"], result)
        self.collect()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    mode = args.config.stat().st_mode
    if not stat.S_ISREG(mode) or stat.S_IMODE(mode) & 0o077:
        parser.error("Adapter configuration must be a private regular file (chmod 600)")
    config = tomllib.loads(args.config.read_text())
    timeout = request_timeout(config["adapter"].get("request_timeout_seconds", 30))
    interval = config["adapter"].get("poll_interval_ms", 1000)
    if type(interval) is not int or interval <= 0:
        parser.error("poll_interval_ms must be a positive integer")
    directory = Path(config["adapter"]["state_directory"])
    if not directory.is_absolute():
        directory = args.config.resolve().parent / directory
    client = McpClient(config["masc"]["url"], config["masc"]["token"], request_timeout_seconds=timeout)
    client.initialize()
    figma = FigmaApi(config["figma"]["url"], config["figma"]["client_token"], timeout=timeout)
    adapter = Adapter(client, figma, directory)
    print("Figma Studio host adapter ready", flush=True)
    try:
        while True:
            try:
                adapter.step()
            except (ServiceRefused, TransportError, ApplicationRefused, ValueError) as error:
                print(f"Figma adapter: {error}", file=sys.stderr)
            time.sleep(interval / 1000)
    finally:
        adapter.close()


if __name__ == "__main__":
    main()
