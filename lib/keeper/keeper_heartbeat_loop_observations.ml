(** Observation reason helpers for the keeper heartbeat loop. *)

type semaphore_wait_observation_kind =
  | Semaphore_wait_pending
  | Semaphore_wait_timeout

let semaphore_wait_observation_reasons ?phase_label ~kind ~channel () =
  let kind_reason =
    match kind with
    | Semaphore_wait_pending -> "semaphore_wait_pending"
    | Semaphore_wait_timeout -> "semaphore_wait_timeout"
  in
  let wait_reason =
    match phase_label with
    | Some phase -> "phase_" ^ phase
    | None -> "peers_holding_slot"
  in
  [ kind_reason
  ; wait_reason
  ; "channel_" ^ Keeper_world_observation.channel_to_string channel
  ]
;;

let record_semaphore_wait_observation
      ?phase_label
      ~base_path
      ~keeper_name
      ~channel
      ~kind
      ()
  =
  Keeper_registry.record_skip_reasons
    ~base_path
    keeper_name
    ~reasons:(semaphore_wait_observation_reasons ?phase_label ~kind ~channel ())
;;

type cascade_backpressure_decision =
  | Cascade_admitted
  | Cascade_backpressured of {
      cascade_name : string;
      reason : string;
    }

let skip_reason_component raw =
  let normalized = String.lowercase_ascii (String.trim raw) in
  let mapped =
    String.map
      (function
        | ('a' .. 'z' | '0' .. '9' | '_') as c -> c
        | '-' -> '_'
        | _ -> '_')
      normalized
  in
  if String.equal mapped "" then "unknown" else mapped
;;

let cascade_backpressure_observation_reasons ~reason =
  let category =
    if String.starts_with ~prefix:"cascade_resilience_" reason
    then "cascade_resilience"
    else "cascade_unhealthy"
  in
  [ "cascade_backpressure"
  ; category
  ; "reason_" ^ skip_reason_component reason
  ]
;;

let cascade_resilience_backpressure_reason
      (resilience : Keeper_exec_preflight.cascade_resilience)
  =
  Option.map
    (fun blocker -> "cascade_resilience_" ^ blocker)
    resilience.blocker
;;

let cascade_backpressure_decision
      ~cascade_resilience
      ~should_run_turn
      ~cascade_name
      ~cascade_status
  =
  let resilience_reason =
    match cascade_resilience with
    | None -> None
    | Some resilience -> cascade_resilience_backpressure_reason resilience
  in
  match should_run_turn, cascade_status, resilience_reason with
  | true, Keeper_health_probe.Unhealthy reason, _ ->
    Cascade_backpressured { cascade_name; reason }
  | true, _, Some reason -> Cascade_backpressured { cascade_name; reason }
  | false, _, _
  | true, Keeper_health_probe.Unknown, None
  | true, Keeper_health_probe.Healthy, None -> Cascade_admitted
;;

let record_cascade_backpressure_observation ~base_path ~keeper_name ~reason =
  Keeper_registry.record_skip_reasons
    ~base_path
    keeper_name
    ~reasons:(cascade_backpressure_observation_reasons ~reason);
  Keeper_registry.touch_last_turn_ts ~base_path keeper_name
;;

let oas_timeout_budget_observation_reasons =
  [ "provider_runtime_error"; "oas_timeout_budget"; "keeper_turn_retry_backoff" ]
;;

let record_oas_timeout_budget_observation ~base_path ~keeper_name =
  Keeper_registry.record_skip_reasons
    ~base_path
    keeper_name
    ~reasons:oas_timeout_budget_observation_reasons;
  Keeper_registry.touch_last_turn_ts ~base_path keeper_name
;;

let clear_oas_timeout_budget_failure_reason ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | Some
      { Keeper_registry.last_failure_reason =
          Some (Keeper_registry.Oas_timeout_budget_loop _)
      ; _
      } -> Keeper_registry.set_failure_reason ~base_path keeper_name None
  | _ -> ()
;;

let prior_oas_timeout_budget_strikes ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | Some
      { Keeper_registry.last_failure_reason =
          Some (Keeper_registry.Oas_timeout_budget_loop { count })
      ; _
      } -> count
  | _ -> 0
;;

let is_oas_timeout_budget_error (err : Agent_sdk.Error.sdk_error) =
  (* Enumerate every [masc_internal_error] variant + [None] so the
     compiler flags any new constructor here. Mirrors the fix in
     [degraded_retry_bypasses_slot_phase_guard] (PR #14716) and
     [cascade_permanently_dead] (PR #14762); this site was missed in
     both sweeps — the same predicate shape exists in three places
     and only this one still had a catch-all. *)
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Oas_timeout_budget _) -> true
  | Some
      ( Keeper_turn_driver.Cascade_exhausted _
      | Keeper_turn_driver.Capacity_backpressure _
      | Keeper_turn_driver.Resumable_cli_session _
      | Keeper_turn_driver.No_tool_capable_provider _
      | Keeper_turn_driver.Accept_rejected _
      | Keeper_turn_driver.Admission_queue_timeout _
      | Keeper_turn_driver.Admission_queue_rejected _
      | Keeper_turn_driver.Turn_timeout _
      | Keeper_turn_driver.Max_tokens_ceiling_violation _
      | Keeper_turn_driver.Ambiguous_post_commit _ )
  | None ->
    false
;;

let timeout_phase_of_oas_timeout_budget_phase phase =
  let phase = String.trim phase in
  if String.equal phase ""
  then None
  else (
    match Keeper_failure_policy.timeout_phase_of_label phase with
    | Some phase -> Some phase
    | None -> Some Keeper_failure_policy.Unknown_timeout)
;;

let oas_timeout_budget_policy_decision
      ~(strikes : int)
      (err : Agent_sdk.Error.sdk_error)
  : Keeper_failure_policy.decision option
  =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Oas_timeout_budget { phase; _ }) ->
    Some
      (Keeper_failure_policy.decide
         (Keeper_failure_policy.Oas_timeout_budget
            { phase = timeout_phase_of_oas_timeout_budget_phase phase
            ; strikes = Some strikes
            ; liveness = Keeper_failure_policy.Recent_heartbeat
            }))
  | Some
      ( Keeper_turn_driver.Cascade_exhausted _
      | Keeper_turn_driver.Capacity_backpressure _
      | Keeper_turn_driver.Resumable_cli_session _
      | Keeper_turn_driver.No_tool_capable_provider _
      | Keeper_turn_driver.Accept_rejected _
      | Keeper_turn_driver.Admission_queue_timeout _
      | Keeper_turn_driver.Admission_queue_rejected _
      | Keeper_turn_driver.Turn_timeout _
      | Keeper_turn_driver.Max_tokens_ceiling_violation _
      | Keeper_turn_driver.Ambiguous_post_commit _ )
  | None ->
    None
;;

let oas_timeout_budget_metric_outcome
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
