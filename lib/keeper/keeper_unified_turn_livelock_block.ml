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
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_turn_livelock_blocks_repeated
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
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_turn_livelock_blocks_threshold_park
      ~labels:
        [ "keeper", keeper_name
        ; "gate_kind", Keeper_livelock_state.gate_kind_to_string gate_kind
        ]
      ()
;;

let handle
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
      ~(generation : int)
      ~(keeper_turn_id : int)
      ~(turn_id : int)
      ~(initial_execution : Keeper_turn_cascade_budget.cascade_execution)
      ~(reason : Keeper_turn_livelock.gate_reason)
  : (Keeper_types.keeper_meta, Agent_sdk.Error.sdk_error) result
  =
  let reason_string = Keeper_turn_livelock.gate_reason_to_string reason in
  let terminal_reason_code = Printf.sprintf "turn_livelock:%s" reason_string in
  let error_message = Printf.sprintf "keeper turn livelock blocked: %s" reason_string in
  let gate_kind = gate_kind_of_livelock_reason ~keeper_name:meta.name reason in
  record_escalation_log ~keeper_name:meta.name ~keeper_turn_id ~turn_id ~reason_string
    ~gate_kind;
  Prometheus.inc_counter Keeper_metrics.metric_keeper_turn_livelock_blocks
    ~labels:[ "keeper", meta.name ] ();
  Keeper_turn_helpers.record_pre_dispatch_terminal_observation
    ~config
    ~meta
    ~generation
    ~cascade_name:initial_execution.cascade_name
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
    ~prev:Keeper_turn_fsm.Cascade_routing
    (Keeper_turn_fsm.Failed
       (Keeper_turn_fsm.Failure_turn_livelock_blocked { reason = reason_string }));
  Error (Agent_sdk.Error.Internal error_message)
;;
