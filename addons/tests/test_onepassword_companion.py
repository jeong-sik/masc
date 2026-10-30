"""Actual private Python bridge over Unix sockets, with a fabricated host.

This exercises framing/serialization/cancellation, not the OCaml host server,
installed Browser worker, real 1Password extension or a personal account.
"""
import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "onepassword" / "companion.py"
SPEC = importlib.util.spec_from_file_location("onepassword_companion_fixture", MODULE)
bridge = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bridge
SPEC.loader.exec_module(bridge)
INSTANCE = "0b000000-0000-4000-8000-000000000021"
OPERATION = "0b000000-0000-4000-8000-000000000022"
WITHDRAW = {"invocation_id": "a" * 64, "withdraw": True}


class Host:
    def __init__(self, handler, maximum=16384, max_connections=1):
        # Keep Unix socket names below the OS path bound in this fixture.
        self.directory = tempfile.TemporaryDirectory(prefix="opc-", dir="/tmp")
        self.path = str(Path(self.directory.name).resolve() / "s")
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(1)
        self.listener.settimeout(2)
        self.descriptor = {"socket_path": self.path, "invocation_id": "a" * 64,
                           "max_message_bytes": maximum, "publication_id": None}
        self.messages, self.errors = [], []
        self.connections = 0

        def run():
            try:
                for _ in range(max_connections):
                    connection, _ = self.listener.accept()
                    self.connections += 1
                    connection.settimeout(2)
                    with connection, connection.makefile("rb") as reader:
                        handler(self, connection, reader)
            except Exception as error:
                self.errors.append(error)
        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def read(self, reader):
        value = json.loads(reader.readline())
        self.messages.append(value)
        return value

    def bind(self, connection, reader):
        self.read(reader)
        self.write(connection, {"bound": True, "operation_id": OPERATION})

    def write(self, connection, value):
        connection.sendall(json.dumps(value).encode() + b"\n")

    def close(self):
        self.listener.close()
        self.thread.join(3)
        self.directory.cleanup()
        if self.thread.is_alive():
            raise AssertionError("private socket fixture did not join")
        if self.errors:
            raise self.errors[0]


class CompanionTests(unittest.TestCase):
    def host(self, handler, **kwargs):
        host = Host(handler, **kwargs)
        self.addCleanup(host.close)
        return host

    def connect(self, host):
        client = bridge.Companion(host.descriptor)
        self.addCleanup(client.cancel)
        client.bind(browser_instance_id=INSTANCE, tab_id=7)
        return client

    def test_actual_socket_prepare_invoke_release_retains_one_binding(self):
        def handler(host, connection, reader):
            host.bind(connection, reader)
            host.read(reader); host.write(connection, {"value": {"prepared": True}})
            host.read(reader); host.write(connection, {"value": {"status": "fill_submitted"}})
            host.read(reader); host.write(connection, {"value": {"released": True}})
        host = self.host(handler)
        client = self.connect(host)
        with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
            client.bind(browser_instance_id="0b000000-0000-4000-8000-000000000023", tab_id=8)
        client.prepare(extension_id="a" * 32, directory="/private/vendor-extension",
                       program="async()=>({ready:true})", arguments={})
        result = client.invoke(program="async context=>context.arguments", arguments={"access_token": "PRIVATE_TOKEN_MARKER"})
        self.assertEqual(result, {"status": "fill_submitted"})
        client.release()
        host.thread.join(2)
        self.assertEqual(host.connections, 1)
        self.assertEqual(host.messages[0], {"invocation_id": "a" * 64, "browser_instance_id": INSTANCE, "tab_id": 7})
        self.assertEqual(client.operation_id, OPERATION)
        self.assertEqual([message["operation_id"] for message in host.messages[1:]], [OPERATION] * 3)
        self.assertEqual(host.messages[1]["tab_id"], 7)
        self.assertNotIn("PRIVATE_TOKEN_MARKER", json.dumps(result))

    def test_departed_host_is_unknown_and_original_call_is_never_replayed(self):
        def handler(host, connection, reader):
            host.bind(connection, reader)
            host.read(reader)
        host = self.host(handler)
        client = self.connect(host)
        with self.assertRaisesRegex(bridge.BridgeError, "^outcome_unknown$"):
            client.invoke(program="async()=>({})", arguments={})
        with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
            client.invoke(program="async()=>({})", arguments={})
        self.assertEqual(host.connections, 1)
        self.assertEqual(len(host.messages), 2)

    def test_malformed_duplicate_nonfinite_and_extra_private_replies_are_erased(self):
        for raw in [b'{"value":{"token":"PRIVATE_TOKEN_MARKER',
                    b'{"value":{},"value":{"token":"PRIVATE_TOKEN_MARKER"}}',
                    b'{"value":{"number":NaN}}',
                    b'{"value":{"number":1e999}}',
                    b'{"value":{"number":-1e999}}',
                    b'{"error":"not_started","message":"PRIVATE_TOKEN_MARKER"}',
                    b'{"error":"PRIVATE_TOKEN_MARKER"}']:
            with self.subTest(raw=raw):
                def handler(host, connection, reader):
                    host.bind(connection, reader)
                    host.read(reader); connection.sendall(raw + b"\n")
                host = self.host(handler)
                client = self.connect(host)
                with self.assertRaises(bridge.BridgeError) as caught:
                    client.invoke(program="async()=>({})", arguments={})
                self.assertEqual(str(caught.exception), "outcome_unknown")
                self.assertNotIn("PRIVATE_TOKEN_MARKER", repr(caught.exception))

    def test_cancel_interrupts_blocked_receive_without_taking_the_io_lock(self):
        entered = threading.Event()
        departed = threading.Event()
        def handler(host, connection, reader):
            host.bind(connection, reader)
            host.read(reader); entered.set()
            self.assertEqual(reader.read(1), b"")
            departed.set()
        host = self.host(handler)
        client = self.connect(host)
        outcome = []
        def invoke():
            try:
                client.invoke(program="async()=>({})", arguments={})
            except bridge.BridgeError as error:
                outcome.append(error.code)
        waiter = threading.Thread(target=invoke, daemon=True)
        waiter.start()
        self.assertTrue(entered.wait(2))
        client.cancel()
        waiter.join(2)
        self.assertFalse(waiter.is_alive())
        self.assertEqual(outcome, ["outcome_unknown"])
        self.assertTrue(departed.wait(2))

    def test_handle_cancel_interrupts_held_initial_bind_and_never_reconnects(self):
        entered, departed = threading.Event(), threading.Event()

        def handler(host, connection, reader):
            host.read(reader)
            entered.set()
            # Hold the initial bound response: the job must already have its
            # handle and be able to cancel this original invocation socket.
            self.assertEqual(reader.read(1), b"")
            departed.set()

        host = self.host(handler)
        client = bridge.Companion(host.descriptor)
        self.addCleanup(client.cancel)
        self.assertEqual(host.connections, 0)
        self.assertIsNone(client.operation_id)
        with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
            client.invoke(program="async()=>({})", arguments={})
        outcome = []

        def bind():
            try:
                client.bind(browser_instance_id=INSTANCE, tab_id=7)
            except bridge.BridgeError as error:
                outcome.append(error.code)

        waiter = threading.Thread(target=bind, daemon=True)
        waiter.start()
        self.assertTrue(entered.wait(2))
        self.assertTrue(waiter.is_alive())
        # A second binder cannot create a second connection or alter the tab
        # while the original handshake is waiting.
        with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
            client.bind(browser_instance_id=INSTANCE, tab_id=8)
        client.cancel()
        waiter.join(2)
        self.assertFalse(waiter.is_alive())
        self.assertEqual(outcome, ["outcome_unknown"])
        self.assertTrue(departed.wait(2))
        self.assertIsNone(client.operation_id)
        with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
            client.bind(browser_instance_id=INSTANCE, tab_id=7)
        with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
            client.invoke(program="async()=>({})", arguments={})
        self.assertEqual(host.connections, 1)
        self.assertEqual(host.messages, [{"invocation_id": "a" * 64, "browser_instance_id": INSTANCE, "tab_id": 7}])

    def test_cancel_before_bind_is_terminal_and_sends_nothing(self):
        with tempfile.TemporaryDirectory(prefix="opc-unbound-", dir="/tmp") as directory:
            path = str(Path(directory).resolve() / "s")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(path)
                listener.listen(1)
                listener.setblocking(False)
                client = bridge.Companion({"socket_path": path, "invocation_id": "c" * 64,
                                           "max_message_bytes": 4096, "publication_id": None})
                self.addCleanup(client.cancel)
                client.cancel()
                for _ in range(2):
                    with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
                        client.bind(browser_instance_id=INSTANCE, tab_id=7)
                with self.assertRaises(BlockingIOError):
                    listener.accept()
                self.assertIsNone(client.operation_id)

    def test_unbound_withdrawal_disposes_only_original_nonce_and_caches_success(self):
        def handler(host, connection, reader):
            self.assertEqual(host.read(reader), WITHDRAW)
            host.write(connection, {"withdrawn": True})

        host = self.host(handler)
        client = bridge.Companion(host.descriptor)
        self.addCleanup(client.close)
        self.assertIsNone(client.withdraw())
        host.thread.join(2)
        self.assertFalse(host.thread.is_alive())
        self.assertIsNone(client.operation_id)
        self.assertEqual(host.messages, [WITHDRAW])
        self.assertEqual(host.connections, 1)
        with patch.object(bridge.socket, "socket", side_effect=AssertionError("cached withdrawal created a socket")):
            self.assertIsNone(client.withdraw())
            client.close()
            client.cancel()
            self.assertIsNone(client.withdraw())
            with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
                client.bind(browser_instance_id=INSTANCE, tab_id=7)

    def test_withdrawal_closes_original_bound_socket_before_credentialless_control(self):
        departed = threading.Event()

        def handler(host, connection, reader):
            if host.connections == 1:
                host.bind(connection, reader)
                self.assertEqual(reader.read(1), b"")
                departed.set()
            else:
                self.assertTrue(departed.is_set())
                self.assertEqual(host.read(reader), WITHDRAW)
                host.write(connection, {"withdrawn": True})

        host = self.host(handler, max_connections=2)
        client = self.connect(host)
        self.addCleanup(client.close)
        client.withdraw()
        host.thread.join(2)
        self.assertEqual(host.connections, 2)
        self.assertEqual(len(host.messages), 2)
        self.assertEqual(host.messages[1], WITHDRAW)
        self.assertEqual(client.operation_id, OPERATION)
        with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
            client.invoke(program="async()=>({})", arguments={})

    def test_unknown_withdrawal_can_be_explicitly_retried_without_replaying_bind(self):
        def handler(host, connection, reader):
            self.assertEqual(host.read(reader), WITHDRAW)
            host.write(connection, {"withdrawn": host.connections == 2})

        host = self.host(handler, max_connections=2)
        client = bridge.Companion(host.descriptor)
        self.addCleanup(client.close)
        with self.assertRaisesRegex(bridge.BridgeError, "^outcome_unknown$"):
            client.withdraw()
        self.assertEqual(host.connections, 1)
        with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
            client.bind(browser_instance_id=INSTANCE, tab_id=7)
        client.withdraw()
        host.thread.join(2)
        self.assertEqual(host.connections, 2)
        self.assertEqual(host.messages, [WITHDRAW, WITHDRAW])
        self.assertIsNone(client.operation_id)

    def test_withdrawal_acknowledgement_is_exact_finite_and_boolean(self):
        for raw in [b'{"withdrawn":1}', b'{"withdrawn":1.0}', b'{"withdrawn":false}',
                    b'{"withdrawn":"true"}', b'{"withdrawn":true,"token":"PRIVATE_TOKEN_MARKER"}',
                    b'{"withdrawn":true,"withdrawn":true}', b'{"withdrawn":1e999}',
                    b'{"withdrawn":-1e999}', b'{"error":"PRIVATE_PROVIDER_MARKER"}']:
            with self.subTest(raw=raw):
                def handler(host, connection, reader):
                    self.assertEqual(host.read(reader), WITHDRAW)
                    connection.sendall(raw + b"\n")

                host = self.host(handler)
                client = bridge.Companion(host.descriptor)
                self.addCleanup(client.close)
                with self.assertRaises(bridge.BridgeError) as caught:
                    client.withdraw()
                self.assertEqual(str(caught.exception), "outcome_unknown")
                self.assertNotIn("PRIVATE_", repr(caught.exception))
                self.assertEqual(host.connections, 1)

    def test_cancel_interrupts_withdrawal_and_explicit_cleanup_can_retry(self):
        entered, departed = threading.Event(), threading.Event()

        def handler(host, connection, reader):
            self.assertEqual(host.read(reader), WITHDRAW)
            if host.connections == 1:
                entered.set()
                self.assertEqual(reader.read(1), b"")
                departed.set()
            else:
                host.write(connection, {"withdrawn": True})

        host = self.host(handler, max_connections=2)
        client = bridge.Companion(host.descriptor)
        self.addCleanup(client.close)
        outcomes = []

        def withdraw():
            try:
                client.withdraw()
            except bridge.BridgeError as error:
                outcomes.append(error.code)

        waiter = threading.Thread(target=withdraw, daemon=True)
        waiter.start()
        self.assertTrue(entered.wait(2))
        client.cancel()
        waiter.join(2)
        self.assertFalse(waiter.is_alive())
        self.assertEqual(outcomes, ["outcome_unknown"])
        self.assertTrue(departed.wait(2))
        client.withdraw()
        host.thread.join(2)
        self.assertEqual(host.messages, [WITHDRAW, WITHDRAW])

    def test_close_interrupts_withdrawal_and_permanently_seals_both_admissions(self):
        entered, departed = threading.Event(), threading.Event()

        def handler(host, connection, reader):
            self.assertEqual(host.read(reader), WITHDRAW)
            entered.set()
            self.assertEqual(reader.read(1), b"")
            departed.set()

        host = self.host(handler)
        client = bridge.Companion(host.descriptor)
        self.addCleanup(client.close)
        outcomes = []

        def withdraw():
            try:
                client.withdraw()
            except bridge.BridgeError as error:
                outcomes.append(error.code)

        waiter = threading.Thread(target=withdraw, daemon=True)
        waiter.start()
        self.assertTrue(entered.wait(2))
        client.close()
        waiter.join(2)
        self.assertFalse(waiter.is_alive())
        self.assertTrue(departed.wait(2))
        self.assertEqual(outcomes, ["outcome_unknown"])
        with patch.object(bridge.socket, "socket", side_effect=AssertionError("sealed handle created a socket")):
            client.cancel()
            with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
                client.withdraw()
            with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
                client.bind(browser_instance_id=INSTANCE, tab_id=7)

    def test_close_before_withdrawal_registration_creates_no_new_socket(self):
        with tempfile.TemporaryDirectory(prefix="opc-seal-", dir="/tmp") as directory:
            path = str(Path(directory).resolve() / "s")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(path)
                listener.listen(1)
                listener.setblocking(False)
                client = bridge.Companion({"socket_path": path, "invocation_id": "d" * 64,
                                           "max_message_bytes": 4096, "publication_id": None})
                self.addCleanup(client.close)
                entered, proceed = threading.Event(), threading.Event()
                cancel_original = client.interrupt

                def paused_original_cleanup():
                    cancel_original()
                    entered.set()
                    proceed.wait()

                client.interrupt = paused_original_cleanup
                outcomes, failures = [], []

                def withdraw():
                    try:
                        client.withdraw()
                    except bridge.BridgeError as error:
                        outcomes.append(error.code)
                    except BaseException as failure:
                        failures.append(failure)

                waiter = threading.Thread(target=withdraw, daemon=True)
                waiter.start()
                try:
                    self.assertTrue(entered.wait(2))
                    client.close()
                    with patch.object(bridge.socket, "socket", side_effect=AssertionError("post-close socket creation")):
                        proceed.set()
                        waiter.join(2)
                    self.assertFalse(waiter.is_alive())
                    self.assertEqual(failures, [])
                    self.assertEqual(outcomes, ["not_started"])
                    with self.assertRaises(BlockingIOError):
                        listener.accept()
                finally:
                    proceed.set()
                    waiter.join(2)

    def test_original_call_late_error_cannot_interrupt_credentialless_disposal(self):
        invoke_entered, withdrawal_entered, allow_ack = (
            threading.Event(), threading.Event(), threading.Event())
        error_entered, allow_error = threading.Event(), threading.Event()

        def handler(host, connection, reader):
            if host.connections == 1:
                host.bind(connection, reader)
                host.read(reader)
                invoke_entered.set()
                self.assertEqual(reader.read(1), b"")
            else:
                self.assertEqual(host.read(reader), WITHDRAW)
                withdrawal_entered.set()
                self.assertTrue(allow_ack.wait(2))
                host.write(connection, {"withdrawn": True})

        host = self.host(handler, max_connections=2)
        client = self.connect(host)
        self.addCleanup(client.close)
        cancel_original = client.interrupt

        def delayed_original_error():
            if threading.current_thread().name == "original-invoke-fixture":
                error_entered.set()
                allow_error.wait()
            cancel_original()

        client.interrupt = delayed_original_error
        invoke_outcomes, withdrawal_outcomes = [], []

        def invoke():
            try:
                client.invoke(program="async()=>({})", arguments={})
            except bridge.BridgeError as error:
                invoke_outcomes.append(error.code)

        def withdraw():
            try:
                withdrawal_outcomes.append(client.withdraw())
            except bridge.BridgeError as error:
                withdrawal_outcomes.append(error.code)

        caller = threading.Thread(target=invoke, name="original-invoke-fixture", daemon=True)
        cleanup = threading.Thread(target=withdraw, daemon=True)
        caller.start()
        try:
            self.assertTrue(invoke_entered.wait(2))
            cleanup.start()
            self.assertTrue(error_entered.wait(2))
            self.assertTrue(withdrawal_entered.wait(2))
            allow_error.set()
            caller.join(2)
            self.assertEqual(invoke_outcomes, ["outcome_unknown"])
            self.assertTrue(cleanup.is_alive())
            allow_ack.set()
            cleanup.join(2)
            self.assertFalse(cleanup.is_alive())
            self.assertEqual(withdrawal_outcomes, [None])
            self.assertEqual(host.connections, 2)
        finally:
            allow_error.set()
            allow_ack.set()
            client.close()
            caller.join(2)
            if cleanup.ident is not None:
                cleanup.join(2)

    def test_invalid_or_oversized_arguments_send_no_private_command(self):
        def handler(host, connection, reader):
            host.bind(connection, reader)
            host.read(reader); host.write(connection, {"value": {"released": True}})
        host = self.host(handler, maximum=256)
        client = self.connect(host)
        cyclic = {}; cyclic["cycle"] = cyclic
        for arguments in [cyclic, {"number": float("nan")}, {"text": "x" * 256}]:
            with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
                client.invoke(program="async()=>({})", arguments=arguments)
        client.release()
        self.assertEqual([message.get("kind") for message in host.messages[1:]], ["release"])

    def test_boolean_success_is_strict(self):
        def handler(host, connection, reader):
            host.bind(connection, reader)
            host.read(reader); host.write(connection, {"value": {"prepared": 1}})
        host = self.host(handler)
        client = self.connect(host)
        with self.assertRaisesRegex(bridge.BridgeError, "^outcome_unknown$"):
            client.prepare(extension_id="a" * 32, directory="/private/vendor-extension",
                           program="async()=>({ready:true})", arguments={})

    def test_endpoint_checks_private_parent_without_exposing_capability(self):
        with tempfile.TemporaryDirectory(prefix="opc-perm-", dir="/tmp") as directory:
            path = str(Path(directory).resolve() / "s")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(path)
                descriptor = {"socket_path": path, "invocation_id": "b" * 64, "max_message_bytes": 4096, "publication_id": None}
                endpoint = bridge.Endpoint.decode(descriptor)
                self.assertNotIn("b" * 64, repr(endpoint))
                os.chmod(directory, 0o755)
                with self.assertRaisesRegex(bridge.BridgeError, "^unavailable$"):
                    bridge.Endpoint.decode(descriptor)
                os.chmod(directory, 0o700)


if __name__ == "__main__":
    unittest.main()
