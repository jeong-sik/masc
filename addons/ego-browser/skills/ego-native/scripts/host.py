"""Host-only ego adapter. Run one JSON request on stdin; never replay dispatch.

The isolated Lane worker does not import or execute this module. One explicit
state directory owns one task space, its serialized calls and retained receipts.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from enum import Enum
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlparse
import uuid

from contract import RESULT_FIELDS, validate_result


class InvalidRequest(ValueError):
    pass


class Operation(str, Enum):
    OPEN = "open"
    RECOVER = "recover"
    OBSERVE = "observe"
    BATCH = "batch"
    FINISH = "finish"


class Status(str, Enum):
    OBSERVED = "observed"
    POSTCONDITION_MET = "postcondition_met"
    CLOSED = "closed"
    REJECTED = "rejected_before_effect"
    UNKNOWN = "outcome_unknown"


STEP_FIELDS = {
    "goto": {"url"}, "click": {"selector"}, "dblclick": {"selector"},
    "hover": {"selector"}, "drag": {"source", "destination"},
    "fill": {"selector", "text"}, "press": {"selector", "key"},
    "wait_for_selector": {"selector", "state"}, "wait_for_url": {"url"},
}


def text(value, label):
    if not isinstance(value, str) or not value.strip():
        raise InvalidRequest(f"{label} must be nonempty text")
    try:
        value.encode("utf-8")
    except UnicodeError as error:
        raise InvalidRequest(f"{label} must be valid UTF-8") from error
    return value


def fields(value, required, optional=()):
    if not isinstance(value, dict) or set(value) - set(required) - set(optional) or set(required) - set(value):
        raise InvalidRequest(f"Expected fields {sorted(required)}; optional {sorted(optional)}")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidRequest(f"Duplicate JSON field: {key}")
        result[key] = value
    return result


def decode(raw):
    def invalid_number(value):
        raise InvalidRequest(f"Nonfinite JSON number: {value}")
    return json.loads(raw, object_pairs_hook=unique_object, parse_constant=invalid_number)


def http_url(value):
    value = text(value, "url")
    try:
        parsed = urlparse(value)
    except ValueError as error:
        raise InvalidRequest("Malformed navigation URL") from error
    if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.username or parsed.password:
        raise InvalidRequest("Navigation requires an HTTP(S) URL without embedded credentials")


def condition(value):
    fields(value, (), ("url", "selector", "state"))
    if not value or not ({"url", "selector"} & set(value)):
        raise InvalidRequest("A condition needs url or selector")
    if "url" in value:
        http_url(value["url"])
    if "selector" in value:
        text(value["selector"], "condition selector")
    if "state" in value and ("selector" not in value or value["state"] not in ("visible", "hidden", "attached", "detached")):
        raise InvalidRequest("Condition state requires a selector and a documented element state")


def validate(request):
    fields(request, ("request_id", "operation"), ("name", "expected_url", "steps", "expect", "screenshot", "scope"))
    text(request["request_id"], "request_id")
    try:
        operation = Operation(request["operation"])
    except (ValueError, TypeError) as error:
        raise InvalidRequest("Unknown operation") from error
    allowed = {Operation.OPEN: {"name", "screenshot", "scope"},
               Operation.RECOVER: {"screenshot", "scope"},
               Operation.OBSERVE: {"screenshot", "scope"},
               Operation.BATCH: {"expected_url", "steps", "expect", "screenshot", "scope"},
               Operation.FINISH: set()}[operation]
    if set(request) - {"request_id", "operation"} - allowed:
        raise InvalidRequest("Fields do not belong to this operation")
    if "screenshot" in request and type(request["screenshot"]) is not bool:
        raise InvalidRequest("screenshot must be boolean")
    if "scope" in request and request["scope"] not in ("viewport", "full_page"):
        raise InvalidRequest("scope must be viewport or full_page")
    if operation is Operation.OPEN:
        text(request.get("name"), "name")
    if operation is Operation.BATCH:
        # Initial ego tabs use chrome://new-tab-page/. This is an equality
        # guard from a prior observation, not an allowed navigation target.
        text(request.get("expected_url"), "expected_url")
        if not isinstance(request.get("steps"), list) or not request["steps"]:
            raise InvalidRequest("batch needs nonempty steps")
        for step in request["steps"]:
            if (not isinstance(step, dict) or not isinstance(step.get("action"), str)
                    or step["action"] not in STEP_FIELDS):
                raise InvalidRequest("Unknown batch action")
            required = STEP_FIELDS[step["action"]]
            fields(step, {"action", *required})
            for key in required:
                if key == "text":
                    if not isinstance(step[key], str):
                        raise InvalidRequest("fill text must be a string")
                    try:
                        step[key].encode("utf-8")
                    except UnicodeError as error:
                        raise InvalidRequest("fill text must be valid UTF-8") from error
                else:
                    text(step[key], key)
            if step["action"] in ("goto", "wait_for_url"):
                http_url(step["url"])
            if step["action"] == "wait_for_selector":
                condition({"selector": step["selector"], "state": step["state"]})
        if "expect" in request:
            condition(request["expect"])
    return operation


def atomic_json(path, value):
    """Publish and sync the exact bytes and parent directory before returning."""
    encoded = json.dumps(value, ensure_ascii=False, allow_nan=False).encode()
    fd, temporary = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        parent = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def locked(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def failure(request, status, message, session=None):
    return {"request_id": request["request_id"], "operation": request["operation"],
            "status": status.value, "session": session, "completed_steps": 0,
            "failed_step": None, "url": None, "title": None, "snapshot": None,
            "error": {"code": None, "message": message}, "screenshot": None}


def publish(directory, result, identity):
    observed = time.time()
    session = result["session"]
    session_id = session["epoch"] if session else identity
    envelope = {"source_id": "ego-browser", "incarnation": session_id,
        "cursor": result["request_id"],
        "complete": result["status"] in (Status.OBSERVED.value, Status.POSTCONDITION_MET.value, Status.CLOSED.value),
        "detail": result["error"]["message"] if result["error"] else None,
        "observations": [{"id": result["request_id"], "kind": "ego_browser",
            "observed_at": observed, "actor": None, "evidence": [], "fields": result}]}
    atomic_json(directory / "snapshot.json", envelope)


def invoke(command, request, session, intent, result_path, screenshot_path):
    runtime = Path(__file__).with_name("runtime.mjs").read_text()
    script = ("const request=" + json.dumps(request, ensure_ascii=True) + ";\n"
        "const session=" + json.dumps(session) + ";\n"
        "const resultPath=" + json.dumps(str(result_path)) + ";\n"
        "const screenshotPath=" + json.dumps(str(screenshot_path)) + ";\n"
        "const intent=" + json.dumps(intent) + ";\n" + runtime)
    # A fresh private result channel avoids parsing CLI banners or stderr for
    # control decisions. Secrets in fill text are not written to script logs.
    child = subprocess.Popen([command, "nodejs"], stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
    try:
        child.communicate(script)
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait()
    if not result_path.exists():
        return failure(request, Status.UNKNOWN,
            f"ego returned no structured result (exit {child.returncode}); do not replay this request", session)
    try:
        result = decode(result_path.read_text())
        fields(result, RESULT_FIELDS)
        if result["request_id"] != request["request_id"] or result["operation"] != request["operation"]:
            raise InvalidRequest("ego reply belongs to another request")
        returned = result["session"]
        if returned is not None and not isinstance(returned, dict):
            raise InvalidRequest("Invalid task-space identity")
        if session and returned != session:
            raise InvalidRequest("ego reply changed the bound task space")
        if not session and returned is not None:
            if intent is None or any(returned.get(key) != value for key, value in intent.items()):
                raise InvalidRequest("ego reply changed the task-space ownership intent")
        if result["screenshot"] is not None:
            if result["screenshot"] != str(screenshot_path):
                raise InvalidRequest("Unexpected screenshot path")
            result["screenshot"] = {"path": str(screenshot_path),
                "sha256": hashlib.sha256(screenshot_path.read_bytes()).hexdigest()}
        validate_result(result)
        if result["completed_steps"] > len(request.get("steps", [])):
            raise InvalidRequest("ego reply exceeds the submitted steps")
        if result["failed_step"] is not None and result["failed_step"] >= len(request.get("steps", [])):
            raise InvalidRequest("ego reply names an unsubmitted failed step")
        if result["status"] == Status.POSTCONDITION_MET.value and "expect" not in request:
            raise InvalidRequest("ego reply claims an unrequested postcondition")
        if result["status"] in (Status.OBSERVED.value, Status.POSTCONDITION_MET.value):
            if result["completed_steps"] != len(request.get("steps", [])):
                raise InvalidRequest("ego reply omitted submitted steps")
            if request["operation"] == Operation.BATCH.value:
                if ("expect" in request) != (result["status"] == Status.POSTCONDITION_MET.value):
                    raise InvalidRequest("ego reply did not report the requested postcondition")
        return result
    except (ValueError, TypeError, KeyError, OSError) as error:
        return failure(request, Status.UNKNOWN, f"Unusable ego result: {error}; do not replay", session)


def run(directory, command, request):
    operation = validate(request)  # Entire batch is validated before effects.
    digest = hashlib.sha256(json.dumps(request, sort_keys=True, ensure_ascii=True).encode()).hexdigest()
    key = hashlib.sha256(request["request_id"].encode()).hexdigest()
    with locked(directory):
        identity_path = directory / "identity.json"
        if not identity_path.exists():
            atomic_json(identity_path, {"id": str(uuid.uuid4())})
        identity = decode(identity_path.read_text())["id"]
        receipts = directory / "receipts"
        receipts.mkdir(exist_ok=True, mode=0o700)
        receipt_path = receipts / (key + ".json")
        if receipt_path.exists():
            receipt = decode(receipt_path.read_text())
            if receipt["request_sha256"] != digest:
                raise InvalidRequest("request_id already belongs to different input")
            if receipt["phase"] == "settled":
                return receipt["result"]
            return failure(request, Status.UNKNOWN,
                "This request was already dispatched without a retained result; inspect before any new action")
        session_path = directory / "session.json"
        session = decode(session_path.read_text()) if session_path.exists() else None
        intent_path = directory / "open-intent.json"
        intent = decode(intent_path.read_text()) if intent_path.exists() else None
        if operation not in (Operation.OPEN, Operation.RECOVER) and session is None:
            raise InvalidRequest("Open a task space first; use recover if the initial open reply was lost")
        if operation is Operation.OPEN and session and session["name"] != request["name"]:
            raise InvalidRequest("This state directory already owns another task; finish it first")
        if operation is Operation.OPEN and session is None and intent is not None:
            raise InvalidRequest("An unresolved open intent exists; use recover, not another open")
        if operation is Operation.RECOVER and session is None and intent is None:
            raise InvalidRequest("There is no retained open intent to recover")
        executable = shutil.which(command)
        if executable is None:
            result = failure(request, Status.REJECTED, "ego-browser executable is unavailable; install and complete onboarding", session)
        else:
            if operation is Operation.OPEN and session is None:
                intent = {"name": request["name"], "epoch": str(uuid.uuid4()),
                          "owner_identity": identity, "native_name": request["name"] + " [masc:" + identity + "]"}
                atomic_json(intent_path, intent)
            # Sync before process creation: crash/lost stdout must not replay.
            atomic_json(receipt_path, {"request_sha256": digest, "phase": "dispatching"})
            with tempfile.TemporaryDirectory(prefix="ego-call-", dir=directory) as temporary:
                try:
                    result = invoke(executable, request, session, intent, Path(temporary) / "result.json", directory / (key + ".png"))
                except OSError as error:
                    # The native process may already have entered. Conservatively
                    # retain uncertainty rather than classify exception text.
                    result = failure(request, Status.UNKNOWN, str(error), session)
        if result["status"] == Status.CLOSED.value:
            atomic_json(session_path, None)
            atomic_json(intent_path, None)
        elif result["session"] is not None:
            atomic_json(session_path, result["session"])
        publish(directory, result, identity)
        atomic_json(receipt_path, {"request_sha256": digest, "phase": "settled", "result": result})
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", required=True, type=Path,
                        help="Private per-installation host state directory")
    parser.add_argument("--ego-command", default="ego-browser")
    args = parser.parse_args()
    try:
        request = decode(sys.stdin.read())
        result = run(args.state_dir.expanduser().resolve(), args.ego_command, request)
    except (InvalidRequest, json.JSONDecodeError) as error:
        print(json.dumps({"status": Status.REJECTED.value, "error": str(error)}))
        return 2
    except OSError as error:
        # Persistence may have failed after native input; the retained dispatch
        # identity is the replay barrier. Never retry the CLI here.
        print(json.dumps({"status": Status.UNKNOWN.value, "error": str(error)}))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["status"] in (Status.OBSERVED.value, Status.POSTCONDITION_MET.value, Status.CLOSED.value) else 1


if __name__ == "__main__":
    raise SystemExit(main())
