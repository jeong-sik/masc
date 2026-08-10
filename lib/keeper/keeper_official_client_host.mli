(** Provider-neutral Keeper projection shared by official CLI runtimes.

    This module owns MASC/AGENT_CORE hooks, typed tool execution, and context
    injection. Protocol adapters only translate the resulting tool records to
    their official client's wire format. *)

type prepared_turn =
  { messages : Agent_core.Types.message list
  ; system_prompt : string
  ; tools : Agent_core.Tool.t list
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  }

type dynamic_tool_result =
  { success : bool
  ; content : string
  }

type dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

type raw_trace_stage =
  | Run_start
  | Assistant_block
  | Tool_start
  | Tool_finish
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

val resolve_reasoning_effort :
  enable_thinking:bool option ->
  reasoning_effort:Llm_provider.Reasoning_effort.t option ->
  (Llm_provider.Reasoning_effort.t option, Agent_core.Error.t) result
(** Reconcile provider-neutral thinking control with an explicit
    official-client effort. An absent effort remains absent. A generic
    [enable_thinking] value is rejected rather than translated. *)

val text_of_blocks :
  runtime_label:string ->
  field:string ->
  Agent_core.Types.content_block list ->
  (string, Agent_core.Error.t) result

type history_projection =
  { messages : Agent_core.Types.message list
  ; dropped_tool_messages : int
  ; dropped_messages : int
  ; dropped_blocks : int
  }

(** Project canonical history onto the official-client wire, which admits
    text-only user/assistant items. Tool-role messages are dropped whole,
    non-text blocks are stripped from kept messages, and a message left
    without any text is dropped; every drop is counted. The representable
    remainder keeps its original order (masc#27812). *)
val project_official_history :
  Agent_core.Types.message list -> history_projection

(** [true] when the projection dropped nothing. *)
val history_projection_lossless : history_projection -> bool

val hook_error :
  runtime_label:string ->
  hook_name:string ->
  stage:Agent_core.Hooks.hook_stage ->
  string ->
  Agent_core.Error.t

val illegal_hook_decision :
  runtime_label:string ->
  hook_name:string ->
  Agent_core.Hooks.hook_decision ->
  Agent_core.Error.t

val invoke_turn_hook :
  keeper_name:string ->
  turn_count:int ->
  hook_name:string ->
  Agent_core.Hooks.hook option ->
  Agent_core.Hooks.hook_event ->
  Agent_core.Hooks.hook_decision

val prepare_turn :
  runtime_label:string ->
  keeper_name:string ->
  turn_count:int ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  initial_messages:Agent_core.Types.message list ->
  model_input_projection:Agent_core.Agent.model_input_projection option ->
  hooks:Agent_core.Hooks.hooks option ->
  (prepared_turn, Agent_core.Error.t) result

val dynamic_tools :
  runtime_label:string ->
  keeper_name:string ->
  turn_count:int ->
  tools:Agent_core.Tool.t list ->
  hooks:Agent_core.Hooks.hooks ->
  event_bus:Agent_core.Event_bus.t option ->
  context_injector:Agent_core.Hooks.context_injector option ->
  context:Agent_core.Context.t option ->
  terminal_error:string option ref ->
  raw_trace_run:Agent_core.Raw_trace.active_run option ->
  (dynamic_tool list, Agent_core.Error.t) result

val with_run_lifecycle_events :
  event_bus:Agent_core.Event_bus.t option ->
  keeper_name:string ->
  (unit -> (Runtime_agent.run_result, Agent_core.Error.t) result) ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
(** Publish the same typed start and terminal lifecycle owned by Agent Core.
    Official clients own their internal model loop, so this host boundary is
    the single MASC owner for those events. *)
