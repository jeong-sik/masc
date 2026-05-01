(** Keeper_guards — composable pre_tool_use hooks for keeper agents.

    Decomposes the previously monolithic [pre_tool_use] guard chain
    (streak / deny / cost / destructive / governance) into standalone
    OAS [Hooks.hooks] records that stack via [Agent_sdk.Hooks.compose].
    Each guard fills only the [pre_tool_use] slot; composition
    short-circuits on the first non-[Continue] decision.

    Design constraints:
    - Public SDK boundary (C0): OAS is consumed as-is, no OAS edits.
    - MASC/OAS boundary (C1): OAS primitives do not learn about
      keepers — keeper-specific state lives in MASC closures.
    - Observability (C2): every override / approval emits a
      [masc.keeper_gate] Event_bus Custom event in addition to the
      legacy [broadcast_tool_skipped] SSE call. *)

(** Percent-encode a field value for the structured [tool_skipped]
    output. Mirrors [Keeper_agent_run.escape_field_value]. *)
val escape_field : string -> string

(** Render the inline skip reason injected into the tool-result
    when a guard returns [Override]. *)
val render_inline_skip_reason :
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
  | Gate_continue
  | Gate_approval_required

val gate_decision_to_string : gate_decision -> string

val gate_decision_is_rejection : gate_decision -> bool

(** Telemetry payload reported to the gate observer. *)
type gate_decision_event =
  { stage : string
  ; decision : gate_decision
  ; reason_code : string
  ; reason_text : string
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; turn : int
  ; accumulated_cost_usd : float
  ; stage_latency_ms : float
  }

(** Default gate observer — discards events. *)
val ignore_gate_decision : gate_decision_event -> unit

(** Invoke [on_gate_decision] with [event]; logs and swallows
    non-cancel exceptions. *)
val notify_gate_decision :
  (gate_decision_event -> unit) -> gate_decision_event -> unit

(** Emit a [masc.keeper_gate] event to the global [Masc_event_bus]
    when one is registered. Marks the turn as gate-rejected on
    [override] / [approval_required] decisions. *)
val emit_gate_event :
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

(** Mutable streak state captured by [streak_guard]: pair of
    [(tool_name, count)]. *)
type streak_state = { mutable entry : string * int }

val make_streak_state : unit -> streak_state

(** Record [tool_start_time] so the post_tool_use phase can compute
    latency. Always returns [Continue]. Compose FIRST so the
    timestamp is set even when a later guard returns [Override]. *)
val timing_guard : tool_start_time:float ref -> Agent_sdk.Hooks.hooks

(** User-supplied guard. Short-circuits via [Override] when the
    callback returns [Some reason_text]. *)
val custom_guard :
  meta_ref:Keeper_types.keeper_meta ref ->
  on_gate_decision:(gate_decision_event -> unit) ->
  guard:(tool_name:string -> input:Yojson.Safe.t -> string option) ->
  Agent_sdk.Hooks.hooks

(** Same-name streak gate: block when [tool_name] is called
    [threshold+] times consecutively. Catches the
    "same operation, different targets" pattern that OAS's exact
    name+args idle detection misses. *)
val streak_guard :
  meta_ref:Keeper_types.keeper_meta ref ->
  on_gate_decision:(gate_decision_event -> unit) ->
  state:streak_state ->
  threshold:int ->
  Agent_sdk.Hooks.hooks

(** Reject every tool name in [denied]. *)
val deny_guard :
  meta_ref:Keeper_types.keeper_meta ref ->
  on_gate_decision:(gate_decision_event -> unit) ->
  denied:string list ->
  Agent_sdk.Hooks.hooks

(** Reject when the running cost meets or exceeds [max_cost_usd].
    No-op when [None]. *)
val cost_guard :
  meta_ref:Keeper_types.keeper_meta ref ->
  on_gate_decision:(gate_decision_event -> unit) ->
  max_cost_usd:float option ->
  Agent_sdk.Hooks.hooks

(** Destructive-pattern detection for tools flagged by
    [Tool_dispatch.is_destructive]; runs only when [enabled]. *)
val destructive_guard :
  meta_ref:Keeper_types.keeper_meta ref ->
  on_gate_decision:(gate_decision_event -> unit) ->
  enabled:bool ->
  Agent_sdk.Hooks.hooks

(** Governance gate. Escalates via [ApprovalRequired] when the
    assessed risk meets or exceeds the keeper-confirm threshold. *)
val governance_approval_guard :
  meta_ref:Keeper_types.keeper_meta ref ->
  on_gate_decision:(gate_decision_event -> unit) ->
  Agent_sdk.Hooks.hooks

(** Build the full keeper pre_tool_use chain in canonical order:
    timing -> custom -> streak -> deny -> cost -> destructive ->
    governance_approval. *)
val build_chain :
  meta_ref:Keeper_types.keeper_meta ref ->
  tool_start_time:float ref ->
  streak_state:streak_state ->
  streak_threshold:int ->
  denied:string list ->
  max_cost_usd:float option ->
  destructive_check:bool ->
  on_gate_decision:(gate_decision_event -> unit) ->
  pre_tool_use_guard:
    (tool_name:string -> input:Yojson.Safe.t -> string option) ->
  Agent_sdk.Hooks.hooks
