#!/usr/bin/env bash
# masc installer — download prebuilt binary, seed runtime config/catalog, smoke-check.
#
# Usage:
#   TAG=vX.Y.Z
#   curl -fsSL "https://raw.githubusercontent.com/jeong-sik/masc/$TAG/scripts/install.sh" -o /tmp/masc-install.sh
#   bash /tmp/masc-install.sh --version "$TAG"
#
# Flags:
#   --version vX.Y.Z   Pin a specific release (default: latest)
#   --prefix DIR       Install dir for the binary (default: $HOME/.local/bin)
#   --base-path DIR    Workspace containing .masc (asked in a terminal;
#                      noninteractive default: $PWD)
#   --no-seed          Skip writing default config files
#   --force            Refresh existing binaries; preserve workspace config
#   --reset-config     Overwrite seeded config and selected team preset files
#   --dry-run          Print what would happen, do not write
#   --uninstall        Remove installed executables/releases; stop MASC first
#   --purge-data       Also remove <base-path>/.masc; requires --uninstall and
#                      an explicit --base-path. External runtime installations remain.
#   --allow-unverified Continue if SHA256SUMS cannot be fetched (unsafe)
#   --wizard           Always run the first-time provider setup wizard
#   --no-wizard        Skip interactive setup and shell PATH prompts
#   --shell-path SHELL Enable PATH in zsh or bash startup files (or none);
#                      default: ask in an interactive wizard
#   --no-guest-shim    Do not place the guest exec shim (masc-exec-shim) and its
#                      sha256 sidecar under <base-path>/.masc/microvm/shim; a
#                      host that boots no microvm keeper needs neither
#   --provider ID      Select a provider, including on an existing workspace
#                      (e.g. deepseek; incompatible with --no-wizard)
#   --team PRESET      Seed a keeper team preset (e.g. classic) into the config
#   --sandbox PROFILE  Set the seeded team keepers' sandbox_profile
#                        (docker|microvm|remote_ssh; use with --team)
#                      root so the named keepers autoboot on the default model.
#                      Requires a release/branch that ships presets/<PRESET>/.
#
# Env:
#   MASC_VERSION   Same as --version
#   MASC_PREFIX    Same as --prefix
#   MASC_REPO      Override repo (default: jeong-sik/masc)
#   MASC_PORT      Port used in the post-install local-start hint (default: 8935)
#   MASC_ALLOW_UNVERIFIED=1  Same as --allow-unverified
#   MASC_RELEASE_BASE_URL  Override the release asset base URL (mirror or
#                  air-gapped install; file:// works). Defaults to
#                  https://github.com/<repo>/releases/download
#   AGENT_CORE_MODEL_CATALOG  Explicit full model catalog override. When unset, AGENT_CORE's
#                  embedded catalog is merged with the deployment overlay.
#   MASC_RUNTIME_EVENTS=0/1  Override OCaml Runtime_events. When unset, the
#                  generated server command keeps the binary's default.
#   MASC_WIZARD=0/1  Same as --no-wizard / --wizard
#   MASC_INSTALL_NO_PING=1  Skip the non-interactive wizard's connectivity check
#                  (air-gapped/offline installs). The check is report-only and
#                  never fails the install; this only silences it.
#   <PROVIDER_API_KEY>  Provider key env declared by runtime.toml credentials.key.
#                  Read, never written: the wizard reports whether it is set and
#                  pings with it, and the key stays in your shell. This script
#                  writes no secret to disk.

set -euo pipefail

REPO="${MASC_REPO:-jeong-sik/masc}"
RELEASE_BASE_URL="${MASC_RELEASE_BASE_URL:-https://github.com/$REPO/releases/download}"
VERSION="${MASC_VERSION:-}"
PREFIX="${MASC_PREFIX:-$HOME/.local/bin}"
MASC_PORT="${MASC_PORT:-8935}"
BASE_PATH=""
SEED_CONFIG=1
FORCE=0
RESET_CONFIG=0
DRY_RUN=0
UNINSTALL=0
PURGE_DATA=0
BASE_PATH_EXPLICIT=0
INSTALL_ACTION_FLAGS=()
GUEST_SHIM=1
ALLOW_UNVERIFIED="${MASC_ALLOW_UNVERIFIED:-0}"
WIZARD="${MASC_WIZARD:-auto}"
WIZARD_PROVIDER=""
SHELL_PATH_MODE=auto
RUN_SETUP_JOURNEY=0
# Whether the config root was already here before this run. This is what makes
# the setup wizard a first-time step rather than one that runs on every install.
CONFIG_PREEXISTING=0
TEAM="${MASC_TEAM_PRESET:-}"
WIZARD_SANDBOX="${MASC_SANDBOX_PROFILE:-}"

# Installer network budgets are script-local SSOTs. Keep them explicit instead
# of scattering bare curl numbers across release lookup, config seeding, and
# provider pings.
readonly MASC_INSTALL_PUBLIC_PING_TIMEOUT_S=5
readonly MASC_INSTALL_AUTH_PING_TIMEOUT_S=10
# The wizard probes every local model server up front to report which are
# running, so this ceiling is kept short: a closed loopback port refuses
# instantly, and a hung one should not stall the whole detection sweep.
readonly MASC_INSTALL_LOCAL_PROBE_TIMEOUT_S=2
readonly MASC_INSTALL_RELEASE_METADATA_TIMEOUT_S=30
readonly MASC_INSTALL_CONFIG_FETCH_TIMEOUT_S=60
readonly MASC_INSTALL_BINARY_DOWNLOAD_TIMEOUT_S=300
readonly MASC_INSTALL_CURL_RETRIES=3

# --- provider catalog ---------------------------------------------------------
# The catalog is a flat list of NUL-delimited records with no record separator,
# so every reader must know each record kind's field count. Two menu kinds
# share these parallel arrays: a "provider" reaches an HTTP endpoint with an
# env-var API key; a "subscription" is reached through its own CLI (Claude Code
# / Codex / Antigravity) and needs no key and no endpoint. PROVIDER_KINDS keeps
# them apart so the endpoint/key steps stay off the subscription path.
PROVIDER_IDS=()
PROVIDER_NAMES=()
PROVIDER_KEYS=()
PROVIDER_ENDPOINTS=()
PROVIDER_PING_PATHS=()
PROVIDER_DEFAULT_RUNTIME_IDS=()
PROVIDER_KINDS=()
PROVIDER_COMMANDS=()
# Availability label per provider, computed once so the report and the default
# preference below do not each re-run the (subprocess) probes.
PROVIDER_AVAIL=()
PROVIDER_INDEX_RESULT=""
DEFAULT_PROVIDER_INDEX=0
CATALOG_FILE=""
PARTIAL_FILES=()
COMPANION_ARGS=()
BUNDLE_HELPER=""
BUNDLE_TRANSACTION_ACTIVE=0
DASHBOARD_ASSETS_DIR=""

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
  PROVIDER_KINDS=()
  PROVIDER_COMMANDS=()
  PROVIDER_AVAIL=()
  DEFAULT_PROVIDER_INDEX=0

  local kind id name key endpoint ping_path runtime_id command default_provider_id="" missing_default_runtime_id=""
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
        PROVIDER_KINDS+=("provider")
        PROVIDER_COMMANDS+=("")
        ;;
      subscription)
        # A subscription runtime signs in through its own CLI, so it carries no
        # API key and no endpoint. It joins the same menu as a keyless entry;
        # the empty key and endpoint keep it off the key and ping paths,
        # and $command is what the wizard probes with `command -v`.
        read_catalog_field id
        read_catalog_field name
        read_catalog_field command
        read_catalog_field runtime_id
        [ -n "${id:-}" ] || die "provider wizard catalog has empty subscription id"
        [ -n "${name:-}" ] || die "provider wizard catalog has empty display name for $id"
        [ -n "${runtime_id:-}" ] || die "provider wizard catalog has empty runtime id for $id"
        PROVIDER_IDS+=("$id")
        PROVIDER_NAMES+=("$name")
        PROVIDER_KEYS+=("")
        PROVIDER_ENDPOINTS+=("")
        PROVIDER_PING_PATHS+=("")
        PROVIDER_DEFAULT_RUNTIME_IDS+=("$runtime_id")
        PROVIDER_KINDS+=("subscription")
        PROVIDER_COMMANDS+=("${command:-}")
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
    # A subscription has no endpoint by design; only HTTP providers must carry one.
    if [ "${PROVIDER_KINDS[$idx]}" = "provider" ]; then
      [ -n "${PROVIDER_ENDPOINTS[$idx]}" ] \
        || die "provider ${PROVIDER_IDS[$idx]} in runtime.toml has no endpoint"
    fi
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

# A loopback endpoint is a model server running on this machine, so "is it up?"
# is a meaningful question. A remote/cloud endpoint is always routable and its
# gate is the API key instead, so the wizard does not probe those for liveness.
endpoint_is_local() {
  case "$1" in
    *://localhost:* | *://localhost/* | *://localhost \
    | *://127.0.0.1:* | *://127.0.0.1/* | *://127.0.0.1 \
    | *://0.0.0.0:* | *://0.0.0.0/* | *://0.0.0.0 \
    | *://\[::1\]:* | *://\[::1\]/* | *://\[::1\]) return 0 ;;
    *) return 1 ;;
  esac
}

# Best-effort, unauthenticated liveness probe of a local server's healthcheck
# path. Exit 0 means the server answered. A closed loopback port refuses at
# once, so this does not wait out the timeout for servers that are simply down.
probe_local_reachable() {
  local idx="$1"
  local endpoint="${PROVIDER_ENDPOINTS[$idx]}"
  local ping_path="${PROVIDER_PING_PATHS[$idx]}"
  curl -fsS --max-time "$MASC_INSTALL_LOCAL_PROBE_TIMEOUT_S" \
    "${endpoint%/}${ping_path}" >/dev/null 2>&1
}

# One word describing whether this entry is ready to use right now:
#   reachable / authentication required / unreachable -- local HTTP endpoint
#   installed / not installed -- a subscription CLI, checked with command -v
#   cloud                     -- a remote provider, gated by its API key
#   local                     -- a local server with no healthcheck path to probe
provider_availability_label() {
  local idx="$1"
  case "${PROVIDER_KINDS[$idx]}" in
    subscription)
      local cmd="${PROVIDER_COMMANDS[$idx]}"
      if [ -z "$cmd" ] || ! command -v "$cmd" >/dev/null 2>&1; then
        echo "not installed"
      else
        # Installed -- also ask its own CLI whether it is signed in. A login
        # check has no drift-safe shell form, so it goes through the masc
        # runtime-probe subcommand, which reuses the server's official-client
        # login probe. 0=signed in, 1=not signed in; anything else (probe not
        # applicable) leaves it at the plain "installed" the CLI presence proved.
        local probe_status=0
        "$DEST" runtime-probe --base-path "$BASE_PATH" \
          "${PROVIDER_DEFAULT_RUNTIME_IDS[$idx]}" >/dev/null 2>&1 || probe_status=$?
        case "$probe_status" in
          0) echo "installed, signed in" ;;
          1) echo "installed, not signed in" ;;
          *) echo "installed" ;;
        esac
      fi
      ;;
    *)
      if endpoint_is_local "${PROVIDER_ENDPOINTS[$idx]}"; then
        if [ -z "${PROVIDER_PING_PATHS[$idx]}" ]; then
          echo "local"
        else
          local status
          if status=$(curl -sS --max-time "$MASC_INSTALL_LOCAL_PROBE_TIMEOUT_S" \
            -o /dev/null -w '%{http_code}' \
            "${PROVIDER_ENDPOINTS[$idx]%/}${PROVIDER_PING_PATHS[$idx]}" 2>/dev/null); then
            case "$status" in
              2??) echo "reachable" ;;
              401|403) echo "authentication required" ;;
              *) echo "responding, HTTP $status" ;;
            esac
          else
            echo "unreachable"
          fi
        fi
      else
        echo "cloud"
      fi
      ;;
  esac
}

# The "detect" half of detect-then-skip: before choosing, print what is ready.
# Runs on every wizard invocation (including --dry-run and --provider), so the
# operator sees which local servers are up and which subscriptions are signed
# in before anything is written.
# Probe every source once and cache the label, so the report and the default
# preference share one pass instead of each spawning the probes again.
compute_provider_availability() {
  PROVIDER_AVAIL=()
  local i
  for i in "${!PROVIDER_IDS[@]}"; do
    PROVIDER_AVAIL[i]="$(provider_availability_label "$i")"
  done
}

# "green" = ready to serve a turn right now: a reachable local server, a signed-in
# subscription, or a cloud provider whose API key is already in the environment
# (a keyless cloud entry counts as ready). Everything else needs a step first.
provider_is_green() {
  local idx="$1"
  case "${PROVIDER_AVAIL[$idx]}" in
    reachable | "installed, signed in")
      return 0
      ;;
    cloud)
      local key_var="${PROVIDER_KEYS[$idx]}"
      [ -z "$key_var" ] && return 0
      provider_env_key "$key_var" >/dev/null 2>&1 && return 0
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

report_provider_availability() {
  log "detected model sources:"
  local i
  for i in "${!PROVIDER_IDS[@]}"; do
    log "  - ${PROVIDER_NAMES[$i]}: ${PROVIDER_AVAIL[$i]}"
  done
}

# Pre-select a source that actually works. If the configured default is already
# green, keep it; otherwise move the menu default to the first green source, so a
# fresh install does not open on a dead default the operator then has to change.
# This only moves which entry the menu pre-selects -- an explicit --provider
# still wins, and the operator can still pick any listed source.
prefer_available_default() {
  provider_is_green "$DEFAULT_PROVIDER_INDEX" && return 0
  local i
  for i in "${!PROVIDER_IDS[@]}"; do
    if provider_is_green "$i"; then
      [ "$i" -eq "$DEFAULT_PROVIDER_INDEX" ] || \
        log "default source ${PROVIDER_NAMES[$DEFAULT_PROVIDER_INDEX]} is not ready; pre-selecting ${PROVIDER_NAMES[$i]}"
      DEFAULT_PROVIDER_INDEX="$i"
      return 0
    fi
  done
}

# Prints the index of the one ready ("green") source, or nothing when zero or
# more than one are ready. "Exactly one" is the only unambiguous choice, so it is
# the only case the wizard makes for the operator without a terminal or a
# --provider (RFC-0408 zero-config). Zero or several stays a question.
single_green_index() {
  local found="" i
  for i in "${!PROVIDER_IDS[@]}"; do
    if provider_is_green "$i"; then
      [ -n "$found" ] && return 0
      found="$i"
    fi
  done
  printf '%s' "$found"
}

# The second axis: where a keeper's tools execute. Unlike the model source, the
# sandbox has no install-time global default to write -- it is per-keeper, in
# .masc/config/keepers/<name>.toml, and a --team preset carries its own choice.
# So this only reports which backends the host can offer, and points at where
# the choice is actually made. The three real backends are docker, microvm
# (Apple's `container` CLI on macOS), and remote_ssh.
report_sandbox_backends() {
  log "detected execution sandboxes (set per keeper, not here):"

  if command -v docker >/dev/null 2>&1; then
    # docker info fails fast when the daemon socket is absent, so this does not
    # hang when Docker is installed but not running.
    if docker info >/dev/null 2>&1; then
      log "  - docker: available"
    else
      log "  - docker: installed, daemon not responding"
    fi
  else
    log "  - docker: not installed"
  fi

  if [ -e /System/Library/CoreServices/SystemVersion.plist ]; then
    if command -v container >/dev/null 2>&1; then
      log "  - microvm (apple container): available"
    else
      log "  - microvm (apple container): not installed"
    fi
  else
    log "  - microvm (apple container): macOS only"
  fi

  # remote_ssh is transport-only; its endpoints live in runtime.toml, so host
  # detection is not meaningful -- point at where they are declared instead.
  log "  - remote_ssh: declare endpoints in runtime.toml [exec.ssh.endpoints]"
  log "  choose one per keeper via sandbox_profile in .masc/config/keepers/<name>.toml,"
  log "  or --team <preset> (add --sandbox docker|microvm|remote_ssh to set the team's)"
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
      if [ "${PROVIDER_KINDS[$i]}" = "subscription" ]; then
        printf >&2 ' - uses %s login' "$(basename "${PROVIDER_COMMANDS[$i]:-its CLI}")"
      elif [ -n "${PROVIDER_KEYS[$i]}" ]; then
        printf >&2 ' - needs %s' "${PROVIDER_KEYS[$i]}"
      fi
      printf >&2 ' [%s; id: %s]\n' "${PROVIDER_AVAIL[$i]}" "${PROVIDER_IDS[$i]}"
    done
    printf >&2 '> '
    local choice
    if ! read_terminal_line choice; then
      warn "input closed; provider selection cancelled"
      return 1
    fi
    if [ -z "$choice" ]; then
      echo "$DEFAULT_PROVIDER_INDEX"
      return
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
      warn "please enter a number"
      continue
    fi
    # Match displayed choices, without evaluating unbounded input as arithmetic.
    for idx in "${!PROVIDER_IDS[@]}"; do
      if [ "$choice" = "$((idx + 1))" ]; then
        echo "$idx"
        return
      fi
    done
    warn "invalid choice"
  done
}

# The key the server will use, read from this shell's environment. The installer
# never asks for one and never stores one: the server resolves its credential
# from the environment it is started in, so that environment is the only place a
# key can be checked and the only place it needs to be.
wizard_env_key() {
  local idx="$1"
  local key_var
  key_var=$(provider_key_var "$idx")
  [ -n "$key_var" ] || return 0
  printf '%s' "${!key_var:-}"
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

  local lane_args=()
  [ "$CONFIG_PREEXISTING" -eq 1 ] || lane_args=(--setup-lanes)
  # macOS ships bash 3.2, where `set -u` treats an empty array's expansion as
  # unbound. This array is empty on exactly the path an existing workspace
  # takes, so the plain form aborts the installer there. Same guard as the
  # companion/runtime args below.
  if ! "$DEST" runtime-default-set --base-path "$base_path" "$runtime_id" \
    ${lane_args[@]+"${lane_args[@]}"} >/dev/null; then
    warn "failed to update $runtime_file through masc runtime-default-set"
    return 1
  fi
  log "set [runtime].default = \"$runtime_id\" in $runtime_file"
}

# Whether a ping would test anything. A provider with no key variable has a
# public healthcheck; one with a key variable can only be reached with the key,
# and the installer only has it when the operator exported it.
provider_ping_possible() {
  local idx="$1" key="$2" key_var
  key_var=$(provider_key_var "$idx")
  if [ "${PROVIDER_KINDS[$idx]}" = "subscription" ]; then
    return 0
  fi
  [ -n "${PROVIDER_PING_PATHS[$idx]}" ] && { [ -z "$key_var" ] || [ -n "$key" ]; }
}

ping_provider() {
  local idx="$1" key="$2"
  local endpoint="${PROVIDER_ENDPOINTS[$idx]}"
  local ping_path="${PROVIDER_PING_PATHS[$idx]}"
  local key_var
  key_var=$(provider_key_var "$idx")

  # CLI presence alone does not prove that the subscription is signed in.
  if [ "${PROVIDER_KINDS[$idx]}" = "subscription" ]; then
    local cli_command="${PROVIDER_COMMANDS[$idx]}"
    if [ -z "$cli_command" ] || ! command -v "$cli_command" >/dev/null 2>&1; then
      warn "$(provider_name "$idx") CLI is not installed; install and sign in before using it"
      return 1
    fi
    local probe_status=0
    "$DEST" runtime-probe --base-path "$BASE_PATH" \
      "${PROVIDER_DEFAULT_RUNTIME_IDS[$idx]}" >/dev/null 2>&1 || probe_status=$?
    case "$probe_status" in
      0) return 0 ;;
      3) return 3 ;; # runtime-probe explicitly reports unsupported
      *) warn "$(provider_name "$idx") sign-in check did not pass; authenticate with its CLI"
         return 1 ;;
    esac
  fi

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

  # Callers decide whether a ping is possible ([provider_ping_possible]); an
  # empty key here would mean this one answered yes for a provider that needs a
  # key and has none, and a "ping" that tested nothing must not be reported as
  # either a pass or a failure.
  [ -n "$key" ] || die "internal: authenticated ping for $key_var without a key"

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

finish_setup_journey() {
  [ "$RUN_SETUP_JOURNEY" -eq 1 ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would open the installed workspace, model and sandbox setup journey"
    return 0
  fi
  # The journey asks for a model and a sandbox, so it needs the terminal the
  # workspace check already borrows: an installer read from a pipe leaves this
  # child reading the pipe, and the wizard reports a cancellation nobody asked for.
  if ! with_terminal_input "$DEST" setup --base-path "$BASE_PATH" --port "$MASC_PORT" >&2; then
    warn "MASC is installed; imp preparation is incomplete. Run masc setup to resume."
    return 1
  fi
}

run_wizard() {
  local base_path="$1"
  local provider_idx key source
  if [ -z "$WIZARD_PROVIDER" ] && is_tty; then
    RUN_SETUP_JOURNEY=1
    return
  fi
  load_provider_catalog "$base_path"
  compute_provider_availability
  report_provider_availability
  report_sandbox_backends

  if [ -n "$WIZARD_PROVIDER" ]; then
    provider_idx=$(provider_index_by_id "$WIZARD_PROVIDER") \
      || die "unknown provider: $WIZARD_PROVIDER"
  elif is_tty; then
    # A terminal is here to choose, so move the menu default onto a source that
    # is actually ready and let the operator confirm or change it.
    prefer_available_default
    provider_idx=$(prompt_provider) || die "provider selection cancelled"
  else
    # No terminal and no --provider. Make the choice only when it is not a
    # choice at all -- exactly one ready source; otherwise leave it to the
    # operator rather than guess between several or seed a dead default.
    local green_idx
    green_idx="$(single_green_index)"
    if [ -n "$green_idx" ]; then
      provider_idx="$green_idx"
      log "no terminal and no --provider; using the only ready source: ${PROVIDER_NAMES[$provider_idx]}"
    elif [ "$WIZARD" = "1" ]; then
      die "no terminal, no --provider, and not exactly one ready source; pass --provider or --no-wizard"
    else
      log "non-interactive shell and no single ready source; skipping first-time setup wizard"
      log "set [runtime].default in .masc/config/runtime.toml to finish setup"
      return 0
    fi
  fi

  # A local server that is not up will not answer once the default is set, so
  # say so plainly rather than leave the operator to discover it at first run.
  # The choice still stands: the server may just need to be started afterwards.
  if [ "${PROVIDER_KINDS[$provider_idx]}" = "provider" ] \
    && endpoint_is_local "${PROVIDER_ENDPOINTS[$provider_idx]}" \
    && [ -n "${PROVIDER_PING_PATHS[$provider_idx]}" ] \
    && ! probe_local_reachable "$provider_idx"; then
    warn "$(provider_name "$provider_idx") is not ready at ${PROVIDER_ENDPOINTS[$provider_idx]}; check its server and authentication before using masc"
  fi

  key=$(wizard_env_key "$provider_idx")

  update_runtime_default "$base_path" "${PROVIDER_DEFAULT_RUNTIME_IDS[$provider_idx]}" \
    || die "could not update runtime.toml default"

  # The one thing left for the operator, said once and named exactly. The
  # server reads this variable from its own environment, so a key that is not
  # there yet has to be exported where the server will be started.
  local key_var
  key_var=$(provider_key_var "$provider_idx")
  if [ -n "$key_var" ] && [ -z "$key" ]; then
    warn "$key_var is not set; export it in the shell that starts masc:"
    printf '    export %s=...\n' "$key_var" >&2
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  if ! is_tty; then
    # No terminal to prompt, so run the same connectivity check the interactive
    # path offers below -- but report-only. A first-run install must not fail on
    # an unreachable provider; it only surfaces the result so the operator learns
    # it here rather than at the first turn. This is the connectivity signal the
    # zero-config auto-select (RFC-0408) and any scripted --provider install
    # otherwise never got: the interactive path pinged, the non-TTY path returned
    # blind. A cloud provider is the case this most helps -- its "green" is only
    # "key is present", never "key works", so a wrong key used to surface only at
    # the first turn. Opt out with MASC_INSTALL_NO_PING=1 (air-gapped installs).
    if [ "${MASC_INSTALL_NO_PING:-0}" = "1" ]; then
      return 0
    fi
    if ! provider_ping_possible "$provider_idx" "$key"; then
      log "missing credential or healthcheck.path for $(provider_name "$provider_idx"); skipping the connectivity check"
    else
      local ping_status=0
      ping_provider "$provider_idx" "$key" || ping_status=$?
      case "$ping_status" in
        0) log "provider connectivity: ok" ;;
        3) log "login probe unavailable for $(provider_name "$provider_idx"); verify sign-in with its CLI" ;;
        *) warn "provider connectivity check did not pass; masc will retry at first turn" ;;
      esac
    fi
    return 0
  fi

  if ! provider_ping_possible "$provider_idx" "$key"; then
    log "missing credential or healthcheck.path for $(provider_name "$provider_idx"); skipping the connectivity check"
    return 0
  fi

  echo >&2
  printf '? Test connectivity to provider? [Y/n] ' >&2
  local answer
  read_terminal_line answer || true
  case "$answer" in
    [Nn]*) ;;
    *)
      local ping_status=0
      ping_provider "$provider_idx" "$key" || ping_status=$?
      case "$ping_status" in
        0) log "provider ping: ok" ;;
        3) log "login probe unavailable for $(provider_name "$provider_idx"); verify sign-in with its CLI" ;;
        *)
          echo >&2
          printf '? Connectivity check failed. [retry/skip/abort] ' >&2
          local action
          read_terminal_line action || true
          case "$action" in
            retry|Retry|r) run_wizard "$base_path" ;;
            skip|Skip|s) ;;
            *) die "aborted by user" ;;
          esac
          ;;
      esac
      ;;
  esac
}

maybe_run_wizard() {
  local base_path="$1"
  local runtime_file="$base_path/.masc/config/runtime.toml"

  if [ "$WIZARD" = "0" ]; then
    return 0
  fi

  if [ ! -e "$runtime_file" ]; then
    if [ "$WIZARD" = "1" ] || [ -n "$WIZARD_PROVIDER" ]; then
      die "runtime.toml not found; cannot run wizard (did you mean to seed config?)"
    fi
    log "runtime.toml not found; skipping first-time setup wizard"
    log "set [runtime].default in .masc/config/runtime.toml to finish setup"
    return 0
  fi

  # "First-time" means the config root was not already here. A workspace that was
  # already configured keeps the [runtime].default it has; --wizard or --reset-config
  # asks for the choice again.
  if [ "$CONFIG_PREEXISTING" -eq 1 ] && [ "$RESET_CONFIG" -eq 0 ] && [ "$WIZARD" != "1" ] && [ -z "$WIZARD_PROVIDER" ]; then
    log "config root was already here; skipping first-time setup wizard"
    log "run with --wizard to choose a provider again"
    return 0
  fi

  # The non-TTY, no --provider case is decided inside run_wizard now: it can
  # auto-select when exactly one source is ready (zero-config), and otherwise
  # skips or, under --wizard, errors -- the same outcomes as before, but only
  # after checking whether a choice was even needed.
  run_wizard "$base_path"
}

# Prompts use stderr; stdout is captured by $(prompt_provider).
is_tty() { [ -t 2 ] && { [ -t 0 ] || ( : </dev/tty ) 2>/dev/null; }; }

read_terminal_line() {
  if [ -t 0 ]; then IFS= read -r "$1"; else IFS= read -r "$1" </dev/tty; fi
}

with_terminal_input() {
  if [ -t 0 ] || ! is_tty; then "$@"; else "$@" </dev/tty; fi
}

choose_install_base_path() {
  [ -z "$BASE_PATH" ] || return 0
  local suggested="$PWD" answer
  if [ "$WIZARD" != "0" ] && is_tty; then
    [ -d "$PWD/.masc/config" ] || suggested="$HOME"
    printf '\nMASC stores configuration, Keepers and workspace data in <workspace>/.masc.\n' >&2
    printf '? Workspace directory [%s]: ' "$suggested" >&2
    read_terminal_line answer || die "workspace selection cancelled"
    BASE_PATH="${answer:-$suggested}"
  else
    BASE_PATH="$suggested"
  fi
}

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

configure_shell_path() {
  local mode="$SHELL_PATH_MODE" answer suggested
  if [ "$mode" = auto ]; then
    if [ "$WIZARD" = 0 ] || ! is_tty; then
      log "For new terminals, enable PATH with --shell-path zsh or --shell-path bash."
      return 0
    fi
    suggested=3
    case "${SHELL:-}" in */zsh|zsh) suggested=1 ;; */bash|bash) suggested=2 ;; esac
    printf '\nMake masc available in new terminals?\n  1) zsh\n  2) bash\n  3) Leave shell files unchanged\nChoice [%s]: ' "$suggested" >&2
    read_terminal_line answer || { warn "shell PATH setup deferred"; return 0; }
    case "${answer:-$suggested}" in 1) mode=zsh ;; 2) mode=bash ;; 3) mode=none ;; *) warn "shell PATH setup deferred: select zsh or bash with --shell-path"; return 0 ;; esac
  fi
  [ "$mode" != none ] || return 0
  [ "$DRY_RUN" -eq 0 ] || { log "[dry-run] would enable masc in $mode startup files"; return 0; }
  if python3 - "$HOME" "${ZDOTDIR:-}" "$PREFIX" "$mode" <<'PYSHELLPATH'
import fcntl, os, shlex, stat, sys, tempfile
from pathlib import Path
home, zdotdir, prefix, shell = sys.argv[1:]
start, end = b'# >>> MASC PATH >>>\n', b'# <<< MASC PATH <<<\n'

def owned_read(path):
    try:
        before = path.lstat()
    except FileNotFoundError:
        return None, b''
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid() or before.st_nlink != 1:
        raise ValueError('startup file must be an owned regular file, not a link')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        observed = os.fstat(fd)
        if (observed.st_dev, observed.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError('startup file changed')
        with os.fdopen(fd, 'rb', closefd=False) as handle:
            content = handle.read()
        after = os.fstat(fd)
        if (after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (observed.st_size, observed.st_mtime_ns, observed.st_ctime_ns):
            raise ValueError('startup file changed')
        return after, content
    finally:
        os.close(fd)

def sync_parent(path):
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def temporary(path, content, mode, suffix):
    fd, name = tempfile.mkstemp(prefix='.' + path.name + suffix, dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'wb') as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        os.unlink(name)
        raise
    return Path(name)

try:
    if any(c in prefix for c in ('\n', '\r', ':')) or not os.path.isabs(prefix):
        raise ValueError('installation directory cannot be represented as one PATH entry')
    root = Path(zdotdir or home) if shell == 'zsh' else Path(home)
    if not root.is_absolute() or not root.is_dir():
        raise ValueError('shell configuration directory must already exist')
    root = root.resolve(strict=True)
    parent_stat = root.stat()
    if parent_stat.st_uid != os.geteuid() or parent_stat.st_mode & 0o022:
        raise ValueError('shell configuration directory must be privately writable')
    if shell == 'zsh':
        targets = [root/'.zshrc']
    else:
        login = next((root/name for name in ('.bash_profile', '.bash_login', '.profile')
                      if os.path.lexists(root/name)), root/'.bash_profile')
        targets = [root/'.bashrc', login]
    # Quote the entire literal PATH entry; never expand $(), backticks or quotes
    # from an operator-selected installation directory when the shell starts.
    literal = shlex.quote(prefix)
    block = start + ('case ":$PATH:" in\n  *:' + literal + ':*) ;;\n  *) export PATH=' + literal + ':"$PATH" ;;\nesac\n').encode() + end
    for path in targets:
        lock_path = str(path) + '.masc-path.lock'
        lock = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            lock_stat = os.fstat(lock)
            if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_uid != os.geteuid() or lock_stat.st_nlink != 1:
                raise ValueError('untrusted shell configuration lock')
            fcntl.flock(lock, fcntl.LOCK_EX)
            before, old = owned_read(path)
            if start in old or end in old:
                if old.count(start) != 1 or old.count(end) != 1 or old.index(end) < old.index(start):
                    raise ValueError('ambiguous existing MASC PATH block; existing file preserved')
                first, last = old.index(start), old.index(end) + len(end)
                new = old[:first] + block + old[last:]
            else:
                new = old + (b'\n' if old and not old.endswith(b'\n') else b'') + block
            if new == old:
                continue
            backup = temporary(path, old, 0o600, '.masc-path-backup-') if before else None
            if backup:
                sync_parent(backup)
            staged = temporary(path, new, stat.S_IMODE(before.st_mode) if before else 0o600, '.masc-path-stage-')
            try:
                after, observed = owned_read(path)
                identity = lambda s: None if s is None else (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_mode, s.st_uid, s.st_nlink)
                if identity(after) != identity(before) or observed != old:
                    raise ValueError('startup file changed; backup retained')
                os.replace(staged, path)
                sync_parent(path)
            finally:
                if staged.exists():
                    staged.unlink()
            print('Enabled masc PATH in ' + str(path))
            if backup:
                print('Original shell file backup: ' + str(backup))
        finally:
            os.close(lock)
except (OSError, ValueError):
    print('Shell PATH setup did not finish. Existing backups were retained; inspect shell files before retrying.', file=sys.stderr)
    sys.exit(1)
PYSHELLPATH
  then log "Open a new terminal to use masc."; else warn "MASC is installed; shell PATH setup needs attention."; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall|--purge-data|--prefix|--base-path|--dry-run|-h|--help) ;;
    *) INSTALL_ACTION_FLAGS+=("$1") ;;
  esac
  case "$1" in
    --version) require_flag_value "$1" "${2-}"; VERSION="$2"; shift 2 ;;
    --prefix)  require_flag_value "$1" "${2-}"; PREFIX="$2";  shift 2 ;;
    --base-path) require_flag_value "$1" "${2-}"; BASE_PATH="$2"; BASE_PATH_EXPLICIT=1; shift 2 ;;
    --no-seed) SEED_CONFIG=0; shift ;;
    --force)   FORCE=1; shift ;;
    --reset-config) RESET_CONFIG=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge-data) PURGE_DATA=1; shift ;;
    --allow-unverified) ALLOW_UNVERIFIED=1; shift ;;
    --wizard)      WIZARD=1; shift ;;
    --no-wizard)   WIZARD=0; shift ;;
    --shell-path)
      require_flag_value "$1" "${2-}"
      case "$2" in zsh|bash|none) SHELL_PATH_MODE="$2" ;; *) die "--shell-path must be zsh, bash, or none" ;; esac
      shift 2 ;;
    --no-guest-shim) GUEST_SHIM=0; shift ;;
    --provider)    require_flag_value "$1" "${2-}"; WIZARD_PROVIDER="$2"; shift 2 ;;
    --team)        require_flag_value "$1" "${2-}"; TEAM="$2"; shift 2 ;;
    --sandbox)     require_flag_value "$1" "${2-}"; WIZARD_SANDBOX="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

# Uninstall runs before platform/dependency checks and all downloads. Only the
# installation's named entries are owned; neither the prefix nor its parent is.
uninstall_masc() {
  [ "${#INSTALL_ACTION_FLAGS[@]}" -eq 0 ] ||
    die "--uninstall cannot be combined with install options: ${INSTALL_ACTION_FLAGS[*]}"
  if [ "$PURGE_DATA" -eq 1 ] && [ "$BASE_PATH_EXPLICIT" -ne 1 ]; then
    die "--purge-data requires an explicit --base-path"
  fi
  local uninstall_prefix="$PREFIX" uninstall_base="$BASE_PATH" target name record recorded_base
  case "$uninstall_prefix" in '~') uninstall_prefix="$HOME" ;; '~/'*) uninstall_prefix="$HOME/${uninstall_prefix#\~/}" ;; esac
  case "$uninstall_base" in '~') uninstall_base="$HOME" ;; '~/'*) uninstall_base="$HOME/${uninstall_base#\~/}" ;; esac
  case "$uninstall_prefix" in /*) ;; *) uninstall_prefix="$PWD/$uninstall_prefix" ;; esac
  if [ -e "$uninstall_prefix/.masc-install-transaction" ] || [ -L "$uninstall_prefix/.masc-install-transaction" ]; then
    die "unfinished installation transaction at $uninstall_prefix/.masc-install-transaction; recover or roll back that installation before uninstalling"
  fi
  local targets=()
  for name in masc masc-tui masc-browser-host masc-deployment-preflight-helper masc-check-runtime-deployment-preflight; do
    target="$uninstall_prefix/$name"
    [ ! -d "$target" ] || [ -L "$target" ] || die "refusing to remove unexpected executable directory: $target"
    targets+=("$target")
  done
  targets+=("$uninstall_prefix/.masc-releases")
  if [ "$PURGE_DATA" -eq 1 ]; then
    case "$uninstall_base" in /*) ;; *) uninstall_base="$PWD/$uninstall_base" ;; esac
    targets+=("$uninstall_base/.masc")
    # `masc init` records this workspace as the default for later commands.
    # Leaving the record behind after purging the workspace it names would
    # point the next install at a directory that is gone.
    record="${XDG_CONFIG_HOME:-$HOME/.config}/masc/default-base-path"
    if [ -f "$record" ]; then
      # Compare existing directory identities too: init records the canonical
      # path, while purge may name the same workspace through a symlink or ./.
      if recorded_base=$(head -n 1 "$record" 2>/dev/null); then
        if [ "$recorded_base" = "$uninstall_base" ] || [ "$recorded_base" -ef "$uninstall_base" ]; then
          targets+=("$record")
        fi
      else
        log "default workspace record could not be read; leaving it in place: $record"
      fi
    fi
  fi
  log "stop running MASC servers and TUI sessions before uninstalling; no processes will be killed"
  for target in "${targets[@]}"; do
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] would remove: $target"
    else
      # No trailing slash: rm removes a symlink itself, never its target tree.
      rm -rf -- "$target" || die "could not remove: $target"
      log "removed: $target"
    fi
  done
  [ "$PURGE_DATA" -eq 1 ] || log "workspace .masc data preserved (use --purge-data --base-path PATH to remove it)"
  log "external runtime installations preserved"
}

if [ "$UNINSTALL" -eq 1 ]; then
  uninstall_masc
  exit 0
fi
[ "$PURGE_DATA" -eq 0 ] || die "--purge-data is only valid with --uninstall"

case "$ALLOW_UNVERIFIED" in
  0|1) ;;
  *) die "MASC_ALLOW_UNVERIFIED must be 0 or 1" ;;
esac

case "$WIZARD" in
  auto|0|1) ;;
  *) die "MASC_WIZARD must be auto, 0, or 1" ;;
esac

# Only the three real per-keeper profiles can be written. "local" is a
# flag-gated in-process lane, not a loadable sandbox_profile value, so it is
# rejected here rather than seeded into a keeper that would then fail to load.
case "$WIZARD_SANDBOX" in
  ''|docker|microvm|remote_ssh) ;;
  local) die "--sandbox local is not a loadable profile; use docker, microvm, or remote_ssh (or omit to keep the preset's own)" ;;
  *) die "--sandbox must be docker, microvm, or remote_ssh" ;;
esac

if [ "$WIZARD" = "0" ] && [ -n "$WIZARD_PROVIDER" ]; then
  die "--provider requires the setup wizard; omit --no-wizard (or MASC_WIZARD=0)"
fi
if [ -n "$WIZARD_SANDBOX" ] && [ -z "$TEAM" ]; then
  die "--sandbox requires --team; existing keepers use their own sandbox_profile"
fi

choose_install_base_path

# Releases use a checksummed private runtime before invoking Python (the
# system python3 may be a Command Line Tools installer stub).
installer_python_ready() {
  "$1" -c 'import json, tarfile, sys; sys.exit(0 if sys.version_info >= (3, 8) else "Python 3.8 or newer is required")'
}
require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
require curl
require uname
require chmod
require mkdir
require mktemp
RUNTIME_STAGE=""
RUNTIME_ARCHIVE=""
RUNTIME_ARGS=()
DRY_RUN_WITHOUT_PYTHON=0
if [ "$(uname -s)" = Darwin ]; then
  case "$(uname -m)" in arm64) minimum=14 ;; x86_64) minimum=15 ;; *) die "unsupported macOS architecture" ;; esac
  os_version=$(sw_vers -productVersion) || die "cannot read macOS version"
  major=${os_version%%.*}
  case "$major" in ''|*[!0-9]*) die "invalid macOS version: $os_version" ;; esac
  [ "$major" -ge "$minimum" ] || die "macOS $os_version is below the released binary minimum macOS $minimum.0"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would verify and install bundled macOS libraries and Python; no Homebrew or Command Line Tools required"
    # Prefer the installed private interpreter, then a usable non-system
    # interpreter. Never probe Apple's python3/CLT shim.
    dry_python=""
    installed_target=$(readlink "$PREFIX/masc" 2>/dev/null || true)
    if [ -n "$installed_target" ]; then
      case "$installed_target" in /*) ;; *) installed_target="$PREFIX/$installed_target" ;; esac
      candidate="$(dirname "$installed_target")/python/bin/python3"
      if [ -x "$candidate" ] && installer_python_ready "$candidate" >/dev/null 2>&1; then
        dry_python="$candidate"
      fi
    fi
    if [ -z "$dry_python" ]; then
      candidate=$(command -v python3 || true)
      case "$candidate" in
        ''|/usr/bin/python3|/Library/Developer/*|/Applications/Xcode.app/*) ;;
        *) if installer_python_ready "$candidate" >/dev/null 2>&1; then dry_python="$candidate"; fi ;;
      esac
    fi
    if [ -n "$dry_python" ]; then
      PATH="$(dirname "$dry_python"):$PATH"; export PATH; hash -r
    else
      DRY_RUN_WITHOUT_PYTHON=1
    fi
  fi
fi

if [ "$(uname -s)" = Linux ] && [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] would verify and install bundled Linux Python; no package-manager installation required"
  candidate=$(command -v python3 || true)
  if [ -z "$candidate" ] || ! installer_python_ready "$candidate" >/dev/null 2>&1; then
    DRY_RUN_WITHOUT_PYTHON=1
  fi
fi

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
    Darwin/x86_64) echo "masc-macos-x64" ;;
    Linux/aarch64) echo "masc-linux-arm64" ;;
    *) die "unsupported platform: $os/$arch" ;;
  esac
}

ASSET=$(detect_asset)
PLATFORM_SUFFIX="${ASSET#masc-}"
TUI_ASSET="masc-tui-$PLATFORM_SUFFIX"
BROWSER_HOST_ASSET="masc-browser-host-$PLATFORM_SUFFIX"
PREFLIGHT_HELPER_ASSET="masc-deployment-preflight-helper-$PLATFORM_SUFFIX"
PREFLIGHT_GATE_ASSET="masc-check-runtime-deployment-preflight-$PLATFORM_SUFFIX"
DASHBOARD_ASSET="masc-dashboard-$PLATFORM_SUFFIX.tar.gz"
BUNDLE_HELPER_ASSET="masc-release-dashboard-bundle-$PLATFORM_SUFFIX.py"
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
  if [ "$BUNDLE_TRANSACTION_ACTIVE" -eq 1 ]; then
    python3 "$BUNDLE_HELPER" rollback --prefix "$PREFIX" \
      || printf '%s\n' "binary/dashboard rollback failed; inspect $PREFIX/.masc-install-transaction" >&2
  fi
  [ -z "$RUNTIME_STAGE" ] || rm -rf "$RUNTIME_STAGE"
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
CHECKSUMS_URL="$RELEASE_BASE_URL/$VERSION/SHA256SUMS"
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

# Bootstrap only release-checksummed regular files into a fresh private tree.
# Even --allow-unverified never authorizes executing an unchecked interpreter.
if [ "$DRY_RUN" -eq 0 ]; then
  require tar
  fetch_release_checksums
  [ "$CHECKSUMS_AVAILABLE" -eq 1 ] || die "bundled Python requires release checksums"
  runtime_asset="masc-runtime-$PLATFORM_SUFFIX.tar.gz"
  runtime_expected=$(expected_hash "$runtime_asset")
  [ -n "$runtime_expected" ] || die "bundled Python checksum missing: $runtime_asset"
  RUNTIME_STAGE=$(mktemp -d)
  RUNTIME_ARCHIVE="$RUNTIME_STAGE/runtime.tar.gz"
  curl -fL --max-time "$MASC_INSTALL_BINARY_DOWNLOAD_TIMEOUT_S" --retry "$MASC_INSTALL_CURL_RETRIES" \
    -o "$RUNTIME_ARCHIVE" "$RELEASE_BASE_URL/$VERSION/$runtime_asset" || die "could not download bundled runtime"
  [ "$(sha256_file "$RUNTIME_ARCHIVE")" = "$runtime_expected" ] || die "bundled Python checksum differs"
  tar -tzf "$RUNTIME_ARCHIVE" > "$RUNTIME_STAGE/members" || die "invalid runtime archive"
  tar -tvzf "$RUNTIME_ARCHIVE" > "$RUNTIME_STAGE/types" || die "invalid runtime archive types"
  LC_ALL=C awk 'substr($0,1,1) != "-" {exit 1}' "$RUNTIME_STAGE/types" || die "runtime archive contains non-regular members"
  LC_ALL=C awk '
    !/^(lib\/|python\/|licenses\/|runtime-provenance\.json$)/ {exit 1}
    /[^A-Za-z0-9_.+\/-]/ || /(^|\/)\.\.?($|\/)/ || /\/\// {exit 1}
    seen[$0]++ {exit 1}
  ' "$RUNTIME_STAGE/members" || die "unsafe runtime archive paths"
  mkdir "$RUNTIME_STAGE/root"
  tar -xzf "$RUNTIME_ARCHIVE" -C "$RUNTIME_STAGE/root" || die "could not extract bundled runtime"
  [ -x "$RUNTIME_STAGE/root/python/bin/python3" ] || die "bundled Python missing"
  PATH="$RUNTIME_STAGE/root/python/bin:$PATH"
  export PATH
  unset PYTHONHOME PYTHONPATH
  hash -r
  installer_python_ready python3 || die "bundled Python cannot start"
  RUNTIME_ARGS=(--runtime-archive "$RUNTIME_ARCHIVE")
fi
if [ "$DRY_RUN_WITHOUT_PYTHON" -eq 1 ]; then
  case "$PREFIX" in '~') PREFIX="$HOME" ;; '~/'*) PREFIX="$HOME/${PREFIX#\~/}" ;; esac
  case "$BASE_PATH" in '~') BASE_PATH="$HOME" ;; '~/'*) BASE_PATH="$HOME/${BASE_PATH#\~/}" ;; esac
  case "$PREFIX" in /*) ;; *) PREFIX="$PWD/$PREFIX" ;; esac
  case "$BASE_PATH" in /*) ;; *) BASE_PATH="$PWD/$BASE_PATH" ;; esac
else
require python3
PREFIX="$(python3 -c 'import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$PREFIX")"
BASE_PATH="$(python3 -c 'import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$BASE_PATH")"
fi
log "workspace: $BASE_PATH"
log "configuration and data: $BASE_PATH/.masc"

# --- 3. download binary -------------------------------------------------------
URL="$RELEASE_BASE_URL/$VERSION/$ASSET"
DEST="$PREFIX/masc"
TUI_DEST="$PREFIX/masc-tui"
BROWSER_HOST_DEST="$PREFIX/masc-browser-host"
PREFLIGHT_HELPER_DEST="$PREFIX/masc-deployment-preflight-helper"
PREFLIGHT_GATE_DEST="$PREFIX/masc-check-runtime-deployment-preflight"

model_catalog_env_value() {
  if [ -n "${AGENT_CORE_MODEL_CATALOG:-}" ]; then
    echo "$AGENT_CORE_MODEL_CATALOG"
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
      AGENT_CORE_MODEL_CATALOG="$catalog" \
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

# Automatic upgrades apply only to ordered stable release versions. Unknown
# development/prerelease strings and downgrades still require an explicit force.
is_stable_upgrade() {
  # Keep version planning available before the private Python bootstrap.
  # Decimal components are compared without shell integer overflow.
  local installed="$1" requested="${2#v}" left right index
  local LC_ALL=C
  local installed_parts requested_parts
  [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a installed_parts <<< "$installed"
  IFS=. read -r -a requested_parts <<< "$requested"
  for index in 0 1 2; do
    left="${installed_parts[$index]}"; right="${requested_parts[$index]}"
    while [ "${#left}" -gt 1 ] && [[ "$left" = 0* ]]; do left="${left#0}"; done
    while [ "${#right}" -gt 1 ] && [[ "$right" = 0* ]]; do right="${right#0}"; done
    [ "${#left}" -lt "${#right}" ] && return 0
    [ "${#left}" -gt "${#right}" ] && return 1
    [[ "$left" < "$right" ]] && return 0
    [[ "$left" > "$right" ]] && return 1
  done
  return 1
}

SKIP_DL=0
if [ -e "$DEST" ]; then
  # The pipeline `... | tail -n1` masks the binary's own exit status, so
  # ask the binary directly first, then capture its output.
  if masc_responds_to_version "$DEST"; then
    existing_ver=$(masc_reported_version "$DEST")
    if [ "$existing_ver" = "${VERSION#v}" ] && [ "$FORCE" -eq 0 ]; then
      log "already at $VERSION ($DEST), skipping download"
      SKIP_DL=1
    elif [ "$existing_ver" = "${VERSION#v}" ]; then
      warn "existing $DEST already reports $existing_ver; refreshing because --force is set"
    elif [ "$FORCE" -eq 0 ] && is_stable_upgrade "$existing_ver" "$VERSION"; then
      log "upgrading $DEST from $existing_ver to ${VERSION#v}; preserving workspace config"
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

install_release_companion() {
  local asset="$1" dest="$2"
  local url="$RELEASE_BASE_URL/$VERSION/$asset"
  if [ "$SKIP_DL" -eq 1 ] && [ -x "$dest" ]; then
    COMPANION_ARGS+=(--companion "${dest##*/}" "$dest")
    log "release companion already present: $dest"
    return 0
  fi
  log "downloading $url"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would download to $dest"
    return 0
  fi
  mkdir -p "$PREFIX"
  local tmp="$dest.partial"
  PARTIAL_FILES+=("$tmp")
  fetch_release_checksums
  curl -fL \
    --max-time "$MASC_INSTALL_BINARY_DOWNLOAD_TIMEOUT_S" \
    --retry "$MASC_INSTALL_CURL_RETRIES" \
    --progress-bar \
    -o "$tmp" \
    "$url" \
    || die "download failed (asset missing for $VERSION?): $asset"
  verify_checksum "$tmp" "$asset"
  chmod +x "$tmp"
  COMPANION_ARGS+=(--companion "${dest##*/}" "$tmp")
  log "staged: $dest"
}

# Stage and verify every companion before publishing any executable.
# The bundle helper journals companions with the main binary for rollback.
#
# A missing asset stops the install rather than skipping the companion. That is
# the same rule the two preflight companions already follow, and it is why the
# README tells you to take the installer and the assets from one tag: an
# installer that quietly delivers less than it was built to deliver is worse
# than one that stops and says which asset was absent.
install_release_companion "$TUI_ASSET" "$TUI_DEST"
install_release_companion "$BROWSER_HOST_ASSET" "$BROWSER_HOST_DEST"
install_release_companion "$PREFLIGHT_HELPER_ASSET" "$PREFLIGHT_HELPER_DEST"
install_release_companion "$PREFLIGHT_GATE_ASSET" "$PREFLIGHT_GATE_DEST"

# The guest exec shim (RFC-0427 B-2). The release ships one static Linux
# binary per guest architecture; the guest is arm64 on an Apple Silicon host
# (Apple's container) and the host's own architecture on Linux. It lands where
# the server's microvm boot mounts it, with the release's own sha256 beside it
# so the boot can refuse a shim the release did not ship. The same rule as the
# companions above: a missing asset stops the install.
guest_shim_asset() {
  case "$PLATFORM_SUFFIX" in
    macos-arm64|linux-arm64) echo "masc-exec-shim-linux-arm64" ;;
    macos-x64|linux-x64) echo "masc-exec-shim-linux-amd64" ;;
    *) die "no guest exec shim asset for platform $PLATFORM_SUFFIX" ;;
  esac
}

install_guest_shim() {
  local asset dest_dir dest sidecar url tmp expected
  asset="$(guest_shim_asset)"
  dest_dir="$BASE_PATH/.masc/microvm/shim"
  dest="$dest_dir/masc-exec-shim"
  sidecar="$dest_dir/masc-exec-shim.sha256"
  url="$RELEASE_BASE_URL/$VERSION/$asset"
  if [ "$SKIP_DL" -eq 1 ] && [ -x "$dest" ] && [ -f "$sidecar" ]; then
    log "guest exec shim already present: $dest"
    return 0
  fi
  log "downloading $url"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would place $dest and $sidecar"
    return 0
  fi
  mkdir -p "$dest_dir"
  tmp="$dest.partial"
  PARTIAL_FILES+=("$tmp")
  fetch_release_checksums
  curl -fL \
    --max-time "$MASC_INSTALL_BINARY_DOWNLOAD_TIMEOUT_S" \
    --retry "$MASC_INSTALL_CURL_RETRIES" \
    --progress-bar \
    -o "$tmp" \
    "$url" \
    || die "download failed (asset missing for $VERSION?): $asset"
  verify_checksum "$tmp" "$asset"
  chmod 755 "$tmp"
  expected=""
  if [ "$CHECKSUMS_AVAILABLE" -eq 1 ]; then
    expected="$(expected_hash "$asset")"
  fi
  mv "$tmp" "$dest"
  if [ -n "$expected" ]; then
    printf '%s  %s\n' "$expected" "$asset" > "$sidecar"
    log "installed: $dest (sha256 sidecar written)"
  else
    rm -f "$sidecar"
    warn "installed: $dest without a sha256 sidecar (release checksums unavailable); the server will run it unverified"
  fi
}

if [ "$GUEST_SHIM" -eq 1 ]; then
  install_guest_shim
fi

# Fetch and verify both halves before publishing the new runtime. The helper
# installs an immutable release directory and one atomic executable pointer;
# EXIT rolls it back if later seeding/wizard/smoke fails.
fetch_bundle_asset() {
  local asset="$1" target="$2"
  fetch_release_checksums
  curl -fL --max-time "$MASC_INSTALL_BINARY_DOWNLOAD_TIMEOUT_S" \
    --retry "$MASC_INSTALL_CURL_RETRIES" --progress-bar \
    -o "$target" "$RELEASE_BASE_URL/$VERSION/$asset" \
    || die "download failed (asset missing for $VERSION?): $asset"
  verify_checksum "$target" "$asset"
}

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] would install verified binary/dashboard bundle at $PREFIX"
else
  mkdir -p "$PREFIX"
  binary_input="$DEST"
  if [ "$SKIP_DL" -ne 1 ]; then
    binary_input="$(mktemp "$PREFIX/.masc-download.XXXXXX")"
    PARTIAL_FILES+=("$binary_input")
    fetch_bundle_asset "$ASSET" "$binary_input"
  fi
  # Diagnose the executable itself before fetching the dashboard. This also
  # exposes dyld/loader stderr when installing an older release bundle helper.
  if [ "$SKIP_DL" -ne 1 ]; then chmod +x "$binary_input"; fi
  if [ -z "$RUNTIME_ARCHIVE" ] && ! run_masc_with_install_env "$binary_input" build-commit; then
    die "downloaded executable cannot start; see loader stderr above (check OS/CPU and native runtime dependencies)"
  fi
  BUNDLE_HELPER="$(mktemp)"
  bundle_archive="$(mktemp)"
  PARTIAL_FILES+=("$BUNDLE_HELPER" "$bundle_archive")
  fetch_bundle_asset "$BUNDLE_HELPER_ASSET" "$BUNDLE_HELPER"
  fetch_bundle_asset "$DASHBOARD_ASSET" "$bundle_archive"
  DASHBOARD_ASSETS_DIR="$(python3 "$BUNDLE_HELPER" install \
    --binary "$binary_input" --archive "$bundle_archive" \
    --prefix "$PREFIX" --binary-asset "$ASSET" ${COMPANION_ARGS[@]+"${COMPANION_ARGS[@]}"} ${RUNTIME_ARGS[@]+"${RUNTIME_ARGS[@]}"})" \
    || die "binary/dashboard installation rejected"
  BUNDLE_TRANSACTION_ACTIVE=1
  log "installed verified binary/dashboard: $DEST"
fi

# Check persisted state before init or Skill seeding can touch an existing workspace.
if [ "$DRY_RUN" -eq 0 ] && [ "$SEED_CONFIG" -eq 1 ]; then
  workspace_helper=$(mktemp)
  workspace_receipt=$(mktemp)
  PARTIAL_FILES+=("$workspace_helper" "$workspace_receipt")
  fetch_bundle_asset install-runtime-setup.py "$workspace_helper"
  with_terminal_input python3 "$workspace_helper" --binary "$DEST" --base-path "$BASE_PATH" --workspace-check > "$workspace_receipt" \
    || die "workspace check stopped installation; existing workspace data was preserved"
  BASE_PATH=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_path"])' "$workspace_receipt")
fi

# --- 4. seed minimum config ---------------------------------------------------
# Record existing workspaces even when an overlay is missing or seeding is disabled.
[ ! -d "$BASE_PATH/.masc/config" ] || CONFIG_PREEXISTING=1
if [ "$SEED_CONFIG" -eq 1 ]; then
  CONFIG_DIR="$BASE_PATH/.masc/config"
  RUNTIME_FILE="$CONFIG_DIR/runtime.toml"
  MODEL_CATALOG_OVERLAY_FILE="$CONFIG_DIR/agent-core-models-overlay.toml"

  # Package publication waits until the binary/dashboard transaction commits.
  # Config seeding is needed by the wizard before that boundary.
  if [ -e "$RUNTIME_FILE" ] && [ -e "$MODEL_CATALOG_OVERLAY_FILE" ] && [ "$RESET_CONFIG" -eq 0 ]; then
    CONFIG_PREEXISTING=1
    log "preserving existing config at $CONFIG_DIR; builtin Skills refresh after bundle commit"
  elif [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would seed configs and model catalog overlay to $CONFIG_DIR from release"
  else
    # The binary carries the whole config/ tree it was built from, so the seed
    # is `masc init` rather than a fetch of the same files from the repo. Three
    # things follow: an offline or mirrored install works, the seed cannot drift
    # from the binary's contract the way a raw fetch at a different tag could,
    # and no checksum is needed for files that arrived inside a verified binary.
    # `init` writes what is missing and leaves the rest; --force overwrites.
    log "seeding configs and model catalog overlay to $CONFIG_DIR from the binary"
    mkdir -p "$CONFIG_DIR"
    # --record-default: this is the operator's workspace, so later commands
    # should find it without being told again. `masc init` does not record by
    # default, because a throwaway workspace must not become the machine's.
    init_args=(init --config-only --base-path "$BASE_PATH" --record-default)
    [ "$RESET_CONFIG" -eq 1 ] && init_args+=(--force)
    if ! init_output="$("$DEST" "${init_args[@]}" 2>&1)"; then
      die "config seed failed ($DEST ${init_args[*]}): $init_output"
    fi
    log "$init_output"
    [ -e "$RUNTIME_FILE" ] || die "config seed produced no $RUNTIME_FILE"
  fi
fi

case ":$PATH:" in *":$PREFIX:"*) ;; *) PATH="$PREFIX:$PATH"; export PATH; hash -r ;; esac

# --- 4b. first-run wizard ------------------------------------------------------
if [ "$DRY_RUN_WITHOUT_PYTHON" -eq 1 ]; then
  if [ -n "$WIZARD_PROVIDER" ]; then
    log "[dry-run] requested provider: $WIZARD_PROVIDER; catalog validation and runtime selection require the planned bundled Python and installed binary"
  elif [ "$WIZARD" != 0 ]; then
    log "[dry-run] provider wizard requires the planned bundled Python and installed binary"
  fi
else
  maybe_run_wizard "$BASE_PATH"
fi

# --- 4c. keeper team preset ----------------------------------------------------
# Seeds presets/<preset>/keepers into the config root (verified via
# the release SHA256SUMS, like the config seed). The keepers inherit
# [runtime].default, so no catalog is edited. Runs after config seed so
# runtime.toml exists first.
# Rewrite a seeded keeper's sandbox_profile to the operator's --sandbox choice.
# Only a line that starts with `sandbox_profile` is touched, so a preset's
# commented rationale (`# sandbox_profile = ...`) is left alone, and a file that
# declares no profile (or is not a keeper TOML) is untouched. This overrides the
# preset's own choice on purpose; the caller has asked for it explicitly.
set_keeper_sandbox_profile() {
  local file="$1" profile="$2"
  grep -q '^sandbox_profile[[:space:]]*=' "$file" 2>/dev/null || return 0
  local tmp
  tmp="$(mktemp "${file}.sbtmp.XXXXXX")" || die "could not create temp file for $file"
  PARTIAL_FILES+=("$tmp")
  if sed 's/^sandbox_profile[[:space:]]*=.*/sandbox_profile = "'"$profile"'"/' "$file" > "$tmp" \
    && mv -f "$tmp" "$file"; then
    log "set sandbox_profile = \"$profile\" in $(basename "$file")"
  else
    rm -f "$tmp"
    die "could not set sandbox_profile in $file"
  fi
}

seed_team() {
  local preset="$1"
  local cfg="$BASE_PATH/.masc/config"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would seed team preset '$preset' into $cfg (presets/$preset/ at $VERSION)"
    [ -n "$WIZARD_SANDBOX" ] \
      && log "[dry-run] would set sandbox_profile = \"$WIZARD_SANDBOX\" on the team's keepers"
    return 0
  fi

  log "seeding keeper team preset '$preset' into $cfg"
  mkdir -p "$cfg"
  local manifest_url="https://raw.githubusercontent.com/$REPO/$VERSION/presets/$preset/manifest.txt"
  local manifest_tmp
  manifest_tmp="$(mktemp)"
  PARTIAL_FILES+=("$manifest_tmp")
  curl -fsSL \
    --max-time "$MASC_INSTALL_CONFIG_FETCH_TIMEOUT_S" \
    --retry "$MASC_INSTALL_CURL_RETRIES" \
    -o "$manifest_tmp" "$manifest_url" \
    || die "team preset '$preset' manifest fetch failed ($manifest_url)"

  local rel dest tmp raw
  while IFS= read -r rel || [ -n "$rel" ]; do
    case "$rel" in ''|'#'*) continue ;; esac
    dest="$cfg/$rel"
    if [ -e "$dest" ] && [ "$RESET_CONFIG" -eq 0 ]; then
      log "team file present: $rel, skipping"
      continue
    fi
    raw="https://raw.githubusercontent.com/$REPO/$VERSION/presets/$preset/$rel"
    tmp="$dest.partial"
    mkdir -p "$(dirname "$dest")"
    PARTIAL_FILES+=("$tmp")
    curl -fsSL \
      --max-time "$MASC_INSTALL_CONFIG_FETCH_TIMEOUT_S" \
      --retry "$MASC_INSTALL_CURL_RETRIES" \
      -o "$tmp" "$raw" \
      || die "team preset file fetch failed ($raw)"
    verify_checksum "$tmp" "presets/$preset/$rel"
    mv "$tmp" "$dest"
    log "seeded team file: $rel"
    [ -n "$WIZARD_SANDBOX" ] && set_keeper_sandbox_profile "$dest" "$WIZARD_SANDBOX"
  done < "$manifest_tmp"
  rm -f "$manifest_tmp"
  log "team preset '$preset' seeded; its keepers autoboot on next server start"
}

if [ -n "$TEAM" ]; then
  if [ "$SEED_CONFIG" -eq 1 ]; then
    seed_team "$TEAM"
  else
    warn "--team '$TEAM' ignored because config seeding is disabled (--no-seed)"
  fi
fi

# --- 5. smoke check -----------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
  if masc_responds_to_version "$DEST"; then
    reported=$(masc_reported_version "$DEST")
    [ "$reported" = "${VERSION#v}" ] \
      || warn "binary reports $reported, expected ${VERSION#v}"
  else
    # A prebuilt binary that will not start is almost always a missing system
    # shared library, and the loader says which one — so surface that instead
    # of the generic "no --version". Re-run capturing stderr (the smoke check
    # discarded it), and on Linux list the unresolved libraries by name.
    # [|| true]: the binary exits non-zero (127 on a missing library) and
    # [set -e] would otherwise kill the installer before it could explain why.
    boot_err="$(run_masc_with_install_env "$DEST" --version 2>&1 >/dev/null || true)"
    case "$boot_err" in
      *"shared librar"*)
        printf '%s\n' "$boot_err" >&2
        missing=""
        if command -v ldd >/dev/null 2>&1; then
          missing="$(ldd "$DEST" 2>/dev/null | awk '/not found/{print $1}' | tr '\n' ' ')"
          [ -n "$missing" ] && warn "missing system libraries: $missing"
        fi
        case "$boot_err $missing" in
          *sqlite3*)
            warn "install the SQLite runtime, e.g. on Debian/Ubuntu: sudo apt-get install -y libsqlite3-0" ;;
          *)
            warn "install the matching system library package, then re-run this installer" ;;
        esac
        ;;
    esac
    die "binary did not respond to --version"
  fi
fi

# --- 6. New-terminal PATH integration ----------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  case "$SHELL_PATH_MODE" in zsh|bash) configure_shell_path ;; esac
  printf '\n%s[dry-run] no files written.%s\n\n' "$c_yel" "$c_off"
  exit 0
fi

python3 "$BUNDLE_HELPER" commit --prefix "$PREFIX"
BUNDLE_TRANSACTION_ACTIVE=0
# --- committed builtin Skill refresh ----------------------------------------
# A later package error must not restore an older executable underneath newer
# instructions. The complete previous package remains in its own backup.
if [ "$SEED_CONFIG" -eq 1 ]; then
  if ! init_output="$("$DEST" init --skills-only --base-path "$BASE_PATH" 2>&1)"; then
    die "binary/dashboard committed; builtin Skill refresh failed: $init_output"
  fi
  log "$init_output"
fi
# --- end committed builtin Skill refresh ------------------------------------
configure_shell_path
catalog_hint=$(model_catalog_env_value)
# Keep the copy-paste start command aligned with runtime base/catalog env, but
# do not default-disable Runtime_events. If the operator supplied an override,
# preserve it; otherwise let the binary's default-on contract apply.
runtime_events_start_env=""
if [ "${MASC_RUNTIME_EVENTS+x}" = "x" ]; then
  runtime_events_start_env="MASC_RUNTIME_EVENTS=\"$MASC_RUNTIME_EVENTS\" "
fi
start_env="MASC_ASSETS_DIR=\"$DASHBOARD_ASSETS_DIR\" ${runtime_events_start_env}MASC_BASE_PATH=\"$BASE_PATH\" MASC_BASE_PATH_INPUT=\"$BASE_PATH\""
if [ -n "$catalog_hint" ]; then
  start_env="AGENT_CORE_MODEL_CATALOG=\"$catalog_hint\" $start_env"
fi

cat <<EOF

${c_grn}masc ${VERSION} installed.${c_off}

Installed:
  server + TUI + dashboard + browser host + deployment preflight tools
  workspace: $BASE_PATH
  provider credentials, Keeper creation and execution backend setup are separate
  browser registration: https://github.com/$REPO/blob/$VERSION/connectors/browser/host/README.md

Next: start your first conversation with imp:
  ${c_dim}# export your provider key in this shell -- the server reads it from its${c_off}
  ${c_dim}# own environment, and the server the TUI starts inherits the TUI's${c_off}
  ${c_dim}# export <PROVIDER>_API_KEY=...   (runtime.toml names the variable)${c_off}

  ${c_dim}# install/start Docker Desktop (macOS) or Docker Engine (Linux), then:${c_off}
  ${c_dim}# prepare the sandbox, start imp, and open the conversation workspace${c_off}
  $start_env "$DEST" setup --base-path "$BASE_PATH" --port "$MASC_PORT"

  ${c_dim}# optional: mint a worker bearer for a separate MCP client${c_off}
  eval "\$($DEST login --base-path \"$BASE_PATH\" --host 127.0.0.1 --port \"$MASC_PORT\" --agent local-mcp-client --role worker --client-env MASC_TOKEN --no-expiry --shell)"

  ${c_dim}# open the workspace: on a terminal this is the fleet TUI, and it starts${c_off}
  ${c_dim}# the server here when nothing is answering the port${c_off}
  $start_env "$DEST" --base-path "$BASE_PATH" --port "$MASC_PORT"

  ${c_dim}# the server on its own, with no terminal (loopback only)${c_off}
  $start_env "$DEST" start --base-path "$BASE_PATH" --port "$MASC_PORT"

  ${c_dim}# to change provider or model later, edit:${c_off}
  #   $BASE_PATH/.masc/config/runtime.toml

  ${c_dim}# sanity check in a second terminal while the server is running${c_off}
  curl http://127.0.0.1:${MASC_PORT}/health

  ${c_dim}# the TUI under its own name, when the port is not the default${c_off}
  ${c_dim}# a fresh root seeds one Keeper, imp, with autoboot off: start it from the Keepers view once a model and a sandbox exist (or reinstall with --team)${c_off}
  "$TUI_DEST" --base-path "$BASE_PATH" --port "$MASC_PORT"

  ${c_dim}# or create one non-interactively once the server is up:${c_off}
  ${c_dim}# $DEST keeper-create --help${c_off}

  ${c_dim}# for Docker Keepers, build the general file/Git tools image:${c_off}
  "$DEST" sandbox-image
  ${c_dim}# microVM uses a separate runtime/image store; see the platform guide:${c_off}
  # https://github.com/$REPO/blob/$VERSION/docs/INSTALL.md

  ${c_dim}# source the printed bearer exports in the shell that starts your MCP client${c_off}
  See: https://github.com/$REPO#mcp-client-setup

EOF
