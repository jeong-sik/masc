(** Llm_client — Vendor-agnostic LLM client for the Perpetual Agent Runtime.

    Unified interface for calling any LLM provider. All providers are
    normalized to an internal message format and results are parsed into
    structured completion_response records.

    HTTP calls use Process_eio subprocess (curl) — the same proven pattern
    used by llm_direct.ml. This avoids complex TLS/cohttp-eio setup
    while being equally reliable.

    @since 2.61.0 *)

open Printf

let int_of_env_default name ~default ~min_v ~max_v =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw ->
      let v =
        try int_of_string (String.trim raw)
        with Failure _ -> default
      in
      max min_v (min max_v v)

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
(* Types                                                            *)
(* ================================================================ *)

type provider =
  | Llama
  | Claude
  | OpenAI
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
  cache_creation_input_tokens : int;
  cache_read_input_tokens : int;
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

let clamp_llama_max_tokens max_tokens =
  max 1 (min max_tokens Env_config.Llama.max_tokens)

let normalize_request (req : completion_request) =
  match req.model.provider with
  | Llama ->
      let max_tokens = clamp_llama_max_tokens req.max_tokens in
      if max_tokens = req.max_tokens then req else { req with max_tokens }
  | _ -> req

(* ================================================================ *)
(* Provider Helpers                                                 *)
(* ================================================================ *)

let string_of_provider = function
  | Llama -> "llama"
  | Claude -> "claude"
  | OpenAI -> "openai"
  | Gemini -> "gemini"
  | Glm_cloud -> "glm_cloud"
  | OpenRouter -> "openrouter"
  | Custom s -> sprintf "custom(%s)" s

let string_of_role = function
  | System -> "system"
  | User -> "user"
  | Assistant -> "assistant"
  | Tool -> "tool"

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
(* Built-in Model Specs                                             *)
(* ================================================================ *)

let llama_default = {
  provider = Llama;
  model_id = Env_config.Llama.default_model;
  max_context = 128000;
  api_url = Env_config.Llama.server_url;
  api_key_env = None;
  cost_per_1k_input = 0.0;
  cost_per_1k_output = 0.0;
}

let claude_opus = {
  provider = Claude;
  model_id = Env_config.Claude.default_model;
  max_context = 200000;
  api_url = "https://api.anthropic.com";
  api_key_env = Some "ANTHROPIC_API_KEY";
  cost_per_1k_input = 0.015;
  cost_per_1k_output = 0.075;
}

let claude_sonnet = {
  provider = Claude;
  model_id = Env_config.Claude.default_model;
  max_context = 200000;
  api_url = "https://api.anthropic.com";
  api_key_env = Some "ANTHROPIC_API_KEY";
  cost_per_1k_input = 0.003;
  cost_per_1k_output = 0.015;
}

let openai_default = {
  provider = OpenAI;
  model_id = Env_config.OpenAI.default_model;
  max_context = 400000;
  api_url = "https://api.openai.com";
  api_key_env = Some "OPENAI_API_KEY";
  cost_per_1k_input = 0.0;
  cost_per_1k_output = 0.0;
}

let glm_cloud = {
  provider = Glm_cloud;
  model_id = Env_config.Llm.default_model;
  max_context = 128000;
  api_url = "https://api.z.ai";
  api_key_env = Some "ZAI_API_KEY";
  cost_per_1k_input = 0.001;
  cost_per_1k_output = 0.002;
}

let gemini_pro = {
  provider = Gemini;
  model_id = Env_config.Gemini.default_model;
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
(* Response cache helpers                                            *)
(* ================================================================ *)

let completion_cache_schema_version = "1.0.0"

let response_format_to_string = function
  | `Text -> "text"
  | `Json -> "json"

let string_opt_to_json = function
  | Some v -> `String v
  | None -> `Null

let message_fingerprint_json (m : message) : Yojson.Safe.t =
  let m = sanitize_message_utf8 m in
  `Assoc
    [
      ("role", `String (string_of_role m.role));
      ("content", `String m.content);
      ("name", string_opt_to_json m.name);
      ("tool_call_id", string_opt_to_json m.tool_call_id);
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
      ("total_tokens", `Int u.total_tokens);
      ("cache_creation_input_tokens", `Int u.cache_creation_input_tokens);
      ("cache_read_input_tokens", `Int u.cache_read_input_tokens);
    ]

let token_usage_of_json (json : Yojson.Safe.t) : (token_usage, string) result =
  let open Yojson.Safe.Util in
  try
    Ok
      {
        input_tokens = json |> member "input_tokens" |> to_int;
        output_tokens = json |> member "output_tokens" |> to_int;
        total_tokens = json |> member "total_tokens" |> to_int;
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
            ("content", `String resp.content);
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
                content = body |> member "content" |> to_string;
                tool_calls;
                usage;
                model_used = body |> member "model_used" |> to_string;
                latency_ms = 0;
              }
        | Error e, _ -> Error e
        | _, Error e -> Error e)
  with exn -> Error (Printexc.to_string exn)

let prompt_char_count (req : completion_request) =
  List.fold_left (fun acc (m : message) -> acc + String.length m.content) 0
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

