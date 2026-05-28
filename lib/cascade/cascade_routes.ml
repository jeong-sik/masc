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


let fallback_name_for_catalog use ~catalog =
  match catalog with
  | name :: _ -> name
  | [] -> "route." ^ logical_use_key use

let cascade_name_for_use ?config_path use =
  let route_key = logical_use_key use in
  let route_target =
    configured_route_bindings ?config_path ()
    |> List.find_map (fun (key, target) ->
           if String.equal key route_key then Some target else None)
  in
  match route_target with
  | Some target -> target
  | None -> "route." ^ route_key
