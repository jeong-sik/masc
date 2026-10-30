#!/usr/bin/env python3
"""One-request AWS SDK bridge. JSON input; JSON-lines output; no credentials on wire.

Boto3 owns AWS profile/SSO/role credential resolution, SigV4 and EventStream.
This is a transport, not an assertion that any model or Keeper is ready.
"""
from __future__ import annotations

import datetime
import json
import logging
import sys
from collections.abc import Callable
from typing import Any

PROTOCOL = "masc.bedrock-sdk.v1"
OPERATIONS = {"profiles", "models", "availability", "converse", "converse_stream"}


class BridgeError(Exception):
    def __init__(self, code: str):
        self.code = code


def request_from_json(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("protocol") != PROTOCOL:
        raise BridgeError("invalid_protocol")
    if set(value) - {"protocol", "operation", "profile", "region", "request"}:
        raise BridgeError("unknown_request_field")
    if not isinstance(value.get("operation"), str) or value["operation"] not in OPERATIONS:
        raise BridgeError("unsupported_operation")
    for key in ("profile", "region"):
        text = value.get(key)
        if text is not None and (not isinstance(text, str) or not text.strip() or text != text.strip()):
            raise BridgeError("invalid_" + key)
    payload = value.get("request", {})
    if not isinstance(payload, dict):
        raise BridgeError("invalid_request_body")
    if value["operation"] in {"profiles", "models"} and payload:
        raise BridgeError("unexpected_request_body")
    if value["operation"] == "availability" and (
        set(payload) != {"modelId"} or not isinstance(payload["modelId"], str) or not payload["modelId"]
    ):
        raise BridgeError("invalid_model_identity")
    return value


def public_response(response: dict[str, Any]) -> dict[str, Any]:
    # SDK transport metadata is not model data and can carry extra HTTP headers.
    return {key: value for key, value in response.items() if key != "ResponseMetadata"}


def run_request(request: dict[str, Any], *, session_factory: Callable[..., Any], emit: Callable[[dict], None]) -> None:
    request = request_from_json(request)
    session = session_factory(profile_name=request.get("profile"), region_name=request.get("region"))
    operation = request["operation"]
    if operation == "profiles":
        emit({"event": "response", "response": {
            "profiles": sorted(session.available_profiles),
            "regions": session.get_available_regions("bedrock-runtime"),
            "selected_region": session.region_name,
            "account_availability_verified": False,
        }})
        return
    service = "bedrock-runtime" if operation in {"converse", "converse_stream"} else "bedrock"
    client = session.client(service)
    try:
        payload = request.get("request", {})
        if operation == "models":
            foundation = public_response(client.list_foundation_models(byOutputModality="TEXT"))
            profiles: list[dict] = []
            seen: set[str] = set()
            args: dict[str, str] = {}
            while True:
                page = client.list_inference_profiles(**args)
                profiles.extend(page.get("inferenceProfileSummaries", []))
                token = page.get("nextToken")
                if not token:
                    break
                if not isinstance(token, str) or token in seen:
                    raise BridgeError("invalid_pagination")
                seen.add(token)
                args = {"nextToken": token}
            emit({"event": "response", "response": {
                "foundation_models": foundation.get("modelSummaries", []),
                "inference_profiles": profiles,
                "source": "aws_bedrock_api",
                "account_availability_verified": False,
            }})
        elif operation == "availability":
            response = client.get_foundation_model_availability(**payload)
            # Entitlement, authorization and region availability remain separate.
            emit({"event": "response", "response": {key: response.get(key) for key in (
                "modelId", "authorizationStatus", "entitlementAvailability", "regionAvailability")},
                "agreement_status": response.get("agreementAvailability", {}).get("status"),
                "response_tool_verified": False})
        elif operation == "converse":
            emit({"event": "response", "response": public_response(client.converse(**payload))})
        else:
            response = client.converse_stream(**payload)
            stream = response["stream"]
            stopped = False
            try:
                for event in stream:
                    if any(key in event for key in ("internalServerException", "modelStreamErrorException",
                            "validationException", "throttlingException", "serviceUnavailableException")):
                        raise BridgeError("aws_stream_failed")
                    emit({"event": "stream", "payload": event})
                    stop = event.get("messageStop", {}).get("stopReason")
                    if isinstance(stop, str) and stop:
                        stopped = True
                if not stopped:
                    raise BridgeError("stream_missing_message_stop")
                emit({"event": "stream_closed"})
            finally:
                stream.close()
    finally:
        client.close()


def json_default(value: Any) -> str:
    if isinstance(value, (datetime.datetime, datetime.date)):
        return value.isoformat()
    raise TypeError("unsupported SDK response type")


def emit(value: dict) -> None:
    print(json.dumps(value, ensure_ascii=False, default=json_default, separators=(",", ":")), flush=True)


def main() -> int:
    try:
        request = request_from_json(json.load(sys.stdin))
    except (ValueError, BridgeError) as error:
        emit({"event": "error", "code": error.code if isinstance(error, BridgeError) else "invalid_json"})
        return 2
    try:
        import boto3
        from botocore.exceptions import BotoCoreError, ClientError
    except ImportError:
        emit({"event": "error", "code": "aws_sdk_missing"})
        return 2
    logging.getLogger("botocore").setLevel(logging.CRITICAL)
    try:
        run_request(request, session_factory=boto3.Session, emit=emit)
    except BridgeError as error:
        emit({"event": "error", "code": error.code})
        return 2
    except (BotoCoreError, ClientError):
        # Exception text and AWS response bodies may contain request data. The
        # parent can distinguish unavailable SDK/auth/service without logging it.
        emit({"event": "error", "code": "aws_request_failed"})
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
