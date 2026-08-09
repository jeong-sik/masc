(** Provider-neutral Keeper projection shared by official CLI runtimes.

    This module owns MASC/OAS hooks, typed tool execution, and context
    injection. Protocol adapters only translate the resulting tool records to
    their official client's wire format. *)

type prepared_turn =
  { messages : Agent_sdk.Types.message list
  ; system_prompt : string
  ; tools : Agent_sdk.Tool.t list
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

val resolve_reasoning_effort :
  enable_thinking:bool option ->
  reasoning_effort:Llm_provider.Reasoning_effort.t option ->
  (Llm_provider.Reasoning_effort.t option, Agent_sdk.Error.sdk_error) result
(** Reconcile provider-neutral thinking control with an explicit
    official-client effort. An absent effort remains absent; this function
    never fabricates a model-specific effort from the boolean toggle. *)

val text_of_blocks :
  runtime_label:string ->
  field:string ->
  Agent_sdk.Types.content_block list ->
  (string, Agent_sdk.Error.sdk_error) result

val hook_error :
  runtime_label:string ->
  hook_name:string ->
  stage:Agent_sdk.Hooks.hook_stage ->
  string ->
  Agent_sdk.Error.sdk_error

val illegal_hook_decision :
  runtime_label:string ->
  hook_name:string ->
  Agent_sdk.Hooks.hook_decision ->
  Agent_sdk.Error.sdk_error

val invoke_turn_hook :
  keeper_name:string ->
  turn_count:int ->
  hook_name:string ->
  Agent_sdk.Hooks.hook option ->
  Agent_sdk.Hooks.hook_event ->
  Agent_sdk.Hooks.hook_decision

val prepare_turn :
  runtime_label:string ->
  keeper_name:string ->
  turn_count:int ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  initial_messages:Agent_sdk.Types.message list ->
  model_input_projection:Agent_sdk.Agent.model_input_projection option ->
  hooks:Agent_sdk.Hooks.hooks option ->
  enable_thinking:bool option ->
  (prepared_turn, Agent_sdk.Error.sdk_error) result

val dynamic_tools :
  runtime_label:string ->
  keeper_name:string ->
  turn_count:int ->
  tools:Agent_sdk.Tool.t list ->
  hooks:Agent_sdk.Hooks.hooks ->
  event_bus:Agent_sdk.Event_bus.t option ->
  context_injector:Agent_sdk.Hooks.context_injector option ->
  context:Agent_sdk.Context.t option ->
  terminal_error:string option ref ->
  (dynamic_tool list, Agent_sdk.Error.sdk_error) result
