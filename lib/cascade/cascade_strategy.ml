(** See cascade_strategy.mli for documentation. *)

type signal_ctx = {
  health : Cascade_health_tracker.t;
  capacity : string -> Cascade_throttle.capacity_info option;
  now : float;
  rand_int : int -> int;
  keeper_name : string;
  cascade_name : Keeper_cascade_profile.runtime_name;
}

let signal_cascade_name ctx =
  Keeper_cascade_profile.runtime_name_to_string ctx.cascade_name

(* ── Latency-aware weight scaling (Phase: PR3 of cascade resilience) ──

   The cascade's effective weight has historically been
   [config_weight × success_rate], so two providers with comparable
   reliability rank identically even if one is 10× slower than the other.
   When latency samples are available (post-PR2 ring buffer), the
   weighted_random strategy multiplies in a [0.0–1.0] latency factor so
   the faster provider wins ties without zeroing out the slow one
   (which would create a thrashing single-provider cascade).

   Formula (intentionally simple, easy to predict):

     [latency_score = min 1.0 (latency_baseline_ms / max(p50, 1.0))]

   - p50 ≤ baseline → score = 1.0 (no penalty).
   - p50 = 2 × baseline → score = 0.5.
   - p50 = 10 × baseline → score = 0.1.
   - Unknown / no samples / [latency_ring_size <= 0] → score = 1.0
     (optimistic default — same convention as success_rate for unknown
     providers).
   - p50 < 1 ms is clamped at 1 ms in the denominator to avoid
     overflowing the score above 1.0 on extremely fast local providers
     (ollama on warm cache).

   The baseline (default 2000 ms) is tuned for cloud LLM tiers — claude
   / gpt / gemini typical p50 lands in the 1–3 second range.  Local
   providers (ollama) are typically far below baseline, so they get full
   weight; slow tail tiers (kimi cli, gemini cli) get fractional weight
   when their p50 drifts above baseline. *)
let latency_baseline_ms =
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

let latency_score_of_p50 p50 =
  let denom = Float.max p50 1.0 in
  Float.min 1.0 (latency_baseline_ms /. denom)

let latency_score_for_provider health ~provider_key =
  match Cascade_health_tracker.provider_info health ~provider_key with
  | None -> 1.0
  | Some info ->
    (match info.p50_latency_ms with
     | None -> 1.0
     | Some p50 -> latency_score_of_p50 p50)

(* ── Rate-limit recency factor (PR3b of cascade resilience) ──────────

   PR1 (#11341) introduced [Soft_rate_limited] outcomes that fire a
   short cooldown on every HTTP 429.  Once that cooldown expires the
   provider is back at full weight even if it has been hammering us
   with 429s — there is no signal carried forward.  This factor adds
   that signal: every recent [Soft_rate_limited] event in the
   {!rate_limit_recency_window_s} window decays the provider's weight
   by [rate_limit_decay_base] (default 0.5 → halve).

   The window is intentionally narrow (default 60s — short enough that
   a recovered provider is back at full weight within a minute, long
   enough to span more than one cascade attempt cycle, see
   {!default_cycle_policy}).

   Set [MASC_CASCADE_RATE_LIMIT_RECENCY_WINDOW_S=0] to disable the
   factor entirely — it is the kill switch for this PR if the
   weighting turns out to be too aggressive. *)
let rate_limit_recency_window_s =
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

(* Decay base in (0.0, 1.0).  At default 0.5, score = 0.5^count so 1
   recent 429 halves the weight, 2 quarters it, etc.  Out-of-range
   values fail closed to the default rather than silently disabling
   the signal. *)
let rate_limit_decay_base =
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

let rate_limit_skip_after =
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

let rate_limit_score_for_provider health ~provider_key =
  if rate_limit_recency_window_s <= 0.0 then 1.0
  else
    let count =
      Cascade_health_tracker.recent_outcome_count
        health
        ~provider_key
        ~outcome:Cascade_health_tracker.Outcome_soft_rate_limited
        ~window_s:rate_limit_recency_window_s
    in
    if count <= 0 then 1.0
    else if rate_limit_skip_after > 0 && count >= rate_limit_skip_after then 0.0
    else Float.pow rate_limit_decay_base (float_of_int count)

(* ── Server-error recency factor (#12797) ────────────────────────────

   Complements the rate-limit recency factor: every recent [Failure]
   event (which covers HTTP 5xx server errors) in a narrow window
   decays the provider's weight, making the ranker prefer providers
   that have been responding cleanly.

   Window: 120 s (wider than the 429 window — 5xx errors tend to clear
   more slowly than transient rate limits).
   Decay: 0.6 per failure (less aggressive than 429 to avoid
   over-penalising brief provider blips).
   Skip threshold: 4 recent failures → weight 0.0 (skip entirely).

   Set [MASC_CASCADE_SERVER_ERROR_RECENCY_WINDOW_S=0] to disable. *)
let server_error_recency_window_s =
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

let server_error_decay_base =
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

let server_error_skip_after =
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

let server_error_score_for_provider health ~provider_key =
  if server_error_recency_window_s <= 0.0 then 1.0
  else
    let count =
      Cascade_health_tracker.recent_outcome_count
        health
        ~provider_key
        ~outcome:Cascade_health_tracker.Outcome_failure
        ~window_s:server_error_recency_window_s
    in
    if count <= 0 then 1.0
    else if server_error_skip_after > 0 && count >= server_error_skip_after then begin
      Prometheus.inc_counter
        Prometheus.metric_cascade_server_error_skip_total
        ~labels:[("provider_key", provider_key)] ();
      0.0
    end else
      Float.pow server_error_decay_base (float_of_int count)

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
}

let failover = {
  kind = Failover;
  cycle = default_cycle_policy;
  tiers = [];
  sticky_ttl_ms = 0;
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
let weighted_shuffle adapter ctx cands =
  (* Compute health-adjusted weight per candidate.

     Base weight is [config_weight × success_rate] (cooldown → 0).  Three
     [0.0–1.0] adaptive factors are multiplied in before the random
     pick:

       - [lat] — latency score, decays as p50 climbs above
         {!latency_baseline_ms}.  Providers without samples get 1.0.
       - [rl]  — rate-limit recency score, decays as
         [decay_base ^ count] for [Soft_rate_limited] events in the
         {!rate_limit_recency_window_s} window.  Providers with no
         recent 429 hit get 1.0.
       - [se]  — server-error recency score (#12797), decays for recent
         [Failure] events (5xx) in {!server_error_recency_window_s}.

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
             let lat = latency_score_for_provider ctx.health ~provider_key in
             let rl  = rate_limit_score_for_provider ctx.health ~provider_key in
             let se  = server_error_score_for_provider ctx.health ~provider_key in
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
    let in_tier c = List.mem (adapter.health_key c) allowed in
    let tier_cands = List.filter in_tier cands in
    (* Starvation guard: if every tier candidate reports capacity=0, fall
       through with the unfiltered tier list so at least one call is
       attempted and the real upstream error (rate limit, auth) surfaces
       instead of silently exhausting the cascade.  Mirrors
       weighted_shuffle's guard at [weighted_shuffle]:140-145. *)
    let with_capacity = filter_capacity adapter ctx tier_cands in
    if with_capacity = [] then tier_cands else with_capacity

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
          cascade.json reload).  Fall back to plain Failover. *)
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
    weighted_shuffle adapter ctx cands
  | Circuit_breaker_cycling ->
    let cooled = filter_cooldown adapter ctx cands in
    (* Starvation guard: same pattern as priority_tier_order.  When all
       candidates report capacity=0 the cascade would otherwise exit
       with no real call attempt — prefer to try once and let the real
       error surface. *)
    let with_capacity = filter_capacity adapter ctx cooled in
    if with_capacity = [] then cooled else with_capacity
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
