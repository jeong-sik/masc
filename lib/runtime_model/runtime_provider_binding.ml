(** Provider identity helpers shared across {!Runtime_config} submodules.

    Extracted from the original [runtime_config.ml] godfile to give the
    parsing/selection/resolve/strategy submodules a stable lowest layer.
    Surface is unchanged: {!Runtime_config} re-exports every function in
    this module so external callers continue to use the facade.

    @stability Internal *)

module Runtime_binding = Agent_sdk.Provider_runtime_binding

let normalize_provider_id provider_id =
  String.trim provider_id
  |> String.lowercase_ascii
  |> String.map (fun c -> if c = '-' then '_' else c)
;;

let runtime_binding_of_label label =
  match Runtime_binding.find label with
  | Some _ as found -> found
  | None -> Runtime_binding.find (normalize_provider_id label)
;;

let provider_name_of_kind (kind : Llm_provider.Provider_config.provider_kind) =
  let cfg =
    Llm_provider.Provider_config.make ~kind ~model_id:"auto" ~base_url:"" ()
  in
  Llm_provider.Provider_registry.provider_name_of_config cfg
;;

let runtime_prefix_of_provider_kind kind =
  let provider_name = provider_name_of_kind kind in
  match runtime_binding_of_label provider_name with
  | Some binding -> binding.Runtime_binding.id
  | None -> provider_name
;;

let provider_label_of_config (cfg : Llm_provider.Provider_config.t) =
  match Runtime_binding.binding_for_provider_config cfg with
  | Some binding -> binding.Runtime_binding.id
  | None -> Llm_provider.Provider_registry.provider_name_of_config cfg
;;

let provider_health_key_of_config (cfg : Llm_provider.Provider_config.t) =
  match cfg.kind with
  | Llm_provider.Provider_config.OpenAI_compat ->
    let base_url = String.trim cfg.base_url in
    if base_url = ""
    then provider_label_of_config cfg
    else Printf.sprintf "%s:%s@%s" (provider_label_of_config cfg) cfg.model_id base_url
  | _ -> provider_label_of_config cfg
;;

let binding_auth_is_no_auth (binding : Runtime_binding.t) =
  match binding.Runtime_binding.auth with
  | Runtime_binding.No_auth -> true
  | Runtime_binding.Api_key_env _
  | Runtime_binding.Oauth_cached_login
  | Runtime_binding.Setup_token_env _ -> false
;;

let binding_base_url_is_loopback (binding : Runtime_binding.t) =
  let base_url = String.trim binding.Runtime_binding.base_url in
  if base_url = ""
  then false
  else Uri.of_string base_url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt
;;

let runtime_kind_of_binding (binding : Runtime_binding.t) =
  if binding_auth_is_no_auth binding && binding_base_url_is_loopback binding
  then "local"
  else "direct_api"
;;

let is_binding_local_openai_runtime (binding : Runtime_binding.t) =
  binding.Runtime_binding.kind = Llm_provider.Provider_config.OpenAI_compat
  && String.equal (runtime_kind_of_binding binding) "local"
;;

let default_local_openai_runtime_provider_id () =
  Runtime_binding.all ()
  |> List.find_opt is_binding_local_openai_runtime
  |> Option.map (fun binding -> binding.Runtime_binding.id)
;;

let local_runtime_label runtime_id =
  match default_local_openai_runtime_provider_id () with
  | Some provider_id -> provider_id ^ ":" ^ runtime_id
  | None -> runtime_id
;;

let default_local_runtime_label () =
  match default_local_openai_runtime_provider_id () with
  | Some provider_id -> provider_id ^ ":auto"
  | None -> "auto"
;;

let registry_default_base_url provider_name =
  let registry = Llm_provider.Provider_registry.default () in
  match Llm_provider.Provider_registry.find registry provider_name with
  | Some entry -> entry.defaults.base_url
  | None -> ""
;;

let provider_config_of_runtime_label label =
  let cfg_of_kind ~kind ~model_id ~base_url =
    Llm_provider.Provider_config.make ~kind ~model_id ~base_url ()
  in
  match Provider_kind_resolver.resolve label with
  | Provider_kind_resolver.Registered { provider_name; model_id; kind } ->
    let base_url = registry_default_base_url provider_name in
    Some (cfg_of_kind ~kind ~model_id ~base_url)
  | Provider_kind_resolver.Custom_url { model_id; base_url } ->
    Some
      (cfg_of_kind
         ~kind:Llm_provider.Provider_config.OpenAI_compat
         ~model_id
         ~base_url)
  | Provider_kind_resolver.Unknown _ -> None
;;

let runtime_health_key_of_label label =
  provider_config_of_runtime_label label
  |> Option.map provider_health_key_of_config
;;

let runtime_health_keys_of_labels labels =
  labels
  |> List.filter_map runtime_health_key_of_label
  |> List.sort_uniq String.compare
;;

let runtime_id_of_label label =
  match Provider_kind_resolver.resolve label with
  | Provider_kind_resolver.Registered { model_id; _ }
  | Provider_kind_resolver.Custom_url { model_id; _ } ->
    let runtime_id = String.trim model_id in
    if String.equal runtime_id "" then None else Some runtime_id
  | Provider_kind_resolver.Unknown _ -> None
;;

let runtime_id_of_label_or_raw label =
  match runtime_id_of_label label with
  | Some runtime_id -> runtime_id
  | None -> String.trim label
;;

let strip_latest_suffix runtime_id =
  let suffix = ":latest" in
  let suffix_len = String.length suffix in
  let len = String.length runtime_id in
  if len > suffix_len
     && String.equal (String.sub runtime_id (len - suffix_len) suffix_len) suffix
  then String.sub runtime_id 0 (len - suffix_len)
  else runtime_id
;;

let normalize_runtime_name_for_bucket label =
  runtime_id_of_label_or_raw label |> strip_latest_suffix
;;

let label_matches_runtime_id ~label ~runtime_id =
  let label_id = normalize_runtime_name_for_bucket label in
  let runtime_id = String.trim runtime_id |> strip_latest_suffix in
  (not (String.equal runtime_id "")) && String.equal label_id runtime_id
;;

type context_window_hint =
  { context_window : int
  ; is_local_model : bool
  }

let context_window_hint_of_labels labels =
  let _ = labels in
  { context_window = 0; is_local_model = false }
;;

let provider_name_matches_default_local_openai_runtime provider_name =
  match default_local_openai_runtime_provider_id () with
  | Some id -> String.equal (normalize_provider_id provider_name) (normalize_provider_id id)
  | None -> false
;;

let provider_name_matches_kind_default provider_name kind =
  String.equal
    (normalize_provider_id provider_name)
    (normalize_provider_id (provider_name_of_kind kind))
;;

let display_provider_name provider_name =
  match runtime_binding_of_label provider_name with
  | Some binding -> binding.Runtime_binding.id
  | None -> String.trim provider_name
;;

let default_headers_for_kind (kind : Llm_provider.Provider_config.provider_kind) =
  let base = [("Content-Type", "application/json")] in
  match kind with
  | Anthropic -> ("anthropic-version", "2023-06-01") :: base
  | OpenAI_compat | Ollama | Gemini | Glm | Kimi | DashScope -> base
;;

(* Build headers list with Authorization when api_key is present.
   Anthropic/Anthropic use x-api-key; OpenAI-compat (including GLM) uses Bearer. *)
(* Returns the non-credential request headers only. The auth credential
   (Authorization / x-api-key) is intentionally NOT emitted here: the OAS
   transport derives it from [~api_key] at request time, and its contract is
   that the header list "never carries sensitive tokens" (oas api.ml auth_hdrs).
   Emitting the credential here too produced a DUPLICATE Authorization header
   that RunPod's cloudflare edge rejected with an opaque 400 before the origin
   (diagnosed 2026-06-01 via the http_client_4xx_request_header_profile log:
   2 x Authorization). The token still travels to OAS via [~api_key]; only
   Content-Type (OAS does not set it) and the non-credential Anthropic version
   header belong here. Mirror of [Runtime_adapter.headers_with_auth] — keep in
   sync (tracked for de-duplication). *)
let headers_with_auth ~(kind : Llm_provider.Provider_config.provider_kind) ~api_key =
  let base = [("Content-Type", "application/json")] in
  if api_key = "" then base
    else match kind with
    | Anthropic ->
        ("anthropic-version", "2023-06-01") :: base
    | OpenAI_compat | Ollama | Gemini | Glm | Kimi | DashScope -> base

let trim_trailing_slash path =
  if String.length path > 1 && String.ends_with ~suffix:"/" path then
    String.sub path 0 (String.length path - 1)
  else path

let is_digit c = c >= '0' && c <= '9'

let is_version_segment s =
  let len = String.length s in
  len >= 2
  && s.[0] = 'v'
  && let rec all_digits i =
       i >= len || (is_digit s.[i] && all_digits (i + 1))
     in
     all_digits 1

let last_path_segment path =
  match String.rindex_opt path '/' with
  | Some idx -> String.sub path (idx + 1) (String.length path - idx - 1)
  | None -> path

let strip_leading_version request_path =
  let len = String.length request_path in
  if len >= 4 && request_path.[0] = '/' && request_path.[1] = 'v'
     && is_digit request_path.[2]
  then
    let rec find_slash i =
      if i >= len then len
      else if request_path.[i] = '/' then i
      else find_slash (i + 1)
    in
    let slash_pos = find_slash 2 in
    String.sub request_path slash_pos (len - slash_pos)
  else
    request_path

let normalize_openai_compat_request_path ~base_url ~request_path =
  let request_path =
    match String.trim request_path with
    | "" -> Masc_network_defaults.openai_chat_completions_path
    | path -> path
  in
  let base_path =
    Uri.path (Uri.of_string base_url) |> trim_trailing_slash
  in
  if base_path = "" || base_path = "/" then
    request_path
  else
    let duplicated_prefix = base_path ^ "/" in
    if String.starts_with ~prefix:duplicated_prefix request_path then
      let suffix_start = String.length base_path + 1 in
      "/"
      ^ String.sub request_path suffix_start
          (String.length request_path - suffix_start)
    else if is_version_segment (last_path_segment base_path)
         && String.length request_path >= 4
         && request_path.[0] = '/'
         && request_path.[1] = 'v'
         && is_digit request_path.[2]
    then
      strip_leading_version request_path
    else
      request_path
