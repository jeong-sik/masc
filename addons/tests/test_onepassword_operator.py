"""Private operator lifecycle through the package boundary; fixture tokens only."""
import contextlib
from concurrent.futures import ThreadPoolExecutor
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit

PACKAGE = Path(__file__).resolve().parents[1] / "onepassword"
sys.path.insert(0, str(PACKAGE))
import server
import oauth
from oauth import Configuration, Connector, PrivateStore
from onepassword_store_fixture import MemoryRecords, active_raw


class OperatorTests(unittest.TestCase):
    def setUp(self):
        backend = patch.object(oauth, "ProtectedRecords", MemoryRecords)
        backend.start()
        self.addCleanup(backend.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.calls = []
        self.fail_exchange = False
        self.connector = Connector(Configuration("client", "SECRET_MARKER", "https://masc.example/addons/oauth/callback"),
                                   PrivateStore(self.root / "private", provision=True), transport=self.transport)
        self.worker = server.Worker(self.root / "config.json")
        self.loader = patch.object(server, "load_settings", return_value=server.Settings(self.connector, "fixture", None))
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

    def callback_with_query(self, begun, fields):
        arguments = self.callback_arguments(begun)
        returned = urlsplit(arguments["callback_url"])
        arguments["callback_url"] = urlunsplit(returned._replace(query=returned.query + "&" + urlencode(fields)))
        return arguments

    def test_optional_callback_metadata_completes_the_original_attempt_without_publication_or_replay(self):
        for metadata in [
            [("iss", "https://issuer.example/tenant")],
            [("base_url", "https://environment.example:8443/")],
            [("base_url", "https://environment.example"), ("iss", "https://issuer.example/tenant")],
        ]:
            with self.subTest(metadata=metadata):
                begun = self.call("connect")
                arguments = self.callback_with_query(begun, metadata)
                before = len(self.calls)
                completed = self.call("complete", arguments)
                self.assertEqual(self.connector.status()["phase"], "connected")
                self.assertEqual(self.connector.connection_identity(), begun["callback"]["arguments"]["connection_id"])
                self.assertEqual(len(self.calls), before + 1)
                self.assertEqual(set(self.calls[-1][1]), {"grant_type", "code", "redirect_uri", "code_verifier"})
                self.assertEqual(self.calls[-1][1]["code"], "CODE_MARKER")
                self.call("complete", arguments)
                self.assertEqual(len(self.calls), before + 1)
                public = json.dumps([completed, self.worker.status(),
                    self.worker.observe({"binding": {"sources": []}, "sources": []})])
                for secret in [begun["callback"]["state"], "CODE_MARKER", "INTEGRATION_MARKER",
                               "ACCESS_MARKER", "REFRESH_MARKER", *[value for _, value in metadata]]:
                    self.assertNotIn(secret, public)
                # Close the fixture's established connection before the next
                # metadata case; this callback performs no provider IO.
                self.connector.disconnect(lambda access, key: None)

    def test_optional_metadata_never_changes_the_actual_token_request_authority(self):
        begun = self.call("connect")
        captured = []
        timeouts = []

        class Opener:
            def open(_, request, *, timeout):
                captured.append(request)
                timeouts.append(timeout)
                return io.BytesIO(json.dumps({"access_token": "ACCESS_MARKER", "refresh_token": "REFRESH_MARKER",
                                              "token_type": "Bearer", "expires_in": 900}).encode())

        self.connector.transport = oauth.post
        with patch.object(oauth.request, "build_opener", return_value=Opener()) as build:
            self.call("complete", self.callback_with_query(begun, [
                ("iss", "https://issuer.example/tenant"), ("base_url", "https://metadata.example:8443")]))
        self.assertEqual(self.connector.status()["phase"], "connected")
        self.assertEqual(len(captured), 1)
        self.assertEqual(timeouts, [oauth.OAUTH_SOCKET_TIMEOUT_S])
        self.assertEqual(captured[0].full_url, oauth.API_ORIGIN + "/v1/oauth/token")
        self.assertEqual(captured[0].get_method(), "POST")
        self.assertTrue(captured[0].get_header("Authorization").startswith("Basic "))
        self.assertIs(build.call_args.args[0], oauth.NoRedirect)
        fields = parse_qs(captured[0].data.decode(), strict_parsing=True)
        self.assertEqual(set(fields), {"grant_type", "code", "redirect_uri", "code_verifier"})
        self.assertEqual(fields["redirect_uri"], [self.connector.configuration.redirect_uri])
        self.assertIsNone(build.call_args.args[0]().redirect_request(None, None, 302, "redirect", {},
                                                                   "https://metadata.example/token"))

    def test_malformed_optional_metadata_and_blank_or_unknown_fields_preserve_the_pending_attempt(self):
        invalid = [
            [("iss", "")], [("base_url", "")], [("unknown", "")], [("unknown", "VALUE_MARKER")],
            [("iss", "https://issuer.example"), ("iss", "")],
            [("base_url", "https://environment.example"), ("base_url", "https://other.example")],
            [("code", "")], [("state", "")],
        ]
        for key in ["iss", "base_url"]:
            invalid.extend([[(key, value)] for value in [
                "http://METADATA_MARKER.example", "https://user:METADATA_MARKER@example.com",
                "https://METADATA_MARKER.example:invalid", "https://METADATA_MARKER.example?secret=value",
                "https://METADATA_MARKER.example#secret", " https://METADATA_MARKER.example",
                "https://META\nDATA_MARKER.example", "https://META\x01DATA_MARKER.example",
            ]])
        invalid.append([("base_url", "https://METADATA_MARKER.example/not-an-origin")])
        begun = self.call("connect")
        identity = self.connector.authorization_identity()
        for metadata in invalid:
            with self.subTest(metadata=metadata):
                before = len(self.calls)
                output = io.StringIO()
                with contextlib.redirect_stderr(output):
                    response = self.call("complete", self.callback_with_query(begun, metadata))
                self.assertEqual(self.connector.authorization_identity(), identity)
                self.assertEqual(len(self.calls), before)
                self.assertEqual([action["id"] for action in response["actions"]], ["view"])
                self.assertEqual(output.getvalue(), "")
                for secret in [identity["state"], "CODE_MARKER", "INTEGRATION_MARKER", "METADATA_MARKER", "VALUE_MARKER"]:
                    self.assertNotIn(secret, json.dumps(response))

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

    def test_declined_callback_cancels_only_the_original_pending_attempt_without_exchange(self):
        begun = self.call("connect")
        arguments = self.callback_arguments(begun)
        arguments["callback_url"] = self.connector.configuration.redirect_uri + "?" + urlencode({
            "error": "access_denied", "state": begun["callback"]["state"],
            "iss": "https://issuer.example/tenant", "base_url": "https://environment.example"})
        response = self.call("complete", arguments)
        self.assertEqual(self.connector.status()["phase"], "disconnected")
        self.assertEqual([action["id"] for action in response["actions"]], ["connect"])
        self.assertEqual(self.calls, [])
        self.assertNotIn(begun["callback"]["state"], json.dumps(response))
        replacement = self.call("connect")
        self.call("complete", arguments)
        self.assertEqual(self.connector.authorization_identity(), replacement["callback"]["arguments"])
        self.assertEqual(self.calls, [])

    def test_decline_requires_exact_state_connection_and_closed_error_shape(self):
        begun = self.call("connect")
        identity = begun["callback"]["arguments"]
        query = [("state", identity["state"]), ("error", "access_denied")]
        invalid = [
            (query + [("error", "access_denied")], "", {}),
            (query + [("code", "CODE_MARKER")], "", {}),
            (query + [("unknown", "")], "", {}),
            (query, "integration_key=INTEGRATION_MARKER", {}),
            ([("state", identity["state"]), ("error", "ERROR_MARKER")], "", {}),
            ([("state", "STATE_MARKER"), ("error", "access_denied")], "", {}),
            (query, "", {"state": "STATE_MARKER"}),
            (query, "", {"connection_id": "other"}),
        ]
        for fields, fragment, changed in invalid:
            with self.subTest(fields=fields, fragment=fragment, changed=changed):
                callback = self.connector.configuration.redirect_uri + "?" + urlencode(fields)
                if fragment:
                    callback += "#" + fragment
                output = io.StringIO()
                with contextlib.redirect_stderr(output):
                    response = self.call("complete", {**identity, "callback_url": callback, **changed})
                self.assertEqual(self.connector.authorization_identity(), identity)
                self.assertEqual(self.calls, [])
                self.assertEqual(output.getvalue(), "")
                for secret in [identity["state"], "STATE_MARKER", "ERROR_MARKER", "CODE_MARKER", "INTEGRATION_MARKER"]:
                    self.assertNotIn(secret, json.dumps(response))

    def test_absent_key_is_not_consumed_or_borrowed_and_existing_connection_is_preserved(self):
        # Characterize the remaining recovery contract, not a completed
        # keyless reconnect: this store has no account-pinned retained key.
        begun = self.call("connect")
        original = self.callback_arguments(begun)
        missing = {**original, "callback_url": original["callback_url"].split("#", 1)[0]}
        rejected = self.call("complete", missing)
        self.assertEqual(self.connector.authorization_identity(), begun["callback"]["arguments"])
        self.assertEqual(self.calls, [])
        self.assertEqual([action["id"] for action in rejected["actions"]], ["view"])
        self.call("complete", original)
        retained = active_raw(self.connector.store).encode()
        self.call("connect")
        self.assertEqual(active_raw(self.connector.store).encode(), retained)
        self.assertTrue(self.connector.status()["connected"])
        self.assertEqual(len(self.calls), 1)

    def test_capture_receipt_survives_exchange_failure_and_same_return_does_not_exchange_again(self):
        begun = self.call("connect")
        arguments = self.callback_arguments(begun)
        self.fail_exchange = True
        first = self.call("complete", arguments)
        expected = {"kind": "captured", "connection_id": arguments["connection_id"]}
        self.assertEqual(first["callback_receipt"], expected)
        self.assertEqual(self.connector.status()["phase"], "reconnect_required")
        self.assertEqual(self.call("complete", arguments)["callback_receipt"], expected)
        self.assertEqual(len(self.calls), 1)
        public = json.dumps([self.worker.status(), self.worker.observe({"binding": {"sources": []}, "sources": []})])
        for private in ["callback_receipt", "INTEGRATION_MARKER", arguments["connection_id"], arguments["state"]]:
            self.assertNotIn(private, public)

    def test_return_before_capture_failure_can_retry_the_same_original_attempt(self):
        begun = self.call("connect")
        arguments = self.callback_arguments(begun)
        write = self.connector.store.write

        def fail_before_capture(root, record):
            if record["phase"] == "exchanging":
                raise OSError("PRIVATE_CAPTURE_FAILURE")
            return write(root, record)

        with patch.object(self.connector.store, "write", side_effect=fail_before_capture):
            rejected = self.call("complete", arguments)
        self.assertNotIn("callback_receipt", rejected)
        self.assertNotIn("PRIVATE_CAPTURE_FAILURE", json.dumps(rejected))
        self.assertEqual(self.calls, [])
        self.assertEqual(self.connector.authorization_identity(), begun["callback"]["arguments"])
        completed = self.call("complete", arguments)
        self.assertEqual(completed["callback_receipt"], {"kind": "captured", "connection_id": arguments["connection_id"]})
        self.assertEqual(len(self.calls), 1)

    def test_receipt_fsync_failure_is_unknown_even_when_the_record_is_visible(self):
        begun = self.call("connect")
        arguments = self.callback_arguments(begun)
        self.call("complete", arguments)
        with patch.object(oauth.os, "fsync", side_effect=OSError("PRIVATE_SYNC_FAILURE")):
            uncertain = self.call("view")
        self.assertNotIn("callback_receipt", uncertain)
        self.assertNotIn("PRIVATE_SYNC_FAILURE", json.dumps(uncertain))
        confirmed = self.call("view")
        self.assertEqual(confirmed["callback_receipt"]["connection_id"], arguments["connection_id"])
        self.assertEqual(len(self.calls), 1)

    def test_decline_receipt_survives_lost_response_and_reconstructed_connector(self):
        begun = self.call("connect")
        identity = begun["callback"]["arguments"]
        arguments = {**identity, "callback_url": self.connector.configuration.redirect_uri + "?" + urlencode({
            "state": identity["state"], "error": "access_denied"})}
        expected = {"kind": "declined", "connection_id": identity["connection_id"]}
        self.assertEqual(self.call("complete", arguments)["callback_receipt"], expected)
        # Discard the first response and reconstruct a Worker, then separately
        # reconstruct the Connector/Store against the retained protected fixture.
        worker = server.Worker(self.worker.configuration)
        self.assertEqual(worker.operator({"action": "complete", "arguments": arguments})["callback_receipt"], expected)
        restarted = Connector(self.connector.configuration,
                              PrivateStore(self.connector.store.directory, records=self.connector.store.records),
                              transport=self.transport)
        self.assertEqual(restarted.decline_authorization(expected_state=identity["state"],
                                                       expected_connection_id=identity["connection_id"]), expected)
        self.assertEqual(json.loads(active_raw(self.connector.store))["declined_callback"], {**expected, "state": identity["state"]})
        self.assertNotIn("callback_receipt", self.call("view"))
        self.assertEqual(self.calls, [])
        public = json.dumps([self.worker.status(), self.worker.observe({"binding": {"sources": []}, "sources": []})])
        for private in ["declined_callback", "callback_receipt", identity["state"], identity["connection_id"]]:
            self.assertNotIn(private, public)
        for path in self.connector.store.directory.iterdir():
            self.assertNotIn(identity["state"].encode(), path.read_bytes())

    def test_decline_replay_requires_exact_identity_and_valid_callback(self):
        begun = self.call("connect")
        identity = begun["callback"]["arguments"]
        callback = self.connector.configuration.redirect_uri + "?" + urlencode({
            "state": identity["state"], "error": "access_denied"})
        arguments = {**identity, "callback_url": callback}
        self.call("complete", arguments)
        before = active_raw(self.connector.store)
        for changed in [{"state": "other"}, {"connection_id": "other"},
                        {"callback_url": callback.replace("masc.example", "attacker.example")},
                        {"callback_url": callback.replace("access_denied", "other_error")},
                        {"callback_url": callback + "&error=access_denied"}]:
            with self.subTest(changed=changed):
                self.assertNotIn("callback_receipt", self.call("complete", {**arguments, **changed}))
                self.assertEqual(active_raw(self.connector.store), before)
        replacement = self.call("connect")
        self.assertNotIn("callback_receipt", self.call("complete", arguments))
        self.assertEqual(self.connector.authorization_identity(), replacement["callback"]["arguments"])
        self.assertEqual(self.calls, [])

    def test_decline_write_failure_preserves_pending_attempt_and_does_not_acknowledge(self):
        begun = self.call("connect")
        identity = begun["callback"]["arguments"]
        arguments = {**identity, "callback_url": self.connector.configuration.redirect_uri + "?" + urlencode({
            "state": identity["state"], "error": "access_denied"})}
        before = active_raw(self.connector.store)
        with patch.object(self.connector.store.records, "write", side_effect=oauth.ConnectionError("protected_store_unavailable")):
            self.assertNotIn("callback_receipt", self.call("complete", arguments))
        self.assertEqual(active_raw(self.connector.store), before)
        self.assertEqual(self.connector.authorization_identity(), identity)
        self.assertEqual(self.call("complete", arguments)["callback_receipt"], {
            "kind": "declined", "connection_id": identity["connection_id"]})
        self.assertEqual(self.calls, [])

    def test_decline_replay_confirms_uncertain_commit_before_acknowledging(self):
        begun = self.call("connect")
        identity = begun["callback"]["arguments"]
        arguments = {**identity, "callback_url": self.connector.configuration.redirect_uri + "?" + urlencode({
            "state": identity["state"], "error": "access_denied"})}
        fsync = os.fsync

        def fail_directory(fd):
            if os.fstat(fd).st_ino == self.connector.store.directory.stat().st_ino:
                raise OSError("PRIVATE_SYNC_FAILURE")
            return fsync(fd)

        with patch.object(oauth.os, "fsync", side_effect=fail_directory):
            for _ in range(2):
                uncertain = self.call("complete", arguments)
                self.assertNotIn("callback_receipt", uncertain)
                self.assertNotIn("PRIVATE_SYNC_FAILURE", json.dumps(uncertain))
        self.assertEqual(self.connector.status()["phase"], "disconnected")
        self.assertEqual(self.call("complete", arguments)["callback_receipt"], {
            "kind": "declined", "connection_id": identity["connection_id"]})
        self.assertEqual(self.calls, [])

    def test_concurrent_matching_declines_replay_one_protected_cancellation(self):
        begun = self.call("connect")
        identity = begun["callback"]["arguments"]
        expected = {"kind": "declined", "connection_id": identity["connection_id"]}
        another = Connector(self.connector.configuration,
                            PrivateStore(self.connector.store.directory, records=self.connector.store.records),
                            transport=self.transport)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda connector: connector.decline_authorization(
                expected_state=identity["state"], expected_connection_id=identity["connection_id"]),
                [self.connector, another]))
        self.assertEqual(results, [expected, expected])
        self.assertNotIn("callback_receipt", self.call("view"))
        self.assertEqual(self.calls, [])

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
        backend = patch.object(oauth, "ProtectedRecords", MemoryRecords)
        backend.start()
        self.addCleanup(backend.stop)
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
            server.load_settings(self.configuration)
        self.assertFalse(self.store.exists())

        view = self.worker.operator({"action": "view", "arguments": {}})
        self.assertEqual([action["id"] for action in view["actions"]], ["connect"])
        self.assertEqual(stat.S_IMODE(self.store.stat().st_mode), 0o700)
        self.assertFalse((self.store / "connection.json").exists())
        self.assertFalse((self.store / "connection.reference.json").exists())
        self.assertEqual(self.worker.status(), {"phase": "disconnected", "connected": False,
                                               "browser_login_available": False})
        begun = self.worker.operator({"action": "connect", "arguments": {}})
        self.assertEqual(parse_qs(urlsplit(begun["open_url"]).query)["state"],
                         [begun["callback"]["state"]])

    def test_status_and_operator_view_do_not_wait_behind_private_credential_io(self):
        settings = self.worker.settings(provision=True)
        # Exercise both the shared thread lock and a separately opened flock.
        for store in [settings.connector.store, server.load_settings(self.configuration).connector.store]:
            with store.locked(), ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(self.worker.status)
                self.assertEqual(future.result(timeout=2), {
                    "phase": "unavailable", "connected": False, "browser_login_available": False})
                view = pool.submit(self.worker.operator_view, settings.connector).result(timeout=2)
                self.assertIn("Pending login controls remain available", view["message"])

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
        actual_load = server.load_settings
        begin_finished, continue_view = threading.Event(), threading.Event()
        pending = {}

        def paused_load(path, *, provision=False):
            settings = actual_load(path, provision=provision)
            connector = settings.connector
            begin = connector.begin

            def paused_begin():
                pending.update(begin())
                begin_finished.set()
                if not continue_view.wait(5):
                    raise AssertionError("replacement operator did not release the view")
                return pending

            connector.begin = paused_begin
            return settings

        with patch.object(server, "load_settings", side_effect=paused_load), ThreadPoolExecutor(max_workers=1) as pool:
            response_future = pool.submit(self.worker.operator, {"action": "connect", "arguments": {}})
            try:
                self.assertTrue(begin_finished.wait(5), "initial begin did not finish")
                other = actual_load(self.configuration).connector
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
        self.assertEqual(actual_load(self.configuration).connector.authorization_identity(), replacement_identity)


if __name__ == "__main__":
    unittest.main()
