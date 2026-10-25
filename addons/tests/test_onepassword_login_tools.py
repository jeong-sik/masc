"""Public/private worker docking with a real service and journal, fake Browser/1P."""
from dataclasses import replace
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "onepassword"))
import server
import oauth
from onepassword_store_fixture import MemoryRecords
from companion import BridgeError
from login import Extension, Logins
from service import Service
from test_onepassword_login import APP_LINK, BROWSER, CALLER, REFERENCE, Bridge, Connector


class LoginToolTests(unittest.TestCase):
    def setUp(self):
        backend = patch.object(oauth, "ProtectedRecords", MemoryRecords)
        backend.start()
        self.addCleanup(backend.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.now = 1000.
        self.bridge = Bridge()
        self.connector = Connector()
        self.connector.status = lambda **kwargs: {"phase": "connected", "connected": True}
        self.connector.store = type("Store", (), {"directory": self.root})()
        self.settings = server.Settings(self.connector, "original-settings",
                                        Extension(self.root / "extension", "a" * 32))
        self.loader = patch.object(server, "load_settings", side_effect=lambda *a, **kw: self.settings)
        self.loader.start()
        self.addCleanup(self.loader.stop)
        self.engine_factory = patch.object(server, "Logins", side_effect=lambda connector, journal, extension:
            Logins(connector, journal, extension, bridge=lambda descriptor: self.bridge, clock=lambda: self.now))
        self.engine_factory.start()
        self.addCleanup(self.engine_factory.stop)
        self.service_factory = patch.object(server, "Service", side_effect=lambda engine: Service(engine, publisher=lambda _: None, clock=lambda: self.now))
        self.service_factory.start()
        self.addCleanup(self.service_factory.stop)
        self.worker = server.Worker(self.root / "configuration.json")
        self.addCleanup(self.worker.close)
        self.worker.handshake({"version": 3})

    def call(self, tool, arguments=None, *, caller=CALLER, companion=None):
        envelope = {"tool": tool, "arguments": arguments or {}, "caller": caller}
        if companion is not None:
            envelope["companion"] = companion
        return self.worker.admitted(envelope)

    def operator(self, action, operation):
        return self.worker.operator({"action": action, "arguments": {"operation_id": operation}})

    def start(self):
        return self.call("onepassword_login", {"browser_instance_id": BROWSER, "tab_id": 7,
            "website": "https://example.test/login", "goal": "Sign in", "reason": "Continue task"},
            companion={"private": "PRIVATE_CAPABILITY"})

    def phase(self, operation, expected):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            result = self.call("onepassword_login_status", {"operation_id": operation})
            if result["phase"] == expected:
                return result
            time.sleep(.001)
        self.fail("fixture service did not settle")

    def test_original_login_private_approval_multistep_and_release(self):
        self.assertTrue(self.worker.status()["browser_login_available"])
        preparing = self.start()
        self.assertEqual(preparing["phase"], "preparing")
        operation = preparing["operation_id"]
        ready = self.phase(operation, "approval_ready")
        opened = self.operator("login_approval", operation)
        self.assertEqual(opened["open_url"], APP_LINK)
        self.assertEqual(self.call("onepassword_login_status", {"operation_id": operation}), ready)
        self.assertNotIn("open_url", self.operator("login_opened", operation))
        self.phase(operation, "awaiting_approval")
        self.bridge.responses.append({"state": "resolved", "granted": True, "reference": REFERENCE})
        self.now += 5
        self.worker.service().notify()
        filled = self.phase(operation, "fill_submitted")
        self.assertTrue(filled["fill_submitted"])
        self.assertFalse(filled["website_login_verified"])
        self.assertEqual(self.call("onepassword_fill_next", {"operation_id": operation})["phase"], "filling")
        self.phase(operation, "fill_submitted")
        self.assertEqual(self.call("onepassword_finish", {"operation_id": operation})["phase"], "settling")
        released = self.phase(operation, "released")
        self.assertFalse(released["website_login_verified"])
        public = self.call("onepassword_logins")
        self.assertEqual(public, {"operations": [released]})
        self.assertNotIn("PRIVATE_", json.dumps(public))
        self.assertEqual(len([1 for name, _ in self.bridge.calls if name == "bind"]), 1)
        self.assertEqual(len([1 for name, _ in self.bridge.calls if name == "fill"]), 2)

    def test_foreign_caller_and_forged_host_context_cannot_reuse_original_grant(self):
        operation = self.start()["operation_id"]
        self.phase(operation, "approval_ready")
        foreign = {"kind": "keeper", "name": "other"}
        self.assertEqual(self.call("onepassword_logins", caller=foreign), {"operations": []})
        for tool in ["onepassword_login_status", "onepassword_fill_next", "onepassword_finish", "onepassword_cancel"]:
            with self.assertRaises(server.InvalidInput):
                self.call(tool, {"operation_id": operation}, caller=foreign)
            with self.assertRaises(server.InvalidInput):
                self.call(tool, {"operation_id": operation}, companion={"private": "replacement"})
        for tool in ["login_opened", "login_approval", "credentials"]:
            with self.assertRaises(server.InvalidInput):
                self.call(tool, {"operation_id": operation})
        request = self.call("onepassword_cancel", {"operation_id": operation})
        self.assertEqual(request, {"operation_id": operation, "cancel_requested": True})
        self.phase(operation, "cancelled")

    def test_settings_change_retires_owner_without_adopting_new_connection(self):
        operation = self.start()["operation_id"]
        self.phase(operation, "approval_ready")
        self.settings = replace(self.settings, fingerprint="replacement-settings")
        self.assertFalse(self.worker.status()["browser_login_available"])
        with self.assertRaises(server.InvalidInput):
            self.call("onepassword_login_status", {"operation_id": operation})
        self.assertTrue(self.bridge.cancelled)
        self.assertTrue(self.worker._retired)

    def test_missing_negotiation_or_extension_refuses_login_availability(self):
        self.worker._negotiated = False
        self.assertFalse(self.worker.status()["browser_login_available"])
        with self.assertRaises(server.InvalidInput):
            self.start()
        self.worker.handshake({"version": 3})
        self.settings = replace(self.settings, extension=None)
        self.worker._settings_value = None
        self.assertFalse(self.worker.status()["browser_login_available"])
        with self.assertRaises(server.InvalidInput):
            self.start()


class SettingsRetirementTests(unittest.TestCase):
    def setUp(self):
        backend = patch.object(oauth, "ProtectedRecords", MemoryRecords)
        backend.start()
        self.addCleanup(backend.stop)

    """Actual private-file reload and durable service; fabricated Browser/1P."""

    def private_configuration(self, root):
        store = root / "private"
        store.mkdir(mode=0o700)
        secret = root / "client-secret"
        secret.write_text("PRIVATE_CLIENT_SECRET_MARKER\n")
        secret.chmod(0o600)
        configuration = root / "configuration.json"
        configuration.write_text(json.dumps({"client_id": "client", "client_secret_file": str(secret),
            "redirect_uri": "https://masc.example/addons/oauth/callback", "store_directory": str(store),
            "browser_extension": {"directory": str(root / "extension"), "extension_id": "a" * 32}}))
        configuration.chmod(0o600)
        return configuration, secret

    def wait(self, predicate):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.001)
        self.fail("fixture service did not reach the expected state")

    def test_unreadable_settings_interrupt_original_poll_and_permanently_retire_owner(self):
        for target in ["configuration", "secret"]:
            for failure in ["missing", "unsafe", "malformed"]:
                with self.subTest(target=target, failure=failure), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    configuration, secret = self.private_configuration(root)
                    entered, returned, resume = threading.Event(), threading.Event(), threading.Event()

                    class PollBridge(Bridge):
                        def invoke(self, *, program, arguments):
                            if arguments["kind"] != "status":
                                return super().invoke(program=program, arguments=arguments)
                            self.calls.append(("status", arguments))
                            entered.set()
                            try:
                                if not resume.wait(2):
                                    raise AssertionError("fixture original poll was not interrupted")
                                if self.cancelled:
                                    raise BridgeError("PRIVATE_CANCELLED_POLL_MARKER")
                                return {"state": "resolved", "granted": True, "reference": REFERENCE}
                            finally:
                                returned.set()

                        def cancel(self):
                            super().cancel()
                            resume.set()

                    bridge, connector, now = PollBridge(), Connector(), [1000.]
                    connector.status = lambda **kwargs: {"phase": "connected", "connected": True}

                    def make_connector(_configuration, private_store):
                        connector.store = private_store
                        return connector

                    with patch.object(server, "Connector", side_effect=make_connector) as connections, \
                         patch.object(server, "Logins", side_effect=lambda c, journal, extension:
                             Logins(c, journal, extension, bridge=lambda descriptor: bridge, clock=lambda: now[0])), \
                         patch.object(server, "Service", side_effect=lambda engine: Service(engine, publisher=lambda _: None, clock=lambda: now[0])):
                        worker = server.Worker(configuration)
                        worker.handshake({"version": 3})

                        def call(tool, arguments):
                            return worker.admitted({"tool": tool, "arguments": arguments, "caller": CALLER})

                        try:
                            admitted = worker.admitted({"tool": "onepassword_login", "arguments": {
                                "browser_instance_id": BROWSER, "tab_id": 7, "website": "https://example.test/login",
                                "goal": "Sign in", "reason": "Continue task"}, "caller": CALLER,
                                "companion": {"private": "PRIVATE_CAPABILITY"}})
                            operation = admitted["operation_id"]
                            self.wait(lambda: call("onepassword_login_status", {"operation_id": operation})["phase"] == "approval_ready")
                            worker.operator({"action": "login_opened", "arguments": {"operation_id": operation}})
                            self.wait(lambda: call("onepassword_login_status", {"operation_id": operation})["phase"] == "awaiting_approval")
                            original_service = worker.service()
                            now[0] += 5.
                            original_service.notify()
                            self.assertTrue(entered.wait(2))
                            path = configuration if target == "configuration" else secret
                            original = path.read_bytes()
                            if failure == "missing":
                                path.unlink()
                            elif failure == "unsafe":
                                path.chmod(0o644)
                            else:
                                path.write_bytes(b'{"PRIVATE_CONFIG_MARKER":' if target == "configuration" else b"\xffPRIVATE_SECRET_MARKER")

                            if failure == "missing":
                                response = worker.status()
                                self.assertEqual(response, {"phase": "unavailable", "connected": False,
                                                           "browser_login_available": False})
                            elif failure == "unsafe":
                                with self.assertRaisesRegex(server.InvalidInput, "^login operation unavailable$"):
                                    call("onepassword_cancel", {"operation_id": operation})
                            else:
                                response = worker.operator({"action": "login_cancel", "arguments": {"operation_id": operation}})
                                self.assertEqual([action["id"] for action in response["actions"]], ["view"])
                                self.assertNotIn("PRIVATE_", json.dumps(response))
                            self.assertTrue(bridge.cancelled)
                            self.assertTrue(worker._retired)
                            path.write_bytes(original)
                            path.chmod(0o600)
                            loaded = connections.call_count
                            self.assertFalse(worker.status()["browser_login_available"])
                            with self.assertRaisesRegex(server.InvalidInput, "^login operation unavailable$"):
                                call("onepassword_cancel", {"operation_id": operation})
                            self.assertEqual(connections.call_count, loaded)
                            self.assertIs(worker._service_value, original_service)
                            worker.close()
                            self.assertTrue(returned.is_set())
                            self.assertFalse(original_service._thread.is_alive())
                            self.assertIsNone(original_service.engine._lease)
                            self.assertEqual([name for name, _ in bridge.calls].count("withdraw"), 1)
                            self.assertEqual([name for name, _ in bridge.calls].count("fill"), 0)
                            self.assertEqual([name for name, _ in bridge.calls].count("bind"), 1)
                        finally:
                            resume.set()
                            worker.close()

    def _retirement_returns_while_actual_withdrawal_waits(self, *, changed):
        from test_onepassword_companion import Host
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            configuration, secret = self.private_configuration(root)
            withdraw_entered, allow_ack = threading.Event(), threading.Event()
            status_done, close_entered, close_done = threading.Event(), threading.Event(), threading.Event()
            responses, errors = [], []

            def handler(host, connection, reader):
                if host.connections == 1:
                    host.bind(connection, reader)
                    host.read(reader)
                    host.write(connection, {"value": {"prepared": True}})
                    host.read(reader)
                    host.write(connection, {"value": {"request_id": "PRIVATE_REQUEST_ID",
                        "entry_id": "PRIVATE_ENTRY_ID", "app_link": APP_LINK}})
                    self.assertEqual(reader.read(1), b"")
                else:
                    self.assertEqual(host.read(reader),
                        {"invocation_id": host.descriptor["invocation_id"], "withdraw": True})
                    withdraw_entered.set()
                    self.assertTrue(allow_ack.wait(2), "fixture did not release withdrawal acknowledgement")
                    host.write(connection, {"withdrawn": True})

            host = Host(handler, max_connections=2)
            connector = Connector()
            connector.status = lambda **kwargs: {"phase": "connected", "connected": True}

            def make_connector(_configuration, private_store):
                connector.store = private_store
                return connector

            with patch.object(server, "Connector", side_effect=make_connector) as connections, \
                 patch.object(server, "Logins", side_effect=lambda c, journal, extension:
                     Logins(c, journal, extension, clock=lambda: 1000.)), \
                 patch.object(server, "Service", side_effect=lambda engine: Service(engine, publisher=lambda _: None, clock=lambda: 1000.)):
                worker = server.Worker(configuration)
                worker.handshake({"version": 3})
                reader = closer = None
                try:
                    operation = worker.admitted({"tool": "onepassword_login", "arguments": {
                        "browser_instance_id": BROWSER, "tab_id": 7, "website": "https://example.test/login",
                        "goal": "Sign in", "reason": "Continue task"}, "caller": CALLER,
                        "companion": host.descriptor})["operation_id"]
                    self.wait(lambda: worker.admitted({"tool": "onepassword_login_status",
                        "arguments": {"operation_id": operation}, "caller": CALLER})["phase"] == "approval_ready")
                    original_service = worker.service()
                    original = secret.read_bytes()
                    if changed:
                        secret.write_text("PRIVATE_REPLACEMENT_SECRET_MARKER\n")
                    else:
                        secret.unlink()

                    def status():
                        try:
                            responses.append(worker.status())
                        except BaseException as error:
                            errors.append(error)
                        finally:
                            status_done.set()

                    reader = threading.Thread(target=status, daemon=True)
                    reader.start()
                    self.assertTrue(withdraw_entered.wait(2))
                    self.assertTrue(status_done.wait(1), "status waited behind private withdrawal IO")
                    self.assertEqual(errors, [])
                    self.assertEqual(responses, [{"phase": "unavailable", "connected": False,
                                                  "browser_login_available": False}])
                    self.assertTrue(worker._retired)
                    self.assertTrue(original_service._thread.is_alive())
                    with self.assertRaisesRegex(server.InvalidInput, "^login operation unavailable$"):
                        worker.admitted({"tool": "onepassword_cancel", "arguments": {"operation_id": operation}, "caller": CALLER})
                    secret.write_bytes(original)
                    secret.chmod(0o600)
                    loaded = connections.call_count
                    self.assertFalse(worker.status()["browser_login_available"])
                    self.assertEqual(connections.call_count, loaded)

                    def close():
                        close_entered.set()
                        try:
                            worker.close()
                        except BaseException as error:
                            errors.append(error)
                        finally:
                            close_done.set()

                    closer = threading.Thread(target=close, daemon=True)
                    closer.start()
                    self.assertTrue(close_entered.wait(1))
                    self.assertFalse(close_done.is_set())
                    allow_ack.set()
                    self.assertTrue(close_done.wait(2))
                    self.assertEqual(errors, [])
                    self.assertFalse(original_service._thread.is_alive())
                    self.assertIsNone(original_service.engine._lease)
                finally:
                    allow_ack.set()
                    worker.close()
                    if reader is not None:
                        reader.join(2)
                    if closer is not None:
                        closer.join(2)
                    host.close()
                self.assertEqual(host.connections, 2)
                self.assertEqual(len(host.messages), 4)

    def test_missing_secret_retirement_status_returns_before_actual_withdrawal_ack(self):
        self._retirement_returns_while_actual_withdrawal_waits(changed=False)

    def test_changed_fingerprint_retirement_status_returns_before_actual_withdrawal_ack(self):
        self._retirement_returns_while_actual_withdrawal_waits(changed=True)


if __name__ == "__main__":
    unittest.main()
