(** Resolve a cascade name to its ordered list of model strings.

    Extracted from [cascade_config.ml]. *)

module Binding = Keeper_config_provider_binding
module Parser = Cascade_config_parser
module Selection = Cascade_config_selection
module Runtime_binding = Binding.Runtime_binding

type cascade_source =
  | Named
  | Default_fallback
  | Hardcoded_defaults
  | Load_failed of string

type selection_trace = {
  candidates : Selection.candidate_info list;
  source : cascade_source;
}

(* ── Materialized JSON helpers ───────────────────────── *)

let normalize_decl_provider_id = Binding.normalize_provider_id

let default_registry = Llm_provider.Provider_registry.default ()

let materialized_provider_json json provider_id =
  match
    Option.bind (Json_util.assoc_member_opt "providers" json) (fun providers_json ->
        Json_util.assoc_member_opt provider_id providers_json)
  with
  | Some _ as provider_json -> provider_json
  | None -> None

let materialized_provider_protocol json provider_id =
  match materialized_provider_json json provider_id with
  | Some provider_json -> Json_util.assoc_string_opt "protocol" provider_json
  | None -> None

let materialized_provider_endpoint json provider_id =
  match materialized_provider_json json provider_id with
  | Some provider_json -> Json_util.assoc_string_opt "endpoint" provider_json
  | None -> None

let direct_provider_cascade_prefix provider_id =
  match Binding.runtime_binding_of_label provider_id with
  | Some binding -> Some binding.Runtime_binding.id
  | None -> None

let registry_provider_prefix provider_id =
  match Llm_provider.Provider_registry.find default_registry provider_id with
  | Some _ -> Some provider_id
  | None ->
    let normalized = normalize_decl_provider_id provider_id in
    (match Llm_provider.Provider_registry.find default_registry normalized with
     | Some _ -> Some normalized
     | None -> None)

let openai_compatible_custom_model json provider_id api_name =
  match materialized_provider_endpoint json provider_id with
  | Some endpoint when String.trim endpoint <> "" ->
    Some (Printf.sprintf "custom:%s@%s" api_name (String.trim endpoint))
  | _ -> None

let cascade_prefix_of_decl_protocol raw =
  let kind =
    match String.trim raw |> String.lowercase_ascii with
    | "provider_a-cli" -> Some Llm_provider.Provider_config.Cli_tool_d
    | "provider_a-http" -> Some Llm_provider.Provider_config.Provider_a
    | "provider_d-cli" -> Some Llm_provider.Provider_config.Cli_tool_a
    | "provider_d-http" -> Some Llm_provider.Provider_config.Provider_d_compat
    | "provider_f-cli" -> Some Llm_provider.Provider_config.Cli_tool_b
    | "provider_c-cli" -> Some Llm_provider.Provider_config.Cli_tool_c
    | "ollama-http" -> Some Llm_provider.Provider_config.Ollama
    | _ -> None
  in
  Option.map Binding.cascade_prefix_of_provider_kind kind

let materialized_member_model_string json provider_id api_name =
  match direct_provider_cascade_prefix provider_id with
  | Some prefix -> Some (Printf.sprintf "%s:%s" prefix api_name)
  | None ->
    (match registry_provider_prefix provider_id with
     | Some prefix -> Some (Printf.sprintf "%s:%s" prefix api_name)
     | None ->
       let protocol =
         materialized_provider_protocol json provider_id
         |> Option.map (fun protocol -> String.trim protocol |> String.lowercase_ascii)
       in
       match protocol with
       | Some "provider_d-http" -> openai_compatible_custom_model json provider_id api_name
       | Some protocol ->
         cascade_prefix_of_decl_protocol protocol
         |> Option.map (fun prefix -> Printf.sprintf "%s:%s" prefix api_name)
       | None -> None)

let materialized_model_api_name json model_id =
  match
    Option.bind (Json_util.assoc_member_opt "models" json) (fun models_json ->
        Json_util.assoc_member_opt model_id models_json)
  with
  | Some model_json -> (
    match Json_util.assoc_string_opt "api-name" model_json with
    | Some _ as api_name -> api_name
    | None -> Json_util.assoc_string_opt "api_name" model_json)
  | None -> None

let weighted_entry_of_materialized_member json member =
  match String.split_on_char '.' (String.trim member) with
  | provider_id :: model_id :: _ -> (
      match materialized_model_api_name json model_id with
      | Some api_name -> (
        match materialized_member_model_string json provider_id api_name with
        | Some model ->
          Some
            {
              Keeper_config_loader.model = model;
              weight = 1;
              supports_tool_choice = None;
              secondary = None;
              secondary_supports_tool_choice = None;
            }
        | None -> None)
      | None -> None)
  | _ -> None

let configured_weighted_entries_from_materialized_json _json ~name:_ =
  []

(* ── resolve_model_strings family ────────────────────── *)

let resolve_model_strings_traced_with
    ~rand_int ?config_path ~name ~defaults () =
  match config_path with
  | Some path ->
    (match Keeper_config_loader.load_catalog_source path with
     | Error msg -> (defaults, Load_failed msg)
     | Ok json ->
       let from_file_weighted =
         configured_weighted_entries_from_materialized_json json ~name
       in
       if from_file_weighted <> [] then
         let ordered =
           Selection.order_weighted_entries
             ~rand_int ~cascade:name from_file_weighted
         in
         let models =
           List.map
             (fun (e : Keeper_config_loader.weighted_entry) -> e.model)
             ordered
         in
         (models, Named)
       else
         let fallback_profile =
           (* #19327/#19340 follow-up: bypass the catalog-aware
              [Keeper_routes_resolve.cascade_name_for_use] (which would
              re-introduce the Keeper_routes ↔ Cascade_catalog_runtime
              cycle through this module) and resolve directly from route
              bindings, falling back to the canonical route name. *)
           let route_key =
             Keeper_routes.logical_use_key Keeper_routes.Keeper_turn
           in
           match
             Keeper_routes.configured_route_bindings ~config_path:path ()
             |> List.find_map (fun (k, target) ->
                    if String.equal k route_key then Some target else None)
           with
           | Some target -> target
           | None ->
             Keeper_routes.fallback_name_for_catalog Keeper_routes.Keeper_turn
               ~catalog:[]
         in
         let fallback_weighted =
           configured_weighted_entries_from_materialized_json
             json ~name:fallback_profile
         in
         if fallback_weighted <> [] then
           let ordered =
             Selection.order_weighted_entries
               ~rand_int ~cascade:fallback_profile fallback_weighted
           in
           let models =
             List.map
               (fun (e : Keeper_config_loader.weighted_entry) -> e.model)
               ordered
           in
           (models, Default_fallback)
         else (defaults, Hardcoded_defaults))
  | None -> (defaults, Hardcoded_defaults)

let resolve_model_strings_traced ?config_path ~name ~defaults () =
  resolve_model_strings_traced_with
    ~rand_int:Selection.weighted_random_int
    ?config_path ~name ~defaults ()

let resolve_model_strings ?config_path ~name ~defaults () =
  fst (resolve_model_strings_traced ?config_path ~name ~defaults ())

(* ── Selection trace (observability) ─────────────────── *)

let selection_trace_of_weighted_entries
    ?(source = Named)
    (entries : Keeper_config_loader.weighted_entry list) : selection_trace =
  let ordered = Selection.order_weighted_entries entries in
  let candidates = List.map Selection.candidate_info_of_weighted ordered in
  { candidates; source }

let resolve_model_strings_with_trace ?config_path ~name ~defaults () =
  match config_path with
  | Some path ->
    (match Keeper_config_loader.load_catalog_source path with
     | Error msg ->
       let candidates =
         List.map (fun m ->
           Selection.candidate_info_of_weighted
             { Keeper_config_loader.model = m; weight = 1; supports_tool_choice = None;
               secondary = None; secondary_supports_tool_choice = None })
           defaults
       in
       (defaults, { candidates; source = Load_failed msg })
     | Ok json ->
    let from_file_weighted =
      configured_weighted_entries_from_materialized_json json ~name in
    if from_file_weighted <> [] then
      let ordered =
        Selection.order_weighted_entries ~cascade:name from_file_weighted
      in
      let models = List.map
          (fun (e : Keeper_config_loader.weighted_entry) -> e.model) ordered in
      let candidates = List.map Selection.candidate_info_of_weighted ordered in
      (models, { candidates; source = Named })
    else
      let fallback_profile =
        (* #19327/#19340 follow-up: bypass catalog-aware resolver to avoid
           the Keeper_routes ↔ Cascade_catalog_runtime cycle. *)
        let route_key =
          Keeper_routes.logical_use_key Keeper_routes.Keeper_turn
        in
        match
          Keeper_routes.configured_route_bindings ~config_path:path ()
          |> List.find_map (fun (k, target) ->
                 if String.equal k route_key then Some target else None)
        with
        | Some target -> target
        | None ->
          Keeper_routes.fallback_name_for_catalog Keeper_routes.Keeper_turn
            ~catalog:[]
      in
      let fallback_weighted =
        configured_weighted_entries_from_materialized_json json
          ~name:fallback_profile in
      if fallback_weighted <> [] then
        let ordered =
          Selection.order_weighted_entries
            ~cascade:fallback_profile fallback_weighted
        in
        let models = List.map
            (fun (e : Keeper_config_loader.weighted_entry) -> e.model) ordered in
        let candidates = List.map Selection.candidate_info_of_weighted ordered in
        (models, { candidates; source = Default_fallback })
      else
        let candidates =
          List.map (fun m ->
            Selection.candidate_info_of_weighted
              { Keeper_config_loader.model = m; weight = 1; supports_tool_choice = None;
               secondary = None; secondary_supports_tool_choice = None })
            defaults
        in
        (defaults, { candidates; source = Hardcoded_defaults }))
  | None ->
    let candidates =
      List.map (fun m ->
        Selection.candidate_info_of_weighted
          { Keeper_config_loader.model = m; weight = 1; supports_tool_choice = None;
               secondary = None; secondary_supports_tool_choice = None })
        defaults
    in
    (defaults, { candidates; source = Hardcoded_defaults })

let dedupe_stable (items : string list) =
  (* Stable dedupe (first occurrence wins, ordering preserved).
     Previous impl scanned a growing [seen] list via [List.mem] per
     item — O(N^2).  Use a Hashtbl for membership while keeping a
     list for the ordered output: O(N) total. *)
  let seen = Hashtbl.create (List.length items) in
  let rec loop acc = function
    | [] -> List.rev acc
    | item :: rest when Hashtbl.mem seen item -> loop acc rest
    | item :: rest ->
        Hashtbl.replace seen item ();
        loop (item :: acc) rest
  in
  loop [] items

let expand_model_strings_for_execution ?rotation_scope (items : string list) =
  items
  |> List.concat_map (Parser.expand_auto_model_string ?rotation_scope)
  |> dedupe_stable
