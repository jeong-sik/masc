(** Resolve a cascade name to its ordered list of model strings.

    Extracted from [cascade_config.ml]. *)

module Binding = Cascade_config_provider_binding
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

let json_assoc_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let json_string_member key json =
  match json_assoc_opt key json with
  | Some (`String value) -> Some value
  | _ -> None

let materialized_provider_json json provider_id =
  match
    Option.bind (json_assoc_opt "providers" json) (fun providers_json ->
        json_assoc_opt provider_id providers_json)
  with
  | Some _ as provider_json -> provider_json
  | None -> None

let materialized_provider_protocol json provider_id =
  match materialized_provider_json json provider_id with
  | Some provider_json -> json_string_member "protocol" provider_json
  | None -> None

let materialized_provider_endpoint json provider_id =
  match materialized_provider_json json provider_id with
  | Some provider_json -> json_string_member "endpoint" provider_json
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
    | "anthropic-cli" -> Some Llm_provider.Provider_config.Claude_code
    | "anthropic-http" -> Some Llm_provider.Provider_config.Anthropic
    | "openai-cli" -> Some Llm_provider.Provider_config.Codex_cli
    | "openai-http" -> Some Llm_provider.Provider_config.OpenAI_compat
    | "google-cli" -> Some Llm_provider.Provider_config.Gemini_cli
    | "kimi-cli" -> Some Llm_provider.Provider_config.Kimi_cli
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
       | Some "openai-http" -> openai_compatible_custom_model json provider_id api_name
       | Some protocol ->
         cascade_prefix_of_decl_protocol protocol
         |> Option.map (fun prefix -> Printf.sprintf "%s:%s" prefix api_name)
       | None -> None)

let json_string_list_member key json =
  match json_assoc_opt key json with
  | Some (`List values) ->
    values
    |> List.filter_map (function
         | `String value -> Some value
         | _ -> None)
  | _ -> []

let materialized_model_api_name json model_id =
  match
    Option.bind (json_assoc_opt "models" json) (fun models_json ->
        json_assoc_opt model_id models_json)
  with
  | Some model_json -> (
    match json_string_member "api-name" model_json with
    | Some _ as api_name -> api_name
    | None -> json_string_member "api_name" model_json)
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
              Cascade_config_loader.model = model;
              weight = 1;
              supports_tool_choice = None;
              secondary = None;
              secondary_supports_tool_choice = None;
            }
        | None -> None)
      | None -> None)
  | _ -> None

let materialized_tier_members json tier_name =
  match
    Option.bind (json_assoc_opt "tier" json) (fun tiers_json ->
        json_assoc_opt tier_name tiers_json)
  with
  | Some tier_json -> json_string_list_member "members" tier_json
  | None -> []

let materialized_tier_group_tiers json group_name =
  match
    Option.bind (json_assoc_opt "tier-group" json) (fun groups_json ->
        json_assoc_opt group_name groups_json)
  with
  | Some group_json -> json_string_list_member "tiers" group_json
  | None -> []

let configured_weighted_entries_from_materialized_json json ~name =
  let trimmed = String.trim name in
  let candidates =
    if String.starts_with ~prefix:"tier-group." trimmed
       || String.starts_with ~prefix:"tier." trimmed
    then [ trimmed ]
    else [ trimmed; "tier-group." ^ trimmed; "tier." ^ trimmed ]
  in
  let resolve_profile profile_name =
    if String.starts_with ~prefix:"tier-group." profile_name then
      let group_name =
        String.sub profile_name 11 (String.length profile_name - 11)
      in
      Some
        (materialized_tier_group_tiers json group_name
         |> List.concat_map (materialized_tier_members json)
         |> List.filter_map (weighted_entry_of_materialized_member json))
    else if String.starts_with ~prefix:"tier." profile_name then
      let tier_name =
        String.sub profile_name 5 (String.length profile_name - 5)
      in
      Some
        (materialized_tier_members json tier_name
         |> List.filter_map (weighted_entry_of_materialized_member json))
    else None
  in
  match
    candidates
    |> List.find_map (fun candidate ->
           match resolve_profile candidate with
           | Some (_ :: _ as entries) -> Some entries
           | Some [] | None -> None)
  with
  | Some entries -> entries
  | None -> []

(* ── resolve_model_strings family ────────────────────── *)

let resolve_model_strings_traced_with
    ~rand_int ?config_path ~name ~defaults () =
  match config_path with
  | Some path ->
    (match Cascade_config_loader.load_catalog_source path with
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
             (fun (e : Cascade_config_loader.weighted_entry) -> e.model)
             ordered
         in
         (models, Named)
       else
         let fallback_profile =
           Cascade_routes.cascade_name_for_use
             ~config_path:path
             Cascade_routes.Keeper_turn
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
               (fun (e : Cascade_config_loader.weighted_entry) -> e.model)
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
    (entries : Cascade_config_loader.weighted_entry list) : selection_trace =
  let ordered = Selection.order_weighted_entries entries in
  let candidates = List.map Selection.candidate_info_of_weighted ordered in
  { candidates; source }

let resolve_model_strings_with_trace ?config_path ~name ~defaults () =
  match config_path with
  | Some path ->
    (match Cascade_config_loader.load_catalog_source path with
     | Error msg ->
       let candidates =
         List.map (fun m ->
           Selection.candidate_info_of_weighted
             { Cascade_config_loader.model = m; weight = 1; supports_tool_choice = None;
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
          (fun (e : Cascade_config_loader.weighted_entry) -> e.model) ordered in
      let candidates = List.map Selection.candidate_info_of_weighted ordered in
      (models, { candidates; source = Named })
    else
      let fallback_profile =
        Cascade_routes.cascade_name_for_use
          ~config_path:path
          Cascade_routes.Keeper_turn
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
            (fun (e : Cascade_config_loader.weighted_entry) -> e.model) ordered in
        let candidates = List.map Selection.candidate_info_of_weighted ordered in
        (models, { candidates; source = Default_fallback })
      else
        let candidates =
          List.map (fun m ->
            Selection.candidate_info_of_weighted
              { Cascade_config_loader.model = m; weight = 1; supports_tool_choice = None;
               secondary = None; secondary_supports_tool_choice = None })
            defaults
        in
        (defaults, { candidates; source = Hardcoded_defaults }))
  | None ->
    let candidates =
      List.map (fun m ->
        Selection.candidate_info_of_weighted
          { Cascade_config_loader.model = m; weight = 1; supports_tool_choice = None;
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
