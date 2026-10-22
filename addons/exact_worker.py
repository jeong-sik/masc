"""Installation-owned retained Exact requests shared by judgment Add-ons.

A contract supplies pure request parsing and conversion to the existing common
host Exact wire. This module owns durable pending/terminal records and MCP I/O;
it never calls a provider or commits a consumer domain state. The host owns the
single worker writer/installation lifetime. Unknown outcomes are never relisted.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import time
import tomllib
from typing import Callable
import uuid

from protocol import INPUT_SCHEMA, InvalidInput, OUTPUT_SCHEMA, encode_output, object_value, reply_id

TEXT = {"type": "string", "minLength": 1}
EMPTY = {"type": "object", "properties": {}, "additionalProperties": False}
OBJECT = {"type": "object", "properties": {}, "additionalProperties": True}


def closed(properties):
    return {"type": "object", "additionalProperties": False,
            "properties": properties, "required": list(properties)}


TOOL_OUTPUT = {"type": "object", "oneOf": [
    closed({"request_id": TEXT,
            "state": {"type": "string", "enum": ["absent", "pending", "capacity_wait"]}}),
    closed({"request_id": TEXT, "state": {"type": "string", "const": "finished"}, "result": OBJECT}),
]}
HOST_RESULT = closed({"request_id": TEXT, "result": OBJECT})
CONTROL = closed({"tool": TEXT, "arguments": OBJECT, "caller": OBJECT})


@dataclass(frozen=True)
class Contract:
    package_id: str
    tool_name: str
    lane_id: str
    row_id: str
    title: str
    tool_input: dict
    parse_request: Callable[[object], dict]
    host_request: Callable[[dict], dict]


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
        raise InvalidInput("Exact request JSON nesting is not supported") from error


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
        raise InvalidInput("Exact request JSON nesting is not supported") from error


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
    def __init__(self, directory: Path, contract: Contract):
        self.contract = contract
        self.directory = directory / contract.package_id
        # The installation state root is provided by the host. Do not silently
        # recreate that authority if it disappears or arrives under another path.
        self.directory.mkdir(exist_ok=True)
        info = self.directory.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise InvalidInput("Exact request store is not a directory")
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
            raise InvalidInput("Exact request store identity changed")

    @contextmanager
    def open_directory(self):
        self.check_directory()
        fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if (info.st_dev, info.st_ino) != self.identity:
                raise InvalidInput("Exact request store identity changed while opening")
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
                raise InvalidInput("Exact request record is not a regular file")
            record = exact(decode(source.read()), {"version", "request", "digest", "result"}, "retained record")
        if type(record["version"]) is not int or record["version"] != 1:
            raise InvalidInput("unknown Exact request record version")
        request = self.contract.parse_request(record["request"])
        if self.path(request["request_id"]).name != name or record["digest"] != digest(request):
            raise InvalidInput("Exact request record identity or input digest disagrees")
        if record["result"] is not None:
            final_of_json(record["result"])
        return record

    def read(self, request_id: str) -> dict | None:
        if self.failed:
            raise InvalidInput("Exact request persistence is unconfirmed")
        with self.open_directory() as directory_fd:
            try:
                return self.read_path(self.path(request_id).name, directory_fd)
            except FileNotFoundError:
                # Only the leaf can be absent: the original directory is open
                # and its identity is checked again before returning to caller.
                return None

    def records(self) -> list[dict]:
        if self.failed:
            raise InvalidInput("Exact request persistence is unconfirmed")
        with self.open_directory() as directory_fd:
            with os.scandir(directory_fd) as entries:
                names = sorted(entry.name for entry in entries if entry.name.endswith(".json"))
            return [self.read_path(name, directory_fd) for name in names]

    def write(self, record: dict) -> None:
        if self.failed:
            raise InvalidInput("Exact request persistence is unconfirmed; reopen and inspect the store")
        try:
            with self.open_directory() as directory_fd:
                temporary = ".exact-" + uuid.uuid4().hex
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
    def __init__(self, state: Path, max_reply_bytes: int, contract: Contract):
        self.contract = contract
        self.store = Store(state, contract)
        self.max_reply_bytes = max_reply_bytes

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
        args = object_value(args, "Exact request arguments")
        match args.get("kind"):
            case "submit":
                exact(caller, {"kind"}, "host admission")
                if caller["kind"] != "operator":
                    raise InvalidInput("only the admitted host operator may submit an Exact request")
                exact(args, {"kind", "request"}, "submit")
                request = self.contract.parse_request(args["request"])
                # Admission precedes persistence; a frame that cannot be listed
                # must not leave an intent that the host can never execute.
                listing = {"requests": [self.host_request(request)]}
                if not self.fits(listing):
                    raise InvalidInput("Exact request exceeds the declared worker reply frame")
                old = self.store.read(request["request_id"])
                if old is not None and old["digest"] != digest(request):
                    raise InvalidInput("request_id already belongs to different Exact request input")
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
                raise InvalidInput("Exact request kind must be submit or read")

    def host_request(self, request: dict) -> dict:
        return self.contract.host_request(request)

    def host_requests(self, args) -> dict:
        exact(args, set(), "host listing")
        if self.store.failed:
            raise InvalidInput("Exact request persistence is unconfirmed")
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
            raise InvalidInput("no original Exact request owns this result")
        result = final_of_json(args["result"])
        if record["result"] is not None:
            if record["result"] != result:
                raise InvalidInput("a different terminal result already belongs to this request")
            return {"accepted": True}
        if not self.fits(self.status(request_id, {**record, "result": result})):
            raise InvalidInput("Exact result exceeds the declared worker reply frame")
        self.store.write({**record, "result": result})
        return {"accepted": True}

    def observe(self, args) -> dict:
        exact(args, {"binding", "sources"}, "observation")
        records = self.store.records()
        fields = {"pending": sum(record["result"] is None for record in records),
                  "finished": sum(record["result"] is not None for record in records),
                  "requests": [record["request"]["request_id"] for record in records]}
        output = {"rows": [{"id": self.contract.row_id, "lane_id": self.contract.lane_id, "kind": "value",
                            "title": self.contract.title, "observed_at": time.time(),
                            "subject_id": self.contract.tool_name, "clock": None, "actor": None,
                            "fields": fields, "evidence": [], "related_ids": []}], "coverage": []}
        if not self.fits(output):
            # Aggregate counts remain available without truncating an intent or
            # claiming that an incomplete ID list is the complete inventory.
            del fields["requests"]
            fields["request_inventory"] = "read individual requests through " + self.contract.tool_name
        return output


def tool_result(output: dict) -> dict:
    return {"content": [{"type": "text", "text": "Retained Exact request state"}],
            "structuredContent": output, "isError": False}


def tools(contract: Contract) -> list[dict]:
    return [
        {"name": "lane_observe", "description": "Read retained Exact request counts and identities.",
         "inputSchema": INPUT_SCHEMA, "outputSchema": OUTPUT_SCHEMA},
        {"name": contract.tool_name, "description": "Read an original Exact request; host authority also admits new requests.",
         "inputSchema": contract.tool_input, "outputSchema": TOOL_OUTPUT},
        {"name": "lane_call", "description": "Host-admitted caller envelope; never export this control port.",
         "inputSchema": CONTROL},
        {"name": "lane_host_requests", "description": "List retained pending Exact requests.", "inputSchema": EMPTY},
        {"name": "lane_host_result", "description": "Retain an original host Exact terminal result.", "inputSchema": HOST_RESULT},
    ]


def serve(here: Path, contract: Contract) -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", type=Path, required=True)
    options = parser.parse_args()
    manifest = tomllib.loads((here / "lane.toml").read_text(encoding="utf-8"))
    worker = Worker(options.state, manifest["resources"]["max_reply_bytes"], contract)
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
                              "serverInfo": {"name": "masc-" + contract.package_id, "version": manifest["revision"]}}
                case "ping":
                    result = {}
                case "tools/list":
                    result = {"tools": tools(contract)}
                case "tools/call":
                    name, args = params.get("name"), params.get("arguments")
                    try:
                        match name:
                            case "lane_observe": output = worker.observe(args)
                            case "lane_host_requests": output = worker.host_requests(args)
                            case "lane_host_result": output = worker.host_result(args)
                            case "lane_call":
                                envelope = exact(args, {"tool", "arguments", "caller"}, "host call")
                                if envelope["tool"] != contract.tool_name:
                                    raise InvalidInput("unknown exported Exact tool")
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


