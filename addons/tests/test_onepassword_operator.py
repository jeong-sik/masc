"""Private operator lifecycle through the package boundary; fixture tokens only."""
import contextlib
from concurrent.futures import ThreadPoolExecutor
import io
import json
from pathlib import Path
import stat
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlencode, urlsplit

PACKAGE = Path(__file__).resolve().parents[1] / "onepassword"
sys.path.insert(0, str(PACKAGE))
import server
from oauth import Configuration, Connector, PrivateStore


class OperatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.calls = []
        self.fail_exchange = False
        self.connector = Connector(Configuration("client", "SECRET_MARKER", "https://masc.example/addons/oauth/callback"),
                                   PrivateStore(self.root / "private", provision=True), transport=self.transport)
        self.worker = server.Worker(self.root / "config.json")
        self.loader = patch.object(server, "load_connector", return_value=self.connector)
        self.loader.start()
        self.addCleanup(self.loader.stop)

    def transport(self, path, fields, configuration):
        self.calls.append((path, fields))
        if self.fail_exchange:
            raise ValueError("PROVIDER_SECRET_MARKER")
        return {"access_token": "ACCESS_MARKER", "refresh_token": "REFRESH_MARKER",
                "token_type": "Bearer", "expires_in": 900}

    def call(self, action, arguments=None):
        return self.worker.operator({"action": action, "arguments": arguments or {}})

    def callback_arguments(self, begun):
        callback = begun["callback"]
        url = (self.connector.configuration.redirect_uri + "?" + urlencode({"state": callback["state"], "code": "CODE_MARKER"})
               + "#" + urlencode({"integration_key": "INTEGRATION_MARKER"}))
        return {**callback["arguments"], callback["field"]: url}

    def test_connect_callback_and_public_status_keep_private_material_separate(self):
        view = self.call("view")
        self.assertEqual([action["id"] for action in view["actions"]], ["connect"])
        begun = self.call("connect")
        self.assertEqual(urlsplit(begun["open_url"]).netloc, "my.1password.com")
        state = parse_qs(urlsplit(begun["open_url"]).query)["state"][0]
        self.assertEqual(state, begun["callback"]["state"])
        completed = self.call("complete", self.callback_arguments(begun))
        self.assertEqual(completed["actions"], [])
        self.assertEqual(self.worker.status(), {"phase": "connected", "connected": True, "browser_login_available": False})
        self.assertEqual(len(self.calls), 1)
        public = json.dumps(self.worker.observe({"binding": {"sources": []}, "sources": []}))
        for secret in [state, "ACCESS_MARKER", "REFRESH_MARKER", "SECRET_MARKER", "INTEGRATION_MARKER", "CODE_MARKER"]:
            self.assertNotIn(secret, public)
            self.assertNotIn(secret, json.dumps(completed))

    def test_callback_destination_state_and_duplicate_fields_are_refused_before_exchange(self):
        begun = self.call("connect")
        original = self.callback_arguments(begun)
        for change in [
            {"callback_url": original["callback_url"].replace("masc.example", "attacker.example")},
            {"state": "other"}, {"connection_id": "other"},
            {"callback_url": original["callback_url"].replace("#", "&code=other#")},
            {"callback_url": original["callback_url"] + "&integration_key=other"},
        ]:
            response = self.call("complete", {**original, **change})
            self.assertNotIn("CODE_MARKER", json.dumps(response))
            self.assertEqual(self.calls, [])
            self.assertEqual(self.connector.status()["phase"], "authorizing")

    def test_late_cancel_cannot_cancel_replacement_or_completed_connection(self):
        first = self.call("connect")
        old = first["callback"]["arguments"]
        self.call("cancel", old)
        second = self.call("connect")
        self.call("cancel", old)
        self.assertEqual(self.connector.authorization_identity(), second["callback"]["arguments"])
        self.call("complete", self.callback_arguments(second))
        self.call("cancel", second["callback"]["arguments"])
        self.assertTrue(self.connector.status()["connected"])
        self.assertEqual(len(self.calls), 1)

    def test_connect_does_not_open_a_cancelled_attempt(self):
        begin = self.connector.begin

        def begin_then_cancel():
            pending = begin()
            identity = self.connector.authorization_identity()
            self.connector.cancel_authorization(expected_state=identity["state"],
                                               expected_connection_id=identity["connection_id"])
            return pending

        with patch.object(self.connector, "begin", side_effect=begin_then_cancel):
            response = self.call("connect")
        self.assertNotIn("open_url", response)
        self.assertNotIn("callback", response)
        self.assertEqual([action["id"] for action in response["actions"]], ["view"])
        self.assertEqual(self.connector.status()["phase"], "disconnected")
        self.assertEqual(self.calls, [])

    def test_interrupted_exchange_is_not_replayed_and_emits_no_provider_text(self):
        begun = self.call("connect")
        self.fail_exchange = True
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            for _ in range(2):
                result = self.call("complete", self.callback_arguments(begun))
                self.assertNotIn("PROVIDER_SECRET_MARKER", json.dumps(result))
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.connector.status()["phase"], "reconnect_required")

    def test_public_host_context_cannot_select_private_operator_actions(self):
        for tool in ["lane_operator", "connect", "complete", "cancel"]:
            with self.assertRaises(server.InvalidInput):
                self.worker.admitted({"tool": tool, "arguments": {}, "caller": {"kind": "operator"}})
        self.assertEqual(self.calls, [])

    def test_private_mcp_reply_has_no_duplicated_text_and_safe_error(self):
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
                "name": "lane_operator", "arguments": {"action": "connect", "arguments": {}}}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
                "name": "lane_operator", "arguments": {"action": "complete", "arguments": {"token": "INPUT_MARKER"}}}},
        ]
        stdin = type("Input", (), {"buffer": io.BytesIO("\n".join(map(json.dumps, requests)).encode())})()
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(server.sys, "stdin", stdin), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            server.serve(self.worker)
        replies = [json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual(replies[0]["result"]["content"], [])
        self.assertTrue(replies[1]["result"]["isError"])
        self.assertNotIn("INPUT_MARKER", stdout.getvalue())
        self.assertEqual(stderr.getvalue(), "")


class InstallationTests(unittest.TestCase):
    """Exercise the actual private-file loader, without a precreated store."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.store = self.root / "private"
        self.secret = self.private_file("client-secret", "CLIENT_SECRET_MARKER\n")
        self.configuration = self.private_file("configuration.json", json.dumps({
            "client_id": "client", "client_secret_file": str(self.secret),
            "redirect_uri": "https://masc.example/addons/oauth/callback",
            "store_directory": str(self.store)}))
        self.worker = server.Worker(self.configuration)

    def private_file(self, name, text):
        path = self.root / name
        path.write_text(text)
        path.chmod(0o600)
        return path

    def test_first_operator_view_provisions_private_store_and_offers_connect(self):
        self.assertEqual(self.worker.status(), {"phase": "unavailable", "connected": False,
                                               "browser_login_available": False})
        self.assertFalse(self.store.exists())
        with self.assertRaises(FileNotFoundError):
            server.load_connector(self.configuration)
        self.assertFalse(self.store.exists())

        view = self.worker.operator({"action": "view", "arguments": {}})
        self.assertEqual([action["id"] for action in view["actions"]], ["connect"])
        self.assertEqual(stat.S_IMODE(self.store.stat().st_mode), 0o700)
        self.assertFalse((self.store / "connection.json").exists())
        self.assertEqual(self.worker.status(), {"phase": "disconnected", "connected": False,
                                               "browser_login_available": False})
        begun = self.worker.operator({"action": "connect", "arguments": {}})
        self.assertEqual(parse_qs(urlsplit(begun["open_url"]).query)["state"],
                         [begun["callback"]["state"]])

    def test_invalid_private_file_permissions_never_provision_store(self):
        for path in [self.configuration, self.secret]:
            with self.subTest(path=path.name):
                path.chmod(0o644)
                response = self.worker.operator({"action": "view", "arguments": {}})
                self.assertEqual([action["id"] for action in response["actions"]], ["view"])
                self.assertNotIn("CLIENT_SECRET_MARKER", json.dumps(response))
                self.assertFalse(self.store.exists())
                path.chmod(0o600)

    def test_connect_refuses_callback_from_concurrent_replacement_attempt(self):
        actual_load = server.load_connector
        begin_finished, continue_view = threading.Event(), threading.Event()
        pending = {}

        def paused_load(path, *, provision=False):
            connector = actual_load(path, provision=provision)
            begin = connector.begin

            def paused_begin():
                pending.update(begin())
                begin_finished.set()
                if not continue_view.wait(5):
                    raise AssertionError("replacement operator did not release the view")
                return pending

            connector.begin = paused_begin
            return connector

        with patch.object(server, "load_connector", side_effect=paused_load), ThreadPoolExecutor(max_workers=1) as pool:
            response_future = pool.submit(self.worker.operator, {"action": "connect", "arguments": {}})
            try:
                self.assertTrue(begin_finished.wait(5), "initial begin did not finish")
                other = actual_load(self.configuration)
                original = other.authorization_identity()
                self.assertEqual(original["connection_id"], pending["connection_id"])
                other.cancel_authorization(expected_state=original["state"],
                                           expected_connection_id=original["connection_id"])
                replacement = other.begin()
                replacement_identity = other.authorization_identity()
                self.assertNotEqual(replacement["connection_id"], pending["connection_id"])
            finally:
                continue_view.set()
            response = response_future.result(timeout=5)

        self.assertNotIn("open_url", response)
        self.assertNotIn("callback", response)
        self.assertEqual([action["id"] for action in response["actions"]], ["view"])
        for secret in [original["state"], replacement_identity["state"], pending["authorization_url"],
                       replacement["authorization_url"], "CLIENT_SECRET_MARKER"]:
            self.assertNotIn(secret, json.dumps(response))
        self.assertEqual(actual_load(self.configuration).authorization_identity(), replacement_identity)


if __name__ == "__main__":
    unittest.main()
