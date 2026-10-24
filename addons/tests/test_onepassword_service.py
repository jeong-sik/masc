"""Actual owned service thread and durable engine, with fabricated private edges."""
from contextlib import redirect_stderr
import io
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "onepassword"))
from login import Extension, Journal, LoginError, Logins
from service import Service
from test_onepassword_login import APP_LINK, BROWSER, CALLER, REFERENCE, Bridge, Connector


class GatedBridge(Bridge):
    def __init__(self):
        super().__init__()
        self.prepare_entered = threading.Event()
        self.prepare_return = None
        self.request_failure = False

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


class ServiceTests(unittest.TestCase):
    def setUp(self):
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
        self.service = Service(self.engine, clock=lambda: self.now)
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
