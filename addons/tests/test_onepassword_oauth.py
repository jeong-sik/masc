"""Connection lifecycle/security behavior, using no real 1Password account."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit
import base64


SOURCE = Path(__file__).resolve().parents[1] / "onepassword" / "oauth.py"
SPEC = importlib.util.spec_from_file_location("onepassword_oauth", SOURCE)
oauth = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = oauth
SPEC.loader.exec_module(oauth)


class ConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / "private"
        self.store = oauth.PrivateStore(self.directory)
        self.configuration = oauth.Configuration("client", "CLIENT_SECRET", "https://masc.example/callback")
        self.clock = 1000.0
        self.calls = []
        self.next_token = 0
        self.connector = oauth.Connector(self.configuration, self.store,
                                         transport=self.transport, now=lambda: self.clock)

    def transport(self, path, fields, configuration):
        self.calls.append((path, fields))
        self.next_token += 1
        return {"access_token": "ACCESS_" + str(self.next_token),
                "refresh_token": "REFRESH_" + str(self.next_token),
                "token_type": "Bearer", "expires_in": 900, "scope": oauth.SCOPES}

    def begin(self):
        operator_result = self.connector.begin()
        return parse_qs(urlsplit(operator_result["authorization_url"]).query)

    def connect(self):
        parameters = self.begin()
        return self.connector.complete(state=parameters["state"][0], code="AUTH_CODE",
                                       integration_key="INTEGRATION_KEY")

    def retained(self):
        with self.store.locked() as root:
            return self.store.read(root)

    def test_pkce_exchange_and_safe_projection(self):
        parameters = self.begin()
        record = self.retained()
        expected = base64.urlsafe_b64encode(hashlib.sha256(record["verifier"].encode()).digest()).rstrip(b"=").decode()
        self.assertEqual(parameters["code_challenge"], [expected])
        self.assertEqual(parameters["code_challenge_method"], ["S256"])
        self.assertEqual(parameters["scope"], [oauth.SCOPES])
        result = self.connector.complete(state=parameters["state"][0], code="AUTH_CODE",
                                         integration_key="INTEGRATION_KEY")
        self.assertEqual(result, {"phase": "connected", "connected": True})
        self.assertEqual(self.calls[0][1]["code_verifier"], record["verifier"])
        self.assertNotIn("client_secret", self.calls[0][1])
        self.assertNotIn("state", self.retained())
        self.assertNotIn("verifier", self.retained())
        for value in ["ACCESS_", "REFRESH_", "INTEGRATION_KEY", "AUTH_CODE", "CLIENT_SECRET"]:
            self.assertNotIn(value, json.dumps(result))
        self.assertNotIn("CLIENT_SECRET", repr(self.configuration))

    def test_csrf_rejection_does_not_exchange_or_consume_request(self):
        parameters = self.begin()
        with self.assertRaisesRegex(oauth.ConnectionError, "oauth_state_mismatch"):
            self.connector.complete(state="wrong", code="AUTH_CODE", integration_key="KEY")
        self.assertEqual(self.calls, [])
        self.assertEqual(self.retained()["state"], parameters["state"][0])

    def test_connection_cannot_borrow_an_old_accounts_key(self):
        self.connect()
        with self.assertRaisesRegex(oauth.ConnectionError, "disconnect_before_connecting"):
            self.connector.begin()
        self.connector.disconnect(lambda access, key: None)
        parameters = self.begin()
        with self.assertRaisesRegex(oauth.ConnectionError, "missing_integration_key"):
            self.connector.complete(state=parameters["state"][0], code="NEXT_CODE", integration_key="")
        self.assertEqual(len(self.calls), 1)

    def test_code_is_not_replayed_after_exchange_response_is_lost(self):
        parameters = self.begin()
        def lose(path, fields, configuration):
            raise oauth.ConnectionError("oauth_transport_or_response_failure")
        self.connector.transport = lose
        with self.assertRaises(oauth.ConnectionError):
            self.connector.complete(state=parameters["state"][0], code="AUTH_CODE", integration_key="KEY")
        restarted = oauth.Connector(self.configuration, oauth.PrivateStore(self.directory), transport=self.transport)
        self.assertEqual(restarted.status()["phase"], "reconnect_required")
        with self.assertRaises(oauth.ConnectionError):
            restarted.complete(state=parameters["state"][0], code="AUTH_CODE", integration_key="KEY")
        self.assertEqual(self.calls, [])

    def test_concurrent_refreshes_rotate_once_and_keep_key(self):
        self.connect()
        self.clock += 901
        second = oauth.Connector(self.configuration, oauth.PrivateStore(self.directory),
                                  transport=self.transport, now=lambda: self.clock)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(connector.credentials, lambda access, key: (access, key))
                       for connector in [self.connector, second]]
            results = [future.result() for future in futures]
        self.assertEqual(results, [("ACCESS_2", "INTEGRATION_KEY")] * 2)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.calls[1][1]["refresh_token"], "REFRESH_1")
        self.assertEqual(self.retained()["refresh_token"], "REFRESH_2")

    def test_lost_rotating_refresh_response_fences_reuse_across_restart(self):
        self.connect()
        self.clock += 901
        def lose(path, fields, configuration):
            self.calls.append((path, fields))
            raise oauth.ConnectionError("oauth_transport_or_response_failure")
        self.connector.transport = lose
        with self.assertRaises(oauth.ConnectionError):
            self.connector.credentials(lambda access, key: self.fail("must not use old token"))
        restarted = oauth.Connector(self.configuration, oauth.PrivateStore(self.directory),
                                     transport=self.transport, now=lambda: self.clock)
        with self.assertRaisesRegex(oauth.ConnectionError, "connection_not_ready"):
            restarted.credentials(lambda access, key: self.fail("must not replay refresh"))
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(restarted.status()["phase"], "reconnect_required")

    def test_disconnect_waits_for_private_use_and_revokes_before_erasing(self):
        self.connect()
        entered, release = threading.Event(), threading.Event()
        revocations = []
        def use(access, key):
            entered.set()
            self.assertTrue(release.wait(5))
            return "safe browser receipt"
        with ThreadPoolExecutor(max_workers=2) as pool:
            in_use = pool.submit(self.connector.credentials, use)
            self.assertTrue(entered.wait(5))
            stopped = pool.submit(self.connector.disconnect, lambda access, key: revocations.append((access, key)))
            self.assertFalse(stopped.done())
            release.set()
            self.assertEqual(in_use.result(), "safe browser receipt")
            self.assertEqual(stopped.result(), {"phase": "disconnected", "connected": False})
        self.assertEqual(revocations, [("ACCESS_1", "INTEGRATION_KEY")])
        self.assertEqual(self.retained(), {"phase": "disconnected"})

    def test_failed_revocation_keeps_private_recovery_authority_but_blocks_use(self):
        self.connect()
        def failed(access, key):
            raise oauth.ConnectionError("revocation_unconfirmed")
        with self.assertRaises(oauth.ConnectionError):
            self.connector.disconnect(failed)
        self.assertEqual(self.connector.status()["phase"], "reconnect_required")
        self.assertEqual(self.retained()["refresh_token"], "REFRESH_1")
        with self.assertRaises(oauth.ConnectionError):
            self.connector.credentials(lambda access, key: None)

    def test_invalid_provider_tokens_do_not_establish_connection(self):
        for invalid in [
            {"access_token": "a", "refresh_token": "r", "token_type": "Bearer", "expires_in": float("nan")},
            {"access_token": "a", "refresh_token": "r", "token_type": "Bearer", "expires_in": True},
            {"access_token": "a", "token_type": "Bearer", "expires_in": 900},
            {"access_token": "a", "refresh_token": "r", "token_type": "Other", "expires_in": 900},
        ]:
            with self.subTest(invalid=invalid):
                other_path = Path(self.temporary.name) / ("case-" + str(len(os.listdir(self.temporary.name))))
                connector = oauth.Connector(self.configuration, oauth.PrivateStore(other_path),
                                             transport=lambda *args: invalid)
                params = parse_qs(urlsplit(connector.begin()["authorization_url"]).query)
                with self.assertRaises(oauth.ConnectionError):
                    connector.complete(state=params["state"][0], code="code", integration_key="key")
                self.assertFalse(connector.status()["connected"])

    def test_redirect_registration_is_https_without_local_authority_or_fragments(self):
        for uri in ["http://masc.example/callback", "https://localhost/callback", "custom://callback",
                    "https://masc.example/callback#secret", "https://user@masc.example/callback",
                    "https://masc.example:invalid/callback"]:
            with self.subTest(uri=uri), self.assertRaises(oauth.ConnectionError):
                oauth.Configuration("client", "secret", uri)

    def test_private_file_permissions_and_symlink_rejection(self):
        self.connect()
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
        target = self.directory / "connection.json"
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        outside = Path(self.temporary.name) / "outside.json"
        target.rename(outside)
        target.symlink_to(outside)
        with self.assertRaises(OSError):
            self.connector.status()
        self.assertIn("INTEGRATION_KEY", outside.read_text())

    def test_hardlinked_record_and_replaced_directory_are_rejected(self):
        self.connect()
        os.link(self.directory / "connection.json", Path(self.temporary.name) / "other-link")
        with self.assertRaisesRegex(oauth.ConnectionError, "unsafe_secret_store"):
            self.connector.status()
        self.directory.rename(Path(self.temporary.name) / "old")
        self.directory.mkdir(mode=0o700)
        with self.assertRaisesRegex(oauth.ConnectionError, "secret_store_replaced"):
            self.connector.status()


if __name__ == "__main__":
    unittest.main()
