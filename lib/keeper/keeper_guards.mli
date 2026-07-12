(** Keeper_guards — composable pre_tool_use hooks for keeper agents.

    Decomposes the previously monolithic [pre_tool_use] guard chain
    (deny / cost / destructive / governance) into standalone
    OAS [Hooks.hooks] records that stack via [Agent_sdk.Hooks.compose].
    Each guard fills only the [pre_tool_use] slot; composition
    short-circuits on the first non-[Continue] decision.

    Design constraints:
    - Public SDK boundary (C0): OAS is consumed as-is, no OAS edits.
    - MASC/OAS boundary (C1): OAS primitives do not learn about
      keepers — keeper-specific state lives in MASC closures.
    - Observability (C2): every override / block / approval emits a
      [masc.keeper_gate] Event_bus Custom event in addition to the
      legacy [broadcast_tool_skipped] SSE call. *)

(** Percent-encode a field value for the structured [tool_skipped]
    output. Mirrors [Keeper_agent_run.escape_field_value]. *)
val escape_field : string -> string

(** Render the inline skip reason injected into the tool-result
    when a guard returns [Override] or [Block]. *)
val render_inline_skip_reason :
  tool_name:string ->
  reason_code:string ->
  reason_text:string ->
  string

val render_inline_skip_reason_with_source :
  source_path:string ->
  source_line:int ->
  tool_name:string ->
  reason_code:string ->
  reason_text:string ->
  string

(** Broadcast a tool-skip event to SSE listeners and record it in
    [Dashboard_governance_metrics]. *)
val broadcast_tool_skipped :
  keeper_name:string ->
  tool_name:string ->
  reason_code:string ->
  unit

(** Project a tool input JSON to the first non-empty
    [command]/[cmd]/[content] string for screening guards. *)
val extract_command_from_input : Yojson.Safe.t -> string

(** Typed gate decision vocabulary. JSON/log/metric labels must pass
    through {!gate_decision_to_string}; internal branching should match this
    variant exhaustively. *)
type gate_decision =
  | Gate_override
  | Gate_block
  | Gate_continue
  | Gate_approval_required

val gate_decision_to_string : gate_decision -> string

val gate_decision_is_rejection : gate_decision -> bool

(** Log severity for repeated gate rejections.  The first sighting stays WARN;
    repeated sightings downgrade so a bad plan does not flood WARN logs every
    keeper cycle. *)
type gate_rejection_log_severity =
  | Gate_rejection_first_warn
  | Gate_rejection_repeat_info of int
  | Gate_rejection_repeat_debug of int

val gate_rejection_log_severity_to_string :
  gate_rejection_log_severity -> string

(** Telemetry payload reported to the gate observer. *)
type gate_decision_event =
  { stage : string
  ; keeper_name : string
  ; decision : gate_decision
  ; reason_code : string
  ; reason_text : string
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; turn : int
  ; accumulated_cost_usd : float
  ; stage_latency_ms : float
  ; source_path : string option
  ; source_line : int option
  }

(** Default gate observer — discards events. *)
val ignore_gate_decision : gate_decision_event -> unit

(** Invoke [on_gate_decision] with [event]; logs and swallows
    non-cancel exceptions.  Observer-failure warnings include
    [keeper=<name>] so log readers can attribute failures by keeper;
    dashboard/microlog integrations should use metric labels or event
    payloads instead of parsing this warning line. *)
val notify_gate_decision :
  (gate_decision_event -> unit) -> gate_decision_event -> unit

(** Emit a [masc.keeper_gate] event to the global [Masc_event_bus]
    when one is registered. Marks the turn as gate-rejected on
    [override] / [block] decisions. *)
val emit_gate_event :
  source_path:string option ->
  source_line:int option ->
  stage:string ->
  decision:gate_decision ->
  reason_code:string ->
  tool_name:string ->
  agent_name:string ->
  turn:int ->
  accumulated_cost_usd:float ->
  stage_latency_ms:float ->
  reason_text:string ->
  unit

(** Compose [emit_gate_event] + [notify_gate_decision] into a
    single call used by every guard. *)
val report_gate_decision :
  (gate_decision_event -> unit) ->
  source_path:string option ->
  source_line:int option ->
  stage:string ->
  decision:gate_decision ->
  reason_code:string ->
  reason_text:string ->
  tool_name:string ->
  keeper_name:string ->
  input:Yojson.Safe.t ->
  turn:int ->
  accumulated_cost_usd:float ->
  stage_latency_ms:float ->
  unit

(** Build a [Hooks.hooks] record with only [pre_tool_use] filled. *)
val hooks_of_pre_tool_use : Agent_sdk.Hooks.hook -> Agent_sdk.Hooks.hooks

(** Compose hooks list left-to-right via [Hooks.compose]; each
    slot short-circuits on the first non-[Continue] decision. *)
val compose_all : Agent_sdk.Hooks.hooks list -> Agent_sdk.Hooks.hooks

(** Mutex-protected per-hook state for consecutive duplicate read-only
    observations. Pending reads are represented as a duplicate-free set of
    in-flight tool/input keys scoped to the current OAS tool batch, so the
    pending bound is the current [tool_schedule.batch_size]. Pending entries
    are drained on PostToolUse, failure, batch change, and turn-boundary reset. *)
type readonly_observation_state

val make_readonly_observation_state : unit -> readonly_observation_state
val reset_readonly_observation_state : readonly_observation_state -> unit

(** Record [tool_start_time] so the post_tool_use phase can compute
    latency. Always returns [Continue]. Compose FIRST so the
    timestamp is set even when a later guard returns [Override]. *)
val timing_guard : tool_start_time:float ref -> Agent_sdk.Hooks.hooks

(** User-supplied guard. Short-circuits via [Override] when the
    callback returns [Some reason_text]. *)
val custom_guard :
  meta_ref:Keeper_meta_contract.keeper_meta ref ->
  on_gate_decision:(gate_decision_event -> unit) ->
  guard:(tool_name:string -> input:Yojson.Safe.t -> string option) ->
  Agent_sdk.Hooks.hooks

(** Block a consecutive duplicate read-only snapshot observation with the same
    canonical tool/input. Same-batch duplicates are blocked while pending;
    completed observations are recorded only after successful PostToolUse.
    The state belongs to one keeper hook closure; internal locking protects
    concurrent hook invocations without serializing other keepers. Descriptor-
    classified polling reads are exempt. *)
val readonly_observation_duplicate_guard :
  meta_ref:Keeper_meta_contract.keeper_meta ref ->
  on_gate_decision:(gate_decision_event -> unit) ->
  state:readonly_observation_state ->
  Agent_sdk.Hooks.hooks

(** Reject every tool name in [denied]. *)
val deny_guard :
  meta_ref:Keeper_meta_contract.keeper_meta ref ->
  on_gate_decision:(gate_decision_event -> unit) ->
  denied:string list ->
  Agent_sdk.Hooks.hooks

(** Cost telemetry passthrough.

    [max_cost_usd] is advisory only and must never reject tool execution. *)
val cost_guard :
  meta_ref:Keeper_meta_contract.keeper_meta ref ->
  on_gate_decision:(gate_decision_event -> unit) ->
  max_cost_usd:float option ->
  Agent_sdk.Hooks.hooks

(** Destructive-pattern detection for tools flagged by descriptor-aware
    capability projection; runs only when the supplied policy is enabled. *)
val destructive_guard :
  meta_ref:Keeper_meta_contract.keeper_meta ref ->
  on_gate_decision:(gate_decision_event -> unit) ->
  policy:Destructive_ops_policy.t ->
  Agent_sdk.Hooks.hooks

(** Governance gate. Escalates via [ApprovalRequired] when the
    assessed risk meets or exceeds the keeper-confirm threshold. *)
val governance_approval_guard :
  meta_ref:Keeper_meta_contract.keeper_meta ref ->
  on_gate_decision:(gate_decision_event -> unit) ->
  Agent_sdk.Hooks.hooks

(** Build the full keeper pre_tool_use chain in canonical order:
    timing -> custom -> read-only observation duplicate -> deny ->
    cost -> destructive -> governance_approval. *)
val build_chain :
  meta_ref:Keeper_meta_contract.keeper_meta ref ->
  tool_start_time:float ref ->
  readonly_observation_state:readonly_observation_state ->
  denied:string list ->
  max_cost_usd:float option ->
  destructive_ops_policy:Destructive_ops_policy.t ->
  on_gate_decision:(gate_decision_event -> unit) ->
  pre_tool_use_guard:
    (tool_name:string -> input:Yojson.Safe.t -> string option) ->
  Agent_sdk.Hooks.hooks

module For_testing : sig
  val reset_gate_rejection_log_counts : unit -> unit

  val record_gate_rejection_log_severity :
    ?reason_key:string ->
    keeper_name:string ->
    stage:string ->
    tool_name:string ->
    reason_code:string ->
    unit ->
    gate_rejection_log_severity

  val planner_alternative_for_gate :
    stage:string -> tool_name:string -> string
end
