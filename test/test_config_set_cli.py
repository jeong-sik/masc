#!/usr/bin/env python3
"""`masc config set`, run as a script runs it: the real executable.

test_runtime_setting_set.ml proves the writer. This runs the executable, so a
subcommand that is renamed, an argument that is not passed on, or a workspace
that is not seeded fails here. Every case works in a scratch workspace under a
scratch HOME.

RFC-0482 §3.2: while a server holds the workspace, the keys go through it,
and so do web-search-setup's section, voice-local-setup's changes and
runtime-default-set's edit. Which process that server is, the kernel says: a
helper holds the lease of the workspace and announces the port, and a stand-in
answers readiness and runtime.toml on that port the way the real server does.
So the command's side of that exchange is checked here; the server's side is
test_dashboard_http_core's.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

MASC = Path(sys.argv.pop(1)).resolve()
ANNOUNCER = Path(sys.argv.pop(1)).resolve()

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


def environment(root):
    return {"HOME": str(root / "home"), "PATH": "/usr/bin:/bin"}


def masc_command(root, *args):
    return subprocess.run([str(MASC), *args], env=environment(root),
                          capture_output=True, text=True)


class Announcement:
    """The helper that holds the lease of a workspace and announces a port.

    The kernel then names it as the server of the workspace, the way it names
    a booted server. `kind` is the server it announces as: single-user,
    account, or none for an owner that announces nothing.
    """

    def __init__(self, root, base, port, kind):
        self.process = subprocess.Popen(
            [str(ANNOUNCER), "--base-path", str(base), "--port", str(port), "--kind", kind],
            env=environment(root), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        line = self.process.stdout.readline()
        if not line.startswith("ready "):
            self.process.kill()
            raise AssertionError("the announcer did not hold the workspace: "
                                 + line + self.process.stderr.read())
        self.pid = int(line.split()[1])

    def withdraw(self):
        """Withdraws the announcement and keeps the lease, as a server does
        once its listener closes on the way to its exit."""
        self.process.stdin.write("withdraw\n")
        self.process.stdin.flush()
        answer = self.process.stdout.readline().strip()
        if answer != "withdrawn":
            raise AssertionError("the announcer did not withdraw: " + answer)

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=30)
        self.process.stdout.close()
        self.process.stderr.close()


def masc(root, *args):
    return masc_command(root, "config", "set", *args)


def runtime_toml(base):
    return base / ".masc/config/runtime.toml"


REVISION = "a" * 64
VOICE_REVISION = "b" * 64
SERVER_PATH = "/srv/config/runtime.toml"
TOKEN = "fixture-bearer"


class StandIn:
    """A server that answers readiness and serves RUNTIME_TOML as its
    runtime.toml, recording every request and what the command sends."""

    def __init__(self, ready=True, save_status=200, speaking=None, before_source=None):
        self.ready, self.save_status = ready, save_status
        self.speaking = speaking
        # Runs once the command asked for runtime.toml, before it is answered.
        self.before_source = before_source
        # The same for readiness and for the voice setup read, once each.
        self.before_ready = self.before_voice = None
        self.requests, self.saves, self.save_paths, self.authorizations = [], [], [], []
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
                stand_in.requests.append(("GET", self.path))
                if self.path == "/health/ready":
                    hook, stand_in.before_ready = stand_in.before_ready, None
                    if hook is not None:
                        hook()
                    self.answer(200 if stand_in.ready else 503, {"ready": stand_in.ready})
                elif self.path == "/api/v1/runtime/config/raw":
                    stand_in.authorizations.append(self.headers.get("authorization"))
                    if stand_in.before_source is not None:
                        stand_in.before_source()
                    self.answer(200, {"ok": True, "source_text": RUNTIME_TOML,
                                      "source_revision": REVISION, "path": SERVER_PATH})
                elif self.path == "/api/v1/voice/setup":
                    stand_in.authorizations.append(self.headers.get("authorization"))
                    hook, stand_in.before_voice = stand_in.before_voice, None
                    if hook is not None:
                        hook()
                    tts = None if stand_in.speaking is None else {"endpoints": stand_in.speaking}
                    self.answer(200, {"revision": VOICE_REVISION, "source": None,
                                      "tts": tts, "stt": None})
                else:
                    self.answer(404, {"ok": False, "error": "not here"})

            def do_POST(self):
                length = int(self.headers.get("content-length", "0"))
                stand_in.requests.append(("POST", self.path))
                stand_in.authorizations.append(self.headers.get("authorization"))
                stand_in.save_paths.append(self.path)
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


    def unused_port(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            return probe.getsockname()[1]

    def announce(self, root, base, port, kind):
        holder = Announcement(root, base, port, kind)
        self.addCleanup(holder.close)
        return holder

    # A stand-in on a port, and the helper the kernel names as the server of
    # [base] on that port. With kind None nothing holds the workspace.
    def stand_in(self, root, base, kind="single-user", **options):
        server = StandIn(**options)
        self.addCleanup(server.close)
        if kind is not None:
            server.holder = self.announce(root, base, server.port, kind)
        return server

    def test_a_running_server_of_this_workspace_saves_the_keys(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base)
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

    # Nothing holds this workspace, so what listens on the port is no server
    # of it: the command writes the file itself and asks the port nothing.
    def test_a_listener_nothing_holds_the_workspace_behind_is_not_its_server(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base, kind=None)
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(server.requests, [])
        self.assertIn("[autonomous]\nenabled = false", runtime_toml(base).read_text())

    # A process holds the workspace and announces no port. Whatever the reason
    # (starting, shutting down, announcing another port behind the lock of
    # another process, listening out of loopback reach, started by a MASC
    # that does not announce), the command neither writes the file under
    # it nor sends the bearer to the port.
    def test_an_owner_that_announces_nothing_stops_the_command(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base, kind="none")
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("pid %d" % server.holder.pid, result.stderr)
        self.assertIn("Nothing was saved", result.stderr)
        self.assertEqual(server.requests, [])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    def test_an_account_server_stops_the_command(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base, kind="account")
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("account server", result.stderr)
        self.assertEqual(server.requests, [])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    # The kernel is asked again before each send of the bearer. The server
    # here gives the workspace up after it answered the read: the save that
    # would follow is not sent to the port it left behind.
    def test_a_server_that_left_after_the_read_gets_no_save(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base, kind=None)
        holder = self.announce(root, base, server.port, "single-user")
        server.before_source = holder.close
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("changed after this command checked it", result.stderr)
        self.assertEqual(server.requests, [("GET", "/health/ready"), ("GET", "/api/v1/runtime/config/raw")])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    # A server that shuts down keeps the workspace and withdraws its
    # announcement. Each request that carries the bearer asks the kernel
    # first, so none of them reaches the port after that: not the read of
    # runtime.toml, not the read of the voice setup, not the voice save.
    def test_a_server_that_withdrew_its_announcement_gets_no_read(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base)
        server.before_ready = server.holder.withdraw
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("(pid %d) withdrew its announcement" % server.holder.pid, result.stderr)
        self.assertEqual(server.requests, [("GET", "/health/ready")])
        self.assertEqual(server.authorizations, [])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    def test_voice_local_setup_reads_nothing_from_a_server_that_withdrew_its_announcement(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base)
        server.before_ready = server.holder.withdraw
        result = masc_command(root, "voice-local-setup", "--base-path", str(base),
                              "--port", str(server.port), "--model", str(root / "ggml-base.bin"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("(pid %d) withdrew its announcement" % server.holder.pid, result.stderr)
        self.assertEqual(server.requests, [("GET", "/health/ready")])
        self.assertEqual(server.authorizations, [])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    def test_voice_local_setup_saves_nothing_to_a_server_that_withdrew_its_announcement(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base)
        server.before_voice = server.holder.withdraw
        result = masc_command(root, "voice-local-setup", "--base-path", str(base),
                              "--port", str(server.port), "--model", str(root / "ggml-base.bin"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("(pid %d) withdrew its announcement" % server.holder.pid, result.stderr)
        self.assertEqual(server.requests, [("GET", "/health/ready"), ("GET", "/api/v1/voice/setup")])
        self.assertEqual(server.saves, [])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    # runtime-setup-batch decides its save against the text the server holds
    # and publishes it through the server. The server here withdraws its
    # announcement after it answered that text: the publication is not sent.
    def test_setup_batch_publishes_nothing_to_a_server_that_withdrew_its_announcement(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base)
        port = ("--base-path", str(base), "--port", str(server.port))
        inventory = masc_command(root, "runtime-setup-inventory", *port)
        self.assertEqual(inventory.returncode, 0, inventory.stderr)
        request = root / "request.json"
        request.write_text(json.dumps({
            "connections": [], "runtime_ids": ["deepseek.chat"], "default_runtime_id": "deepseek.chat",
            "expected_revision": json.loads(inventory.stdout)["setup_revision"], "verify": False}))
        os.chmod(request, 0o600)
        del server.requests[:]
        server.before_source = server.holder.withdraw
        result = masc_command(root, "runtime-setup-batch", *port, "--request", str(request))
        self.assertEqual(result.returncode, 1, result.stdout)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["kind"], "commit_refused", receipt)
        self.assertIn("(pid %d) withdrew its announcement" % server.holder.pid, receipt["detail"])
        self.assertEqual(server.requests, [("GET", "/health/ready"), ("GET", "/api/v1/runtime/config/raw")])
        self.assertEqual(server.saves, [])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    # Whether a server holds the workspace is not known then, so the command
    # neither writes the file itself nor asks the port anything.
    def test_an_owner_that_cannot_be_read_stops_the_command(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base, kind=None)
        # The lease root of a workspace is this directory; a file in its
        # place holds no lease that could be read.
        (base / ".masc-owner").write_text("")
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("could not be checked", result.stderr)
        self.assertIn("Nothing was saved", result.stderr)
        self.assertEqual(server.requests, [])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    def test_a_server_on_another_port_stops_the_command(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base, kind=None)
        announced = self.unused_port()
        self.announce(root, base, announced, "single-user")
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("--port %d" % announced, result.stderr)
        self.assertEqual(server.requests, [])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    def test_a_starting_server_stops_the_command(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base, ready=False)
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("starting", result.stderr)
        self.assertEqual(server.saves, [])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    def test_a_running_server_without_a_sign_in_stops_the_command(self):
        root = self.scratch()
        base = workspace(root)
        server = self.stand_in(root, base)
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("masc login", result.stderr)
        self.assertEqual(server.saves, [])
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    # web-search-setup saves through the same client: the state it prints is
    # the text the server holds after the save.
    def test_web_search_setup_saves_through_a_running_server(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base)
        result = masc_command(root, "web-search-setup", "--base-path", str(base),
                              "--port", str(server.port), "--timeout-sec", "30")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("through the running server", result.stdout)
        self.assertEqual(len(server.saves), 1)
        self.assertIn("timeout_sec = 30", server.saves[0]["source_text"])
        self.assertEqual(server.saves[0]["expected_source_revision"], REVISION)
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    # voice-local-setup sends its changes to the server's voice route, with the
    # revision it decided them on, and leaves the file to the server.
    def test_voice_local_setup_sends_its_changes_to_a_running_server(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base)
        model = str(root / "ggml-base.bin")
        result = masc_command(root, "voice-local-setup", "--base-path", str(base),
                              "--port", str(server.port), "--model", model)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("through the running server", result.stdout)
        self.assertEqual(server.save_paths, ["/api/v1/voice/setup"])
        save = server.saves[0]
        self.assertEqual(save["expected_revision"], VOICE_REVISION)
        self.assertEqual(save["changes"], [{
            "change": "put_endpoint", "section": "stt",
            "endpoint": {"id": "whisper-local", "kind": "whisper_cli",
                         "enabled": True, "model": model}}])
        self.assertTrue(all(value == "Bearer " + TOKEN for value in server.authorizations))
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML,
                         "the command wrote the file under a running server")

    # The changes are decided against what the server holds. The server may
    # read another file than this workspace's own (MASC_CONFIG_DIR): here the
    # workspace has none, and the command still sets up through the server.
    def test_voice_local_setup_decides_against_the_servers_configuration(self):
        root = self.scratch()
        base = root / "workspace"
        base.mkdir()
        sign_in(base)
        server = self.stand_in(root, base)
        result = masc_command(root, "voice-local-setup", "--base-path", str(base),
                              "--port", str(server.port), "--model", str(root / "ggml-base.bin"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(server.save_paths, ["/api/v1/voice/setup"])
        self.assertFalse(runtime_toml(base).exists())

    def test_voice_local_setup_reads_the_servers_speaking_endpoints(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base, speaking=[{"id": "macos-say", "kind": "espeak_ng"}])
        result = masc_command(root, "voice-local-setup", "--base-path", str(base),
                              "--port", str(server.port), "--voice", "Yuna")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("already names another provider", result.stderr)
        self.assertEqual(server.saves, [])

    def test_voice_local_setup_refused_by_the_server_writes_nothing(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base, save_status=409)
        result = masc_command(root, "voice-local-setup", "--base-path", str(base),
                              "--port", str(server.port), "--model", str(root / "ggml-base.bin"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("HTTP 409", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)

    # runtime-default-set makes the edit its local write commits, to the text
    # the server holds, and saves it through the text route.
    def test_runtime_default_set_saves_through_a_running_server(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base)
        result = masc_command(root, "runtime-default-set", "--base-path", str(base),
                              "--port", str(server.port), "other.chat")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("through the running server", result.stdout)
        self.assertEqual(server.save_paths, ["/api/v1/runtime/config/raw"])
        self.assertIn('default = "other.chat"', server.saves[0]["source_text"])
        self.assertEqual(server.saves[0]["expected_source_revision"], REVISION)
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML,
                         "the command wrote the file under a running server")

    def test_a_file_changed_on_the_server_is_not_overwritten(self):
        root = self.scratch()
        base = workspace(root)
        sign_in(base)
        server = self.stand_in(root, base, save_status=409)
        result = masc(root, "autonomous.enabled=false", "--base-path", str(base),
                      "--port", str(server.port))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("changed", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), RUNTIME_TOML)


if __name__ == "__main__":
    unittest.main()
