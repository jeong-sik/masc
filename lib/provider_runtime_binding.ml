(** Read-only runtime provider bindings. *)

module PC = Llm_provider.Provider_catalog
module PR = Llm_provider.Provider_registry
module PConfig = Llm_provider.Provider_config
module MC = Llm_provider.Model_catalog

type provider_kind = PConfig.provider_kind
type capabilities = Llm_provider.Capabilities.capabilities

type auth =
  | No_auth
  | Api_key_env of string
  | Setup_token_env of string

type t =
  { id : string
  ; aliases : string list
  ; kind : provider_kind
  ; base_url : string
  ; request_path : string
  ; api_key_env : string
  ; auth : auth
  ; default_model : string option
  ; max_context : int option
  ; capabilities : capabilities
  ; available : bool
  ; credential_scope : string option
  }

let normalize value = String.trim value |> String.lowercase_ascii

let trim_non_empty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed
;;

let auth_of_catalog = function
  | PC.No_auth -> No_auth
  | PC.Api_key_env env -> Api_key_env env
  | PC.Setup_token_env env -> Setup_token_env env
;;

let auth_of_defaults (defaults : PR.provider_defaults) =
  match trim_non_empty defaults.api_key_env with
  | Some env -> Api_key_env env
  | None -> No_auth
;;

let registry_lookup_available registry id =
  match PR.find registry (normalize id) with
  | Some entry -> entry.is_available ()
  | None -> false
;;

let registry_lookup_max_context registry id fallback =
  match PR.find registry (normalize id) with
  | Some entry -> entry.max_context
  | _ -> fallback
;;

let binding_of_catalog_entry registry (entry : PC.entry) =
  { id = normalize entry.id
  ; aliases = List.map normalize entry.aliases
  ; kind = entry.kind
  ; base_url = entry.base_url
  ; request_path = entry.request_path
  ; api_key_env = entry.api_key_env
  ; auth = auth_of_catalog entry.auth
  ; default_model = entry.default_model
  ; max_context = registry_lookup_max_context registry entry.id entry.max_context
  ; capabilities = entry.capabilities
  ; available = registry_lookup_available registry entry.id
  ; credential_scope = entry.credential_scope
  }
;;

let binding_of_registry_entry (entry : PR.entry) =
  { id = normalize entry.name
  ; aliases = []
  ; kind = entry.defaults.kind
  ; base_url = entry.defaults.base_url
  ; request_path = entry.defaults.request_path
  ; api_key_env = entry.defaults.api_key_env
  ; auth = auth_of_defaults entry.defaults
  ; default_model = None
  ; max_context = entry.max_context
  ; capabilities = entry.capabilities
  ; available = entry.is_available ()
  ; credential_scope = None
  }
;;

let embedded_provider_entries () =
  match MC.global () with
  | None -> []
  | Some catalog -> MC.provider_entries catalog
;;

let binding_of_embedded_entry registry (entry : MC.provider_entry) =
  let registry_entry = PR.find registry entry.id in
  let capabilities =
    match registry_entry with
    | Some registered -> registered.capabilities
    | None -> Llm_provider.Capabilities.default_capabilities
  in
  { id = normalize entry.id
  ; aliases = List.map normalize entry.aliases
  ; kind = entry.kind
  ; base_url = Llm_provider.Model_provider_catalog.resolved_base_url entry
  ; request_path = entry.request_path
  ; api_key_env = entry.api_key_env
  ; auth =
      (match trim_non_empty entry.api_key_env with
       | Some env -> Api_key_env env
       | None -> No_auth)
  ; default_model = entry.default_model
  ; max_context = registry_lookup_max_context registry entry.id None
  ; capabilities
  ; available = registry_lookup_available registry entry.id
  ; credential_scope = None
  }
;;

let catalog_entries () =
  match PC.global () with
  | None -> []
  | Some catalog -> PC.entries catalog
;;

let catalog_names entries =
  entries
  |> List.concat_map (fun (entry : PC.entry) -> entry.id :: entry.aliases)
  |> List.map normalize
;;

let embedded_names entries =
  entries
  |> List.concat_map (fun (entry : MC.provider_entry) -> entry.id :: entry.aliases)
  |> List.map normalize
;;

let find_embedded_entry entries normalized =
  List.find_opt
    (fun (entry : MC.provider_entry) ->
       String.equal (normalize entry.id) normalized
       || List.exists
            (fun alias -> String.equal (normalize alias) normalized)
            entry.aliases)
    entries
;;

let sort_bindings bindings = List.sort (fun a b -> String.compare a.id b.id) bindings

let binding_by_exact_label registry normalized =
  match PC.global () with
  | Some catalog ->
    (match PC.lookup catalog normalized with
     | Some entry -> Some (binding_of_catalog_entry registry entry)
     | None ->
       (match find_embedded_entry (embedded_provider_entries ()) normalized with
        | Some entry -> Some (binding_of_embedded_entry registry entry)
        | None -> Option.map binding_of_registry_entry (PR.find registry normalized)))
  | None ->
    (match find_embedded_entry (embedded_provider_entries ()) normalized with
     | Some entry -> Some (binding_of_embedded_entry registry entry)
     | None -> Option.map binding_of_registry_entry (PR.find registry normalized))
;;

let all () =
  let registry = PR.default () in
  let catalog = catalog_entries () in
  let embedded = embedded_provider_entries () in
  let declared_name_set = catalog_names catalog @ embedded_names embedded in
  let from_catalog = List.map (binding_of_catalog_entry registry) catalog in
  let from_embedded =
    embedded
    |> List.filter (fun (entry : MC.provider_entry) ->
      not (List.mem (normalize entry.id) (catalog_names catalog)))
    |> List.map (binding_of_embedded_entry registry)
  in
  let from_registry =
    PR.all registry
    |> List.filter (fun (entry : PR.entry) ->
      not (List.mem (normalize entry.name) declared_name_set))
    |> List.map binding_of_registry_entry
  in
  sort_bindings (from_catalog @ from_embedded @ from_registry)
;;

let find label =
  let normalized = normalize label in
  if normalized = "" then None else binding_by_exact_label (PR.default ()) normalized
;;

let find_catalog label =
  let normalized = normalize label in
  if normalized = ""
  then None
  else (
    let registry = PR.default () in
    match PC.global () with
    | Some catalog ->
      Option.map (binding_of_catalog_entry registry) (PC.lookup catalog normalized)
    | None -> None)
;;

let known_labels () =
  all ()
  |> List.concat_map (fun binding -> binding.id :: binding.aliases)
  |> List.map normalize
  |> List.sort_uniq String.compare
;;

let binding_for_provider_config (cfg : PConfig.t) = Option.bind cfg.provider_id find

let canonical_explicit_provider_id (cfg : PConfig.t) =
  match cfg.provider_id with
  | Some provider_id ->
    (match find provider_id with
     | Some binding -> Some binding.id
     | None -> Some (normalize provider_id))
  | None -> None
;;

let provider_id_of_provider_config cfg =
  match canonical_explicit_provider_id cfg with
  | Some provider_id -> provider_id
  | None -> PConfig.string_of_provider_kind cfg.kind
;;

let base_capabilities_of_kind = function
  | PConfig.Ollama -> Llm_provider.Capabilities.ollama_capabilities
  | PConfig.Anthropic -> Llm_provider.Capabilities.anthropic_capabilities
  | PConfig.Kimi -> Llm_provider.Capabilities.kimi_capabilities
  | PConfig.OpenAI_compat -> Llm_provider.Capabilities.openai_compat_chat_capabilities
  | PConfig.Gemini -> Llm_provider.Capabilities.gemini_capabilities
  | PConfig.Glm -> Llm_provider.Capabilities.glm_capabilities
  | PConfig.DashScope -> Llm_provider.Capabilities.dashscope_capabilities
;;

let registry_capabilities_for_provider_config (cfg : PConfig.t) =
  match binding_for_provider_config cfg with
  | Some binding -> binding.capabilities
  | None -> base_capabilities_of_kind cfg.kind
;;

let capabilities_for_provider_config (cfg : PConfig.t) =
  let caps = registry_capabilities_for_provider_config cfg in
  let caps =
    match PConfig.capabilities_for_config_model cfg with
    | Some model_caps -> model_caps
    | None ->
      (match
         Llm_provider.Capabilities.for_provider_model_id
           ~allow_bare_fallback:false
           ~provider_label:(provider_id_of_provider_config cfg)
           ~model_id:cfg.model_id
       with
       | Some model_caps -> model_caps
       | None -> caps)
  in
  match cfg.supports_tool_choice_override with
  | Some supports_tool_choice ->
    { caps with
      supports_tool_choice
    ; supports_required_tool_choice = supports_tool_choice
    ; supports_named_tool_choice = supports_tool_choice
    }
  | None -> caps
;;

let resolve_model binding ~requested_model =
  match Option.bind requested_model trim_non_empty with
  | Some model -> Ok model
  | None ->
    (match Option.bind binding.default_model trim_non_empty with
     | Some model -> Ok model
     | None ->
       Error
         (Error.Config
            (InvalidConfig
               { field = "model"
               ; detail =
                   Printf.sprintf
                     "provider %S requires an exact model or a catalog-declared \
                      default_model"
                     binding.id
               })))
;;

let to_provider_config ?model binding =
  Result.map
    (fun model_id ->
       let request_path = trim_non_empty binding.request_path in
       let max_context = binding.max_context in
       let provider_capabilities_override =
         match
           Llm_provider.Capabilities.for_provider_model_id
             ~allow_bare_fallback:false
             ~provider_label:binding.id
             ~model_id
         with
         | Some _ -> None
         | None -> Some binding.capabilities
       in
       let supports_structured_output_override =
         Option.map
           (fun (caps : Llm_provider.Capabilities.capabilities) ->
              caps.supports_structured_output)
           provider_capabilities_override
       in
       PConfig.make
         ~kind:binding.kind
         ~provider_id:binding.id
         ~model_id
         ~base_url:binding.base_url
         ?supports_structured_output_override
         ?model_capabilities_override:provider_capabilities_override
         ?request_path
         ?max_context
         ())
    (resolve_model binding ~requested_model:model)
;;
