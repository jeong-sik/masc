(** Success-path post-processing for [Keeper_unified_turn]. *)

module KCB = Keeper_turn_runtime_budget
module KEC = Keeper_context_runtime
module KUM = Keeper_unified_metrics
open Keeper_meta_contract

(* RFC-0132 PR-2: success-path keeper-facing metric label = external boundary; redact via SSOT. *)
let runtime_lane_label = Boundary_redaction.to_string Boundary_redaction.runtime_lane_label

(* cost_usd is accounted independently of token-count trust (token⊥cost), so the
   turn cost no longer needs a usage-trust classification. *)
let turn_cost result = KUM.estimate_usage_cost_usd result.Keeper_agent_run.usage
;;

let apply_lifecycle ~config ~base_dir ~meta ~final_execution ~current_turn_blocker_info result =
  let resilience_handles = KCB.post_turn_resilience_handles ~config ~meta in
  let lifecycle : KEC.post_turn_lifecycle =
    KEC.apply_post_turn_lifecycle_with_resilience_handles
      ~base_dir
      ~resilience_audit_store:resilience_handles.resilience_audit_store
      ~resilience_strategy_executor:resilience_handles.resilience_strategy_executor
      ~on_compaction_started:(fun () ->
        KEC.dispatch_keeper_phase_event
          ~config
          ~origin:Keeper_registry.Post_turn_lifecycle
          ~keeper_name:meta.name
          Keeper_state_machine.Compaction_started)
      ~on_handoff_started:(fun () ->
        KEC.dispatch_keeper_phase_event
          ~config
          ~origin:Keeper_registry.Post_turn_lifecycle
          ~keeper_name:meta.name
          Keeper_state_machine.Handoff_started)
      ~meta
      ~model:result.Keeper_agent_run.model_used
      ~primary_model_max_tokens:final_execution.KCB.max_context
      ~current_turn_blocker_info
      ~checkpoint:result.checkpoint
    |> resilience_handles.sync_lifecycle_meta
  in
  KEC.dispatch_post_turn_lifecycle_events
    ~config
    ~keeper_name:meta.name
    lifecycle;
  lifecycle
;;

let budget_exhausted_no_progress_threshold_override
      ~stop_reason
      ~strong_evidence
      ~surface_requires_evidence
      ~observation
  =
  let budget_exhausted =
    match stop_reason with
    | Runtime_agent.TurnBudgetExhausted _ -> true
    | Runtime_agent.Completed
    | Runtime_agent.MutationBoundaryReached _
    | Runtime_agent.Yielded_to_chat_waiting _
    | Runtime_agent.Yielded_to_durable_stimulus _
    | Runtime_agent.InputRequired _
    | Runtime_agent.ToolFailureRecoveryDeferred _ -> false
  in
  if
    budget_exhausted
    && (not strong_evidence)
    && surface_requires_evidence
    && Keeper_unified_metrics_support.is_scheduled_autonomous_cycle_of_observation
         observation
  then Some 1
  else None
;;

(* Runtime-observed delivery classification for the no-progress loop detector.
   It is derived once from turn facts already in scope — the tool capabilities
   actually exercised and whether visible text was emitted — so the
   anti-thrash verdict never trusts a model-authored delivery label.

   Tool-capability classification is delegated to [Keeper_tool_capability_axis],
   the typed SSOT for tool-name capabilities, rather than matching tool-name
   string literals here (CLAUDE.md anti-pattern #1: no scattered hardcoded tool
   names). *)
type turn_delivery =
  | Peer_only
    (* peer-surface tool (board/comment/broadcast/keeper-msg), or silent:
       no peer/claim tool and no visible text *)
  | User_facing
    (* RFC-0294 R2a [Reply_to_external] concept: non-empty visible reply on a
       REACTIVE turn whose reply is externally delivered to the prompting
       surface. Exempt from evidence: replying to an external prompt is itself
       the work only when the reply is actually sent back. *)
  | Internal_prose
    (* Non-empty prose that is not an externally delivered reactive reply.
       This includes scheduled-autonomous prose and keeper-cycle internal
       decision text produced while stale scope messages are pending. Requires
       evidence: internal prose alone neither clears the external lane nor
       mutates durable workspace state. *)
  | Task_claim (* task-claim tool *)

type reply_delivery =
  | Internal_only
  | Externally_delivered

(* Classify from observable facts. Order is significant: a turn that calls a
   peer-surface tool is [Peer_only] even if it also produced text, because the
   board/broadcast post is the salient delivery; a claim turn is exempt because
   claiming is itself progress (RFC-0239). The canonical precedence is
   peer > claim > text, so a multi-signal turn cannot flip the anti-thrash
   verdict to exempt.

   Behavior change (RFC-0276 §2.4): the [Board_activity] capability set is
   {keeper_board_post, keeper_board_comment, keeper_broadcast, masc_broadcast,
   masc_keeper_msg}. A turn that only sends a peer message with no durable
   evidence accrues the no-progress streak. This is intentional: a bare peer
   message is exactly the "posts to peers without evidence" case RFC-0239
   targets. The set is pinned in test_no_progress_loop_detector so any axis
   change forces a conscious no-progress review. *)
let classify_delivery ~is_autonomous ~reply_delivery ~tools ~has_visible_text =
  if Keeper_tool_capability_axis.(supports_any Board_activity tools)
  then Peer_only
  else if Keeper_tool_capability_axis.(supports_any Claim_task tools)
  then Task_claim
  else if has_visible_text
  then
    match is_autonomous, reply_delivery with
    | false, Externally_delivered -> User_facing
    | (true | false), Internal_only | true, Externally_delivered -> Internal_prose
  else Peer_only
;;

(* A peer-only/silent turn, or internal prose-only turn, must show durable
   evidence to count as progress; an externally delivered reactive user-facing
   reply or a task claim is exempt. Exhaustive, no [_ ->] catch-all (CLAUDE.md
   anti-pattern #4): a new [turn_delivery] variant must be classified here at
   compile time. *)
let delivery_requires_evidence = function
  | Peer_only | Internal_prose -> true
  | User_facing | Task_claim -> false
;;

(* RFC-0239 / audit D1·D3: the no-progress verdict reads the typed
   determinism-boundary outcome ([Keeper_tool_outcome]) recorded on each tool
   call, not just the tool name. A completion/execution call that typed a
   failure is not evidence; a claim that typed [No_progress] did not bind work,
   so the [Task_claim] exemption must not apply to it. A [None] typed outcome
   keeps the legacy name-based behavior: this only DEMOTES on an explicit typed
   failure / no-progress signal, never promotes, so tools that do not emit a
   typed outcome are never newly flagged as no-progress. *)
(* Outcome gate delegates to [Keeper_tool_outcome.is_nonprogress], the single
   owner (RFC-0289 §"Why not the smaller option": the execution-predicate half
   of "substantive" is unified by the library split; the outcome gate is unified
   here, in the module that owns the variant). *)
let typed_outcome_is_nonprogress (outcome : Keeper_tool_outcome.t option) =
  Keeper_tool_outcome.is_nonprogress outcome
;;

(* Outcome-aware substantive evidence: an execution/completion tool whose typed
   outcome is not a failure. Mirrors [Keeper_unified_metrics.has_substantive_tool_calls]
   (name-only) but drops calls the typed channel marked errored / no-progress. *)
let has_substantive_tool_calls_with_outcome
      (calls : (string * Keeper_tool_outcome.t option) list) =
  List.exists
    (fun (name, outcome) ->
       Keeper_tool_progress.is_execution_progress_tool_name name
       && not (typed_outcome_is_nonprogress outcome))
    calls
;;

(* A [Task_claim] turn is exempt from evidence only when a claim actually bound
   work. A claim that typed [No_progress] (No_eligible_tasks / No_work_available
   / Resource_conflict) did not bind work and must accrue the no-progress streak
   (the sangsu claim-idle loop, PR #21065 diagnosis). An untyped claim ([None])
   stays exempt for back-compat. *)
let claim_bound_work (calls : (string * Keeper_tool_outcome.t option) list) =
  List.exists
    (fun (name, outcome) ->
       Keeper_tool_progress.is_claim_context_tool_name name
       && not (typed_outcome_is_nonprogress outcome))
    calls
;;

(* RFC-0303 Phase 3: [no_progress_reason_of_turn] and [apply_loop_detectors]
   are retired. Phase 2 removed the blind self-cadence wake that manufactured
   the passive turns the no-progress loop detector chased, so the success path
   no longer runs loop detection. [Contract_passive_only] remains inert
   telemetry (see [completion_contract_attention_reason_code] below). *)

type terminal_outcome =
  | Terminal_done
  | Terminal_checkpoint
  | Terminal_input_required
  | Terminal_failed_completion_contract of { reason_code : string }

type failure_judgment_delivery =
  | Queue_successor
  | Handled_in_turn

type handle_result =
  | Completed of Keeper_meta_contract.keeper_meta
  | Failed_completion_contract of
      { meta : Keeper_meta_contract.keeper_meta
      ; failure_judgment : Keeper_event_queue.failure_judgment
      ; judgment_delivery : failure_judgment_delivery
      }

let completion_contract_attention_reason_code result =
  match result with
  | Keeper_execution_receipt.Contract_passive_only ->
    (* Passive-only turns are no-progress detector input, not completion-contract
       auto-failures. *)
    None
  | result
    when Keeper_execution_receipt.completion_contract_result_requires_attention
           result ->
    Some (Keeper_execution_receipt.completion_contract_result_to_string result)
  | _ -> None
;;

let completion_contract_terminal_failure_reason_code result =
  match result.Keeper_agent_run.operator_disposition with
  | Some
      { disposition = Keeper_execution_receipt.Disp_pause_human
      ; reason = Keeper_execution_receipt.Reason_completion_contract_unsatisfied
      } ->
    completion_contract_attention_reason_code
      result.Keeper_agent_run.completion_contract_result
  | Some
      { disposition = Keeper_execution_receipt.Disp_alert_exhausted
      ; reason = Keeper_execution_receipt.Reason_turn_budget_exhausted
      } ->
    (match result.Keeper_agent_run.stop_reason with
     | Runtime_agent.TurnBudgetExhausted _ ->
       completion_contract_attention_reason_code
         result.Keeper_agent_run.completion_contract_result
     | Runtime_agent.Completed
     | Runtime_agent.MutationBoundaryReached _
     | Runtime_agent.Yielded_to_chat_waiting _
     | Runtime_agent.Yielded_to_durable_stimulus _
     | Runtime_agent.InputRequired _
     | Runtime_agent.ToolFailureRecoveryDeferred _ -> None)
  | Some _ -> None
  | None ->
    Some
      (Keeper_execution_receipt.operator_disposition_reason_to_string
         Keeper_execution_receipt.Reason_unmapped_runtime_state)
;;

let terminal_outcome_of_result result =
  match completion_contract_terminal_failure_reason_code result with
  | Some reason_code -> Terminal_failed_completion_contract { reason_code }
  | None ->
    (match result.Keeper_agent_run.stop_reason with
     | Runtime_agent.Completed -> Terminal_done
     | Runtime_agent.InputRequired _ -> Terminal_input_required
     | Runtime_agent.TurnBudgetExhausted _
     | Runtime_agent.MutationBoundaryReached _
     | Runtime_agent.Yielded_to_chat_waiting _
     | Runtime_agent.Yielded_to_durable_stimulus _
     | Runtime_agent.ToolFailureRecoveryDeferred _ ->
       Terminal_checkpoint)
;;

let terminal_outcome_is_completed_turn = function
  | Terminal_done | Terminal_checkpoint | Terminal_input_required -> true
  | Terminal_failed_completion_contract _ -> false
;;

let terminal_outcome_to_activity_kind = function
  | Terminal_failed_completion_contract _ -> "keeper.turn_failed"
  | Terminal_done | Terminal_checkpoint -> "keeper.turn_completed"
  | Terminal_input_required -> "keeper.turn_input_required"

let terminal_outcome_to_label = function
  | Terminal_done -> "done"
  | Terminal_checkpoint -> "checkpoint"
  | Terminal_input_required -> "input_required"
  | Terminal_failed_completion_contract _ -> "failed"

let terminal_outcome_to_log_label = function
  | Terminal_done -> "OK"
  | Terminal_checkpoint -> "checkpoint"
  | Terminal_input_required -> "input_required"
  | Terminal_failed_completion_contract _ -> "failed"

let append_metrics_snapshot
      ~config
      ~meta
      ~updated_meta
      ~observation
      ~result
      ~latency_ms
      ~turn_cost
      ~(lifecycle : KEC.post_turn_lifecycle)
      ~last_provider_timeout_budget
      ~terminal_outcome
  =
  let any_pending =
    observation.Keeper_world_observation.pending_mentions <> []
    || observation.pending_board_events <> []
    || observation.pending_scope_messages <> []
  in
  (* Single typed channel for the whole cycle: post helpers + the metrics
     snapshot + the failure-path label all derive from one value, so the
     reactive/autonomous decision can no longer drift between sites. *)
  let channel =
    if any_pending
    then Keeper_world_observation.Reactive
    else Keeper_world_observation.Scheduled_autonomous
  in
  let channel_tag = Keeper_world_observation.channel_to_string channel in
  try
    if any_pending
    then Keeper_turn_helpers.post_assign_task ~any_pending ~channel:channel_tag
    else Keeper_turn_helpers.post_empty_queue_sleep ~any_pending ~channel:channel_tag;
    KUM.append_metrics_snapshot
      ~config
      ~meta:updated_meta
      ~observation
      ~result
      ~latency_ms
      ~turn_cost
      ~turn_generation:lifecycle.KEC.turn_generation
      ~channel
      ~snapshot_source:"keeper_unified_turn"
      ~context_ratio:lifecycle.context_ratio
      ~context_tokens:lifecycle.context_tokens
      ~context_max:lifecycle.context_max
      ~message_count:lifecycle.message_count
      ~compaction:lifecycle.compaction
      ~handoff_json:lifecycle.handoff_json
      ?provider_timeout_plan_json:
        (Option.map KCB.provider_timeout_budget_to_yojson last_provider_timeout_budget)
      ~count_completed_turn:(terminal_outcome_is_completed_turn terminal_outcome)
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string MetricEmitDropped)
      ~labels:
        [ "keeper", updated_meta.name
        ; "channel", channel_tag
        ; "site", Keeper_metric_emit_dropped_site.(to_label Keeper_unified_turn)
        ]
      ();
    Log.Keeper.error
      "write metrics snapshot failed after keeper cycle: %s"
      (Printexc.to_string exn);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string TurnMetricsSnapshotFailures)
      ~labels:
        [ "keeper", meta.Keeper_meta_contract.name
        ; "site", Keeper_turn_metrics_snapshot_failure_site.(to_label Post_cycle)
        ]
      ()
;;

let emit_activity_graph
      ~config
      ~updated_meta
      ~result
      ~latency_ms
      ~turn_cost
      ~usage_trust
      ~usage_trusted
      ~turn_mode_label
      ~(lifecycle : KEC.post_turn_lifecycle)
      ~wall_tokens_per_second
      ~terminal_outcome
  =
  try
    let activity_kind = terminal_outcome_to_activity_kind terminal_outcome in
    let cache_miss_input_tokens =
      Keeper_hooks_oas.cache_miss_input_tokens
        ~input_tokens:result.Keeper_agent_run.usage.input_tokens
        ~cache_creation_input_tokens:result.usage.cache_creation_input_tokens
        ~cache_read_input_tokens:result.usage.cache_read_input_tokens
    in
    let event =
      Activity_graph.emit
        config
        ~actor:{ kind = "agent"; id = updated_meta.Keeper_meta_contract.agent_name }
        ~kind:activity_kind
        ~payload:
          (`Assoc
              ([ "keeper_name", `String updated_meta.name
               ; "terminal_outcome", `String (terminal_outcome_to_label terminal_outcome)
               ; ( "input_tokens"
                 , if usage_trusted then `Int result.Keeper_agent_run.usage.input_tokens else `Null )
               ; ( "output_tokens"
                 , if usage_trusted then `Int result.usage.output_tokens else `Null )
               ; ( "cache_creation_tokens"
                 , if usage_trusted
                   then `Int result.usage.cache_creation_input_tokens
                   else `Null )
               ; ( "cache_read_tokens"
                 , if usage_trusted then `Int result.usage.cache_read_input_tokens else `Null )
               ; ( "cache_miss_input_tokens"
                 , if usage_trusted then `Int cache_miss_input_tokens else `Null )
               ; ("cost_usd", if usage_trusted then `Float turn_cost else `Null)
               ; "latency_ms", `Int latency_ms
               ; "model_used", `Null
               ; "resolved_model_id", `Null
               ; "usage_trust", `String (KUM.usage_trust_to_string usage_trust)
               ; ( "usage_anomaly_reasons"
                 , `List
                     (List.map
                        (fun reason -> `String reason)
                        (KUM.usage_trust_reasons usage_trust)) )
               ; "turn_mode", `String turn_mode_label
               ; "context_ratio", `Float lifecycle.KEC.context_ratio
               ]
               @ (match wall_tokens_per_second with
                  | Some v -> [ "tokens_per_second", `Float v ]
                  | None -> [])
               @
               match result.inference_telemetry with
               | Some t ->
                 (match t.reasoning_tokens with
                  | Some n -> [ "reasoning_tokens", `Int n ]
                  | None -> [])
                 @
                   (match t.timings with
                   | Some ti ->
                     (match ti.prompt_per_second with
                      | Some v -> [ "prompt_per_second", `Float v ]
                      | None -> [])
                     @
                       (match ti.predicted_per_second with
                       | Some v -> [ "hw_decode_tokens_per_second", `Float v ]
                       | None -> [])
                   | None -> [])
               | None -> []))
        ~tags:[ "keeper"; "turn"; "metrics" ]
        ()
    in
    Log.Keeper.debug
      "%s: activity graph %s emitted seq=%d"
      updated_meta.name
      activity_kind
      event.seq
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
      ~config
      ~keeper_name:updated_meta.name
      ~side_effect:"activity graph turn terminal emit"
      (Printexc.to_string exn)
;;

let emit_usage_metrics_and_log
      ~updated_meta
      ~result
      ~latency_ms
      ~usage_trust
      ~usage_trusted
      ~turn_mode_label
      ~(lifecycle : KEC.post_turn_lifecycle)
      ~terminal_outcome
  =
  let outcome_str =
    match result.Keeper_agent_run.stop_reason with
    | Runtime_agent.Completed -> "completed"
    | Runtime_agent.TurnBudgetExhausted { turns_used; limit; _ } ->
      Printf.sprintf "budget_exhausted(%d/%d)" turns_used limit
    | Runtime_agent.MutationBoundaryReached { turns_used; tool_name } ->
      (match tool_name with
       | Some tool -> Printf.sprintf "mutation_boundary(%d:%s)" turns_used tool
       | None -> Printf.sprintf "mutation_boundary(%d)" turns_used)
    | Runtime_agent.Yielded_to_chat_waiting { turns_used } ->
      Printf.sprintf "yielded_to_chat_waiting(%d)" turns_used
    | Runtime_agent.Yielded_to_durable_stimulus { turns_used } ->
      Printf.sprintf "yielded_to_durable_stimulus(%d)" turns_used
    | Runtime_agent.InputRequired { turns_used; _ } ->
      Printf.sprintf "input_required(%d)" turns_used
    | Runtime_agent.ToolFailureRecoveryDeferred { turns_used; _ } ->
      Printf.sprintf "tool_failure_recovery_deferred(%d)" turns_used
  in
  let outcome_label =
    match terminal_outcome with
    | Terminal_failed_completion_contract _ -> "failure"
    | Terminal_done -> "success"
    | Terminal_input_required -> "input_required"
    | Terminal_checkpoint ->
      (match result.stop_reason with
       | Runtime_agent.TurnBudgetExhausted _ -> "budget_exhausted"
       | Runtime_agent.MutationBoundaryReached _ -> "mutation_boundary"
       | Runtime_agent.Yielded_to_chat_waiting _ -> "yielded_to_chat_waiting"
       | Runtime_agent.Yielded_to_durable_stimulus _ ->
         "yielded_to_durable_stimulus"
       | Runtime_agent.InputRequired _ -> "input_required"
       | Runtime_agent.ToolFailureRecoveryDeferred _ ->
         "tool_failure_recovery_deferred"
       | Runtime_agent.Completed -> "success")
  in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string Turns)
    ~labels:[ "keeper", updated_meta.name; "outcome", outcome_label ]
    ();
  if usage_trusted
  then (
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string InputTokens)
      ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
      ~delta:(float_of_int result.usage.input_tokens)
      ();
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string OutputTokens)
      ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
      ~delta:(float_of_int result.usage.output_tokens)
      ();
    if result.usage.cache_creation_input_tokens > 0
    then
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string CacheCreationTokens)
        ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
        ~delta:(float_of_int result.usage.cache_creation_input_tokens)
        ();
    if result.usage.cache_read_input_tokens > 0
    then
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string CacheReadTokens)
        ~labels:[ "keeper", updated_meta.name; "model", runtime_lane_label ]
        ~delta:(float_of_int result.usage.cache_read_input_tokens)
        ())
  else (
    let reasons =
      match KUM.usage_trust_reasons usage_trust with
      | [] -> [ KUM.usage_trust_to_string usage_trust ]
      | reasons -> reasons
    in
    List.iter
      (fun reason ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string UsageAnomalies)
           ~labels:
             [ "keeper", updated_meta.name
             ; "model", runtime_lane_label
             ; "reason", reason
             ]
           ())
      reasons;
    let log_usage =
      if Keeper_usage_trust.warns_operator usage_trust
      then Log.Keeper.warn
      else Log.Keeper.info
    in
    log_usage
      "%s: keeper usage telemetry %s runtime_lane=%s reasons=%s input=%d output=%d \
       context_max=%d"
      updated_meta.name
      (if Keeper_usage_trust.warns_operator usage_trust
       then "untrusted"
       else "unavailable")
      runtime_lane_label
      (String.concat "," reasons)
      result.usage.input_tokens
      result.usage.output_tokens
      lifecycle.KEC.context_max);
  let logged_total_tokens =
    if usage_trusted then result.usage.input_tokens + result.usage.output_tokens else 0
  in
  match terminal_outcome with
  | Terminal_failed_completion_contract { reason_code } ->
    Log.Keeper.warn
      "%s: keeper cycle failed runtime_lane=%s tokens=%d latency=%dms mode=%s \
       stop=%s terminal=completion_contract_violation reason=%s"
      updated_meta.name
      runtime_lane_label
      logged_total_tokens
      latency_ms
      turn_mode_label
      outcome_str
      reason_code
  | Terminal_done | Terminal_checkpoint | Terminal_input_required ->
    Log.Keeper.info
      "%s: keeper cycle %s runtime_lane=%s tokens=%d latency=%dms mode=%s stop=%s"
      updated_meta.name
      (terminal_outcome_to_log_label terminal_outcome)
      runtime_lane_label
      logged_total_tokens
      latency_ms
      turn_mode_label
      outcome_str
;;

type decision_outcome =
  | Decision_success
  | Decision_checkpoint
  | Decision_input_required
  | Decision_failure

let decision_outcome_of_terminal_outcome = function
  | Terminal_done -> Decision_success
  | Terminal_checkpoint -> Decision_checkpoint
  | Terminal_input_required -> Decision_input_required
  | Terminal_failed_completion_contract _ -> Decision_failure

let decision_outcome_to_label = function
  | Decision_success -> "success"
  | Decision_checkpoint -> "checkpoint"
  | Decision_input_required -> "input_required"
  | Decision_failure -> "failure"

let terminal_reason_of_outcome result = function
  | Terminal_done -> Keeper_turn_terminal.success ()
  | Terminal_input_required ->
    Keeper_turn_terminal.of_disposition
      ~source:"runtime_stop_reason"
      Keeper_turn_disposition.Input_required
  | Terminal_checkpoint ->
    (match result.Keeper_agent_run.stop_reason with
     | Runtime_agent.TurnBudgetExhausted { turns_used; limit } ->
       Keeper_turn_terminal.of_disposition
         ~source:"runtime_stop_reason"
         (Keeper_turn_disposition.Turn_budget_exhausted
            { detail = None; used = turns_used; limit })
     | Runtime_agent.MutationBoundaryReached _
     | Runtime_agent.Yielded_to_chat_waiting _
     | Runtime_agent.Yielded_to_durable_stimulus _
     | Runtime_agent.InputRequired _ ->
       Keeper_turn_terminal.of_disposition
         ~source:"runtime_stop_reason"
         Keeper_turn_disposition.Input_required
     | Runtime_agent.ToolFailureRecoveryDeferred _
     | Runtime_agent.Completed ->
       Keeper_turn_terminal.success ())
  | Terminal_failed_completion_contract _ ->
    Keeper_turn_terminal.of_disposition
      ~source:"completion_contract"
      Keeper_turn_disposition.Completion_contract_unsatisfied

let persist_terminal_turn_meta
      ~config
      ~original_meta
      ~clear_auto_resume_after_sec
      ~updated_meta
  =
  let updated_meta =
    if clear_auto_resume_after_sec && updated_meta.auto_resume_after_sec <> None
    then { updated_meta with auto_resume_after_sec = None }
    else updated_meta
  in
  (match
     Keeper_meta_store.write_meta_with_merge
       ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
       config
       updated_meta
   with
   | Ok () -> ()
   | Error msg ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string WriteMetaFailures)
       ~labels:
         [ "keeper", updated_meta.name
         ; ( "phase"
           , if Keeper_meta_store.is_version_conflict_error msg
             then "keeper_cycle_cas_race"
             else "keeper_cycle" )
         ]
       ();
     (* #22043: emit inside the [Error] arm so
        [write_meta_cycle_failures_total] stays a failure counter. It is
        summed into the dashboard failure panel (Dashboard.ml), and the
        sibling emit site (Keeper_unified_turn.ml, site=Turn_failure) only
        fires on the failure path. Previously this inc sat after the match
        and fired on every successful persist cycle, inflating the series. *)
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string WriteMetaCycleFailures)
       ~labels:
         [ "keeper", original_meta.name
         ; "site", Keeper_write_meta_cycle_failure_site.(to_label Keeper_cycle)
         ]
       ();
     if Keeper_meta_store.is_version_conflict_error msg
     then Log.Keeper.warn "write_meta lost CAS race after retries (keeper cycle): %s" msg
     else Log.Keeper.error "write_meta failed after keeper cycle: %s" msg);
  updated_meta
;;

let reset_turn_failures_for_stop_reason ~config ~updated_meta result =
  let reset_failure_state () =
    Keeper_registry.set_failure_reason
      ~base_path:config.Workspace.base_path
      updated_meta.name
      None;
    Keeper_registry.reset_turn_failures
      ~base_path:config.Workspace.base_path
      updated_meta.name;
    Health.record_success ~agent_name:updated_meta.name
  in
  match result.Keeper_agent_run.stop_reason with
  | Runtime_agent.TurnBudgetExhausted { turns_used; limit } ->
    Log.Keeper.warn ~keeper_name:updated_meta.name
      "turn budget exhausted (%d/%d), checkpoint saved; not recording health success \
       or clearing turn-failure state"
      turns_used
      limit
  | Runtime_agent.MutationBoundaryReached { tool_name; _ } ->
    Log.Keeper.info ~keeper_name:updated_meta.name
      "mutation boundary reached after %s, checkpoint saved — will resume next cycle"
      (match tool_name with
       | Some tool -> tool
       | None -> "committed tool");
    reset_failure_state ()
  | Runtime_agent.Yielded_to_chat_waiting { turns_used } ->
    (* A clean, intentional yield to a parked chat, not a degraded outcome:
       clear turn-failure state and record health success, like a completed
       turn. The keeper resumes its own work on the next cycle. *)
    Log.Keeper.info ~keeper_name:updated_meta.name
      "yielded turn slot to a waiting chat request after %d turn(s), checkpoint \
       saved — will resume next cycle"
      turns_used;
    reset_failure_state ()
  | Runtime_agent.Yielded_to_durable_stimulus { turns_used } ->
    Log.Keeper.info ~keeper_name:updated_meta.name
      "yielded autonomous run for a pending durable stimulus after %d turn(s), \
       checkpoint saved — will resume next cycle"
      turns_used;
    reset_failure_state ()
  | Runtime_agent.ToolFailureRecoveryDeferred
      { turns_used; reason; tool_names } ->
    Log.Keeper.info ~keeper_name:updated_meta.name
      "typed tool-failure recovery deferred after %d turn(s), checkpoint saved \
       tools=%s reason_digest=%s"
      turns_used
      (String.concat "," tool_names)
      Digestif.SHA256.(digest_string reason |> to_hex);
    reset_failure_state ()
  | Runtime_agent.InputRequired { turns_used; request } ->
    Log.Keeper.info ~keeper_name:updated_meta.name
      "typed input required after %d turn(s), checkpoint saved request_id=%s"
      turns_used
      request.Agent_sdk.Error.request_id;
    reset_failure_state ()
  | Runtime_agent.Completed -> reset_failure_state ()
;;

module For_testing = struct
  let budget_exhausted_no_progress_threshold_override =
    budget_exhausted_no_progress_threshold_override

  type nonrec turn_delivery = turn_delivery =
    | Peer_only
    | User_facing
    | Internal_prose
    | Task_claim

  type nonrec reply_delivery = reply_delivery =
    | Internal_only
    | Externally_delivered

  let classify_delivery = classify_delivery
  let delivery_requires_evidence = delivery_requires_evidence
  let has_substantive_tool_calls_with_outcome = has_substantive_tool_calls_with_outcome
  let claim_bound_work = claim_bound_work

  let completion_contract_terminal_failure_reason_code =
    completion_contract_terminal_failure_reason_code

  type nonrec terminal_outcome = terminal_outcome =
    | Terminal_done
    | Terminal_checkpoint
    | Terminal_input_required
    | Terminal_failed_completion_contract of { reason_code : string }

  let terminal_outcome_of_result = terminal_outcome_of_result
  let terminal_outcome_is_completed_turn = terminal_outcome_is_completed_turn

  let persist_terminal_turn_meta_for_outcome
        ~config
        ~original_meta
        ~updated_meta
        ~terminal_outcome
    =
    persist_terminal_turn_meta
      ~config
      ~original_meta
      ~clear_auto_resume_after_sec:(terminal_outcome_is_completed_turn terminal_outcome)
      ~updated_meta

  let reset_turn_failures_for_stop_reason = reset_turn_failures_for_stop_reason
end

let completion_contract_attention_detail ~reason_code =
  Printf.sprintf
    "completion contract requires attention after runtime success: result=%s"
    reason_code
;;

let record_completion_contract_attention_failure
      ~(config : Workspace.config)
      ~(updated_meta : Keeper_meta_contract.keeper_meta)
      ~runtime_id
      ~reason_code
  =
  let base_path = config.Workspace.base_path in
  let detail = completion_contract_attention_detail ~reason_code in
  Keeper_registry.increment_turn_failures ~base_path updated_meta.name;
  Keeper_registry.set_failure_reason
    ~base_path
    updated_meta.name
    (Some (Keeper_registry.Completion_contract_violation { detail }));
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ContractViolations)
    ~labels:[ "keeper", updated_meta.name ]
    ();
  Health.record_failure
    ~agent_name:updated_meta.name
    ~reason:(Keeper_types_profile.short_preview detail);
  let count = Keeper_registry.get_turn_failures ~base_path updated_meta.name in
  let fj : Keeper_event_queue.failure_judgment =
    { fj_runtime_id = runtime_id
    ; fj_judgment = Keeper_runtime_failure_route.Contract_violation
    ; fj_detail = detail
    }
  in
  if Keeper_pacing_shadow.pacing_enforced ()
  then (
    (* Return the typed successor to the owning heartbeat lease transaction.
       Enqueueing here would commit the successor separately from acknowledging
       the stimulus that caused this turn. *)
    Log.Keeper.warn
      "%s: completion contract attention (streak=%d, reason=%s) escalated as \
       an atomic judgment successor (RFC-0313 W3)"
      updated_meta.name
      count
      reason_code;
    updated_meta, fj, Queue_successor)
  else (
    let pause_threshold = Runtime.pause_threshold () in
    let turn_fail_streak_threshold =
      pause_threshold.Runtime_schema.turn_fail_streak_threshold
    in
    if count >= turn_fail_streak_threshold && not updated_meta.paused
    then (
      let blocker =
        Keeper_meta_contract.blocker_info_of_class
          ~detail:(Keeper_types_profile.short_preview detail)
          Keeper_meta_contract.Completion_contract_violation
      in
      let pause_meta =
        { updated_meta with
          runtime = { updated_meta.runtime with last_blocker = Some blocker }
        }
      in
      match
        KCB.sync_keeper_paused_state_with_resume_policy
          ~config
          ~meta:pause_meta
          ~paused:true
          ~resume_policy:Keeper_supervisor_pause_policy.Manual_resume_required
      with
      | Ok paused_meta ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string FailureDrivenPause)
          ~labels:
            [ "keeper", updated_meta.name
            ; "site", "completion_contract_attention"
            ]
          ();
        Log.Keeper.warn
          "%s: auto-paused after %d completion contract attention failures \
           (pause_threshold=%d, reason=%s); operator must inspect provider/model \
           reasoning/tool interleave before resuming"
          updated_meta.name
          count
          turn_fail_streak_threshold
          reason_code;
        paused_meta, fj, Handled_in_turn
      | Error sync_err ->
        Log.Keeper.error
          "%s: completion contract attention auto-pause sync failed: %s \
           (persistent failure remains counted)"
          updated_meta.name
          sync_err;
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string RuntimeSyncFailures)
          ~labels:
            [ "keeper", updated_meta.name
            ; "site", "completion_contract_attention_auto_pause"
            ]
          ();
        pause_meta, fj, Handled_in_turn)
    else updated_meta, fj, Handled_in_turn)
;;

let emit_terminal_fsm
      ~config
      ~meta
      ~keeper_turn_id
      ~updated_meta
      ~runtime_id
      ~terminal_outcome
      result
  =
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.Keeper_meta_contract.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Streaming
    Keeper_turn_fsm.Completing;
  match terminal_outcome with
  | Terminal_failed_completion_contract { reason_code } ->
    let updated_meta, failure_judgment, judgment_delivery =
      record_completion_contract_attention_failure
        ~config
        ~updated_meta
        ~runtime_id
        ~reason_code
    in
    Keeper_turn_fsm.emit_transition
      ~keeper_name:meta.name
      ~turn_id:keeper_turn_id
      ~prev:Keeper_turn_fsm.Completing
      (Keeper_turn_fsm.Failed
         (Keeper_turn_fsm.Failure_completion_contract_violation { reason_code }));
    Failed_completion_contract
      { meta = updated_meta; failure_judgment; judgment_delivery }
  | Terminal_done | Terminal_checkpoint | Terminal_input_required ->
    reset_turn_failures_for_stop_reason ~config ~updated_meta result;
    Keeper_turn_fsm.emit_transition
      ~keeper_name:meta.name
      ~turn_id:keeper_turn_id
      ~prev:Keeper_turn_fsm.Completing
      Keeper_turn_fsm.Done;
    Completed updated_meta
;;

let handle
      ~config
      ~base_dir
      ~meta
      ~turn_ctx_cell
      ~observation
      ~final_execution
      ~latency_ms
      ~degraded_retry_applied
      ~degraded_retry_runtime
      ~fallback_reason
      ~last_provider_timeout_budget
      ~current_turn_blocker_info
      ~keeper_turn_id
      result
  =
  let turn_cost = turn_cost result in
  let lifecycle =
    apply_lifecycle
      ~config
      ~base_dir
      ~meta
      ~final_execution
      ~current_turn_blocker_info
      result
  in
  let updated_meta =
    KUM.update_metrics_from_result
      lifecycle.KEC.updated_meta
      ~latency_ms
      ~observation
      ~context_max:lifecycle.context_max
      ~update_proactive_rt:true
      result
  in
  (* RFC-0303 Phase 3: the no-progress loop detector is retired, so the
     metrics-updated meta flows through unchanged (no loop-detection rebind). *)
  let terminal_outcome = terminal_outcome_of_result result in
  append_metrics_snapshot
    ~config
    ~meta
    ~updated_meta
    ~observation
    ~result
    ~latency_ms
    ~turn_cost
    ~lifecycle
    ~last_provider_timeout_budget
    ~terminal_outcome;
  let turn_mode = KUM.turn_mode_of_result result in
  let turn_mode_label = KUM.turn_mode_to_string turn_mode in
  let usage_trust =
    KUM.classify_usage_trust
      ~usage_reported:result.Keeper_agent_run.usage_reported
      ~usage:result.usage
      ~context_max:lifecycle.context_max
  in
  let usage_trusted = KUM.usage_trust_is_trusted usage_trust in
  let wall_tokens_per_second =
    if usage_trusted && latency_ms > 0
    then Some (float_of_int result.usage.output_tokens /. (float_of_int latency_ms /. 1000.0))
    else None
  in
  emit_activity_graph
    ~config
    ~updated_meta
    ~result
    ~latency_ms
    ~turn_cost
    ~usage_trust
    ~usage_trusted
    ~turn_mode_label
    ~lifecycle
    ~wall_tokens_per_second
    ~terminal_outcome;
  KUM.broadcast_lifecycle_events
    ~name:updated_meta.name
    ~turn_generation:lifecycle.turn_generation
    ~compaction:lifecycle.compaction
    ~handoff_json:lifecycle.handoff_json;
  KUM.append_decision_record
    ~config
    ~meta:updated_meta
    ~turn_ctx_cell
    ~observation
    ~latency_ms
    ~outcome:
      (decision_outcome_to_label
         (decision_outcome_of_terminal_outcome terminal_outcome))
    ~degraded_retry_applied
    ?degraded_retry_runtime
    ?fallback_reason:(Option.map Keeper_error_classify.degraded_retry_reason_to_string fallback_reason)
    ~turn_mode
    ~terminal_reason:(terminal_reason_of_outcome result terminal_outcome)
    ~result:(Some result)
    ();
  emit_usage_metrics_and_log
    ~updated_meta
    ~result
    ~latency_ms
    ~usage_trust
    ~usage_trusted
    ~turn_mode_label
    ~lifecycle
    ~terminal_outcome;
  (* Every terminal outcome has consumed a keeper turn id. Persist the updated
     usage even for completion-contract failures so the next cycle cannot
     allocate the same turn id again. *)
  let updated_meta =
    persist_terminal_turn_meta
      ~config
      ~original_meta:meta
      ~clear_auto_resume_after_sec:(terminal_outcome_is_completed_turn terminal_outcome)
      ~updated_meta
  in
  let tool_call_summaries =
    let max_tool_calls = 10 in
    result.Keeper_agent_run.tool_calls
    |> List.map (fun (d : Keeper_agent_run.tool_call_detail) ->
       ( { tool_name = d.tool_name; outcome = d.outcome }
         : Keeper_meta_contract.tool_call_summary ))
    |> fun l ->
    let rec take n = function [] -> [] | h :: t -> if n <= 0 then [] else h :: take (n - 1) t in
    take max_tool_calls l
  in
  let updated_meta =
    { updated_meta with
      runtime = { updated_meta.runtime with last_turn_tool_calls = tool_call_summaries }
    }
  in
  (* Single source of truth for success-path terminal FSM transitions.
     [Keeper_unified_turn.handle] is the only caller. The terminal outcome is
     computed before side effects, so metrics, decision records, activity graph,
     meta writes, health/failure accounting, and FSM emission cannot disagree
     on whether this turn completed or failed its completion contract. *)
  emit_terminal_fsm
    ~config
    ~meta
    ~keeper_turn_id
    ~updated_meta
    ~runtime_id:final_execution.runtime_id
    ~terminal_outcome
    result
;;
