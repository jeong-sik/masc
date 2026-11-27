#!/usr/bin/env python3
"""The exec shim's notice archive holds what its shim links, and the release check refuses anything less."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import sys
import tarfile
import tempfile
import unittest
from collections.abc import Mapping, Sequence
from pathlib import Path
from types import ModuleType

SCRIPT = Path(__file__).resolve().parents[1] / "package-exec-shim-notices.py"


def load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("package_exec_shim_notices", SCRIPT)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


shim_notices = load()
stage_ocaml = shim_notices.runtime_stage_ocaml()

INSTALLED_MUSL = "musl-dev-1.2.5-r23\n"
MUSL_COPYRIGHT = b"musl as a whole is licensed under the following standard MIT license\n"
YOJSON_LICENSE = b"Copyright (c) 2010-2012 Martin Jambon\n"
SHIMS = {"amd64": b"\x7fELF amd64 shim\n", "arm64": b"\x7fELF arm64 shim\n"}


def musl_release(copyright_bytes: bytes = MUSL_COPYRIGHT) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        info = tarfile.TarInfo("musl-1.2.5/COPYRIGHT")
        info.size = len(copyright_bytes)
        tar.addfile(info, io.BytesIO(copyright_bytes))
    return buffer.getvalue()


MUSL_RELEASE = musl_release()
PINS = {"1.2.5": hashlib.sha512(MUSL_RELEASE).hexdigest()}


def installed(output: str):
    def run(argv: Sequence[str]) -> str:
        assert list(argv) == ["apk", "info", "--installed", "-v", "musl-dev"], argv
        return output
    return run


def fetch_release(url: str) -> bytes:
    assert url == "https://musl.libc.org/releases/musl-1.2.5.tar.gz", url
    return MUSL_RELEASE


def never_fetch(url: str) -> bytes:
    raise AssertionError(f"fetched {url}")


def write_ocaml_notices(directory: Path, executables: Sequence[str] = ("bin/masc_exec_shim.exe",)) -> Path:
    (directory / "yojson").mkdir(parents=True)
    (directory / "yojson/LICENSE.md").write_bytes(YOJSON_LICENSE)
    manifest = {"schema": "masc.ocaml-notices.v1", "executables": list(executables), "packages": [
        {"name": "yojson", "version": "3.0.0", "source_hash": None, "excluded": [], "notices": [
            {"file": "yojson/LICENSE.md", "sha256": hashlib.sha256(YOJSON_LICENSE).hexdigest(),
             "found_in": ["source"]}]}]}
    (directory / "packages.json").write_text(json.dumps(manifest))
    return directory


def members_of(archive: Path) -> dict[str, bytes]:
    members = shim_notices.read_archive(archive)
    assert isinstance(members, dict), members
    return members


def rewrite(archive: Path, members: Mapping[str, bytes]) -> None:
    with tempfile.TemporaryDirectory() as scratch:
        for name, data in members.items():
            (Path(scratch) / name).parent.mkdir(parents=True, exist_ok=True)
            (Path(scratch) / name).write_bytes(data)
        archive.unlink()
        shim_notices.write_archive(Path(scratch), archive)


class ExecShimNotices(unittest.TestCase):
    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.dist = self.root / "dist"
        self.dist.mkdir()
        self.musl = shim_notices.musl_notice(installed(INSTALLED_MUSL), fetch_release, PINS)
        self.assertIsInstance(self.musl, shim_notices.MuslNotice)

    def package(self, arch: str, executables: Sequence[str] = ("bin/masc_exec_shim.exe",)):
        shim = self.dist / shim_notices.shim_asset(arch)
        shim.write_bytes(SHIMS[arch])
        ocaml = write_ocaml_notices(self.root / f"ocaml-{arch}", executables)
        return shim_notices.package(arch, shim, ocaml, self.dist / shim_notices.notices_asset(arch),
                                    self.musl, stage_ocaml)

    def package_both(self) -> None:
        for arch in shim_notices.ARCHES:
            self.assertEqual(1, self.package(arch))

    def assertRefused(self, result: object, *fragments: str) -> None:
        self.assertIsInstance(result, shim_notices.Refused)
        text = "\n".join(result.reasons)  # type: ignore[attr-defined]
        for fragment in fragments:
            self.assertIn(fragment, text)

    def test_the_release_check_accepts_what_package_wrote(self) -> None:
        self.package_both()
        self.assertEqual({"amd64": 1, "arm64": 1}, shim_notices.verify(self.dist, stage_ocaml))
        members = members_of(self.dist / "masc-exec-shim-licenses-linux-arm64.tar.gz")
        self.assertEqual({"exec-shim-provenance.json", "licenses/musl/COPYRIGHT",
                          "licenses/ocaml/packages.json", "licenses/ocaml/yojson/LICENSE.md"}, set(members))
        self.assertEqual(MUSL_COPYRIGHT, members["licenses/musl/COPYRIGHT"])
        provenance = json.loads(members["exec-shim-provenance.json"])
        self.assertEqual({"asset": "masc-exec-shim-linux-arm64",
                          "sha256": hashlib.sha256(SHIMS["arm64"]).hexdigest()}, provenance["shim"])
        self.assertEqual("musl-dev-1.2.5-r23", provenance["musl"]["package"])

    def test_a_musl_version_without_a_pinned_source_stops_before_any_download(self) -> None:
        self.assertRefused(shim_notices.musl_notice(installed("musl-dev-1.2.6-r0\n"), never_fetch, PINS),
                           "musl-dev-1.2.6-r0", "MUSL_SOURCES pins no musl 1.2.6")

    def test_a_musl_source_that_differs_from_its_pin_is_refused(self) -> None:
        other = {"1.2.5": hashlib.sha512(b"another tarball").hexdigest()}
        self.assertRefused(shim_notices.musl_notice(installed(INSTALLED_MUSL), fetch_release, other),
                           "musl-1.2.5.tar.gz has sha512")

    def test_notices_collected_for_another_executable_are_not_packaged(self) -> None:
        self.assertRefused(self.package("amd64", ("bin/main_eio.exe",)), "bin/masc_exec_shim.exe")
        self.assertFalse((self.dist / "masc-exec-shim-licenses-linux-amd64.tar.gz").exists())

    def test_a_missing_archive_stops_the_release(self) -> None:
        self.assertEqual(1, self.package("amd64"))
        (self.dist / "masc-exec-shim-linux-arm64").write_bytes(SHIMS["arm64"])
        self.assertRefused(shim_notices.verify(self.dist, stage_ocaml),
                           "masc-exec-shim-licenses-linux-arm64.tar.gz is missing")

    def test_a_listed_notice_missing_from_the_archive_stops_the_release(self) -> None:
        self.package_both()
        archive = self.dist / "masc-exec-shim-licenses-linux-amd64.tar.gz"
        members = members_of(archive)
        del members["licenses/ocaml/yojson/LICENSE.md"]
        rewrite(archive, members)
        self.assertRefused(shim_notices.verify(self.dist, stage_ocaml), "yojson/LICENSE.md")

    def test_a_missing_musl_notice_stops_the_release(self) -> None:
        self.package_both()
        archive = self.dist / "masc-exec-shim-licenses-linux-arm64.tar.gz"
        members = members_of(archive)
        del members["licenses/musl/COPYRIGHT"]
        rewrite(archive, members)
        self.assertRefused(shim_notices.verify(self.dist, stage_ocaml), "licenses/musl/COPYRIGHT is missing")

    def test_a_member_nothing_lists_stops_the_release(self) -> None:
        self.package_both()
        archive = self.dist / "masc-exec-shim-licenses-linux-arm64.tar.gz"
        members = members_of(archive)
        members["licenses/ocaml/uuidm/LICENSE.md"] = b"ISC\n"
        members["README"] = b"extra\n"
        rewrite(archive, members)
        self.assertRefused(shim_notices.verify(self.dist, stage_ocaml), "uuidm/LICENSE.md",
                           "README is neither a notice nor the provenance")

    def test_notices_of_another_shim_stop_the_release(self) -> None:
        self.package_both()
        (self.dist / "masc-exec-shim-linux-amd64").write_bytes(SHIMS["arm64"])
        self.assertRefused(shim_notices.verify(self.dist, stage_ocaml),
                           "the notices are for masc-exec-shim-linux-amd64 with sha256")


if __name__ == "__main__":
    unittest.main()
