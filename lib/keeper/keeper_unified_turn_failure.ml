(** Failure-path post-processing for [Keeper_unified_turn]. *)

(* RFC turn-failure-visible-stop (#32105): every turn failure advances the
   durable crash-accounting streak. There is no exemption class and no
   per-class budget. The historical exemption design kept a persistent
   transport outage retrying forever with [consecutive] pinned at 0 while
   fleet health stayed [ok] (#31958), and its "every exemption carries its
   own compensating accounting" invariant was enforced only by a comment
   that drifted from the code. Failure classification still exists for
   telemetry and routing; it no longer decides crash accounting. *)
let record_failure_observation
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~terminal_reason
      ~err
      ~error_text
  =
  let base_path = config.base_path in
  let count =
    Keeper_turn_failure_streak.increment ~base_path ~keeper_name:meta.name
  in
  Health.record_failure
    ~agent_name:meta.name
    ~reason:(Keeper_types_profile.short_preview error_text);
  let reason =
    match
      Keeper_unified_turn_types.registry_failure_reason_of_terminal_reason
        ~core_error:err terminal_reason ~raw_error:error_text
    with
    | Some typed_cause -> typed_cause
    | None -> Keeper_registry.Turn_consecutive_failures count
  in
  let publish_reason () =
    Keeper_registry.set_failure_reason ~base_path meta.name (Some reason)
  in
  (match reason with
   | Keeper_registry.Official_client_recovery_required recovery ->
     (match
        Keeper_official_client_session_store.commit_if_input_recovery_current
          ~base_path
          ~keeper_name:meta.name
          ~expected:recovery
          ~commit:publish_reason
      with
      | Ok true -> ()
      | Ok false ->
        Log.Keeper.info
          ~keeper_name:meta.name
          "turn failure retained a resolved or replaced official-client recovery"
      | Error detail ->
        Log.Keeper.warn
          ~keeper_name:meta.name
          "turn failure could not verify current official-client recovery: %s"
          detail;
        (* The store could not prove that the recovery was resolved. Keep the
           actionable cause: dropping it makes fleet health misclassify the
           Keeper as retrying without operator help. A later successful turn
           or confirmed recovery resolution still clears the observation. *)
        publish_reason ())
   | Keeper_registry.Turn_consecutive_failures _
   | Keeper_registry.Heartbeat_consecutive_failures _
   | Keeper_registry.Stale_termination_storm _
   | Keeper_registry.Provider_runtime_error _
   | Keeper_registry.Turn_configuration_error _
   | Keeper_registry.Fiber_unresolved _
   | Keeper_registry.Exception _
   | Keeper_registry.Turn_overflow_failure
   | Keeper_registry.Operator_interrupt -> publish_reason ());
  Log.Keeper.warn
    "%s: turn failure observed (consecutive=%d); Keeper lifecycle remains active: %s"
    meta.name
    count
    (Keeper_types_profile.short_preview error_text)
;;
