"""Actual owned service thread and durable engine, with fabricated private edges."""
from contextlib import redirect_stderr
import io
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "onepassword"))
import oauth
from onepassword_store_fixture import MemoryRecords
from login import Extension, Journal, LoginError, Logins
from service import Service
from test_onepassword_login import APP_LINK, BROWSER, CALLER, REFERENCE, Bridge, Connector


class GatedBridge(Bridge):
    def __init__(self):
        super().__init__()
        self.prepare_entered = threading.Event()
        self.prepare_return = None
        self.bind_entered = threading.Event()
        self.bind_return = None
        self.request_failure = False

    def bind(self, **arguments):
        super().bind(**arguments)
        self.bind_entered.set()
        if self.bind_return is not None and not self.bind_return.wait(2):
            raise RuntimeError("fixture bind did not settle")

    def prepare(self, **arguments):
        super().prepare(**arguments)
        self.prepare_entered.set()
        if self.prepare_return is not None and not self.prepare_return.wait(2):
            raise RuntimeError("fixture prepare did not settle")

    def invoke(self, **arguments):
        if self.request_failure:
            raise RuntimeError("PRIVATE_BACKGROUND_FAILURE_MARKER")
        return super().invoke(**arguments)

    def cancel(self):
        super().cancel()
        if self.prepare_return is not None:
            self.prepare_return.set()
        if self.bind_return is not None:
            self.bind_return.set()


class ServiceTests(unittest.TestCase):
    def setUp(self):
        backend = patch.object(oauth, "ProtectedRecords", MemoryRecords)
        backend.start()
        self.addCleanup(backend.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "logins"
        self.journal = Journal(self.directory, provision=True)
        self.connector = Connector()
        self.bridges = []
        self.next_bridge = GatedBridge()
        self.now = 1000.

        def create(_descriptor):
            bridge = self.next_bridge
            self.next_bridge = GatedBridge()
            self.bridges.append(bridge)
            return bridge
        self.engine = Logins(self.connector, self.journal,
            Extension(Path(self.temp.name) / "extension", "a" * 32),
            bridge=create, clock=lambda: self.now)
        self.service = Service(self.engine, publisher=lambda _: None, clock=lambda: self.now)
        self.addCleanup(self.service.close)

    def submit(self, **changes):
        return self.service.submit(**{**dict(descriptor={"private": "PRIVATE_CAPABILITY"},
            caller=CALLER, browser_instance_id=BROWSER, tab_id=7,
            website="https://example.test/login", goal="Sign in", reason="Continue task"), **changes})

    def wait(self, predicate):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(0.001)
        self.fail("owned service did not reach the expected fixture state")

    def phase(self, operation, expected):
        return self.wait(lambda: (value if (value := self.service.status(operation, CALLER))["phase"] == expected else None))

    def pending(self):
        result = self.submit()
        self.assertEqual(result["phase"], "preparing")
        self.phase(result["operation_id"], "approval_ready")
        return result["operation_id"], self.bridges[-1]

    def opened(self, operation):
        self.assertEqual(self.service.approval(operation), {"open_url": APP_LINK})
        self.service.opened(operation)
        self.phase(operation, "awaiting_approval")

    def test_original_binding_background_approval_fill_next_and_release(self):
        operation, bridge = self.pending()
        self.opened(operation)
        bridge.responses.append({"state": "resolved", "granted": True, "reference": REFERENCE})
        self.now += 5.
        self.service.notify()
        filled = self.phase(operation, "fill_submitted")
        self.assertFalse(filled["website_login_verified"])
        self.assertNotIn("PRIVATE_", str(filled))
        self.assertEqual(self.service.fill_next(operation, CALLER)["phase"], "filling")
        self.phase(operation, "fill_submitted")
        self.assertEqual(self.service.finish(operation, CALLER)["phase"], "settling")
        self.phase(operation, "released")
        self.assertEqual([name for name, _ in bridge.calls].count("bind"), 1)
        self.assertEqual([name for name, _ in bridge.calls].count("request"), 1)
        self.assertEqual([name for name, _ in bridge.calls].count("fill"), 2)
        self.assertEqual([name for name, _ in bridge.calls].count("release"), 1)

    def test_status_stays_available_and_cancel_interrupts_private_prepare(self):
        bridge = self.next_bridge
        bridge.prepare_return = threading.Event()
        operation = self.submit()["operation_id"]
        self.assertTrue(bridge.prepare_entered.wait(2))
        observed, done = [], threading.Event()

        def read():
            try:
                observed.append((self.service.status(operation, CALLER), self.service.operations(CALLER)))
            finally:
                done.set()
        reader = threading.Thread(target=read)
        reader.start()
        try:
            self.assertTrue(done.wait(1), "status waited behind extension IO")
            self.assertEqual(observed[0][0]["phase"], "preparing")
            with self.assertRaisesRegex(LoginError, "^unavailable$"):
                self.submit(tab_id=8)
        finally:
            receipt = self.service.cancel(operation, CALLER)
            reader.join(2)
        self.assertEqual(receipt, {"operation_id": operation, "cancel_requested": True})
        self.phase(operation, "outcome_unknown")
        self.assertEqual([name for name, _ in bridge.calls].count("request"), 0)

    def test_binding_runs_after_admission_and_cancel_prevents_prepare(self):
        bridge = self.next_bridge
        bridge.bind_return = threading.Event()
        admitted = self.submit()
        operation = admitted["operation_id"]
        self.assertEqual(admitted["phase"], "preparing")
        self.assertTrue(bridge.bind_entered.wait(2))
        self.assertEqual(self.service.status(operation, CALLER)["phase"], "preparing")
        self.assertEqual(self.service.cancel(operation, CALLER),
                         {"operation_id": operation, "cancel_requested": True})
        self.phase(operation, "outcome_unknown")
        self.assertEqual([name for name, _ in bridge.calls], ["bind", "withdraw"])

    def test_actual_socket_bind_wait_keeps_status_and_cancellation_available(self):
        from test_onepassword_companion import Host
        self.service.close()
        entered = threading.Event()

        def handler(host, connection, reader):
            frame = host.read(reader)
            if frame.get("withdraw") is True:
                self.assertEqual(set(frame), {"invocation_id", "withdraw"})
                host.write(connection, {"withdrawn": True})
            else:
                entered.set()
                self.assertEqual(reader.readline(), b"")

        host = Host(handler, max_connections=2)
        self.addCleanup(host.close)
        engine = Logins(self.connector, self.journal,
            Extension(Path(self.temp.name) / "extension", "a" * 32), clock=lambda: self.now)
        service = Service(engine, publisher=lambda _: None, clock=lambda: self.now)
        self.addCleanup(service.close)
        try:
            admitted = service.submit(descriptor=host.descriptor, caller=CALLER,
                browser_instance_id=BROWSER, tab_id=7, website="https://example.test/login",
                goal="Sign in", reason="Continue task")
            self.assertTrue(entered.wait(2))
            operation = admitted["operation_id"]
            self.assertEqual(service.status(operation, CALLER)["phase"], "preparing")
            self.assertEqual(service.cancel(operation, CALLER),
                             {"operation_id": operation, "cancel_requested": True})
            self.wait(lambda: service.status(operation, CALLER)["phase"] == "outcome_unknown")
            self.assertEqual(self.connector.uses, [])
            self.assertEqual(len(host.messages), 2)
            self.assertEqual(set(host.messages[0]), {"invocation_id", "browser_instance_id", "tab_id"})
            self.assertEqual(host.messages[1], {"invocation_id": host.descriptor["invocation_id"], "withdraw": True})
        finally:
            service.close()
        host.thread.join(2)
        self.assertFalse(host.thread.is_alive())

    def test_cancel_before_bind_withdraws_nonce_and_refuses_descriptor_replay(self):
        from companion import BridgeError, Companion
        from test_onepassword_companion import Host
        self.service.close()
        entered, resume = threading.Event(), threading.Event()
        active, binds = [True], []

        def handler(host, connection, reader):
            frame = host.read(reader)
            if frame.get("withdraw") is True:
                self.assertEqual(frame, {"invocation_id": host.descriptor["invocation_id"], "withdraw": True})
                active[0] = False
                host.write(connection, {"withdrawn": True})
            else:
                if active[0]:
                    binds.append(frame)
                host.write(connection, {"error": "not_started"})

        host = Host(handler, max_connections=2)
        self.addCleanup(host.close)
        engine = Logins(self.connector, self.journal,
            Extension(Path(self.temp.name) / "extension", "a" * 32), clock=lambda: self.now)
        original_request = engine.request

        def gated_request(*args, **kwargs):
            entered.set()
            if not resume.wait(2):
                raise AssertionError("fixture deferred request did not settle")
            return original_request(*args, **kwargs)

        engine.request = gated_request
        service = Service(engine, publisher=lambda _: None, clock=lambda: self.now)
        self.addCleanup(service.close)
        try:
            operation = service.submit(descriptor=host.descriptor, caller=CALLER,
                browser_instance_id=BROWSER, tab_id=7, website="https://example.test/login",
                goal="Sign in", reason="Continue task")["operation_id"]
            self.assertTrue(entered.wait(2))
            self.assertEqual(host.messages, [])
            self.assertTrue(service.cancel(operation, CALLER)["cancel_requested"])
            resume.set()
            self.wait(lambda: service.status(operation, CALLER)["phase"] == "outcome_unknown")
            replay = Companion(host.descriptor)
            self.addCleanup(replay.close)
            with self.assertRaises(BridgeError):
                replay.bind(browser_instance_id=BROWSER, tab_id=7)
            self.assertEqual(binds, [])
            self.assertFalse(active[0])
            self.assertEqual(self.connector.uses, [])
        finally:
            resume.set()
            service.close()
        host.thread.join(2)
        self.assertFalse(host.thread.is_alive())

    def test_cancelling_other_operation_does_not_wait_for_unrelated_io(self):
        first, first_bridge = self.pending()
        second_bridge = self.next_bridge
        second_bridge.prepare_return = threading.Event()
        second = self.submit(tab_id=8)["operation_id"]
        self.assertTrue(second_bridge.prepare_entered.wait(2))
        receipts, done = [], threading.Event()

        def cancel_first():
            try:
                receipts.append(self.service.cancel(first, CALLER))
            finally:
                done.set()
        cancelling = threading.Thread(target=cancel_first)
        cancelling.start()
        try:
            self.assertTrue(done.wait(1), "cancellation queued behind an unrelated private call")
            self.assertTrue(first_bridge.cancelled)
            self.assertFalse(second_bridge.cancelled)
            self.assertEqual(receipts, [{"operation_id": first, "cancel_requested": True}])
            with self.assertRaises(LoginError):
                self.service.approval(first)
        finally:
            self.service.cancel(second, CALLER)
            cancelling.join(2)
        self.phase(first, "cancelled")
        self.phase(second, "outcome_unknown")

    def _cancel_during_actual_withdrawal(self, *, automatic_failure):
        from test_onepassword_companion import Host
        self.service.close()
        withdraw_entered, allow_ack = threading.Event(), threading.Event()
        business_thread = threading.current_thread()
        business_interrupts = []

        def handler(host, connection, reader):
            if host.connections == 1:
                host.bind(connection, reader)
                host.read(reader)
                host.write(connection, {"value": {"prepared": True}})
                host.read(reader)
                result = ({"unexpected": "PRIVATE_ERROR_MARKER"} if automatic_failure else
                          {"request_id": "PRIVATE_REQUEST_ID", "entry_id": "PRIVATE_ENTRY_ID", "app_link": APP_LINK})
                host.write(connection, {"value": result})
                self.assertEqual(reader.read(1), b"")
            else:
                self.assertEqual(host.read(reader),
                    {"invocation_id": host.descriptor["invocation_id"], "withdraw": True})
                withdraw_entered.set()
                self.assertTrue(allow_ack.wait(2), "fixture did not release withdrawal acknowledgement")
                host.write(connection, {"withdrawn": True})

        host = Host(handler, max_connections=2)
        self.addCleanup(host.close)
        engine = Logins(self.connector, self.journal,
            Extension(Path(self.temp.name) / "extension", "a" * 32), clock=lambda: self.now)
        original_interrupt = engine.interrupt

        def counted_interrupt(operation_id, caller):
            if threading.current_thread() is business_thread and caller == CALLER:
                business_interrupts.append(operation_id)
            return original_interrupt(operation_id, caller)

        engine.interrupt = counted_interrupt
        service = Service(engine, publisher=lambda _: None, clock=lambda: self.now)
        self.addCleanup(service.close)
        try:
            operation = service.submit(descriptor=host.descriptor, caller=CALLER,
                browser_instance_id=BROWSER, tab_id=7, website="https://example.test/login",
                goal="Sign in", reason="Continue task")["operation_id"]
            receipt = {"operation_id": operation, "cancel_requested": True}
            if automatic_failure:
                # The request's own error path already holds the engine lock
                # and waits for disposal IO before the first business cancel.
                self.assertTrue(withdraw_entered.wait(2))
            else:
                self.wait(lambda: service.status(operation, CALLER)["phase"] == "approval_ready")
            self.assertEqual(service.cancel(operation, CALLER), receipt)
            self.assertTrue(withdraw_entered.wait(2))
            self.assertEqual(service.cancel(operation, CALLER), receipt)
            self.assertEqual(service.cancel(operation, {"kind": "operator"}), receipt)
            with self.assertRaisesRegex(LoginError, "^unavailable$"):
                service.cancel(operation, {"kind": "keeper", "name": "other"})
            self.assertEqual(business_interrupts, [operation])
            self.assertEqual(service.status(operation, CALLER)["phase"],
                             "requesting" if automatic_failure else "approval_ready")
            allow_ack.set()
            expected = "outcome_unknown" if automatic_failure else "cancelled"
            self.wait(lambda: service.status(operation, CALLER)["phase"] == expected)
            with service._condition:
                self.assertTrue(service._condition.wait_for(lambda: operation not in service._cancels, timeout=2))
            # A lost withdrawal acknowledgement would poison owner cleanup.
            service.close()
            with self.assertRaisesRegex(LoginError, "^unavailable$"):
                service.cancel(operation, CALLER)
            self.assertEqual(business_interrupts, [operation])
        finally:
            allow_ack.set()
            service.close()
        host.thread.join(2)
        self.assertFalse(host.thread.is_alive())
        self.assertEqual(host.connections, 2)
        self.assertEqual(len(host.messages), 4)
        self.assertEqual(sum(frame.get("withdraw") is True for frame in host.messages), 1)

    def test_duplicate_cancel_preserves_actual_withdrawal_acknowledgement(self):
        self._cancel_during_actual_withdrawal(automatic_failure=False)

    def test_first_cancel_during_automatic_error_preserves_actual_withdrawal(self):
        self._cancel_during_actual_withdrawal(automatic_failure=True)

    def test_cancel_admission_failure_rolls_back_and_does_not_interrupt_foreign_grant(self):
        operation, _ = self.pending()
        original_interrupt = self.engine.interrupt
        calls = []

        def refused_interrupt(operation_id, caller):
            calls.append(operation_id)
            raise LoginError("unavailable")

        self.engine.interrupt = refused_interrupt
        with self.assertRaisesRegex(LoginError, "^unavailable$"):
            self.service.cancel(operation, {"kind": "keeper", "name": "other"})
        self.assertEqual(calls, [])
        with self.assertRaisesRegex(LoginError, "^unavailable$"):
            self.service.cancel(operation, CALLER)
        with self.service._condition:
            self.assertNotIn(operation, self.service._cancels)
            self.assertEqual(self.service._jobs, [])
        self.engine.interrupt = original_interrupt
        self.assertEqual(self.service.cancel(operation, CALLER),
                         {"operation_id": operation, "cancel_requested": True})
        self.phase(operation, "cancelled")

    def test_vendor_window_pauses_and_explicit_user_confirmation_continues(self):
        operation, bridge = self.pending()
        self.opened(operation)
        self.now += 121.
        self.service.notify()
        self.phase(operation, "waiting_user")
        self.assertEqual([name for name, _ in bridge.calls].count("status"), 0)
        bridge.responses.append({"state": "resolved", "granted": True, "reference": REFERENCE})
        self.service.confirmed(operation)
        self.phase(operation, "fill_submitted")
        self.assertEqual([name for name, _ in bridge.calls].count("request"), 1)
        self.assertEqual([name for name, _ in bridge.calls].count("status"), 1)

    def test_status_reads_do_not_start_provider_checks(self):
        operation, bridge = self.pending()
        for _ in range(3):
            self.assertEqual(self.service.status(operation, CALLER)["phase"], "approval_ready")
        self.assertEqual([name for name, _ in bridge.calls].count("status"), 0)
        with self.assertRaises(LoginError):
            self.service.status(operation, {"kind": "keeper", "name": "other"})
        self.assertEqual(self.service.operations({"kind": "keeper", "name": "other"}), [])

    def test_owner_close_during_reservation_is_not_a_successful_submission(self):
        original = self.connector.connection_identity

        def close_during_identity():
            self.engine.close()
            return original()

        self.connector.connection_identity = close_during_identity
        with self.assertRaisesRegex(LoginError, "^outcome_unknown$"):
            self.submit()
        self.assertEqual([name for bridge in self.bridges for name, _ in bridge.calls], [])

    def test_close_joins_original_private_call_and_refuses_new_jobs(self):
        bridge = self.next_bridge
        bridge.prepare_return = threading.Event()
        operation = self.submit()["operation_id"]
        self.assertTrue(bridge.prepare_entered.wait(2))
        self.service.close()
        self.assertTrue(bridge.cancelled)
        with self.assertRaises(LoginError):
            self.submit()
        restored = Logins(self.connector, self.journal,
            Extension(Path(self.temp.name) / "extension", "a" * 32),
            clock=lambda: self.now)
        self.addCleanup(restored.close)
        self.assertEqual(restored.status(operation, CALLER)["phase"], "outcome_unknown")

    def test_owner_thread_close_retires_without_claiming_self_join(self):
        original_request = self.engine.request
        observed, attempted = [], threading.Event()

        def close_before_request(*args, **kwargs):
            try:
                self.service.close()
            except LoginError as error:
                observed.append(str(error))
            finally:
                attempted.set()
            return original_request(*args, **kwargs)

        self.engine.request = close_before_request
        self.submit()
        self.assertTrue(attempted.wait(2))
        self.service.close()
        self.assertEqual(observed, ["outcome_unknown"])
        self.assertFalse(self.service._thread.is_alive())
        self.assertEqual([name for bridge in self.bridges for name, _ in bridge.calls], ["withdraw"])

    def test_background_exception_is_fixed_and_has_no_stderr_traceback(self):
        self.next_bridge.request_failure = True
        output = io.StringIO()
        with redirect_stderr(output):
            operation = self.submit()["operation_id"]

            def failed():
                try:
                    self.service.status(operation, CALLER)
                except LoginError as error:
                    return str(error) == "unavailable"
                return False
            self.wait(failed)
            self.service.close()
        self.assertEqual(output.getvalue(), "")
        restored = Logins(self.connector, self.journal,
            Extension(Path(self.temp.name) / "extension", "a" * 32), clock=lambda: self.now)
        self.addCleanup(restored.close)
        self.assertEqual(restored.status(operation, CALLER)["phase"], "outcome_unknown")


if __name__ == "__main__":
    unittest.main()
