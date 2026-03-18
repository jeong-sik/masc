(** Provider dispatch — config build, HTTP execution.

    Converts MASC {!Llm_types.completion_request} to OAS
    {!Llm_provider.Provider_config.t} and calls
    {!Llm_provider.Complete.complete}. Returns OAS
    {!Llm_provider.Types.api_response} directly.

    @since 2.107.0 *)

open Printf
open Llm_types

(* ================================================================ *)
(* API Key & Endpoint Resolution                                    *)
(* ================================================================ *)

let get_api_key (spec : model_spec) : string =
  match spec.api_key_env with
  | Some env_var -> Sys.getenv_opt env_var |> Option.value ~default:""
  | None -> ""

let fetch_vertex_adc_access_token () =
  let manual_override =
    Sys.getenv_opt "MASC_VERTEX_ACCESS_TOKEN"
    |> Option.value ~default:"" |> String.trim
  in
  if manual_override <> "" then Ok manual_override
  else
    let status, output =
      Process_eio.run_argv_with_status
        ~timeout_sec:Env_config_runtime.Timeout.gcloud_auth_sec
        [ "gcloud"; "auth"; "application-default"; "print-access-token" ]
    in
    match status with
    | Unix.WEXITED 0 ->
        let token = String.trim output in
        if token = "" then
          Error "Gemini Vertex ADC unavailable; run gcloud auth application-default login"
        else Ok token
    | _ ->
        Error "Gemini Vertex ADC unavailable; run gcloud auth application-default login"

let resolve_openai_compatible_endpoint (spec : model_spec) =
  match spec.provider with
  | Gemini -> (
      match Provider_adapter.resolve_gemini_direct_auth () with
      | Provider_adapter.Gemini_vertex_adc { project; location } -> (
          match fetch_vertex_adc_access_token () with
          | Ok access_token ->
              Ok
                ( Provider_adapter.gemini_vertex_openai_base_url ~project ~location,
                  "/chat/completions",
                  [ ("Authorization", sprintf "Bearer %s" access_token) ] )
          | Error _ as e -> e)
      | Provider_adapter.Gemini_api_key ->
          let api_key = get_api_key spec in
          if api_key = "" then
            Error
              "Gemini auth unavailable; set GOOGLE_CLOUD_PROJECT for Vertex ADC or GEMINI_API_KEY"
          else
            Ok
              ( spec.api_url,
                "/v1beta/openai/chat/completions",
                [ ("Authorization", sprintf "Bearer %s" api_key) ] )
      | Provider_adapter.Gemini_auth_missing message -> Error message)
  | OpenAI ->
      let api_key = get_api_key spec in
      if api_key = "" then Error "OPENAI_API_KEY not set"
      else
        Ok
          ( spec.api_url,
            "/v1/chat/completions",
            [ ("Authorization", sprintf "Bearer %s" api_key) ] )
  | Glm_cloud ->
      let api_key = get_api_key spec in
      if api_key = "" then Error "ZAI_API_KEY not set"
      else
        Ok
          ( spec.api_url,
            "/api/coding/paas/v4/chat/completions",
            [ ("Authorization", sprintf "Bearer %s" api_key) ] )
  | OpenRouter ->
      let api_key = get_api_key spec in
      if api_key = "" then Error "OPENROUTER_API_KEY not set"
      else
        Ok
          ( spec.api_url,
            "/v1/chat/completions",
            [ ("Authorization", sprintf "Bearer %s" api_key) ] )
  | Claude ->
      Error "Claude uses Anthropic provider via provider_config_of_request"
  | Llama -> Ok (spec.api_url, "/v1/chat/completions", [])
  | Custom _ ->
      let auth_headers =
        match get_api_key spec with
        | "" -> []
        | api_key -> [ ("Authorization", sprintf "Bearer %s" api_key) ]
      in
      Ok (spec.api_url, "/v1/chat/completions", auth_headers)

(* ================================================================ *)
(* MASC message/tool → OAS types                                    *)
(* ================================================================ *)

let provider_message_of_masc (m : Llm_types.message) : Llm_provider.Types.message =
  { role = m.role; content = m.content }

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

let tool_def_to_json (td : tool_def) : Yojson.Safe.t =
  `Assoc [
    ("name", `String td.tool_name);
    ("description", `String td.tool_description);
    ("input_schema", td.parameters);
    ("parameters", td.parameters);
  ]

(* ================================================================ *)
(* completion_request → Provider_config.t                           *)
(* ================================================================ *)

let provider_config_of_request (req : completion_request)
    : (Llm_provider.Provider_config.t
       * Llm_provider.Types.message list
       * Yojson.Safe.t list, string) result =
  let sanitized_messages = sanitize_messages_utf8 req.messages in
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
      let api_key = get_api_key req.model in
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
      match resolve_openai_compatible_endpoint req.model with
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
      let api_key = get_api_key req.model in
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
      let api_key = get_api_key req.model in
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
      let api_key = get_api_key req.model in
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
        match get_api_key req.model with
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
(* Response helpers                                                 *)
(* ================================================================ *)

(* ================================================================ *)
(* Error conversion                                                 *)
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
(* Public: call_provider + GLM pool dispatch                        *)
(* ================================================================ *)

let call_provider ?timeout_sec:_ ?cache ?metrics (req : completion_request)
    : (Llm_provider.Types.api_response, string) result =
  let req = normalize_request req in
  match provider_config_of_request req with
  | Error e -> Error e
  | Ok (config, messages, tools) -> (
      let env = Llm_eio_env.get () in
      Log.LlmClient.debug
        "provider req: model=%s provider=%s max_tokens=%d tools=%d"
        req.model.model_id
        (string_of_provider req.model.provider)
        req.max_tokens (List.length req.tools);
      let result = match env.clock with
        | Some clock ->
            Llm_provider.Complete.complete_with_retry
              ~sw:env.sw ~net:env.net ~clock ~config
              ~messages ~tools ?cache ?metrics ()
        | None ->
            Llm_provider.Complete.complete
              ~sw:env.sw ~net:env.net ~config
              ~messages ~tools ?cache ?metrics ()
      in
      match result with
      | Ok resp ->
          let text = Agent_sdk.Types.text_of_content resp.content in
          if String.trim text = "" && not (Llm_types.has_tool_calls resp) then
            Error "Empty completion (no content or tool_calls)"
          else Ok resp
      | Error http_err -> Error (string_of_http_error http_err))

let call_glm_cloud_with_pool ?timeout_sec ?cache ?metrics
    (req : completion_request) : (Llm_provider.Types.api_response, string) result =
  let preferred_model =
    if Glm_pool.is_pool_model req.model.model_id then
      Some req.model.model_id
    else
      None
  in
  Glm_pool.with_model preferred_model (fun pool_model_id ->
    let modified_model = { req.model with model_id = pool_model_id } in
    let modified_req = { req with model = modified_model } in
    match call_provider ?timeout_sec ?cache ?metrics modified_req with
    | Ok resp -> Ok { resp with model = pool_model_id }
    | Error e -> Error e)

(* OAS Type Adapters *)

let to_oas_provider (spec : model_spec) : Agent_sdk.Provider.config option =
  match spec.provider with
  | Claude ->
    Some { Agent_sdk.Provider.provider = Anthropic;
           model_id = spec.model_id;
           api_key_env = Option.value ~default:"ANTHROPIC_API_KEY" spec.api_key_env }
  | Llama ->
    Some { provider = Local { base_url = spec.api_url };
           model_id = spec.model_id; api_key_env = "" }
  | Glm_cloud | OpenAI | OpenRouter ->
    Some { provider = OpenAICompat { base_url = spec.api_url; auth_header = None;
             path = "/v1/chat/completions"; static_token = None };
           model_id = spec.model_id;
           api_key_env = Option.value ~default:"" spec.api_key_env }
  | Gemini ->
    Some { provider = OpenAICompat { base_url = spec.api_url; auth_header = None;
             path = "/v1beta/chat/completions"; static_token = None };
           model_id = spec.model_id;
           api_key_env = Option.value ~default:"GEMINI_API_KEY" spec.api_key_env }
  | Custom _ ->
    Some { provider = OpenAICompat { base_url = spec.api_url; auth_header = None;
             path = "/v1/chat/completions"; static_token = None };
           model_id = spec.model_id;
           api_key_env = Option.value ~default:"" spec.api_key_env }

let to_oas_message (m : message) : Agent_sdk.Types.message option =
  match m.role with System -> None | _ -> Some m

let of_oas_message (m : Agent_sdk.Types.message) : message = m
let of_oas_usage (u : Agent_sdk.Types.api_usage) : token_usage = u
let to_oas_usage (u : token_usage) : Agent_sdk.Types.api_usage = u
