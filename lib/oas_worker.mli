(** Oas_worker — Unified entry point for OAS-based MASC tool modules.

    Callers either pass a [cascade_name] string for configured fallback
    selection or a [model_label] string for {!run_model_by_label}.
    All public APIs accept string model labels; no [Model_spec.model_spec]
    type is exposed.

    Transport selection: all [run_*] functions accept an optional
    [~transport] parameter. When omitted, the transport is resolved
    from [MASC_AGENT_TRANSPORT] env var (default: [Local]).

    @since Phase 1 — MASC->OAS migration
    @since Phase 4 — public API restricted to named cascade functions
    @since Phase 5 — run_model_by_label added (string-based API)
    @since Phase 6 — Model_spec.model_spec type fully eliminated from API
    @since Phase 8 — Cascade module deleted, defaults moved here
    @since Phase 9 — gRPC transport option added (#2381) *)

module Oas = Agent_sdk

type run_result = {
  response : Oas.Types.api_response;
  checkpoint : Oas.Checkpoint.t option;
  session_id : string;
  turns : int;
  trace_ref : Oas.Raw_trace.run_ref option;
  proof : Oas.Cdal_proof.t option;
}

(** Cascade call/error metrics as JSON array, sorted by call count. *)
val cascade_metrics_json : unit -> Yojson.Safe.t

(** Locate config/cascade.json via CWD or ME_ROOT.
    Delegates to {!Model_spec.cascade_config_path}. *)
val default_config_path : unit -> string option

(** Return the default model string list for a given cascade name. *)
val default_model_strings : cascade_name:string -> string list

val run_named :
  cascade_name:string ->
  goal:string ->
  ?session_id:string ->
  ?system_prompt:string ->
  ?tools:Oas.Tool.t list ->
  ?initial_messages:Oas.Types.message list ->
  ?max_turns:int ->
  ?max_idle_turns:int ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?accept:(Oas_response.api_response -> bool) ->
  ?guardrails:Oas.Guardrails.t ->
  ?hooks:Oas.Hooks.hooks ->
  ?context_reducer:Oas.Context_reducer.t ->
  ?priority:Llm_provider.Request_priority.t ->
  ?memory:Oas.Memory.t ->
  ?raw_trace:Oas.Raw_trace.t ->
  ?on_event:(Oas.Types.sse_event -> unit) ->
  ?agent_ref:Oas.Agent.t option ref ->
  ?proof_ref:Oas.Cdal_proof.t option ref ->
  ?contract:Oas.Risk_contract.t ->
  ?transport:Masc_grpc_transport.t ->
  ?allowed_paths:string list ->
  ?working_context:Yojson.Safe.t ->
  ?cache_system_prompt:bool ->
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  unit ->
  (run_result, string) result

(** Run a single Agent.run() using a model label string (e.g. "llama:qwen3.5").
    Validates the label parses before attempting execution. *)
val run_model_by_label :
  model_label:string ->
  goal:string ->
  ?system_prompt:string ->
  ?tools:Oas.Tool.t list ->
  ?max_turns:int ->
  ?max_idle_turns:int ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?accept:(Oas_response.api_response -> bool) ->
  ?guardrails:Oas.Guardrails.t ->
  ?hooks:Oas.Hooks.hooks ->
  ?context_reducer:Oas.Context_reducer.t ->
  ?memory:Oas.Memory.t ->
  ?enable_thinking:bool ->
  ?contract:Oas.Risk_contract.t ->
  ?on_event:(Oas.Types.sse_event -> unit) ->
  ?transport:Masc_grpc_transport.t ->
  ?priority:Llm_provider.Request_priority.t ->
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  unit ->
  (run_result, string) result

val run_named_with_masc_tools :
  cascade_name:string ->
  goal:string ->
  ?system_prompt:string ->
  masc_tools:Types.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> bool * string) ->
  ?max_turns:int ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?guardrails:Oas.Guardrails.t ->
  ?hooks:Oas.Hooks.hooks ->
  ?memory:Oas.Memory.t ->
  ?raw_trace:Oas.Raw_trace.t ->
  ?on_event:(Oas.Types.sse_event -> unit) ->
  ?proof_ref:Oas.Cdal_proof.t option ref ->
  ?contract:Oas.Risk_contract.t ->
  ?transport:Masc_grpc_transport.t ->
  ?priority:Llm_provider.Request_priority.t ->
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  unit ->
  (run_result, string) result

val run_model_with_masc_tools :
  model_label:string ->
  goal:string ->
  ?system_prompt:string ->
  masc_tools:Types.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> bool * string) ->
  ?max_turns:int ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?guardrails:Oas.Guardrails.t ->
  ?hooks:Oas.Hooks.hooks ->
  ?memory:Oas.Memory.t ->
  ?enable_thinking:bool ->
  ?raw_trace:Oas.Raw_trace.t ->
  ?on_event:(Oas.Types.sse_event -> unit) ->
  ?transport:Masc_grpc_transport.t ->
  ?priority:Llm_provider.Request_priority.t ->
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  unit ->
  (run_result, string) result
