#!/usr/bin/env python3
"""Package and verify the license notices of the static exec shim (masc#39934).

masc-exec-shim-linux-<arch> is a static binary. It links the OCaml runtime,
the opam libraries of lib/exec_ssh_protocol and lib/exec_shim, and musl's
libc.a. Each release publishes their notices beside it as
masc-exec-shim-licenses-linux-<arch>.tar.gz:

  exec-shim-provenance.json  the shim asset and sha256 these notices belong to,
                             and where the musl notice came from
  licenses/ocaml/            scripts/collect-ocaml-notices.py output for
                             bin/masc_exec_shim.exe, laid out as the runtime
                             archive ships its own
  licenses/musl/COPYRIGHT    musl's notice

`package` runs inside the shim's builder container
(scripts/remote-ssh/build-shim.sh --notices), next to the opam switch and the
musl that linked the shim. No Alpine package installs musl's COPYRIGHT, so it
is read from the release tarball Alpine builds musl-dev from. MUSL_SOURCES
pins that tarball by the sha512 Alpine's APKBUILD records for each exact
upstream version; a musl it does not name stops the packaging.

`verify` runs in the release job on the assembled assets. A missing archive, a
notice that packages.json lists but the archive lacks, a member nothing lists,
or a shim whose sha256 differs from the one the archive names stops the release.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import TypeAlias, cast

SCHEMA = "masc.exec-shim-notices.v1"
ARCHES = ("amd64", "arm64")
SHIM_TARGET = "bin/masc_exec_shim.exe"
PROVENANCE = "exec-shim-provenance.json"
OCAML_DIR = "licenses/ocaml/"
OCAML_MANIFEST = "packages.json"
MUSL_NOTICE = "licenses/musl/COPYRIGHT"
# The static link reads libc.a, which this package installs.
MUSL_PACKAGE = "musl-dev"
INSTALLED_MUSL = re.compile(r"musl-dev-(?P<version>[0-9]+(?:\.[0-9]+)+)-r[0-9]+")
MUSL_RELEASE_URL = "https://musl.libc.org/releases/musl-{version}.tar.gz"
FETCH_TIMEOUT_S = 120
# scripts/collect-ocaml-notices.py ships only paths in this alphabet.
MEMBER_PATH = re.compile(r"[A-Za-z0-9_.+-]+(?:/[A-Za-z0-9_.+-]+)*")

# Read on 2026-11-27 from the sha512sums of aports 3.23-stable main/musl/APKBUILD,
# the recipe of the musl-dev in the builder's Alpine 3.23 base image
# (scripts/remote-ssh/Dockerfile.shim-builder).
MUSL_SOURCES: Mapping[str, str] = {
    "1.2.5": "7bb7f7833923cd69c7a1a9b8a5f1784bfd5289663eb6061dcd43d583e45987df"
             "8a68a1be05d75cc1c88a3f5b610653d1a70f4a9cff4d8f7fd41ae73ee058c17c",
}


@dataclass(frozen=True, slots=True)
class Refused:
    """Why packaging or verification stopped. Every reason found is kept."""

    reasons: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class MuslNotice:
    package: str
    source: str
    source_sha512: str
    data: bytes


Run: TypeAlias = Callable[[Sequence[str]], "str | Refused"]
Fetch: TypeAlias = Callable[[str], "bytes | Refused"]
# scripts/package-macos-runtime.py stage_ocaml_notices: copies the collector's
# directory to <stage>/licenses/ocaml, raising ValueError unless it holds
# exactly the files its packages.json names, with those sha256.
StageOcaml: TypeAlias = Callable[[Path, Path], None]


def shim_asset(arch: str) -> str:
    return f"masc-exec-shim-linux-{arch}"


def notices_asset(arch: str) -> str:
    return f"masc-exec-shim-licenses-linux-{arch}.tar.gz"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run_command(argv: Sequence[str]) -> str | Refused:
    completed = subprocess.run(list(argv), capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        return Refused((f"`{' '.join(argv)}` exited {completed.returncode}: {completed.stderr.strip()}",))
    return completed.stdout


def fetch_url(url: str) -> bytes | Refused:
    try:
        with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT_S) as response:
            return cast(bytes, response.read())
    except OSError as error:  # URLError and HTTPError are OSErrors
        return Refused((f"{url}: {error}",))


def runtime_stage_ocaml() -> StageOcaml:
    """The runtime packager's notice check, so both archives follow one rule."""
    path = Path(__file__).resolve().with_name("package-macos-runtime.py")
    spec = importlib.util.spec_from_file_location("portable_runtime", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return cast(StageOcaml, module.stage_ocaml_notices)


def staged_ocaml(stage_ocaml: StageOcaml, stage: Path, notices: Path) -> None | Refused:
    try:
        stage_ocaml(stage, notices)
    except ValueError as error:
        return Refused((str(error),))
    return None


def tar_member(archive: bytes, name: str) -> bytes | Refused:
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        try:
            member = tar.getmember(name)
        except KeyError:
            return Refused((f"the release tarball has no {name}",))
        source = tar.extractfile(member) if member.isfile() else None
        if source is None:
            return Refused((f"{name} in the release tarball is not a regular file",))
        return source.read()


def musl_notice(run: Run, fetch: Fetch, sources: Mapping[str, str]) -> MuslNotice | Refused:
    installed = run(["apk", "info", "--installed", "-v", MUSL_PACKAGE])
    if isinstance(installed, Refused):
        return installed
    package = installed.strip()
    match = INSTALLED_MUSL.fullmatch(package)
    if match is None:
        return Refused((f"apk names no single installed {MUSL_PACKAGE}: {package!r}",))
    version = match["version"]
    expected = sources.get(version)
    if expected is None:
        return Refused((f"{package} is linked, but MUSL_SOURCES pins no musl {version} release tarball; "
                        "add the sha512 that Alpine's APKBUILD for it records",))
    url = MUSL_RELEASE_URL.format(version=version)
    archive = fetch(url)
    if isinstance(archive, Refused):
        return archive
    actual = hashlib.sha512(archive).hexdigest()
    if actual != expected:
        return Refused((f"{url} has sha512 {actual}, but MUSL_SOURCES pins {expected}",))
    data = tar_member(archive, f"musl-{version}/COPYRIGHT")
    if isinstance(data, Refused):
        return data
    if not data.strip():
        return Refused((f"musl-{version}/COPYRIGHT in {url} is empty",))
    return MuslNotice(package, url, expected, data)


def write_archive(stage: Path, output: Path) -> None:
    """A tar.gz of every file below `stage`, sorted, with no time or owner in it."""
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as tar:
            for path in sorted(p for p in stage.rglob("*") if p.is_file()):
                data = path.read_bytes()
                info = tarfile.TarInfo(path.relative_to(stage).as_posix())
                info.size, info.mode, info.mtime = len(data), 0o644, 0
                tar.addfile(info, io.BytesIO(data))
    output.write_bytes(buffer.getvalue())


def read_archive(path: Path) -> dict[str, bytes] | Refused:
    if not path.is_file():
        return Refused((f"{path.name} is missing",))
    members: dict[str, bytes] = {}
    try:
        with tarfile.open(path, "r:gz") as tar:
            for member in tar.getmembers():
                name = member.name
                parts = PurePosixPath(name).parts
                source = tar.extractfile(member) if member.isfile() else None
                if source is None or MEMBER_PATH.fullmatch(name) is None or {".", ".."} & set(parts):
                    return Refused((f"{path.name}: {name!r} is not a plain file with a shippable path",))
                if name in members:
                    return Refused((f"{path.name}: {name} appears twice",))
                members[name] = source.read()
    except (tarfile.TarError, EOFError, OSError) as error:  # gzip.BadGzipFile is an OSError
        return Refused((f"{path.name} is not a readable tar.gz: {error}",))
    return members


def check_archive(label: str, members: Mapping[str, bytes], arch: str, shim_sha256: str,
                  stage_ocaml: StageOcaml) -> int | Refused:
    """The number of OCaml notice files, when `members` are the notices of that shim."""
    reasons: list[str] = []
    musl = members.get(MUSL_NOTICE, b"")
    if not musl.strip():
        reasons.append(f"{label}: {MUSL_NOTICE} is missing or empty")
    try:
        provenance: object = json.loads(members.get(PROVENANCE, b"null"))
    except ValueError:
        provenance = None
    match provenance:
        case {"schema": str() as schema, "shim": {"asset": str() as asset, "sha256": str() as shim},
              "musl": {"sha256": str() as musl_sha256}}:
            if schema != SCHEMA:
                reasons.append(f"{label}: {PROVENANCE} has schema {schema!r}, not {SCHEMA!r}")
            if (asset, shim) != (shim_asset(arch), shim_sha256):
                reasons.append(f"{label}: the notices are for {asset} with sha256 {shim}, "
                               f"but {shim_asset(arch)} has sha256 {shim_sha256}")
            if musl and musl_sha256 != sha256(musl):
                reasons.append(f"{label}: {MUSL_NOTICE} differs from the sha256 {PROVENANCE} names")
        case _:
            reasons.append(f"{label}: {PROVENANCE} is missing or does not name the shim and the musl notice")
    ocaml = {name.removeprefix(OCAML_DIR): data for name, data in members.items() if name.startswith(OCAML_DIR)}
    reasons.extend(f"{label}: {name} is neither a notice nor the provenance" for name in sorted(members)
                   if name not in (PROVENANCE, MUSL_NOTICE) and not name.startswith(OCAML_DIR))
    try:
        manifest: object = json.loads(ocaml.get(OCAML_MANIFEST, b"null"))
    except ValueError:
        manifest = None
    match manifest:
        case {"executables": [str() as target], "packages": [_, *_]} if target == SHIM_TARGET:
            pass
        case _:
            reasons.append(f"{label}: {OCAML_DIR}{OCAML_MANIFEST} is missing or does not list the packages "
                           f"linked into {SHIM_TARGET}")
    with tempfile.TemporaryDirectory(prefix="masc-exec-shim-notices-") as scratch:
        notices = Path(scratch) / "ocaml"
        for name, data in ocaml.items():
            (notices / name).parent.mkdir(parents=True, exist_ok=True)
            (notices / name).write_bytes(data)
        notices.mkdir(exist_ok=True)
        staged = staged_ocaml(stage_ocaml, Path(scratch) / "stage", notices)
    if isinstance(staged, Refused):
        reasons.extend(f"{label}: {reason}" for reason in staged.reasons)
    return Refused(tuple(reasons)) if reasons else len(ocaml) - 1


def package(arch: str, shim: Path, ocaml_notices: Path, output: Path, musl: MuslNotice,
            stage_ocaml: StageOcaml) -> int | Refused:
    """Write `output` only when it passes the same check the release job runs."""
    if output.exists():
        return Refused((f"{output} already exists",))
    if shim.is_symlink() or not shim.is_file():
        return Refused((f"{shim} is not the built shim",))
    shim_sha256 = sha256(shim.read_bytes())
    with tempfile.TemporaryDirectory(prefix="masc-exec-shim-stage-") as scratch:
        stage = Path(scratch)
        staged = staged_ocaml(stage_ocaml, stage, ocaml_notices)
        if isinstance(staged, Refused):
            return staged
        (stage / MUSL_NOTICE).parent.mkdir(parents=True)
        (stage / MUSL_NOTICE).write_bytes(musl.data)
        provenance = {
            "schema": SCHEMA,
            "shim": {"asset": shim_asset(arch), "sha256": shim_sha256},
            "musl": {"package": musl.package, "source": musl.source, "source_sha512": musl.source_sha512,
                     "sha256": sha256(musl.data)},
        }
        (stage / PROVENANCE).write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
        write_archive(stage, output)
    members = read_archive(output)
    checked = members if isinstance(members, Refused) else check_archive(
        output.name, members, arch, shim_sha256, stage_ocaml)
    if isinstance(checked, Refused):
        output.unlink()
    return checked


def verify(dist: Path, stage_ocaml: StageOcaml) -> dict[str, int] | Refused:
    counts: dict[str, int] = {}
    reasons: list[str] = []
    for arch in ARCHES:
        shim = dist / shim_asset(arch)
        shim_sha256 = sha256(shim.read_bytes()) if shim.is_file() else None
        match shim_sha256, read_archive(dist / notices_asset(arch)):
            case None, Refused(more):
                reasons.extend((f"{shim.name} is missing", *more))
            case None, _:
                reasons.append(f"{shim.name} is missing")
            case _, Refused(more):
                reasons.extend(more)
            case str() as shim_digest, dict() as members:
                match check_archive(notices_asset(arch), members, arch, shim_digest, stage_ocaml):
                    case Refused(more):
                        reasons.extend(more)
                    case int() as count:
                        counts[arch] = count
    return Refused(tuple(reasons)) if reasons else counts


def refuse(result: Refused) -> int:
    for reason in result.reasons:
        print(f"package-exec-shim-notices: {reason}", file=sys.stderr)
    return 1


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    packing = commands.add_parser("package", help="write one architecture's notice archive (builder container)")
    packing.add_argument("--arch", choices=ARCHES, required=True)
    packing.add_argument("--shim", type=Path, required=True, help="the built masc-exec-shim-linux-<arch>")
    packing.add_argument("--ocaml-notices", type=Path, required=True,
                         help=f"scripts/collect-ocaml-notices.py output for {SHIM_TARGET}")
    packing.add_argument("--output", type=Path, required=True)
    checking = commands.add_parser("verify", help="check both architectures' archives against their shims")
    checking.add_argument("--dist", type=Path, required=True, help="directory holding the release assets")
    args = parser.parse_args(argv)
    if args.command == "verify":
        verified = verify(cast(Path, args.dist), runtime_stage_ocaml())
        if isinstance(verified, Refused):
            return refuse(verified)
        print("package-exec-shim-notices: " + ", ".join(
            f"{notices_asset(arch)} holds {count} OCaml notice files and musl's" for arch, count in verified.items()))
        return 0
    arch = cast(str, args.arch)
    musl = musl_notice(run_command, fetch_url, MUSL_SOURCES)
    if isinstance(musl, Refused):
        return refuse(musl)
    output = cast(Path, args.output)
    packed = package(arch, cast(Path, args.shim), cast(Path, args.ocaml_notices), output, musl,
                     runtime_stage_ocaml())
    if isinstance(packed, Refused):
        return refuse(packed)
    print(f"package-exec-shim-notices: {packed} OCaml notice files and {musl.package}'s COPYRIGHT -> {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
