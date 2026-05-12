(** See {!Keeper_cascade_profile} interface for rationale. *)

open Cascade_ref

(** Per RFC-0041 cascade routing SSOT, the live cascade catalog
    (cascade.json) is the only source of truth for cascade profile
    names.  There is no compile-time enum here — anything that needs to
    know "what profiles are available" reads them from
    [Cascade_config_loader.load_catalog] / [catalog_names_*] below.  If
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

let catalog_entries_result ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> Error "cascade catalog path is not resolved"
  | Some path ->
      Cascade_config_loader.load_catalog ~config_path:path

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
    [provider]/[model]/[profile] aware) over the legacy
    [Cascade_config_loader.load_catalog] (only sees `*_models` namespaces).
    Falls back to the legacy reader when the snapshot is not yet
    materialized (early boot, before [validate_path]) so existing
    boot-order semantics are preserved. *)
let catalog_names ?config_path () =
  match Cascade_catalog_runtime.known_profile_names () with
  | Ok names when names <> [] -> names
  | Ok _ | Error _ ->
      (match catalog_entries ?config_path () with
       | Some entries ->
           List.map
             (fun (entry : Cascade_config_loader.catalog_entry) -> entry.name)
             entries
       | None -> [])

let catalog_names_result ?config_path () =
  match Cascade_catalog_runtime.known_profile_names () with
  | Ok names when names <> [] -> Ok names
  | Ok _ | Error _ ->
      (match catalog_entries_result ?config_path () with
       | Error _ as err -> err
       | Ok entries ->
           Ok
             (List.map
                (fun (entry : Cascade_config_loader.catalog_entry) -> entry.name)
                entries))

let catalog_names_for_validation ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> Error "cascade catalog path is not resolved"
  | Some path -> declarative_public_catalog_names ~config_path:path ()

let is_system_only_cascade raw =
  let name = String.trim raw in
  match catalog_entries () with
  | None -> false
  | Some entries ->
      List.exists
        (fun (entry : Cascade_config_loader.catalog_entry) ->
          String.equal entry.name name && not entry.keeper_assignable)
        entries

let keeper_catalog_names ?config_path () =
  let declarative_names =
    match config_path with
    | Some path -> (
        match Cascade_declarative_hotpath.try_load_declarative path with
        | Some (Ok snapshot) ->
            public_names_of_declarative_snapshot snapshot
        | Some (Error _) | None -> [])
    | None -> (
        match declarative_public_catalog_names () with
        | Ok names -> names
        | Error _ -> (
            match Cascade_catalog_runtime.known_profile_names () with
            | Ok names -> List.map strip_declarative_profile_prefix names
            | Error _ -> []))
  in
  match declarative_names with
  | _ :: _ -> declarative_names
  | [] ->
      (match catalog_entries ?config_path () with
       | Some entries ->
           entries
           |> List.filter_map
                (fun (entry : Cascade_config_loader.catalog_entry) ->
                  if entry.keeper_assignable then Some entry.name else None)
       | None -> [])

let system_catalog_names ?config_path () =
  match catalog_entries ?config_path () with
  | Some entries ->
      entries
      |> List.filter_map
           (fun (entry : Cascade_config_loader.catalog_entry) ->
             if entry.keeper_assignable then None else Some entry.name)
  | None -> []

(** Track which (cascade, target) pairs we have already logged as
    invalid fallback_cascade hints so the WARN line fires once per
    process — not once per keeper turn. *)
let logged_invalid_fallback : (string * string, unit) Hashtbl.t =
  Hashtbl.create 4

let fallback_cascade_for ?config_path name =
  let trimmed_name = String.trim name in
  if String.equal trimmed_name "" then None
  else
    match catalog_entries ?config_path () with
    | None -> None
    | Some entries ->
        let catalog_names =
          List.map
            (fun (entry : Cascade_config_loader.catalog_entry) -> entry.name)
            entries
        in
        let entry_opt =
          List.find_opt
            (fun (entry : Cascade_config_loader.catalog_entry) ->
              String.equal entry.name trimmed_name)
            entries
        in
        (match entry_opt with
         | None -> None
         | Some entry ->
             (match entry.fallback_cascade with
              | None -> None
              | Some target ->
                  if String.equal target trimmed_name then None
                  else if List.mem target catalog_names then Some target
                  else begin
                    (* Iter 37: tick a counter on every invalid-hint
                       hit (not only on the once-per-pair WARN) so
                       operators can alert on the rate.  Runtime
                       complement to iter-32 [capability_mismatch]
                       which catches the same graph fault at
                       catalog-build time. *)
                    Cascade_metrics.on_fallback_hint_invalid ();
                    let key = (trimmed_name, target) in
                    if not (Hashtbl.mem logged_invalid_fallback key) then begin
                      Hashtbl.add logged_invalid_fallback key ();
                      Log.Misc.warn
                        "[CascadeConfig] profile %s declares \
                         fallback_cascade=%s which is not in the live \
                         catalog; ignoring hint"
                        trimmed_name target
                    end;
                    None
                  end))

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
