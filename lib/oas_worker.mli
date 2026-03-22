(** Oas_worker — Unified entry point for OAS-based MASC tool modules.

    Callers either pass a [cascade_name] string for configured fallback
    selection, a [model_label] string for {!run_model_by_label}, or an
    explicit {!Model_spec.model_spec} when the runtime must honor a
    concrete provider/model choice. Internal [config] / [build] / [run]
    are implementation details and not exported.

    Prefer {!run_named} (cascade) or {!run_model_by_label} (explicit model
    as string) over {!run_model} (requires Model_spec.model_spec).

    @since Phase 1 — MASC→OAS migration
    @since Phase 4 — public API restricted to named cascade functions
    @since Phase 5 — run_model_by_label added (string-based API)
    @since Phase 8 — Cascade module deleted, defaults moved here *)

module Oas = Agent_sdk

type run_result = {
  response : Oas.Types.api_response;
  checkpoint : Oas.Checkpoint.t option;
  session_id : string;
  turns : int;
  trace_ref : Oas.Raw_trace.run_ref option;
}

(** Locate config/cascade.json via CWD or ME_ROOT.
    Delegates to {!Model_spec.cascade_config_path}. *)
val default_config_path : unit -> string option

(** Return the default model string list for a given cascade name. *)
val default_model_strings : cascade_name:string -> string list

val run_named :
  cascade_name:string ->
  goal:string ->
  ?system_prompt:string ->
  ?tools:Oas.Tool.t list ->
  ?initial_messages:Oas.Types.message list ->
  ?max_turns:int ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?accept:(Oas_response.api_response -> bool) ->
  ?guardrails:Oas.Guardrails.t ->
  ?hooks:Oas.Hooks.hooks ->
  ?context_reducer:Oas.Context_reducer.t ->
  ?memory:Oas.Memory.t ->
  ?raw_trace:Oas.Raw_trace.t ->
  ?on_event:(Oas.Types.sse_event -> unit) ->
  ?agent_ref:Oas.Agent.t option ref ->
  unit ->
  (run_result, string) result

(** Run a single Agent.run() using a model label string (e.g. "llama:qwen3.5").
    Parses the label internally. Callers do not need Model_spec.model_spec. *)
val run_model_by_label :
  model_label:string ->
  goal:string ->
  ?system_prompt:string ->
  ?tools:Oas.Tool.t list ->
  ?max_turns:int ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?accept:(Oas_response.api_response -> bool) ->
  ?guardrails:Oas.Guardrails.t ->
  ?hooks:Oas.Hooks.hooks ->
  ?context_reducer:Oas.Context_reducer.t ->
  ?memory:Oas.Memory.t ->
  ?on_event:(Oas.Types.sse_event -> unit) ->
  unit ->
  (run_result, string) result

(** Run a single Agent.run() with an explicit Model_spec.model_spec.
    Prefer {!run_model_by_label} for new code. *)
val run_model :
  model_spec:Model_spec.model_spec ->
  goal:string ->
  ?system_prompt:string ->
  ?tools:Oas.Tool.t list ->
  ?max_turns:int ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?accept:(Oas_response.api_response -> bool) ->
  ?guardrails:Oas.Guardrails.t ->
  ?hooks:Oas.Hooks.hooks ->
  ?context_reducer:Oas.Context_reducer.t ->
  ?memory:Oas.Memory.t ->
  ?on_event:(Oas.Types.sse_event -> unit) ->
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
  unit ->
  (run_result, string) result

val run_model_with_masc_tools :
  model_spec:Model_spec.model_spec ->
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
  unit ->
  (run_result, string) result
