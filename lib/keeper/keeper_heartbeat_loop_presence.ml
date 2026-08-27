(** Presence/identity sync for the keeper heartbeat loop. Extracted from
    [keeper_heartbeat_loop.ml] (godfile decomp). Five helpers covering
    effective keepalive metadata resolution, identity drift repair,
    deriving [Masc_domain.agent_status] from [keeper_meta], noting
    preserved turn-failure debt after a heartbeat, and the actual
    [sync_keeper_presence] step that publishes the heartbeat into the
    registry. *)

open Keeper_types
open Keeper_meta_contract
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
  let selected, registry_meta_opt =
    match disk_meta_opt with
    | Some latest ->
      let registry_meta_opt =
        Keeper_registry.get ~base_path fallback.name
        |> Option.map (fun (entry : Keeper_registry.registry_entry) ->
               entry.meta)
      in
      latest, registry_meta_opt
    | None ->
      (match Keeper_registry.get ~base_path fallback.name with
       | Some entry -> entry.meta, Some entry.meta
       | None -> fallback, None)
  in
  let selected =
    match registry_meta_opt with
    | Some registry_meta
      when Keeper_id.Trace_id.equal
             registry_meta.runtime.trace_id
             selected.runtime.trace_id
           && Option.is_some
                registry_meta.runtime.usage.last_usage_reported_at ->
      let observed_usage = registry_meta.runtime.usage in
      {
        selected with
        runtime =
          {
            selected.runtime with
            usage =
              {
                selected.runtime.usage with
                last_input_tokens = observed_usage.last_input_tokens;
                last_output_tokens = observed_usage.last_output_tokens;
                last_total_tokens = observed_usage.last_total_tokens;
                last_usage_reported_at =
                  observed_usage.last_usage_reported_at;
              };
          };
      }
    | Some _ | None -> selected
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
  : keeper_meta
  =
  try
    let synced = meta_current in
    consecutive_failures := 0;
    Keeper_registry.dispatch_event_unit
      ~base_path:ctx.config.base_path
      meta_current.name
      Keeper_state_machine.Heartbeat_ok;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string HeartbeatSuccesses)
      ~labels:[ "keeper", meta_current.name ]
      ();
    note_turn_failures_preserved_after_heartbeat ~ctx ~meta:meta_current;
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
