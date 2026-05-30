(** MASC-owned cascade runtime resolution helpers.

    Named cascade fallback defaults, cascade-name -> label resolution,
    label -> provider config conversion, and label context lookup all live
    here so MASC keeps ownership of cascade behavior and OAS remains a
    consumer of resolved runtime inputs. *)

let fallback_context_window = 128_000

let default_registry = Llm_provider.Provider_registry.default ()
module Runtime_binding = Agent_sdk.Provider_runtime_binding

let provider_name_of_label (label : string) : string option =
  match String.index_opt label ':' with
  | None -> None
  | Some idx ->
      if idx = 0 then None
      else Some (String.sub label 0 idx |> String.trim |> String.lowercase_ascii)

;;

let binding_is_local_runtime (binding : Runtime_binding.t) =
  match binding.Runtime_binding.transport with
  | Runtime_binding.Cli -> false
  | Runtime_binding.Http | Runtime_binding.Managed | Runtime_binding.Custom_provider_d_compat ->
      Keeper_config_provider_binding.binding_auth_is_no_auth binding
      && Keeper_config_provider_binding.binding_base_url_is_loopback binding

let local_runtime_provider_id () =
  Runtime_binding.all ()
  |> List.find_opt binding_is_local_runtime
  |> Option.map (fun binding -> binding.Runtime_binding.id)

let local_model_label model_id =
  match local_runtime_provider_id () with
  | Some provider_id -> provider_id ^ ":" ^ model_id
  | None -> "auto"

let is_typed_declarative_label_provider = function
  | "openai_compat" -> true
  | _ -> false

let cascade_name_to_string = Cascade_name.to_string

let has_execution_model_config () =
  match Provider_runtime_projection.preferred_execution_model_labels () with
  | _ :: _ -> true
  | [] -> false

let default_model_strings ~cascade_name =
  let cascade_name =
    cascade_name |> cascade_name_to_string |> Keeper_turn_profile.canonicalize
  in
  match Provider_runtime_projection.preferred_execution_model_labels () with
  | [] ->
    (* No preferred execution label is configured. Surface so dashboards can
       alert on missing execution-lane config. *)
    Cascade_metrics.on_default_label_fallback
      ~cascade:cascade_name ~reason:"no_execution_labels";
    [ Provider_runtime_projection.default_local_fallback_label () ]
  | labels -> labels

(* Local discovery removed: tier-based local/non-local classification
   no longer exists. All providers are treated uniformly. *)
let refresh_local_discovery_if_possible ?sw:_ ?net:_ (_labels : string list) : bool =
  false

let context_floor = 4_096

let effective_discovered_ctx ~static_ctx ~(discovered : int option) : int =
  match discovered with
  | Some ctx when ctx >= context_floor -> ctx
  | Some _below_floor ->
    (* Discovered value present but below the safety floor — likely
       discovery-API misbehavior or corrupted response.  Fall back to
       the static registry value and tick the counter so operators
       can alert on suspicious discovery readings (iter 27). *)
    Cascade_metrics.on_discovered_context_below_floor ();
    static_ctx
  | None -> static_ctx

let static_context_of_entry
    (entry : Llm_provider.Provider_registry.entry) : int =
  match entry.capabilities.Llm_provider.Capabilities.max_context_tokens with
  | Some caps_ctx when caps_ctx > entry.max_context ->
    (* Capability table reports a larger context than the legacy
       [max_context] field.  Pick [caps_ctx] (newer, more accurate)
       but tick the drift counter — the disagreement means operator
       updated one of two ground truths and forgot the other.
       Iter 28 telemetry. *)
    Cascade_metrics.on_context_capability_drift ~provider:entry.name;
    caps_ctx
  | _ -> entry.max_context

let max_context_of_label (label : string) : int =
  let static_ctx =
    match provider_name_of_label label with
    | None ->
      Cascade_metrics.on_max_context_fallback ~site:"label_no_provider_name";
      fallback_context_window
    | Some pname -> (
        match Llm_provider.Provider_registry.find default_registry pname with
        | Some entry -> static_context_of_entry entry
        | None ->
          Cascade_metrics.on_max_context_fallback ~site:"label_unregistered_scheme";
          fallback_context_window)
  in
  match Cascade_config.resolve_label_context label with
  | Some ctx -> effective_discovered_ctx ~static_ctx ~discovered:(Some ctx)
  | None -> static_ctx

let context_of_entry (label : string) (entry : Llm_provider.Provider_registry.entry)
    : int =
  let static_ctx = static_context_of_entry entry in
  match Cascade_config.resolve_label_context label with
  | Some discovered ->
      effective_discovered_ctx ~static_ctx ~discovered:(Some discovered)
  | None -> static_ctx

let context_of_registry_label ?(require_available = false)
    (registry : Llm_provider.Provider_registry.t) (label : string) : int option =
  match provider_name_of_label label with
  | None -> None
  | Some pname -> (
      match Llm_provider.Provider_registry.find registry pname with
      | None -> None
      | Some entry when require_available && not (entry.is_available ()) -> None
      | Some entry -> Some (context_of_entry label entry))

let context_if_available (label : string) : int option =
  context_of_registry_label ~require_available:true default_registry label

let resolve_primary_max_context_in_registry registry (labels : string list) : int =
  match
    List.find_map
      (context_of_registry_label ~require_available:true registry)
      labels
  with
  | Some ctx -> ctx
  | None ->
    Cascade_metrics.on_max_context_fallback ~site:"primary_no_available";
    fallback_context_window

let resolve_primary_max_context (labels : string list) : int =
  resolve_primary_max_context_in_registry default_registry labels

let resolve_max_cascade_context (labels : string list) : int =
  match List.filter_map context_if_available labels with
  | [] ->
    Cascade_metrics.on_max_context_fallback ~site:"cascade_max_no_available";
    fallback_context_window
  | ctxs -> List.fold_left max 0 ctxs

module For_testing = struct
  let resolve_primary_max_context_in_registry =
    resolve_primary_max_context_in_registry
end

let clamp_context_for_pure_local_labels ~(labels : string list) ~(max_context : int)
    : int =
  ignore labels;
  max_context

let model_id_of_label label =
  match String.index_opt label ':' with
  | None -> ""
  | Some idx ->
      if idx >= String.length label - 1 then ""
      else String.sub label (idx + 1) (String.length label - idx - 1) |> String.trim

let resolve_primary_model_id (labels : string list) : string =
  let rec find = function
    | [] -> ""
    | label :: rest -> (
        match provider_name_of_label label with
        | None -> find rest
        | Some pname -> (
            match Llm_provider.Provider_registry.find default_registry pname with
            | None -> find rest
            | Some entry ->
                if entry.is_available () then model_id_of_label label else find rest))
  in
  find labels

let default_local_model_label_and_id () : string * string =
  let fallback = ("auto", "auto") in
  let try_label label =
    match provider_name_of_label label with
    | None -> None
    | Some pname -> (
        match Llm_provider.Provider_registry.find default_registry pname with
        | None -> None
        | Some entry ->
            if entry.is_available () then Some (label, model_id_of_label label)
            else None)
  in
  match Provider_runtime_projection.configured_default_model_label_result () with
  | Ok label -> (
      match try_label label with
      | Some pair -> pair
      | None -> (
          match
            List.find_map
              try_label
              (Provider_runtime_projection.preferred_execution_model_labels ())
          with
          | Some pair -> pair
          | None -> fallback))
  | Error _ -> (
      match
        List.find_map
          try_label
          (Provider_runtime_projection.preferred_execution_model_labels ())
      with
      | Some pair -> pair
      | None -> fallback)

let ensure_api_keys_for_labels (labels : string list) : (unit, string) result =
  if labels = [] then Ok ()
  else
    let any_available =
      List.exists
        (fun label ->
          match provider_name_of_label label with
          | None -> true
          | Some pname ->
              if is_typed_declarative_label_provider pname
              then true
              else
                match Llm_provider.Provider_registry.find default_registry pname with
                | None -> false
                | Some entry -> entry.is_available ())
        labels
    in
    if any_available then Ok ()
    else
      let missing =
        List.filter_map
          (fun label ->
            match provider_name_of_label label with
            | None -> None
            | Some pname ->
                if is_typed_declarative_label_provider pname
                then None
                else
                  match Llm_provider.Provider_registry.find default_registry pname with
                  | None -> Some (Printf.sprintf "%s (unknown provider)" pname)
                  | Some entry ->
                      if entry.defaults.api_key_env = "" then None
                      else if entry.is_available () then None
                      else Some entry.defaults.api_key_env)
          labels
      in
      Error
        (Printf.sprintf "No valid/available model specs for labels: %s (missing: %s)"
           (String.concat ", " labels)
           (String.concat ", " missing))

let apply_required_tool_choice_filter ?runtime_mcp_policy
    ~require_tool_choice_support ~require_tool_support ~label
    (providers : Llm_provider.Provider_config.t list) =
  Provider_tool_support.apply_required_tool_use_filter ?runtime_mcp_policy
    ~require_tool_choice_support ~require_tool_support ~label providers

let cascade_config_path () : string option =
  Config_dir_resolver.log_warnings ~context:"CascadeRuntime" ();
  Config_dir_resolver.cascade_path_opt ()

let models_of_cascade_name_result cascade_name :
    (string list, string) result =
  Keeper_catalog_runtime.models_of_cascade_name
    (cascade_name_to_string cascade_name)

let models_of_cascade_name cascade_name =
  let cascade_name_string = cascade_name_to_string cascade_name in
  match models_of_cascade_name_result cascade_name with
  | Ok labels -> labels
  | Error detail ->
      let normalized =
        Keeper_turn_profile.normalize_declared_name cascade_name_string
      in
      Log.warn ~ctx:"CascadeRuntime"
        "cascade config resolve failed for %s, returning []: %s"
        normalized detail;
      []

let min_positive_int_options values =
  values
  |> List.filter_map (function Some value when value > 0 -> Some value | _ -> None)
  |> function
  | [] -> None
  | value :: rest -> Some (List.fold_left min value rest)

let strip_prefix ~prefix value =
  let prefix_len = String.length prefix in
  if String.length value >= prefix_len
     && String.equal (String.sub value 0 prefix_len) prefix
  then Some (String.sub value prefix_len (String.length value - prefix_len))
  else None

let declarative_model_max_output_tokens
    (cfg : Cascade_declarative_types.cascade_config)
    model_id =
  let open Cascade_declarative_types in
  match
    cfg.models
    |> List.find_opt
         (fun (model : cascade_model_spec) -> String.equal model.id model_id)
  with
  | None -> None
  | Some model -> (
      match model.capabilities with
      | Some caps -> caps.max_output_tokens
      | None -> None)

let declarative_member_max_output_tokens
    (cfg : Cascade_declarative_types.cascade_config)
    member =
  let open Cascade_declarative_types in
  let alias =
    cfg.aliases
    |> List.find_opt (fun (alias : cascade_alias) ->
         String.equal
           (Printf.sprintf "%s.%s.%s" alias.provider_id alias.model_id alias.name)
           member)
  in
  match alias with
  | Some alias ->
      min_positive_int_options
        [
          alias.max_output;
          declarative_model_max_output_tokens cfg alias.model_id;
        ]
  | None ->
      (match
         cfg.bindings
         |> List.find_opt
              (fun (binding : cascade_binding) ->
                 String.equal
                   (Printf.sprintf "%s.%s" binding.provider_id binding.model_id)
                   member)
       with
       | None -> None
       | Some binding -> declarative_model_max_output_tokens cfg binding.model_id)

let declarative_member_exists (cfg : Cascade_declarative_types.cascade_config) member
    =
  let open Cascade_declarative_types in
  List.exists
    (fun (alias : cascade_alias) ->
       String.equal
         (Printf.sprintf "%s.%s.%s" alias.provider_id alias.model_id alias.name)
         member)
    cfg.aliases
  || List.exists
       (fun (binding : cascade_binding) ->
          String.equal
            (Printf.sprintf "%s.%s" binding.provider_id binding.model_id)
            member)
       cfg.bindings

let declarative_members_for_profile
    (cfg : Cascade_declarative_types.cascade_config)
    profile_name =
  if declarative_member_exists cfg profile_name then [ profile_name ]
  else []

let declarative_route_target
    (cfg : Cascade_declarative_types.cascade_config)
    raw_name =
  let open Cascade_declarative_types in
  let trimmed = String.trim raw_name in
  let route_key = strip_prefix ~prefix:"route." trimmed in
  let routes = cfg.routes @ cfg.system_targets in
  match route_key with
  | None -> None
  | Some route_key ->
    routes
    |> List.find_opt (fun (route : cascade_route) -> String.equal route.name route_key)
    |> Option.map (fun route -> route.target)

let max_output_tokens_ceiling_of_cascade_name cascade_name =
  match cascade_config_path () with
  | None -> None
  | Some path -> (
      match Cascade_declarative_parser.parse_file path with
      | Error _ -> None
      | Ok cfg ->
          let raw_name = cascade_name_to_string cascade_name in
          let members =
            if declarative_member_exists cfg raw_name then [ raw_name ]
            else []
          in
          if members = [] then None
          else
            members
            |> List.map (declarative_member_max_output_tokens cfg)
            |> min_positive_int_options)

let resolve_named_providers_result ?provider_filter
    ?(require_tool_choice_support = false)
    ?(require_tool_support = false)
    ?runtime_mcp_policy
    ~cascade_name ()
    : (Llm_provider.Provider_config.t list, string) result =
  let cascade_name_string = cascade_name_to_string cascade_name in
  let label =
    Keeper_turn_profile.normalize_declared_name cascade_name_string
  in
  match
    Keeper_catalog_runtime.resolve_named_providers ?provider_filter
      ?runtime_mcp_policy ~require_tool_choice_support:false
      ~cascade_name:cascade_name_string ()
  with
  | Error _ as e -> e
  | Ok providers ->
      Ok
        (apply_required_tool_choice_filter ?runtime_mcp_policy
           ~require_tool_choice_support
           ~require_tool_support ~label providers)

let resolve_named_providers_result_strict ?provider_filter
    ?(require_tool_choice_support = false)
    ?(require_tool_support = false)
    ?runtime_mcp_policy
    ~cascade_name ()
    : (Llm_provider.Provider_config.t list, string) result =
  let cascade_name_string = cascade_name_to_string cascade_name in
  let label =
    Keeper_turn_profile.normalize_declared_name cascade_name_string
  in
  match
    Keeper_catalog_runtime.resolve_named_providers_strict ?provider_filter
      ?runtime_mcp_policy ~require_tool_choice_support:false
      ~cascade_name:cascade_name_string ()
  with
  | Error _ as e -> e
  | Ok providers ->
      Ok
        (apply_required_tool_choice_filter ?runtime_mcp_policy
           ~require_tool_choice_support
           ~require_tool_support ~label providers)

let resolve_named_providers ?provider_filter
    ?(require_tool_choice_support = false)
    ?(require_tool_support = false)
    ?runtime_mcp_policy
    ~cascade_name ()
    : Llm_provider.Provider_config.t list =
  match
    resolve_named_providers_result ?provider_filter ?runtime_mcp_policy
      ~require_tool_choice_support ~require_tool_support ~cascade_name ()
  with
  | Ok providers -> providers
  | Error detail ->
      Log.Misc.warn "cascade %s: %s"
        (Keeper_turn_profile.normalize_declared_name
           (cascade_name_to_string cascade_name))
        detail;
      []

type local_capacity = {
  total : int;
  process_active : int;
  process_available : int;
  process_queue_length : int;
  all_discovered : bool;
  endpoints_found : int;
}

let empty_capacity = {
  total = 0;
  process_active = 0;
  process_available = 0;
  process_queue_length = 0;
  all_discovered = true;
  endpoints_found = 0;
}

let local_urls_of_named_selection ~sw ~net selection =
  match
    Keeper_catalog_runtime.resolve_named_providers
      ~sw
      ~net
      ~cascade_name:selection
      ()
  with
  | Error _ -> []
  | Ok providers ->
    providers
    |> List.filter_map (fun (provider : Llm_provider.Provider_config.t) ->
           if Llm_provider.Provider_config.is_local provider
           then
             let base_url = String.trim provider.base_url in
             if base_url = "" then None else Some base_url
           else None)

(* [?config_path] was previously exposed but discarded — the downstream
   [Keeper_catalog_runtime.resolve_named_providers] resolves against the
   process-global active catalog ([lookup_active_profile]) and has no
   path-override entry point, so a non-default argument silently routed
   capacity probes to the wrong catalog. No caller actually passes the
   override (see grep across lib/ — dashboard
   judges all omit it). Removing the parameter eliminates the footgun
   instead of preserving a misleading shim. If catalog-path override
   becomes a real requirement, plumb it through [resolve_named_providers]
   and [lookup_active_profile] under an RFC. *)
let local_capacity_for_selections ~sw ~net selections =
  let local_urls =
    selections
    |> List.concat_map (fun selection ->
           match local_urls_of_named_selection ~sw ~net selection with
           | _ :: _ as urls -> urls
           | [] ->
             let fallback_profile =
               Keeper_routes_resolve.cascade_name_for_use
                 Keeper_routes.Keeper_turn
             in
             local_urls_of_named_selection ~sw ~net fallback_profile)
    |> List.sort_uniq String.compare
  in
  if local_urls = [] then empty_capacity
  else begin
    let need_probe =
      List.filter (fun url -> Keeper_throttle.lookup url = None) local_urls
    in
    if need_probe <> [] then begin
      let statuses =
        Llm_provider.Discovery.discover ~sw ~net ~endpoints:need_probe
      in
      Keeper_throttle.populate statuses
    end;
    let infos =
      List.filter_map (fun url -> Keeper_throttle.capacity url) local_urls
    in
    match infos with
    | [] -> empty_capacity
    | _ ->
      List.fold_left
        (fun acc (info : Keeper_throttle.capacity_info) ->
           { total = acc.total + info.total
           ; process_active = acc.process_active + info.process_active
           ; process_available =
               acc.process_available + info.process_available
           ; process_queue_length =
               acc.process_queue_length + info.process_queue_length
           ; all_discovered =
               acc.all_discovered
               &&
               info.source = Llm_provider.Provider_throttle.Discovered
           ; endpoints_found = acc.endpoints_found + 1
           })
        { empty_capacity with all_discovered = true }
        infos
  end
