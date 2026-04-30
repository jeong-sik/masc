(** See {!Cascade_routes} interface. *)

type logical_use =
  | Keeper_turn
  | Phase_recovery
  | Phase_buffer
  | Tool_required
  | Governance_judge
  | Operator_judge
  | Cross_verifier
  | Verifier
  | Autoresearch
  | Adversarial_reviewer
  | Auto_responder
  | Routing
  | Openai_compat
  | Persona_generation
  | Provider_benchmark
  | Tool_rerank_use

type fallback_policy =
  | Prefer_keeper_assignable of { last_resort_profile : string }
  | Prefer_system_only of {
      preferred_profiles : string list;
      last_resort_profile : string;
    }

type route_spec = {
  use : logical_use;
  key : string;
  aliases : string list;
  fallback_policy : fallback_policy;
}

let keeper_route use key aliases =
  {
    use;
    key;
    aliases;
    fallback_policy =
      Prefer_keeper_assignable { last_resort_profile = "big_three" };
  }

let system_route use key aliases ~preferred_profiles ~last_resort_profile =
  {
    use;
    key;
    aliases;
    fallback_policy =
      Prefer_system_only { preferred_profiles; last_resort_profile };
  }

let route_specs =
  [
    keeper_route Keeper_turn "keeper_turn"
      [
        "default";
        "default_models";
        "oas-keeper_unified";
        "coding_first";
        "oas-coding_first";
        "keeper_reply";
        "keeper_unified";
      ];
    keeper_route Phase_recovery "phase_recovery" [ "local_recovery" ];
    keeper_route Phase_buffer "phase_buffer" [ "local_only" ];
    keeper_route Tool_required "tool_required"
      [ "tool_use_strict"; "resilient_breaker" ];
    keeper_route Governance_judge "governance_judge" [];
    keeper_route Operator_judge "operator_judge" [];
    keeper_route Cross_verifier "cross_verifier" [];
    keeper_route Verifier "verifier" [];
    keeper_route Autoresearch "autoresearch" [];
    keeper_route Adversarial_reviewer "adversarial_reviewer" [];
    keeper_route Auto_responder "auto_responder" [];
    keeper_route Routing "routing" [ "routing_judge" ];
    keeper_route Openai_compat "openai_compat" [];
    keeper_route Persona_generation "persona_generation" [];
    keeper_route Provider_benchmark "provider_benchmark" [];
    system_route Tool_rerank_use "llm_rerank" []
      ~preferred_profiles:[ "tool_rerank" ]
      ~last_resort_profile:"tool_rerank";
  ]

let spec_for_use use =
  match List.find_opt (fun spec -> spec.use = use) route_specs with
  | Some spec -> spec
  | None -> assert false

let all_logical_uses = List.map (fun spec -> spec.use) route_specs

let known_route_keys =
  route_specs
  |> List.map (fun spec -> spec.key)
  |> List.sort_uniq String.compare

let logical_use_key use = (spec_for_use use).key

let logical_use_of_string_opt raw =
  match String.trim raw |> String.lowercase_ascii with
  | "" -> Some Keeper_turn
  | normalized ->
      route_specs
      |> List.find_map (fun spec ->
             if String.equal normalized spec.key
                || List.mem normalized spec.aliases
             then Some spec.use
             else None)

let route_bindings_from_json = function
  | `Assoc fields -> (
      match List.assoc_opt "routes" fields with
      | Some (`Assoc routes) ->
          routes
          |> List.filter_map (fun (key, value) ->
                 match value with
                 | `String raw_target ->
                     let target = String.trim raw_target in
                     if String.equal key "" || String.equal target "" then None
                     else Some (key, target)
                 | _ -> None)
      | _ -> [])
  | _ -> []

let configured_route_bindings ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> []
  | Some path -> (
      match Cascade_config_loader.load_json path with
      | Ok json -> route_bindings_from_json json
      | Error _ -> [])

let configured_route_targets ?config_path () =
  configured_route_bindings ?config_path ()
  |> List.map snd
  |> List.sort_uniq String.compare

let configured_route_keys ?config_path () =
  configured_route_bindings ?config_path ()
  |> List.map fst
  |> List.sort_uniq String.compare

let configured_unknown_route_keys ?config_path () =
  configured_route_keys ?config_path ()
  |> List.filter (fun key -> not (List.mem key known_route_keys))

let catalog_entries ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> None
  | Some path -> (
      match Cascade_config_loader.load_catalog ~config_path:path with
      | Ok entries -> Some entries
      | Error _ -> None)

let first_keeper_assignable entries =
  entries
  |> List.find_map (fun (entry : Cascade_config_loader.catalog_entry) ->
         if entry.keeper_assignable then Some entry.name else None)

let first_system_only entries =
  entries
  |> List.find_map (fun (entry : Cascade_config_loader.catalog_entry) ->
         if entry.keeper_assignable then None else Some entry.name)

let first_catalog_name entries =
  match entries with
  | (entry : Cascade_config_loader.catalog_entry) :: _ -> Some entry.name
  | [] -> None

let first_available_name ~catalog names =
  names |> List.find_opt (fun name -> List.mem name catalog)

let fallback_from_entries use entries =
  let spec = spec_for_use use in
  let catalog_names =
    List.map (fun (entry : Cascade_config_loader.catalog_entry) -> entry.name) entries
  in
  match spec.fallback_policy with
  | Prefer_keeper_assignable { last_resort_profile } ->
      (match first_keeper_assignable entries with
       | Some name -> name
       | None ->
           Option.value (first_catalog_name entries) ~default:last_resort_profile)
  | Prefer_system_only { preferred_profiles; last_resort_profile } ->
      (match first_available_name ~catalog:catalog_names preferred_profiles with
       | Some name -> name
       | None -> (
           match first_system_only entries with
           | Some name -> name
           | None -> (
               match first_keeper_assignable entries with
               | Some name -> name
               | None ->
                   Option.value (first_catalog_name entries)
                     ~default:last_resort_profile)))

let fallback_name_for_catalog use ~catalog =
  let first_catalog = match catalog with name :: _ -> Some name | [] -> None in
  let spec = spec_for_use use in
  match spec.fallback_policy with
  | Prefer_keeper_assignable { last_resort_profile } ->
      Option.value first_catalog ~default:last_resort_profile
  | Prefer_system_only { preferred_profiles; last_resort_profile } -> (
      match first_available_name ~catalog preferred_profiles with
      | Some name -> name
      | None -> Option.value first_catalog ~default:last_resort_profile)

let logged_invalid_route_targets : (string * string, unit) Hashtbl.t =
  Hashtbl.create 8

let warn_invalid_route_target_once ~route_key ~target ~fallback =
  let key = (route_key, target) in
  if not (Hashtbl.mem logged_invalid_route_targets key) then begin
    Hashtbl.add logged_invalid_route_targets key ();
    Eio.traceln
      "[CascadeRoutes] WARN routes.%s targets missing profile %s; using %s"
      route_key target fallback
  end

let cascade_name_for_use ?config_path use =
  let route_key = logical_use_key use in
  let route_target =
    configured_route_bindings ?config_path ()
    |> List.find_map (fun (key, target) ->
           if String.equal key route_key then Some target else None)
  in
  let entries = Option.value (catalog_entries ?config_path ()) ~default:[] in
  let catalog_names =
    List.map (fun (entry : Cascade_config_loader.catalog_entry) -> entry.name) entries
  in
  let fallback = fallback_from_entries use entries in
  match route_target with
  | Some target when catalog_names = [] -> target
  | Some target when List.mem target catalog_names -> target
  | Some target ->
      warn_invalid_route_target_once ~route_key ~target ~fallback;
      fallback
  | None -> fallback
