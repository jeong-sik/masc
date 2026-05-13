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

let is_system_only_cascade raw =
  let (_ : string) = raw in
  false

let keeper_catalog_names ?config_path () =
  catalog_names ?config_path ()

let system_catalog_names ?config_path () =
  let (_ : string option) = config_path in
  []

let fallback_cascade_for ?config_path name =
  let (_ : string option) = config_path in
  let (_ : string) = name in
  None

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
