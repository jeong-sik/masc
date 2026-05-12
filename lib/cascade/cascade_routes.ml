(** See {!Cascade_routes} interface. *)

open Cascade_ref

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

type route_spec = {
  use : logical_use;
  key : string;
  aliases : string list;
}

(* Per RFC-0041 cascade routing SSOT, the live cascade catalog
   (cascade.toml) is the single source of truth for keeper-assignable
   profile names.  This module performs static lookup only — operator
   spec (cascade.toml [routes] + fallback_cascade) decides routing and
   the runtime cascade chain handles try/fail/next-cascade.  If the
   catalog is empty at runtime,
   [Cascade_catalog_runtime.validate_path_result] already rejects keeper
   boot.  [fallback_from_entries]/[fallback_name_for_catalog] return the
   first alias from [spec_for_use] as a soft fallback, so test
   executables that link these modules transitively do not crash at
   module-init time. *)

let route use key aliases = { use; key; aliases }

(* [spec_for_use] is the SSOT for the (logical_use → key/aliases) mapping.
   Written as an exhaustive [match] so adding a new constructor to
   [logical_use] is a compile-time error here, not a runtime
   [assert false] surfaced by [spec_for_use] callers.  Per CLAUDE.md
   §"FSM Sparse Match" anti-pattern: a list lookup keyed by a closed
   sum type silently degrades when the list and the type drift apart. *)
let spec_for_use : logical_use -> route_spec = function
  | Keeper_turn ->
      route Keeper_turn "keeper_turn"
        [
          "default";
          "default_models";
          "oas-keeper_unified";
          "coding_first";
          "oas-coding_first";
          "keeper_reply";
          "keeper_unified";
        ]
  | Phase_recovery -> route Phase_recovery "phase_recovery" [ "local_recovery" ]
  | Phase_buffer -> route Phase_buffer "phase_buffer" [ "local_only" ]
  | Tool_required ->
      route Tool_required "tool_required"
        [ "tool_use_strict"; "resilient_breaker" ]
  | Governance_judge -> route Governance_judge "governance_judge" []
  | Operator_judge -> route Operator_judge "operator_judge" []
  | Cross_verifier -> route Cross_verifier "cross_verifier" []
  | Verifier -> route Verifier "verifier" []
  | Autoresearch -> route Autoresearch "autoresearch" []
  | Adversarial_reviewer -> route Adversarial_reviewer "adversarial_reviewer" []
  | Auto_responder -> route Auto_responder "auto_responder" []
  | Routing -> route Routing "routing" [ "routing_judge" ]
  | Openai_compat -> route Openai_compat "openai_compat" []
  | Persona_generation -> route Persona_generation "persona_generation" []
  | Provider_benchmark -> route Provider_benchmark "provider_benchmark" []
  | Simple_task -> route Simple_task "simple_task" []
  | Moderate_task -> route Moderate_task "moderate_task" []
  | Complex_task -> route Complex_task "complex_task" []
  | Tool_rerank_use -> route Tool_rerank_use "llm_rerank" []

(* The known-uses enumeration must remain in sync with [logical_use].
   When a new constructor is added, the [match] in [spec_for_use] will
   refuse to compile until extended; this list still requires a manual
   append, but downstream lookups go through [spec_for_use] so the
   silent-runtime-failure path is closed. *)
let all_logical_uses : logical_use list =
  [
    Keeper_turn;
    Phase_recovery;
    Phase_buffer;
    Tool_required;
    Governance_judge;
    Operator_judge;
    Cross_verifier;
    Verifier;
    Autoresearch;
    Adversarial_reviewer;
    Auto_responder;
    Routing;
    Openai_compat;
    Persona_generation;
    Provider_benchmark;
    Simple_task;
    Moderate_task;
    Complex_task;
    Tool_rerank_use;
  ]

let route_specs : route_spec list = List.map spec_for_use all_logical_uses

let known_route_keys =
  route_specs
  |> List.map (fun spec -> spec.key)
  |> List.sort_uniq String.compare

let logical_use_key use = (spec_for_use use).key

let logical_use_of_string_opt raw =
  match String.trim raw |> String.lowercase_ascii with
  | "" -> Some Keeper_turn
  | normalized ->
      route_specs
      |> List.find_map (fun spec ->
             if String.equal normalized spec.key
                || List.mem normalized spec.aliases
             then Some spec.use
             else None)

(* RFC-0058 v2 supports two route encodings in the materialized JSON:
   - legacy:    {"routes": {"X": "tier_or_group"}}            (string value)
   - declarative: {"routes": {"X": {"target": "tier-..."}}}   (object value)
   The Phase 4 materializer (lib/cascade/cascade_toml_materializer.ml)
   passes sub-tables through verbatim, so this consumer must extract
   the [target] field instead of filtering non-string values to None —
   otherwise every declarative route silently disappears from the
   runtime view (Cascade_routes.configured_route_targets returns []).
   See PR #14550 review thread #DUH/#DUN for the regression report. *)
let target_of_route_value : Yojson.Safe.t -> string option = function
  | `String raw -> Some (String.trim raw)
  | `Assoc obj ->
      (match List.assoc_opt "target" obj with
       | Some (`String raw) -> Some (String.trim raw)
       | _ -> None)
  | _ -> None

let route_bindings_from_json = function
  | `Assoc fields -> (
      match List.assoc_opt "routes" fields with
      | Some (`Assoc routes) ->
          routes
          |> List.filter_map (fun (key, value) ->
                 match target_of_route_value value with
                 | Some target
                   when not (String.equal key "" || String.equal target "") ->
                     Some (key, target)
                 | Some _ ->
                     (* Iter 33: target produced but key or target
                        trimmed to empty string.  Silent drop without
                        this counter — operators saw routes 'work' in
                        cascade.toml but the catalog had nothing for
                        the bad entry. *)
                     Cascade_metrics.on_route_binding_dropped
                       ~reason:"empty_key_or_target";
                     None
                 | None ->
                     (* Iter 33: value matches neither legacy-string
                        nor declarative-table encoding, or the
                        [Assoc] has no [target] subfield.  Most
                        common cause: operator typoed the [target]
                        key. *)
                     Cascade_metrics.on_route_binding_dropped
                       ~reason:"invalid_value";
                     None)
      | _ -> [])
  | _ -> []

let configured_route_bindings ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> []
  | Some path -> (
      match Cascade_config_loader.load_catalog_source path with
      | Ok json -> route_bindings_from_json json
      | Error _ -> [])

let configured_route_targets ?config_path () =
  configured_route_bindings ?config_path ()
  |> List.map snd
  |> List.sort_uniq String.compare

let configured_route_keys ?config_path () =
  configured_route_bindings ?config_path ()
  |> List.map fst
  |> List.sort_uniq String.compare

let configured_unknown_route_keys ?config_path () =
  configured_route_keys ?config_path ()
  |> List.filter (fun key -> not (List.mem key known_route_keys))

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

let first_catalog_name entries =
  match entries with
  | (entry : Cascade_config_loader.catalog_entry) :: _ -> Some entry.name
  | [] -> None

let first_alias_or_key (spec : route_spec) =
  match spec.aliases with
  | first :: _ -> first
  | [] -> spec.key

let fallback_from_entries use entries =
  let spec = spec_for_use use in
  match first_catalog_name entries with
  | Some name -> name
  | None -> first_alias_or_key spec

let fallback_name_for_catalog use ~catalog =
  let spec = spec_for_use use in
  match catalog with
  | name :: _ -> name
  | [] -> first_alias_or_key spec

let logged_invalid_route_targets : (string * string, unit) Hashtbl.t =
  Hashtbl.create 8

let logged_unvalidated_route_targets : (string * string, unit) Hashtbl.t =
  Hashtbl.create 8

let warn_invalid_route_target_once ~route_key ~target ~fallback =
  let key = (route_key, target) in
  if not (Hashtbl.mem logged_invalid_route_targets key) then begin
    Hashtbl.add logged_invalid_route_targets key ();
    Log.Misc.warn
      "[CascadeRoutes] routes.%s targets missing profile %s; using %s"
      route_key target fallback
  end

let warn_unvalidated_route_target_once ~route_key ~target ~fallback =
  let key = (route_key, target) in
  if not (Hashtbl.mem logged_unvalidated_route_targets key) then begin
    Hashtbl.add logged_unvalidated_route_targets key ();
    Log.Misc.warn
      "[CascadeRoutes] routes.%s targets %s but no live catalog profiles \
       were validated; preserving configured target (legacy fallback would be %s)"
      route_key target fallback
  end

let cascade_name_for_use ?config_path use =
  let route_key = logical_use_key use in
  let route_target =
    configured_route_bindings ?config_path ()
    |> List.find_map (fun (key, target) ->
           if String.equal key route_key then Some target else None)
  in
  let entries = Option.value (catalog_entries ?config_path ()) ~default:[] in
  let catalog_names =
    List.map (fun (entry : Cascade_config_loader.catalog_entry) -> entry.name) entries
  in
  let fallback = fallback_from_entries use entries in
  match route_target with
  | Some target when catalog_names = [] ->
      Cascade_metrics.on_route_resolve_fallback ~reason:"catalog_unvalidated";
      warn_unvalidated_route_target_once ~route_key ~target ~fallback;
      target
  | Some target when List.mem target catalog_names -> target
  | Some target ->
      Cascade_metrics.on_route_resolve_fallback ~reason:"target_not_in_catalog";
      warn_invalid_route_target_once ~route_key ~target ~fallback;
      fallback
  | None -> fallback
