(** Declarative cascade config → runtime adapter (RFC-0058 Phase 2).

    Converts a validated {!Cascade_declarative_types.cascade_config} into
    an {!adapted_catalog} that mirrors the runtime's expected shape.

    Resolution chain:
    - TOML provider.id -> declared provider metadata
    - TOML provider metadata + model spec -> Provider_config.t

    @stability Internal *)

open Cascade_declarative_types

module Runtime_binding = Agent_sdk.Provider_runtime_binding

type adapter_error =
  | Provider_not_found of string
  | Model_not_found of string
  | Binding_resolution_failed of string
  | Alias_resolution_failed of string
  | Strategy_mismatch of string
  | Tier_group_empty of string
  | Duplicate_route of string
  | Internal of string
[@@deriving show]

type adapted_profile = {
  name : string;
  provider_configs : Llm_provider.Provider_config.t list;
  strategy : Cascade_strategy.t;
  ollama_max_concurrent : int option;
  cli_max_concurrent : int option;
}

type adapted_catalog = {
  profiles : adapted_profile list;
  routes : (string * string) list;
  system_targets : (string * string) list;
  default_profile : string option;
  errors : adapter_error list;
}

(* --- Helpers --- *)

let normalize_id (s : string) : string =
  String.trim s |> String.lowercase_ascii
  |> String.map (fun c -> if c = '-' then '_' else c)

let err (e : adapter_error) : adapter_error list = [ e ]

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
    let normalized = normalize_id provider_id in
    runtime_binding_id normalized
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

let find_provider (cfg : cascade_config) (provider_id : string) :
    cascade_provider option =
  List.find_opt (fun (p : cascade_provider) -> p.id = provider_id) cfg.providers

let find_registry_entry (provider_id : string) :
    Llm_provider.Provider_registry.entry option =
  let registry = Llm_provider.Provider_registry.default () in
  match Llm_provider.Provider_registry.find registry provider_id with
  | Some _ as found -> found
  | None ->
    (match resolve_provider_prefix provider_id with
     | Some cascade_prefix -> Llm_provider.Provider_registry.find registry cascade_prefix
     | None -> None)

let credential_env_candidates = function
  | "OLLAMA_CLOUD_API_KEY" -> [ "OLLAMA_CLOUD_API_KEY"; "OLLAMA_API_KEY" ]
  | key -> [ key ]

let api_key_from_env key =
  credential_env_candidates key
  |> List.find_map (fun env ->
         match Sys.getenv_opt env with
         | Some value when String.trim value <> "" -> Some value
         | _ -> None)
  |> Option.value ~default:""

let api_key_of_credential ?registry_entry = function
  | Some (Env key) ->
      api_key_from_env key
  | Some (Inline value) -> value
  | Some (File _) -> ""
  | None ->
    (match registry_entry with
     | Some entry ->
       let env = entry.Llm_provider.Provider_registry.defaults.api_key_env in
       if env = ""
       then ""
       else (
         (* NDT-OK: credential materialization is the provider boundary; catalog parsing stays deterministic. *)
         api_key_from_env env)
     | None -> "")

let provider_kind_of_cli_provider (provider : cascade_provider) :
    Llm_provider.Provider_config.provider_kind option =
  let resolve_kind raw =
    Llm_provider.Provider_config.provider_kind_of_string raw
  in
  match resolve_kind provider.id with
  | Some kind when Llm_provider.Provider_config.is_subprocess_cli kind ->
    Some kind
  | _ ->
    (match resolve_provider_prefix provider.id with
     | Some cascade_prefix ->
       (match resolve_kind cascade_prefix with
        | Some kind when Llm_provider.Provider_config.is_subprocess_cli kind -> Some kind
        | _ -> None)
     | None -> None)

let provider_kind_for_http_provider ?registry_entry (provider : cascade_provider) :
    Llm_provider.Provider_config.provider_kind option =
  match provider.api_format with
  | Ollama_api -> Some Llm_provider.Provider_config.Ollama
  | Chat_completions_api ->
    Some
      (match registry_entry with
       | Some entry ->
         let kind = entry.Llm_provider.Provider_registry.defaults.kind in
         if kind = Llm_provider.Provider_config.Ollama
         then Llm_provider.Provider_config.OpenAI_compat
         else kind
       | None -> Llm_provider.Provider_config.OpenAI_compat)
  | Messages_api -> None

let request_path_for_http_provider ~provider ~registry_entry ~kind ~base_url =
  let request_path =
    match provider.api_format, kind with
    | Chat_completions_api, Llm_provider.Provider_config.OpenAI_compat ->
      Llm_provider.Provider_config.request_path_default_for_kind kind
    | _ ->
      (match registry_entry with
       | Some entry -> entry.Llm_provider.Provider_registry.defaults.request_path
       | None -> Llm_provider.Provider_config.request_path_default_for_kind kind)
  in
  match kind with
  | Llm_provider.Provider_config.OpenAI_compat ->
    Cascade_config.normalize_openai_compat_request_path ~base_url ~request_path
  | _ -> request_path

let supports_tool_choice_override_of_model_spec (spec : cascade_model_spec) =
  match spec.capabilities with
  | Some capabilities -> Some capabilities.supports_tool_choice
  | None -> None
;;

let max_output_tokens_of_model_spec (spec : cascade_model_spec) =
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

let provider_config_from_declared_provider
    (provider : cascade_provider)
    (spec : cascade_model_spec)
    ~(max_tokens : int option)
    : Llm_provider.Provider_config.t option =
  let registry_entry = find_registry_entry provider.id in
  let supports_tool_choice_override =
    supports_tool_choice_override_of_model_spec spec
  in
  let max_tokens = effective_max_tokens_for_model spec max_tokens in
  match provider.transport with
  | Http base_url ->
    let base_url = Masc_network_defaults.normalize_loopback_base_url base_url in
    (match provider_kind_for_http_provider ?registry_entry provider with
     | Some kind ->
       let request_path =
         request_path_for_http_provider ~provider ~registry_entry ~kind ~base_url
       in
       let api_key = api_key_of_credential ?registry_entry provider.credentials in
       let headers = Cascade_config.headers_with_auth ~kind ~api_key in
       Some
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
            ())
     | None -> None)
  | Cli _ ->
    (match provider_kind_of_cli_provider provider with
     | Some kind ->
       Some
         (Llm_provider.Provider_config.make
            ~kind
            ~model_id:spec.api_name
            ~base_url:""
            ~api_key:(api_key_of_credential ?registry_entry provider.credentials)
            ~headers:[]
            ~max_context:spec.max_context
            ?supports_tool_choice_override
            ?max_tokens
            ())
     | None -> None)

(* --- Model lookup --- *)

let find_model (cfg : cascade_config) (model_id : string) :
    cascade_model_spec option =
  List.find_opt (fun (m : cascade_model_spec) -> m.id = model_id) cfg.models

(* --- Binding → Provider_config.t --- *)

let resolve_binding_config (cfg : cascade_config)
    (binding : cascade_binding)
    (errors : adapter_error list ref) :
    Llm_provider.Provider_config.t option =
  let model_spec = find_model cfg binding.model_id in
  match model_spec with
  | None ->
    errors := Model_not_found binding.model_id :: !errors;
    None
  | Some spec ->
    let max_tokens =
      match binding.price_input, binding.price_output with
      | Some input_cost, Some _ when input_cost > 0.0 -> Some spec.max_context
      | _ -> None
    in
    let result =
      match find_provider cfg binding.provider_id with
      | Some provider ->
        (match provider_config_from_declared_provider provider spec ~max_tokens with
         | Some cfg -> Some cfg
         | None -> None)
      | None ->
        errors := Provider_not_found binding.provider_id :: !errors;
        None
    in
    (match result with
     | Some config ->
       if binding.max_concurrent > 0
       then
         Some
           { config with
             Llm_provider.Provider_config.internal_model_rotation_count =
               Some binding.max_concurrent
           }
       else Some config
     | None ->
       errors :=
         Binding_resolution_failed
           (Printf.sprintf "%s.%s" binding.provider_id binding.model_id)
         :: !errors;
       None)

(* --- Alias overrides --- *)

let apply_alias_overrides (base : Llm_provider.Provider_config.t)
    (alias : cascade_alias) :
    Llm_provider.Provider_config.t =
  let with_max_input =
    match alias.max_input with
    | None -> base
    | Some cap ->
      let effective_max =
        match base.Llm_provider.Provider_config.max_tokens with
        | None -> Some cap
        | Some existing -> Some (min existing cap)
      in
      { base with Llm_provider.Provider_config.max_tokens = effective_max }
  in
  let with_max_output =
    match alias.max_output with
    | None -> with_max_input
    | Some cap ->
      let effective =
        match with_max_input.Llm_provider.Provider_config.max_tokens with
        | None -> Some cap
        | Some existing -> Some (min existing cap)
      in
      { with_max_input with Llm_provider.Provider_config.max_tokens = effective }
  in
  let with_temp =
    match alias.temperature with
    | None -> with_max_output
    | Some t ->
      { with_max_output with Llm_provider.Provider_config.temperature = Some t }
  in
  let with_thinking =
    match alias.thinking_enabled with
    | None -> with_temp
    | Some enabled ->
      { with_temp with
        Llm_provider.Provider_config.enable_thinking = Some enabled }
  in
  match alias.thinking_budget with
  | None -> with_thinking
  | Some budget ->
    { with_thinking with
      Llm_provider.Provider_config.thinking_budget = Some budget }

(* --- Strategy mapping --- *)

let map_strategy_kind (decl : cascade_strategy) : Cascade_strategy.kind =
  match decl with
  | Failover -> Cascade_strategy.Failover
  | Priority_tier -> Cascade_strategy.Priority_tier

let map_cycle_policy (cp : cascade_cycle_policy) :
    Cascade_strategy.cycle_policy =
  {
    Cascade_strategy.max_cycles = cp.max_cycles;
    backoff_base_ms = cp.backoff_base_ms;
    backoff_cap_ms = cp.backoff_cap_ms;
  }

let build_strategy (tier : cascade_tier) : Cascade_strategy.t =
  let kind = map_strategy_kind tier.strategy in
  let cycle =
    match tier.cycle_policy with
    | Some cp -> map_cycle_policy cp
    | None -> Cascade_strategy.default_cycle_policy
  in
  ignore tier.sticky_ttl_ms;
  ignore tier.scoring_params;
  { Cascade_strategy.kind; cycle; tiers = [] }

let build_tier_group_strategy (tg : cascade_tier_group)
    (tier_tiers : string list list) : Cascade_strategy.t =
  let kind = map_strategy_kind tg.strategy in
  let cycle =
    match kind with
    | Cascade_strategy.Priority_tier ->
      { Cascade_strategy.default_cycle_policy with
        max_cycles = max 1 (List.length tier_tiers)
      }
    | Cascade_strategy.Failover -> Cascade_strategy.default_cycle_policy
  in
  {
    Cascade_strategy.kind;
    cycle;
    tiers = tier_tiers;
  }

(* --- Member resolution --- *)

let resolve_member (cfg : cascade_config)
    (bindings_by_key : (string, cascade_binding) Hashtbl.t)
    (aliases_by_key : (string, cascade_alias) Hashtbl.t)
    (resolved_configs : (string, Llm_provider.Provider_config.t) Hashtbl.t)
    (errors : adapter_error list ref)
    (member : string) :
    Llm_provider.Provider_config.t option =
  match Hashtbl.find_opt resolved_configs member with
  | Some config -> Some config
  | None ->
    (* Try alias first (longer keys: "p.m.a") *)
    match Hashtbl.find_opt aliases_by_key member with
    | Some alias ->
      let parent_key =
        Printf.sprintf "%s.%s" alias.provider_id alias.model_id
      in
      (match Hashtbl.find_opt resolved_configs parent_key with
       | Some base ->
         let overridden = apply_alias_overrides base alias in
         Hashtbl.replace resolved_configs member overridden;
         Some overridden
       | None ->
         errors := Alias_resolution_failed member :: !errors;
         None)
    | None ->
      (* Try binding *)
      (match Hashtbl.find_opt bindings_by_key member with
       | Some binding ->
         (match resolve_binding_config cfg binding errors with
          | Some config ->
            Hashtbl.replace resolved_configs member config;
            Some config
          | None -> None)
       | None ->
         errors := Binding_resolution_failed member :: !errors;
         None)

(* --- Tier → adapted_profile --- *)

let build_profile_from_tier (cfg : cascade_config)
    (bindings_by_key : (string, cascade_binding) Hashtbl.t)
    (aliases_by_key : (string, cascade_alias) Hashtbl.t)
    (resolved_configs : (string, Llm_provider.Provider_config.t) Hashtbl.t)
    (errors : adapter_error list ref)
    (tier : cascade_tier) :
    adapted_profile =
  let provider_configs =
    List.filter_map
      (resolve_member cfg bindings_by_key aliases_by_key
         resolved_configs errors)
      tier.members
  in
  let strategy = build_strategy tier in
  {
    name = Printf.sprintf "tier.%s" tier.name;
    provider_configs;
    strategy;
    ollama_max_concurrent = tier.max_concurrent;
    cli_max_concurrent = tier.max_concurrent;
  }

(* --- Tier-group → adapted_profile --- *)

let build_profile_from_tier_group (cfg : cascade_config)
    (bindings_by_key : (string, cascade_binding) Hashtbl.t)
    (aliases_by_key : (string, cascade_alias) Hashtbl.t)
    (resolved_configs : (string, Llm_provider.Provider_config.t) Hashtbl.t)
    (tiers_by_name : (string, cascade_tier) Hashtbl.t)
    (errors : adapter_error list ref)
    (tg : cascade_tier_group) :
    adapted_profile =
  let resolved_tiers =
    List.filter_map
      (fun name -> Hashtbl.find_opt tiers_by_name name)
      tg.tiers
  in
  let resolved_configs_by_tier =
    List.map
      (fun (tier : cascade_tier) ->
         List.filter_map
           (resolve_member cfg bindings_by_key aliases_by_key
              resolved_configs errors)
           tier.members)
      resolved_tiers
  in
  let provider_configs = List.concat resolved_configs_by_tier in
  let tier_member_keys =
    List.map
      (List.map provider_health_key_of_config)
      resolved_configs_by_tier
  in
  let strategy = build_tier_group_strategy tg tier_member_keys in
  {
    name = Printf.sprintf "tier-group.%s" tg.name;
    provider_configs;
    strategy;
    ollama_max_concurrent = None;
    cli_max_concurrent = None;
  }

(* --- Route target resolution --- *)

let resolve_route_target (target : string)
    (profile_names : string list) :
    string option =
  List.find_opt (fun name -> name = target) profile_names

(* --- System target resolution --- *)

let resolve_system_target (target : string)
    (bindings_by_key : (string, cascade_binding) Hashtbl.t)
    (aliases_by_key : (string, cascade_alias) Hashtbl.t) :
    string option =
  if Hashtbl.mem bindings_by_key target then Some target
  else if Hashtbl.mem aliases_by_key target then Some target
  else None

(* --- Default profile detection --- *)

let find_default_profile (cfg : cascade_config)
    (profile_names : string list)
    (bindings_by_key : (string, cascade_binding) Hashtbl.t) :
    string option =
  let has_default =
    List.exists (fun (b : cascade_binding) -> b.is_default) cfg.bindings
  in
  if not has_default then None
  else List.find_opt (fun name ->
    String.starts_with ~prefix:"tier." name ||
    String.starts_with ~prefix:"tier-group." name)
    profile_names

(* --- Duplicate route detection --- *)

let check_duplicate_routes (routes : cascade_route list) :
    adapter_error list =
  let names =
    List.map (fun (r : cascade_route) -> r.name) routes
  in
  let sorted = List.sort String.compare names in
  let rec dups = function
    | [] | [_] -> []
    | a :: ((b :: _) as rest) ->
      if a = b then Duplicate_route a :: dups rest
      else dups rest
  in
  dups sorted

(* --- Top-level adaptation --- *)

let adapt_config (cfg : cascade_config) : adapted_catalog =
  let errors = ref [] in

  (* Build lookup tables *)
  let bindings_by_key = Hashtbl.create 16 in
  List.iter (fun (b : cascade_binding) ->
    let key = Printf.sprintf "%s.%s" b.provider_id b.model_id in
    Hashtbl.replace bindings_by_key key b)
    cfg.bindings;

  let aliases_by_key = Hashtbl.create 16 in
  List.iter (fun (a : cascade_alias) ->
    let key = Printf.sprintf "%s.%s.%s" a.provider_id a.model_id a.name in
    Hashtbl.replace aliases_by_key key a)
    cfg.aliases;

  let tiers_by_name = Hashtbl.create 8 in
  List.iter (fun (t : cascade_tier) ->
    Hashtbl.replace tiers_by_name t.name t)
    cfg.tiers;

  (* Resolved configs cache (member key → Provider_config.t) *)
  let resolved_configs = Hashtbl.create 32 in

  (* Pre-resolve all bindings so aliases can reference them *)
  List.iter (fun (b : cascade_binding) ->
    let key = Printf.sprintf "%s.%s" b.provider_id b.model_id in
    match resolve_binding_config cfg b errors with
    | Some config -> Hashtbl.replace resolved_configs key config
    | None -> ())
    cfg.bindings;

  (* Build profiles from tiers *)
  let tier_profiles =
    List.map
      (build_profile_from_tier cfg bindings_by_key aliases_by_key
         resolved_configs errors)
      cfg.tiers
  in

  (* Build profiles from tier-groups *)
  let tg_profiles =
    List.map
      (build_profile_from_tier_group cfg bindings_by_key aliases_by_key
         resolved_configs tiers_by_name errors)
      cfg.tier_groups
  in

  let all_profiles = tier_profiles @ tg_profiles in
  let profile_names = List.map (fun p -> p.name) all_profiles in

  (* Resolve routes *)
  let route_errors = check_duplicate_routes cfg.routes in
  let routes =
    List.filter_map (fun (r : cascade_route) ->
      (* Route target can be: tier-group.X, tier.X, or a binding key *)
      let target_profile =
        if String.starts_with ~prefix:"tier-group." r.target then
          resolve_route_target r.target profile_names
        else if String.starts_with ~prefix:"tier." r.target then
          resolve_route_target r.target profile_names
        else
          (* Binding or alias key → find the profile that contains it *)
          let matching_profile =
            List.find_opt (fun (p : adapted_profile) ->
              List.exists
                (fun (pc : Llm_provider.Provider_config.t) ->
                  let model_string =
                    Printf.sprintf "%s:%s"
                      (Llm_provider.Provider_kind.to_string pc.Llm_provider.Provider_config.kind)
                      pc.Llm_provider.Provider_config.model_id
                  in
                  String.starts_with ~prefix:r.target model_string)
                p.provider_configs)
            all_profiles
          in
          match matching_profile with
          | Some p -> Some p.name
          | None -> None
      in
      match target_profile with
      | Some name -> Some (r.name, name)
      | None ->
        errors := Internal
          (Printf.sprintf "route %S target %S unresolved" r.name r.target)
          :: !errors;
        None)
      cfg.routes
  in

  (* Resolve system targets *)
  let system_targets =
    List.filter_map (fun (r : cascade_route) ->
      match resolve_system_target r.target bindings_by_key aliases_by_key with
      | Some key -> Some (r.name, key)
      | None ->
        errors := Internal
          (Printf.sprintf "system target %S unresolved" r.target)
          :: !errors;
        None)
      cfg.system_targets
  in

  (* Default profile *)
  let default_profile =
    find_default_profile cfg profile_names bindings_by_key
  in

  {
    profiles = all_profiles;
    routes;
    system_targets;
    default_profile;
    errors = List.rev (!errors) @ route_errors;
  }
