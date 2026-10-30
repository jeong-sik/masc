"""Private lifecycle with real durable files and fabricated credential/Browser edges.

These tests do not execute Chrome, the host broker or a real 1Password account.
"""
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "onepassword"))
from companion import BridgeError
from login import Extension, Journal, LoginError, Logins, Phase
import oauth
from oauth import ConnectionError
from onepassword_store_fixture import MemoryRecords, active_raw, replace_active_raw
from test_onepassword_companion import Host


CALLER = {"kind": "keeper", "name": "login-owner"}
BROWSER = "0b000000-0000-4000-8000-000000000001"
APP_LINK = "onepassword://grant-brokered-access?PRIVATE_APPROVAL_MARKER"
REFERENCE = "PRIVATE_CREDENTIAL_REFERENCE"


class Connector:
    def __init__(self):
        self.identity = str(uuid.uuid4())
        self.uses = []

    def connection_identity(self):
        return self.identity

    def callback_receipt(self):
        return None

    def credentials(self, use, *, expected_connection_id):
        if expected_connection_id != self.identity:
            raise ConnectionError("connection_identity_mismatch")
        self.uses.append(expected_connection_id)
        return use("PRIVATE_ACCESS_TOKEN_" + str(len(self.uses)), "PRIVATE_INTEGRATION_KEY")


class Bridge:
    def __init__(self):
        self.calls, self.responses = [], []
        self.cancelled = False
        self.fill_error = self.release_error = False
        self.withdraw_error = False
        self.fill_entered = self.fill_return = None
        self.release_entered = self.release_return = None
        self.journal_store = None

    def bind(self, **arguments):
        self.calls.append(("bind", arguments))

    def prepare(self, **arguments):
        self.calls.append(("prepare", arguments))

    def invoke(self, *, program, arguments):
        self.calls.append((arguments["kind"], arguments))
        if self.journal_store:
            record = json.loads(active_raw(self.journal_store))["operations"][-1]
            expected = {"request": "requesting", "status": "checking", "fill": "filling"}
            assert record["phase"] == expected[arguments["kind"]]
        if arguments["kind"] == "request":
            return {"request_id": "PRIVATE_REQUEST_ID", "entry_id": "PRIVATE_ENTRY_ID", "app_link": APP_LINK}
        if arguments["kind"] == "status":
            return self.responses.pop(0) if self.responses else {"state": "pending"}
        if self.fill_entered:
            self.fill_entered.set()
            if not self.fill_return.wait(2):
                raise RuntimeError("fixture cancellation did not release fill")
        if self.fill_error:
            raise BridgeError("PRIVATE_PROVIDER_ERROR_MARKER")
        return {"status": "fill_submitted"}

    def release(self):
        self.calls.append(("release", {}))
        if self.release_entered:
            self.release_entered.set()
            if not self.release_return.wait(2):
                raise RuntimeError("fixture did not release settlement")
        if self.release_error:
            raise BridgeError("PRIVATE_RELEASE_ERROR_MARKER")

    def cancel(self):
        self.cancelled = True
        if self.fill_return:
            self.fill_return.set()

    def withdraw(self):
        self.calls.append(("withdraw", {}))
        if self.withdraw_error:
            raise BridgeError("PRIVATE_WITHDRAW_ERROR_MARKER")

    def close(self):
        self.cancel()

    def interrupt(self):
        self.cancel()
        if self.release_return:
            self.release_return.set()


class LoginTests(unittest.TestCase):
    def setUp(self):
        backend = patch.object(oauth, "ProtectedRecords", MemoryRecords)
        backend.start()
        self.addCleanup(backend.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "logins"
        self.journal = Journal(self.directory, provision=True)
        self.connector, self.bridges = Connector(), []
        self.now = 1000.
        self.extension = Extension(Path(self.temp.name) / "extension", "a" * 32)
        self.engine = self.make_engine()

    def make_engine(self):
        def create(_descriptor):
            bridge = Bridge()
            bridge.journal_store = self.journal
            self.bridges.append(bridge)
            return bridge
        engine = Logins(self.connector, self.journal, self.extension,
                        bridge=create, clock=lambda: self.now)
        self.addCleanup(engine.close)
        return engine

    def start(self, **changes):
        arguments = {**dict(descriptor={"private": "PRIVATE_CAPABILITY_MARKER"},
            caller=CALLER, browser_instance_id=BROWSER, tab_id=7,
            website="https://example.test/login", goal="Sign in", reason="Continue the task"), **changes}
        admitted, reserved = self.engine.reserve(**arguments)
        return (self.engine.request(admitted["operation_id"], arguments["caller"],
                goal=arguments["goal"], reason=arguments["reason"]) if reserved else admitted)

    def fill_next(self, operation, caller):
        self.engine.reserve_fill(operation, caller)
        return self.engine.fill(operation, caller)

    def finish(self, operation, caller):
        self.engine.reserve_finish(operation, caller)
        return self.engine.finish(operation, caller)

    def ready(self):
        operation = self.start()["operation_id"]
        self.assertEqual(self.engine.approval(operation), {"open_url": APP_LINK})
        self.engine.opened(operation)
        self.now += 5.
        return operation, self.bridges[-1]

    def assert_public(self, value):
        self.assertEqual(set(value), {"operation_id", "phase", "fill_submitted", "website_login_verified"})
        self.assertFalse(value["website_login_verified"])
        self.assertNotIn("PRIVATE_", json.dumps(value))

    def grant(self, bridge):
        bridge.responses.append({"state": "resolved", "granted": True, "reference": REFERENCE})

    def test_original_grant_multiple_pages_and_explicit_release(self):
        operation, bridge = self.ready()
        self.grant(bridge)
        filled = self.engine.advance(operation, CALLER)
        self.assertEqual(filled["phase"], "fill_submitted")
        self.assertTrue(filled["fill_submitted"])
        self.assert_public(filled)
        self.assertEqual(self.engine.status(operation, CALLER), filled)
        self.assertEqual(self.engine.advance(operation, CALLER), filled)
        for _ in range(3):
            self.assertEqual(self.fill_next(operation, CALLER), filled)
        fills = [arguments for name, arguments in bridge.calls if name == "fill"]
        self.assertEqual(len(fills), 4)
        self.assertTrue(all(args["reference"] == REFERENCE for args in fills))
        self.assertEqual(len({args["access_token"] for args in fills}), 4)
        self.assertEqual(len([1 for name, _ in bridge.calls if name == "bind"]), 1)
        released = self.finish(operation, CALLER)
        self.assertEqual(released["phase"], "released")
        self.assert_public(released)
        self.assertEqual([name for name, _ in bridge.calls].count("release"), 1)
        with self.assertRaises(LoginError):
            self.fill_next(operation, CALLER)
        record = json.loads(active_raw(self.journal))["operations"][0]
        self.assertIsNone(record["app_link"])
        self.assertIsNone(record["reference"])
        self.assertNotIn("PRIVATE_ACCESS_TOKEN", json.dumps(record))

    def test_status_and_observation_contain_no_private_payload(self):
        pending = self.start()
        self.assert_public(pending)
        self.assertEqual(pending["phase"], "approval_ready")
        for caller in [CALLER, {"kind": "operator"}]:
            self.assert_public(self.engine.status(pending["operation_id"], caller))
        path = self.directory / "operations.reference.json"
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)

    def test_original_caller_and_account_are_pinned(self):
        operation, bridge = self.ready()
        stranger = {"kind": "keeper", "name": "other"}
        for call in [lambda: self.engine.status(operation, stranger),
                     lambda: self.engine.cancel(operation, stranger)]:
            with self.assertRaises(LoginError):
                call()
        self.assertFalse(bridge.cancelled)
        self.connector.identity = str(uuid.uuid4())
        self.grant(bridge)
        result = self.engine.advance(operation, CALLER)
        self.assertEqual(result["phase"], "outcome_unknown")
        self.assert_public(result)
        self.assertEqual([name for name, _ in bridge.calls].count("fill"), 0)

    def test_never_check_before_open_or_vendor_first_wait(self):
        operation = self.start()["operation_id"]
        self.engine.advance(operation, CALLER)
        self.engine.approval(operation)
        self.engine.opened(operation)
        self.now += 4.9
        self.engine.advance(operation, CALLER)
        self.assertEqual([name for name, _ in self.bridges[-1].calls].count("status"), 0)
        self.now += 0.1
        self.engine.advance(operation, CALLER)
        self.assertEqual([name for name, _ in self.bridges[-1].calls].count("status"), 1)

    def test_vendor_rate_limit_and_user_wait_do_not_expire_operation(self):
        operation, bridge = self.ready()
        bridge.responses.append({"error": "rateLimitExceeded"})
        self.engine.advance(operation, CALLER)
        self.now += 59.
        self.engine.advance(operation, CALLER)
        self.assertEqual([name for name, _ in bridge.calls].count("status"), 1)
        self.now += 1.
        self.engine.advance(operation, CALLER)
        self.assertEqual([name for name, _ in bridge.calls].count("status"), 2)
        self.now = 1000. + 121.
        paused = self.engine.advance(operation, CALLER)
        self.assertEqual(paused["phase"], "waiting_user")
        self.now += 10000.
        self.assertEqual(self.engine.advance(operation, CALLER), paused)
        self.grant(bridge)
        self.assertEqual(self.engine.advance(operation, CALLER, user_confirmed=True)["phase"], "fill_submitted")
        self.assertEqual([name for name, _ in bridge.calls].count("request"), 1)

    def test_denied_expired_failed_and_skipped_entry_never_fill(self):
        for response, expected in [({"state": "denied"}, "denied"),
                ({"state": "expired"}, "expired"), ({"state": "failed"}, "failed"),
                ({"state": "resolved", "granted": False}, "denied")]:
            with self.subTest(response=response):
                operation, bridge = self.ready()
                bridge.responses.append(response)
                result = self.engine.advance(operation, CALLER)
                self.assertEqual(result["phase"], expected)
                self.assert_public(result)
                self.assertEqual([name for name, _ in bridge.calls].count("fill"), 0)
                self.assertTrue(bridge.cancelled)

    def test_unknown_fill_is_never_replayed(self):
        operation, bridge = self.ready()
        self.grant(bridge)
        bridge.fill_error = True
        unknown = self.engine.advance(operation, CALLER)
        self.assertEqual(unknown["phase"], "outcome_unknown")
        self.assert_public(unknown)
        self.assertEqual(self.engine.advance(operation, CALLER), unknown)
        self.assertEqual([name for name, _ in bridge.calls].count("fill"), 1)

    def test_malformed_private_status_is_unknown_before_fill(self):
        operation, bridge = self.ready()
        bridge.responses.append({"state": "resolved", "granted": 0})
        result = self.engine.advance(operation, CALLER)
        self.assertEqual(result["phase"], "outcome_unknown")
        self.assert_public(result)
        self.assertEqual([name for name, _ in bridge.calls].count("fill"), 0)

    def test_untyped_caller_is_refused_before_allocating_an_operation(self):
        with self.assertRaisesRegex(LoginError, "^not_started$"):
            self.start(caller={"kind": [], "name": "somebody"})
        self.assertFalse(self.bridges)

    def test_unknown_release_preserves_observed_fill_without_auth_claim(self):
        operation, bridge = self.ready()
        self.grant(bridge)
        self.engine.advance(operation, CALLER)
        bridge.release_error = True
        result = self.finish(operation, CALLER)
        self.assertEqual(result["phase"], "outcome_unknown")
        self.assertTrue(result["fill_submitted"])
        self.assert_public(result)

    def test_release_wait_is_durable_nonterminal_and_restart_is_unknown(self):
        for terminal, submitted in [("released", True), ("denied", False)]:
            with self.subTest(terminal=terminal):
                operation, bridge = self.ready()
                if submitted:
                    self.grant(bridge)
                    self.engine.advance(operation, CALLER)
                    settle = lambda: self.finish(operation, CALLER)
                else:
                    bridge.responses.append({"state": "denied"})
                    settle = lambda: self.engine.advance(operation, CALLER)
                bridge.release_entered, bridge.release_return = threading.Event(), threading.Event()
                outcomes, failures = [], []

                def finish():
                    try:
                        outcomes.append(settle())
                    except BaseException as failure:
                        failures.append(failure)

                worker = threading.Thread(target=finish, daemon=True)
                worker.start()
                try:
                    self.assertTrue(bridge.release_entered.wait(2))
                    self.assertTrue(worker.is_alive())
                    with self.journal.locked() as root:
                        snapshot = self.journal.read(root)
                    record = next(record for record in snapshot["operations"]
                                  if record["operation_id"] == operation)
                    self.assertEqual(record["phase"], "settling")
                    self.assertEqual(record["fill_submitted"], submitted)
                    self.assertIsNone(record["app_link"])
                    self.assertIsNone(record["reference"])

                    # Recover the actual bytes committed while release is held,
                    # on a separate journal as if the old process had crashed.
                    recovered_journal = Journal(Path(self.temp.name) / ("snapshot-" + terminal), provision=True)
                    with recovered_journal.locked() as root:
                        recovered_journal.write(root, snapshot)

                    def refuse_rebind(_descriptor):
                        self.fail("restart must never allocate a replacement private bridge")

                    recovered = Logins(self.connector, recovered_journal, self.extension,
                                       bridge=refuse_rebind, clock=lambda: self.now)
                    self.addCleanup(recovered.close)
                    unknown = recovered.status(operation, CALLER)
                    self.assertEqual(unknown["phase"], "outcome_unknown")
                    self.assertEqual(unknown["fill_submitted"], submitted)
                    self.assertEqual(recovered.advance(operation, CALLER), unknown)
                    self.assert_public(unknown)
                finally:
                    bridge.release_return.set()
                    worker.join(2)
                self.assertFalse(worker.is_alive())
                self.assertEqual(failures, [])
                self.assertEqual(outcomes[0]["phase"], terminal)
                self.assertEqual(outcomes[0]["fill_submitted"], submitted)
                with self.journal.locked() as root:
                    settled = self.journal.read(root)
                self.assertEqual(next(record for record in settled["operations"]
                                      if record["operation_id"] == operation)["phase"], terminal)
                self.assertEqual([name for name, _ in bridge.calls].count("release"), 1)

    def test_close_ends_admission_before_a_gated_identity_can_publish_a_handle(self):
        self.start()
        existing = self.bridges[-1]
        identity_entered, identity_return = threading.Event(), threading.Event()
        close_sweep, close_done = threading.Event(), threading.Event()
        bind_entered, bind_return = threading.Event(), threading.Event()
        original_identity = self.connector.connection_identity

        def gated_identity():
            identity_entered.set()
            identity_return.wait()
            return original_identity()

        self.connector.connection_identity = gated_identity
        original_cancel = existing.cancel

        def observed_close_sweep():
            original_cancel()
            close_sweep.set()

        existing.cancel = observed_close_sweep
        original_create = self.engine._bridge

        def gated_bridge(descriptor):
            bridge = original_create(descriptor)
            bind, cancel = bridge.bind, bridge.cancel

            def held_bind(**arguments):
                bind_entered.set()
                bind_return.wait()
                return bind(**arguments)

            def interrupt_bind():
                cancel()
                bind_return.set()

            bridge.bind, bridge.cancel = held_bind, interrupt_bind
            return bridge

        self.engine._bridge = gated_bridge
        outcomes, failures = [], []

        def start():
            try:
                outcomes.append(self.start(tab_id=8))
            except BaseException as failure:
                failures.append(failure)

        def close():
            try:
                self.engine.close()
                close_done.set()
            except BaseException as failure:
                failures.append(failure)

        starting = threading.Thread(target=start, daemon=True)
        closing = threading.Thread(target=close, daemon=True)
        starting.start()
        try:
            self.assertTrue(identity_entered.wait(2))
            closing.start()
            self.assertTrue(close_sweep.wait(2))
            identity_return.set()
            starting.join(2)
            closing.join(2)
            self.assertFalse(starting.is_alive())
            self.assertFalse(closing.is_alive())
            self.assertTrue(close_done.is_set())
            self.assertFalse(bind_entered.is_set())
            self.assertEqual(failures, [])
            self.assertEqual(outcomes[0]["phase"], "outcome_unknown")
            self.assertTrue(self.bridges[-1].cancelled)
            with self.assertRaisesRegex(LoginError, "^unavailable$"):
                self.start(tab_id=9)
        finally:
            identity_return.set()
            bind_return.set()
            starting.join(2)
            if closing.ident is not None:
                closing.join(2)

    def test_approval_redelivery_waits_for_opened_ack_and_repeated_ack_preserves_first_wait(self):
        operation = self.start()["operation_id"]
        bridge = self.bridges[-1]
        path = self.directory / "operations.reference.json"
        original = active_raw(self.journal).encode()
        for _ in range(2):
            self.assertEqual(self.engine.approval(operation), {"open_url": APP_LINK})
        self.now += 20.
        self.assertEqual(self.engine.advance(operation, CALLER)["phase"], "approval_ready")
        self.assertEqual([name for name, _ in bridge.calls].count("status"), 0)
        self.assertEqual(active_raw(self.journal).encode(), original)
        opened = self.engine.opened(operation)
        first = json.loads(active_raw(self.journal))["operations"][0]
        self.assertEqual(first["opened_at"], self.now)
        self.assertEqual(first["next_check_at"], self.now + 5.)
        self.now += 3.
        self.assertEqual(self.engine.approval(operation), {"open_url": APP_LINK})
        self.assertEqual(self.engine.opened(operation), opened)
        self.assertEqual(json.loads(active_raw(self.journal))["operations"][0], first)
        self.engine.advance(operation, CALLER)
        self.assertEqual([name for name, _ in bridge.calls].count("status"), 0)
        self.now = first["next_check_at"]
        self.engine.advance(operation, CALLER)
        self.assertEqual([name for name, _ in bridge.calls].count("status"), 1)

    def test_opened_ack_never_resets_rate_limit_or_user_wait(self):
        operation, bridge = self.ready()
        bridge.responses.append({"error": "rateLimitExceeded"})
        self.engine.advance(operation, CALLER)
        path = self.directory / "operations.reference.json"
        limited = json.loads(active_raw(self.journal))["operations"][0]
        self.now += 30.
        self.engine.opened(operation)
        self.assertEqual(self.engine.approval(operation), {"open_url": APP_LINK})
        self.assertEqual(json.loads(active_raw(self.journal))["operations"][0], limited)
        self.engine.advance(operation, CALLER)
        self.assertEqual([name for name, _ in bridge.calls].count("status"), 1)
        self.now = limited["next_check_at"]
        self.engine.advance(operation, CALLER)
        self.now = limited["opened_at"] + 121.
        waiting = self.engine.advance(operation, CALLER)
        self.assertEqual(waiting["phase"], "waiting_user")
        retained = json.loads(active_raw(self.journal))["operations"][0]
        self.assertEqual(self.engine.approval(operation), {"open_url": APP_LINK})
        self.assertEqual(self.engine.opened(operation), waiting)
        self.assertEqual(json.loads(active_raw(self.journal))["operations"][0], retained)
        self.assertEqual(self.engine.advance(operation, CALLER), waiting)
        self.assertEqual([name for name, _ in bridge.calls].count("status"), 2)

    def test_cancellation_interrupts_fill_and_discards_late_success(self):
        operation, bridge = self.ready()
        self.grant(bridge)
        bridge.fill_entered, bridge.fill_return = threading.Event(), threading.Event()
        outcomes = []
        worker = threading.Thread(target=lambda: outcomes.append(self.engine.advance(operation, CALLER)))
        worker.start()
        self.addCleanup(worker.join, 2)
        self.assertTrue(bridge.fill_entered.wait(2))
        result = self.engine.cancel(operation, CALLER)
        worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(result["phase"], "outcome_unknown")
        self.assertFalse(result["fill_submitted"])
        self.assertEqual(outcomes, [result])
        self.assert_public(result)

    def test_cancel_pending_reserves_no_successor_tab(self):
        operation = self.start()["operation_id"]
        with self.assertRaises(LoginError):
            self.start()
        result = self.engine.cancel(operation, CALLER)
        self.assertEqual(result["phase"], "cancelled")
        self.assertNotEqual(self.start()["operation_id"], operation)

    def test_unconfirmed_withdrawal_never_claims_cancelled_or_clean_close(self):
        self.engine.close()
        bridge = Bridge()
        bridge.withdraw_error = True
        engine = Logins(self.connector, self.journal, self.extension,
                        bridge=lambda _descriptor: bridge, clock=lambda: self.now)
        try:
            admitted, reserved = engine.reserve(descriptor={"private": "PRIVATE_CAPABILITY"}, caller=CALLER,
                browser_instance_id=BROWSER, tab_id=7, website="https://example.test/login",
                goal="Sign in", reason="Continue task")
            self.assertTrue(reserved)
            result = engine.cancel(admitted["operation_id"], CALLER)
            self.assertEqual(result["phase"], "outcome_unknown")
            self.assert_public(result)
            self.assertEqual([name for name, _ in bridge.calls], ["withdraw"])
        finally:
            with self.assertRaisesRegex(LoginError, "^outcome_unknown$"):
                engine.close()
        with self.assertRaisesRegex(LoginError, "^outcome_unknown$"):
            engine.close()

    def test_restart_does_not_rebind_approval_or_grant(self):
        operation, bridge = self.ready()
        self.grant(bridge)
        self.engine.advance(operation, CALLER)
        self.engine.close()
        recovered = self.make_engine()
        self.assertEqual(recovered.status(operation, CALLER)["phase"], "outcome_unknown")
        self.assertTrue(recovered.status(operation, CALLER)["fill_submitted"])
        self.assertEqual(len(self.bridges), 1)

    def test_a_live_engine_cannot_be_recovered_by_a_second_owner(self):
        operation = self.start()["operation_id"]
        with self.assertRaisesRegex(LoginError, "^unavailable$"):
            self.make_engine()
        self.assertEqual(self.engine.status(operation, CALLER)["phase"], "approval_ready")

    def test_retained_record_is_closed_and_never_repairs_unknown_fields(self):
        self.start()
        self.engine.close()
        path = self.directory / "operations.reference.json"
        value = json.loads(active_raw(self.journal))
        value["operations"][0]["unexpected_private_data"] = "PRIVATE_MARKER"
        replace_active_raw(self.journal, json.dumps(value))
        os.chmod(path, 0o600)
        with self.assertRaisesRegex(LoginError, "^unavailable$"):
            self.make_engine()
        self.assertIn("unexpected_private_data", json.loads(active_raw(self.journal))["operations"][0])

    def test_lifecycle_on_actual_private_socket_and_durable_store(self):
        def handler(host, connection, reader):
            host.bind(connection, reader)
            host.read(reader); host.write(connection, {"value": {"prepared": True}})
            host.read(reader); host.write(connection, {"value": {"request_id": "PRIVATE_REQUEST_ID",
                "entry_id": "PRIVATE_ENTRY_ID", "app_link": APP_LINK}})
            host.read(reader); host.write(connection, {"value": {"state": "resolved",
                "granted": True, "reference": REFERENCE}})
            host.read(reader); host.write(connection, {"value": {"status": "fill_submitted"}})
            host.read(reader); host.write(connection, {"value": {"released": True}})
        self.engine.close()
        host = Host(handler)
        self.addCleanup(host.close)
        engine = Logins(self.connector, self.journal, self.extension, clock=lambda: self.now)
        self.addCleanup(engine.close)
        pending, reserved = engine.reserve(descriptor=host.descriptor, caller=CALLER, browser_instance_id=BROWSER,
            tab_id=7, website="https://example.test/login", goal="Sign in", reason="Continue task")
        self.assertTrue(reserved)
        pending = engine.request(pending["operation_id"], CALLER, goal="Sign in", reason="Continue task")
        self.assert_public(pending)
        operation = pending["operation_id"]
        self.assertEqual(engine.approval(operation), {"open_url": APP_LINK})
        engine.opened(operation)
        self.now += 5.
        self.assert_public(engine.advance(operation, CALLER))
        engine.reserve_finish(operation, CALLER)
        self.assertEqual(engine.finish(operation, CALLER)["phase"], "released")
        host.thread.join(2)
        self.assertFalse(host.thread.is_alive())
        self.assertEqual(host.connections, 1)
        commands = host.messages[1:]
        self.assertEqual([command["kind"] for command in commands],
                         ["prepare", "invoke", "invoke", "invoke", "release"])
        self.assertEqual([command["arguments"]["kind"] for command in commands[1:4]],
                         ["request", "status", "fill"])
        self.assertEqual(commands[3]["arguments"]["reference"], REFERENCE)
        self.assertEqual(len({command["operation_id"] for command in commands}), 1)


if __name__ == "__main__":
    unittest.main()
