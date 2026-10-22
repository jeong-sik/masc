#!/usr/bin/env python3
"""`masc browser-lane-setup`, run as the install script and the docs run it.

test_browser_lane_setup.ml and test_browser_lane_bidi_setup.ml prove the
libraries; this runs the real executable, so a flag that is renamed, a mode
that is dropped or an argument that is not passed on fails here. Every case
works in a scratch workspace and a scratch manifest directory under a scratch
HOME.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MASC = Path(sys.argv.pop(1)).resolve()
HOST = Path(sys.argv.pop(1)).resolve()
EXTENSION_ID = "browser-lane@masc.local"


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


def workspace(root, name="workspace"):
    base = root / name
    runtime_toml(base).parent.mkdir(parents=True)
    runtime_toml(base).write_text(RUNTIME_TOML)
    return base


def fake_geckodriver(root, directory=None):
    path = (directory or root) / "geckodriver"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\necho 'geckodriver 0.0 (fixture)'\n")
    path.chmod(0o755)
    return path


def fake_firefox(root):
    path = root / "fake firefox"
    path.write_text("#!/bin/sh\necho 'Mozilla Firefox 0.0 (fixture)'\n")
    path.chmod(0o755)
    return path


class BrowserLaneSetupCommand(unittest.TestCase):
    def scratch(self):
        temporary = tempfile.TemporaryDirectory(prefix="lane cli ' ")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        (root / "home").mkdir()
        return root

    # The flags install-local-build.sh passes, and the ones the docs show.
    def test_install_with_the_flags_the_script_and_the_docs_use(self):
        root = self.scratch()
        base, manifests = root / "workspace ' one", root / "native manifests"
        token = root / "provisioned-token"
        token.write_text("provisioned-browser-lane-test-token\n")
        result = masc(root, "--mode", "extension", "--binary", str(HOST), "--base-path", str(base),
                      "--host-name", "masc.cli_test", "--manifest-dir", str(manifests),
                      "--token-file", str(token))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((lane(base) / "host/masc-browser-host").read_bytes(), HOST.read_bytes())
        self.assertEqual(os.stat(lane(base) / "host/launch").st_mode & 0o777, 0o755)
        self.assertEqual((lane(base) / "token").read_text(), token.read_text())
        self.assertEqual(os.stat(lane(base) / "token").st_mode & 0o777, 0o600)
        for name in ("manifest.json", "background.js"):
            self.assertTrue((lane(base) / "extension" / name).is_file(), name)
        registration = json.loads((manifests / "masc.cli_test.json").read_text())
        self.assertEqual(registration["name"], "masc.cli_test")
        self.assertEqual(registration["path"], str(lane(base) / "host/launch"))
        self.assertEqual(registration["allowed_extensions"], [EXTENSION_ID])
        # What the operator is told to load is the file that was written.
        self.assertIn(str(lane(base) / "extension/manifest.json"), result.stdout)

    def test_without_a_mode_nothing_is_written_and_the_state_is_printed(self):
        root = self.scratch()
        base = root / "workspace"
        before = masc(root, "--base-path", str(base))
        self.assertEqual(before.returncode, 0, before.stderr)
        self.assertIn("masc browser-lane-setup --mode extension --base-path", before.stdout)
        self.assertFalse(base.exists())
        installed = masc(root, "--mode", "extension", "--binary", str(HOST), "--base-path", str(base),
                         "--manifest-dir", str(root / "manifests"))
        self.assertEqual(installed.returncode, 0, installed.stderr)
        after = masc(root, "--base-path", str(base))
        self.assertEqual(after.returncode, 0, after.stderr)
        self.assertIn("follows the workspace connection port", after.stdout)
        self.assertNotIn("masc browser-lane-setup --mode extension", after.stdout)

    def test_installing_again_keeps_the_token(self):
        root = self.scratch()
        base = root / "workspace"
        arguments = ("--mode", "extension", "--binary", str(HOST), "--base-path", str(base),
                     "--manifest-dir", str(root / "manifests"))
        self.assertEqual(masc(root, *arguments).returncode, 0)
        token = (lane(base) / "token").read_text()
        self.assertEqual(masc(root, *arguments).returncode, 0)
        self.assertEqual((lane(base) / "token").read_text(), token)

    def test_a_refusal_exits_with_one_and_leaves_nothing_behind(self):
        root = self.scratch()
        base, manifests = root / "workspace", root / "manifests"
        short_token = root / "short-token"
        short_token.write_text("short\n")
        for label, arguments in (
            ("a host name that names a path", ("--host-name", "../owned")),
            ("a binary that is not there", ("--binary", str(root / "absent"))),
            ("a token that is too short", ("--token-file", str(short_token))),
        ):
            with self.subTest(label):
                full = {"--binary": str(HOST), "--base-path": str(base), "--manifest-dir": str(manifests)}
                full.update(dict(zip(arguments[0::2], arguments[1::2])))
                result = masc(root, "--mode", "extension",
                              *[part for item in full.items() for part in item])
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertFalse(base.exists(), "nothing was written to the workspace")
                self.assertFalse(manifests.exists(), "nothing was registered")

    # --mode addon: the browser Add-on package this masc carries and one
    # declaration of it. Every other mode does the same after its host step.
    def test_addon_writes_the_package_and_declares_it_once(self):
        root = self.scratch()
        base = workspace(root)
        first = masc(root, "--mode", "addon", "--base-path", str(base))
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        declaration = base / ".masc/config/lane-addons/browser.toml"
        self.assertTrue(declaration.is_file(), "the Add-on is declared")
        self.assertTrue((base / ".masc/packages/browser/lane.toml").is_file(), "the package is written")
        self.assertFalse(lane(base).exists(), "no host, no token, no extension")
        written = declaration.read_text()
        again = masc(root, "--mode", "addon", "--base-path", str(base))
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(declaration.read_text(), written, "the declaration is not rewritten")
        self.assertEqual(sorted(path.name for path in declaration.parent.glob("*.toml")),
                         ["browser.toml"], "one declaration")

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

    def test_every_route_declares_the_addon(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "--mode", "host", "--binary", str(HOST), "--base-path", str(base))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((base / ".masc/config/lane-addons/browser.toml").is_file())

    def test_no_addon_leaves_the_addon_alone(self):
        root = self.scratch()
        base = workspace(root)
        result = masc(root, "--mode", "host", "--binary", str(HOST), "--base-path", str(base),
                      "--no-addon")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((lane(base) / "host/masc-browser-host").is_file(), "the host is installed")
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

    # --mode host: the host and the launcher, for a browser attached by hand and
    # for bringing an installed lane's host up to date.
    def test_host_installs_the_host_and_the_launcher_and_nothing_else(self):
        root = self.scratch()
        base = root / "workspace"
        result = masc(root, "--mode", "host", "--binary", str(HOST), "--base-path", str(base))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((lane(base) / "host/masc-browser-host").read_bytes(), HOST.read_bytes())
        self.assertTrue((lane(base) / "host/launch.json").is_file())
        self.assertEqual(os.stat(lane(base) / "token").st_mode & 0o777, 0o600)
        self.assertFalse((lane(base) / "extension").exists(), "no extension is written")
        for directory in ("Library", ".mozilla"):
            self.assertFalse((root / "home" / directory).exists(), "no manifest is registered")
        self.assertFalse(runtime_toml(base).exists(), "no runtime.toml is needed or written")
        self.assertIn("connects no browser", result.stdout)
        # What the lane says is left to do follows, as for the extension route.
        self.assertIn("follows the workspace connection port", result.stdout)

    def test_host_takes_a_provisioned_token_like_the_other_modes(self):
        root = self.scratch()
        base = root / "workspace"
        token = root / "provisioned-token"
        token.write_text("provisioned-browser-lane-test-token\n")
        result = masc(root, "--mode", "host", "--binary", str(HOST), "--base-path", str(base),
                      "--token-file", str(token))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((lane(base) / "token").read_text(), token.read_text())

    def test_the_host_mode_beside_another_route_does_not_say_two_browsers_are_connected(self):
        root = self.scratch()
        firefox = fake_firefox(root)
        for label, extra in (("extension", ("--manifest-dir", str(root / "manifests"))),
                             ("bidi", ("--firefox", str(firefox), "--profile", str(root / "profile")))):
            with self.subTest(label):
                base = workspace(root, name="workspace " + label)
                result = masc(root, "--mode", "host", "--mode", label, "--binary", str(HOST),
                              "--base-path", str(base), *extra)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("ambiguous_browser_clients", result.stdout)

    def test_host_refreshes_the_copy_and_leaves_the_runtime_table_as_it_is(self):
        root = self.scratch()
        base = workspace(root)
        firefox, profile = fake_firefox(root), root / "keeper profile"
        first = masc(root, "--mode", "bidi", "--binary", str(HOST), "--base-path", str(base),
                     "--firefox", str(firefox), "--profile", str(profile))
        self.assertEqual(first.returncode, 0, first.stderr)
        with_table = runtime_toml(base).read_text()
        copy = lane(base) / "host/masc-browser-host"
        copy.write_bytes(b"an older build")
        token = (lane(base) / "token").read_text()
        again = masc(root, "--mode", "host", "--binary", str(HOST), "--base-path", str(base))
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(copy.read_bytes(), HOST.read_bytes())
        self.assertEqual(runtime_toml(base).read_text(), with_table)
        self.assertEqual((lane(base) / "token").read_text(), token)

    # --mode automation configures the Add-on-owned driver and installs no host.
    def test_automation_writes_the_geckodriver_and_installs_no_host(self):
        root = self.scratch()
        base = workspace(root)
        driver = fake_geckodriver(root, root / "tools")
        # No --binary: the lane needs no host to install.
        result = masc(root, "--mode", "automation", "--base-path", str(base),
                      path=f"{driver.parent}:/usr/bin:/bin")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = runtime_toml(base).read_text()
        self.assertTrue(text.startswith(RUNTIME_TOML), "what was there is kept, then the table follows")
        self.assertIn("[browser.automation]", text.splitlines())
        self.assertIn(f'geckodriver = "{driver}"', text.splitlines())
        self.assertNotIn("binary", text)
        self.assertFalse(lane(base).exists(), "no host, no token, no extension")
        for directory in ("Library", ".mozilla"):
            self.assertFalse((root / "home" / directory).exists(), "no manifest is registered")
        self.assertIn("Restart the MASC server", result.stdout)
        self.assertIn("logins do not carry over to a new session", result.stdout)
        self.assertIn("Wrote [browser.automation] to", result.stdout)
        # The extension lane's sentence ("install the host...") is not this
        # lane's, and nothing here installs one.
        self.assertNotIn("browser lane host is installed", result.stdout)
        self.assertNotIn("Browser lane for", result.stdout)

    def test_automation_edits_keys_where_the_file_already_has_them(self):
        root = self.scratch()
        base = workspace(root)
        driver, other = fake_geckodriver(root, root / "one"), fake_geckodriver(root, root / "two")
        browser = fake_firefox(root)
        runtime_toml(base).write_text(RUNTIME_TOML + f'\n[browser]\ngeckodriver = "{driver}"\n')
        result = masc(root, "--mode", "automation", "--base-path", str(base),
                      "--browser", str(browser))
        self.assertEqual(result.returncode, 0, result.stderr)
        text = runtime_toml(base).read_text()
        self.assertNotIn("[browser.automation]", text.splitlines(), "no second spelling is added")
        self.assertIn(f'geckodriver = "{driver}"', text.splitlines(), "the driver is kept")
        self.assertIn(f'binary = "{browser}"', text.splitlines())
        self.assertIn("Changed binary in [browser] of", result.stdout)
        unchanged = masc(root, "--mode", "automation", "--base-path", str(base))
        self.assertEqual(unchanged.returncode, 0, unchanged.stderr)
        self.assertIn("was already there and is left as it is", unchanged.stdout)
        changed = masc(root, "--mode", "automation", "--base-path", str(base),
                       "--geckodriver", str(other))
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertIn(f'geckodriver = "{other}"', runtime_toml(base).read_text().splitlines())

    def test_a_kept_geckodriver_that_is_gone_is_said_and_left_alone(self):
        # A brew upgrade or a removed install leaves the old absolute path in
        # runtime.toml while PATH finds a new geckodriver. The command keeps the
        # value, and it used to say only that, with the server failing later.
        root = self.scratch()
        base = workspace(root)
        gone = root / "removed" / "geckodriver"
        fake_geckodriver(root, root / "new")
        text = RUNTIME_TOML + f'\n[browser.automation]\ngeckodriver = "{gone}"\n'
        runtime_toml(base).write_text(text)
        result = masc(root, "--mode", "automation", "--base-path", str(base),
                      path=f"{root / 'new'}:/usr/bin:/bin")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("was already there and is left as it is", result.stdout)
        self.assertIn(f"geckodriver = {gone} is not an executable file now", result.stdout)
        self.assertIn("name --geckodriver to change it", result.stdout)
        self.assertEqual(runtime_toml(base).read_text(), text, "the value is not changed")
        named = masc(root, "--mode", "automation", "--base-path", str(base),
                     "--geckodriver", str(root / "new" / "geckodriver"))
        self.assertEqual(named.returncode, 0, named.stderr)
        self.assertNotIn("is not an executable file now", named.stdout)

    def test_automation_beside_bidi_writes_both_tables_and_one_host(self):
        root = self.scratch()
        base = workspace(root)
        driver, firefox = fake_geckodriver(root), fake_firefox(root)
        arguments = ("--mode", "automation", "--mode", "bidi", "--binary", str(HOST),
                     "--base-path", str(base), "--geckodriver", str(driver),
                     "--firefox", str(firefox), "--profile", str(root / "keeper profile"))
        first = masc(root, *arguments)
        self.assertEqual(first.returncode, 0, first.stderr)
        lines = runtime_toml(base).read_text().splitlines()
        self.assertIn("[browser.automation]", lines)
        self.assertIn("[browser.live.bidi]", lines)
        self.assertTrue((lane(base) / "host/launch.json").is_file())
        files = [runtime_toml(base), lane(base) / "host/launch", lane(base) / "token"]
        before = [path.read_bytes() for path in files]
        second = masc(root, *arguments)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual([path.read_bytes() for path in files], before)

    def test_automation_that_cannot_be_planned_installs_nothing_for_the_other_route(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        # No geckodriver on PATH (an empty directory is all there is) and none named.
        empty = root / "empty path"
        empty.mkdir()
        result = masc(root, "--mode", "automation", "--mode", "bidi", "--binary", str(HOST),
                      "--base-path", str(base), "--firefox", str(fake_firefox(root)),
                      "--profile", str(root / "profile"), path=str(empty))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("No geckodriver answered", result.stderr)
        self.assertFalse(lane(base).exists(), "the host was not installed first")
        self.assertEqual(runtime_toml(base).read_text(), before)

    def test_automation_options_are_refused_with_the_other_modes_and_the_reverse(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        driver = fake_geckodriver(root)
        for arguments, sentence in (
            (("--mode", "automation", "--binary", str(HOST)), "--binary only applies with"),
            (("--mode", "automation", "--token-file", str(root / "t")), "--token-file only applies"),
            (("--mode", "automation", "--port", "9333"), "--port only applies with --mode bidi"),
            (("--mode", "automation", "--firefox", str(driver)),
             "--firefox only applies with --mode bidi"),
            (("--mode", "automation", "--profile", str(root / "p")),
             "--profile only applies with --mode bidi"),
            (("--mode", "automation", "--manifest-dir", str(root / "m")),
             "--manifest-dir only applies with --mode extension"),
            (("--mode", "automation", "--host-name", "masc.other"),
             "--host-name only applies with --mode extension"),
            (("--mode", "bidi", "--geckodriver", str(driver)),
             "--geckodriver only applies with --mode automation"),
            (("--mode", "extension", "--browser", str(driver)),
             "--browser only applies with --mode automation"),
            (("--mode", "host", "--geckodriver", str(driver)), "--geckodriver only applies"),
        ):
            with self.subTest(arguments):
                result = masc(root, "--base-path", str(base), *arguments)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(sentence, result.stderr)
                self.assertFalse(lane(base).exists(), "nothing was installed")
                self.assertEqual(runtime_toml(base).read_text(), before)

    def test_a_named_geckodriver_with_a_space_after_it_is_refused_not_written_as_another_file(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        driver = fake_geckodriver(root)
        result = masc(root, "--mode", "automation", "--base-path", str(base),
                      "--geckodriver", str(driver) + " ")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("--geckodriver must be an executable file", result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), before)

    def test_a_geckodriver_that_answers_once_and_not_again_does_not_leave_a_half_install(self):
        root = self.scratch()
        base = workspace(root)
        # A driver that answers --version the first time it is asked and exits 9
        # after that: a run that asked again after writing would report a
        # failure after the host and the bidi table were written.
        # The marker sits beside the script: the scratch directory's name holds a
        # quote, which a path written into the script would not survive.
        driver = root / "tools" / "geckodriver"
        driver.parent.mkdir()
        driver.write_text('#!/bin/sh\nmarker="$(dirname "$0")/asked"\n'
                          'if [ -e "$marker" ]; then exit 9; fi\n: > "$marker"\n'
                          "echo 'geckodriver 0.0 (fixture)'\n")
        driver.chmod(0o755)
        result = masc(root, "--mode", "automation", "--mode", "bidi", "--binary", str(HOST),
                      "--base-path", str(base), "--firefox", str(fake_firefox(root)),
                      "--profile", str(root / "profile"), path=f"{driver.parent}:/usr/bin:/bin")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = runtime_toml(base).read_text().splitlines()
        self.assertIn("[browser.automation]", lines)
        self.assertIn("[browser.live.bidi]", lines)

    def test_a_mode_that_does_not_exist_is_refused(self):
        root = self.scratch()
        result = masc(root, "--mode", "everything", "--base-path", str(root / "workspace"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((root / "workspace").exists())

    # --mode bidi: the host and the launcher, and the table the server reads.
    def test_bidi_writes_the_table_and_the_host_and_no_extension(self):
        root = self.scratch()
        base = workspace(root)
        firefox, profile = fake_firefox(root), root / "keeper profile"
        result = masc(root, "--mode", "bidi", "--binary", str(HOST), "--base-path", str(base),
                      "--firefox", str(firefox), "--profile", str(profile), "--port", "9333")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = runtime_toml(base).read_text()
        self.assertTrue(text.startswith(RUNTIME_TOML), "what was there is kept, then the table follows")
        for line in (f'firefox = "{firefox}"', f'profile = "{profile}"', "port = 9333"):
            self.assertIn(line, text.splitlines())
        self.assertIn("[browser.live.bidi]", text.splitlines())
        self.assertEqual(os.stat(profile).st_mode & 0o777, 0o700)
        self.assertEqual((lane(base) / "host/masc-browser-host").read_bytes(), HOST.read_bytes())
        self.assertTrue((lane(base) / "host/launch.json").is_file())
        self.assertFalse((lane(base) / "extension").exists(), "no extension is written")
        for directory in ("Library", ".mozilla"):
            self.assertFalse((root / "home" / directory).exists(), "no manifest is registered")
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
        arguments = ("--mode", "bidi", "--binary", str(HOST), "--base-path", str(base))
        result = masc(root, *arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(runtime_toml(base).read_text(), before)
        self.assertIn("left as it is", result.stdout)
        changed = masc(root, *arguments, "--port", "9444")
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertEqual(runtime_toml(base).read_text(), before.replace("port = 9300", "port = 9444"))

    def test_both_routes_install_once_and_a_second_run_changes_nothing(self):
        root = self.scratch()
        base = workspace(root)
        firefox, manifests = fake_firefox(root), root / "native manifests"
        arguments = ("--mode", "extension", "--mode", "bidi", "--binary", str(HOST),
                     "--base-path", str(base), "--manifest-dir", str(manifests),
                     "--firefox", str(firefox), "--profile", str(root / "keeper profile"))
        first = masc(root, *arguments)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertTrue((manifests / "masc_browser_host.json").is_file())
        self.assertTrue((lane(base) / "extension/manifest.json").is_file())
        self.assertIn("[browser.live.bidi]", runtime_toml(base).read_text().splitlines())
        self.assertIn("Each connected route has its own clientId", first.stdout)
        files = [runtime_toml(base), manifests / "masc_browser_host.json",
                 lane(base) / "host/launch", lane(base) / "token"]
        before = [path.read_bytes() for path in files]
        second = masc(root, *arguments)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual([path.read_bytes() for path in files], before)

    def test_an_option_the_chosen_modes_do_not_use_is_refused(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        for arguments in (("--mode", "bidi", "--manifest-dir", str(root / "manifests")),
                          ("--mode", "bidi", "--host-name", "masc.other"),
                          ("--mode", "extension", "--firefox", str(fake_firefox(root))),
                          ("--mode", "extension", "--profile", str(root / "profile")),
                          ("--mode", "extension", "--port", "9333"),
                          ("--mode", "host", "--manifest-dir", str(root / "manifests")),
                          ("--mode", "host", "--firefox", str(fake_firefox(root))),
                          ("--mode", "host", "--port", "9333"),
                          ("--binary", str(HOST))):
            with self.subTest(arguments):
                result = masc(root, "--base-path", str(base), *arguments)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("only applies with", result.stderr)
                self.assertFalse(lane(base).exists(), "nothing was installed")
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
                result = masc(root, "--mode", "bidi", "--binary", str(HOST),
                              "--base-path", str(base), *arguments)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(sentence, result.stderr)
                self.assertFalse(lane(base).exists(), "the host was not installed first")
                self.assertEqual(runtime_toml(base).read_text(), before)

    def test_a_profile_that_cannot_be_made_is_refused_before_the_host_is_installed(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        locked = root / "locked"
        locked.mkdir(mode=0o500)
        self.addCleanup(locked.chmod, 0o700)
        result = masc(root, "--mode", "bidi", "--binary", str(HOST), "--base-path", str(base),
                      "--firefox", str(fake_firefox(root)), "--profile", str(locked / "profile"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Could not create the profile directory", result.stderr)
        self.assertFalse(lane(base).exists(), "nothing was installed")
        self.assertEqual(runtime_toml(base).read_text(), before)

    def test_a_table_that_cannot_be_written_leaves_the_host_and_no_table(self):
        root = self.scratch()
        base = workspace(root)
        before = runtime_toml(base).read_text()
        # masc needs to create its lock file beside runtime.toml; a directory
        # it cannot write into fails the commit, which comes after the host.
        config = runtime_toml(base).parent
        config.chmod(0o500)
        self.addCleanup(config.chmod, 0o700)
        result = masc(root, "--mode", "bidi", "--binary", str(HOST), "--base-path", str(base),
                      "--firefox", str(fake_firefox(root)), "--profile", str(root / "profile"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("runtime.toml was not written", result.stderr)
        # The host is installed first and the table last, so what a failure
        # leaves is an installed lane and no table, never a table with no lane.
        self.assertTrue((lane(base) / "host/launch.json").is_file())
        self.assertEqual(runtime_toml(base).read_text(), before)

    def test_a_live_lane_that_is_off_says_so_instead_of_asking_for_a_restart(self):
        root = self.scratch()
        base = workspace(root)
        runtime_toml(base).write_text(RUNTIME_TOML + "\n[browser.live]\nenabled = false\n")
        result = masc(root, "--mode", "bidi", "--binary", str(HOST), "--base-path", str(base),
                      "--firefox", str(fake_firefox(root)), "--profile", str(root / "profile"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[browser.live.bidi]", runtime_toml(base).read_text().splitlines())
        self.assertIn("keeps the live lane off", result.stdout)

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
            [str(MASC), "browser-lane-setup", "--mode", "bidi", "--binary", str(HOST),
             "--base-path", str(base), "--firefox", str(fake_firefox(root)),
             "--profile", str(root / "profile")],
            env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[browser.live.bidi]", (elsewhere / "runtime.toml").read_text().splitlines())
        self.assertFalse((base / ".masc/config/runtime.toml").exists())

    def test_bidi_without_a_runtime_toml_creates_nothing(self):
        root = self.scratch()
        base = root / "workspace"
        result = masc(root, "--mode", "bidi", "--binary", str(HOST), "--base-path", str(base))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("masc init", result.stderr)
        self.assertFalse(base.exists())

    # --base-path names the workspace that holds .masc, as for every command.
    def test_a_trailing_dot_masc_in_the_workspace_path_is_dropped(self):
        root = self.scratch()
        base = root / "workspace"
        result = masc(root, "--mode", "extension", "--binary", str(HOST),
                      "--base-path", str(base / ".masc"), "--manifest-dir", str(root / "manifests"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((lane(base) / "host/launch").is_file())
        self.assertFalse((base / ".masc/.masc").exists())


if __name__ == "__main__":
    unittest.main()
