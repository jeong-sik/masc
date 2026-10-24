"""Private, single-connection host bridge. Never a model tool or secret store.

The host supplies the endpoint in its private invocation context. This module
never discovers a replacement endpoint, reconnects, retries or logs a payload.
Construct the handle before calling bind so the login job can cancel even while
the original handshake is blocked. Release on normal completion; cancel on abort.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum, auto
import json
import math
import os
from pathlib import Path
import socket
import stat
import threading
import uuid


class BridgeError(Exception):
    """Fixed failures; neither provider prose nor request/reply fragments."""
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def _constant(_value):
    raise ValueError("nonfinite JSON")


def _finite_float(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("nonfinite JSON")
    return number


def _uuid(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise ValueError("invalid identity")
    return value


@dataclass(frozen=True)
class Endpoint:
    socket_path: str
    invocation_id: str = field(repr=False)
    max_message_bytes: int

    @classmethod
    def decode(cls, value):
        try:
            if not isinstance(value, dict) or set(value) != {"socket_path", "invocation_id", "max_message_bytes"}:
                raise ValueError("invalid endpoint")
            path, invocation_id, maximum = (value[key] for key in ("socket_path", "invocation_id", "max_message_bytes"))
            if (not isinstance(path, str) or "\x00" in path or not Path(path).is_absolute() or str(Path(path)) != path
                    or not isinstance(invocation_id, str) or len(invocation_id) != 64
                    or any(char not in "0123456789abcdef" for char in invocation_id)
                    or type(maximum) is not int or maximum < len('{"error":"outcome_unknown"}')):
                raise ValueError("invalid endpoint")
            parent = Path(path).parent
            info = parent.lstat()
            if (str(parent.resolve()) != str(parent) or not stat.S_ISDIR(info.st_mode)
                    or stat.S_IMODE(info.st_mode) != 0o700 or info.st_uid != os.getuid()):
                raise ValueError("unsafe endpoint parent")
            target = Path(path).lstat()
            if not stat.S_ISSOCK(target.st_mode) or target.st_uid != os.getuid():
                raise ValueError("unsafe endpoint")
            return cls(path, invocation_id, maximum)
        except (ValueError, TypeError, OSError, UnicodeError):
            raise BridgeError("unavailable") from None


class _Phase(Enum):
    NEW = auto()
    BINDING = auto()
    BOUND = auto()
    CANCELLED = auto()


class Companion:
    def __init__(self, descriptor):
        self._endpoint = Endpoint.decode(descriptor)
        self._io_lock, self._state_lock = threading.Lock(), threading.Lock()
        self._phase = _Phase.NEW
        self._socket = None
        self._operation_id = None
        self._tab_id = None

    def bind(self, *, browser_instance_id, tab_id):
        try:
            _uuid(browser_instance_id)
            if type(tab_id) is not int or tab_id < 0:
                raise ValueError("invalid tab")
        except (ValueError, TypeError, AttributeError):
            raise BridgeError("not_started") from None
        with self._state_lock:
            if self._phase is not _Phase.NEW:
                raise BridgeError("not_started")
            self._phase = _Phase.BINDING
            try:
                flow = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            except OSError:
                self._phase = _Phase.CANCELLED
                raise BridgeError("unavailable") from None
            # Register before connect: cancel must own the original socket
            # throughout connect, handshake send and handshake receive.
            self._socket = flow
            self._tab_id = tab_id
        try:
            flow.connect(self._endpoint.socket_path)
        except OSError:
            self.cancel()
            raise BridgeError("unavailable") from None
        try:
            bound = self._exchange({"invocation_id": self._endpoint.invocation_id,
                                    "browser_instance_id": browser_instance_id, "tab_id": tab_id}, binding=True)
            if not isinstance(bound, dict) or set(bound) != {"bound", "operation_id"} or bound["bound"] is not True:
                raise ValueError("invalid binding")
            operation_id = _uuid(bound["operation_id"])
            with self._state_lock:
                if self._phase is not _Phase.BINDING or self._socket is not flow:
                    raise BridgeError("outcome_unknown")
                self._operation_id = operation_id
                self._phase = _Phase.BOUND
        except (BridgeError, ValueError, TypeError, KeyError, AttributeError):
            self.cancel()
            raise BridgeError("outcome_unknown") from None

    @property
    def operation_id(self):
        with self._state_lock:
            return self._operation_id

    def cancel(self):
        # Independent of the I/O lock: cancellation must interrupt a blocked
        # recv and wake the host's original-operation disconnect watcher.
        with self._state_lock:
            self._phase = _Phase.CANCELLED
            flow, self._socket = self._socket, None
        if flow is not None:
            try:
                flow.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                flow.close()
            except OSError:
                pass

    def _exchange(self, value, *, binding):
        with self._io_lock:
            try:
                raw = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
            except (ValueError, TypeError, UnicodeError, RecursionError):
                raise BridgeError("not_started") from None
            if len(raw) > self._endpoint.max_message_bytes:
                raise BridgeError("not_started")
            with self._state_lock:
                expected = _Phase.BINDING if binding else _Phase.BOUND
                if self._phase is not expected:
                    raise BridgeError("not_started")
                flow = self._socket
            if flow is None:
                raise BridgeError("not_started")
            try:
                # A partial send has an uncertain outcome. There is no retry.
                flow.sendall(raw + b"\n")
                reply = bytearray()
                while b"\n" not in reply:
                    chunk = flow.recv(min(4096, self._endpoint.max_message_bytes + 2 - len(reply)))
                    if not chunk:
                        raise ValueError("departed host")
                    reply.extend(chunk)
                    if len(reply) > self._endpoint.max_message_bytes + 1:
                        raise ValueError("oversized reply")
                line, trailing = bytes(reply).split(b"\n", 1)
                if trailing:
                    raise ValueError("unexpected pipelined reply")
                result = json.loads(line.decode("utf-8"), object_pairs_hook=_object,
                                    parse_constant=_constant, parse_float=_finite_float)
                if isinstance(result, dict) and set(result) == {"error"}:
                    error = result["error"]
                    if error not in ("unavailable", "not_started", "outcome_unknown"):
                        error = "outcome_unknown"
                    self.cancel()
                    raise BridgeError(error)
                with self._state_lock:
                    if self._phase is not expected or self._socket is not flow:
                        raise ValueError("cancelled original operation")
                return result
            except BridgeError:
                raise
            except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
                self.cancel()
                raise BridgeError("outcome_unknown") from None

    def _command(self, command):
        with self._state_lock:
            if self._phase is not _Phase.BOUND:
                raise BridgeError("not_started")
            operation_id = self._operation_id
        result = self._exchange({**command, "operation_id": operation_id}, binding=False)
        if not isinstance(result, dict) or set(result) != {"value"} or not isinstance(result["value"], dict):
            self.cancel()
            raise BridgeError("outcome_unknown")
        return result["value"]

    def prepare(self, *, extension_id, directory, program, arguments):
        with self._state_lock:
            if self._phase is not _Phase.BOUND:
                raise BridgeError("not_started")
            tab_id = self._tab_id
        result = self._command({"kind": "prepare", "tab_id": tab_id, "extension_id": extension_id,
                                "directory": directory, "program": program, "arguments": arguments})
        if set(result) != {"prepared"} or result["prepared"] is not True:
            self.cancel()
            raise BridgeError("outcome_unknown")

    def invoke(self, *, program, arguments):
        return self._command({"kind": "invoke", "program": program, "arguments": arguments})

    def release(self):
        result = self._command({"kind": "release"})
        if set(result) != {"released"} or result["released"] is not True:
            self.cancel()
            raise BridgeError("outcome_unknown")
        self.cancel()
