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
# The typed result for a request this worker could never list to the host.
REQUEST_BODY_REFUSED = {"status": "input_refused", "kind": "request_body_refused"}


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
    additional_tools: tuple[dict, ...] = ()
    tool_for_request: Callable[[dict], str] | None = None

    def exported_names(self) -> set[str]:
        return {self.tool_name, *(tool["name"] for tool in self.additional_tools)}

    def request_tool(self, request: dict) -> str:
        name = self.tool_name if self.tool_for_request is None else self.tool_for_request(request)
        if name not in self.exported_names():
            raise InvalidInput("request purpose has no exported Exact tool")
        return name


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


def is_digest(value) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def record_id(record: dict) -> str:
    """A pending record names its request; a terminal keeps only the id."""
    return record["request"]["request_id"] if "request" in record else record["request_id"]


@dataclass(frozen=True)
class Retained:
    """What a listing or an observation needs from a record, without its body."""
    request_id: str
    pending: bool


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
        case "invalid_output" | "output_limit_reached":
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
        # Why this worker stopped trusting its store. Every later call fails
        # with it until the worker starts again.
        self.failure: str | None = None
        # Every record's identity and state by file name, built by the first
        # inventory and kept current by write. The host mounts each state
        # volume into one worker, so this worker is the only writer. Listings
        # and submits recheck pending records and stop on external changes.
        # read() checks its named record: a missing leaf is absent, a damaged
        # record fails only that call. Added records and changes to finished
        # records otherwise become visible at the next inventory after restart.
        self.index: dict[str, Retained] | None = None
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

    def trusted(self) -> None:
        if self.failure is not None:
            raise InvalidInput(self.failure)

    def stop(self, reason: str) -> InvalidInput:
        self.failure = reason + "; reopen and inspect the store"
        return InvalidInput(self.failure)

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
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise InvalidInput("Exact request record is not a regular file")
            # Keep ownership of the raw fd even if constructing the stream fails.
            with os.fdopen(fd, "r", encoding="utf-8", closefd=False) as source:
                record = object_value(decode(source.read()), "retained record")
        finally:
            os.close(fd)
        if type(record.get("version")) is not int or record["version"] != 2:
            raise InvalidInput("unknown Exact request record version")
        if set(record) == {"version", "request", "digest", "result"}:
            request = self.contract.parse_request(record["request"])
            self.contract.request_tool(request)
            if self.path(request["request_id"]).name != name or record["digest"] != digest(request):
                raise InvalidInput("Exact request record identity or input digest disagrees")
            if record["result"] is not None:
                raise InvalidInput("a finished Exact request must not retain its input body")
        elif set(record) == ({"version", "request_id", "digest", "result", "tool"}
                             if len(self.contract.exported_names()) > 1
                             else {"version", "request_id", "digest", "result"}):
            # Every terminal retains only its identity, input digest and result.
            # Multi-tool workers also retain the destination without the body.
            if len(self.contract.exported_names()) > 1:
                tool = text(record["tool"], "Exact terminal tool")
                if tool not in self.contract.exported_names():
                    raise InvalidInput("Exact terminal has no exported tool")
            if self.path(record["request_id"]).name != name or not is_digest(record["digest"]):
                raise InvalidInput("Exact terminal identity or input digest disagrees")
            final_of_json(record["result"])
        else:
            raise InvalidInput("retained record is neither a pending Exact request nor a terminal")
        return record

    def read(self, request_id: str) -> dict | None:
        self.trusted()
        with self.open_directory() as directory_fd:
            try:
                return self.read_path(self.path(request_id).name, directory_fd)
            except FileNotFoundError:
                # Only the leaf can be absent: the original directory is open
                # and its identity is checked again before returning to caller.
                return None

    def retained(self, name: str, directory_fd: int) -> Retained:
        """One record's identity and state. Its body is dropped on return."""
        record = self.read_path(name, directory_fd)
        return Retained(record_id(record), record["result"] is None)

    def inventory(self) -> list[tuple[str, Retained]]:
        """Every record's file name, request id and state, in name order.

        The first call after the worker starts reads and checks each record,
        one at a time, so it holds one request body instead of the whole store.
        A missing or invalid record stops the worker; transient I/O errors
        fail only the call. Later calls answer from
        memory after checking that the store directory is the one this worker
        opened; finished bodies are not read again."""
        self.trusted()
        if self.index is None:
            index = {}
            with self.open_directory() as directory_fd:
                with os.scandir(directory_fd) as entries:
                    names = sorted(entry.name for entry in entries if entry.name.endswith(".json"))
                for name in names:
                    try:
                        index[name] = self.retained(name, directory_fd)
                    except (FileNotFoundError, ValueError) as error:
                        raise self.stop(f"Exact request record {name!r} cannot be read: {error}") from error
            self.index = index
        else:
            self.check_directory()
        return sorted(self.index.items())

    def pending(self) -> list[dict]:
        """The pending records in name order, read and checked again. A pending
        record that is gone, invalid or finished changed outside this worker,
        which stops it. Transient I/O errors fail only the call."""
        names = [name for name, retained in self.inventory() if retained.pending]
        records = []
        with self.open_directory() as directory_fd:
            for name in names:
                try:
                    record = self.read_path(name, directory_fd)
                except (FileNotFoundError, ValueError) as error:
                    raise self.stop(f"Exact request record {name!r} changed outside this worker: {error}") from error
                if record["result"] is not None:
                    raise self.stop(f"Exact request record {name!r} was finished outside this worker")
                records.append(record)
        return records

    def write(self, record: dict) -> None:
        self.trusted()
        try:
            with self.open_directory() as directory_fd:
                temporary = ".exact-" + uuid.uuid4().hex
                name = self.path(record_id(record)).name
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directory_fd)
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as target:
                        target.write(canonical(record) + "\n")
                        target.flush()
                        os.fsync(target.fileno())
                    os.replace(temporary, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
                    temporary = None
                    os.fsync(directory_fd)
                    if self.index is not None:
                        self.index[name] = Retained(record_id(record), record["result"] is None)
                finally:
                    if temporary is not None:
                        os.unlink(temporary, dir_fd=directory_fd)
        except (OSError, InvalidInput):
            self.failure = "Exact request persistence is unconfirmed; reopen and inspect the store"
            raise


class Worker:
    def __init__(self, state: Path, max_reply_bytes: int, contract: Contract):
        self.contract = contract
        self.store = Store(state, contract)
        self.max_reply_bytes = max_reply_bytes

    def fits(self, result: dict) -> bool:
        envelope = {"jsonrpc": "2.0", "id": 2 ** 53, "result": tool_result(result)}
        return len((encode_output(envelope) + "\n").encode("utf-8")) <= self.max_reply_bytes

    def retained_tool(self, record: dict) -> str:
        if "request" in record:
            return self.contract.request_tool(record["request"])
        return record["tool"] if len(self.contract.exported_names()) > 1 else self.contract.tool_name

    def terminal_record(self, request_id: str, request_digest: str, result: dict, tool_name: str) -> dict:
        record = {"version": 2, "request_id": request_id, "digest": request_digest, "result": result}
        if len(self.contract.exported_names()) > 1:
            record["tool"] = tool_name
        return record

    def status(self, request_id: str, record: dict | None) -> dict:
        if record is None:
            return {"request_id": request_id, "state": "absent"}
        if record["result"] is None:
            return {"request_id": request_id, "state": "pending"}
        return {"request_id": request_id, "state": "finished", "result": record["result"]}

    def invoke(self, args, caller: dict, *, tool_name: str | None = None) -> dict:
        tool_name = self.contract.tool_name if tool_name is None else tool_name
        text(tool_name, "tool")
        if tool_name not in self.contract.exported_names():
            raise InvalidInput("unknown exported Exact tool")
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
                if self.contract.request_tool(request) != tool_name:
                    raise InvalidInput("Exact request purpose does not belong to this tool")
                request_id, request_digest = request["request_id"], digest(request)
                # A retained request keeps its answer even if the declared frame
                # changed after it was admitted.
                old = self.store.read(request_id)
                if old is not None:
                    if old["digest"] != request_digest:
                        raise InvalidInput("request_id already belongs to different Exact request input")
                    if self.retained_tool(old) != tool_name:
                        raise InvalidInput("retained Exact request belongs to another tool")
                    return self.status(request_id, old)
                listing = [self.host_request(request)]
                if not self.fits({"requests": listing}):
                    # No listing reply can carry this request, so it never
                    # becomes an intent. The refusal is kept without the body:
                    # a read after a lost reply gives this answer, not absent.
                    refused = self.terminal_record(request_id, request_digest, {**REQUEST_BODY_REFUSED}, tool_name)
                    self.store.write(refused)
                    return self.status(request_id, refused)
                pending = [self.host_request(record["request"]) for record in self.store.pending()]
                if not self.fits({"requests": pending + listing}):
                    return {"request_id": request_id, "state": "capacity_wait"}
                accepted = {"version": 2, "request": request, "digest": request_digest, "result": None}
                self.store.write(accepted)
                return self.status(request_id, accepted)
            case "read":
                exact(args, {"kind", "request_id"}, "read")
                request_id = text(args["request_id"], "request_id")
                record = self.store.read(request_id)
                if record is not None:
                    if self.retained_tool(record) != tool_name:
                        raise InvalidInput("retained Exact request belongs to another tool")
                return self.status(request_id, record)
            case _:
                raise InvalidInput("Exact request kind must be submit or read")

    def host_request(self, request: dict) -> dict:
        return self.contract.host_request(request)

    def host_requests(self, args) -> dict:
        exact(args, set(), "host listing")
        requests = [self.host_request(record["request"]) for record in self.store.pending()]
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
        terminal = self.terminal_record(request_id, record["digest"], result, self.retained_tool(record))
        self.store.write(terminal)
        return {"accepted": True}

    def observe(self, args) -> dict:
        exact(args, {"binding", "sources"}, "observation")
        inventory = [retained for _, retained in self.store.inventory()]
        fields = {"pending": sum(retained.pending for retained in inventory),
                  "finished": sum(not retained.pending for retained in inventory),
                  "requests": [retained.request_id for retained in inventory]}
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
        *contract.additional_tools,
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
                                text(envelope["tool"], "tool")
                                if envelope["tool"] not in contract.exported_names():
                                    raise InvalidInput("unknown exported Exact tool")
                                output = worker.invoke(envelope["arguments"], object_value(envelope["caller"], "caller"),
                                                       tool_name=envelope["tool"])
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


