(** Provider identity helpers shared across {!Cascade_config} submodules.

    Extracted from the original [cascade_config.ml] godfile to give the
    parsing/selection/resolve/strategy submodules a stable lowest layer.
    Surface is unchanged: {!Cascade_config} re-exports every function in
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

let cascade_prefix_of_provider_kind kind =
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
  | Llm_provider.Provider_config.OpenAI_compat
    when Llm_provider.Provider_config.is_local cfg ->
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
  | Runtime_binding.Cli_cached_login
  | Runtime_binding.Oauth_cached_login
  | Runtime_binding.Setup_token_env _
  | Runtime_binding.File _
  | Runtime_binding.Exec _ -> false
;;

let binding_base_url_is_loopback (binding : Runtime_binding.t) =
  let base_url = String.trim binding.Runtime_binding.base_url in
  if base_url = ""
  then false
  else Uri.of_string base_url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt
;;

let runtime_kind_of_binding (binding : Runtime_binding.t) =
  match binding.Runtime_binding.transport with
  | Runtime_binding.Cli -> "cli_agent"
  | Runtime_binding.Http | Runtime_binding.Managed | Runtime_binding.Custom_openai_compat ->
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

(* Build headers list with Authorization when api_key is present.
   Anthropic/Kimi use x-api-key; OpenAI-compat (including GLM) uses Bearer. *)
let headers_with_auth ~(kind : Llm_provider.Provider_config.provider_kind) ~api_key =
  let base = [("Content-Type", "application/json")] in
  if api_key = "" then base
    else match kind with
    | Anthropic | Kimi ->
        ("x-api-key", api_key)
        :: ("anthropic-version", "2023-06-01")
        :: base
    | OpenAI_compat | Ollama | Gemini | Glm | Claude_code | DashScope ->
        ("Authorization", "Bearer " ^ api_key) :: base
    | Gemini_cli | Kimi_cli | Codex_cli -> []

let trim_trailing_slash path =
  if String.length path > 1 && String.ends_with ~suffix:"/" path then
    String.sub path 0 (String.length path - 1)
  else path

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
    else request_path
