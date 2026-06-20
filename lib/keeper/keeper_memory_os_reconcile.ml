(** Keeper_memory_os_reconcile — RFC-0259 §3.3/§3.4 grounding reconciler.

    The classification core (P2) is pure — the only external IO is the injected
    {!verify_fn}. The advance/demote write path (P3, [run_reconcile]) persists the
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
  ; terminal_kept : int
  ; advanced : int
  ; kept : int
  ; committed : bool
  }

let empty_apply =
  { scanned = 0; terminal_kept = 0; advanced = 0; kept = 0; committed = false }
;;

let reconcile_facts ~now ~horizon ~verify (facts : fact list)
  : fact list * apply_report
  =
  let kept_rev, report =
    List.fold_left
      (fun (kept, report) f ->
        let report = { report with scanned = report.scanned + 1 } in
        match classify ~now ~horizon ~verify f with
        | Stale_terminal ->
          (* Demote-not-delete (RFC-0259 §3.4): a now-terminal ref is LEFT IN PLACE
             for P1's volatile TTL (valid_until = first_seen + ttl) and the GC organ
             to remove on expiry. Deletion-by-terminal-state was rejected: [classify]
             reads only the ref's external state, never the claim, so it cannot tell a
             false "PR #X is open" from a true "PR #X was merged at <sha>" — deleting
             on state alone erases true historical records (RFC-0259 keeps a still-true
             claim). The TTL already hides these from recall, so deletion adds no
             recall benefit, only irreversibility. *)
          f :: kept, { report with terminal_kept = report.terminal_kept + 1 }
        | Stale_open ->
          (* Confirmed still live — advance the reconciler's re-check anchor
             ([last_verified_at]) so it is not re-verified until the next horizon.
             This does NOT touch [valid_until] (first_seen-anchored), so the fact
             still hard-expires on its volatile TTL; advance only paces the external
             re-check, it does not make the fact durable. *)
          let f' = { f with last_verified_at = Some now } in
          f' :: kept, { report with advanced = report.advanced + 1 }
        | Fresh | Stale_unknown ->
          (* Uncertainty (verify failure / Task kind) never deletes; non-volatile and
             in-horizon facts are untouched. *)
          f :: kept, { report with kept = report.kept + 1 })
      ([], empty_apply)
      facts
  in
  List.rev kept_rev, report
;;

let run_reconcile ?(dry_run = false) ~keeper_id ~now ~horizon ~verify () : apply_report =
  (* Phase 1 — NO LOCK. The strict read and the injected [verify] (one gh call per
     ref-bearing past-horizon fact, ~10s each) run WITHOUT the per-keeper facts lock.
     The earlier design held the lock across the whole verify loop "because verify
     never touches the store"; that is true for correctness but holds the lock —
     shared with librarian/GC/consolidation — across K*10s of network IO, stalling
     every memory write for the keeper. Off-lock verify removes that stall; the cost
     is an unlocked read-modify gap, closed by the snapshot CAS in Phase 2. *)
  match Io.read_facts_all_strict ~keeper_id with
  | Error message ->
    raise (Fact_store_corrupt ("memory os reconcile fact store read failed: " ^ message))
  | Ok facts ->
    let survivors, report = reconcile_facts ~now ~horizon ~verify facts in
    if dry_run
    then report
    else if report.advanced = 0
    then
      (* Only [Stale_open] advances mutate the store (demoted terminal facts stay
         byte-identical), so a pass with no still-open ref writes nothing and never
         takes the lock. *)
      report
    else
      (* Phase 2 — LOCK. Re-read under the lock and rewrite only if the store is
         still byte-for-byte the snapshot we classified (optimistic concurrency CAS,
         mirroring the consolidation runtime). If a concurrent writer committed
         during the verify window the snapshot differs, so abandon this cycle's
         rewrite — the reconciler is periodic and re-runs next tick — rather than
         clobber the concurrent write with stale survivors. The re-read and rewrite
         share one lock acquisition, so no third writer can interleave between them.
         A lock-acquisition timeout yields a no-op cycle (committed=false). *)
      Io.with_facts_lock ~keeper_id ~on_timeout:(fun _ -> report) (fun () ->
        match Io.read_facts_all_strict ~keeper_id with
        | Error message ->
          (* Preserve over delete: a re-read that now fails to parse must NOT be
             overwritten by the snapshot's survivors — surface the corruption. *)
          raise
            (Fact_store_corrupt
               ("memory os reconcile fact store changed before rewrite: " ^ message))
        | Ok current ->
          if Io.same_fact_snapshot facts current
          then (
            Io.rewrite_facts_atomically ~keeper_id survivors;
            { report with committed = true })
          else report)
;;
