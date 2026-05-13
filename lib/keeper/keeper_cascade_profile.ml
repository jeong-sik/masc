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

let strip_declarative_profile_prefix name =
  let tier_group_prefix = "tier-group." in
  let tier_prefix = "tier." in
  if String.starts_with ~prefix:tier_group_prefix name then
    String.sub name (String.length tier_group_prefix)
      (String.length name - String.length tier_group_prefix)
  else if String.starts_with ~prefix:tier_prefix name then
    String.sub name (String.length tier_prefix)
      (String.length name - String.length tier_prefix)
  else name

let public_names_of_declarative_snapshot snapshot =
  Cascade_declarative_hotpath.decl_snapshot_profile_names snapshot
  |> List.map strip_declarative_profile_prefix
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

let catalog_names_for_validation ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> Error "cascade catalog path is not resolved"
  | Some path -> declarative_public_catalog_names ~config_path:path ()

type catalog_metadata = {
  public_names : string list;
  keeper_assignable_names : string list;
  system_names : string list;
  fallback_hints : (string * string) list;
}

let public_name_of_tier name = strip_declarative_profile_prefix ("tier." ^ name)

let public_name_of_target target =
  strip_declarative_profile_prefix (String.trim target)

let catalog_metadata_result ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> Error "cascade catalog path is not resolved"
  | Some path -> (
      match Cascade_declarative_parser.parse_file path with
      | Error errors ->
          let rendered =
            errors
            |> List.map
                 (fun (e : Cascade_declarative_parser.parse_error) ->
                   Printf.sprintf "%s: %s" e.path e.message)
            |> String.concat "; "
          in
          Error ("declarative cascade catalog invalid: " ^ rendered)
      | Ok cfg ->
          let tier_names =
            cfg.tiers
            |> List.map (fun (tier : Cascade_declarative_types.cascade_tier) ->
                   public_name_of_tier tier.name)
          in
          let tier_group_names =
            cfg.tier_groups
            |> List.map
                 (fun (group : Cascade_declarative_types.cascade_tier_group) ->
                   public_name_of_target ("tier-group." ^ group.name))
          in
          let public_names =
            tier_names @ tier_group_names |> List.sort_uniq String.compare
          in
          let profile_assignability =
            (cfg.tiers
             |> List.map (fun (tier : Cascade_declarative_types.cascade_tier) ->
                    (public_name_of_tier tier.name, tier.keeper_assignable)))
            @
            (cfg.tier_groups
             |> List.map
                  (fun (group : Cascade_declarative_types.cascade_tier_group) ->
                    ( public_name_of_target ("tier-group." ^ group.name)
                    , group.keeper_assignable )))
          in
          let profile_is_keeper_assignable name =
            not
              (List.exists
                 (fun (profile_name, assignable) ->
                   String.equal profile_name name
                   && Option.equal Bool.equal assignable (Some false))
                 profile_assignability)
          in
          let keeper_assignable_names =
            cfg.routes
            |> List.filter_map
                 (fun (route : Cascade_declarative_types.cascade_route) ->
                   let target = public_name_of_target route.target in
                   if List.mem target public_names
                      && profile_is_keeper_assignable target
                   then Some target
                   else None)
            |> List.sort_uniq String.compare
          in
          let system_names =
            public_names
            |> List.filter (fun name ->
                   not (List.mem name keeper_assignable_names))
          in
          let fallback_hints =
            cfg.tier_groups
            |> List.concat_map
                 (fun (group : Cascade_declarative_types.cascade_tier_group) ->
                   if (not group.fallback) || List.length group.tiers < 2
                   then []
                   else
                     let group_name =
                       public_name_of_target ("tier-group." ^ group.name)
                     in
                     let tier_edges =
                       let rec loop acc = function
                         | current :: ((next :: _) as rest) ->
                             loop
                               ((public_name_of_tier current, public_name_of_tier next)
                                :: acc)
                               rest
                         | [] | [_] -> List.rev acc
                       in
                       loop [] group.tiers
                     in
                     match group.tiers with
                     | _first :: next :: _ ->
                         (group_name, public_name_of_tier next) :: tier_edges
                     | [] | [_] -> tier_edges)
            |> List.filter (fun (source, target) ->
                   (not (String.equal source target))
                   && List.mem source public_names
                   && List.mem target public_names)
          in
          Ok
            {
              public_names;
              keeper_assignable_names;
              system_names;
              fallback_hints;
            })

let normalized_query_name ?config_path raw =
  let trimmed = String.trim raw in
  let routed =
    match logical_use_of_string_opt trimmed with
    | Some use -> cascade_name_for_use ?config_path use
    | None -> trimmed
  in
  public_name_of_target routed

let is_system_only_cascade raw =
  let name = normalized_query_name raw in
  match catalog_metadata_result () with
  | Ok meta -> List.mem name meta.system_names
  | Error _ -> false

let keeper_catalog_names ?config_path () =
  match catalog_metadata_result ?config_path () with
  | Ok meta when meta.keeper_assignable_names <> [] ->
      meta.keeper_assignable_names
  | Ok _ | Error _ -> catalog_names ?config_path ()

let system_catalog_names ?config_path () =
  match catalog_metadata_result ?config_path () with
  | Ok meta -> meta.system_names
  | Error _ -> []

(** Track which (cascade, target) pairs we have already logged as
    invalid fallback hints so the WARN line fires once per process. *)
let logged_invalid_fallback : (string * string, unit) Hashtbl.t =
  Hashtbl.create 4

let fallback_cascade_for ?config_path name =
  let trimmed_name = normalized_query_name ?config_path name in
  if String.equal trimmed_name "" then None
  else
    match catalog_metadata_result ?config_path () with
    | Error _ -> None
    | Ok meta -> (
        match List.assoc_opt trimmed_name meta.fallback_hints with
        | None -> None
        | Some target ->
            if String.equal target trimmed_name then None
            else if List.mem target meta.public_names then Some target
            else begin
              Cascade_metrics.on_fallback_hint_invalid ();
              let key = (trimmed_name, target) in
              if not (Hashtbl.mem logged_invalid_fallback key) then begin
                Hashtbl.add logged_invalid_fallback key ();
                Log.Misc.warn
                  "[CascadeConfig] profile %s declares fallback hint %s \
                   which is not in the live catalog; ignoring hint"
                  trimmed_name target
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
  resolve_live_with_catalog ~catalog:(catalog_names ?config_path ()) raw

let canonicalize (raw : string) : string =
  canonicalize_with_catalog ~catalog:(catalog_names ()) raw

let runtime_name_of_string raw = Runtime_name (canonicalize raw)

let models_key name = canonicalize name ^ "_models"
let temperature_key name = canonicalize name ^ "_temperature"
let max_tokens_key name = canonicalize name ^ "_max_tokens"
