(** Keeper_meta_contract_types — type definitions, serialization, and
    blocker classification extracted from [Keeper_meta_contract] (699 LoC).

    Contains all policy/runtime record types, blocker variant taxonomy,
    cascade attempt tracking, and their JSON converters.
    @since Keeper 500-line decomposition *)

(* -- Policy types (remain in keeper_meta top-level) -- *)

type compaction_policy =
  { profile : string
  ; ratio_gate : float
  ; message_gate : int
  ; token_gate : int
  ; cooldown_sec : int
  ; max_checkpoint_messages : int
  ; keep_recent_tool_results : int
    (* Verbatim tool-result tail length for OAS context compaction
       (consumed by [Agent_sdk.Context_reducer.stub_tool_results
       ~keep_recent]).  Default 2; parsers clamp to
       [[0, Keeper_config.keep_recent_tool_results_max]]. *)
  ; tool_heavy_msg_threshold : int
    (* Per-keeper message-count floor for the tool-heavy compaction
       gate.  Default {!Keeper_config.default_tool_heavy_msg_threshold}
       (40); preserves prior global behavior in
       [Keeper_compact_policy].  Heavy-tool keepers can lower this
       to compact sooner without code change.  Wired by PR-B. *)
  ; tool_heavy_ratio_floor : float
    (* Per-keeper context-ratio floor for the tool-heavy compaction
       gate.  Default
       {!Keeper_config.default_tool_heavy_ratio_floor} (0.15);
       preserves prior global behavior.  Wired by PR-B. *)
  }

type proactive_policy =
  { enabled : bool
  ; idle_sec : int
  ; cooldown_sec : int
  }

type proactive_cycle_outcome =
  | Proactive_never_started
  | Proactive_unknown
  | Proactive_silent
  | Proactive_text_response
  | Proactive_tool_use
  | Proactive_mixed_response
  | Proactive_error

(* -- Runtime types (moved into agent_runtime_state) -- *)

type compaction_runtime_decision = Compaction_runtime_decision of string

let compaction_runtime_decision_to_string (Compaction_runtime_decision value) = value
let compaction_runtime_decision_of_string value = Compaction_runtime_decision value

type compaction_runtime =
  { count : int
  ; last_ts : float
  ; last_before_tokens : int
  ; last_after_tokens : int
  ; last_check_ts : float
  ; last_decision : compaction_runtime_decision
  }

type proactive_runtime =
  { count_total : int
  ; last_ts : float
  ; visible_count_total : int
  ; last_visible_ts : float
  ; last_outcome : proactive_cycle_outcome
  ; last_reason : string
  ; last_preview : string
  ; last_work_discovery_ts : float
  ; work_discovery_count : int
  ; consecutive_noop_count : int
    (** Consecutive autonomous cycles where only observation tools
          (board_list, stay_silent, context_status) were used with no
          substantive action.  Resets to 0 on any productive cycle.
          Used by [effective_scheduled_autonomous_cooldown] for exponential
          backoff: cooldown *= 2^min(n, 3), capping at 8x. *)
  }

(* ── Structured blocker classification ──────────────────────── *)

type cascade_exhaustion_reason =
  | Connection_refused
  | Dns_failure
    (** RFC-0142 PR-2 (2026-05-22): typed surface for the dominant Other_detail
        message ["failed to resolve hostname: ..."] (50% live share on 5/21).
        Producer-side typed signal already exists at
        [Llm_provider.Http_client.network_error_kind] as [Dns_failure];
        previously [keeper_turn_driver.ml]'s NetworkError branch only honoured
        [Connection_refused] and let [Dns_failure] fall through the
        string/substring SSOT, manifesting as [Other_detail "failed to resolve
        hostname: ..."].  This variant closes that typed→string→typed
        roundtrip without adding any new substring matcher. *)
  | No_providers_available
  | All_providers_failed
  | Candidates_filtered_after_cycles
  | Max_turns_exceeded
  | Structural_attempt_timeout of { detail : string }
  | Other_detail of string

type blocker_class =
  | Cascade_exhausted of cascade_exhaustion_reason
  | Capacity_backpressure
  | Ambiguous_post_commit_timeout
  | Ambiguous_post_commit_failure
  | Autonomous_slot_wait_timeout
  | Admission_queue_wait_timeout
  | Turn_timeout_after_queue_wait
  | Turn_timeout
  | Turn_livelock_blocked
  | Completion_contract_violation
  | No_tool_capable_provider
  | Stay_silent_loop
  | Fiber_unresolved
    (** 2026-05-05: turn fiber finished without invoking [resolve_done]
        (cancelled mid-turn, raised an exception not handled by the
        body, or the OAS request returned but the keeper switch tore
        down before completion bookkeeping ran).  Maps 1:1 to the
        supervisor's [Keeper_registry.Fiber_unresolved] cohort key
        used by self-preservation, so blocker_class stamping mirrors
        the same diagnosis on keeper_meta. *)
  | Stale_turn_timeout
    (** 2026-05-05 cycle 9: stale watchdog forced fiber termination
        because the running turn exceeded [idle_turn] threshold (~5m).
        Maps to [Keeper_registry.Stale_turn_timeout _] cohort.  Like
        [Fiber_unresolved], this path runs through
        [force_unresolved_watchdog_crash] and never visits
        [handle_crash_auto_pause], so historical string-only blocker
        stamping did not apply. Without this variant, dashboards and
        per-keeper meta lacked a structured blocker class for the majority
        cohort during a fleet stall (observed: 6/14 keepers in
        cohort=stale_turn_timeout). *)
  | Stale_fleet_batch
    (** Legacy blocker class for pre-existing fleet-batch state. Current
        fleet-batch detection is observation-only and should not stamp keeper
        meta; stale keepers use their per-keeper watchdog blocker instead. *)
  | Sdk_max_turns_exceeded
  | Sdk_token_budget_exceeded
  | Sdk_cost_budget_exceeded
  | Sdk_unrecognized_stop_reason
  | Sdk_idle_detected
  | Sdk_tool_retry_exhausted
  | Sdk_guardrail_violation
  | Sdk_tripwire_violation
  | Sdk_exit_condition_met
  | Sdk_input_required

let blocker_class_to_string = function
  | Cascade_exhausted _ -> "cascade_exhausted"
  | Capacity_backpressure -> "capacity_backpressure"
  | Ambiguous_post_commit_timeout -> "ambiguous_post_commit_timeout"
  | Ambiguous_post_commit_failure -> "ambiguous_post_commit_failure"
  | Autonomous_slot_wait_timeout -> "autonomous_slot_wait_timeout"
  | Admission_queue_wait_timeout -> "admission_queue_wait_timeout"
  | Turn_timeout_after_queue_wait -> "turn_timeout_after_queue_wait"
  | Turn_timeout -> "turn_timeout"
  | Turn_livelock_blocked -> "turn_livelock_blocked"
  | Completion_contract_violation -> "completion_contract_violation"
  | No_tool_capable_provider -> "no_tool_capable_provider"
  | Stay_silent_loop -> "stay_silent_loop"
  | Fiber_unresolved -> "fiber_unresolved"
  | Stale_turn_timeout -> "stale_turn_timeout"
  | Stale_fleet_batch -> "stale_fleet_batch"
  | Sdk_max_turns_exceeded -> "sdk_max_turns_exceeded"
  | Sdk_token_budget_exceeded -> "sdk_token_budget_exceeded"
  | Sdk_cost_budget_exceeded -> "sdk_cost_budget_exceeded"
  | Sdk_unrecognized_stop_reason -> "sdk_unrecognized_stop_reason"
  | Sdk_idle_detected -> "sdk_idle_detected"
  | Sdk_tool_retry_exhausted -> "sdk_tool_retry_exhausted"
  | Sdk_guardrail_violation -> "sdk_guardrail_violation"
  | Sdk_tripwire_violation -> "sdk_tripwire_violation"
  | Sdk_exit_condition_met -> "sdk_exit_condition_met"
  | Sdk_input_required -> "sdk_input_required"
;;

let blocker_class_of_serialized_string = function
  | "cascade_exhausted" -> Some (Cascade_exhausted (Other_detail "cascade_exhausted"))
  | "capacity_backpressure" -> Some Capacity_backpressure
  | "ambiguous_post_commit_timeout" -> Some Ambiguous_post_commit_timeout
  | "ambiguous_post_commit_failure" -> Some Ambiguous_post_commit_failure
  | "autonomous_slot_wait_timeout" -> Some Autonomous_slot_wait_timeout
  | "admission_queue_wait_timeout" -> Some Admission_queue_wait_timeout
  | "turn_timeout_after_queue_wait" -> Some Turn_timeout_after_queue_wait
  | "turn_timeout" -> Some Turn_timeout
  | "turn_livelock_blocked" -> Some Turn_livelock_blocked
  | "completion_contract_violation" -> Some Completion_contract_violation
  | "no_tool_capable_provider" -> Some No_tool_capable_provider
  | "stay_silent_loop" -> Some Stay_silent_loop
  | "fiber_unresolved" -> Some Fiber_unresolved
  | "stale_turn_timeout" -> Some Stale_turn_timeout
  | "stale_fleet_batch" -> Some Stale_fleet_batch
  | "sdk_max_turns_exceeded" -> Some Sdk_max_turns_exceeded
  | "sdk_token_budget_exceeded" -> Some Sdk_token_budget_exceeded
  | "sdk_cost_budget_exceeded" -> Some Sdk_cost_budget_exceeded
  | "sdk_unrecognized_stop_reason" -> Some Sdk_unrecognized_stop_reason
  | "sdk_idle_detected" -> Some Sdk_idle_detected
  | "sdk_tool_retry_exhausted" -> Some Sdk_tool_retry_exhausted
  | "sdk_guardrail_violation" -> Some Sdk_guardrail_violation
  | "sdk_tripwire_violation" -> Some Sdk_tripwire_violation
  | "sdk_exit_condition_met" -> Some Sdk_exit_condition_met
  | "sdk_input_required" -> Some Sdk_input_required
  | _ -> None
;;

let cascade_exhaustion_summary = function
  | Connection_refused ->
    "Cascade exhausted after provider failures; local runtime connection refused."
  | Dns_failure ->
    "Cascade exhausted; hostname resolution failed (DNS)."
  | No_providers_available -> "Cascade exhausted; no providers were available."
  | All_providers_failed ->
    "Cascade exhausted after all configured providers failed; inspect per-attempt root causes."
  | Candidates_filtered_after_cycles ->
    "Cascade exhausted after provider candidates were filtered; inspect candidate filter reasons."
  | Max_turns_exceeded ->
    "Cascade exhausted after a provider hit its per-call turn budget."
  | Structural_attempt_timeout _ ->
    "Cascade exhausted after the per-OAS-call ceiling (max_execution_time_s) fired."
  | Other_detail _ ->
    "Cascade exhausted; inspect cascade attempts for the dominant root cause."
;;

let blocker_class_continue_gate = function
  | Ambiguous_post_commit_timeout
  | Ambiguous_post_commit_failure -> true
  | Cascade_exhausted _
  | Capacity_backpressure
  | Autonomous_slot_wait_timeout
  | Admission_queue_wait_timeout
  | Turn_timeout_after_queue_wait
  | Turn_timeout
  | Turn_livelock_blocked
  | Completion_contract_violation
  | No_tool_capable_provider
  | Stay_silent_loop
  | Fiber_unresolved
  | Stale_turn_timeout
  | Stale_fleet_batch
  | Sdk_max_turns_exceeded
  | Sdk_token_budget_exceeded
  | Sdk_cost_budget_exceeded
  | Sdk_unrecognized_stop_reason
  | Sdk_idle_detected
  | Sdk_tool_retry_exhausted
  | Sdk_guardrail_violation
  | Sdk_tripwire_violation
  | Sdk_exit_condition_met
  | Sdk_input_required -> false
;;

let cascade_exhaustion_reason_to_json = function
  | Connection_refused -> `String "connection_refused"
  | Dns_failure -> `String "dns_failure"
  | No_providers_available -> `String "no_providers_available"
  | All_providers_failed -> `String "all_providers_failed"
  | Candidates_filtered_after_cycles -> `String "candidates_filtered_after_cycles"
  | Max_turns_exceeded -> `String "max_turns_exceeded"
  | Structural_attempt_timeout { detail } ->
    `Assoc [ "tag", `String "structural_attempt_timeout"; "detail", `String detail ]
  | Other_detail msg -> `Assoc [ "tag", `String "other_detail"; "message", `String msg ]
;;

let cascade_exhaustion_reason_of_json = function
  | `String "connection_refused" -> Some Connection_refused
  | `String "dns_failure" -> Some Dns_failure
  | `String "no_providers_available" -> Some No_providers_available
  | `String "all_providers_failed" -> Some All_providers_failed
  | `String "candidates_filtered_after_cycles" -> Some Candidates_filtered_after_cycles
  | `String "max_turns_exceeded" -> Some Max_turns_exceeded
  | `Assoc fields ->
    (match List.assoc_opt "tag" fields with
     | Some (`String "structural_attempt_timeout") ->
       (match List.assoc_opt "detail" fields with
        | Some (`String detail) -> Some (Structural_attempt_timeout { detail })
        | _ -> None)
     | Some (`String "other_detail") ->
       (match List.assoc_opt "message" fields with
        | Some (`String msg) -> Some (Other_detail msg)
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let cascade_exhaustion_reason_from_message msg =
  if String_util.contains_substring_ci msg "max_execution_time_s"
  then Structural_attempt_timeout { detail = msg }
  else Other_detail msg
;;

(* ── Unified blocker_info: typed klass + free-form detail ───────
   Replaces the historic [last_blocker: string] +
   [last_blocker_class: blocker_class option] pair.  The string-only
   field was used by [blocker_class_of_string] (substring classifier)
   to recover a typed class — exactly the workaround pattern called
   out in CLAUDE.md "워크어라운드 거부 기준 #2 String/Substring
   분류기 보강".  Making [blocker_class] the only authoritative class
   eliminates that recovery path; [detail] carries free-form context
   for UI / Prometheus labels (no classification semantics). *)
type blocker_info = {
  klass : blocker_class;
  detail : string;
}

let blocker_info_of_class ?(detail = "") klass = { klass; detail }

let blocker_info_to_json (info : blocker_info) : Yojson.Safe.t =
  let klass_payload = match info.klass with
    | Cascade_exhausted reason ->
      `Assoc [ "name", `String "cascade_exhausted"
             ; "reason", cascade_exhaustion_reason_to_json reason
             ]
    | _ -> `String (blocker_class_to_string info.klass)
  in
  `Assoc
    [ "klass", klass_payload
    ; "detail", `String info.detail
    ]
;;

let blocker_info_of_json (json : Yojson.Safe.t) : blocker_info option =
  match json with
  | `Null -> None
  | `Assoc fields ->
    let klass =
      match List.assoc_opt "klass" fields with
      | Some (`String s) -> blocker_class_of_serialized_string s
      | Some (`Assoc kfields) ->
        (match List.assoc_opt "name" kfields with
         | Some (`String "cascade_exhausted") ->
           let reason =
             match List.assoc_opt "reason" kfields with
             | Some r ->
               (match cascade_exhaustion_reason_of_json r with
                | Some r -> r
                | None -> Other_detail "cascade_exhausted")
             | None -> Other_detail "cascade_exhausted"
           in
           Some (Cascade_exhausted reason)
         | Some (`String s) -> blocker_class_of_serialized_string s
         | _ -> None)
      | _ -> None
    in
    (match klass with
     | None -> None
     | Some klass ->
       let detail = match List.assoc_opt "detail" fields with
         | Some (`String s) -> s
         | _ -> ""
       in
       Some { klass; detail })
  | _ -> None
;;

type cascade_attempt_record =
  { provider_id : string
  ; http_status : int option
  ; outcome : [ `Success | `Failure of string ]
  ; timestamp : float
  }

let cascade_attempt_outcome_to_json = function
  | `Success -> `Assoc [ "kind", `String "success" ]
  | `Failure message ->
    `Assoc [ "kind", `String "failure"; "message", `String message ]
;;

let cascade_attempt_outcome_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "success") -> Some `Success
     | Some (`String "failure") ->
       (match List.assoc_opt "message" fields with
        | Some (`String message) -> Some (`Failure message)
        (* DET-OK: legacy attempt rows encoded failure without a message;
           keep the lossy historical record instead of dropping it. *)
        | _ -> Some (`Failure ""))
     | _ -> None)
  | `String "success" -> Some `Success
  | `String "failure" -> Some (`Failure "")
  | _ -> None
;;

let cascade_attempt_record_to_json (record : cascade_attempt_record) : Yojson.Safe.t =
  `Assoc
    [ "provider_id", `String record.provider_id
    ; ( "http_status"
      , match record.http_status with
        | Some status -> `Int status
        | None -> `Null )
    ; "outcome", cascade_attempt_outcome_to_json record.outcome
    ; "timestamp", `Float record.timestamp
    ]
;;

let cascade_attempt_record_of_json (json : Yojson.Safe.t)
  : cascade_attempt_record option
  =
  match json with
  | `Null -> None
  | `Assoc fields ->
    let provider_id =
      match List.assoc_opt "provider_id" fields with
      | Some (`String value) -> Some value
      | _ -> None
    in
    let http_status =
      match List.assoc_opt "http_status" fields with
      | Some (`Int status) -> Some status
      | Some `Null | None -> None
      | _ -> None
    in
    let outcome =
      match List.assoc_opt "outcome" fields with
      | Some value -> cascade_attempt_outcome_of_json value
      | None -> None
    in
    let timestamp =
      match List.assoc_opt "timestamp" fields with
      | Some (`Float value) -> Some value
      | Some (`Int value) -> Some (float_of_int value)
      | _ -> None
    in
    (match provider_id, outcome, timestamp with
     | Some provider_id, Some outcome, Some timestamp ->
       Some { provider_id; http_status; outcome; timestamp }
     | _ -> None)
  | _ -> None
;;

type usage_metrics =
  { total_turns : int
  ; total_input_tokens : int
  ; total_output_tokens : int
  ; total_tokens : int
  ; total_cost_usd : float
  ; last_turn_ts : float
  ; last_model_used : string
  ; last_input_tokens : int
  ; last_output_tokens : int
  ; last_total_tokens : int
  ; last_latency_ms : int
  }

type agent_runtime_state =
  { usage : usage_metrics
  ; compaction_rt : compaction_runtime
  ; proactive_rt : proactive_runtime
  ; generation : int
  ; trace_id : Keeper_id.Trace_id.t
  ; trace_history : string list
  ; last_handoff_ts : float
  ; last_continuity_update_ts : float
  ; last_autonomous_action_at : string
  ; autonomous_action_count : int
  ; autonomous_turn_count : int
  ; autonomous_text_turn_count : int
  ; autonomous_tool_turn_count : int
  ; board_reactive_turn_count : int
  ; mention_reactive_turn_count : int
  ; noop_turn_count : int
  ; last_speech_act : string
  ; last_social_transition_reason : string
  ; last_active_desire : string
  ; last_current_intention : string
  ; last_blocker : blocker_info option
  ; last_cascade_attempt : cascade_attempt_record option
  ; last_need : string
  }
