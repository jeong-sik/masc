#!/usr/bin/env bash
# Download the prebuilt masc server binary for both Linux architectures and
# verify each runs in a container of that architecture. No local build
# (constitution).
#
# Terminal-Bench 4.0.0 task images are prebuilt for amd64, while a task built
# from its Dockerfile takes the Docker daemon's architecture. The agent picks
# dist/linux-x64 or dist/linux-arm64 per container by `uname -m`
# (agents/masc_dist.py), so both are fetched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/../dist"

# Resolved, not pinned. This repository prunes old releases — the previous
# pin (0.35.8) stopped existing and the script then failed with a bare
# "release not found". Pass MASC_VERSION to hold a specific one; the committed
# dist manifest records whichever was used, so a run stays attributable.
MASC_VERSION="${MASC_VERSION:-}"
if [[ -z "${MASC_VERSION}" ]]; then
  MASC_VERSION="$(gh release view -R jeong-sik/masc --json tagName --jq '.tagName' 2>/dev/null | sed 's/^v//')"
  if [[ -z "${MASC_VERSION}" ]]; then
    echo "could not resolve the latest masc release; pass MASC_VERSION=<x.y.z>" >&2
    exit 1
  fi
  echo "[fetch] latest release: v${MASC_VERSION}"
fi

# The bootstrap writes env_file= into the shim config, a key a shim before
# 0.35.20 refuses as unknown, and with it every request (masc#36919). The same
# release is the first whose shim looks an argv program up in path= (masc#36916).
# agents/masc_dist.py reads the same floor before it uploads dist/ to a task
# container, so binaries fetched before this floor are refused there too. Only
# X.Y.Z is compared: sort -V puts 0.35.20-rc1 after 0.35.20.
MIN_MASC_VERSION="$(<"${SCRIPT_DIR}/min_masc_version")"
if [[ ! "${MASC_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "MASC_VERSION ${MASC_VERSION} is not an X.Y.Z release" >&2
  exit 1
fi
if [[ "$(printf '%s\n%s\n' "${MIN_MASC_VERSION}" "${MASC_VERSION}" | sort -V | head -1)" != "${MIN_MASC_VERSION}" ]]; then
  echo "masc ${MASC_VERSION} is older than ${MIN_MASC_VERSION}, the first release whose shim reads the env_file= the bootstrap writes; use ${MIN_MASC_VERSION} or later" >&2
  exit 1
fi

# gh is uploaded only when the run passes GH_TOKEN, and is absent from debian
# stable, which many task base images use.
GH_VERSION="${GH_VERSION:-2.65.0}"
PROBE_TIMEOUT_SEC="${PROBE_TIMEOUT_SEC:-600}"
if [[ ! "${PROBE_TIMEOUT_SEC}" =~ ^[1-9][0-9]*$ ]]; then
  echo "PROBE_TIMEOUT_SEC must be a positive integer" >&2
  exit 1
fi
if ! command -v timeout >/dev/null 2>&1; then
  echo "timeout is required to bound Docker verification" >&2
  exit 1
fi

SOURCE_COMMIT="$(gh api "repos/jeong-sik/masc/commits/v${MASC_VERSION}" --jq .sha 2>/dev/null || true)"
if [[ ! "${SOURCE_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "could not resolve the source commit for masc v${MASC_VERSION}" >&2
  exit 1
fi

# <dist dir> <masc asset suffix> <shim and gh asset suffix> <docker platform> <uname -m>
ARCHES=(
  "linux-x64 x64 amd64 linux/amd64 x86_64"
  "linux-arm64 arm64 arm64 linux/arm64 aarch64"
)

STAGE_DIR="$(mktemp -d "${DIST_DIR}.stage.XXXXXX")"
trap 'rm -rf "${STAGE_DIR}"' EXIT
for row in "${ARCHES[@]}"; do
  read -r dir masc_arch pkg_arch _ _ <<<"${row}"
  out="${STAGE_DIR}/${dir}"
  mkdir -p "${out}"
  if ! gh release download "v${MASC_VERSION}" -R jeong-sik/masc \
       -p "masc-linux-${masc_arch}" -O "${out}/masc" --clobber; then
    echo "no masc-linux-${masc_arch} asset on v${MASC_VERSION}. Releases that exist:" >&2
    gh release list -R jeong-sik/masc --limit 5 >&2 || true
    exit 1
  fi
  # The remote_ssh exec lane invokes `masc-exec-shim` on the remote PATH; the
  # release ships it as a separate static binary.
  gh release download "v${MASC_VERSION}" -R jeong-sik/masc \
    -p "masc-exec-shim-linux-${pkg_arch}" -O "${out}/masc-exec-shim" --clobber
  curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${pkg_arch}.tar.gz" \
    | tar -xz -C "${out}" --strip-components=2 "gh_${GH_VERSION}_linux_${pkg_arch}/bin/gh"
  chmod +x "${out}/masc" "${out}/masc-exec-shim" "${out}/gh"
done

# Record what was downloaded. A release asset can be replaced or truncated,
# and nothing else here would notice.
if command -v shasum >/dev/null 2>&1; then sum=(shasum -a 256); else sum=(sha256sum); fi
( cd "${STAGE_DIR}" && "${sum[@]}" linux-*/masc linux-*/masc-exec-shim linux-*/gh > SHA256SUMS )

run_bounded() {
  set +e
  # TERM gives Docker one second to clean up; KILL makes the bound hold even
  # when the CLI or daemon path ignores cancellation.
  PROBE_OUTPUT="$(timeout --kill-after=1 "${PROBE_TIMEOUT_SEC}" "$@" 2>&1)"
  PROBE_STATUS=$?
  set -e
}

probe_timed_out() {
  [[ ${PROBE_STATUS} -eq 124 || ${PROBE_STATUS} -eq 137 ]]
}

run_bounded docker info --format '{{.ServerVersion}}'
if probe_timed_out; then
  echo "Docker daemon probe timed out after ${PROBE_TIMEOUT_SEC}s" >&2
  exit 1
elif [[ ${PROBE_STATUS} -ne 0 ]]; then
  echo "Docker daemon probe failed: ${PROBE_OUTPUT}" >&2
  exit 1
fi

# Verify by running it, and let that verdict stand. The old form was
#   bash -c 'masc --version || masc --help | head -5'
# whose inner shell inherits no errexit and ends in `head`, so it exits 0 for a
# truncated download, a wrong-arch asset, or a binary missing every library —
# while its comment claimed to verify the binary runs.
#
# A platform this Docker cannot run at all (no emulation for it) is named and
# skipped: no task container of that platform can run on this host either.
VERIFIED_ARCHES="${STAGE_DIR}/.verified-architectures"
: > "${VERIFIED_ARCHES}"
for row in "${ARCHES[@]}"; do
  read -r dir _ _ platform machine <<<"${row}"
  run_bounded docker run --rm --platform "${platform}" ubuntu:24.04 true
  if probe_timed_out; then
    echo "Docker platform probe for ${platform} timed out after ${PROBE_TIMEOUT_SEC}s" >&2
    exit 1
  elif [[ ${PROBE_STATUS} -eq 125 ]]; then
    echo "Docker platform probe for ${platform} failed: ${PROBE_OUTPUT}" >&2
    exit 1
  elif [[ ${PROBE_STATUS} -ne 0 ]]; then
    echo "[fetch] ${dir}: this Docker cannot run ${platform} containers; not verified here"
    continue
  fi
  echo "[fetch] verify ${dir} on ${platform}"
  run_bounded docker run --rm --platform "${platform}" \
    -v "${STAGE_DIR}/${dir}:/opt/dist:ro" \
    ubuntu:24.04 /opt/dist/masc --version
  if probe_timed_out; then
    echo "masc --version verification for ${platform} timed out after ${PROBE_TIMEOUT_SEC}s" >&2
    exit 1
  elif [[ ${PROBE_STATUS} -ne 0 ]]; then
    echo "masc --version verification for ${platform} failed: ${PROBE_OUTPUT}" >&2
    exit 1
  fi
  printf '%s\n' "${PROBE_OUTPUT}"
  run_bounded docker run --rm --platform "${platform}" \
    -v "${STAGE_DIR}/${dir}:/opt/dist:ro" \
    ubuntu:24.04 /opt/dist/masc build-commit
  if probe_timed_out; then
    echo "masc build-commit verification for ${platform} timed out after ${PROBE_TIMEOUT_SEC}s" >&2
    exit 1
  elif [[ ${PROBE_STATUS} -ne 0 ]]; then
    echo "masc build-commit verification for ${platform} failed: ${PROBE_OUTPUT}" >&2
    exit 1
  elif [[ "${PROBE_OUTPUT}" != "${SOURCE_COMMIT}" ]]; then
    echo "${dir} embeds build commit '${PROBE_OUTPUT}', expected ${SOURCE_COMMIT}" >&2
    exit 1
  fi
  printf '%s\t%s\t%s\n' "${dir}" "${machine}" "${platform}" >> "${VERIFIED_ARCHES}"
done

if [[ ! -s "${VERIFIED_ARCHES}" ]]; then
  echo "Docker cannot run either downloaded MASC release architecture" >&2
  exit 1
fi

python3 - "${MASC_VERSION}" "${SOURCE_COMMIT}" "${STAGE_DIR}" "${VERIFIED_ARCHES}" <<'PY'
import hashlib
import json
import pathlib
import sys

release, source_commit, stage_raw, verified_raw = sys.argv[1:]
stage = pathlib.Path(stage_raw)
architectures = {}
for line in pathlib.Path(verified_raw).read_text().splitlines():
    directory, machine, platform = line.split("\t")
    binaries = {}
    for name in ("masc", "masc-exec-shim", "gh"):
        binaries[name] = hashlib.sha256((stage / directory / name).read_bytes()).hexdigest()
    architectures[directory] = {
        "machine": machine,
        "platform": platform,
        "binaries": binaries,
    }
manifest = {
    "schema": "masc.terminal-bench-dist.v1",
    "release_version": release,
    "source_commit": source_commit,
    "architectures": architectures,
}
(stage / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

# The committed manifest is the admission marker and moves last. A failed
# download or verification leaves the previous committed set untouched; an
# interruption during publication makes its hashes disagree and admission
# fails closed.
mkdir -p "${DIST_DIR}"
for row in "${ARCHES[@]}"; do
  read -r dir _ _ _ _ <<<"${row}"
  rm -rf "${DIST_DIR:?}/${dir}"
  mv "${STAGE_DIR}/${dir}" "${DIST_DIR}/${dir}"
done
mv "${STAGE_DIR}/SHA256SUMS" "${DIST_DIR}/SHA256SUMS"
mv "${STAGE_DIR}/manifest.json" "${DIST_DIR}/manifest.json"
