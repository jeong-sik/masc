"""Native ego result contract shared by the host and isolated observer.

Only normalized results cross this boundary. In particular, a screenshot is a
host-verified path and digest, never the raw CLI's screenshot return value.
"""

RESULT_FIELDS = frozenset((
    "request_id", "operation", "status", "session", "completed_steps",
    "failed_step", "url", "title", "snapshot", "error", "screenshot",
))
SESSION_FIELDS = frozenset(("space_id", "name", "page", "epoch", "owner_identity", "native_name"))
OPERATIONS = frozenset(("open", "observe", "batch", "finish", "recover"))
SUCCESS_STATUSES = frozenset(("observed", "postcondition_met", "closed"))
FAILURE_STATUSES = frozenset(("rejected_before_effect", "outcome_unknown"))


class InvalidResult(ValueError):
    pass


def _fields(value, required, optional=()):
    if not isinstance(value, dict) or set(value) - set(required) - set(optional) or set(required) - set(value):
        raise InvalidResult(f"Expected result fields {sorted(required)}; optional {sorted(optional)}")


def _text(value, label):
    if not isinstance(value, str) or not value.strip():
        raise InvalidResult(f"{label} must be nonempty text")
    _utf8(value, label)


def _utf8(value, label):
    try:
        value.encode("utf-8")
    except UnicodeError as error:
        raise InvalidResult(f"{label} must be valid UTF-8") from error


def validate_result(result) -> None:
    """Reject malformed or internally inconsistent native result envelopes."""
    _fields(result, RESULT_FIELDS)
    _text(result["request_id"], "request_id")
    operation, status = result["operation"], result["status"]
    if not isinstance(operation, str) or operation not in OPERATIONS:
        raise InvalidResult("Unknown ego operation")
    if not isinstance(status, str) or status not in SUCCESS_STATUSES | FAILURE_STATUSES:
        raise InvalidResult("Unknown ego status")
    if ((status == "closed" and operation != "finish")
            or (status == "postcondition_met" and operation != "batch")
            or (status == "observed" and operation == "finish")):
        raise InvalidResult("Ego status does not belong to this operation")
    completed, failed = result["completed_steps"], result["failed_step"]
    if type(completed) is not int or completed < 0:
        raise InvalidResult("completed_steps must be a nonnegative integer")
    if failed is not None and (type(failed) is not int or failed != completed):
        raise InvalidResult("failed_step must be null or the next uncompleted step")
    if operation != "batch" and (completed != 0 or failed is not None):
        raise InvalidResult("Only batch operations may report step progress")
    if status in SUCCESS_STATUSES and failed is not None:
        raise InvalidResult("A successful result cannot report a failed step")
    if status == "rejected_before_effect" and (completed != 0 or failed is not None):
        raise InvalidResult("A pre-effect rejection cannot report executed steps")
    session = result["session"]
    if session is not None:
        _fields(session, SESSION_FIELDS)
        if type(session["space_id"]) is not int or session["space_id"] <= 0:
            raise InvalidResult("space_id must be a positive integer")
        if session["page"] != "p1":
            raise InvalidResult("The bound ego page must be p1")
        for key in ("name", "epoch", "owner_identity", "native_name"):
            _text(session[key], f"session {key}")
    for key in ("url", "title", "snapshot"):
        if result[key] is not None and not isinstance(result[key], str):
            raise InvalidResult(f"{key} must be text or null")
        if result[key] is not None:
            _utf8(result[key], key)
    if status in SUCCESS_STATUSES and session is None:
        raise InvalidResult("Successful ego results require a bound session")
    if status in ("observed", "postcondition_met") and result["snapshot"] is None:
        raise InvalidResult("Observed ego state requires a snapshot")
    error = result["error"]
    if status in SUCCESS_STATUSES:
        if error is not None:
            raise InvalidResult("Successful ego results cannot contain an error")
    else:
        _fields(error, ("code", "message"), ("observation",))
        if error["code"] is not None and not isinstance(error["code"], str):
            raise InvalidResult("error code must be text or null")
        if error["code"] is not None:
            _utf8(error["code"], "error code")
        if not isinstance(error["message"], str):
            raise InvalidResult("error message must be text")
        _utf8(error["message"], "error message")
        if "observation" in error and not isinstance(error["observation"], str):
            raise InvalidResult("observation error must be text")
        if "observation" in error:
            _utf8(error["observation"], "observation error")
    screenshot = result["screenshot"]
    if screenshot is not None:
        _fields(screenshot, ("path", "sha256"))
        _text(screenshot["path"], "screenshot path")
        digest = screenshot["sha256"]
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise InvalidResult("screenshot sha256 must be a lowercase SHA-256 digest")
