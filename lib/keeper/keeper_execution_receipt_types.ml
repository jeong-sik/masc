(* Keeper_execution_receipt_types — receipt type definitions,
   outcome/runtime/slot classification, completion contract types, and
   JSON helpers. Extracted from keeper_execution_receipt.ml during
   godfile decomposition. *)

(* Receipt outcome classification. Mirrors the TLA+ spec
   [ReceiptOutcomeSet] (see [specs/keeper-turn-fsm/KeeperTurnFSM.tla] and
   [specs/keeper-state-machine/KeeperOutcomesConservation.tla]).
   [`Skipped] corresponds to TLA+ "receipt_skipped" produced by the
   [PhaseGateSkip] action: the turn reached terminal [Done] without
   dispatching, so it is a successful no-op rather than a failure or
   cancellation. The receipt record still stores the legacy string for
   JSON compatibility; consumers must go through these helpers so that
   Skipped/Cancelled/Error are not silently folded into one another. *)
type outcome_kind = Keeper_execution_receipt_outcome_kind.outcome_kind

let outcome_kind_to_string =
  Keeper_execution_receipt_outcome_kind.outcome_kind_to_string
let outcome_kind_to_tla_receipt =
  Keeper_execution_receipt_outcome_kind.outcome_kind_to_tla_receipt
let outcome_kind_of_string =
  Keeper_execution_receipt_outcome_kind.outcome_kind_of_string
let outcome_kind_is_terminal_success =
  Keeper_execution_receipt_outcome_kind.outcome_kind_is_terminal_success

type error_kind = Error_kind of string

let error_kind_of_string value = Error_kind value
let error_kind_to_string (Error_kind value) = value

(* TLA+ ReceiptIsAuthoritative invariant
   (specs/keeper-turn-fsm/KeeperTurnFSM.tla:336):
     receipt_outcome = "receipt_done" => turn_state = "done"
   Per ReceiptMatchesState the [Done] state also accepts receipt_skipped
   (PhaseGateSkip path), so this helper enforces the receipt-authoritative
   direction for both `Ok and `Skipped: a successful-terminal receipt
   MUST be paired with turn_state = "done". `Error and `Cancelled are
   left to ReceiptMatchesState (a separate invariant) and accepted here
   so this helper is single-concern. *)
type receipt_authority_violation =
  { outcome : string
  ; turn_state : string
  }

let assert_receipt_authoritative ~outcome ~turn_state =
  match outcome, turn_state with
  | `Ok, "done" | `Skipped, "done" -> Ok ()
  | `Ok, other -> Error { outcome = "receipt_done"; turn_state = other }
  | `Skipped, other -> Error { outcome = "receipt_skipped"; turn_state = other }
  | (`Error | `Cancelled), _ -> Ok ()
;;

type tool_surface =
  { turn_lane : Keeper_agent_tool_surface.turn_lane }

(* Terminal classification of a runtime rotation attempt.  Producer-side
   closed set in [keeper_unified_turn.ml]; JSON wire form is the lowercase
   string via [runtime_rotation_outcome_to_string].

   This type intentionally has no [@@deriving tla]; following the precedent
   in [keeper_types_profile.ml], a follow-up can wrap a TLA mirror in a
   submodule when a spec actually models rotation outcomes. *)
type runtime_rotation_outcome =
  | Rotation_setup_failed
  | Rotation_retry_scheduled

let runtime_rotation_outcome_to_string = function
  | Rotation_setup_failed -> "setup_failed"
  | Rotation_retry_scheduled -> "retry_scheduled"
;;

(* Receipt-level summary of how the in-turn runtime attempt sequence
   ended.  Closed set across two producer paths:
    - [Keeper_agent_error.runtime_outcome_of_observation] — 4 values
       sourced from [Runtime_legacy_runner.runtime_observation].
     - [keeper_turn_helpers.build_pending_receipt] — emits
       [Runtime_not_dispatched] for pre-dispatch pending receipts.
   JSON wire form is the lowercase string via
   [runtime_outcome_to_string]. *)
type runtime_outcome =
  | Runtime_passed_to_next_model
  | Runtime_completed
  | Runtime_failed
  | Runtime_not_observed
  | Runtime_not_dispatched

let runtime_outcome_to_string = function
  | Runtime_passed_to_next_model -> "passed_to_next_model"
  (* Runtime-attempt completion is intentionally distinct from the final turn
     disposition: a completed provider attempt can still fail the Keeper
     completion contract. This field therefore keeps its own typed wire. *)
  | Runtime_completed -> "completed"
  | Runtime_failed -> "failed"
  | Runtime_not_observed -> "not_observed"
  | Runtime_not_dispatched -> "not_dispatched"
;;

(* Receipt-level observation of visible completion evidence.  This axis is
   deliberately independent of turn outcome, terminal reason, lifecycle,
   authorization, and operator disposition.  It records only whether dispatch
   happened and whether a response or tool execution was observed. *)
type completion_contract_result =
  | Completion_observation_unknown
  | Completion_not_dispatched
  | Completion_no_visible_output
  | Completion_response_observed
  | Completion_tool_execution_observed

module Completion_contract_label = Keeper_completion_contract_result_label

let completion_contract_result_to_label = function
  | Completion_observation_unknown -> Completion_contract_label.Unknown
  | Completion_not_dispatched -> Completion_contract_label.Not_dispatched
  | Completion_no_visible_output -> Completion_contract_label.No_visible_output
  | Completion_response_observed -> Completion_contract_label.Response_observed
  | Completion_tool_execution_observed ->
    Completion_contract_label.Tool_execution_observed
;;

let completion_contract_result_to_string result =
  result
  |> completion_contract_result_to_label
  |> Completion_contract_label.to_string
;;

let completion_contract_result_of_label = function
  | Completion_contract_label.Unknown -> Completion_observation_unknown
  | Completion_contract_label.Not_dispatched -> Completion_not_dispatched
  | Completion_contract_label.No_visible_output -> Completion_no_visible_output
  | Completion_contract_label.Response_observed -> Completion_response_observed
  | Completion_contract_label.Tool_execution_observed ->
    Completion_tool_execution_observed
;;

let completion_contract_result_of_string raw =
  raw
  |> Completion_contract_label.of_string
  |> Option.map completion_contract_result_of_label
;;

type runtime_rotation_attempt =
  { from_runtime : string
  ; to_runtime : string
  ; reason : Keeper_error_classify.degraded_retry_reason
  ; outcome : runtime_rotation_outcome
  ; productive_phase_elapsed_ms : int option
  ; retry_phase_elapsed_ms : int option
  ; error_kind : error_kind option
  ; error_message : string option
  ; recorded_at : string
  }

type t =
  { keeper_name : string
  ; agent_name : string
  ; trace_id : string
  ; generation : int
  ; turn_count : int option
  ; oas_turn_count : int option
  ; oas_dispatch_mode : string option
  ; oas_internal_runtime_disabled : bool
  ; current_task_id : string option
  ; outcome : outcome_kind
  ; terminal_reason_code : string
  ; response_text_present : bool
  ; model_used : string option
  ; completion_contract_result : completion_contract_result
  ; actionable_signal : Keeper_contract_classifier.actionable_signal option
    (* World-observation signal captured at turn time. It is independent of
       completion evidence and does not authorize or block the turn. *)
  ; tool_surface : tool_surface
  ; sandbox_kind : Keeper_types_profile_sandbox.sandbox_profile
  ; sandbox_root : string option
  ; network_mode : Keeper_types_profile_sandbox.network_mode
  ; runtime_id : string
  ; runtime_selected_model : string option
  ; runtime_attempt_count : int
  ; runtime_fallback_applied : bool
  ; runtime_outcome : runtime_outcome
  ; oas_internal_runtime_allowed : bool
  ; degraded_retry_applied : bool
  ; degraded_retry_runtime : string option
  ; fallback_reason : Keeper_error_classify.degraded_retry_reason option
  ; runtime_rotation_attempts : runtime_rotation_attempt list
  ; stop_reason : Runtime_agent.stop_reason option
  ; error_kind : error_kind option
  ; error_message : string option
  ; started_at : string
  ; ended_at : string
  ; extra_system_context_digest : string option
  ; extra_system_context_injected_size : int option
  ; extra_system_context_computed_size : int option
  ; pre_dispatch_compacted : bool
  ; pre_dispatch_compaction_trigger : string option
  ; pre_dispatch_compaction_before_tokens : int option
  ; pre_dispatch_compaction_after_tokens : int option
  }

let stop_reason_to_string = function
  | Runtime_agent.Completed -> "completed"
  | Runtime_agent.TurnLimitObserved { turns_used; limit } ->
    Printf.sprintf "turn_limit_observed:turns=%d,limit=%d" turns_used limit
  | Runtime_agent.ExecutionTimeoutObserved
      { elapsed_sec; timeout_sec; turn_count; max_turns } ->
    Printf.sprintf
      "execution_timeout_observed:elapsed_sec=%.1f,timeout_sec=%.1f,turn_count=%d,max_turns=%d"
      elapsed_sec
      timeout_sec
      turn_count
      max_turns
  | Runtime_agent.ExecutionIdleTimeoutObserved
      { idle_sec; idle_timeout_sec; turn_count; max_turns } ->
    Printf.sprintf
      "execution_idle_timeout_observed:idle_sec=%.1f,idle_timeout_sec=%.1f,turn_count=%d,max_turns=%d"
      idle_sec
      idle_timeout_sec
      turn_count
      max_turns
  | Runtime_agent.Yielded_to_chat_waiting { turns_used } ->
    Printf.sprintf "yielded_to_chat_waiting:%d" turns_used
  | Runtime_agent.Yielded_to_durable_stimulus { turns_used } ->
    Printf.sprintf "yielded_to_durable_stimulus:%d" turns_used
  | Runtime_agent.InputRequired _ ->
    Keeper_turn_disposition.to_wire Keeper_turn_disposition.Input_required
;;

(* This projects the runtime-stop axis into the receipt's terminal_reason_code
   vocabulary. It does not classify the independent completion-contract axis;
   [operator_disposition] remains the final typed receipt verdict. *)
let receipt_terminal_reason_code_of_stop_reason = function
  | Runtime_agent.InputRequired _ ->
    Keeper_turn_disposition.to_wire Keeper_turn_disposition.Input_required
  | Runtime_agent.Completed
  | Runtime_agent.TurnLimitObserved _
  | Runtime_agent.ExecutionTimeoutObserved _
  | Runtime_agent.ExecutionIdleTimeoutObserved _ ->
    Keeper_turn_disposition.to_wire Keeper_turn_disposition.Success
  | ( Runtime_agent.Yielded_to_chat_waiting _
    | Runtime_agent.Yielded_to_durable_stimulus _ ) as stop_reason ->
    stop_reason_to_string stop_reason
;;

let sandbox_kind_of_meta (meta : Keeper_meta_contract.keeper_meta) : Keeper_types_profile_sandbox.sandbox_profile =
  meta.sandbox_profile
;;

let list_json values = `List (List.map (fun value -> `String value) values)

let string_opt_json = function
  | Some value -> `String value
  | None -> `Null
;;
