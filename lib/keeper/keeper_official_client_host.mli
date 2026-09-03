(** Provider-neutral Keeper projection shared by official CLI runtimes.

    This module owns MASC/AGENT_CORE hooks, typed tool execution, and context
    injection. Protocol adapters only translate the resulting tool records to
    their official client's wire format. *)

val config_error : field:string -> string -> Agent_core.Error.t
(** Build the [InvalidConfig] error the official-client adapters report when a
    runtime is misconfigured. Shared so the three adapters name the offending
    field the same way. *)

val internal_error : string -> Agent_core.Error.t
(** Build the [Internal] error for a failure that is neither configuration nor
    provider behaviour. *)

type prepared_turn =
  { messages : Agent_core.Types.message list
  ; system_prompt : string
  ; tools : Agent_core.Tool.t list
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  }

type terminal_boundary_outcome = Runtime_official_client_tool.terminal_boundary_outcome =
  | Terminal_completed
  | Durable_stimulus_deferred
  | External_effect_deferred
  | Terminal_failed of
      { failure_class : Tool_result.tool_failure_class
      ; effect_disposition : Tool_result.failure_effect_disposition
      ; diagnostic : string
      }

type host_stop = Runtime_official_client_tool.host_stop =
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
  | Terminal_tool_boundary of
      { tool_name : string
      ; outcome : terminal_boundary_outcome
      }

type dynamic_tool_result = Runtime_official_client_tool.dynamic_tool_result =
  { success : bool
  ; content : string
  ; abort_turn : host_stop option
  }

type dynamic_tool = Runtime_official_client_tool.dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

(** One pre_tool_use rejection (typed [Block]) recorded during a turn.
    The official-client CLI owns the live conversation; when it
    escalates the reject to a dead turn this record is the only
    surviving copy of the corrective round-trip (masc#28885). *)
type rejected_tool_call =
  { call_id : string
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; detail : string
  }

type raw_trace_stage =
  | Run_start
  | Assistant_block
  | Tool_start
  | Tool_finish
  | Native_tool_start
  | Native_tool_finish
  | Run_finish

val observe_raw_trace
  :  keeper_name:string
  -> stage:raw_trace_stage
  -> (unit -> ('a, Agent_core.Error.t) result)
  -> 'a option
(** Attempt one secondary RAW-trace observation. A typed trace failure is
    logged and counted but cannot replace the authoritative provider, tool, or
    cancellation result. Reserved exceptions from the observation still
    propagate. *)

val start_raw_trace
  :  keeper_name:string
  -> raw_trace:Agent_core.Raw_trace.t option
  -> prompt:string
  -> ?model:string
  -> ?reasoning_effort:string
  -> unit
  -> Agent_core.Raw_trace.active_run option

val finish_raw_error
  :  keeper_name:string
  -> Agent_core.Raw_trace.active_run option
  -> Agent_core.Error.t
  -> unit

val finish_raw_success
  :  keeper_name:string
  -> Agent_core.Raw_trace.active_run option
  -> Runtime_agent.run_result
  -> Runtime_agent.run_result
(** Complete one official-client RAW run. Observation failure cannot replace
    the authoritative runtime result; a trace reference is returned only when
    every assistant block and the terminal record were persisted. *)

val record_raw_native_tool
  :  keeper_name:string
  -> raw_trace_run:Agent_core.Raw_trace.active_run option
  -> phase:[ `Started | `Finished ]
  -> Runtime_native_tools.observation
  -> unit
(** Best-effort durable observation of an official client's built-in tool.
    It is deliberately separate from MASC tool execution and approval rows. *)

val resolve_reasoning_effort :
  enable_thinking:bool option ->
  reasoning_effort:Llm_provider.Reasoning_effort.t option ->
  (Llm_provider.Reasoning_effort.t option, Agent_core.Error.t) result
(** Reconcile provider-neutral thinking control with an explicit
    official-client effort. An absent effort remains absent. A generic
    [enable_thinking] value is rejected rather than translated. *)

(** One base64 image pulled out of a goal, ready for a transport that carries
    images alongside the prompt text. *)
type image_block =
  { media_type : string
  ; base64_data : string
  }

val text_and_images_of_blocks :
  runtime_label:string ->
  field:string ->
  Agent_core.Types.content_block list ->
  (string * image_block list, Agent_core.Error.t) result
(** Project a goal into the prompt text plus its base64 images. Use this for a
    transport that carries images; {!text_of_blocks} is for one that does not,
    and rejects an image rather than dropping it. Non-base64 image sources and
    every other block kind are rejected here too. *)

val text_of_blocks :
  runtime_label:string ->
  field:string ->
  Agent_core.Types.content_block list ->
  (string, Agent_core.Error.t) result

val encode_history_message : Agent_core.Types.message -> string
(** Preserve one canonical message on a text-only official-client wire. Every
    role uses the same versioned envelope, so raw user bytes cannot spoof the
    framing layer and typed block payloads, tool identities, structured result
    content, failure provenance, and message metadata remain visible. *)

val invoke_turn_completion_hooks :
  runtime_label:string ->
  keeper_name:string ->
  turn_count:int ->
  hooks:Agent_core.Hooks.hooks ->
  Agent_core.Types.api_response ->
  (unit, Agent_core.Error.t) result
(** Run the Agent Core [after_turn] and [on_stop] lifecycle for a completed
    official-client turn. Host-stop projections use the same hook order as a
    provider-emitted terminal before their durable session is settled. *)

val measure_message_bytes : Agent_core.Types.message -> int
(** Bytes one message contributes to the start-turn seed budget, in the
    canonical MASC encoding. At or above what any adapter's own rendering
    sends, so a budget checked with this cannot be exceeded downstream. *)

val prepare_turn :
  runtime_label:string ->
  keeper_name:string ->
  turn_count:int ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  initial_messages:Agent_core.Types.message list ->
  model_input_projection:Agent_core.Agent.model_input_projection option ->
  hooks:Agent_core.Hooks.hooks option ->
  configured_reasoning_effort:Llm_provider.Reasoning_effort.t option ->
  (prepared_turn, Agent_core.Error.t) result
(** [configured_reasoning_effort] seeds the turn params the
    [before_turn_params] hook receives, so a hook can still override it.

    The hook's [extra_system_context] is appended as a raw [System] message
    carrying {!Agent_core.Types.Extra_system_context_provenance}. Official
    adapters must keep that message on their provider instruction surface; it
    is not an Agent Core synthetic User carrier.

    The seed carries the projected history as-is. Nothing is cut here: the
    provider owns its context window and reports exceeding it as a typed
    terminal, which the shrink sequence in
    {!Keeper_turn_driver_try_provider.context_overflow_shrink_sequence}
    consumes to retry with less. A second ceiling applied before that one
    measured wire bytes instead of tokens and dropped the oldest atoms with no
    copy kept. *)

val dynamic_tools :
  tool_approval:Agent_core.Hooks.tool_approval_callback option ->
  runtime_label:string ->
  keeper_name:string ->
  turn_count:int ->
  tools:Agent_core.Tool.t list ->
  hooks:Agent_core.Hooks.hooks ->
  event_bus:Agent_core.Event_bus.t option ->
  context_injector:Agent_core.Hooks.context_injector option ->
  context:Agent_core.Context.t option ->
  terminal_effect_state:(unit -> Keeper_tools_agent_core.terminal_effect_state) ->
  terminal_error:string option ref ->
  pre_tool_rejects:rejected_tool_call list ref ->
  ?on_result_handoff:
    (invocation:Agent_core.Tool_contract.Invocation.t -> content:string -> unit) ->
  raw_trace_run:Agent_core.Raw_trace.active_run option ->
  unit ->
  (dynamic_tool list, Agent_core.Error.t) result
(** Project Agent Core tools onto one official-client turn.

    [tool_approval] settles a [pre_tool_use] hook that answers
    [ElicitToolApproval], exactly as it does on AGENT_CORE's own tool loop --
    both paths go through
    {!Agent_core.Agent_tool_pre_execution_gate.settle}. Without it such a
    decision is rejected rather than admitted, so a caller that does not
    supply one is no more permissive than before.

    Required rather than optional so a new runtime lane cannot inherit [None]
    by saying nothing. Silence is how one lane came to offer a decision the
    other refused. Three consecutive
    calls with the same tool, canonical input, disposition, and output produce
    [abort_turn]; this is the official-client equivalent of Agent Core's
    repeated exact tool boundary and prevents a vendor-owned loop from holding
    one Keeper and host resources indefinitely. *)

val persist_pre_tool_rejects :
  session_dir:string ->
  session_id:string ->
  rejected_tool_call list ->
  (int, string) result
(** Append a dead turn's reject round-trips to the canonical checkpoint
    so the next turn's replay carries the corrective text (masc#28885:
    every escalated turn lost its correction and the model resent the
    same broken call). Each reject becomes the pair a surviving turn
    already persists — an assistant [ToolUse] block answered by a
    tool-role [ToolResult] with the deterministic validation failure —
    appended in call order. Returns how many rejects were persisted; an
    empty list and a missing checkpoint (no replay exists to correct)
    are both [Ok 0]. Callers flush only on a failed turn: a surviving
    turn's round-trips reach the checkpoint through the next turn's
    history, and appending them here too would duplicate them. *)

val with_run_lifecycle_events :
  event_bus:Agent_core.Event_bus.t option ->
  keeper_name:string ->
  (unit -> (Runtime_agent.run_result, Agent_core.Error.t) result) ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
(** Publish the same typed start and terminal lifecycle owned by Agent Core.
    Official clients own their internal model loop, so this host boundary is
    the single MASC owner for those events. *)

val clamp_reasoning_effort_to_catalog :
  model_id:string option ->
  requested:Llm_provider.Reasoning_effort.t option ->
  Llm_provider.Reasoning_effort.t option
(** Snap a requested reasoning effort into the catalog's accepted set for
    [model_id]: the requested effort when it is accepted, otherwise the
    nearest accepted effort (highest below; lowest when every accepted effort
    is higher). Pure; pinned by [test_keeper_codex_effort_clamp]. *)

val effective_reasoning_effort :
  runtime_label:string ->
  keeper_name:string ->
  runtime_id:string ->
  model_id:string option ->
  requested:Llm_provider.Reasoning_effort.t option ->
  Llm_provider.Reasoning_effort.t option
(** {!clamp_reasoning_effort_to_catalog} plus the operator-visible info log
    when the effort was snapped. One call site per official-client lane, so
    Codex and Claude Code treat the same declared effort identically. *)

val host_stop_result :
  runtime_id:string ->
  model:string ->
  session_id:string ->
  turn_id:string ->
  turns_used:int ->
  latency_ms:int option ->
  usage:Agent_core.Types.api_usage option ->
  host_stop ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
(** Build the provider-neutral checkpoint terminal after an official-client
    adapter stops its vendor-owned loop. The external client session is the
    durable continuation owner, so no Agent Core checkpoint is synthesized.

    [usage] is what the adapter could measure before the stop: Claude Code
    sums the usage of the assistant frames it saw, since the result frame
    that carries a turn total never arrives after a host stop. [Some] marks
    the observation [Per_request]; [None] leaves the scope unavailable, which
    is what every host-stopped turn recorded before 2026-09-03.

    Non-failed stops carry a one-attempt runtime observation (masc#31312):
    the vendor loop did run to reach this boundary, and a [None] observation
    here made every host-stopped turn classify as [Runtime_not_observed],
    which the operator disposition surfaced as "unmapped_runtime_state". *)



val admit_native_posture :
  posture:Runtime_native_tools.posture ->
  approval_mode:Keeper_tool_approval_mode.mode ->
  none_supported:bool ->
  client_label:string ->
  (unit, string) result
(** Pure admission rule for RFC-0390. [Native_none] is refused when the
    client cannot disable its built-in tools. [Native_full] is refused
    unless the keeper's approval stance is [Yolo]: built-in calls run inside
    the vendor process and never reach [ElicitToolApproval], so full native
    effects are admitted only where every MASC call would also run unasked.
    This is the typed predicate only — see {!resolve_native_posture} for
    what a refusal does to the turn. *)

val resolve_native_posture :
  base_path:string ->
  keeper_name:string ->
  client_label:string ->
  default:Runtime_native_tools.posture ->
  none_supported:bool ->
  (Runtime_native_tools.posture, Agent_core.Error.t) result
(** Read the keeper's declared posture from its profile TOML (cached loader),
    fall back to [default] when the profile declares nothing, then apply
    {!admit_native_posture} against the keeper's current approval stance.
    A profile that fails to load is a config error, not a silent default.
    An admission refusal does not fail this call: the posture degrades to
    the safest weaker one ([full] -> [read]; [none] -> [read] where the
    client cannot disable built-ins) and the downgrade is published as a
    typed event ([masc.keeper.native_posture_degraded]) — the turn keeps
    running, the record says what was declared and why it was not honored.

    Reporting cadence differs by branch (#30408 review): the [full] ->
    [read] degradation is turn state (the approval mode lives in process
    memory and can flip), so it emits one event per affected turn. The
    [none]-on-a-client-without-a-disable-switch case is a static
    profile-vs-assignment contradiction, so it emits once per process per
    (keeper, client) pair at the first offending resolution and then goes
    quiet until a resolution honors the declaration (which re-arms the
    gate). The effective posture returned is unchanged in both branches.
    The approval stance is in-memory by design; after a restart that means
    a [full] keeper runs degraded-to-[read] turns, each one recorded,
    until an operator re-arms [Yolo]. *)
