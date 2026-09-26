#!/usr/bin/env python3
"""A local install brings every registered browser lane host to the new build."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/install-local-build.sh"
HOST_INSTALLER = REPO / "connectors/browser/install-host.sh"


def executable(path, text):
    path.write_text("#!/bin/sh\necho " + text + "\n")
    path.chmod(0o755)
    return path


# Stands in for the new build's deployment preflight helper: the gate asks it
# for its identity and filenames, then for the runtime.toml verdict.
def preflight_helper(build, verdict_exit=0):
    path = build / "deployment_preflight_helper.exe"
    path.write_text("#!/bin/sh\n"
                    "case \"$1\" in\n"
                    "  build-commit) echo fixture-commit ;;\n"
                    "  durable-filenames) printf 'snapshot=fixture-snapshot.json\\nwal=fixture-wal.jsonl\\n' ;;\n"
                    f"  validate-runtime-config) echo 'runtime.toml fixture verdict'; exit {verdict_exit} ;;\n"
                    "  *) echo \"unexpected helper call: $*\" >&2; exit 2 ;;\n"
                    "esac\n")
    path.chmod(0o755)
    return path


def workspace(root):
    base = root / "live workspace"
    base.mkdir()
    return base


class LocalBuildInstall(unittest.TestCase):
    def test_every_registered_host_gets_the_new_copy_under_its_own_name(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            manifests = root / "native manifests"
            old_host = executable(root / "old-host", "old")
            # Two workspaces registered the way install-host.sh registers them,
            # one under the default host name and one under an isolated name.
            first, second = root / "workspace one", root / "workspace two"
            for base, name in ((first, "masc_browser_host"), (second, "masc_browser_host_second")):
                subprocess.run(["bash", str(HOST_INSTALLER), "--binary", str(old_host), "--base-path", str(base),
                                "--host-name", name, "--manifest-dir", str(manifests)],
                               check=True, capture_output=True)
            # A host that is not a workspace browser lane must be left alone.
            unrelated = manifests / "com.example.password.json"
            unrelated.write_text(json.dumps({"name": "com.example.password", "path": str(root / "elsewhere/launch")}))
            before_unrelated = unrelated.read_text()

            build = root / "build"
            build.mkdir()
            executable(build / "main_eio.exe", "masc")
            executable(build / "masc_tui.exe", "tui")
            executable(build / "masc_browser_host.exe", "new")
            preflight_helper(build)
            prefix = root / "prefix"

            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(manifests),
                                     "--base-path", str(workspace(root))],
                                    check=True, capture_output=True, text=True)

            for name, marker in (("masc", "masc"), ("masc-tui", "tui"), ("masc-browser-host", "new")):
                self.assertIn(marker, (prefix / name).read_text())
            for base, name in ((first, "masc_browser_host"), (second, "masc_browser_host_second")):
                copy = base / ".masc/browser-lane/host/masc-browser-host"
                self.assertIn("new", copy.read_text(), f"{base} still starts the old host")
                manifest = json.loads((manifests / f"{name}.json").read_text())
                self.assertEqual(manifest["name"], name)
                self.assertEqual(Path(manifest["path"]), base / ".masc/browser-lane/host/launch")
                self.assertTrue((base / ".masc/browser-lane/host/launch.json").is_file())
                self.assertIn(f"refreshed browser lane host {name} for {base}", result.stdout)
            self.assertEqual(unrelated.read_text(), before_unrelated)
            self.assertFalse((root / "elsewhere").exists())

    def test_no_registered_host_installs_binaries_and_says_so(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            for exe in ("main_eio.exe", "masc_tui.exe", "masc_browser_host.exe"):
                executable(build / exe, exe)
            preflight_helper(build)
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(root / "prefix"), "--manifest-dir", str(root / "absent"),
                                     "--base-path", str(workspace(root))],
                                    check=True, capture_output=True, text=True)
            self.assertTrue((root / "prefix/masc-browser-host").is_file())
            self.assertIn("no browser lane host is registered", result.stdout)

    # #39311: the new build refuses the live runtime.toml before any binary is
    # replaced, so the running server and its editor are left as they were.
    def test_a_refused_runtime_toml_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            for exe in ("main_eio.exe", "masc_tui.exe", "masc_browser_host.exe"):
                executable(build / exe, exe)
            preflight_helper(build, verdict_exit=1)
            prefix = root / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                                     "--base-path", str(workspace(root))],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("runtime.toml is not one this build accepts", result.stderr)
            self.assertIn("nothing was stopped or installed", result.stderr)
            self.assertFalse(prefix.exists(), "a build that refused the live runtime.toml was installed")

    def test_no_workspace_to_check_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            for exe in ("main_eio.exe", "masc_tui.exe", "masc_browser_host.exe"):
                executable(build / exe, exe)
            preflight_helper(build)
            prefix = root / "prefix"
            env = {key: value for key, value in os.environ.items() if key != "MASC_BASE_PATH"}
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent")],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("--base-path DIR or MASC_BASE_PATH", result.stderr)
            self.assertFalse(prefix.exists())

    def test_unknown_option_is_refused_before_anything_is_installed(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary) / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--prefix", str(prefix), "--bogus"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("unknown option: --bogus", result.stderr)
            self.assertFalse(prefix.exists())

    def test_the_build_goes_through_dune_local_and_a_refusal_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            checkout = root / "checkout"
            (checkout / "scripts").mkdir(parents=True)
            shutil.copy2(SCRIPT, checkout / "scripts/install-local-build.sh")
            # Stands in for dune-local.sh refusing the switch: records where and
            # how it was called, then fails the way its guards do.
            record = root / "dune-local call"
            guard = checkout / "scripts/dune-local.sh"
            guard.write_text("#!/bin/sh\npwd > \"$RECORD\"\nprintf '%s\\n' \"$@\" >> \"$RECORD\"\n"
                             "echo '[dune-local] OCaml 5.5.0 detected; this repo requires exactly 5.5.1' >&2\n"
                             "exit 1\n")
            guard.chmod(0o755)
            prefix = root / "prefix"
            result = subprocess.run(["bash", str(checkout / "scripts/install-local-build.sh"), "--prefix", str(prefix),
                                     "--manifest-dir", str(root / "absent")],
                                    env=dict(os.environ, RECORD=str(record)), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("this repo requires exactly 5.5.1", result.stderr)
            self.assertFalse(prefix.exists(), "a build dune-local.sh refused was installed")
            cwd, *arguments = record.read_text().splitlines()
            self.assertEqual(Path(cwd).resolve(), checkout)
            self.assertEqual(arguments, ["build", "--root", str(checkout), "./bin/main_eio.exe",
                                         "./bin/masc_tui.exe", "./bin/masc_browser_host.exe",
                                         "./bin/deployment_preflight_helper.exe"])

    def test_dune_local_takes_the_install_build_line(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            for exe in ("main_eio.exe", "masc_tui.exe", "masc_browser_host.exe"):
                executable(build / exe, exe)
            preflight_helper(build)
            # A dry run prints the Dune command and runs nothing, so the real
            # script is checked for taking these arguments without a switch.
            result = subprocess.run(["bash", str(SCRIPT), "--build-dir", str(build), "--prefix", str(root / "prefix"),
                                     "--manifest-dir", str(root / "absent"), "--base-path", str(workspace(root))],
                                    env=dict(os.environ, MASC_DUNE_DRY_RUN="1"),
                                    check=True, capture_output=True, text=True)
            self.assertIn("[dune-local] command: dune build --root", result.stderr)
            self.assertIn("./bin/masc_browser_host.exe", result.stderr)
            self.assertTrue((root / "prefix/masc").is_file())


if __name__ == "__main__":
    unittest.main()
