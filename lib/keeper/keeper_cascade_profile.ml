(** See {!Keeper_cascade_profile} interface for rationale. *)

open Cascade_ref

(** Per RFC-0041 cascade routing SSOT, the live cascade catalog
    (cascade.toml) is the only source of truth for cascade profile
    names.  There is no compile-time enum here — anything that needs to
    know "what profiles are available" reads them from
    [Cascade_catalog_runtime] / [catalog_names_*] below.  If
    the catalog is empty at runtime,
    [Cascade_catalog_runtime.validate_path_result] is the boot-time
    gate that rejects keeper boot, so a missing catalog never reaches
    these helpers. *)

type logical_use = Cascade_ref.logical_use =
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
  | Simple_task
  | Moderate_task
  | Complex_task
  | Tool_rerank_use

let logical_use_key = Cascade_routes.logical_use_key
let logical_use_of_string_opt = Cascade_routes.logical_use_of_string_opt
let configured_route_targets = Cascade_routes.configured_route_targets
let cascade_name_for_use = Cascade_routes.cascade_name_for_use

(* RFC-0066 cycle break: [runtime_name] moved to [Cascade_ref] (leaf).
   Manifest alias preserved here so every caller written as
   [Keeper_cascade_profile.Runtime_name x] / [.runtime_name_to_string]
   keeps compiling unchanged. *)
type runtime_name = Cascade_ref.runtime_name = Runtime_name of string

let runtime_name_to_string = Cascade_ref.runtime_name_to_string

let tier_group_prefix = "tier-group."
let tier_prefix = "tier."

let is_qualified_profile_name name =
  String.starts_with ~prefix:tier_group_prefix name
  || String.starts_with ~prefix:tier_prefix name

let strip_declarative_profile_prefix name =
  if String.starts_with ~prefix:tier_group_prefix name then
    String.sub name (String.length tier_group_prefix)
      (String.length name - String.length tier_group_prefix)
  else if String.starts_with ~prefix:tier_prefix name then
    String.sub name (String.length tier_prefix)
      (String.length name - String.length tier_prefix)
  else name

let qualified_tier_name name = tier_prefix ^ name
let qualified_tier_group_name name = tier_group_prefix ^ name

let qualified_names_of_declarative_snapshot snapshot =
  Cascade_declarative_hotpath.decl_snapshot_profile_names snapshot
  |> List.sort_uniq String.compare

let public_names_of_declarative_snapshot snapshot =
  qualified_names_of_declarative_snapshot snapshot
  |> List.map strip_declarative_profile_prefix
  |> List.sort_uniq String.compare

let lookup_names_of_qualified_names names =
  (names @ List.map strip_declarative_profile_prefix names)
  |> List.sort_uniq String.compare

let declarative_public_catalog_names ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> Error "cascade catalog path is not resolved"
  | Some path -> (
      match Cascade_declarative_hotpath.try_load_declarative path with
      | Some (Ok snapshot) ->
          let names = public_names_of_declarative_snapshot snapshot in
          if names = []
          then Error "declarative cascade catalog contains no profiles"
          else Ok names
      | Some (Error errors) ->
          let rendered =
            errors
            |> List.map Cascade_declarative_adapter.show_adapter_error
            |> String.concat "; "
          in
          Error ("declarative cascade catalog invalid: " ^ rendered)
      | None -> Error "cascade.toml is not a declarative cascade catalog")

let declarative_catalog_lookup_names ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> Error "cascade catalog path is not resolved"
  | Some path -> (
      match Cascade_declarative_hotpath.try_load_declarative path with
      | Some (Ok snapshot) ->
          let names =
            qualified_names_of_declarative_snapshot snapshot
            |> lookup_names_of_qualified_names
          in
          if names = []
          then Error "declarative cascade catalog contains no profiles"
          else Ok names
      | Some (Error errors) ->
          let rendered =
            errors
            |> List.map Cascade_declarative_adapter.show_adapter_error
            |> String.concat "; "
          in
          Error ("declarative cascade catalog invalid: " ^ rendered)
      | None -> Error "cascade.toml is not a declarative cascade catalog")

(** RFC-0066 Phase 2: prefer the live validated snapshot (declarative
    [provider]/[model]/[profile] aware). *)
let catalog_names ?config_path () =
  match config_path with
  | Some _ ->
      (match declarative_public_catalog_names ?config_path () with
       | Ok names -> names
       | Error _ -> [])
  | None ->
      (match Cascade_catalog_runtime.known_profile_names () with
       | Ok names when names <> [] ->
           names |> List.map strip_declarative_profile_prefix
           |> List.sort_uniq String.compare
       | Ok _ | Error _ ->
           (match declarative_public_catalog_names () with
            | Ok names -> names
            | Error _ -> []))

let catalog_names_result ?config_path () =
  match config_path with
  | Some _ -> declarative_public_catalog_names ?config_path ()
  | None ->
      (match Cascade_catalog_runtime.known_profile_names () with
       | Ok names when names <> [] ->
           Ok
             (names |> List.map strip_declarative_profile_prefix
              |> List.sort_uniq String.compare)
       | Ok _ | Error _ -> declarative_public_catalog_names ())

let catalog_lookup_names ?config_path () =
  match config_path with
  | Some _ ->
      (match declarative_catalog_lookup_names ?config_path () with
       | Ok names -> names
       | Error _ -> [])
  | None ->
      (match Cascade_catalog_runtime.known_profile_names () with
       | Ok names when names <> [] -> lookup_names_of_qualified_names names
       | Ok _ | Error _ ->
           (match declarative_catalog_lookup_names () with
            | Ok names -> names
            | Error _ -> []))

let catalog_names_for_validation ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> Error "cascade catalog path is not resolved"
  | Some path -> declarative_catalog_lookup_names ~config_path:path ()

type catalog_metadata = {
  qualified_names : string list;
  public_names : string list;
  keeper_assignable_names : string list;
  system_qualified_names : string list;
  system_names : string list;
  fallback_hints : (string * string) list;
}

let public_name_of_target target =
  strip_declarative_profile_prefix (String.trim target)

let profile_is_keeper_assignable = function
  | Some false -> false
  | None | Some true -> true

let json_assoc_member key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let json_assoc_table_fields key json =
  match json_assoc_member key json with
  | Some (`Assoc fields) -> fields
  | Some _ | None -> []

let json_bool_field key json =
  match json_assoc_member key json with
  | Some (`Bool value) -> Some value
  | _ -> None

let json_string_list_field key json =
  match json_assoc_member key json with
  | Some (`List values) ->
      values
      |> List.filter_map (function
        | `String value ->
            let trimmed = String.trim value in
            if String.equal trimmed "" then None else Some trimmed
        | _ -> None)
  | _ -> []

let json_keeper_assignable_opt json =
  match json_bool_field "keeper-assignable" json with
  | Some _ as value -> value
  | None -> json_bool_field "keeper_assignable" json

let qualified_name_for_public meta public_name =
  let group_name = qualified_tier_group_name public_name in
  let tier_name = qualified_tier_name public_name in
  if List.mem group_name meta.qualified_names then group_name
  else if List.mem tier_name meta.qualified_names then tier_name
  else public_name

let qualified_name_for_public_names qualified_names public_name =
  let group_name = qualified_tier_group_name public_name in
  let tier_name = qualified_tier_name public_name in
  if List.mem group_name qualified_names then group_name
  else if List.mem tier_name qualified_names then tier_name
  else public_name

let catalog_metadata_of_materialized_json json =
  let tier_profiles =
    json_assoc_table_fields "tier" json
    |> List.map (fun (name, tier_json) ->
      qualified_tier_name name, json_keeper_assignable_opt tier_json)
  in
  let tier_group_fields = json_assoc_table_fields "tier-group" json in
  let tier_group_profiles =
    tier_group_fields
    |> List.map (fun (name, group_json) ->
      qualified_tier_group_name name, json_keeper_assignable_opt group_json)
  in
  let profile_assignability = tier_profiles @ tier_group_profiles in
  let qualified_names =
    profile_assignability |> List.map fst |> List.sort_uniq String.compare
  in
  let public_names =
    qualified_names
    |> List.map strip_declarative_profile_prefix
    |> List.sort_uniq String.compare
  in
  let system_qualified_names =
    profile_assignability
    |> List.filter_map (fun (name, assignable) ->
      if profile_is_keeper_assignable assignable then None else Some name)
    |> List.sort_uniq String.compare
  in
  let keeper_assignable_names =
    public_names
    |> List.filter (fun public_name ->
      let qualified_name =
        qualified_name_for_public_names qualified_names public_name
      in
      match List.assoc_opt qualified_name profile_assignability with
      | Some assignable -> profile_is_keeper_assignable assignable
      | None -> true)
  in
  let system_names =
    public_names
    |> List.filter (fun name -> not (List.mem name keeper_assignable_names))
  in
  let fallback_hints =
    tier_group_fields
    |> List.concat_map (fun (name, group_json) ->
      let fallback =
        match json_bool_field "fallback" group_json with
        | Some true -> true
        | Some false | None -> false
      in
      let tiers = json_string_list_field "tiers" group_json in
      if (not fallback) || List.length tiers < 2
      then []
      else (
        let group_name = qualified_tier_group_name name in
        let tier_edges =
          let rec loop acc = function
            | current :: ((next :: _) as rest) ->
                loop
                  ((qualified_tier_name current, qualified_tier_name next)
                   :: acc)
                  rest
            | [] | [_] -> List.rev acc
          in
          loop [] tiers
        in
        match tiers with
        | _first :: next :: _ ->
            (group_name, qualified_tier_name next) :: tier_edges
        | [] | [_] -> tier_edges))
    |> List.filter (fun (source, target) ->
      (not (String.equal source target))
      && List.mem source qualified_names
      && List.mem target qualified_names)
  in
  Ok
    {
      qualified_names;
      public_names;
      keeper_assignable_names;
      system_qualified_names;
      system_names;
      fallback_hints;
    }

let catalog_metadata_result ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> Error "cascade catalog path is not resolved"
  | Some path -> (
      match Cascade_config_loader.load_catalog_source_for_diagnostics path with
      | Error msg -> Error ("declarative cascade catalog invalid: " ^ msg)
      | Ok json -> catalog_metadata_of_materialized_json json)

let routed_query_target ?config_path raw =
  let trimmed = String.trim raw in
  match logical_use_of_string_opt trimmed with
  | Some use -> cascade_name_for_use ?config_path use
  | None -> trimmed

let normalized_query_name ?config_path raw =
  routed_query_target ?config_path raw |> public_name_of_target

let is_system_only_cascade raw =
  let routed = routed_query_target raw |> String.trim in
  let public_name = public_name_of_target routed in
  match catalog_metadata_result () with
  | Ok meta ->
      if is_qualified_profile_name routed then
        List.mem routed meta.system_qualified_names
      else
        List.mem public_name meta.system_names
  | Error _ -> false

let keeper_catalog_names ?config_path () =
  match catalog_metadata_result ?config_path () with
  | Ok meta -> meta.keeper_assignable_names
  | Error _ -> catalog_names ?config_path ()

let system_catalog_names ?config_path () =
  match catalog_metadata_result ?config_path () with
  | Ok meta -> meta.system_names
  | Error _ -> []

(** Track which (cascade, target) pairs we have already logged as
    invalid fallback hints so the WARN line fires once per process. *)
let logged_invalid_fallback : (string * string, unit) Hashtbl.t =
  Hashtbl.create 4

let fallback_cascade_for ?config_path name =
  let public_name = normalized_query_name ?config_path name in
  if String.equal public_name "" then None
  else
    match catalog_metadata_result ?config_path () with
    | Error _ -> None
    | Ok meta -> (
        let qualified_name =
          let routed = routed_query_target ?config_path name |> String.trim in
          if is_qualified_profile_name routed
          then routed
          else qualified_name_for_public meta public_name
        in
        match List.assoc_opt qualified_name meta.fallback_hints with
        | None -> None
        | Some qualified_target ->
            let target = public_name_of_target qualified_target in
            if String.equal target public_name then None
            else if List.mem qualified_target meta.qualified_names then Some target
            else begin
              Cascade_metrics.on_fallback_hint_invalid ();
              let key = (qualified_name, qualified_target) in
              if not (Hashtbl.mem logged_invalid_fallback key) then begin
                Hashtbl.add logged_invalid_fallback key ();
                Log.Misc.warn
                  "[CascadeConfig] profile %s declares fallback hint %s \
                   which is not in the live catalog; ignoring hint"
                  qualified_name qualified_target
              end;
              None
            end)

let canonicalize_with_catalog ~catalog raw =
  match String.trim raw with
  | "" -> Cascade_routes.fallback_name_for_catalog Keeper_turn ~catalog
  | trimmed ->
      if List.mem trimmed catalog then trimmed
      else (
        match logical_use_of_string_opt trimmed with
        | Some use -> Cascade_routes.fallback_name_for_catalog use ~catalog
        | None -> trimmed)

let normalize_declared_name (raw : string) : string =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then
    cascade_name_for_use Keeper_turn
  else
    match logical_use_of_string_opt trimmed with
    | Some use -> cascade_name_for_use use
    | None -> trimmed

let resolve_live_with_catalog ~catalog raw =
  let trimmed = String.trim raw in
  let normalized =
    if List.mem trimmed catalog then trimmed
    else
      match logical_use_of_string_opt trimmed with
      | Some use -> Cascade_routes.fallback_name_for_catalog use ~catalog
      | None -> trimmed
  in
  if List.mem normalized catalog then normalized
  else begin
    (* Iter 36: raw cascade name doesn't normalize to a catalog
       member.  Silently falls back to [Keeper_turn] default —
       operator's intended cascade is invalidated.  Distinct from
       iter-30 [route_resolve_fallback] which catches the
       route-table path; this is the direct-raw-name path. *)
    Cascade_metrics.on_resolve_live_fallback ();
    Cascade_routes.fallback_name_for_catalog Keeper_turn ~catalog
  end

let resolve_live ?config_path raw =
  resolve_live_with_catalog ~catalog:(catalog_lookup_names ?config_path ()) raw

let canonicalize (raw : string) : string =
  canonicalize_with_catalog ~catalog:(catalog_names ()) raw

let runtime_name_of_string raw = Runtime_name (canonicalize raw)

let models_key name = canonicalize name ^ "_models"
let temperature_key name = canonicalize name ^ "_temperature"
let max_tokens_key name = canonicalize name ^ "_max_tokens"
