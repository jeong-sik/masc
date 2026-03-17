(** Bridge between MASC [Llm_types] and OAS [Llm_provider].

    Converts MASC {!Llm_types.completion_request} into
    {!Llm_provider.Provider_config.t} + {!Llm_provider.Types.message list},
    calls {!Llm_provider.Complete.complete}, and converts
    {!Llm_provider.Types.api_response} back to {!Llm_types.completion_response}.

    Replaces curl-subprocess calls in {!Llm_transport} with cohttp-eio
    via the shared OAS HTTP client.

    @since 2.103.0 — v0.49 transport replacement *)

open Printf
open Llm_types

(* ================================================================ *)
(* MASC message → Llm_provider.Types.message                       *)
(* ================================================================ *)

(** Convert a MASC message to an OAS Llm_provider message.
    Both use [Agent_sdk.Types.content_block list] for content after v0.47. *)
let provider_message_of_masc (m : Llm_types.message) : Llm_provider.Types.message =
  { role = m.role; content = m.content }

(** Extract system messages and return (system_prompt option, non-system messages). *)
let extract_system (msgs : Llm_types.message list) =
  let system_parts, rest =
    List.partition (fun (m : Llm_types.message) -> m.role = System) msgs
  in
  let system_prompt =
    match system_parts with
    | [] -> None
    | parts ->
        let text =
          parts
          |> List.map text_of_message
          |> String.concat "\n"
          |> String.trim
        in
        if text = "" then None else Some text
  in
  (system_prompt, rest)

(* ================================================================ *)
(* MASC tool_def → Yojson.Safe.t (provider-neutral format)         *)
(* ================================================================ *)

(** Convert a MASC tool_def to the raw JSON that Llm_provider expects.
    Includes both [input_schema] (Anthropic) and [parameters] (OpenAI)
    so both backend builders can find the schema. *)
let tool_def_to_json (td : tool_def) : Yojson.Safe.t =
  `Assoc [
    ("name", `String td.tool_name);
    ("description", `String td.tool_description);
    ("input_schema", td.parameters);
    ("parameters", td.parameters);
  ]

(* ================================================================ *)
(* MASC completion_request → Provider_config.t                     *)
(* ================================================================ *)

(** Build Provider_config from a MASC completion_request.
    Returns (config, provider_messages, provider_tools) or an error. *)
let provider_config_of_request (req : completion_request)
    : (Llm_provider.Provider_config.t
       * Llm_provider.Types.message list
       * Yojson.Safe.t list, string) result =
  let sanitized_messages = Llm_transport.sanitize_messages_utf8 req.messages in
  let system_prompt, non_system_msgs = extract_system sanitized_messages in
  let provider_messages =
    List.map provider_message_of_masc non_system_msgs
  in
  let provider_tools = List.map tool_def_to_json req.tools in
  let response_format_json = match req.response_format with
    | `Json -> true
    | `Text -> false
  in
  match req.model.provider with
  | Claude ->
      let api_key = Llm_transport.get_api_key req.model in
      if api_key = "" then Error "ANTHROPIC_API_KEY not set"
      else
        let config =
          Llm_provider.Provider_config.make
            ~kind:Anthropic
            ~model_id:req.model.model_id
            ~base_url:req.model.api_url
            ~api_key
            ~headers:[
              ("Content-Type", "application/json");
              ("x-api-key", api_key);
              ("anthropic-version", "2023-06-01");
            ]
            ~request_path:"/v1/messages"
            ~max_tokens:req.max_tokens
            ~temperature:req.temperature
            ?system_prompt
            ~response_format_json
            ()
        in
        Ok (config, provider_messages, provider_tools)

  | Llama ->
      let config =
        Llm_provider.Provider_config.make
          ~kind:OpenAI_compat
          ~model_id:req.model.model_id
          ~base_url:req.model.api_url
          ~request_path:"/v1/chat/completions"
          ~max_tokens:req.max_tokens
          ~temperature:req.temperature
          ?system_prompt
          ~response_format_json
          ()
      in
      Ok (config, provider_messages, provider_tools)

  | Gemini -> (
      match Llm_transport.resolve_openai_compatible_endpoint req.model with
      | Error e -> Error e
      | Ok (base_url, path, auth_headers) ->
          let headers = [("Content-Type", "application/json")] @ auth_headers in
          let config =
            Llm_provider.Provider_config.make
              ~kind:OpenAI_compat
              ~model_id:req.model.model_id
              ~base_url
              ~headers
              ~request_path:path
              ~max_tokens:req.max_tokens
              ~temperature:req.temperature
              ?system_prompt
              ~response_format_json
              ()
          in
          Ok (config, provider_messages, provider_tools))

  | OpenAI ->
      let api_key = Llm_transport.get_api_key req.model in
      if api_key = "" then Error "OPENAI_API_KEY not set"
      else
        let config =
          Llm_provider.Provider_config.make
            ~kind:OpenAI_compat
            ~model_id:req.model.model_id
            ~base_url:req.model.api_url
            ~api_key
            ~headers:[
              ("Content-Type", "application/json");
              ("Authorization", sprintf "Bearer %s" api_key);
            ]
            ~request_path:"/v1/chat/completions"
            ~max_tokens:req.max_tokens
            ~temperature:req.temperature
            ?system_prompt
            ~response_format_json
            ()
        in
        Ok (config, provider_messages, provider_tools)

  | OpenRouter ->
      let api_key = Llm_transport.get_api_key req.model in
      if api_key = "" then Error "OPENROUTER_API_KEY not set"
      else
        let config =
          Llm_provider.Provider_config.make
            ~kind:OpenAI_compat
            ~model_id:req.model.model_id
            ~base_url:req.model.api_url
            ~api_key
            ~headers:[
              ("Content-Type", "application/json");
              ("Authorization", sprintf "Bearer %s" api_key);
            ]
            ~request_path:"/v1/chat/completions"
            ~max_tokens:req.max_tokens
            ~temperature:req.temperature
            ?system_prompt
            ~response_format_json
            ()
        in
        Ok (config, provider_messages, provider_tools)

  | Glm_cloud ->
      let api_key = Llm_transport.get_api_key req.model in
      if api_key = "" then Error "ZAI_API_KEY not set"
      else
        let config =
          Llm_provider.Provider_config.make
            ~kind:OpenAI_compat
            ~model_id:req.model.model_id
            ~base_url:req.model.api_url
            ~api_key
            ~headers:[
              ("Content-Type", "application/json");
              ("Authorization", sprintf "Bearer %s" api_key);
            ]
            ~request_path:"/api/coding/paas/v4/chat/completions"
            ~max_tokens:req.max_tokens
            ~temperature:req.temperature
            ?system_prompt
            ~response_format_json
            ()
        in
        Ok (config, provider_messages, provider_tools)

  | Custom _ ->
      let auth_headers =
        match Llm_transport.get_api_key req.model with
        | "" -> []
        | api_key -> [("Authorization", sprintf "Bearer %s" api_key)]
      in
      let headers = [("Content-Type", "application/json")] @ auth_headers in
      let config =
        Llm_provider.Provider_config.make
          ~kind:OpenAI_compat
          ~model_id:req.model.model_id
          ~base_url:req.model.api_url
          ~headers
          ~request_path:"/v1/chat/completions"
          ~max_tokens:req.max_tokens
          ~temperature:req.temperature
          ?system_prompt
          ~response_format_json
          ()
      in
      Ok (config, provider_messages, provider_tools)

(* ================================================================ *)
(* Llm_provider.Types.api_response → MASC completion_response     *)
(* ================================================================ *)

(** Extract MASC tool_calls from content blocks. *)
let tool_calls_of_content (blocks : Llm_provider.Types.content_block list)
    : tool_call list =
  List.filter_map
    (function
      | Llm_provider.Types.ToolUse { id; name; input } ->
          Some
            {
              call_id = id;
              call_name = name;
              call_arguments = Yojson.Safe.to_string input;
            }
      | _ -> None)
    blocks

(** Convert OAS api_response to MASC completion_response. *)
let completion_response_of_api_response
    (resp : Llm_provider.Types.api_response) : completion_response =
  let tool_calls = tool_calls_of_content resp.content in
  let usage =
    match resp.usage with
    | Some u ->
        {
          input_tokens = u.input_tokens;
          output_tokens = u.output_tokens;
          total_tokens = u.input_tokens + u.output_tokens;
          cache_creation_input_tokens = u.cache_creation_input_tokens;
          cache_read_input_tokens = u.cache_read_input_tokens;
        }
    | None ->
        {
          input_tokens = 0;
          output_tokens = 0;
          total_tokens = 0;
          cache_creation_input_tokens = 0;
          cache_read_input_tokens = 0;
        }
  in
  {
    content = resp.content;
    tool_calls;
    usage;
    model_used = resp.model;
    latency_ms = 0;
  }

(* ================================================================ *)
(* Error conversion                                                *)
(* ================================================================ *)

let string_of_http_error = function
  | Llm_provider.Http_client.HttpError { code; body } ->
      let body_trunc =
        if String.length body > 200 then String.sub body 0 200 ^ "..."
        else body
      in
      sprintf "HTTP %d: %s" code body_trunc
  | Llm_provider.Http_client.NetworkError { message } ->
      sprintf "Network error: %s" message

(* ================================================================ *)
(* Public API: call                                                *)
(* ================================================================ *)

(** Execute an LLM completion using Llm_provider (cohttp-eio).
    Replaces curl-subprocess calls for all providers. *)
let call ?timeout_sec:_ (req : completion_request)
    : (completion_response, string) result =
  let req = normalize_request req in
  match provider_config_of_request req with
  | Error e -> Error e
  | Ok (config, messages, tools) -> (
      let env = Llm_eio_env.get () in
      Log.LlmClient.debug
        "provider-bridge req: model=%s provider=%s max_tokens=%d tools=%d"
        req.model.model_id
        (string_of_provider req.model.provider)
        req.max_tokens (List.length req.tools);
      match
        Llm_provider.Complete.complete ~sw:env.sw ~net:env.net ~config
          ~messages ~tools ()
      with
      | Ok resp ->
          let masc_resp = completion_response_of_api_response resp in
          let text = text_of_response masc_resp in
          if String.trim text = "" && masc_resp.tool_calls = [] then
            Error "Empty completion (no content or tool_calls)"
          else Ok masc_resp
      | Error http_err -> Error (string_of_http_error http_err))

(* ================================================================ *)
(* GLM Cloud pool dispatch                                          *)
(* ================================================================ *)

(** GLM Cloud call with pool-based load balancing.
    Uses Glm_pool.with_model to select best available model and track usage.
    Delegates the actual HTTP call to {!call}. *)
let call_glm_cloud_with_pool ?timeout_sec (req : completion_request)
    : (completion_response, string) result =
  let preferred_model =
    if Glm_pool.is_pool_model req.model.model_id then
      Some req.model.model_id
    else
      None
  in
  Glm_pool.with_model preferred_model (fun pool_model_id ->
    let modified_model = { req.model with model_id = pool_model_id } in
    let modified_req = { req with model = modified_model } in
    match call ?timeout_sec modified_req with
    | Ok resp -> Ok { resp with model_used = pool_model_id }
    | Error e -> Error e)
