"""Actual service thread and durable login engine with gated private edges.

Events order confirmation admission against a real rate-limit state update.
This does not run Chrome, the host broker or a personal 1Password account.
"""
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "onepassword"))
import oauth
from onepassword_store_fixture import MemoryRecords
from login import Extension, Journal, Logins
from service import Service, _Kind
from test_onepassword_login import BROWSER, CALLER, Bridge, Connector


class ConfirmationTests(unittest.TestCase):
    def setUp(self):
        backend = patch.object(oauth, "ProtectedRecords", MemoryRecords)
        backend.start()
        self.addCleanup(backend.stop)

    def test_confirmation_retains_intent_when_inflight_check_extends_vendor_floor(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            now = [1000.]
            request_done, opened_done = threading.Event(), threading.Event()
            automatic_entered, automatic_return, automatic_done = (
                threading.Event(), threading.Event(), threading.Event())
            confirmation_captured, enqueue_allowed, confirmation_done = (
                threading.Event(), threading.Event(), threading.Event())
            bridge = Bridge()
            invoke = bridge.invoke
            status_calls = []

            def gated_invoke(*, program, arguments):
                if arguments["kind"] == "status":
                    status_calls.append(now[0])
                    if len(status_calls) == 1:
                        automatic_entered.set()
                        automatic_return.wait()
                return invoke(program=program, arguments=arguments)

            bridge.invoke = gated_invoke
            cancel = bridge.cancel

            def interrupt():
                automatic_return.set()
                cancel()

            bridge.cancel = interrupt
            engine = Logins(Connector(), Journal(root / "logins", provision=True),
                            Extension(root / "extension", "a" * 32),
                            bridge=lambda _descriptor: bridge, clock=lambda: now[0])
            bridge.journal_store = engine.journal
            request, opened, advance = engine.request, engine.opened, engine.advance
            confirmed_calls = []

            def observed_request(*args, **kwargs):
                result = request(*args, **kwargs)
                request_done.set()
                return result

            def observed_opened(*args, **kwargs):
                result = opened(*args, **kwargs)
                opened_done.set()
                return result

            def observed_advance(operation_id, caller, *, user_confirmed=False):
                if user_confirmed:
                    confirmed_calls.append((operation_id, now[0]))
                result = advance(operation_id, caller, user_confirmed=user_confirmed)
                (confirmation_done if user_confirmed else automatic_done).set()
                return result

            engine.request, engine.opened, engine.advance = observed_request, observed_opened, observed_advance
            service = Service(engine, publisher=lambda _: None, clock=lambda: now[0])
            enqueue = service._enqueue
            captured = []

            def gated_enqueue(job, *, due=None):
                if job.kind is _Kind.CONFIRMED and not captured:
                    captured.append((due, job))
                    confirmation_captured.set()
                    enqueue_allowed.wait()
                return enqueue(job, due=due)

            service._enqueue = gated_enqueue
            receipts, failures = [], []
            confirming = None
            try:
                operation = service.submit(descriptor={"private": "PRIVATE_CAPABILITY"}, caller=CALLER,
                    browser_instance_id=BROWSER, tab_id=7, website="https://example.test/login",
                    goal="Sign in", reason="Continue task")["operation_id"]
                self.assertTrue(request_done.wait(2))
                service.opened(operation)
                self.assertTrue(opened_done.wait(2))
                old_due = engine.confirmation_time(operation)
                def confirm():
                    try:
                        receipts.append(service.confirmed(operation))
                    except BaseException as failure:
                        failures.append(failure)

                confirming = threading.Thread(target=confirm, daemon=True)
                confirming.start()
                self.assertTrue(confirmation_captured.wait(2))
                self.assertEqual(captured[0][0], old_due)
                # Keep the automatic job ineligible until the old due is
                # captured, then begin its check at elapsed 119 seconds.
                now[0] = 1119.
                bridge.responses.extend([{"error": "rateLimitExceeded"}, {"state": "pending"}])
                service.notify()
                self.assertTrue(automatic_entered.wait(2))
                self.assertEqual(service.status(operation, CALLER)["phase"], "checking")
                automatic_return.set()
                self.assertTrue(automatic_done.wait(2))
                new_due = engine.confirmation_time(operation)
                self.assertEqual(new_due, 1179.)
                enqueue_allowed.set()
                confirming.join(2)
                self.assertFalse(confirming.is_alive())
                self.assertEqual(failures, [])

                def deferred():
                    return [(due, order, job) for due, order, job in service._jobs
                            if job.kind is _Kind.CONFIRMED and job.operation_id == operation
                            and due == new_due]

                with service._condition:
                    self.assertTrue(service._condition.wait_for(deferred, timeout=2),
                                    "the original confirmation was consumed before its current vendor floor")
                    queued = deferred()
                    self.assertEqual(len(queued), 1)
                    self.assertIs(queued[0][2], captured[0][1])
                    self.assertIn(operation, service._confirmed)
                self.assertEqual(confirmed_calls, [])
                self.assertEqual(status_calls, [1119.])
                # Re-delivery while deferred must keep one original intent.
                service.confirmed(operation)
                with service._condition:
                    self.assertEqual(len(deferred()), 1)
                now[0] = new_due
                service.notify()
                self.assertTrue(confirmation_done.wait(2))
                with service._condition:
                    self.assertTrue(service._condition.wait_for(
                        lambda: operation not in service._confirmed, timeout=2))
                    self.assertEqual(deferred(), [])
                self.assertEqual(confirmed_calls, [(operation, new_due)])
                self.assertEqual(status_calls, [1119., new_due])
                self.assertEqual(service.status(operation, CALLER)["phase"], "waiting_user")
                self.assertEqual(receipts[0]["operation_id"], operation)
            finally:
                enqueue_allowed.set()
                automatic_return.set()
                if confirming is not None:
                    confirming.join(2)
                service.close()


if __name__ == "__main__":
    unittest.main()
