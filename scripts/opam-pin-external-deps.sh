#!/usr/bin/env bash
# Pin private/external opam dependencies that are not published on opam-repository.
#
# All first-party packages are pinned to specific commit SHAs so that the
# opam cache in CI stays stable across runs. When upstream changes are needed,
# update the readonly SHA below.
#
# To bump a pin:
#   git ls-remote https://github.com/jeong-sik/<repo>.git HEAD
#   # update the readonly SHA below, commit, push
#
# ──────────────────────────────────────────────────────────────────────────
# pin vs install trap (2026-04-11 post-mortem)
#
# Every `opam pin add` here uses `-n -y`: `-y` answers yes automatically,
# `-n` means "do NOT install/rebuild the pinned package". Those flags are
# correct for CI, which runs a clean `opam install` pass after pinning so
# the cache stays deterministic. But for LOCAL development they are a
# footgun: after bumping a SHA and re-running this script you will see
# "pinned successfully" and conclude the new code is live, when in fact
# the installed binary is still the OLD commit.
#
# Pass `--install` to run `opam install --yes <pinned packages>` at the
# tail of this script so the binary actually matches the pin. The full
# install takes several minutes, which is why it is opt-in.
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --check reads the pin table and writes nothing, so it takes a read lease.
# A write lease waits behind every reader, which turned the check into a 5s
# refusal whenever anything else held the switch -- including the read lease
# dune-local.sh is already holding when it calls this.
lease_mode=write
lease_flag=MASC_OPAM_WRITE_LEASE_HELD
for arg in "$@"; do
  if [[ "${arg}" == "--check" ]]; then
    lease_mode=read
    lease_flag=MASC_OPAM_READ_LEASE_HELD
  fi
done

lease_already_held() {
  [[ "${MASC_OPAM_WRITE_LEASE_HELD:-0}" == "1" ]] && return 0
  # A write lease covers a read; the reverse does not hold.
  [[ "${lease_mode}" == "read" && "${MASC_OPAM_READ_LEASE_HELD:-0}" == "1" ]]
}

if ! lease_already_held; then
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  exec "${SCRIPT_DIR}/opam-switch-rw-lock.sh" \
    "${lease_mode}" -- "${ENV_CMD:-/usr/bin/env}" "${lease_flag}=1" \
    "${script_path}" "$@"
fi

# Refuse to mutate a different or unsupported switch.  This script is the
# documented repair path for external dependency pin drift, so it must not silently
# repair the switch named by opam while the caller's shell still executes
# tools from another prefix.
required_ocaml_version="$(sed -nE '/^[[:space:]]*\(ocaml[[:space:]]+\(=[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+)\)\).*$/ { s//\1/; p; q; }' \
  "${REPO_ROOT}/dune-project")"
if [[ -z "${required_ocaml_version}" ]]; then
  echo "[opam-pin] ERROR: unable to read exact OCaml version from ${REPO_ROOT}/dune-project" >&2
  exit 1
fi
if ! command -v opam >/dev/null 2>&1; then
  echo "[opam-pin] ERROR: opam is unavailable; MASC requires OCaml ${required_ocaml_version}" >&2
  exit 1
fi
active_opam_switch="$(opam switch show 2>/dev/null || true)"
active_opam_prefix="$(opam var prefix 2>/dev/null || true)"
active_ocaml_version="$(opam exec -- ocamlc -version 2>/dev/null || true)"
if [[ -z "${active_opam_switch}" || -z "${active_opam_prefix}" ]]; then
  echo "[opam-pin] ERROR: unable to resolve the active opam switch and prefix" >&2
  exit 1
fi
if [[ -n "${OPAM_SWITCH_PREFIX:-}" \
      && "${OPAM_SWITCH_PREFIX%/}" != "${active_opam_prefix%/}" ]]; then
  echo "[opam-pin] ERROR: split opam environment: switch ${active_opam_switch} uses ${active_opam_prefix} but OPAM_SWITCH_PREFIX=${OPAM_SWITCH_PREFIX}" >&2
  echo "[opam-pin] repair: eval \"\$(opam env --switch=${required_ocaml_version} --set-switch)\"" >&2
  exit 1
fi
if [[ "${active_ocaml_version}" != "${required_ocaml_version}" ]]; then
  echo "[opam-pin] ERROR: OCaml ${active_ocaml_version:-unknown} detected; MASC requires exactly ${required_ocaml_version}" >&2
  echo "[opam-pin] repair: eval \"\$(opam env --switch=${required_ocaml_version} --set-switch)\"" >&2
  exit 1
fi

# --- Pin SHAs (bump these when upstream changes are needed) ---
readonly GRPC_DIRECT_SHA="d7269ebebf9e4688486cc6591c66e794607e7b0f"
readonly WS_DIRECT_SHA="05e01cf008d4a5024474d13cee35cda42e2bea09"
# MSX emulator core (Z80 + V9938 + MSX2 machine). Path-pinned locally for
# core development; SHA-pinned here for CI.
readonly OCAML_MSX_SHA="8e641bf1cb4ccbfe3718b7e4320180bcbf5b2546"
# cohttp-eio 6.2.1 + one line: Reader_flow.single_read continues a partial body
# delivery from the position already delivered instead of offset 0. Without it
# a chunk handed over in three or more single_read calls repeats its first
# bytes and drops the displaced ones, which is the sse/malformed_payload the
# providers were blamed for (masc#28761). Pinned as version 6.2.1 so the lock
# file constraint still holds. Verified by test_cohttp_eio_body_flow. Remove
# the pin when a cohttp-eio release carries the fix (upstream PR from this fork).
readonly COHTTP_EIO_SHA="45ecbe94b2a6e9a49e5ce11a9f69127833814d46"

include_bisect=false
include_compact_protocol=false
do_install=false
do_check=false
for arg in "$@"; do
  case "$arg" in
    --with-bisect)
      include_bisect=true
      ;;
    --with-compact-protocol)
      include_compact_protocol=true
      ;;
    --install)
      do_install=true
      ;;
    --check)
      do_check=true
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done


# Accumulate the package names we pin so a follow-up `opam install` in
# --install mode can rebuild exactly the set that changed, nothing more.
pinned_pkgs=()

# --check reports which of the pins below the active switch is missing or
# holding at a different target, and pins nothing. It exists because a pin
# added here reaches a developer's switch only when they re-run this script,
# and nothing told them to: cohttp-eio was pinned on 2026-09-05 (#33206) to
# stop a body-flow bug that silently corrupts SSE payloads, and two days
# later the switch this was written on still had the stock build. The check
# reads one `opam pin list`, so adding a pin above is enough to cover it.
pin_drift=()
# A pin the developer aimed at a checkout on this machine. Kept apart from
# drift because it is the opposite situation: drift means the switch quietly
# holds a build nobody chose, while a path pin is a deliberate act -- someone
# is editing that dependency. Failing on it was worse than useless, because
# the only repair this script offers (--install) replaces the path pin with
# the git one and throws the working copy out of the build.
pin_local=()
# One "name<TAB>target" line per live pin. A table rather than an associative
# array: macOS ships bash 3.2, where `declare -A` does not exist.
live_pin_table=""

load_live_pins() {
  # `opam pin list` prints `name.version  kind  target  (at sha)`, and writes
  # the target with a `git+` prefix that `opam pin add` does not take.
  live_pin_table="$(opam pin list 2>/dev/null | awk '
    { name = $1; sub(/\..*/, "", name)
      target = $3; sub(/^git\+/, "", target)
      print name "\t" target }')"
}

live_pin_target() {
  printf '%s\n' "${live_pin_table}" | awk -F'\t' -v want="$1" '$1 == want { print $2; exit }'
}

# A target naming a place on this machine rather than a repository to fetch.
# `opam pin list` writes these as `file:///path` for a path or rsync pin.
is_local_pin_target() {
  case "$1" in
    file://* | /*) return 0 ;;
    *) return 1 ;;
  esac
}

check_pin() {
  local package="${1%%.*}"
  local want="$2"
  local have
  have="$(live_pin_target "${package}")"

  if [[ -z "${have}" ]]; then
    pin_drift+=("${package}: not pinned; expected ${want}")
  elif [[ "${have}" == "${want}" ]]; then
    :
  elif is_local_pin_target "${have}"; then
    pin_local+=("${package}: your checkout at ${have}; this repo names ${want}")
  else
    pin_drift+=("${package}: pinned to ${have}; expected ${want}")
  fi
}

opam_pin_add() {
  local package="$1"
  local source="$2"
  shift 2

  if $do_check; then
    check_pin "${package}" "${source}"
    return 0
  fi

  # A path pin is somebody's working copy, and re-pinning it to the named
  # commit throws that out of the build -- which is what the check used to
  # send people here to do, to fix an unrelated package. Left alone and said
  # out loud; OPAM_PIN_REPLACE_LOCAL=1 asks for the named commit back.
  local live
  live="$(live_pin_target "${package%%.*}")"
  if [[ -n "${live}" ]] \
     && [[ "${live}" != "${source#git+}" ]] \
     && is_local_pin_target "${live}" \
     && [[ "${OPAM_PIN_REPLACE_LOCAL:-0}" != "1" ]]; then
    echo "[opam-pin] keeping your checkout for ${package}: ${live}" >&2
    echo "[opam-pin]   this repo names ${source#git+}; OPAM_PIN_REPLACE_LOCAL=1 to switch back" >&2
    return 0
  fi

  local max_attempts="${OPAM_PIN_RETRIES:-4}"
  local retry_delay_sec="${OPAM_PIN_RETRY_DELAY_SEC:-5}"
  local attempt=1
  local status=0

  while true; do
    if opam pin add "${package}" "${source}" "$@"; then
      return 0
    fi

    status=$?
    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      echo "[opam-pin] ERROR: opam pin add failed after ${attempt} attempts: ${package} ${source}" >&2
      return "${status}"
    fi

    echo "[opam-pin] WARN: opam pin add failed for ${package} (attempt ${attempt}/${max_attempts}, exit=${status}); retrying in ${retry_delay_sec}s" >&2
    sleep "${retry_delay_sec}"
    attempt=$((attempt + 1))
  done
}

# Read for every mode. A pinning run needs it too, so it can tell a package
# nobody has touched from one already aimed at a checkout on this machine.
load_live_pins

if $include_compact_protocol; then
  opam_pin_add compact-protocol https://github.com/jeong-sik/compact-protocol.git#main -n -y
  pinned_pkgs+=("compact-protocol")
fi

# mcp_protocol_eio and mcp_protocol_http merged into mcp_protocol
# as sub-libraries (mcp-protocol-sdk#60). Pin the released single-package line.
opam_pin_add mcp_protocol https://github.com/jeong-sik/mcp-protocol-sdk.git#v1.3.0 -n -y
pinned_pkgs+=("mcp_protocol")
opam_pin_add grpc-direct-core "https://github.com/jeong-sik/grpc-direct.git#${GRPC_DIRECT_SHA}" -n -y
pinned_pkgs+=("grpc-direct-core")
opam_pin_add grpc-direct "https://github.com/jeong-sik/grpc-direct.git#${GRPC_DIRECT_SHA}" -n -y
pinned_pkgs+=("grpc-direct")
opam_pin_add ws-direct-core "https://github.com/jeong-sik/ws-direct.git#${WS_DIRECT_SHA}" -n -y
pinned_pkgs+=("ws-direct-core")
opam_pin_add ws-direct-gluten "https://github.com/jeong-sik/ws-direct.git#${WS_DIRECT_SHA}" -n -y
pinned_pkgs+=("ws-direct-gluten")
opam_pin_add ws-direct-eio "https://github.com/jeong-sik/ws-direct.git#${WS_DIRECT_SHA}" -n -y
pinned_pkgs+=("ws-direct-eio")
opam_pin_add ocaml-msx "https://github.com/jeong-sik/ocaml-msx.git#${OCAML_MSX_SHA}" -n -y
pinned_pkgs+=("ocaml-msx")
opam_pin_add cohttp-eio.6.2.1 "https://github.com/jeong-sik/ocaml-cohttp.git#${COHTTP_EIO_SHA}" -n -y
pinned_pkgs+=("cohttp-eio")

if $include_bisect; then
  # bisect_ppx opam constraints lag newer compilers; keep CI solvable under OCaml 5.5 by pinning.
  opam_pin_add bisect_ppx git+https://github.com/patricoferris/bisect_ppx.git#5.2 -n -y
  pinned_pkgs+=("bisect_ppx")
fi

if $do_check; then
  # Said whether or not anything failed, so a build off a working copy says so
  # once per run instead of looking like a build of the named commit.
  if [[ ${#pin_local[@]} -gt 0 ]]; then
    echo "[opam-pin] built from a checkout on this machine, not the named commit:" >&2
    printf '[opam-pin]   %s\n' "${pin_local[@]}" >&2
    echo "[opam-pin] whatever is in that directory right now is what links." >&2
    echo "[opam-pin] to go back to the named commit: bash scripts/opam-pin-external-deps.sh --install" >&2
  fi
  if [[ ${#pin_drift[@]} -eq 0 ]]; then
    echo "[opam-pin] all ${#pinned_pkgs[@]} pins are in place"
    exit 0
  fi
  echo "[opam-pin] the active switch does not carry these pins:" >&2
  printf '[opam-pin]   %s\n' "${pin_drift[@]}" >&2
  echo "[opam-pin] the installed build is not the one this repo expects" >&2
  echo "[opam-pin] repair: bash scripts/opam-pin-external-deps.sh --install" >&2
  exit 1
fi

if $do_install; then
  echo ""
  echo "[opam-pin] --install set; rebuilding ${#pinned_pkgs[@]} pinned packages..."
  opam install --yes "${pinned_pkgs[@]}"
  echo "[opam-pin] install complete. Installed binaries now match the pins above."
else
  echo ""
  echo "[opam-pin] Pins updated. NOTE: installed binaries are still the previous versions."
  echo "[opam-pin] Run the same command with --install to rebuild, or run manually:"
  printf '[opam-pin]   opam install --yes'
  printf ' %s' "${pinned_pkgs[@]}"
  printf '\n'
fi
