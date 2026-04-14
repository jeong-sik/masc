(** Capability_registry — canonical tool/capability SSOT.

    Public MCP tools and internal agent-facing tool surfaces are projections
    over one capability inventory. Some surfaces intentionally reuse the same
    tool name with a narrower schema (for example local worker projections).
*)

open Types

module StringSet = Set.Make (String)

type risk_class =
  | Safe
  | Audited
  | Privileged

type audience =
  | External_mcp_client
  | Spawned_managed_agent
  | Local_worker_agent
  | Keeper_agent
  | Privileged_executor

type surface =
  | Public_mcp
  | Spawned_agent_mcp
  | Local_worker
  | Keeper_standard
  | Keeper_privileged
  | Privileged_executor_surface

type projection = {
  surface : surface;
  tool_name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  backend_tool_name : string;
}

type capability_def = {
  capability_id : string;
  risk_class : risk_class;
  audiences : audience list;
  supports_audit_evidence : bool;
  supports_direct_user_discovery : bool;
  projections : projection list;
}

type capability_seed = {
  capability_id : string;
  risk_class : risk_class;
  audiences : audience list;
  supports_audit_evidence : bool;
  supports_direct_user_discovery : bool;
  projection : projection;
}

let risk_rank = function
  | Safe -> 0
  | Audited -> 1
  | Privileged -> 2

let max_risk left right =
  if risk_rank left >= risk_rank right then left else right

let unique_preserve_order = Json_util.dedupe_keep_order

let dedupe_schemas (schemas : Types.tool_schema list) =
  let seen = ref StringSet.empty in
  List.filter
    (fun (schema : Types.tool_schema) ->
      if StringSet.mem schema.name !seen then
        false
      else (
        seen := StringSet.add schema.name !seen;
        true))
    schemas

let dedupe_projections projections =
  let seen = ref StringSet.empty in
  List.filter
    (fun (projection : projection) ->
      let key =
        Printf.sprintf "%s|%s"
          (match projection.surface with
          | Public_mcp -> "public_mcp"
          | Spawned_agent_mcp -> "spawned_agent_mcp"
          | Local_worker -> "local_worker"
          | Keeper_standard -> "keeper_standard"
          | Keeper_privileged -> "keeper_privileged"
          | Privileged_executor_surface -> "privileged_executor")
          projection.tool_name
      in
      if StringSet.mem key !seen then
        false
      else (
        seen := StringSet.add key !seen;
        true))
    projections

let prefixed_tool_names names =
  names |> List.map (fun name -> "mcp__masc__" ^ name)

let canonical_capability_id tool_name =
  match (Tool_catalog.metadata tool_name).Tool_catalog.canonical_name with
  | Some canonical_name -> canonical_name
  | None -> tool_name


let surface_to_string = function
  | Public_mcp -> "public_mcp"
  | Spawned_agent_mcp -> "spawned_agent_mcp"
  | Local_worker -> "local_worker"
  | Keeper_standard -> "keeper_standard"
  | Keeper_privileged -> "keeper_privileged"
  | Privileged_executor_surface -> "privileged_executor"

let risk_class_to_string = function
  | Safe -> "safe"
  | Audited -> "audited"
  | Privileged -> "privileged"

let audience_to_string = function
  | External_mcp_client -> "external_mcp_client"
  | Spawned_managed_agent -> "spawned_managed_agent"
  | Local_worker_agent -> "local_worker_agent"
  | Keeper_agent -> "keeper_agent"
  | Privileged_executor -> "privileged_executor"

let projection_to_schema (projection : projection) : Types.tool_schema =
  {
    Types.name = projection.tool_name;
    description = projection.description;
    input_schema = projection.input_schema;
  }

let make_seed ?capability_id ?(risk_class = Safe)
    ?(audiences = [ External_mcp_client ]) ?(supports_audit_evidence = false)
    ?(supports_direct_user_discovery = true) ~surface ?backend_tool_name
    (schema : Types.tool_schema) : capability_seed =
  let backend_tool_name = Option.value ~default:schema.name backend_tool_name in
  {
    capability_id =
      Option.value ~default:(canonical_capability_id backend_tool_name)
        capability_id;
    risk_class;
    audiences;
    supports_audit_evidence;
    supports_direct_user_discovery;
    projection =
      {
        surface;
        tool_name = schema.name;
        description = schema.description;
        input_schema = schema.input_schema;
        backend_tool_name;
      };
  }

let spawned_agent_public_tool_names : string list =
  Tool_catalog.tools_for_surface Tool_catalog.Spawned_agent

let spawned_agent_prefixed_tools : string list =
  prefixed_tool_names (Tool_catalog.tools_for_surface Tool_catalog.Spawned_agent)

let local_worker_public_tool_names : string list =
  Tool_catalog.tools_for_surface Tool_catalog.Local_worker

let local_worker_internal_schemas : Types.tool_schema list =
  Agent_tool_surfaces.local_worker_internal_schemas

let privileged_public_tool_names : string list =
  [ "masc_spawn"; "masc_worktree_create"; "masc_worktree_remove" ]

let privileged_keeper_tool_names : string list =
  [ "keeper_bash"; "keeper_fs_edit"; "keeper_github";
    "keeper_pr_workflow"; "masc_worktree_create" ]

(* Derived from Tool_catalog_surfaces.keeper_internal_replacement (SSOT).
   Returns the masc_* backend name for aliased tools, identity otherwise. *)
let keeper_backend_tool_name name =
  match Tool_catalog_surfaces.keeper_internal_replacement name with
  | Some masc_name -> masc_name
  | None -> name

let public_projection_seeds_from (public_tool_source_schemas : Types.tool_schema list) :
    capability_seed list =
  let public_schemas =
    Tool_help_registry.canonicalize_schemas public_tool_source_schemas
  in
  let make_public_seed schema =
    let name = schema.Types.name in
    let risk_class =
      if List.mem name privileged_public_tool_names then
        Privileged
      else if
        List.mem name spawned_agent_public_tool_names
      then
        Audited
      else
        Safe
    in
    let audiences =
      unique_preserve_order
        (External_mcp_client
         :: (if List.mem name spawned_agent_public_tool_names then [ Spawned_managed_agent ] else [])
         @ (if List.mem name local_worker_public_tool_names then [ Local_worker_agent ] else []))
    in
    let supports_audit_evidence =
      List.mem name spawned_agent_public_tool_names
    in
    let base =
      [
        make_seed ~risk_class ~audiences ~supports_audit_evidence
          ~supports_direct_user_discovery:true ~surface:Public_mcp schema;
      ]
    in
    let with_spawned =
      if List.mem name spawned_agent_public_tool_names then
        base
        @ [
            make_seed ~risk_class ~audiences ~supports_audit_evidence
              ~supports_direct_user_discovery:false
              ~surface:Spawned_agent_mcp schema;
          ]
      else
        base
    in
    let with_local_worker =
      if List.mem name local_worker_public_tool_names then
        with_spawned
        @ [
            make_seed ~risk_class ~audiences ~supports_audit_evidence
              ~supports_direct_user_discovery:false ~surface:Local_worker schema;
          ]
      else
        with_spawned
    in
    with_local_worker
  in
  public_schemas |> List.concat_map make_public_seed

let local_worker_internal_seeds : capability_seed list =
  let base =
    local_worker_internal_schemas
    |> List.map (fun schema ->
           make_seed ~risk_class:Audited
             ~audiences:[ Local_worker_agent ]
             ~supports_audit_evidence:true
             ~supports_direct_user_discovery:false ~surface:Local_worker
             schema)
  in
  base

let keeper_projection_seeds : capability_seed list =
  Tool_shard.keeper_model_tools
  |> List.concat_map (fun (tool : Types.tool_schema) ->
         let schema = tool in
         let backend_tool_name = keeper_backend_tool_name tool.name in
         let privileged = List.mem tool.name privileged_keeper_tool_names in
         let primary_surface =
           if privileged then Keeper_privileged else Keeper_standard
         in
         let primary_seed =
           make_seed
             ~risk_class:(if privileged then Privileged else Audited)
             ~audiences:
               (if privileged then
                  [ Keeper_agent; Privileged_executor ]
                else
                  [ Keeper_agent ])
             ~supports_audit_evidence:true
             ~supports_direct_user_discovery:false ~surface:primary_surface
             ~backend_tool_name schema
         in
         if privileged then
           [
             primary_seed;
             make_seed ~capability_id:primary_seed.capability_id
               ~risk_class:Privileged
               ~audiences:[ Privileged_executor ]
               ~supports_audit_evidence:true
               ~supports_direct_user_discovery:false
               ~surface:Privileged_executor_surface ~backend_tool_name schema;
           ]
         else
           [ primary_seed ])

let all_projection_seeds_from (public_tool_source_schemas : Types.tool_schema list) :
    capability_seed list =
  public_projection_seeds_from public_tool_source_schemas
  @ local_worker_internal_seeds @ keeper_projection_seeds

let all_capabilities_from (public_tool_source_schemas : Types.tool_schema list) :
    capability_def list =
  let tbl : (string, capability_def) Hashtbl.t = Hashtbl.create 256 in
  let ordered_ids = ref [] in
  List.iter
    (fun (seed : capability_seed) ->
      match Hashtbl.find_opt tbl seed.capability_id with
      | None ->
          ordered_ids := !ordered_ids @ [ seed.capability_id ];
          Hashtbl.replace tbl seed.capability_id
            {
              capability_id = seed.capability_id;
              risk_class = seed.risk_class;
              audiences = unique_preserve_order seed.audiences;
              supports_audit_evidence = seed.supports_audit_evidence;
              supports_direct_user_discovery = seed.supports_direct_user_discovery;
              projections = [ seed.projection ];
            }
      | Some existing ->
          Hashtbl.replace tbl seed.capability_id
            {
              capability_id = existing.capability_id;
              risk_class = max_risk existing.risk_class seed.risk_class;
              audiences =
                unique_preserve_order (existing.audiences @ seed.audiences);
              supports_audit_evidence =
                existing.supports_audit_evidence || seed.supports_audit_evidence;
              supports_direct_user_discovery =
                existing.supports_direct_user_discovery
                || seed.supports_direct_user_discovery;
              projections =
                dedupe_projections (existing.projections @ [ seed.projection ]);
            })
    (all_projection_seeds_from public_tool_source_schemas);
  !ordered_ids
  |> List.filter_map (fun capability_id -> Hashtbl.find_opt tbl capability_id)

let surface_tool_schemas_from (public_tool_source_schemas : Types.tool_schema list)
    surface : Types.tool_schema list =
  match surface with
  | Public_mcp ->
      public_tool_source_schemas
      |> Tool_help_registry.canonicalize_schemas
      |> List.filter (fun (schema : Types.tool_schema) ->
             Tool_catalog.is_public_mcp schema.name)
      |> dedupe_schemas
  | _ ->
      all_projection_seeds_from public_tool_source_schemas
      |> List.filter (fun (seed : capability_seed) -> seed.projection.surface = surface)
      |> List.map (fun (seed : capability_seed) -> projection_to_schema seed.projection)
      |> dedupe_schemas

let surface_tool_names_from (public_tool_source_schemas : Types.tool_schema list)
    surface : string list =
  surface_tool_schemas_from public_tool_source_schemas surface
  |> List.map (fun (schema : Types.tool_schema) -> schema.name)

let public_raw_tool_schemas_from (public_tool_source_schemas : Types.tool_schema list) :
    Types.tool_schema list =
  dedupe_schemas public_tool_source_schemas

(* Surface filtering at this layer removed in #1961 — all registered tools pass
   through here unchanged. The public MCP surface is now filtered at the profile
   level: [Mcp_server_eio_tool_profile.tool_schemas_for_profile] applies
   [Tool_catalog.is_public_mcp] to the Full profile, reducing tools/list to ~34.
   Internal dispatch ([Tool_dispatch.dispatch]) remains unrestricted. *)
let public_tool_schemas_from (public_tool_source_schemas : Types.tool_schema list) :
    Types.tool_schema list =
  dedupe_schemas public_tool_source_schemas
  |> Tool_help_registry.canonicalize_schemas

let visible_public_tool_schemas_from
    ?(include_hidden = false) ?(include_deprecated = false)
    (public_tool_source_schemas : Types.tool_schema list) : Types.tool_schema list =
  public_tool_schemas_from public_tool_source_schemas
  |> List.filter (fun (schema : Types.tool_schema) ->
         Tool_catalog.is_visible ~include_hidden ~include_deprecated schema.name)

let local_worker_tool_schemas ?names () :
    (Types.tool_schema list, string) result =
  Agent_tool_surfaces.local_worker_tool_schemas ?names ()

let keeper_all_tool_names : string list =
  Tool_shard.keeper_model_tools
  |> List.map (fun tool -> tool.Types.name)
  |> unique_preserve_order

let keeper_safe_tool_names : string list =
  Tool_shard.keeper_model_tools
  |> List.map (fun tool -> tool.Types.name)
  |> List.filter (fun name -> not (List.mem name privileged_keeper_tool_names))
  |> unique_preserve_order

let keeper_privileged_tool_names : string list =
  privileged_keeper_tool_names

let keeper_wrapped_server_tools : string list =
  [ "masc_board_post"; "masc_board_comment"; "masc_board_list";
    "masc_tasks"; "masc_broadcast";
    "masc_worktree_create"; "masc_worktree_list";
    "masc_code_search"; "masc_code_symbols"; "masc_code_read";
    "masc_cases"; "masc_case_status"; "masc_ruling_status";
    "masc_governance_status"; "masc_governance_feed";
    "masc_case_brief_submit"; "masc_petition_submit" ]

let keeper_wrapped_internal_tools : string list =
  keeper_all_tool_names

let surface_snapshot_json
    (public_tool_source_schemas : Types.tool_schema list) =
  let surface_json surface =
    let names = surface_tool_names_from public_tool_source_schemas surface in
    `Assoc
      [
        ("count", `Int (List.length names));
        ("tools", `List (List.map (fun name -> `String name) names));
      ]
  in
  `Assoc
    [
      ("public_mcp", surface_json Public_mcp);
      ("spawned_agent_mcp", surface_json Spawned_agent_mcp);
      ("local_worker", surface_json Local_worker);
      ("keeper_standard", surface_json Keeper_standard);
      ("keeper_privileged", surface_json Keeper_privileged);
      ("privileged_executor", surface_json Privileged_executor_surface);
      ("keeper_wrapped_server_tools",
        `List (List.map (fun name -> `String name) keeper_wrapped_server_tools));
    ]

let capability_to_json (capability : capability_def) =
  `Assoc
    [
      ("capability_id", `String capability.capability_id);
      ("risk_class", `String (risk_class_to_string capability.risk_class));
      ( "audiences",
        `List
          (List.map
             (fun audience -> `String (audience_to_string audience))
             capability.audiences) );
      ("supports_audit_evidence", `Bool capability.supports_audit_evidence);
      ( "supports_direct_user_discovery",
        `Bool capability.supports_direct_user_discovery );
      ( "projections",
        `List
          (List.map
             (fun (projection : projection) ->
               `Assoc
                 [
                   ("surface", `String (surface_to_string projection.surface));
                   ("tool_name", `String projection.tool_name);
                   ("backend_tool_name", `String projection.backend_tool_name);
                 ])
             capability.projections) );
    ]
