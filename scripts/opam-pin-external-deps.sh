#!/usr/bin/env bash
# Pin private/external opam dependencies that are not published on opam-repository.
#
# All first-party packages are pinned to specific commit SHAs so that the
# opam cache in CI stays stable across runs. When upstream changes are needed,
# bump the SHA constants below and in oas-agent-sdk-pin.sh.
#
# To bump a pin:
#   git ls-remote https://github.com/jeong-sik/<repo>.git HEAD
#   # update the readonly SHA below, commit, push
#
# For local development against an unreleased checkout:
#   AGENT_SDK_PIN_URL=/path/to/local/oas opam-pin-external-deps.sh
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
# the installed binary is still the OLD commit. Symptoms include "my
# feat is staged in OAS but `masc-mcp` never sees it" and "the function
# exists in the pinned source tree but `dune build` links against an
# older copy".
#
# Pass `--install` to run `opam install --yes <pinned packages>` at the
# tail of this script so the binary actually matches the pin. The full
# install takes several minutes, which is why it is opt-in.
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/oas-agent-sdk-pin.sh"
opam_lock_path="${MASC_OPAM_LOCK_PATH:-/tmp/me-opam-switch.lock}"
agent_sdk_floor_path="${MASC_AGENT_SDK_FLOOR_PATH:-/tmp/me-agent-sdk-floor}"

if [[ "${MASC_OPAM_LOCK:-1}" != "0" \
      && "${MASC_SKIP_OPAM_LOCK:-0}" != "1" \
      && "${MASC_OPAM_LOCK_HELD:-0}" != "1" ]]; then
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  echo "[opam-pin] waiting for opam switch lock ${opam_lock_path}" >&2
  if command -v lockf >/dev/null 2>&1; then
    exec lockf -k "$opam_lock_path" env MASC_OPAM_LOCK_HELD=1 "$script_path" "$@"
  elif command -v flock >/dev/null 2>&1; then
    exec flock "$opam_lock_path" env MASC_OPAM_LOCK_HELD=1 "$script_path" "$@"
  else
    echo "[opam-pin] WARN: neither lockf nor flock found; mutating opam switch unlocked" >&2
  fi
fi

# --- Pin SHAs (bump these when upstream changes are needed) ---
readonly WEBRTC_SHA="1b7993605b293f45169369d488f970ba15132a9f"
readonly GRPC_DIRECT_SHA="840b6cd6fe822d3577aa26147e7dc71ca25abecc"
readonly NEO4J_BOLT_SHA="a1ca30c1247db5c58934e99306fe330419f7b21a"

include_bisect=false
include_compact_protocol=false
do_install=false
agent_sdk_pin_source="${AGENT_SDK_PIN_URL:-${OAS_AGENT_SDK_URL}#${OAS_AGENT_SDK_SHA}}"

normalize_version_triplet() {
  local value
  value="$(printf '%s' "$1" | sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g')"
  if [[ "${value}" =~ ([0-9]+(\.[0-9]+){0,2}) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Returns true when $1 > $2 for three-part semver-ish versions.
version_gt() {
  local lhs rhs
  lhs="$(normalize_version_triplet "$1")"
  rhs="$(normalize_version_triplet "$2")"
  [[ -n "${lhs}" && -n "${rhs}" ]] || return 1

  local IFS='.'
  # shellcheck disable=SC2206
  local a=(${lhs}) b=(${rhs})
  local i
  for i in 0 1 2; do
    local va=${a[$i]:-0} vb=${b[$i]:-0}
    if (( va > vb )); then return 0; fi
    if (( va < vb )); then return 1; fi
  done
  return 1
}

installed_agent_sdk_version() {
  command -v opam >/dev/null 2>&1 || return 1

  local installed_packages agent_sdk_row installed_version show_version
  if ! installed_packages="$(OPAMCOLOR=never opam list --installed --columns=name,version 2>&1)"; then
    echo "[opam-pin] ERROR: failed to inspect installed agent_sdk via opam list" >&2
    echo "[opam-pin] opam list output: ${installed_packages:-<empty>}" >&2
    return 2
  fi

  agent_sdk_row="$(awk '$1 == "agent_sdk" { print; exit }' <<<"${installed_packages}")"
  if [[ -n "${agent_sdk_row}" ]]; then
    installed_version="$(awk '{ print $2 }' <<<"${agent_sdk_row}")"
    if [[ -z "$(normalize_version_triplet "${installed_version}")" ]]; then
      echo "[opam-pin] ERROR: could not parse installed agent_sdk version from opam list row: ${agent_sdk_row}" >&2
      return 2
    fi
    printf '%s' "${installed_version}"
    return 0
  fi

  # Fallback: opam show reads package metadata directly from the switch.  This
  # covers cases where opam list output is incomplete but the switch still knows
  # the package version.
  show_version="$(OPAMCOLOR=never opam show agent_sdk --field=version 2>/dev/null || true)"
  if [[ -n "${show_version}" ]]; then
    installed_version="$(normalize_version_triplet "${show_version}")"
    if [[ -z "${installed_version}" ]]; then
      echo "[opam-pin] ERROR: could not parse installed agent_sdk version from opam show output: ${show_version}" >&2
      return 2
    fi
    printf '%s' "${installed_version}"
    return 0
  fi

  echo "[opam-pin] ERROR: could not determine installed agent_sdk version from opam list or opam show" >&2
  return 2
}

print_opam_lock_holder() {
  if command -v lsof >/dev/null 2>&1; then
    # Filter out our own PID and parent PID: by the time this runs we have
    # already re-execed under flock/lockf and hold the lock ourselves, so
    # naive [lsof <lock>] would report this script as the "stale" holder
    # and hide the actual upstream culprit.
    local self_pid="${BASHPID:-$$}"
    local parent_pid="${PPID:-0}"
    local holders
    holders="$(lsof -t "${opam_lock_path}" 2>/dev/null \
      | awk -v self="${self_pid}" -v parent="${parent_pid}" '$0 != self && $0 != parent' \
      || true)"
    if [[ -n "${holders}" ]]; then
      # shellcheck disable=SC2086
      lsof -p ${holders//$'\n'/,} "${opam_lock_path}" >&2 2>/dev/null || true
    else
      echo "[opam-pin] no other holders of ${opam_lock_path} (self=${self_pid})" >&2
    fi
  else
    echo "[opam-pin] lock holder unknown: lsof unavailable" >&2
  fi
}

allow_agent_sdk_pin_downgrade() {
  [[ "${MASC_ALLOW_OAS_PIN_DOWNGRADE:-0}" == "1" \
    || "${MASC_ALLOW_AGENT_SDK_PIN_DOWNGRADE:-0}" == "1" ]]
}

guard_agent_sdk_downgrade() {
  [[ "${GITHUB_ACTIONS:-}" != "true" ]] || return 0
  # Note: this intentionally does not return early for AGENT_SDK_PIN_URL.
  # Any caller trying to lower the shared floor must opt in explicitly.
  allow_agent_sdk_pin_downgrade && return 0

  local recorded_floor
  if [[ -r "${agent_sdk_floor_path}" ]]; then
    recorded_floor="$(head -n 1 "${agent_sdk_floor_path}" 2>/dev/null || true)"
    if [[ -n "${recorded_floor}" ]] && version_gt "${recorded_floor}" "${OAS_AGENT_SDK_MIN_VERSION}"; then
      echo "[opam-pin] ERROR: refusing to downgrade shared agent_sdk pin below recorded floor ${recorded_floor}; branch floor is ${OAS_AGENT_SDK_MIN_VERSION}" >&2
      echo "[opam-pin] worktree: ${REPO_ROOT}" >&2
      echo "[opam-pin] recorded floor: ${agent_sdk_floor_path}" >&2
      echo "[opam-pin] branch pin source: ${agent_sdk_pin_source}" >&2
      echo "[opam-pin] lock path: ${opam_lock_path}" >&2
      print_opam_lock_holder
      echo "[opam-pin] repair: rebase/update this worktree to the current OAS pin, or set MASC_ALLOW_OAS_PIN_DOWNGRADE=1/MASC_ALLOW_AGENT_SDK_PIN_DOWNGRADE=1 for an intentional rollback" >&2
      exit 1
    fi
  fi

  local installed_version
  if installed_version="$(installed_agent_sdk_version)"; then
    :
  else
    case "$?" in
      1)
        return 0
        ;;
      *)
        echo "[opam-pin] ERROR: refusing to mutate agent_sdk pin because installed version could not be determined" >&2
        echo "[opam-pin] worktree: ${REPO_ROOT}" >&2
        echo "[opam-pin] branch pin source: ${agent_sdk_pin_source}" >&2
        echo "[opam-pin] lock path: ${opam_lock_path}" >&2
        print_opam_lock_holder
        echo "[opam-pin] repair: fix opam switch inspection, or set MASC_ALLOW_OAS_PIN_DOWNGRADE=1/MASC_ALLOW_AGENT_SDK_PIN_DOWNGRADE=1 for an intentional rollback" >&2
        exit 1
        ;;
    esac
  fi

  if version_gt "${installed_version}" "${OAS_AGENT_SDK_MIN_VERSION}"; then
    echo "[opam-pin] ERROR: refusing to downgrade shared agent_sdk pin" >&2
    echo "[opam-pin] worktree: ${REPO_ROOT}" >&2
    echo "[opam-pin] requested: agent_sdk >= ${OAS_AGENT_SDK_MIN_VERSION} at ${agent_sdk_pin_source}" >&2
    echo "[opam-pin] installed: agent_sdk ${installed_version}" >&2
    echo "[opam-pin] lock path: ${opam_lock_path}" >&2
    print_opam_lock_holder
    echo "[opam-pin] repair: use the newer worktree pin, or set MASC_ALLOW_OAS_PIN_DOWNGRADE=1/MASC_ALLOW_AGENT_SDK_PIN_DOWNGRADE=1 for an intentional downgrade" >&2
    exit 1
  fi
}

record_agent_sdk_floor() {
  # Explicit local/rollback use should not ratchet the shared default floor down.
  [[ -z "${AGENT_SDK_PIN_URL:-}" ]] || return 0

  local recorded_floor
  if [[ -r "${agent_sdk_floor_path}" ]]; then
    recorded_floor="$(head -n 1 "${agent_sdk_floor_path}" 2>/dev/null || true)"
    if [[ -n "${recorded_floor}" ]] && version_gt "${recorded_floor}" "${OAS_AGENT_SDK_MIN_VERSION}"; then
      return 0
    fi
  fi

  local floor_dir tmp_path
  floor_dir="$(dirname "${agent_sdk_floor_path}")"
  mkdir -p "${floor_dir}" 2>/dev/null || {
    echo "[opam-pin] WARN: could not create agent_sdk floor dir: ${floor_dir}" >&2
    return 0
  }
  tmp_path="${agent_sdk_floor_path}.tmp.$$"
  if printf '%s\n' "${OAS_AGENT_SDK_MIN_VERSION}" > "${tmp_path}" \
    && mv "${tmp_path}" "${agent_sdk_floor_path}"; then
    return 0
  fi
  rm -f "${tmp_path}" 2>/dev/null || true
  echo "[opam-pin] WARN: could not record agent_sdk floor: ${agent_sdk_floor_path}" >&2
}

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
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

guard_agent_sdk_downgrade

# Accumulate the package names we pin so a follow-up `opam install` in
# --install mode can rebuild exactly the set that changed, nothing more.
pinned_pkgs=()

opam_pin_add() {
  local package="$1"
  local source="$2"
  shift 2

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

if $include_compact_protocol; then
  opam_pin_add compact-protocol https://github.com/jeong-sik/compact-protocol.git#main -n -y
  pinned_pkgs+=("compact-protocol")
fi

# mcp_protocol_eio and mcp_protocol_http merged into mcp_protocol
# as sub-libraries (mcp-protocol-sdk#60). Pin the released single-package line.
opam_pin_add mcp_protocol https://github.com/jeong-sik/mcp-protocol-sdk.git#v1.3.0 -n -y
pinned_pkgs+=("mcp_protocol")
opam_pin_add agent_sdk "${agent_sdk_pin_source}" -n -y
record_agent_sdk_floor
pinned_pkgs+=("agent_sdk")
opam_pin_add ocaml-webrtc "https://github.com/jeong-sik/ocaml-webrtc.git#${WEBRTC_SHA}" -n -y
pinned_pkgs+=("ocaml-webrtc")
opam_pin_add grpc-direct-core "https://github.com/jeong-sik/grpc-direct.git#${GRPC_DIRECT_SHA}" -n -y
pinned_pkgs+=("grpc-direct-core")
opam_pin_add grpc-direct "https://github.com/jeong-sik/grpc-direct.git#${GRPC_DIRECT_SHA}" -n -y
pinned_pkgs+=("grpc-direct")
opam_pin_add neo4j_packstream "https://github.com/jeong-sik/ocaml-neo4j-bolt.git#${NEO4J_BOLT_SHA}" -n -y
pinned_pkgs+=("neo4j_packstream")
opam_pin_add neo4j_bolt_common "https://github.com/jeong-sik/ocaml-neo4j-bolt.git#${NEO4J_BOLT_SHA}" -n -y
pinned_pkgs+=("neo4j_bolt_common")
opam_pin_add neo4j_bolt "https://github.com/jeong-sik/ocaml-neo4j-bolt.git#${NEO4J_BOLT_SHA}" -n -y
pinned_pkgs+=("neo4j_bolt")
opam_pin_add neo4j_bolt_eio "https://github.com/jeong-sik/ocaml-neo4j-bolt.git#${NEO4J_BOLT_SHA}" -n -y
pinned_pkgs+=("neo4j_bolt_eio")

if $include_bisect; then
  # bisect_ppx opam constraints lag newer compilers; keep CI solvable under OCaml 5.4 by pinning.
  opam_pin_add bisect_ppx git+https://github.com/patricoferris/bisect_ppx.git#5.2 -n -y
  pinned_pkgs+=("bisect_ppx")
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
