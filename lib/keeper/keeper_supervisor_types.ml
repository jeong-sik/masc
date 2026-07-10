(** Keeper_supervisor_types — pure type definitions and helpers extracted
    from Keeper_supervisor (2632 LoC godfile).

    See keeper_supervisor_types.mli for rationale and contract. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let supervisor_agent_name = "keeper-supervisor"

let supervision_cohort_size = 8

type supervision_cohort =
  { cohort_id : int
  ; keepers : Keeper_registry.registry_entry list
  }

let supervision_cohorts
      ?(cohort_size = supervision_cohort_size)
      (entries : Keeper_registry.registry_entry list)
  =
  let cohort_size = max 1 cohort_size in
  let sorted =
    List.sort
      (fun (a : Keeper_registry.registry_entry) (b : Keeper_registry.registry_entry) ->
         String.compare a.name b.name)
      entries
  in
  let rec take n acc rest =
    match n, rest with
    | 0, rest -> List.rev acc, rest
    | _, [] -> List.rev acc, []
    | n, entry :: rest -> take (n - 1) (entry :: acc) rest
  in
  let rec loop cohort_id acc remaining =
    match remaining with
    | [] -> List.rev acc
    | _ ->
      let keepers, rest = take cohort_size [] remaining in
      loop (cohort_id + 1) ({ cohort_id; keepers } :: acc) rest
  in
  loop 0 [] sorted
;;

let fresh_supervision_cohort_keepers ~base_path (cohort : supervision_cohort) =
  List.filter_map
    (fun (entry : Keeper_registry.registry_entry) ->
       Keeper_registry.get ~base_path entry.name)
    cohort.keepers
;;

let iter_supervision_cohorts ?(yield_between = Eio_guard.fair_yield) cohorts ~f =
  let rec loop = function
    | [] -> ()
    | [ cohort ] -> f cohort
    | cohort :: rest ->
      f cohort;
      yield_between ();
      loop rest
  in
  loop cohorts
;;

type persona_drift_log_level =
  | Persona_drift_warn
  | Persona_drift_error

let keeper_defaults_have_inline_identity
    (defaults : Keeper_types_profile.keeper_profile_defaults)
  =
  Option.is_some defaults.goal
  || Option.is_some defaults.instructions
  || defaults.mention_targets <> []
;;

let persona_drift_log_level_for_missing_profile (meta : keeper_meta) =
  match Keeper_types_profile.load_keeper_profile_defaults_result meta.name with
  | Ok defaults when keeper_defaults_have_inline_identity defaults ->
    Persona_drift_warn
  | Ok _ | Error _ -> Persona_drift_error
;;

let should_cleanup_dead ~now ~dead_ttl_sec (entry : Keeper_registry.registry_entry) =
  match entry.phase, entry.dead_since_ts with
  | Keeper_state_machine.Dead, Some dead_since -> now -. dead_since >= dead_ttl_sec
  | Keeper_state_machine.Dead, None -> false
  | ( ( Keeper_state_machine.Offline
      | Keeper_state_machine.Running
      | Keeper_state_machine.Failing
      | Keeper_state_machine.Overflowed
      | Keeper_state_machine.Compacting
      | Keeper_state_machine.HandingOff
      | Keeper_state_machine.Draining
      | Keeper_state_machine.Paused
      | Keeper_state_machine.Stopped
      | Keeper_state_machine.Crashed
      | Keeper_state_machine.Restarting
      | Keeper_state_machine.Zombie )
    , _ ) -> false
;;

let is_stale_paused_meta ~now ~paused_ttl_sec (meta : keeper_meta) =
  if not meta.paused
  then false
  else
    match Workspace_resilience.Time.parse_iso8601_opt meta.updated_at with
    | Some updated_ts -> updated_ts > 0.0 && now -. updated_ts >= paused_ttl_sec
    | None -> false
;;

let paused_meta_requires_reconcile_recovery (meta : keeper_meta) =
  meta.paused
  &&
  (match meta.latched_reason with
   | Some (Keeper_latched_reason.Continue_gate_pending _) -> true
   | Some (Keeper_latched_reason.Repository_registration_pending _) -> true
   | Some _ -> false
   | None ->
     match meta.runtime.last_blocker with
     | Some info -> blocker_class_continue_gate info.klass
     | None -> false)
;;

let paused_meta_latched_terminal_pause (meta : keeper_meta) =
  match meta.latched_reason with
  | Some Keeper_latched_reason.Dead_tombstone -> true
  | Some
      (Keeper_latched_reason.Operator_paused
        { operator_actor = Keeper_latched_reason.Hitl_rejection }) ->
    true
  | Some _
  | None -> false
;;

let paused_meta_legacy_auto_resume_after_sec (meta : keeper_meta) =
  match meta.runtime.last_blocker with
  | Some { klass = Turn_timeout; _ } ->
    let initial_sec = Env_config.KeeperSupervisor.auto_resume_initial_sec in
    let max_sec = Env_config.KeeperSupervisor.auto_resume_max_sec in
    if initial_sec <= 0.0 then None else Some (Float.min max_sec initial_sec)
  | Some
      { klass =
          ( Runtime_exhausted _
          | Capacity_backpressure
          | Ambiguous_post_commit_timeout
          | Ambiguous_post_commit_failure
          | Admission_queue_wait_timeout
          | Turn_timeout_after_queue_wait
          | Turn_livelock_blocked
          | Completion_contract_violation
          | No_progress_loop
          | Fiber_unresolved
          | Stale_turn_timeout
          | Stale_fleet_batch
          | Oas_agent_execution_timeout
          | Sdk_max_turns_exceeded
          | Sdk_token_budget_exceeded
          | Sdk_cost_budget_exceeded
          | Sdk_unrecognized_stop_reason
          | Sdk_idle_detected
          | Sdk_guardrail_violation
          | Sdk_tripwire_violation
          | Sdk_exit_condition_met
          | Sdk_input_required )
      ; _
      }
  | None -> None
;;

let paused_meta_effective_auto_resume_after_sec (meta : keeper_meta) =
  match meta.auto_resume_after_sec with
  | Some _ as explicit -> explicit
  | None -> paused_meta_legacy_auto_resume_after_sec meta
;;

let next_auto_resume_after_sec ~initial_sec ~max_sec previous =
  if initial_sec <= 0.0
  then None
  else
    Some
      (match previous with
       | None -> Float.min max_sec initial_sec
       | Some prev -> Float.min max_sec (prev *. 2.0))
;;

let paused_meta_auto_resume_due ~now (meta : keeper_meta) =
  if (not meta.paused)
     || paused_meta_requires_reconcile_recovery meta
     || paused_meta_latched_terminal_pause meta
  then false
  else
    match paused_meta_effective_auto_resume_after_sec meta with
    | None -> false
    | Some resume_after_sec ->
      (match Workspace_resilience.Time.parse_iso8601_opt meta.updated_at with
       | Some paused_ts -> paused_ts > 0.0 && now -. paused_ts >= resume_after_sec
       | None -> false)
;;

let cohort_key_of_reason = Keeper_registry.failure_reason_cohort_key

let stale_turn_timeout_cohort_key =
  cohort_key_of_reason
    (Some
       (Keeper_registry.Stale_turn_timeout
          (Keeper_registry.Idle_turn { stall_seconds = 0.0 })))
;;

let active_supervision_keeper_count entries =
  List_util.count_if
    (fun (e : Keeper_registry.registry_entry) ->
       e.phase = Keeper_state_machine.Running || e.phase = Keeper_state_machine.Crashed)
    entries
;;
