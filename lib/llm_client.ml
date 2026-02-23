(** Llm_client — Vendor-agnostic LLM client for the Perpetual Agent Runtime.

    Unified interface for calling any LLM provider.  All providers are
    normalized to an internal message format and results are parsed into
    structured completion_response records.

    HTTP calls use Process_eio subprocess (curl) — the same proven pattern
    used by llm_direct.ml.  This avoids complex TLS/cohttp-eio setup
    while being equally reliable.

    @since 2.61.0 *)

open Printf

let contains_ci (text : string) (needle : string) : bool =
  let hay = String.lowercase_ascii text in
  let ndl = String.lowercase_ascii needle in
  ndl <> ""
  &&
  try
    let _ = Str.search_forward (Str.regexp_string ndl) hay 0 in
    true
  with Not_found -> false

let int_of_env_default name ~default ~min_v ~max_v =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      let v =
        try int_of_string (String.trim raw)
        with _ -> default
      in
      max min_v (min max_v v)

let ollama_timeout_sec () =
  int_of_env_default
    "MASC_LLM_OLLAMA_TIMEOUT_SEC"
    ~default:45
    ~min_v:10
    ~max_v:180

(* ================================================================ *)
(* Concurrency limiter — throttle simultaneous LLM requests          *)
(* ================================================================ *)

(** Maximum concurrent cascade/LLM calls.
    Default 2 matches OLLAMA_MAX_LOADED_MODELS on M3 Max 128GB.
    Prevents keeper stampede from overloading Ollama VRAM. *)
let max_concurrent_llm =
  int_of_env_default "MASC_MAX_CONCURRENT_LLM" ~default:2 ~min_v:1 ~max_v:16

let llm_semaphore = Eio.Semaphore.make max_concurrent_llm

let llm_semaphore_available () = Eio.Semaphore.get_value llm_semaphore

let with_llm_permit f =
  Eio.Semaphore.acquire llm_semaphore;
  Fun.protect ~finally:(fun () -> Eio.Semaphore.release llm_semaphore) f

let ollama_should_fallback_to_generate (err : string) : bool =
  contains_ci err "404"
  || contains_ci err "not found"
  || contains_ci err "unsupported"
  || contains_ci err "unknown endpoint"

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type provider =
  | Ollama
  | Claude
  | Gemini
  | Glm_cloud
  | OpenRouter
  | Custom of string

type model_spec = {
  provider : provider;
  model_id : string;
  max_context : int;
  api_url : string;
  api_key_env : string option;
  cost_per_1k_input : float;
  cost_per_1k_output : float;
}

type role = System | User | Assistant | Tool

type message = {
  role : role;
  content : string;
  name : string option;
  tool_call_id : string option;
}

type tool_def = {
  tool_name : string;
  tool_description : string;
  parameters : Yojson.Safe.t;
}

type tool_call = {
  call_id : string;
  call_name : string;
  call_arguments : string;
}

type token_usage = {
  input_tokens : int;
  output_tokens : int;
  total_tokens : int;
}

type completion_request = {
  model : model_spec;
  messages : message list;
  temperature : float;
  max_tokens : int;
  tools : tool_def list;
  response_format : [ `Text | `Json ];
}

type completion_response = {
  content : string;
  tool_calls : tool_call list;
  usage : token_usage;
  model_used : string;
  latency_ms : int;
}

(* ================================================================ *)
(* Provider Helpers                                                 *)
(* ================================================================ *)

let string_of_provider = function
  | Ollama -> "ollama"
  | Claude -> "claude"
  | Gemini -> "gemini"
  | Glm_cloud -> "glm_cloud"
  | OpenRouter -> "openrouter"
  | Custom s -> sprintf "custom(%s)" s

let string_of_role = function
  | System -> "system"
  | User -> "user"
  | Assistant -> "assistant"
  | Tool -> "tool"

(* ================================================================ *)
(* Built-in Model Specs                                             *)
(* ================================================================ *)

let ollama_glm = {
  provider = Ollama;
  model_id = "glm-4.7-flash";
  max_context = 202000;
  api_url = "http://127.0.0.1:11434";
  api_key_env = None;
  cost_per_1k_input = 0.0;
  cost_per_1k_output = 0.0;
}

let ollama_lfm = {
  provider = Ollama;
  model_id = "LFM2.5-1.2B-Instruct";
  max_context = 128000;
  api_url = "http://127.0.0.1:11434";
  api_key_env = None;
  cost_per_1k_input = 0.0;
  cost_per_1k_output = 0.0;
}

let claude_opus = {
  provider = Claude;
  model_id = "claude-opus-4-6";
  max_context = 200000;
  api_url = "https://api.anthropic.com";
  api_key_env = Some "ANTHROPIC_API_KEY";
  cost_per_1k_input = 0.015;
  cost_per_1k_output = 0.075;
}

let claude_sonnet = {
  provider = Claude;
  model_id = "claude-sonnet-4-5-20250929";
  max_context = 200000;
  api_url = "https://api.anthropic.com";
  api_key_env = Some "ANTHROPIC_API_KEY";
  cost_per_1k_input = 0.003;
  cost_per_1k_output = 0.015;
}

let glm_cloud = {
  provider = Glm_cloud;
  model_id = "glm-4.7";
  max_context = 128000;
  api_url = "https://api.z.ai";
  api_key_env = Some "ZAI_API_KEY";
  cost_per_1k_input = 0.001;
  cost_per_1k_output = 0.002;
}

let gemini_pro = {
  provider = Gemini;
  model_id = "gemini-2.5-pro";
  max_context = 1000000;
  api_url = "https://generativelanguage.googleapis.com";
  api_key_env = Some "GEMINI_API_KEY";
  cost_per_1k_input = 0.0;
  cost_per_1k_output = 0.0;
}

(* ================================================================ *)
(* Message Constructors                                             *)
(* ================================================================ *)

let system_msg content = { role = System; content; name = None; tool_call_id = None }
let user_msg content = { role = User; content; name = None; tool_call_id = None }
let assistant_msg content = { role = Assistant; content; name = None; tool_call_id = None }

let tool_msg ~name ~call_id content =
  { role = Tool; content; name = Some name; tool_call_id = Some call_id }

(* ================================================================ *)
(* Token Estimation                                                 *)
(* ================================================================ *)

(** Heuristic: ~4 characters per token (conservative estimate). *)
let estimate_tokens (msgs : message list) =
  List.fold_left (fun acc (m : message) -> acc + (String.length m.content / 4) + 4) 0 msgs

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

(** Build OpenAI-compatible request body (works for Ollama, GLM, OpenRouter).
    Gemini's OpenAI-compat endpoint uses [max_completion_tokens] (thinking models
    consume internal tokens from this budget, so [max_tokens] alone under-allocates). *)
let build_openai_body (req : completion_request) : string =
  let messages_json = List.map message_to_openai_json req.messages in
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
  (* Claude uses separate system parameter *)
  let system_text = List.fold_left (fun acc m ->
    match m.role with System -> acc ^ m.content ^ "\n" | _ -> acc
  ) "" req.messages |> String.trim in
  let non_system = List.filter (fun m -> m.role <> System) req.messages in
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
          with _ -> None
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
    let usage = {
      input_tokens = (try usage_json |> member "prompt_tokens" |> to_int with _ -> 0);
      output_tokens = (try usage_json |> member "completion_tokens" |> to_int with _ -> 0);
      total_tokens = (try usage_json |> member "total_tokens" |> to_int with _ -> 0);
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
    let input_tokens = try usage_json |> member "input_tokens" |> to_int with _ -> 0 in
    let output_tokens = try usage_json |> member "output_tokens" |> to_int with _ -> 0 in
    let usage = {
      input_tokens;
      output_tokens;
      total_tokens = input_tokens + output_tokens;
    } in
    let model_used = json |> member "model" |> to_string_option
                     |> Option.value ~default:"unknown" in
    Ok { content; tool_calls; usage; model_used; latency_ms = 0 }
  with
  | Failure msg -> Error msg
  | exn -> Error (sprintf "Parse error: %s" (Printexc.to_string exn))

let parse_ollama_generate_response (json_str : string) : (completion_response, string) result =
  try
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let content = json |> member "response" |> to_string in
    let eval_count = try json |> member "eval_count" |> to_int with _ -> 0 in
    let prompt_eval_count = try json |> member "prompt_eval_count" |> to_int with _ -> 0 in
    let model_used = json |> member "model" |> to_string_option
                     |> Option.value ~default:"unknown" in
    let usage = {
      input_tokens = prompt_eval_count;
      output_tokens = eval_count;
      total_tokens = prompt_eval_count + eval_count;
    } in
    Ok { content; tool_calls = []; usage; model_used; latency_ms = 0 }
  with exn ->
    Error (sprintf "Ollama parse error: %s" (Printexc.to_string exn))

(** Parse native Ollama /api/chat response.
    Format: { "message": { "content": "..." }, "done": true,
              "eval_count": N, "prompt_eval_count": N, "model": "..." } *)
let parse_ollama_chat_response (json_str : string) : (completion_response, string) result =
  try
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let msg = json |> member "message" in
    let content = msg |> member "content" |> to_string_option
                  |> Option.value ~default:"" in
    let eval_count = try json |> member "eval_count" |> to_int with _ -> 0 in
    let prompt_eval_count = try json |> member "prompt_eval_count" |> to_int with _ -> 0 in
    let model_used = json |> member "model" |> to_string_option
                     |> Option.value ~default:"unknown" in
    let usage = {
      input_tokens = prompt_eval_count;
      output_tokens = eval_count;
      total_tokens = prompt_eval_count + eval_count;
    } in
    Ok { content; tool_calls = []; usage; model_used; latency_ms = 0 }
  with exn ->
    Error (sprintf "Ollama chat parse error: %s" (Printexc.to_string exn))

(* ================================================================ *)
(* HTTP Execution via curl subprocess                               *)
(* ================================================================ *)

(** Get API key from environment variable. *)
let get_api_key (spec : model_spec) : string =
  match spec.api_key_env with
  | Some env_var -> Sys.getenv_opt env_var |> Option.value ~default:""
  | None -> ""

(** Run curl with body via stdin, return response string.
    Uses status-aware execution to distinguish timeout (exit 28)
    from connection failure (exit 7) and other errors. *)
let curl_post ~url ~headers ~body ~timeout_sec : (string, string) result =
  let header_args = List.concat_map (fun (k, v) ->
    ["-H"; sprintf "%s: %s" k v]
  ) headers in
  let argv = ["curl"; "-s"; "--max-time"; string_of_int timeout_sec;
              "-X"; "POST"; url] @ header_args @ ["-d"; "@-"] in
  try
    let (status, raw) = Process_eio.run_argv_with_stdin_and_status
      ~timeout_sec:(Float.of_int timeout_sec +. 5.0)
      ~stdin_content:body
      argv in
    match status with
    | Unix.WEXITED 0 ->
      if String.length raw = 0 then Error "Empty response from API"
      else Ok raw
    | Unix.WEXITED 28 ->
      Error (sprintf "Request timed out after %ds (%s)" timeout_sec url)
    | Unix.WEXITED 7 ->
      Error (sprintf "Connection refused (%s)" url)
    | Unix.WEXITED code ->
      Error (sprintf "curl exit %d (%s)" code url)
    | Unix.WSIGNALED sig_num ->
      Error (sprintf "curl killed by signal %d after %ds (%s)" sig_num timeout_sec url)
    | Unix.WSTOPPED _ ->
      Error "curl stopped unexpectedly"
  with exn ->
    Error (sprintf "HTTP error: %s" (Printexc.to_string exn))

(* ================================================================ *)
(* Provider-Specific Execution                                      *)
(* ================================================================ *)

(** Build native Ollama /api/chat request body with think:false.
    Uses the same message format as OpenAI but adds Ollama-specific fields.
    Includes tools when provided - Ollama supports OpenAI-compatible tool format. *)
let build_ollama_chat_body (req : completion_request) : string =
  let messages_json = List.map message_to_openai_json req.messages in
  let base = [
    ("model", `String req.model.model_id);
    ("messages", `List messages_json);
    ("stream", `Bool false);
    ("think", `Bool false);
    ("options", `Assoc [
      ("temperature", `Float req.temperature);
      ("num_predict", `Int req.max_tokens);
    ]);
  ] in
  let with_tools = match req.tools with
    | [] -> base
    | tools ->
      let tools_json = List.map tool_def_to_openai_json tools in
      ("tools", `List tools_json) :: base
  in
  Yojson.Safe.to_string (`Assoc with_tools)

let call_ollama_chat ?timeout_sec (req : completion_request) : (completion_response, string) result =
  let url = sprintf "%s/api/chat" req.model.api_url in
  let body = build_ollama_chat_body req in
  let headers = [("Content-Type", "application/json")] in
  let timeout_sec = Option.value timeout_sec ~default:(ollama_timeout_sec ()) in
  eprintf "[llm_client] ollama_chat req: model=%s tools=%d body_len=%d\n%!"
    req.model.model_id (List.length req.tools) (String.length body);
  match curl_post ~url ~headers ~body ~timeout_sec with
  | Error e -> Error e
  | Ok raw -> parse_ollama_chat_response raw

(** Ollama fallback: /api/generate for models without chat support. *)
let call_ollama_generate ?timeout_sec (req : completion_request) : (completion_response, string) result =
  let url = sprintf "%s/api/generate" req.model.api_url in
  let prompt = List.fold_left (fun acc m ->
    match m.role with
    | System -> sprintf "%s[System] %s\n" acc m.content
    | User -> sprintf "%s%s\n" acc m.content
    | Assistant -> sprintf "%s[Assistant] %s\n" acc m.content
    | Tool -> sprintf "%s[Tool:%s] %s\n" acc
                (Option.value ~default:"" m.name) m.content
  ) "" req.messages in
  let body = Yojson.Safe.to_string (`Assoc [
    ("model", `String req.model.model_id);
    ("prompt", `String prompt);
    ("stream", `Bool false);
    ("think", `Bool false);
    ("options", `Assoc [
      ("temperature", `Float req.temperature);
      ("num_predict", `Int req.max_tokens);
    ]);
  ]) in
  let headers = [("Content-Type", "application/json")] in
  let timeout_sec = Option.value timeout_sec ~default:(ollama_timeout_sec ()) in
  match curl_post ~url ~headers ~body ~timeout_sec with
  | Error e -> Error e
  | Ok raw -> parse_ollama_generate_response raw

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
    let timeout_sec = Option.value timeout_sec ~default:120 in
    match curl_post ~url ~headers ~body ~timeout_sec with
    | Error e -> Error e
    | Ok raw -> parse_claude_response raw

let call_openai_compatible ?timeout_sec (req : completion_request) : (completion_response, string) result =
  let api_key = get_api_key req.model in
  let path = match req.model.provider with
    | Gemini -> "/v1beta/openai/chat/completions"
    | Glm_cloud -> "/api/coding/paas/v4/chat/completions"
    | _ -> "/v1/chat/completions"
  in
  let url = sprintf "%s%s" req.model.api_url path in
  let body = build_openai_body req in
  Printf.eprintf "[llm_client] openai-compat req: model=%s max_tokens=%d tools=%d url=%s\n%!"
    req.model.model_id req.max_tokens (List.length req.tools) url;
  if req.tools <> [] then begin
    let body_trunc = if String.length body > 1500 then String.sub body 0 1500 ^ "..." else body in
    Printf.eprintf "[llm_client] openai-compat body (tools present, %d bytes): %s\n%!" (String.length body) body_trunc
  end;
  let headers = [("Content-Type", "application/json")] @
    (if api_key <> "" then [("Authorization", sprintf "Bearer %s" api_key)] else [])
  in
  let timeout_sec = Option.value timeout_sec ~default:60 in
  match curl_post ~url ~headers ~body ~timeout_sec with
  | Error e -> Error e
  | Ok raw ->
    let trunc = if String.length raw > 500 then String.sub raw 0 500 ^ "..." else raw in
    Printf.eprintf "[llm_client] openai-compat raw (%d bytes): %s\n%!" (String.length raw) trunc;
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

let complete ?timeout_sec ?ollama_timeout_sec (req : completion_request) : (completion_response, string) result =
  let t0 = Time_compat.now () in
  let effective_ollama_timeout_sec =
    match timeout_sec, ollama_timeout_sec with
    | None, None -> None
    | Some t, None -> Some (max 1 t)
    | None, Some o -> Some o
    | Some t, Some o -> Some (min (max 1 t) o)
  in
  let result = match req.model.provider with
    | Ollama ->
      (* Try chat API first.
         Fallback to /api/generate only for likely endpoint-support errors,
         because retrying on timeouts doubles latency and can exceed caller deadlines. *)
      (match call_ollama_chat ?timeout_sec:effective_ollama_timeout_sec req with
       | Ok _ as ok -> ok
       | Error e ->
         if req.tools <> [] then Error e
         else if ollama_should_fallback_to_generate e then
           call_ollama_generate ?timeout_sec:effective_ollama_timeout_sec req
         else Error e)
    | Claude -> call_claude ?timeout_sec req
    | Glm_cloud -> call_glm_cloud_with_pool ?timeout_sec req
    | Gemini | OpenRouter | Custom _ ->
      call_openai_compatible ?timeout_sec req
  in
  let elapsed_ms = int_of_float ((Time_compat.now () -. t0) *. 1000.0) in
  (* Inject latency into response *)
  Result.map (fun resp -> { resp with latency_ms = elapsed_ms }) result

(* ================================================================ *)
(* Cascade: try models in order                                     *)
(* ================================================================ *)

let cascade ?timeout_sec ?ollama_timeout_sec (requests : completion_request list) : (completion_response, string) result =
  with_llm_permit (fun () ->
    let avail = Eio.Semaphore.get_value llm_semaphore in
    eprintf "[llm_client] cascade: acquired permit (%d/%d available)\n%!"
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
        eprintf "[llm_client] cascade: trying %s (%s)\n%!"
          req.model.model_id (string_of_provider req.model.provider);
        let attempt_result =
          match remaining_timeout_sec () with
          | None -> complete ?ollama_timeout_sec req
          | Some sec when sec > 0 ->
              complete ~timeout_sec:sec ?ollama_timeout_sec req
          | Some _ -> Error "cascade deadline exceeded"
        in
        match attempt_result with
        | Ok resp ->
          eprintf "[llm_client] cascade: success with %s (%dms)\n%!"
            resp.model_used resp.latency_ms;
          Ok resp
        | Error e ->
          eprintf "[llm_client] cascade: %s failed: %s\n%!"
            req.model.model_id e;
          try_next (e :: errors) rest
    in
    try_next [] requests)

(* ================================================================ *)
(* Model Spec Parser                                                *)
(* ================================================================ *)

let model_spec_of_string s =
  let s = String.trim s in
  match String.index_opt s ':' with
  | None ->
    Error (sprintf "Cannot parse model spec: %s (expected provider:model)" s)
  | Some idx ->
    if idx = 0 || idx >= String.length s - 1 then
      Error (sprintf "Cannot parse model spec: %s (expected provider:model)" s)
    else
      let provider = String.sub s 0 idx |> String.lowercase_ascii in
      let model_id =
        String.sub s (idx + 1) (String.length s - idx - 1)
        |> String.trim
      in
      if model_id = "" then
        Error (sprintf "Cannot parse model spec: %s (expected provider:model)" s)
      else
        match provider with
        | "ollama" ->
          Ok { ollama_glm with model_id }
        | "gemini" | "google" ->
          if model_id = "pro" then Ok gemini_pro
          else if model_id = "flash" then
            Ok { gemini_pro with model_id = "gemini-3-flash-preview" }
          else
            Ok { gemini_pro with model_id }
        | "claude" | "anthropic" ->
          if model_id = "opus" then Ok claude_opus
          else if model_id = "sonnet" then Ok claude_sonnet
          else Ok { claude_opus with model_id }
        | "glm" | "glm_cloud" | "zai" ->
          Ok { glm_cloud with model_id }
        | "openrouter" ->
          Ok {
            provider = OpenRouter;
            model_id;
            max_context = 128000;
            api_url = "https://openrouter.ai/api";
            api_key_env = Some "OPENROUTER_API_KEY";
            cost_per_1k_input = 0.001;
            cost_per_1k_output = 0.002;
          }
        | _ ->
          Error
            (sprintf
               "Cannot parse model spec: %s (unsupported provider '%s'; supported: ollama, claude, gemini, glm, openrouter)"
               s provider)
