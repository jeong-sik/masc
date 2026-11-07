#!/usr/bin/env python3
"""`masc browser-lane-setup`, run as the install script and the docs run it.

test_browser_lane_setup.ml and test_browser_lane_bidi_setup.ml prove the
libraries; this runs the real executable, so a flag that is renamed, a mode
that is dropped or an argument that is not passed on fails here. Every case
works in a scratch workspace under a scratch HOME.
"""
import os
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


# A configured [browser.live.bidi]. Parsing reads no file, so fixture paths do.
FIREFOX_TABLE = """
[browser.live.bidi]
firefox = "/fixture/firefox"
profile = "/fixture/firefox-profile"
"""


def workspace(root, name="workspace"):
    base = root / name
    runtime_toml(base).parent.mkdir(parents=True)
    runtime_toml(base).write_text(RUNTIME_TOML)
    return base


def fake_firefox(root):
    path = root / "fake firefox"
    path.write_text("#!/bin/sh\necho 'Mozilla Firefox 0.0 (fixture)'\n")
    path.chmod(0o755)
    return path


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

    # --mode addon: for each browser source the workspace runs, the package
    # this masc carries for it and one declaration of it. Every other mode
    # does the same after its own step.
    def test_addon_declares_each_configured_source_once(self):
        root = self.scratch()
        base = workspace(root)
        runtime_toml(base).write_text(RUNTIME_TOML + FIREFOX_TABLE)
        first = masc(root, "--mode", "addon", "--base-path", str(base))
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(declared(base), ["browser-firefox.toml"], "the configured source only")
        self.assertTrue((package(base, "firefox") / "lane.toml").is_file(), "its package is written")
        self.assertFalse(lane(base).exists(), "the Add-on step writes no browser-lane files")
        declaration = base / ".masc/config/lane-addons/browser-firefox.toml"
        written = declaration.read_text()
        again = masc(root, "--mode", "addon", "--base-path", str(base))
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(declaration.read_text(), written, "the declaration is not rewritten")
        self.assertEqual(declared(base), ["browser-firefox.toml"], "one declaration")

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
        for label, extra in (("syntax", "[browser.live.bidi\n"), ("repeated table", FIREFOX_TABLE),
                             ("a lane switch", "\n[browser.live.ego]\nenabled = false\n")):
            with self.subTest(label):
                root = self.scratch()
                base = workspace(root)
                runtime_toml(base).write_text(RUNTIME_TOML + FIREFOX_TABLE + extra)
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

    def test_each_route_declares_the_sources_it_runs(self):
        root = self.scratch()
        firefox, ego = fake_firefox(root), fake_ego(root / "ego")
        for label, arguments, folders in (
            ("bidi", ("--mode", "bidi", "--firefox", str(firefox),
                      "--profile", str(root / "keeper profile")), ["firefox"]),
            ("ego", ("--mode", "ego", "--ego-command", str(ego)), ["ego"]),
        ):
            with self.subTest(label):
                base = workspace(root, name="workspace " + label)
                result = masc(root, "--base-path", str(base), *arguments)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(declared(base), ["browser-" + folder + ".toml" for folder in folders])
                for folder in folders:
                    self.assertTrue((package(base, folder) / "lane.toml").is_file(), folder)

    def test_no_addon_leaves_the_addon_alone(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "--mode", "bidi", "--base-path", str(base), "--firefox",
                      str(fake_firefox(root)), "--profile", str(root / "keeper profile"), "--no-addon")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[browser.live.bidi]", runtime_toml(base).read_text().splitlines(),
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

    # Two tables of one command: the later one is planned again against the
    # file the earlier one wrote.
    def test_ego_beside_bidi_writes_both_tables(self):
        root = self.scratch()
        base = workspace(root)
        firefox, ego = fake_firefox(root), fake_ego(root / "ego")
        arguments = ("--mode", "bidi", "--mode", "ego",
                     "--base-path", str(base), "--firefox", str(firefox),
                     "--profile", str(root / "keeper profile"), "--ego-command", str(ego), "--ego-space", "work")
        first = masc(root, *arguments)
        self.assertEqual(first.returncode, 0, first.stderr)
        text = runtime_toml(base).read_text()
        for header in ("[browser.live.bidi]", "[browser.live.ego]"):
            self.assertIn(header, text.splitlines())
        self.assertIn('command = "' + str(ego) + '"', text)
        self.assertIn('space = "work"', text)
        self.assertIn("answered ego lite 0.6.0.16, Chromium 154.0.8037.44", first.stdout)
        before = runtime_toml(base).read_bytes()
        second = masc(root, *arguments)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(runtime_toml(base).read_bytes(), before)

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
        self.assertTrue(package(base, "ego").is_dir(), "every route declares its browser Add-on")

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

    def test_ego_options_are_refused_with_the_other_modes(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        for arguments, sentence in (
            (("--mode", "bidi", "--ego-space", "work"), "--ego-space only applies with --mode ego"),
            (("--mode", "addon", "--ego-command", "/bin/sh"), "--ego-command only applies with --mode ego"),
            (("--mode", "ego", "--firefox", "/bin/sh"), "--firefox only applies with --mode bidi"),
        ):
            with self.subTest(arguments):
                result = masc(root, "--base-path", str(base), *arguments)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(sentence, result.stderr)
                self.assertEqual(runtime_toml(base).read_text(), before)

    def test_an_ego_that_cannot_be_planned_installs_nothing_for_the_other_route(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        ego = fake_ego(root / "ego", script="echo 'ego-browser: not signed in'; exit 3")
        result = masc(root, "--mode", "bidi", "--mode", "ego",
                      "--base-path", str(base), "--firefox", str(fake_firefox(root)),
                      "--profile", str(root / "profile"), "--ego-command", str(ego))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Finish ego lite's onboarding", result.stderr)
        self.assertFalse((root / "profile").exists(), "the bidi profile was not made first")
        self.assertEqual(runtime_toml(base).read_text(), before)

    def test_bidi_options_are_refused_with_the_ego_mode(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        for arguments, sentence in (
            (("--mode", "ego", "--port", "9333"), "--port only applies with --mode bidi"),
            (("--mode", "ego", "--profile", str(root / "p")),
             "--profile only applies with --mode bidi"),
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

    # --mode bidi: the table the server reads.
    def test_bidi_writes_the_table(self):
        root = self.scratch()
        base = workspace(root)
        firefox, profile = fake_firefox(root), root / "keeper profile"
        result = masc(root, "--mode", "bidi", "--base-path", str(base),
                      "--firefox", str(firefox), "--profile", str(profile), "--port", "9333")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = runtime_toml(base).read_text()
        self.assertTrue(text.startswith(RUNTIME_TOML), "what was there is kept, then the table follows")
        for line in (f'firefox = "{firefox}"', f'profile = "{profile}"', "port = 9333"):
            self.assertIn(line, text.splitlines())
        self.assertIn("[browser.live.bidi]", text.splitlines())
        self.assertEqual(os.stat(profile).st_mode & 0o777, 0o700)
        self.assertIn("Restart the MASC server", result.stdout)
        self.assertIn(str(profile), result.stdout)

    def test_an_existing_table_is_left_as_it_is_unless_a_value_is_named(self):
        root = self.scratch()
        base = workspace(root)
        firefox, profile = fake_firefox(root), root / "operator profile"
        profile.mkdir()
        table = (f'\n# the profile the Keepers are logged in to\n[browser.live.bidi]\n'
                 f'firefox = "{firefox}"\nprofile = "{profile}"\nport = 9300\n')
        runtime_toml(base).write_text(RUNTIME_TOML + table)
        before = runtime_toml(base).read_text()
        arguments = ("--mode", "bidi", "--base-path", str(base))
        result = masc(root, *arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), before)
        self.assertIn("left as it is", result.stdout)
        changed = masc(root, *arguments, "--port", "9444")
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertEqual(runtime_toml(base).read_text(), before.replace("port = 9300", "port = 9444"))

    def test_an_option_the_chosen_modes_do_not_use_is_refused(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        for arguments in (("--mode", "addon", "--firefox", str(fake_firefox(root))),
                          ("--mode", "addon", "--profile", str(root / "profile")),
                          ("--mode", "addon", "--port", "9333"),
                          ("--firefox", str(fake_firefox(root)))):
            with self.subTest(arguments):
                result = masc(root, "--base-path", str(base), *arguments)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("only applies with", result.stderr)
                self.assertFalse(lane(base).exists(), "nothing was written")
                self.assertEqual(runtime_toml(base).read_text(), before)

    def test_a_bidi_refusal_leaves_the_workspace_as_it_was(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        for label, arguments, sentence in (
            ("a Firefox that is not a path", ("--firefox", "firefox", "--profile", str(root)),
             "absolute path"),
            ("a port out of range", ("--firefox", str(fake_firefox(root)), "--profile", str(root),
                                     "--port", "70000"), "1 to 65535"),
            ("a Firefox that is not there", ("--firefox", str(root / "absent"),
                                             "--profile", str(root)), "executable file"),
        ):
            with self.subTest(label):
                result = masc(root, "--mode", "bidi", "--base-path", str(base), *arguments)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(sentence, result.stderr)
                self.assertEqual(declared(base), [], "nothing was declared")
                self.assertEqual(runtime_toml(base).read_text(), before)

    def test_a_profile_that_cannot_be_made_is_refused_before_anything_is_written(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        locked = root / "locked"
        locked.mkdir(mode=0o500)
        self.addCleanup(locked.chmod, 0o700)
        result = masc(root, "--mode", "bidi", "--base-path", str(base),
                      "--firefox", str(fake_firefox(root)), "--profile", str(locked / "profile"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Could not create the profile directory", result.stderr)
        self.assertEqual(declared(base), [], "nothing was declared")
        self.assertEqual(runtime_toml(base).read_text(), before)

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
        result = masc(root, "--mode", "bidi", "--base-path", str(base),
                      "--firefox", str(fake_firefox(root)), "--profile", str(root / "profile"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("[browser.live.bidi] was not written to runtime.toml", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), before)
        # The owned Firefox waits for its table.
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
            [str(MASC), "browser-lane-setup", "--mode", "bidi",
             "--base-path", str(base), "--firefox", str(fake_firefox(root)),
             "--profile", str(root / "profile")],
            env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[browser.live.bidi]", (elsewhere / "runtime.toml").read_text().splitlines())
        self.assertFalse((base / ".masc/config/runtime.toml").exists())

    def test_bidi_without_a_runtime_toml_creates_nothing(self):
        root = self.scratch()
        base = root / "workspace"
        result = masc(root, "--mode", "bidi", "--base-path", str(base))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("masc init", result.stderr)
        self.assertFalse(base.exists())

    # --base-path names the workspace that holds .masc, as for every command.
    def test_a_trailing_dot_masc_in_the_workspace_path_is_dropped(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "--mode", "bidi", "--base-path", str(base / ".masc"),
                      "--firefox", str(fake_firefox(root)), "--profile", str(root / "profile"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[browser.live.bidi]", runtime_toml(base).read_text().splitlines())
        self.assertFalse((base / ".masc/.masc").exists())


if __name__ == "__main__":
    unittest.main()
