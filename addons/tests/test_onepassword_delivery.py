"""Actual Service, journal and publisher sockets against controlled edges.

The host ACK is fabricated. No OCaml queue, Keeper turn or real account runs.
"""
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "onepassword"))
from login import Extension, Journal, LoginError, Logins, Phase
import oauth
from onepassword_store_fixture import MemoryRecords, active_raw
from oauth import ConnectionError
from service import Service
from test_onepassword_companion import Host
from test_onepassword_login import BROWSER, CALLER, REFERENCE, Bridge, Connector


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        backend = patch.object(oauth, "ProtectedRecords", MemoryRecords)
        backend.start()
        self.addCleanup(backend.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "journal"
        self.journal = Journal(self.directory, provision=True)
        self.bridge, self.now = Bridge(), 1000.
        self.bridge.journal_store = self.journal
        self.engine = Logins(Connector(), self.journal,
            Extension(Path(self.temp.name) / "extension", "a" * 32),
            bridge=lambda _: self.bridge, clock=lambda: self.now)
        self.service = Service(self.engine, clock=lambda: self.now)
        self.uncertain_close = False
        def close():
            if self.uncertain_close:
                with self.assertRaises(LoginError):
                    self.service.close()
            else:
                self.service.close()
        self.addCleanup(close)

    def host(self, handler, **kwargs):
        host = Host(handler, **kwargs)
        host.descriptor["publication_id"] = "b" * 64
        self.addCleanup(host.close)
        return host

    def start(self, host):
        return self.service.submit(descriptor=host.descriptor, caller=CALLER,
            browser_instance_id=BROWSER, tab_id=7, website="https://example.test/login",
            goal="Sign in", reason="Continue original task")["operation_id"]

    def wait(self, predicate):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if result := predicate():
                return result
            time.sleep(.001)
        self.fail("controlled delivery did not reach its expected state")

    def phase(self, operation, expected):
        return self.wait(lambda: self.service.status(operation, CALLER)["phase"] == expected)

    def test_original_caller_acknowledges_attention_fill_and_terminal_after_browser_close(self):
        def handler(host, connection, reader):
            host.read(reader)
            host.write(connection, {"accepted": True})
        host = self.host(handler, max_connections=3)
        operation = self.start(host)
        self.phase(operation, "approval_ready")
        self.wait(lambda: not self.engine.pending_publications(operation, CALLER))
        self.service.opened(operation)
        self.phase(operation, "awaiting_approval")
        self.bridge.responses.append({"state": "resolved", "granted": True, "reference": REFERENCE})
        self.now += 5
        self.service.notify()
        self.phase(operation, "fill_submitted")
        self.wait(lambda: not self.engine.pending_publications(operation, CALLER))
        self.service.finish(operation, CALLER)
        self.phase(operation, "released")
        self.wait(lambda: not self.engine.pending_publications(operation, CALLER))
        self.assertTrue(self.bridge.cancelled)
        self.assertEqual([message["event"]["output"]["phase"] for message in host.messages],
                         ["approval_ready", "fill_submitted", "released"])
        self.assertTrue(all(message["publication_id"] == "b" * 64 for message in host.messages))
        self.assertTrue(all(message["event"]["output"]["operation_id"] == operation for message in host.messages))
        self.assertNotIn("PRIVATE_", json.dumps(host.messages))
        self.assertEqual([kind for kind, _ in self.bridge.calls].count("request"), 1)
        self.assertEqual([kind for kind, _ in self.bridge.calls].count("fill"), 1)

    def test_blocked_publication_ack_does_not_block_cancel_and_close_joins_both_threads(self):
        received = threading.Event()
        def handler(host, connection, reader):
            host.read(reader)
            received.set()
            self.assertEqual(reader.read(1), b"")
        host = self.host(handler)
        operation = self.start(host)
        self.assertTrue(received.wait(2))
        self.assertEqual(self.service.cancel(operation, CALLER),
                         {"operation_id": operation, "cancel_requested": True})
        self.phase(operation, "cancelled")
        self.assertEqual([event["output"]["phase"] for event in self.engine.pending_publications(operation, CALLER)],
                         ["approval_ready", "cancelled"])
        self.service.close()
        self.assertFalse(self.service._thread.is_alive())
        self.assertFalse(self.service._delivery._thread.is_alive())
        self.assertIsNone(self.engine._lease)
        self.assertEqual(host.connections, 1)

    def test_lost_ack_reconciles_same_identity_without_replaying_request(self):
        def handler(host, connection, reader):
            host.read(reader)
            if host.connections == 2:
                host.write(connection, {"accepted": True})
        host = self.host(handler, max_connections=2)
        operation = self.start(host)
        self.phase(operation, "approval_ready")
        self.wait(lambda: not self.engine.pending_publications(operation, CALLER))
        self.assertEqual(host.messages[0], host.messages[1])
        self.assertEqual([kind for kind, _ in self.bridge.calls].count("request"), 1)
        self.assertEqual([kind for kind, _ in self.bridge.calls].count("fill"), 0)
        self.assertEqual(self.service.status(operation, CALLER)["phase"], "approval_ready")

    def test_uncertain_ack_write_fences_cached_next_notice_and_retains_disk_evidence(self):
        received, acknowledge = threading.Event(), threading.Event()
        def handler(host, connection, reader):
            host.read(reader)
            received.set()
            self.assertTrue(acknowledge.wait(2))
            host.write(connection, {"accepted": True})
        host = self.host(handler)
        operation = self.start(host)
        self.assertTrue(received.wait(2))
        self.service.cancel(operation, CALLER)
        self.phase(operation, "cancelled")
        original = self.journal.write
        def uncertain(root, value):
            original(root, value)
            if any(p["host_accepted"] for record in value["operations"] for p in record["publications"]):
                raise ConnectionError("PRIVATE_ACK_WRITE_UNCERTAINTY")
        with patch.object(self.journal, "write", side_effect=uncertain):
            acknowledge.set()
            self.wait(lambda: self.engine._storage_failed)
            self.uncertain_close = True
            with self.assertRaises(LoginError):
                self.service.close()
        retained = json.loads(active_raw(self.journal))["operations"][0]
        self.assertEqual([p["host_accepted"] for p in retained["publications"]], [True, False])
        self.assertEqual(host.connections, 1)
        self.assertFalse(self.service._delivery._thread.is_alive())
        self.assertIsNone(self.engine._lease)

    def test_unrouted_status_flow_and_refused_second_service_preserve_original_owner(self):
        host = self.host(lambda *_: None, max_connections=0)
        host.descriptor["publication_id"] = None
        operation = self.start(host)
        self.phase(operation, "approval_ready")
        with self.assertRaises(LoginError):
            Service(self.engine, clock=lambda: self.now)
        self.assertIsNotNone(self.engine._lease)
        self.assertEqual(self.service.status(operation, CALLER)["phase"], "approval_ready")
        self.service.cancel(operation, CALLER)
        self.phase(operation, "cancelled")
        self.assertEqual(host.connections, 0)
        self.assertTrue(self.engine.pending_publications(operation, CALLER))

    def test_terminal_commit_after_empty_snapshot_keeps_its_original_publisher(self):
        empty, resume = threading.Event(), threading.Event()
        gated = threading.Event()
        original = self.engine.publication_snapshot
        def snapshot(operation, caller):
            value = original(operation, caller)
            if value.phase is Phase.APPROVAL_READY and not value.pending and not gated.is_set():
                gated.set()
                empty.set()
                self.assertTrue(resume.wait(2))
            return value
        def handler(host, connection, reader):
            host.read(reader)
            host.write(connection, {"accepted": True})
        host = self.host(handler, max_connections=2)
        with patch.object(self.engine, "publication_snapshot", side_effect=snapshot):
            operation = self.start(host)
            try:
                self.assertTrue(empty.wait(2))
                self.service.cancel(operation, CALLER)
                self.phase(operation, "cancelled")
            finally:
                resume.set()
            self.wait(lambda: not self.engine.pending_publications(operation, CALLER))
        self.assertEqual([message["event"]["output"]["phase"] for message in host.messages],
                         ["approval_ready", "cancelled"])
