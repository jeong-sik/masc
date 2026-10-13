"""Durable document requests: dispatched mutations are never automatically replayed."""

from __future__ import annotations

import base64
import hashlib
import json
import math
import sqlite3
import time
import uuid
from collections.abc import Callable
from enum import StrEnum
from pathlib import Path
from typing import Any

Json = dict[str, Any]


class State(StrEnum):
    PREPARED = "prepared"
    DISPATCHED = "dispatched"
    CAPTURED = "captured"
    APPLIED = "applied"
    REJECTED = "rejected"
    UNKNOWN = "outcome_unknown"


class Access(StrEnum):
    OWNER = "owner"
    RELAY = "relay"
    SNAPSHOT = "snapshot"


class Refused(ValueError):
    pass


def encode(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def text(value: Any) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise Refused("Expected nonempty trimmed string")
    return value


def fields(value: Any, required: set[str], optional: set[str] | None = None) -> Json:
    if (
        not isinstance(value, dict)
        or not required <= value.keys()
        or value.keys() - required - (optional or set())
    ):
        raise Refused(
            f"Expected fields {sorted(required)}, optional {sorted(optional or set())}"
        )
    return value


def native_document(tree_json: Any) -> Json:
    """Parse the native tree shape used by snapshot identity and validation."""

    def reject_constant(value: str) -> Any:
        raise Refused(f"Non-finite number in native export: {value}")

    def finite_float(value: str) -> float:
        number = float(value)
        if not math.isfinite(number):
            raise Refused("Non-finite number in native export")
        return number

    try:
        tree = json.loads(
            text(tree_json), parse_constant=reject_constant, parse_float=finite_float
        )
    except Refused:
        raise
    except (ValueError, RecursionError) as error:
        raise Refused("Invalid native export JSON") from error
    if not isinstance(tree, dict) or not isinstance(tree.get("document"), dict):
        raise Refused("Native export requires a document object")
    document = tree["document"]
    pending = [document]
    identities = set()
    while pending:
        node = pending.pop()
        identity = text(node.get("id"))
        if identity in identities:
            raise Refused("Ambiguous duplicate node IDs in native export")
        identities.add(identity)
        children = node.get("children", [])
        if not isinstance(children, list) or any(
            not isinstance(child, dict) for child in children
        ):
            raise Refused("Native node children must be an array of objects")
        pending.extend(children)
    return document


def png_bytes(preview: Json | None) -> bytes | None:
    if preview is None:
        return None
    fields(preview, {"mime_type", "data_base64"})
    if preview["mime_type"] != "image/png":
        raise Refused("Preview must be PNG")
    encoded = text(preview["data_base64"])
    try:
        data = base64.b64decode(encoded, validate=True)
    except ValueError as error:
        raise Refused("Invalid canonical PNG encoding") from error
    if base64.b64encode(data).decode() != encoded or not data.startswith(
        b"\x89PNG\r\n\x1a\n"
    ):
        raise Refused("Invalid canonical PNG encoding")
    return data


class Store:
    def __init__(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(directory / "studio.sqlite3")
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript("""
          CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, document TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS snapshots (id TEXT PRIMARY KEY, metadata TEXT NOT NULL, png BLOB);
          CREATE TABLE IF NOT EXISTS reports (id TEXT PRIMARY KEY, content TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, boot TEXT NOT NULL,
            session TEXT NOT NULL, request TEXT NOT NULL, state TEXT NOT NULL, result TEXT,
            created REAL NOT NULL, updated REAL NOT NULL);
        """)
        self.boot_id = str(uuid.uuid4())
        self.binding: Json | None = None

    def meta(self, key: str) -> str | None:
        row = self.db.execute(
            "SELECT value FROM metadata WHERE key=?", (key,)
        ).fetchone()
        return row[0] if row else None

    def set_meta(self, key: str, value: str) -> None:
        self.db.execute("INSERT OR REPLACE INTO metadata VALUES (?,?)", (key, value))

    def configure(self, binding: Json) -> None:
        fields(binding, {"installation", "keeper", "relay_agent", "sources"})
        for key in ("installation", "keeper", "relay_agent"):
            text(binding[key])
        if binding["sources"] != []:
            raise Refused("Studio owns its state; sources must be empty")
        if self.meta("binding") not in (None, encode(binding)):
            raise Refused("State belongs to another binding; use a new installation")
        if self.binding is None:
            with self.db:
                self.set_meta("binding", encode(binding))
                self.db.execute("DELETE FROM sessions")
                self.db.execute("DELETE FROM metadata WHERE key='active_session'")
                for old, new, reason in (
                    (State.PREPARED, State.REJECTED, "Restarted before dispatch"),
                    (
                        State.DISPATCHED,
                        State.UNKNOWN,
                        "Restarted after dispatch; do not replay",
                    ),
                ):
                    self.db.execute(
                        "UPDATE operations SET state=?,result=?,updated=? WHERE state=?",
                        (new, encode({"reason": reason}), time.time(), old),
                    )
            self.binding = binding

    def authorize(self, caller: Json, *, access: Access = Access.OWNER) -> None:
        if self.binding is None:
            raise Refused("Waiting for host lane_observe binding")
        relay = [{"kind": "agent", "name": self.binding["relay_agent"]}]
        owner = [
            {"kind": "keeper", "name": self.binding["keeper"]},
            {"kind": "operator"},
        ]
        allowed = {
            Access.OWNER: owner,
            Access.RELAY: relay,
            Access.SNAPSHOT: owner + relay,
        }[access]
        if caller not in allowed:
            raise Refused(f"Caller does not have Studio {access.value} access")

    def session(self, identity: str) -> Json:
        row = self.db.execute(
            "SELECT document FROM sessions WHERE id=?", (identity,)
        ).fetchone()
        if row is None:
            raise Refused("Plugin session has not reported to this worker")
        return json.loads(row[0])

    def bind(self, identity: str) -> Json:
        document = self.session(text(identity))
        with self.db:
            self.set_meta("active_session", identity)
        return {
            "session_id": identity,
            "document": document,
            "worker_boot_id": self.boot_id,
        }

    def operation(self, identity: str) -> Json:
        row = self.db.execute(
            "SELECT * FROM operations WHERE id=?", (text(identity),)
        ).fetchone()
        if row is None:
            raise Refused("Unknown operation")
        return {
            "operation_id": row["id"],
            "worker_boot_id": row["boot"],
            "session_id": row["session"],
            "state": row["state"],
            "request": json.loads(row["request"]),
            "result": json.loads(row["result"]) if row["result"] else None,
        }

    def snapshot(self, identity: str) -> tuple[Json, bytes | None]:
        row = self.db.execute(
            "SELECT metadata,png FROM snapshots WHERE id=?", (text(identity),)
        ).fetchone()
        if row is None:
            raise Refused("Unknown snapshot")
        return json.loads(row[0]), row[1]

    def submit(self, args: Json) -> Json:
        fields(
            args,
            {"operation_id", "session_id", "kind", "root_id"},
            {"snapshot_id", "ops"},
        )
        identity, session = text(args["operation_id"]), text(args["session_id"])
        request = {key: value for key, value in args.items() if key != "operation_id"}
        prior = self.db.execute(
            "SELECT request FROM operations WHERE id=?", (identity,)
        ).fetchone()
        if prior:
            if prior[0] != encode(request):
                raise Refused("Operation ID already identifies different input")
            return self.operation(identity)
        document = self.session(session)
        if self.meta("active_session") != session:
            raise Refused("Explicitly bind the Plugin session first")
        text(args["root_id"])
        if args["kind"] == "apply":
            if not document["can_edit"]:
                raise Refused("Session does not report Design editing capability")
            snapshot, _ = self.snapshot(text(args.get("snapshot_id")))
            if snapshot["source"] != "plugin_live":
                raise Refused(
                    "An edit needs a live Plugin baseline, not an unassociated REST snapshot"
                )
            if (
                snapshot["session_id"] != session
                or snapshot["root_id"] != args["root_id"]
                or not snapshot["coverage"]["stable"]
            ):
                raise Refused(
                    "Edit requires a stable snapshot for this exact session and root"
                )
            if not isinstance(args.get("ops"), list) or not args["ops"]:
                raise Refused("Edit needs nonempty native operations")
        elif args["kind"] != "capture" or set(args) != {
            "operation_id",
            "session_id",
            "kind",
            "root_id",
        }:
            raise Refused("Unknown or malformed operation")
        now = time.time()
        with self.db:
            self.db.execute(
                "INSERT INTO operations VALUES (?,?,?,?,?,NULL,?,?)",
                (
                    identity,
                    self.boot_id,
                    session,
                    encode(request),
                    State.PREPARED,
                    now,
                    now,
                ),
            )
        return self.operation(identity)

    def relay(
        self,
        args: Json,
        *,
        check_poll: Callable[[Json], None],
        check_snapshot: Callable[[str, Json, bytes | None], None],
        check_session: Callable[[str, Json], None],
    ) -> Json:
        fields(
            args,
            {"kind", "worker_boot_id", "session_id"},
            {"document", "operation_id", "ok", "payload"},
        )
        if args["worker_boot_id"] != self.boot_id:
            raise Refused("Worker replaced; pair again")
        session = text(args["session_id"])
        if args["kind"] == "session":
            fields(args, {"kind", "worker_boot_id", "session_id", "document"})
            doc = fields(
                args["document"],
                {"name", "page_id", "selection", "editor_type", "mode", "can_edit"},
            )
            if (
                not isinstance(doc["name"], str)
                or not isinstance(doc["selection"], list)
                or type(doc["can_edit"]) is not bool
            ):
                raise Refused("Malformed Plugin context")
            for key in ("page_id", "editor_type", "mode"):
                text(doc[key])
            check_session(session, doc)
            with self.db:
                self.db.execute(
                    "INSERT OR REPLACE INTO sessions VALUES (?,?)",
                    (session, encode(doc)),
                )
            return {"status": "reported"}
        self.session(session)
        if args["kind"] == "poll":
            fields(args, {"kind", "worker_boot_id", "session_id"})
            with self.db:
                row = self.db.execute(
                    "SELECT id FROM operations WHERE session=? AND boot=? AND state=? ORDER BY created,id LIMIT 1",
                    (session, self.boot_id, State.PREPARED),
                ).fetchone()
                if row is None:
                    return {"command": None}
                operation = self.operation(row[0])
                command = {"id": row[0], **operation["request"]}
                if command["kind"] == "apply":
                    snapshot, _ = self.snapshot(command.pop("snapshot_id"))
                    command["expected_tree_json"] = snapshot["tree_json"]
                response = {"command": command}
                # The retained baseline can make this reply larger than the
                # submitted operation. Refuse before handing off ownership.
                try:
                    check_poll(response)
                except Refused as error:
                    rejection = {"reason": str(error), "effect": "proven_pre_effect"}
                    self.db.execute(
                        "UPDATE operations SET state=?,result=?,updated=? WHERE id=?",
                        (State.REJECTED, encode(rejection), time.time(), row[0]),
                    )
                    return {
                        "command": None,
                        "rejected_operation": {
                            "operation_id": row[0],
                            "state": State.REJECTED,
                            **rejection,
                        },
                    }
                self.db.execute(
                    "UPDATE operations SET state=?,updated=? WHERE id=?",
                    (State.DISPATCHED, time.time(), row[0]),
                )
            return response
        if args["kind"] != "result":
            raise Refused("Unknown relay action")
        fields(
            args,
            {"kind", "worker_boot_id", "session_id", "operation_id", "ok", "payload"},
        )
        operation = self.operation(args["operation_id"])
        if (
            operation["session_id"] != session
            or operation["worker_boot_id"] != self.boot_id
        ):
            raise Refused("Result belongs to another session/worker")
        if type(args["ok"]) is not bool or not isinstance(args["payload"], dict):
            raise Refused("Expected boolean ok and object payload")
        raw = {"ok": args["ok"], "payload": args["payload"]}
        if operation["state"] != State.DISPATCHED:
            if operation["result"] and operation["result"].get("relay_result") == raw:
                return operation
            raise Refused("Operation already has a result or was not dispatched")
        result: Json = {"relay_result": raw}
        state = (
            State.REJECTED
            if args["payload"].get("status") == "rejected"
            else State.UNKNOWN
        )
        with self.db:
            if args["ok"]:
                try:
                    result["snapshot_id"] = self.save_snapshot(
                        args["payload"],
                        session,
                        operation["request"]["root_id"],
                        check=check_snapshot,
                    )
                    state = (
                        State.CAPTURED
                        if operation["request"]["kind"] == "capture"
                        else State.APPLIED
                    )
                except Refused as error:
                    result["reason"] = f"Unusable readback: {error}"
                    state = State.UNKNOWN
            self.db.execute(
                "UPDATE operations SET state=?,result=?,updated=? WHERE id=?",
                (state, encode(result), time.time(), operation["operation_id"]),
            )
        return self.operation(operation["operation_id"])

    def save_snapshot(
        self,
        value: Json,
        session: str | None,
        root: str,
        *,
        check: Callable[[str, Json, bytes | None], None],
    ) -> str:
        origin = (
            {"session_id", "page_id"}
            if session is not None
            else {"file_key", "version"}
        )
        fields(
            value,
            origin
            | {
                "schema_version",
                "source",
                "root_id",
                "tree_json",
                "preview",
                "coverage",
                "observed_at",
            },
            {"completed"},
        )
        if (
            value["schema_version"] != 1
            or value["source"]
            != ("plugin_live" if session is not None else "rest_version")
            or (session is not None and value["session_id"] != session)
            or value["root_id"] != root
        ):
            raise Refused("Snapshot identity mismatch")
        document = native_document(value["tree_json"])
        if document["id"] != root:
            raise Refused("Native export root mismatch")
        coverage = fields(value["coverage"], {"stable", "missing"})
        if (
            type(coverage["stable"]) is not bool
            or not isinstance(coverage["missing"], list)
            or any(not isinstance(x, str) for x in coverage["missing"])
        ):
            raise Refused("Invalid capture coverage")
        data = png_bytes(value["preview"])
        if data is None and not any(
            x.startswith("preview:") for x in coverage["missing"]
        ):
            raise Refused("Missing preview must be explicit")
        metadata = {
            **value,
            "preview": {
                "mime_type": "image/png",
                "sha256": hashlib.sha256(data).hexdigest(),
            }
            if data
            else None,
        }
        try:
            encoded = encode(metadata)
            identity = hashlib.sha256(encoded.encode()).hexdigest()
        except (ValueError, TypeError, UnicodeError) as error:
            raise Refused("Snapshot must contain valid UTF-8 JSON values") from error
        # Validate both read and observation projections before publishing a
        # latest pointer. A rejected readback remains only in its operation.
        check(identity, metadata, data)
        self.db.execute(
            "INSERT OR IGNORE INTO snapshots VALUES (?,?,?)", (identity, encoded, data)
        )
        self.set_meta("latest_snapshot", identity)
        return identity

    def status(self, *, session: tuple[str, Json] | None = None) -> Json:
        sessions = {
            row[0]: {"session_id": row[0], **json.loads(row[1])}
            for row in self.db.execute("SELECT id,document FROM sessions ORDER BY id")
        }
        if session is not None:
            sessions[session[0]] = {"session_id": session[0], **session[1]}
        return {
            "worker_boot_id": self.boot_id,
            "binding_ready": self.binding is not None,
            "active_session": self.meta("active_session"),
            "latest_snapshot": self.meta("latest_snapshot"),
            "latest_validation": self.meta("latest_validation"),
            "sessions": [sessions[identity] for identity in sorted(sessions)],
        }

    def record_validation(
        self, report: Json, *, check: Callable[[str, str], None]
    ) -> Json:
        content = encode(report)
        identity = hashlib.sha256(content.encode()).hexdigest()
        check(identity, content)
        with self.db:
            self.db.execute(
                "INSERT OR IGNORE INTO reports VALUES (?,?)", (identity, content)
            )
            self.set_meta("latest_validation", identity)
        return {"report_id": identity, **report}

    def observe(
        self,
        *,
        snapshot: tuple[str, Json, bytes | None] | None = None,
        report: tuple[str, str] | None = None,
        session: tuple[str, Json] | None = None,
    ) -> Json:
        status = self.status(session=session)
        if snapshot is not None:
            status["latest_snapshot"] = snapshot[0]
        if report is not None:
            status["latest_validation"] = report[0]
        row: Json = {
            "id": self.boot_id,
            "lane_id": "figma/studio",
            "kind": "value",
            "title": "Figma Studio",
            "observed_at": time.time(),
            "subject_id": self.binding["installation"] if self.binding else "studio",
            "clock": None,
            "actor": None,
            "fields": status,
            "evidence": [],
            "related_ids": [],
        }
        artifacts: list[Json] = []
        if status["latest_snapshot"]:
            identity = status["latest_snapshot"]
            metadata, data = snapshot[1:] if snapshot else self.snapshot(identity)
            artifacts.append(
                {
                    "id": identity,
                    "mime_type": "application/json",
                    "data_base64": base64.b64encode(encode(metadata).encode()).decode(),
                }
            )
            row["evidence"].append({"artifact_id": identity})
            if data:
                image_id = metadata["preview"]["sha256"]
                artifacts.append(
                    {
                        "id": image_id,
                        "mime_type": "image/png",
                        "data_base64": base64.b64encode(data).decode(),
                    }
                )
                row["evidence"].append({"artifact_id": image_id})
        if status["latest_validation"]:
            identity = status["latest_validation"]
            content = (
                report[1]
                if report
                else self.db.execute(
                    "SELECT content FROM reports WHERE id=?", (identity,)
                ).fetchone()[0]
            )
            artifacts.append(
                {
                    "id": identity,
                    "mime_type": "application/json",
                    "data_base64": base64.b64encode(content.encode()).decode(),
                }
            )
            row["evidence"].append({"artifact_id": identity})
        return {"rows": [row], "coverage": [], "artifacts": artifacts}
