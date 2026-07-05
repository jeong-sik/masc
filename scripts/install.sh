#!/usr/bin/env bash
# masc installer — download prebuilt binary, seed runtime config/catalog, smoke-check.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/scripts/install.sh -o /tmp/masc-install.sh
#   less /tmp/masc-install.sh
#   bash /tmp/masc-install.sh --version <release-tag>
#   curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/scripts/install.sh | bash -s -- --version <release-tag> --prefix /usr/local/bin
#
# Flags:
#   --version vX.Y.Z   Pin a specific release (default: latest)
#   --prefix DIR       Install dir for the binary (default: $HOME/.local/bin)
#   --base-path DIR    .masc seed target (default: $PWD)
#   --no-seed          Skip writing default config files
#   --force            Overwrite existing binary / config
#   --dry-run          Print what would happen, do not write
#   --allow-unverified Continue if SHA256SUMS cannot be fetched (unsafe)
#   --wizard           Always run the first-time provider setup wizard
#   --no-wizard        Skip the provider setup wizard
#   --provider ID      Pre-select a provider for the wizard (e.g. deepseek)
#   --api-key KEY      Provider API key (use with --provider; visible in ps)
#   --api-key-stdin    Read provider API key from stdin (use with --provider)
#
# Env:
#   MASC_VERSION   Same as --version
#   MASC_PREFIX    Same as --prefix
#   MASC_REPO      Override repo (default: jeong-sik/masc)
#   MASC_PORT      Port used in the post-install local-start hint (default: 8935)
#   MASC_ALLOW_UNVERIFIED=1  Same as --allow-unverified
#   OAS_MODEL_CATALOG  Override model catalog path; defaults to seeded
#                  <base-path>/.masc/config/oas-models.toml when present.
#   MASC_RUNTIME_EVENTS=0/1  Override OCaml Runtime_events. When unset, the
#                  generated server command keeps the binary's default.
#   MASC_WIZARD=0/1  Same as --no-wizard / --wizard
#   <PROVIDER_API_KEY>  Provider key env declared by runtime.toml credentials.key
#   MASC_API_KEY   Used only when the selected provider declares
#                  credentials.key = "MASC_API_KEY" in runtime.toml.

set -euo pipefail

REPO="${MASC_REPO:-jeong-sik/masc}"
VERSION="${MASC_VERSION:-}"
PREFIX="${MASC_PREFIX:-$HOME/.local/bin}"
MASC_PORT="${MASC_PORT:-8935}"
BASE_PATH=""
SEED_CONFIG=1
FORCE=0
DRY_RUN=0
ALLOW_UNVERIFIED="${MASC_ALLOW_UNVERIFIED:-0}"
WIZARD="${MASC_WIZARD:-auto}"
WIZARD_PROVIDER=""
WIZARD_API_KEY=""
WIZARD_API_KEY_STDIN=0
WIZARD_GENERIC_API_KEY="${MASC_API_KEY:-}"

# Installer network budgets are script-local SSOTs. Keep them explicit instead
# of scattering bare curl numbers across release lookup, config seeding, and
# provider pings.
readonly MASC_INSTALL_PUBLIC_PING_TIMEOUT_S=5
readonly MASC_INSTALL_AUTH_PING_TIMEOUT_S=10
readonly MASC_INSTALL_RELEASE_METADATA_TIMEOUT_S=30
readonly MASC_INSTALL_CONFIG_FETCH_TIMEOUT_S=60
readonly MASC_INSTALL_BINARY_DOWNLOAD_TIMEOUT_S=300
readonly MASC_INSTALL_CURL_RETRIES=3

# --- provider catalog ---------------------------------------------------------
PROVIDER_IDS=()
PROVIDER_NAMES=()
PROVIDER_KEYS=()
PROVIDER_ENDPOINTS=()
PROVIDER_PING_PATHS=()
PROVIDER_DEFAULT_RUNTIME_IDS=()
PROVIDER_INDEX_RESULT=""
DEFAULT_PROVIDER_INDEX=0
CATALOG_FILE=""
PARTIAL_FILES=()

provider_index_by_id() {
  local id="$1" i
  for i in "${!PROVIDER_IDS[@]}"; do
    if [ "${PROVIDER_IDS[$i]}" = "$id" ]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

runtime_id_in_catalog() {
  local runtime_id="$1" i
  for i in "${!PROVIDER_DEFAULT_RUNTIME_IDS[@]}"; do
    if [ "${PROVIDER_DEFAULT_RUNTIME_IDS[$i]}" = "$runtime_id" ]; then
      return 0
    fi
  done
  return 1
}

read_catalog_field() {
  local __field_name="$1"
  if ! IFS= read -r -d '' "$__field_name"; then
    die "truncated provider wizard catalog record"
  fi
}

load_provider_catalog() {
  local base_path="$1"
  local runtime_file="$base_path/.masc/config/runtime.toml"
  if [ ! -e "$runtime_file" ]; then
    die "runtime.toml not found; cannot derive provider wizard catalog"
  fi
  if [ ! -x "${DEST:-}" ]; then
    die "installed masc binary not found; cannot derive provider wizard catalog"
  fi

  PROVIDER_IDS=()
  PROVIDER_NAMES=()
  PROVIDER_KEYS=()
  PROVIDER_ENDPOINTS=()
  PROVIDER_PING_PATHS=()
  PROVIDER_DEFAULT_RUNTIME_IDS=()
  DEFAULT_PROVIDER_INDEX=0

  local kind id name key endpoint ping_path runtime_id default_provider_id="" missing_default_runtime_id=""
  [ -z "$CATALOG_FILE" ] || rm -f "$CATALOG_FILE"
  CATALOG_FILE="$(mktemp)" || die "could not create provider wizard catalog temp file"
  "$DEST" runtime-wizard-catalog --base-path "$base_path" >"$CATALOG_FILE" \
    || die "failed to derive provider wizard catalog from $runtime_file"
  while IFS= read -r -d '' kind; do
    case "$kind" in
      provider)
        read_catalog_field id
        read_catalog_field name
        read_catalog_field key
        read_catalog_field endpoint
        read_catalog_field ping_path
        read_catalog_field runtime_id
        [ -n "${id:-}" ] || die "provider wizard catalog has empty provider id"
        [ -n "${name:-}" ] || die "provider wizard catalog has empty display name for $id"
        [ -n "${endpoint:-}" ] || die "provider wizard catalog has empty endpoint for $id"
        [ -n "${runtime_id:-}" ] || die "provider wizard catalog has empty runtime id for $id"
        PROVIDER_IDS+=("$id")
        PROVIDER_NAMES+=("$name")
        PROVIDER_KEYS+=("${key:-}")
        PROVIDER_ENDPOINTS+=("$endpoint")
        PROVIDER_PING_PATHS+=("${ping_path:-}")
        PROVIDER_DEFAULT_RUNTIME_IDS+=("$runtime_id")
        ;;
      default-provider)
        read_catalog_field id
        default_provider_id="${id:-}"
        ;;
      default-runtime-missing)
        read_catalog_field runtime_id
        missing_default_runtime_id="${runtime_id:-}"
        ;;
      *)
        die "unknown provider wizard catalog record kind: $kind"
        ;;
    esac
  done <"$CATALOG_FILE"
  rm -f "$CATALOG_FILE"
  CATALOG_FILE=""

  if [ "${#PROVIDER_IDS[@]}" -eq 0 ]; then
    die "runtime.toml has no typed provider catalog entries for the setup wizard"
  fi

  if [ -n "$missing_default_runtime_id" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      die "runtime.toml default runtime id is not present in provider bindings: $missing_default_runtime_id"
    fi
    warn "configured default runtime '$missing_default_runtime_id' is not in the runtime catalog; the wizard will set a new default"
    DEFAULT_PROVIDER_INDEX=0
  fi

  for idx in "${!PROVIDER_IDS[@]}"; do
    [ -n "${PROVIDER_ENDPOINTS[$idx]}" ] \
      || die "provider ${PROVIDER_IDS[$idx]} in runtime.toml has no endpoint"
    [ -n "${PROVIDER_DEFAULT_RUNTIME_IDS[$idx]}" ] \
      || die "provider ${PROVIDER_IDS[$idx]} in runtime.toml has no concrete runtime binding"
    if [ -n "${PROVIDER_KEYS[$idx]}" ] && ! [[ "${PROVIDER_KEYS[$idx]}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      die "provider ${PROVIDER_IDS[$idx]} credential key must be a valid environment variable name"
    fi
    if [ -n "${PROVIDER_PING_PATHS[$idx]}" ] && [[ "${PROVIDER_PING_PATHS[$idx]}" != /* ]]; then
      die "provider ${PROVIDER_IDS[$idx]} healthcheck.path must start with /"
    fi
  done

  if [ -n "$default_provider_id" ]; then
    if idx=$(provider_index_by_id "$default_provider_id"); then
      DEFAULT_PROVIDER_INDEX="$idx"
    elif [ "$DRY_RUN" -eq 1 ]; then
      # --dry-run does not write, so it cannot repair a stale [runtime].default
      # (see the [dry-run] guard in the runtime-default writer). Surface the
      # broken default as an error rather than pretend the wizard proceeded.
      die "provider wizard catalog default-provider is not present in provider entries: $default_provider_id"
    else
      # The seeded [runtime].default names a provider with no catalog entry
      # (renamed/removed provider, or a hand-edited runtime.toml). Repairing
      # that stale default is exactly what the wizard exists to do, so warn and
      # fall back to the first catalog provider as the menu default instead of
      # aborting — otherwise the broken config is unrepairable by the tool meant
      # to fix it. An explicit --provider still overrides this downstream, and
      # the wizard rewrites [runtime].default to the selected provider before
      # finishing.
      warn "configured default provider '$default_provider_id' is not in the runtime catalog; the wizard will set a new default"
      DEFAULT_PROVIDER_INDEX=0
    fi
  fi
}

provider_key_var() {
  echo "${PROVIDER_KEYS[$1]}"
}

provider_name() {
  echo "${PROVIDER_NAMES[$1]}"
}

provider_env_key() {
  local key_var="$1"
  if [ -n "$key_var" ] && [ -n "${!key_var:-}" ]; then
    echo "${!key_var}"
    return 0
  fi
  return 1
}

prompt_provider() {
  if ! is_tty; then
    echo "$DEFAULT_PROVIDER_INDEX"
    return
  fi
  local idx
  while true; do
    echo >&2
    echo "? Choose your default provider:" >&2
    local i
    for i in "${!PROVIDER_IDS[@]}"; do
      local marker=""
      [ "$i" -eq "$DEFAULT_PROVIDER_INDEX" ] && marker=" (default)"
      printf >&2 '  %d) %s%s' "$((i + 1))" "${PROVIDER_NAMES[$i]}" "$marker"
      [ -n "${PROVIDER_KEYS[$i]}" ] && printf >&2 ' - needs %s' "${PROVIDER_KEYS[$i]}"
      printf >&2 '\n'
    done
    printf >&2 '> '
    local choice
    read -r choice || true
    if [ -z "$choice" ]; then
      echo "$DEFAULT_PROVIDER_INDEX"
      return
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
      warn "please enter a number"
      continue
    fi
    idx=$((choice - 1))
    if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#PROVIDER_IDS[@]}" ]; then
      warn "invalid choice"
      continue
    fi
    echo "$idx"
    return
  done
}

prompt_key() {
  local idx="$1"
  local key_var
  key_var=$(provider_key_var "$idx")
  if [ -z "$key_var" ]; then
    return 0
  fi

  if ! is_tty; then
    return 0
  fi

  local existing=""
  local existing_name=""
  if [ -n "${!key_var:-}" ]; then
    existing="${!key_var}"
    existing_name="$key_var"
  elif [ "$key_var" = "MASC_API_KEY" ] && [ -n "$WIZARD_GENERIC_API_KEY" ]; then
    existing="$WIZARD_GENERIC_API_KEY"
    existing_name="MASC_API_KEY"
  fi

  if [ -n "$existing" ]; then
    echo >&2
    printf '? %s is already set in the environment. Use it? [Y/n] ' "$existing_name" >&2
    local reuse
    read -r reuse || true
    case "$reuse" in
      [Nn]* ) ;;
      *) echo "$existing"; return ;;
    esac
  fi

  local key
  while true; do
    echo >&2
    printf '? Enter %s: ' "$key_var" >&2
    read -s -r key || true
    echo >&2
    if [ -z "$key" ]; then
      warn "key is empty; please enter a value or press Ctrl-C to abort"
      continue
    fi
    echo "$key"
    return
  done
}

resolve_wizard_key() {
  local idx="$1"
  local key_var
  key_var=$(provider_key_var "$idx")
  if [ -z "$key_var" ]; then
    return 0
  fi

  if [ -n "$WIZARD_API_KEY" ]; then
    echo "$WIZARD_API_KEY"
    return 0
  fi

  if is_tty; then
    prompt_key "$idx"
    return
  fi

  if [ "$key_var" = "MASC_API_KEY" ] && [ -n "$WIZARD_GENERIC_API_KEY" ]; then
    echo "$WIZARD_GENERIC_API_KEY"
    return 0
  fi

  provider_env_key "$key_var" \
    || die "API key for $key_var is required in non-TTY mode (set $key_var or pass --api-key)"
}

validate_provider_key() {
  local key="$1" key_var="$2"
  if [ -z "$key" ]; then
    die "API key for $key_var cannot be empty"
  fi
  if [[ "$key" == *$'\r'* ]] || [[ "$key" == *$'\n'* ]]; then
    die "API key for $key_var contains a newline; refusing to write"
  fi
}

write_env_local() {
  local base_path="$1" idx="$2" key="$3"
  local key_var
  key_var=$(provider_key_var "$idx")
  local env_file="$base_path/.masc/config/.env.local"

  if [ -z "$key_var" ]; then
    log "provider $(provider_name "$idx") does not require an API key"
    return 0
  fi

  validate_provider_key "$key" "$key_var"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would write $env_file with $key_var=***"
    return 0
  fi

  local env_dir tmp
  env_dir="$(dirname "$env_file")"
  mkdir -p "$env_dir"
  tmp="$(umask 077 && mktemp "$env_dir/.env.local.tmp.XXXXXX")" \
    || die "could not create private temp file for $env_file"
  PARTIAL_FILES+=("$tmp")
  if ( umask 077 && printf 'export %s=%q\n' "$key_var" "$key" > "$tmp" ); then
    :
  else
    rm -f "$tmp"
    die "could not write $env_file"
  fi
  if chmod 600 "$tmp" 2>/dev/null; then
    :
  else
    rm -f "$tmp"
    die "could not restrict permissions on $env_file"
  fi
  if mv -f "$tmp" "$env_file"; then
    :
  else
    rm -f "$tmp"
    die "could not replace $env_file"
  fi
  log "wrote $env_file"
}

update_runtime_default() {
  local base_path="$1" runtime_id="$2"
  local runtime_file="$base_path/.masc/config/runtime.toml"

  if ! runtime_id_in_catalog "$runtime_id"; then
    warn "unknown runtime id '$runtime_id'; skipping runtime.toml update"
    return 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would set [runtime].default = \"$runtime_id\" in $runtime_file"
    return 0
  fi

  if [ ! -e "$runtime_file" ]; then
    warn "runtime.toml not found; cannot update default provider"
    return 1
  fi

  if [ ! -x "${DEST:-}" ]; then
    warn "installed masc binary not found; cannot update runtime.toml default"
    return 1
  fi

  if ! "$DEST" runtime-default-set --base-path "$base_path" "$runtime_id" >/dev/null; then
    warn "failed to update $runtime_file through masc runtime-default-set"
    return 1
  fi
  log "set [runtime].default = \"$runtime_id\" in $runtime_file"
}

ping_provider() {
  local idx="$1" key="$2"
  local endpoint="${PROVIDER_ENDPOINTS[$idx]}"
  local ping_path="${PROVIDER_PING_PATHS[$idx]}"
  local key_var
  key_var=$(provider_key_var "$idx")

  if [ -z "$ping_path" ]; then
    warn "provider $(provider_name "$idx") has no healthcheck.path in runtime.toml; skipping ping"
    return 0
  fi

  # Best-effort connectivity probe. The path is provider-owned runtime.toml
  # metadata so the installer does not guess protocol-specific probe URLs.
  local ping_url="${endpoint%/}${ping_path}"

  if [ -z "$key_var" ]; then
    if curl -fsS \
      --max-time "$MASC_INSTALL_PUBLIC_PING_TIMEOUT_S" \
      "$ping_url" >/dev/null 2>&1; then
      return 0
    else
      warn "could not reach $ping_url ($(provider_name "$idx") may not be running)"
      return 1
    fi
  fi

  validate_provider_key "$key" "$key_var"

  # Feed the bearer header through an anonymous fd so the key is not written to
  # disk and does not appear in curl's process arguments.
  if ! curl -fsS --max-time "$MASC_INSTALL_AUTH_PING_TIMEOUT_S" \
    -H @<(printf 'Authorization: Bearer %s\n' "$key") \
    "$ping_url" >/dev/null 2>&1; then
    warn "provider ping failed for $(provider_name "$idx")"
    return 1
  fi
  return 0
}

run_wizard() {
  local base_path="$1"
  local provider_idx key
  load_provider_catalog "$base_path"

  if [ -n "$WIZARD_PROVIDER" ]; then
    provider_idx=$(provider_index_by_id "$WIZARD_PROVIDER") \
      || die "unknown provider: $WIZARD_PROVIDER"
  else
    provider_idx=$(prompt_provider)
  fi

  key=$(resolve_wizard_key "$provider_idx")

  update_runtime_default "$base_path" "${PROVIDER_DEFAULT_RUNTIME_IDS[$provider_idx]}" \
    || die "could not update runtime.toml default"
  write_env_local "$base_path" "$provider_idx" "$key"

  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  if ! is_tty; then
    return 0
  fi

  echo >&2
  printf '? Test connectivity to provider? [Y/n] ' >&2
  local answer
  read -r answer || true
  case "$answer" in
    [Nn]*) ;;
    *)
      if ping_provider "$provider_idx" "$key"; then
        log "provider ping: ok"
      else
        echo >&2
        printf '? Connectivity check failed. [retry/skip/abort] ' >&2
        local action
        read -r action || true
        case "$action" in
          retry|Retry|r) run_wizard "$base_path" ;;
          skip|Skip|s) ;;
          *) die "aborted by user" ;;
        esac
      fi
      ;;
  esac
}

maybe_run_wizard() {
  local base_path="$1"
  local env_file="$base_path/.masc/config/.env.local"
  local runtime_file="$base_path/.masc/config/runtime.toml"

  if [ "$WIZARD" = "0" ]; then
    return 0
  fi

  if [ ! -e "$runtime_file" ]; then
    if [ "$WIZARD" = "1" ]; then
      die "runtime.toml not found; cannot run wizard (did you mean to seed config?)"
    fi
    log "runtime.toml not found; skipping first-time setup wizard"
    log "edit .masc/config/.env.local and .masc/config/runtime.toml to finish setup"
    return 0
  fi

  if [ -e "$env_file" ] && [ "$FORCE" -eq 0 ]; then
    if [ "$WIZARD" = "1" ] && is_tty; then
      echo >&2
      printf '? %s already exists. Overwrite? [y/N] ' "$env_file" >&2
      local answer
      read -r answer || true
      case "$answer" in
        [Yy]*) ;;
        *) log "keeping existing $env_file; skipping wizard" >&2; return 0 ;;
      esac
    else
      log "$env_file already exists; skipping first-time setup wizard"
      log "edit .masc/config/.env.local and .masc/config/runtime.toml to change provider or key"
      return 0
    fi
  fi

  if ! is_tty; then
    if [ -z "$WIZARD_PROVIDER" ]; then
      if [ "$WIZARD" = "1" ]; then
        die "cannot run wizard in non-TTY shell without --provider (use --provider with --api-key/env, or --no-wizard)"
      fi
      log "non-interactive shell detected; skipping first-time setup wizard"
      log "edit .masc/config/.env.local and .masc/config/runtime.toml to finish setup"
      return 0
    fi
  fi
  run_wizard "$base_path"
}

is_tty() { [ -t 0 ] && [ -t 1 ]; }

c_red=$(printf '\033[31m'); c_yel=$(printf '\033[33m'); c_grn=$(printf '\033[32m')
c_dim=$(printf '\033[2m'); c_off=$(printf '\033[0m')
[ -t 1 ] || { c_red=""; c_yel=""; c_grn=""; c_dim=""; c_off=""; }

log()  { printf '%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%swarn:%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

require_flag_value() {
  local flag="$1" value="${2:-}"
  [ -n "$value" ] || die "$flag requires a value"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) require_flag_value "$1" "${2-}"; VERSION="$2"; shift 2 ;;
    --prefix)  require_flag_value "$1" "${2-}"; PREFIX="$2";  shift 2 ;;
    --base-path) require_flag_value "$1" "${2-}"; BASE_PATH="$2"; shift 2 ;;
    --no-seed) SEED_CONFIG=0; shift ;;
    --force)   FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-unverified) ALLOW_UNVERIFIED=1; shift ;;
    --wizard)      WIZARD=1; shift ;;
    --no-wizard)   WIZARD=0; shift ;;
    --provider)    require_flag_value "$1" "${2-}"; WIZARD_PROVIDER="$2"; shift 2 ;;
    --api-key)     require_flag_value "$1" "${2-}"; WIZARD_API_KEY="$2"; shift 2 ;;
    --api-key-stdin) WIZARD_API_KEY_STDIN=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

if [ "$WIZARD_API_KEY_STDIN" -eq 1 ]; then
  [ -z "$WIZARD_API_KEY" ] || die "--api-key and --api-key-stdin are mutually exclusive"
  if IFS= read -r -s WIZARD_API_KEY || [ -n "$WIZARD_API_KEY" ]; then
    [ -n "$WIZARD_API_KEY" ] || die "--api-key-stdin requires a non-empty key on stdin"
  else
    die "--api-key-stdin requires one key on stdin"
  fi
fi

case "$ALLOW_UNVERIFIED" in
  0|1) ;;
  *) die "MASC_ALLOW_UNVERIFIED must be 0 or 1" ;;
esac

case "$WIZARD" in
  auto|0|1) ;;
  *) die "MASC_WIZARD must be auto, 0, or 1" ;;
esac

[ -z "$BASE_PATH" ] && BASE_PATH="$PWD"
MODEL_CATALOG_FILE="$BASE_PATH/.masc/config/oas-models.toml"

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
require curl
require uname
require chmod
require mkdir
require mktemp

# --- checksum helpers ---------------------------------------------------------
has_sha256sum() { command -v sha256sum >/dev/null 2>&1; }
has_shasum()    { command -v shasum    >/dev/null 2>&1; }

sha256_file() {
  if has_sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif has_shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo ""
  fi
}

expected_hash() {
  local file="$1"
  awk -v f="$file" '$2 == f {print $1; exit}' "$CHECKSUMS_FILE"
}

verify_checksum() {
  local file="$1" name="$2"
  [ "$CHECKSUMS_FETCHED" -eq 1 ] || fetch_release_checksums
  if [ "$CHECKSUMS_AVAILABLE" -ne 1 ]; then
    [ "$ALLOW_UNVERIFIED" = "1" ] \
      || die "release checksums unavailable; refusing to install unverified $name (pass --allow-unverified or set MASC_ALLOW_UNVERIFIED=1 to override)"
    warn "skipping checksum for $name because unverified install override is enabled"
    return 0
  fi
  local expected actual
  expected=$(expected_hash "$name")
  if [ -z "$expected" ]; then
    die "no checksum entry for $name in SHA256SUMS"
  fi
  actual=$(sha256_file "$file")
  if [ -z "$actual" ]; then
    die "cannot compute sha256 for $name (missing sha256sum/shasum)"
  fi
  if [ "$actual" != "$expected" ]; then
    die "checksum mismatch for $name (expected $expected, got $actual)"
  fi
  log "verified $name checksum"
}

# --- 1. detect platform -------------------------------------------------------
detect_asset() {
  local os arch
  os=$(uname -s); arch=$(uname -m)
  case "$os/$arch" in
    Darwin/arm64)  echo "masc-macos-arm64" ;;
    Linux/x86_64)  echo "masc-linux-x64"   ;;
    Darwin/x86_64) die "macOS x86_64 release asset not built. Build from source per README." ;;
    Linux/aarch64) die "Linux arm64 release asset not built yet. Track .github/workflows/release.yml." ;;
    *) die "unsupported platform: $os/$arch" ;;
  esac
}

ASSET=$(detect_asset)
log "platform: $ASSET"


# --- 2. resolve version -------------------------------------------------------
resolve_version() {
  if [ -n "$VERSION" ]; then echo "$VERSION"; return; fi
  log "resolving latest release from github.com/$REPO ..." >&2
  local api="https://api.github.com/repos/$REPO/releases/latest"
  local tag
  if command -v jq >/dev/null 2>&1; then
    tag=$(curl -fsSL \
      --max-time "$MASC_INSTALL_RELEASE_METADATA_TIMEOUT_S" \
      --retry "$MASC_INSTALL_CURL_RETRIES" \
      "$api" | jq -er '.tag_name // empty') \
      || die "could not parse latest release tag from GitHub API response"
  else
    tag=$(curl -fsSL \
      --max-time "$MASC_INSTALL_RELEASE_METADATA_TIMEOUT_S" \
      --retry "$MASC_INSTALL_CURL_RETRIES" \
      "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    [ -n "$tag" ] || die "could not parse latest release tag from GitHub API response (fallback regex failed)"
  fi
  echo "$tag"
}

VERSION=$(resolve_version)
[ -n "$VERSION" ] || die "could not resolve version (network or rate limit?)"
log "version: $VERSION"

# --- 2b. fetch release checksums ----------------------------------------------
CHECKSUMS_FILE="$(mktemp)"
cleanup_install_temp_files() {
  rm -f "$CHECKSUMS_FILE"
  [ -z "${CATALOG_FILE:-}" ] || rm -f "$CATALOG_FILE"
  local partial
  if [ "${#PARTIAL_FILES[@]}" -gt 0 ]; then
    for partial in "${PARTIAL_FILES[@]}"; do
      [ -z "$partial" ] || rm -f "$partial"
    done
  fi
}
trap cleanup_install_temp_files EXIT
CHECKSUMS_AVAILABLE=0
CHECKSUMS_FETCHED=0
CHECKSUMS_URL="https://github.com/$REPO/releases/download/$VERSION/SHA256SUMS"
fetch_release_checksums() {
  [ "$CHECKSUMS_FETCHED" -eq 0 ] || return 0
  CHECKSUMS_FETCHED=1
  # In unverified/dry-run mode, suppress curl network chatter so it does not
  # pollute the structured install log or the test ratchet.
  local curl_stderr="/dev/stderr"
  if [ "$ALLOW_UNVERIFIED" = "1" ] || [ "$DRY_RUN" -eq 1 ]; then
    curl_stderr="/dev/null"
  fi
  if curl -fsSL \
    --max-time "$MASC_INSTALL_RELEASE_METADATA_TIMEOUT_S" \
    --retry "$MASC_INSTALL_CURL_RETRIES" \
    -o "$CHECKSUMS_FILE" \
    "$CHECKSUMS_URL" 2>"$curl_stderr"; then
    CHECKSUMS_AVAILABLE=1
  elif [ "$ALLOW_UNVERIFIED" = "1" ]; then
    warn "could not fetch release checksums ($CHECKSUMS_URL); continuing because unverified install override is enabled"
  else
    die "could not fetch release checksums ($CHECKSUMS_URL); refusing unverified install (pass --allow-unverified or set MASC_ALLOW_UNVERIFIED=1 to override)"
  fi
}

# --- 3. download binary -------------------------------------------------------
URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
DEST="$PREFIX/masc"

model_catalog_env_value() {
  if [ -n "${OAS_MODEL_CATALOG:-}" ]; then
    echo "$OAS_MODEL_CATALOG"
  elif [ -e "$MODEL_CATALOG_FILE" ]; then
    echo "$MODEL_CATALOG_FILE"
  else
    echo ""
  fi
}

run_masc_with_install_env() {
  local catalog
  catalog=$(model_catalog_env_value)
  # MASC_BASE_PATH is the resolved runtime root. MASC_BASE_PATH_INPUT mirrors
  # the explicit --base-path input for bootstrap/diagnostic readers that report
  # the operator-provided path before the runtime finishes normalizing config.
  if [ -n "$catalog" ]; then
    MASC_BASE_PATH="$BASE_PATH" \
      MASC_BASE_PATH_INPUT="$BASE_PATH" \
      OAS_MODEL_CATALOG="$catalog" \
      MASC_RUNTIME_EVENTS="${MASC_RUNTIME_EVENTS:-0}" \
      "$@"
  else
    MASC_BASE_PATH="$BASE_PATH" \
      MASC_BASE_PATH_INPUT="$BASE_PATH" \
      MASC_RUNTIME_EVENTS="${MASC_RUNTIME_EVENTS:-0}" \
      "$@"
  fi
}

masc_responds_to_version() {
  local bin="$1"
  run_masc_with_install_env "$bin" --version >/dev/null 2>&1
}

masc_reported_version() {
  local bin="$1"
  run_masc_with_install_env "$bin" --version 2>/dev/null | tail -n1
}

SKIP_DL=0
if [ -e "$DEST" ]; then
  # The pipeline `... | tail -n1` masks the binary's own exit status, so
  # ask the binary directly first, then capture its output.
  if masc_responds_to_version "$DEST"; then
    existing_ver=$(masc_reported_version "$DEST")
    if [ "$existing_ver" = "${VERSION#v}" ]; then
      log "already at $VERSION ($DEST), skipping download"
      SKIP_DL=1
    elif [ "$FORCE" -eq 0 ]; then
      warn "existing $DEST is version $existing_ver, target is ${VERSION#v}; pass --force to overwrite"
      exit 1
    else
      warn "existing $DEST is version $existing_ver, target is ${VERSION#v}; overwriting because --force is set"
    fi
  elif [ "$FORCE" -eq 0 ]; then
    warn "$DEST exists but does not respond to --version; pass --force to overwrite"
    exit 1
  else
    warn "$DEST exists but does not respond to --version; overwriting because --force is set"
  fi
fi

if [ "$SKIP_DL" -ne 1 ]; then
  log "downloading $URL"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would download to $DEST"
  else
    mkdir -p "$PREFIX"
    tmp="$DEST.partial"
    PARTIAL_FILES+=("$tmp")
    fetch_release_checksums
    curl -fL \
      --max-time "$MASC_INSTALL_BINARY_DOWNLOAD_TIMEOUT_S" \
      --retry "$MASC_INSTALL_CURL_RETRIES" \
      --progress-bar \
      -o "$tmp" \
      "$URL" \
      || die "download failed (asset missing for $VERSION?)"
    verify_checksum "$tmp" "$ASSET"
    chmod +x "$tmp"
    mv "$tmp" "$DEST"
    log "installed: $DEST"
  fi
fi

# --- 4. seed minimum config ---------------------------------------------------
if [ "$SEED_CONFIG" -eq 1 ]; then
  CONFIG_DIR="$BASE_PATH/.masc/config"
  CONFIG_FILE="$CONFIG_DIR/tool_policy.toml"
  RUNTIME_FILE="$CONFIG_DIR/runtime.toml"
  MODEL_CATALOG_FILE="$CONFIG_DIR/oas-models.toml"

  if [ -e "$CONFIG_FILE" ] && [ -e "$RUNTIME_FILE" ] && [ -e "$MODEL_CATALOG_FILE" ] && [ "$FORCE" -eq 0 ]; then
    log "config already present at $CONFIG_DIR, skipping seed"
  elif [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would seed configs and model catalog to $CONFIG_DIR from release"
  else
    log "seeding configs and model catalog to $CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"

    seed_raw() {
      local raw_path="$1" name="$2" dest="$3"
      local raw="https://raw.githubusercontent.com/$REPO/$VERSION/$raw_path"
      local tmp="$dest.partial"
      PARTIAL_FILES+=("$tmp")
      fetch_release_checksums
      curl -fsSL \
        --max-time "$MASC_INSTALL_CONFIG_FETCH_TIMEOUT_S" \
        --retry "$MASC_INSTALL_CURL_RETRIES" \
        -o "$tmp" \
        "$raw" \
        || die "config seed failed (raw fetch from $raw)"
      verify_checksum "$tmp" "$name"
      mv "$tmp" "$dest"
    }

    seed_raw_if_missing() {
      local raw_path="$1" name="$2" dest="$3"
      if [ -e "$dest" ] && [ "$FORCE" -eq 0 ]; then
        log "config already present: $dest, skipping seed"
      else
        seed_raw "$raw_path" "$name" "$dest"
      fi
    }

    seed_config_if_missing() {
      local name="$1" dest="$2"
      seed_raw_if_missing "config/$name" "$name" "$dest"
    }

    seed_config_if_missing "tool_policy.toml" "$CONFIG_FILE"
    seed_config_if_missing "runtime.toml" "$RUNTIME_FILE"
    seed_raw_if_missing "oas-models.toml" "oas-models.toml" "$MODEL_CATALOG_FILE"
  fi
fi

# --- 4b. first-run wizard ------------------------------------------------------
maybe_run_wizard "$BASE_PATH"

# --- 5. smoke check -----------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
  if masc_responds_to_version "$DEST"; then
    reported=$(masc_reported_version "$DEST")
    [ "$reported" = "${VERSION#v}" ] \
      || warn "binary reports $reported, expected ${VERSION#v}"
  else
    die "binary did not respond to --version"
  fi
fi

# --- 6. PATH guidance ---------------------------------------------------------
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) warn "$PREFIX is not in PATH. Add this to your shell rc:
      export PATH=\"$PREFIX:\$PATH\"" ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\n%s[dry-run] no files written.%s\n\n' "$c_yel" "$c_off"
  exit 0
fi

source_hint=""
if [ -e "$BASE_PATH/.masc/config/.env.local" ]; then
  source_hint="source \"$BASE_PATH/.masc/config/.env.local\""
else
  source_hint="# .env.local was not created; configure provider key manually if needed"
fi

catalog_hint=$(model_catalog_env_value)
# Keep the copy-paste start command aligned with runtime base/catalog env, but
# do not default-disable Runtime_events. If the operator supplied an override,
# preserve it; otherwise let the binary's default-on contract apply.
runtime_events_start_env=""
if [ "${MASC_RUNTIME_EVENTS+x}" = "x" ]; then
  runtime_events_start_env="MASC_RUNTIME_EVENTS=\"$MASC_RUNTIME_EVENTS\" "
fi
start_env="${runtime_events_start_env}MASC_BASE_PATH=\"$BASE_PATH\" MASC_BASE_PATH_INPUT=\"$BASE_PATH\""
if [ -n "$catalog_hint" ]; then
  start_env="OAS_MODEL_CATALOG=\"$catalog_hint\" $start_env"
fi

cat <<EOF

${c_grn}masc ${VERSION} installed.${c_off}

Next:
  ${c_dim}# load provider key${c_off}
  $source_hint

  ${c_dim}# start server (loopback only)${c_off}
  $start_env $DEST --base-path "$BASE_PATH"

  ${c_dim}# if you need to change provider or key later, edit:${c_off}
  #   $BASE_PATH/.masc/config/.env.local
  #   $BASE_PATH/.masc/config/runtime.toml

  ${c_dim}# sanity check${c_off}
  curl http://127.0.0.1:${MASC_PORT}/health

  ${c_dim}# wire up your MCP client (local agent)${c_off}
  See: https://github.com/$REPO#mcp-client-setup

EOF
