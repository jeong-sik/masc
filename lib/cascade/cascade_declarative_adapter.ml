(** Declarative cascade config → runtime adapter (RFC-0058 Phase 2).

    Converts a validated {!Cascade_declarative_types.cascade_config} into
    an {!adapted_catalog} that mirrors the runtime's expected shape.

    Resolution chain:
    - TOML provider.id → normalize → Provider_adapter.resolve_adapter_by_cascade_prefix
    - adapter.cascade_prefix + model_spec.api_name → "prefix:api_name" string
    - Cascade_config.parse_model_string → Provider_config.t

    @stability Internal *)

open Cascade_declarative_types

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

let resolve_provider_prefix (provider_id : string) : string option =
  match Provider_adapter.resolve_adapter_by_cascade_prefix provider_id with
  | Some adapter -> Some adapter.Provider_adapter.cascade_prefix
  | None ->
    let normalized = normalize_id provider_id in
    match Provider_adapter.resolve_adapter_by_cascade_prefix normalized with
    | Some adapter -> Some adapter.Provider_adapter.cascade_prefix
    | None -> None

(* --- Model lookup --- *)

let find_model (cfg : cascade_config) (model_id : string) :
    cascade_model_spec option =
  List.find_opt (fun (m : cascade_model_spec) -> m.id = model_id) cfg.models

(* --- Binding → Provider_config.t --- *)

let resolve_binding_config (cfg : cascade_config)
    (binding : cascade_binding)
    (errors : adapter_error list ref) :
    Llm_provider.Provider_config.t option =
  let prefix =
    match resolve_provider_prefix binding.provider_id with
    | Some p -> Some p
    | None ->
      errors := Provider_not_found binding.provider_id :: !errors;
      None
  in
  match prefix with
  | None -> None
  | Some cascade_prefix ->
    let model_spec =
      find_model cfg binding.model_id
    in
    (match model_spec with
     | None ->
       errors := Model_not_found binding.model_id :: !errors;
       None
     | Some spec ->
       let model_string =
         Printf.sprintf "%s:%s" cascade_prefix spec.api_name
       in
       let max_tokens =
         match binding.price_input, binding.price_output with
         | Some input_cost, Some _ when input_cost > 0.0 ->
           Some spec.max_context
         | _ -> None
       in
       let result =
         Cascade_config.parse_model_string
           ?max_tokens
           model_string
       in
       (match result with
        | Some config ->
          let max_concurrent =
            if binding.max_concurrent > 0 then
              Some { config with
                Llm_provider.Provider_config.internal_model_rotation_count =
                  Some binding.max_concurrent }
            else Some config
          in
          max_concurrent
        | None ->
          errors := Binding_resolution_failed
            (Printf.sprintf "%s.%s" binding.provider_id binding.model_id)
            :: !errors;
          None))

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
  | Capacity_aware -> Cascade_strategy.Capacity_aware
  | Weighted_random -> Cascade_strategy.Weighted_random
  | Circuit_breaker_cycling -> Cascade_strategy.Circuit_breaker_cycling
  | Priority_tier -> Cascade_strategy.Priority_tier
  | Sticky -> Cascade_strategy.Sticky
  | Round_robin -> Cascade_strategy.Round_robin

let map_cycle_policy (cp : cascade_cycle_policy) :
    Cascade_strategy.cycle_policy =
  {
    Cascade_strategy.max_cycles = cp.max_cycles;
    backoff_base_ms = cp.backoff_base_ms;
    backoff_cap_ms = cp.backoff_cap_ms;
  }

let map_scoring_params (sp : cascade_scoring_params) :
    Cascade_strategy.scoring_params =
  {
    Cascade_strategy.latency_baseline_ms = sp.latency_baseline_ms;
    rate_limit_recency_window_s = sp.rate_limit_recency_window_s;
    rate_limit_decay_base = sp.rate_limit_decay_base;
    rate_limit_skip_after = sp.rate_limit_skip_after;
    server_error_recency_window_s = sp.server_error_recency_window_s;
    server_error_decay_base = sp.server_error_decay_base;
    server_error_skip_after = sp.server_error_skip_after;
  }

let build_strategy (tier : cascade_tier) : Cascade_strategy.t =
  let kind = map_strategy_kind tier.strategy in
  let cycle =
    match tier.cycle_policy with
    | Some cp -> map_cycle_policy cp
    | None -> Cascade_strategy.default_cycle_policy
  in
  let sticky_ttl_ms =
    match tier.sticky_ttl_ms with
    | Some ttl -> ttl
    | None -> Cascade_strategy.default_sticky_ttl_ms
  in
  let scoring =
    match tier.scoring_params with
    | Some sp -> map_scoring_params sp
    | None -> Cascade_strategy.default_scoring_params
  in
  { Cascade_strategy.kind; cycle; tiers = []; sticky_ttl_ms; scoring }

let build_tier_group_strategy (tg : cascade_tier_group)
    (tier_tiers : string list list) : Cascade_strategy.t =
  let kind = map_strategy_kind tg.strategy in
  {
    Cascade_strategy.kind;
    cycle = Cascade_strategy.default_cycle_policy;
    tiers = tier_tiers;
    sticky_ttl_ms = 0;
    scoring = Cascade_strategy.default_scoring_params;
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
  let provider_configs =
    List.concat_map (fun (tier : cascade_tier) ->
      List.filter_map
        (resolve_member cfg bindings_by_key aliases_by_key
           resolved_configs errors)
        tier.members)
      resolved_tiers
  in
  let tier_member_keys =
    List.map (fun (tier : cascade_tier) -> tier.members) resolved_tiers
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
