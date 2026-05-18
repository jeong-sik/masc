(** Env-driven runtime configuration for {!Cascade_health_tracker}. *)

(** One-time deprecation warning for legacy OAS_CASCADE_* env vars.
    The cascade routing layer was migrated from OAS to MASC in v0.149.0
    (see docs/rfc/RFC-OAS-006-weighted-cascade-routing.md + follow-ups);
    the env var prefix stayed [OAS_CASCADE_*] by drift.  We accept both
    during the transition and emit a one-shot warning per deprecated
    key so operators can update their deployment config. *)
let deprecation_warned : (string, unit) Hashtbl.t = Hashtbl.create 4

let getenv_with_alias ~primary ?deprecated () =
  match Sys.getenv_opt primary with
  | Some v -> Some v
  | None ->
      (match deprecated with
       | None -> None
       | Some dep ->
           (match Sys.getenv_opt dep with
            | Some _ as some ->
                if not (Hashtbl.mem deprecation_warned dep)
                then (
                  Hashtbl.add deprecation_warned dep ();
                  Log.Misc.warn
                    "env var %s is deprecated; use %s (same semantics)"
                    dep
                    primary);
                some
            | None -> None))

let read_float_setting ~primary ?deprecated ~default () =
  match getenv_with_alias ~primary ?deprecated () with
  | None -> default
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = ""
      then default
      else (
        match Safe_ops.float_of_string_safe trimmed with
        | Some value -> value
        | None ->
            Log.Misc.warn
              "Invalid float for %s=%S, using default %.1f"
              primary
              raw
              default;
            default)

let read_int_setting ~primary ?deprecated ~default () =
  match getenv_with_alias ~primary ?deprecated () with
  | None -> default
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = ""
      then default
      else (
        match Safe_ops.int_of_string_safe trimmed with
        | Some value -> value
        | None ->
            Log.Misc.warn
              "Invalid int for %s=%S, using default %d"
              primary
              raw
              default;
            default)

(** Rolling window duration in seconds.  Events older than this are
    discarded on read.  Default: 300s (5 minutes), matching OpenRouter's
    rolling percentile window. *)
let window_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_HEALTH_WINDOW_SEC"
    ~deprecated:"OAS_CASCADE_HEALTH_WINDOW_SEC"
    ~default:300.0
    ()

(** Number of consecutive failures before cooldown activates.
    Default: 3, matching LiteLLM's [allowed_fails] concept. *)
let cooldown_threshold =
  read_int_setting
    ~primary:"MASC_CASCADE_COOLDOWN_THRESHOLD"
    ~deprecated:"OAS_CASCADE_COOLDOWN_THRESHOLD"
    ~default:3
    ()

(** Cooldown duration in seconds.  During cooldown, the provider is
    skipped (not attempted).  Default: 30s, matching the provider
    circuit-breaker OPEN threshold used by the cascade.  Hard quota and
    terminal provider errors use separate long cooldowns. *)
let cooldown_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_COOLDOWN_SEC"
    ~deprecated:"OAS_CASCADE_COOLDOWN_SEC"
    ~default:30.0
    ()

let local_cooldown_threshold =
  Int.max 1
    (read_int_setting
       ~primary:"MASC_LOCAL_COOLDOWN_THRESHOLD"
       ~default:5
       ())

let local_cooldown_sec =
  Float.max 1.0
    (read_float_setting
       ~primary:"MASC_LOCAL_COOLDOWN_SEC"
       ~default:10.0
       ())

let local_runtime_auth = function
  | Agent_sdk.Provider_runtime_binding.No_auth -> true
  | Api_key_env _ | Cli_cached_login | Oauth_cached_login | Setup_token_env _
  | File _ | Exec _ -> false

let local_runtime_base_url base_url =
  match Uri.of_string (String.trim base_url) |> Uri.host with
  | Some host -> Masc_network_defaults.is_loopback_host_opt (Some host)
  | None -> false

let runtime_binding_is_local (binding : Agent_sdk.Provider_runtime_binding.t) =
  local_runtime_auth binding.auth && local_runtime_base_url binding.base_url

let provider_key_is_local provider_key =
  let key = String.trim provider_key |> String.lowercase_ascii in
  String.equal key "custom"
  ||
  match Agent_sdk.Provider_runtime_binding.find key with
  | Some binding -> runtime_binding_is_local binding
  | None -> false

let cooldown_config_for ~provider_key =
  if provider_key_is_local provider_key
  then local_cooldown_threshold, local_cooldown_sec
  else cooldown_threshold, cooldown_sec

(** Cooldown duration for provider calls classified as hard-quota exhaustion
    (account balance depleted, monthly quota reached, resource exhausted).
    Unlike transient 429s, hard-quota errors will not recover within a short
    window: retrying on the next cascade tick just wastes a turn.  This
    cooldown is applied immediately on the first such error (no threshold)
    and is significantly longer than {!cooldown_sec}. *)
let hard_quota_cooldown_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_HARD_QUOTA_COOLDOWN_SEC"
    ~deprecated:"OAS_CASCADE_HARD_QUOTA_COOLDOWN_SEC"
    ~default:3600.0
    ()

(** Cooldown duration for provider calls classified as terminal structural
    failures, where retrying the same provider on the next cascade tick is
    expected to reproduce the same failure until operator/runtime state changes. *)
let terminal_failure_cooldown_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_TERMINAL_FAILURE_COOLDOWN_SEC"
    ~deprecated:"OAS_CASCADE_TERMINAL_FAILURE_COOLDOWN_SEC"
    ~default:3600.0
    ()

(** Default cooldown applied immediately on a transient HTTP 429. *)
let soft_rate_limit_cooldown_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_SOFT_RATE_LIMIT_COOLDOWN_SEC"
    ~default:10.0
    ()

(** Upper clamp for caller-supplied Retry-After. *)
let soft_rate_limit_max_clamp_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_SOFT_RATE_LIMIT_MAX_CLAMP_SEC"
    ~default:120.0
    ()

let read_ring_size env_name =
  match Sys.getenv_opt env_name with
  | None -> 100
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = ""
      then 100
      else (
        match Safe_ops.int_of_string_safe trimmed with
        | Some n -> n
        | None ->
            Log.Misc.warn "Invalid int for %s=%S, using default 100" env_name raw;
            100)

(** Per-provider ring buffer size for recent successful-call latency. *)
let latency_ring_size = read_ring_size "MASC_CASCADE_LATENCY_RING_SIZE"

let confidence_ring_size = read_ring_size "MASC_CASCADE_CONFIDENCE_RING_SIZE"
let cost_ring_size = read_ring_size "MASC_CASCADE_COST_RING_SIZE"
