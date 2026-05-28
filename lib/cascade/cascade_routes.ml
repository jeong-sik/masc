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
}

(* Per RFC-0041 cascade routing SSOT, the live cascade catalog
   (cascade.toml) is the single source of truth for keeper-assignable
   profile names.  This module performs static lookup only — operator
   spec (cascade.toml [routes] + fallback_cascade) decides routing and
   the runtime cascade chain handles try/fail/next-cascade.  If the
   catalog is empty at runtime,
   [Cascade_catalog_runtime.validate_path_result] already rejects keeper
   boot; the canonical-key empty fallback only keeps module init and
   focused test executables from depending on historical aliases. *)

let route use key = { use; key }

(* [spec_for_use] is the SSOT for the (logical_use → route key) mapping.
   Written as an exhaustive [match] so adding a new constructor to
   [logical_use] is a compile-time error here, not a runtime
   [assert false] surfaced by [spec_for_use] callers.  Per CLAUDE.md
   §"FSM Sparse Match" anti-pattern: a list lookup keyed by a closed
   sum type silently degrades when the list and the type drift apart. *)
let spec_for_use : logical_use -> route_spec = function
  | Keeper_turn -> route Keeper_turn "keeper_turn"
  | Phase_recovery -> route Phase_recovery "phase_recovery"
  | Phase_buffer -> route Phase_buffer "phase_buffer"
  | Tool_required -> route Tool_required "tool_required"
  | Governance_judge -> route Governance_judge "governance_judge"
  | Operator_judge -> route Operator_judge "operator_judge"
  | Cross_verifier -> route Cross_verifier "cross_verifier"
  | Verifier -> route Verifier "verifier"
  | Adversarial_reviewer -> route Adversarial_reviewer "adversarial_reviewer"
  | Auto_responder -> route Auto_responder "auto_responder"
  | Routing -> route Routing "routing"
  | Openai_compat -> route Openai_compat "openai_compat"
  | Persona_generation -> route Persona_generation "persona_generation"
  | Provider_benchmark -> route Provider_benchmark "provider_benchmark"
  | Simple_task -> route Simple_task "simple_task"
  | Moderate_task -> route Moderate_task "moderate_task"
  | Complex_task -> route Complex_task "complex_task"
  | Tool_rerank_use -> route Tool_rerank_use "llm_rerank"

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
  | "" -> None
  | normalized ->
      route_specs
      |> List.find_map (fun spec ->
             if String.equal normalized spec.key then Some spec.use else None)

(* RFC-0058 v2 route encoding in the materialized JSON:
   {"routes": {"X": {"target": "tier-..."}}}.
   The TOML materializer passes [routes.X] sub-tables through verbatim,
   so this consumer extracts the [target] field. *)
let target_of_route_value : Yojson.Safe.t -> string option = function
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
                     (* Iter 33: value is not a declarative route
                        object with a [target] subfield. Most common
                        cause: operator typoed the [target] key. *)
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

let declarative_catalog_names_from_json = function
  | `Assoc fields ->
      let keys_with_prefix table prefix =
        match List.assoc_opt table fields with
        | Some (`Assoc entries) ->
            List.map (fun (name, _) -> prefix ^ name) entries
        | _ -> []
      in
      keys_with_prefix "tier-group" "tier-group."
      @ keys_with_prefix "tier" "tier."
      |> List.sort_uniq String.compare
  | _ -> []

let declarative_catalog_names ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> []
  | Some path -> (
      match Cascade_config_loader.load_catalog_source path with
      | Ok json -> declarative_catalog_names_from_json json
      | Error _ -> [])

let live_catalog_names ?config_path () =
  declarative_catalog_names ?config_path ()

let fallback_name_for_catalog use ~catalog =
  match catalog with
  | name :: _ -> name
  | [] -> "route." ^ logical_use_key use

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
       were validated; preserving configured target (fallback would be %s)"
      route_key target fallback
  end

(* ── Phonebook-based routing (RFC Cascade-Phonebook Phase 4) ───── *)

let task_use_of_logical_use = function
  | Keeper_turn | Phase_recovery | Phase_buffer | Openai_compat
  | Persona_generation ->
      Cascade_routing_policy.Code_generation
  | Tool_required | Tool_rerank_use -> Cascade_routing_policy.Tool_execution
  | Governance_judge | Operator_judge | Cross_verifier | Verifier
  | Adversarial_reviewer ->
      Cascade_routing_policy.Code_review
  | Auto_responder | Routing | Provider_benchmark | Simple_task
  | Moderate_task ->
      Cascade_routing_policy.Quick_decision
  | Complex_task -> Cascade_routing_policy.Long_reasoning

(** Resolve a logical_use to model strings via the phonebook.

    Maps canonical route use → [task_use] → tier-group → model strings.
    Returns [None] when the phonebook is unavailable. *)
let cascade_models_for_use_via_phonebook
    ?config_path
    (use : logical_use)
  : string list option =
  let task = task_use_of_logical_use use in
    let phonebook =
      match config_path with
      | Some path ->
        (match Cascade_config_loader.load_phonebook path with
         | Ok pb -> Some pb
         | Error _ -> None)
      | None ->
        (match Cascade_config_loader.load_phonebook_from_config () with
         | Some (Ok pb) -> Some pb
         | _ -> None)
    in
    match phonebook with
    | None -> None
    | Some pb ->
      let models =
        Cascade_phonebook_resolve.resolve_model_strings_for_task pb task
      in
      if models = [] then None else Some models

(** Resolve a logical_use to Provider_config.t list via the phonebook.

    Full phonebook path: route use → task_use → tier-group → models →
    providers → endpoint/auth → Provider_config.t.
    Returns [None] when phonebook is unavailable or no models resolve. *)
let cascade_provider_configs_for_use_via_phonebook
    ?config_path
    ?temperature
    ?max_tokens
    (use : logical_use)
  : Llm_provider.Provider_config.t list option =
  let task = task_use_of_logical_use use in
    let phonebook =
      match config_path with
      | Some path ->
        (match Cascade_config_loader.load_phonebook path with
         | Ok pb -> Some pb
         | Error _ -> None)
      | None ->
        (match Cascade_config_loader.load_phonebook_from_config () with
         | Some (Ok pb) -> Some pb
         | _ -> None)
    in
    match phonebook with
    | None -> None
    | Some pb ->
      let configs =
        Cascade_phonebook_resolve.resolve_provider_configs_for_task
          ?temperature ?max_tokens pb task
      in
      if configs = [] then None else Some configs

let cascade_name_for_use ?config_path use =
  let route_key = logical_use_key use in
  let route_target =
    configured_route_bindings ?config_path ()
    |> List.find_map (fun (key, target) ->
           if String.equal key route_key then Some target else None)
  in
  let catalog_names = live_catalog_names ?config_path () in
  let fallback = fallback_name_for_catalog use ~catalog:catalog_names in
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
