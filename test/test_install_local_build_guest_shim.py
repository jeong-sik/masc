#!/usr/bin/env python3
"""A local install brings a workspace's release guest shim to the build's release."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import test_install_local_build as local_build

SCRIPT = local_build.SCRIPT
VERSION = "9.8.7"
ARM64 = "masc-exec-shim-linux-arm64"
AMD64 = "masc-exec-shim-linux-amd64"
OLD_SHIM = b"shim of an older release\n"
NEW_SHIM = b"shim of the build's release\n"


def sha256(content):
    return hashlib.sha256(content).hexdigest()


# What the release ships for [asset]: the architecture is part of the content,
# so a test can tell which of the two was installed.
def shipped(asset):
    return NEW_SHIM + asset.encode()


def server_naming(build, version):
    server = build / "main_eio.exe"
    server.write_text(f'#!/bin/sh\nif [ "$1" = --version ]; then echo {version}; fi\n')
    server.chmod(0o755)


# A build whose server names [version] the way masc --version does.
# [unnamed_workspace] is what the helper answers when --base-path is not given.
def build_naming(root, version=VERSION, unnamed_workspace=None):
    build = root / "build"
    build.mkdir()
    local_build.binaries(build)
    server_naming(build, version)
    local_build.preflight_helper(build, unnamed_workspace=unnamed_workspace)
    return build


# A release as MASC_RELEASE_BASE_URL serves it: <base>/v<version>/<asset> and
# its SHA256SUMS, with both guest architectures. [listed] maps an asset to the
# content SHA256SUMS vouches for when that is not what the asset holds;
# [unlisted] names assets SHA256SUMS leaves out; [absent] names assets it
# lists but the release does not serve.
def release_base(root, listed=None, unlisted=(), absent=()):
    directory = root / "releases" / f"v{VERSION}"
    directory.mkdir(parents=True)
    lines = [f"{sha256(b'another asset')}  masc-macos-arm64"]
    for asset in (ARM64, AMD64):
        if asset not in absent:
            (directory / asset).write_bytes(shipped(asset))
        if asset not in unlisted:
            vouched = (listed or {}).get(asset, shipped(asset))
            lines.append(f"{sha256(vouched)}  {asset}")
    (directory / "SHA256SUMS").write_text("\n".join(lines) + "\n")
    return (root / "releases").as_uri()


def sidecar_line(content, asset=ARM64):
    return f"{sha256(content)}  {asset}\n"


# The workspace's shim directory as the release installer leaves it: the
# binary, and beside it the release's SHA256SUMS line for the asset that was
# installed. Without [sidecar] it is what scripts/remote-ssh/build-shim.sh
# leaves: a hand build.
def workspace_with_shim(root, content=OLD_SHIM, sidecar: str | None = sidecar_line(OLD_SHIM)):
    base = local_build.workspace(root)
    directory = base / ".masc/microvm/shim"
    directory.mkdir(parents=True)
    shim = directory / "masc-exec-shim"
    shim.write_bytes(content)
    shim.chmod(0o755)
    if sidecar is not None:
        (directory / "masc-exec-shim.sha256").write_text(sidecar)
    return base, shim, directory / "masc-exec-shim.sha256"


def install(root, build, releases, base=None, *more, env=None):
    named = [] if base is None else ["--base-path", str(base)]
    return subprocess.run(
        ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
         "--prefix", str(root / "prefix"), "--manifest-dir", str(root / "absent"),
         *named, *more],
        env=dict(os.environ if env is None else env, MASC_RELEASE_BASE_URL=releases),
        cwd=root, capture_output=True, text=True)


def warnings(result):
    return [line for line in result.stderr.splitlines() if "WARN" in line]


def shim_directory(shim):
    return sorted(path.name for path in shim.parent.iterdir())


PAIR = ["masc-exec-shim", "masc-exec-shim.sha256"]


class GuestShim(unittest.TestCase):
    def test_invalid_browser_addon_inputs_leave_installed_programs_and_guest_shim_untouched(self):
        for program in local_build.BROWSER_ADDON_PROGRAMS:
            for invalid in ("missing", "not_executable", "directory"):
                with self.subTest(program=program, invalid=invalid), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary).resolve()
                    base, shim, sidecar = workspace_with_shim(root)
                    build = build_naming(root)
                    bad = build / f"{program}.exe"
                    if invalid == "not_executable":
                        bad.chmod(0o600)
                    else:
                        bad.unlink()
                        if invalid == "directory":
                            bad.mkdir()
                    prefix = root / "prefix"
                    prefix.mkdir()
                    old_server = local_build.executable(prefix / "masc", "old-server")
                    old_worker = local_build.executable(prefix / "masc-browser-addon-worker", "old-worker")
                    before = {p: p.read_bytes() for p in (shim, sidecar, old_server, old_worker)}
                    result = install(root, build, release_base(root), base)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(str(bad), result.stderr)
                    for path, content in before.items():
                        self.assertEqual(path.read_bytes(), content, str(path))
                    self.assertEqual(local_build.helper_calls(build), [])
                    self.assertEqual(local_build.lane_calls(prefix), [])

    # #42726: the release installer was the only thing that placed the shim, so
    # a workspace deployed from local builds kept the shim of its last release
    # install while the server moved on. Which architecture is the sidecar's
    # to say: a Rosetta shell on Apple Silicon would have picked the wrong one.
    def test_a_shim_from_another_release_is_replaced_with_the_same_asset_of_the_builds(self):
        for asset in (ARM64, AMD64):
            with self.subTest(asset=asset), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                base, shim, sidecar = workspace_with_shim(
                    root, sidecar=sidecar_line(OLD_SHIM, asset))
                result = install(root, build_naming(root), release_base(root), base)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(shim.read_bytes(), shipped(asset))
                self.assertTrue(os.access(shim, os.X_OK),
                                "the guest cannot run a shim without the execute bit")
                self.assertEqual(sidecar.read_text(), sidecar_line(shipped(asset), asset))
                self.assertEqual(shim_directory(shim), PAIR)
                self.assertIn(f"installed the v{VERSION} guest exec shim", result.stdout)
                self.assertEqual(result.stderr, "")
                self.assertTrue((root / "prefix/masc").is_file())

    # The operator's own call names no workspace: the one masc would use is
    # the one whose shim is brought up.
    def test_the_workspace_masc_resolves_gets_its_shim_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, sidecar = workspace_with_shim(root)
            build = build_naming(root, unnamed_workspace=(base, "persisted_default"))
            result = install(root, build, release_base(root), env=local_build.unnamed_env(root))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.read_bytes(), shipped(ARM64))
            self.assertEqual(sidecar.read_text(), sidecar_line(shipped(ARM64)))

    # The asset is not served here, so a download would fail: the sums alone
    # say the shim is current.
    def test_a_shim_already_from_the_builds_release_is_not_downloaded_again(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, _ = workspace_with_shim(
                root, content=shipped(ARM64), sidecar=sidecar_line(shipped(ARM64)))
            before = shim.stat().st_ino
            result = install(root, build_naming(root), release_base(root, absent=(ARM64,)), base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.stat().st_ino, before, "a current shim was replaced")
            self.assertIn(f"is already the v{VERSION} asset", result.stdout)
            self.assertEqual(result.stderr, "")
            self.assertEqual(shim_directory(shim), PAIR)

    # A pair that disagrees is the pair the microVM boot refuses, whichever
    # half is the current one.
    def test_a_pair_with_one_current_half_is_replaced_whole(self):
        for label, content, recorded in (
                ("old binary beside the release's sidecar", OLD_SHIM, shipped(ARM64)),
                ("the release's binary beside an old sidecar", shipped(ARM64), OLD_SHIM)):
            with self.subTest(label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                base, shim, sidecar = workspace_with_shim(
                    root, content=content, sidecar=sidecar_line(recorded))
                result = install(root, build_naming(root), release_base(root), base)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(shim.read_bytes(), shipped(ARM64))
                self.assertEqual(sidecar.read_text(), sidecar_line(shipped(ARM64)))

    def test_a_hand_built_shim_is_left_alone(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, sidecar = workspace_with_shim(root, sidecar=None)
            result = install(root, build_naming(root), release_base(root), base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.read_bytes(), OLD_SHIM)
            self.assertFalse(sidecar.exists(), "a hand-built shim was given a release sidecar")
            self.assertIn("built by hand", result.stdout)
            self.assertTrue((root / "prefix/masc").is_file())

    def test_a_workspace_without_a_shim_is_given_none(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base = local_build.workspace(root)
            result = install(root, build_naming(root), release_base(root), base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((base / ".masc/microvm").exists())
            self.assertNotIn("guest exec shim", result.stdout + result.stderr)

    def test_no_guest_shim_leaves_the_shim_and_asks_no_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, sidecar = workspace_with_shim(root)
            result = install(root, build_naming(root), release_base(root), base, "--no-guest-shim")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.read_bytes(), OLD_SHIM)
            self.assertEqual(sidecar.read_text(), sidecar_line(OLD_SHIM))
            self.assertNotIn("guest exec shim", result.stdout + result.stderr)
            self.assertTrue((root / "prefix/masc").is_file())

    # A sidecar that names no release asset says nothing about which
    # architecture to fetch, and a guess could install the wrong one.
    def test_a_sidecar_that_names_no_release_asset_leaves_the_shim(self):
        for label, written in (("another name", f"{sha256(OLD_SHIM)}  masc-exec-shim\n"),
                               ("a hash alone", f"{sha256(OLD_SHIM)}\n"),
                               ("empty", "")):
            with self.subTest(label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                base, shim, sidecar = workspace_with_shim(root, sidecar=written)
                result = install(root, build_naming(root), release_base(root), base)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(shim.read_bytes(), OLD_SHIM)
                self.assertEqual(sidecar.read_text(), written)
                self.assertEqual(len(warnings(result)), 1, result.stderr)
                self.assertIn("does not name a release shim asset", warnings(result)[0])
                self.assertTrue((root / "prefix/masc").is_file())

    # No network, a mirror without the release, a version built before its
    # tag was published. The server and the shim keep working one release
    # apart, so the install goes ahead, and the one line says what curl said.
    def test_a_release_that_cannot_be_read_leaves_the_shim_and_installs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, sidecar = workspace_with_shim(root)
            (root / "releases").mkdir()
            result = install(root, build_naming(root), (root / "releases").as_uri(), base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.read_bytes(), OLD_SHIM)
            self.assertEqual(sidecar.read_text(), sidecar_line(OLD_SHIM))
            self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
            self.assertIn(f"v{VERSION}/SHA256SUMS could not be read (curl:", result.stderr)
            self.assertIn("WARN", result.stderr)
            self.assertEqual(shim_directory(shim), PAIR)
            self.assertTrue((root / "prefix/masc").is_file())

    def test_a_release_that_lists_no_shim_leaves_the_shim_and_installs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, _ = workspace_with_shim(root)
            result = install(root, build_naming(root), release_base(root, unlisted=(ARM64,)), base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.read_bytes(), OLD_SHIM)
            self.assertEqual(len(warnings(result)), 1, result.stderr)
            self.assertIn(f"lists no {ARM64}", warnings(result)[0])

    # The release lists the asset and then does not serve it: nothing half
    # downloaded is left where the guests look.
    def test_an_asset_that_cannot_be_downloaded_leaves_the_shim_and_installs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, sidecar = workspace_with_shim(root)
            result = install(root, build_naming(root), release_base(root, absent=(ARM64,)), base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.read_bytes(), OLD_SHIM)
            self.assertEqual(sidecar.read_text(), sidecar_line(OLD_SHIM))
            self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
            self.assertIn(f"{ARM64} could not be downloaded (curl:", result.stderr)
            self.assertEqual(shim_directory(shim), PAIR)
            self.assertTrue((root / "prefix/masc").is_file())

    def test_a_build_that_names_no_release_leaves_the_shim_and_installs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, _ = workspace_with_shim(root)
            result = install(root, build_naming(root, version="dev"), release_base(root), base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.read_bytes(), OLD_SHIM)
            self.assertEqual(len(warnings(result)), 1, result.stderr)
            self.assertIn("names no release version", warnings(result)[0])
            self.assertIn("'dev'", warnings(result)[0])

    # A shim the release did not ship is what the sidecar exists to refuse, so
    # it stops the install before the server is replaced.
    def test_an_asset_that_fails_its_checksum_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, sidecar = workspace_with_shim(root)
            releases = release_base(root, listed={ARM64: b"what the release meant to ship\n"})
            result = install(root, build_naming(root), releases, base)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match its SHA256SUMS line", result.stderr)
            self.assertIn("nothing installed", result.stderr)
            self.assertEqual(shim.read_bytes(), OLD_SHIM)
            self.assertEqual(sidecar.read_text(), sidecar_line(OLD_SHIM))
            self.assertEqual(shim_directory(shim), PAIR)
            self.assertFalse((root / "prefix").exists(),
                             "the server was replaced beside a refused shim")

    def test_help_prints_the_usage_block_and_nothing_else(self):
        result = subprocess.run(["bash", str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        lines = result.stdout.splitlines()
        self.assertTrue(lines[0].startswith("# Usage: scripts/install-local-build.sh"), lines[0])
        self.assertTrue(lines[-1].startswith("#   --no-guest-shim"), lines[-1])
        for option in ("--prefix", "--manifest-dir", "--skip-build", "--build-dir",
                       "--base-path", "--keep-build", "--no-guest-shim"):
            self.assertEqual(sum(line.startswith(f"#   {option} ") for line in lines), 1, option)


if __name__ == "__main__":
    unittest.main()
