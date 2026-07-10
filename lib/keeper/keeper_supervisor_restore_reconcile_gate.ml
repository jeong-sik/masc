(** Reconcile-gate restore path, extracted from
    [keeper_supervisor.ml] (godfile decomp).

    [restore_reconcile_continue_gate] rehydrates a pending
    "keeper_continue_after_reconcile" approval entry from the
    persisted paused meta. On [Approve | Edit], it forwards to
    [resume_keeper_after_reconcile_gate] (which itself lives in
    [Keeper_supervisor_resume_reconcile_gate] — we call it directly
    here, passing the injected [~supervise_keepalive] callback, to
    avoid bouncing through the parent's wrapper).

    On [Reject], it logs the reason, increments
    [metric_keeper_supervisor_cleanup_failures] tagged
    [Reconcile_gate_rejected], and leaves the keeper paused. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
module Startup_helpers = Keeper_supervisor_startup_helpers
module Resume_reconcile_gate = Keeper_supervisor_resume_reconcile_gate

let restore_reconcile_continue_gate
      ~(supervise_keepalive : proactive_warmup_sec:int -> _ context -> keeper_meta -> unit)
      (ctx : _ context)
      (meta : keeper_meta)
  =
  let blocker_detail, blocker_klass =
    match meta.runtime.last_blocker with
    | Some info -> String.trim info.detail, Some info.klass
    | None -> "", None
  in
  let committed_tools =
    Startup_helpers.committed_tools_of_ambiguous_blocker blocker_detail
  in
  let failure_reason =
    match blocker_klass with
    | Some Ambiguous_post_commit_timeout ->
      "ambiguous_partial_commit(post_commit_timeout)"
    | Some Ambiguous_post_commit_failure ->
      "ambiguous_partial_commit(post_commit_failure)"
    | Some _ | None -> "ambiguous_partial_commit(post_commit_failure)"
  in
  let blocker = blocker_detail in
  let input =
    `Assoc
      [ "kind", `String "reconcile_required"
      ; "keeper_name", `String meta.name
      ; "failure_reason", `String failure_reason
      ; "error_detail", `String blocker
      ; "committed_tools", `List (List.map (fun tool -> `String tool) committed_tools)
      ]
  in
  let _approval_id =
    Keeper_approval_queue.submit_pending
      ~keeper_name:meta.name
      ~tool_name:"keeper_continue_after_reconcile"
      ~input
      ~risk_level:Keeper_approval_queue.Critical
      ~base_path:ctx.config.base_path
      ~lane_policy:Keeper_approval_queue.Blocking
      ~on_resolution:(fun decision ->
        match decision with
        | Agent_sdk.Hooks.Approve | Agent_sdk.Hooks.Edit _ ->
          Resume_reconcile_gate.resume_keeper_after_reconcile_gate
            ~supervise_keepalive
            ctx
            meta;
          Log.Keeper.info
            "%s: restored reconcile continue gate approved; keeper resumed"
            meta.name
        | Agent_sdk.Hooks.Reject reason ->
          Log.Keeper.warn
            "%s: restored reconcile continue gate rejected; keeper remains paused (%s)"
            meta.name
            reason;
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string SupervisorCleanupFailures)
            ~labels:
              [ "keeper", meta.name
              ; ( "site"
                , Keeper_supervisor_cleanup_failure_site.(to_label Reconcile_gate_rejected) )
              ]
            ())
      ()
  in
  Log.Keeper.warn
    "%s: restored reconcile continue gate from persisted paused meta"
    meta.name
;;
