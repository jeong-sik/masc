open Base
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

(** Agent_tool_surfaces — lightweight internal tool surface definitions.

    This module stays dependency-light so spawned agents, local workers, and
    strict worker flows can share allowlists without pulling in the full public
    capability registry.
*)

open Types

module SS = Set.Make (String)

let unique_preserve_order = Json_util.dedupe_keep_order

let dedupe_schemas (schemas : Types.tool_schema list) =
  let unique, _ =
    List.fold_left
      (fun (acc, seen) (schema : Types.tool_schema) ->
        if SS.mem schema.name seen then (acc, seen)
        else (schema :: acc, SS.add schema.name seen))
      ([], SS.empty)
      schemas
  in
  List.rev unique

let prefixed_tool_names names =
  names |> List.map (fun name -> "mcp__masc__" ^ name)

let lookup_schemas_by_name_exn ~label all_schemas values =
  let requested =
    values
    |> List.map String.trim
    |> List.filter (fun value -> not (String.equal value ""))
    |> unique_preserve_order
  in
  let by_name = Hashtbl.create (List.length all_schemas) in
  List.iter
    (fun (schema : Types.tool_schema) ->
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
  Tool_catalog.tools_for_surface Tool_catalog.Spawned_agent

let spawned_agent_prefixed_tools : string list =
  prefixed_tool_names spawned_agent_public_tool_names

let local_worker_public_tool_names : string list =
  Tool_catalog.tools_for_surface Tool_catalog.Local_worker

let local_worker_contract_schemas : Types.tool_schema list =
  Sdk_tool_contract.sdk_tool_schemas

let local_worker_compat_passthrough_tool_names =
  [
    "masc_status";
    "masc_tasks";
    "masc_claim_next";
    "masc_transition";
    "masc_add_task";
    "masc_broadcast";
  ]

let local_worker_compat_passthrough_schemas : Types.tool_schema list =
  lookup_schemas_by_name_exn
    ~label:"agent_tool_surfaces.local_worker_compat_passthrough_schemas"
    (Tool_schemas_coord_core.schemas
     @ Tool_task_schemas.schemas
     @ Tool_schemas_inline_coord.schemas)
    local_worker_compat_passthrough_tool_names

let local_worker_internal_schemas : Types.tool_schema list =
  List.filter
    (fun (schema : Types.tool_schema) -> String.equal schema.name "masc_heartbeat")
    Tool_schemas_coord_core.schemas

let local_worker_code_schemas : Types.tool_schema list =
  Tool_schemas_code.schemas

let local_worker_worktree_schemas : Types.tool_schema list =
  Tool_schemas_worktree.schemas

let local_worker_run_schemas : Types.tool_schema list =
  Tool_schemas_run.schemas

let local_worker_spawn_schemas : Types.tool_schema list =
  List.filter
    (fun (schema : Types.tool_schema) -> String.equal schema.name "masc_spawn")
    Tool_schemas_inline_infra.schemas

let select_public_local_worker_schemas () =
  let wanted = local_worker_public_tool_names in
  dedupe_schemas
    (Tool_board.tools
    @ Tool_schemas_coord_core.schemas
    @ Tool_schemas_coord_extra.schemas
    @ local_worker_code_schemas
    @ local_worker_worktree_schemas
    @ local_worker_run_schemas
    @ local_worker_spawn_schemas)
  |> List.filter (fun (schema : Types.tool_schema) ->
         List.mem schema.name wanted)

let resolve_named_schemas all_schemas values :
    (Types.tool_schema list, string) Result.t =
  let requested =
    values
    |> List.map String.trim
    |> List.filter (fun value -> not (String.equal value ""))
    |> unique_preserve_order
  in
  let schemas =
    all_schemas
    |> List.filter (fun (schema : Types.tool_schema) ->
           List.mem schema.name requested)
  in
  let missing =
    requested
    |> List.filter (fun tool_name ->
           not
             (List.exists
                (fun (schema : Types.tool_schema) ->
                  String.equal schema.name tool_name)
                schemas))
  in
  match missing with [] ->
    Ok schemas
  | _ ->
    Error
      (Printf.sprintf "unknown tool schema(s): %s"
         (String.concat ", " missing))

let local_worker_tool_schemas ?names () :
    (Types.tool_schema list, string) Result.t =
  let all_schemas =
    dedupe_schemas
      ( local_worker_internal_schemas
      @ local_worker_compat_passthrough_schemas
      @ local_worker_contract_schemas
      @ select_public_local_worker_schemas () )
  in
  match names with
  | None -> Ok all_schemas
  | Some values -> resolve_named_schemas all_schemas values

(** Admin tool names that should be excluded from autonomous agents.
    SSOT: Tool_catalog.Admin surface. *)
let admin_tool_names : string list =
  Tool_catalog.tools_for_surface Tool_catalog.Admin

(** Role-catalog candidates for coordinators and fleet leaders.
    SSOT: Tool_catalog_surfaces.coordination_role_tools.
    [build_tool_catalog] filters against surfaced tool names so stale
    entries cannot escape into prompts. *)
let coordination_tool_names : string list =
  Tool_catalog_surfaces.coordination_role_tools

(** Role-catalog candidates for worker agents.
    SSOT: Tool_catalog_surfaces.execution_role_tools. *)
let execution_tool_names : string list =
  Tool_catalog_surfaces.execution_role_tools

let filter_catalog_to_available ~available names =
  let available = SS.of_list available in
  names
  |> List.filter (fun name -> SS.mem name available)
  |> unique_preserve_order

(** Build a role-based tool catalog from the full registered tool set.
    [role] determines which subset of tools the agent sees:
    - ["worker"]: execution-focused tools
    - ["coordinator"]: coordination and orchestration tools
    - [_]: all non-admin tools (autonomous default)
    Returns tool names (unprefixed). *)
let build_tool_catalog ~(role : string) () : string list =
  let all_names =
    spawned_agent_public_tool_names @ local_worker_public_tool_names
    |> unique_preserve_order
  in
  let filtered =
    match role with
    | "worker" ->
        filter_catalog_to_available ~available:all_names execution_tool_names
    | "coordinator" | "fleet_leader" ->
        filter_catalog_to_available ~available:all_names coordination_tool_names
    | _ ->
        (* autonomous: all except admin *)
        List.filter
          (fun name -> not (List.mem name admin_tool_names))
          all_names
  in
  unique_preserve_order filtered

(** [local_worker_resolvable_tool_names ()] returns only the tool names
    that [local_worker_tool_schemas] can actually resolve.  Use this to
    intersect with [build_tool_catalog] output before passing to
    [run_worker], so that the autonomous catalog does not include names
    unknown to the local worker schema registry. *)
let local_worker_resolvable_tool_names () : string list =
  match local_worker_tool_schemas () with
  | Ok schemas ->
      List.map (fun (s : Types.tool_schema) -> s.name) schemas
  | Error msg ->
      Log.Misc.warn "[AgentToolSurfaces] local_worker_tool_schemas failed: %s" msg;
      []
