"""Durable Candle judgment requests; model admission and money stay on the host.

The exported tool only submits or reads an intent. It never waits for a model
inside a worker RPC. The ordinary host-request cycle performs declared Exact
outputs and delivers their original terminal result. Reopening the same state
directory retains both pending intents and completed results.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import uuid
import time
import tomllib

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from protocol import InvalidInput, OUTPUT_SCHEMA, encode_output, object_value, reply_id  # noqa: E402

TEXT = {"type": "string", "minLength": 1}
EMPTY = {"type": "object", "properties": {}, "additionalProperties": False}
OBJECT = {"type": "object", "properties": {}, "additionalProperties": True}
IDENTITY = {"type": "object", "additionalProperties": False,
            "properties": {key: TEXT for key in ("goal_id", "request_id", "verification_run_id")},
            "required": ["goal_id", "request_id", "verification_run_id"]}
REQUEST_FIELDS = {"request_id": TEXT, "identity": IDENTITY, "input": OBJECT,
                  "schema": OBJECT, "prompt": TEXT}


def closed(properties):
    return {"type": "object", "additionalProperties": False,
            "properties": properties, "required": list(properties)}


REQUEST = {"type": "object", "oneOf": [
    closed({**REQUEST_FIELDS, "stage": {"type": "string", "enum": ["grade", "weights"]}}),
    closed({**REQUEST_FIELDS, "stage": {"type": "string", "enum": ["relation"]}, "task_id": TEXT}),
]}
TOOL_INPUT = {"type": "object", "oneOf": [
    closed({"kind": {"type": "string", "const": "submit"}, "request": REQUEST}),
    closed({"kind": {"type": "string", "const": "read"}, "request_id": TEXT}),
]}
TOOL_OUTPUT = {"type": "object", "oneOf": [
    closed({"request_id": TEXT,
            "state": {"type": "string", "enum": ["absent", "pending", "capacity_wait"]}}),
    closed({"request_id": TEXT, "state": {"type": "string", "const": "finished"}, "result": OBJECT}),
]}

CONTEXT = {"type": "object", "additionalProperties": False,
           "properties": {"instance_id": TEXT, "incarnation": TEXT},
           "required": ["instance_id", "incarnation"]}
OBSERVE = {"type": "object", "additionalProperties": False,
           "properties": {"context": CONTEXT, "binding": OBJECT,
                          "sources": {"type": "array", "items": OBJECT}},
           "required": ["context", "binding", "sources"]}
HOST_RESULT = {"type": "object", "additionalProperties": False,
               "properties": {"request_id": TEXT, "result": OBJECT}, "required": ["request_id", "result"]}
CONTROL = {"type": "object", "additionalProperties": False,
           "properties": {"tool": TEXT, "arguments": OBJECT, "caller": OBJECT},
           "required": ["tool", "arguments", "caller"]}
TOOL_NAME = "candle_appraise"


def exact(value, fields: set[str], label: str) -> dict:
    value = object_value(value, label)
    if set(value) != fields:
        raise InvalidInput(f"{label} fields must be exactly {sorted(fields)}")
    return value


def text(value, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise InvalidInput(f"{label} must be non-blank text")
    return value


def canonical(value) -> str:
    try:
        return json.dumps(value, sort_keys=True, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
    except RecursionError as error:
        raise InvalidInput("appraisal JSON nesting is not supported") from error


def digest(value) -> str:
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def pairs(items) -> dict:
    result = {}
    for key, value in items:
        if key in result:
            raise InvalidInput(f"duplicate JSON field {key}")
        result[key] = value
    return result


def decode(raw: str):
    def invalid_constant(value):
        raise InvalidInput(f"non-finite JSON number {value}")
    try:
        return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid_constant)
    except RecursionError as error:
        raise InvalidInput("appraisal JSON nesting is not supported") from error


def request_of_json(raw) -> dict:
    raw = object_value(raw, "appraisal request")
    fields = set(REQUEST_FIELDS) | {"stage"}
    if raw.get("stage") == "relation":
        fields.add("task_id")
    request = exact(raw, fields, "appraisal request")
    text(request["request_id"], "request_id")
    identity = exact(request["identity"], set(IDENTITY["required"]), "identity")
    for key, value in identity.items():
        text(value, f"identity.{key}")
    match request["stage"], request.get("task_id"):
        case "relation", (str() as task_id):
            text(task_id, "task_id")
        case ("grade" | "weights"), None:
            pass
        case _:
            raise InvalidInput("only a Relation names its original task_id")
    object_value(request["input"], "input")
    object_value(request["schema"], "schema")
    text(request["prompt"], "prompt")
    canonical(request)
    return request


def final_of_json(raw) -> dict:
    result = object_value(raw, "host result")
    match result.get("status"):
        case "answered":
            fields = {"status", "output", "slot"}
            if "usage" in result:
                fields.add("usage")
                usage = exact(result["usage"], {"input_tokens", "output_tokens"}, "usage")
                if any(isinstance(n, bool) or not isinstance(n, int) or n < 0 for n in usage.values()):
                    raise InvalidInput("usage must contain non-negative token counts")
            exact(result, fields, "answered result")
            object_value(result["output"], "output")
            text(result["slot"], "slot")
        case "invalid_output":
            exact(result, {"status", "detail"}, "invalid output")
            text(result["detail"], "detail")
        case "input_refused":
            exact(result, {"status", "kind"}, "input refusal")
            if result["kind"] not in ("input_capacity", "context_overflow", "invalid_request", "request_body_refused"):
                raise InvalidInput("unknown input refusal")
        case "not_allowed":
            exact(result, {"status", "reason"}, "output refusal")
            text(result["reason"], "reason")
        case "outcome_unknown" | "request_id_reused":
            exact(result, {"status"}, "terminal result")
        case _:
            raise InvalidInput("host result must be an original Exact terminal result")
    canonical(result)
    return result


class Store:
    def __init__(self, directory: Path):
        self.directory = directory / "candle-appraiser"
        # The installation state root is provided by the host. Do not silently
        # recreate that authority if it disappears or arrives under another path.
        self.directory.mkdir(exist_ok=True)
        info = self.directory.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise InvalidInput("appraisal store is not a directory")
        self.identity = (info.st_dev, info.st_ino)
        self.failed = False
        # A first request ACK requires both its directory entry and the new
        # store entry in the installation state root to survive a crash.
        self.sync_directory(self.directory)
        self.sync_directory(self.directory.parent)

    @staticmethod
    def sync_directory(path: Path) -> None:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def check_directory(self) -> None:
        info = self.directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or (info.st_dev, info.st_ino) != self.identity:
            raise InvalidInput("appraisal store identity changed")

    @contextmanager
    def open_directory(self):
        self.check_directory()
        fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if (info.st_dev, info.st_ino) != self.identity:
                raise InvalidInput("appraisal store identity changed while opening")
            yield fd
            self.check_directory()
        finally:
            os.close(fd)

    def path(self, request_id: str) -> Path:
        return self.directory / (digest(text(request_id, "request_id")) + ".json")

    def read_path(self, name: str, directory_fd: int) -> dict:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
        with os.fdopen(fd, "r", encoding="utf-8") as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                raise InvalidInput("appraisal record is not a regular file")
            record = exact(decode(source.read()), {"version", "request", "digest", "result"}, "retained record")
        if type(record["version"]) is not int or record["version"] != 1:
            raise InvalidInput("unknown appraisal record version")
        request = request_of_json(record["request"])
        if self.path(request["request_id"]).name != name or record["digest"] != digest(request):
            raise InvalidInput("appraisal record identity or input digest disagrees")
        if record["result"] is not None:
            final_of_json(record["result"])
        return record

    def read(self, request_id: str) -> dict | None:
        if self.failed:
            raise InvalidInput("appraisal persistence is unconfirmed")
        with self.open_directory() as directory_fd:
            try:
                return self.read_path(self.path(request_id).name, directory_fd)
            except FileNotFoundError:
                # Only the leaf can be absent: the original directory is open
                # and its identity is checked again before returning to caller.
                return None

    def records(self) -> list[dict]:
        if self.failed:
            raise InvalidInput("appraisal persistence is unconfirmed")
        with self.open_directory() as directory_fd:
            with os.scandir(directory_fd) as entries:
                names = sorted(entry.name for entry in entries if entry.name.endswith(".json"))
            return [self.read_path(name, directory_fd) for name in names]

    def write(self, record: dict) -> None:
        if self.failed:
            raise InvalidInput("appraisal persistence is unconfirmed; reopen and inspect the store")
        try:
            with self.open_directory() as directory_fd:
                temporary = ".appraisal-" + uuid.uuid4().hex
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directory_fd)
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as target:
                        target.write(canonical(record) + "\n")
                        target.flush()
                        os.fsync(target.fileno())
                    os.replace(temporary, self.path(record["request"]["request_id"]).name,
                               src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
                    temporary = None
                    os.fsync(directory_fd)
                finally:
                    if temporary is not None:
                        os.unlink(temporary, dir_fd=directory_fd)
        except (OSError, InvalidInput):
            self.failed = True
            raise


class Worker:
    def __init__(self, state: Path, max_reply_bytes: int):
        self.store = Store(state)
        self.max_reply_bytes = max_reply_bytes
        self.context = None

    def fits(self, result: dict) -> bool:
        envelope = {"jsonrpc": "2.0", "id": 2 ** 53, "result": tool_result(result)}
        return len((encode_output(envelope) + "\n").encode("utf-8")) <= self.max_reply_bytes

    def status(self, request_id: str, record: dict | None) -> dict:
        if record is None:
            return {"request_id": request_id, "state": "absent"}
        if record["result"] is None:
            return {"request_id": request_id, "state": "pending"}
        return {"request_id": request_id, "state": "finished", "result": record["result"]}

    def invoke(self, args, caller: dict) -> dict:
        match caller.get("kind"):
            case "operator" | "anonymous":
                exact(caller, {"kind"}, "caller")
            case "keeper" | "agent" | "host_actor":
                exact(caller, {"kind", "name"}, "caller")
                text(caller["name"], "caller.name")
            case _:
                raise InvalidInput("unknown admitted caller kind")
        args = object_value(args, "appraisal arguments")
        match args.get("kind"):
            case "submit":
                exact(caller, {"kind"}, "Candle authority")
                if caller["kind"] != "operator":
                    raise InvalidInput("only the host Candle owner may submit an appraisal")
                exact(args, {"kind", "request"}, "submit")
                request = request_of_json(args["request"])
                # Admission precedes persistence; a frame that cannot be listed
                # must not leave an intent that the host can never execute.
                listing = {"requests": [self.host_request(request)]}
                if not self.fits(listing):
                    raise InvalidInput("appraisal request exceeds the declared worker reply frame")
                old = self.store.read(request["request_id"])
                if old is not None and old["digest"] != digest(request):
                    raise InvalidInput("request_id already belongs to different appraisal input")
                if old is None:
                    pending = [self.host_request(record["request"]) for record in self.store.records()
                               if record["result"] is None]
                    if not self.fits({"requests": pending + listing["requests"]}):
                        return {"request_id": request["request_id"], "state": "capacity_wait"}
                    old = {"version": 1, "request": request, "digest": digest(request), "result": None}
                    self.store.write(old)
                return self.status(request["request_id"], old)
            case "read":
                exact(args, {"kind", "request_id"}, "read")
                request_id = text(args["request_id"], "request_id")
                return self.status(request_id, self.store.read(request_id))
            case _:
                raise InvalidInput("appraisal kind must be submit or read")

    @staticmethod
    def host_request(request: dict) -> dict:
        # Payout identity/task ids are audit metadata, never model evidence.
        return {"kind": "exact_output", "request_id": request["request_id"], "output": request["stage"],
                "messages": [{"role": "user", "text": request["prompt"]}], "schema": request["schema"]}

    def host_requests(self, args) -> dict:
        exact(args, set(), "host listing")
        if self.store.failed:
            raise InvalidInput("appraisal persistence is unconfirmed")
        requests = []
        for record in self.store.records():
            if record["result"] is None:
                candidate = self.host_request(record["request"])
                requests.append(candidate)
        if not self.fits({"requests": requests}):
            raise InvalidInput("retained pending requests exceed the current declared reply frame")
        return {"requests": requests}

    def host_result(self, args) -> dict:
        args = exact(args, {"request_id", "result"}, "host result arguments")
        request_id = text(args["request_id"], "request_id")
        record = self.store.read(request_id)
        if record is None:
            raise InvalidInput("no original appraisal owns this result")
        result = final_of_json(args["result"])
        if record["result"] is not None:
            if record["result"] != result:
                raise InvalidInput("a different terminal result already belongs to this request")
            return {"accepted": True}
        if not self.fits(self.status(request_id, {**record, "result": result})):
            raise InvalidInput("appraisal result exceeds the declared worker reply frame")
        self.store.write({**record, "result": result})
        return {"accepted": True}

    def observe(self, args) -> dict:
        args = exact(args, {"context", "binding", "sources"}, "observation")
        context = exact(args["context"], {"instance_id", "incarnation"}, "context")
        for key, value in context.items():
            text(value, key)
        if self.context is not None and self.context != context:
            raise InvalidInput("observation belongs to another worker incarnation")
        self.context = context
        records = self.store.records()
        fields = {"pending": sum(record["result"] is None for record in records),
                  "finished": sum(record["result"] is not None for record in records),
                  "requests": [record["request"]["request_id"] for record in records]}
        output = {"rows": [{"id": "appraisals", "lane_id": "candle/appraisals", "kind": "value",
                            "title": "Candle appraisal requests", "observed_at": time.time(),
                            "subject_id": context["instance_id"], "clock": None, "actor": None,
                            "fields": fields, "evidence": [], "related_ids": []}], "coverage": []}
        if not self.fits(output):
            # Aggregate counts remain available without truncating an intent or
            # claiming that an incomplete ID list is the complete inventory.
            del fields["requests"]
            fields["request_inventory"] = "read individual requests through candle_appraise"
        return output


def tool_result(output: dict) -> dict:
    return {"content": [{"type": "text", "text": "Candle appraisal state"}],
            "structuredContent": output, "isError": False}


TOOLS = [
    {"name": "lane_observe", "description": "Read retained Candle appraisal counts and request identities.",
     "inputSchema": OBSERVE, "outputSchema": OUTPUT_SCHEMA},
    {"name": TOOL_NAME, "description": "Read an original Candle appraisal; host authority also admits new requests.",
     "inputSchema": TOOL_INPUT, "outputSchema": TOOL_OUTPUT},
    {"name": "lane_call", "description": "Host-admitted caller envelope; never export this control port.",
     "inputSchema": CONTROL},
    {"name": "lane_host_requests", "description": "List retained pending Exact requests.", "inputSchema": EMPTY},
    {"name": "lane_host_result", "description": "Retain an original host Exact terminal result.", "inputSchema": HOST_RESULT},
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", type=Path, required=True)
    options = parser.parse_args()
    manifest = tomllib.loads((HERE / "lane.toml").read_text(encoding="utf-8"))
    worker = Worker(options.state, manifest["resources"]["max_reply_bytes"])
    for line in sys.stdin.buffer:
        request_id = None
        try:
            rpc = object_value(decode(line.decode("utf-8")), "JSON-RPC")
            request_id = reply_id(rpc.get("id"))
            if "id" not in rpc or "method" not in rpc:
                continue
            params = object_value(rpc.get("params", {}), "params")
            match rpc["method"]:
                case "initialize":
                    result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                              "serverInfo": {"name": "masc-candle-appraiser", "version": manifest["revision"]}}
                case "ping":
                    result = {}
                case "tools/list":
                    result = {"tools": TOOLS}
                case "tools/call":
                    name, args = params.get("name"), params.get("arguments")
                    try:
                        match name:
                            case "lane_observe": output = worker.observe(args)
                            case "lane_host_requests": output = worker.host_requests(args)
                            case "lane_host_result": output = worker.host_result(args)
                            case "lane_call":
                                envelope = exact(args, {"tool", "arguments", "caller"}, "host call")
                                if envelope["tool"] != TOOL_NAME:
                                    raise InvalidInput("unknown exported Candle tool")
                                output = worker.invoke(envelope["arguments"], object_value(envelope["caller"], "caller"))
                            case _:
                                raise InvalidInput("use the admitted caller envelope for exported tools")
                        result = tool_result(output)
                    except (InvalidInput, OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
                        result = {"content": [{"type": "text", "text": str(error)}], "isError": True}
                case _:
                    print(encode_output({"jsonrpc": "2.0", "id": request_id,
                                         "error": {"code": -32601, "message": "Method not found"}}), flush=True)
                    continue
            encoded = encode_output({"jsonrpc": "2.0", "id": request_id, "result": result})
            if len((encoded + "\n").encode("utf-8")) > worker.max_reply_bytes:
                encoded = encode_output({"jsonrpc": "2.0", "id": request_id,
                                         "result": {"content": [{"type": "text", "text": "worker reply exceeds declared frame"}],
                                                    "isError": True}})
        except (InvalidInput, ValueError, UnicodeError) as error:
            encoded = encode_output({"jsonrpc": "2.0", "id": request_id,
                                     "error": {"code": -32602, "message": str(error)}})
        print(encoded, flush=True)


if __name__ == "__main__":
    main()
