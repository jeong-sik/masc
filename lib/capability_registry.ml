(** Capability_registry — canonical tool/capability SSOT.

    Public MCP tools and internal agent-facing tool surfaces are projections
    over one capability inventory. Some surfaces intentionally reuse the same
    tool name with a narrower schema (for example local worker projections).
*)

open Masc_domain

module StringSet = Set_util.StringSet
module StringMap = Set_util.StringMap

type audience =
  | External_mcp_client
  | Spawned_managed_agent
  | Local_worker_agent
  | Keeper_agent

type surface =
  | Public_mcp
  | Spawned_agent_mcp
  | Local_worker
  | Keeper

type projection = {
  surface : surface;
  tool_name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  backend_tool_name : string;
}

type capability_def = {
  capability_id : string;
  audiences : audience list;
  supports_audit_evidence : bool;
  supports_direct_user_discovery : bool;
  projections : projection list;
}

type capability_seed = {
  capability_id : string;
  audiences : audience list;
  supports_audit_evidence : bool;
  supports_direct_user_discovery : bool;
  projection : projection;
}

let dedupe_schemas (schemas : Masc_domain.tool_schema list) =
  let _, results =
    List.fold_left
      (fun (seen, acc) (schema : Masc_domain.tool_schema) ->
        if StringSet.mem schema.name seen then (seen, acc)
        else (StringSet.add schema.name seen, schema :: acc))
      (StringSet.empty, []) schemas
  in
  List.rev results

let dedupe_projections projections =
  let _, results =
    List.fold_left
      (fun (seen, acc) (projection : projection) ->
        let key =
          Printf.sprintf "%s|%s"
            (match projection.surface with
            | Public_mcp -> "public_mcp"
            | Spawned_agent_mcp -> "spawned_agent_mcp"
            | Local_worker -> "local_worker"
            | Keeper -> "keeper")
            projection.tool_name
        in
        if StringSet.mem key seen then (seen, acc)
        else (StringSet.add key seen, projection :: acc))
      (StringSet.empty, []) projections
  in
  List.rev results

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
  | Keeper -> "keeper"

let audience_to_string = function
  | External_mcp_client -> "external_mcp_client"
  | Spawned_managed_agent -> "spawned_managed_agent"
  | Local_worker_agent -> "local_worker_agent"
  | Keeper_agent -> "keeper_agent"

let projection_to_schema (projection : projection) : Masc_domain.tool_schema =
  {
    Masc_domain.name = projection.tool_name;
    description = projection.description;
    input_schema = projection.input_schema;
  }

let make_seed ?capability_id
    ?(audiences = [ External_mcp_client ]) ?(supports_audit_evidence = false)
    ?(supports_direct_user_discovery = true) ~surface ?backend_tool_name
    (schema : Masc_domain.tool_schema) : capability_seed =
  let backend_tool_name = Option.value ~default:schema.name backend_tool_name in
  {
    capability_id =
      Option.value ~default:(canonical_capability_id backend_tool_name)
        capability_id;
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
  Tool_catalog_surfaces.spawned_agent_surface_tools

let spawned_agent_prefixed_tools : string list =
  prefixed_tool_names Tool_catalog_surfaces.spawned_agent_surface_tools

let local_worker_public_tool_names : string list =
  Tool_catalog_surfaces.local_worker_surface_tools

let local_worker_internal_schemas : Masc_domain.tool_schema list =
  Keeper_tool_surfaces.local_worker_internal_schemas

let keeper_backend_tool_name name = name

let keeper_wrapped_server_tool_alias name =
  match name with
  | "masc_board_post" -> "keeper_board_post"
  | "masc_board_comment" -> "keeper_board_comment"
  | "masc_board_list" -> "keeper_board_list"
  | "masc_tasks" -> "keeper_tasks_list"
  | "masc_broadcast" -> "keeper_broadcast"
  | _ -> name
;;

let keeper_wrapped_server_tools : string list =
  [ "masc_board_post"; "masc_board_comment"; "masc_board_list";
    "masc_tasks"; "masc_broadcast";
  ]
;;

let public_projection_seeds_from (public_tool_source_schemas : Masc_domain.tool_schema list) :
    capability_seed list =
  let public_schemas =
    Tool_help_registry.canonicalize_schemas public_tool_source_schemas
  in
  let make_public_seed schema =
    let name = schema.Masc_domain.name in
    let audiences =
      Json_util.dedupe_keep_order
        (External_mcp_client
         :: (if List.mem name spawned_agent_public_tool_names then [ Spawned_managed_agent ] else [])
         @ (if List.mem name local_worker_public_tool_names then [ Local_worker_agent ] else []))
    in
    let supports_audit_evidence =
      List.mem name spawned_agent_public_tool_names
    in
    let base =
      [
        make_seed ~audiences ~supports_audit_evidence
          ~supports_direct_user_discovery:true ~surface:Public_mcp schema;
      ]
    in
    let with_spawned =
      if List.mem name spawned_agent_public_tool_names then
        base
        @ [
            make_seed ~audiences ~supports_audit_evidence
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
            make_seed ~audiences ~supports_audit_evidence
              ~supports_direct_user_discovery:false ~surface:Local_worker schema;
          ]
      else
        with_spawned
    in
    let with_keeper_wrapper =
      if List.mem name keeper_wrapped_server_tools then
        let alias_name = keeper_wrapped_server_tool_alias name in
        let alias_schema =
          match
            List.find_opt
              (fun (s : Masc_domain.tool_schema) -> String.equal s.name alias_name)
              Tool_shard.all_keeper_tool_schemas
          with
          | Some s -> s
          | None -> schema
        in
        with_local_worker
        @ [
            make_seed ~capability_id:name
              ~audiences:[ Keeper_agent ]
              ~supports_audit_evidence:true
              ~supports_direct_user_discovery:false
              ~surface:Keeper ~backend_tool_name:alias_name alias_schema;
          ]
      else
        with_local_worker
    in
    if List.mem name Tool_catalog_surfaces.keeper_schedule_surface_tools then
      with_keeper_wrapper
      @ [
          make_seed ~audiences:[ Keeper_agent ]
            ~supports_audit_evidence
            ~supports_direct_user_discovery:false ~surface:Keeper
            schema;
        ]
    else
      with_keeper_wrapper
  in
  public_schemas |> List.concat_map make_public_seed

let local_worker_internal_seeds : capability_seed list =
  let base =
    local_worker_internal_schemas
    |> List.map (fun schema ->
           make_seed
             ~audiences:[ Local_worker_agent ]
             ~supports_audit_evidence:true
             ~supports_direct_user_discovery:false ~surface:Local_worker
             schema)
  in
  base

let keeper_projection_seeds : capability_seed list =
  Tool_shard.keeper_model_tools
  |> List.map (fun (tool : Masc_domain.tool_schema) ->
         let schema = tool in
         let backend_tool_name = keeper_backend_tool_name tool.name in
         make_seed
           ~audiences:[ Keeper_agent ]
           ~supports_audit_evidence:true
           ~supports_direct_user_discovery:false ~surface:Keeper
           ~backend_tool_name schema)

let all_projection_seeds_from (public_tool_source_schemas : Masc_domain.tool_schema list) :
    capability_seed list =
  public_projection_seeds_from public_tool_source_schemas
  @ local_worker_internal_seeds @ keeper_projection_seeds

let all_capabilities_from (public_tool_source_schemas : Masc_domain.tool_schema list) :
    capability_def list =
  let seeds = all_projection_seeds_from public_tool_source_schemas in
  let tbl, ordered_ids =
    List.fold_left
      (fun (tbl, ordered_ids) (seed : capability_seed) ->
        match StringMap.find_opt seed.capability_id tbl with
        | None ->
            let def =
              {
                capability_id = seed.capability_id;
                audiences = Json_util.dedupe_keep_order seed.audiences;
                supports_audit_evidence = seed.supports_audit_evidence;
                supports_direct_user_discovery = seed.supports_direct_user_discovery;
                projections = [ seed.projection ];
              }
            in
            ( StringMap.add seed.capability_id def tbl,
              seed.capability_id :: ordered_ids )
        | Some existing ->
            let def =
              {
                capability_id = existing.capability_id;
                audiences =
                  Json_util.dedupe_keep_order (existing.audiences @ seed.audiences);
                supports_audit_evidence =
                  existing.supports_audit_evidence || seed.supports_audit_evidence;
                supports_direct_user_discovery =
                  existing.supports_direct_user_discovery
                  || seed.supports_direct_user_discovery;
                projections =
                  dedupe_projections (existing.projections @ [ seed.projection ]);
              }
            in
            (StringMap.add seed.capability_id def tbl, ordered_ids))
      (StringMap.empty, []) seeds
  in
  List.rev ordered_ids |> List.filter_map (fun id -> StringMap.find_opt id tbl)

let surface_tool_schemas_from (public_tool_source_schemas : Masc_domain.tool_schema list)
    surface : Masc_domain.tool_schema list =
  match surface with
  | Public_mcp ->
      public_tool_source_schemas
      |> Tool_help_registry.canonicalize_schemas
      |> List.filter (fun (schema : Masc_domain.tool_schema) ->
             Tool_catalog.is_public_mcp schema.name)
      |> dedupe_schemas
  | _ ->
      all_projection_seeds_from public_tool_source_schemas
      |> List.filter (fun (seed : capability_seed) -> seed.projection.surface = surface)
      |> List.map (fun (seed : capability_seed) -> projection_to_schema seed.projection)
      |> dedupe_schemas

let surface_tool_names_from (public_tool_source_schemas : Masc_domain.tool_schema list)
    surface : string list =
  surface_tool_schemas_from public_tool_source_schemas surface
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)

let public_raw_tool_schemas_from (public_tool_source_schemas : Masc_domain.tool_schema list) :
    Masc_domain.tool_schema list =
  dedupe_schemas public_tool_source_schemas

(* Surface filtering at this layer removed in #1961 — all registered tools pass
   through here unchanged. The public MCP surface is now filtered at the profile
   level: [Mcp_server_eio_tool_profile.tool_schemas_for_profile] applies
   [Tool_catalog.is_public_mcp] to the Full profile, reducing tools/list to ~34.

   RFC-0084 §1.1 + §2.2 (PR-7) — Internal dispatch now flows through
   [Tool_dispatch.guarded_dispatch] which wraps [dispatch_structured]
   (pre-hook + handler + observer) with [Tool_telemetry.with_span].
   The keeper turn loop in [keeper_tool_registered_runtime.ml:164,218] routes through
   the guarded entry so the pre-hook chain ([external_effect_gate:203],
   [tool_input_validation:217]) covers keeper-originated calls.
   PR-8 wires the MCP server; PR-9 wires tag-dispatch fallback.
   PR-11 removes the legacy [dispatch] and [dispatch_structured] entries
   once all callers migrate. *)
let public_tool_schemas_from (public_tool_source_schemas : Masc_domain.tool_schema list) :
    Masc_domain.tool_schema list =
  dedupe_schemas public_tool_source_schemas
  |> Tool_help_registry.canonicalize_schemas

let visible_public_tool_schemas_from
    ?(include_hidden = false)
    (public_tool_source_schemas : Masc_domain.tool_schema list) : Masc_domain.tool_schema list =
  public_tool_schemas_from public_tool_source_schemas
  |> List.filter (fun (schema : Masc_domain.tool_schema) ->
         Tool_catalog.is_visible ~include_hidden schema.name)

let local_worker_tool_schemas ?names () :
    (Masc_domain.tool_schema list, string) result =
  Keeper_tool_surfaces.local_worker_tool_schemas ?names ()

let keeper_all_tool_names : string list =
  Tool_shard.keeper_model_tools
  |> List.map (fun tool -> tool.Masc_domain.name)
  |> Json_util.dedupe_keep_order

let keeper_wrapped_internal_tools : string list =
  keeper_all_tool_names

let surface_snapshot_json
    (public_tool_source_schemas : Masc_domain.tool_schema list) =
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
      ("keeper", surface_json Keeper);
      ("keeper_wrapped_server_tools",
        `List (List.map (fun name -> `String name) keeper_wrapped_server_tools));
    ]

let capability_to_json (capability : capability_def) =
  `Assoc
    [
      ("capability_id", `String capability.capability_id);
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
