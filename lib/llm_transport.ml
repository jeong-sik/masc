(** Llm_transport — HTTP execution, JSON encoding/parsing, and UTF-8 sanitization for LLM providers. *)

open Printf
open Llm_types

(* ================================================================ *)
(* UTF-8 Sanitization                                               *)
(* ================================================================ *)

let sanitize_text_utf8 (s : string) : string =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len then ()
    else
      let dec = String.get_utf_8_uchar s i in
      let dlen = Uchar.utf_decode_length dec in
      if dlen > 0 && Uchar.utf_decode_is_valid dec then (
        Buffer.add_substring buf s i dlen;
        loop (i + dlen))
      else (
        Buffer.add_string buf "\xEF\xBF\xBD";
        loop (i + 1))
  in
  loop 0;
  Buffer.contents buf

let sanitize_message_utf8 (m : message) : message =
  {
    m with
    content = sanitize_text_utf8 m.content;
    name = Option.map sanitize_text_utf8 m.name;
    tool_call_id = Option.map sanitize_text_utf8 m.tool_call_id;
  }

let sanitize_messages_utf8 (msgs : message list) : message list =
  List.map sanitize_message_utf8 msgs

(* ================================================================ *)
(* JSON Encoding — per provider                                     *)
(* ================================================================ *)

let message_to_openai_json (m : message) : Yojson.Safe.t =
  let base = [
    ("role", `String (string_of_role m.role));
    ("content", `String m.content);
  ] in
  let with_name = match m.name with
    | Some n -> ("name", `String n) :: base
    | None -> base
  in
  let with_id = match m.tool_call_id with
    | Some id -> ("tool_call_id", `String id) :: with_name
    | None -> with_name
  in
  `Assoc with_id

let tool_def_to_openai_json (td : tool_def) : Yojson.Safe.t =
  `Assoc [
    ("type", `String "function");
    ("function", `Assoc [
      ("name", `String td.tool_name);
      ("description", `String td.tool_description);
      ("parameters", td.parameters);
    ]);
  ]

(** Build OpenAI-compatible request body (works for llama.cpp, GLM, OpenRouter).
    Gemini's OpenAI-compat endpoint uses [max_completion_tokens] (thinking models
    consume internal tokens from this budget, so [max_tokens] alone under-allocates). *)
let build_openai_body (req : completion_request) : string =
  let req = normalize_request req in
  let messages_json =
    req.messages |> sanitize_messages_utf8 |> List.map message_to_openai_json
  in
  let max_token_fields = match req.model.provider with
    | Gemini ->
      (* Gemini 2.5+ thinking models consume internal thinking tokens from the
         output budget.  The OpenAI-compat endpoint uses max_completion_tokens
         (NOT max_tokens).  Sending both causes HTTP 400. *)
      [("max_completion_tokens", `Int req.max_tokens)]
    | _ ->
      [("max_tokens", `Int req.max_tokens)]
  in
  let base = [
    ("model", `String req.model.model_id);
    ("messages", `List messages_json);
    ("temperature", `Float req.temperature);
  ] @ max_token_fields in
  let with_tools = match req.tools with
    | [] -> base
    | tools ->
      let tools_json = List.map tool_def_to_openai_json tools in
      ("tools", `List tools_json) :: base
  in
  let with_format = match req.response_format with
    | `Json -> ("response_format", `Assoc [("type", `String "json_object")]) :: with_tools
    | `Text -> with_tools
  in
  Yojson.Safe.to_string (`Assoc with_format)

(** Build Anthropic Messages API request body. *)
let build_claude_body (req : completion_request) : string =
  let req = normalize_request req in
  let sanitized_messages = sanitize_messages_utf8 req.messages in
  (* Claude uses separate system parameter *)
  let system_text = List.fold_left (fun acc m ->
    match m.role with System -> acc ^ m.content ^ "\n" | _ -> acc
  ) "" sanitized_messages |> String.trim in
  let non_system = List.filter (fun m -> m.role <> System) sanitized_messages in
  let messages_json = List.map (fun m ->
    `Assoc [
      ("role", `String (string_of_role m.role));
      ("content", `String m.content);
    ]
  ) non_system in
  let base = [
    ("model", `String req.model.model_id);
    ("max_tokens", `Int req.max_tokens);
    ("messages", `List messages_json);
  ] in
  let with_system = if system_text <> "" then
    ("system", `String system_text) :: base
  else base in
  let with_tools = match req.tools with
    | [] -> with_system
    | tools ->
      let tools_json = List.map (fun td ->
        `Assoc [
          ("name", `String td.tool_name);
          ("description", `String td.tool_description);
          ("input_schema", td.parameters);
        ]
      ) tools in
      ("tools", `List tools_json) :: with_system
  in
  Yojson.Safe.to_string (`Assoc with_tools)

(* ================================================================ *)
(* Response Parsing — per provider                                  *)
(* ================================================================ *)

let parse_openai_response (json_str : string) : (completion_response, string) result =
  try
    (* Gemini wraps errors in an array: [{"error": {...}}].
       Unwrap the first element if the top-level JSON is a list. *)
    let raw_json = Yojson.Safe.from_string json_str in
    let json = match raw_json with
      | `List (first :: _) -> first
      | other -> other
    in
    let open Yojson.Safe.Util in
    (* Check for error *)
    (match json |> member "error" with
     | `Null -> ()
     | err ->
       let msg = err |> member "message" |> to_string_option
                 |> Option.value ~default:"Unknown API error" in
       raise (Failure msg));
    let choice = json |> member "choices" |> index 0 in
    let msg = choice |> member "message" in
    let finish_reason =
      choice |> member "finish_reason" |> to_string_option
      |> Option.value ~default:""
    in
    let content =
      match msg |> member "content" with
      | `String s -> s
      | `List blocks ->
          blocks
          |> List.filter_map (fun block ->
                 match block with
                 | `String s -> Some s
                 | `Assoc _ ->
                     (match block |> member "text" with
                     | `String s -> Some s
                     | _ -> None)
                 | _ -> None)
          |> String.concat ""
      | _ -> ""
    in
    (* Parse tool calls if present *)
    let tool_calls = match msg |> member "tool_calls" with
      | `List calls ->
        List.filter_map (fun tc ->
          try
            let fn = tc |> member "function" in
            Some {
              call_id = tc |> member "id" |> to_string;
              call_name = fn |> member "name" |> to_string;
              call_arguments = fn |> member "arguments" |> to_string;
            }
          with exn ->
            Printf.eprintf "[WARN] [llm] tool_call parse failed: %s\n%!" (Printexc.to_string exn);
            None
        ) calls
      | _ -> (
          match msg |> member "function_call" with
          | `Assoc _ as fn ->
              let name = fn |> member "name" |> to_string_option in
              let arguments =
                fn |> member "arguments" |> to_string_option
                |> Option.value ~default:"{}"
              in
              (match name with
              | Some call_name when String.trim call_name <> "" ->
                  [
                    {
                      call_id = "function_call";
                      call_name;
                      call_arguments = arguments;
                    };
                  ]
              | _ -> [])
          | _ -> [])
    in
    if String.trim content = "" && tool_calls = [] then (
      let reason =
        match String.lowercase_ascii finish_reason with
        | "length" ->
            "Empty completion (finish_reason=length)"
        | "content_filter" ->
            "Empty completion (content filtered)"
        | _ -> "Empty completion (no content/tool_calls)"
      in
      raise (Failure reason)
    );
    (* Parse usage *)
    let usage_json = json |> member "usage" in
    let parse_token key =
      match Safe_ops.json_int_opt key usage_json with
      | Some n -> n
      | None ->
        Log.LlmClient.debug "token field missing or wrong type: %s" key;
        0
    in
    let usage = {
      input_tokens = parse_token "prompt_tokens";
      output_tokens = parse_token "completion_tokens";
      total_tokens = parse_token "total_tokens";
      cache_creation_input_tokens = 0;
      cache_read_input_tokens = 0;
    } in
    let model_used = json |> member "model" |> to_string_option
                     |> Option.value ~default:"unknown" in
    Ok { content; tool_calls; usage; model_used; latency_ms = 0 }
  with
  | Failure msg -> Error msg
  | exn -> Error (sprintf "Parse error: %s" (Printexc.to_string exn))

let parse_claude_response (json_str : string) : (completion_response, string) result =
  try
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    (* Check for error *)
    (match json |> member "type" |> to_string_option with
     | Some "error" ->
       let msg = json |> member "error" |> member "message" |> to_string in
       raise (Failure msg)
     | _ -> ());
    (* Extract content blocks *)
    let content_blocks = json |> member "content" |> to_list in
    let content = List.fold_left (fun acc block ->
      match block |> member "type" |> to_string with
      | "text" -> acc ^ (block |> member "text" |> to_string)
      | _ -> acc
    ) "" content_blocks in
    (* Extract tool use blocks *)
    let tool_calls = List.filter_map (fun block ->
      match block |> member "type" |> to_string with
      | "tool_use" ->
        Some {
          call_id = block |> member "id" |> to_string;
          call_name = block |> member "name" |> to_string;
          call_arguments = block |> member "input" |> Yojson.Safe.to_string;
        }
      | _ -> None
    ) content_blocks in
    (* Parse usage *)
    let usage_json = json |> member "usage" in
    let input_tokens = Safe_ops.json_int "input_tokens" usage_json in
    let output_tokens = Safe_ops.json_int "output_tokens" usage_json in
    let cache_creation = Safe_ops.json_int "cache_creation_input_tokens" usage_json in
    let cache_read = Safe_ops.json_int "cache_read_input_tokens" usage_json in
    let usage = {
      input_tokens;
      output_tokens;
      total_tokens = input_tokens + output_tokens;
      cache_creation_input_tokens = cache_creation;
      cache_read_input_tokens = cache_read;
    } in
    let model_used = json |> member "model" |> to_string_option
                     |> Option.value ~default:"unknown" in
    Ok { content; tool_calls; usage; model_used; latency_ms = 0 }
  with
  | Failure msg -> Error msg
  | exn -> Error (sprintf "Parse error: %s" (Printexc.to_string exn))

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
