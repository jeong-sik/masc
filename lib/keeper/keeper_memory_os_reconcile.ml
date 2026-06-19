(** Keeper_memory_os_reconcile — RFC-0259 §3.3 grounding reconciler (P2 core).

    See the .mli for the boundary rationale. This module is pure: the only IO (a
    [gh] call) is the injected {!verify_fn}. *)

open Keeper_memory_os_types

type external_state =
  | Still_open
  | Terminal
  | Unverifiable

type verify_fn = external_ref -> external_state

type verdict =
  | Fresh
  | Stale_open
  | Stale_terminal
  | Stale_unknown

let verdict_to_string = function
  | Fresh -> "fresh"
  | Stale_open -> "stale_open"
  | Stale_terminal -> "stale_terminal"
  | Stale_unknown -> "stale_unknown"
;;

(* Re-ground at half the volatile TTL so a still-true ref is confirmed (and would
   have its last_verified_at advanced by P3) before the TTL would hard-expire it. *)
let default_grounding_horizon_seconds = volatile_external_ttl_seconds /. 2.0

(* The reference time a fact was last known good: last_verified_at if set, else
   first_seen — a never-re-verified fact is as old as its extraction. *)
let reference_time (f : fact) =
  match f.last_verified_at with
  | Some t -> t
  | None -> f.first_seen
;;

let classify ~now ~horizon ~(verify : verify_fn) (f : fact) : verdict =
  match f.external_ref with
  | None -> Fresh
  | Some r ->
    if now -. reference_time f <= horizon
    then Fresh
    else (
      match verify r with
      | Still_open -> Stale_open
      | Terminal -> Stale_terminal
      | Unverifiable -> Stale_unknown)
;;

type dry_run_report =
  { scanned : int
  ; stale_open : int
  ; stale_terminal : int
  ; stale_unknown : int
  }

let empty_report = { scanned = 0; stale_open = 0; stale_terminal = 0; stale_unknown = 0 }

let dry_run ~now ~horizon ~verify (facts : fact list)
  : dry_run_report * (fact * verdict) list
  =
  let report, rev_items =
    List.fold_left
      (fun (report, items) f ->
        let v = classify ~now ~horizon ~verify f in
        let report = { report with scanned = report.scanned + 1 } in
        match v with
        | Fresh -> report, items
        | Stale_open ->
          { report with stale_open = report.stale_open + 1 }, (f, v) :: items
        | Stale_terminal ->
          { report with stale_terminal = report.stale_terminal + 1 }, (f, v) :: items
        | Stale_unknown ->
          { report with stale_unknown = report.stale_unknown + 1 }, (f, v) :: items)
      (empty_report, [])
      facts
  in
  report, List.rev rev_items
;;
