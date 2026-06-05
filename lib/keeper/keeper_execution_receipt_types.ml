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

(* Phase identifier emitted when a runtime rotation releases the in-flight
   turn slot.  Producer-side closed set; the JSON wire is the lowercase
   string form via [slot_release_phase_to_string].  [@@deriving tla] so the
   RFC-0065 correspondence harness picks the symbols up automatically. *)
type slot_release_phase =
  | Retry_setup_failed [@tla.symbol "retry_setup_failed"]
  | Retry_scheduled [@tla.symbol "retry_scheduled"]
  | Retry_budget_exhausted [@tla.symbol "retry_budget_exhausted"]
  | Productive_phase_exhausted [@tla.symbol "productive_phase_exhausted"]
[@@deriving tla]

(* [@tla.symbol] is the single source of truth for the wire form:
   - to_tla_symbol (ppx-generated) emits the symbol attached per variant
   - all_symbols / all_states (ppx-generated) enumerate the type
   Defining slot_release_phase_to_string in terms of to_tla_symbol means
   JSON/Otel_metric_store wire and TLA correspondence catalog cannot drift.
   Mirrors the receipt wire pattern from earlier correspondence checks. *)
let slot_release_phase_to_string = to_tla_symbol

(* Terminal classification of a runtime rotation attempt.  Producer-side
   closed set in [keeper_unified_turn.ml]; JSON wire form is the lowercase
   string via [runtime_rotation_outcome_to_string].

   No [@@deriving tla] here because [slot_release_phase] above already
   binds module-level [all_symbols]; following the precedent in
   [keeper_types_profile.ml] a follow-up can wrap a TLA mirror in a
   submodule when a spec actually models rotation outcomes. *)
type runtime_rotation_outcome =
  | Rotation_setup_failed
  | Rotation_retry_scheduled
  | Rotation_budget_exhausted
  | Rotation_slot_phase_exhausted

let runtime_rotation_outcome_to_string = function
  | Rotation_setup_failed -> "setup_failed"
  | Rotation_retry_scheduled -> "retry_scheduled"
  | Rotation_budget_exhausted -> "budget_exhausted"
  | Rotation_slot_phase_exhausted -> "slot_phase_exhausted"
;;

(* Receipt-level summary of how the in-turn runtime attempt sequence
   ended.  Closed set across two producer paths:
     - [Keeper_agent_error.runtime_outcome_of_observation] — 3 values
       sourced from [Runtime_legacy_runner.runtime_observation].
     - [keeper_turn_helpers.build_pending_receipt] — emits
       [Runtime_not_dispatched] for pre-dispatch pending receipts.
   JSON wire form is the lowercase string via
   [runtime_outcome_to_string]. *)
type runtime_outcome =
  | Runtime_passed_to_next_model
  | Runtime_completed
  | Runtime_not_observed
  | Runtime_not_dispatched

let runtime_outcome_to_string = function
  | Runtime_passed_to_next_model -> "passed_to_next_model"
  | Runtime_completed -> "completed"
  | Runtime_not_observed -> "not_observed"
  | Runtime_not_dispatched -> "not_dispatched"
;;

(* Receipt-level result of the completion-contract evaluation for the turn.
   Closed union of three producer paths:
     1. Initial-state marker from [keeper_run_tools]: [Contract_unknown].
     2. Boundary-state overrides: [Contract_violated] (agent_run
        CompletionContractViolation), [Contract_not_dispatched]
        (turn_helpers pre-dispatch), [Contract_no_capable_provider]
        (run_tools no-provider escape).
     3. Six outcomes mirrored from
        [Keeper_contract_classifier.contract_status_label]:
        [Contract_surface_mismatch], [Contract_claim_only_after_owned_task],
        [Contract_needs_execution_progress], [Contract_passive_only],
        [Contract_satisfied_completion],
        [Contract_satisfied_execution].
   JSON wire form is the lowercase string via
   [completion_contract_result_to_string].  No raw ["satisfied"] variant —
   producer never emits it; closed type makes the fictional test fixture
   string unrepresentable. *)
type completion_contract_result =
  | Contract_unknown
  | Contract_not_dispatched
  | Contract_violated
  | Contract_surface_mismatch
  | Contract_no_capable_provider
  | Contract_claim_only_after_owned_task
  | Contract_needs_execution_progress
  | Contract_passive_only
  | Contract_satisfied_completion
  | Contract_satisfied_execution

let completion_contract_result_to_string = function
  | Contract_unknown -> "unknown"
  | Contract_not_dispatched -> "not_dispatched"
  | Contract_violated -> "violated"
  | Contract_surface_mismatch -> "surface_mismatch"
  | Contract_no_capable_provider -> "no_capable_provider"
  | Contract_claim_only_after_owned_task -> "claim_only_after_owned_task"
  | Contract_needs_execution_progress -> "needs_execution_progress"
  | Contract_passive_only -> "passive_only"
  | Contract_satisfied_completion -> "satisfied_completion"
  | Contract_satisfied_execution -> "satisfied_execution"
;;

(* Lift the typed [Keeper_contract_classifier.contract_status] into the
   receipt-level [completion_contract_result].  Bridges the six classifier
   outcomes; the four boundary states are emitted only by producer sites
   that already know they hold one of those states. *)
let completion_contract_result_of_contract_status
  : Keeper_contract_classifier.contract_status -> completion_contract_result
  = function
  | Surface_mismatch _ -> Contract_surface_mismatch
  | Claim_only_after_owned_task -> Contract_claim_only_after_owned_task
  | Needs_execution_progress -> Contract_needs_execution_progress
  | Passive_only -> Contract_passive_only
  | Satisfied_completion -> Contract_satisfied_completion
  | Satisfied_execution -> Contract_satisfied_execution
;;

(* Structured contract-violation terminal_reason_code encoding.
   The legacy wire format is:
     completion_contract_violation:<contract_id>
   The extended format adds called and satisfying tool lists:
     completion_contract_violation:<contract_id>:called[t1,t2]:satisfying[t3,t4]
   Both forms start with the same prefix so existing prefix-matching
   consumers (dashboard, disposition logic) remain backward-compatible.
   Empty tool lists are encoded as empty brackets: called[]:satisfying[]. *)

let encode_tool_list = function
  | [] -> "[]"
  | tools -> "[" ^ String.concat "," tools ^ "]"
;;

let encode_contract_violation_reason
    ~called_tools
    ~satisfying_tools
    (contract_id : string)
  : string
  =
  Printf.sprintf
    "completion_contract_violation:%s:called%s:satisfying%s"
    contract_id
    (encode_tool_list called_tools)
    (encode_tool_list satisfying_tools)
;;

(* Decode the extended terminal_reason_code back into its components.
   Returns [None] if the string is not a contract-violation code.
   For the legacy format (no called/satisfying suffix), both lists are [ [] ]. *)
let decode_tool_list str =
  let len = String.length str in
  if len < 2 then None
  else if String.sub str 0 1 <> "[" || String.sub str (len - 1) 1 <> "]"
  then None
  else
    let inner = String.sub str 1 (len - 2) in
    if inner = "" then Some []
    else Some (String.split_on_char ',' inner)
;;

let decode_contract_violation_reason (wire : string)
  : (string * string list * string list) option
  =
  let prefix = "completion_contract_violation:" in
  if not (String.starts_with ~prefix wire) then None
  else
    let rest = String.sub wire (String.length prefix) (String.length wire - String.length prefix) in
    match String.split_on_char ':' rest with
    | [] -> None
    | [ contract_id ] ->
      Some (contract_id, [], [])
    | contract_id :: parts ->
      let called = ref [] in
      let satisfying = ref [] in
      let consumed = ref 0 in
      List.iter (fun part ->
        if String.length part > 6 && String.sub part 0 6 = "called"
        then (
          match decode_tool_list (String.sub part 6 (String.length part - 6)) with
          | Some tools -> called := tools; incr consumed
          | None -> ())
        else if String.length part > 10 && String.sub part 0 10 = "satisfying"
        then (
          match decode_tool_list (String.sub part 10 (String.length part - 10)) with
          | Some tools -> satisfying := tools; incr consumed
          | None -> ())
        else ()
      ) parts;
      if !consumed > 0
      then Some (contract_id, !called, !satisfying)
      else Some (contract_id, [], [])
;;

type runtime_rotation_attempt =
  { from_runtime : string
  ; to_runtime : string
  ; reason : Keeper_error_classify.degraded_retry_reason
  ; outcome : runtime_rotation_outcome
  ; slot_release_at_phase : slot_release_phase option
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
  ; goal_ids : string list
  ; outcome : outcome_kind
  ; terminal_reason_code : string
  ; response_text_present : bool
  ; model_used : string option
  ; completion_contract_result : completion_contract_result
  ; tool_surface : tool_surface
  ; sandbox_kind : Keeper_types_profile_sandbox.sandbox_profile
  ; sandbox_root : string option
  ; network_mode : Keeper_types_profile_sandbox.network_mode
  ; approval_profile : string option
  ; approval_profile_derived : bool
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
  | Runtime_agent.TurnBudgetExhausted { turns_used; limit } ->
    Printf.sprintf "turn_budget_exhausted:%d/%d" turns_used limit
  | Runtime_agent.MutationBoundaryReached { turns_used; tool_name } ->
    (match tool_name with
     | Some tool -> Printf.sprintf "mutation_boundary:%s:%d" tool turns_used
     | None -> Printf.sprintf "mutation_boundary:%d" turns_used)
;;

let enrich_contract_violation_reason (receipt : t) : string =
  receipt.terminal_reason_code
;;

let sandbox_kind_of_meta (meta : Keeper_meta_contract.keeper_meta) : Keeper_types_profile_sandbox.sandbox_profile =
  meta.sandbox_profile
;;

let list_json values = `List (List.map (fun value -> `String value) values)

let string_opt_json = function
  | Some value -> `String value
  | None -> `Null
;;
