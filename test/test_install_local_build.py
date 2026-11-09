#!/usr/bin/env python3
"""A local install puts one build into the prefix and declares its browser Add-on."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/install-local-build.sh"
BROWSER_ADDON_PROGRAMS = ("masc_native_addon_launcher", "masc_browser_addon_worker")


def executable(path, text):
    path.write_text("#!/bin/sh\necho " + text + "\n")
    path.chmod(0o755)
    return path


# Stands in for the masc the script installs. A browser-lane-setup call is
# recorded as one JSON list of its arguments per line in addon-calls beside it,
# so an argument that holds a space stays one argument. It exits 5 for a
# workspace whose path holds "addon-refused" and 3, as for a workspace with no
# config root yet, for one that holds "addon-unconfigured". The real command is
# run by test_browser_lane_setup_cli.py. Any other call only says which binary
# it is.
FAKE_MASC = '''#!{python}
import json, sys
from pathlib import Path
here = Path(sys.argv[0]).resolve().parent
if sys.argv[1:2] != ["browser-lane-setup"]:
    print("masc")
    sys.exit(0)
args = sys.argv[1:]
options = dict(zip(args[1::2], args[2::2]))
base = Path(options["--base-path"])
with open(here / "addon-calls", "a") as log:
    log.write(json.dumps(args) + "\\n")
if "addon-refused" in str(base):
    sys.exit(5)
sys.exit(3 if "addon-unconfigured" in str(base) else 0)
'''


def fake_masc(path):
    path.write_text(FAKE_MASC.format(python=sys.executable))
    path.chmod(0o755)
    return path


def addon_calls(prefix):
    calls = prefix / "addon-calls"
    return [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []


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
    for exe in ("main_eio.exe", "masc_tui.exe", "masc_exec_ssh_bootstrap.exe", "masc_antigravity_path_hook.exe"):
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
                 "--prefix", str(prefix),
                 "--base-path", str(base)],
                env=unnamed_env(root), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            bootstrap = prefix / "masc-exec-ssh-bootstrap"
            self.assertEqual(bootstrap.read_bytes(), (build / "masc_exec_ssh_bootstrap.exe").read_bytes())
            self.assertTrue(os.access(bootstrap, os.X_OK))
            hook = prefix / "masc-antigravity-path-hook"
            self.assertEqual(hook.read_bytes(), (build / "masc_antigravity_path_hook.exe").read_bytes())
            self.assertTrue(os.access(hook, os.X_OK))
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
            for exe in ("masc_tui.exe", "masc_exec_ssh_bootstrap.exe", "masc_antigravity_path_hook.exe"):
                executable(build / exe, exe)
            fake_masc(build / "main_eio.exe")
            preflight_helper(build)
            prefix = root / "prefix"
            base = workspace(root)
            result = subprocess.run(
                ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                 "--prefix", str(prefix),
                 "--base-path", str(base), "--no-browser-addon"],
                env=unnamed_env(root), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for program in BROWSER_ADDON_PROGRAMS:
                self.assertFalse((prefix / program.replace("_", "-")).exists())
            self.assertEqual(addon_calls(prefix), [])

    def test_no_browser_addon_names_programs_an_earlier_install_left(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            for exe in ("main_eio.exe", "masc_tui.exe", "masc_exec_ssh_bootstrap.exe", "masc_antigravity_path_hook.exe"):
                executable(build / exe, exe)
            preflight_helper(build)
            prefix = root / "prefix"
            prefix.mkdir()
            left = executable(prefix / "masc-browser-addon-worker", "an earlier worker")
            before = left.read_bytes()
            result = subprocess.run(
                ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                 "--prefix", str(prefix),
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
                 str(root / "prefix")],
                env=dict(unnamed_env(root), RECORD=str(record)), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(record.read_text().splitlines(), [
                "build", "--root", str(checkout), "./bin/main_eio.exe", "./bin/masc_tui.exe",
                "./bin/deployment_preflight_helper.exe", "./bin/masc_exec_ssh_bootstrap.exe",
                "./bin/masc_antigravity_path_hook.exe"])

    def test_missing_ssh_bootstrap_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            build.mkdir()
            binaries(build)
            preflight_helper(build)
            (build / "masc_exec_ssh_bootstrap.exe").unlink()
            prefix = root / "prefix"
            prefix.mkdir()
            previous = executable(prefix / "masc", "old masc").read_bytes()
            result = subprocess.run(
                ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                 "--prefix", str(prefix),
                 "--base-path", str(workspace(root)), "--no-browser-addon"],
                env=unnamed_env(root), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("masc_exec_ssh_bootstrap.exe", result.stderr)
            self.assertEqual((prefix / "masc").read_bytes(), previous)
            self.assertFalse((prefix / "masc-tui").exists())

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
                     "--prefix", str(prefix),
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
            result = subprocess.run(
                ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
                 "--prefix", str(prefix),
                 "--base-path", str(base)],
                env=unnamed_env(root), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("browser Add-on", result.stderr)
            self.assertTrue((prefix / "masc").is_file(), "the programs stay installed")
            self.assertIn(f"the browser Add-on of {base} is not set up", result.stderr)

    def run_addon_install(self, root, base):
        build = root / "build"
        build.mkdir()
        binaries(build)
        fake_masc(build / "main_eio.exe")
        preflight_helper(build)
        prefix = root / "prefix"
        result = subprocess.run(
            ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
             "--prefix", str(prefix),
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
                 "--prefix", str(prefix),
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
                command = ["bash", str(scripts / SCRIPT.name), "--prefix", str(prefix)]
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

    def test_install_retains_build_and_selected_workspace_state(self):
        for location in ("inside", "build_root", "symlink_inside", "outside"):
            for explicit in (False, True):
                with self.subTest(location=location, explicit=explicit), \
                        tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary).resolve()
                    checkout = root / "checkout"
                    scripts = checkout / "scripts"
                    scripts.mkdir(parents=True)
                    shutil.copy2(SCRIPT, scripts / SCRIPT.name)
                    (scripts / "lib").mkdir()
                    shutil.copy2(REPO / "scripts/lib/install-workspace-dashboard.sh", scripts / "lib")
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
                    command = ["bash", str(scripts / SCRIPT.name), "--prefix", str(prefix)]
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
                    self.assertTrue(artifact.exists(), "installation removed incremental output")
                    self.assertEqual((checkout / "calls").read_text().splitlines(), ["build"])

    def test_install_preserves_incremental_output(self):
        for flags, fail_build in (
                ([], False), (["--skip-build"], False), ([], True),
                (["--prefix", "BUILD_PREFIX"], False)):
            with self.subTest(flags=flags, fail_build=fail_build), \
                    tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                checkout = root / "checkout"
                scripts = checkout / "scripts"
                scripts.mkdir(parents=True)
                shutil.copy2(SCRIPT, scripts / SCRIPT.name)
                (scripts / "lib").mkdir()
                shutil.copy2(REPO / "scripts/lib/install-workspace-dashboard.sh", scripts / "lib")
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
                         else flag for flag in flags]
                if "--prefix" in flags:
                    prefix = Path(flags[flags.index("--prefix") + 1])
                result = subprocess.run(
                    ["bash", str(scripts / SCRIPT.name), "--prefix", str(prefix),
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
                self.assertTrue(artifact.exists(), "installation removed incremental output")
                calls = checkout / "calls"
                if calls.exists():
                    self.assertEqual(calls.read_text().splitlines(), ["build:1"])
                else:
                    self.assertIn("--skip-build", flags)

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
                                     "--prefix", str(prefix),
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
                                     "--prefix", str(prefix),
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
                                     "--prefix", str(prefix),
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
                                     "--prefix", str(prefix)],
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
                                     "--prefix", str(prefix)],
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
                                     "--prefix", str(prefix),
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
                                     "--prefix", str(prefix),
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
                                     "--prefix", str(prefix),
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
                                     "--prefix", str(prefix),
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
                                 "--prefix", str(root / "prefix"),
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
                     "--prefix", str(root / "prefix"),
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
                             ("masc", "masc-tui",
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
                         "--prefix", str(prefix),
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
                                     "--prefix", str(prefix),
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
                                     "--prefix", str(prefix)],
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
                                     "--prefix", str(prefix)],
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
            result = subprocess.run(["bash", str(checkout / "scripts/install-local-build.sh"), "--prefix", str(prefix)],
                                    env=dict(os.environ, RECORD=str(record)), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("this repo requires exactly 5.5.1", result.stderr)
            self.assertFalse(prefix.exists(), "a build dune-local.sh refused was installed")
            cwd, *arguments = record.read_text().splitlines()
            self.assertEqual(Path(cwd).resolve(), checkout)
            self.assertEqual(arguments, ["build", "--root", str(checkout), "./bin/main_eio.exe",
                                         "./bin/masc_tui.exe",
                                         "./bin/deployment_preflight_helper.exe",
                                         "./bin/masc_exec_ssh_bootstrap.exe",
                                         "./bin/masc_antigravity_path_hook.exe",
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
                                     "--base-path", str(workspace(root))],
                                    env=dict(os.environ, MASC_DUNE_DRY_RUN="1"),
                                    check=True, capture_output=True, text=True)
            self.assertIn("[dune-local] command: dune build --root", result.stderr)
            self.assertIn("./bin/masc_exec_ssh_bootstrap.exe", result.stderr)
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
                                     "--prefix", str(prefix),
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
                                     "--prefix", str(prefix),
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
