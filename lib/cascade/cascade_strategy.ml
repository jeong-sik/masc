(** See cascade_strategy.mli for documentation. *)

type signal_ctx = {
  health : Cascade_health_tracker.t;
  capacity : string -> Cascade_throttle.capacity_info option;
  now : float;
  rand_int : int -> int;
  keeper_name : string;
  cascade_name : string;
}

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
  | Failover
  | Capacity_aware
  | Weighted_random
  | Circuit_breaker_cycling
  | Priority_tier
  | Sticky
  | Round_robin

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
  (* Compute health-adjusted weight per candidate.  The base weight from
     the tracker reflects [config_weight * success_rate], with [0] for
     cooled-down providers.  We multiply in a [0.0–1.0] latency factor
     when the tracker has accumulated p50 samples; cooled-down providers
     stay at 0 (the multiplication preserves zero), and providers
     without latency samples get factor 1.0 (no change vs prior behavior).
     The [max 1] guard prevents a slow-but-alive provider from getting
     zeroed out purely from latency — strategy still gives it a chance
     each cycle, just with less probability than its peers. *)
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
             max 1 (int_of_float (float_of_int ew *. lat))
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
  match
    Cascade_state.lookup_sticky
      ~keeper:ctx.keeper_name
      ~cascade:ctx.cascade_name
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
        ~cascade:ctx.cascade_name
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
    Cascade_state.record_sticky_choice
      ~keeper:ctx.keeper_name
      ~cascade:ctx.cascade_name
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
