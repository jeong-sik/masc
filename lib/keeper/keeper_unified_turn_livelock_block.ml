(** See [keeper_unified_turn_livelock_block.mli] for the contract. *)

let gate_kind_of_livelock_reason ~keeper_name reason =
  let gate_kind_kind = Keeper_turn_livelock.gate_reason_kind reason in
  match Keeper_livelock_state.gate_kind_of_string gate_kind_kind with
  | Some k -> k
  | None ->
    (* Contract drift between Keeper_turn_livelock and Keeper_livelock_state.
       Fail loud at the log surface while preserving the existing error path. *)
    Log.Keeper.warn
      ~keeper_name
      "%s: livelock escalation contract drift -- unknown gate_kind=%s, defaulting \
       to attempts_exhausted"
      keeper_name
      gate_kind_kind;
    Keeper_livelock_state.Attempts_exhausted
;;

let record_escalation_log ~keeper_name ~keeper_turn_id ~turn_id ~reason_string ~gate_kind =
  match Keeper_livelock_state.record_block ~keeper:keeper_name ~gate_kind () with
  | `First ->
    Log.Keeper.error
      ~keeper_name
      ~turn_id:keeper_turn_id
      "%s: keeper turn livelock guard blocked dispatch turn=%d: %s"
      keeper_name
      turn_id
      reason_string
  | `Repeated count ->
    Log.Keeper.debug
      ~keeper_name
      ~turn_id:keeper_turn_id
      "%s: keeper turn livelock guard blocked dispatch turn=%d: %s (repeat #%d, \
       demoted from ERROR)"
      keeper_name
      turn_id
      reason_string
      count;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string TurnLivelockBlocksRepeated)
      ~labels:
        [ "keeper", keeper_name
        ; "gate_kind", Keeper_livelock_state.gate_kind_to_string gate_kind
        ]
      ()
  | `Threshold_park { count; park_threshold } ->
    Log.Keeper.error
      ~keeper_name
      ~turn_id:keeper_turn_id
      "%s: keeper turn livelock guard blocked dispatch turn=%d: %s (threshold_park \
       count=%d threshold=%d -- further blocks on this keeper+gate_kind demoted to \
       DEBUG)"
      keeper_name
      turn_id
      reason_string
      count
      park_threshold;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string TurnLivelockBlocksThresholdPark)
      ~labels:
        [ "keeper", keeper_name
        ; "gate_kind", Keeper_livelock_state.gate_kind_to_string gate_kind
        ]
      ()
;;

let persist_turn_livelock_pause
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(detail : string)
  : unit
  =
  if Keeper_pacing_shadow.pacing_enforced ()
  then
    (* RFC-0313 W3: the livelock gate keeps blocking the repeated mutating
       call in-turn (unchanged), but no longer flips keeper existence. The
       blocked turn ends through the failure path, which records pacing and
       routes the error. *)
    Log.Keeper.warn
      "%s: turn livelock block recorded without pause (RFC-0313 W3): %s"
      meta.name
      detail
  else (
    match
      Keeper_supervisor_pause_policy.handle_auto_pause_from_meta
        ~config
        ~meta
        ~reason_tag:"turn_livelock"
        ~lifecycle_detail:detail
        ~log_message:(Printf.sprintf "paused keeper after turn livelock block: %s" detail)
        ~blocker_class:(Some Keeper_meta_contract.Turn_livelock_blocked)
        ~resume_policy:Keeper_supervisor_pause_policy.Auto_resume_with_backoff
        ()
    with
    | Ok _paused_meta ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string FailureDrivenPause)
        ~labels:[ "keeper", meta.name; "site", "turn_livelock" ]
        ()
    | Error _err -> ())
;;

let handle
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(generation : int)
      ~(keeper_turn_id : int)
      ~(turn_id : int)
      ~(initial_execution : Keeper_turn_runtime_budget.runtime_execution)
      ~(reason : Keeper_turn_livelock.gate_reason)
  : (Keeper_meta_contract.keeper_meta, Agent_sdk.Error.sdk_error) result
  =
  let reason_string = Keeper_turn_livelock.gate_reason_to_string reason in
  let terminal_reason_code = Printf.sprintf "turn_livelock:%s" reason_string in
  let error_message = Printf.sprintf "keeper turn livelock blocked: %s" reason_string in
  let gate_kind = gate_kind_of_livelock_reason ~keeper_name:meta.name reason in
  record_escalation_log ~keeper_name:meta.name ~keeper_turn_id ~turn_id ~reason_string
    ~gate_kind;
  Otel_metric_store.inc_counter Keeper_metrics.(to_string TurnLivelockBlocks)
    ~labels:[ "keeper", meta.name ] ();
  Keeper_turn_helpers.record_pre_dispatch_terminal_observation
    ~config
    ~meta
    ~generation
    ~runtime_id:initial_execution.runtime_id
    (* "blocked" is not in the outcome_kind quad-state, so this maps to error.
       The specific reason is retained in terminal_reason_code. *)
    ~outcome:`Error
    ~terminal_reason_code
    ~activity_kind:"keeper.turn_blocked"
    ~trajectory_outcome:(Trajectory.Gated terminal_reason_code)
    ~error_kind:(Keeper_execution_receipt.error_kind_of_string "turn_livelock_blocked")
    ~error_message
    ~keeper_turn_id
    ();
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Runtime_routing
    (Keeper_turn_fsm.Failed
       (Keeper_turn_fsm.Failure_turn_livelock_blocked { reason = reason_string }));
  (* Persist paused state + dispatch Operator_pause so the next heartbeat
     does not re-enter the same livelock guard path.  Without this, the
     scheduler observed total_turns+1 candidate turn and re-blocked the
     same (keeper, turn_id), fuelling the repeated ERROR log surface. *)
  persist_turn_livelock_pause ~config ~meta ~detail:error_message;
  Keeper_registry.set_failure_reason
    ~base_path:config.base_path
    meta.name
    (Some Keeper_registry.Turn_livelock_pause);
  Error (Agent_sdk.Error.Internal error_message)
;;
