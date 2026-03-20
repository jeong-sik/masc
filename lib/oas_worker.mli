(** Oas_worker — Unified entry point for OAS-based MASC tool modules.

    Callers pass a [cascade_name] string; model resolution is handled
    internally via {!default_model_strings} and
    [Llm_provider.Cascade_config].  Internal [config] / [build] / [run]
    are implementation details and not exported.

    Single-shot calls use {!complete_single}.  Multi-turn agent loops
    use {!run_named} or {!run_named_with_masc_tools}.

    Cascade profile defaults and config path resolution are now hosted
    directly in this module (moved from the deleted [Cascade] module).

    @since Phase 1 — MASC→OAS migration
    @since Phase 4 — public API restricted to named cascade functions
    @since Phase 5 — complete_single moved here from Cascade
    @since Phase 8 — Cascade module deleted, defaults moved here *)

module Oas = Agent_sdk

type run_result = {
  response : Oas.Types.api_response;
  checkpoint : Oas.Checkpoint.t option;
  session_id : string;
  turns : int;
}

(** Locate config/cascade.json via CWD or ME_ROOT. *)
val default_config_path : unit -> string option

(** Return the default model string list for a given cascade name. *)
val default_model_strings : cascade_name:string -> string list

(** Single-shot LLM call via cascade policy.
    Returns OAS [api_response] directly; error formatted as string. *)
val complete_single :
  cascade_name:string ->
  messages:Oas.Types.message list ->
  ?config_path:string ->
  ?temperature:float ->
  ?timeout_sec:int ->
  ?max_tokens:int ->
  ?accept:(Llm_provider.Types.api_response -> bool) ->
  ?tools:Yojson.Safe.t list ->
  unit ->
  (Llm_provider.Types.api_response, string) result

val run_named :
  cascade_name:string ->
  goal:string ->
  ?system_prompt:string ->
  ?tools:Oas.Tool.t list ->
  ?max_turns:int ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?accept:(Llm_provider.Types.api_response -> bool) ->
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
  ?on_event:(Oas.Types.sse_event -> unit) ->
  unit ->
  (run_result, string) result
