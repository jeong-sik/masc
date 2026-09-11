#!/usr/bin/env python3
"""Offline tests: the SDK boundary is a fixture, no AWS credentials or calls."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bedrock_sdk", ROOT / "scripts/bedrock-sdk.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class Stream:
    def __init__(self, events):
        self.events, self.closed = events, False
    def __iter__(self):
        return iter(self.events)
    def close(self):
        self.closed = True


class Client:
    def __init__(self):
        self.calls, self.closed = [], False
        self.stream = Stream([{"contentBlockDelta": {"delta": {"text": "hello"}}},
                              {"messageStop": {"stopReason": "end_turn"}}])
    def close(self):
        self.closed = True
    def converse(self, **request):
        self.calls.append(("converse", request))
        return {"output": {"message": {"role": "assistant", "content": [
            {"toolUse": {"toolUseId": "id", "name": "inspect", "input": {}}}]}},
            "stopReason": "tool_use", "ResponseMetadata": {"hidden": "transport-only"}}
    def converse_stream(self, **request):
        self.calls.append(("converse_stream", request))
        return {"stream": self.stream}
    def list_foundation_models(self, **request):
        self.calls.append(("foundation", request))
        return {"modelSummaries": [{"modelId": "exact-current-model"}]}
    def list_inference_profiles(self, **request):
        self.calls.append(("profiles", request))
        if not request:
            return {"inferenceProfileSummaries": [{"inferenceProfileId": "first"}], "nextToken": "next"}
        return {"inferenceProfileSummaries": [{"inferenceProfileId": "second"}]}
    def get_foundation_model_availability(self, **request):
        return {"modelId": request["modelId"], "authorizationStatus": "AUTHORIZED",
                "entitlementAvailability": "NOT_AVAILABLE", "regionAvailability": "AVAILABLE",
                "agreementAvailability": {"status": "PENDING", "errorMessage": "do-not-output"}}


class Session:
    available_profiles = ["work", "personal"]
    region_name = "us-east-1"
    def __init__(self, client):
        self.instance, self.services = client, []
    def client(self, service):
        self.services.append(service)
        return self.instance
    def get_available_regions(self, service):
        assert service == "bedrock-runtime"
        return ["us-east-1", "us-west-2"]


class BedrockBridgeTests(unittest.TestCase):
    def run_bridge(self, operation, payload=None, client=None):
        client = client or Client()
        session, frames, selections = Session(client), [], []
        def factory(**selection):
            selections.append(selection)
            return session
        bridge.run_request({"protocol": bridge.PROTOCOL, "operation": operation,
            "profile": "work", "region": "us-west-2", "request": payload or {}},
            session_factory=factory, emit=frames.append)
        self.assertEqual(selections, [{"profile_name": "work", "region_name": "us-west-2"}])
        return client, session, frames

    def test_converse_keeps_native_tool_wire_and_profile(self):
        payload = {"modelId": "current-model", "messages": [{"role": "user", "content": [{"text": "hello"}]}],
                   "toolConfig": {"tools": [{"toolSpec": {"name": "inspect", "inputSchema": {"json": {"type": "object"}}}}]}}
        client, session, frames = self.run_bridge("converse", payload)
        self.assertEqual(client.calls, [("converse", payload)])
        self.assertEqual(session.services, ["bedrock-runtime"])
        self.assertEqual(frames[0]["response"]["stopReason"], "tool_use")
        self.assertNotIn("ResponseMetadata", frames[0]["response"])
        self.assertTrue(client.closed)

    def test_stream_is_incremental_and_closed(self):
        client, _, frames = self.run_bridge("converse_stream", {"modelId": "current-model", "messages": []})
        self.assertEqual([f["event"] for f in frames], ["stream", "stream", "stream_closed"])
        self.assertTrue(client.stream.closed and client.closed)

    def test_missing_model_stop_is_not_success(self):
        client = Client()
        client.stream = Stream([{"contentBlockDelta": {"delta": {"text": "partial"}}}])
        with self.assertRaises(bridge.BridgeError) as raised:
            self.run_bridge("converse_stream", client=client)
        self.assertEqual(raised.exception.code, "stream_missing_message_stop")
        self.assertTrue(client.stream.closed and client.closed)

    def test_models_follow_actual_profile_pages_without_entitlement_claim(self):
        client, session, frames = self.run_bridge("models")
        result = frames[0]["response"]
        self.assertEqual(session.services, ["bedrock"])
        self.assertEqual(result["foundation_models"][0]["modelId"], "exact-current-model")
        self.assertEqual([p["inferenceProfileId"] for p in result["inference_profiles"]], ["first", "second"])
        self.assertFalse(result["account_availability_verified"])

    def test_availability_does_not_promote_authorization_to_entitlement(self):
        _, _, frames = self.run_bridge("availability", {"modelId": "model"})
        self.assertEqual(frames[0]["response"]["authorizationStatus"], "AUTHORIZED")
        self.assertEqual(frames[0]["response"]["entitlementAvailability"], "NOT_AVAILABLE")
        self.assertFalse(frames[0]["response_tool_verified"])
        self.assertNotIn("do-not-output", repr(frames))

    def test_stream_error_message_is_not_emitted(self):
        client = Client()
        client.stream = Stream([{"throttlingException": {"message": "do-not-log-request-data"}}])
        frames = []
        with self.assertRaises(bridge.BridgeError) as raised:
            bridge.run_request({"protocol": bridge.PROTOCOL, "operation": "converse_stream"},
                session_factory=lambda **_: Session(client), emit=frames.append)
        self.assertEqual(raised.exception.code, "aws_stream_failed")
        self.assertEqual(frames, [])
        self.assertTrue(client.stream.closed and client.closed)

    def test_credentials_cannot_enter_bridge_request(self):
        with self.assertRaises(bridge.BridgeError):
            bridge.request_from_json({"protocol": bridge.PROTOCOL, "operation": "models", "aws_secret_access_key": "secret"})

    def test_profile_catalog_does_not_create_cloud_client(self):
        _, session, frames = self.run_bridge("profiles")
        self.assertEqual(session.services, [])
        self.assertEqual(frames[0]["response"]["profiles"], ["personal", "work"])


if __name__ == "__main__":
    unittest.main()
