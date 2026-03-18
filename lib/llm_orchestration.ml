(** Llm_orchestration — Concurrency control, response caching, and cascade logic for LLM calls. *)

open Printf
open Llm_types

(* ================================================================ *)
(* Concurrency limiter — throttle simultaneous LLM requests          *)
(* ================================================================ *)

(** Maximum concurrent cascade/LLM calls.
    Default 2 is conservative for local llama.cpp runtimes on 128GB hosts. *)
let max_concurrent_llm =
  int_of_env_default "MASC_MAX_CONCURRENT_LLM" ~default:2 ~min_v:1 ~max_v:128

let llm_semaphore = Eio.Semaphore.make max_concurrent_llm

let llm_semaphore_available () = Eio.Semaphore.get_value llm_semaphore

(** Outstanding permit counter for diagnostics.
    Tracks how many LLM calls are currently holding a permit. *)
let permits_outstanding = Atomic.make 0

let [@warning "-32"] permits_outstanding_count () = Atomic.get permits_outstanding

(** Eio-safe permit acquisition: explicit try/with ensures release on any
    exception including Eio.Cancel.Cancelled.
    Also tracks outstanding permits via Atomic counter for diagnostics. *)
let with_llm_permit f =
  Eio.Semaphore.acquire llm_semaphore;
  Atomic.incr permits_outstanding;
  match f () with
  | result ->
      Atomic.decr permits_outstanding;
      Eio.Semaphore.release llm_semaphore;
      result
  | exception exn ->
      Atomic.decr permits_outstanding;
      Eio.Semaphore.release llm_semaphore;
      raise exn

let llm_permits_in_use () =
  max_concurrent_llm - Eio.Semaphore.get_value llm_semaphore

(* ================================================================ *)
(* Response cache helpers                                            *)
(* ================================================================ *)

let completion_cache_schema_version = "1.0.0"

let response_format_to_string = function
  | `Text -> "text"
  | `Json -> "json"

let message_fingerprint_json (m : message) : Yojson.Safe.t =
  let m = sanitize_message_utf8 m in
  `Assoc
    [
      ("role", `String (string_of_role m.role));
      ("content", `String (text_of_message m));
    ]

let completion_request_fingerprint_json (req : completion_request) : Yojson.Safe.t =
  let req = normalize_request req in
  `Assoc
    [
      ("schema_version", `String completion_cache_schema_version);
      ("provider", `String (string_of_provider req.model.provider));
      ("model_id", `String req.model.model_id);
      ("response_format", `String (response_format_to_string req.response_format));
      ("temperature", `Float req.temperature);
      ("max_tokens", `Int req.max_tokens);
      ("messages", `List (List.map message_fingerprint_json req.messages));
    ]

let completion_cache_key (req : completion_request) =
  let canonical = Yojson.Safe.to_string (completion_request_fingerprint_json req) in
  Llm_response_cache.make_key ~namespace:"llmresp" ~content:canonical

let cache_key_of_request = completion_cache_key

let token_usage_to_json (u : token_usage) : Yojson.Safe.t =
  `Assoc
    [
      ("input_tokens", `Int u.input_tokens);
      ("output_tokens", `Int u.output_tokens);
      ("total_tokens", `Int (Llm_types.total_tokens u));
      ("cache_creation_input_tokens", `Int u.cache_creation_input_tokens);
      ("cache_read_input_tokens", `Int u.cache_read_input_tokens);
    ]

let token_usage_of_json (json : Yojson.Safe.t) : (token_usage, string) result =
  let open Yojson.Safe.Util in
  try
    Ok
      { Agent_sdk.Types.input_tokens = json |> member "input_tokens" |> to_int;
        output_tokens = json |> member "output_tokens" |> to_int;
        cache_creation_input_tokens =
          json |> member "cache_creation_input_tokens" |> to_int;
        cache_read_input_tokens = json |> member "cache_read_input_tokens" |> to_int;
      }
  with exn -> Error (Printexc.to_string exn)

let tool_call_to_json (tc : tool_call) : Yojson.Safe.t =
  `Assoc
    [
      ("call_id", `String tc.call_id);
      ("call_name", `String tc.call_name);
      ("call_arguments", `String tc.call_arguments);
    ]

let tool_call_of_json (json : Yojson.Safe.t) : (tool_call, string) result =
  let open Yojson.Safe.Util in
  try
    Ok
      {
        call_id = json |> member "call_id" |> to_string;
        call_name = json |> member "call_name" |> to_string;
        call_arguments = json |> member "call_arguments" |> to_string;
      }
  with exn -> Error (Printexc.to_string exn)

let completion_response_to_cache_json (resp : completion_response) : Yojson.Safe.t =
  `Assoc
    [
      ("schema_version", `String completion_cache_schema_version);
      ("kind", `String "completion_response");
      ( "response",
        `Assoc
          [
            ("content", `String (text_of_response resp));
            ("tool_calls", `List (List.map tool_call_to_json resp.tool_calls));
            ("usage", token_usage_to_json resp.usage);
            ("model_used", `String resp.model_used);
          ] );
    ]

let completion_response_of_cache_json
    (json : Yojson.Safe.t) : (completion_response, string) result =
  let open Yojson.Safe.Util in
  try
    let schema_version = json |> member "schema_version" |> to_string in
    if not (String.equal schema_version completion_cache_schema_version) then
      Error
        (Printf.sprintf "schema mismatch: expected=%s actual=%s"
           completion_cache_schema_version schema_version)
    else
      let kind = json |> member "kind" |> to_string in
      if not (String.equal kind "completion_response") then
        Error (Printf.sprintf "unexpected cache kind: %s" kind)
      else
        let body = json |> member "response" in
        let usage_json = body |> member "usage" in
        let usage = token_usage_of_json usage_json in
        let tool_calls =
          body |> member "tool_calls" |> to_list
          |> List.map tool_call_of_json
        in
        let tool_calls =
          List.fold_right
            (fun item acc ->
              match (item, acc) with
              | Ok tc, Ok xs -> Ok (tc :: xs)
              | Error e, _ -> Error e
              | _, Error e -> Error e)
            tool_calls (Ok [])
        in
        (match usage, tool_calls with
        | Ok usage, Ok tool_calls ->
            Ok
              {
                content = [Agent_sdk.Types.Text (body |> member "content" |> to_string)];
                tool_calls;
                usage;
                model_used = body |> member "model_used" |> to_string;
                latency_ms = 0;
              }
        | Error e, _ -> Error e
        | _, Error e -> Error e)
  with exn -> Error (Printexc.to_string exn)

let prompt_char_count (req : completion_request) =
  List.fold_left (fun acc (m : message) -> acc + String.length (text_of_message m)) 0
    req.messages

let request_has_tool_role_message (req : completion_request) =
  List.exists (fun (m : message) -> m.role = Tool) req.messages

let cache_bypass_reason (req : completion_request) : string option =
  if not Env_config.Llm.cache_enabled then
    Some "disabled"
  else if req.tools <> [] then
    Some "tools_present"
  else if request_has_tool_role_message req then
    Some "tool_role_message"
  else if req.temperature > Env_config.Llm.cache_max_temperature then
    Some "temperature"
  else if prompt_char_count req > Env_config.Llm.cache_max_prompt_chars then
    Some "prompt_too_large"
  else
    None

let record_cache_bypass reason =
  Prometheus.inc_counter "masc_llm_cache_bypass_total" ();
  Prometheus.inc_counter "masc_llm_cache_bypass_total"
    ~labels:[ ("reason", reason) ] ()

(* ================================================================ *)
(* Provider Bridge — config build, HTTP execution, response map     *)
(* Inlined from llm_provider_bridge.ml (deleted in this migration)  *)
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

(** Convert a MASC message to an OAS provider message.
    Both use Agent_sdk.Types.content_block list after v0.47 type convergence. *)
let provider_message_of_masc (m : Llm_types.message) : Llm_provider.Types.message =
  { role = m.role; content = m.content }

(** Extract system messages; returns (system_prompt option, non-system messages). *)
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

(** Convert a MASC tool_def to JSON for OAS provider.
    Includes both input_schema (Anthropic) and parameters (OpenAI). *)
let tool_def_to_json (td : tool_def) : Yojson.Safe.t =
  `Assoc [
    ("name", `String td.tool_name);
    ("description", `String td.tool_description);
    ("input_schema", td.parameters);
    ("parameters", td.parameters);
  ]

(** Build Provider_config from a MASC completion_request. *)
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

(** Extract MASC tool_calls from OAS content blocks. *)
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
  let usage : Llm_types.token_usage =
    match resp.usage with
    | Some u -> u
    | None ->
        { Agent_sdk.Types.input_tokens = 0;
          output_tokens = 0;
          cache_creation_input_tokens = 0;
          cache_read_input_tokens = 0 }
  in
  {
    content = resp.content;
    tool_calls;
    usage;
    model_used = resp.model;
    latency_ms = 0;
  }

let string_of_http_error = function
  | Llm_provider.Http_client.HttpError { code; body } ->
      let body_trunc =
        if String.length body > 200 then String.sub body 0 200 ^ "..."
        else body
      in
      sprintf "HTTP %d: %s" code body_trunc
  | Llm_provider.Http_client.NetworkError { message } ->
      sprintf "Network error: %s" message

(** Execute an LLM completion using OAS provider path.
    Calls {!Llm_provider.Complete.complete_with_retry} when a clock is
    available (server runtime), falls back to bare {!complete} otherwise. *)
let call_provider ?timeout_sec:_ ?cache ?metrics (req : completion_request)
    : (completion_response, string) result =
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
          let masc_resp = completion_response_of_api_response resp in
          let text = text_of_response masc_resp in
          if String.trim text = "" && masc_resp.tool_calls = [] then
            Error "Empty completion (no content or tool_calls)"
          else Ok masc_resp
      | Error http_err -> Error (string_of_http_error http_err))

(** GLM Cloud call with pool-based load balancing.
    Uses Glm_pool.with_model to select best available model and track usage. *)
let call_glm_cloud_with_pool ?timeout_sec ?cache ?metrics
    (req : completion_request) : (completion_response, string) result =
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
    | Ok resp -> Ok { resp with model_used = pool_model_id }
    | Error e -> Error e)

(* ================================================================ *)
(* Core: complete                                                   *)
(* ================================================================ *)

(** Single completion with MASC-level cache check/write and OAS metrics.
    Cache remains at MASC layer (format/key compatibility with existing data).
    Metrics are forwarded to OAS Complete via {!Llm_oas_adapters}. *)
let complete ?timeout_sec (req : completion_request) : (completion_response, string) result =
  let t0 = Time_compat.now () in
  let req = normalize_request req in
  let cache_key =
    match cache_bypass_reason req with
    | Some reason ->
        record_cache_bypass reason;
        None
    | None -> Some (completion_cache_key req)
  in
  let cached_result =
    match cache_key with
    | None -> None
    | Some key -> (
        match Llm_response_cache.get_json ~key with
        | Ok (Some cached_json) -> (
            match completion_response_of_cache_json cached_json with
            | Ok resp ->
                Prometheus.inc_counter "masc_llm_cache_hits_total" ();
                Some (Ok resp)
            | Error e ->
                Prometheus.inc_counter "masc_llm_cache_errors_total" ();
                let _ = Llm_response_cache.delete ~key in
                Log.LlmClient.warn "cache decode error: %s" e;
                None)
        | Ok None ->
            Prometheus.inc_counter "masc_llm_cache_misses_total" ();
            None
        | Error e ->
            Prometheus.inc_counter "masc_llm_cache_errors_total" ();
            Log.LlmClient.warn "cache read error: %s" e;
            None)
  in
  let metrics_opt = Some (Llm_oas_adapters.metrics_adapter ()) in
  let result =
    match cached_result with
    | Some cached -> cached
    | None ->
        let upstream_result =
          match req.model.provider with
          | Glm_cloud ->
              call_glm_cloud_with_pool ?timeout_sec ?metrics:metrics_opt req
          | _ ->
              call_provider ?timeout_sec ?metrics:metrics_opt req
        in
        (match (cache_key, upstream_result) with
        | Some key, Ok resp -> (
            match
              Llm_response_cache.set_json ~key
                ~ttl_seconds:Env_config.Llm.cache_ttl_seconds
                (completion_response_to_cache_json resp)
            with
            | Ok () -> Prometheus.inc_counter "masc_llm_cache_writes_total" ()
            | Error e ->
                Prometheus.inc_counter "masc_llm_cache_errors_total" ();
                Log.LlmClient.warn "cache write error: %s" e);
            Ok resp
        | _ -> upstream_result)
  in
  let elapsed_ms = int_of_float ((Time_compat.now () -. t0) *. 1000.0) in
  Result.map (fun resp -> { resp with latency_ms = elapsed_ms }) result

(* ================================================================ *)
(* Provider-aware capacity check                                    *)
(* ================================================================ *)

(** Check whether local providers (Llama) have healthy endpoints.
    When cloud fallbacks exist in the cascade, unhealthy local providers
    are removed so cloud takes over. When the cascade is local-only,
    requests pass through unchanged — the provider returns a connection
    error, which is more informative than a synthetic "unhealthy" error. *)
let filter_by_provider_health (requests : completion_request list)
    : completion_request list =
  let has_local = List.exists (fun (r : completion_request) ->
    r.model.provider = Llama) requests in
  if not has_local then requests
  else
    let has_cloud = List.exists (fun (r : completion_request) ->
      r.model.provider <> Llama) requests in
    let endpoints = Llm_discovery_cache.get_cached_or_refresh () in
    let any_healthy = Llm_discovery_cache.any_local_healthy () in
    let idle = Llm_discovery_cache.idle_slot_count () in
    let busy = Llm_discovery_cache.busy_slot_count () in
    Log.LlmClient.info
      "cascade capacity: local endpoints=%d healthy=%b idle=%d busy=%d"
      (List.length endpoints) any_healthy idle busy;
    if not any_healthy && has_cloud then begin
      Log.LlmClient.warn
        "cascade: local endpoints unhealthy, falling back to cloud providers";
      List.filter (fun (r : completion_request) ->
        r.model.provider <> Llama) requests
    end else
      requests

(* ================================================================ *)
(* Cascade: try models in order                                     *)
(* ================================================================ *)

let cascade ?(accept = fun _ -> true) ?timeout_sec
    (requests : completion_request list) : (completion_response, string) result =
  let requests = filter_by_provider_health requests in
  with_llm_permit (fun () ->
    let avail = Eio.Semaphore.get_value llm_semaphore in
    Log.LlmClient.debug "cascade: acquired permit (%d/%d available)"
      avail max_concurrent_llm;
    let deadline_opt =
      Option.map (fun sec -> Time_compat.now () +. float_of_int sec) timeout_sec
    in
    let remaining_timeout_sec () =
      match deadline_opt with
      | None -> None
      | Some deadline ->
          let remaining = int_of_float (Float.ceil (deadline -. Time_compat.now ())) in
          Some (max 0 remaining)
    in
    let rec try_next errors = function
      | [] ->
        let all_errors = String.concat "; " (List.rev errors) in
        Error (sprintf "All models failed: %s" all_errors)
      | _ when Option.value ~default:1 (remaining_timeout_sec ()) <= 0 ->
        let all_errors =
          String.concat "; " (List.rev ("cascade deadline exceeded" :: errors))
        in
        Error (sprintf "All models failed: %s" all_errors)
      | req :: rest ->
        Log.LlmClient.debug "cascade: trying %s (%s)"
          req.model.model_id (string_of_provider req.model.provider);
        let attempt_result =
          match remaining_timeout_sec () with
          | None -> complete req
          | Some sec when sec > 0 ->
              complete ~timeout_sec:sec req
          | Some _ -> Error "cascade deadline exceeded"
        in
        match attempt_result with
        | Ok resp ->
          if accept resp then (
            Log.LlmClient.info "cascade: success with %s (%dms)"
              resp.model_used resp.latency_ms;
            Ok resp)
          else (
            Log.LlmClient.warn
              "cascade: %s rejected by validator, continuing"
              resp.model_used;
            try_next ("response rejected by validator" :: errors) rest)
        | Error e ->
          Log.LlmClient.warn "cascade: %s failed: %s"
            req.model.model_id e;
          try_next (e :: errors) rest
    in
    try_next [] requests)

(* ================================================================ *)
(* run_prompt_cascade                                                *)
(* ================================================================ *)

let run_prompt_cascade ?(temperature = 0.7) ?timeout_sec
    ?(accept = fun _ -> true) ?system ~model_specs ~max_tokens ~prompt () =
  let msgs =
    match system with
    | Some s -> [ system_msg s; user_msg prompt ]
    | None -> [ user_msg prompt ]
  in
  let requests =
    List.map
      (fun (model : model_spec) ->
        ({
           model;
           messages = msgs;
           temperature;
           max_tokens;
           tools = [];
           response_format = `Text;
         }
          : completion_request))
      model_specs
  in
  cascade ?timeout_sec ~accept requests
