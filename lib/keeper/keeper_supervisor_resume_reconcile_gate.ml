(** Reconcile-gate resume path, extracted from
    [keeper_supervisor.ml] (godfile decomp).

    [resume_keeper_after_reconcile_gate] clears the [paused] flag,
    [latched_reason], and [runtime.last_blocker] on the latest disk meta, writes back through
    [Keeper_meta_merge.heartbeat_fields_from_disk] to avoid stealing
    concurrent heartbeat writes (cf. #9733), resets the keeper's
    livelock/turn-failure state, dispatches [Operator_resume], and
    either wakes the existing supervised fiber or re-launches keepalive
    via the injected [~supervise_keepalive] callback. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile

exception Reconcile_resume_persistence_failed of string

let resume_keeper_after_reconcile_gate
      ~(supervise_keepalive : proactive_warmup_sec:int -> _ context -> keeper_meta -> unit)
      (ctx : _ context)
      (meta : keeper_meta)
      ~gate_id
  =
  let resumed_meta =
    match
      Keeper_hitl_continue_gate.resolve
        ~config:ctx.config
        ~keeper_name:meta.name
        ~gate_id
        ~decision:Keeper_hitl_continue_gate.Approve
    with
    | Ok persisted -> persisted
    | Error err ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string WriteMetaFailures)
        ~labels:[ "keeper", meta.name; "phase", "reconcile_resume" ]
        ();
      Log.Keeper.error "%s: exact reconcile gate resume failed: %s" meta.name err;
      raise (Reconcile_resume_persistence_failed err)
  in
  (* [clear_for_operator_resume] also clears the live registry failure latch;
     run it only after the durable metadata write succeeds. Pass the original
     meta so the helper still sees the pre-resume blocker classification. *)
  ignore
    (Keeper_unified_turn_completion_contract.clear_for_operator_resume
       ~base_path:ctx.config.base_path
       meta);
  Keeper_registry.set_failure_reason
    ~base_path:ctx.config.base_path
    resumed_meta.name
    None;
  Keeper_registry.reset_turn_failures ~base_path:ctx.config.base_path resumed_meta.name;
  Keeper_turn_livelock.reset_keeper_livelock
    ~base_path:ctx.config.base_path
    ~keeper:resumed_meta.name;
  (* ETA-LIVELOCK: keep typed-escalation classifier aligned with the
     resume path so the resumed keeper's first livelock block emits at
     ERROR (not silently demoted to DEBUG from a previous lifetime). *)
  Keeper_livelock_state.reset_for_keeper ~keeper:resumed_meta.name;
  fun () ->
    (* The post-removal hint is non-authoritative. Re-read durable truth so an
       operator pause/resume committed between the approval write and this
       closure wins, then version-gate the live projection. *)
    match read_meta ctx.config resumed_meta.name with
    | Error err ->
      Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
        ~config:ctx.config
        ~keeper_name:resumed_meta.name
        ~side_effect:"reconcile resume post-removal meta refresh"
        ~severity:`Error
        err
    | Ok None ->
      Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
        ~config:ctx.config
        ~keeper_name:resumed_meta.name
        ~side_effect:"reconcile resume post-removal meta refresh"
        ~severity:`Error
        "persisted keeper metadata disappeared after approval"
    | Ok (Some authoritative_meta) ->
      Keeper_registry.sync_persisted_meta_if_newer
        ~base_path:ctx.config.base_path
        authoritative_meta.name
        authoritative_meta;
      if authoritative_meta.paused
      then ()
      else
        match Keeper_registry.get ~base_path:ctx.config.base_path authoritative_meta.name with
        | Some entry when Option.is_none (Eio.Promise.peek entry.done_p) ->
          (* tla-lint: allow-mutation: post-removal keeper resume signal *)
          Atomic.set entry.fiber_wakeup true
        | Some _ ->
          Keeper_registry.unregister
            ~base_path:ctx.config.base_path
            authoritative_meta.name;
          supervise_keepalive ~proactive_warmup_sec:0 ctx authoritative_meta
        | None -> supervise_keepalive ~proactive_warmup_sec:0 ctx authoritative_meta
;;
