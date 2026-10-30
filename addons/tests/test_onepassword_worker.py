"""Actual native-style MCP subprocess checks; no installed Keeper claim."""
import json
import os
from pathlib import Path
import sys
import tempfile
import tomllib
import unittest

from stdio_fixture import run_stdio

PACKAGE = Path(__file__).resolve().parents[1] / "onepassword"


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = self.root / "configuration.json"

    def call(self, requests):
        result = run_stdio([sys.executable, str(PACKAGE / "server.py"), "--config", str(self.config)],
                           input="".join(json.dumps(value) + "\n" for value in requests),
                           text=True, capture_output=True, check=True, timeout=10, cwd=self.root)
        self.assertEqual(result.stderr, "")
        return [json.loads(line) for line in result.stdout.splitlines()]

    def rpc(self, tool, arguments, identity=1):
        return {"jsonrpc": "2.0", "id": identity, "method": "tools/call",
                "params": {"name": tool, "arguments": arguments}}

    def private_file(self, name, value):
        path = self.root / name
        path.write_text(value)
        path.chmod(0o600)
        return path

    def test_manifest_discovery_and_host_admitted_agent_call(self):
        manifest = tomllib.loads((PACKAGE / "lane.toml").read_text())
        self.assertEqual(manifest["runtime"], "host_process")
        self.assertNotIn("service", manifest)
        responses = self.call([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            self.rpc("lane_call", {"tool": "onepassword_status", "arguments": {},
                                   "caller": {"kind": "keeper", "name": "fixture-agent"}}, 3),
        ])
        tools = {tool["name"]: tool for tool in responses[1]["result"]["tools"]}
        self.assertTrue(set(manifest["world"]["tools"]["export"]) <= set(tools))
        status = responses[2]["result"]["structuredContent"]
        self.assertEqual(status, {"phase": "not_configured", "connected": False,
                                  "browser_login_available": False})
        self.assertEqual(set(status), set(tools["onepassword_status"]["outputSchema"]["required"]))
        self.assertTrue((PACKAGE / "skills" / "onepassword" / "SKILL.md").is_file())

    def test_private_companion_negotiation_grants_only_login_start(self):
        responses = self.call([self.rpc("lane_companion", {"version": 3}),
                               self.rpc("lane_companion", {"token": "MUST_NOT_LEAK"}, 2),
                               self.rpc("lane_call", {"tool": "lane_companion", "arguments": {},
                                                       "caller": {"kind": "operator"}}, 3)])
        self.assertEqual(responses[0]["result"], {"content": [], "structuredContent": {"version": 3, "tools": ["onepassword_login"]},
                                                "isError": False})
        self.assertTrue(responses[1]["result"]["isError"])
        self.assertTrue(responses[2]["result"]["isError"])
        self.assertNotIn("MUST_NOT_LEAK", json.dumps(responses))

    def test_deferred_bind_requires_exact_host_protocol_version(self):
        responses = self.call([self.rpc("lane_companion", arguments, index) for index, arguments in
                               enumerate([{}, {"version": 1}, {"version": 2}, {"version": 3.0}], 1)])
        self.assertTrue(all(response["result"]["isError"] for response in responses))

    def test_status_requires_host_context_and_cannot_select_oauth_controls(self):
        requests = [self.rpc("onepassword_status", {}, 1)]
        for identity, (tool, caller, arguments) in enumerate([
            ("onepassword_status", {"kind": "anonymous"}, {}),
            ("onepassword_status", {"kind": "keeper", "name": " keeper"}, {}),
            ("connect", {"kind": "operator"}, {}),
            ("complete", {"kind": "operator"}, {}),
            ("credentials", {"kind": "keeper", "name": "fixture"}, {}),
            ("onepassword_status", {"kind": "operator"}, {"token": "MUST_NOT_LEAK"}),
        ], start=2):
            requests.append(self.rpc("lane_call", {"tool": tool, "caller": caller,
                                                   "arguments": arguments}, identity))
        responses = self.call(requests)
        self.assertTrue(all(response["result"]["isError"] for response in responses))
        self.assertNotIn("MUST_NOT_LEAK", json.dumps(responses))

    def test_observation_retains_only_safe_connection_fields(self):
        result = self.call([self.rpc("lane_observe", {"binding": {"sources": []}, "sources": []})])[0]["result"]
        self.assertFalse(result["isError"])
        fields = result["structuredContent"]["rows"][0]["fields"]
        self.assertEqual(fields, {"phase": "not_configured", "connected": False,
                                  "browser_login_available": False})
        self.assertEqual(result["structuredContent"]["coverage"], [])

    def test_configuration_errors_never_echo_secrets_or_paths(self):
        for configuration in ["MUST_NOT_LEAK", json.dumps({"access_token": "MUST_NOT_LEAK"}),
                              json.dumps(["MUST_NOT_LEAK"])]:
            self.private_file(self.config.name, configuration)
            responses = self.call([self.rpc("lane_call", {"tool": "onepassword_status", "arguments": {},
                                                           "caller": {"kind": "operator"}})])
            wire = json.dumps(responses)
            self.assertNotIn("MUST_NOT_LEAK", wire)
            self.assertNotIn(str(self.root), wire)
            self.assertEqual(responses[0]["result"]["structuredContent"]["phase"], "unavailable")

    def test_status_does_not_create_a_missing_secret_store(self):
        secret = self.private_file("secret", "CLIENT_SECRET")
        missing_store = self.root / "missing-store"
        self.private_file(self.config.name, json.dumps({"client_id": "client", "client_secret_file": str(secret),
                                                       "redirect_uri": "https://masc.example/callback",
                                                       "store_directory": str(missing_store)}))
        response = self.call([self.rpc("lane_call", {"tool": "onepassword_status", "arguments": {},
                                                     "caller": {"kind": "operator"}})])[0]
        self.assertEqual(response["result"]["structuredContent"]["phase"], "unavailable")
        self.assertFalse(missing_store.exists())

    def test_public_configuration_permissions_are_refused(self):
        self.private_file(self.config.name, "{}")
        self.config.chmod(0o644)
        response = self.call([self.rpc("lane_call", {"tool": "onepassword_status", "arguments": {},
                                                     "caller": {"kind": "operator"}})])[0]
        self.assertEqual(response["result"]["structuredContent"]["phase"], "unavailable")


if __name__ == "__main__":
    unittest.main()
