type choice = Ollama | Llama_cpp | Vllm | Openai_compatible | Messages | Claude_code | Codex | Antigravity
type http_kind = Openai_compat | Anthropic | Kimi | Glm | Ollama_kind
type credential = Env_reference of string | File_reference of string
type transport =
  | Http of {endpoint:string; credential:credential option;
      kind:http_kind; request_path:string; api_key_env:string}
  | Client of {command:string; oauth:string option; timeout:float option}
type t = {choice:choice; model:string; context:int; tools:bool; streaming:bool;
  transport:transport; canonical_spec:string}
type error = Invalid_spec of string
let error_message (Invalid_spec field) = "Invalid runtime setup specification: " ^ field
let ( let* ) = Result.bind
let invalid field = Error (Invalid_spec field)
let choice_name = function Ollama -> "ollama" | Llama_cpp -> "llama_cpp" | Vllm -> "vllm"
  | Openai_compatible -> "openai_compatible" | Messages -> "messages" | Claude_code -> "claude_code"
  | Codex -> "codex" | Antigravity -> "antigravity"
let protocol = function Ollama -> "ollama-http" | Messages -> "messages-http"
  | Claude_code -> "claude-code" | Codex -> "codex-app-server" | Antigravity -> "antigravity-cli"
  | Llama_cpp | Vllm | Openai_compatible -> "openai-compatible-http"
let http = function Ollama | Llama_cpp | Vllm | Openai_compatible | Messages -> true | _ -> false
let safe_text value = value <> "" && String.trim value = value
  && not (String.exists (function '\000'..'\031' | '\127' -> true | _ -> false) value)
let required fields key = match List.assoc_opt key fields with
  | Some (`String value) when safe_text value -> Ok value | _ -> invalid key
let optional fields key = match List.assoc_opt key fields with
  | None | Some (`String "") -> Ok None
  | Some (`String value) when safe_text value -> Ok (Some value)
  | _ -> invalid key
let bool fields key = match List.assoc_opt key fields with Some (`Bool value) -> Ok value | _ -> invalid key
let env_name value =
  let first = function 'A'..'Z' | 'a'..'z' | '_' -> true | _ -> false in
  let rest c = first c || (c >= '0' && c <= '9') in
  String.length value > 0 && first value.[0] && String.for_all rest value
let valid_endpoint value =
  try
    let uri = Uri.of_string value in
    List.mem (Uri.scheme uri) [Some "http";Some "https"] && Uri.host uri <> None
    && Uri.userinfo uri = None && Uri.query uri = [] && Uri.fragment uri = None
    && (match Uri.port uri with None -> true | Some port -> port >= 1 && port <= 65535)
  with Invalid_argument _ -> false
let valid_path value =
  let uri = Uri.of_string value in
  safe_text value && String.starts_with ~prefix:"/" value
  && Uri.scheme uri = None && Uri.host uri = None && Uri.query uri = [] && Uri.fragment uri = None
(* Match pathlib's lexical POSIX File spelling without resolving symlinks or
   reading a credential. Parent traversal remains explicit, as in the input. *)
let reference_path path =
  let prefix = if String.starts_with ~prefix:"//" path && not (String.starts_with ~prefix:"///" path) then "//" else "/" in
  prefix ^ String.concat "/" (List.filter (fun part -> part <> "" && part <> ".") (String.split_on_char '/' path))
let of_json ?home_dir = function
  | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) ->
    let* name = required fields "choice" in
    let* choice = match name with
      | "ollama" -> Ok Ollama | "llama_cpp" -> Ok Llama_cpp | "vllm" -> Ok Vllm
      | "openai_compatible" -> Ok Openai_compatible | "messages" -> Ok Messages
      | "claude_code" -> Ok Claude_code | "codex" -> Ok Codex | "antigravity" -> Ok Antigravity
      | _ -> invalid "choice" in
    let allowed = ["choice";"model";"max_context";"tools";"streaming"]
      @ (if http choice then ["endpoint";"api_key_env";"credential_file";"provider_kind";"request_path"] else ["command"])
      @ (if choice = Antigravity then ["credential_file";"timeout_s"] else []) in
    let* () = if List.for_all (fun (key,_) -> List.mem key allowed) fields then Ok () else invalid "unexpected fields" in
    let* model = required fields "model" in
    let* context = match List.assoc_opt "max_context" fields with Some (`Int value) when value > 0 -> Ok value | _ -> invalid "max_context" in
    let* tools = bool fields "tools" in let* streaming = bool fields "streaming" in
    let* transport = if http choice then (
      let* endpoint = required fields "endpoint" in
      let* () = if valid_endpoint endpoint then Ok () else invalid "endpoint" in
      let* env = optional fields "api_key_env" in
      let* file = if List.mem_assoc "credential_file" fields then required fields "credential_file" |> Result.map Option.some else Ok None in
      let* credential = match file,env with
        | Some path,None when not (Filename.is_relative path) -> Ok (Some (File_reference (reference_path path)))
        | None,Some name when env_name name -> Ok (Some (Env_reference name))
        | None,None -> Ok None | _ -> invalid "credential reference" in
      let* kind = optional fields "provider_kind" in
      let* kind = match choice,kind with
        | Ollama,(None | Some "ollama") -> Ok Ollama_kind
        | Messages,Some "anthropic" -> Ok Anthropic | Messages,Some "kimi" -> Ok Kimi
        | (Llama_cpp | Vllm | Openai_compatible),(None | Some "openai_compat") -> Ok Openai_compat
        | (Llama_cpp | Vllm | Openai_compatible),Some "glm" -> Ok Glm
        | _ -> invalid "provider_kind" in
      let* request_path = optional fields "request_path" in
      let request_path = match request_path with
        | Some path -> path
        | None -> (match choice with Ollama -> "/api/chat" | Messages -> "/v1/messages" | _ -> "/chat/completions") in
      let* () = if valid_path request_path then Ok () else invalid "request_path" in
      let api_key_env = match env with Some name -> name | None -> "" in
      Ok (Http {endpoint;credential;kind;request_path;api_key_env}))
    else (
      let* command = if List.mem_assoc "command" fields then required fields "command"
        else Ok (match choice with Claude_code -> "claude" | Codex -> "codex" | _ -> "agy") in
      let* oauth,timeout = if choice <> Antigravity then Ok (None,None) else (
        let* path = required fields "credential_file" in
        let path = match home_dir with
          | Some home when String.starts_with ~prefix:"~/" path -> Filename.concat home (String.sub path 2 (String.length path - 2))
          | Some home when path = "~" -> home | _ -> path in
        let* () = if Filename.is_relative path then invalid "credential_file" else Ok () in
        let* timeout = match List.assoc_opt "timeout_s" fields with
          | Some (`Int value) when value > 0 -> Ok (float_of_int value)
          | Some (`Float value) when Float.is_finite value && value > 0. -> Ok value
          | _ -> invalid "timeout_s" in Ok (Some (reference_path path),Some timeout)) in
      Ok (Client {command;oauth;timeout})) in
    let canonical_spec = Yojson.Safe.to_string (`Assoc (List.sort (fun (a,_) (b,_) -> String.compare a b) fields)) in
    Ok {choice;model;context;tools;streaming;transport;canonical_spec}
  | _ -> invalid "object or duplicate fields"
let quoted value = Yojson.Safe.to_string (`String value)
let table ?(array=false) path fields =
  "\n" ^ (if array then "[[" else "[") ^ String.concat "." (List.map quoted path)
  ^ (if array then "]]\n" else "]\n")
  ^ String.concat "" (List.map (fun (key,value) -> quoted key ^ " = " ^ Yojson.Safe.to_string value ^ "\n") fields)
let unverified_capabilities = ["supports_tool_choice";"supports_required_tool_choice";"supports_named_tool_choice";
  "supports_parallel_tool_calls";"supports_reasoning";"supports_response_format_json";"supports_structured_output";
  "supports_multimodal_inputs";"supports_image_input";"supports_audio_input";"supports_video_input";
  "supports_document_input";"supports_prompt_caching";"supports_top_k";"supports_min_p";"supports_seed"]
type rendered = {runtime_id:string;runtime_toml:string;model_overlay_toml:string}
let render spec =
  let name = choice_name spec.choice in
  let provider = "setup_" ^ name ^ "_" ^ Digestif.SHA256.(to_hex (digest_string spec.canonical_spec)) in
  let model_key = provider ^ "_model" in
  let runtime_id = provider ^ "." ^ model_key in
  let fields = ["display-name",`String (name ^ " / " ^ spec.model);"protocol",`String (protocol spec.choice)] in
  let transport_fields,credential = match spec.transport with
    | Http h -> ["endpoint",`String h.endpoint],h.credential
    | Client c -> ["command",`String c.command;"is-non-interactive",`Bool true]
      @ (match c.timeout with None -> [] | Some timeout -> ["timeout-s",`Float timeout]),
      Option.map (fun path -> File_reference path) c.oauth in
  let runtime = table ["providers";provider] (fields @ transport_fields) in
  let runtime = runtime ^ (if http spec.choice then table ["providers";provider;"healthcheck"]
      ["path",`String (if spec.choice=Ollama then "/api/tags" else "/models")] else "") in
  let runtime = runtime ^ (match credential with
    | Some (File_reference path) -> table ["providers";provider;"credentials"] ["type",`String "file";"path",`String path]
    | Some (Env_reference name) -> table ["providers";provider;"credentials"] ["type",`String "env";"key",`String name]
    | None -> "") in
  let runtime = runtime ^ table ["models";model_key] ["api-name",`String spec.model;"max-context",`Int spec.context;
    "tools-support",`Bool spec.tools;"streaming",`Bool spec.streaming]
    ^ table [provider;model_key] (["wizard-default",`Bool true] @ if spec.choice=Ollama then ["num-ctx",`Int spec.context] else []) in
  let overlay = match spec.transport with Client _ -> "" | Http h ->
    let kind,base = match h.kind with Openai_compat -> "openai_compat","openai_chat" | Anthropic -> "anthropic","anthropic"
      | Kimi -> "kimi","kimi" | Glm -> "glm","glm" | Ollama_kind -> "ollama","ollama" in
    table ~array:true ["models"] (["id_prefix",`String spec.model;"provider_name",`String provider;"base",`String base;
      "max_context_tokens",`Int spec.context;"supports_tools",`Bool spec.tools;"supports_native_streaming",`Bool spec.streaming]
      @ List.map (fun key -> key,`Bool false) unverified_capabilities
      @ ["thinking_control_format",`String "none";"reasoning_streaming_format",`String "none"])
    ^ table ~array:true ["providers"] ["id",`String provider;"kind",`String kind;"base_url",`String h.endpoint;
      "request_path",`String h.request_path;"api_key_env",`String h.api_key_env;"capabilities_base",`String base]
    ^ table ~array:true ["targets"] ["id",`String runtime_id;"provider_ref",`String provider;"model_id",`String spec.model] in
  {runtime_id;runtime_toml=runtime;model_overlay_toml=overlay}
let render_json value = `Assoc ["runtime_id",`String value.runtime_id;"runtime_toml",`String value.runtime_toml;
  "model_overlay_toml",`String value.model_overlay_toml]
