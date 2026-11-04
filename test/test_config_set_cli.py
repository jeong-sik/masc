#!/usr/bin/env python3
"""`masc config set`, run as a script runs it: the real executable.

test_runtime_setting_set.ml proves the writer. This runs the executable, so a
subcommand that is renamed, an argument that is not passed on, or a workspace
that is not seeded fails here. Every case works in a scratch workspace under a
scratch HOME.

RFC-0482 §3.2: while the workspace's server answers on the port, the keys go
through it. A stand-in server answers health and runtime.toml the way the
real one does, so the command's side of that exchange is checked here; the
server's side is test_dashboard_http_core's.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest

MASC = Path(sys.argv.pop(1)).resolve()

# A runtime.toml the server would load: [runtime].default is required.
RUNTIME_TOML = """# Operator notes: kept as they are.
[providers."deepseek"]
display-name = "Fixture HTTP (deepseek)"
protocol = "openai-compatible-http"
endpoint = "https://fixture.invalid/v1"
[providers."deepseek".credentials]
type = "inline"
value = "previous-fixture-key"
[models.chat]
api-name = "deepseek-v4-pro"
["deepseek".chat]
[runtime]
default = "deepseek.chat"
"""


def masc(root, *args):
    environment = {"HOME": str(root / "home"), "PATH": "/usr/bin:/bin"}
    return subprocess.run([str(MASC), "config", "set", *args], env=environment,
                          capture_output=True, text=True)


def runtime_toml(base):
    return base / ".masc/config/runtime.toml"


REVISION = "a" * 64
SERVER_PATH = "/srv/config/runtime.toml"
TOKEN = "fixture-bearer"


class StandIn:
    """A server that answers /health for one workspace and serves RUNTIME_TOML
    as its runtime.toml, recording what the command sends."""

    def __init__(self, base_path, ready=True, save_status=200):
        self.base_path, self.ready, self.save_status = base_path, ready, save_status
        self.saves, self.authorizations = [], []
        stand_in = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def answer(self, status, body):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if self.path.startswith("/health"):
                    self.answer(200, {"paths": {"effective_base_path": str(stand_in.base_path)},
                                      "startup": {"state_ready": stand_in.ready}})
                elif self.path == "/api/v1/runtime/config/raw":
                    stand_in.authorizations.append(self.headers.get("authorization"))
                    self.answer(200, {"ok": True, "source_text": RUNTIME_TOML,
                                      "source_revision": REVISION, "path": SERVER_PATH})
                else:
                    self.answer(404, {"ok": False, "error": "not here"})

            def do_POST(self):
                length = int(self.headers.get("content-length", "0"))
                stand_in.authorizations.append(self.headers.get("authorization"))
                stand_in.saves.append(json.loads(self.rfile.read(length)))
                self.answer(stand_in.save_status, {"ok": stand_in.save_status == 200})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def sign_in(base):
    auth = base / ".masc/auth"
    auth.mkdir(parents=True, exist_ok=True)
    token = auth / "local-admin.token"
    token.write_text(TOKEN)
    os.chmod(token, 0o600)


def workspace(root, name="workspace"):
    base = root / name
    runtime_toml(base).parent.mkdir(parents=True)
    runtime_toml(base).write_text(RUNTIME_TOML)
    return base


class ConfigSetCommand(unittest.TestCase):
    def scratch(self):
        temporary = tempfile.TemporaryDirectory(prefix="config set cli ' ")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        (root / "home").mkdir()
        return root

    # A script starts from a base path nothing has touched.
    def test_a_fresh_workspace_is_seeded_and_the_keys_are_written(self):
        root = self.scratch()
        base = root / "fresh workspace ' one"
        result = masc(root, "autonomous.enabled=false", "otel.enabled=false",
                      "--base-path", str(base))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(runtime_toml(base).is_file(), "the config root was not seeded")
        written = runtime_toml(base).read_text()
        self.assertIn("[autonomous]\nenabled = false", written)
        self.assertIn("[otel]\nenabled = false", written)
        self.assertIn("autonomous.enabled", result.stdout)

    def test_a_second_run_changes_nothing(self):
        root = self.scratch()
        base = workspace(root)
        arguments = ("autonomous.enabled=false", "--base-path", str(base))
        self.assertEqual(masc(root, *arguments).returncode, 0)
        first = runtime_toml(base).read_bytes()
        second = masc(root, *arguments)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("already as requested", second.stdout)
        self.assertEqual(runtime_toml(base).read_bytes(), first)

    def test_a_workspace_that_has_a_file_keeps_its_notes(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "heartbeat.interval_sec=30", "--base-path", str(base))
        self.assertEqual(result.returncode, 0, result.stderr)
        written = runtime_toml(base).read_text()
        self.assertTrue(written.startswith(RUNTIME_TOML), written)
        self.assertTrue(written.endswith("[heartbeat]\ninterval_sec = 30\n"), written)

    def test_an_unknown_key_is_refused_and_nothing_is_seeded(self):
        root = self.scratch()
        base = root / "fresh"
        result = masc(root, "bogus.key=1", "--base-path", str(base))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("bogus.key", result.stderr)
        self.assertFalse(runtime_toml(base).exists())

    def test_a_value_of_the_wrong_kind_is_refused(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "autonomous.enabled=maybe", "--base-path", str(base))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("autonomous.enabled", result.stderr)
        self.assertIn("true or false", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    def test_several_assignments_are_all_or_none(self):
        root = self.scratch()
        base = workspace(root)
        # heartbeat.interval_sec is at least 1: the first assignment must not
        # land without the second.
        result = masc(root, "autonomous.enabled=false", "heartbeat.interval_sec=0",
                      "--base-path", str(base))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("heartbeat.interval_sec", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    def test_an_argument_without_an_equals_sign_is_refused(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "autonomous.enabled", "--base-path", str(base))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("KEY=VALUE", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)


    def stand_in(self, base, **options):
        server = StandIn(base, **options)
        self.addCleanup(server.close)
        return server

    def test_a_running_server_of_this_workspace_saves_the_keys(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(base)
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("through the running server", result.stdout)
        self.assertEqual(len(server.saves), 1)
        save = server.saves[0]
        self.assertEqual(save["expected_source_revision"], REVISION)
        self.assertEqual(save["expected_source_path"], SERVER_PATH)
        self.assertIn("[autonomous]\nenabled = false", save["source_text"])
        self.assertTrue(all(value == "Bearer " + TOKEN for value in server.authorizations))
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML,
                         "the command wrote the file under a running server")

    def test_a_server_of_another_workspace_is_not_this_ones(self):
        root = self.scratch()
        base = workspace(root)
        server = self.stand_in(root / "another")
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(server.saves, [])
        self.assertIn("[autonomous]\nenabled = false", runtime_toml(base).read_text())

    def test_a_starting_server_stops_the_command(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(base, ready=False)
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("starting", result.stderr)
        self.assertEqual(server.saves, [])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    def test_a_running_server_without_a_sign_in_stops_the_command(self):
        root = self.scratch()
        base = workspace(root)
        server = self.stand_in(base)
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("masc login", result.stderr)
        self.assertEqual(server.saves, [])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    def test_a_file_changed_on_the_server_is_not_overwritten(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(base, save_status=409)
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("changed", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)


if __name__ == "__main__":
    unittest.main()
