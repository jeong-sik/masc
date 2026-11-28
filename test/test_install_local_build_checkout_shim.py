#!/usr/bin/env python3
"""A local install rebuilds a source-built guest shim from its checkout (#53164)."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import test_install_local_build as local_build
import test_install_local_build_guest_shim as guest_shim

BUILD_SOURCE = guest_shim.BUILD_SOURCE
OTHER_SOURCE = guest_shim.OTHER_SOURCE
# The source of a later commit, for a second rebuild.
LATER_SOURCE = "d" * 40 + "/clean"
PREVIOUS = "masc-exec-shim.previous"
# ELF e_machine values (offset 18, little-endian).
EM_AARCH64 = 0xB7
EM_X86_64 = 0x3E
EM_ARM = 0x28
GUEST_ARCHES = ((EM_AARCH64, "arm64"), (EM_X86_64, "amd64"))
BY_HAND = "scripts/remote-ssh/build-shim.sh --arch"

# Stands in for scripts/remote-ssh/build-shim.sh, which needs Docker. It
# records the directory it runs in and its arguments as one line in
# build-shim-calls at the checkout root. Like the real script it writes to
# <checkout>/<--out>/masc-exec-shim-linux-<arch>, so an --out that is not
# relative to the checkout leaves nothing there. It copies the shim the case
# put at fixture-shim-<arch>, and fails as a Docker that is not running when
# fixture-build-fails exists.
FAKE_BUILD_SHIM = '''#!/bin/sh
top=$(pwd -P)
printf '%s %s\\n' "$top" "$*" >> "$(dirname "$0")/../../build-shim-calls"
arch=""
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) arch=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    *) echo "unexpected argument $1" >&2; exit 2 ;;
  esac
done
if [ -f "$top/fixture-build-fails" ]; then
  echo "fixture: Cannot connect to the Docker daemon" >&2
  exit 1
fi
cp "$top/fixture-shim-$arch" "$top/$out/masc-exec-shim-linux-$arch"
'''


# The first bytes of a 64-bit ELF executable for [machine], then the source
# declaration a shim of [source] carries, or none when [source] is None.
def elf(machine, source, little_endian=True):
    data = 1 if little_endian else 2
    order = "little" if little_endian else "big"
    header = (b"\x7fELF" + bytes([2, data, 1, 0]) + bytes(8)
              + (2).to_bytes(2, order) + machine.to_bytes(2, order))
    declaration = b"" if source is None else guest_shim.declaring(source)
    return header + declaration + b"\nshim\n"


# A checkout that holds the real install-local-build.sh and the stand-in
# build-shim.sh, which builds [built] for each guest architecture.
def checkout(root, built=lambda machine: elf(machine, BUILD_SOURCE), build_fails=False):
    repo = root / "checkout"
    scripts = repo / "scripts"
    (scripts / "lib").mkdir(parents=True)
    (scripts / "remote-ssh").mkdir()
    shutil.copy2(local_build.SCRIPT, scripts / local_build.SCRIPT.name)
    shutil.copy2(local_build.REPO / "scripts/lib/install-workspace-dashboard.sh", scripts / "lib")
    local_build.executable(scripts / "check-runtime-deployment-preflight.sh", "fixture-preflight")
    stub = scripts / "remote-ssh/build-shim.sh"
    stub.write_text(FAKE_BUILD_SHIM)
    stub.chmod(0o755)
    for machine, arch in GUEST_ARCHES:
        (repo / f"fixture-shim-{arch}").write_bytes(built(machine))
    if build_fails:
        (repo / "fixture-build-fails").touch()
    return repo


# curl records that it was asked, so a case can show no release was read.
def no_release_env(root):
    hooks = root / "hooks"
    hooks.mkdir(exist_ok=True)
    curl = hooks / "curl"
    curl.write_text(f'#!/bin/sh\ntouch "{root / "release-requested"}"\nexit 99\n')
    curl.chmod(0o755)
    env = local_build.unnamed_env(root)
    env["PATH"] = str(hooks) + os.pathsep + env["PATH"]
    env["MASC_RELEASE_BASE_URL"] = (root / "no-releases").as_uri()
    return env


# An mv that refuses the one rename whose source and target match the shell
# patterns [source] and [target], and is the real mv for every other.
# no_release_env puts the hooks directory first on PATH.
def refusing_mv(root, source, target):
    hooks = root / "hooks"
    hooks.mkdir(exist_ok=True)
    mv = hooks / "mv"
    mv.write_text(f'''#!/bin/sh
for target; do :; done
case "$1 -> $target" in
  {source}" -> "{target}) echo "fixture: mv refused" >&2; exit 1 ;;
esac
exec {shutil.which("mv")} "$@"
''')
    mv.chmod(0o755)


def install(root, repo, build, base, *more):
    return subprocess.run(
        ["bash", str(repo / "scripts" / local_build.SCRIPT.name), "--skip-build",
         "--build-dir", str(build), "--prefix", str(root / "prefix"),
         "--base-path", str(base), *more],
        env=no_release_env(root), cwd=root, capture_output=True, text=True)


def build_calls(repo):
    calls = repo / "build-shim-calls"
    return calls.read_text().splitlines() if calls.exists() else []


# What install-local-build left of its build directories in the checkout.
def leftover_builds(repo):
    out = repo / "dist/remote-ssh"
    return sorted(p.name for p in out.iterdir()) if out.exists() else []


class CheckoutGuestShim(unittest.TestCase):
    # A refused install changes nothing: the shim still holds [content] and
    # has no company, the checkout keeps no build directory, and no binary
    # was installed.
    def refused(self, content, result, root, repo, shim):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nothing installed", result.stderr)
        self.assertEqual(shim.read_bytes(), content)
        self.assertEqual(guest_shim.shim_directory(shim), ["masc-exec-shim"])
        self.assertEqual(leftover_builds(repo), [])
        self.assertFalse((root / "prefix").exists(),
                         "the server was replaced beside a shim it refuses")

    def test_a_shim_of_this_build_is_kept_and_nothing_is_built(self):
        for more in ((), ("--refresh-guest-shim",)):
            with self.subTest(more=more), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                repo = checkout(root)
                current = elf(EM_AARCH64, BUILD_SOURCE)
                base, shim, _ = guest_shim.workspace_with_shim(root, content=current, sidecar=None)
                inode = shim.stat().st_ino
                result = install(root, repo, guest_shim.build_naming(root), base, *more)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(build_calls(repo), [])
                self.assertEqual(shim.stat().st_ino, inode, "a current shim was replaced")
                self.assertEqual(guest_shim.shim_directory(shim), ["masc-exec-shim"])
                self.assertIn(f"already declares this build's source identity {BUILD_SOURCE}",
                              result.stdout)
                self.assertFalse((root / "release-requested").exists(),
                                 "a source-built shim asked for a release")
                self.assertTrue((root / "prefix/masc").is_file())

    # The architecture is the old shim's, read from its ELF header, and the
    # old shim stays beside the new one as the one previous copy.
    def test_a_shim_of_another_source_is_rebuilt_from_the_checkout_with_a_previous_copy(self):
        for (machine, arch), old_source in ((arch, source) for arch in GUEST_ARCHES
                                            for source in (OTHER_SOURCE, None)):
            with self.subTest(arch=arch, old_source=old_source), \
                    tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                repo = checkout(root)
                old = elf(machine, old_source)
                base, shim, sidecar = guest_shim.workspace_with_shim(root, content=old, sidecar=None)
                result = install(root, repo, guest_shim.build_naming(root), base)
                self.assertEqual(result.returncode, 0, result.stderr)
                [call] = build_calls(repo)
                self.assertTrue(call.startswith(
                    f"{repo} --arch {arch} --out dist/remote-ssh/install-local-build."), call)
                self.assertEqual(shim.read_bytes(), elf(machine, BUILD_SOURCE))
                self.assertTrue(os.access(shim, os.X_OK),
                                "the guest cannot run a shim without the execute bit")
                self.assertFalse(sidecar.exists(), "a source-built shim was given a sidecar")
                self.assertEqual(guest_shim.shim_directory(shim), ["masc-exec-shim", PREVIOUS])
                self.assertEqual((shim.parent / PREVIOUS).read_bytes(), old)
                self.assertEqual(leftover_builds(repo), [])
                self.assertIn(f"installed the {arch} guest exec shim built from {repo}",
                              result.stdout)
                self.assertTrue((root / "prefix/masc").is_file())

    # A second rebuild replaces the previous copy instead of adding one, and
    # copies other hands left in the directory stay as they are.
    def test_two_rebuilds_keep_one_previous_copy_and_leave_hand_copies(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repo = checkout(root)
            old = elf(EM_AARCH64, OTHER_SOURCE)
            base, shim, _ = guest_shim.workspace_with_shim(root, content=old, sidecar=None)
            hand_copies = {shim.parent / "masc-exec-shim.bak-20261118T234400Z": b"hand swap\n",
                           shim.parent / "masc-exec-shim.sha256.20261118": b"old sidecar\n"}
            for path, content in hand_copies.items():
                path.write_bytes(content)
            first = install(root, repo, guest_shim.build_naming(root), base)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual((shim.parent / PREVIOUS).read_bytes(), old)
            later = root / "later"
            later.mkdir()
            (repo / "fixture-shim-arm64").write_bytes(elf(EM_AARCH64, LATER_SOURCE))
            second = install(root, repo, guest_shim.build_naming(later, source=LATER_SOURCE), base)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(len(build_calls(repo)), 2)
            self.assertEqual(shim.read_bytes(), elf(EM_AARCH64, LATER_SOURCE))
            self.assertEqual((shim.parent / PREVIOUS).read_bytes(), elf(EM_AARCH64, BUILD_SOURCE))
            self.assertEqual(guest_shim.shim_directory(shim),
                             sorted(["masc-exec-shim", PREVIOUS, *(p.name for p in hand_copies)]))
            for path, content in hand_copies.items():
                self.assertEqual(path.read_bytes(), content, str(path))

    # Docker is not running: the shim, the prefix and the checkout stay as
    # they were, and the refusal says how to build the shim by hand.
    def test_a_failed_build_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repo = checkout(root, build_fails=True)
            old = elf(EM_AARCH64, OTHER_SOURCE)
            base, shim, _ = guest_shim.workspace_with_shim(root, content=old, sidecar=None)
            result = install(root, repo, guest_shim.build_naming(root), base)
            self.refused(old, result, root, repo, shim)
            self.assertEqual(len(build_calls(repo)), 1)
            self.assertIn("Cannot connect to the Docker daemon", result.stderr)
            self.assertIn("build-shim.sh --arch arm64 failed", result.stderr)
            self.assertIn(f"so no shim was built for {shim}", result.stderr)
            self.assertIn(f"{BY_HAND} arm64 && install -m 755 dist/remote-ssh/masc-exec-shim-linux-arm64",
                          result.stderr)
            # printf %q escapes the space in the fixture's workspace path.
            quoted = str(shim).replace(" ", "\\ ")
            self.assertIn(f"&& mv {quoted}.partial {quoted}", result.stderr)

    # The checkout changed after the server was built: its shim would be
    # refused like the old one.
    def test_a_built_shim_of_another_source_installs_nothing(self):
        for label, source in (("another source", OTHER_SOURCE), ("no declaration", None)):
            with self.subTest(label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                repo = checkout(root, built=lambda machine, source=source: elf(machine, source))
                old = elf(EM_AARCH64, OTHER_SOURCE)
                base, shim, _ = guest_shim.workspace_with_shim(root, content=old, sidecar=None)
                result = install(root, repo, guest_shim.build_naming(root), base)
                self.refused(old, result, root, repo, shim)
                declared = "none" if source is None else source
                self.assertIn(f"declares {declared} instead", result.stderr)

    # 2026-11-21: a release shim with its sidecar was put under a checkout
    # server. The install left it alone and ended 0 each of the next fourteen
    # times, every restarted server refused it, and three microVM Keepers ran
    # no guest command for 73 hours. The sidecar says where the bytes came
    # from; whether this build's server runs them is the identity they declare.
    def test_a_release_shim_of_another_source_is_rebuilt_and_loses_its_sidecar(self):
        for (machine, arch), old_source in ((arch, source) for arch in GUEST_ARCHES
                                            for source in (OTHER_SOURCE, None)):
            with self.subTest(arch=arch, old_source=old_source), \
                    tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                repo = checkout(root)
                old = elf(machine, old_source)
                base, shim, sidecar = guest_shim.workspace_with_shim(
                    root, content=old, sidecar=guest_shim.sidecar_line(old))
                result = install(root, repo, guest_shim.build_naming(root), base)
                self.assertEqual(result.returncode, 0, result.stderr)
                [call] = build_calls(repo)
                self.assertTrue(call.startswith(
                    f"{repo} --arch {arch} --out dist/remote-ssh/install-local-build."), call)
                self.assertEqual(shim.read_bytes(), elf(machine, BUILD_SOURCE))
                self.assertFalse(sidecar.exists(),
                                 "the sidecar of the replaced shim stayed beside a shim it does not describe")
                self.assertEqual(guest_shim.shim_directory(shim), ["masc-exec-shim", PREVIOUS])
                self.assertEqual((shim.parent / PREVIOUS).read_bytes(), old)
                self.assertIn(f"{sidecar} described the replaced shim and was removed", result.stdout)
                self.assertFalse((root / "release-requested").exists(),
                                 "a default install requested a release")
                self.assertTrue((root / "prefix/masc").is_file())

    # The sidecar still describes these bytes, so it stays with them.
    def test_a_release_shim_of_this_build_keeps_its_sidecar_and_nothing_is_built(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repo = checkout(root)
            current = elf(EM_AARCH64, BUILD_SOURCE)
            recorded = guest_shim.sidecar_line(current)
            base, shim, sidecar = guest_shim.workspace_with_shim(root, content=current, sidecar=recorded)
            inode = shim.stat().st_ino
            result = install(root, repo, guest_shim.build_naming(root), base)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(build_calls(repo), [])
            self.assertEqual(shim.stat().st_ino, inode, "a current shim was replaced")
            self.assertEqual(sidecar.read_text(), recorded)
            self.assertEqual(guest_shim.shim_directory(shim), guest_shim.PAIR)
            self.assertFalse((root / "release-requested").exists(),
                             "a default install requested a release")
            self.assertTrue((root / "prefix/masc").is_file())

    # A refused rebuild leaves the pair as it was: the server in place still
    # runs that shim, and no new server is put beside it.
    def test_a_failed_build_leaves_a_release_shim_and_its_sidecar(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repo = checkout(root, build_fails=True)
            old = elf(EM_AARCH64, OTHER_SOURCE)
            recorded = guest_shim.sidecar_line(old)
            base, shim, sidecar = guest_shim.workspace_with_shim(root, content=old, sidecar=recorded)
            result = install(root, repo, guest_shim.build_naming(root), base)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("nothing installed", result.stderr)
            self.assertEqual(shim.read_bytes(), old)
            self.assertEqual(sidecar.read_text(), recorded)
            self.assertEqual(guest_shim.shim_directory(shim), guest_shim.PAIR)
            self.assertEqual(leftover_builds(repo), [])
            self.assertFalse((root / "prefix").exists(),
                             "the server was replaced beside a shim it refuses")
            # A shim put in place by hand beside the old sidecar would be
            # refused for its sha256, so the command removes the sidecar first.
            quoted = str(shim).replace(" ", "\\ ")
            self.assertIn(f"&& rm -f {quoted}.sha256 && mv {quoted}.partial {quoted}", result.stderr)

    # The two renames that touch the pair. When either is refused the install
    # stops with the release shim and its sidecar as they were; the copy in
    # masc-exec-shim.previous is the one thing a late refusal leaves.
    def test_a_refused_rename_leaves_a_release_shim_with_its_sidecar(self):
        for label, source, target, said in (
                ("the sidecar is not set aside", "*/masc-exec-shim.sha256", "*",
                 "could not be set aside"),
                ("the built shim is not renamed", "*/masc-exec-shim.partial.*", "*/masc-exec-shim",
                 "could not be renamed")):
            with self.subTest(label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                repo = checkout(root)
                old = elf(EM_AARCH64, OTHER_SOURCE)
                recorded = guest_shim.sidecar_line(old)
                base, shim, sidecar = guest_shim.workspace_with_shim(root, content=old, sidecar=recorded)
                refusing_mv(root, source, target)
                result = install(root, repo, guest_shim.build_naming(root), base)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("fixture: mv refused", result.stderr)
                self.assertIn(said, result.stderr)
                self.assertIn("nothing installed", result.stderr)
                self.assertEqual(shim.read_bytes(), old)
                self.assertEqual(sidecar.read_text(), recorded)
                self.assertEqual(guest_shim.shim_directory(shim),
                                 sorted([*guest_shim.PAIR, PREVIOUS]))
                self.assertEqual(leftover_builds(repo), [])
                self.assertFalse((root / "prefix").exists(),
                                 "the server was replaced beside a shim it refuses")

    # No guess from this shell: an architecture the header does not name is
    # refused before anything is built.
    def test_an_unknown_guest_architecture_installs_nothing(self):
        for label, content, found in (
                ("not an ELF file", b"#!/bin/sh\n" + guest_shim.declaring(OTHER_SOURCE), "not an ELF file"),
                ("32-bit ARM", elf(EM_ARM, OTHER_SOURCE), "ELF machine 0x28"),
                ("big-endian", elf(EM_AARCH64, OTHER_SOURCE, little_endian=False),
                 "not a little-endian ELF file")):
            with self.subTest(label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                repo = checkout(root)
                base, shim, _ = guest_shim.workspace_with_shim(root, content=content, sidecar=None)
                result = install(root, repo, guest_shim.build_naming(root), base)
                self.refused(content, result, root, repo, shim)
                self.assertEqual(build_calls(repo), [])
                self.assertIn(f"names no guest architecture this install can build ({found})",
                              result.stderr)
                self.assertIn(f"{BY_HAND} ARCH &&", result.stderr)
                self.assertIn("ARCH is arm64 or amd64", result.stderr)

    # A server without its own declaration refuses every shim, so a workspace
    # that runs microVM Keepers cannot take it.
    def test_a_build_that_declares_no_source_installs_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repo = checkout(root)
            old = elf(EM_AARCH64, OTHER_SOURCE)
            base, shim, _ = guest_shim.workspace_with_shim(root, content=old, sidecar=None)
            result = install(root, repo, guest_shim.build_naming(root, source=None), base)
            self.refused(old, result, root, repo, shim)
            self.assertEqual(build_calls(repo), [])
            self.assertIn("does not declare exactly one source identity (found: none)", result.stderr)


if __name__ == "__main__":
    unittest.main()
