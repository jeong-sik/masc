(** Llm_types — Shared type definitions, model registry, and parsing for the LLM client subsystem. *)

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

type role = Agent_sdk.Types.role = System | User | Assistant | Tool

type message = {
  role : role;
  content : Agent_sdk.Types.content_block list;
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
  content : Agent_sdk.Types.content_block list;
  tool_calls : tool_call list;
  usage : token_usage;
  model_used : string;
  latency_ms : int;
}

(** Extract text content from a completion_response.
    Delegates to Agent_sdk.Types.text_of_content for rich content_block list. *)
let text_of_response (resp : completion_response) : string =
  Agent_sdk.Types.text_of_content resp.content

let clamp_llama_max_tokens max_tokens =
  max 1 (min max_tokens Env_config.Llama.max_tokens)

let normalize_request (req : completion_request) =
  match req.model.provider with
  | Llama ->
      let max_tokens = clamp_llama_max_tokens req.max_tokens in
      if max_tokens = req.max_tokens then req else { req with max_tokens }
  | _ -> req

let string_of_provider = function
  | Llama -> "llama"
  | Claude -> "claude"
  | OpenAI -> "openai"
  | Gemini -> "gemini"
  | Glm_cloud -> "glm_cloud"
  | OpenRouter -> "openrouter"
  | Custom s -> sprintf "custom(%s)" s

let string_of_role = Agent_sdk.Types.role_to_string

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

let system_msg text =
  { role = System; content = [Agent_sdk.Types.Text text]; name = None; tool_call_id = None }
let user_msg text =
  { role = User; content = [Agent_sdk.Types.Text text]; name = None; tool_call_id = None }
let assistant_msg text =
  { role = Assistant; content = [Agent_sdk.Types.Text text]; name = None; tool_call_id = None }

let tool_msg ~name ~call_id text =
  { role = Tool;
    content = [Agent_sdk.Types.ToolResult { tool_use_id = call_id; content = text; is_error = false }];
    name = Some name; tool_call_id = Some call_id }

(** Extract text content from a message.
    Delegates to Agent_sdk.Types.text_of_content for rich content_block list. *)
let text_of_message (m : message) : string =
  Agent_sdk.Types.text_of_content m.content

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
  { m with
    content = List.map (fun block ->
      match block with
      | Agent_sdk.Types.Text s -> Agent_sdk.Types.Text (sanitize_text_utf8 s)
      | Agent_sdk.Types.ToolResult { tool_use_id; content; is_error } ->
          Agent_sdk.Types.ToolResult { tool_use_id; content = sanitize_text_utf8 content; is_error }
      | other -> other
    ) m.content;
    name = Option.map sanitize_text_utf8 m.name;
    tool_call_id = Option.map sanitize_text_utf8 m.tool_call_id;
  }

let sanitize_messages_utf8 (msgs : message list) : message list =
  List.map sanitize_message_utf8 msgs

(** Heuristic: ~4 characters per token (conservative estimate). *)
let estimate_tokens (msgs : message list) =
  List.fold_left (fun acc (m : message) -> acc + (String.length (text_of_message m) / 4) + 4) 0 msgs

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
