(** Keeper_meta_contract — Keeper meta policy + runtime contract
    types and pure helpers.

    Included by {!Keeper_types} so existing [Keeper_types.*]
    callers keep their public API.  This module separates the
    type-heavy contract from JSON parsing
    ({!Keeper_meta_json}) and store I/O.

    Internal: ~3 helpers stay private —
    \[blocker_class_of_serialized_string] (deserializer used
    only by JSON parsing), \[map_compaction_rt] /
    \[map_proactive_rt]
    (nested-record updaters that callers reach via the higher-level
    {!map_runtime} / {!map_usage}).  All consumed only via the runtime
    contract or the JSON pipeline. *)

(** {1 Tool-access persisted-meta helpers} *)

(** Trim, drop blanks, dedupe (preserve first-seen order). *)
val normalize_tool_names : string list -> string list

(** Parse [tool_access] from persisted meta JSON. Canonical form is a JSON
    array of tool names. *)
val tool_access_of_meta_json :
  Yojson.Safe.t -> (string list, string) result

(** {1 Policy types} *)

type compaction_policy = {
  profile : string;
  ratio_gate : float;
  message_gate : int;
  token_gate : int;
  cooldown_sec : int;
  max_checkpoint_messages : int;
  keep_recent_tool_results : int;
    (** Verbatim tool-result tail length passed to
        [Agent_sdk.Context_reducer.stub_tool_results ~keep_recent].
        Default
        {!Keeper_config.default_keep_recent_tool_results} (2);
        loader clamps to
        [[0, Keeper_config.keep_recent_tool_results_max]]. *)
}

type proactive_policy = {
  enabled : bool;
  idle_sec : int;
  cooldown_sec : int;
}

type proactive_cycle_outcome =
  | Proactive_never_started
  | Proactive_unknown
  | Proactive_silent
  | Proactive_text_response
  | Proactive_tool_use
  | Proactive_mixed_response
  | Proactive_error
(** Outcome variants for a single proactive (autonomous) cycle.
    Round-trip enforced at module load time
    ([proactive_cycle_outcome_to_string] +
    [proactive_cycle_outcome_of_string] must form a bijection)
    via an [assert_roundtrip] block — adding a variant fails
    compile until both directions are wired. *)

(** {1 Runtime state types} *)

type compaction_runtime_decision = Compaction_runtime_decision of string
(** Last compaction gate result as persisted in keeper meta.  JSON and
    dashboard boundaries still use the historical string value via
    {!compaction_runtime_decision_to_string}. *)

val compaction_runtime_decision_to_string :
  compaction_runtime_decision -> string

val compaction_runtime_decision_of_string :
  string -> compaction_runtime_decision

type compaction_runtime = {
  count : int;
  last_ts : float;
  last_before_tokens : int;
  last_after_tokens : int;
  last_check_ts : float;
  last_decision : compaction_runtime_decision;
}

type proactive_runtime = {
  count_total : int;
  last_ts : float;
  visible_count_total : int;
  last_visible_ts : float;
  last_outcome : proactive_cycle_outcome;
  last_reason : string;
  last_preview : string;
  consecutive_noop_count : int;
      (** Consecutive autonomous cycles where only observation
          tools were used with no substantive action.  Used by
          [effective_scheduled_autonomous_cooldown] for
          exponential backoff: cooldown *= 2^min(n, 2),
          capping at 4x.  Resets on any productive cycle. *)
}

type usage_metrics = {
  total_turns : int;
  total_input_tokens : int;
  total_output_tokens : int;
  total_tokens : int;
  total_cost_usd : float;
  last_turn_ts : float;
  last_input_tokens : int;
  last_output_tokens : int;
  last_total_tokens : int;
  last_latency_ms : int;
}

(** {1 Blocker classification} *)

type runtime_exhaustion_reason = Keeper_internal_error.runtime_exhaustion_reason =
  | Connection_refused
  | Dns_failure
      (** RFC-0142 PR-2: typed surface for hostname-resolution failure.
          Closes the dominant Other_detail share (50% live on 5/21,
          "failed to resolve hostname: ...") by mapping the existing
          [Llm_provider.Http_client.network_error_kind.Dns_failure] kind
          directly to a typed runtime reason instead of routing through
          the substring SSOT. *)
  | No_providers_available
  | All_providers_failed
  | Candidates_filtered_after_cycles
  | Max_turns_exceeded
  | Structural_attempt_timeout of { detail : string }
      (** Agent SDK [with_optional_timeout] wrapper fired its per-OAS-call
          ceiling ([max_execution_time_s]). Distinct from transport-level
          provider timeouts. This variant is accepted only from typed
          envelopes; free-form messages stay [Other_detail]. *)
  | Capacity_exhausted
      (** Typed surface for capacity-induced runtime exhaustion.
          Previously [ProviderFailure { kind = Capacity_exhausted _ }] fell
          through to [Other_detail message], losing auto-recovery eligibility
          and triggering the harsher failure policy. *)
  | Other_detail of string

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

val blocker_class_to_string : blocker_class -> string
(** Canonical lowercase labels.  Pinned literals — operator
    dashboards parse these for keeper supervisor alerting. *)

val runtime_exhaustion_summary :
  runtime_exhaustion_reason -> string
(** Human-readable one-sentence summary per reason variant.
    Used in keeper supervisor logs + dashboard tooltips. *)

val runtime_exhaustion_reason_retryable : runtime_exhaustion_reason -> bool
(** Total typed retryability per reason variant. Transient/connectivity
    reasons and bounded-cycle/turn/capacity exhaustion are retryable;
    [Other_detail] (unknown free-text) is not. Replaces a string-prefix
    reparse with a [_ -> false] catch-all that mis-biased transient faults
    to terminal. *)

val blocker_class_continue_gate : blocker_class -> bool
(** [blocker_class_continue_gate b] is [true] iff the supervisor
    should retry past this blocker.  Currently only
    [Ambiguous_post_commit_timeout] and
    [Ambiguous_post_commit_failure] are continue-gated — every
    other blocker terminates the keeper.  Pinned at the
    contract seam — drift changes keeper recovery semantics. *)

val blocker_class_auto_approval_blocked : blocker_class -> bool
(** [blocker_class_auto_approval_blocked b] is [true] iff this blocker
    class should prevent auto-approval of the keeper's next tool call
    (including [always_approve] and remembered allow-rules).  Only
    safety/uncertainty classes are hard-forbidden; transient liveness
    signals such as [Capacity_backpressure], [Turn_timeout], and SDK
    budget/idle/input conditions are intentionally excluded so
    automated recovery flows are not stalled.  Exhaustive — adding a
    variant forces an explicit auto-approval policy decision. *)

val runtime_exhaustion_reason_to_json :
  runtime_exhaustion_reason -> Yojson.Safe.t

val runtime_exhaustion_reason_of_json :
  Yojson.Safe.t -> runtime_exhaustion_reason option

val blocker_class_of_serialized_string :
  string -> blocker_class option
(** [blocker_class_of_serialized_string label] is the inverse
    of {!blocker_class_to_string}.  [Runtime_exhausted _]
    maps from the bare ["runtime_exhausted"] string to
    [Runtime_exhausted (Other_detail "runtime_exhausted")] —
    the reason payload is not round-trippable through this
    function alone (callers needing the reason use
    {!runtime_exhaustion_reason_of_json}).  Used by
    {!Keeper_meta_json_parse} to decode persisted blocker
    state. *)

(** {1 Unified blocker_info} *)

type no_progress_blocker_facts = {
  no_progress_reason : string;
  no_progress_streak : int;
  no_progress_threshold : int;
  no_progress_latched : bool;
}
(** Structured facts for a persisted [No_progress_loop] blocker.  These fields
    are machine-readable state; [blocker_info.detail] remains presentation
    text only. *)

type blocker_facts =
  | No_progress_loop_facts of no_progress_blocker_facts

type blocker_info = {
  klass : blocker_class;
  detail : string;
  facts : blocker_facts option;
}
(** Authoritative blocker representation: a typed [blocker_class]
    paired with optional free-form [detail] (UI / Otel_metric_store label).
    Replaces the deprecated split blocker fields, so substring
    classification is no longer load-bearing for persisted keeper_meta.
    When there is no
    blocker, the runtime state holds [None]; when there is a blocker,
    [klass] is always populated and [detail] may be ["" ]. *)

val blocker_info_of_class :
  ?detail:string -> ?facts:blocker_facts -> blocker_class -> blocker_info
(** [blocker_info_of_class ?detail klass] constructs a [blocker_info]
    for [klass].  [detail] defaults to [""]. *)

val blocker_info_of_no_progress_loop :
  ?detail:string ->
  reason:string ->
  streak:int ->
  threshold:int ->
  latched:bool ->
  unit ->
  blocker_info
(** [blocker_info_of_no_progress_loop] stamps [No_progress_loop] with
    structured telemetry facts so downstream status surfaces do not parse
    the human-readable [detail]. *)

val blocker_info_to_json : blocker_info -> Yojson.Safe.t
(** Round-trippable JSON encoding.  [Runtime_exhausted reason] uses
    a structured object so the inner [runtime_exhaustion_reason] is
    preserved across read/write cycles. *)

val blocker_info_of_json : Yojson.Safe.t -> blocker_info option
(** Parses the JSON shape emitted by {!blocker_info_to_json}.
    Returns [None] for [`Null] or any value whose [klass] field is
    absent / not recognisable. *)

(** {1 Runtime attempt provenance} *)

type runtime_attempt_record = {
  provider_id : string;
  http_status : int option;
  outcome : [ `Success | `Failure of string ];
  timestamp : float;
}
(** Last observed provider attempt for a keeper-managed runtime turn.
    Persisted in [agent_runtime_state] so supervisor-only terminal
    outcomes can still surface provider/HTTP context. *)

val runtime_attempt_record_to_json :
  runtime_attempt_record -> Yojson.Safe.t

val runtime_attempt_record_of_json :
  Yojson.Safe.t -> runtime_attempt_record option

(** {1 Tool call summary for continuity} *)

type tool_call_summary = {
  tool_name : string;
  outcome : string;  (** "ok" | "error: <short_msg>" *)
}

(** {1 Agent runtime state record} *)

type agent_runtime_state = {
  usage : usage_metrics;
  compaction_rt : compaction_runtime;
  proactive_rt : proactive_runtime;
  generation : int;
  trace_id : Keeper_id.Trace_id.t;
  trace_history : string list;
  last_handoff_ts : float;
  last_continuity_update_ts : float;
  last_autonomous_action_at : string;
  autonomous_action_count : int;
  autonomous_turn_count : int;
  autonomous_text_turn_count : int;
  autonomous_tool_turn_count : int;
  board_reactive_turn_count : int;
  mention_reactive_turn_count : int;
  noop_turn_count : int;
  last_blocker : blocker_info option;
  last_runtime_attempt : runtime_attempt_record option;
  last_turn_tool_calls : tool_call_summary list;
  last_seen_message_seq : int;
  (** Highest message seq this keeper has scanned for direct mentions. *)
}

(** {1 Keeper meta record} *)

type keeper_meta = {
  (* Identity & profile *)
  id : Ids.Keeper_id.t option;
  name : string;
  agent_name : string;
  persona : string option;
  goal : string;
  instructions : string;
  (* Policy *)
  sandbox_profile : Keeper_types_profile.sandbox_profile;
  sandbox_image : string option;
  network_mode : Keeper_types_profile.network_mode;
  allowed_paths : string list;
  tool_access : string list;
  tool_denylist : string list;
  mention_targets : string list;
  proactive : proactive_policy;
  compaction : compaction_policy;
  multimodal_policy : Keeper_types_profile.multimodal_policy;
  auto_handoff : bool;
  handoff_threshold : float;
  handoff_cooldown_sec : int;
  (* Lifecycle *)
  created_at : string;
  updated_at : string;
  (* Performance & limits *)
  max_context_override : int option;
  (* Operational control *)
  continuity_summary : string;
  active_goal_ids : string list;
  paused : bool;
  latched_reason : Keeper_latched_reason.t option;
      (** Typed companion to [paused]: why this keeper is latched.
          Producers set it alongside [paused = true]; consumers surface
          it via the status bridge. Display/observability only. *)
  auto_resume_after_sec : float option;
      (** Self-healing circuit breaker: when [Some sec] the supervisor
          can auto-resume this keeper after [sec] seconds following the
          updated pause timestamp. [None] means operator-owned pause. *)
  autoboot_enabled : bool;
  current_task_id : Keeper_id.Task_id.t option;
      (** Currently claimed task ID for cost attribution.  Set
          when keeper claims a task; cleared on
          masc_transition action=done.  Propagated to
          trajectory accumulator for per-task cost tracking. *)
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  always_approve : bool option;
  (* Agent runtime state *)
  runtime : agent_runtime_state;
  (* Identity & concurrency *)
  keeper_id : Keeper_id.Uid.t option;
  oas_env : (string * string) list;
  meta_version : int;
}

(** Overlay TOML/persona defaults onto persisted runtime meta for
    status-facing reads. Persisted runtime JSON intentionally omits
    TOML-owned fields such as [sandbox_profile], [network_mode], and
    [tool_access]. *)
val effective_meta_result : keeper_meta -> (keeper_meta, string) result

(** Pure variant for callers that already loaded profile defaults. *)
val effective_meta_of_profile_defaults :
  Keeper_types_profile.keeper_profile_defaults ->
  keeper_meta ->
  (keeper_meta, string) result

val missing_required_sandbox_profile_error :
  keeper_name:string ->
  Keeper_types_profile.keeper_profile_defaults ->
  string
(** Error text shared by effective-meta reconcile and keeper-up parsing when a
    declarative keeper profile omits the required [sandbox_profile]. *)

val runtime_id_of_meta : keeper_meta -> string
(** Runtime id selected for keeper dispatch. Uses the keeper profile [model]
    when present; otherwise falls back to the configured default runtime id. *)

(** {1 Outcome <-> string} *)

val proactive_cycle_outcome_to_string :
  proactive_cycle_outcome -> string
(** Canonical lowercase labels: ["never_started"], ["unknown"],
    ["silent"], ["text_response"], ["tool_use"],
    ["mixed_response"], ["error"]. *)

val proactive_cycle_outcome_of_string :
  string -> proactive_cycle_outcome
(** Permissive parser (case-insensitive after trim).  Unknown
    labels fall back to [Proactive_unknown] — but module-load
    [assert_roundtrip] guarantees every variant produced by
    [_to_string] is parsed back identically, so unknown means
    operator error, not silent variant drift. *)

(** {1 Updater helpers} *)

val now_iso : unit -> string
(** [now_iso ()] is the ISO-8601 timestamp from
    {!Masc_domain.now_iso}. *)

val map_runtime :
  (agent_runtime_state -> agent_runtime_state) ->
  keeper_meta ->
  keeper_meta
(** [map_runtime f m] returns [{ m with runtime = f m.runtime }] —
    pure functional update of the runtime sub-record. *)

val map_usage :
  (usage_metrics -> usage_metrics) ->
  keeper_meta ->
  keeper_meta
(** [map_usage f m] is [map_runtime (fun rt -> { rt with usage =
    f rt.usage }) m] — convenience for usage-only updates. *)

val zero_usage : usage_metrics
(** [zero_usage] is the all-zero usage_metrics record.  Pinned
    at the contract seam — drift would change "fresh keeper"
    initial state. *)

val reset_runtime_state : keeper_meta -> keeper_meta
(** [reset_runtime_state m] is [map_usage (fun _ -> zero_usage)
    m] — used by keeper restart to clear cumulative counters
    while preserving identity / policy fields. *)

val map_compaction_rt :
  (compaction_runtime -> compaction_runtime) ->
  keeper_meta ->
  keeper_meta
(** Nested update of [m.runtime.compaction_rt]. *)

val map_proactive_rt :
  (proactive_runtime -> proactive_runtime) ->
  keeper_meta ->
  keeper_meta
(** Nested update of [m.runtime.proactive_rt]. *)

(** {1 Removed model-arg marker list} *)

val removed_keeper_model_arg_names : string list
(** Names of removed keeper-creation tool arguments that have
    been retired because runtime/provider/model selection is not part
    of the keeper contract
    (["models"], ["allowed_models"], ["active_model"]).
    Consumed by {!reject_removed_model_args} which
    surfaces operator-readable rejection messages instead of
    silently ignoring removed args.  Pinned data table —
    drift would either re-accept removed args silently or
    reject newly added args by mistake. *)

val reject_removed_model_args :
  tool_name:string -> Yojson.Safe.t -> (unit, string) result
(** Reject retired keeper model-selection input fields at tool/API boundaries.
    Model and provider identity is resolved from the default Runtime binding,
    not per-call keeper arguments. *)
