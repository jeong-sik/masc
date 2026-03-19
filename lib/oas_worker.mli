(** Oas_worker — Unified entry point for OAS-based MASC tool modules.

    @since Phase 1 — MASC→OAS migration *)

module Oas = Agent_sdk

type config = {
  name : string;
  model_spec : Llm_types.model_spec;
  system_prompt : string;
  tools : Oas.Tool.t list;
  max_turns : int;
  max_tokens : int;
  temperature : float;
  hooks : Oas.Hooks.hooks option;
  guardrails : Oas.Guardrails.t option;
  event_bus : Oas.Event_bus.t option;
  checkpoint_dir : string option;
  session_id : string option;
  description : string option;
}

val default_config :
  name:string ->
  model_spec:Llm_types.model_spec ->
  system_prompt:string ->
  tools:Oas.Tool.t list ->
  config

type run_result = {
  response : Oas.Types.api_response;
  checkpoint : Oas.Checkpoint.t option;
  session_id : string;
  turns : int;
}

val build :
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  (Oas.Agent.t, string) result

val run :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  string ->
  (run_result, string) result

val run_with_masc_tools :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  masc_tools:Llm_types.tool_def list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> bool * string) ->
  string ->
  (run_result, string) result

(** Drop-in replacement for [Llm_orchestration.complete].
    Extracts model/messages/temperature/max_tokens from the request,
    resolves Eio context from globals, runs a single-turn OAS agent.
    Returns [api_response] directly for compatibility. *)
val complete :
  ?timeout_sec:int ->
  Llm_types.completion_request ->
  (Llm_types.api_response, string) result

(** Drop-in replacement for [Llm_orchestration.run_prompt_cascade].
    Tries each model spec in order via [complete]. *)
val prompt_cascade :
  ?temperature:float ->
  ?timeout_sec:int ->
  ?system:string ->
  model_specs:Llm_types.model_spec list ->
  max_tokens:int ->
  prompt:string ->
  unit ->
  (Llm_types.api_response, string) result
