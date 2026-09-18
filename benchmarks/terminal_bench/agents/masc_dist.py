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

import re
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from harbor.agents.installed.base import BaseInstalledAgent
    from harbor.environments.base import BaseEnvironment

# `uname -m` inside the container -> the dist/ directory fetch_masc.sh fills.
# MASC releases Linux binaries for these two only.
DIST_DIR_BY_MACHINE = {
    "x86_64": "linux-x64",
    "aarch64": "linux-arm64",
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

# The oldest release the bootstrap works with, which image/fetch_masc.sh reads
# too. A shim before it refuses the bootstrap's env_file= per command only: its
# --probe reads no config, so the install and keeper_up would pass and every
# keeper command would fail, scoring the task instead of refusing the run.
MIN_VERSION_FILE = Path(__file__).resolve().parents[1] / "image" / "min_masc_version"
RELEASE = re.compile(r"(\d+)\.(\d+)\.(\d+)")


def release_version(text: str) -> tuple[int, int, int] | None:
    """X.Y.Z as numbers; None for anything else, a pre-release included."""
    match = RELEASE.fullmatch(text.strip())
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def require_fetched_release(bench_root: Path) -> None:
    """Refuse dist/ when it holds a release older than the floor."""
    floor_text = MIN_VERSION_FILE.read_text().strip()
    floor = release_version(floor_text)
    if floor is None:
        raise RuntimeError(f"{MIN_VERSION_FILE} holds {floor_text!r}, not an X.Y.Z release")
    version_file = bench_root / "dist" / ".version"
    if not version_file.exists():
        raise RuntimeError(f"{version_file} is missing; run image/fetch_masc.sh first")
    fetched_text = version_file.read_text().strip()
    fetched = release_version(fetched_text)
    if fetched is None:
        raise RuntimeError(
            f"dist/.version holds {fetched_text!r}, not an X.Y.Z release; "
            "run image/fetch_masc.sh again")
    if fetched < floor:
        raise RuntimeError(
            f"dist/ holds masc {fetched_text}, older than {floor_text}, the first release "
            "whose shim reads the env_file= the bootstrap writes; run image/fetch_masc.sh again")


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


async def container_binaries(
    agent: BaseInstalledAgent,
    environment: BaseEnvironment,
    bench_root: Path,
    *,
    with_gh: bool,
) -> list[Path]:
    """The binaries to upload for this container's architecture."""
    require_fetched_release(bench_root)
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
    dist_dir = bench_root / "dist" / dist_dir_name
    binaries = [dist_dir / name for name in REQUIRED_BINARIES]
    if with_gh:
        binaries.append(dist_dir / GH_BINARY)
    missing = [str(binary) for binary in binaries if not binary.exists()]
    if missing:
        raise RuntimeError(
            f"{machine} task container needs {', '.join(missing)}; "
            "run image/fetch_masc.sh first"
        )
    return binaries
