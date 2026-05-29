(** See cascade_strategy.mli for documentation. *)

type signal_ctx = {
  health : Cascade_health_tracker.t;
  capacity : string -> Cascade_throttle.capacity_info option;
  now : float;
  rand_int : int -> int;
  keeper_name : string;
  cascade_name : Cascade_name.t;
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
  | Failover [@tla.symbol "failover"]
[@@deriving tla]

let kind_to_string = function
  | Failover -> "failover"

(* Issue #8603: SSOT helpers — the [parse_kind] Error arm lists
   [valid_kind_strings] (derived from [all_kinds]) so adding a second
   constructor updates the operator-visible error message automatically.
   Same Variant SSOT shape as #8486 / #8467 / #8592 / #8601. *)
let all_kinds = [
  Failover;
]

let valid_kind_strings = List.map kind_to_string all_kinds

let config_kind_strings = [ "failover" ]

let parse_kind = function
  | "failover" -> Ok Failover
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
}

let failover = {
  kind = Failover;
  cycle = default_cycle_policy;
}

type 'a adapter = {
  health_key : 'a -> string;
  capacity_key : 'a -> string;
}

(* ── Filters ────────────────────────────────────────────────────── *)

let key_is_full ctx key =
  match ctx.capacity key with
  | Some info -> info.Cascade_throttle.process_available <= 0
  | None -> false

let dedupe_full_capacity_keys adapter ctx cands =
  let seen_full = Hashtbl.create (List.length cands) in
  cands
  |> List.filter (fun c ->
         let key = String.trim (adapter.capacity_key c) in
         if String.equal key "" || not (key_is_full ctx key)
         then true
         else if Hashtbl.mem seen_full key
         then false
         else (
           Hashtbl.replace seen_full key ();
           true))

let filter_cooldown adapter ctx cands =
  List.filter
    (fun c ->
       not (Cascade_health_tracker.is_in_cooldown ctx.health
              ~provider_key:(adapter.health_key c)))
    cands

(* ── Public ordering ────────────────────────────────────────────── *)

let order_candidates t ~adapter ~ctx ~cycle:_ cands =
  match t.kind with
  | Failover ->
    filter_cooldown adapter ctx cands
    |> dedupe_full_capacity_keys adapter ctx

(* ── Stateful hooks ─────────────────────────────────────────────── *)

let record_choice _t ~ctx:_ ~provider_key:_ = ()
