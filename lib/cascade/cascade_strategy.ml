(** See cascade_strategy.mli for documentation. *)

type signal_ctx = {
  health : Cascade_health_tracker.t;
  capacity : string -> Cascade_throttle.capacity_info option;
  now : float;
  rand_int : int -> int;
}

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

let kind_to_string = function
  | Failover -> "failover"
  | Capacity_aware -> "capacity_aware"
  | Weighted_random -> "weighted_random"
  | Circuit_breaker_cycling -> "circuit_breaker_cycling"

let parse_kind = function
  | "failover" -> Ok Failover
  | "capacity_aware" -> Ok Capacity_aware
  | "weighted_random" -> Ok Weighted_random
  | "circuit_breaker_cycling" -> Ok Circuit_breaker_cycling
  | other ->
    Error (Printf.sprintf
             "unknown cascade strategy %S (expected one of: \
              failover, capacity_aware, weighted_random, \
              circuit_breaker_cycling)" other)

type t = {
  kind : kind;
  cycle : cycle_policy;
}

let failover = { kind = Failover; cycle = default_cycle_policy }

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
   tracker.  Zero-weight candidates (cooldown) are filtered, with the
   guarantee that at least one candidate survives (the full input list)
   to avoid starvation — mirrors
   [Cascade_config.order_weighted_entries]:435-439. *)
let weighted_shuffle adapter ctx cands =
  (* Compute health-adjusted weight per candidate. *)
  let weighted = List.map
      (fun c ->
         let ew = Cascade_health_tracker.effective_weight ctx.health
             ~provider_key:(adapter.health_key c)
             ~config_weight:(adapter.weight c)
         in
         (c, max 0 ew))
      cands
  in
  let active = List.filter (fun (_, w) -> w > 0) weighted in
  let effective =
    if active = [] then
      (* Starvation guard: fall back to the original list, each with
         weight 1, so that at least one call attempt is made. *)
      List.map (fun (c, _) -> (c, 1)) weighted
    else active
  in
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
  pick [] effective

(* ── Public ordering ────────────────────────────────────────────── *)

let order_candidates t ~adapter ~ctx ~cycle:_ cands =
  match t.kind with
  | Failover ->
    cands
  | Capacity_aware ->
    filter_capacity adapter ctx cands
  | Weighted_random ->
    weighted_shuffle adapter ctx cands
  | Circuit_breaker_cycling ->
    cands
    |> filter_cooldown adapter ctx
    |> filter_capacity adapter ctx
