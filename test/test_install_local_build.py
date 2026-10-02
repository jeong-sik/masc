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


# Stands in for the new build's deployment preflight helper and records every
# call in helper-calls beside it. install-local-build asks it which workspace
# masc would use; the gate asks for its identity and filenames, then for the
# runtime.toml verdict. [unnamed_workspace] is what resolve-workspace answers
# without --base-path: a (root, source) pair, a raw answer body for malformed
# answers, or None for no workspace. An [old] helper predates the check and
# knows neither subcommand.
def preflight_helper(build, verdict_exit=0, unnamed_workspace=None, old=False,
                     resolve_failure=False):
    path = build / "deployment_preflight_helper.exe"
    if unnamed_workspace is None:
        unnamed = "printf 'workspace=none\\n'"
    elif isinstance(unnamed_workspace, str):
        unnamed = f"printf '{unnamed_workspace}'"
    else:
        root, source = unnamed_workspace
        unnamed = f"printf 'workspace=resolved\\nroot=%s\\nsource=%s\\n' '{root}' '{source}'"
    resolve = ("" if old else
               "  resolve-workspace) if [ \"$2\" = --help ]; then exit 0; fi; "
               "echo 'fixture workspace lookup failed' >&2; exit 42 ;;\n"
               if resolve_failure else
               "  resolve-workspace)\n"
               "    if [ \"$2\" = --base-path ]; then\n"
               "      printf 'workspace=resolved\\nroot=%s\\nsource=explicit_cli\\n' \"$3\"\n"
               f"    else {unnamed}; fi ;;\n")
    validate = ("" if old else
                f"  validate-runtime-config) echo 'runtime.toml fixture verdict'; exit {verdict_exit} ;;\n")
    path.write_text("#!/bin/sh\n"
                    "printf '%s\\n' \"$*\" >> \"$(dirname \"$0\")/helper-calls\"\n"
                    "case \"$1\" in\n"
                    "  build-commit) echo fixture-commit ;;\n"
                    "  durable-filenames) printf 'snapshot=fixture-snapshot.json\\nwal=fixture-wal.jsonl\\n' ;;\n"
                    + resolve + validate +
                    "  *) echo \"unexpected helper call: $*\" >&2; exit 2 ;;\n"
                    "esac\n")
    path.chmod(0o755)
    return path


def helper_calls(build):
    calls = build / "helper-calls"
    return calls.read_text().splitlines() if calls.exists() else []


def binaries(build):
    for exe in ("main_eio.exe", "masc_tui.exe", "masc_browser_host.exe"):
        executable(build / exe, exe)


# Neither the operator's MASC_BASE_PATH nor their recorded default may reach
# a case that means to name no workspace.
def unnamed_env(root):
    env = {key: value for key, value in os.environ.items() if key != "MASC_BASE_PATH"}
    env["XDG_CONFIG_HOME"] = str(root / "xdg")
    return env


def workspace(root):
    base = root / "live workspace"
    base.mkdir()
    return base


class LocalBuildInstall(unittest.TestCase):
    def test_successful_default_install_cleans_only_its_own_build(self):
        for flags, expected_clean, fail_build in (
                ([], True, False), (["--keep-build"], False, False),
                (["--skip-build"], False, False), ([], False, True),
                (["--prefix", "BUILD_PREFIX"], False, False),
                (["--manifest-dir", "BUILD_MANIFESTS"], False, False)):
            with self.subTest(flags=flags, fail_build=fail_build), \
                    tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                checkout = root / "checkout"
                scripts = checkout / "scripts"
                scripts.mkdir(parents=True)
                shutil.copy2(SCRIPT, scripts / SCRIPT.name)
                build = checkout / "_build/default/bin"
                build.mkdir(parents=True)
                binaries(build)
                artifact = checkout / "_build/cache-artifact"
                artifact.write_text("regenerable")
                wrapper = scripts / "dune-local.sh"
                wrapper.write_text(
                    "#!/bin/sh\n"
                    'repo=$(cd "$(dirname "$0")/.." && pwd)\n'
                    'printf "%s:%s\\n" "$1" "$MASC_DUNE_LOCK_HELD" >> "$repo/calls"\n'
                    'if [ "$1" = clean ]; then rm -f "$repo/_build/cache-artifact"; '
                    'else exit ' + ("23" if fail_build else "0") + '; fi\n')
                wrapper.chmod(0o755)
                prefix = root / "prefix"
                flags = [str(checkout / "_build/installed") if flag == "BUILD_PREFIX"
                         else str(checkout / "_build/manifests") if flag == "BUILD_MANIFESTS"
                         else flag for flag in flags]
                if "--prefix" in flags:
                    prefix = Path(flags[flags.index("--prefix") + 1])
                result = subprocess.run(
                    ["bash", str(scripts / SCRIPT.name), "--prefix", str(prefix),
                     "--manifest-dir", str(root / "absent"), *flags],
                    env={key: value for key, value in unnamed_env(root).items()
                         if key not in ("DUNE_BUILD_DIR", "MASC_DUNE_DRY_RUN")},
                    capture_output=True, text=True)
                if fail_build:
                    self.assertEqual(result.returncode, 23)
                    self.assertFalse((prefix / "masc").exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(subprocess.check_output(
                        [str(prefix / "masc")], text=True).strip(), "main_eio.exe")
                self.assertEqual(artifact.exists(), not expected_clean)
                calls = checkout / "calls"
                if calls.exists():
                    self.assertTrue(all(line.endswith(":1")
                                        for line in calls.read_text().splitlines()))

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

    # Without --base-path the check runs on the workspace masc itself would use,
    # as the helper resolves it, and the install goes ahead once it passes.
    def test_an_unnamed_workspace_is_resolved_like_masc_and_checked(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            recorded = workspace(root)
            preflight_helper(build, unnamed_workspace=(recorded, "persisted_default"))
            prefix = root / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent")],
                                    env=unnamed_env(root), cwd=root, check=True, capture_output=True, text=True)
            self.assertIn(f"checking runtime.toml of {recorded} (workspace from persisted_default)", result.stdout)
            self.assertIn(f"validate-runtime-config --base-path {recorded}", helper_calls(build))
            self.assertTrue((prefix / "masc").is_file())

    # #39431 makes these two refusals in the next version. Until then the
    # install says why it did not check, once, and installs as main does.
    def test_no_workspace_found_warns_skips_the_check_and_installs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            preflight_helper(build, verdict_exit=1)
            prefix = root / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent")],
                                    env=unnamed_env(root), cwd=root, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            warnings = [line for line in result.stderr.splitlines() if "WARN" in line]
            self.assertEqual(len(warnings), 1, result.stderr)
            self.assertIn("--base-path DIR or set MASC_BASE_PATH", warnings[0])
            self.assertIn("issues/39431", warnings[0])
            self.assertFalse(any(call.startswith("validate-runtime-config") for call in helper_calls(build)))
            self.assertTrue((prefix / "masc").is_file())

    def test_skip_build_without_the_helper_warns_skips_the_check_and_installs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            prefix = root / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                                     "--base-path", str(workspace(root))],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            warnings = [line for line in result.stderr.splitlines() if "WARN" in line]
            self.assertEqual(len(warnings), 1, result.stderr)
            self.assertIn(str(build / "deployment_preflight_helper.exe"), warnings[0])
            self.assertIn("issues/39431", warnings[0])
            self.assertTrue((prefix / "masc").is_file())

    def test_skip_build_with_a_helper_older_than_the_check_warns_and_installs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            preflight_helper(build, old=True)
            prefix = root / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                                     "--base-path", str(workspace(root))],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            warnings = [line for line in result.stderr.splitlines() if "WARN" in line]
            self.assertEqual(len(warnings), 1, result.stderr)
            self.assertIn("predates the check", warnings[0])
            self.assertTrue((prefix / "masc").is_file())

    def test_new_helper_workspace_lookup_failure_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            preflight_helper(build, resolve_failure=True)
            prefix = root / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                                     "--base-path", str(workspace(root))],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("helper failed to resolve the workspace", result.stderr)
            self.assertFalse(prefix.exists(), "a failed new helper skipped validation and installed binaries")

    # A named workspace that does not exist yet has no runtime.toml to judge;
    # the server creates it on its first start.
    def test_a_named_workspace_not_created_yet_is_reported_and_installed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            preflight_helper(build, verdict_exit=1)
            prefix = root / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                                     "--base-path", str(root / "not yet")],
                                    check=True, capture_output=True, text=True)
            self.assertIn("does not exist yet", result.stdout)
            self.assertTrue((prefix / "masc").is_file())

    # A resolved workspace with no root is an invalid answer, not a workspace
    # that does not exist yet: installing through it would skip the required
    # runtime.toml check and replace the deployed binaries unchecked.
    def test_a_resolved_workspace_without_a_root_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            preflight_helper(build, unnamed_workspace="workspace=resolved\\nsource=persisted_default\\n")
            prefix = root / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent")],
                                    env=unnamed_env(root), cwd=root, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("resolved the workspace but returned no root", result.stderr)
            self.assertIn("nothing installed", result.stderr)
            self.assertFalse(prefix.exists(), "a rootless resolved workspace was installed")

    def test_a_resolved_workspace_with_an_empty_root_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            preflight_helper(build, unnamed_workspace="workspace=resolved\\nroot=\\nsource=persisted_default\\n")
            prefix = root / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent")],
                                    env=unnamed_env(root), cwd=root, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("resolved the workspace but returned no root", result.stderr)
            self.assertIn("nothing installed", result.stderr)
            self.assertFalse(prefix.exists(), "an empty-root resolved workspace was installed")

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

    # #39224: the gate resolves its helper beside itself first, so a prefix
    # that holds only the server runs whatever helper was installed last. The
    # install must put the pair in the prefix with the server.
    def test_the_preflight_pair_is_installed_with_the_server(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            preflight_helper(build)
            prefix = root / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                                     "--base-path", str(workspace(root))],
                                    check=True, capture_output=True, text=True)
            self.assertTrue((prefix / "masc-deployment-preflight-helper").is_file())
            self.assertTrue((prefix / "masc-check-runtime-deployment-preflight").is_file())
            # The installed gate must look for its helper beside itself, which
            # is the line that makes the pair matter.
            gate = (prefix / "masc-check-runtime-deployment-preflight").read_text()
            self.assertIn('"$SCRIPT_DIR/masc-deployment-preflight-helper"', gate)
            self.assertIn("masc-deployment-preflight-helper", result.stdout)

    # Without a helper there is no pair to install: the WARN above already
    # says why, and the server installs alone as before.
    def test_no_helper_installs_the_server_without_a_half_pair(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            prefix = root / "prefix"
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                                     "--base-path", str(workspace(root))],
                                    check=True, capture_output=True, text=True)
            self.assertTrue((prefix / "masc").is_file())
            self.assertFalse((prefix / "masc-deployment-preflight-helper").exists())
            self.assertFalse((prefix / "masc-check-runtime-deployment-preflight").exists())

    # A prefix that already holds an older pair from a previous install must
    # not be left running that stale gate against an upgraded server: that is
    # the exact mismatch #39224 reports, just reached through --skip-build.
    def test_no_helper_with_a_pre_existing_pair_refuses_and_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            prefix = root / "prefix"
            prefix.mkdir()
            old_masc = executable(prefix / "masc", "old masc")
            old_gate = executable(prefix / "masc-check-runtime-deployment-preflight", "old gate")
            old_helper = executable(prefix / "masc-deployment-preflight-helper", "old helper")
            before_masc, before_gate, before_helper = (
                old_masc.read_text(), old_gate.read_text(), old_helper.read_text())
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                                     "--base-path", str(workspace(root))],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already holds a deployment preflight pair", result.stderr)
            self.assertIn(str(build / "deployment_preflight_helper.exe"), result.stderr)
            self.assertEqual(old_gate.read_text(), before_gate, "stale gate was touched")
            self.assertEqual(old_helper.read_text(), before_helper, "stale helper was touched")
            self.assertEqual(old_masc.read_text(), before_masc,
                              "server was upgraded while the stale pair stayed callable")


if __name__ == "__main__":
    unittest.main()
