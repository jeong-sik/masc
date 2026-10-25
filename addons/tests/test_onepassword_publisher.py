"""Actual publisher sockets and disposal, against a controlled host.

No real 1Password account, OCaml broker or Keeper turn is exercised here.
"""
import copy
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest.mock import patch

from test_onepassword_companion import Host, INSTANCE, bridge


EVENT = {"publication_id": "0b000000-0000-4000-8000-000000000031", "kind": "terminal",
         "output": {"operation_id": "0b000000-0000-4000-8000-000000000032",
                    "phase": "released", "fill_submitted": True, "website_login_verified": False}}


class PublisherTests(unittest.TestCase):
    def host(self, handler, **kwargs):
        host = Host(handler, **kwargs)
        host.descriptor["publication_id"] = "b" * 64
        self.addCleanup(host.close)
        return host

    def publisher(self, host):
        publisher = bridge.Publisher(host.descriptor)
        self.addCleanup(publisher.close)
        return publisher

    def test_terminal_publication_survives_original_browser_release_and_close(self):
        def handler(host, connection, reader):
            if host.connections == 1:
                host.bind(connection, reader)
                host.read(reader)
                host.write(connection, {"value": {"released": True}})
            else:
                host.read(reader)
                host.write(connection, {"accepted": True})
        host = self.host(handler, max_connections=2)
        publisher = self.publisher(host)
        browser = bridge.Companion(host.descriptor)
        self.addCleanup(browser.close)
        browser.bind(browser_instance_id=INSTANCE, tab_id=7)
        browser.release()
        browser.close()
        publisher.publish(EVENT)
        self.assertEqual(host.messages[-1], {"publication_id": "b" * 64, "event": EVENT})
        self.assertEqual(host.connections, 2)

    def test_lost_ack_leaves_same_event_for_explicit_reconciliation(self):
        def handler(host, connection, reader):
            host.read(reader)
            if host.connections == 2:
                host.write(connection, {"accepted": True})
        host = self.host(handler, max_connections=2)
        publisher = self.publisher(host)
        event = copy.deepcopy(EVENT)
        with self.assertRaises(bridge.BridgeError):
            publisher.publish(event)
        self.assertEqual(host.connections, 1)
        self.assertEqual(event, EVENT)
        publisher.publish(event)
        self.assertEqual(host.messages, [{"publication_id": "b" * 64, "event": EVENT}] * 2)

    def test_close_interrupts_blocked_ack_and_permanently_seals_admission(self):
        received = threading.Event()
        errors = []
        def handler(host, connection, reader):
            host.read(reader)
            received.set()
            self.assertEqual(reader.read(1), b"")
        host = self.host(handler)
        publisher = self.publisher(host)
        def send():
            try:
                publisher.publish(EVENT)
            except bridge.BridgeError as error:
                errors.append(error.code)
        thread = threading.Thread(target=send)
        thread.start()
        self.assertTrue(received.wait(2))
        publisher.close()
        thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, ["outcome_unknown"])
        with self.assertRaises(bridge.BridgeError):
            publisher.publish(EVENT)
        self.assertEqual(host.connections, 1)

    def test_replaced_socket_is_refused_before_sending_original_nonce(self):
        with tempfile.TemporaryDirectory(prefix="opp-", dir="/tmp") as directory:
            path = str(Path(directory).resolve() / "s")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as original:
                original.bind(path)
                original.listen(1)
                publisher = bridge.Publisher({"socket_path": path, "invocation_id": "a" * 64,
                    "publication_id": "b" * 64, "max_message_bytes": 16384})
                self.addCleanup(publisher.close)
                os.unlink(path)
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as replacement:
                    replacement.bind(path)
                    replacement.listen(1)
                    with self.assertRaises(bridge.BridgeError):
                        publisher.publish(EVENT)
                    replacement.settimeout(.02)
                    with self.assertRaises(TimeoutError):
                        replacement.accept()

    def test_explicit_unrouted_descriptor_has_no_publisher(self):
        with tempfile.TemporaryDirectory(prefix="opp-", dir="/tmp") as directory:
            path = str(Path(directory).resolve() / "s")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(path)
                listener.listen(1)
                with self.assertRaises(bridge.BridgeError):
                    bridge.Publisher({"socket_path": path, "invocation_id": "a" * 64,
                        "publication_id": None, "max_message_bytes": 16384})

    def test_close_after_actual_ack_read_cannot_return_late_success(self):
        acknowledged, resume = threading.Event(), threading.Event()
        errors = []
        def handler(host, connection, reader):
            host.read(reader)
            host.write(connection, {"accepted": True})
        host = self.host(handler)
        publisher = self.publisher(host)
        roundtrip = publisher._roundtrip
        def gated(flow, raw):
            reply = roundtrip(flow, raw)
            acknowledged.set()
            self.assertTrue(resume.wait(2))
            return reply
        def send():
            try:
                publisher.publish(EVENT)
            except bridge.BridgeError as error:
                errors.append(error.code)
        with patch.object(publisher, "_roundtrip", side_effect=gated):
            thread = threading.Thread(target=send)
            thread.start()
            try:
                self.assertTrue(acknowledged.wait(2))
                publisher.close()
            finally:
                resume.set()
                thread.join(2)
            self.assertFalse(thread.is_alive())
        self.assertEqual(errors, ["outcome_unknown"])

    def test_malformed_and_deep_actual_replies_keep_fixed_failure_boundary(self):
        for reply in [b'{broken\n', b'[' * 1100 + b'0' + b']' * 1100 + b'\n']:
            with self.subTest(reply_bytes=len(reply)):
                def handler(host, connection, reader):
                    host.read(reader)
                    connection.sendall(reply)
                host = self.host(handler)
                publisher = self.publisher(host)
                with self.assertRaises(bridge.BridgeError) as raised:
                    publisher.publish(EVENT)
                self.assertEqual(raised.exception.code, "outcome_unknown")
