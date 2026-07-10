(** Reconcile-gate restore path, extracted from
    [keeper_supervisor.ml] (godfile decomp).

    [restore_reconcile_continue_gate] rehydrates a pending
    "keeper_continue_after_reconcile" approval entry from the
    persisted paused meta. On [Approve], it forwards to
    [resume_keeper_after_reconcile_gate] (which itself lives in
    [Keeper_supervisor_resume_reconcile_gate] — we call it directly
    here, passing the injected [~supervise_keepalive] callback, to
    avoid bouncing through the parent's wrapper). [Edit] has no typed
    lifecycle meaning and fails closed, leaving the approval pending.

    On [Reject], it logs the reason, increments
    [metric_keeper_supervisor_cleanup_failures] tagged
    [Reconcile_gate_rejected], and leaves the keeper paused. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
module Startup_helpers = Keeper_supervisor_startup_helpers
module Resume_reconcile_gate = Keeper_supervisor_resume_reconcile_gate

exception Reconcile_gate_edit_unsupported
exception Reconcile_gate_rejection_persistence_failed of string

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
  let gate_context =
    match meta.latched_reason with
    | Some
        (Keeper_latched_reason.Continue_gate_pending
          { gate_id; origin; committed_tools }) ->
      Ok (meta, gate_id, origin, committed_tools)
    | None ->
      let gate_id = Keeper_hitl_continue_gate.generate_id () in
      let committed_tools =
        (* Explicit one-way adapter for pre-typed persisted blockers. New
           continue gates carry [committed_tools] in their typed latch. *)
        Startup_helpers.committed_tools_of_ambiguous_blocker blocker_detail
      in
      (match
         Keeper_hitl_continue_gate.migrate_legacy
           ~config:ctx.config
           ~meta
           ~gate_id
           ~origin:Keeper_latched_reason.Reconcile_recovery
           ~committed_tools
       with
       | Ok migrated ->
         Ok
           ( migrated
           , gate_id
           , Keeper_latched_reason.Reconcile_recovery
           , committed_tools )
       | Error err -> Error err)
    | Some _ -> Error "paused keeper has a different typed latch owner"
  in
  match gate_context with
  | Error err ->
    Log.Keeper.error
      "%s: reconcile continue gate not restored because typed ownership changed: %s"
      meta.name
      err
  | Ok (gated_meta, gate_id, origin, committed_tools) ->
    let failure_reason =
      match blocker_klass with
      | Some Ambiguous_post_commit_timeout ->
        "ambiguous_partial_commit(post_commit_timeout)"
      | Some Ambiguous_post_commit_failure ->
        "ambiguous_partial_commit(post_commit_failure)"
      | Some _ | None -> "ambiguous_partial_commit(post_commit_failure)"
    in
    let input =
      `Assoc
        [ "kind", `String "reconcile_required"
        ; "keeper_name", `String gated_meta.name
        ; "gate_id", `String gate_id
        ; ( "gate_origin"
          , `String
              (match origin with
               | Keeper_latched_reason.Partial_commit -> "partial_commit"
               | Reconcile_recovery -> "reconcile_recovery") )
        ; "failure_reason", `String failure_reason
        ; "error_detail", `String blocker_detail
        ; "committed_tools", `List (List.map (fun tool -> `String tool) committed_tools)
        ]
    in
    let tool_name =
      match origin with
      | Keeper_latched_reason.Partial_commit -> "keeper_continue_after_partial_commit"
      | Reconcile_recovery -> "keeper_continue_after_reconcile"
    in
    ignore
      (Keeper_approval_queue.submit_pending_blocking
         ~keeper_name:gated_meta.name
         ~tool_name
         ~input
         ~risk_level:Keeper_approval_queue.Critical
         ~base_path:ctx.config.base_path
         ~on_resolution:(fun ~approval_id:_ decision ->
           let plan commit =
             Keeper_approval_queue.blocking_resolution_plan
               ~effect_key:("continue_gate:" ^ gate_id)
               ~commit
           in
           match decision with
           | Agent_sdk.Hooks.Edit _ -> raise Reconcile_gate_edit_unsupported
           | Agent_sdk.Hooks.Approve ->
             plan (fun () ->
               let wake =
                 Resume_reconcile_gate.resume_keeper_after_reconcile_gate
                   ~supervise_keepalive
                   ctx
                   gated_meta
                   ~gate_id
               in
               fun () ->
                 wake ();
                 Log.Keeper.info
                   "%s: restored continue gate approved; keeper resumed"
                   gated_meta.name)
           | Agent_sdk.Hooks.Reject reason ->
             plan (fun () ->
               match
                 Keeper_hitl_continue_gate.resolve
                   ~config:ctx.config
                   ~keeper_name:gated_meta.name
                   ~gate_id
                   ~decision:Keeper_hitl_continue_gate.Reject
               with
               | Error err -> raise (Reconcile_gate_rejection_persistence_failed err)
               | Ok rejected_meta ->
                 fun () ->
                   Keeper_registry.set_failure_reason
                     ~base_path:ctx.config.base_path
                     rejected_meta.name
                     None;
                   Log.Keeper.warn
                     "%s: restored continue gate rejected; keeper remains operator-paused (%s)"
                     rejected_meta.name
                     reason;
                   Otel_metric_store.inc_counter
                     Keeper_metrics.(to_string SupervisorCleanupFailures)
                     ~labels:
                       [ "keeper", rejected_meta.name
                       ; ( "site"
                         , Keeper_supervisor_cleanup_failure_site.(to_label Reconcile_gate_rejected) )
                       ]
                     ()))
         ());
    Log.Keeper.warn
      "%s: restored exact continue gate id=%s from persisted paused meta"
      gated_meta.name
      gate_id
;;
