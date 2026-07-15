module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float
module Random = Stdlib.Random

(** Keeper_tool_surfaces — lightweight internal tool surface definitions.

    This module stays dependency-light so spawned agents, local workers, and
    strict worker flows can share allowlists without pulling in the full public
    capability registry.
*)

open Masc_domain

module SS = Set_util.StringSet


let dedupe_schemas (schemas : Masc_domain.tool_schema list) =
  let unique, _ =
    List.fold_left
      (fun (acc, seen) (schema : Masc_domain.tool_schema) ->
        if SS.mem schema.name seen then (acc, seen)
        else (schema :: acc, SS.add schema.name seen))
      ([], SS.empty)
      schemas
  in
  List.rev unique

let prefixed_tool_names names =
  names |> List.map (fun name -> "mcp__masc__" ^ name)

(* Hashtbl materialisation helper for membership-only checks.  Used
   below where we'd otherwise scan a name list per element of a
   filter loop — replaces O(N x M) with O(N + M). *)
let name_set names =
  let tbl = Hashtbl.create (List.length names) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) names;
  tbl

let lookup_schemas_by_name_exn ~label all_schemas values =
  let requested =
    values
    |> List.map String.trim
    |> List.filter (fun value -> not (String.equal value ""))
    |> Json_util.dedupe_keep_order
  in
  let by_name = Hashtbl.create (List.length all_schemas) in
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
      if not (Hashtbl.mem by_name schema.name) then
        Hashtbl.add by_name schema.name schema)
    all_schemas;
  let missing =
    requested
    |> List.filter (fun tool_name -> not (Hashtbl.mem by_name tool_name))
  in
  (match missing with [] -> () | _ ->
    invalid_arg
      (Printf.sprintf "%s: unknown tool schema(s): %s" label
         (String.concat ", " missing)));
  (* Guard above ensures all names exist *)
  requested |> List.filter_map (Hashtbl.find_opt by_name)

let spawned_agent_public_tool_names : string list =
  Tool_catalog_surfaces.spawned_agent_surface_tools

let spawned_agent_prefixed_tools : string list =
  prefixed_tool_names spawned_agent_public_tool_names

let local_worker_public_tool_names : string list =
  Tool_catalog_surfaces.local_worker_surface_tools

let local_worker_contract_schemas : Masc_domain.tool_schema list =
  Sdk_tool_contract.sdk_tool_schemas

let local_worker_internal_schemas : Masc_domain.tool_schema list =
  List.filter
    (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name "masc_heartbeat")
    Tool_schemas_workspace_core.schemas

let local_worker_run_schemas : Masc_domain.tool_schema list =
  Tool_schemas_run.schemas

(* RFC-0182: local_worker_spawn_schemas removed — masc_spawn is dead. *)

let select_public_local_worker_schemas () =
  let wanted_set = name_set local_worker_public_tool_names in
  dedupe_schemas
    (Board_tool.tools
    @ Tool_schemas_workspace_core.schemas
    @ Task.Schemas.schemas
    @ Tool_schemas_agent.schemas
    @ local_worker_run_schemas)
  |> List.filter (fun (schema : Masc_domain.tool_schema) ->
         Hashtbl.mem wanted_set schema.name)

let resolve_named_schemas all_schemas values :
    (Masc_domain.tool_schema list, string) Result.t =
  let requested =
    values
    |> List.map String.trim
    |> List.filter (fun value -> not (String.equal value ""))
    |> Json_util.dedupe_keep_order
  in
  (* Materialise both directions of the membership relation once:
     - [requested_set] for the first filter (per-schema lookup),
     - [found_set] for the missing-name check (per-requested lookup).
     Previous shape ran [List.mem] / [List.exists] per element in each
     filter — O(S x R) and O(R x found) respectively. *)
  let requested_set = name_set requested in
  let schemas =
    all_schemas
    |> List.filter (fun (schema : Masc_domain.tool_schema) ->
           Hashtbl.mem requested_set schema.name)
  in
  let found_set =
    let tbl = Hashtbl.create (List.length schemas) in
    List.iter
      (fun (schema : Masc_domain.tool_schema) ->
        Hashtbl.replace tbl schema.name ())
      schemas;
    tbl
  in
  let missing =
    requested
    |> List.filter (fun tool_name -> not (Hashtbl.mem found_set tool_name))
  in
  match missing with [] ->
    Ok schemas
  | _ ->
    Error
      (Printf.sprintf "unknown tool schema(s): %s"
         (String.concat ", " missing))

let local_worker_tool_schemas ?names () :
    (Masc_domain.tool_schema list, string) Result.t =
  let all_schemas =
    dedupe_schemas
      ( local_worker_internal_schemas
      @ local_worker_contract_schemas
      @ select_public_local_worker_schemas () )
  in
  match names with
  | None -> Ok all_schemas
  | Some values -> resolve_named_schemas all_schemas values

(** Role-catalog candidates for workspace leads and fleet leaders.
    SSOT: Tool_catalog_surfaces.workspace_role_tools.
    [build_tool_catalog] filters against resolvable surfaced tool names so
    stale entries cannot escape into prompts. *)
let workspace_tool_names : string list =
  Tool_catalog_surfaces.workspace_role_tools

(** Role-catalog candidates for worker agents.
    SSOT: Tool_catalog_surfaces.execution_role_tools. *)
let execution_tool_names : string list =
  Tool_catalog_surfaces.execution_role_tools

let filter_catalog_to_available ~available names =
  let available = SS.of_list available in
  names
  |> List.filter (fun name -> SS.mem name available)
  |> Json_util.dedupe_keep_order

(** [local_worker_resolvable_tool_names ()] returns only the tool names
    that [local_worker_tool_schemas] can actually resolve. *)
let local_worker_resolvable_tool_names () : string list =
  match local_worker_tool_schemas () with
  | Ok schemas ->
      List.map (fun (s : Masc_domain.tool_schema) -> s.name) schemas
  | Error msg ->
      Log.Misc.warn "[AgentToolSurfaces] local_worker_tool_schemas failed: %s" msg;
      []

let role_catalog_available_tool_names () =
  let surfaced =
    spawned_agent_public_tool_names @ local_worker_public_tool_names
    |> Json_util.dedupe_keep_order
  in
  filter_catalog_to_available
    ~available:(local_worker_resolvable_tool_names ())
    surfaced

(** Build a role-based tool catalog from the full registered tool set.
    [role] determines which subset of tools the agent sees:
    - ["worker"]: execution-focused tools
    - ["workspace_lead"]: workspace and orchestration tools
    - [_]: all available spawned/local worker tools
    Returns tool names (unprefixed). *)
let build_tool_catalog ~(role : string) () : string list =
  let available_names = role_catalog_available_tool_names () in
  let filtered =
    match role with
    | "worker" ->
        filter_catalog_to_available ~available:available_names execution_tool_names
    | "workspace_lead" | "fleet_leader" ->
        filter_catalog_to_available ~available:available_names workspace_tool_names
    | _ -> available_names
  in
  Json_util.dedupe_keep_order filtered
