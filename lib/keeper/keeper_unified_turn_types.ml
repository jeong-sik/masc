(** Keeper_unified_turn_types — pure helpers extracted from
    Keeper_unified_turn (3020 LoC godfile).

    See keeper_unified_turn_types.mli for rationale and contract.
    Re-included from Keeper_unified_turn so existing callers continue to
    use [Keeper_unified_turn.<name>] unchanged. *)

let json_of_string_opt = function
  | None -> `Null
  | Some value -> `String value
;;

let turn_event_bus_manifest_decision
      (summary : Keeper_turn_cascade_budget.turn_event_bus_summary)
  =
  let overflow =
    match summary.overflow_imminent with
    | None -> `Null
    | Some overflow ->
      `Assoc
        [
          ("estimated_tokens", `Int overflow.estimated_tokens);
          ("limit_tokens", `Int overflow.limit_tokens);
        ]
  in
  let last_compaction =
    match summary.last_compaction with
    | None -> `Null
    | Some compaction ->
      `Assoc
        [
          ("before_tokens", `Int compaction.before_tokens);
          ("after_tokens", `Int compaction.after_tokens);
          ("tokens_freed", `Int compaction.tokens_freed);
          ("phase_hint", `String compaction.phase_hint);
        ]
  in
  `Assoc
    [
      ("correlation_id", json_of_string_opt summary.correlation_id);
      ("run_id", json_of_string_opt summary.run_id);
      ("caused_by", json_of_string_opt summary.caused_by);
      ("overflow_imminent", overflow);
      ( "context_compact_started_count",
        `Int summary.context_compact_started_count );
      ("context_compacted_count", `Int summary.context_compacted_count);
      ("last_compaction", last_compaction);
    ]
;;

(* Pure predicate (Keeper_exec_context + Keeper_behavioral_regime). *)
let should_auto_pause_required_tool_contract_violation
      ~(paused : bool)
      ~(consecutive_failures : int)
      (err : Agent_sdk.Error.sdk_error)
  : bool
  =
  Keeper_error_classify.is_required_tool_contract_violation err
  && consecutive_failures >= Keeper_behavioral_regime.turn_fail_streak_threshold
  && not paused
;;

(* Pure constructor for the SDK retry-timeout error wire shape. *)
let sdk_error_of_retry_slot_reacquire_timeout
      ~(keeper_name : string)
      (timeout : Keeper_turn_slot.semaphore_wait_timeout)
  =
  let phase = Keeper_turn_slot.semaphore_wait_phase_to_string timeout.timeout_phase in
  let holder_summary = Keeper_turn_slot.format_slot_holders timeout.timeout_holders in
  Agent_sdk.Error.Api
    (Agent_sdk.Retry.Timeout
       { message =
           Printf.sprintf
             "keeper turn slot reacquire timed out after degraded retry (keeper=%s \
              phase=%s wait=%.0fs holders=%s)"
             keeper_name
             phase
             timeout.timeout_wait_sec
             holder_summary
       })
;;
