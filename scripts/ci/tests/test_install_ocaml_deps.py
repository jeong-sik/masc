"""Exercise the two CI steps that call `opam install` against stub commands.

install-ocaml-deps/install.sh and opam-pin-external-deps.sh --install decide
whether a run asks the system package manager for anything. Each scenario
records the commands the script ran and checks which of them reached apt
and which flags opam got.
"""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
INSTALL = REPO / ".github/actions/install-ocaml-deps/install.sh"
PIN = REPO / "scripts/opam-pin-external-deps.sh"

# Every stub appends its own name and arguments to $CALLS. `timeout` drops
# its own options and runs the command it was given, as timeout(1) does.
STUBS = {
    "sudo": '#!/bin/sh\necho "sudo $*" >> "$CALLS"\n',
    "timeout": (
        "#!/bin/sh\n"
        'while [ "${1#-}" != "$1" ]; do shift; done\n'
        "shift\n"
        'exec "$@"\n'
    ),
    # $OPAM_FAILS_WITH names a flag; opam fails when it is called with it.
    # The three answers are what the pin script reads before it pins.
    "opam": (
        "#!/bin/sh\n"
        'echo "opam $*" >> "$CALLS"\n'
        'case "$*" in\n'
        '  "switch show") echo ci ;;\n'
        '  "var prefix") echo "$STUB_PREFIX" ;;\n'
        '  "exec -- ocamlc -version") echo 5.5.2 ;;\n'
        "esac\n"
        'for arg in "$@"; do\n'
        '  if [ -n "${OPAM_FAILS_WITH:-}" ] && [ "$arg" = "$OPAM_FAILS_WITH" ]; then\n'
        "    exit 10\n"
        "  fi\n"
        "done\n"
    ),
}


def run_install(**env):
    return run_script([str(INSTALL)], **env)


def run_pin(**env):
    return run_script([str(PIN), "--install"], **env)


def run_script(script, **env):
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = Path(tmp) / "bin"
        bin_dir.mkdir()
        for name, body in STUBS.items():
            stub = bin_dir / name
            stub.write_text(body)
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        calls = Path(tmp) / "calls"
        calls.touch()
        completed = subprocess.run(
            ["bash", *script],
            env={
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "CALLS": str(calls),
                "STUB_PREFIX": str(Path(tmp) / "prefix"),
                "INSTALL_TIMEOUT_MINUTES": "1",
                "HEARTBEAT_SECONDS": "1",
                "INSTALL_FLAGS": "--with-test",
                **env,
            },
            capture_output=True,
            text=True,
            check=False,
        )
        return completed, calls.read_text().splitlines()


def apt_calls(calls):
    return [call for call in calls if call.startswith("sudo apt-get")]


def opam_calls(calls):
    return [call for call in calls if call.startswith("opam install")]


class InstallOcamlDeps(unittest.TestCase):
    def test_restored_switch_with_skip_asks_for_no_system_packages(self):
        completed, calls = run_install(
            MASC_SYSTEM_PACKAGES_ON_RESTORED_SWITCH="skip",
            MASC_OPAM_SWITCH_RESTORE_ONLY="true",
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(apt_calls(calls), [])
        self.assertEqual(
            opam_calls(calls),
            ["opam install ./masc.opam --deps-only --locked --with-test --no-depexts --yes"],
        )

    def test_failed_install_on_the_restored_switch_installs_system_packages(self):
        completed, calls = run_install(
            MASC_SYSTEM_PACKAGES_ON_RESTORED_SWITCH="skip",
            MASC_OPAM_SWITCH_RESTORE_ONLY="true",
            OPAM_FAILS_WITH="--no-depexts",
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(apt_calls(calls), ["sudo apt-get update -qq"])
        self.assertEqual(
            opam_calls(calls),
            [
                "opam install ./masc.opam --deps-only --locked --with-test --no-depexts --yes",
                "opam install ./masc.opam --deps-only --locked --with-test --yes",
            ],
        )

    def test_default_installs_system_packages_on_a_restored_switch(self):
        completed, calls = run_install(MASC_OPAM_SWITCH_RESTORE_ONLY="true")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(apt_calls(calls), ["sudo apt-get update -qq"])
        self.assertEqual(
            opam_calls(calls),
            ["opam install ./masc.opam --deps-only --locked --with-test --yes"],
        )

    def test_skip_does_not_apply_to_a_run_that_may_save_the_switch(self):
        completed, calls = run_install(MASC_SYSTEM_PACKAGES_ON_RESTORED_SWITCH="skip")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(apt_calls(calls), ["sudo apt-get update -qq"])
        self.assertEqual(
            opam_calls(calls),
            ["opam install ./masc.opam --deps-only --locked --with-test --yes"],
        )

    def test_skip_does_not_apply_when_the_job_asks_for_os_packages(self):
        completed, calls = run_install(
            MASC_SYSTEM_PACKAGES_ON_RESTORED_SWITCH="skip",
            MASC_OPAM_SWITCH_RESTORE_ONLY="true",
            OS_PACKAGES="jq ripgrep",
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            apt_calls(calls),
            ["sudo apt-get update -qq", "sudo apt-get install -y jq ripgrep"],
        )
        self.assertEqual(
            opam_calls(calls),
            ["opam install ./masc.opam --deps-only --locked --with-test --yes"],
        )


class PinExternalDeps(unittest.TestCase):
    def test_restored_switch_with_skip_asks_for_no_system_packages(self):
        completed, calls = run_pin(
            MASC_SYSTEM_PACKAGES_ON_RESTORED_SWITCH="skip",
            MASC_OPAM_SWITCH_RESTORE_ONLY="true",
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(apt_calls(calls), [])
        installs = opam_calls(calls)
        self.assertEqual(len(installs), 1, installs)
        self.assertTrue(installs[0].startswith("opam install --yes --no-depexts "), installs)

    def test_failed_install_on_the_restored_switch_installs_system_packages(self):
        completed, calls = run_pin(
            MASC_SYSTEM_PACKAGES_ON_RESTORED_SWITCH="skip",
            MASC_OPAM_SWITCH_RESTORE_ONLY="true",
            OPAM_FAILS_WITH="--no-depexts",
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(apt_calls(calls), ["sudo apt-get update -qq"])
        installs = opam_calls(calls)
        self.assertEqual(len(installs), 2, installs)
        self.assertNotIn("--no-depexts", installs[1])

    def test_default_installs_system_packages(self):
        completed, calls = run_pin(MASC_OPAM_SWITCH_RESTORE_ONLY="true")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(apt_calls(calls), ["sudo apt-get update -qq"])
        installs = opam_calls(calls)
        self.assertEqual(len(installs), 1, installs)
        self.assertNotIn("--no-depexts", installs[0])

    def test_skip_does_not_apply_to_a_run_that_may_save_the_switch(self):
        completed, calls = run_pin(MASC_SYSTEM_PACKAGES_ON_RESTORED_SWITCH="skip")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(apt_calls(calls), ["sudo apt-get update -qq"])
        self.assertNotIn("--no-depexts", opam_calls(calls)[0])


if __name__ == "__main__":
    unittest.main()
