(** Projection helpers for OAS runtime provider bindings. *)

module Binding = Agent_sdk.Provider_runtime_binding
module PConfig = Llm_provider.Provider_config

type binding = Binding.t

let normalize_label value = String.trim value |> String.lowercase_ascii

let trim_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed
;;

let all = Binding.all
let id (binding : binding) = binding.Binding.id
let command (binding : binding) = binding.Binding.command

let labels (binding : binding) =
  binding.Binding.id :: binding.Binding.aliases
  |> List.filter_map trim_nonempty
  |> List.map normalize_label
  |> Json_util.dedupe_keep_order
;;

let find_by_candidates candidates =
  let rec loop = function
    | [] -> None
    | candidate :: rest ->
      (match trim_nonempty candidate with
       | None -> loop rest
       | Some label ->
         (match Binding.find label with
          | Some _ as binding -> binding
          | None -> loop rest))
  in
  loop candidates
;;

let find_unique_by_kind kind =
  match List.filter (fun (binding : binding) -> binding.Binding.kind = kind) (all ()) with
  | [ binding ] -> Some binding
  | [] | _ :: _ :: _ -> None
;;

let endpoint_url (binding : binding) = trim_nonempty binding.Binding.base_url
let default_model_id (binding : binding) = Option.bind binding.Binding.default_model trim_nonempty

let supported_models (binding : binding) =
  match binding.Binding.capabilities.supported_models with
  | Some models -> models |> List.filter_map trim_nonempty |> Json_util.dedupe_keep_order
  | None -> []
;;

let available (binding : binding) = binding.Binding.available

let auth_kind (binding : binding) =
  match binding.Binding.auth with
  | Binding.No_auth -> "none"
  | Binding.Api_key_env env -> "api_key:" ^ env
  | Binding.Cli_cached_login -> "cli_cached_login"
  | Binding.Oauth_cached_login -> "oauth_cached_login"
  | Binding.Setup_token_env env -> "setup_token:" ^ env
  | Binding.File path -> "file:" ^ path
  | Binding.Exec command -> "exec:" ^ command
;;

let auth_env_keys (binding : binding) =
  let auth_env =
    match binding.Binding.auth with
    | Binding.Api_key_env env | Binding.Setup_token_env env -> [ env ]
    | Binding.No_auth
    | Binding.Cli_cached_login
    | Binding.Oauth_cached_login
    | Binding.File _
    | Binding.Exec _ -> []
  in
  binding.Binding.api_key_env :: auth_env
  |> List.filter_map trim_nonempty
  |> Json_util.dedupe_keep_order
;;

let primary_api_key_env binding =
  match auth_env_keys binding with
  | first :: _ -> Some first
  | [] -> None
;;

let base_url_is_loopback binding =
  match endpoint_url binding with
  | None -> false
  | Some base_url -> Uri.of_string base_url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt
;;

let auth_is_no_auth (binding : binding) =
  match binding.Binding.auth with
  | Binding.No_auth -> true
  | Binding.Api_key_env _
  | Binding.Cli_cached_login
  | Binding.Oauth_cached_login
  | Binding.Setup_token_env _
  | Binding.File _
  | Binding.Exec _ -> false
;;

let has_label binding expected =
  labels binding
  |> List.exists (fun label -> String.equal label (normalize_label expected))
;;

let is_local_binding binding =
  match binding.Binding.kind with
  | PConfig.Ollama -> auth_is_no_auth binding && base_url_is_loopback binding
  | PConfig.OpenAI_compat ->
    auth_is_no_auth binding && (base_url_is_loopback binding || has_label binding "llama")
  | PConfig.Anthropic
  | PConfig.Kimi
  | PConfig.Glm
  | PConfig.DashScope
  | PConfig.Gemini
  | PConfig.Claude_code
  | PConfig.Codex_cli
  | PConfig.Gemini_cli
  | PConfig.Kimi_cli -> false
;;

let runtime_kind binding =
  match binding.Binding.transport with
  | Binding.Cli -> `Cli_agent
  | Binding.Http | Binding.Managed | Binding.Custom_openai_compat ->
    if is_local_binding binding then `Local else `Direct_api
;;

let supports_runtime_mcp_http_headers (binding : binding) =
  binding.Binding.capabilities.supports_runtime_mcp_tools
  || binding.Binding.capabilities.supports_runtime_tool_events
;;

let uses_prompt_caching (binding : binding) =
  binding.Binding.capabilities.supports_prompt_caching
  || binding.Binding.capabilities.supports_caching
;;

let usage_missing_by_design (binding : binding) =
  not binding.Binding.capabilities.emits_usage_tokens
;;

let resolve_model ?requested_model binding = Binding.resolve_model binding ~requested_model
let provider_config ?model binding = Binding.to_provider_config ?model binding
