(** Lightweight provider configuration for standalone LLM calls.
    @since 0.46.0 *)

(** Re-exported from {!Provider_kind} so existing callers
    ([Provider_config.Anthropic], [Provider_config.string_of_provider_kind],
    …) keep working. The underlying type now lives in {!Provider_kind} so it
    can be shared with {!Types} without creating a module dependency cycle. *)
type provider_kind = Provider_kind.t =
  | Anthropic
  | Kimi
  | OpenAI_compat
  | Ollama
  | Gemini
  | Glm
  | DashScope

(** Default [request_path] for a given provider kind. Centralised so that
    [make] and any caller building a record literal stay aligned with the
    same wire-format defaults. Gemini returns [""] because
    it does not dispatch over an HTTP path. *)
let request_path_default_for_kind = function
  | Anthropic -> "/v1/messages"
  | Kimi -> "/v1/messages"
  | OpenAI_compat -> "/v1/chat/completions"
  | Ollama -> "/api/chat"
  | Gemini -> ""
  | Glm -> "/chat/completions"
  | DashScope -> "/chat/completions"
;;

type t =
  { kind : provider_kind
  ; provider_id : string option
  ; model_id : string
  ; base_url : string
  ; api_key : Secret.t
  ; headers : (string * string) list
  ; request_path : string
  ; max_tokens : int option
  ; max_context : int option
  ; max_request_body_bytes : int option
  ; temperature : float option
  ; top_p : float option
  ; top_k : int option
  ; min_p : float option
  ; system_prompt : string option
  ; enable_thinking : bool option
  ; preserve_thinking : bool option
  ; thinking_budget : int option
  ; reasoning_effort : Reasoning_effort.t option
  ; clear_thinking : bool option
  ; tool_stream : bool
  ; tool_choice : Types.tool_choice option
  ; disable_parallel_tool_use : bool
  ; response_format : Types.response_format
  ; cache_system_prompt : bool
  ; supports_tool_choice_override : bool option
  ; supports_structured_output_override : bool option
  ; model_capabilities_override : Capabilities.capabilities option
  ; keep_alive : string option
  ; internal_model_rotation_count : int option
  ; num_ctx : int option
  ; seed : int option
  ; previous_response_id : string option
  ; connect_timeout_s : float option
  ; max_concurrent_requests : int option
  }

let make
      ~kind
      ~model_id
      ~base_url
      ?provider_id
      ?(api_key = "")
      ?(headers = [ "Content-Type", "application/json" ])
      ?request_path
      ?max_tokens
      ?max_context
      ?max_request_body_bytes
      ?temperature
      ?top_p
      ?top_k
      ?min_p
      ?system_prompt
      ?enable_thinking
      ?preserve_thinking
      ?thinking_budget
      ?reasoning_effort
      ?clear_thinking
      ?(tool_stream = false)
      ?tool_choice
      ?(disable_parallel_tool_use = false)
      ?(response_format = Types.Off)
      ?(cache_system_prompt = false)
      ?supports_tool_choice_override
      ?supports_structured_output_override
      ?model_capabilities_override
      ?keep_alive
      ?internal_model_rotation_count
      ?num_ctx
      ?seed
      ?previous_response_id
      ?connect_timeout_s
      ?max_concurrent_requests
      ()
  =
  let request_path =
    match request_path with
    | Some p -> p
    | None -> request_path_default_for_kind kind
  in
  let provider_id =
    Option.map
      (fun raw ->
         let trimmed = String.trim raw in
         if trimmed = ""
         then invalid_arg "Provider_config.make: provider_id must not be empty"
         else if raw <> trimmed
         then
           invalid_arg
             "Provider_config.make: provider_id must not have leading or trailing \
              whitespace"
         else String.lowercase_ascii raw)
      provider_id
  in
  { kind
  ; provider_id
  ; model_id
  ; base_url
  ; api_key = Secret.of_string api_key
  ; headers
  ; request_path
  ; max_tokens
  ; max_context
  ; max_request_body_bytes
  ; temperature
  ; top_p
  ; top_k
  ; min_p
  ; system_prompt
  ; enable_thinking
  ; preserve_thinking
  ; thinking_budget
  ; reasoning_effort
  ; clear_thinking
  ; tool_stream
  ; tool_choice
  ; disable_parallel_tool_use
  ; response_format
  ; cache_system_prompt
  ; supports_tool_choice_override
  ; supports_structured_output_override
  ; model_capabilities_override
  ; keep_alive
  ; internal_model_rotation_count
  ; num_ctx
  ; seed
  ; previous_response_id
  ; connect_timeout_s
  ; max_concurrent_requests
  }
;;

(** Helpers for [provider_kind]. Implementations live in {!Provider_kind};
    these re-exports keep the call-site [Provider_config.*] namespace
    unchanged while the underlying type is hoisted to a shared module. *)
let string_of_provider_kind = Provider_kind.to_string

let provider_kind_of_string = Provider_kind.of_string
let all_provider_kinds = Provider_kind.all
let default_api_key_env = Provider_kind.default_api_key_env
let pp_provider_kind = Provider_kind.pp
let show_provider_kind = Provider_kind.show
let provider_kind_to_yojson = Provider_kind.to_yojson
let provider_kind_of_yojson = Provider_kind.of_yojson

let capability_provider_label (config : t) =
  Option.value config.provider_id ~default:(Provider_kind.to_string config.kind)
;;

let capabilities_for_config_model (config : t) =
  match config.model_capabilities_override with
  | Some caps -> Some caps
  | None ->
    let provider_label = capability_provider_label config in
    let allow_bare_fallback =
      match config.provider_id, config.kind with
      | Some _, _ | None, OpenAI_compat -> false
      | None, (Anthropic | Kimi | Ollama | Gemini | Glm | DashScope) -> true
    in
    Capabilities.for_provider_model_id
      ~allow_bare_fallback
      ~provider_label
      ~model_id:config.model_id
;;

(** Compute auth headers from a provider kind and secret. This is the core
    implementation shared by {!auth_headers_for_config} and
    {!auth_headers_for_kind_and_key}; it avoids constructing a dummy
    [Provider_config.t] when only kind and key are available. *)
let auth_headers_for_kind_and_secret ~(kind : provider_kind) ~(api_key : Secret.t)
  : (string * string) list
  =
  if Secret.is_empty api_key
  then []
  else (
    match kind with
    | Anthropic | Kimi -> [ "x-api-key", Secret.header_value api_key ]
    | Gemini -> [ "x-goog-api-key", Secret.header_value api_key ]
    | OpenAI_compat | Ollama | Glm | DashScope ->
      [ "Authorization", "Bearer " ^ Secret.header_value api_key ])
;;

(** Return only the auth-specific headers for a config.
    Callers merge this into [config.headers] at HTTP request time so that
    [Provider_config.t.headers] never carries sensitive tokens like API keys.
    Gemini keys are sent in the [x-goog-api-key] header and are never placed
    in the URL query string. *)
let auth_headers_for_config (config : t) : (string * string) list =
  auth_headers_for_kind_and_secret ~kind:config.kind ~api_key:config.api_key
;;

(** Same as {!auth_headers_for_config} but takes the provider kind and raw key
    as separate arguments, so a caller does not need to construct a full
    [Provider_config.t] just to compute auth headers. *)
let auth_headers_for_kind_and_key ~(kind : provider_kind) ~(api_key : string)
  : (string * string) list
  =
  auth_headers_for_kind_and_secret ~kind ~api_key:(Secret.of_string api_key)
;;

type reasoning_effort = Reasoning_effort.t =
  | None_
  | Minimal
  | Low
  | Medium
  | High
  | XHigh
  | Max

let all_reasoning_efforts = Reasoning_effort.all
let reasoning_effort_to_string = Reasoning_effort.to_string
let reasoning_effort_of_string = Reasoning_effort.of_string

(* Preserved-Thinking gate for the [Thinking_object_clear_thinking] preserve
   wire (SSOT).

   Rows declaring that wire carry the thinking toggle in a top-level [thinking]
   object and only echo prior-turn [reasoning_content] under Preserved
   Thinking — that is, when thinking is active AND [clear_thinking] is false.
   With the wire default [clear_thinking = true] the server ignores/removes
   prior-turn reasoning, so sending it back violates the documented contract and
   grows the request every turn. [clear_thinking] resolves from the explicit
   field, else the inverse of [preserve_thinking], else the wire default [true].

   Exposed on raw fields rather than on [t] because the request builders carry
   different config records ([Provider_config.t] vs [Types.agent_config]); both
   route through this one resolver so the gate cannot drift between them. *)
let clear_thinking_value ~clear_thinking ~preserve_thinking =
  match clear_thinking with
  | Some clear -> clear
  | None ->
    (match preserve_thinking with
     | Some preserve -> not preserve
     | None -> true)
;;

let preserved_thinking_active ~enable_thinking ~clear_thinking ~preserve_thinking =
  enable_thinking = Some true
  && not (clear_thinking_value ~clear_thinking ~preserve_thinking)
;;

let clear_thinking_object_request_field
      ~(preserve_thinking_control_format : Capabilities.preserve_thinking_control_format)
      ~clear_thinking
      ~preserve_thinking
  =
  match preserve_thinking_control_format with
  | Capabilities.Thinking_object_clear_thinking ->
    Some (clear_thinking_value ~clear_thinking ~preserve_thinking)
  | Capabilities.No_preserve_thinking_control
  | Capabilities.Thinking_object_keep_all
  | Capabilities.Chat_template_kwargs_preserve_thinking
  | Capabilities.Top_level_preserve_thinking
  | Capabilities.Always_preserved_thinking -> None
;;

type tool_choice_request_rejection =
  | Unsupported_named_tool_choice of
      { provider_kind : provider_kind
      ; model_id : string
      ; tool_name : string
      }
  | Unsupported_required_tool_choice of
      { provider_kind : provider_kind
      ; model_id : string
      }
  | Unsupported_named_tool_choice_with_thinking of
      { provider_kind : provider_kind
      ; model_id : string
      ; tool_name : string
      }
  | Unsupported_required_tool_choice_with_thinking of
      { provider_kind : provider_kind
      ; model_id : string
      }

let tool_choice_request_rejection_to_message = function
  | Unsupported_named_tool_choice { provider_kind; model_id; tool_name } ->
    Printf.sprintf
      "%s model %S does not support named forced tool_choice %S; use auto/none or remove \
       tool_choice"
      (string_of_provider_kind provider_kind)
      model_id
      tool_name
  | Unsupported_required_tool_choice { provider_kind; model_id } ->
    Printf.sprintf
      "%s model %S does not support required forced tool_choice; use auto/none or remove \
       tool_choice"
      (string_of_provider_kind provider_kind)
      model_id
  | Unsupported_named_tool_choice_with_thinking { provider_kind; model_id; tool_name } ->
    Printf.sprintf
      "%s model %S does not support named forced tool_choice %S when thinking is \
       enabled; use auto/none or disable thinking"
      (string_of_provider_kind provider_kind)
      model_id
      tool_name
  | Unsupported_required_tool_choice_with_thinking { provider_kind; model_id } ->
    Printf.sprintf
      "%s model %S does not support required forced tool_choice when thinking is \
       enabled; use auto/none or disable thinking"
      (string_of_provider_kind provider_kind)
      model_id
;;

let request_capabilities_for_config (config : t) =
  let caps =
    match capabilities_for_config_model config with
    | Some caps -> caps
    | None ->
      (match config.kind with
       | Glm -> Capabilities.glm_capabilities
       | Anthropic -> Capabilities.anthropic_capabilities
       | Kimi -> Capabilities.kimi_capabilities
       | Ollama -> Capabilities.ollama_capabilities
       | Gemini -> Capabilities.gemini_capabilities
       | DashScope -> Capabilities.dashscope_capabilities
       | OpenAI_compat -> Capabilities.default_capabilities)
  in
  caps
;;

let tool_choice_capabilities_for_config (config : t) =
  let caps =
    match capabilities_for_config_model config with
    | Some caps -> caps
    | None ->
      (match config.kind with
       | Glm -> Capabilities.glm_capabilities
       | Anthropic | Kimi | OpenAI_compat | Ollama | Gemini | DashScope ->
         Capabilities.default_capabilities)
  in
  match config.supports_tool_choice_override with
  | Some supports_tool_choice ->
    { caps with
      Capabilities.supports_tool_choice
    ; supports_required_tool_choice = supports_tool_choice
    ; supports_named_tool_choice = supports_tool_choice
    }
  | None -> caps
;;

let validate_tool_choice_request_with_capabilities
      ~provider_kind
      ~model_id
      ~tool_choice
      caps
  =
  match tool_choice with
  | Some Types.Any
    when (not caps.Capabilities.supports_tool_choice)
         || not caps.Capabilities.supports_required_tool_choice ->
    Error (Unsupported_required_tool_choice { provider_kind; model_id })
  | Some (Types.Tool tool_name)
    when (not caps.Capabilities.supports_tool_choice)
         || not caps.Capabilities.supports_named_tool_choice ->
    Error (Unsupported_named_tool_choice { provider_kind; model_id; tool_name })
  | Some (Types.Tool _) -> Ok ()
  | Some (Types.Auto | Types.Any | Types.None_) | None -> Ok ()
;;

let validate_anthropic_thinking_tool_choice (config : t) =
  match config.kind, config.enable_thinking, config.tool_choice with
  | Anthropic, Some true, Some Types.Any ->
    Error
      (Unsupported_required_tool_choice_with_thinking
         { provider_kind = config.kind; model_id = config.model_id })
  | Anthropic, Some true, Some (Types.Tool tool_name) ->
    Error
      (Unsupported_named_tool_choice_with_thinking
         { provider_kind = config.kind; model_id = config.model_id; tool_name })
  | Anthropic, _, _ | (Kimi | OpenAI_compat | Ollama | Gemini | Glm | DashScope), _, _ ->
    Ok ()
;;

let validate_tool_choice_request_typed (config : t) =
  match validate_anthropic_thinking_tool_choice config with
  | Error _ as error -> error
  | Ok () ->
    let caps = tool_choice_capabilities_for_config config in
    validate_tool_choice_request_with_capabilities
      ~provider_kind:config.kind
      ~model_id:config.model_id
      ~tool_choice:config.tool_choice
      caps
;;

let validate_tool_choice_request config =
  Result.map_error
    tool_choice_request_rejection_to_message
    (validate_tool_choice_request_typed config)
;;

type reasoning_effort_request_rejection =
  | Unsupported_reasoning_effort of
      { provider_kind : provider_kind
      ; model_id : string
      ; effort : reasoning_effort
      ; accepted : reasoning_effort list
      }
  | Undeclared_reasoning_effort_capability of
      { provider_kind : provider_kind
      ; model_id : string
      ; effort : reasoning_effort
      }

let reasoning_effort_list_to_message values =
  values |> List.map reasoning_effort_to_string |> String.concat "/"
;;

let reasoning_effort_request_rejection_to_message = function
  | Unsupported_reasoning_effort { provider_kind; model_id; effort; accepted } ->
    if accepted = []
    then
      Printf.sprintf
        "%s model %S does not accept categorical reasoning effort"
        (string_of_provider_kind provider_kind)
        model_id
    else
      Printf.sprintf
        "%s model %S does not accept reasoning effort %S; accepted values: %s"
        (string_of_provider_kind provider_kind)
        model_id
        (reasoning_effort_to_string effort)
        (reasoning_effort_list_to_message accepted)
  | Undeclared_reasoning_effort_capability { provider_kind; model_id; effort } ->
    Printf.sprintf
      "%s model %S has no declared categorical reasoning-effort contract; cannot send %S"
      (string_of_provider_kind provider_kind)
      model_id
      (reasoning_effort_to_string effort)
;;

let validate_reasoning_effort_request_typed (config : t) =
  match config.reasoning_effort with
  | None -> Ok ()
  | Some effort ->
    let caps = request_capabilities_for_config config in
    (match caps.Capabilities.accepted_reasoning_efforts with
     | Some accepted when not (List.mem effort accepted) ->
       Error
         (Unsupported_reasoning_effort
            { provider_kind = config.kind; model_id = config.model_id; effort; accepted })
     | Some _ -> Ok ()
     | None ->
       Error
         (Undeclared_reasoning_effort_capability
            { provider_kind = config.kind; model_id = config.model_id; effort }))
;;

let validate_reasoning_effort_request config =
  Result.map_error
    reasoning_effort_request_rejection_to_message
    (validate_reasoning_effort_request_typed config)
;;

let structured_output_name_of_schema (schema : Yojson.Safe.t) : string =
  let default_name = "structured_output" in
  let raw_name =
    match schema with
    | `Assoc fields ->
      (match List.assoc_opt "title" fields with
       | Some (`String s) when String.trim s <> "" -> s
       | _ -> default_name)
    | _ -> default_name
  in
  let normalized =
    let buf = Buffer.create (String.length raw_name) in
    let last_was_sep = ref false in
    let push_sep () =
      if Buffer.length buf > 0 && not !last_was_sep
      then (
        Buffer.add_char buf '_';
        last_was_sep := true)
    in
    String.iter
      (fun ch ->
         match ch with
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' ->
           Buffer.add_char buf (Char.lowercase_ascii ch);
           last_was_sep := false
         | '_' | '-' ->
           Buffer.add_char buf ch;
           last_was_sep := true
         | _ -> push_sep ())
      raw_name;
    Buffer.contents buf
  in
  let rec trim_bounds s =
    let len = String.length s in
    if len = 0
    then default_name
    else (
      let first = s.[0]
      and last = s.[len - 1] in
      if first = '_' || first = '-'
      then trim_bounds (String.sub s 1 (len - 1))
      else if last = '_' || last = '-'
      then trim_bounds (String.sub s 0 (len - 1))
      else s)
  in
  let trimmed = trim_bounds normalized in
  if trimmed = "" then default_name else trimmed
;;

let structured_schema_requested (config : t) : bool =
  match config.response_format with
  | Types.JsonSchema _ -> true
  | Types.JsonMode | Types.Off -> false
;;

let request_path_targets_responses_api request_path =
  let lower = String.lowercase_ascii (String.trim request_path) in
  let path =
    match String.index_opt lower '?' with
    | Some i -> String.sub lower 0 i
    | None -> lower
  in
  String.equal path "/v1/responses" || String.equal path "/responses"
;;

let validate_request_path (config : t) =
  if request_path_targets_responses_api config.request_path
  then (
    match config.kind with
    | OpenAI_compat -> Ok ()
    | Anthropic | Kimi | Ollama | Gemini | Glm | DashScope ->
      Error
        "OpenAI Responses API request_path requires provider kind OpenAI_compat; other \
         provider kinds use their own wire formats.")
  else Ok ()
;;

(* Structured-output tier admission (OAS #2744 / masc#25550 audit finding P4).
   The tier is read from the resolved model/provider capability, never from
   provider identity. [config.kind] used to gate this (GLM hard-denied, three
   kinds hard-allowed), so a capability-driven fact was decided by a vendor
   name. Now the two catalog-sourced booleans project to a typed tier
   ([Capabilities.structured_output_support]) matched exhaustively here: a
   provider that declares native json_schema is admitted and one that declares
   json_object-only is denied regardless of which vendor it is.

   Capabilities are resolved through [request_capabilities_for_config], the same
   function the request serializers use, so this decision and the wire it gates
   read one capability record. That matters when a config names no catalog row:
   the previous inline fallback dropped to [default_capabilities] (structured =
   false) and would have denied an Anthropic/Gemini/DashScope config that names
   an off-catalog model, whereas the wire path resolves it to the provider's
   base record via the [config.kind] arm below. The old kind gate admitted those
   unconditionally; routing through the shared resolver keeps that behaviour
   (their base records declare native schema) without reading identity here —
   identity selects the base capability record, it does not decide the tier. GLM
   and Kimi base records are json_object-only and stay denied. *)
let validate_output_schema_request (config : t) =
  match structured_schema_requested config with
  | false -> Ok ()
  | true ->
    let caps = request_capabilities_for_config config in
    (match Capabilities.structured_output_support caps with
     | Capabilities.Native_json_schema -> Ok ()
     | Capabilities.Json_object_only ->
       Error
         (Printf.sprintf
            "model %s advertises JSON mode (json_object) only; native json_schema output \
             is not supported by its declared capability"
            config.model_id)
     | Capabilities.No_structured_output ->
       Error
         (Printf.sprintf
            "model %s does not advertise native structured output"
            config.model_id))
;;

let has_host_prefix ~url ~prefix =
  let prefix_len = String.length prefix in
  String.length url >= prefix_len
  && String.sub url 0 prefix_len = prefix
  &&
  let next_index = prefix_len in
  String.length url = prefix_len
  || Char.equal url.[next_index] ':'
  || Char.equal url.[next_index] '/'
  || Char.equal url.[next_index] '?'
  || Char.equal url.[next_index] '#'
;;

let is_loopback_ip_literal host =
  try
    let normalized = Unix.inet_addr_of_string host |> Unix.string_of_inet_addr in
    String.equal normalized "::1"
    ||
    let is_ipv4_loopback literal =
      match String.split_on_char '.' literal with
      | first_octet :: _ -> String.equal first_octet "127"
      | _ -> false
    in
    let is_ipv4_mapped_loopback literal =
      let prefix = "::ffff:" in
      let prefix_len = String.length prefix in
      String.length literal > prefix_len
      && String.equal (String.sub literal 0 prefix_len) prefix
      && is_ipv4_loopback
           (String.sub literal prefix_len (String.length literal - prefix_len))
    in
    is_ipv4_loopback normalized || is_ipv4_mapped_loopback normalized
  with
  | Failure _ | Unix.Unix_error _ -> false
;;

let is_loopback_host host =
  let host = String.lowercase_ascii (String.trim host) in
  String.equal host "localhost" || is_loopback_ip_literal host
;;

let is_local (config : t) =
  let url = String.trim config.base_url in
  match Uri.of_string url |> Uri.host with
  | Some host -> is_loopback_host host
  | None ->
    let url = String.lowercase_ascii url in
    has_host_prefix ~url ~prefix:Constants.Endpoints.local_prefix
    || has_host_prefix ~url ~prefix:Constants.Endpoints.localhost_prefix
;;
