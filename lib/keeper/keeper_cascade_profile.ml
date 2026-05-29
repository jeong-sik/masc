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
let cascade_name_for_use = Cascade_routes_resolve.cascade_name_for_use

let strip_declarative_profile_prefix name = name

let qualified_names_of_declarative_snapshot snapshot =
  Cascade_declarative_hotpath.decl_snapshot_profile_names snapshot
  |> List.sort_uniq String.compare

let public_names_of_declarative_snapshot snapshot =
  qualified_names_of_declarative_snapshot snapshot

let lookup_names_of_qualified_names names = names

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

(* keeper-assignable guardrail removed 2026-05-28 — all profiles are usable. *)
let profile_is_keeper_assignable _ = true

let json_assoc_table_fields key json =
  match Json_util.assoc_member_opt key json with
  | Some (`Assoc fields) -> fields
  | Some _ | None -> []

let json_keeper_assignable_opt json =
  match Json_util.assoc_bool_opt "keeper-assignable" json with
  | Some _ as value -> value
  | None -> Json_util.assoc_bool_opt "keeper_assignable" json

let qualified_name_for_public _meta public_name = public_name

let qualified_name_for_public_names _qualified_names public_name = public_name

let catalog_metadata_of_materialized_json json =
  let routes = json_assoc_table_fields "routes" json in
  let route_targets =
    routes
    |> List.filter_map (fun (_name, route_json) ->
      match Json_util.assoc_member_opt "target" route_json with
      | Some (`String target) ->
          let trimmed = String.trim target in
          if String.equal trimmed "" then None else Some trimmed
      | _ -> None)
    |> List.sort_uniq String.compare
  in
  let fallback_hints =
    routes
    |> List.filter_map (fun (name, route_json) ->
      match Json_util.assoc_member_opt "fallback_cascade" route_json with
      | Some (`String target) ->
          let trimmed = String.trim target in
          if String.equal trimmed "" then None
          else Some (String.trim name, trimmed)
      | _ -> None)
    |> List.filter (fun (source, target) ->
      (not (String.equal source target))
      && List.mem source route_targets
      && List.mem target route_targets)
  in
  Ok
    {
      qualified_names = route_targets;
      public_names = route_targets;
      keeper_assignable_names = route_targets;
      system_qualified_names = [];
      system_names = [];
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

let is_system_only_cascade _raw = false

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
        match List.assoc_opt public_name meta.fallback_hints with
        | None -> None
        | Some target ->
            if String.equal target public_name then None
            else if List.mem target meta.public_names
            then Some target
            else begin
              Cascade_metrics.on_fallback_hint_invalid ();
              let key = (public_name, target) in
              if not (Hashtbl.mem logged_invalid_fallback key) then begin
                Hashtbl.add logged_invalid_fallback key ();
                Log.Misc.warn
                  "[CascadeConfig] profile %s declares fallback hint %s \
                   which is not in the live catalog; ignoring hint"
                  public_name target
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
  if List.mem trimmed catalog then Some trimmed else None

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

(* keeper-assignable guardrail removed 2026-05-28, then re-narrowed 2026-05-29:
   a keeper runtime turn must resolve to a real route target. After tier-group
   removal (#19436/#19439) legacy "tier-group.*"/"tier.*" declared names are
   neither logical-use routes nor catalog members, so [normalize_declared_name]
   passes them through verbatim; the unresolved name then fails capability
   resolution at dispatch (no_tool_capable_provider) and crash-loops the keeper.
   An unresolvable declared name is substituted with the [Keeper_turn] route —
   the logical route a keeper turn runs on — and the substitution is recorded
   (RFC-0038 L4 I-Intent: substitution must be visible, not silent).
   This is the keeper-runtime narrowing only; [normalize_declared_name] keeps
   verbatim passthrough for non-runtime callers. *)
let normalize_keeper_runtime_declared_name ?config_path raw =
  let trimmed = String.trim raw in
  match logical_use_of_string_opt trimmed with
  | Some _ -> normalize_declared_name ?config_path raw
  | None ->
      (match
         canonical_member_of_lookup_catalog
           ~catalog:(catalog_lookup_names ?config_path ())
           trimmed
       with
       | Some canonical -> canonical
       | None ->
           Cascade_metrics.on_route_resolve_fallback
             ~reason:"keeper_runtime_declared_name_unresolved";
           cascade_name_for_use ?config_path Keeper_turn)

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
