"""Which prebuilt binaries go into a task container.

Terminal-Bench 4.0.0 on the Harbor hub pins a prebuilt image per task
(`[environment] docker_image`), published for amd64 only (65 of 66 checked in
the registry on 2026-09-17; one lookup timed out): on Apple Silicon they run
emulated. A task without `docker_image` is built from its Dockerfile with no
platform set and takes the Docker daemon's architecture instead. The
architecture is therefore a property of each container, read from it at
install time rather than taken from the host or a fetch setting.

image/fetch_masc.sh places both release architectures under dist/linux-x64 and
dist/linux-arm64.
"""
from __future__ import annotations

import hashlib
import json
import re
import shutil
from collections.abc import Awaitable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any, Protocol

if TYPE_CHECKING:
    from harbor.environments.base import BaseEnvironment


class RootExecutor(Protocol):
    def exec_as_root(
        self,
        environment: BaseEnvironment,
        command: str,
        env: dict[str, str] | None = None,
        cwd: str | None = None,
        timeout_sec: int | None = None,
    ) -> Awaitable[Any]: ...

# `uname -m` inside the container -> the dist/ directory fetch_masc.sh fills.
# MASC releases Linux binaries for these two only.
DIST_DIR_BY_MACHINE = {
    "x86_64": "linux-x64",
    "aarch64": "linux-arm64",
}
PLATFORM_BY_MACHINE = {
    "x86_64": "linux/amd64",
    "aarch64": "linux/arm64",
}

# Harbor's docker environment returns stderr inside stdout, so anything the
# container's shell prints first (a setlocale warning from an image that sets
# LC_ALL to a locale it never generated) arrives before `uname -m`. The value is
# printed on a line of its own and read from that line only.
UNAME_MARK = "MASC_UNAME_M="
UNAME_COMMAND = f"printf '{UNAME_MARK}%s\\n' \"$(uname -m)\""

REQUIRED_BINARIES = ("masc", "masc-exec-shim")
# gh is needed only when the keeper is given a GitHub login: the remote_ssh
# preflight runs `gh auth status` when the endpoint has a hosts.yml, and
# gh_seed.sh writes one only from GH_TOKEN.
GH_BINARY = "gh"
KNOWN_BINARIES = (*REQUIRED_BINARIES, GH_BINARY)
MANIFEST_SCHEMA = "masc.terminal-bench-dist.v1"
MANIFEST_FILE = "manifest.json"
COMMIT = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")

# The oldest release the bootstrap works with, which image/fetch_masc.sh reads
# too. A shim before it refuses the bootstrap's env_file= per command only: its
# --probe reads no config, so the install and keeper_up would pass and every
# keeper command would fail, scoring the task instead of refusing the run.
MIN_VERSION_FILE = Path(__file__).resolve().parents[1] / "image" / "min_masc_version"
RELEASE = re.compile(r"(\d+)\.(\d+)\.(\d+)")


@dataclass(frozen=True)
class DistIdentity:
    release_version: str
    source_commit: str
    machine: str
    binary_sha256: str


@dataclass(frozen=True)
class ContainerDistribution:
    binaries: list[Path]
    identity: DistIdentity


def identity_metadata(identity: DistIdentity | None) -> dict:
    if identity is None:
        return {}
    return {"masc_dist": {
        "release_version": identity.release_version,
        "source_commit": identity.source_commit,
        "machine": identity.machine,
        "binary_sha256": identity.binary_sha256,
    }}


def release_version(text: str) -> tuple[int, int, int] | None:
    """X.Y.Z as numbers; None for anything else, a pre-release included."""
    match = RELEASE.fullmatch(text.strip())
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def _exact_fields(value: dict, expected: set[str], context: str) -> None:
    actual = set(value)
    if actual != expected:
        raise RuntimeError(
            f"{context} fields differ: missing={sorted(expected - actual)}, "
            f"unknown={sorted(actual - expected)}; run image/fetch_masc.sh again")


def _nonblank_string(value: object, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise RuntimeError(
            f"{context} must be a non-blank string; run image/fetch_masc.sh again")
    return value


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _dist_manifest(bench_root: Path) -> dict:
    manifest_path = bench_root / "dist" / MANIFEST_FILE
    try:
        manifest = json.loads(manifest_path.read_text())
    except FileNotFoundError as exc:
        raise RuntimeError(
            f"{manifest_path} is missing; run image/fetch_masc.sh first") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(
            f"{manifest_path} is unreadable: {exc}; run image/fetch_masc.sh again") from exc
    if not isinstance(manifest, dict):
        raise RuntimeError(
            f"{manifest_path} must contain an object; run image/fetch_masc.sh again")
    _exact_fields(manifest,
                  {"schema", "release_version", "source_commit", "architectures"},
                  "dist manifest")
    if manifest["schema"] != MANIFEST_SCHEMA:
        raise RuntimeError(
            f"dist manifest schema is {manifest['schema']!r}, expected {MANIFEST_SCHEMA!r}; "
            "run image/fetch_masc.sh again")
    source_commit = _nonblank_string(manifest["source_commit"], "source_commit")
    if COMMIT.fullmatch(source_commit) is None:
        raise RuntimeError(
            "dist manifest source_commit is not a lowercase 40-digit commit; "
            "run image/fetch_masc.sh again")
    architectures = manifest["architectures"]
    if not isinstance(architectures, dict) or not architectures:
        raise RuntimeError(
            "dist manifest has no verified architectures; run image/fetch_masc.sh again")
    unknown = set(architectures) - set(DIST_DIR_BY_MACHINE.values())
    if unknown:
        raise RuntimeError(
            f"dist manifest has unknown architectures {sorted(unknown)}; "
            "run image/fetch_masc.sh again")
    return manifest


def require_fetched_release(bench_root: Path) -> dict:
    """Return the committed manifest after enforcing the bootstrap floor."""
    floor_text = MIN_VERSION_FILE.read_text().strip()
    floor = release_version(floor_text)
    if floor is None:
        raise RuntimeError(f"{MIN_VERSION_FILE} holds {floor_text!r}, not an X.Y.Z release")
    manifest = _dist_manifest(bench_root)
    fetched_text = _nonblank_string(manifest["release_version"], "release_version")
    fetched = release_version(fetched_text)
    if fetched is None:
        raise RuntimeError(
            f"dist manifest release_version holds {fetched_text!r}, not an X.Y.Z release; "
            "run image/fetch_masc.sh again")
    if fetched < floor:
        raise RuntimeError(
            f"dist/ holds masc {fetched_text}, older than {floor_text}, the first release "
            "the default arm can run (see image/fetch_masc.sh); run image/fetch_masc.sh again")
    return manifest


def refuse_a_named_agent_user(environment: BaseEnvironment) -> None:
    """Refuse a task that names the account its agent runs as.

    harbor runs an agent's commands as the task's `[agent] user` when it names
    one (environment.default_user during setup) and as the image's USER
    otherwise. The bench runs keeper commands as PID 1's user
    (driver/endpoint_account.sh), which is the image's USER, so a named account
    would differ without a word. No 4.0.0 task names one.
    """
    if environment.default_user is not None:
        raise RuntimeError(
            f"the task runs its agent as {environment.default_user!r}; the bench runs "
            "keeper commands as the image's user (driver/endpoint_account.sh) and does "
            "not follow a named one")


async def container_distribution(
    agent: RootExecutor,
    environment: BaseEnvironment,
    bench_root: Path,
    snapshot_dir: Path,
    *,
    with_gh: bool,
) -> ContainerDistribution:
    """Validated binaries and immutable identity for one container architecture."""
    manifest = require_fetched_release(bench_root)
    refuse_a_named_agent_user(environment)
    result = await agent.exec_as_root(environment, UNAME_COMMAND)
    output = result.stdout or ""
    marked = [line[len(UNAME_MARK):].strip() for line in output.splitlines()
              if line.startswith(UNAME_MARK)]
    if len(marked) != 1:
        raise RuntimeError(
            f"could not read the task container architecture from {output!r}")
    machine = marked[0]
    dist_dir_name = DIST_DIR_BY_MACHINE.get(machine)
    if dist_dir_name is None:
        raise RuntimeError(
            f"task container architecture {machine!r} has no MASC release "
            f"binary; releases cover {sorted(DIST_DIR_BY_MACHINE)}"
        )
    architectures = manifest["architectures"]
    architecture = architectures.get(dist_dir_name)
    if not isinstance(architecture, dict):
        raise RuntimeError(
            f"dist manifest has no verified {dist_dir_name} release; "
            "run image/fetch_masc.sh on this Docker host first")
    _exact_fields(architecture, {"machine", "platform", "binaries"}, dist_dir_name)
    if architecture["machine"] != machine:
        raise RuntimeError(
            f"dist manifest {dist_dir_name}.machine does not match {machine!r}; "
            "run image/fetch_masc.sh again")
    if architecture["platform"] != PLATFORM_BY_MACHINE[machine]:
        raise RuntimeError(
            f"dist manifest {dist_dir_name}.platform does not match "
            f"{PLATFORM_BY_MACHINE[machine]!r}; run image/fetch_masc.sh again")
    binaries_manifest = architecture["binaries"]
    if not isinstance(binaries_manifest, dict):
        raise RuntimeError(
            f"dist manifest {dist_dir_name}.binaries must be an object; "
            "run image/fetch_masc.sh again")
    names = [*REQUIRED_BINARIES]
    if with_gh:
        names.append(GH_BINARY)
    unknown = set(binaries_manifest) - set(KNOWN_BINARIES)
    if unknown:
        raise RuntimeError(
            f"dist manifest {dist_dir_name}.binaries has unknown names {sorted(unknown)}; "
            "run image/fetch_masc.sh again")
    dist_dir = bench_root / "dist" / dist_dir_name
    snapshot_dir.mkdir(parents=True, exist_ok=True)
    binaries = []
    hashes: dict[str, str] = {}
    for name in names:
        expected = binaries_manifest.get(name)
        if not isinstance(expected, str) or SHA256.fullmatch(expected) is None:
            raise RuntimeError(
                f"dist manifest has no valid {dist_dir_name}/{name} sha256; "
                "run image/fetch_masc.sh again")
        binary = dist_dir / name
        if not binary.is_file():
            raise RuntimeError(
                f"{machine} task container needs {binary}; run image/fetch_masc.sh first")
        snapshot = snapshot_dir / name
        shutil.copy2(binary, snapshot)
        actual = _sha256(snapshot)
        if actual != expected:
            raise RuntimeError(
                f"{binary} snapshot sha256 does not match the committed dist manifest; "
                "run image/fetch_masc.sh again")
        binaries.append(snapshot)
        hashes[name] = actual
    return ContainerDistribution(
        binaries=binaries,
        identity=DistIdentity(
            release_version=manifest["release_version"],
            source_commit=manifest["source_commit"],
            machine=machine,
            binary_sha256=hashes["masc"],
        ),
    )
