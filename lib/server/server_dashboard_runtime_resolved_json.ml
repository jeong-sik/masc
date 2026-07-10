(* GET /api/v1/runtime/resolved — single source of truth for "what runtime,
   model, and max-context is actually applied" (bugs #14/#15/#36):

   - #15: max-context previously diverged across three sources (runtime.toml
     override, OAS hardcoded defaults, OAS capability catalog cap). This
     document reports the one value [Runtime.max_context_of_runtime] resolves,
     plus which of [override]/[capability]/[override_clamped_by_capability]
     produced it ([Runtime.resolve_max_context_of_runtime]).
   - #14: the settings panel previously rendered only explicit
     [\[runtime.assignments\]] entries. [assignments] here joins every
     configured keeper — including ones riding [\[runtime\].default] with no
     explicit entry — so the frontend never has to reconstruct that join.
   - #36: this is the one place an operator can see the resolved
     runtime/model actually in effect. *)

let string_opt_json = Json_util.string_opt_to_json
let int_opt_json = Json_util.int_opt_to_json

let runtime_resolution_json (rt : Runtime.t) : Yojson.Safe.t =
  let effective_max_context, source =
    match Runtime.resolve_max_context_of_runtime rt with
    | Some (n, source) -> Some n, Some source
    | None -> None, None
  in
  `Assoc
    [ "id", `String rt.id
    ; "provider", `String rt.provider.display_name
    ; "model", `String rt.model.api_name
    ; "effective_max_context", int_opt_json effective_max_context
    ; ( "max_context_source"
      , string_opt_json (Option.map Runtime.max_context_source_to_string source) )
    ; "max_output_tokens", int_opt_json (Runtime.max_output_tokens_of_runtime_id rt.id)
    ; "is_local", `Bool (Runtime.is_local_runtime rt)
    ; "is_default", `Bool rt.binding.is_default
    ]
;;

let lane_json (lane : Runtime_lane.t) : Yojson.Safe.t =
  `Assoc
    [ "id", `String (Runtime_lane.id lane)
    ; "runtime_ids", Json_util.json_string_list (Runtime_lane.ordered_candidates lane)
    ]
;;

let resolved_assignment_json
      (resolution : [ `Lane of Runtime_lane.t | `Single_runtime of Runtime.t | `Missing ])
  : Yojson.Safe.t
  =
  match resolution with
  | `Lane lane -> `Assoc [ "kind", `String "lane"; "id", `String (Runtime_lane.id lane) ]
  | `Single_runtime rt -> `Assoc [ "kind", `String "single_runtime"; "id", `String rt.id ]
  | `Missing -> `Assoc [ "kind", `String "missing"; "id", `Null ]
;;

(* Mirrors [Keeper_meta_contract.runtime_id_of_meta]: a keeper with no
   [\[runtime.assignments\]] entry (or a blank one) runs on [\[runtime\].default].
   Duplicating that exact fallback here (rather than only reporting explicit
   assignments) is bug #14's fix — the resolved document must match what a
   turn actually dispatches to. *)
let assignment_json (default : Runtime.t option) (keeper_name : string) : Yojson.Safe.t =
  let explicit_id = Runtime.runtime_id_for_keeper keeper_name in
  let assignment_source, runtime_id =
    match explicit_id with
    | Some id when String.trim id <> "" -> "explicit", Some (String.trim id)
    | Some _ | None -> "default", Option.map (fun (rt : Runtime.t) -> rt.id) default
  in
  let resolved =
    match runtime_id with
    | Some id -> resolved_assignment_json (Runtime.resolve_assignment id)
    | None -> `Assoc [ "kind", `String "missing"; "id", `Null ]
  in
  `Assoc
    [ "keeper", `String keeper_name
    ; "assignment_source", `String assignment_source
    ; "resolved", resolved
    ]
;;

(* Union of explicit [\[runtime.assignments\]] keys and the keeper registry:
   an assignment can name a keeper whose directory has not materialized yet,
   and the registry can list keepers with no assignment at all (the default
   riders bug #14 is about). *)
let all_keeper_names ~(config : Workspace.config) : string list =
  let assigned = List.map fst (Runtime.keeper_assignments ()) in
  let registered = Keeper_meta_store.keeper_names config in
  assigned @ registered |> List.sort_uniq String.compare
;;

let build ~generated_at_iso ~(config : Workspace.config) : Yojson.Safe.t =
  let default = Runtime.get_default_runtime () in
  `Assoc
    [ "generated_at_iso", `String generated_at_iso
    ; "source", `String "/api/v1/runtime/resolved"
    ; "config_path", string_opt_json (Runtime.config_path ())
    ; ( "default_runtime"
      , match default with
        | Some rt -> runtime_resolution_json rt
        | None -> `Null )
    ; "runtimes", `List (List.map runtime_resolution_json (Runtime.get_runtimes ()))
    ; "lanes", `List (List.map lane_json (Runtime.lanes ()))
    ; ( "assignments"
      , `List (List.map (assignment_json default) (all_keeper_names ~config)) )
    ]
;;
