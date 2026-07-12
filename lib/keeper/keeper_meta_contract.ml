(** Keeper meta policy/runtime contract and pure helpers.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public API while the type-heavy contract is separated from JSON
    parsing and store I/O. *)

open Keeper_types_profile

let now_iso () = Masc_domain.now_iso ()

let normalize_tool_names names =
  names
  |> List.map String.trim
  |> List.filter (fun name -> name <> "")
  |> dedupe_keep_order
;;

let string_list_field_result ?label ~field_name (json : Yojson.Safe.t) =
  let label = Option.value ~default:field_name label in
  match Json_util.assoc_member_opt field_name json with
  | Some (`List items) ->
    let rec collect acc index = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> collect (value :: acc) (index + 1) rest
      | bad :: _ ->
        Error
          (Printf.sprintf "keeper %s[%d] must be a string (received %s)" label
             index (Json_util.kind_name bad))
    in
    collect [] 0 items
  | Some `Null | None -> Error (Printf.sprintf "keeper %s must be an array of strings" label)
  | Some other ->
    Error
      (Printf.sprintf "keeper %s must be an array of strings (received %s)"
         label (Json_util.kind_name other))
;;

let tool_access_of_meta_json (json : Yojson.Safe.t) =
  match Json_util.assoc_member_opt "tool_access" json with
  | Some `Null | None -> Error "keeper tool_access must be an array of strings"
  | Some (`List _ as list_json) ->
    (match
       string_list_field_result ~field_name:"tool_access"
         (`Assoc [ "tool_access", list_json ])
     with
     | Ok tools -> Ok (normalize_tool_names tools)
     | Error msg -> Error msg)
  | Some other ->
    Error
      (Printf.sprintf "keeper tool_access must be an array of strings (received %s)"
         (Json_util.kind_name other))
;;

(* -- Policy types (remain in keeper_meta top-level) -- *)

type compaction_policy =
  { profile : string
  ; mode : Keeper_config.compaction_mode
    (* HOW the checkpoint is summarized: [Deterministic] extractive chain
       (fail-closed default) or opt-in [Llm] librarian-lane summarizer (W2).
       Orthogonal to [profile], which decides WHEN to compact. *)
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
  ; consecutive_noop_count : int
    (** Consecutive autonomous cycles where only observation tools
          (board_list, context_status, other passive reads) were used with no
          substantive action.  Resets to 0 on any productive cycle.
          Used by [effective_scheduled_autonomous_cooldown] for exponential
          backoff: cooldown *= 2^min(n, 2), capping at 4x. *)
  }

(* ── Structured blocker classification ──────────────────────── *)

type runtime_exhaustion_reason = Keeper_internal_error.runtime_exhaustion_reason =
  | Connection_refused
  | Dns_failure
  | No_providers_available
  | All_providers_failed
  | Candidates_filtered_after_cycles
  | Max_turns_exceeded
  | Structural_attempt_timeout of { detail : string }
  | Capacity_exhausted
  | Other_detail of string

(** Total typed retryability for a runtime-exhaustion reason.

    Replaces a former string-prefix reparse in
    [keeper_supervisor_pause_policy] that matched on the wire form of
    [runtime_exhaustion_reason_code] and biased every unlisted reason to
    non-retryable via a [_ -> false] catch-all.  That polarity was wrong
    for transient/connectivity faults (Connection_refused, Dns_failure,
    No_providers_available, All_providers_failed,
    Structural_attempt_timeout), which the supervisor should retry.

    Exhaustive match: adding a new [runtime_exhaustion_reason] variant
    fails compilation here, forcing an explicit retryability decision
    rather than silently defaulting. *)
let runtime_exhaustion_reason_retryable (reason : runtime_exhaustion_reason) : bool =
  Keeper_internal_error.runtime_exhaustion_reason_retryable reason
;;

type blocker_class =
  | Runtime_exhausted of runtime_exhaustion_reason
  | Capacity_backpressure
  | Ambiguous_post_commit_timeout
  | Ambiguous_post_commit_failure
  | Admission_queue_wait_timeout
  | Turn_timeout_after_queue_wait
  | Turn_timeout
  | Turn_livelock_blocked
  | Completion_contract_violation
  | No_progress_loop
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
    (** Retired blocker class for pre-existing fleet-batch state. Current
        fleet-batch detection is observation-only and should not stamp keeper
        meta; stale keepers use their per-keeper watchdog blocker instead. *)
  | Oas_agent_execution_timeout
  | Sdk_max_turns_exceeded
  | Sdk_token_budget_exceeded
  | Sdk_cost_budget_exceeded
  | Sdk_unrecognized_stop_reason
  | Sdk_idle_detected
  | Sdk_guardrail_violation
  | Sdk_tripwire_violation
  | Sdk_exit_condition_met
  | Sdk_input_required
  | Sdk_tool_failure_recovery_failed

let blocker_class_to_string = function
  | Runtime_exhausted _ -> "runtime_exhausted"
  | Capacity_backpressure -> "capacity_backpressure"
  | Ambiguous_post_commit_timeout -> "ambiguous_post_commit_timeout"
  | Ambiguous_post_commit_failure -> "ambiguous_post_commit_failure"
  | Admission_queue_wait_timeout -> "admission_queue_wait_timeout"
  | Turn_timeout_after_queue_wait -> "turn_timeout_after_queue_wait"
  | Turn_timeout -> "turn_timeout"
  | Turn_livelock_blocked -> "turn_livelock_blocked"
  | Completion_contract_violation -> "completion_contract_violation"
  | No_progress_loop -> "no_progress_loop"
  | Fiber_unresolved -> "fiber_unresolved"
  | Stale_turn_timeout -> "stale_turn_timeout"
  | Stale_fleet_batch -> "stale_fleet_batch"
  | Oas_agent_execution_timeout -> "oas_agent_execution_timeout"
  | Sdk_max_turns_exceeded -> "sdk_max_turns_exceeded"
  | Sdk_token_budget_exceeded -> "sdk_token_budget_exceeded"
  | Sdk_cost_budget_exceeded -> "sdk_cost_budget_exceeded"
  | Sdk_unrecognized_stop_reason -> "sdk_unrecognized_stop_reason"
  | Sdk_idle_detected -> "sdk_idle_detected"
  | Sdk_guardrail_violation -> "sdk_guardrail_violation"
  | Sdk_tripwire_violation -> "sdk_tripwire_violation"
  | Sdk_exit_condition_met -> "sdk_exit_condition_met"
  | Sdk_input_required -> "sdk_input_required"
  | Sdk_tool_failure_recovery_failed -> "sdk_tool_failure_recovery_failed"
;;

let blocker_class_of_serialized_string = function
  | "runtime_exhausted" -> Some (Runtime_exhausted (Other_detail "runtime_exhausted"))
  | "capacity_backpressure" -> Some Capacity_backpressure
  | "ambiguous_post_commit_timeout" -> Some Ambiguous_post_commit_timeout
  | "ambiguous_post_commit_failure" -> Some Ambiguous_post_commit_failure
  | "admission_queue_wait_timeout" -> Some Admission_queue_wait_timeout
  | "turn_timeout_after_queue_wait" -> Some Turn_timeout_after_queue_wait
  | "turn_timeout" -> Some Turn_timeout
  | "turn_livelock_blocked" -> Some Turn_livelock_blocked
  | "completion_contract_violation" -> Some Completion_contract_violation
  | "no_progress_loop" -> Some No_progress_loop
  | "fiber_unresolved" -> Some Fiber_unresolved
  | "stale_turn_timeout" -> Some Stale_turn_timeout
  | "stale_fleet_batch" -> Some Stale_fleet_batch
  | "oas_agent_execution_timeout" -> Some Oas_agent_execution_timeout
  | "sdk_max_turns_exceeded" -> Some Sdk_max_turns_exceeded
  | "sdk_token_budget_exceeded" -> Some Sdk_token_budget_exceeded
  | "sdk_cost_budget_exceeded" -> Some Sdk_cost_budget_exceeded
  | "sdk_unrecognized_stop_reason" -> Some Sdk_unrecognized_stop_reason
  | "sdk_idle_detected" -> Some Sdk_idle_detected
  | "sdk_guardrail_violation" -> Some Sdk_guardrail_violation
  | "sdk_tripwire_violation" -> Some Sdk_tripwire_violation
  | "sdk_exit_condition_met" -> Some Sdk_exit_condition_met
  | "sdk_input_required" -> Some Sdk_input_required
  | "sdk_tool_failure_recovery_failed" -> Some Sdk_tool_failure_recovery_failed
  | _ -> None
;;

let runtime_exhaustion_summary = function
  | Connection_refused ->
    "Runtime exhausted after provider failures; local runtime connection refused."
  | Dns_failure ->
    "Runtime exhausted; hostname resolution failed (DNS)."
  | No_providers_available -> "Runtime exhausted; no providers were available."
  | All_providers_failed ->
    "Runtime exhausted after all configured providers failed; inspect per-attempt root causes."
  | Candidates_filtered_after_cycles ->
    "Runtime exhausted after provider candidates were filtered; inspect candidate filter reasons."
  | Max_turns_exceeded ->
    "Runtime exhausted after a provider hit its per-call turn budget."
  | Structural_attempt_timeout _ ->
    "Runtime exhausted after the per-OAS-call ceiling (max_execution_time_s) fired."
  | Capacity_exhausted ->
    "Runtime exhausted; all providers reported capacity backpressure."
  | Other_detail _ ->
    "Runtime exhausted; inspect runtime attempts for the dominant root cause."
;;

let blocker_class_continue_gate = function
  | Ambiguous_post_commit_timeout
  | Ambiguous_post_commit_failure -> true
  | Runtime_exhausted _
  | Capacity_backpressure
  | Admission_queue_wait_timeout
  | Turn_timeout_after_queue_wait
  | Turn_timeout
  | Turn_livelock_blocked
  | Completion_contract_violation
  | No_progress_loop
  | Fiber_unresolved
  | Stale_turn_timeout
  | Stale_fleet_batch
  | Oas_agent_execution_timeout
  | Sdk_max_turns_exceeded
  | Sdk_token_budget_exceeded
  | Sdk_cost_budget_exceeded
  | Sdk_unrecognized_stop_reason
  | Sdk_idle_detected
  | Sdk_guardrail_violation
  | Sdk_tripwire_violation
  | Sdk_exit_condition_met
  | Sdk_input_required
  | Sdk_tool_failure_recovery_failed -> false
;;

(** [blocker_class_auto_approval_blocked b] is [true] iff the presence of
    this blocker should prevent auto-approval (including [always_approve]
    and remembered allow-rules) for the keeper's next tool call.

    Only blockers that signal genuine safety/uncertainty conditions are
    hard-forbidden.  Transient liveness signals — capacity backpressure,
    queue timeouts, turn timeouts, SDK budget/idle/input conditions — do
    NOT block auto-approval, so automated recovery flows are not stalled
    by a momentary runtime hiccup.

    This classifier is exhaustive so adding a new [blocker_class] variant
    forces an explicit auto-approval policy decision. *)
let blocker_class_auto_approval_blocked = function
  | Ambiguous_post_commit_timeout
  | Ambiguous_post_commit_failure
  | Completion_contract_violation
  | Runtime_exhausted _
  | Fiber_unresolved
  | Stale_turn_timeout
  | Stale_fleet_batch
  | Turn_livelock_blocked
  | No_progress_loop
  | Oas_agent_execution_timeout
  | Sdk_guardrail_violation
  | Sdk_tripwire_violation
  | Sdk_exit_condition_met
  | Sdk_tool_failure_recovery_failed -> true
  | Capacity_backpressure
  | Admission_queue_wait_timeout
  | Turn_timeout_after_queue_wait
  | Turn_timeout
  | Sdk_max_turns_exceeded
  | Sdk_token_budget_exceeded
  | Sdk_cost_budget_exceeded
  | Sdk_unrecognized_stop_reason
  | Sdk_idle_detected
  | Sdk_input_required -> false
;;

let runtime_exhaustion_reason_to_json reason =
  Keeper_internal_error.runtime_exhaustion_reason_to_json reason

let runtime_exhaustion_reason_of_json json =
  Keeper_internal_error.runtime_exhaustion_reason_of_json json

(* ── Unified blocker_info: typed klass + free-form detail ───────
   Replaces the historic split blocker fields. The string-only field was used
   by substring classifiers to recover a typed class — exactly the workaround
   pattern called out in CLAUDE.md
   "워크어라운드 거부 기준 #2 String/Substring 분류기 보강". Making
   [blocker_class] the only authoritative class eliminates that recovery path;
   [detail] carries free-form context for UI / Otel_metric_store labels (no
   classification semantics). *)
type no_progress_blocker_facts =
  { no_progress_reason : string
  ; no_progress_streak : int
  ; no_progress_threshold : int
  ; no_progress_latched : bool
  }

type blocker_facts =
  | No_progress_loop_facts of no_progress_blocker_facts

type blocker_info = {
  klass : blocker_class;
  detail : string;
  facts : blocker_facts option;
}

let blocker_info_of_class ?(detail = "") ?facts klass = { klass; detail; facts }

let blocker_info_of_no_progress_loop
      ?(detail = "")
      ~reason
      ~streak
      ~threshold
      ~latched
      ()
  =
  blocker_info_of_class
    ~detail
    ~facts:
      (No_progress_loop_facts
         { no_progress_reason = reason
         ; no_progress_streak = streak
         ; no_progress_threshold = threshold
         ; no_progress_latched = latched
         })
    No_progress_loop
;;

let no_progress_blocker_facts_to_json facts : Yojson.Safe.t =
  `Assoc
    [ "kind", `String "no_progress_loop"
    ; "reason", `String facts.no_progress_reason
    ; "streak", `Int facts.no_progress_streak
    ; "threshold", `Int facts.no_progress_threshold
    ; "latched", `Bool facts.no_progress_latched
    ]
;;

let blocker_facts_to_json = function
  | No_progress_loop_facts facts -> no_progress_blocker_facts_to_json facts
;;

let no_progress_blocker_facts_of_fields fields =
  match
    ( List.assoc_opt "reason" fields
    , List.assoc_opt "streak" fields
    , List.assoc_opt "threshold" fields
    , List.assoc_opt "latched" fields )
  with
  | Some (`String reason), Some (`Int streak), Some (`Int threshold), Some (`Bool latched)
    when String.trim reason <> "" ->
    Some
      { no_progress_reason = reason
      ; no_progress_streak = streak
      ; no_progress_threshold = threshold
      ; no_progress_latched = latched
      }
  | _ -> None
;;

let blocker_facts_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "no_progress_loop") ->
       Option.map
         (fun facts -> No_progress_loop_facts facts)
         (no_progress_blocker_facts_of_fields fields)
     | _ -> None)
  | _ -> None
;;

let blocker_info_to_json (info : blocker_info) : Yojson.Safe.t =
  let klass_payload = match info.klass with
    | Runtime_exhausted reason ->
      `Assoc [ "name", `String "runtime_exhausted"
             ; "reason", runtime_exhaustion_reason_to_json reason
             ]
    | _ -> `String (blocker_class_to_string info.klass)
  in
  let fields =
    [ "klass", klass_payload
    ; "detail", `String info.detail
    ]
  in
  let fields =
    match info.facts with
    | Some facts -> fields @ [ "facts", blocker_facts_to_json facts ]
    | None -> fields
  in
  `Assoc fields
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
         | Some (`String "runtime_exhausted") ->
           let reason =
             match List.assoc_opt "reason" kfields with
             | Some r ->
               (match runtime_exhaustion_reason_of_json r with
                | Some r -> r
                | None -> Other_detail "runtime_exhausted")
             | None -> Other_detail "runtime_exhausted"
           in
           Some (Runtime_exhausted reason)
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
       let facts =
         match List.assoc_opt "facts" fields with
         | Some raw -> blocker_facts_of_json raw
         | None -> None
       in
       Some { klass; detail; facts })
  | _ -> None
;;

type runtime_attempt_record =
  { provider_id : string
  ; http_status : int option
  ; outcome : [ `Success | `Failure of string ]
  ; timestamp : float
  }

let runtime_attempt_outcome_to_json = function
  | `Success -> `Assoc [ "kind", `String "success" ]
  | `Failure message ->
    `Assoc [ "kind", `String "failure"; "message", `String message ]
;;

let runtime_attempt_outcome_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "success") -> Some `Success
     | Some (`String "failure") ->
       (match List.assoc_opt "message" fields with
        | Some (`String message) -> Some (`Failure message)
        (* DET-OK: retired attempt rows encoded failure without a message;
           keep the lossy historical record instead of dropping it. *)
        | _ -> Some (`Failure ""))
     | _ -> None)
  | `String "success" -> Some `Success
  | `String "failure" -> Some (`Failure "")
  | _ -> None
;;

let runtime_attempt_record_to_json (record : runtime_attempt_record) : Yojson.Safe.t =
  `Assoc
    [ "provider_id", `String record.provider_id
    ; ( "http_status"
      , match record.http_status with
        | Some status -> `Int status
        | None -> `Null )
    ; "outcome", runtime_attempt_outcome_to_json record.outcome
    ; "timestamp", `Float record.timestamp
    ]
;;

let runtime_attempt_record_of_json (json : Yojson.Safe.t)
  : runtime_attempt_record option
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
      | Some value -> runtime_attempt_outcome_of_json value
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
  ; last_input_tokens : int
  ; last_output_tokens : int
  ; last_total_tokens : int
  ; last_latency_ms : int
  }

type tool_call_summary =
  { tool_name : string
  ; outcome : string
  }

type agent_runtime_state =
  { usage : usage_metrics
  ; compaction_rt : compaction_runtime
  ; proactive_rt : proactive_runtime
  ; generation : int
  ; trace_id : Keeper_id.Trace_id.t
  ; trace_history : string list
  ; last_handoff_ts : float
  ; last_autonomous_action_at : string
  ; autonomous_action_count : int
  ; autonomous_turn_count : int
  ; autonomous_text_turn_count : int
  ; autonomous_tool_turn_count : int
  ; board_reactive_turn_count : int
  ; mention_reactive_turn_count : int
  ; noop_turn_count : int
  ; last_blocker : blocker_info option
  ; last_runtime_attempt : runtime_attempt_record option
  ; last_turn_tool_calls : tool_call_summary list
  ; last_seen_message_seq : int
    (** Highest message seq this keeper has scanned for direct
        mentions. Persisted across heartbeats so mentions are not re-surfaced. *)
  }

type keeper_meta =
  { (* -- Identity & profile -- *)
    id : Ids.Keeper_id.t option [@default None]
  ; name : string
  ; agent_name : string
  ; persona : string option
  ; goal : string
  ; instructions : string
  ; (* -- Policy -- *)
    sandbox_profile : Keeper_types_profile.sandbox_profile
  ; sandbox_image : string option
  ; network_mode : Keeper_types_profile.network_mode
  ; allowed_paths : string list
  ; tool_access : string list
  ; tool_denylist : string list
  ; mention_targets : string list
  ; proactive : proactive_policy
  ; compaction : compaction_policy
  ; multimodal_policy : Keeper_types_profile.multimodal_policy
  ; auto_handoff : bool
  ; handoff_threshold : float
  ; handoff_cooldown_sec : int
  ; (* -- Lifecycle -- *)
    created_at : string
  ; updated_at : string
  ; (* -- Performance & Limits -- *)
    max_context_override : int option
  ; (* -- Operational control (top-level, not runtime) -- *)
    active_goal_ids : string list
  ; paused : bool
  ; latched_reason : Keeper_latched_reason.t option
    (** Typed companion to [paused]: {i why} this keeper is latched.
        Producers set it alongside [paused = true] (bool-only pause sites
        record their [Keeper_latched_reason.t]); consumers surface it via
        the status bridge. [paused] remains the pause authority, while
        [Dead_tombstone] refines it into a terminal lifecycle state. [None]
        while paused is a fail-closed unclassified pause. *)
  ; auto_resume_after_sec : float option
    (** Self-healing circuit breaker: when [Some sec] the supervisor will
        auto-resume this keeper after [sec] seconds following the last
        [updated_at] timestamp recorded at auto-pause time.  Doubles on
        each successive auto-pause (exponential back-off), capped at
        [Env_config.KeeperSupervisor.auto_resume_max_sec].  Reset to
        [None] after a successful turn so a healthy run re-arms the
        initial delay.  [None] = operator-owned pause, no auto-resume. *)
  ; autoboot_enabled : bool
  ; current_task_id : Keeper_id.Task_id.t option
    (** Currently claimed task ID for cost attribution.
      Set when keeper claims a task; cleared on masc_transition action=done.
      Propagated to trajectory accumulator for per-task cost tracking. *)
  ; telemetry_feedback_enabled : bool option
  ; telemetry_feedback_window_hours : int option
  ; always_approve : bool option
  ; (* -- Agent runtime state (usage, tracing, autonomy metrics) -- *)
    runtime : agent_runtime_state
  ; (* -- Identity & concurrency -- *)
    keeper_id : Keeper_id.Uid.t option
  ; oas_env : (string * string) list
  ; meta_version : int
  }

let apply_profile_default opt current =
  match opt with
  | Some value -> value
  | None -> current
;;

let apply_profile_default_opt opt current =
  match opt with
  | Some _ -> opt
  | None -> current
;;

let missing_required_sandbox_profile_error ~keeper_name
    (defaults : Keeper_types_profile.keeper_profile_defaults) =
  let manifest_hint =
    match defaults.manifest_path with
    | Some path -> Printf.sprintf " (loaded from %s)" path
    | None -> ""
  in
  Printf.sprintf
    "keeper %s rejected: sandbox_profile is required (allowed: %s)%s. \
     Add e.g. `sandbox_profile = \"docker\"` to the keeper TOML."
    keeper_name
    (String.concat ", " Keeper_types_profile.valid_sandbox_profile_strings)
    manifest_hint
;;

let effective_meta_of_profile_defaults
    (defaults : Keeper_types_profile.keeper_profile_defaults)
    (meta : keeper_meta) : (keeper_meta, string) result =
  let open Keeper_types_profile in
  let has_profile_source = Option.is_some defaults.manifest_path in
  let target_sandbox_profile =
    match defaults.sandbox_profile, defaults.manifest_path with
    | Some profile, _ -> Ok profile
    | None, _ -> Error (missing_required_sandbox_profile_error ~keeper_name:meta.name defaults)
  in
  match target_sandbox_profile with
  | Error _ as err -> err
  | Ok sandbox_profile ->
      let default_network_mode =
        if has_profile_source then default_network_mode_for_profile sandbox_profile
        else meta.network_mode
      in
      let network_mode =
        apply_profile_default defaults.network_mode default_network_mode
      in
      let tool_access =
        match defaults.tool_access with
        | Some tools -> normalize_tool_names tools
        | None -> meta.tool_access
      in
      Ok
        { meta with
          persona = apply_profile_default_opt defaults.persona_name meta.persona;
          proactive =
            {
              enabled =
                apply_profile_default defaults.proactive_enabled
                  Keeper_config.default_proactive_enabled;
              idle_sec =
                apply_profile_default defaults.proactive_idle_sec
                  Keeper_config.default_proactive_idle_sec;
              cooldown_sec =
                apply_profile_default defaults.proactive_cooldown_sec
                  Keeper_config.default_proactive_cooldown_sec;
            };
          tool_denylist =
            apply_profile_default defaults.tool_denylist meta.tool_denylist;
          goal = apply_profile_default defaults.goal meta.goal;
          instructions =
            apply_profile_default defaults.instructions meta.instructions;
          autoboot_enabled =
            apply_profile_default defaults.autoboot_enabled
              meta.autoboot_enabled;
          mention_targets =
            (match defaults.mention_targets with
             | [] -> meta.mention_targets
             | targets -> targets);
          active_goal_ids =
            apply_profile_default defaults.active_goal_ids meta.active_goal_ids;
          tool_access;
          sandbox_profile;
          sandbox_image =
            apply_profile_default_opt defaults.sandbox_image meta.sandbox_image;
          network_mode;
          (* RFC vision-delegation §2.4: TOML profile overrides the carried
             value; absent -> keep [meta]'s (defaults to Inherit). *)
          multimodal_policy =
            apply_profile_default defaults.multimodal_policy meta.multimodal_policy;
          allowed_paths =
            apply_profile_default defaults.allowed_paths
              (if has_profile_source then [] else meta.allowed_paths);
          telemetry_feedback_enabled =
            apply_profile_default_opt defaults.telemetry_feedback_enabled
              meta.telemetry_feedback_enabled;
          telemetry_feedback_window_hours =
            apply_profile_default_opt defaults.telemetry_feedback_window_hours
              meta.telemetry_feedback_window_hours;
          always_approve =
            apply_profile_default_opt defaults.always_approve
              meta.always_approve;
          oas_env =
            (match defaults.oas_env with
             | [] -> meta.oas_env
             | env -> env);
        }
;;

let effective_meta_result ~base_path (meta : keeper_meta) : (keeper_meta, string) result =
  match
    Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
      ~base_path
      meta.name
  with
  | Error error ->
      Error
        (Printf.sprintf
           "invalid keeper profile for keeper %s: %s"
           meta.name
           (Keeper_types_profile.keeper_toml_load_error_to_string error))
  | Ok defaults -> effective_meta_of_profile_defaults defaults meta
;;

(* persona⊥{model,runtime}: a keeper's runtime is assigned in runtime.toml
   ([[runtime.assignments]], the sole SSOT), keyed by keeper name — NOT read
   from the persona profile [model] field. An unassigned keeper falls to the
   default runtime (the designed fallback; RFC-0206 §2.1 fail-fast still applies
   to the default itself). The id is opaque here; only the OAS adapter parses
   it. *)
let runtime_id_of_meta (meta : keeper_meta) =
  match Runtime.runtime_id_for_keeper meta.name with
  | Some runtime_id when String.trim runtime_id <> "" -> String.trim runtime_id
  | Some _ | None -> Runtime.get_default_runtime_id ()
;;

let proactive_cycle_outcome_to_string = function
  | Proactive_never_started -> "never_started"
  | Proactive_unknown -> "unknown"
  | Proactive_silent -> "silent"
  | Proactive_text_response -> "text_response"
  | Proactive_tool_use -> "tool_use"
  | Proactive_mixed_response -> "mixed_response"
  | Proactive_error -> "error"
;;

let proactive_cycle_outcome_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "never_started" -> Proactive_never_started
  | "unknown" -> Proactive_unknown
  | "silent" -> Proactive_silent
  | "text_response" -> Proactive_text_response
  | "tool_use" -> Proactive_tool_use
  | "mixed_response" -> Proactive_mixed_response
  | "error" -> Proactive_error
  | _ -> Proactive_unknown
;;

(* Round-trip guard: [proactive_cycle_outcome_to_string] already fails to
   compile when a new variant is added (its match has no wildcard).  This
   assertion enforces the other direction — if a new variant's label is
   not wired through [proactive_cycle_outcome_of_string], the round-trip
   silently collapses the new case to [Proactive_unknown] and leaks it at
   runtime.  The exhaustive pattern inside [assert_roundtrip] makes
   adding a variant a compile error until the parser is extended too. *)
let () =
  let assert_roundtrip v =
    (match v with
     | Proactive_never_started
     | Proactive_unknown
     | Proactive_silent
     | Proactive_text_response
     | Proactive_tool_use
     | Proactive_mixed_response
     | Proactive_error -> ());
    let s = proactive_cycle_outcome_to_string v in
    if proactive_cycle_outcome_of_string s <> v
    then
      invalid_arg
        (Printf.sprintf "keeper_types: proactive round-trip broken for label %S" s)
  in
  List.iter
    assert_roundtrip
    [ Proactive_never_started
    ; Proactive_unknown
    ; Proactive_silent
    ; Proactive_text_response
    ; Proactive_tool_use
    ; Proactive_mixed_response
    ; Proactive_error
    ]
;;

(* -- Updater helpers -- *)

let now_iso () = Masc_domain.now_iso ()

let map_runtime (f : agent_runtime_state -> agent_runtime_state) (m : keeper_meta)
  : keeper_meta
  =
  { m with runtime = f m.runtime }
;;

let map_usage (f : usage_metrics -> usage_metrics) (m : keeper_meta) : keeper_meta =
  { m with runtime = { m.runtime with usage = f m.runtime.usage } }
;;

let zero_usage : usage_metrics =
  { total_turns = 0
  ; total_input_tokens = 0
  ; total_output_tokens = 0
  ; total_tokens = 0
  ; total_cost_usd = 0.0
  ; last_turn_ts = 0.0
  ; last_input_tokens = 0
  ; last_output_tokens = 0
  ; last_total_tokens = 0
  ; last_latency_ms = 0
  }
;;

let reset_runtime_state (m : keeper_meta) : keeper_meta =
  map_usage (fun _ -> zero_usage) m
;;

let map_compaction_rt (f : compaction_runtime -> compaction_runtime) (m : keeper_meta)
  : keeper_meta
  =
  { m with runtime = { m.runtime with compaction_rt = f m.runtime.compaction_rt } }
;;

let map_proactive_rt (f : proactive_runtime -> proactive_runtime) (m : keeper_meta)
  : keeper_meta
  =
  { m with runtime = { m.runtime with proactive_rt = f m.runtime.proactive_rt } }
;;

let removed_keeper_model_arg_names = [ "models"; "allowed_models"; "active_model" ]

let reject_removed_model_args ~tool_name (args : Yojson.Safe.t) =
  let present =
    removed_keeper_model_arg_names
    |> List.filter (fun key ->
      (* A legacy arg counts as "present" only when supplied with a real value.
         [assoc_member_opt] returns [None] for an absent key; the prior
         [| _ -> true] arm classified that [None] as present, so a request
         that simply omitted all three keys (e.g. the [{name}] used by base
         autoboot materialization) was rejected as if it had passed them.
         Absent ([None]) and explicit-null are both "not supplied". *)
      match Json_util.assoc_member_opt key args with
      | None | Some `Null -> false
      | Some _ -> true)
  in
  match present with
  | [] -> Ok ()
  | fields ->
    Error
      (Printf.sprintf
         "removed keeper model args for %s: %s. Use runtime_id; concrete \
          provider/model identity is resolved from the default runtime."
         tool_name
         (String.concat ", " fields))
;;
