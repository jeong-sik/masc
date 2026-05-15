(** Runtime provider projection for MASC-owned model labels.

    OAS owns provider identity through [Agent_sdk.Provider_runtime_binding].
    This module only projects those bindings into MASC's local label and
    fallback conventions, so cascade/spawn callers do not depend on the legacy
    [Provider_adapter] boundary. *)

module Runtime_binding = Agent_sdk.Provider_runtime_binding

type runtime_kind =
  | Local
  | Cli_agent
  | Direct_api

type model_family =
  | Generic
  | Glm_general
  | Glm_coding
  | Kimi_api_family

type auto_models_source =
  | No_auto_models
  | Env_csv_or_default of
      { env_var : string
      ; defaults : string list
      ; prefer_default_model_env : bool
      }
  | Zai_general_auto_models
  | Zai_coding_auto_models

type model_policy =
  { default_model_env : string option
  ; default_model_fallback : string option
  ; auto_models : auto_models_source
  ; expand_auto : bool
  ; family : model_family
  }

type provider_profile =
  { id : string
  ; aliases : string list
  ; runtime_kind : runtime_kind
  ; cascade_prefix : string
  ; default_model_id : string option
  ; model_policy : model_policy
  ; spawn_key : string option
  }

let normalize_label label = String.trim label |> String.lowercase_ascii

let trim_nonempty value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed
;;

let env_value_opt ?(getenv = Sys.getenv_opt) name =
  match getenv name with
  | Some raw ->
    let trimmed = String.trim raw in
    if String.equal trimmed "" then None else Some trimmed
  | None -> None
;;

let csv_items raw =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun item -> not (String.equal item ""))
;;

let binding_endpoint_url (binding : Runtime_binding.t) =
  trim_nonempty binding.Runtime_binding.base_url
;;

let binding_base_url_is_loopback binding =
  match binding_endpoint_url binding with
  | None -> false
  | Some base_url -> Uri.of_string base_url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt
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

let runtime_kind_of_binding (binding : Runtime_binding.t) =
  match binding.Runtime_binding.transport with
  | Runtime_binding.Cli -> Cli_agent
  | Runtime_binding.Http | Runtime_binding.Managed | Runtime_binding.Custom_openai_compat ->
    if binding_auth_is_no_auth binding && binding_base_url_is_loopback binding
    then Local
    else Direct_api
;;

let binding_labels (binding : Runtime_binding.t) =
  let id = binding.Runtime_binding.id in
  let dashed_id = String.map (function '_' -> '-' | c -> c) id in
  let local_aliases =
    if String.equal id "llama" then [ "llama.cpp"; "llamacpp" ] else []
  in
  id :: dashed_id :: binding.Runtime_binding.aliases @ local_aliases
  |> List.filter_map trim_nonempty
  |> List.map normalize_label
  |> Json_util.dedupe_keep_order
;;

let binding_default_model_id (binding : Runtime_binding.t) =
  match Option.bind binding.Runtime_binding.default_model trim_nonempty with
  | Some _ as value -> value
  | None ->
    (match binding.Runtime_binding.capabilities.supported_models with
     | Some (model :: _) -> trim_nonempty model
     | Some [] | None -> None)
;;

let binding_env_fragment (binding : Runtime_binding.t) =
  binding.Runtime_binding.id
  |> String.map (function
    | 'a' .. 'z' as c -> Char.uppercase_ascii c
    | 'A' .. 'Z' | '0' .. '9' as c -> c
    | _ -> '_')
;;

let model_family_of_binding (binding : Runtime_binding.t) =
  match binding.Runtime_binding.kind, binding.Runtime_binding.id with
  | Llm_provider.Provider_config.Glm, "glm-coding" -> Glm_coding
  | Llm_provider.Provider_config.Glm, _ -> Glm_general
  | Llm_provider.Provider_config.Kimi, _ -> Kimi_api_family
  | _ -> Generic
;;

let first_catalog_model models = models |> List.find_map trim_nonempty

let catalog_default_model_id_of_binding (binding : Runtime_binding.t) =
  match model_family_of_binding binding with
  | Glm_general -> first_catalog_model (Llm_provider.Zai_catalog.glm_auto_models ())
  | Glm_coding -> first_catalog_model (Llm_provider.Zai_catalog.glm_coding_auto_models ())
  | Generic | Kimi_api_family -> None
;;

let default_model_id_of_binding (binding : Runtime_binding.t) =
  match binding_default_model_id binding with
  | Some _ as value -> value
  | None ->
    (match catalog_default_model_id_of_binding binding with
     | Some _ as value -> value
     | None ->
       (match runtime_kind_of_binding binding with
        | Local -> None
        | Cli_agent | Direct_api -> Some "auto"))
;;

let auto_models_of_binding binding default_model_id =
  match runtime_kind_of_binding binding with
  | Cli_agent ->
    Some
      (Env_csv_or_default
         { env_var = "MASC_" ^ binding_env_fragment binding ^ "_AUTO_MODELS"
         ; defaults = [ Option.value default_model_id ~default:"auto" ]
         ; prefer_default_model_env = false
         })
  | Local | Direct_api ->
    (match model_family_of_binding binding with
     | Glm_general -> Some Zai_general_auto_models
     | Glm_coding -> Some Zai_coding_auto_models
     | Generic | Kimi_api_family -> None)
;;

let spawn_command_keys = [ "claude"; "codex"; "gemini"; "llama" ]

let spawn_key_of_binding (binding : Runtime_binding.t) =
  match binding.Runtime_binding.command with
  | Some command when List.exists (String.equal command) spawn_command_keys -> Some command
  | Some _ | None -> None
;;

let profile_of_binding (binding : Runtime_binding.t) =
  let default_model_id = default_model_id_of_binding binding in
  let auto_models = auto_models_of_binding binding default_model_id in
  { id = binding.Runtime_binding.id
  ; aliases = binding_labels binding
  ; runtime_kind = runtime_kind_of_binding binding
  ; cascade_prefix = binding.Runtime_binding.id
  ; default_model_id
  ; model_policy =
      { default_model_env = Some (binding_env_fragment binding ^ "_DEFAULT_MODEL")
      ; default_model_fallback = default_model_id
      ; auto_models = Option.value auto_models ~default:No_auto_models
      ; expand_auto = Option.is_some auto_models
      ; family = model_family_of_binding binding
      }
  ; spawn_key = spawn_key_of_binding binding
  }
;;

let all_profiles () = Runtime_binding.all () |> List.map profile_of_binding

let find_profile_by_alias label =
  let normalized = normalize_label label in
  match Runtime_binding.find normalized with
  | Some binding -> Some (profile_of_binding binding)
  | None ->
    all_profiles ()
    |> List.find_opt (fun profile ->
      List.exists (fun alias -> String.equal alias normalized) profile.aliases)
;;

let find_profile_by_cascade_prefix label =
  let normalized = normalize_label label in
  all_profiles ()
  |> List.find_opt (fun profile ->
    String.equal (normalize_label profile.cascade_prefix) normalized)
;;

let cascade_prefix_of_provider_label label =
  find_profile_by_alias label |> Option.map (fun profile -> profile.cascade_prefix)
;;

let model_policy_for_cascade_prefix provider_name =
  find_profile_by_cascade_prefix provider_name |> Option.map (fun p -> p.model_policy)
;;

let provider_profile_for_cascade_prefix = find_profile_by_cascade_prefix

let resolve_model_policy_default ?getenv (policy : model_policy) =
  match policy.default_model_env with
  | Some env_name ->
    (match env_value_opt ?getenv env_name with
     | Some _ as value -> value
     | None -> policy.default_model_fallback)
  | None -> policy.default_model_fallback
;;

let resolve_auto_models ?getenv (policy : model_policy) =
  match policy.auto_models with
  | No_auto_models -> None
  | Zai_general_auto_models -> Some (Llm_provider.Zai_catalog.glm_auto_models ())
  | Zai_coding_auto_models -> Some (Llm_provider.Zai_catalog.glm_coding_auto_models ())
  | Env_csv_or_default { env_var; defaults; prefer_default_model_env } ->
    (match env_value_opt ?getenv env_var with
     | Some raw ->
       (match csv_items raw with
        | [] -> Some defaults
        | items -> Some items)
     | None when prefer_default_model_env ->
       (match policy.default_model_env with
        | Some default_env ->
          (match env_value_opt ?getenv default_env with
           | Some model_id -> Some [ model_id ]
           | None -> Some defaults)
        | None -> Some defaults)
     | None -> Some defaults)
;;

let default_model_id_for_cascade_prefix ?getenv provider_name =
  match model_policy_for_cascade_prefix provider_name with
  | Some policy -> resolve_model_policy_default ?getenv policy
  | None -> None
;;

let auto_models_for_cascade_prefix ?getenv provider_name =
  match model_policy_for_cascade_prefix provider_name with
  | Some policy when policy.expand_auto -> resolve_auto_models ?getenv policy
  | Some _ | None -> None
;;

let split_csv_nonempty raw =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun value -> not (String.equal value ""))
;;

let nonempty_env name = env_value_opt name

let env_present name = Option.is_some (nonempty_env name)

let configured_default_model_label_result () =
  match Env_config.Model_defaults.default_cascade_opt () with
  | Some raw ->
    let labels = split_csv_nonempty raw in
    (match labels with
     | first :: _ -> Ok first
     | [] -> Error "MASC_DEFAULT_CASCADE is set but empty")
  | None ->
    (match nonempty_env "MASC_DEFAULT_PROVIDER", nonempty_env "MASC_DEFAULT_MODEL" with
     | Some provider, Some model_id -> Ok (provider ^ ":" ^ model_id)
     | Some _, None ->
       Error "MASC_DEFAULT_MODEL is required when MASC_DEFAULT_PROVIDER is set"
     | None, Some _ ->
       Error "MASC_DEFAULT_PROVIDER is required when MASC_DEFAULT_MODEL is set"
     | None, None -> Error "No explicit default model configured")
;;

let local_runtime_provider_id () =
  all_profiles ()
  |> List.find_opt (fun profile -> profile.runtime_kind = Local)
  |> Option.map (fun profile -> profile.cascade_prefix)
;;

(* Legacy spawn still accepts [llama] as the local llama.cpp process key even
   though OAS local HTTP discovery usually surfaces as [ollama]. Keep this
   compatibility label local to spawn/default-model handling. *)
let legacy_local_spawn_prefix = "llama"

let local_model_label model_id = legacy_local_spawn_prefix ^ ":" ^ model_id

let explicit_local_model_id_result () =
  match nonempty_env "LLAMA_DEFAULT_MODEL" with
  | Some model_id -> Ok model_id
  | None ->
    (match nonempty_env "MASC_DEFAULT_PROVIDER", nonempty_env "MASC_DEFAULT_MODEL" with
     | Some provider, Some model_id
       when String.equal (String.lowercase_ascii provider) legacy_local_spawn_prefix ->
       Ok model_id
     | _ ->
       Error
         "LLAMA_DEFAULT_MODEL is not set; configure LLAMA_DEFAULT_MODEL or \
          MASC_DEFAULT_PROVIDER=llama with MASC_DEFAULT_MODEL")
;;

let explicit_local_model_label_result () =
  Result.map local_model_label (explicit_local_model_id_result ())
;;

let default_local_fallback_label () =
  match local_runtime_provider_id () with
  | Some provider_id -> provider_id ^ ":auto"
  | None -> "auto"
;;

let binding_auth_available (binding : Runtime_binding.t) =
  match binding.Runtime_binding.auth with
  | Runtime_binding.No_auth -> true
  | Runtime_binding.Cli_cached_login ->
    (match binding.Runtime_binding.command with
     | Some command -> Llm_provider.Provider_registry.command_in_path command
     | None -> false)
  | Runtime_binding.Api_key_env env_name | Runtime_binding.Setup_token_env env_name ->
    env_present env_name
  | Runtime_binding.Oauth_cached_login
  | Runtime_binding.File _
  | Runtime_binding.Exec _ -> binding.Runtime_binding.available
;;

let default_model_label_for_binding (binding : Runtime_binding.t) =
  let profile = profile_of_binding binding in
  match profile.runtime_kind with
  | Local ->
    Result.map
      (fun model_id -> profile.cascade_prefix ^ ":" ^ model_id)
      (explicit_local_model_id_result ())
  | Cli_agent | Direct_api ->
    (match profile.default_model_id with
     | Some _ -> Ok (profile.cascade_prefix ^ ":auto")
     | None ->
       Error
         (Printf.sprintf
            "Provider '%s' requires explicit runtime_model"
            profile.id))
;;

let auto_label_for_binding (binding : Runtime_binding.t) =
  if not (binding_auth_available binding)
  then None
  else (
    match default_model_label_for_binding binding with
    | Ok label -> Some label
    | Error msg ->
      Log.Misc.warn "[ProviderRuntimeProjection] default model label failed: %s" msg;
      None)
;;

let participates_in_auto_detection (binding : Runtime_binding.t) =
  let profile = profile_of_binding binding in
  (* OpenRouter has no provider-wide default model; it needs an explicit
     runtime_model despite being a normal OAS binding. Once OAS exposes that
     as catalog data, this compatibility exception can disappear. *)
  profile.runtime_kind = Direct_api
  && not (String.equal (normalize_label profile.id) "openrouter")
;;

let preferred_execution_model_labels () =
  let explicit =
    [ (match configured_default_model_label_result () with
       | Ok label -> Some label
       | Error _ -> None)
    ; (match explicit_local_model_label_result () with
       | Ok label -> Some label
       | Error _ -> None)
    ]
  in
  Json_util.dedupe_keep_order
    (List.filter_map Fun.id explicit
     @ (Runtime_binding.all ()
        |> List.filter participates_in_auto_detection
        |> List.filter_map auto_label_for_binding))
;;

let spawn_key_of_label label =
  match find_profile_by_alias label with
  | Some profile -> profile.spawn_key
  | None -> None
;;

let label_is_legacy_local_spawn label =
  String.equal (normalize_label label) legacy_local_spawn_prefix
;;

let is_bare_ollama_label label =
  (* This is the legacy native-Ollama migration guard, not a generic provider
     selection rule. [ollama:<model>] remains explicit and valid. *)
  String.equal (normalize_label label) "ollama"
  && String.equal Env_config_runtime.Ollama.default_model ""
;;

let bare_ollama_migration_message () =
  "Bare `ollama` without a model requires OLLAMA_DEFAULT_MODEL env var. Use \
   `ollama:<model>` for explicit selection."
;;
