#!/usr/bin/env python3
"""A local install brings every registered browser lane host to the new build."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/install-local-build.sh"
BROWSER_ADDON_PROGRAMS = ("masc_native_addon_launcher", "masc_browser_addon_worker", "masc_browser_process_owner")


def executable(path, text):
    path.write_text("#!/bin/sh\necho " + text + "\n")
    path.chmod(0o755)
    return path


# Stands in for the masc the script installs. A browser-lane-setup call is
# recorded as one JSON list of its arguments per line in lane-calls beside it,
# so an argument that holds a space stays one argument. What it does stands for
# what the real command does to a workspace: it copies the host it was given
# beside the launcher and leaves the registration as it was. A workspace whose
# path holds "fails" makes it exit 3; one that holds "stale" makes it exit 0
# without copying the host; one that holds "moves" makes it register the lane
# somewhere else, as the real command does with a path it trims or strips a
# trailing .masc from. A --mode addon call is recorded in addon-calls instead,
# and exits 5 for a workspace whose path holds "addon-refused" and 3, as for a
# workspace with no config root yet, for one that holds "addon-unconfigured". The real
# command is run by test_browser_lane_setup_cli.py. Any other call only says
# which binary it is.
FAKE_MASC = '''#!{python}
import json, shutil, sys
from pathlib import Path
here = Path(sys.argv[0]).resolve().parent
if sys.argv[1:2] != ["browser-lane-setup"]:
    print("masc")
    sys.exit(0)
args = sys.argv[1:]
options = dict(zip(args[1::2], args[2::2]))
base = Path(options["--base-path"])
if options["--mode"] == "addon":
    with open(here / "addon-calls", "a") as log:
        log.write(json.dumps(args) + "\\n")
    if "addon-refused" in str(base):
        sys.exit(5)
    sys.exit(3 if "addon-unconfigured" in str(base) else 0)
with open(here / "lane-calls", "a") as log:
    log.write(json.dumps(args) + "\\n")
if "fails" in str(base):
    sys.exit(3)
if "stale" in str(base):
    sys.exit(0)
if options["--mode"] == "host":
    # The host and the launcher only: no registration to read or write. A path
    # that holds "partial" fails after the host was written, as masc does when a
    # later step cannot be.
    host = base / ".masc/browser-lane/host/masc-browser-host"
    host.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(options["--binary"], host)
    sys.exit(4 if "partial" in str(base) else 0)
registration = Path(options["--manifest-dir"]) / (options["--host-name"] + ".json")
if "moves" in str(base):
    registration.write_text(json.dumps({{"name": options["--host-name"],
                                        "path": "/elsewhere/.masc/browser-lane/host/launch"}}))
    sys.exit(0)
host = base / ".masc/browser-lane/host/masc-browser-host"
host.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(options["--binary"], host)
'''


def fake_masc(path):
    path.write_text(FAKE_MASC.format(python=sys.executable))
    path.chmod(0o755)
    return path


def lane_calls(prefix):
    calls = prefix / "lane-calls"
    return [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []


def addon_calls(prefix):
    calls = prefix / "addon-calls"
    return [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []


def host_call(prefix, base):
    return ["browser-lane-setup", "--mode", "host", "--binary", str(prefix / "masc-browser-host"),
            "--base-path", str(base)]


# A lane installed for a workspace as masc reads it: the launcher and the
# declaration beside it, with the host copy an older build left.
def install_lane(base, host_text="old", launcher=True, extension=False):
    host_directory = base / ".masc/browser-lane/host"
    host_directory.mkdir(parents=True, exist_ok=True)
    if launcher:
        (host_directory / "launch").write_text("#!/bin/sh\n")
    (host_directory / "launch.json").write_text("{}")
    (host_directory / "masc-browser-host").write_text(host_text)
    if extension:
        (base / ".masc/browser-lane/extension").mkdir(parents=True, exist_ok=True)
        (base / ".masc/browser-lane/extension/manifest.json").write_text("{}")


def lane_call(prefix, base, name, manifests):
    return ["browser-lane-setup", "--mode", "extension", "--binary", str(prefix / "masc-browser-host"),
            "--base-path", str(base), "--host-name", name, "--manifest-dir", str(manifests)]


# A workspace whose lane is registered with Firefox under [name]: the native
# messaging manifest whose launcher lives under the workspace's
# .masc/browser-lane/host, which is what the script looks for.
def register(manifests, base, name):
    host_directory = base / ".masc/browser-lane/host"
    host_directory.mkdir(parents=True, exist_ok=True)
    manifests.mkdir(exist_ok=True)
    (manifests / f"{name}.json").write_text(
        json.dumps({"name": name, "path": str(host_directory / "launch")}))


# Stands in for the new build's deployment preflight helper and records every
# call in helper-calls beside it. install-local-build asks it which workspace
# masc would use; the gate asks for its identity and filenames, then for the
# runtime.toml verdict, and install-local-build then asks for the stored-state
# verdict. [unnamed_workspace] is what resolve-workspace answers
# without --base-path: a (root, source) pair, a raw answer body for malformed
# answers, or None for no workspace. An [old] helper predates the check and
# knows neither subcommand.
def preflight_helper(build, verdict_exit=0, unnamed_workspace=None, old=False,
                     resolve_failure=False, stores_exit=0, resolve_failure_silent=False,
                     resolve_notice=None, resolve_hang=False, named_unresolved=False):
    path = build / "deployment_preflight_helper.exe"
    if unnamed_workspace is None:
        unnamed = "printf 'workspace=none\\n'"
    elif isinstance(unnamed_workspace, str):
        unnamed = f"printf '{unnamed_workspace}'"
    else:
        root, source = unnamed_workspace
        unnamed = f"printf 'workspace=resolved\\nroot=%s\\nsource=%s\\n' '{root}' '{source}'"
    notice = "" if resolve_notice is None else f"    echo '{resolve_notice}' >&2\n"
    hang = "    sleep 30\n" if resolve_hang else ""
    failure_message = "" if resolve_failure_silent else "echo 'fixture workspace lookup failed' >&2; "
    resolve = ("" if old else
               "  resolve-workspace) if [ \"$2\" = --help ]; then exit 0; fi; "
               f"{failure_message}exit 42 ;;\n"
               if resolve_failure or resolve_failure_silent else
               "  resolve-workspace)\n"
               + notice + hang +
               "    if [ \"$2\" = --base-path ]; then\n"
               + ("      printf 'workspace=none\\n'\n" if named_unresolved else
                  "      printf 'workspace=resolved\\nroot=%s\\nsource=explicit_cli\\n' \"$3\"\n") +
               f"    else {unnamed}; fi ;;\n")
    validate = ("" if old else
                f"  validate-runtime-config) echo 'runtime.toml fixture verdict'; exit {verdict_exit} ;;\n"
                f"  validate-stores) echo 'stored state fixture verdict'; exit {stores_exit} ;;\n")
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


# The browser Add-on programs every build installs beside masc.
def browser_addon_programs(build):
    for program in BROWSER_ADDON_PROGRAMS:
        executable(build / f"{program}.exe", program)


def binaries(build):
    for exe in ("main_eio.exe", "masc_tui.exe", "masc_browser_host.exe"):
        executable(build / exe, exe)
    browser_addon_programs(build)


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
    # Every browser route runs in the browser Add-on, so its programs come with
    # masc from the same build, and the masc just installed declares the Add-on
    # for the selected workspace.
    def test_browser_addon_programs_are_installed_and_the_addon_declared(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            fake_masc(build / "main_eio.exe")
            preflight_helper(build)
            prefix = root / "prefix"
            base = workspace(root)
            result = subprocess.run(
                ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                 "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                 "--base-path", str(base)],
                env=unnamed_env(root), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for program in BROWSER_ADDON_PROGRAMS:
                installed = prefix / program.replace("_", "-")
                self.assertEqual(installed.read_bytes(), (build / f"{program}.exe").read_bytes())
                self.assertTrue(os.access(installed, os.X_OK))
            self.assertEqual(addon_calls(prefix),
                             [["browser-lane-setup", "--mode", "addon", "--base-path", str(base)]])

    def test_no_browser_addon_installs_and_declares_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            for exe in ("masc_tui.exe", "masc_browser_host.exe"):
                executable(build / exe, exe)
            fake_masc(build / "main_eio.exe")
            preflight_helper(build)
            prefix = root / "prefix"
            base = workspace(root)
            install_lane(base)
            result = subprocess.run(
                ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                 "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                 "--base-path", str(base), "--no-browser-addon"],
                env=unnamed_env(root), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for program in BROWSER_ADDON_PROGRAMS:
                self.assertFalse((prefix / program.replace("_", "-")).exists())
            self.assertEqual(addon_calls(prefix), [])
            # The host refresh carries the choice, so setup does not declare it.
            self.assertEqual(lane_calls(prefix), [host_call(prefix, base) + ["--no-addon"]])

    def test_no_browser_addon_names_programs_an_earlier_install_left(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            for exe in ("main_eio.exe", "masc_tui.exe", "masc_browser_host.exe"):
                executable(build / exe, exe)
            preflight_helper(build)
            prefix = root / "prefix"
            prefix.mkdir()
            left = executable(prefix / "masc-browser-addon-worker", "an earlier worker")
            before = left.read_bytes()
            result = subprocess.run(
                ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                 "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                 "--base-path", str(workspace(root)), "--no-browser-addon"],
                env=unnamed_env(root), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(str(left), result.stderr)
            self.assertEqual(left.read_bytes(), before, "the earlier program is not removed")

    def test_no_browser_addon_leaves_its_programs_out_of_the_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            checkout = root / "checkout"
            scripts = checkout / "scripts"
            scripts.mkdir(parents=True)
            shutil.copy2(SCRIPT, scripts / SCRIPT.name)
            record = root / "build-call"
            guard = scripts / "dune-local.sh"
            guard.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$RECORD"\nexit 1\n')
            guard.chmod(0o755)
            result = subprocess.run(
                ["bash", str(scripts / SCRIPT.name), "--no-browser-addon", "--prefix",
                 str(root / "prefix"), "--manifest-dir", str(root / "absent")],
                env=dict(unnamed_env(root), RECORD=str(record)), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(record.read_text().splitlines(), [
                "build", "--root", str(checkout), "./bin/main_eio.exe", "./bin/masc_tui.exe",
                "./bin/masc_browser_host.exe", "./bin/deployment_preflight_helper.exe"])

    def test_a_missing_browser_addon_program_installs_nothing(self):
        for program in BROWSER_ADDON_PROGRAMS:
            with self.subTest(program=program), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                build = root / "build"
                build.mkdir()
                binaries(build)
                preflight_helper(build)
                (build / f"{program}.exe").unlink()
                prefix = root / "prefix"
                result = subprocess.run(
                    ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                     "--base-path", str(workspace(root))],
                    env=unnamed_env(root), capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{program}.exe", result.stderr)
                self.assertFalse(prefix.exists())

    def test_a_refused_addon_declaration_fails_the_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            fake_masc(build / "main_eio.exe")
            preflight_helper(build)
            prefix = root / "prefix"
            base = root / "addon-refused workspace"
            base.mkdir()
            install_lane(base)
            result = subprocess.run(
                ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                 "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                 "--base-path", str(base)],
                env=unnamed_env(root), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("browser Add-on", result.stderr)
            self.assertTrue((prefix / "masc").is_file(), "the programs stay installed")
            # The refusal waits for the host refresh, so the lane still gets
            # the new host.
            self.assertEqual(lane_calls(prefix), [host_call(prefix, base)])
            self.assertEqual((base / ".masc/browser-lane/host/masc-browser-host").read_bytes(),
                             (prefix / "masc-browser-host").read_bytes())

    def run_addon_install(self, root, base):
        build = root / "build"
        build.mkdir()
        binaries(build)
        fake_masc(build / "main_eio.exe")
        preflight_helper(build)
        prefix = root / "prefix"
        result = subprocess.run(
            ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
             "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
             "--base-path", str(base)],
            env=unnamed_env(root), capture_output=True, text=True)
        return result, prefix

    # The first server start writes the config root, so the install goes on
    # and says what to run after it.
    def test_a_workspace_without_a_config_root_yet_is_noted_and_installed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base = root / "addon-unconfigured workspace"
            base.mkdir()
            result, prefix = self.run_addon_install(root, base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(addon_calls(prefix)), 1)
            self.assertIn("browser Add-on is not declared yet", result.stdout)
            self.assertIn(f"--mode addon --base-path {base}", result.stdout)

    def test_a_refused_addon_and_a_failed_refresh_are_both_reported(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base = root / "addon-refused fails workspace"
            base.mkdir()
            install_lane(base)
            result, _ = self.run_addon_install(root, base)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn(f"could not refresh browser lane host for {base}", result.stderr)
            self.assertIn(f"the browser Add-on of {base} is not set up", result.stderr)

    def test_a_workspace_that_does_not_exist_yet_gets_no_addon_declaration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            fake_masc(build / "main_eio.exe")
            preflight_helper(build)
            prefix = root / "prefix"
            base = root / "not created yet"
            result = subprocess.run(
                ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                 "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                 "--base-path", str(base)],
                env=unnamed_env(root), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(addon_calls(prefix), [])
            self.assertFalse(base.exists(), "the workspace is not created")

    # An install that cannot run the check stops before it replaces a binary or
    # cleans the build tree, so the selected workspace and the build stay.
    def test_a_build_without_a_current_helper_installs_and_cleans_nothing(self):
        for helper_kind in ("missing", "old", "no_workspace"):
            with self.subTest(helper_kind=helper_kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                checkout = root / "checkout"
                scripts = checkout / "scripts"
                scripts.mkdir(parents=True)
                shutil.copy2(SCRIPT, scripts / SCRIPT.name)
                build_root = checkout / "_build"
                build = build_root / "default/bin"
                build.mkdir(parents=True)
                binaries(build)
                selected = build_root / "live workspace"
                (selected / ".masc").mkdir(parents=True)
                state = selected / ".masc/durable-state"
                state.write_text("operator state")
                if helper_kind == "old":
                    preflight_helper(build, old=True)
                    executable(scripts / "check-runtime-deployment-preflight.sh", "fixture-preflight")
                if helper_kind == "no_workspace":
                    preflight_helper(build)
                artifact = build_root / "cache-artifact"
                artifact.write_text("regenerable")
                wrapper = scripts / "dune-local.sh"
                wrapper.write_text(
                    "#!/bin/sh\n"
                    'repo=$(cd "$(dirname "$0")/.." && pwd -P)\n'
                    'printf "%s\\n" "$1" >> "$repo/calls"\n'
                    'if [ "$1" = clean ]; then rm -rf "$repo/_build"; fi\n')
                wrapper.chmod(0o755)
                prefix = root / "prefix"
                command = ["bash", str(scripts / SCRIPT.name), "--prefix", str(prefix),
                           "--manifest-dir", str(root / "absent-manifests")]
                if helper_kind != "no_workspace":
                    command += ["--base-path", str(selected)]
                result = subprocess.run(
                    command,
                    cwd=root,
                    env=dict(unnamed_env(root), MASC_DUNE_LOCK_HELD="1"),
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("nothing installed", result.stderr)
                # The build ran here, so --skip-build is not advice for this run.
                self.assertNotIn("--skip-build", result.stderr)
                self.assertFalse(prefix.exists(), "a binary was installed without the check")
                self.assertEqual(state.read_text(), "operator state")
                self.assertTrue(artifact.exists(), "the build tree was cleaned after a refused install")
                self.assertEqual((checkout / "calls").read_text().splitlines(), ["build"])

    def test_cleanup_protects_selected_workspace_state(self):
        for location in ("inside", "build_root", "symlink_inside", "outside"):
            for explicit in (False, True):
                with self.subTest(location=location, explicit=explicit), \
                        tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary).resolve()
                    checkout = root / "checkout"
                    scripts = checkout / "scripts"
                    scripts.mkdir(parents=True)
                    shutil.copy2(SCRIPT, scripts / SCRIPT.name)
                    build_root = checkout / "_build"
                    build = build_root / "default/bin"
                    build.mkdir(parents=True)
                    binaries(build)
                    artifact = build_root / "cache-artifact"
                    artifact.write_text("regenerable")
                    if location == "build_root":
                        selected = build_root
                    elif location == "outside":
                        selected = root / "live workspace"
                    else:
                        selected = build_root / "live workspace"
                    (selected / ".masc").mkdir(parents=True)
                    state = selected / ".masc/durable-state"
                    state.write_text("operator state")
                    if location == "symlink_inside":
                        alias = root / "workspace alias"
                        alias.symlink_to(selected, target_is_directory=True)
                        selected = alias
                    preflight_helper(build, unnamed_workspace=(selected, "persisted_default"))
                    executable(scripts / "check-runtime-deployment-preflight.sh", "fixture-preflight")
                    wrapper = scripts / "dune-local.sh"
                    wrapper.write_text(
                        "#!/bin/sh\n"
                        'repo=$(cd "$(dirname "$0")/.." && pwd -P)\n'
                        'printf "%s\\n" "$1" >> "$repo/calls"\n'
                        'if [ "$1" = clean ]; then rm -rf "$repo/_build"; fi\n')
                    wrapper.chmod(0o755)
                    prefix = root / "prefix"
                    command = ["bash", str(scripts / SCRIPT.name), "--prefix", str(prefix),
                               "--manifest-dir", str(root / "absent-manifests")]
                    if explicit:
                        command += ["--base-path", str(selected)]
                    env = {key: value for key, value in unnamed_env(root).items()
                           if key not in ("DUNE_BUILD_DIR", "MASC_DUNE_DRY_RUN")}
                    env["MASC_DUNE_LOCK_HELD"] = "1"
                    result = subprocess.run(command, cwd=root, env=env,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue((prefix / "masc").is_file())
                    self.assertIn(f"checking runtime.toml of {selected}", result.stdout)
                    self.assertTrue(state.exists(), "successful installation removed workspace state")
                    self.assertEqual(state.read_text(), "operator state")
                    protected = location in ("inside", "build_root", "symlink_inside")
                    self.assertEqual(artifact.exists(), protected)
                    self.assertEqual((checkout / "calls").read_text().splitlines(),
                                     ["build"] if protected else ["build", "clean"])

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
                preflight_helper(build)
                executable(scripts / "check-runtime-deployment-preflight.sh", "fixture-preflight")
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
                     "--manifest-dir", str(root / "absent"),
                     "--base-path", str(workspace(root)), *flags],
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
            # Two workspaces registered with Firefox, one under the default
            # host name and one under an isolated, dotted name. The second
            # workspace's path holds a space, a quote and a dollar sign.
            first, second = root / "workspace one", root / "workspace ' two $x"
            lanes = ((first, "masc_browser_host"), (second, "masc.browser.host_second"))
            for base, name in lanes:
                register(manifests, base, name)
            # A host that is not a workspace browser lane must be left alone.
            unrelated = manifests / "com.example.password.json"
            unrelated.write_text(json.dumps({"name": "com.example.password", "path": str(root / "elsewhere/launch")}))
            before_unrelated = unrelated.read_text()

            build = root / "build"
            build.mkdir()
            fake_masc(build / "main_eio.exe")
            executable(build / "masc_tui.exe", "tui")
            executable(build / "masc_browser_host.exe", "new")
            browser_addon_programs(build)
            preflight_helper(build)
            prefix = root / "prefix"

            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(manifests),
                                     "--base-path", str(workspace(root))],
                                    check=True, capture_output=True, text=True)

            for name, marker in (("masc", "masc"), ("masc-tui", "tui"), ("masc-browser-host", "new")):
                self.assertIn(marker, (prefix / name).read_text())
            # Each registered workspace is brought to the new host by the masc
            # that was just installed, under the host name it was registered
            # with; the unrelated host is not asked about.
            self.assertEqual(sorted(lane_calls(prefix)),
                             sorted(lane_call(prefix, base, name, manifests) for base, name in lanes))
            for base, name in lanes:
                self.assertIn(f"refreshed browser lane host {name} for {base}", result.stdout)
                self.assertIn("new", (base / ".masc/browser-lane/host/masc-browser-host").read_text())
            self.assertEqual(unrelated.read_text(), before_unrelated)
            self.assertFalse((root / "elsewhere").exists())

    def run_script_with_registered_lanes(self, root, lanes):
        manifests = root / "native manifests"
        for base, name in lanes:
            register(manifests, base, name)
        build = root / "build"
        build.mkdir()
        fake_masc(build / "main_eio.exe")
        executable(build / "masc_tui.exe", "tui")
        executable(build / "masc_browser_host.exe", "new")
        browser_addon_programs(build)
        preflight_helper(build)
        prefix = root / "prefix"
        result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                 "--prefix", str(prefix), "--manifest-dir", str(manifests),
                                 "--base-path", str(workspace(root))],
                                capture_output=True, text=True)
        return result, prefix, manifests

    def test_a_workspace_that_cannot_be_refreshed_does_not_stop_the_others(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            # Manifests are walked in file name order: the one that fails is first.
            failing = (root / "ws fails", "masc_a_failing")
            others = ((root / "ws b", "masc_b"), (root / "ws c", "masc_c"))
            result, prefix, _ = self.run_script_with_registered_lanes(root, (failing, *others))
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(len(lane_calls(prefix)), 3)
            self.assertIn("could not refresh browser lane host masc_a_failing", result.stderr)
            self.assertIn("exited 3", result.stderr)
            self.assertNotIn("refreshed browser lane host masc_a_failing", result.stdout)
            for base, name in others:
                self.assertIn(f"refreshed browser lane host {name} for {base}", result.stdout)
                self.assertIn("new", (base / ".masc/browser-lane/host/masc-browser-host").read_text())
            # The binaries were installed before any workspace was refreshed.
            self.assertTrue((prefix / "masc-browser-host").is_file())

    def test_a_refresh_that_registers_another_workspace_is_refused_and_undone(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            moved = (root / "ws moves", "masc_moved")
            result, prefix, manifests = self.run_script_with_registered_lanes(root, (moved,))
            registration = manifests / "masc_moved.json"
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("another workspace", result.stderr)
            self.assertNotIn("refreshed browser lane host masc_moved", result.stdout)
            # The registration is as it was before masc rewrote it.
            self.assertEqual(json.loads(registration.read_text()),
                             {"name": "masc_moved",
                              "path": str(moved[0] / ".masc/browser-lane/host/launch")})

    def test_a_refresh_that_leaves_the_old_host_is_reported_not_trusted(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            stale = root / "ws stale"
            old_copy = stale / ".masc/browser-lane/host/masc-browser-host"
            old_copy.parent.mkdir(parents=True)
            old_copy.write_text("old")
            result, _, _ = self.run_script_with_registered_lanes(root, ((stale, "masc_stale"),))
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("is not the host just installed", result.stderr)
            self.assertNotIn("refreshed browser lane host masc_stale", result.stdout)
            self.assertEqual(old_copy.read_text(), "old")

    @unittest.skipUnless(shutil.which("zsh"), "zsh's zsystem flock holds the fcntl lock a BiDi host holds")
    def test_the_extension_host_is_stopped_and_the_running_bidi_host_is_kept(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            manifests = root / "native manifests"
            base = root / "workspace one"
            register(manifests, base, "masc_browser_host")
            host = base / ".masc/browser-lane/host/masc-browser-host"
            lock = base / ".masc/browser-lane/bidi-host.lock"
            lock.touch()

            # Each runs as the workspace's copy of the host with the arguments
            # it was given, which is what ps shows. A shell builtin waits on
            # stdin, so no other process is started.
            def running_as_host(*arguments):
                return subprocess.Popen(["bash", "-c", 'exec -a "$0" /bin/bash -c "read line" "$0" "$@"',
                                         str(host), *arguments], stdin=subprocess.PIPE)

            # The BiDi host holds the workspace's host lock, a lockf (fcntl)
            # lock (lib/browser_bidi_host_record.ml); zsystem flock takes the
            # same kind.
            bidi = subprocess.Popen(
                ["bash", "-c",
                 """exec -a "$0" zsh -c 'zmodload zsh/system; zsystem flock -f fd "$1"; print locked; read line' "$0" "$1" """,
                 str(host), str(lock)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            # ps joins arguments with spaces, so a path can read as a flag.
            extension = running_as_host(str(root / "native manifests --bidi-url x/masc_browser_host.json"),
                                        "masc@yousleepwhen")
            # Given --bidi-url, but another holds the lock: such a host is
            # refused and ends; nothing marks it as the workspace's host.
            unlocked = running_as_host("--bidi-url", "ws://127.0.0.1:9222/session")
            processes = (bidi, extension, unlocked)
            try:
                self.assertEqual(bidi.stdout.readline(), b"locked\n")
                # A host that was killed leaves its record without an ending,
                # and its pid may now be another process's.
                (base / ".masc/browser-lane/bidi-host.json").write_text(
                    json.dumps({"pid": extension.pid, "ended": None}))
                build = root / "build"
                build.mkdir()
                for exe in ("masc_tui.exe", "masc_browser_host.exe"):
                    executable(build / exe, exe)
                browser_addon_programs(build)
                fake_masc(build / "main_eio.exe")
                preflight_helper(build)
                result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                         "--prefix", str(root / "prefix"), "--manifest-dir", str(manifests),
                                         "--base-path", str(workspace(root))],
                                        check=True, capture_output=True, text=True)
                self.assertEqual(extension.wait(timeout=10), -15, result.stdout)
                self.assertEqual(unlocked.wait(timeout=10), -15, result.stdout)
                self.assertIsNone(bidi.poll(), "the BiDi host was stopped")
                stopped = re.search(r"stopped host pid ([0-9, ]+); Firefox starts the new copy", result.stdout)
                self.assertIsNotNone(stopped, result.stdout)
                self.assertEqual(sorted(stopped.group(1).split(", ")), sorted([str(extension.pid), str(unlocked.pid)]))
                self.assertIn(f"kept BiDi host pid {bidi.pid}, which nothing would start again", result.stdout)
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    process.stdin.close()
                bidi.stdout.close()

    # A lane set up with --mode bidi or --mode host registers no manifest, so
    # the manifests cannot lead to it; the workspace the install works with is
    # looked at as well.
    def run_script_for_workspace(self, root, base, lanes=()):
        manifests = root / "native manifests"
        for lane_base, name in lanes:
            register(manifests, lane_base, name)
        build = root / "build"
        build.mkdir()
        fake_masc(build / "main_eio.exe")
        executable(build / "masc_tui.exe", "tui")
        executable(build / "masc_browser_host.exe", "new")
        browser_addon_programs(build)
        preflight_helper(build)
        prefix = root / "prefix"
        result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                 "--prefix", str(prefix), "--manifest-dir", str(manifests),
                                 "--base-path", str(base)],
                                capture_output=True, text=True)
        return result, prefix

    def test_the_selected_workspaces_lane_with_no_manifest_gets_the_new_host(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            base = workspace(root)
            install_lane(base)
            result, prefix = self.run_script_for_workspace(root, base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(lane_calls(prefix), [host_call(prefix, base)])
            self.assertIn("new", (base / ".masc/browser-lane/host/masc-browser-host").read_text())
            self.assertIn(f"refreshed browser lane host for {base} (no host running)", result.stdout)
            self.assertNotIn("no browser lane host is registered", result.stdout)

    def test_a_selected_workspace_that_is_registered_is_refreshed_once_by_its_manifest(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            base = workspace(root)
            install_lane(base)
            result, prefix = self.run_script_for_workspace(root, base, lanes=((base, "masc_browser_host"),))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(lane_calls(prefix),
                             [lane_call(prefix, base, "masc_browser_host", root / "native manifests")])

    def test_registered_lanes_and_the_selected_workspace_are_all_refreshed(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            base, other = workspace(root), root / "other workspace"
            install_lane(base)
            result, prefix = self.run_script_for_workspace(root, base, lanes=((other, "masc_other"),))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(sorted(lane_calls(prefix)),
                             sorted([host_call(prefix, base),
                                     lane_call(prefix, other, "masc_other", root / "native manifests")]))

    def test_a_selected_workspace_with_no_installed_lane_is_left_alone(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            base = workspace(root)
            # A host copy with no declaration is not an installed lane.
            host = base / ".masc/browser-lane/host/masc-browser-host"
            host.parent.mkdir(parents=True)
            host.write_text("old")
            result, prefix = self.run_script_for_workspace(root, base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(lane_calls(prefix), [])
            self.assertEqual(host.read_text(), "old")
            self.assertIn("no browser lane host is registered", result.stdout)

    def test_a_host_refresh_that_leaves_the_old_copy_is_reported_and_fails_the_install(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            base = root / "stale workspace"
            base.mkdir()
            install_lane(base)
            result, prefix = self.run_script_for_workspace(root, base)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn(f"could not refresh browser lane host for {base}", result.stderr)
            self.assertIn("is not the host just installed", result.stderr)
            self.assertNotIn("refreshed browser lane host", result.stdout)
            self.assertTrue((prefix / "masc-browser-host").is_file(), "the binaries were installed first")

    def test_a_launcher_without_its_declaration_or_the_reverse_is_not_an_installed_lane(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            base = workspace(root)
            install_lane(base, launcher=False)
            result, prefix = self.run_script_for_workspace(root, base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(lane_calls(prefix), [])
            self.assertFalse((base / ".masc/browser-lane/host/launch").exists())

    def test_a_lane_with_an_extension_and_no_manifest_here_is_named_and_left_alone(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            base = workspace(root)
            install_lane(base, extension=True)
            result, prefix = self.run_script_for_workspace(root, base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(lane_calls(prefix), [])
            self.assertIn("old", (base / ".masc/browser-lane/host/masc-browser-host").read_text())
            self.assertIn(f"WARN the browser lane of {base} has an extension and no manifest", result.stderr)

    def test_a_manifest_covers_the_selected_workspace_under_another_spelling_of_its_path(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            real = root / "real workspace"
            real.mkdir()
            link = root / "link workspace"
            link.symlink_to(real)
            install_lane(real)
            # Registered under a path that leads there through a link, and
            # selected as the exact directory, which is all the preflight check
            # accepts.
            result, prefix = self.run_script_for_workspace(root, real, lanes=((link, "masc_browser_host"),))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(lane_calls(prefix),
                             [lane_call(prefix, link, "masc_browser_host", root / "native manifests")])

    def test_a_manifest_that_cannot_name_a_path_is_skipped_and_the_rest_are_refreshed(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            base = workspace(root)
            install_lane(base)
            manifests = root / "native manifests"
            manifests.mkdir()
            (manifests / "nul.json").write_text(json.dumps(
                {"name": "nul", "path": "/nowhere\u0000/.masc/browser-lane/host/launch"}))
            result, prefix = self.run_script_for_workspace(root, base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(lane_calls(prefix), [host_call(prefix, base)])

    def test_a_host_refresh_that_masc_fails_is_named_by_its_exit_status(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            base = root / "fails workspace"
            base.mkdir()
            install_lane(base)
            result, _ = self.run_script_for_workspace(root, base)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn(f"could not refresh browser lane host for {base}: masc browser-lane-setup exited 3",
                          result.stderr)

    def test_a_refresh_that_writes_the_host_and_then_fails_is_still_a_failure(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            base = root / "partial workspace"
            base.mkdir()
            install_lane(base)
            result, _ = self.run_script_for_workspace(root, base)
            self.assertIn("new", (base / ".masc/browser-lane/host/masc-browser-host").read_text())
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("masc browser-lane-setup exited 4", result.stderr)
            self.assertNotIn("refreshed browser lane host", result.stdout)

    def test_the_selected_workspaces_running_host_is_stopped(self):
        with tempfile.TemporaryDirectory(prefix="local build ' ") as temporary:
            root = Path(temporary).resolve()
            base = workspace(root)
            install_lane(base)
            host = base / ".masc/browser-lane/host/masc-browser-host"
            # A host runs as the copy its launcher names, with the arguments it
            # was given, which is what ps shows.
            running = subprocess.Popen(["bash", "-c", 'exec -a "$0" /bin/bash -c "read line" "$0"', str(host)],
                                       stdin=subprocess.PIPE)
            try:
                result, _ = self.run_script_for_workspace(root, base)
                self.assertEqual(running.wait(timeout=10), -15, result.stdout)
                self.assertIn(f"refreshed browser lane host for {base} (stopped host pid {running.pid}; "
                              "Firefox starts the new copy)", result.stdout)
            finally:
                if running.poll() is None:
                    running.kill()
                    running.wait()
                running.stdin.close()

    def test_no_registered_host_installs_binaries_and_says_so(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
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
            binaries(build)
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
            self.assertFalse(any(call.startswith("validate-stores") for call in helper_calls(build)))

    # #43483: a store this build cannot decode stops the install the way the
    # deploy preflight stops a deploy. #42020 changed the Memory admission
    # queue file; the install went ahead and five Keepers could not write
    # explicit Memory for a week.
    def test_unreadable_stored_state_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            preflight_helper(build, stores_exit=124)
            prefix = root / "prefix"
            base = workspace(root)
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                                     "--base-path", str(base)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stored state fixture verdict", result.stdout)
            self.assertIn("nothing installed", result.stderr)
            self.assertIn("Fresh state required", result.stderr)
            self.assertIn(f"validate-stores --base-path {base}", helper_calls(build))
            self.assertFalse(prefix.exists(), "a build that cannot read the stored state was installed")

    # The stored state is read after runtime.toml passes and before anything
    # is replaced; a readable state lets the install go ahead.
    def test_readable_stored_state_is_checked_and_installed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            preflight_helper(build)
            prefix = root / "prefix"
            base = workspace(root)
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                                     "--base-path", str(base)],
                                    check=True, capture_output=True, text=True)
            self.assertIn(f"checking stored state of {base}", result.stdout)
            calls = helper_calls(build)
            self.assertLess(calls.index(f"validate-runtime-config --base-path {base}"),
                            calls.index(f"validate-stores --base-path {base}"))
            self.assertTrue((prefix / "masc").is_file())

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

    # An install that cannot run the check installs nothing and exits 2, and
    # says what to do about it.
    def test_no_workspace_found_installs_nothing(self):
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
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("--base-path DIR or set MASC_BASE_PATH", result.stderr)
            self.assertIn("nothing installed", result.stderr)
            self.assertFalse(any(call.startswith("validate-runtime-config") for call in helper_calls(build)))
            self.assertFalse(any(call.startswith("validate-stores") for call in helper_calls(build)))
            self.assertFalse(prefix.exists(), "a binary was installed without a workspace to check")

    def test_skip_build_without_the_helper_installs_nothing(self):
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
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn(str(build / "deployment_preflight_helper.exe"), result.stderr)
            self.assertIn("is missing", result.stderr)
            self.assertIn("drop --skip-build", result.stderr)
            self.assertIn("nothing installed", result.stderr)
            self.assertFalse(prefix.exists(), "a binary was installed without the helper")

    def test_skip_build_with_a_helper_older_than_the_check_installs_nothing(self):
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
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("predates the check", result.stderr)
            self.assertIn("nothing installed", result.stderr)
            # An old helper's unsupported-command noise stays suppressed even
            # when missing preflight support refuses the installation.
            self.assertNotIn("unexpected helper call", result.stderr)
            self.assertFalse(prefix.exists(), "a binary was installed by a helper that cannot check")

    def test_a_base_path_the_helper_cannot_resolve_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            preflight_helper(build, named_unresolved=True)
            prefix = root / "prefix"
            named = workspace(root)
            result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                     "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                                     "--base-path", str(named)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            # The user did pass --base-path, so the advice is not to pass it.
            self.assertIn(f"could not resolve --base-path {named}", result.stderr)
            self.assertNotIn("Pass --base-path", result.stderr)
            self.assertFalse(prefix.exists(), "a binary was installed for a workspace nobody resolved")

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
            self.assertIn("resolve-workspace exited with status 42", result.stderr)
            # The helper's own error is the cause; the install names it instead
            # of reporting a missing workspace.
            self.assertIn("fixture workspace lookup failed", result.stderr)
            self.assertFalse(prefix.exists(), "a failed new helper skipped validation and installed binaries")

    def run_with_private_tmpdir(self, root, build, *arguments):
        scratch = root / "scratch"
        scratch.mkdir()
        env = dict(unnamed_env(root), TMPDIR=str(scratch))
        result = subprocess.run(["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                                 "--prefix", str(root / "prefix"), "--manifest-dir", str(root / "absent"),
                                 *arguments],
                                env=env, cwd=root, capture_output=True, text=True)
        return result, sorted(path.name for path in scratch.glob("masc-resolve-workspace.*"))

    def test_the_workspace_lookup_leaves_no_temporary_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            outcomes = {
                "lookup succeeds": dict(),
                "lookup fails": dict(resolve_failure=True),
                "answer has no root": dict(
                    unnamed_workspace="workspace=resolved\\nsource=persisted_default\\n"),
                "answer is invalid": dict(unnamed_workspace="workspace=bogus\\n"),
            }
            for label, helper_arguments in outcomes.items():
                with self.subTest(outcome=label):
                    case = root / label.replace(" ", "-")
                    case.mkdir()
                    build = case / "build"
                    build.mkdir()
                    binaries(build)
                    preflight_helper(build, **helper_arguments)
                    named = ("--base-path", str(workspace(case))) if label in ("lookup succeeds", "lookup fails") else ()
                    result, left = self.run_with_private_tmpdir(case, build, *named)
                    self.assertEqual(left, [], result.stderr)

    def test_a_signal_during_the_workspace_lookup_leaves_no_temporary_file(self):
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=signum.name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                build = root / "build"
                build.mkdir()
                binaries(build)
                preflight_helper(build, resolve_hang=True)
                scratch = root / "scratch"
                scratch.mkdir()
                env = dict(unnamed_env(root), TMPDIR=str(scratch))
                # A signal ignored by the test runner is inherited and cannot be trapped.
                restore = lambda: [signal.signal(name, signal.SIG_DFL)
                                   for name in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)]
                process = subprocess.Popen(
                    ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                     "--prefix", str(root / "prefix"), "--manifest-dir", str(root / "absent"),
                     "--base-path", str(workspace(root))],
                    env=env, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=True, preexec_fn=restore)
                try:
                    # The helper records its call before it hangs, so the trap is set.
                    deadline = time.monotonic() + 30
                    while not any(call.startswith("resolve-workspace") for call in helper_calls(build)):
                        self.assertIsNone(process.poll(), "the install ended before the lookup began")
                        self.assertLess(time.monotonic(), deadline, "the lookup never began")
                        time.sleep(0.05)
                    os.killpg(process.pid, signum)
                    # Returns once every process of the group has closed the pipes.
                    process.communicate(timeout=30)
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.communicate()
                self.assertEqual(sorted(path.name for path in scratch.glob("masc-resolve-workspace.*")), [])

    def test_a_silent_helper_failure_says_there_was_no_error_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            preflight_helper(build, resolve_failure_silent=True)
            result, _ = self.run_with_private_tmpdir(root, build, "--base-path", str(workspace(root)))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("resolve-workspace exited with status 42", result.stderr)
            self.assertTrue(result.stderr.rstrip().endswith("Its error output:\n(none)"), result.stderr)

    # The helper that answers badly may also say why on stderr.
    def test_a_refused_workspace_answer_shows_the_helpers_error_output(self):
        answers = {
            "returned no root": "workspace=resolved\\nsource=persisted_default\\n",
            "returned an invalid workspace answer": "workspace=bogus\\n",
        }
        shown = {
            "a notice": ("fixture notice before the answer", "fixture notice before the answer"),
            "no notice": (None, "(none)"),
        }
        for refusal, answer in answers.items():
            for label, (notice, expected) in shown.items():
                with self.subTest(refusal=refusal, helper_stderr=label), \
                        tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary).resolve()
                    build = root / "build"
                    build.mkdir()
                    binaries(build)
                    preflight_helper(build, unnamed_workspace=answer, resolve_notice=notice)
                    result, _ = self.run_with_private_tmpdir(root, build)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(refusal, result.stderr)
                    self.assertTrue(result.stderr.rstrip().endswith(f"Its error output:\n{expected}"),
                                    result.stderr)

    def test_an_invalid_or_unobservable_workspace_preserves_installed_binaries(self):
        kinds = ["file", "file_parent", "broken_link", "broken_link_parent"]
        if os.geteuid() != 0:
            kinds.append("unsearchable_parent")
        for kind in kinds:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                build = root / "build"
                build.mkdir()
                binaries(build)
                preflight_helper(build)
                prefix = root / "prefix"
                prefix.mkdir()
                installed = {name: ("installed " + name).encode() for name in
                             ("masc", "masc-tui", "masc-browser-host",
                              "masc-deployment-preflight-helper", "masc-check-runtime-deployment-preflight")}
                for name, content in installed.items():
                    (prefix / name).write_bytes(content)
                selected = root / "selected"
                inaccessible = None
                if kind in ("file", "file_parent"):
                    selected.write_text("existing operator file")
                    if kind == "file_parent":
                        selected = selected / "workspace"
                elif kind in ("broken_link", "broken_link_parent"):
                    selected.symlink_to(root / "missing target", target_is_directory=True)
                    if kind == "broken_link_parent":
                        selected = selected / "workspace"
                else:
                    inaccessible = root / "private"
                    selected = inaccessible / "workspace"
                    selected.mkdir(parents=True)
                    inaccessible.chmod(0)
                try:
                    result = subprocess.run(
                        ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                         "--prefix", str(prefix), "--manifest-dir", str(root / "absent"),
                         "--base-path", str(selected), "--no-guest-shim"],
                        capture_output=True, text=True)
                finally:
                    if inaccessible is not None:
                        inaccessible.chmod(0o700)
                self.assertEqual(
                    {name: (prefix / name).read_bytes() for name in installed}, installed,
                    f"{kind} replaced binaries without an observable workspace: {result.stdout}")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("nothing installed", result.stderr)
                self.assertFalse(any(call.startswith(("validate-runtime-config", "validate-stores"))
                                     for call in helper_calls(build)))

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
            self.assertFalse(any(call.startswith("validate-stores") for call in helper_calls(build)))
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
                                         "./bin/deployment_preflight_helper.exe",
                                         *[f"./bin/{program}.exe" for program in BROWSER_ADDON_PROGRAMS]])

    def test_dune_local_takes_the_install_build_line(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
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
            self.assertIn("masc-deployment-preflight-helper", result.stdout)

    # A prefix that already holds an older pair from a previous install is not
    # touched when the install is refused for want of a helper: the stale gate
    # stays callable only with the server it was installed with (#39224).
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
            self.assertIn("is missing", result.stderr)
            self.assertIn("nothing installed", result.stderr)
            self.assertIn(str(build / "deployment_preflight_helper.exe"), result.stderr)
            self.assertEqual(old_gate.read_text(), before_gate, "stale gate was touched")
            self.assertEqual(old_helper.read_text(), before_helper, "stale helper was touched")
            self.assertEqual(old_masc.read_text(), before_masc,
                              "the server was replaced by an install that was refused")


if __name__ == "__main__":
    unittest.main()
