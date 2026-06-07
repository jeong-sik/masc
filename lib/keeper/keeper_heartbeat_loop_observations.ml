(** Observation reason helpers for the keeper heartbeat loop. *)

let provider_timeout_observation_reasons =
  [ "provider_runtime_error"; "provider_timeout"; "keeper_turn_retry_backoff" ]
;;

let record_provider_timeout_observation ~base_path ~keeper_name =
  Keeper_registry.record_skip_reasons
    ~base_path
    keeper_name
    ~reasons:provider_timeout_observation_reasons;
  Keeper_registry.touch_last_turn_ts ~base_path keeper_name
;;

let clear_provider_timeout_failure_reason ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | Some
      { Keeper_registry.last_failure_reason =
          Some (Keeper_registry.Provider_timeout_loop _)
      ; _
      } -> Keeper_registry.set_failure_reason ~base_path keeper_name None
  | _ -> ()
;;

let prior_provider_timeout_strikes ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | Some
      { Keeper_registry.last_failure_reason =
          Some (Keeper_registry.Provider_timeout_loop { count })
      ; _
      } -> count
  | _ -> 0
;;

let is_provider_timeout_error (err : Agent_sdk.Error.sdk_error) =
  (* Enumerate every [masc_internal_error] variant + [None] so the
     compiler flags any new constructor here. Mirrors the fix in
     [degraded_retry_bypasses_slot_phase_guard] (PR #14716) and
     [runtime_permanently_dead] (PR #14762); this site was missed in
     both sweeps — the same predicate shape exists in three places
     and only this one still had a catch-all. *)
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Provider_timeout _) -> true
  | Some
      ( Keeper_turn_driver.Runtime_exhausted _
      | Keeper_turn_driver.Capacity_backpressure _
      | Keeper_turn_driver.Resumable_cli_session _

      | Keeper_turn_driver.Accept_rejected _
      | Keeper_turn_driver.Admission_queue_timeout _
      | Keeper_turn_driver.Admission_queue_rejected _
      | Keeper_turn_driver.Turn_timeout _
      | Keeper_turn_driver.Max_tokens_ceiling_violation _
      | Keeper_turn_driver.Ambiguous_post_commit _
      (* RFC-0159 Phase A: Internal_* variants are not OAS-budget timeouts. *)
      | Keeper_turn_driver.Internal_unhandled_exception _
      | Keeper_turn_driver.Internal_bridge_exception _
      | Keeper_turn_driver.Internal_contract_rejected _ )
  | None ->
    false
;;

let timeout_phase_of_provider_timeout_phase phase =
  let phase = String.trim phase in
  if String.equal phase ""
  then None
  else (
    match Keeper_failure_policy.timeout_phase_of_label phase with
    | Some phase -> Some phase
    | None -> Some Keeper_failure_policy.Unknown_timeout)
;;

let provider_timeout_policy_decision
      ~(strikes : int)
      (err : Agent_sdk.Error.sdk_error)
  : Keeper_failure_policy.decision option
  =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Provider_timeout { phase; _ }) ->
    Some
      (Keeper_failure_policy.decide
         (Keeper_failure_policy.Provider_timeout
            { phase = timeout_phase_of_provider_timeout_phase phase
            ; strikes = Some strikes
            ; liveness = Keeper_failure_policy.Recent_heartbeat
            }))
  | Some
      ( Keeper_turn_driver.Runtime_exhausted _
      | Keeper_turn_driver.Capacity_backpressure _
      | Keeper_turn_driver.Resumable_cli_session _

      | Keeper_turn_driver.Accept_rejected _
      | Keeper_turn_driver.Admission_queue_timeout _
      | Keeper_turn_driver.Admission_queue_rejected _
      | Keeper_turn_driver.Turn_timeout _
      | Keeper_turn_driver.Max_tokens_ceiling_violation _
      | Keeper_turn_driver.Ambiguous_post_commit _
      (* RFC-0159 Phase A: Internal_* variants are not OAS-budget timeouts. *)
      | Keeper_turn_driver.Internal_unhandled_exception _
      | Keeper_turn_driver.Internal_bridge_exception _
      | Keeper_turn_driver.Internal_contract_rejected _ )
  | None ->
    None
;;

let provider_timeout_metric_outcome
      (decision : Keeper_failure_policy.decision)
  =
  match decision.lifecycle_effect with
  | Keeper_failure_policy.Keep_running
  | Keeper_failure_policy.Soft_fail_turn -> "warn"
  | Keeper_failure_policy.Pause_current_work -> "soft_backoff"
  | Keeper_failure_policy.Force_release_turn -> "force_release"
  | Keeper_failure_policy.Pause_keeper -> "pause"
  | Keeper_failure_policy.Restart_keeper ->
    if Keeper_failure_policy.should_kill_keeper decision then "promote" else "restart"
;;
