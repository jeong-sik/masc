(** See cascade_strategy.mli for documentation. *)

type signal_ctx = {
  health : Cascade_health_tracker.t;
  capacity : string -> Cascade_throttle.capacity_info option;
  now : float;
  rand_int : int -> int;
  keeper_name : string;
  cascade_name : Cascade_ref.runtime_name;
}

let signal_cascade_name ctx =
  Cascade_ref.runtime_name_to_string ctx.cascade_name

(* ── Scoring parameters (configurable via TOML / env vars) ─────────

   These parameters control how the [Weighted_random] strategy scores
   providers based on latency, rate-limit recency, and server-error
   recency.  Each has a documented default that preserves the
   pre-existing behaviour when no override is provided.

   Resolution order: TOML profile field → env var → compiled default.

   The [scoring_params] record is carried inside {!t} so each cascade
   can have independent tuning.  The module-level env-var-backed
   defaults remain as fallbacks for callers that construct strategies
   without a TOML profile (e.g. {!failover}). *)

(** Configurable scoring parameters for the [Weighted_random] strategy.

    Each field documents its default, meaning, and the env-var fallback
    used when the TOML profile does not override it. *)
type scoring_params = {
  (* ── Latency scoring ──

     Formula: [latency_score = min 1.0 (baseline / max(p50, 1.0))]

     - p50 ≤ baseline → score = 1.0 (no penalty).
     - p50 = 2 × baseline → score = 0.5.
     - Unknown / no samples → score = 1.0 (optimistic default).
     - p50 < 1 ms clamped at 1 ms in denominator to avoid overflow. *)
  latency_baseline_ms : float;
  (** Milliseconds.  Provider p50 above this value incurs a fractional
      score penalty.  Default 2000.0 (tuned for cloud LLM tiers:
      claude/gpt/gemini typical p50 is 1–3 s).  Env var fallback:
      [MASC_CASCADE_LATENCY_BASELINE_MS]. *)

  (* ── Rate-limit recency scoring ──

     Every recent [Soft_rate_limited] (HTTP 429) event in the window
     decays the provider's weight by [rate_limit_decay_base ^ count].
     A provider reaching [rate_limit_skip_after] events gets weight 0.0
     (skipped entirely). *)
  rate_limit_recency_window_s : float;
  (** Seconds.  Lookback window for counting recent 429 events.
      Default 60.0 (short enough for recovery within a minute, long
      enough to span more than one cascade cycle).  Set to 0.0 to
      disable the factor.  Env var: [MASC_CASCADE_RATE_LIMIT_RECENCY_WINDOW_S]. *)

  rate_limit_decay_base : float;
  (** Per-event decay multiplier in (0.0, 1.0).  Default 0.5 (each
      recent 429 halves the weight).  Out-of-range values fall back to
      the default.  Env var: [MASC_CASCADE_RATE_LIMIT_DECAY_BASE]. *)

  rate_limit_skip_after : int;
  (** Hard-skip threshold.  Provider with ≥ this many recent 429s
      within the window gets weight 0.0.  Default 3.  Set to 0 to
      disable hard-skip (only decay applies).  Env var:
      [MASC_CASCADE_RATE_LIMIT_SKIP_AFTER]. *)

  (* ── Server-error recency scoring (#12797) ──

     Mirrors the rate-limit factor but for [Failure] events (HTTP 5xx).
     Window is wider because 5xx errors tend to clear more slowly than
     transient rate limits. *)
  server_error_recency_window_s : float;
  (** Seconds.  Lookback window for counting recent 5xx events.
      Default 120.0 (wider than the 429 window).  Set to 0.0 to
      disable.  Env var:
      [MASC_CASCADE_SERVER_ERROR_RECENCY_WINDOW_S]. *)

  server_error_decay_base : float;
  (** Per-event decay multiplier in (0.0, 1.0).  Default 0.6 (less
      aggressive than 429 to avoid over-penalising brief blips).
      Env var: [MASC_CASCADE_SERVER_ERROR_DECAY_BASE]. *)

  server_error_skip_after : int;
  (** Hard-skip threshold.  Default 4 (more forgiving than the 429
      threshold of 3).  Env var:
      [MASC_CASCADE_SERVER_ERROR_SKIP_AFTER]. *)
}

(* ── Env-var fallbacks (used when no TOML override is provided) ── *)

let env_latency_baseline_ms =
  match Sys.getenv_opt "MASC_CASCADE_LATENCY_BASELINE_MS" with
  | None -> 2000.0
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then 2000.0
    else
      match Safe_ops.float_of_string_safe trimmed with
      | Some n when n > 0.0 -> n
      | _ ->
        Log.Misc.warn
          "Invalid float for MASC_CASCADE_LATENCY_BASELINE_MS=%S, using default 2000.0"
          raw;
        2000.0

let env_rate_limit_recency_window_s =
  match Sys.getenv_opt "MASC_CASCADE_RATE_LIMIT_RECENCY_WINDOW_S" with
  | None -> 60.0
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then 60.0
    else
      match Safe_ops.float_of_string_safe trimmed with
      | Some n -> n
      | None ->
        Log.Misc.warn
          "Invalid float for MASC_CASCADE_RATE_LIMIT_RECENCY_WINDOW_S=%S, \
           using default 60.0" raw;
        60.0

let env_rate_limit_decay_base =
  match Sys.getenv_opt "MASC_CASCADE_RATE_LIMIT_DECAY_BASE" with
  | None -> 0.5
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then 0.5
    else
      match Safe_ops.float_of_string_safe trimmed with
      | Some n when n > 0.0 && n < 1.0 -> n
      | _ ->
        Log.Misc.warn
          "Invalid decay base for MASC_CASCADE_RATE_LIMIT_DECAY_BASE=%S \
           (must be in (0.0, 1.0)), using default 0.5" raw;
        0.5

let env_rate_limit_skip_after =
  match Sys.getenv_opt "MASC_CASCADE_RATE_LIMIT_SKIP_AFTER" with
  | None -> 3
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then 3
    else
      match Safe_ops.int_of_string_safe trimmed with
      | Some n when n >= 0 -> n
      | _ ->
        Log.Misc.warn
          "Invalid int for MASC_CASCADE_RATE_LIMIT_SKIP_AFTER=%S, using default 3"
          raw;
        3

let env_server_error_recency_window_s =
  match Sys.getenv_opt "MASC_CASCADE_SERVER_ERROR_RECENCY_WINDOW_S" with
  | None -> 120.0
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then 120.0
    else
      match Safe_ops.float_of_string_safe trimmed with
      | Some n -> n
      | None ->
        Log.Misc.warn
          "Invalid float for MASC_CASCADE_SERVER_ERROR_RECENCY_WINDOW_S=%S, \
           using default 120.0" raw;
        120.0

let env_server_error_decay_base =
  match Sys.getenv_opt "MASC_CASCADE_SERVER_ERROR_DECAY_BASE" with
  | None -> 0.6
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then 0.6
    else
      match Safe_ops.float_of_string_safe trimmed with
      | Some n when n > 0.0 && n < 1.0 -> n
      | _ ->
        Log.Misc.warn
          "Invalid decay base for MASC_CASCADE_SERVER_ERROR_DECAY_BASE=%S \
           (must be in (0.0, 1.0)), using default 0.6" raw;
        0.6

let env_server_error_skip_after =
  match Sys.getenv_opt "MASC_CASCADE_SERVER_ERROR_SKIP_AFTER" with
  | None -> 4
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then 4
    else
      match Safe_ops.int_of_string_safe trimmed with
      | Some n when n >= 0 -> n
      | _ ->
        Log.Misc.warn
          "Invalid int for MASC_CASCADE_SERVER_ERROR_SKIP_AFTER=%S, using default 4"
          raw;
        4

(** Default scoring params using env-var overrides, falling back to
    compiled defaults when the env var is unset/invalid.  This is the
    value used by {!failover} and by callers that do not load a TOML
    profile. *)
let default_scoring_params = {
  latency_baseline_ms = env_latency_baseline_ms;
  rate_limit_recency_window_s = env_rate_limit_recency_window_s;
  rate_limit_decay_base = env_rate_limit_decay_base;
  rate_limit_skip_after = env_rate_limit_skip_after;
  server_error_recency_window_s = env_server_error_recency_window_s;
  server_error_decay_base = env_server_error_decay_base;
  server_error_skip_after = env_server_error_skip_after;
}

(* ── Scoring functions (parameterised) ──────────────────────────── *)

let latency_score_of_p50 ~baseline p50 =
  let denom = Float.max p50 1.0 in
  Float.min 1.0 (baseline /. denom)

let latency_score_for_provider health ~provider_key =
  (* Public API: uses the env-var-backed global default baseline so
     external callers (e.g. Cascade_inventory) do not need to thread
     a [scoring_params] record. *)
  match Cascade_health_tracker.provider_info health ~provider_key with
  | None -> 1.0
  | Some info ->
    (match info.p50_latency_ms with
     | None -> 1.0
     | Some p50 -> latency_score_of_p50 ~baseline:env_latency_baseline_ms p50)

let latency_score_for_provider_with ~baseline health ~provider_key =
  (* Internal: parameterised version used by [weighted_shuffle]. *)
  match Cascade_health_tracker.provider_info health ~provider_key with
  | None -> 1.0
  | Some info ->
    (match info.p50_latency_ms with
     | None -> 1.0
     | Some p50 -> latency_score_of_p50 ~baseline p50)

let rate_limit_score_for_provider health ~provider_key =
  (* Public API: uses env-var-backed global defaults. *)
  if env_rate_limit_recency_window_s <= 0.0 then 1.0
  else
    let count =
      Cascade_health_tracker.recent_outcome_count
        health
        ~provider_key
        ~outcome:Cascade_health_tracker.Outcome_soft_rate_limited
        ~window_s:env_rate_limit_recency_window_s
    in
    if count <= 0 then 1.0
    else if env_rate_limit_skip_after > 0 && count >= env_rate_limit_skip_after then 0.0
    else Float.pow env_rate_limit_decay_base (float_of_int count)

let rate_limit_score_for_provider_with
    ~window_s ~decay_base ~skip_after
    health ~provider_key =
  (* Internal: parameterised version. *)
  if window_s <= 0.0 then 1.0
  else
    let count =
      Cascade_health_tracker.recent_outcome_count
        health
        ~provider_key
        ~outcome:Cascade_health_tracker.Outcome_soft_rate_limited
        ~window_s
    in
    if count <= 0 then 1.0
    else if skip_after > 0 && count >= skip_after then 0.0
    else Float.pow decay_base (float_of_int count)

let server_error_score_for_provider health ~provider_key =
  (* Public API: uses env-var-backed global defaults. *)
  if env_server_error_recency_window_s <= 0.0 then 1.0
  else
    let count =
      Cascade_health_tracker.recent_outcome_count
        health
        ~provider_key
        ~outcome:Cascade_health_tracker.Outcome_failure
        ~window_s:env_server_error_recency_window_s
    in
    if count <= 0 then 1.0
    else if env_server_error_skip_after > 0 && count >= env_server_error_skip_after then begin
      Prometheus.inc_counter
        Prometheus.metric_cascade_server_error_skip_total
        ~labels:[("provider_key", provider_key)] ();
      0.0
    end else
      Float.pow env_server_error_decay_base (float_of_int count)

let server_error_score_for_provider_with
    ~window_s ~decay_base ~skip_after
    health ~provider_key =
  (* Internal: parameterised version. *)
  if window_s <= 0.0 then 1.0
  else
    let count =
      Cascade_health_tracker.recent_outcome_count
        health
        ~provider_key
        ~outcome:Cascade_health_tracker.Outcome_failure
        ~window_s
    in
    if count <= 0 then 1.0
    else if skip_after > 0 && count >= skip_after then begin
      Prometheus.inc_counter
        Prometheus.metric_cascade_server_error_skip_total
        ~labels:[("provider_key", provider_key)] ();
      0.0
    end else
      Float.pow decay_base (float_of_int count)

type cycle_policy = {
  max_cycles : int;
  backoff_base_ms : int;
  backoff_cap_ms : int;
}

let default_cycle_policy = {
  max_cycles = 1;
  backoff_base_ms = 500;
  backoff_cap_ms = 10_000;
}

let backoff_ms policy ~cycle =
  if cycle <= 0 then 0
  else
    (* Exponential: base * 2^(cycle-1), capped.  Use bit shift but
       guard against integer overflow on large cycle counts — cap
       kicks in well before 2^30 on any reasonable config. *)
    let shift = min (cycle - 1) 30 in
    let raw = policy.backoff_base_ms lsl shift in
    let raw = if raw < 0 then policy.backoff_cap_ms else raw in
    min policy.backoff_cap_ms raw

type kind =
  | Failover [@tla.symbol "failover"]
  | Capacity_aware [@tla.symbol "capacity_aware"]
  | Weighted_random [@tla.symbol "weighted_random"]
  | Circuit_breaker_cycling [@tla.symbol "circuit_breaker_cycling"]
  | Priority_tier [@tla.symbol "priority_tier"]
  | Sticky [@tla.symbol "sticky"]
  | Round_robin [@tla.symbol "round_robin"]
[@@deriving tla]

let kind_to_string = function
  | Failover -> "failover"
  | Capacity_aware -> "capacity_aware"
  | Weighted_random -> "weighted_random"
  | Circuit_breaker_cycling -> "circuit_breaker_cycling"
  | Priority_tier -> "priority_tier"
  | Sticky -> "sticky"
  | Round_robin -> "round_robin"

(* Issue #8603: SSOT helpers — replace hard-coded list in [parse_kind]'s
   Error arm so adding an 8th constructor updates the operator-visible
   error message automatically. Same Variant SSOT shape as #8486 /
   #8467 / #8592 / #8601. *)
let all_kinds = [
  Failover;
  Capacity_aware;
  Weighted_random;
  Circuit_breaker_cycling;
  Priority_tier;
  Sticky;
  Round_robin;
]

let valid_kind_strings = List.map kind_to_string all_kinds

let parse_kind = function
  | "failover" -> Ok Failover
  | "capacity_aware" -> Ok Capacity_aware
  | "weighted_random" -> Ok Weighted_random
  | "circuit_breaker_cycling" -> Ok Circuit_breaker_cycling
  | "priority_tier" -> Ok Priority_tier
  | "sticky" -> Ok Sticky
  | "round_robin" -> Ok Round_robin
  | other ->
    Error (Printf.sprintf
             "unknown cascade strategy %S (expected one of: %s)"
             other (String.concat ", " valid_kind_strings))

let default_sticky_ttl_ms = 300_000

type t = {
  kind : kind;
  cycle : cycle_policy;
  tiers : string list list;
  sticky_ttl_ms : int;
  scoring : scoring_params;
  (** Scoring parameters used by [Weighted_random] to compute per-provider
      weight multipliers.  Defaults to {!default_scoring_params} (env-var
      overrides → compiled defaults).  Configurable per-cascade via TOML
      profile fields ([latency_baseline_ms], [rate_limit_recency_window_s],
      etc.).  Stateless strategies ([Failover], [Capacity_aware]) ignore
      this field. *)
}

let failover = {
  kind = Failover;
  cycle = default_cycle_policy;
  tiers = [];
  sticky_ttl_ms = 0;
  scoring = default_scoring_params;
}

type 'a adapter = {
  health_key : 'a -> string;
  capacity_key : 'a -> string;
  weight : 'a -> int;
}

(* ── Filters ────────────────────────────────────────────────────── *)

let has_capacity ctx ~url =
  match ctx.capacity url with
  | None -> true                          (* unknown → fail-open *)
  | Some info -> info.Cascade_throttle.process_available > 0

let filter_capacity adapter ctx cands =
  List.filter (fun c -> has_capacity ctx ~url:(adapter.capacity_key c)) cands

let filter_cooldown adapter ctx cands =
  List.filter
    (fun c ->
       not (Cascade_health_tracker.is_in_cooldown ctx.health
              ~provider_key:(adapter.health_key c)))
    cands

(* ── Weighted shuffle ───────────────────────────────────────────── *)

(* Weighted-random permutation using effective_weight from the health
   tracker. Zero-weight candidates (cooldown) are filtered. When every
   candidate is cooled down, return [[]] so the caller can surface the
   filtered-empty state instead of reviving a provider that was
   intentionally put into cooldown (e.g. hard quota exhausted). *)
let weighted_shuffle ~scoring adapter ctx cands =
  (* Compute health-adjusted weight per candidate.

     Base weight is [config_weight × success_rate] (cooldown → 0).  Three
     [0.0–1.0] adaptive factors are multiplied in before the random
     pick:

       - [lat] — latency score, decays as p50 climbs above
         {!scoring.latency_baseline_ms}.  Providers without samples get 1.0.
       - [rl]  — rate-limit recency score, decays as
         [decay_base ^ count] for [Soft_rate_limited] events in the
         {!scoring.rate_limit_recency_window_s} window.  Providers with no
         recent 429 hit get 1.0.
       - [se]  — server-error recency score (#12797), decays for recent
         [Failure] events (5xx) in {!scoring.server_error_recency_window_s}.

     Cooled-down providers stay at 0.  Latency never zeroes a provider,
     but a sustained rate-limit burst or server-error storm may return
     [rl = 0.0] / [se = 0.0] and remove the provider for this ordering
     pass; otherwise the [max 1] guard prevents tiny fractional weights
     from rounding to zero. *)
  let weighted = List.map
      (fun c ->
         let provider_key = adapter.health_key c in
         let ew = Cascade_health_tracker.effective_weight ctx.health
             ~provider_key
             ~config_weight:(adapter.weight c)
         in
         let final =
           if ew <= 0 then 0
           else
             let lat = latency_score_for_provider_with
                 ~baseline:scoring.latency_baseline_ms
                 ctx.health ~provider_key in
             let rl  = rate_limit_score_for_provider_with
                 ~window_s:scoring.rate_limit_recency_window_s
                 ~decay_base:scoring.rate_limit_decay_base
                 ~skip_after:scoring.rate_limit_skip_after
                 ctx.health ~provider_key in
             let se  = server_error_score_for_provider_with
                 ~window_s:scoring.server_error_recency_window_s
                 ~decay_base:scoring.server_error_decay_base
                 ~skip_after:scoring.server_error_skip_after
                 ctx.health ~provider_key in
             if lat <= 0.0 || rl <= 0.0 || se <= 0.0 then 0
             else max 1 (int_of_float (float_of_int ew *. lat *. rl *. se))
         in
         (c, final))
      cands
  in
  let active = List.filter (fun (_, w) -> w > 0) weighted in
  (* Sequential weighted pick without replacement. *)
  let rec pick acc remaining =
    match remaining with
    | [] -> List.rev acc
    | _ ->
      let total = List.fold_left (fun s (_, w) -> s + w) 0 remaining in
      if total <= 0 then List.rev_append acc (List.map fst remaining)
      else
        let r = ctx.rand_int total in
        let rec step consumed = function
          | [] ->
            (* Shouldn't happen: r < total, so we must land on a
               candidate.  Guard against FP/RNG misuse. *)
            (List.map fst remaining |> List.rev_append acc)
          | (c, w) :: rest ->
            if r < consumed + w then
              let kept = List.filter (fun (c', _) -> c' != c) remaining in
              pick (c :: acc) kept
            else
              step (consumed + w) rest
        in
        step 0 remaining
  in
  pick [] active

(* ── Priority tier ──────────────────────────────────────────────── *)

(* Pick the tier for [cycle], clamped to the last tier when [cycle]
   exceeds [length tiers - 1].  Returns [[]] when [tiers] is empty
   (no usable configuration → starvation guard handled at caller). *)
let tier_for_cycle tiers ~cycle =
  match tiers with
  | [] -> []
  | _ ->
    let n = List.length tiers in
    let idx = if cycle >= n then n - 1 else max 0 cycle in
    match List.nth_opt tiers idx with
    | Some tier -> tier
    | None -> []

let priority_tier_order adapter ctx ~tiers ~cycle cands =
  let allowed = tier_for_cycle tiers ~cycle in
  match allowed with
  | [] -> []
  | _ ->
    (* Materialise [allowed] as a Hashtbl once so the per-candidate
       membership check is O(1); prior shape did [List.mem health_key
       allowed] per candidate, i.e. O(C x A) per ordering call. *)
    let allowed_set = Hashtbl.create (List.length allowed) in
    List.iter (fun name -> Hashtbl.replace allowed_set name ()) allowed;
    let in_tier c = Hashtbl.mem allowed_set (adapter.health_key c) in
    let tier_cands = List.filter in_tier cands in
    (* Starvation guard: if every tier candidate reports capacity=0, fall
       through with the unfiltered tier list so at least one call is
       attempted and the real upstream error (rate limit, auth) surfaces
       instead of silently exhausting the cascade.  Mirrors
       weighted_shuffle guard at [weighted_shuffle]:140-145.  Iter 22
       telemetry: ticks [Cascade_metrics.on_strategy_starvation_guard]
       so the fail-open rate is observable per cascade. *)
    let with_capacity = filter_capacity adapter ctx tier_cands in
    if with_capacity = [] then (
      Cascade_metrics.on_strategy_starvation_guard
        ~cascade:(signal_cascade_name ctx)
        ~strategy:"priority_tier";
      tier_cands)
    else with_capacity

(* ── Sticky ─────────────────────────────────────────────────────── *)

let sticky_order adapter ctx cands =
  let cascade = signal_cascade_name ctx in
  match
    Cascade_state.lookup_sticky
      ~keeper:ctx.keeper_name
      ~cascade
      ~now:ctx.now
  with
  | None -> cands
  | Some pinned ->
    (match List.find_opt
             (fun c -> adapter.health_key c = pinned)
             cands
     with
     | Some c -> [c]
     | None ->
       (* Pinned provider no longer in candidate list (config drift,
          cascade.toml reload, provider deprecation).  Fall back to
          plain Failover.  Iter 23 telemetry: ticks
          [Cascade_metrics.on_sticky_drift] so the drift rate is
          observable per cascade rather than living only in this
          comment. *)
       Cascade_metrics.on_sticky_drift ~cascade;
       cands)

(* ── Round-robin ────────────────────────────────────────────────── *)

(* Rotation: take cursor mod len, return [tail @ head] where the
   first [cursor] elements move to the back.  Cursor advances on
   every call, even when the cascade ends up using a later element —
   the goal is cross-call fairness, not per-attempt fairness. *)
let round_robin_order ctx cands =
  let n = List.length cands in
  if n <= 1 then cands
  else
    let cursor =
      Cascade_state.rotate_round_robin
        ~cascade:(signal_cascade_name ctx)
        ~bound:n
    in
    let head, tail =
      let rec split i acc = function
        | xs when i <= 0 -> (List.rev acc, xs)
        | [] -> (List.rev acc, [])
        | x :: rest -> split (i - 1) (x :: acc) rest
      in
      split cursor [] cands
    in
    tail @ head

(* ── Public ordering ────────────────────────────────────────────── *)

let order_candidates t ~adapter ~ctx ~cycle cands =
  match t.kind with
  | Failover ->
    filter_cooldown adapter ctx cands
  | Capacity_aware ->
    filter_capacity adapter ctx cands
  | Weighted_random ->
    weighted_shuffle ~scoring:t.scoring adapter ctx cands
  | Circuit_breaker_cycling ->
    let cooled = filter_cooldown adapter ctx cands in
    (* Starvation guard: same pattern as priority_tier_order.  When all
       candidates report capacity=0 the cascade would otherwise exit
       with no real call attempt — prefer to try once and let the real
       error surface.  Iter 22 telemetry: ticks
       [Cascade_metrics.on_strategy_starvation_guard] so the fail-open
       rate is observable per cascade. *)
    let with_capacity = filter_capacity adapter ctx cooled in
    if with_capacity = [] then (
      Cascade_metrics.on_strategy_starvation_guard
        ~cascade:(signal_cascade_name ctx)
        ~strategy:"circuit_breaker_cycling";
      cooled)
    else with_capacity
  | Priority_tier ->
    priority_tier_order adapter ctx ~tiers:t.tiers ~cycle cands
  | Sticky ->
    sticky_order adapter ctx cands
  | Round_robin ->
    round_robin_order ctx cands

(* ── Stateful hooks ─────────────────────────────────────────────── *)

let record_choice t ~ctx ~provider_key =
  match t.kind with
  | Sticky ->
    let cascade = signal_cascade_name ctx in
    Cascade_state.record_sticky_choice
      ~keeper:ctx.keeper_name
      ~cascade
      ~provider:provider_key
      ~ttl_ms:t.sticky_ttl_ms
      ~now:ctx.now
  | Failover
  | Capacity_aware
  | Weighted_random
  | Circuit_breaker_cycling
  | Priority_tier
  | Round_robin ->
    ()
