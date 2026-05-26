(** Keeper_cascade_profile_catalog — declarative catalog metadata types,
    JSON codecs, qualified-name helpers, and typed catalog query extracted
    from [Keeper_cascade_profile] (643 LoC).  Catalog name resolution
    and normalization remain in the parent.
    @since Keeper 500-line decomposition *)

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
