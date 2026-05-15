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
  | Priority_tier [@tla.symbol "priority_tier"]
[@@deriving tla]

let kind_to_string = function
  | Failover -> "failover"
  | Priority_tier -> "priority_tier"

(* Issue #8603: SSOT helpers — replace hard-coded list in [parse_kind]'s
   Error arm so adding an 8th constructor updates the operator-visible
   error message automatically. Same Variant SSOT shape as #8486 /
   #8467 / #8592 / #8601. *)
let all_kinds = [
  Failover;
  Priority_tier;
]

let valid_kind_strings = List.map kind_to_string all_kinds

let config_kind_strings = [ "failover"; "priority_tier" ]

let parse_kind = function
  | "failover" -> Ok Failover
  | "priority_tier" -> Ok Priority_tier
  | other ->
    Error (Printf.sprintf
             "unknown cascade strategy %S (expected one of: %s)"
             other (String.concat ", " valid_kind_strings))

let parse_config_kind raw =
  match parse_kind raw with
  | Error msg ->
    Error
      (Printf.sprintf
         "unsupported cascade config strategy %S (expected one of: %s): %s"
         raw (String.concat ", " config_kind_strings) msg)
  | Ok kind -> Ok kind

type t = {
  kind : kind;
  cycle : cycle_policy;
  tiers : string list list;
}

let failover = {
  kind = Failover;
  cycle = default_cycle_policy;
  tiers = [];
}

type 'a adapter = {
  health_key : 'a -> string;
  capacity_key : 'a -> string;
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
       instead of silently exhausting the cascade. *)
    let with_capacity = filter_capacity adapter ctx tier_cands in
    if with_capacity = [] then (
      Cascade_metrics.on_strategy_starvation_guard
        ~cascade:(signal_cascade_name ctx)
        ~strategy:"priority_tier";
      tier_cands)
    else with_capacity

(* ── Public ordering ────────────────────────────────────────────── *)

let order_candidates t ~adapter ~ctx ~cycle cands =
  match t.kind with
  | Failover ->
    filter_cooldown adapter ctx cands
  | Priority_tier ->
    priority_tier_order adapter ctx ~tiers:t.tiers ~cycle cands

let latency_score_of_p50_ms = function
  | ms when (not (Float.is_finite ms)) || ms <= 0.0 -> 1.0
  | ms when ms <= 1000.0 -> 1.0
  | ms when ms <= 3000.0 -> 0.8
  | ms when ms <= 5000.0 -> 0.6
  | ms when ms <= 15000.0 -> 0.4
  | ms when ms <= 30000.0 -> 0.2
  | _ -> 0.1

let latency_score_for_provider health ~provider_key =
  match Cascade_health_tracker.provider_info health ~provider_key with
  | None -> 1.0
  | Some info ->
    (match info.Cascade_health_tracker.p50_latency_ms with
     | None -> 1.0
     | Some p50 -> latency_score_of_p50_ms p50)

(* ── Stateful hooks ─────────────────────────────────────────────── *)

let record_choice _t ~ctx:_ ~provider_key:_ = ()
