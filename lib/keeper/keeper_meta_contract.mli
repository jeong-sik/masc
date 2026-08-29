(** Keeper_meta_contract — Keeper meta policy + runtime contract
    types and pure helpers.

    Included by {!Keeper_types} so existing [Keeper_types.*]
    callers keep their public API.  This module separates the
    type-heavy contract from JSON parsing
    ({!Keeper_meta_json}) and store I/O.

    Internal: ~3 helpers stay private —
    [blocker_class_of_serialized_string] (deserializer used
    only by JSON parsing), [map_proactive_rt]
    (nested-record updaters that callers reach via the higher-level
    {!map_runtime} / {!map_usage}).  All consumed only via the runtime
    contract or the JSON pipeline. *)

(** {1 Policy types} *)

type proactive_policy = {
  enabled : bool;
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
  last_usage_reported_at : float option;
      (** Timestamp of the most recent provider-reported usage observation.
          [None] means no provider usage has been observed. *)
  last_latency_ms : int;
}

val with_last_reported_usage :
  usage_metrics ->
  usage_reported:bool ->
  input_tokens:int ->
  output_tokens:int ->
  total_tokens:int ->
  observed_at:float ->
  usage_metrics
(** Replace the last provider-usage observation only when the provider
    reported usage. Missing usage preserves the three token fields and their
    timestamp as one observation. *)

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
  | Session_conflict
      (** The provider session lease is owned by another process. This remains
          terminal for automatic retry and is never inferred from message text. *)
  | Capacity_exhausted
      (** Typed surface for capacity-induced runtime exhaustion.
          Previously [ProviderFailure { kind = Capacity_exhausted _ }] fell
          through to [Other_detail message], losing auto-recovery eligibility
          and triggering the harsher failure policy. *)
  | Other_detail of string

type blocker_class =
  | Runtime_exhausted of runtime_exhaustion_reason
  | Capacity_backpressure
  | Fiber_unresolved
  | Agent_core_context_window_exceeded
  | Agent_core_unrecognized_stop_reason
  | Agent_core_guardrail_violation
  | Agent_core_tripwire_violation
  | Agent_core_input_required
  | Internal_unhandled_exception
  | Internal_bridge_exception
  | Internal_contract_rejected
  | Incomplete_tool_transcript
  | Terminal_effect_failed
  | Provider_attempt_effect_fenced
  | Tool_correction_lost
  | Receipt_persistence_failed
  | Gate_replay_repair_required

val blocker_class_to_string : blocker_class -> string
(** Canonical lowercase labels.  Pinned literals — operator
    dashboards parse these for keeper supervisor alerting. *)

val runtime_exhaustion_summary :
  runtime_exhaustion_reason -> string
(** Human-readable one-sentence summary per reason variant.
    Used in keeper supervisor logs + dashboard tooltips. *)

val runtime_exhaustion_reason_retryable : runtime_exhaustion_reason -> bool
(** Total typed retryability per reason variant. Transient/connectivity
    reasons and candidate/capacity exhaustion are retryable;
    [Session_conflict] and [Other_detail] (unknown free-text) are not. Replaces
    a string-prefix reparse with a [_ -> false] catch-all that mis-biased
    transient faults to terminal. *)

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

type blocker_info = {
  klass : blocker_class;
  detail : string;
}
(** Authoritative blocker representation: a typed [blocker_class]
    paired with optional free-form [detail] (UI / Otel_metric_store label).
    Replaces the deprecated split blocker fields, so substring
    classification is no longer load-bearing for persisted keeper_meta.
    When there is no
    blocker, the runtime state holds [None]; when there is a blocker,
    [klass] is always populated and [detail] may be ["" ]. *)

val blocker_info_of_class :
  ?detail:string -> blocker_class -> blocker_info
(** [blocker_info_of_class ?detail klass] constructs a [blocker_info]
    for [klass].  [detail] defaults to [""]. *)


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

(** {1 Agent runtime state record} *)

type agent_runtime_state = {
  usage : usage_metrics;
  proactive_rt : proactive_runtime;
  trace_id : Keeper_id.Trace_id.t;
  trace_history : string list;
  last_handoff_ts : float;
  last_runtime_attempt : runtime_attempt_record option;
  message_scope_ack_id : string option;
  (** Stable chat-row id of the newest message-scope row injected into a
      completed Keeper turn. *)
}

(** {1 Keeper meta record} *)

type keeper_meta = {
  (* Identity & profile *)
  id : Ids.Keeper_id.t option;
  name : string;
  instructions : string;
  (* Policy *)
  sandbox_profile : Keeper_types_profile.sandbox_profile;
  sandbox_image : string option;
  network_mode : Keeper_types_profile.network_mode;
  mention_targets : string list;
  proactive : proactive_policy;
  (* Lifecycle *)
  created_at : string;
  updated_at : string;
  (* Performance & limits *)
  max_context_override : int option;
  (* Operational control *)
  paused : bool;
  latched_reason : Keeper_latched_reason.t option;
      (** Typed companion to [paused]. Explicit operator pause and
          transcript-corruption reset-required paths may write it. [None] while paused is a fail-closed unclassified state
          requiring operator action. *)
  autoboot_enabled : bool;
  current_task_id : Keeper_id.Task_id.t option;
      (** Currently claimed task ID for cost attribution.  Set
          when keeper claims a task; cleared on
          masc_transition action=done.  Propagated to
          trajectory accumulator for per-task cost tracking. *)
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  always_allow : bool option;
  (* Agent runtime state *)
  runtime : agent_runtime_state;
  (* Identity & concurrency *)
  keeper_id : Keeper_id.Uid.t option;
  agent_core_env : (string * string) list;
}

(** Sanctioned generic unpause transform. Clears ordinary/operator/dead
    latches with the pause bit. A
    [Transcript_corruption_reset_required] latch is returned unchanged, so
    generic resume cannot replay a poisoned checkpoint. *)
val mark_resumed : keeper_meta -> keeper_meta

(** Overlay Keeper configuration defaults onto persisted runtime meta for
    status-facing reads. Persisted runtime JSON intentionally omits
    TOML-owned fields such as [sandbox_profile] and [network_mode]. *)
val effective_meta_result :
  base_path:string -> keeper_meta -> (keeper_meta, string) result

(** The overlay alone, over defaults the caller already holds.

    {!effective_meta_result} loads the profile and applies it in one step,
    which is right for a one-shot status read. A turn that overlays more than
    once must not re-read the profile between them, or two reads of the same
    turn can disagree; it loads once and applies with this.

    Rejects a resolved [Local] profile unless the local-playground hatch
    ([MASC_EXEC_ALLOW_LOCAL_PLAYGROUND]) is set. *)
val effective_meta_of_profile_defaults :
     Keeper_types_profile.keeper_profile_defaults
  -> keeper_meta
  -> (keeper_meta, string) result

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
