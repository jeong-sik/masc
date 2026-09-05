#!/usr/bin/env bash
# masc installer — download prebuilt binary, seed runtime config/catalog, smoke-check.
#
# Usage:
#   TAG=vX.Y.Z
#   curl -fsSL "https://raw.githubusercontent.com/jeong-sik/masc/$TAG/scripts/install.sh" -o /tmp/masc-install.sh
#   less /tmp/masc-install.sh
#   bash /tmp/masc-install.sh --version "$TAG"
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
DRY_RUN=0
ALLOW_UNVERIFIED="${MASC_ALLOW_UNVERIFIED:-0}"
WIZARD="${MASC_WIZARD:-auto}"
WIZARD_PROVIDER=""
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
#   reachable / not running  -- a local server, probed over HTTP
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
        elif probe_local_reachable "$idx"; then
          echo "reachable"
        else
          echo "not running"
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

  if ! "$DEST" runtime-default-set --base-path "$base_path" "$runtime_id" >/dev/null; then
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
  [ -z "$key_var" ] || [ -n "$key" ]
}

ping_provider() {
  local idx="$1" key="$2"
  local endpoint="${PROVIDER_ENDPOINTS[$idx]}"
  local ping_path="${PROVIDER_PING_PATHS[$idx]}"
  local key_var
  key_var=$(provider_key_var "$idx")

  # A subscription has no endpoint to reach; the meaningful check is whether its
  # CLI is on PATH. Being signed in is a deeper, per-CLI probe left to a later
  # step (RFC-0408) -- here we only confirm the command exists.
  if [ "${PROVIDER_KINDS[$idx]}" = "subscription" ]; then
    local cli_command="${PROVIDER_COMMANDS[$idx]}"
    if [ -z "$cli_command" ]; then
      warn "subscription $(provider_name "$idx") has no CLI command in runtime.toml; skipping check"
      return 0
    fi
    if command -v "$cli_command" >/dev/null 2>&1; then
      return 0
    fi
    warn "$cli_command not found on PATH; sign in to $(provider_name "$idx") before using it"
    return 1
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

run_wizard() {
  local base_path="$1"
  local provider_idx key
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
    provider_idx=$(prompt_provider)
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
    warn "$(provider_name "$provider_idx") is not running at ${PROVIDER_ENDPOINTS[$provider_idx]}; start it before using masc"
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
      log "no key in this environment to reach $(provider_name "$provider_idx") with; skipping the connectivity check"
    elif ping_provider "$provider_idx" "$key"; then
      log "provider connectivity: ok"
    else
      warn "provider connectivity check did not pass; masc will retry at first turn"
    fi
    return 0
  fi

  if ! provider_ping_possible "$provider_idx" "$key"; then
    log "no key in this environment to reach $(provider_name "$provider_idx") with; skipping the connectivity check"
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
  local runtime_file="$base_path/.masc/config/runtime.toml"

  if [ "$WIZARD" = "0" ]; then
    return 0
  fi

  if [ ! -e "$runtime_file" ]; then
    if [ "$WIZARD" = "1" ]; then
      die "runtime.toml not found; cannot run wizard (did you mean to seed config?)"
    fi
    log "runtime.toml not found; skipping first-time setup wizard"
    log "set [runtime].default in .masc/config/runtime.toml to finish setup"
    return 0
  fi

  # "First-time" means the config root was not already here. A workspace that was
  # already configured keeps the [runtime].default it has; --wizard or --force
  # asks for the choice again.
  if [ "$CONFIG_PREEXISTING" -eq 1 ] && [ "$FORCE" -eq 0 ] && [ "$WIZARD" != "1" ]; then
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
    --team)        require_flag_value "$1" "${2-}"; TEAM="$2"; shift 2 ;;
    --sandbox)     require_flag_value "$1" "${2-}"; WIZARD_SANDBOX="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

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

[ -z "$BASE_PATH" ] && BASE_PATH="$PWD"

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
    Linux/aarch64) echo "masc-linux-arm64" ;;
    *) die "unsupported platform: $os/$arch" ;;
  esac
}

ASSET=$(detect_asset)
PLATFORM_SUFFIX="${ASSET#masc-}"
TUI_ASSET="masc-tui-$PLATFORM_SUFFIX"
PREFLIGHT_HELPER_ASSET="masc-deployment-preflight-helper-$PLATFORM_SUFFIX"
PREFLIGHT_GATE_ASSET="masc-check-runtime-deployment-preflight-$PLATFORM_SUFFIX"
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

# --- 3. download binary -------------------------------------------------------
URL="$RELEASE_BASE_URL/$VERSION/$ASSET"
DEST="$PREFIX/masc"
TUI_DEST="$PREFIX/masc-tui"
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
  mv "$tmp" "$dest"
  log "installed: $dest"
}

# Install and verify the companions before replacing the main binary.
# A failed companion download must leave the currently installed runtime intact.
#
# A missing asset stops the install rather than skipping the companion. That is
# the same rule the two preflight companions already follow, and it is why the
# README tells you to take the installer and the assets from one tag: an
# installer that quietly delivers less than it was built to deliver is worse
# than one that stops and says which asset was absent.
install_release_companion "$TUI_ASSET" "$TUI_DEST"
install_release_companion "$PREFLIGHT_HELPER_ASSET" "$PREFLIGHT_HELPER_DEST"
install_release_companion "$PREFLIGHT_GATE_ASSET" "$PREFLIGHT_GATE_DEST"

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
  RUNTIME_FILE="$CONFIG_DIR/runtime.toml"
  MODEL_CATALOG_OVERLAY_FILE="$CONFIG_DIR/agent-core-models-overlay.toml"

  if [ -e "$RUNTIME_FILE" ] && [ -e "$MODEL_CATALOG_OVERLAY_FILE" ] && [ "$FORCE" -eq 0 ]; then
    CONFIG_PREEXISTING=1
    log "config already present at $CONFIG_DIR, skipping seed"
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
    init_args=(init --base-path "$BASE_PATH")
    [ "$FORCE" -eq 1 ] && init_args+=(--force)
    if ! init_summary="$("$DEST" "${init_args[@]}" 2>&1 | tail -1)"; then
      die "config seed failed ($DEST ${init_args[*]}): $init_summary"
    fi
    log "$init_summary"
    [ -e "$RUNTIME_FILE" ] || die "config seed produced no $RUNTIME_FILE"
  fi
fi

# --- 4b. first-run wizard ------------------------------------------------------
maybe_run_wizard "$BASE_PATH"

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
    if [ -e "$dest" ] && [ "$FORCE" -eq 0 ]; then
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
  start_env="AGENT_CORE_MODEL_CATALOG=\"$catalog_hint\" $start_env"
fi

cat <<EOF

${c_grn}masc ${VERSION} installed.${c_off}

Next:
  ${c_dim}# export your provider key in this shell -- the server reads it from its${c_off}
  ${c_dim}# own environment, and the server the TUI starts inherits the TUI's${c_off}
  ${c_dim}# export <PROVIDER>_API_KEY=...   (runtime.toml names the variable)${c_off}

  ${c_dim}# mint a worker bearer in this shell for your MCP client${c_off}
  eval "\$($DEST login --base-path \"$BASE_PATH\" --host 127.0.0.1 --port \"$MASC_PORT\" --agent local-mcp-client --role worker --client-env MASC_TOKEN --no-expiry --shell)"

  ${c_dim}# open the workspace: on a terminal this is the fleet TUI, and it starts${c_off}
  ${c_dim}# the server here when nothing is answering the port${c_off}
  $start_env $DEST --base-path "$BASE_PATH"

  ${c_dim}# the server on its own, with no terminal (loopback only)${c_off}
  $start_env $DEST start --base-path "$BASE_PATH"

  ${c_dim}# to change provider or model later, edit:${c_off}
  #   $BASE_PATH/.masc/config/runtime.toml

  ${c_dim}# sanity check${c_off}
  curl http://127.0.0.1:${MASC_PORT}/health

  ${c_dim}# the TUI under its own name, when the port is not the default${c_off}
  ${c_dim}# no Keepers yet? create your first from the Keepers view (or reinstall with --team)${c_off}
  $TUI_DEST --base-path "$BASE_PATH" --port "$MASC_PORT"

  ${c_dim}# or create one non-interactively once the server is up:${c_off}
  ${c_dim}# $DEST keeper-create --help${c_off}

  ${c_dim}# a Keeper on sandbox_profile = "docker" runs inside masc-keeper-sandbox:local,${c_off}
  ${c_dim}# which is built locally and published to no registry. Without it every turn${c_off}
  ${c_dim}# stops at docker_preflight_failed. From a source checkout:${c_off}
  ${c_dim}#   scripts/build-keeper-sandbox-image.sh${c_off}

  ${c_dim}# source the printed bearer exports in the shell that starts your MCP client${c_off}
  See: https://github.com/$REPO#mcp-client-setup

EOF
