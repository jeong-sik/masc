(** Semaphore-wait timeout helpers for the heartbeat loop, extracted from
    [keeper_heartbeat_loop.ml]. Holds the blocker-class mapping, diagnostic
    formatter, and the [handle_semaphore_wait_timeout] entry used by the
    legacy heartbeat path. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
module Observations = Keeper_heartbeat_loop_observations

(* Re-export the kind constructors so the body below can write
   [~kind:Semaphore_wait_timeout] without an Observations. prefix. *)
type semaphore_wait_observation_kind = Observations.semaphore_wait_observation_kind =
  | Semaphore_wait_pending
  | Semaphore_wait_timeout

let record_semaphore_wait_observation = Observations.record_semaphore_wait_observation

let semaphore_wait_timeout_blocker_class
      (timeout : Keeper_turn_slot.semaphore_wait_timeout)
  =
  match timeout.timeout_phase with
  | Keeper_turn_slot.Autonomous_queue_head -> Keeper_meta_contract.Admission_queue_wait_timeout
  | Keeper_turn_slot.Autonomous_slot -> Keeper_meta_contract.Autonomous_slot_wait_timeout
  | Keeper_turn_slot.Reactive_slot | Keeper_turn_slot.Turn_slot ->
    Keeper_meta_contract.Turn_timeout_after_queue_wait
;;

let semaphore_wait_timeout_diagnostics
      ~runtime_id
      (timeout : Keeper_turn_slot.semaphore_wait_timeout)
  =
  let phase_label =
    Keeper_turn_slot.semaphore_wait_phase_to_string timeout.timeout_phase
  in
  let queue_ahead_text =
    match timeout.timeout_phase, timeout.timeout_queue_ahead with
    | Keeper_turn_slot.Autonomous_queue_head, Some ahead ->
      Printf.sprintf " queue_blocker=autonomous_fifo queue_ahead=%d" ahead
    | Keeper_turn_slot.Autonomous_queue_head, None ->
      " queue_blocker=autonomous_fifo queue_ahead=unknown"
    | _, Some ahead -> Printf.sprintf " queue_ahead=%d" ahead
    | _, None -> ""
  in
  let persisted_blocker =
    Printf.sprintf
      "skipped: semaphore wait > %.0fs phase=%s (runtime=%s%s queue_depth=%d \
       autonomous_available=%d reactive_available=%d turn_available=%d)"
      timeout.timeout_wait_sec
      phase_label
      runtime_id
      queue_ahead_text
      timeout.timeout_queue_depth
      timeout.timeout_autonomous_available
      timeout.timeout_reactive_available
      timeout.timeout_turn_available
  in
  let log_diagnostic =
    match timeout.timeout_phase with
    | Keeper_turn_slot.Autonomous_queue_head ->
      let ahead_text =
        match timeout.timeout_queue_ahead with
        | Some ahead -> string_of_int ahead
        | None -> "unknown"
      in
      Printf.sprintf
        "%s queue_head=[blocker=autonomous_fifo ahead=%s depth=%d]"
        persisted_blocker
        ahead_text
        timeout.timeout_queue_depth
    | Keeper_turn_slot.Autonomous_slot
    | Keeper_turn_slot.Reactive_slot
    | Keeper_turn_slot.Turn_slot ->
      let holder_text =
        match timeout.timeout_holders with
        | [] -> "none"
        | holders ->
          holders
          |> List.map (fun (name, age) -> Printf.sprintf "%s/%.0fs" name age)
          |> String.concat ", "
      in
      Printf.sprintf "%s holders=[%s]" persisted_blocker holder_text
  in
  persisted_blocker, log_diagnostic
;;

(** Handle semaphore wait timeout for legacy path. *)
let handle_semaphore_wait_timeout
      ~ctx
      ~meta_after_triage
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      (timeout : Keeper_turn_slot.semaphore_wait_timeout)
  =
  let phase_label =
    Keeper_turn_slot.semaphore_wait_phase_to_string timeout.timeout_phase
  in
  record_semaphore_wait_observation
    ~base_path:ctx.config.base_path
    ~keeper_name:meta_after_triage.name
    ~channel:turn_decision.channel
    ~phase_label
    ~kind:Semaphore_wait_timeout
    ();
  let persisted_blocker, log_diagnostic =
    semaphore_wait_timeout_diagnostics
      ~runtime_id:(runtime_id_of_meta meta_after_triage)
      timeout
  in
  let blocker_class = semaphore_wait_timeout_blocker_class timeout in
  Log.Keeper.warn "%s: skipping turn (%s)" meta_after_triage.name log_diagnostic;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string SemaphoreWaitTimeout)
    ~labels:
      [ "keeper", meta_after_triage.name
      ; "channel", Keeper_world_observation.channel_to_string turn_decision.channel
      ]
    ();
  Keeper_meta_contract.map_runtime
    (fun rt ->
       { rt with
         last_blocker =
           Some
             (Keeper_meta_contract.blocker_info_of_class
                ~detail:persisted_blocker
                blocker_class)
       })
    meta_after_triage
;;
