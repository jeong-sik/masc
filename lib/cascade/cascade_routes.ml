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
   (cascade.json) is the single source of truth for keeper-assignable
   profile names.  This module performs static lookup only — operator
   spec (cascade.json [routes] + fallback_cascade) decides routing and
   the runtime cascade chain handles try/fail/next-cascade.  If the
   catalog is empty at runtime,
   [Cascade_catalog_runtime.validate_path_result] already rejects keeper
   boot, so a missing catalog never reaches these helpers; the
   [failwith] in [fallback_from_entries]/[fallback_name_for_catalog]
   guards that boot-time invariant. *)

let route use key aliases = { use; key; aliases }

let route_specs =
  [
    route Keeper_turn "keeper_turn"
      [
        "default";
        "default_models";
        "oas-keeper_unified";
        "coding_first";
        "oas-coding_first";
        "keeper_reply";
        "keeper_unified";
      ];
    route Phase_recovery "phase_recovery" [ "local_recovery" ];
    route Phase_buffer "phase_buffer" [ "local_only" ];
    route Tool_required "tool_required"
      [ "tool_use_strict"; "resilient_breaker" ];
    route Governance_judge "governance_judge" [];
    route Operator_judge "operator_judge" [];
    route Cross_verifier "cross_verifier" [];
    route Verifier "verifier" [];
    route Autoresearch "autoresearch" [];
    route Adversarial_reviewer "adversarial_reviewer" [];
    route Auto_responder "auto_responder" [];
    route Routing "routing" [ "routing_judge" ];
    route Openai_compat "openai_compat" [];
    route Persona_generation "persona_generation" [];
    route Provider_benchmark "provider_benchmark" [];
    route Simple_task "simple_task" [];
    route Moderate_task "moderate_task" [];
    route Complex_task "complex_task" [];
    route Tool_rerank_use "llm_rerank" [];
  ]

let spec_for_use use =
  match List.find_opt (fun spec -> spec.use = use) route_specs with
  | Some spec -> spec
  | None -> assert false

let all_logical_uses = List.map (fun spec -> spec.use) route_specs

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

let route_bindings_from_json = function
  | `Assoc fields -> (
      match List.assoc_opt "routes" fields with
      | Some (`Assoc routes) ->
          routes
          |> List.filter_map (fun (key, value) ->
                 match value with
                 | `String raw_target ->
                     let target = String.trim raw_target in
                     if String.equal key "" || String.equal target "" then None
                     else Some (key, target)
                 | _ -> None)
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
      match Cascade_config_loader.load_json path with
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

let catalog_empty_invariant_violation context =
  failwith
    (Printf.sprintf
       "cascade catalog empty when resolving %s — \
        Cascade_catalog_runtime.validate_path_result should have rejected \
        keeper boot before this is reached"
       context)

let fallback_from_entries use entries =
  let _ = spec_for_use use in
  match first_catalog_name entries with
  | Some name -> name
  | None ->
      catalog_empty_invariant_violation
        (Printf.sprintf "logical use %S" (logical_use_key use))

let fallback_name_for_catalog use ~catalog =
  let _ = spec_for_use use in
  match catalog with
  | name :: _ -> name
  | [] ->
      catalog_empty_invariant_violation
        (Printf.sprintf "logical use %S" (logical_use_key use))

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
       were validated; using %s"
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
      warn_unvalidated_route_target_once ~route_key ~target ~fallback;
      fallback
  | Some target when List.mem target catalog_names -> target
  | Some target ->
      warn_invalid_route_target_once ~route_key ~target ~fallback;
      fallback
  | None -> fallback
