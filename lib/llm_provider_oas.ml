(** OAS LLM Provider adapter — bridges MASC LLM types to OAS Provider layer.

    All LLM calls route through OAS {!Agent_sdk.Provider.config} and
    {!Agent_sdk.Provider.cascade} types via {!Llm_provider_bridge}.

    All types used here are from {!Llm_types} (the canonical type source
    shared by {!Llm_provider_bridge}).

    @since 2.104.0 — Phase 3 OAS integration *)

open Printf
open Llm_types

(* ================================================================ *)
(* model_spec → Agent_sdk.Provider.config                           *)
(* ================================================================ *)

(** Convert a MASC {!model_spec} to an OAS {!Agent_sdk.Provider.config}.
    Maps MASC provider variants to OAS provider constructors.
    Returns [None] for [Custom] providers that have no OAS equivalent.

    Inlined from the equivalent logic in [Llm_client.to_oas_provider]
    to avoid type incompatibility between [Llm_types.model_spec] and
    [Llm_client.model_spec] (nominally distinct due to .mli re-declaration). *)
let provider_config_of_model_spec (spec : model_spec)
    : Agent_sdk.Provider.config option =
  match spec.provider with
  | Claude ->
      Some {
        Agent_sdk.Provider.provider = Agent_sdk.Provider.Anthropic;
        model_id = spec.model_id;
        api_key_env =
          Option.value ~default:"ANTHROPIC_API_KEY" spec.api_key_env;
      }
  | Llama ->
      Some {
        Agent_sdk.Provider.provider =
          Agent_sdk.Provider.Local { base_url = spec.api_url };
        model_id = spec.model_id;
        api_key_env = "";
      }
  | Glm_cloud | OpenAI | OpenRouter ->
      Some {
        Agent_sdk.Provider.provider =
          Agent_sdk.Provider.OpenAICompat {
            base_url = spec.api_url;
            auth_header = None;
            path = "/v1/chat/completions";
            static_token = None;
          };
        model_id = spec.model_id;
        api_key_env = Option.value ~default:"" spec.api_key_env;
      }
  | Gemini ->
      Some {
        Agent_sdk.Provider.provider =
          Agent_sdk.Provider.OpenAICompat {
            base_url = spec.api_url;
            auth_header = None;
            path = "/v1beta/chat/completions";
            static_token = None;
          };
        model_id = spec.model_id;
        api_key_env =
          Option.value ~default:"GEMINI_API_KEY" spec.api_key_env;
      }
  | Custom _ -> None

(* ================================================================ *)
(* complete_via_oas — single completion through OAS                 *)
(* ================================================================ *)

(** Execute a single LLM completion using the OAS provider path.
    Converts MASC {!completion_request} to OAS types, calls
    {!Llm_provider.Complete.complete}, and converts the response back
    to MASC {!completion_response}.

    Delegates to {!Llm_provider_bridge.provider_config_of_request} for
    the actual provider config construction (API key resolution,
    endpoint discovery) and to
    {!Llm_provider_bridge.completion_response_of_api_response} for
    response conversion. *)
let complete_via_oas ?timeout_sec:_ (req : completion_request)
    : (completion_response, string) result =
  let req = normalize_request req in
  match Llm_provider_bridge.provider_config_of_request req with
  | Error e -> Error e
  | Ok (config, messages, tools) -> (
      let env = Llm_eio_env.get () in
      Log.LlmClient.debug
        "oas-adapter: complete model=%s provider=%s max_tokens=%d tools=%d"
        req.model.model_id
        (string_of_provider req.model.provider)
        req.max_tokens (List.length req.tools);
      match
        Llm_provider.Complete.complete ~sw:env.sw ~net:env.net ~config
          ~messages ~tools ()
      with
      | Ok resp ->
          let masc_resp =
            Llm_provider_bridge.completion_response_of_api_response resp
          in
          let text = text_of_response masc_resp in
          if String.trim text = "" && masc_resp.tool_calls = [] then
            Error "Empty completion (no content or tool_calls)"
          else Ok masc_resp
      | Error http_err ->
          Error (Llm_provider_bridge.string_of_http_error http_err))

(* ================================================================ *)
(* cascade_complete — multi-model failover via OAS cascade          *)
(* ================================================================ *)

(** Build an OAS {!Agent_sdk.Provider.cascade} from a list of MASC
    model specs. The first spec becomes [primary], the rest become
    [fallbacks]. Returns [Error] if the list is empty or if the
    primary model spec cannot be converted to an OAS config. *)
let build_oas_cascade (specs : model_spec list)
    : (Agent_sdk.Provider.cascade, string) result =
  match specs with
  | [] -> Error "cascade_complete: no model specs provided"
  | primary_spec :: fallback_specs ->
      (match provider_config_of_model_spec primary_spec with
       | None ->
           Error
             (sprintf
                "cascade_complete: cannot convert primary model %s to OAS config"
                primary_spec.model_id)
       | Some primary ->
           let fallbacks =
             List.filter_map provider_config_of_model_spec fallback_specs
           in
           Ok (Agent_sdk.Provider.cascade ~primary ~fallbacks))

(** Try models in cascade order using OAS provider path.
    Each model is tried via {!complete_via_oas}; on failure,
    the next model in the cascade is attempted.

    Concurrency control is NOT applied here.
    Callers who need concurrency limiting should wrap this call.

    @param accept Optional response validator. If a response is
    obtained but [accept] returns [false], the next model is tried.
    @param timeout_sec Optional overall deadline for the cascade. *)
let cascade_complete ?(accept = fun _ -> true) ?timeout_sec
    (requests : completion_request list)
    : (completion_response, string) result =
  let deadline_opt =
    Option.map
      (fun sec -> Time_compat.now () +. float_of_int sec)
      timeout_sec
  in
  let remaining_timeout_sec () =
    match deadline_opt with
    | None -> None
    | Some deadline ->
        let remaining =
          int_of_float (Float.ceil (deadline -. Time_compat.now ()))
        in
        Some (max 0 remaining)
  in
  let rec try_next errors = function
    | [] ->
        let all_errors = String.concat "; " (List.rev errors) in
        Error (sprintf "All models failed (OAS cascade): %s" all_errors)
    | _ when Option.value ~default:1 (remaining_timeout_sec ()) <= 0 ->
        let all_errors =
          String.concat "; "
            (List.rev ("oas cascade deadline exceeded" :: errors))
        in
        Error (sprintf "All models failed (OAS cascade): %s" all_errors)
    | req :: rest ->
        Log.LlmClient.debug "oas-cascade: trying %s (%s)"
          req.model.model_id (string_of_provider req.model.provider);
        let attempt_result =
          match remaining_timeout_sec () with
          | None -> complete_via_oas req
          | Some sec when sec > 0 ->
              complete_via_oas ~timeout_sec:sec req
          | Some _ -> Error "oas cascade deadline exceeded"
        in
        (match attempt_result with
         | Ok resp ->
             if accept resp then (
               Log.LlmClient.info
                 "oas-cascade: success with %s (%dms)"
                 resp.model_used resp.latency_ms;
               Ok resp)
             else (
               Log.LlmClient.warn
                 "oas-cascade: %s rejected by validator, continuing"
                 resp.model_used;
               try_next ("response rejected by validator" :: errors) rest)
         | Error e ->
             Log.LlmClient.warn "oas-cascade: %s failed: %s"
               req.model.model_id e;
             try_next (e :: errors) rest)
  in
  try_next [] requests

(* ================================================================ *)
(* Unified entry points                                             *)
(* ================================================================ *)

(** Single completion through OAS provider path. *)
let complete ?timeout_sec (req : completion_request)
    : (completion_response, string) result =
  complete_via_oas ?timeout_sec req

(** Cascade completion through OAS provider path. *)
let cascade ?(accept = fun _ -> true) ?timeout_sec
    (requests : completion_request list)
    : (completion_response, string) result =
  cascade_complete ~accept ?timeout_sec requests

(** Convenience: cascade from model_specs + prompt via OAS. *)
let run_prompt_cascade ?(temperature = 0.7) ?timeout_sec
    ?(accept = fun _ -> true) ?system ~model_specs ~max_tokens
    ~prompt () : (completion_response, string) result =
  let msgs =
    match system with
    | Some s -> [ system_msg s; user_msg prompt ]
    | None -> [ user_msg prompt ]
  in
  let requests =
    List.map
      (fun (model : model_spec) ->
        ({ model; messages = msgs; temperature;
           max_tokens; tools = []; response_format = `Text }
          : completion_request))
      model_specs
  in
  cascade_complete ~accept ?timeout_sec requests

(** Summary of OAS-convertible model specs for diagnostics. *)
let supported_providers_summary () : string =
  "Supported provider mappings: \
   Claude->Anthropic, Llama->Local, \
   Glm_cloud/OpenAI/OpenRouter->OpenAICompat, \
   Gemini->OpenAICompat(/v1beta). \
   Custom providers are not supported via OAS path."
