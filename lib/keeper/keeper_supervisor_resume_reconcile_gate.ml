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

let resume_keeper_after_reconcile_gate
      ~(supervise_keepalive : proactive_warmup_sec:int -> _ context -> keeper_meta -> unit)
      (ctx : _ context)
      (meta : keeper_meta)
  =
  let latest_meta =
    match read_meta ctx.config meta.name with
    | Ok (Some latest) -> latest
    | _ -> meta
  in
  (* RFC-0047 §3.2 / plan hypothesis B: clear the completion-contract
     detector latch *before* the paused/last_blocker reset so the helper
     sees the un-mutated disk klass. Otherwise the unconditional
     [runtime.last_blocker = None] below hides the violation and the
     helper becomes a no-op. *)
  let latest_meta =
    Keeper_unified_turn_completion_contract.clear_for_operator_resume
      ~base_path:ctx.config.base_path
      latest_meta
  in
  let resumed_meta =
    { latest_meta with
      paused = false
    ; latched_reason = None
    ; updated_at = now_iso ()
    ; runtime = { latest_meta.runtime with last_blocker = None }
    }
  in
  (* #9733: same race shape as keeper_msg/overflow-pause/sync paths
     already migrated by #10135 / #10145.  The supervisor reconcile
     fiber clears [paused] and [runtime.last_blocker] (cycle-owned
     fields); a heartbeat fiber bumping heartbeat-owned metadata in
     parallel can still steal the CAS write and silently leave the keeper paused while
     [Keeper_registry.update_meta] applies the resume in-memory —
     a registry/disk split that hides the failure. *)
  (match
     write_meta_with_merge
       ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
       ctx.config
       resumed_meta
   with
   | Ok () -> ()
   | Error err when is_version_conflict_error err ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string WriteMetaFailures)
       ~labels:[ "keeper", resumed_meta.name; "phase", "reconcile_resume_cas_race" ]
       ();
     Log.Keeper.warn
       "%s: reconcile gate resume write_meta lost CAS race after retries: %s"
       resumed_meta.name
       err
   | Error err ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string WriteMetaFailures)
       ~labels:[ "keeper", resumed_meta.name; "phase", "reconcile_resume" ]
       ();
     Log.Keeper.error
       "%s: reconcile gate resume write_meta failed: %s"
       resumed_meta.name
       err);
  Keeper_registry.update_meta
    ~base_path:ctx.config.base_path
    resumed_meta.name
    resumed_meta;
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
  Keeper_registry.dispatch_event_unit
    ~base_path:ctx.config.base_path
    resumed_meta.name
    Keeper_state_machine.Operator_resume;
  match Keeper_registry.get ~base_path:ctx.config.base_path resumed_meta.name with
  | Some entry when Option.is_none (Eio.Promise.peek entry.done_p) ->
    (* tla-lint: allow-mutation: fiber signal — wake the keeper after operator resume *)
    Atomic.set entry.fiber_wakeup true
  | Some entry when not (Keeper_registry.lane_has_exited entry) ->
    Log.Keeper.warn
      "%s: resume deferred because the prior lane has a terminal result but has not joined"
      resumed_meta.name
  | Some entry ->
    (match Keeper_registry.unregister_exact entry with
     | Keeper_registry.Exact_unregistered
     | Keeper_registry.Exact_entry_missing ->
       supervise_keepalive ~proactive_warmup_sec:0 ctx resumed_meta
     | Keeper_registry.Exact_entry_replaced ->
       Log.Keeper.warn
         "%s: resume retained a newer same-name lane"
         resumed_meta.name)
  | None -> supervise_keepalive ~proactive_warmup_sec:0 ctx resumed_meta
;;
