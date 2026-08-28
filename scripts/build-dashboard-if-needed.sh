#!/usr/bin/env bash
# build-dashboard-if-needed.sh — Rebuild dashboard SPA only when sources changed.
# Called by `make build`. Compares source mtime against build output.
# Skips when: no package.json, pnpm/corepack missing, or sources unchanged.

set -euo pipefail

FORCE_BUILD=0
PREPARE_EXACT=0
BUILD_EXACT=0
EXPECTED_PM_EXECUTABLE=""
EXPECTED_PM_KIND=""
EXPECTED_PM_SHA256=""
EXPECTED_NODE_EXECUTABLE=""
EXPECTED_NODE_SHA256=""
EXPECTED_BUILD_PATH=""
EXPECTED_ENVIRONMENT_PROFILE_SHA256=""
EXPECTED_RUNTIME_RECEIPT=""
EXPECTED_BUILD_INPUT_RECEIPT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE_BUILD=1
      shift
      ;;
    --prepare-exact)
      PREPARE_EXACT=1
      shift
      ;;
    --build-exact)
      BUILD_EXACT=1
      shift
      ;;
    --package-manager-executable)
      EXPECTED_PM_EXECUTABLE="$2"
      shift 2
      ;;
    --package-manager-kind)
      EXPECTED_PM_KIND="$2"
      shift 2
      ;;
    --package-manager-sha256)
      EXPECTED_PM_SHA256="$2"
      shift 2
      ;;
    --node-executable)
      EXPECTED_NODE_EXECUTABLE="$2"
      shift 2
      ;;
    --node-sha256)
      EXPECTED_NODE_SHA256="$2"
      shift 2
      ;;
    --build-path)
      EXPECTED_BUILD_PATH="$2"
      shift 2
      ;;
    --environment-profile-sha256)
      EXPECTED_ENVIRONMENT_PROFILE_SHA256="$2"
      shift 2
      ;;
    --runtime-receipt)
      EXPECTED_RUNTIME_RECEIPT="$2"
      shift 2
      ;;
    --build-input-receipt)
      EXPECTED_BUILD_INPUT_RECEIPT="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--force|--prepare-exact|--build-exact] [--package-manager-executable PATH --package-manager-kind pnpm|corepack --package-manager-sha256 SHA256 --node-executable PATH --node-sha256 SHA256 --build-path PATH --environment-profile-sha256 SHA256]" >&2
      exit 2
      ;;
  esac
done
if [ $((FORCE_BUILD + PREPARE_EXACT + BUILD_EXACT)) -gt 1 ]; then
  echo "dashboard build modes are mutually exclusive" >&2
  exit 2
fi
if { [ -n "$EXPECTED_PM_EXECUTABLE" ] && { [ -z "$EXPECTED_PM_KIND" ] || [ -z "$EXPECTED_PM_SHA256" ] || [ -z "$EXPECTED_NODE_EXECUTABLE" ] || [ -z "$EXPECTED_NODE_SHA256" ] || [ -z "$EXPECTED_BUILD_PATH" ] || [ -z "$EXPECTED_ENVIRONMENT_PROFILE_SHA256" ] || [ -z "$EXPECTED_RUNTIME_RECEIPT" ]; }; } \
  || { [ -z "$EXPECTED_PM_EXECUTABLE" ] && { [ -n "$EXPECTED_PM_KIND" ] || [ -n "$EXPECTED_PM_SHA256" ] || [ -n "$EXPECTED_NODE_EXECUTABLE" ] || [ -n "$EXPECTED_NODE_SHA256" ] || [ -n "$EXPECTED_BUILD_PATH" ] || [ -n "$EXPECTED_ENVIRONMENT_PROFILE_SHA256" ] || [ -n "$EXPECTED_RUNTIME_RECEIPT" ]; }; }; then
  echo "dashboard package-manager identity arguments must be provided together" >&2
  exit 2
fi
if { [ "$PREPARE_EXACT" = "1" ] || [ "$BUILD_EXACT" = "1" ]; } && [ -z "$EXPECTED_PM_EXECUTABLE" ]; then
  echo "exact dashboard phase requires a captured runtime identity" >&2
  exit 2
fi
if [ "$PREPARE_EXACT" = "1" ] && [ -n "$EXPECTED_BUILD_INPUT_RECEIPT" ]; then
  echo "dependency preparation does not accept a full build-input receipt" >&2
  exit 2
fi
if [ "$BUILD_EXACT" = "1" ] && [ -z "$EXPECTED_BUILD_INPUT_RECEIPT" ]; then
  echo "exact dashboard build requires a full build-input receipt" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DASHBOARD_DIR="$REPO_ROOT/dashboard"
OUTPUT_DIR="$REPO_ROOT/assets/dashboard"
STAMP="$OUTPUT_DIR/.build-stamp"

# No dashboard source — nothing to do
if [ ! -f "$DASHBOARD_DIR/package.json" ]; then
  if [ "$FORCE_BUILD" = "1" ] || [ "$PREPARE_EXACT" = "1" ] || [ "$BUILD_EXACT" = "1" ]; then
    echo "[dashboard] package.json missing; exact force build cannot continue." >&2
    exit 1
  fi
  exit 0
fi

dashboard_pm=()
dashboard_pm_label=""
if [ -n "$EXPECTED_PM_EXECUTABLE" ]; then
  if [ ! -f "$EXPECTED_PM_EXECUTABLE" ] || [ ! -x "$EXPECTED_PM_EXECUTABLE" ] \
    || [ ! -f "$EXPECTED_NODE_EXECUTABLE" ] || [ ! -x "$EXPECTED_NODE_EXECUTABLE" ]; then
    echo "[dashboard] expected package-manager executable is unavailable." >&2
    exit 1
  fi
  case "$EXPECTED_PM_KIND" in
    pnpm) dashboard_pm=("$EXPECTED_NODE_EXECUTABLE" "$EXPECTED_PM_EXECUTABLE") ;;
    corepack) dashboard_pm=("$EXPECTED_NODE_EXECUTABLE" "$EXPECTED_PM_EXECUTABLE" pnpm) ;;
    *)
      echo "[dashboard] expected package-manager invocation kind is invalid." >&2
      exit 2
      ;;
  esac
elif command -v pnpm >/dev/null 2>&1; then
  dashboard_pm=(pnpm)
elif command -v corepack >/dev/null 2>&1; then
  dashboard_pm=(corepack pnpm)
else
  if [ "$FORCE_BUILD" = "1" ]; then
    echo "[dashboard] pnpm/corepack not found; exact force build cannot continue." >&2
    exit 1
  else
    echo "[dashboard] pnpm/corepack not found, skipping." >&2
    exit 0
  fi
fi
dashboard_pm_label="${dashboard_pm[*]}"

require_expected_package_manager_identity() {
  if [ -z "$EXPECTED_PM_EXECUTABLE" ]; then
    return 0
  fi
  "$REPO_ROOT/scripts/run-local-executable-binding.py" \
    --verify-dashboard-build-runtime \
    --dashboard-build-runtime-receipt "$EXPECTED_RUNTIME_RECEIPT" \
    --dashboard-package-manager-kind "$EXPECTED_PM_KIND" \
    --dashboard-package-manager-executable "$EXPECTED_PM_EXECUTABLE" \
    --dashboard-package-manager-sha256 "$EXPECTED_PM_SHA256" \
    --dashboard-node-executable "$EXPECTED_NODE_EXECUTABLE" \
    --dashboard-node-sha256 "$EXPECTED_NODE_SHA256" \
    --dashboard-environment-path "$EXPECTED_BUILD_PATH" \
    --dashboard-environment-profile-sha256 "$EXPECTED_ENVIRONMENT_PROFILE_SHA256"
}

require_expected_build_input_identity() {
  "$REPO_ROOT/scripts/run-local-executable-binding.py" \
    --verify-dashboard-build-input \
    --dashboard-build-runtime-receipt "$EXPECTED_RUNTIME_RECEIPT" \
    --dashboard-build-input-receipt "$EXPECTED_BUILD_INPUT_RECEIPT" \
    --dashboard-package-manager-kind "$EXPECTED_PM_KIND" \
    --dashboard-package-manager-executable "$EXPECTED_PM_EXECUTABLE" \
    --dashboard-node-executable "$EXPECTED_NODE_EXECUTABLE" \
    --dashboard-environment-path "$EXPECTED_BUILD_PATH"
}

generated_index_has_remote_startup_resources() {
  local index="$OUTPUT_DIR/index.html"
  [ -f "$index" ] || return 1

  # The dashboard source index intentionally avoids network-blocking startup
  # resources. Treat stale generated output that still contains them as invalid
  # even when the timestamp stamp says "fresh".
  if grep -Eiq 'https://fonts\.(googleapis|gstatic)\.com' "$index"; then
    return 0
  fi
  if grep -Eiq '<link[^>]+rel=["'\'']stylesheet["'\''][^>]+href=["'\'']https://' "$index"; then
    return 0
  fi

  return 1
}

sanitize_dashboard_build_environment() {
  local variable_name=""
  for variable_name in ${!VITE_@}; do
    unset "$variable_name"
  done
  unset BUNDLE_REPORT MASC_DASHBOARD_PROXY_TARGET NODE_ENV NODE_OPTIONS
  export NODE_ENV=production
  if [ -n "$EXPECTED_BUILD_PATH" ]; then
    export PATH="$EXPECTED_BUILD_PATH"
  fi
}

if [ "$PREPARE_EXACT" = "1" ]; then
  if ! (cd "$DASHBOARD_DIR" && require_expected_package_manager_identity && sanitize_dashboard_build_environment && "${dashboard_pm[@]}" install --frozen-lockfile --prefer-offline); then
    echo "[dashboard] Exact dependency preparation failed." >&2
    exit 1
  fi
  echo "[dashboard] Exact dependency preparation complete." >&2
  exit 0
fi

if [ "$BUILD_EXACT" = "1" ]; then
  if ! (cd "$DASHBOARD_DIR" && require_expected_build_input_identity && sanitize_dashboard_build_environment && "${dashboard_pm[@]}" run build); then
    echo "[dashboard] Exact build failed." >&2
    exit 1
  fi
  touch "$STAMP"
  echo "[dashboard] Exact build complete." >&2
  exit 0
fi

# Check if rebuild is needed: source mtimes, missing output, or invalid output.
needs_rebuild() {
  [ "$FORCE_BUILD" = "1" ] && return 0
  # No stamp or no output → must build
  [ ! -f "$STAMP" ] && return 0
  [ ! -f "$OUTPUT_DIR/index.html" ] && return 0

  if generated_index_has_remote_startup_resources; then
    echo "[dashboard] Generated index contains remote startup resources; rebuilding." >&2
    return 0
  fi

  # Any .ts/.tsx/.css/.html source newer than stamp → rebuild
  if find "$DASHBOARD_DIR/src" \
       -newer "$STAMP" \( -name '*.ts' -o -name '*.tsx' -o -name '*.css' -o -name '*.html' \) \
       2>/dev/null | head -1 | grep -q .; then
    return 0
  fi

  # Root index.html newer than stamp → rebuild
  if [ "$DASHBOARD_DIR/index.html" -nt "$STAMP" ]; then
    return 0
  fi

  # package.json changed → rebuild (deps may have changed)
  if [ "$DASHBOARD_DIR/package.json" -nt "$STAMP" ]; then
    return 0
  fi

  return 1
}

if needs_rebuild; then
  echo "[dashboard] Build output stale, rebuilding SPA..." >&2
  temp_root="${TMPDIR:-/tmp}"
  temp_root="${temp_root%/}"
  if [ ! -d "$temp_root" ] || [ ! -w "$temp_root" ]; then
    temp_root="/tmp"
  fi
  if ! log_file="$(TMPDIR="$temp_root" mktemp "$temp_root/masc-dashboard-build.XXXXXX" 2>/dev/null)"; then
    echo "[dashboard] Unable to create temp log file; falling back to stderr-less logging." >&2
    log_file="/dev/null"
  fi
  if [ "$FORCE_BUILD" != "1" ] && [ -d "$DASHBOARD_DIR/node_modules" ]; then
    if (cd "$DASHBOARD_DIR" && require_expected_package_manager_identity && sanitize_dashboard_build_environment && "${dashboard_pm[@]}" run build >"$log_file" 2>&1); then
      tail -n 3 "$log_file" >&2 || true
      if [ "$log_file" != "/dev/null" ]; then
        rm -f "$log_file"
      fi
      touch "$STAMP"
      echo "[dashboard] Build complete." >&2
      exit 0
    fi
    echo "[dashboard] Existing deps build failed, retrying after ${dashboard_pm_label} install..." >&2
  fi

  if ! (cd "$DASHBOARD_DIR" && require_expected_package_manager_identity && sanitize_dashboard_build_environment && "${dashboard_pm[@]}" install --frozen-lockfile --prefer-offline >"$log_file" 2>&1 && "${dashboard_pm[@]}" run build >>"$log_file" 2>&1); then
    tail -n 20 "$log_file" >&2 || true
    if [ "$log_file" != "/dev/null" ]; then
      rm -f "$log_file"
    fi
    echo "[dashboard] Build FAILED. Dashboard SPA is stale — fix vite errors or pass --non-fatal." >&2
    if [ "$FORCE_BUILD" != "1" ] && [[ "${MASC_DASHBOARD_BUILD_NON_FATAL:-}" == "1" ]]; then
      echo "[dashboard] Continuing (MASC_DASHBOARD_BUILD_NON_FATAL=1)." >&2
      exit 0
    fi
    exit 1
  fi
  tail -n 6 "$log_file" >&2 || true
  if [ "$log_file" != "/dev/null" ]; then
    rm -f "$log_file"
  fi
  touch "$STAMP"
  echo "[dashboard] Build complete." >&2
else
  # Binary-only deploys leave the stamp older than the freshly built server
  # binary, and the server compares stamp mtime against its own executable
  # (lib/web_dashboard.ml bundle_freshness) — so /health reported the bundle
  # as stale even though it matches the sources (#28973). The stamp asserts
  # source-bundle consistency; when that holds (needs_rebuild said no) and
  # the server binary is newer, refresh the stamp instead of rebuilding.
  server_bin="$REPO_ROOT/_build/default/bin/main_eio.exe"
  if [ -f "$server_bin" ] && [ "$server_bin" -nt "$STAMP" ]; then
    touch "$STAMP"
    echo "[dashboard] Up to date; stamp refreshed past newer server binary (#28973)." >&2
  else
    echo "[dashboard] Up to date, skipping." >&2
  fi
fi
