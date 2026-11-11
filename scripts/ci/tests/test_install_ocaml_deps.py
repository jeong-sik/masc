"""Exercise install-ocaml-deps/install.sh against stub opam, sudo and timeout.

The script decides whether a run asks the system package manager for
anything. Each scenario records the commands the script ran and checks
which of them reached apt and which flags opam got.
"""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
INSTALL = REPO / ".github/actions/install-ocaml-deps/install.sh"

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
    "opam": (
        "#!/bin/sh\n"
        'echo "opam $*" >> "$CALLS"\n'
        'for arg in "$@"; do\n'
        '  if [ -n "${OPAM_FAILS_WITH:-}" ] && [ "$arg" = "$OPAM_FAILS_WITH" ]; then\n'
        "    exit 10\n"
        "  fi\n"
        "done\n"
    ),
}


def run_install(**env):
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
            ["bash", str(INSTALL)],
            env={
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "CALLS": str(calls),
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
    def test_exact_restore_with_skip_asks_for_no_system_packages(self):
        completed, calls = run_install(
            SYSTEM_PACKAGES_ON_EXACT_RESTORE="skip",
            MASC_OPAM_SWITCH_EXACT_RESTORE="true",
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(apt_calls(calls), [])
        self.assertEqual(
            opam_calls(calls),
            ["opam install ./masc.opam --deps-only --locked --with-test --no-depexts --yes"],
        )

    def test_failed_install_on_the_restored_switch_installs_system_packages(self):
        completed, calls = run_install(
            SYSTEM_PACKAGES_ON_EXACT_RESTORE="skip",
            MASC_OPAM_SWITCH_EXACT_RESTORE="true",
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

    def test_default_installs_system_packages_on_an_exact_restore(self):
        completed, calls = run_install(MASC_OPAM_SWITCH_EXACT_RESTORE="true")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(apt_calls(calls), ["sudo apt-get update -qq"])
        self.assertEqual(
            opam_calls(calls),
            ["opam install ./masc.opam --deps-only --locked --with-test --yes"],
        )

    def test_skip_does_not_apply_to_a_switch_not_restored_exactly(self):
        completed, calls = run_install(SYSTEM_PACKAGES_ON_EXACT_RESTORE="skip")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(apt_calls(calls), ["sudo apt-get update -qq"])
        self.assertEqual(
            opam_calls(calls),
            ["opam install ./masc.opam --deps-only --locked --with-test --yes"],
        )

    def test_skip_does_not_apply_when_the_job_asks_for_os_packages(self):
        completed, calls = run_install(
            SYSTEM_PACKAGES_ON_EXACT_RESTORE="skip",
            MASC_OPAM_SWITCH_EXACT_RESTORE="true",
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


if __name__ == "__main__":
    unittest.main()
