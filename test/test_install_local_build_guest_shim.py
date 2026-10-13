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
# The guest runs the host's architecture, as scripts/install.sh maps it.
ASSET = {"arm64": "masc-exec-shim-linux-arm64", "aarch64": "masc-exec-shim-linux-arm64",
         "x86_64": "masc-exec-shim-linux-amd64", "amd64": "masc-exec-shim-linux-amd64"}[os.uname().machine]
OLD_SHIM = b"shim of an older release\n"
NEW_SHIM = b"shim of the build's release\n"


def sha256(content):
    return hashlib.sha256(content).hexdigest()


# A build whose server names [version] the way masc --version does.
def build_naming(root, version=VERSION):
    build = root / "build"
    build.mkdir()
    local_build.binaries(build)
    server = build / "main_eio.exe"
    server.write_text(f'#!/bin/sh\nif [ "$1" = --version ]; then echo {version}; fi\n')
    server.chmod(0o755)
    local_build.preflight_helper(build)
    return build


# A release as MASC_RELEASE_BASE_URL serves it: <base>/v<version>/<asset> and
# its SHA256SUMS. [listed] is the content SHA256SUMS vouches for, when that is
# not what the asset holds; [list_asset=False] is a release that ships no shim.
def release_base(root, asset=NEW_SHIM, listed=None, list_asset=True):
    directory = root / "releases" / f"v{VERSION}"
    directory.mkdir(parents=True)
    (directory / ASSET).write_bytes(asset)
    lines = [f"{sha256(b'another asset')}  masc-macos-arm64"]
    if list_asset:
        lines.append(f"{sha256(asset if listed is None else listed)}  {ASSET}")
    (directory / "SHA256SUMS").write_text("\n".join(lines) + "\n")
    return (root / "releases").as_uri()


# The workspace's shim directory as the release installer leaves it. Without
# [sidecar] it is what scripts/remote-ssh/build-shim.sh leaves: a hand build.
def workspace_with_shim(root, content=OLD_SHIM, sidecar: bytes | None = OLD_SHIM):
    base = local_build.workspace(root)
    directory = base / ".masc/microvm/shim"
    directory.mkdir(parents=True)
    shim = directory / "masc-exec-shim"
    shim.write_bytes(content)
    shim.chmod(0o755)
    if sidecar is not None:
        (directory / "masc-exec-shim.sha256").write_text(f"{sha256(sidecar)}  {ASSET}\n")
    return base, shim, directory / "masc-exec-shim.sha256"


def install(root, build, base, releases):
    return subprocess.run(
        ["bash", str(SCRIPT), "--skip-build", "--build-dir", str(build),
         "--prefix", str(root / "prefix"), "--manifest-dir", str(root / "absent"),
         "--base-path", str(base)],
        env=dict(os.environ, MASC_RELEASE_BASE_URL=releases),
        capture_output=True, text=True)


def warnings(result):
    return [line for line in result.stderr.splitlines() if "WARN" in line]


class GuestShim(unittest.TestCase):
    # #42726: the release installer was the only thing that placed the shim, so
    # a workspace deployed from local builds kept the shim of its last release
    # install while the server moved on.
    def test_a_shim_from_another_release_is_replaced_with_the_builds(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, sidecar = workspace_with_shim(root)
            result = install(root, build_naming(root), base, release_base(root))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.read_bytes(), NEW_SHIM)
            self.assertTrue(os.access(shim, os.X_OK), "the guest cannot run a shim without the execute bit")
            self.assertEqual(sidecar.read_text(), f"{sha256(NEW_SHIM)}  {ASSET}\n")
            self.assertEqual(sorted(path.name for path in shim.parent.iterdir()),
                             ["masc-exec-shim", "masc-exec-shim.sha256"])
            self.assertIn(f"installed the v{VERSION} guest exec shim", result.stdout)
            self.assertEqual(warnings(result), [])
            self.assertTrue((root / "prefix/masc").is_file())

    # The asset is not in the release directory here, so a download would fail:
    # the sums alone say the shim is current.
    def test_a_shim_already_from_the_builds_release_is_not_downloaded_again(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, _ = workspace_with_shim(root, content=NEW_SHIM, sidecar=NEW_SHIM)
            releases = release_base(root)
            (root / "releases" / f"v{VERSION}" / ASSET).unlink()
            before = shim.stat().st_ino
            result = install(root, build_naming(root), base, releases)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.stat().st_ino, before, "a current shim was replaced")
            self.assertIn(f"is already the v{VERSION} asset", result.stdout)
            self.assertEqual(warnings(result), [])

    # A sidecar that names the release while the binary beside it holds
    # something else is the pair the microVM boot refuses.
    def test_a_binary_that_disagrees_with_a_current_sidecar_is_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, sidecar = workspace_with_shim(root, content=OLD_SHIM, sidecar=NEW_SHIM)
            result = install(root, build_naming(root), base, release_base(root))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.read_bytes(), NEW_SHIM)
            self.assertEqual(sidecar.read_text(), f"{sha256(NEW_SHIM)}  {ASSET}\n")

    def test_a_hand_built_shim_is_left_alone(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, sidecar = workspace_with_shim(root, sidecar=None)
            result = install(root, build_naming(root), base, release_base(root))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.read_bytes(), OLD_SHIM)
            self.assertFalse(sidecar.exists(), "a hand-built shim was given a release sidecar")
            self.assertIn("built by hand", result.stdout)
            self.assertTrue((root / "prefix/masc").is_file())

    def test_a_workspace_without_a_shim_is_given_none(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base = local_build.workspace(root)
            result = install(root, build_naming(root), base, release_base(root))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((base / ".masc/microvm").exists())
            self.assertNotIn("guest exec shim", result.stdout + result.stderr)

    # Main names a version before its release is published. The server and the
    # shim keep working one release apart, so the install goes ahead.
    def test_an_unpublished_release_leaves_the_shim_and_installs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, sidecar = workspace_with_shim(root)
            (root / "releases").mkdir()
            result = install(root, build_naming(root), base, (root / "releases").as_uri())
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.read_bytes(), OLD_SHIM)
            self.assertEqual(sidecar.read_text(), f"{sha256(OLD_SHIM)}  {ASSET}\n")
            self.assertEqual(len(warnings(result)), 1, result.stderr)
            self.assertIn(f"v{VERSION}/SHA256SUMS could not be read", warnings(result)[0])
            self.assertTrue((root / "prefix/masc").is_file())

    def test_a_release_that_lists_no_shim_leaves_the_shim_and_installs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, _ = workspace_with_shim(root)
            result = install(root, build_naming(root), base, release_base(root, list_asset=False))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(shim.read_bytes(), OLD_SHIM)
            self.assertEqual(len(warnings(result)), 1, result.stderr)
            self.assertIn(f"lists no {ASSET}", warnings(result)[0])

    def test_a_build_that_names_no_release_leaves_the_shim_and_installs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            base, shim, _ = workspace_with_shim(root)
            result = install(root, build_naming(root, version="dev"), base, release_base(root))
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
            releases = release_base(root, asset=b"not what the release shipped\n", listed=NEW_SHIM)
            result = install(root, build_naming(root), base, releases)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match its SHA256SUMS line", result.stderr)
            self.assertIn("nothing installed", result.stderr)
            self.assertEqual(shim.read_bytes(), OLD_SHIM)
            self.assertEqual(sidecar.read_text(), f"{sha256(OLD_SHIM)}  {ASSET}\n")
            self.assertEqual(sorted(path.name for path in shim.parent.iterdir()),
                             ["masc-exec-shim", "masc-exec-shim.sha256"])
            self.assertFalse((root / "prefix").exists(), "the server was replaced beside a refused shim")


if __name__ == "__main__":
    unittest.main()
