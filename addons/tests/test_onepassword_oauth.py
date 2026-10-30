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
from unittest.mock import patch
from onepassword_store_fixture import MemoryRecords, active_raw, replace_active_raw
from urllib.parse import parse_qs, urlsplit
import base64


SOURCE = Path(__file__).resolve().parents[1] / "onepassword" / "oauth.py"
SPEC = importlib.util.spec_from_file_location("onepassword_oauth", SOURCE)
oauth = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = oauth
SPEC.loader.exec_module(oauth)


class ConnectionTests(unittest.TestCase):
    def setUp(self):
        backend = patch.object(oauth, "ProtectedRecords", MemoryRecords)
        backend.start()
        self.addCleanup(backend.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / "private"
        self.store = oauth.PrivateStore(self.directory, provision=True)
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

    def test_cancel_authorization_erases_only_its_exact_pending_attempt(self):
        authorization = self.connector.begin()
        state = parse_qs(urlsplit(authorization["authorization_url"]).query)["state"][0]
        self.assertEqual(authorization["connection_id"], self.retained()["connection_id"])
        self.assertEqual(self.connector.cancel_authorization(expected_state=state,
                                                             expected_connection_id=authorization["connection_id"]),
                         {"phase": "disconnected", "connected": False})
        self.assertEqual(self.retained(), {"phase": "disconnected",
                                           "configuration_id": self.configuration.identity})
        self.assertEqual(self.calls, [])
        self.assertNotIn("connection_id", self.connector.status())
        with self.assertRaisesRegex(oauth.ConnectionError, "authorization_cancel_refused"):
            self.connector.cancel_authorization(expected_state=state,
                                                 expected_connection_id=authorization["connection_id"])
        with self.assertRaisesRegex(oauth.ConnectionError, "oauth_state_mismatch"):
            self.connector.complete(state=state, code="code", integration_key="key")
        self.assertEqual(self.calls, [])

    def test_authorization_cancel_requires_both_identities_without_consuming_the_attempt(self):
        authorization = self.connector.begin()
        original = self.retained()
        for state, connection_id in [
            ("wrong", authorization["connection_id"]),
            (original["state"], "wrong"),
            (None, authorization["connection_id"]),
            (original["state"], None),
            ("다른 요청", authorization["connection_id"]),
            ("\ud800", authorization["connection_id"]),
        ]:
            with self.subTest(state=state, connection_id=connection_id):
                with self.assertRaisesRegex(oauth.ConnectionError, "authorization_cancel_refused"):
                    self.connector.cancel_authorization(expected_state=state,
                                                         expected_connection_id=connection_id)
                self.assertEqual(self.retained(), original)
        self.assertEqual(self.calls, [])

    def test_stale_cancel_rereads_a_new_attempt_from_the_shared_store(self):
        first = self.connector.begin()
        first_state = self.retained()["state"]
        second_connector = oauth.Connector(self.configuration, oauth.PrivateStore(self.directory),
                                           transport=self.transport, now=lambda: self.clock)
        self.assertEqual(second_connector.status()["phase"], "authorizing")
        self.connector.cancel_authorization(expected_state=first_state,
                                             expected_connection_id=first["connection_id"])
        second = second_connector.begin()
        second_record = self.retained()
        with self.assertRaisesRegex(oauth.ConnectionError, "authorization_cancel_refused"):
            self.connector.cancel_authorization(expected_state=first_state,
                                                 expected_connection_id=first["connection_id"])
        self.assertEqual(self.retained(), second_record)
        self.assertNotEqual(first["connection_id"], second["connection_id"])
        self.assertEqual(self.calls, [])

    def test_late_cancel_waits_for_callback_and_cannot_revoke_its_completed_connection(self):
        authorization = self.connector.begin()
        state = self.retained()["state"]
        entered, release, cancel_started = threading.Event(), threading.Event(), threading.Event()
        second_connector = oauth.Connector(self.configuration, oauth.PrivateStore(self.directory),
                                           transport=self.transport, now=lambda: self.clock)

        def exchange(path, fields, configuration):
            entered.set()
            self.assertTrue(release.wait(5))
            return self.transport(path, fields, configuration)

        def cancel():
            cancel_started.set()
            return second_connector.cancel_authorization(expected_state=state,
                                                          expected_connection_id=authorization["connection_id"])

        self.connector.transport = exchange
        with ThreadPoolExecutor(max_workers=2) as pool:
            completed = pool.submit(self.connector.complete, state=state, code="code", integration_key="key")
            self.assertTrue(entered.wait(5))
            cancelled = pool.submit(cancel)
            self.assertTrue(cancel_started.wait(5))
            self.assertFalse(cancelled.done())
            release.set()
            self.assertEqual(completed.result(), {"phase": "connected", "connected": True})
            with self.assertRaisesRegex(oauth.ConnectionError, "authorization_cancel_refused"):
                cancelled.result()
        self.assertEqual(self.retained()["phase"], "connected")
        self.assertEqual(self.retained()["connection_id"], authorization["connection_id"])
        self.assertEqual(len(self.calls), 1)

    def test_parallel_authorization_cancels_have_one_winner(self):
        authorization = self.connector.begin()
        state = self.retained()["state"]
        second = oauth.Connector(self.configuration, oauth.PrivateStore(self.directory),
                                 transport=self.transport, now=lambda: self.clock)

        def cancel(connector):
            try:
                return connector.cancel_authorization(expected_state=state,
                                                       expected_connection_id=authorization["connection_id"])
            except oauth.ConnectionError as failure:
                return str(failure)

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(cancel, [self.connector, second]))
        self.assertCountEqual(results, [{"phase": "disconnected", "connected": False},
                                        "authorization_cancel_refused"])
        self.assertEqual(self.retained()["phase"], "disconnected")
        self.assertEqual(self.calls, [])

    def test_authorization_cancel_does_not_clear_interrupted_operations(self):
        for operation in ["exchange", "refresh", "revoke"]:
            with self.subTest(operation=operation):
                directory = Path(self.temporary.name) / operation
                connector = oauth.Connector(self.configuration, oauth.PrivateStore(directory, provision=True),
                                             transport=self.transport, now=lambda: self.clock)
                authorization = connector.begin()
                state = parse_qs(urlsplit(authorization["authorization_url"]).query)["state"][0]

                def lose(*args):
                    raise oauth.ConnectionError("outcome_unknown")

                with self.assertRaises(oauth.ConnectionError):
                    if operation == "exchange":
                        connector.transport = lose
                        connector.complete(state=state, code="code", integration_key="key")
                    else:
                        connector.complete(state=state, code="code", integration_key="key")
                        if operation == "refresh":
                            self.clock += 901
                            connector.transport = lose
                            connector.credentials(lambda *args: self.fail("unknown refresh must not use credentials"),
                                                  expected_connection_id=authorization["connection_id"])
                        else:
                            connector.disconnect(lose)
                before = active_raw(connector.store).encode()
                calls_before = len(self.calls)
                with self.assertRaisesRegex(oauth.ConnectionError, "authorization_cancel_refused"):
                    connector.cancel_authorization(expected_state=state,
                                                     expected_connection_id=authorization["connection_id"])
                self.assertEqual(active_raw(connector.store).encode(), before)
                self.assertEqual(len(self.calls), calls_before)

    def test_disconnect_requires_the_pinned_cancel_api_for_pending_authorization(self):
        self.connector.begin()
        original = self.retained()
        with self.assertRaisesRegex(oauth.ConnectionError, "authorization_cancel_required"):
            self.connector.disconnect(lambda *args: self.fail("pending authorization has nothing to revoke"))
        self.assertEqual(self.retained(), original)
        self.assertEqual(self.calls, [])

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
        original = self.retained()
        def lose(path, fields, configuration):
            raise oauth.ConnectionError("oauth_transport_or_response_failure")
        self.connector.transport = lose
        with self.assertRaises(oauth.ConnectionError):
            self.connector.complete(state=parameters["state"][0], code="AUTH_CODE", integration_key="KEY")
        self.assertEqual(self.retained()["connection_id"], original["connection_id"])
        self.assertEqual(self.retained()["integration_key"], "KEY")
        restarted = oauth.Connector(self.configuration, oauth.PrivateStore(self.directory), transport=self.transport)
        self.assertEqual(restarted.status()["phase"], "reconnect_required")
        with self.assertRaises(oauth.ConnectionError):
            restarted.complete(state=parameters["state"][0], code="AUTH_CODE", integration_key="KEY")
        self.assertEqual(self.calls, [])

    def test_concurrent_refreshes_rotate_once_and_keep_key(self):
        self.connect()
        connection_id = self.connector.connection_identity()
        self.clock += 901
        second = oauth.Connector(self.configuration, oauth.PrivateStore(self.directory),
                                  transport=self.transport, now=lambda: self.clock)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(connector.credentials, lambda access, key: (access, key),
                                   expected_connection_id=connection_id)
                       for connector in [self.connector, second]]
            results = [future.result() for future in futures]
        self.assertEqual(results, [("ACCESS_2", "INTEGRATION_KEY")] * 2)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.calls[1][1]["refresh_token"], "REFRESH_1")
        self.assertEqual(self.retained()["refresh_token"], "REFRESH_2")

    def test_lost_rotating_refresh_response_fences_reuse_across_restart(self):
        self.connect()
        connection_id = self.connector.connection_identity()
        self.clock += 901
        def lose(path, fields, configuration):
            self.calls.append((path, fields))
            raise oauth.ConnectionError("oauth_transport_or_response_failure")
        self.connector.transport = lose
        with self.assertRaises(oauth.ConnectionError):
            self.connector.credentials(lambda access, key: self.fail("must not use old token"),
                                       expected_connection_id=connection_id)
        restarted = oauth.Connector(self.configuration, oauth.PrivateStore(self.directory),
                                     transport=self.transport, now=lambda: self.clock)
        with self.assertRaisesRegex(oauth.ConnectionError, "connection_not_ready"):
            restarted.credentials(lambda access, key: self.fail("must not replay refresh"),
                                  expected_connection_id=connection_id)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(restarted.status()["phase"], "reconnect_required")

    def test_disconnect_waits_for_private_use_and_revokes_before_erasing(self):
        self.connect()
        connection_id = self.connector.connection_identity()
        entered, release = threading.Event(), threading.Event()
        revocations = []
        def use(access, key):
            entered.set()
            self.assertTrue(release.wait(5))
            return "safe browser receipt"
        with ThreadPoolExecutor(max_workers=2) as pool:
            in_use = pool.submit(self.connector.credentials, use, expected_connection_id=connection_id)
            self.assertTrue(entered.wait(5))
            stopped = pool.submit(self.connector.disconnect, lambda access, key: revocations.append((access, key)))
            self.assertFalse(stopped.done())
            release.set()
            self.assertEqual(in_use.result(), "safe browser receipt")
            self.assertEqual(stopped.result(), {"phase": "disconnected", "connected": False})
        self.assertEqual(revocations, [("ACCESS_1", "INTEGRATION_KEY")])
        self.assertEqual(self.retained(), {"phase": "disconnected",
                                           "configuration_id": self.configuration.identity})

    def test_disconnect_refreshes_an_expired_token_before_revoking(self):
        self.connect()
        original = self.retained()
        self.clock += 901
        revocations = []

        def revoke(access, key):
            retained = self.retained_record_bytes()
            self.assertEqual(retained["phase"], "revoking")
            self.assertEqual(retained["connection_id"], original["connection_id"])
            self.assertEqual(retained["refresh_token"], "REFRESH_2")
            self.assertGreater(retained["expires_at"], self.clock)
            revocations.append((access, key))

        self.assertEqual(self.connector.disconnect(revoke),
                         {"phase": "disconnected", "connected": False})
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.calls[1][1]["grant_type"], "refresh_token")
        self.assertEqual(self.calls[1][1]["refresh_token"], "REFRESH_1")
        self.assertEqual(revocations, [("ACCESS_2", "INTEGRATION_KEY")])
        self.assertEqual(set(self.retained()), {"phase", "configuration_id"})

    def retained_record_bytes(self):
        # Used only by an in-flight fixture callback that already holds the
        # connection lock; reacquiring another flock would block that callback.
        return json.loads(active_raw(self.store))

    def test_lost_refresh_during_disconnect_is_not_replayed_or_revoked(self):
        self.connect()
        self.clock += 901

        def lose(path, fields, configuration):
            self.calls.append((path, fields))
            raise oauth.ConnectionError("oauth_transport_or_response_failure")

        self.connector.transport = lose
        with self.assertRaises(oauth.ConnectionError):
            self.connector.disconnect(lambda *args: self.fail("must not revoke an unknown token"))
        self.assertEqual(self.retained()["phase"], "refreshing")
        restarted = oauth.Connector(self.configuration, oauth.PrivateStore(self.directory),
                                     transport=self.transport, now=lambda: self.clock)
        with self.assertRaisesRegex(oauth.ConnectionError, "remote_connection_reconciliation_required"):
            restarted.disconnect(lambda *args: self.fail("must not replay an uncertain operation"))
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(restarted.status(), {"phase": "reconnect_required", "connected": False})

    def test_failed_revocation_keeps_private_recovery_authority_but_blocks_use(self):
        self.connect()
        connection_id = self.connector.connection_identity()
        revocations = []
        def failed(access, key):
            revocations.append((access, key))
            raise oauth.ConnectionError("revocation_unconfirmed")
        with self.assertRaises(oauth.ConnectionError):
            self.connector.disconnect(failed)
        self.assertEqual(self.connector.status()["phase"], "reconnect_required")
        self.assertEqual(self.retained()["refresh_token"], "REFRESH_1")
        with self.assertRaises(oauth.ConnectionError):
            self.connector.credentials(lambda access, key: None, expected_connection_id=connection_id)
        restarted = oauth.Connector(self.configuration, oauth.PrivateStore(self.directory),
                                     transport=self.transport, now=lambda: self.clock)
        with self.assertRaisesRegex(oauth.ConnectionError, "remote_connection_reconciliation_required"):
            restarted.disconnect(failed)
        self.assertEqual(revocations, [("ACCESS_1", "INTEGRATION_KEY")])

    def test_connection_records_are_bound_to_the_configured_oauth_client(self):
        self.connect()
        original = self.retained()
        for configuration in [
            oauth.Configuration("another-client", "CLIENT_SECRET", self.configuration.redirect_uri),
            oauth.Configuration(self.configuration.client_id, "CLIENT_SECRET", "https://other.example/callback"),
        ]:
            with self.subTest(configuration=configuration):
                other = oauth.Connector(configuration, oauth.PrivateStore(self.directory),
                                        transport=self.transport, now=lambda: self.clock)
                for operation in [other.status, other.begin,
                                  lambda: other.credentials(lambda *args: self.fail("must not use tokens"),
                                                            expected_connection_id=original["connection_id"]),
                                  lambda: other.disconnect(lambda *args: self.fail("must not revoke tokens"))]:
                    with self.assertRaisesRegex(oauth.ConnectionError, "connection_configuration_mismatch"):
                        operation()
                self.assertEqual(self.retained(), original)
        self.assertEqual(len(self.calls), 1)
        self.connector.disconnect(lambda *args: None)
        with self.assertRaisesRegex(oauth.ConnectionError, "connection_configuration_mismatch"):
            other.status()

    def test_pending_authorization_is_bound_to_its_configuration(self):
        parameters = self.begin()
        other = oauth.Connector(oauth.Configuration("another-client", "secret", self.configuration.redirect_uri),
                                oauth.PrivateStore(self.directory), transport=self.transport)
        with self.assertRaisesRegex(oauth.ConnectionError, "connection_configuration_mismatch"):
            other.complete(state=parameters["state"][0], code="code", integration_key="key")
        self.assertEqual(self.calls, [])
        self.assertEqual(self.retained()["phase"], "authorizing")

    def test_client_secret_rotation_preserves_the_logical_connection(self):
        self.connect()
        original = self.retained()
        configuration = oauth.Configuration(self.configuration.client_id, "ROTATED_SECRET",
                                              self.configuration.redirect_uri)
        self.assertEqual(configuration.identity, self.configuration.identity)
        self.clock += 901
        rotated = oauth.Connector(configuration, oauth.PrivateStore(self.directory),
                                  transport=self.transport, now=lambda: self.clock)
        self.assertEqual(rotated.credentials(lambda access, key: (access, key),
                                              expected_connection_id=original["connection_id"]),
                         ("ACCESS_2", "INTEGRATION_KEY"))
        self.assertEqual(self.retained()["connection_id"], original["connection_id"])
        self.assertEqual(self.retained()["configuration_id"], original["configuration_id"])
        self.assertNotIn("ROTATED_SECRET", json.dumps(self.retained()))

    def test_connection_identity_survives_operations_and_changes_on_new_connection(self):
        self.begin()
        authorizing = self.retained()
        self.connector.complete(state=authorizing["state"], code="code", integration_key="key")
        self.assertEqual(self.retained()["connection_id"], authorizing["connection_id"])
        self.clock += 901

        def refresh(path, fields, configuration):
            record = self.retained_record_bytes()
            self.assertEqual(record["phase"], "refreshing")
            self.assertEqual(record["connection_id"], authorizing["connection_id"])
            return self.transport(path, fields, configuration)

        self.connector.transport = refresh
        self.connector.credentials(lambda *args: None, expected_connection_id=authorizing["connection_id"])
        self.connector.disconnect(lambda *args: None)
        self.begin()
        self.assertNotEqual(self.retained()["connection_id"], authorizing["connection_id"])

    def test_old_operation_cannot_use_or_refresh_a_reconnected_accounts_credentials(self):
        self.connect()
        original_connection = self.connector.connection_identity()
        self.connector.disconnect(lambda *args: None)
        self.connect()
        current_connection = self.connector.connection_identity()
        self.assertNotEqual(original_connection, current_connection)
        self.clock += 901
        calls_before = len(self.calls)
        with self.assertRaisesRegex(oauth.ConnectionError, "connection_identity_mismatch"):
            self.connector.credentials(lambda *args: self.fail("must not retarget an old operation"),
                                       expected_connection_id=original_connection)
        self.assertEqual(len(self.calls), calls_before)
        self.assertEqual(self.connector.credentials(lambda access, key: access,
                                                     expected_connection_id=current_connection), "ACCESS_3")

    def test_connection_identity_is_available_only_for_a_ready_connection(self):
        with self.assertRaisesRegex(oauth.ConnectionError, "connection_not_ready"):
            self.connector.connection_identity()
        parameters = self.begin()
        with self.assertRaisesRegex(oauth.ConnectionError, "connection_not_ready"):
            self.connector.connection_identity()
        self.connector.complete(state=parameters["state"][0], code="code", integration_key="key")
        self.assertEqual(self.connector.connection_identity(), self.retained()["connection_id"])

    def test_full_record_schema_is_validated_before_connected_projection_or_use(self):
        self.connect()
        original = self.retained()
        damaged = [
            {"phase": "connected"},
            {key: value for key, value in original.items() if key != "integration_key"},
            {**original, "unexpected": "secret"},
            {**original, "configuration_id": "not-a-configuration-identity"},
            {**original, "connection_id": "not-a-connection-id"},
            {**original, "refresh_token": []},
            {**original, "expires_at": True},
            {**original, "expires_at": -1},
            {**original, "expires_at": float("inf")},
            {**original, "phase": "reconnect_required"},
        ]
        for record in damaged:
            with self.subTest(record=record):
                replace_active_raw(self.store, json.dumps(record))
                for operation in [self.connector.status,
                                  lambda: self.connector.credentials(lambda *args: self.fail("must not use corrupt tokens"),
                                                                     expected_connection_id=original["connection_id"]),
                                  lambda: self.connector.disconnect(lambda *args: self.fail("must not revoke corrupt tokens"))]:
                    with self.assertRaisesRegex(oauth.ConnectionError, "invalid_connection_record"):
                        operation()
        self.assertEqual(len(self.calls), 1)

    def test_duplicate_json_fields_are_not_accepted_as_authoritative_records(self):
        self.connect()
        original = self.retained()
        replace_active_raw(self.store, '{"phase":"connected",' + json.dumps(original)[1:])
        with self.assertRaisesRegex(oauth.ConnectionError, "invalid_connection_record"):
            self.connector.status()

    def test_invalid_provider_tokens_do_not_establish_connection(self):
        for invalid in [
            {"access_token": "a", "refresh_token": "r", "token_type": "Bearer", "expires_in": float("nan")},
            {"access_token": "a", "refresh_token": "r", "token_type": "Bearer", "expires_in": True},
            {"access_token": "a", "token_type": "Bearer", "expires_in": 900},
            {"access_token": "a", "refresh_token": "r", "token_type": "Other", "expires_in": 900},
            {"access_token": "a", "refresh_token": "r", "token_type": {"secret": "body"}, "expires_in": 900},
            {"access_token": "a", "refresh_token": "r", "token_type": 42, "expires_in": 900},
            {"access_token": "a", "refresh_token": "r", "token_type": None, "expires_in": 900},
            [],
        ]:
            with self.subTest(invalid=invalid):
                other_path = Path(self.temporary.name) / ("case-" + str(len(os.listdir(self.temporary.name))))
                connector = oauth.Connector(self.configuration, oauth.PrivateStore(other_path, provision=True),
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
        target = self.directory / "connection.reference.json"
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        outside = Path(self.temporary.name) / "outside.json"
        target.rename(outside)
        target.symlink_to(outside)
        with self.assertRaises(OSError):
            self.connector.status()
        self.assertNotIn("INTEGRATION_KEY", outside.read_text())

    def test_hardlinked_record_and_replaced_directory_are_rejected(self):
        self.connect()
        os.link(self.directory / "connection.reference.json", Path(self.temporary.name) / "other-link")
        with self.assertRaisesRegex(oauth.ConnectionError, "unsafe_secret_store"):
            self.connector.status()
        self.directory.rename(Path(self.temporary.name) / "old")
        self.directory.mkdir(mode=0o700)
        with self.assertRaisesRegex(oauth.ConnectionError, "secret_store_replaced"):
            self.connector.status()


if __name__ == "__main__":
    unittest.main()
