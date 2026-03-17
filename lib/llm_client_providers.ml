include Llm_client_core

open Printf

(* ================================================================ *)
(* HTTP Execution via curl subprocess                               *)
(* ================================================================ *)

(** Get API key from environment variable. *)
let get_api_key (spec : model_spec) : string =
  match spec.api_key_env with
  | Some env_var -> Sys.getenv_opt env_var |> Option.value ~default:""
  | None -> ""

let fetch_vertex_adc_access_token () =
  let manual_override = Sys.getenv_opt "MASC_VERTEX_ACCESS_TOKEN" |> Option.value ~default:"" |> String.trim in
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
      Error "Claude direct provider uses call_claude, not OpenAI-compatible transport"
  | Llama -> Ok (spec.api_url, "/v1/chat/completions", [])
  | Custom _ ->
      let auth_headers =
        match get_api_key spec with
        | "" -> []
        | api_key -> [ ("Authorization", sprintf "Bearer %s" api_key) ]
      in
      Ok (spec.api_url, "/v1/chat/completions", auth_headers)

(** Run curl with body via stdin, return response string.
    Uses status-aware execution to distinguish timeout (exit 28)
    from connection failure (exit 7) and other errors. *)
let curl_post ~url ~headers ~body ~timeout_sec : (string, string) result =
  let header_args = List.concat_map (fun (k, v) ->
    ["-H"; sprintf "%s: %s" k v]
  ) headers in
  let argv = ["curl"; "-s"; "--max-time"; string_of_int timeout_sec;
              "-X"; "POST"; url] @ header_args @ ["-d"; "@-"] in
  let run_once () =
    Process_eio.run_argv_with_stdin_and_status
      ~timeout_sec:(Float.of_int timeout_sec +. 5.0)
      ~stdin_content:body
      argv
  in
  let rec handle attempt =
    let (status, raw) = run_once () in
    let should_retry =
      match status with
      | Unix.WEXITED 0 when String.length raw = 0 -> true
      | Unix.WEXITED 52 -> true
      | _ -> false
    in
    if should_retry && attempt = 0 then (
      Time_compat.sleep 0.2;
      handle 1)
    else
      match status with
      | Unix.WEXITED 0 ->
        if String.length raw = 0 then Error "Empty response from API"
        else Ok raw
      | Unix.WEXITED 28 ->
        Error (sprintf "Request timed out after %ds (%s)" timeout_sec url)
      | Unix.WEXITED 7 ->
        Error (sprintf "Connection refused (%s)" url)
      | Unix.WEXITED 52 ->
        Error (sprintf "Empty reply from server (%s)" url)
      | Unix.WEXITED code ->
        Error (sprintf "curl exit %d (%s)" code url)
      | Unix.WSIGNALED sig_num ->
        Error (sprintf "curl killed by signal %d after %ds (%s)" sig_num timeout_sec url)
      | Unix.WSTOPPED _ ->
        Error "curl stopped unexpectedly"
  in
  try
    handle 0
  with exn ->
    Error (sprintf "HTTP error: %s" (Printexc.to_string exn))

let call_claude ?timeout_sec (req : completion_request) : (completion_response, string) result =
  let api_key = get_api_key req.model in
  if api_key = "" then Error "ANTHROPIC_API_KEY not set"
  else
    let url = sprintf "%s/v1/messages" req.model.api_url in
    let body = build_claude_body req in
    let headers = [
      ("Content-Type", "application/json");
      ("x-api-key", api_key);
      ("anthropic-version", "2023-06-01");
    ] in
    let timeout_sec = Option.value timeout_sec ~default:Env_config_runtime.Timeout.anthropic_api_sec in
    match curl_post ~url ~headers ~body ~timeout_sec with
    | Error e -> Error e
    | Ok raw -> parse_claude_response raw

let call_openai_compatible ?timeout_sec (req : completion_request) : (completion_response, string) result =
  let effective_req = normalize_request req in
  match resolve_openai_compatible_endpoint req.model with
  | Error e -> Error e
  | Ok (base_url, path, auth_headers) ->
      let url = sprintf "%s%s" base_url path in
      let body = build_openai_body effective_req in
      Log.LlmClient.debug
        "openai-compat req: model=%s provider=%s requested_max_tokens=%d effective_max_tokens=%d tools=%d url=%s"
        req.model.model_id (string_of_provider req.model.provider) req.max_tokens
        effective_req.max_tokens (List.length req.tools) url;
      if req.tools <> [] then begin
        let trunc = Env_config_runtime.Llm_defaults.log_truncation_len in
        let body_trunc = if String.length body > trunc then String.sub body 0 trunc ^ "..." else body in
        Log.LlmClient.debug "openai-compat body (tools present, %d bytes): %s" (String.length body) body_trunc
      end;
      let headers = [("Content-Type", "application/json")] @ auth_headers in
      let timeout_sec = Option.value timeout_sec ~default:Env_config_runtime.Timeout.openai_compat_api_sec in
      match curl_post ~url ~headers ~body ~timeout_sec with
      | Error e -> Error e
      | Ok raw ->
          let trunc = if String.length raw > 500 then String.sub raw 0 500 ^ "..." else raw in
          Log.LlmClient.debug "openai-compat raw (%d bytes): %s" (String.length raw) trunc;
          parse_openai_response raw

(** GLM Cloud call with pool-based load balancing.
    Uses Glm_pool.with_model to select best available model and track usage. *)
let call_glm_cloud_with_pool ?timeout_sec (req : completion_request) : (completion_response, string) result =
  (* Check if the requested model is in our pool for load balancing *)
  let preferred_model =
    if Glm_pool.is_pool_model req.model.model_id then
      Some req.model.model_id
    else
      None
  in
  (* Use pool selection - will pick best available or use preferred if has capacity *)
  Glm_pool.with_model preferred_model (fun pool_model_id ->
    (* Create modified request with pool-selected model *)
    let modified_model = { req.model with model_id = pool_model_id } in
    let modified_req = { req with model = modified_model } in
    (* Make the actual API call *)
    match call_openai_compatible ?timeout_sec modified_req with
    | Ok resp ->
      (* Return response with pool model_id reflected in model_used *)
      Ok { resp with model_used = pool_model_id }
    | Error e -> Error e
  )

(* ================================================================ *)
(* Core: complete                                                   *)
(* ================================================================ *)

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
  let result =
    match cached_result with
    | Some cached -> cached
    | None ->
      let upstream_result =
          match req.model.provider with
          | Llama -> call_openai_compatible ?timeout_sec req
          | Claude -> call_claude ?timeout_sec req
          | Glm_cloud -> call_glm_cloud_with_pool ?timeout_sec req
          | OpenAI | Gemini | OpenRouter | Custom _ -> call_openai_compatible ?timeout_sec req
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
  (* Inject latency into response *)
  Result.map (fun resp -> { resp with latency_ms = elapsed_ms }) result

(* ================================================================ *)
(* Cascade: try models in order                                     *)
(* ================================================================ *)

let cascade ?(accept = fun _ -> true) ?timeout_sec
    (requests : completion_request list) : (completion_response, string) result =
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
(* Model Spec Parser                                                *)
(* ================================================================ *)

let rec model_spec_of_string s =
  let s = String.trim s in
  if String.equal (String.lowercase_ascii s) "default" then
    match Provider_adapter.default_model_label_result () with
    | Ok label -> model_spec_of_string label
    | Error _ as e -> e
  else if
    String.length s > 8
    && String.equal
         (String.lowercase_ascii (String.sub s 0 8))
         "default:"
  then
    let override_model =
      String.sub s 8 (String.length s - 8) |> String.trim
    in
    (match Provider_adapter.default_model_override_label_result override_model with
    | Ok label -> model_spec_of_string label
    | Error _ as e -> e)
  else
  match String.index_opt s ':' with
  | None ->
    Error
      (sprintf
         "Cannot parse model spec: %s (expected provider:model or default[:model])"
         s)
  | Some idx ->
    if idx = 0 || idx >= String.length s - 1 then
      Error
        (sprintf
           "Cannot parse model spec: %s (expected provider:model or default[:model])"
           s)
    else
      let provider = String.sub s 0 idx |> String.lowercase_ascii in
      let model_id =
        String.sub s (idx + 1) (String.length s - idx - 1)
        |> String.trim
      in
      if model_id = "" then
        Error
          (sprintf
             "Cannot parse model spec: %s (expected provider:model or default[:model])"
             s)
      else
        match Provider_adapter.resolve_direct_adapter provider with
        | Some adapter when adapter.canonical_name = "llama" ->
          Ok { llama_default with model_id }
        | Some adapter when adapter.canonical_name = "gemini-api" ->
          if model_id = "pro" then Ok gemini_pro
          else if model_id = "flash" then
            let flash = Env_config_governance.Gemini.flash_model in
            Ok { gemini_pro with model_id = (if flash = "" then "flash" else flash) }
          else
            Ok { gemini_pro with model_id }
        | Some adapter when adapter.canonical_name = "claude-api" ->
          if model_id = "opus" then Ok claude_opus
          else if model_id = "sonnet" then Ok claude_sonnet
          else Ok { claude_opus with model_id }
        | Some adapter when adapter.canonical_name = "codex-api" ->
          Ok { openai_default with model_id }
        | Some adapter when adapter.canonical_name = "glm" ->
          (* "auto" or empty → Glm_pool selects at runtime *)
          let effective_id = if model_id = "auto" then "" else model_id in
          Ok { glm_cloud with model_id = effective_id }
        | Some adapter when adapter.canonical_name = "openrouter" ->
          Ok {
            provider = OpenRouter;
            model_id;
            max_context = 128000;
            api_url = "https://openrouter.ai/api";
            api_key_env = Some "OPENROUTER_API_KEY";
            cost_per_1k_input = 0.001;
            cost_per_1k_output = 0.002;
          }
        | Some _ ->
          Error (sprintf "Cannot parse model spec: %s (unsupported direct adapter '%s')" s provider)
        | None ->
          match provider with
        | "mlx" ->
          Ok {
            provider = Custom "mlx";
            model_id;
            max_context = 128000;
            api_url = Env_config_runtime.Mlx.server_url;
            api_key_env = None;
            cost_per_1k_input = 0.0;
            cost_per_1k_output = 0.0;
          }
        | "custom" ->
          (* Format: custom:model@http://host:port or custom:model *)
          let actual_model, url =
            match String.index_opt model_id '@' with
            | Some at_idx ->
              ( String.sub model_id 0 at_idx,
                String.sub model_id (at_idx + 1)
                  (String.length model_id - at_idx - 1) )
            | None -> (model_id, Env_config_runtime.Custom_llm.default_server_url)
          in
          Ok {
            provider = Custom actual_model;
            model_id = actual_model;
            max_context = 128000;
            api_url = url;
            api_key_env = None;
            cost_per_1k_input = 0.0;
            cost_per_1k_output = 0.0;
          }
        | _ ->
          Error
            (sprintf
               "Cannot parse model spec: %s (unsupported provider '%s'; supported: llama, claude, gemini, glm, openrouter, mlx, custom)"
               s provider)

let configured_default_model_label () =
  match Provider_adapter.configured_default_model_label_result () with
  | Ok label -> Some label
  | Error _ -> None

let default_execution_model_labels () =
  Provider_adapter.preferred_execution_model_labels ()

let default_verifier_model_labels () =
  Provider_adapter.preferred_verifier_model_labels ()

let available_model_specs_of_strings model_strs =
  model_strs
  |> List.filter_map (fun model_str ->
         match model_spec_of_string model_str with
         | Error err ->
             Log.LlmClient.warn "ignoring invalid model spec %s: %s"
               model_str err;
             None
         | Ok spec -> (
             match spec.api_key_env with
             | Some env_name ->
                 let value = Sys.getenv_opt env_name |> Option.value ~default:"" in
                 if String.trim value = "" then (
                   Log.LlmClient.debug "skipping %s: %s not set"
                     model_str env_name;
                   None)
                 else Some spec
             | None -> Some spec))

let first_available_model_spec labels =
  match available_model_specs_of_strings labels with
  | spec :: _ -> Ok spec
  | [] ->
      Error
        "No default model available. Set MASC_DEFAULT_CASCADE, \
         MASC_DEFAULT_PROVIDER/MASC_DEFAULT_MODEL, or provider credentials for the \
         preferred fallback chain, or pass an explicit model."

let default_execution_model_spec () =
  first_available_model_spec (default_execution_model_labels ())

let default_verifier_model_spec () =
  first_available_model_spec (default_verifier_model_labels ())

let default_local_model_spec () =
  match configured_default_model_label () with
  | Some label -> (
      match model_spec_of_string label with
      | Ok spec -> spec
      | Error _ -> (
          match default_execution_model_spec () with
          | Ok spec -> spec
          | Error _ -> glm_cloud))
  | None -> (
      match default_execution_model_spec () with
      | Ok spec -> spec
      | Error _ -> glm_cloud)

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

(* ================================================================ *)
(* OAS Type Adapters                                                *)
(* ================================================================ *)

let to_oas_provider (spec : model_spec) : Agent_sdk.Provider.config option =
  match spec.provider with
  | Claude ->
    Some {
      Agent_sdk.Provider.provider = Agent_sdk.Provider.Anthropic;
      model_id = spec.model_id;
      api_key_env = Option.value ~default:"ANTHROPIC_API_KEY" spec.api_key_env;
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
      api_key_env = Option.value ~default:"GEMINI_API_KEY" spec.api_key_env;
    }
  | Custom _ -> None

let to_oas_message (m : message) : Agent_sdk.Types.message option =
  match m.role with
  | System ->
    (* System messages belong in Checkpoint.system_prompt, not in messages.
       Dropping here prevents duplication at the OAS boundary. *)
    None
  | Tool ->
    let tool_use_id = Option.value ~default:"masc-tool" m.tool_call_id in
    Some { Agent_sdk.Types.role = User;
           content = [ToolResult { tool_use_id; content = text_of_message m; is_error = false }] }
  | User ->
    Some { Agent_sdk.Types.role = User; content = [Text (text_of_message m)] }
  | Assistant ->
    Some { Agent_sdk.Types.role = Assistant; content = [Text (text_of_message m)] }

let of_oas_message (m : Agent_sdk.Types.message) : message =
  (* Role and content are now the same types -- pass through directly. *)
  { role = m.role; content = m.content; name = None; tool_call_id = None }

let of_oas_usage (u : Agent_sdk.Types.api_usage) : token_usage =
  {
    input_tokens = u.input_tokens;
    output_tokens = u.output_tokens;
    total_tokens = u.input_tokens + u.output_tokens;
    cache_creation_input_tokens = u.cache_creation_input_tokens;
    cache_read_input_tokens = u.cache_read_input_tokens;
  }

let to_oas_usage (u : token_usage) : Agent_sdk.Types.api_usage =
  {
    Agent_sdk.Types.input_tokens = u.input_tokens;
    output_tokens = u.output_tokens;
    cache_creation_input_tokens = u.cache_creation_input_tokens;
    cache_read_input_tokens = u.cache_read_input_tokens;
  }
