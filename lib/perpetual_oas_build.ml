(** Perpetual_oas_build — OAS Agent.t builder for perpetual execution.

    Extracted from [perpetual_oas.ml]. Ties together all phase adapters
    (context reducer, checkpoint, LLM provider, verifier, builder) to
    construct an OAS Agent.t configured for perpetual operation.

    Dependencies: [Perpetual_oas_state], [Perpetual_oas_hooks],
    [Llm_client], [Tool_bridge], OAS Builder.

    @since 2.111.0 — H2 God File split *)

open Printf

module Oas = Agent_sdk

(** Construct an OAS Agent.t configured for perpetual execution.

    Ties together all phase adapters:
    - Phase 1: context reducer strategies
    - Phase 2: checkpoint config
    - Phase 3: LLM provider mapping
    - Phase 4: verifier hook / guardrails
    - Phase 5: builder pattern

    @param config The perpetual loop configuration.
    @param pstate Mutable state for hook closures.
    @param emit Event emitter.
    @param ctx_ref Current working context ref.
    @param net Eio network capability.
    @return Agent.t configured for perpetual operation, or error. *)
let build_perpetual_agent
    ~(config : Perpetual_loop.loop_config)
    ~(pstate : Perpetual_oas_state.perpetual_state)
    ~(emit : Perpetual_loop.event -> unit)
    ~(ctx_ref : Context_manager.working_context ref)
    ~(net : [> `Generic | `Unix ] Eio.Net.ty Eio.Resource.t)
  : (Oas.Agent.t, string) result =
  (* Resolve OAS model from primary cascade model *)
  let primary_model = match config.model_cascade with
    | m :: _ -> m
    | [] -> Llm_client.default_local_model_spec ()
  in
  let oas_model = Oas.Types.Custom primary_model.model_id in
  (* Build provider via Phase 3 adapter.
     Uses Llm_client.to_oas_provider which handles the Llm_client.model_spec
     -> Oas.Provider.config conversion (avoiding Llm_types nominality gap). *)
  let provider = match Llm_client.to_oas_provider primary_model with
    | Some cfg -> cfg
    | None ->
      (* Fallback for Custom providers — use OpenAICompat *)
      { Oas.Provider.provider =
          Oas.Provider.OpenAICompat {
            base_url = primary_model.api_url;
            auth_header = None;
            path = "/v1/chat/completions";
            static_token = None;
          };
        model_id = primary_model.model_id;
        api_key_env = Option.value ~default:"" primary_model.api_key_env;
      }
  in
  (* Hooks: perpetual lifecycle + Phase 4 verifier *)
  let hooks = Perpetual_oas_hooks.perpetual_hooks ~config ~pstate ~emit ~ctx_ref in
  (* Heartbeat callback *)
  let periodic_cbs =
    Perpetual_oas_hooks.perpetual_periodic_callbacks ~config ~pstate ~emit ~ctx_ref
  in
  (* Guardrails via Phase 4 adapter *)
  let guardrails =
    Verifier_oas.guardrails_with_read_only_tag
      ~max_tool_calls_per_turn:12 ()
  in
  (* Convert MASC tool_defs to OAS Tool.t list.
     Tool_bridge.oas_tool_of_masc creates OAS Tool.t from name/desc/schema/handler.
     For the perpetual loop adapter, each tool delegates to a no-op handler since
     actual tool dispatch remains in MASC's perpetual_loop infrastructure. *)
  let tools = List.map (fun (td : Llm_client.tool_def) ->
    Tool_bridge.oas_tool_of_masc
      ~name:td.tool_name
      ~description:td.tool_description
      ~input_schema:td.parameters
      (fun _input ->
        (true, "[perpetual_oas] Tool dispatch delegated to MASC infrastructure"))
  ) config.tools in
  let tool_names =
    List.map (fun (t : Oas.Tool.t) -> t.schema.name) tools
  in
  let system_prompt = (!ctx_ref).system_prompt in
  (* Use max_turns as a reasonable upper bound per generation.
     Perpetual loop handles multi-generation externally. *)
  let max_turns = 100 in
  let builder =
    Oas.Builder.create ~net ~model:oas_model
    |> Oas.Builder.with_name config.agent_name
    |> Oas.Builder.with_system_prompt system_prompt
    |> Oas.Builder.with_max_tokens 4096
    |> Oas.Builder.with_max_turns max_turns
    |> Oas.Builder.with_temperature 0.7
    |> Oas.Builder.with_provider provider
    |> Oas.Builder.with_tools tools
    |> Oas.Builder.with_hooks hooks
    |> Oas.Builder.with_guardrails { guardrails with
      tool_filter =
        if tool_names <> [] then
          Oas.Guardrails.AllowList tool_names
        else
          Oas.Guardrails.AllowAll }
    |> Oas.Builder.with_periodic_callbacks periodic_cbs
    |> Oas.Builder.with_description
         (sprintf "Perpetual agent (gen %d, trace %s)"
           pstate.generation pstate.trace_id)
  in
  Oas.Builder.build_safe builder
  |> Result.map_error Oas.Error.to_string
