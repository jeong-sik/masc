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
source "${SCRIPT_DIR}/oas-agent-sdk-pin.sh"
opam_lock_path="${MASC_OPAM_LOCK_PATH:-/tmp/me-opam-switch.lock}"

if [[ "${MASC_OPAM_LOCK:-1}" != "0" \
      && "${MASC_SKIP_OPAM_LOCK:-0}" != "1" \
      && "${MASC_OPAM_LOCK_HELD:-0}" != "1" ]]; then
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  echo "[opam-pin] waiting for opam switch lock ${opam_lock_path}" >&2
  if command -v lockf >/dev/null 2>&1; then
    exec lockf "$opam_lock_path" env MASC_OPAM_LOCK_HELD=1 "$script_path" "$@"
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
