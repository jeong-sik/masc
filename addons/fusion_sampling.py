"""Shared consistency contract for a retained Fusion sampling result."""
import json

from protocol import InvalidInput, boolean, evidence, object_value, optional_string, string


def coverage(value, label):
    value = object_value(value, label)
    for key in ("source_id", "incarnation"):
        string(value.get(key), f"{label}.{key}")
    for key in ("cursor", "detail"):
        if key not in value:
            raise InvalidInput(f"{label}.{key} is required")
        optional_string(value[key], f"{label}.{key}")
    boolean(value.get("complete"), f"{label}.complete")
    return value


def response_problem(response):
    if response.get("role") != "assistant":
        return "Fusion requires an assistant sampling response"
    content = response.get("content")
    if not isinstance(content, dict) or content.get("type") != "text" or not isinstance(content.get("text"), str):
        return "Fusion requires free-text sampling content"
    model = response.get("model")
    if not isinstance(model, str) or not model.strip():
        return "Fusion requires an actual response model"
    if response.get("stopReason") is not None and not isinstance(response["stopReason"], str):
        return "Fusion sampling stop reason must be text or null"
    return None


def terminal_error(error, computation, refs):
    error = object_value(error, "sampling_error")
    # The pinned host MCP client emits internal_error for callback Error,
    # with no data payload. Reject worker-supplied envelope extensions.
    if (type(error.get("code")) is not int or error["code"] != -32603
            or set(error) not in ({"code", "message"}, {"code", "message", "data"})
            or error.get("data") is not None):
        raise InvalidInput("Sampling error envelope differs from the host callback error")
    try:
        terminal = object_value(json.loads(error.get("message")), "sampling terminal error")
    except (json.JSONDecodeError, TypeError) as cause:
        raise InvalidInput("Sampling error must retain the host terminal outcome") from cause
    if terminal.get("status") != computation["status"]:
        raise InvalidInput("Computation status differs from the host terminal outcome")
    keys = {"status", "error", "evidence"}
    if terminal["status"] == "invalid_response":
        keys.add("response")
    elif terminal["status"] == "outcome_unknown" and "request" in terminal:
        keys = {"status", "error", "request"}
    if set(terminal) != keys or not isinstance(terminal.get("error"), str):
        raise InvalidInput("Sampling terminal fields differ from the host outcome contract")
    expected = terminal.get("evidence")
    if expected is not None and (not isinstance(expected, dict) or "outcome" not in expected):
        raise InvalidInput("Terminal evidence requires an attested outcome")
    if expected is None and terminal["status"] == "outcome_unknown" and "request" in terminal:
        expected = {"request": terminal["request"]}
    if expected != refs or ("request" in terminal and terminal["request"] != refs.get("request")):
        raise InvalidInput("Model evidence differs from the host terminal outcome")
    return terminal


def validate_host_receipt(computation, fields, refs, row_evidence, receipts):
    retained = evidence(row_evidence)
    if any(ref not in retained or ref["uri"] != "lane-evidence:" + ref["sha256"]
           for ref in refs.values()):
        raise InvalidInput("Model references must identify retained row evidence")
    if not isinstance(receipts, list):
        raise InvalidInput("Computation requires host-projected sampling receipts")
    matches = [receipt for receipt in receipts if isinstance(receipt, dict)
               and receipt.get("request") == refs["request"]]
    if len(matches) != 1 or matches[0].get("outcome") != refs.get("outcome"):
        raise InvalidInput("Model references do not identify this producer's host sampling receipt")
    terminal = matches[0].get("terminal")
    if terminal is None:
        if computation["status"] != "outcome_unknown" or "outcome" in refs:
            raise InvalidInput("Pending host sampling cannot certify a terminal result")
        return
    terminal = object_value(terminal, "host sampling terminal")
    response = fields.get("sampling_response")
    if response is not None:
        actual = object_value(terminal.get("response"), "host sampling response")
        if terminal.get("status") == "invalid_response" and computation["status"] == "invalid_response":
            failure = terminal_error(fields.get("sampling_error"), computation, refs)
            if failure.get("error") != terminal.get("error") or failure.get("response") != actual:
                raise InvalidInput("Computation differs from the host-retained sampling failure")
        elif terminal.get("status") != "answered" or fields.get("sampling_error") is not None:
            raise InvalidInput("Computation response was not returned by host sampling")
        # The broker adds its receipt coordinates after retaining the response.
        supplied = dict(object_value(response, "sampling_response"))
        metadata = dict(object_value(supplied.get("_meta"), "sampling_response metadata"))
        metadata.pop("masc.lane_sampling", None)
        if metadata:
            supplied["_meta"] = metadata
        else:
            supplied.pop("_meta", None)
        expected = dict(actual)
        expected_metadata = dict(expected["_meta"]) if isinstance(expected.get("_meta"), dict) else {}
        expected_metadata.pop("masc.lane_sampling", None)
        if expected_metadata:
            expected["_meta"] = expected_metadata
        else:
            expected.pop("_meta", None)
        if supplied != expected:
            raise InvalidInput("Computation differs from the host-retained sampling response")
    else:
        if terminal.get("status") == "invalid_response" and terminal.get("response") is not None:
            raise InvalidInput("Invalid response must preserve the host-retained response")
        if terminal.get("status") != computation["status"]:
            raise InvalidInput("Computation contradicts the host sampling terminal status")
        failure = terminal_error(fields.get("sampling_error"), computation, refs)
        if failure.get("error") != terminal.get("error"):
            raise InvalidInput("Computation differs from the host-retained sampling failure")


def validate_sampling_result(computation, fields, refs, row_evidence, receipts):
    validate_host_receipt(computation, fields, refs, row_evidence, receipts)
    if "sampling_response" not in fields or "sampling_error" not in fields:
        raise InvalidInput("Computation must retain its actual sampling response and error")
    response, error = fields["sampling_response"], fields["sampling_error"]
    validation_error = fields.get("validation_error")
    if computation["status"] == "answered":
        response = object_value(response, "sampling_response")
        content = object_value(response.get("content"), "sampling_response.content")
        metadata = object_value(response.get("_meta"), "sampling_response metadata")
        if (error is not None or validation_error is not None or response_problem(response) is not None
                or response.get("model") != computation["model"]
                or content.get("type") != "text" or content.get("text") != computation["text"]
                or response.get("stopReason") != computation["stop_reason"]
                or metadata.get("masc.lane_sampling") != refs):
            raise InvalidInput("Computation differs from its actual sampling response")
    else:
        if any(computation[key] is not None for key in ("model", "text", "stop_reason")):
            raise InvalidInput("Failed or uncertain computation cannot claim a sampling response")
        if computation["status"] == "invalid_response" and response is not None:
            response = object_value(response, "sampling_response")
            problem = response_problem(response)
            metadata = object_value(response.get("_meta"), "sampling_response metadata")
            if (problem is None or validation_error != problem
                    or metadata.get("masc.lane_sampling") != refs):
                raise InvalidInput("Invalid response must retain its actual validation failure and evidence")
            return
        if response is not None or validation_error is not None:
            raise InvalidInput("Host sampling failures must retain only their actual terminal error")
        terminal_error(error, computation, refs)
