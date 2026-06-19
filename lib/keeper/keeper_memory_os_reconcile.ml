(** Keeper_memory_os_reconcile — RFC-0259 §3.3/§3.4 grounding reconciler.

    The classification core (P2) is pure — the only external IO is the injected
    {!verify_fn}. The retraction write path (P3, [run_reconcile]) persists the
    result under the per-keeper facts lock. See the .mli for the boundary
    rationale. *)

open Keeper_memory_os_types
module Io = Keeper_memory_os_io

(* Raised when the store cannot be fully parsed: preserve over delete — leave a
   corrupt store untouched and surface the error rather than letting the rewrite
   erase the rows around one bad line (mirrors GC's Fact_store_corrupt). *)
exception Fact_store_corrupt of string

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

type apply_report =
  { scanned : int
  ; retracted : int
  ; advanced : int
  ; kept : int
  }

let empty_apply = { scanned = 0; retracted = 0; advanced = 0; kept = 0 }

let reconcile_facts ~now ~horizon ~verify (facts : fact list)
  : fact list * apply_report
  =
  let kept_rev, report =
    List.fold_left
      (fun (kept, report) f ->
        let report = { report with scanned = report.scanned + 1 } in
        match classify ~now ~horizon ~verify f with
        | Stale_terminal ->
          (* Drop: a merged/closed ref backing an in-progress claim. *)
          kept, { report with retracted = report.retracted + 1 }
        | Stale_open ->
          (* Confirmed still live — advance the verification timestamp so it is not
             re-checked until the next horizon (and survives its volatile TTL). *)
          let f' = { f with last_verified_at = Some now } in
          f' :: kept, { report with advanced = report.advanced + 1 }
        | Fresh | Stale_unknown ->
          (* Uncertainty (gh failure / Task kind) never deletes; non-volatile and
             in-horizon facts are untouched. *)
          f :: kept, { report with kept = report.kept + 1 })
      ([], empty_apply)
      facts
  in
  List.rev kept_rev, report
;;

let run_reconcile ?(dry_run = false) ~keeper_id ~now ~horizon ~verify () : apply_report =
  (* Same per-keeper facts lock as GC/librarian/consolidation: the verify IO runs
     inside the lock, but it only reads external state (gh) and never touches the
     store, so unlike the consolidation runtime there is no unlocked read-modify gap
     to guard with a snapshot CAS — the whole read-classify-rewrite is atomic. *)
  File_lock_eio.with_lock (Io.facts_path ~keeper_id) (fun () ->
    match Io.read_facts_all_strict ~keeper_id with
    | Error message ->
      raise
        (Fact_store_corrupt ("memory os reconcile fact store read failed: " ^ message))
    | Ok facts ->
      let survivors, report = reconcile_facts ~now ~horizon ~verify facts in
      if (not dry_run) && (report.retracted > 0 || report.advanced > 0)
      then Io.rewrite_facts_atomically ~keeper_id survivors;
      report)
;;
