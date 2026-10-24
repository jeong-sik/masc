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

MODULE = Path(__file__).resolve().parents[1] / "onepassword" / "companion.py"
SPEC = importlib.util.spec_from_file_location("onepassword_companion_fixture", MODULE)
bridge = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bridge
SPEC.loader.exec_module(bridge)
INSTANCE = "0b000000-0000-4000-8000-000000000021"
OPERATION = "0b000000-0000-4000-8000-000000000022"


class Host:
    def __init__(self, handler, maximum=16384):
        # Keep Unix socket names below the OS path bound in this fixture.
        self.directory = tempfile.TemporaryDirectory(prefix="opc-", dir="/tmp")
        self.path = str(Path(self.directory.name).resolve() / "s")
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(1)
        self.listener.settimeout(2)
        self.descriptor = {"socket_path": self.path, "invocation_id": "a" * 64,
                           "max_message_bytes": maximum}
        self.messages, self.errors = [], []
        self.connections = 0

        def run():
            try:
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
                                           "max_message_bytes": 4096})
                self.addCleanup(client.cancel)
                client.cancel()
                for _ in range(2):
                    with self.assertRaisesRegex(bridge.BridgeError, "^not_started$"):
                        client.bind(browser_instance_id=INSTANCE, tab_id=7)
                with self.assertRaises(BlockingIOError):
                    listener.accept()
                self.assertIsNone(client.operation_id)

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
                descriptor = {"socket_path": path, "invocation_id": "b" * 64, "max_message_bytes": 4096}
                endpoint = bridge.Endpoint.decode(descriptor)
                self.assertNotIn("b" * 64, repr(endpoint))
                os.chmod(directory, 0o755)
                with self.assertRaisesRegex(bridge.BridgeError, "^unavailable$"):
                    bridge.Endpoint.decode(descriptor)
                os.chmod(directory, 0o700)


if __name__ == "__main__":
    unittest.main()
