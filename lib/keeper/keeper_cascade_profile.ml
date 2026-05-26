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

(** Phonebook-based [Provider_config.t] resolution.
    Directly returns typed provider configs without string intermediaries.
    Returns [None] when phonebook is unavailable or no models resolve. *)
let provider_configs_for_use ?config_path ?temperature ?max_tokens use =
  Cascade_routes.cascade_provider_configs_for_use_via_phonebook
    ?config_path ?temperature ?max_tokens use

(** Phonebook-based model string list resolution.
    Returns [None] when phonebook is unavailable. *)
let model_strings_for_use ?config_path use =
  Cascade_routes.cascade_models_for_use_via_phonebook ?config_path use


(** Catalog metadata types, JSON codecs, qualified-name helpers, and typed
    catalog query extracted to [Keeper_cascade_profile_catalog].  Name
    resolution and normalization remain in the parent. *)

include Keeper_cascade_profile_catalog

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
  (* RFC-0143 PR-2 — typed catalog query. *)
  match catalog_metadata_query () with
  | Catalog_ok meta ->
      if is_qualified_profile_name routed then
        List.mem routed meta.system_qualified_names
      else
        List.mem public_name meta.system_names
  | Catalog_unavailable _ -> false

let keeper_catalog_names ?config_path () =
  (* RFC-0143 PR-2 — typed catalog query.  On [Catalog_unavailable]
     fall back to the plain catalog name list. *)
  match catalog_metadata_query ?config_path () with
  | Catalog_ok meta -> meta.keeper_assignable_names
  | Catalog_unavailable _ -> catalog_names ?config_path ()

let system_catalog_names ?config_path () =
  (* RFC-0143 PR-2 — typed catalog query. *)
  match catalog_metadata_query ?config_path () with
  | Catalog_ok meta -> meta.system_names
  | Catalog_unavailable _ -> []

(** Track which (cascade, target) pairs we have already logged as
    invalid fallback hints so the WARN line fires once per process. *)
let logged_invalid_fallback : (string * string, unit) Hashtbl.t =
  Hashtbl.create 4

let fallback_cascade_for ?config_path name =
  let public_name = normalized_query_name ?config_path name in
  if String.equal public_name "" then None
  else
    (* RFC-0143 PR-2 — typed catalog query. *)
    match catalog_metadata_query ?config_path () with
    | Catalog_unavailable _ -> None
    | Catalog_ok meta -> (
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
            else if List.mem qualified_target meta.qualified_names
            then Some qualified_target
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
  | "" -> ""
  | trimmed ->
      if List.mem trimmed catalog then trimmed
      else (
        match logical_use_of_string_opt trimmed with
        | Some use when catalog <> [] ->
            Cascade_routes.fallback_name_for_catalog use ~catalog
        | Some _ -> trimmed
        | None -> trimmed)

let canonical_member_of_lookup_catalog ~catalog raw =
  let trimmed = String.trim raw in
  if not (List.mem trimmed catalog) then None
  else if Cascade_name.is_canonical_prefix trimmed then Some trimmed
  else
    let tier_group = qualified_tier_group_name trimmed in
    let tier = qualified_tier_name trimmed in
    if List.mem tier_group catalog then Some tier_group
    else if List.mem tier catalog then Some tier
    else None

let normalize_declared_name ?config_path (raw : string) : string =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then trimmed
  else
    match logical_use_of_string_opt trimmed with
    | Some use -> cascade_name_for_use ?config_path use
    | None ->
        (match
           canonical_member_of_lookup_catalog
             ~catalog:(catalog_lookup_names ?config_path ())
             trimmed
         with
         | Some canonical -> canonical
         | None -> trimmed)

let keeper_runtime_route_uses =
  [ Keeper_turn; Phase_recovery; Phase_buffer; Tool_required ]

let is_keeper_runtime_route_use use =
  List.exists (( = ) use) keeper_runtime_route_uses

let route_target_public_name ?config_path use =
  try Some (cascade_name_for_use ?config_path use |> public_name_of_target)
  with Failure _ -> None

let normalize_keeper_runtime_declared_name ?config_path raw =
  let normalized = normalize_declared_name ?config_path raw in
  let public_name = public_name_of_target normalized in
  let explicitly_keeper_assignable =
    (* RFC-0143 PR-2 — typed catalog query. *)
    match catalog_metadata_query ?config_path () with
    | Catalog_ok meta -> List.mem normalized meta.keeper_assignable_names
    | Catalog_unavailable _ -> false
  in
  let keeper_route_targets =
    keeper_runtime_route_uses
    |> List.filter_map (route_target_public_name ?config_path)
    |> List.sort_uniq String.compare
  in
  let non_keeper_route_targets =
    Cascade_routes.all_logical_uses
    |> List.filter (fun use -> not (is_keeper_runtime_route_use use))
    |> List.filter_map (route_target_public_name ?config_path)
    |> List.sort_uniq String.compare
  in
  if (not explicitly_keeper_assignable)
     && List.mem public_name non_keeper_route_targets
     && not (List.mem public_name keeper_route_targets)
  then cascade_name_for_use ?config_path Keeper_turn
  else normalized

(* RFC-0149 §3.3 — "Parse, don't validate" reverse of the silent-fallback
  shape.  [resolve_live_with_catalog_result] returns [Ok cascade_name]
  when the catalog can resolve the input, otherwise [Error (`Unresolved
   raw)].  The unresolved branch is isolated to a single [Error] arm so
   the sunset path stays mechanical. *)
let resolve_live_with_catalog_result ~catalog raw :
    (Cascade_name.t, [ `Unresolved of string ]) result =
  let trimmed = String.trim raw in
  let normalized =
    match canonical_member_of_lookup_catalog ~catalog trimmed with
    | Some canonical -> canonical
    | None ->
      if List.mem trimmed catalog then trimmed
      else
        match logical_use_of_string_opt trimmed with
        | Some use when catalog <> [] ->
            Cascade_routes.fallback_name_for_catalog use ~catalog
        | Some _ -> trimmed
        | None -> trimmed
  in
  let normalized =
    match canonical_member_of_lookup_catalog ~catalog normalized with
    | Some canonical -> canonical
    | None -> normalized
  in
  (* Catalog members are canonical by construction; verify with
     [Cascade_name.of_string] so the result is typed. *)
  if List.mem normalized catalog then
    match Cascade_name.of_string normalized with
    | Ok cn -> Ok cn
    | Error _ -> Error (`Unresolved raw)
  else Error (`Unresolved raw)

(* RFC-0149 §3.3 — Result-returning wrapper that reads the active catalog
   from the resolved cascade config path.  Mirrors
   {!resolve_live_with_catalog_result} but with the catalog loaded from
   [config_path].  The legacy silent-fallback [resolve_live] /
   [resolve_live_with_catalog] entry points + their counter + WARN-once
   Hashtbl were removed as part of the §3.3 sunset closeout. *)
let resolve_live_result ?config_path raw :
    (Cascade_name.t, [ `Unresolved of string ]) result =
  resolve_live_with_catalog_result
    ~catalog:(catalog_lookup_names ?config_path ()) raw

let required_capability_profile_of_cascade_name name =
  Cascade_catalog_runtime_cache.with_cache_lock (fun () ->
    match !Cascade_catalog_runtime_cache.cache.active_snapshot with
    | None -> None
    | Some snapshot -> (
      match
        Cascade_catalog_runtime_cache.profile_lookup snapshot.profiles name
      with
      | None -> None
      | Some profile -> profile.required_capability_profile))

let canonicalize (raw : string) : string =
  canonicalize_with_catalog ~catalog:(catalog_names ()) raw

let models_key name = canonicalize name ^ "_models"
let temperature_key name = canonicalize name ^ "_temperature"
let max_tokens_key name = canonicalize name ^ "_max_tokens"
