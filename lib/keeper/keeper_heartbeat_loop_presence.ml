(** Presence/identity sync for the keeper heartbeat loop. Extracted from
    [keeper_heartbeat_loop.ml] (godfile decomp). Five helpers covering
    effective keepalive metadata resolution, identity drift repair,
    deriving [Masc_domain.agent_status] from [keeper_meta], noting
    preserved turn-failure debt after a heartbeat, and the actual
    [sync_keeper_presence] step that publishes the heartbeat into the
    registry. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_memory
open Keeper_execution
open Keeper_keepalive_signal
module Observations = Keeper_heartbeat_loop_observations

let effective_keepalive_meta
      ~base_path
      ~(fallback : keeper_meta)
      ~(disk_meta_opt : keeper_meta option)
  : keeper_meta
  =
  let selected =
    match disk_meta_opt with
  | Some latest -> latest
  | None ->
    (match Keeper_registry.get ~base_path fallback.name with
     | Some entry -> entry.meta
     | None -> fallback)
  in
  match Keeper_meta_contract.effective_meta_result ~base_path selected with
  | Ok effective -> effective
  | Error msg ->
    Log.Keeper.warn
      "effective_keepalive_meta: failed to overlay TOML profile for %s: %s"
      selected.name
      msg;
    selected
;;

let repair_identity_drift_for_keepalive ?lifecycle_token ~(ctx : _ context) (meta : keeper_meta)
  : keeper_meta option
  =
  let expected_agent_name = Keeper_identity.keeper_agent_name meta.name in
  if String.equal expected_agent_name meta.agent_name
  then Some meta
  else if Option.is_some lifecycle_token
  then (
    (* A lifecycle transaction has one durable commit point. Identity repair
       would mint another generation and write after that commit, so reject
       the launch and let the transaction restore its original snapshot. *)
    Log.Keeper.error
      "keepalive identity drift cannot be repaired inside lifecycle transaction keeper=%s actual=%s expected=%s"
      meta.name
      meta.agent_name
      expected_agent_name;
    None)
  else (
    let previous_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let new_trace_id_raw = Keeper_identity.generate_trace_id () in
    match Keeper_id.Trace_id.of_string new_trace_id_raw with
    | Error err ->
      Log.Keeper.error
        "keepalive identity repair failed for %s: invalid trace_id %s (%s)"
        meta.name
        new_trace_id_raw
        err;
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string HeartbeatFailures)
        ~labels:[ "keeper", meta.name; "phase", "identity_repair" ]
        ();
      None
    | Ok new_trace_id ->
      let base_dir = session_base_dir ctx.config in
      let _session =
        Keeper_context_runtime.create_session ~session_id:new_trace_id_raw ~base_dir
      in
      let repaired =
        { meta with
          agent_name = expected_agent_name
        ; updated_at = now_iso ()
        ; runtime =
            { meta.runtime with
              trace_id = new_trace_id
            ; trace_history =
                Json_util.dedupe_keep_order
                  (previous_trace_id :: meta.runtime.trace_history)
            ; generation = meta.runtime.generation + 1
            }
        }
      in
      (match
         match lifecycle_token with
         | None ->
           write_meta_with_merge
             ~merge:Keeper_meta_merge.monotonic_usage_counters
             ctx.config
             repaired
         | Some token ->
           write_meta_with_merge_for_lifecycle
             token
             ~merge:Keeper_meta_merge.monotonic_usage_counters
             ctx.config
             repaired
       with
       | Ok () ->
         Log.Keeper.warn
           "keepalive repaired identity drift for %s: %s -> %s"
           meta.name
           meta.agent_name
           expected_agent_name;
         Some repaired
       | Error err ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string WriteMetaFailures)
           ~labels:[ "keeper", meta.name; "phase", "identity_repair" ]
           ();
         Log.Keeper.error
           "keepalive identity repair failed for %s: write_meta failed: %s"
           meta.name
           err;
         None))
;;

let keeper_agent_status (meta : keeper_meta) =
  if meta.paused
  then Masc_domain.Inactive
  else (
    match meta.current_task_id with
    | Some _ -> Masc_domain.Busy
    | None -> Masc_domain.Active)
;;

(** Preserve turn failure accounting when heartbeat recovers.

    Heartbeat health and turn health are independent in the keeper FSM. A
    successful heartbeat may recover [heartbeat_healthy], but it must not emit
    [Turn_succeeded] or reset provider/tool failure counters. Otherwise a
    runtime_exhausted turn can be erased by the next keepalive heartbeat before
    diagnostics observe the failure streak. *)
let note_turn_failures_preserved_after_heartbeat ~(ctx : _ context) ~(meta : keeper_meta)
  =
  let turn_failures =
    Keeper_registry.get_turn_failures ~base_path:ctx.config.base_path meta.name
  in
  if turn_failures > 0
  then
    Log.Keeper.debug
      "heartbeat healthy for %s; preserving %d turn failure(s) until a real \
       turn succeeds"
      meta.name
      turn_failures
;;

let sync_keeper_presence
      ~(ctx : _ context)
      ~(meta_current : keeper_meta)
      ~(consecutive_failures : int ref)
      ~(last_successful_heartbeat_ts : float ref)
  : keeper_meta
  =
  try
    let synced = meta_current in
    consecutive_failures := 0;
    last_successful_heartbeat_ts := Time_compat.now ();
    Keeper_registry.dispatch_event_unit
      ~base_path:ctx.config.base_path
      meta_current.name
      Keeper_state_machine.Heartbeat_ok;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string HeartbeatSuccesses)
      ~labels:[ "keeper", meta_current.name ]
      ();
    note_turn_failures_preserved_after_heartbeat ~ctx ~meta:meta_current;
    match
      write_meta_with_merge
        ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
        ctx.config
        synced
    with
    | Ok () -> synced
    | Error e ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string WriteMetaFailures)
        ~labels:[ "keeper", synced.name; "phase", "heartbeat" ]
        ();
      Log.Keeper.warn "write_meta failed (heartbeat): %s" e;
      synced
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    incr consecutive_failures;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string WorkspaceHeartbeatFailures)
      ~labels:[ "keeper", meta_current.name ]
      ();
    Log.Keeper.error
      "workspace heartbeat failed (consecutive=%d): %s"
      !consecutive_failures
      (Printexc.to_string exn);
    (* RFC-0002: dispatch heartbeat failure *)
    Keeper_registry.dispatch_event_unit
      ~base_path:ctx.config.base_path
      meta_current.name
      (Keeper_state_machine.Heartbeat_failed
         { consecutive = !consecutive_failures });
    meta_current
;;
