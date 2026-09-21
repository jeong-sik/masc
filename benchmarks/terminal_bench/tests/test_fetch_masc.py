import hashlib
import json
import os
import shutil
import subprocess
import time
from pathlib import Path


SOURCE_COMMIT = "a" * 40


def executable(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body)
    path.chmod(0o755)


def fixture(tmp_path: Path) -> tuple[Path, dict[str, str]]:
    source_image = Path(__file__).resolve().parents[1] / "image"
    image = tmp_path / "image"
    image.mkdir()
    shutil.copy(source_image / "fetch_masc.sh", image / "fetch_masc.sh")
    shutil.copy(source_image / "min_masc_version", image / "min_masc_version")

    commands = tmp_path / "commands"
    commands.mkdir()
    real_timeout = shutil.which("timeout")
    assert real_timeout is not None
    executable(
        commands / "gh",
        f'''
if [[ "$1" == "api" ]]; then
  printf '%s\\n' "{SOURCE_COMMIT}"
  exit 0
fi
if [[ "$1 $2" != "release download" ]]; then exit 2; fi
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-O" ]]; then shift; out="$1"; fi
  shift
done
mkdir -p "$(dirname "$out")"
printf 'fixture:%s\\n' "$(basename "$out")" > "$out"
chmod +x "$out"
''',
    )
    executable(commands / "curl", "exit 0\n")
    executable(
        commands / "tar",
        """
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-C" ]]; then shift; out="$1"; fi
  shift
done
cat >/dev/null
printf 'fixture:gh\\n' > "$out/gh"
chmod +x "$out/gh"
""",
    )
    executable(
        commands / "timeout",
        f'''[[ "$1" == "--kill-after=1" ]] || exit 3
exec "{real_timeout}" "$@"
''',
    )
    executable(
        commands / "docker",
        f"""
if [[ "$1" == "info" ]]; then
  if [[ "${{FAKE_TIMEOUT_DOCKER_INFO:-0}}" == "1" ]]; then
    trap '' TERM
    while true; do :; done
  fi
  echo fixture-docker
  exit 0
fi
[[ "$1" == "run" ]] || exit 2
platform=""
last=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--platform" ]]; then shift; platform="$1"; fi
  last="$1"
  shift
done
if [[ "$last" == "true" ]]; then
  [[ "${{FAKE_UNSUPPORTED_PLATFORM:-}}" == "$platform" ]] && exit 126
  exit 0
fi
if [[ "$last" == "--version" ]]; then
  echo 'masc fixture'
  exit 0
fi
if [[ "$last" == "build-commit" ]]; then
  printf '%s\\n' "${{FAKE_BUILD_COMMIT:-{SOURCE_COMMIT}}}"
  exit 0
fi
exit 2
""",
    )
    env = {
        **os.environ,
        "PATH": f"{commands}:{os.environ['PATH']}",
        "MASC_VERSION": (image / "min_masc_version").read_text().strip(),
        "PROBE_TIMEOUT_SEC": "1",
    }
    return image, env


def run_fetch(image: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(image / "fetch_masc.sh")],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_fetch_commits_only_verified_architectures_with_exact_hashes(tmp_path):
    image, env = fixture(tmp_path)
    env["FAKE_UNSUPPORTED_PLATFORM"] = "linux/arm64"
    result = run_fetch(image, env)
    assert result.returncode == 0, result.stderr
    assert "cannot run linux/arm64" in result.stdout

    dist = tmp_path / "dist"
    manifest = json.loads((dist / "manifest.json").read_text())
    assert manifest["source_commit"] == SOURCE_COMMIT
    assert set(manifest["architectures"]) == {"linux-x64"}
    binaries = manifest["architectures"]["linux-x64"]["binaries"]
    for name, digest in binaries.items():
        assert (
            digest
            == hashlib.sha256((dist / "linux-x64" / name).read_bytes()).hexdigest()
        )


def test_docker_timeout_does_not_publish_a_manifest(tmp_path):
    image, env = fixture(tmp_path)
    env["FAKE_TIMEOUT_DOCKER_INFO"] = "1"
    started = time.monotonic()
    result = run_fetch(image, env)
    elapsed = time.monotonic() - started
    assert result.returncode != 0
    assert "timed out" in result.stderr
    assert elapsed < 4
    assert not (tmp_path / "dist" / "manifest.json").exists()


def test_build_commit_mismatch_does_not_publish_a_manifest(tmp_path):
    image, env = fixture(tmp_path)
    env["FAKE_BUILD_COMMIT"] = "b" * 40
    result = run_fetch(image, env)
    assert result.returncode != 0
    assert "embeds build commit" in result.stderr
    assert not (tmp_path / "dist" / "manifest.json").exists()
