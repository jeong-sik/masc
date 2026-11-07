#!/usr/bin/env python3
"""`masc browser-lane-setup`, run as the install script and the docs run it.

test_browser_lane_ego_setup.ml proves the library; this runs the real executable, so a flag that is renamed, a mode
that is dropped or an argument that is not passed on fails here. Every case
works in a scratch workspace under a scratch HOME.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MASC = Path(sys.argv.pop(1)).resolve()


def masc(root, *args, path="/usr/bin:/bin"):
    environment = {"HOME": str(root / "home"), "PATH": path}
    return subprocess.run([str(MASC), "browser-lane-setup", *args], env=environment,
                          capture_output=True, text=True)


def lane(base):
    return base / ".masc/browser-lane"


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


def runtime_toml(base):
    return base / ".masc/config/runtime.toml"


# Each browser source the workspace runs has its own Add-on package and
# declaration, named browser-<source folder>.
def package(base, folder):
    return base / ".masc/packages" / ("browser-" + folder)


def declared(base):
    directory = base / ".masc/config/lane-addons"
    return sorted(path.name for path in directory.glob("*.toml")) if directory.is_dir() else []


# A configured [browser.live.ego]. Parsing runs nothing, so a fixture path does.
EGO_TABLE = """
[browser.live.ego]
command = "/fixture/ego-browser"
space = "masc-keepers"
"""


def workspace(root, name="workspace"):
    base = root / name
    runtime_toml(base).parent.mkdir(parents=True)
    runtime_toml(base).write_text(RUNTIME_TOML)
    return base


# What ego lite 0.6.0.16 prints for --version once its onboarding is done.
EGO_VERSION = "ego-browser 0.6.0.16\n  chromium 154.0.8037.44\n  node v24.21.0"
# The one answer line of the space listing setup runs with `nodejs`: no task
# space of that name in ego lite yet.
EGO_NO_SPACES = 'masc-ego-result {"ok":true,"value":[]}'


def fake_ego(directory, script=None):
    path = directory / "ego-browser"
    path.parent.mkdir(parents=True, exist_ok=True)
    answers = ("case \"$1\" in\n  nodejs) printf '%s\\n' '" + EGO_NO_SPACES + "' ;;\n"
               "  *) printf '%s\\n' '" + EGO_VERSION.replace("\n", "' '") + "' ;;\nesac")
    path.write_text("#!/bin/sh\n" + (script or answers) + "\n")
    path.chmod(0o755)
    return path


class BrowserLaneSetupCommand(unittest.TestCase):
    def scratch(self):
        temporary = tempfile.TemporaryDirectory(prefix="lane cli ' ")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        (root / "home").mkdir()
        return root

    def test_without_a_mode_nothing_is_written_and_the_state_is_printed(self):
        root = self.scratch()
        base = root / "workspace"
        result = masc(root, "--base-path", str(base))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(base.exists())

    # --mode addon: for the browser source the workspace runs, the package
    # this masc carries for it and one declaration of it. --mode ego does the
    # same after its own step.
    def test_addon_declares_the_configured_source_once(self):
        root = self.scratch()
        base = workspace(root)
        runtime_toml(base).write_text(RUNTIME_TOML + EGO_TABLE)
        first = masc(root, "--mode", "addon", "--base-path", str(base))
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(declared(base), ["browser-ego.toml"], "the configured source only")
        self.assertTrue((package(base, "ego") / "lane.toml").is_file(), "its package is written")
        self.assertFalse(lane(base).exists(), "the Add-on step writes no browser-lane files")
        declaration = base / ".masc/config/lane-addons/browser-ego.toml"
        written = declaration.read_text()
        again = masc(root, "--mode", "addon", "--base-path", str(base))
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(declaration.read_text(), written, "the declaration is not rewritten")
        self.assertEqual(declared(base), ["browser-ego.toml"], "one declaration")

    def test_addon_without_a_configured_source_declares_nothing(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "--mode", "addon", "--base-path", str(base))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(declared(base), [], "nothing is declared")
        self.assertFalse((base / ".masc/packages").exists(), "no package is written")

    # Which sources a runtime.toml that does not parse runs is not known. A
    # repeated table is refused like a syntax error, not raised.
    def test_a_runtime_toml_that_does_not_parse_is_refused(self):
        for label, extra in (("syntax", "[browser.live.ego\n"), ("repeated table", EGO_TABLE + EGO_TABLE),
                             ("a lane switch", "\n[browser.live.ego]\nenabled = false\n")):
            with self.subTest(label):
                root = self.scratch()
                base = workspace(root)
                runtime_toml(base).write_text(RUNTIME_TOML + extra)
                result = masc(root, "--mode", "addon", "--base-path", str(base))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("does not parse", result.stderr)
                self.assertEqual(declared(base), [], "nothing is declared")
                self.assertFalse((base / ".masc/packages").exists(), "no package is written")

    # A workspace no server has started in has no config root yet. That is not
    # a refusal: the first start writes one, and install-local-build.sh tells
    # the two apart by this status.
    def test_addon_without_a_config_root_exits_3_and_writes_nothing(self):
        root = self.scratch()
        base = root / "workspace"
        base.mkdir()
        result = masc(root, "--mode", "addon", "--base-path", str(base))
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertFalse((base / ".masc").exists(), "nothing is written")

    def test_the_ego_route_declares_its_source(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "--base-path", str(base), "--mode", "ego", "--ego-command", str(fake_ego(root / "ego")))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(declared(base), ["browser-ego.toml"])
        self.assertTrue((package(base, "ego") / "lane.toml").is_file())

    def test_no_addon_leaves_the_addon_alone(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "--mode", "ego", "--base-path", str(base), "--ego-command",
                      str(fake_ego(root / "ego")), "--no-addon")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[browser.live.ego]", runtime_toml(base).read_text().splitlines(),
                      "the mode's own step runs")
        self.assertFalse((base / ".masc/config/lane-addons").exists(), "nothing is declared")
        self.assertFalse((base / ".masc/packages").exists(), "no package is written")

    def test_no_addon_with_the_addon_mode_or_alone_is_refused(self):
        root = self.scratch()
        base = workspace(root)
        for arguments in (("--mode", "addon", "--no-addon"), ("--no-addon",)):
            with self.subTest(arguments=arguments):
                result = masc(root, *arguments, "--base-path", str(base))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertFalse((base / ".masc/config/lane-addons").exists())
                self.assertFalse((base / ".masc/packages").exists())

    # --mode ego: the table the server reads. A second run with the same
    # values leaves the file byte for byte.
    def test_ego_writes_its_table_once(self):
        root = self.scratch()
        base = workspace(root)
        ego = fake_ego(root / "ego")
        arguments = ("--mode", "ego", "--base-path", str(base), "--ego-command", str(ego), "--ego-space", "work")
        first = masc(root, *arguments)
        self.assertEqual(first.returncode, 0, first.stderr)
        text = runtime_toml(base).read_text()
        self.assertTrue(text.startswith(RUNTIME_TOML), "what was there is kept, then the table follows")
        self.assertIn("[browser.live.ego]", text.splitlines())
        self.assertIn('command = "' + str(ego) + '"', text)
        self.assertIn('space = "work"', text)
        self.assertIn("answered ego lite 0.6.0.16, Chromium 154.0.8037.44", first.stdout)
        self.assertIn("Restart the MASC server", first.stdout)
        before = runtime_toml(base).read_bytes()
        second = masc(root, *arguments)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(runtime_toml(base).read_bytes(), before)

    def test_an_existing_table_is_left_as_it_is_unless_a_value_is_named(self):
        root = self.scratch()
        base = workspace(root)
        ego = fake_ego(root / "ego")
        table = (f'\n# the space the Keepers work in\n[browser.live.ego]\n'
                 f'command = "{ego}"\nspace = "work"\n')
        runtime_toml(base).write_text(RUNTIME_TOML + table)
        before = runtime_toml(base).read_text()
        arguments = ("--mode", "ego", "--base-path", str(base))
        result = masc(root, *arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), before)
        self.assertIn("left as it is", result.stdout)
        changed = masc(root, *arguments, "--ego-space", "play")
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertEqual(runtime_toml(base).read_text(), before.replace('space = "work"', 'space = "play"'))

    # ego lite's onboarding links ego-browser into ~/.local/bin, which a
    # setup started from another shell may not have on PATH.
    def test_ego_is_found_where_its_onboarding_links_it(self):
        root = self.scratch()
        base = workspace(root)
        ego = fake_ego(root / "home/.local/bin")
        result = masc(root, "--mode", "ego", "--base-path", str(base))
        self.assertEqual(result.returncode, 0, result.stderr)
        text = runtime_toml(base).read_text()
        self.assertIn('command = "' + str(ego) + '"', text)
        self.assertIn('space = "masc-keepers"', text)
        self.assertFalse(lane(base).exists(), "ego writes no browser-lane files")
        self.assertTrue(package(base, "ego").is_dir(), "the route declares its browser Add-on")

    def test_an_ego_whose_onboarding_is_not_finished_writes_nothing(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        ego = fake_ego(root / "ego", script="echo 'ego-browser: not signed in'; exit 3")
        result = masc(root, "--mode", "ego", "--base-path", str(base), "--ego-command", str(ego))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Finish ego lite's onboarding", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), before)
        self.assertFalse((base / ".masc/packages").exists(), "nothing was written first")

    def test_an_option_the_chosen_modes_do_not_use_is_refused(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        for arguments, sentence in (
            (("--mode", "addon", "--ego-command", "/bin/sh"), "--ego-command only applies with --mode ego"),
            (("--mode", "addon", "--ego-space", "work"), "--ego-space only applies with --mode ego"),
            (("--ego-space", "work"), "--ego-space only applies with --mode ego"),
        ):
            with self.subTest(arguments):
                result = masc(root, "--base-path", str(base), *arguments)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(sentence, result.stderr)
                self.assertFalse(lane(base).exists(), "nothing was written")
                self.assertEqual(runtime_toml(base).read_text(), before)

    def test_a_mode_that_does_not_exist_is_refused(self):
        root = self.scratch()
        result = masc(root, "--mode", "everything", "--base-path", str(root / "workspace"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((root / "workspace").exists())

    def test_a_table_that_cannot_be_written_declares_nothing(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        # masc needs to create its lock file beside runtime.toml; a directory
        # it cannot write into fails the commit.
        config = runtime_toml(base).parent
        (config / "lane-addons").mkdir()
        config.chmod(0o500)
        self.addCleanup(config.chmod, 0o700)
        result = masc(root, "--mode", "ego", "--base-path", str(base), "--ego-command", str(fake_ego(root / "ego")))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("[browser.live.ego] was not written to runtime.toml", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), before)
        # The ego source waits for its table.
        self.assertEqual(declared(base), [])

    def test_the_table_goes_where_the_config_directory_override_points(self):
        root = self.scratch()
        base = root / "workspace"
        base.mkdir()
        elsewhere = root / "elsewhere config"
        elsewhere.mkdir()
        (elsewhere / "runtime.toml").write_text(RUNTIME_TOML)
        environment = {"HOME": str(root / "home"), "PATH": "/usr/bin:/bin",
                       "MASC_CONFIG_DIR": str(elsewhere)}
        result = subprocess.run(
            [str(MASC), "browser-lane-setup", "--mode", "ego",
             "--base-path", str(base), "--ego-command", str(fake_ego(root / "ego"))],
            env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[browser.live.ego]", (elsewhere / "runtime.toml").read_text().splitlines())
        self.assertFalse((base / ".masc/config/runtime.toml").exists())

    def test_ego_without_a_runtime_toml_creates_nothing(self):
        root = self.scratch()
        base = root / "workspace"
        result = masc(root, "--mode", "ego", "--base-path", str(base), "--ego-command", str(fake_ego(root / "ego")))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("masc init", result.stderr)
        self.assertFalse(base.exists())

    # --base-path names the workspace that holds .masc, as for every command.
    def test_a_trailing_dot_masc_in_the_workspace_path_is_dropped(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "--mode", "ego", "--base-path", str(base / ".masc"),
                      "--ego-command", str(fake_ego(root / "ego")))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[browser.live.ego]", runtime_toml(base).read_text().splitlines())
        self.assertFalse((base / ".masc/.masc").exists())


if __name__ == "__main__":
    unittest.main()
