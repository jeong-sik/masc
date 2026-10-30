"""Exercise the native adapter policy with a credential-free Security fixture."""
import contextlib
import ctypes
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "onepassword"))
import oauth
import server


class KeychainPolicyTests(unittest.TestCase):
    def setUp(self):
        self.allowed = True
        self.requires_authentication = False
        self.get_status = self.disable_status = self.restore_status = 0
        self.operations = []
        self.prompts = 0
        self.values = {}
        fixture = self

        def get_allowed(pointer):
            ctypes.cast(pointer, ctypes.POINTER(ctypes.c_ubyte))[0] = int(self.allowed)
            return self.get_status

        def set_allowed(value):
            status = self.restore_status if value else self.disable_status
            if status == 0:
                self.allowed = bool(value)
            return status

        def admission(kind):
            fixture.operations.append((kind, fixture.allowed))
            if fixture.requires_authentication:
                fixture.prompts += int(fixture.allowed)
                # The OS fixture reports where a real interactive operation
                # would wait; it never opens UI or reads an actual credential.
                raise PermissionError("fixture authentication required")

        class Keyring:
            def get_password(self, service, username):
                admission("read")
                return fixture.values.get((service, username))

            def set_password(self, service, username, password):
                admission("write")
                fixture.values[service, username] = password

        module = types.ModuleType("keyring.backends.macOS")
        module.Keyring = Keyring
        module.api = types.SimpleNamespace(OS_status=ctypes.c_int32, _sec=types.SimpleNamespace(
            SecKeychainGetUserInteractionAllowed=Mock(side_effect=get_allowed),
            SecKeychainSetUserInteractionAllowed=Mock(side_effect=set_allowed)))
        self.module = module
        for change in (patch.object(oauth.platform, "system", return_value="Darwin"),
                       patch.dict(sys.modules, {"keyring.backends.macOS": module})):
            change.start()
            self.addCleanup(change.stop)
        oauth.ProtectedRecords._backend_class.cache_clear()
        self.addCleanup(oauth.ProtectedRecords._backend_class.cache_clear)

    def test_status_and_following_rpc_do_not_enter_interactive_keychain(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            connector = oauth.Connector(oauth.Configuration("fixture", "fixture-secret", "https://masc.example/callback"),
                                        oauth.PrivateStore(root / "private", provision=True))
            worker = server.Worker(root / "configuration.json")
            self.requires_authentication = True
            requests = [
                {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
                    "name": "lane_observe", "arguments": {"binding": {"sources": []}, "sources": []}}},
                {"jsonrpc": "2.0", "id": 2, "method": "ping"},
            ]
            stream = types.SimpleNamespace(buffer=io.BytesIO(
                ("\n".join(json.dumps(value) for value in requests) + "\n").encode()))
            output = io.StringIO()
            with patch.object(server, "load_settings", return_value=server.Settings(connector, "fixture", None)), \
                    patch.object(sys, "stdin", stream), contextlib.redirect_stdout(output):
                server.serve(worker)
            responses = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual([value["id"] for value in responses], [1, 2])
            self.assertEqual(responses[0]["result"]["structuredContent"]["rows"][0]["fields"]["phase"], "unavailable")
            self.assertEqual(responses[1]["result"], {})
            self.assertEqual(self.prompts, 0)
            self.assertTrue(self.allowed)

    def test_read_and_write_suppress_ui_and_restore_the_original_policy(self):
        records = oauth.ProtectedRecords("policy-fixture")
        records.write(0, "protected-fixture")
        self.assertEqual(records.read(0), "protected-fixture")
        self.assertEqual(self.operations, [("write", False), ("read", False)])
        self.assertTrue(self.allowed)
        self.allowed = False
        self.assertEqual(records.read(0), "protected-fixture")
        self.assertFalse(self.allowed)

    def test_native_policy_failures_are_unavailable_before_record_access(self):
        for field in ("get_status", "disable_status"):
            with self.subTest(field=field):
                self.operations.clear()
                setattr(self, field, -50)
                try:
                    with self.assertRaisesRegex(oauth.ConnectionError, "^protected_store_unavailable$"):
                        oauth.ProtectedRecords("policy-fixture").read(0)
                    self.assertEqual(self.operations, [])
                    self.assertTrue(self.allowed)
                finally:
                    setattr(self, field, 0)

    def test_record_error_restores_policy_without_exposing_native_error(self):
        self.requires_authentication = True
        for operation in (lambda records: records.read(0), lambda records: records.write(0, "fixture")):
            with self.assertRaisesRegex(oauth.ConnectionError, "^protected_store_unavailable$"):
                operation(oauth.ProtectedRecords("policy-fixture"))
            self.assertEqual(self.prompts, 0)
            self.assertTrue(self.allowed)

    def test_failed_policy_restore_does_not_return_a_record(self):
        self.restore_status = -50
        with self.assertRaisesRegex(oauth.ConnectionError, "^protected_store_unavailable$"):
            oauth.ProtectedRecords("policy-fixture").read(0)


if __name__ == "__main__":
    unittest.main()
