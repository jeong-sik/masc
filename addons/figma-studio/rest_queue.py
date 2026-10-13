"""Server-version capture queue, separate from live Plugin sessions."""

import json
import time
from typing import Callable

from store import Json, Refused, State, Store, encode, fields, text


class RestQueue:
    def __init__(self, store: Store):
        self.store = store
        self.db = store.db
        with self.db:
            self.db.execute(
                "CREATE TABLE IF NOT EXISTS rest_requests (id TEXT PRIMARY KEY, request TEXT NOT NULL, state TEXT NOT NULL, result TEXT, created REAL NOT NULL)"
            )
            self.db.execute(
                "UPDATE rest_requests SET state=?,result=? WHERE state IN (?,?)",
                (
                    State.UNKNOWN,
                    encode(
                        {"reason": "Worker restarted; submit a new read explicitly"}
                    ),
                    State.PREPARED,
                    State.DISPATCHED,
                ),
            )

    def get(self, identity: str) -> Json:
        row = self.db.execute(
            "SELECT * FROM rest_requests WHERE id=?", (text(identity),)
        ).fetchone()
        if row is None:
            raise Refused("Unknown REST capture")
        return {
            "operation_id": row["id"],
            "request": json.loads(row["request"]),
            "state": row["state"],
            "result": json.loads(row["result"]) if row["result"] else None,
        }

    def submit(self, args: Json) -> Json:
        fields(args, {"operation_id", "file_key", "root_id"}, {"version"})
        for value in args.values():
            text(value)
        identity = args["operation_id"]
        request = {key: value for key, value in args.items() if key != "operation_id"}
        row = self.db.execute(
            "SELECT request FROM rest_requests WHERE id=?", (identity,)
        ).fetchone()
        if row:
            if row[0] != encode(request):
                raise Refused("REST operation ID identifies different input")
            return self.get(identity)
        with self.db:
            self.db.execute(
                "INSERT INTO rest_requests VALUES (?,?,?,NULL,?)",
                (identity, encode(request), State.PREPARED, time.time()),
            )
        return self.get(identity)

    def relay(
        self,
        args: Json,
        *,
        check_poll: Callable[[Json], None],
        check_snapshot: Callable[[str, Json, bytes | None], None],
    ) -> Json:
        if args.get("worker_boot_id") != self.store.boot_id:
            raise Refused("REST relay targets a replaced worker")
        if args.get("kind") == "rest_poll":
            fields(args, {"kind", "worker_boot_id"})
            with self.db:
                row = self.db.execute(
                    "SELECT id FROM rest_requests WHERE state=? ORDER BY created,id LIMIT 1",
                    (State.PREPARED,),
                ).fetchone()
                if row is None:
                    return {"command": None}
                operation = self.get(row[0])
                response = {"command": {"id": row[0], **operation["request"]}}
                try:
                    check_poll(response)
                except Refused as error:
                    rejection = {"reason": str(error), "effect": "proven_pre_effect"}
                    self.db.execute(
                        "UPDATE rest_requests SET state=?,result=? WHERE id=?",
                        (State.REJECTED, encode(rejection), row[0]),
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
                    "UPDATE rest_requests SET state=? WHERE id=?",
                    (State.DISPATCHED, row[0]),
                )
            return response
        fields(args, {"kind", "worker_boot_id", "operation_id", "ok", "payload"})
        if (
            args["kind"] != "rest_result"
            or type(args["ok"]) is not bool
            or not isinstance(args["payload"], dict)
        ):
            raise Refused("Invalid REST result")
        operation = self.get(args["operation_id"])
        raw = {"ok": args["ok"], "payload": args["payload"]}
        if operation["state"] != State.DISPATCHED:
            if operation["result"] and operation["result"].get("relay_result") == raw:
                return operation
            raise Refused("REST capture already has a result or was not dispatched")
        result: Json = {"relay_result": raw}
        state = State.UNKNOWN
        with self.db:
            if args["ok"]:
                try:
                    request, payload = operation["request"], args["payload"]
                    if payload.get("file_key") != request["file_key"] or (
                        "version" in request
                        and payload.get("version") != request["version"]
                    ):
                        raise Refused("REST file/version identity mismatch")
                    text(payload.get("version"))
                    result["snapshot_id"] = self.store.save_snapshot(
                        payload, None, request["root_id"], check=check_snapshot
                    )
                    state = State.CAPTURED
                except Refused as error:
                    result["reason"] = f"Unusable REST capture: {error}"
            self.db.execute(
                "UPDATE rest_requests SET state=?,result=? WHERE id=?",
                (state, encode(result), operation["operation_id"]),
            )
        return self.get(operation["operation_id"])

    @staticmethod
    def summary(operation: Json) -> Json:
        result = operation["result"]
        if result and "relay_result" in result:
            raw = result["relay_result"]
            result = {
                key: value for key, value in result.items() if key != "relay_result"
            }
            result["error"] = raw["payload"].get("error")
        return {**operation, "result": result}
