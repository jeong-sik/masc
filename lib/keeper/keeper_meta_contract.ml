(** Keeper meta policy/runtime contract and pure helpers.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public API while the type-heavy contract is separated from JSON
    parsing and store I/O. *)

open Keeper_types_profile
include Keeper_meta_tool_access

(* -- Policy types (remain in keeper_meta top-level) -- *)

type compaction_policy =
  { profile : string
  ; ratio_gate : float
  ; message_gate : int
  ; token_gate : int
  ; cooldown_sec : int
  ; max_checkpoint_messages : int
  }

type proactive_policy =
  { enabled : bool
  ; idle_sec : int
  ; cooldown_sec : int
  }

type scheduled_autonomous_policy = proactive_policy

type proactive_cycle_outcome =
  | Proactive_never_started
  | Proactive_unknown
  | Proactive_silent
  | Proactive_text_response
  | Proactive_tool_use
  | Proactive_mixed_response
  | Proactive_error

type scheduled_autonomous_cycle_outcome = proactive_cycle_outcome

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

type scheduled_autonomous_runtime = proactive_runtime

(* ── Structured blocker classification ──────────────────────── *)

type cascade_exhaustion_reason =
  | Connection_refused
  | No_providers_available
  | All_providers_failed
  | Candidates_filtered_after_cycles
  | Max_turns_exceeded
  | Other_detail of string

type blocker_class =
  | Cascade_exhausted of cascade_exhaustion_reason
  | Ambiguous_post_commit_timeout
  | Ambiguous_post_commit_failure
  | Autonomous_slot_wait_timeout
  | Admission_queue_wait_timeout
  | Turn_timeout_after_queue_wait
  | Oas_timeout_budget
  | Turn_timeout
  | Completion_contract_violation
  | No_tool_capable_provider
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
        [handle_crash_auto_pause], so PR #12889's [last_blocker_class]
        stamp does not apply.  Without this variant, dashboards and
        per-keeper meta read [last_blocker_class = null] for the
        majority cohort during a fleet stall (observed: 6/14 keepers
        in cohort=stale_turn_timeout, every meta showing null). *)

let blocker_class_to_string = function
  | Cascade_exhausted _ -> "cascade_exhausted"
  | Ambiguous_post_commit_timeout -> "ambiguous_post_commit_timeout"
  | Ambiguous_post_commit_failure -> "ambiguous_post_commit_failure"
  | Autonomous_slot_wait_timeout -> "autonomous_slot_wait_timeout"
  | Admission_queue_wait_timeout -> "admission_queue_wait_timeout"
  | Turn_timeout_after_queue_wait -> "turn_timeout_after_queue_wait"
  | Oas_timeout_budget -> "oas_timeout_budget"
  | Turn_timeout -> "turn_timeout"
  | Completion_contract_violation -> "completion_contract_violation"
  | No_tool_capable_provider -> "no_tool_capable_provider"
  | Fiber_unresolved -> "fiber_unresolved"
  | Stale_turn_timeout -> "stale_turn_timeout"
;;

let blocker_class_of_serialized_string = function
  | "cascade_exhausted" -> Some (Cascade_exhausted (Other_detail "cascade_exhausted"))
  | "ambiguous_post_commit_timeout" -> Some Ambiguous_post_commit_timeout
  | "ambiguous_post_commit_failure" -> Some Ambiguous_post_commit_failure
  | "autonomous_slot_wait_timeout" -> Some Autonomous_slot_wait_timeout
  | "admission_queue_wait_timeout" -> Some Admission_queue_wait_timeout
  | "turn_timeout_after_queue_wait" -> Some Turn_timeout_after_queue_wait
  | "oas_timeout_budget" -> Some Oas_timeout_budget
  | "turn_timeout" -> Some Turn_timeout
  | "completion_contract_violation" -> Some Completion_contract_violation
  | "no_tool_capable_provider" -> Some No_tool_capable_provider
  | "fiber_unresolved" -> Some Fiber_unresolved
  | "stale_turn_timeout" -> Some Stale_turn_timeout
  | _ -> None
;;

let cascade_exhaustion_summary = function
  | Connection_refused ->
    "Cascade exhausted after provider failures; local runtime connection refused."
  | No_providers_available -> "Cascade exhausted; no providers were available."
  | All_providers_failed -> "Cascade exhausted after all configured providers failed."
  | Candidates_filtered_after_cycles -> "Cascade exhausted after provider failures."
  | Max_turns_exceeded ->
    "Cascade exhausted after a provider hit its per-call turn budget."
  | Other_detail _ -> "Cascade exhausted after provider failures."
;;

let blocker_class_continue_gate = function
  | Ambiguous_post_commit_timeout | Ambiguous_post_commit_failure -> true
  | _ -> false
;;

let cascade_exhaustion_reason_to_json = function
  | Connection_refused -> `String "connection_refused"
  | No_providers_available -> `String "no_providers_available"
  | All_providers_failed -> `String "all_providers_failed"
  | Candidates_filtered_after_cycles -> `String "candidates_filtered_after_cycles"
  | Max_turns_exceeded -> `String "max_turns_exceeded"
  | Other_detail msg -> `Assoc [ "tag", `String "other_detail"; "message", `String msg ]
;;

let cascade_exhaustion_reason_of_json = function
  | `String "connection_refused" -> Some Connection_refused
  | `String "no_providers_available" -> Some No_providers_available
  | `String "all_providers_failed" -> Some All_providers_failed
  | `String "candidates_filtered_after_cycles" -> Some Candidates_filtered_after_cycles
  | `String "max_turns_exceeded" -> Some Max_turns_exceeded
  | `Assoc fields ->
    (match List.assoc_opt "tag" fields with
     | Some (`String "other_detail") ->
       (match List.assoc_opt "message" fields with
        | Some (`String msg) -> Some (Other_detail msg)
        | _ -> None)
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
  ; consecutive_noop_count : int
  ; last_speech_act : string
  ; last_social_transition_reason : string
  ; last_active_desire : string
  ; last_current_intention : string
  ; last_blocker : string
  ; last_blocker_class : blocker_class option
  ; last_need : string
  }

type keeper_meta =
  { (* -- Identity & profile -- *)
    id : Ids.Keeper_id.t option [@default None]
  ; name : string
  ; agent_name : string
  ; goal : string
  ; short_goal : string
  ; mid_goal : string
  ; long_goal : string
  ; social_model : string
  ; cascade_name : string
  ; models : string list
  ; will : string
  ; needs : string
  ; desires : string
  ; instructions : string
  ; (* -- Policy -- *)
    policy_voice_enabled : bool
  ; sandbox_profile : sandbox_profile
  ; sandbox_image : string option
  ; network_mode : network_mode
  ; allowed_paths : string list
  ; tool_access : tool_access
  ; tool_preset_source : string option
  ; tool_denylist : string list
  ; mention_targets : string list
  ; room_signal_prompt_enabled : bool
  ; joined_room_ids : string list
  ; last_seen_seq_by_room : (string * int) list
  ; proactive : proactive_policy
  ; compaction : compaction_policy
  ; auto_handoff : bool
  ; handoff_threshold : float
  ; handoff_cooldown_sec : int
  ; (* -- Voice -- *)
    voice_enabled : bool
  ; voice_channel : string
  ; voice_agent_id : string
  ; (* -- Lifecycle -- *)
    created_at : string
  ; updated_at : string
  ; (* -- Performance & Limits -- *)
    max_context_override : int option
  ; (* -- Operational control (top-level, not runtime) -- *)
    continuity_summary : string
  ; active_goal_ids : string list
  ; paused : bool
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
  ; work_discovery_enabled : bool option
  ; work_discovery_sources : string list option
  ; work_discovery_interval_sec : int option
  ; work_discovery_guidance : string option
  ; telemetry_feedback_enabled : bool option
  ; telemetry_feedback_window_hours : int option
  ; per_provider_timeout_s : float option
  ; always_approve : bool option
  ; (* -- Agent runtime state (usage, tracing, autonomy metrics) -- *)
    runtime : agent_runtime_state
  ; (* -- Identity & concurrency -- *)
    keeper_id : Keeper_id.Uid.t option
  ; oas_env : (string * string) list
  ; meta_version : int
  }

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

let scheduled_autonomous_cycle_outcome_to_string = proactive_cycle_outcome_to_string
let scheduled_autonomous_cycle_outcome_of_string = proactive_cycle_outcome_of_string

(* -- Updater helpers for nested record updates -- *)

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
  ; last_model_used = ""
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

let map_scheduled_autonomous_rt = map_proactive_rt
let now_iso () = Masc_domain.now_iso ()
let keeper_legacy_model_arg_names = [ "models"; "allowed_models"; "active_model" ]
