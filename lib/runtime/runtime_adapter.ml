(** Single-binding → [Provider_config.t] materialization (RFC-0206 §5).

    Re-homed from the deleted [Runtime_declarative_adapter]. Keeps only the
    binding materialization path:

    - TOML provider.id -> declared provider metadata (via {!Runtime_schema})
    - provider metadata + model spec -> {!Llm_provider.Provider_config.t}

    Routing (aliases / routes / system_targets / capability profiles /
    strategy mapping) and the typed [adapter_error] aggregate are dropped: a
    Runtime is one pre-selected binding. Errors are surfaced as
    [(_, string) result] so the caller fails fast (no silent fallback).

    The identity helpers ([normalize_provider_id], [default_headers_for_kind],
    [normalize_openai_compat_request_path]) lived only in the deleted
    [Runtime_config_provider_binding] and are inlined here so this module has
    no [Runtime_*] dependency.

    @stability Internal *)

module Runtime_binding = Agent_sdk.Provider_runtime_binding

(* --- Inlined from the deleted [Runtime_config_provider_binding] --- *)

(* Trim, lowercase, and replace [-] with [_] in a provider identifier so
   label/binding lookups are case- and separator-insensitive. *)
let normalize_provider_id provider_id =
  String.trim provider_id
  |> String.lowercase_ascii
  |> String.map (fun c -> if c = '-' then '_' else c)
;;

(* Returns the non-credential request headers only. The auth credential
   (Authorization / x-api-key) is intentionally NOT emitted here: the OAS
   transport derives it from [~api_key] at request time, and its contract is
   that the header list "never carries sensitive tokens" (oas api.ml auth_hdrs).
   Emitting the credential here too produced a DUPLICATE Authorization header
   that RunPod's cloudflare edge rejected with an opaque 400 before the origin
   (diagnosed 2026-06-01 via the http_client_4xx_request_header_profile log:
   2 x Authorization, 74 B each). The token still travels to OAS via [~api_key];
   only Content-Type (OAS does not set it) and the non-credential Anthropic
   version header belong here. *)
let default_headers_for_kind (kind : Llm_provider.Provider_config.provider_kind) =
  let base = [ ("Content-Type", "application/json") ] in
  match kind with
  | Anthropic -> ("anthropic-version", "2023-06-01") :: base
  | OpenAI_compat | Ollama | Gemini | Glm | Kimi | DashScope -> base
;;

let normalize_header_key key = String.lowercase_ascii (String.trim key)

let is_auth_header_key key =
  match normalize_header_key key with
  | "authorization" | "x-api-key" -> true
  | _ -> false
;;

let trim_trailing_slash path =
  if String.length path > 1 && String.ends_with ~suffix:"/" path
  then String.sub path 0 (String.length path - 1)
  else path
;;

let is_digit c = c >= '0' && c <= '9'

let is_version_segment s =
  let len = String.length s in
  len >= 2
  && s.[0] = 'v'
  &&
  let rec all_digits i = i >= len || (is_digit s.[i] && all_digits (i + 1)) in
  all_digits 1
;;

let last_path_segment path =
  match String.rindex_opt path '/' with
  | Some idx -> String.sub path (idx + 1) (String.length path - idx - 1)
  | None -> path
;;

let strip_leading_version request_path =
  let len = String.length request_path in
  if len >= 4 && request_path.[0] = '/' && request_path.[1] = 'v' && is_digit request_path.[2]
  then (
    let rec find_slash i =
      if i >= len then len
      else if request_path.[i] = '/' then i
      else find_slash (i + 1)
    in
    let slash_pos = find_slash 2 in
    String.sub request_path slash_pos (len - slash_pos))
  else request_path
;;

let normalize_openai_compat_request_path ~base_url ~request_path =
  let request_path =
    match String.trim request_path with
    | "" -> Masc_network_defaults.openai_chat_completions_path
    | path -> path
  in
  let base_path = Uri.path (Uri.of_string base_url) |> trim_trailing_slash in
  if base_path = "" || base_path = "/"
  then request_path
  else (
    let duplicated_prefix = base_path ^ "/" in
    if String.starts_with ~prefix:duplicated_prefix request_path
    then (
      let suffix_start = String.length base_path + 1 in
      "/"
      ^ String.sub request_path suffix_start (String.length request_path - suffix_start))
    else if is_version_segment (last_path_segment base_path)
            && String.length request_path >= 4
            && request_path.[0] = '/'
            && request_path.[1] = 'v'
            && is_digit request_path.[2]
    then strip_leading_version request_path
    else request_path)
;;

(* --- Provider resolution --- *)

let runtime_binding_id label =
  match Runtime_binding.find label with
  | Some binding -> Some binding.Runtime_binding.id
  | None -> None
;;

let resolve_provider_prefix (provider_id : string) : string option =
  match runtime_binding_id provider_id with
  | Some _ as found -> found
  | None ->
    let normalized = normalize_provider_id provider_id in
    runtime_binding_id normalized
;;

let find_registry_entry (provider_id : string)
    : Llm_provider.Provider_registry.entry option =
  let registry = Llm_provider.Provider_registry.default () in
  match Llm_provider.Provider_registry.find registry provider_id with
  | Some _ as found -> found
  | None ->
    (match resolve_provider_prefix provider_id with
     | Some prefix -> Llm_provider.Provider_registry.find registry prefix
     | None -> None)
;;

(* --- Credential materialization --- *)

let credential_env_candidates = function
  | "OLLAMA_CLOUD_API_KEY" -> [ "OLLAMA_CLOUD_API_KEY"; "OLLAMA_API_KEY" ]
  | key -> [ key ]
;;

let api_key_from_env key =
  credential_env_candidates key
  |> List.find_map (fun env ->
         match Sys.getenv_opt env with
         | Some value when String.trim value <> "" -> Some value
         | _ -> None)
  |> Option.value ~default:""
;;

let api_key_of_credential ?registry_entry (credential : Runtime_schema.credential option) =
  match credential with
  | Some (Env key) -> api_key_from_env key
  | Some (Inline value) -> value
  | Some (File _) -> ""
  | None ->
    (match registry_entry with
     | Some entry ->
       let env = entry.Llm_provider.Provider_registry.defaults.api_key_env in
       if env = ""
       then ""
       else
         (* NDT-OK: credential materialization is the provider boundary;
            catalog parsing stays deterministic. *)
         api_key_from_env env
     | None -> "")
;;

(* --- Provider kind resolution --- *)

(* CLI subprocess provider kinds were removed in the agent_sdk pin bump
   (oas service-name migration). No provider kind is a subprocess CLI, so a
   CLI-transport provider can never resolve to a provider kind. The reason is
   surfaced as [Error] (not [None]) so a binding dropped for this cause explains
   itself at load instead of vanishing silently (Unknown->silent-drop
   anti-pattern). *)
let provider_kind_of_cli_provider (provider : Runtime_schema.provider)
    : (Llm_provider.Provider_config.provider_kind, string) result =
  Error
    (Printf.sprintf
       "provider %S uses protocol %s over a CLI transport, which the runtime \
        adapter no longer materializes (CLI subprocess provider kinds were \
        removed in the agent_sdk pin bump)"
       provider.id
       provider.protocol)
;;

let registry_provider_kind = function
  | Some entry -> Some entry.Llm_provider.Provider_registry.defaults.kind
  | None -> None
;;

let messages_api_compatible_provider_kind = function
  | Llm_provider.Provider_config.Anthropic | Llm_provider.Provider_config.Kimi -> true
  | Llm_provider.Provider_config.OpenAI_compat
  | Llm_provider.Provider_config.Ollama
  | Llm_provider.Provider_config.Gemini
  | Llm_provider.Provider_config.Glm
  | Llm_provider.Provider_config.DashScope -> false
;;

let provider_kind_for_http_provider ?registry_entry (provider : Runtime_schema.provider)
    : (Llm_provider.Provider_config.provider_kind, string) result =
  match provider.api_format with
  | Ollama_api -> Ok Llm_provider.Provider_config.Ollama
  | Chat_completions_api ->
    (* Chat-completions keeps the historical OpenAI-compatible fallback when
       registry metadata is absent. Messages API deliberately fails closed
       below because there is no safe Anthropic-style default. *)
    Ok
      (match registry_provider_kind registry_entry with
       | Some Llm_provider.Provider_config.Ollama ->
         Llm_provider.Provider_config.OpenAI_compat
       | Some kind -> kind
       | None -> Llm_provider.Provider_config.OpenAI_compat)
  | Messages_api ->
    (match registry_provider_kind registry_entry with
     | Some kind when messages_api_compatible_provider_kind kind -> Ok kind
     | Some kind ->
       Error
         (Printf.sprintf
            "provider %S uses protocol %s, but registry kind %s is not \
             messages-compatible"
            provider.id
            provider.protocol
            (Llm_provider.Provider_config.string_of_provider_kind kind))
     | None ->
       Error
         (Printf.sprintf
            "provider %S uses protocol %s, but no OAS provider registry entry exists; \
             messages-http requires registry kind SSOT"
            provider.id
            provider.protocol))
;;

let request_path_for_http_provider ~(provider : Runtime_schema.provider) ~registry_entry ~kind
    ~base_url =
  let request_path =
    match provider.api_format, kind with
    | Runtime_schema.Chat_completions_api, Llm_provider.Provider_config.OpenAI_compat ->
      Masc_network_defaults.chat_completions_path
    | _ ->
      (match registry_entry with
       | Some entry -> entry.Llm_provider.Provider_registry.defaults.request_path
       | None -> Llm_provider.Provider_config.request_path_default_for_kind kind)
  in
  match kind with
  | Llm_provider.Provider_config.OpenAI_compat ->
    normalize_openai_compat_request_path ~base_url ~request_path
  | _ -> request_path
;;

(* --- Model capability projection --- *)

let supports_tool_choice_override_of_model_spec (spec : Runtime_schema.model_spec) =
  match spec.capabilities with
  | Some capabilities -> Some capabilities.supports_tool_choice
  | None -> None
;;

let max_output_tokens_of_model_spec (spec : Runtime_schema.model_spec) =
  match spec.capabilities with
  | Some capabilities -> capabilities.max_output_tokens
  | None -> None
;;

let effective_max_tokens_for_model spec requested =
  match requested, max_output_tokens_of_model_spec spec with
  | Some configured, Some capability -> Some (min configured capability)
  | Some configured, None -> Some configured
  | None, Some capability -> Some capability
  | None, None -> None
;;

(* --- provider × model spec → Provider_config.t ---

   v1 drops the [Provider_tool_support.runtime_capabilities_override] that the
   deleted adapter carried alongside the config (it was paired with the
   now-removed alias layer); [binding_to_provider_config] never consumed it. *)
let provider_config_from_declared_provider ?keep_alive ?num_ctx
    (provider : Runtime_schema.provider) (spec : Runtime_schema.model_spec)
    ~(max_tokens : int option) : (Llm_provider.Provider_config.t, string) result =
  let registry_entry = find_registry_entry provider.id in
  let supports_tool_choice_override = supports_tool_choice_override_of_model_spec spec in
  let max_tokens = effective_max_tokens_for_model spec max_tokens in
  match provider.transport with
  | Http base_url ->
    let base_url = Masc_network_defaults.normalize_loopback_base_url base_url in
    (match provider_kind_for_http_provider ?registry_entry provider with
     | Ok kind ->
       let request_path =
         request_path_for_http_provider ~provider ~registry_entry ~kind ~base_url
       in
       let api_key = api_key_of_credential ?registry_entry provider.credentials in
       let default_headers = default_headers_for_kind kind in
       let custom_headers =
         match provider.headers with
         | None -> []
         | Some headers ->
           List.filter (fun (key, _) -> not (is_auth_header_key key)) headers
       in
       (* TOML-declared custom headers override generated non-auth headers by
          key. Auth is carried only by [api_key] and is merged by OAS at HTTP
          request time, so [Provider_config.headers] does not duplicate secrets. *)
       let custom_keys = List.map (fun (key, _) -> normalize_header_key key) custom_headers in
       let headers =
         custom_headers
         @ List.filter
             (fun (key, _) -> not (List.mem (normalize_header_key key) custom_keys))
             default_headers
       in
       Ok
         (Llm_provider.Provider_config.make
            ~kind
            ~model_id:spec.api_name
            ~base_url
            ~api_key
            ~headers
            ~request_path
            ~max_context:spec.max_context
            ?supports_tool_choice_override
            ?max_tokens
            ?keep_alive
            ?num_ctx
            ?connect_timeout_s:provider.connect_timeout_s
            ())
     | Error reason -> Error reason)
  | Cli _ ->
    (match provider_kind_of_cli_provider provider with
     | Ok kind ->
       Ok
         (Llm_provider.Provider_config.make
            ~kind
            ~model_id:spec.api_name
            ~base_url:""
            ~api_key:(api_key_of_credential ?registry_entry provider.credentials)
            ~headers:(Option.value ~default:[] provider.headers)
            ~max_context:spec.max_context
            ?supports_tool_choice_override
            ?max_tokens
            ?keep_alive
            ?num_ctx
            ?connect_timeout_s:provider.connect_timeout_s
            ())
     | Error reason -> Error reason)
;;

(* --- binding → Provider_config.t ---

   Replaces the deleted [resolve_binding_config]/[binding_to_provider_config]
   pair. The typed [adapter_error] list is collapsed into [(_, string) result]
   strings; the override carrier is dropped (see above). *)
let binding_to_provider_config (cfg : Runtime_schema.config) (binding : Runtime_schema.binding)
    : (Llm_provider.Provider_config.t, string) result =
  match Runtime_schema.model_of_id cfg binding.model_id with
  | None -> Error (Printf.sprintf "model not found: %s" binding.model_id)
  | Some spec ->
    let max_tokens =
      match binding.price_input, binding.price_output with
      | Some input_cost, Some _ when input_cost > 0.0 -> Some spec.max_context
      | _ -> None
    in
    (match Runtime_schema.provider_of_id cfg binding.provider_id with
     | None -> Error (Printf.sprintf "provider not found: %s" binding.provider_id)
     | Some provider ->
       (* [provider_config_from_declared_provider] already returns the concrete
          reason (e.g. "provider ... uses protocol messages-http, which the
          runtime adapter cannot build a provider_config for ..."); propagate it
          verbatim instead of collapsing to a generic "resolution failed" that
          hid which provider/protocol was unmapped. *)
       provider_config_from_declared_provider
         ?keep_alive:binding.keep_alive
         ?num_ctx:binding.num_ctx
         provider
         spec
         ~max_tokens)
;;
