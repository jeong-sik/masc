"""Exercise the installer's real shell wizard through a terminal and pipes."""
import errno
import http.server
import os
from pathlib import Path
import pty
import shlex
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "scripts/install.sh").read_text()
DEFINITIONS = SCRIPT.split('\nwhile [ $# -gt 0 ]; do', 1)[0]
CATALOG = '''
PROVIDER_IDS=(one two)
PROVIDER_NAMES=(One Two)
PROVIDER_KEYS=("" "")
PROVIDER_ENDPOINTS=(https://one.invalid https://two.invalid)
PROVIDER_PING_PATHS=(/health /health)
PROVIDER_DEFAULT_RUNTIME_IDS=(one.model two.model)
PROVIDER_KINDS=(provider provider)
PROVIDER_COMMANDS=("" "")
PROVIDER_AVAIL=(cloud cloud)
DEFAULT_PROVIDER_INDEX=0
load_provider_catalog() { :; }
compute_provider_availability() { :; }
report_sandbox_backends() { :; }
update_runtime_default() { printf 'selected=%s\\n' "$2"; }
prompt_runtime_source() { echo configured; }
DRY_RUN=1
BASE_PATH=/fixture
'''


def run_shell(body, terminal_input=None):
    master = slave = reader = None
    terminal = bytearray()
    try:
        if terminal_input is not None:
            master, slave = pty.openpty()

            def drain():
                while True:
                    try:
                        chunk = os.read(master, 65536)
                        if not chunk:
                            return
                        terminal.extend(chunk)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        return

            reader = threading.Thread(target=drain)
            reader.start()
            os.write(master, terminal_input)
        result = subprocess.run(
            ["bash", "-c", DEFINITIONS + CATALOG + body],
            stdin=slave if slave is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=slave if slave is not None else subprocess.PIPE,
            text=True, timeout=5,
        )
        if slave is not None:
            os.close(slave)
            slave = None
            reader.join(timeout=5)
            if reader.is_alive():
                raise RuntimeError("terminal output reader did not finish")
        return result, terminal.decode()
    finally:
        if slave is not None:
            os.close(slave)
        if reader is not None:
            reader.join(timeout=5)
        if master is not None:
            os.close(master)


class Wizard(unittest.TestCase):
    def test_local_authentication_challenge_is_not_reported_as_stopped(self):
        class AuthRequired(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(401)
                self.send_header('Content-Length', '0')
                self.end_headers()
            def log_message(self, *args):
                pass
        with http.server.HTTPServer(('127.0.0.1', 0), AuthRequired) as server:
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                body = ('\nPROVIDER_KINDS=(provider)\n'
                        f'PROVIDER_ENDPOINTS=(http://127.0.0.1:{server.server_port})\n'
                        'PROVIDER_PING_PATHS=(/models)\nprovider_availability_label 0\n')
                result, _ = run_shell(body)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), 'authentication required')
            finally:
                server.shutdown()
                thread.join()

    def test_runtime_connection_choices_are_visible_without_installed_clients(self):
        definition = 'prompt_runtime_source() {' + SCRIPT.split('prompt_runtime_source() {', 1)[1].split('\nruntime_setup_input()', 1)[0]
        for choice, expected in [(b'2\n', 'llama_cpp'), (b'3\n', 'vllm'),
                                 (b'4\n', 'claude_code'), (b'5\n', 'codex'),
                                 (b'6\n', 'antigravity'), (b'7\n', 'openai_compatible'),
                                 (b'8\n', 'later')]:
            with self.subTest(expected=expected):
                result, terminal = run_shell('\n' + definition + '\nprompt_runtime_source\n', choice)
                self.assertEqual(result.returncode, 0, terminal)
                self.assertEqual(result.stdout.strip(), expected)
                for label in ('llama.cpp', 'vLLM', 'Claude Code', 'Codex', 'Antigravity'):
                    self.assertIn(label, terminal)

    def test_new_workspace_prompts_and_defaults_to_home(self):
        with tempfile.TemporaryDirectory() as directory:
            result, terminal = run_shell(
                '\ncd ' + shlex.quote(directory) + '\nBASE_PATH=""\n'
                'choose_install_base_path\nprintf "workspace=%s\\n" "$BASE_PATH"\n', b'\n')
        self.assertEqual(result.returncode, 0, terminal)
        self.assertIn('Workspace directory', terminal)
        self.assertIn('workspace=' + os.environ['HOME'], result.stdout)

    def test_existing_workspace_remains_the_suggested_location(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / '.masc/config').mkdir(parents=True)
            result, terminal = run_shell(
                '\ncd ' + shlex.quote(directory) + '\nBASE_PATH=""\n'
                'choose_install_base_path\nprintf "workspace=%s\\n" "$BASE_PATH"\n', b'\n')
            self.assertIn('workspace=' + directory, result.stdout)
        self.assertEqual(result.returncode, 0, terminal)

    def test_custom_workspace_with_spaces_is_preserved(self):
        result, terminal = run_shell(
            '\nBASE_PATH=""\nchoose_install_base_path\nprintf "workspace=%s\\n" "$BASE_PATH"\n',
            b'/tmp/masc workspace\n')
        self.assertEqual(result.returncode, 0, terminal)
        self.assertIn('workspace=/tmp/masc workspace', result.stdout)

    def test_explicit_workspace_does_not_prompt(self):
        result, terminal = run_shell(
            '\nchoose_install_base_path\nprintf "workspace=%s\\n" "$BASE_PATH"\n', b'\n')
        self.assertEqual(result.returncode, 0, terminal)
        self.assertNotIn('Workspace directory', terminal)
        self.assertIn('workspace=/fixture', result.stdout)

    def test_terminal_choice_survives_captured_stdout(self):
        result, terminal = run_shell('\nrun_wizard "$BASE_PATH"\n', b'2\n')
        self.assertEqual(result.returncode, 0, terminal)
        self.assertIn('Choose your default provider', terminal)
        self.assertIn('id: two', terminal)
        self.assertIn('selected=two.model', result.stdout)

    def test_invalid_numeric_input_can_be_corrected(self):
        result, terminal = run_shell('\nrun_wizard "$BASE_PATH"\n', b'08\n999999999999999999999999999999\n2\n')
        self.assertEqual(result.returncode, 0, terminal)
        self.assertIn('invalid choice', terminal)
        self.assertIn('selected=two.model', result.stdout)
        self.assertNotIn('value too great for base', terminal)

    def test_closed_terminal_does_not_select_a_default(self):
        result, terminal = run_shell('\nrun_wizard "$BASE_PATH"\n', b'\x04')
        self.assertNotEqual(result.returncode, 0, terminal)
        self.assertIn('provider selection cancelled', terminal)
        self.assertNotIn('selected=', result.stdout)

    def test_explicit_provider_applies_to_existing_config(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / ".masc/config"
            config.mkdir(parents=True)
            (config / "runtime.toml").touch()
            result, _ = run_shell('''
CONFIG_PREEXISTING=1
WIZARD_PROVIDER=two
run_wizard() { printf 'wizard=%s\\n' "$WIZARD_PROVIDER"; }
maybe_run_wizard "''' + directory + '"\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('wizard=two', result.stdout)

    def test_explicit_provider_requires_runtime_config(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _ = run_shell('WIZARD_PROVIDER=two\nmaybe_run_wizard "' + directory + '"\n')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('runtime.toml not found; cannot run wizard', result.stderr)

    def test_noninteractive_ambiguous_sources_do_not_change_default(self):
        result, _ = run_shell('run_wizard "$BASE_PATH"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('skipping first-time setup wizard', result.stdout)
        self.assertNotIn('selected=', result.stdout)

    def test_subscription_cli_without_login_is_not_connectivity_success(self):
        result, _ = run_shell('''
PROVIDER_KINDS=(subscription subscription)
PROVIDER_COMMANDS=(bash bash)
DEST=false
if ping_provider 0 ""; then echo false-success; else echo login-not-ready; fi
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('login-not-ready', result.stdout)
        self.assertNotIn('false-success', result.stdout)

    def test_unsupported_login_probe_is_neither_success_nor_failure(self):
        result, _ = run_shell('''
PROVIDER_KINDS=(subscription subscription)
PROVIDER_COMMANDS=(bash bash)
probe_unavailable() { return 3; }
DEST=probe_unavailable
WIZARD_PROVIDER=one
DRY_RUN=0
run_wizard "$BASE_PATH"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('login probe unavailable', result.stdout)
        self.assertNotIn('provider connectivity: ok', result.stdout)
        self.assertNotIn('check did not pass', result.stderr)

    def test_missing_healthcheck_is_skipped(self):
        result, _ = run_shell('''
PROVIDER_PING_PATHS=("" "")
if provider_ping_possible 0 ""; then echo false-success; else echo check-unavailable; fi
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('check-unavailable', result.stdout)

    def test_conflicting_flags_fail_before_download(self):
        for args, message in [
            (["--provider", "one", "--no-wizard"], "--provider requires"),
            (["--sandbox", "docker"], "--sandbox requires --team"),
        ]:
            with self.subTest(args=args):
                result = subprocess.run(["bash", str(ROOT / 'scripts/install.sh'), *args], capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertNotIn('downloading', result.stdout)


if __name__ == '__main__':
    unittest.main()
