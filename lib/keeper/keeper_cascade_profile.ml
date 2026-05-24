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

(* RFC-0058 Phase 8.2 + 8.1.5: partial-catalog warns route through
   [Log.Cascade] (dedicated namespace, RFC-0058 phase 8.1.5) and are
   deduplicated by (path, mtime, sorted-error-signature) so a single
   reload triggers at most one WARN even when consulted by multiple
   keeper toml load sites.

   Dedup state is module-local. The key set is bounded by the number
   of distinct (path, mtime) pairs the server sees in its lifetime.
   In practice cascade.toml mtime changes on operator edit; the table
   does not grow without bound during normal operation. *)
module Partial_warn_dedup = struct
  let table : (string * float * string, unit) Hashtbl.t = Hashtbl.create 8
  let mutex = Mutex.create ()

  let key_of_errors errors =
    errors
    |> List.map Cascade_declarative_adapter.show_adapter_error
    |> List.sort String.compare
    |> String.concat "|"

  (* [reset_for_tests] is intentionally NOT exposed in any .mli. It is
     called only from inside this module by the unit test fixture that
     runs in the same translation unit. Public callers cannot reach it. *)
  let _ = fun () -> Hashtbl.clear table

  let observe_once ~path ~mtime ~errors f =
    let sig_ = key_of_errors errors in
    let key = (path, mtime, sig_) in
    Mutex.lock mutex;
    let fresh =
      if Hashtbl.mem table key then false
      else (Hashtbl.add table key (); true)
    in
    Mutex.unlock mutex;
    if fresh then f sig_
end

let log_partial_catalog_errors ~path ~mtime
    (errors : Cascade_declarative_adapter.adapter_error list) =
  if errors <> [] then
    Partial_warn_dedup.observe_once ~path ~mtime ~errors
      (fun rendered ->
        Log.Cascade.warn
          "declarative cascade catalog has %d adapter error(s) in %s \
           (mtime=%.0f); surfacing valid subset to keeper validation: %s"
          (List.length errors) path mtime rendered)

let declarative_public_catalog_names ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> Error "cascade catalog path is not resolved"
  | Some path -> (
      match Cascade_declarative_hotpath.try_load_partial path with
      | Some { snapshot; errors } ->
          log_partial_catalog_errors ~path ~mtime:snapshot.mtime errors;
          let names = public_names_of_declarative_snapshot snapshot in
          if names = []
          then Error "declarative cascade catalog contains no profiles"
          else Ok names
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
      match Cascade_declarative_hotpath.try_load_partial path with
      | Some { snapshot; errors } ->
          log_partial_catalog_errors ~path ~mtime:snapshot.mtime errors;
          let names =
            qualified_names_of_declarative_snapshot snapshot
            |> lookup_names_of_qualified_names
          in
          if names = []
          then Error "declarative cascade catalog contains no profiles"
          else Ok names
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
  let keeper_assignable_public_names =
    public_names
    |> List.filter (fun public_name ->
      let qualified_name =
        qualified_name_for_public_names qualified_names public_name
      in
      match List.assoc_opt qualified_name profile_assignability with
      | Some assignable -> profile_is_keeper_assignable assignable
      | None -> true)
  in
  let keeper_assignable_qualified_names =
    profile_assignability
    |> List.filter_map (fun (name, assignable) ->
      if profile_is_keeper_assignable assignable then Some name else None)
  in
  let keeper_assignable_names =
    keeper_assignable_public_names @ keeper_assignable_qualified_names
    |> List.sort_uniq String.compare
  in
  let system_names =
    public_names
    |> List.filter (fun name -> not (List.mem name keeper_assignable_public_names))
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

(* RFC-0143 typed catalog metadata query.

   Distinguishes the three control-flow origins of an unavailable
   catalog so callers can decide what to do about each without
   grepping an error string.  Replaces the legacy string-error
   [catalog_metadata_result] which was deleted by the §4 PR-5
   closeout once all callers consumed this typed variant. *)
type catalog_unavailable_reason =
  | Catalog_path_not_resolved
      (** The config-dir resolver returned no cascade.toml path.
          Typical on first-boot installs before [masc init] runs. *)
  | Catalog_load_failed of string
      (** [Cascade_config_loader.load_catalog_source_for_diagnostics]
          surfaced an I/O or TOML/JSON parse error. The string is the
          loader's diagnostic, including any [Sys_error] / [Unix_error]
          / [Yojson.Json_error] / [End_of_file] message. *)
  | Catalog_metadata_invalid of string
      (** The catalog loaded but its declarative metadata did not
          materialize cleanly into the [catalog_metadata] record. *)

type 'a catalog_query_result =
  | Catalog_ok of 'a
  | Catalog_unavailable of {
      reason : catalog_unavailable_reason;
      message : string;
    }

let catalog_unavailable_reason_to_string = function
  | Catalog_path_not_resolved -> "path_not_resolved"
  | Catalog_load_failed _ -> "load_failed"
  | Catalog_metadata_invalid _ -> "metadata_invalid"
;;

let catalog_metadata_query ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None ->
    Catalog_unavailable
      {
        reason = Catalog_path_not_resolved;
        message = "cascade catalog path is not resolved";
      }
  | Some path -> (
      match Cascade_config_loader.load_catalog_source_for_diagnostics path with
      | Error msg ->
        Catalog_unavailable
          { reason = Catalog_load_failed msg; message = msg }
      | Ok json -> (
          match catalog_metadata_of_materialized_json json with
          | Ok meta -> Catalog_ok meta
          | Error msg ->
            Catalog_unavailable
              { reason = Catalog_metadata_invalid msg; message = msg }))
;;

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
  | "" -> ""
  | trimmed ->
      if List.mem trimmed catalog then trimmed
      else (
        match logical_use_of_string_opt trimmed with
        | Some use when catalog <> [] ->
            Cascade_routes.fallback_name_for_catalog use ~catalog
        | Some _ -> trimmed
        | None -> trimmed)

let normalize_declared_name (raw : string) : string =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then trimmed
  else
    match logical_use_of_string_opt trimmed with
    | Some use -> cascade_name_for_use use
    | None -> trimmed

let keeper_runtime_route_uses =
  [ Keeper_turn; Phase_recovery; Phase_buffer; Tool_required ]

let is_keeper_runtime_route_use use =
  List.exists (( = ) use) keeper_runtime_route_uses

let route_target_public_name ?config_path use =
  try Some (cascade_name_for_use ?config_path use |> public_name_of_target)
  with Failure _ -> None

let normalize_keeper_runtime_declared_name ?config_path raw =
  let normalized = normalize_declared_name raw in
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
   raw)].  The legacy [resolve_live_with_catalog] below keeps the silent
   fallback + WARN-once + counter for callers that have not yet migrated,
   but the unresolved branch is now isolated to a single [Error] arm so
   the sunset path is mechanical. *)
let resolve_live_with_catalog_result ~catalog raw :
    (Cascade_name.t, [ `Unresolved of string ]) result =
  let trimmed = String.trim raw in
  let normalized =
    if List.mem trimmed catalog then trimmed
    else
      match logical_use_of_string_opt trimmed with
      | Some use when catalog <> [] ->
          Cascade_routes.fallback_name_for_catalog use ~catalog
      | Some _ -> trimmed
      | None -> trimmed
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
