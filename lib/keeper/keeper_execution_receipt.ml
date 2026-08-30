(* Types, classification, and JSON helpers extracted to
   [Keeper_execution_receipt_types] (godfile decomp). *)
include Keeper_execution_receipt_types


let runtime_rotation_attempt_to_json attempt =
  `Assoc
    [ "from_runtime", `String (attempt.from_runtime)
    ; "to_runtime", `String (attempt.to_runtime)
    ; ( "reason"
      , `String (Keeper_error_classify.degraded_retry_reason_to_string attempt.reason) )
    ; "outcome", `String (runtime_rotation_outcome_to_string attempt.outcome)
    ; ( "productive_phase_elapsed_ms"
      , Json_util.int_opt_to_json attempt.productive_phase_elapsed_ms )
    ; ( "retry_phase_elapsed_ms"
      , Json_util.int_opt_to_json attempt.retry_phase_elapsed_ms )
    ; "error_kind", string_opt_json (Option.map error_kind_to_string attempt.error_kind)
    ; "error_message", string_opt_json attempt.error_message
    ; "recorded_at", `String attempt.recorded_at
    ]
;;

let receipt_duration_ms receipt =
  match
    ( Masc_domain.parse_iso8601_opt receipt.started_at
    , Masc_domain.parse_iso8601_opt receipt.ended_at )
  with
  | Some started_at, Some ended_at -> max 0.0 ((ended_at -. started_at) *. 1000.0)
  | _ -> 0.0
;;

(* Cycle 51 observability: alert when [operator_disposition] cannot
   classify a receipt and falls through to the catch-all
   [(Disp_unknown, Reason_unmapped_runtime_state)].

   This counter alerts operators if a future refactor leaves a receipt
   tuple outside the typed classification below. *)
let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string ReceiptUnmappedDisposition)
    ~help:
      "Total receipts whose (outcome, runtime_outcome) tuple did not match any branch of \
       operator_disposition and fell through to the typed catch-all \
       (Disp_unknown, Reason_unmapped_runtime_state).  PR #11651 fixed the historical \
       'blocked' -> 'unknown' silent path; this counter alerts operators if a future \
       refactor reintroduces such a path. A non-zero rate is a regression signal — \
       investigate which receipt.outcome / runtime_outcome / terminal_reason_code \
       combination is unclassified.  Labels are intentionally omitted: receipt fields \
       are high-cardinality free-form strings; structured detail goes to the WARN log \
       line at the firing site."
    ()
;;

type operator_disposition_kind =
  | Disp_pass
  | Disp_fail_open_next_runtime
  | Disp_retry_later
  | Disp_pass_next_model
  | Disp_operator_action_required
  | Disp_user_cancelled
  | Disp_skipped
  | Disp_unknown

let operator_disposition_kind_to_string = function
  | Disp_pass -> "pass"
  | Disp_fail_open_next_runtime -> "fail_open_next_runtime"
  | Disp_retry_later -> "retry_later"
  | Disp_pass_next_model -> "pass_next_model"
  | Disp_operator_action_required -> "operator_action_required"
  | Disp_user_cancelled -> "user_cancelled"
  | Disp_skipped -> "skipped"
  | Disp_unknown -> "unknown"
;;

let operator_disposition_kind_of_string = function
  | "pass" -> Some Disp_pass
  | "fail_open_next_runtime" -> Some Disp_fail_open_next_runtime
  | "retry_later" -> Some Disp_retry_later
  | "pass_next_model" -> Some Disp_pass_next_model
  | "operator_action_required" -> Some Disp_operator_action_required
  | "user_cancelled" -> Some Disp_user_cancelled
  | "skipped" -> Some Disp_skipped
  | "unknown" -> Some Disp_unknown
  | _ -> None
;;

type operator_disposition_reason =
  | Reason_healthy
  | Reason_runtime_exhausted
  | Reason_preflight_config_error
  | Reason_degraded_retry
  | Reason_runtime_fallback
  | Reason_transient_runtime_retry
  | Reason_capacity_backpressure
  | Reason_provider_runtime_error
  | Reason_internal_error
  | Reason_input_required
  | Reason_cancelled
  | Reason_phase_skipped
  | Reason_transcript_corruption
  | Reason_provider_attempt_effect_fenced
  | Reason_tool_correction_lost
  | Reason_accept_rejected
  | Reason_terminal_effect_failed
  | Reason_unmapped_runtime_state

let operator_disposition_reason_to_string = function
  | Reason_healthy -> "healthy"
  | Reason_runtime_exhausted -> "runtime_exhausted"
  | Reason_preflight_config_error -> "preflight_config_error"
  | Reason_degraded_retry -> "degraded_retry"
  | Reason_runtime_fallback -> "runtime_fallback"
  | Reason_transient_runtime_retry -> "transient_runtime_retry"
  | Reason_capacity_backpressure -> Keeper_internal_error.capacity_backpressure_kind
  | Reason_provider_runtime_error -> "provider_runtime_error"
  | Reason_internal_error -> "internal_error"
  | Reason_input_required -> "input_required"
  | Reason_cancelled -> "cancelled"
  | Reason_phase_skipped -> "phase_skipped"
  | Reason_transcript_corruption -> "transcript_corruption"
  | Reason_provider_attempt_effect_fenced ->
    Keeper_internal_error.provider_attempt_effect_fenced_kind
  | Reason_tool_correction_lost -> Keeper_internal_error.tool_correction_lost_kind
  | Reason_accept_rejected -> Keeper_internal_error.accept_rejected_kind
  | Reason_terminal_effect_failed -> Keeper_internal_error.terminal_effect_failed_kind
  | Reason_unmapped_runtime_state -> "unmapped_runtime_state"
;;

let operator_disposition (receipt : t)
  : operator_disposition_kind * operator_disposition_reason
  =
  (* Parse the wire string ONCE into the typed classification
     ([Keeper_terminal_reason], RFC-0042 PR-4). The earlier
     [String.starts_with] / [string_contains] chain is now a single
     [of_wire] call; each former string predicate is a variant test,
     preserving the original [if/else] priority order. The error_kind
     sub-predicates stay here (they read the receipt record, not the wire
     string) and remain OR'd with the variant test at the same branch. *)
  let terminal_reason = Keeper_terminal_reason.of_wire receipt.terminal_reason_code in
  let input_required =
    let open Keeper_turn_disposition in
    match Keeper_turn_disposition.of_wire receipt.terminal_reason_code with
    | Input_required -> true
    | Success
    | External_cancel
    | Runtime_attempts_exhausted
    | Provider_error _
    | Unknown _ -> false
  in
  let provider_runtime_failure =
    match terminal_reason with
    | Keeper_terminal_reason.Provider_runtime_failure _ -> true
    | _ -> false
  in
  let preflight_config_failure =
    match terminal_reason with
    | Keeper_terminal_reason.Config_or_auth _ -> true
    | _ -> false
  in
  (* Pre-typing, this branch also matched runtime_outcome="runtime_exhausted"
     and "exhausted" — neither is in the producer's closed [runtime_outcome]
     set ([Runtime_passed_to_next_model] / [_completed] / [_failed] /
     [_not_observed] / [_not_dispatched]).  Those branches were unreachable workarounds; the
     typed migration drops them.  Runtime exhaustion still reaches this
     branch via [terminal_reason="runtime_exhausted"]. *)
  match terminal_reason with
  | _ when input_required -> Disp_pass, Reason_input_required
  | Keeper_terminal_reason.Transcript_corruption _ ->
    (* An incomplete tool transcript no longer parks the Keeper: boot-time
       tail recovery closes the open cycles a process death leaves, and the
       turn otherwise follows the ordinary typed route. Keep the operator
       alert with the typed reason rather than claiming a pause that no
       longer happens. *)
    Disp_unknown, Reason_transcript_corruption
  | Keeper_terminal_reason.Provider_attempt_effect_fenced _ ->
    (* Same-turn replay stays forbidden, and the runtime lifecycle remains
       responsible for selecting a later turn. Keep the operator alert, but
       classify the canonical typed failure instead of incrementing the
       unmapped-state regression metric. *)
    Disp_unknown, Reason_provider_attempt_effect_fenced
  | Keeper_terminal_reason.Tool_correction_lost _ ->
    (* Identical disposition to the fence above; only the label differs so a
       lost correction (masc#28885) is countable apart from an ordinary
       fenced provider failure. *)
    Disp_unknown, Reason_tool_correction_lost
  | Keeper_terminal_reason.Terminal_effect_failed _ ->
    (* Third member of the same family: the turn's closing tool may or may not
       have put something outside the process, so the turn is never replayed
       and the stimulus behind it is retired rather than requeued. A human
       decides what happened, which is why this sits with its siblings above
       the retry-label guards — a degraded retry elsewhere in the turn must
       not relabel an alert this one earns on its own. Until now it reached
       the operator as an unmapped state (#29929). *)
    Disp_unknown, Reason_terminal_effect_failed
  | Keeper_terminal_reason.Runtime_exhausted _ ->
    Disp_fail_open_next_runtime, Reason_runtime_exhausted
  | Keeper_terminal_reason.Capacity_backpressure _ ->
    (* The typed runtime route treats provider-capacity failure as retryable and
       continues with another eligible runtime.  [runtime_fallback_applied] is
       derived from the lane walk's winning candidate index, which only
       advances on a candidate that actually wins the turn — this receipt is
       for the failed pre-dispatch attempt itself, so [runtime_fallback_applied]
       stays false here even though the lane goes on to try a later
       candidate. It must neither claim a completed fallback nor page a
       human. *)
    Disp_fail_open_next_runtime, Reason_capacity_backpressure
  | _ when preflight_config_failure ->
    Disp_operator_action_required, Reason_preflight_config_error
  | _
    when provider_runtime_failure
         && (receipt.degraded_retry_applied
             || Option.is_some receipt.degraded_retry_runtime) ->
    Disp_fail_open_next_runtime, Reason_degraded_retry
  | _
    when provider_runtime_failure
         && (receipt.runtime_fallback_applied
             || receipt.runtime_outcome = Runtime_passed_to_next_model) ->
    Disp_pass_next_model, Reason_runtime_fallback
  | _
    when provider_runtime_failure
         && Keeper_terminal_reason.is_transient_provider_runtime_failure
              terminal_reason ->
    (* This terminal receipt has already excluded both same-turn degraded retry
       and cross-runtime fallback.  The Keeper remains live and its keepalive
       cadence may run another turn later, but this turn did not move to a next
       runtime.  Keep that future scheduling contract distinct from observed
       same-turn routing. *)
    Disp_retry_later, Reason_transient_runtime_retry
  | _ when provider_runtime_failure ->
    Disp_fail_open_next_runtime, Reason_provider_runtime_error
  | Keeper_terminal_reason.Internal_error _ ->
    Disp_fail_open_next_runtime, Reason_internal_error
  | Config_or_auth _
  | Provider_runtime_failure _
  | Accept_rejected _
  | Pre_dispatch_success _
  | Unknown _ ->
    (* Generic fall-through. [Config_or_auth] and
       [Provider_runtime_failure] are caught by the guarded branches above
       (their constructors force [preflight_config_failure] /
       [provider_runtime_failure] true), so only [Pre_dispatch_success] and
       [Unknown] reach here in practice;
       [Config_or_auth] and [Provider_runtime_failure] are listed to keep the
       match exhaustive without a wildcard. *)
    if receipt.degraded_retry_applied || Option.is_some receipt.degraded_retry_runtime
    then Disp_fail_open_next_runtime, Reason_degraded_retry
    else if
      receipt.runtime_fallback_applied
      || receipt.runtime_outcome = Runtime_passed_to_next_model
    then Disp_pass_next_model, Reason_runtime_fallback
    else if
      receipt.outcome = `Ok
      && receipt.runtime_outcome = Runtime_not_dispatched
      &&
      (match terminal_reason with
       | Keeper_terminal_reason.Pre_dispatch_success _ -> true
       | Runtime_exhausted _
       | Capacity_backpressure _
       | Config_or_auth _
       | Provider_runtime_failure _
       | Transcript_corruption _
       | Provider_attempt_effect_fenced _
       | Tool_correction_lost _
       | Accept_rejected _
       | Terminal_effect_failed _
       | Internal_error _
       | Unknown _ -> false)
    then Disp_pass, Reason_healthy
    (* "healthy" requires an explicit success signal: turn completed without
       error AND runtime reached the configured terminal. Any other fallthrough
       is an unmapped state — surface it as "unknown" so a new runtime_outcome
       or terminal_reason_code does not silently display as "healthy" on the
       dashboard. See #9900 and CLAUDE.md anti-pattern #2.

       Cancelled is split out from the legacy binary outcome so dashboards
       and replay decoders can distinguish a user-initiated cancellation
       from a true failure. Skipped corresponds to the TLA+ [PhaseGateSkip]
       action: a turn that intentionally never dispatched, so runtime
       never engaged. It is a successful no-op rather than a failure or
       an unmapped state. Spec parity with [ReceiptOutcomeSet] in
       [specs/keeper-turn-fsm/KeeperTurnFSM.tla]. *)
    else (
      match receipt.outcome with
      | `Cancelled -> Disp_user_cancelled, Reason_cancelled
      | `Skipped -> Disp_skipped, Reason_phase_skipped
      | `Ok when receipt.runtime_outcome = Runtime_completed -> Disp_pass, Reason_healthy
      | `Ok when receipt.runtime_outcome = Runtime_not_dispatched ->
        (* Pre-dispatch shortcut: the turn completed successfully without
           dispatching to the LLM (cached response, immediate tool result,
           or pre-dispatch check resolved the turn).  Treated as healthy
           because the outcome is success — the runtime was simply not
           needed.  Previously unmapped (1062 WARN/day on 2026-05-24). *)
        Disp_pass, Reason_healthy
      (* masc#31312 closed the producer gap this arm papered over: the
         official-client host-stop path now writes a one-attempt runtime
         observation, so a successful turn no longer arrives as
         [Runtime_not_observed]. A receipt that still does is a new
         producer hole and belongs in unmapped, per the contract above. *)
      | _
        when (match terminal_reason with
              | Keeper_terminal_reason.Accept_rejected _ -> true
              | Runtime_exhausted _
              | Capacity_backpressure _
              | Config_or_auth _
              | Provider_runtime_failure _
              | Transcript_corruption _
              | Provider_attempt_effect_fenced _
              | Tool_correction_lost _
              | Terminal_effect_failed _
              | Internal_error _
              | Pre_dispatch_success _
              | Unknown _ -> false) ->
        (* Last, not first: the degraded-retry and fallback labels above say
           what the system DID about the rejection, which is the more useful
           fact when one of them applies — and today they claim 41 of the 42
           accept rejections on record. This arm names the remaining case
           instead of calling it an unclassified state. Not pageable: the
           provider was healthy, MASC's own accept contract refused the
           answer, and the keeper takes its next turn. *)
        Disp_fail_open_next_runtime, Reason_accept_rejected
      | _ ->
        Otel_metric_store.inc_counter Keeper_metrics.(to_string ReceiptUnmappedDisposition) ();
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string ExecutionReceiptFailures)
          ~labels:[ "keeper", receipt.keeper_name; "site", Keeper_execution_receipt_failure_site.(to_label Unmapped_disposition) ]
          ();
        Log.Keeper.warn
          ~keeper_name:receipt.keeper_name
          "operator_disposition: unmapped (outcome=%s runtime_outcome=%s \
           terminal_reason=%s completion_contract_result=%s error_kind=%s) — investigate \
           regression of #11651 silent-path fix"
          (outcome_kind_to_string receipt.outcome)
          (runtime_outcome_to_string receipt.runtime_outcome)
          receipt.terminal_reason_code
          (completion_contract_result_to_string receipt.completion_contract_result)
          (Option.value
             (Option.map error_kind_to_string receipt.error_kind)
             ~default:"<none>");
        Disp_unknown, Reason_unmapped_runtime_state)
;;

let to_json_with_operator_disposition
      (receipt : t)
      ~disposition
      ~disposition_reason
  =
  let terminal_reason_code = receipt.terminal_reason_code in
  let operator_disposition = operator_disposition_kind_to_string disposition in
  let operator_disposition_reason =
    operator_disposition_reason_to_string disposition_reason
  in
  let error_json =
    match receipt.error_kind, receipt.error_message with
    | None, None -> `Null
    | error_kind, error_message ->
      `Assoc
        [ ( "kind"
          , string_opt_json (Option.map error_kind_to_string error_kind) )
        ; ( "message", string_opt_json error_message )
        ]
  in
  let runtime_contract =
    Keeper_runtime_contract.runtime_observability_contract_json_from_fields
      ~keeper_name:receipt.keeper_name
      ~trace_id:receipt.trace_id
      ~session_id:receipt.trace_id
      ?keeper_turn_id:receipt.turn_count
      ?task_id:receipt.current_task_id
      ~sandbox_profile:(Keeper_types_profile_sandbox.sandbox_profile_to_string receipt.sandbox_kind)
      ?sandbox_root:receipt.sandbox_root
      ~network_mode:(Keeper_types_profile_sandbox.network_mode_to_string receipt.network_mode)
      ~runtime_profile:(receipt.runtime_id)
      ()
  in
  let action_radius =
    Keeper_runtime_contract.action_radius_json
      ~tool_name:"keeper_turn"
      ~input:
        (`Assoc
            [ "action", `String "run_turn"
            ; "target_kind", `String "keeper"
            ; "target_path", string_opt_json receipt.sandbox_root
            ])
      ~success:(outcome_kind_is_terminal_success receipt.outcome)
      ~duration_ms:(receipt_duration_ms receipt)
      ?error:receipt.error_message
      ~sandbox_target:(Keeper_types_profile_sandbox.sandbox_profile_to_string receipt.sandbox_kind)
      ()
  in
  `Assoc
    [ "schema", `String Keeper_types_support.execution_receipt_schema
    ; "recorded_at", `String receipt.ended_at
    ; "keeper_name", `String receipt.keeper_name
    ; "trace_id", `String receipt.trace_id
    ; ( "turn_count", Json_util.int_opt_to_json receipt.turn_count )
    ; ( "agent_core_turn_count", Json_util.int_opt_to_json receipt.agent_core_turn_count )
    ; ( "current_task_id", string_opt_json receipt.current_task_id )
    ; "outcome", `String (outcome_kind_to_tla_receipt receipt.outcome)
    ; "terminal_reason_code", `String terminal_reason_code
    ; "operator_disposition", `String operator_disposition
    ; "operator_disposition_reason", `String operator_disposition_reason
    ; "runtime_contract", runtime_contract
    ; "action_radius", action_radius
    ; "response_text_present", `Bool receipt.response_text_present
    ; ( "completion_contract_result"
      , `String (completion_contract_result_to_string receipt.completion_contract_result) )
    ; ( "actionable_signal"
      , match receipt.actionable_signal with
        | Some signal -> `String (Keeper_contract_classifier.actionable_signal_label signal)
        | None -> `Null )
    ; ( "tool_surface"
      , `Assoc
          [ ( "turn_lane"
            , Keeper_agent_tool_surface.turn_lane_to_yojson receipt.tool_surface.turn_lane
            )
          ] )
    ; ( "sandbox"
      , `Assoc
          [ "kind", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string receipt.sandbox_kind)
          ; ( "sandbox_root", string_opt_json receipt.sandbox_root )
          ; ( "network_mode"
            , `String (Keeper_types_profile_sandbox.network_mode_to_string receipt.network_mode) )
          ] )
    ; ( "runtime"
      , `Assoc
          [ "name", `String (receipt.runtime_id)
          ; "selected_model", string_opt_json receipt.runtime_selected_model
          ; "attempt_count", `Int receipt.runtime_attempt_count
          ; "lane_attempt_count", `Int receipt.runtime_lane_attempt_count
          ; "fallback_applied", `Bool receipt.runtime_fallback_applied
          ; "outcome", `String (runtime_outcome_to_string receipt.runtime_outcome)
          ; "agent_core_internal_runtime_allowed", `Bool receipt.agent_core_internal_runtime_allowed
          ; "degraded_retry_applied", `Bool receipt.degraded_retry_applied
          ; ( "degraded_retry_runtime"
            , match receipt.degraded_retry_runtime with
              | Some value -> `String (value)
              | None -> `Null )
          ; ( "fallback_reason"
            , match receipt.fallback_reason with
              | Some value ->
                `String (Keeper_error_classify.degraded_retry_reason_to_string value)
              | None -> `Null )
          ; ( "rotation_attempts"
            , `List
                (List.map
                   runtime_rotation_attempt_to_json
                   receipt.runtime_rotation_attempts) )
          ] )
    ; ( "stop_reason"
      , match receipt.stop_reason with
        | Some value -> `String (stop_reason_to_string value)
        | None -> `Null )
    ; "error", error_json
    ; "started_at", `String receipt.started_at
    ; "ended_at", `String receipt.ended_at
    ; ( "extra_system_context_digest"
      , string_opt_json receipt.extra_system_context_digest )
    ; ( "extra_system_context_injected_size"
      , Json_util.int_opt_to_json receipt.extra_system_context_injected_size )
    ; ( "extra_system_context_computed_size"
      , Json_util.int_opt_to_json receipt.extra_system_context_computed_size )
    ]
;;

let to_json receipt =
  let disposition, disposition_reason = operator_disposition receipt in
  to_json_with_operator_disposition receipt ~disposition ~disposition_reason
;;

(* Receipt-local operator notification. [append] emits only from durable
   receipt evidence; it makes no watchdog or liveness claim for a keeper that
   did not produce a receipt. *)
let needs_operator_broadcast = function
  | Disp_operator_action_required | Disp_unknown -> true
  | Disp_pass
  | Disp_fail_open_next_runtime
  | Disp_retry_later
  | Disp_pass_next_model
  | Disp_user_cancelled
  | Disp_skipped -> false
;;

let operator_broadcast_payload (receipt : t) ~disposition ~reason =
  let terminal_reason_code = receipt.terminal_reason_code in
  let disposition_s = operator_disposition_kind_to_string disposition in
  let reason_s = operator_disposition_reason_to_string reason in
  `Assoc
    [ "schema", `String "keeper.operator_broadcast_required.v1"
    ; "keeper_name", `String receipt.keeper_name
    ; "trace_id", `String receipt.trace_id
    ; ( "turn_count", Json_util.int_opt_to_json receipt.turn_count )
    ; "disposition", `String disposition_s
    ; "disposition_reason", `String reason_s
    ; "outcome", `String (outcome_kind_to_tla_receipt receipt.outcome)
    ; "terminal_reason_code", `String terminal_reason_code
    ; ( "current_task_id", string_opt_json receipt.current_task_id )
    ; "response_text_present", `Bool receipt.response_text_present
    ; "runtime_id", `String (receipt.runtime_id)
    ; "runtime_outcome", `String (runtime_outcome_to_string receipt.runtime_outcome)
    ; ( "completion_contract_result"
      , `String (completion_contract_result_to_string receipt.completion_contract_result) )
    ; ( "actionable_signal"
      , match receipt.actionable_signal with
        | Some signal -> `String (Keeper_contract_classifier.actionable_signal_label signal)
        | None -> `Null )
    ; ( "sandbox"
      , `Assoc
          [ "kind", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string receipt.sandbox_kind)
          ; "sandbox_root", string_opt_json receipt.sandbox_root
          ; ( "network_mode"
            , `String (Keeper_types_profile_sandbox.network_mode_to_string receipt.network_mode) )
          ] )
    ; ( "stop_reason"
      , match receipt.stop_reason with
        | Some value -> `String (stop_reason_to_string value)
        | None -> `Null )
    ; ( "error_kind"
      , match receipt.error_kind with
        | Some v -> `String (error_kind_to_string v)
        | None -> `Null )
    ; ( "error_message", string_opt_json receipt.error_message )
    ; "ended_at", `String receipt.ended_at
    ]
;;

let emit_operator_broadcast_event config (receipt : t) ~disposition ~reason =
  let payload = operator_broadcast_payload receipt ~disposition ~reason in
  let event =
    Activity_graph.emit
      config
      ~actor:{ Activity_graph.kind = "agent"; id = receipt.keeper_name }
      ~kind:"keeper.operator_broadcast_required"
      ~payload
      ()
  in
  Log.Keeper.warn
    ~keeper_name:receipt.keeper_name
    "%s: operator_broadcast_required emitted disposition=%s reason=%s seq=%d"
    receipt.keeper_name
    (operator_disposition_kind_to_string disposition)
    (operator_disposition_reason_to_string reason)
    event.seq
;;

let emit_operator_broadcast config (receipt : t) ~disposition ~reason =
  emit_operator_broadcast_event config receipt ~disposition ~reason
;;

let append (config : Workspace.config) (receipt : t) =
  let store =
    Keeper_types_support.keeper_execution_receipt_store config receipt.keeper_name
  in
  let disposition, reason = operator_disposition receipt in
  let receipt_json =
    to_json_with_operator_disposition
      receipt
      ~disposition
      ~disposition_reason:reason
  in
  Dated_jsonl.append store receipt_json;
  if needs_operator_broadcast disposition
  then (
    let disposition_label = operator_disposition_kind_to_string disposition in
    let reason_label = operator_disposition_reason_to_string reason in
    (try
       emit_operator_broadcast config receipt ~disposition ~reason
     with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        (* fail-closed: log loud, do not silently swallow. The append itself
           has already persisted the receipt; the broadcast failure is its
           own diagnostic that watchdogs/log alerts will pick up. *)
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string ExecutionReceiptFailures)
          ~labels:[ "keeper", receipt.keeper_name; "site", Keeper_execution_receipt_failure_site.(to_label Emit_failed) ]
          ();
        Log.Keeper.error
          ~keeper_name:receipt.keeper_name
          "%s: operator_broadcast_required EMIT FAILED disposition=%s reason=%s exn=%s"
          receipt.keeper_name
          disposition_label
          reason_label
          (Printexc.to_string exn)))
;;

let latest_json (config : Workspace.config) keeper_name =
  let store = Keeper_types_support.keeper_execution_receipt_store config keeper_name in
  match Dated_jsonl.read_recent store 1 with
  | [ json ] -> Some json
  | _ -> None
;;

let latest_json_by_keeper (config : Workspace.config) keeper_names =
  keeper_names
  |> List.filter_map (fun keeper_name ->
    match latest_json config keeper_name with
    | Some json -> Some (keeper_name, json)
    | None -> None)
;;
