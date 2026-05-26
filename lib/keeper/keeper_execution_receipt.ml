(* Types, classification, and JSON helpers extracted to
   [Keeper_execution_receipt_types] (godfile decomp). *)
include Keeper_execution_receipt_types


let last_nonempty values =
  List.fold_left
    (fun acc value -> if String.trim value = "" then acc else Some value)
    None
    values
;;

let last_tool_name receipt =
  let rec choose = function
    | [] -> None
    | values :: rest ->
      (match last_nonempty values with
       | Some _ as value -> value
       | None -> choose rest)
  in
  choose
    [ receipt.observed_tools
    ; receipt.canonical_tools
    ; receipt.tools_used
    ; receipt.reported_tools
    ; receipt.requested_tools
    ]
;;

let cascade_rotation_attempt_to_json attempt =
  `Assoc
    [ "from_cascade", `String (Cascade_name.to_string attempt.from_cascade)
    ; "to_cascade", `String (Cascade_name.to_string attempt.to_cascade)
    ; ( "reason"
      , `String (Keeper_error_classify.degraded_retry_reason_to_string attempt.reason) )
    ; "outcome", `String (cascade_rotation_outcome_to_string attempt.outcome)
    ; ( "slot_release_at_phase"
      , string_opt_json
          (Option.map slot_release_phase_to_string attempt.slot_release_at_phase) )
    ; ( "productive_phase_elapsed_ms"
      , match attempt.productive_phase_elapsed_ms with
        | Some value -> `Int value
        | None -> `Null )
    ; ( "retry_phase_elapsed_ms"
      , match attempt.retry_phase_elapsed_ms with
        | Some value -> `Int value
        | None -> `Null )
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

let string_contains_ci haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if needle_len = 0
    then true
    else if i + needle_len > haystack_len
    then false
    else if String.sub haystack i needle_len = needle
    then true
    else loop (i + 1)
  in
  loop 0
;;

let bump_count name counts =
  let rec loop prefix = function
    | [] -> List.rev ((name, 1) :: prefix)
    | (existing, count) :: rest when String.equal existing name ->
      List.rev_append prefix ((existing, count + 1) :: rest)
    | item :: rest -> loop (item :: prefix) rest
  in
  loop [] counts
;;

let count_json values =
  values
  |> List.map (fun (name, count) ->
    `Assoc [ "name", `String name; "count", `Int count ])
  |> fun values -> `List values
;;

let count_descriptors ~f descriptors =
  descriptors
  |> List.fold_left
       (fun counts descriptor -> bump_count (f descriptor) counts)
       []
  |> count_json
;;

let descriptor_receipt_labels_json descriptors =
  descriptors
  |> List.map (fun (descriptor : Agent_tool_descriptor.t) ->
    `Assoc
      [ "descriptor_id", `String descriptor.id
      ; "labels", Agent_tool_descriptor.receipt_labels_json descriptor
      ])
  |> fun values -> `List values
;;

let policy_decision_failed receipt =
  let candidates =
    [ receipt.terminal_reason_code
    ; Option.value
        (Option.map error_kind_to_string receipt.error_kind)
        ~default:""
    ; Option.value receipt.error_message ~default:""
    ]
  in
  List.exists
    (fun value ->
       string_contains_ci value "policy_denied"
       || string_contains_ci value "denied_by_policy"
       || string_contains_ci value "approval_required"
       || string_contains_ci value "governance_approval")
    candidates
;;

let tool_descriptor_summary_json receipt =
  let descriptors =
    receipt.observed_tools
    @ receipt.canonical_tools
    @ receipt.tools_used
    @ receipt.reported_tools
    |> Agent_tool_descriptor_resolution.descriptors_for_tool_names
  in
  `Assoc
    [ "source", `String "receipt_tool_sets"
    ; ( "observed_descriptor_ids"
      , list_json (List.map (fun (d : Agent_tool_descriptor.t) -> d.id) descriptors) )
    ; "descriptor_count", `Int (List.length descriptors)
    ; "receipt_labels_by_descriptor", descriptor_receipt_labels_json descriptors
    ; ( "executor_counts"
      , count_descriptors
          ~f:(fun (d : Agent_tool_descriptor.t) ->
            Agent_tool_descriptor.executor_to_string d.executor)
          descriptors )
    ; ( "backend_counts"
      , count_descriptors
          ~f:(fun (d : Agent_tool_descriptor.t) ->
            Agent_tool_descriptor.backend_to_string d.backend)
          descriptors )
    ; ( "sandbox_counts"
      , count_descriptors
          ~f:(fun (d : Agent_tool_descriptor.t) ->
            Agent_tool_descriptor.sandbox_to_string d.sandbox)
          descriptors )
    ; ( "failed_policy_decision_count"
      , `Int (if policy_decision_failed receipt then 1 else 0) )
    ]
;;

(* Cycle 51 observability: alert when [operator_disposition] cannot
   classify a receipt and falls through to the catch-all
   [(Disp_unknown, Reason_unmapped_cascade_state)].

   PR #11651 fixed the historical "blocked" -> "unknown" silent path
   (livelock turns emitted [outcome="blocked"] which was not in
   [outcome_kind] and therefore mapped to the unknown bucket; the fix
   was to map livelock terminations to [outcome="error"] with
   [terminal_reason_code] carrying the specific reason).  After that
   fix the unmapped fall-through SHOULD be unreachable in production.

   This counter alerts operators if a future refactor reintroduces a
   silent path — a non-zero rate is a regression signal.  Companion
   to the existing PR #11651 narrative documented at the fall-through
   case below ([match outcome_kind_of_string ...] catch-all). *)
let () =
  Prometheus.register_counter
    ~name:Keeper_metrics.metric_keeper_receipt_unmapped_disposition
    ~help:
      "Total receipts whose (outcome, cascade_outcome) tuple did not match any branch of \
       operator_disposition and fell through to the typed catch-all \
       (Disp_unknown, Reason_unmapped_cascade_state).  PR #11651 fixed the historical \
       'blocked' -> 'unknown' silent path; this counter alerts operators if a future \
       refactor reintroduces such a path. A non-zero rate is a regression signal — \
       investigate which receipt.outcome / cascade_outcome / terminal_reason_code \
       combination is unclassified.  Labels are intentionally omitted: receipt fields \
       are high-cardinality free-form strings; structured detail goes to the WARN log \
       line at the firing site."
    ()
;;

type operator_disposition_kind =
  | Disp_pass
  | Disp_pause_human
  | Disp_alert_exhausted
  | Disp_fail_open_next_cascade
  | Disp_pass_next_model
  | Disp_user_cancelled
  | Disp_skipped
  | Disp_unknown

let operator_disposition_kind_to_string = function
  | Disp_pass -> "pass"
  | Disp_pause_human -> "pause_human"
  | Disp_alert_exhausted -> "alert_exhausted"
  | Disp_fail_open_next_cascade -> "fail_open_next_cascade"
  | Disp_pass_next_model -> "pass_next_model"
  | Disp_user_cancelled -> "user_cancelled"
  | Disp_skipped -> "skipped"
  | Disp_unknown -> "unknown"
;;

type operator_disposition_reason =
  | Reason_healthy
  | Reason_cascade_exhausted
  | Reason_preflight_config_error
  | Reason_degraded_retry
  | Reason_cascade_fallback
  | Reason_provider_runtime_error
  | Reason_internal_error
  | Reason_tool_required_unsatisfied
  | Reason_tool_route_recoverable_failure
  | Reason_turn_livelock_blocked
  | Reason_cancelled
  | Reason_phase_skipped
  | Reason_unmapped_cascade_state

let operator_disposition_reason_to_string = function
  | Reason_healthy -> "healthy"
  | Reason_cascade_exhausted -> "cascade_exhausted"
  | Reason_preflight_config_error -> "preflight_config_error"
  | Reason_degraded_retry -> "degraded_retry"
  | Reason_cascade_fallback -> "cascade_fallback"
  | Reason_provider_runtime_error -> "provider_runtime_error"
  | Reason_internal_error -> "internal_error"
  | Reason_tool_required_unsatisfied -> "tool_required_unsatisfied"
  | Reason_tool_route_recoverable_failure -> "tool_route_recoverable_failure"
  | Reason_turn_livelock_blocked -> "turn_livelock_blocked"
  | Reason_cancelled -> "cancelled"
  | Reason_phase_skipped -> "phase_skipped"
  | Reason_unmapped_cascade_state -> "unmapped_cascade_state"
;;

let operator_disposition (receipt : t)
  : operator_disposition_kind * operator_disposition_reason
  =
  let terminal_reason = String.lowercase_ascii receipt.terminal_reason_code in
  let error_kind =
    Option.map
      (fun kind -> String.lowercase_ascii (error_kind_to_string kind))
      receipt.error_kind
  in
  let provider_runtime_failure =
    String.starts_with ~prefix:"api_error_" terminal_reason
    || String.equal terminal_reason "provider_error"
    ||
    match error_kind with
    | Some ("api" | "mcp" | "io" | "orchestration" | "serialization") -> true
    | Some _ | None -> false
  in
  let preflight_config_failure =
    match error_kind with
    | Some kind ->
      string_contains_ci kind "config"
      || string_contains_ci kind "auth"
      || string_contains_ci terminal_reason "config"
      || string_contains_ci terminal_reason "auth"
    | None ->
      string_contains_ci terminal_reason "config"
      || string_contains_ci terminal_reason "auth"
  in
  (* Pre-typing, this branch also matched cascade_outcome="cascade_exhausted"
     and "exhausted" — neither is in the producer's closed [cascade_outcome]
     set ([Cascade_passed_to_next_model] / [_completed] / [_not_observed] /
     [_not_dispatched]).  Those branches were unreachable workarounds; the
     typed migration drops them.  Cascade exhaustion still reaches this
     branch via [terminal_reason="cascade_exhausted"]. *)
  if String.equal terminal_reason "cascade_exhausted"
  then Disp_alert_exhausted, Reason_cascade_exhausted
  else if preflight_config_failure
  then Disp_pause_human, Reason_preflight_config_error
  else if
    provider_runtime_failure
    && (receipt.degraded_retry_applied || Option.is_some receipt.degraded_retry_cascade)
  then Disp_fail_open_next_cascade, Reason_degraded_retry
  else if
    provider_runtime_failure
    && (receipt.cascade_fallback_applied
        || receipt.cascade_outcome = Cascade_passed_to_next_model)
  then Disp_pass_next_model, Reason_cascade_fallback
  else if provider_runtime_failure
  then Disp_pause_human, Reason_provider_runtime_error
  else if String.starts_with ~prefix:"completion_contract_violation:" terminal_reason
  then
    (* The downstream completion-contract layer has already decided the turn
       violated [require_tool_use] (or another contract sub-clause) and emits
       [terminal_reason="completion_contract_violation:<sub_clause>"]. The
       earlier-layer [tool_contract_result] can show [satisfied_completion]
       from a separate classifier that judged the same turn locally OK; the
       two-layer disagreement was the unmapped fall-through that #11651
       regression counter is meant to flag. Treat terminal_reason as
       authoritative — the disposition is the same as the explicit
       [tool_required_unsatisfied] branch below. *)
    Disp_pause_human, Reason_tool_required_unsatisfied
  else if
    String.starts_with ~prefix:"turn_livelock:" terminal_reason
    ||
    match error_kind with
    | Some "turn_livelock_blocked" -> true
    | Some _ | None -> false
  then Disp_pause_human, Reason_turn_livelock_blocked
  else if
    String.equal terminal_reason "internal_error"
    ||
    match error_kind with
    | Some "internal" -> true
    | Some _ | None -> false
  then Disp_pause_human, Reason_internal_error
  else
    let canonical_names names =
      names
      |> List.map Keeper_tool_resolution.canonical_tool_name
      |> Keeper_types.dedupe_keep_order
    in
    let used_tool_names =
      canonical_names
        (receipt.canonical_tools @ receipt.observed_tools @ receipt.tools_used)
    in
    let required_tool_names = canonical_names receipt.tool_surface.required_tools in
    let required_tools_satisfied =
      required_tool_names <> []
      && receipt.tool_surface.missing_required_tools = []
      && List.for_all
           (fun required -> List.mem required used_tool_names)
           required_tool_names
    in
    let generic_claim_context_progress =
      (* Generic require_tool_use has no named required-tool set. A successful
         claim-only turn still made scheduling progress; the next turn must
         execute, but this receipt should not be reclassified as a human pause. *)
      required_tool_names = []
      && receipt.tool_surface.missing_required_tools = []
      && List.exists Keeper_tool_progress.is_claim_context_tool_name used_tool_names
    in
    let ok_followup_progress =
      receipt.outcome = `Ok
      && receipt.cascade_outcome = Cascade_completed
      && receipt.tool_contract_result = Contract_needs_execution_progress
      && (required_tools_satisfied || generic_claim_context_progress)
    in
    let required_tool_contract_unsatisfied =
      receipt.tool_surface.tool_requirement = Required
      && (List.mem
            receipt.tool_contract_result
            [ Contract_violated
            ; Contract_unknown
            ; Contract_needs_execution_progress
            ; Contract_missing_required_tool_use
            ; Contract_passive_only
            ; Contract_claim_only_after_owned_task
            ; Contract_tool_surface_mismatch
            ; Contract_no_tool_capable_provider
            ]
          || receipt.tools_used = [])
      && not ok_followup_progress
    in
    let required_tool_route_failure =
      List.mem
        receipt.tool_contract_result
        [ Contract_tool_surface_mismatch; Contract_no_tool_capable_provider ]
    in
    if required_tool_contract_unsatisfied && required_tool_route_failure
    then
      if receipt.degraded_retry_applied || Option.is_some receipt.degraded_retry_cascade
      then Disp_fail_open_next_cascade, Reason_tool_route_recoverable_failure
      else if
        receipt.cascade_fallback_applied
        || receipt.cascade_outcome = Cascade_passed_to_next_model
      then Disp_pass_next_model, Reason_tool_route_recoverable_failure
      else Disp_pause_human, Reason_tool_route_recoverable_failure
    else if required_tool_contract_unsatisfied
    then (
      if receipt.tool_contract_result = Contract_missing_required_tool_use
      then
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_contract_violations
          ~labels:
            [ "keeper_name", receipt.keeper_name
            ; "kind", "missing_required_tool_use"
            ; "signal"
            , (if receipt.tools_used = []
               then "no_tools_used"
               else "partial_tools_used")
            ]
          ();
      Disp_pause_human, Reason_tool_required_unsatisfied)
    else if
      receipt.degraded_retry_applied || Option.is_some receipt.degraded_retry_cascade
    then Disp_fail_open_next_cascade, Reason_degraded_retry
    else if
      receipt.cascade_fallback_applied
      || receipt.cascade_outcome = Cascade_passed_to_next_model
    then Disp_pass_next_model, Reason_cascade_fallback
    else if
      receipt.outcome = `Ok
      && receipt.cascade_outcome = Cascade_not_dispatched
      && receipt.tool_contract_result = Contract_not_dispatched
      && String.equal terminal_reason "pre_dispatch_success"
    then Disp_pass, Reason_healthy
    (* "healthy" requires an explicit success signal: turn completed without
       error AND cascade reached the configured terminal. Any other fallthrough
       is an unmapped state — surface it as "unknown" so a new cascade_outcome
       or terminal_reason_code does not silently display as "healthy" on the
       dashboard. See #9900 and CLAUDE.md anti-pattern #2.

       Cancelled is split out from the legacy binary outcome so dashboards
       and replay decoders can distinguish a user-initiated cancellation
       from a true failure. Skipped corresponds to the TLA+ [PhaseGateSkip]
       action: a turn that intentionally never dispatched, so cascade
       never engaged. It is a successful no-op rather than a failure or
       an unmapped state. Spec parity with [ReceiptOutcomeSet] in
       [specs/keeper-turn-fsm/KeeperTurnFSM.tla]. *)
    else (
      match receipt.outcome with
      | `Cancelled -> Disp_user_cancelled, Reason_cancelled
      | `Skipped -> Disp_skipped, Reason_phase_skipped
      | `Ok when receipt.cascade_outcome = Cascade_completed -> Disp_pass, Reason_healthy
      | `Ok when receipt.cascade_outcome = Cascade_not_dispatched ->
        (* Pre-dispatch shortcut: the turn completed successfully without
           dispatching to the LLM (cached response, immediate tool result,
           or pre-dispatch check resolved the turn).  Treated as healthy
           because the outcome is success — the cascade was simply not
           needed.  Previously unmapped (1062 WARN/day on 2026-05-24). *)
        Disp_pass, Reason_healthy
      | _ ->
        Prometheus.inc_counter Keeper_metrics.metric_keeper_receipt_unmapped_disposition ();
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_execution_receipt_failures
          ~labels:[ "keeper", receipt.keeper_name; "site", Keeper_execution_receipt_failure_site.(to_label Unmapped_disposition) ]
          ();
        Log.Keeper.warn
          "operator_disposition: unmapped (outcome=%s cascade_outcome=%s \
           terminal_reason=%s tool_contract_result=%s error_kind=%s) — investigate \
           regression of #11651 silent-path fix"
          (outcome_kind_to_string receipt.outcome)
          (cascade_outcome_to_string receipt.cascade_outcome)
          terminal_reason
          (tool_contract_result_to_string receipt.tool_contract_result)
          (Option.value
             (Option.map error_kind_to_string receipt.error_kind)
             ~default:"<none>");
        Disp_unknown, Reason_unmapped_cascade_state)
;;

let to_json (receipt : t) =
  let terminal_reason_code = enrich_contract_violation_reason receipt in
  let disposition, disposition_reason = operator_disposition receipt in
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
          , match error_kind with
            | Some value -> `String (error_kind_to_string value)
            | None -> `Null )
        ; ( "message"
          , match error_message with
            | Some value -> `String value
            | None -> `Null )
        ]
  in
  let runtime_contract =
    Keeper_runtime_contract.runtime_contract_json_from_fields
      ~keeper_name:receipt.keeper_name
      ~agent_name:receipt.agent_name
      ~trace_id:receipt.trace_id
      ~session_id:receipt.trace_id
      ~generation:receipt.generation
      ?keeper_turn_id:receipt.turn_count
      ?task_id:receipt.current_task_id
      ~goal_ids:receipt.goal_ids
      ~sandbox_profile:(Keeper_types.sandbox_profile_to_string receipt.sandbox_kind)
      ?sandbox_root:receipt.sandbox_root
      ~network_mode:(Keeper_types.network_mode_to_string receipt.network_mode)
      ?approval_mode:receipt.approval_profile
      ~tool_surface_class:
        (Keeper_agent_tool_surface.tool_surface_class_to_string
           receipt.tool_surface.tool_surface_class)
      ~visible_tool_count:receipt.tool_surface.visible_tool_count
      ~required_tools:receipt.tool_surface.required_tools
      ~required_tool_candidates:receipt.tool_surface.required_tool_candidates
      ~missing_required_tools:receipt.tool_surface.missing_required_tools
      ~cascade_profile:(Cascade_name.to_string receipt.cascade_name)
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
      ~sandbox_target:(Keeper_types.sandbox_profile_to_string receipt.sandbox_kind)
      ()
  in
  `Assoc
    [ "schema", `String "keeper.execution_receipt.v1"
    ; "recorded_at", `String receipt.ended_at
    ; "keeper_name", `String receipt.keeper_name
    ; "agent_name", `String receipt.agent_name
    ; "trace_id", `String receipt.trace_id
    ; "generation", `Int receipt.generation
    ; ( "turn_count"
      , match receipt.turn_count with
        | Some value -> `Int value
        | None -> `Null )
    ; ( "oas_turn_count"
      , match receipt.oas_turn_count with
        | Some value -> `Int value
        | None -> `Null )
    ; ( "oas_dispatch_mode"
      , match receipt.oas_dispatch_mode with
        | Some value -> `String value
        | None -> `Null )
    ; ( "oas_internal_cascade_disabled"
      , `Bool receipt.oas_internal_cascade_disabled )
    ; ( "current_task_id"
      , match receipt.current_task_id with
        | Some value -> `String value
        | None -> `Null )
    ; "goal_ids", list_json receipt.goal_ids
    ; "outcome", `String (outcome_kind_to_tla_receipt receipt.outcome)
    ; "terminal_reason_code", `String terminal_reason_code
    ; "operator_disposition", `String operator_disposition
    ; "operator_disposition_reason", `String operator_disposition_reason
    ; "runtime_contract", runtime_contract
    ; "action_radius", action_radius
    ; "response_text_present", `Bool receipt.response_text_present
    ; "model_used", `Null
    ; "requested_tools", list_json receipt.requested_tools
    ; "reported_tools", list_json receipt.reported_tools
    ; "observed_tools", list_json receipt.observed_tools
    ; "canonical_tools", list_json receipt.canonical_tools
    ; "unexpected_tools", list_json receipt.unexpected_tools
    ; "tools_used", list_json receipt.tools_used
    ; "tool_descriptor_summary", tool_descriptor_summary_json receipt
    ; ( "tool_contract_result"
      , `String (tool_contract_result_to_string receipt.tool_contract_result) )
    ; ( "tool_surface"
      , `Assoc
          [ ( "turn_lane"
            , Keeper_agent_tool_surface.turn_lane_to_yojson receipt.tool_surface.turn_lane
            )
          ; ( "tool_surface_class"
            , Keeper_agent_tool_surface.tool_surface_class_to_yojson
                receipt.tool_surface.tool_surface_class )
          ; ( "tool_requirement"
            , Keeper_agent_tool_surface.tool_requirement_to_yojson
                receipt.tool_surface.tool_requirement )
          ; "visible_tool_count", `Int receipt.tool_surface.visible_tool_count
          ; "tool_gate_enabled", `Bool receipt.tool_surface.tool_gate_enabled
          ; ( "tool_surface_fallback_used"
            , `Bool receipt.tool_surface.tool_surface_fallback_used )
          ; "required_tools", list_json receipt.tool_surface.required_tools
          ; ( "required_tool_candidates"
            , list_json receipt.tool_surface.required_tool_candidates )
          ; ( "missing_required_tools"
            , list_json receipt.tool_surface.missing_required_tools )
          ; ( "materialized_tools"
            , list_json receipt.tool_surface.materialized_tools )
          ] )
    ; ( "sandbox"
      , `Assoc
          [ "kind", `String (Keeper_types.sandbox_profile_to_string receipt.sandbox_kind)
          ; ( "sandbox_root"
            , match receipt.sandbox_root with
              | Some value -> `String value
              | None -> `Null )
          ; ( "network_mode"
            , `String (Keeper_types.network_mode_to_string receipt.network_mode) )
          ] )
    ; ( "approval"
      , `Assoc
          [ ( "profile"
            , match receipt.approval_profile with
              | Some value -> `String value
              | None -> `Null )
          ; "derived", `Bool receipt.approval_profile_derived
          ] )
    ; ( "cascade"
      , `Assoc
          [ "name", `String (Cascade_name.to_string receipt.cascade_name)
          ; "selected_model", `Null
          ; "attempt_count", `Int receipt.cascade_attempt_count
          ; "fallback_applied", `Bool receipt.cascade_fallback_applied
          ; "outcome", `String (cascade_outcome_to_string receipt.cascade_outcome)
          ; "oas_internal_cascade_allowed", `Bool receipt.oas_internal_cascade_allowed
          ; "degraded_retry_applied", `Bool receipt.degraded_retry_applied
          ; ( "degraded_retry_cascade"
            , match receipt.degraded_retry_cascade with
              | Some value -> `String (Cascade_name.to_string value)
              | None -> `Null )
          ; ( "fallback_reason"
            , match receipt.fallback_reason with
              | Some value ->
                `String (Keeper_error_classify.degraded_retry_reason_to_string value)
              | None -> `Null )
          ; ( "rotation_attempts"
            , `List
                (List.map
                   cascade_rotation_attempt_to_json
                   receipt.cascade_rotation_attempts) )
          ] )
    ; ( "stop_reason"
      , match receipt.stop_reason with
        | Some value -> `String (stop_reason_to_string value)
        | None -> `Null )
    ; "error", error_json
    ; "started_at", `String receipt.started_at
    ; "ended_at", `String receipt.ended_at
    ; ( "extra_system_context_digest"
      , match receipt.extra_system_context_digest with
        | Some value -> `String value
        | None -> `Null )
    ; ( "extra_system_context_injected_size"
      , match receipt.extra_system_context_injected_size with
        | Some value -> `Int value
        | None -> `Null )
    ; ( "extra_system_context_computed_size"
      , match receipt.extra_system_context_computed_size with
        | Some value -> `Int value
        | None -> `Null )
    ; ( "pre_dispatch_compacted", `Bool receipt.pre_dispatch_compacted )
    ; ( "pre_dispatch_compaction_trigger"
      , match receipt.pre_dispatch_compaction_trigger with
        | Some value -> `String value
        | None -> `Null )
    ; ( "pre_dispatch_compaction_before_tokens"
      , match receipt.pre_dispatch_compaction_before_tokens with
        | Some value -> `Int value
        | None -> `Null )
    ; ( "pre_dispatch_compaction_after_tokens"
      , match receipt.pre_dispatch_compaction_after_tokens with
        | Some value -> `Int value
        | None -> `Null )
    ]
;;

(* Operator broadcast hook (#fleet-stall 2026-04-26): operator_disposition
   was a derived display field — emitted nowhere. A pause_human/alert_exhausted
   verdict therefore had no transition out: dashboard turned a chip red, but
   no event reached operators and no supervisor handoff fired. We now emit a
   structured "keeper.operator_broadcast_required" activity event so the gate
   verdict becomes addressable instead of cosmetic.

   Spec navigation (OCaml -> TLA+) — plan §19 anchor pattern.
   Authoritative spec mirror is
   [specs/keeper-state-machine/OperatorPauseBroadcast.tla].

   Spec lines 17-21 already cite this module:
     "lib/keeper/keeper_execution_receipt.ml: needs_operator_broadcast +
      emit_operator_broadcast called from append".

   This block is the reverse-direction citation so code search for
   "OperatorPauseBroadcast" lands at this hook.

   Spec property under audit (line 11-15):
     For every keeper that enters PauseHuman or StaleRunning, an
     OperatorBroadcast event is eventually emitted (leads-to).  The
     clean Spec satisfies this; the bug model where emit is silently
     dropped MUST violate it.

   OCaml mapping:
     PauseHuman / StaleRunning  -> [needs_operator_broadcast]
                                  returns [true] for "pause_human",
                                  "alert_exhausted", "unknown".
     OperatorBroadcast event    -> [append] emits
                                  "keeper.operator_broadcast_required.v1"
                                  with structured payload. Repeated
                                  turn-livelock receipts for the same
                                  keeper/turn/reason are coalesced after
                                  the first event; the receipt itself is
                                  still persisted.
     Eventually-emit liveness   -> [append] calls the emit when
                                  [needs_operator_broadcast] is true and
                                  the receipt is not a duplicate livelock
                                  notification, inside a [try] so a single
                                  failure does not cascade — the spec's
                                  clean model.

   Bug model (would be violated if a future refactor dropped the first
   emit for a broadcast-worthy state, or skipped without the suppression
   metric): an OperatorBroadcast path that requires manual operator
   dispatch instead of automatic emit would re-create the original
   #fleet-stall bug.  Sibling anchor in [keeper_supervisor.ml]
   (StaleRunning watchdog + emit_stale_keeper_broadcast) is deferred to
   a separate cycle. *)
let needs_operator_broadcast = function
  | Disp_pause_human | Disp_alert_exhausted | Disp_unknown -> true
  | Disp_pass
  | Disp_fail_open_next_cascade
  | Disp_pass_next_model
  | Disp_user_cancelled
  | Disp_skipped -> false
;;

let operator_broadcast_dedupe_mu = Eio.Mutex.create ()
let operator_broadcast_dedupe_by_keeper : (string, string) Hashtbl.t =
  Hashtbl.create 16
;;

let operator_broadcast_key_part = function
  | Some value -> value
  | None -> "-"
;;

let operator_broadcast_turn_key = function
  | Some value -> string_of_int value
  | None -> "-"
;;

let operator_broadcast_dedupe_key receipt ~disposition ~reason =
  String.concat
    "\000"
    [ receipt.keeper_name
    ; receipt.agent_name
    ; string_of_int receipt.generation
    ; operator_broadcast_turn_key receipt.turn_count
    ; operator_broadcast_key_part receipt.current_task_id
    ; operator_disposition_kind_to_string disposition
    ; operator_disposition_reason_to_string reason
    ; receipt.terminal_reason_code
    ]
;;

let should_emit_operator_broadcast receipt ~disposition ~reason =
  match reason with
  | Reason_turn_livelock_blocked ->
    let key = operator_broadcast_dedupe_key receipt ~disposition ~reason in
    Eio.Mutex.use_rw ~protect:true operator_broadcast_dedupe_mu (fun () ->
      match Hashtbl.find_opt operator_broadcast_dedupe_by_keeper receipt.keeper_name with
      | Some previous_key when String.equal previous_key key -> false
      | _ ->
        Hashtbl.replace operator_broadcast_dedupe_by_keeper receipt.keeper_name key;
        true)
  | _ -> true
;;

let operator_broadcast_payload (receipt : t) ~disposition ~reason =
  let terminal_reason_code = enrich_contract_violation_reason receipt in
  let disposition_s = operator_disposition_kind_to_string disposition in
  let reason_s = operator_disposition_reason_to_string reason in
  `Assoc
    [ "schema", `String "keeper.operator_broadcast_required.v1"
    ; "keeper_name", `String receipt.keeper_name
    ; "agent_name", `String receipt.agent_name
    ; "trace_id", `String receipt.trace_id
    ; "generation", `Int receipt.generation
    ; ( "turn_count"
      , match receipt.turn_count with
        | Some value -> `Int value
        | None -> `Null )
    ; "disposition", `String disposition_s
    ; "disposition_reason", `String reason_s
    ; "outcome", `String (outcome_kind_to_tla_receipt receipt.outcome)
    ; "terminal_reason_code", `String terminal_reason_code
    ; ( "current_task_id"
      , match receipt.current_task_id with
        | Some value -> `String value
        | None -> `Null )
    ; "goal_ids", list_json receipt.goal_ids
    ; "response_text_present", `Bool receipt.response_text_present
    ; "cascade_name", `String (Cascade_name.to_string receipt.cascade_name)
    ; "cascade_outcome", `String (cascade_outcome_to_string receipt.cascade_outcome)
    ; ( "tool_contract_result"
      , `String (tool_contract_result_to_string receipt.tool_contract_result) )
    ; ( "last_tool_name"
      , match last_tool_name receipt with
        | Some value -> `String value
        | None -> `Null )
    ; "tools_used", list_json receipt.tools_used
    ; ( "contract_violation_detail"
      , match decode_contract_violation_reason terminal_reason_code with
        | None -> `Null
        | Some (contract_id, called, satisfying) ->
          `Assoc
            [ "contract_id", `String contract_id
            ; "called_tools", list_json called
            ; "satisfying_tools", list_json satisfying
            ] )
    ; ( "tool_contract"
      , `Assoc
          [ ( "result"
            , `String (tool_contract_result_to_string receipt.tool_contract_result) )
          ; "required_tools", list_json receipt.tool_surface.required_tools
          ; ( "required_tool_candidates"
            , list_json receipt.tool_surface.required_tool_candidates )
          ; ( "missing_required_tools"
            , list_json receipt.tool_surface.missing_required_tools )
          ; "visible_tool_count", `Int receipt.tool_surface.visible_tool_count
          ; ( "tool_requirement"
            , Keeper_agent_tool_surface.tool_requirement_to_yojson
                receipt.tool_surface.tool_requirement )
          ; ( "turn_lane"
            , Keeper_agent_tool_surface.turn_lane_to_yojson
                receipt.tool_surface.turn_lane )
          ; ( "tool_surface_class"
            , Keeper_agent_tool_surface.tool_surface_class_to_yojson
                receipt.tool_surface.tool_surface_class )
          ; "tool_gate_enabled", `Bool receipt.tool_surface.tool_gate_enabled
          ; ( "tool_surface_fallback_used"
            , `Bool receipt.tool_surface.tool_surface_fallback_used )
          ; ( "materialized_tools"
            , list_json receipt.tool_surface.materialized_tools )
          ] )
    ; ( "sandbox"
      , `Assoc
          [ "kind", `String (Keeper_types.sandbox_profile_to_string receipt.sandbox_kind)
          ; "sandbox_root", string_opt_json receipt.sandbox_root
          ; ( "network_mode"
            , `String (Keeper_types.network_mode_to_string receipt.network_mode) )
          ] )
    ; "model_used", `Null
    ; ( "stop_reason"
      , match receipt.stop_reason with
        | Some value -> `String (stop_reason_to_string value)
        | None -> `Null )
    ; ( "error_kind"
      , match receipt.error_kind with
        | Some v -> `String (error_kind_to_string v)
        | None -> `Null )
    ; ( "error_message"
      , match receipt.error_message with
        | Some v -> `String v
        | None -> `Null )
    ; "ended_at", `String receipt.ended_at
    ]
;;

let emit_operator_broadcast config (receipt : t) ~disposition ~reason =
  let payload = operator_broadcast_payload receipt ~disposition ~reason in
  let event =
    Activity_graph.emit
      config
      ~actor:{ Activity_graph.kind = "agent"; id = receipt.agent_name }
      ~kind:"keeper.operator_broadcast_required"
      ~payload
      ()
  in
  Log.Keeper.warn
    "%s: operator_broadcast_required emitted disposition=%s reason=%s seq=%d"
    receipt.keeper_name
    (operator_disposition_kind_to_string disposition)
    (operator_disposition_reason_to_string reason)
    event.seq
;;

let append (config : Coord.config) (receipt : t) =
  let store =
    Keeper_types_support.keeper_execution_receipt_store config receipt.keeper_name
  in
  let receipt_json = to_json receipt in
  Dated_jsonl.append store receipt_json;
  (try
     Keeper_reaction_ledger.record_execution_receipt_reaction
       config
       ~keeper_name:receipt.keeper_name
       ~trace_id:receipt.trace_id
       ?turn_count:receipt.turn_count
       ~current_task_id:receipt.current_task_id
       ~goal_ids:receipt.goal_ids
       ~outcome:(outcome_kind_to_tla_receipt receipt.outcome)
       ~terminal_reason_code:receipt.terminal_reason_code
       ~receipt_json
       ()
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Keeper.warn
       "%s: reaction ledger receipt append failed trace_id=%s: %s"
       receipt.keeper_name
       receipt.trace_id
       (Printexc.to_string exn));
  let disposition, reason = operator_disposition receipt in
  if needs_operator_broadcast disposition
  then (
    let disposition_s = operator_disposition_kind_to_string disposition in
    let reason_s = operator_disposition_reason_to_string reason in
    if should_emit_operator_broadcast receipt ~disposition ~reason
    then (
      try emit_operator_broadcast config receipt ~disposition ~reason with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        (* fail-closed: log loud, do not silently swallow. The append itself
           has already persisted the receipt; the broadcast failure is its
           own diagnostic that watchdogs/log alerts will pick up. *)
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_execution_receipt_failures
          ~labels:[ "keeper", receipt.keeper_name; "site", Keeper_execution_receipt_failure_site.(to_label Emit_failed) ]
          ();
        Log.Keeper.error
          "%s: operator_broadcast_required EMIT FAILED disposition=%s reason=%s exn=%s"
          receipt.keeper_name
          disposition_s
          reason_s
          (Printexc.to_string exn))
    else (
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_operator_broadcast_suppressed
        ~labels:[ "keeper", receipt.keeper_name; "reason", reason_s ]
        ();
      Log.Keeper.info
        "%s: operator_broadcast_required suppressed duplicate disposition=%s reason=%s turn=%s"
        receipt.keeper_name
        disposition_s
        reason_s
        (operator_broadcast_turn_key receipt.turn_count)))
;;

(* Watchdog-driven broadcast (#fleet-stall 2026-04-26 Step 3): emitted by a
   supervisor-side fiber when a Running keeper has not produced a turn for
   longer than the stale threshold. This is the path that catches the
   "KSM=Running but no live turn" failure mode where the heartbeat fiber is
   blocked on a long call and would otherwise never produce a receipt. *)
let stale_kill_class_label = function
  | Keeper_registry.Idle_turn _ -> "idle_turn"
  | Keeper_registry.In_turn_hung _ -> "in_turn_hung"
  | Keeper_registry.Mid_turn_no_progress _ -> "mid_turn_no_progress"
  | Keeper_registry.Noop_failure_loop _ -> "noop_failure_loop"
;;

let stale_terminal_reason_code_typed reason =
  match reason with
  | Some (Keeper_registry.Provider_timeout_loop _) ->
    Keeper_turn_terminal_code.Provider_runtime_error "provider_timeout_loop"
  | _ -> Keeper_turn_terminal_code.of_failure_reason_option reason
;;

let stale_broadcast_failure_cohort = function
  | Some (Keeper_registry.Provider_timeout_loop _) -> "provider_timeout_loop"
  | Some _ as reason -> Keeper_registry.failure_reason_cohort_key reason
  | None -> "stale_turn_timeout"
;;

let stale_broadcast_failure_reason_text = function
  | Some (Keeper_registry.Provider_timeout_loop { count }) ->
    Some (Printf.sprintf "provider_timeout_loop(count=%d)" count)
  | Some reason -> Some (Keeper_registry.failure_reason_to_string reason)
  | None -> None
;;

let stale_broadcast_kill_class = function
  | Some (Keeper_registry.Stale_turn_timeout cls) -> Some (stale_kill_class_label cls)
  | _ -> None
;;

let stale_turn_bucket stale_seconds =
  if stale_seconds < 30.0
  then "stale_turn_lt_30s"
  else if stale_seconds < 60.0
  then "stale_turn_30s_to_60s"
  else if stale_seconds < 300.0
  then "stale_turn_1m_to_5m"
  else if stale_seconds < 600.0
  then "stale_turn_5m_to_10m"
  else if stale_seconds < 1_800.0
  then "stale_turn_10m_to_30m"
  else "stale_turn_ge_30m"
;;

let stale_broadcast_payload
      ~keeper_name
      ~agent_name
      ~cascade_name
      ~trace_id
      ~generation
      ~failure_reason
      ~stale_seconds
      ~last_turn_ts
  =
  let cascade_name_string = Cascade_name.to_string cascade_name in
  let failure_reason_text = stale_broadcast_failure_reason_text failure_reason in
  let failure_reason_cohort = stale_broadcast_failure_cohort failure_reason in
  `Assoc
    [ "schema", `String "keeper.operator_broadcast_required.v1"
    ; "keeper_name", `String keeper_name
    ; "agent_name", `String agent_name
    ; "cascade_name", `String cascade_name_string
    ; "trace_id", `String trace_id
    ; "generation", `Int generation
    ; "disposition", `String "stalled"
    ; "disposition_reason", `String failure_reason_cohort
    ; ( "terminal_reason_code"
      , `String
          (Keeper_turn_terminal_code.to_wire
             (stale_terminal_reason_code_typed failure_reason)) )
    ; "failure_reason", string_opt_json failure_reason_text
    ; "failure_reason_cohort", `String failure_reason_cohort
    ; "stale_kill_class", string_opt_json (stale_broadcast_kill_class failure_reason)
    ; "stale_turn_bucket", `String (stale_turn_bucket stale_seconds)
    ; "stale_seconds", `Float stale_seconds
    ; "last_turn_ts", `Float last_turn_ts
    ; "source", `String "watchdog"
    ]
;;

let emit_stale_keeper_broadcast
      config
      ~keeper_name
      ~agent_name
      ~cascade_name
      ~trace_id
      ~generation
      ~failure_reason
      ~stale_seconds
      ~last_turn_ts
  =
  let cascade_name_string = Cascade_name.to_string cascade_name in
  let payload =
    stale_broadcast_payload
      ~keeper_name
      ~agent_name
      ~cascade_name
      ~trace_id
      ~generation
      ~stale_seconds
      ~last_turn_ts
      ~failure_reason
  in
  let event =
    Activity_graph.emit
      config
      ~actor:{ Activity_graph.kind = "watchdog"; id = keeper_name }
      ~kind:"keeper.operator_broadcast_required"
      ~payload
      ()
  in
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_execution_receipt_failures
    ~labels:[ "keeper", keeper_name; "site", Keeper_execution_receipt_failure_site.(to_label Stale_broadcast) ]
    ();
  Log.Keeper.warn
    "%s: stale_keeper_broadcast emitted last_turn=%.0fs ago cascade=%s seq=%d"
    keeper_name
    stale_seconds
    cascade_name_string
    event.seq
;;

let latest_json (config : Coord.config) keeper_name =
  let store = Keeper_types_support.keeper_execution_receipt_store config keeper_name in
  match Dated_jsonl.read_recent store 1 with
  | [ json ] -> Some json
  | _ -> None
;;

let latest_json_by_keeper (config : Coord.config) keeper_names =
  keeper_names
  |> List.filter_map (fun keeper_name ->
    match latest_json config keeper_name with
    | Some json -> Some (keeper_name, json)
    | None -> None)
;;
