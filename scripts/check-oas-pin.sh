#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCAL_ONLY=0

usage() {
  cat <<'EOF'
Usage: scripts/check-oas-pin.sh [--local-only]

Options:
  --local-only   Skip upstream remote drift lookup and verify only repository
                 manifests plus the current local opam switch.
  -h, --help     Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-only)
      LOCAL_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# GitHub release metadata can lag for this repo. Keep the dependency floor
# aligned with the pinned SDK's declared opam version, and ratchet the runtime
# pin against upstream main so CI catches drift immediately.
source "${SCRIPT_DIR}/oas-agent-sdk-pin.sh"

min_version_re="${OAS_AGENT_SDK_MIN_VERSION//./\\.}"
default_pin_source="${OAS_AGENT_SDK_URL}#${OAS_AGENT_SDK_SHA}"
pin_source="${AGENT_SDK_PIN_URL:-${default_pin_source}}"
expected_opam_pin_source="git+${OAS_AGENT_SDK_URL}#${OAS_AGENT_SDK_SHA}"
# Ambient local checkouts are not authoritative for doctor runs.
# Only validate a local OAS checkout when the caller explicitly opts in.
local_oas_checkout="${AGENT_SDK_LOCAL_REPO:-}"

if [[ "${pin_source}" == "${default_pin_source}" ]]; then
  if [[ "${LOCAL_ONLY}" -eq 0 ]]; then
    latest_main_sha="$(
      git ls-remote "${OAS_AGENT_SDK_URL}" "refs/heads/${OAS_AGENT_SDK_TRACK_REF}" \
        | awk '{print $1}'
    )"

    if [[ -z "${latest_main_sha}" ]]; then
      echo "failed to resolve upstream ${OAS_AGENT_SDK_TRACK_REF} SHA" >&2
      exit 1
    fi

    if [[ "${OAS_AGENT_SDK_SHA}" != "${latest_main_sha}" ]]; then
      echo "::warning::OAS main drift: pinned ${OAS_AGENT_SDK_SHA}, upstream ${latest_main_sha} — update pin when API-compatible"
    fi

    # Ref-reachability guard: the pin SHA must be an ancestor of
    # OAS_AGENT_SDK_TRACK_REF on upstream. Orphan or diverged SHAs still
    # exist as loose objects on GitHub for a grace period, but they are GC
    # candidates and will silently break CI once collected. Checking
    # ancestry here catches drift at review time instead of at incident time.
    reachability_scratch="$(mktemp -d -t oas-pin-reachability.XXXXXX)"
    if GIT_DIR="${reachability_scratch}" git init -q --bare \
       && GIT_DIR="${reachability_scratch}" git fetch -q --no-tags \
            "${OAS_AGENT_SDK_URL}" \
            "+refs/heads/${OAS_AGENT_SDK_TRACK_REF}:refs/heads/${OAS_AGENT_SDK_TRACK_REF}" \
            2>/dev/null; then
      if ! GIT_DIR="${reachability_scratch}" git merge-base --is-ancestor \
           "${OAS_AGENT_SDK_SHA}" \
           "refs/heads/${OAS_AGENT_SDK_TRACK_REF}" 2>/dev/null; then
        echo "OAS pin ${OAS_AGENT_SDK_SHA} is not reachable from ${OAS_AGENT_SDK_TRACK_REF} on ${OAS_AGENT_SDK_URL}" >&2
        echo "  Orphan or diverged SHAs are GC candidates on GitHub and will silently break CI once collected." >&2
        echo "  repair: bump OAS_AGENT_SDK_SHA in scripts/oas-agent-sdk-pin.sh to a commit on ${OAS_AGENT_SDK_TRACK_REF}" >&2
        rm -rf "${reachability_scratch}"
        exit 1
      fi
    else
      echo "WARN: could not fetch ${OAS_AGENT_SDK_TRACK_REF} from ${OAS_AGENT_SDK_URL}; skipping ref-reachability check" >&2
    fi
    rm -rf "${reachability_scratch}"
  fi
else
  echo "OAS pin override in use: ${pin_source}"
fi

if ! grep -Eq "\\(agent_sdk \\(>= ${min_version_re}\\)\\)" "${REPO_ROOT}/dune-project"; then
  echo "dune-project agent_sdk floor is not ${OAS_AGENT_SDK_MIN_VERSION}" >&2
  exit 1
fi

if ! grep -Eq "\"agent_sdk\" \\{>= \"${min_version_re}\"\\}" "${REPO_ROOT}/masc_mcp.opam"; then
  echo "masc_mcp.opam agent_sdk floor is not ${OAS_AGENT_SDK_MIN_VERSION}" >&2
  exit 1
fi

if ! bash "${SCRIPT_DIR}/sync-oas-pin-docs.sh" --check; then
  echo "OAS pin generated doc blocks are not aligned with scripts/oas-agent-sdk-pin.sh" >&2
  exit 1
fi

if [[ "${pin_source}" == "${default_pin_source}" ]]; then
  if [[ -n "${local_oas_checkout}" ]] \
    && git -C "${local_oas_checkout}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local_checkout_head="$(git -C "${local_oas_checkout}" rev-parse HEAD 2>/dev/null || true)"
    if [[ "${local_checkout_head}" != "${OAS_AGENT_SDK_SHA}" ]]; then
      echo "local oas checkout drift: ${local_oas_checkout}@${local_checkout_head:-unknown}, expected ${OAS_AGENT_SDK_SHA}" >&2
      echo "repair: git -C \"${local_oas_checkout}\" checkout ${OAS_AGENT_SDK_SHA} # or pin that checkout explicitly via AGENT_SDK_PIN_URL" >&2
      exit 1
    fi
  elif [[ -n "${AGENT_SDK_LOCAL_REPO:-}" ]]; then
    echo "AGENT_SDK_LOCAL_REPO is not a git checkout: ${local_oas_checkout}" >&2
    exit 1
  fi
fi

# Portable semver comparison: returns 0 (true) if $1 >= $2.
# Handles 3-part versions (major.minor.patch); missing parts default to 0.
normalize_version_triplet() {
  local value
  value="$(printf '%s' "$1" | sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g')"
  if [[ "${value}" =~ ([0-9]+(\.[0-9]+){0,2}) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

version_gte() {
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
  return 0
}

if command -v opam >/dev/null 2>&1; then
  # Refresh switch environment — opam install may have changed the switch
  # state on disk without updating the current shell's env vars.
  eval "$(opam env --switch=. --set-switch 2>/dev/null)" || true

  # Use opam list directly (not opam exec --) to avoid stale environment
  # from a cached exec context. Keep stderr visible for diagnostics.
  installed_packages="$(OPAMCOLOR=never opam list --installed --columns=name,version --short 2>&1)" || true
  installed_version="$(awk '$1 == "agent_sdk" { print $2 }' <<<"${installed_packages}")"

  # Fallback: opam show reads package metadata directly from the switch.
  if [[ -z "${installed_version}" ]]; then
    installed_version="$(OPAMCOLOR=never opam show agent_sdk --field=version 2>/dev/null || true)"
  fi

  if [[ -z "${installed_version}" ]]; then
    echo "agent_sdk is not installed in the current opam switch" >&2
    echo "  opam list output: ${installed_packages:-<empty>}" >&2
    echo "repair: bash scripts/opam-pin-external-deps.sh && opam install . --deps-only --with-test -y" >&2
    exit 1
  fi
  if ! version_gte "${installed_version}" "${OAS_AGENT_SDK_MIN_VERSION}"; then
    echo "installed agent_sdk version is ${installed_version}, expected >= ${OAS_AGENT_SDK_MIN_VERSION}" >&2
    echo "repair: bash scripts/opam-pin-external-deps.sh && opam install . --deps-only --with-test -y" >&2
    exit 1
  fi

  pin_list_output="$(OPAMCOLOR=never opam pin list 2>/dev/null || true)"
  pin_line="$(awk '$1 ~ /^agent_sdk\./ { print }' <<<"${pin_list_output}")"
  if [[ -n "${pin_line}" ]]; then
    installed_pin_source="$(sed -nE 's/.*(git\+[^[:space:]]+).*/\1/p' <<<"${pin_line}")"
    case "${installed_pin_source}" in
      "${expected_opam_pin_source}")
        ;;
      git+file://*)
        local_pin_path="${installed_pin_source#git+file://}"
        local_pin_path="${local_pin_path%%#*}"
        local_pin_head="$(git -C "${local_pin_path}" rev-parse HEAD 2>/dev/null || true)"
        if [[ "${local_pin_head}" != "${OAS_AGENT_SDK_SHA}" ]]; then
          echo "local agent_sdk pin points to ${local_pin_path}@${local_pin_head:-unknown}, expected ${OAS_AGENT_SDK_SHA}" >&2
          echo "repair: bash scripts/opam-pin-external-deps.sh" >&2
          exit 1
        fi
        ;;
      *)
        echo "agent_sdk pin source is ${installed_pin_source}, expected ${expected_opam_pin_source}" >&2
        echo "repair: bash scripts/opam-pin-external-deps.sh" >&2
        exit 1
        ;;
    esac
  elif [[ "${LOCAL_ONLY}" -eq 0 ]]; then
    echo "WARN: could not read agent_sdk pin source from opam; installed version ${installed_version} satisfies floor ${OAS_AGENT_SDK_MIN_VERSION}" >&2
  fi
fi

if [[ "${pin_source}" == "${default_pin_source}" ]]; then
  echo "OAS pin verified: ${OAS_AGENT_SDK_TRACK_REF}@${OAS_AGENT_SDK_SHA} (base version ${OAS_AGENT_SDK_BASE_VERSION})"
else
  echo "OAS pin verified via override: ${pin_source}"
fi

# API surface summary (non-fatal). A full drift diff with repair
# guidance is available via `make doctor-oas-drift` or
# `bash scripts/oas-drift-check.sh`. Here we emit one line so that
# every doctor-oas-pin run surfaces surface-level drift without
# requiring the operator to remember a second command.
if [[ -x "${SCRIPT_DIR}/oas-drift-check.sh" ]]; then
  if drift_output="$(bash "${SCRIPT_DIR}/oas-drift-check.sh" 2>&1)"; then
    echo "OAS API surface: ✓ matches fingerprint"
  else
    drift_exit=$?
    if [[ "${drift_exit}" -eq 2 ]]; then
      # Count delta entries across all sections for a one-line summary.
      added_n="$(printf '%s\n' "${drift_output}" | grep -c '^      + ' || true)"
      removed_n="$(printf '%s\n' "${drift_output}" | grep -c '^      - ' || true)"
      echo "OAS API surface: ⚠ drift (added ${added_n}, removed ${removed_n}) — run 'make doctor-oas-drift' for detail"
    else
      echo "OAS API surface: (could not compute — ${drift_exit}; run 'bash scripts/oas-drift-check.sh' for detail)"
    fi
  fi
fi
