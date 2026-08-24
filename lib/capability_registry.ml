(** Capability_registry — canonical tool/capability SSOT.

    Public MCP tools and internal agent-facing tool surfaces are projections
    over one capability inventory. Some surfaces intentionally reuse the same
    tool name with a narrower schema (for example spawned-agent projections).
*)

open Masc_domain

module StringSet = Set_util.StringSet
module StringMap = Set_util.StringMap

type audience =
  | External_mcp_client
  | Spawned_managed_agent
  | Keeper_agent

type surface =
  | Public_mcp
  | Spawned_agent_mcp
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

let require_unique_schemas ~label (schemas : Masc_domain.tool_schema list) =
  let duplicates, _ =
    List.fold_left
      (fun (duplicates, seen) (schema : Masc_domain.tool_schema) ->
        if StringSet.mem schema.name seen
        then schema.name :: duplicates, seen
        else duplicates, StringSet.add schema.name seen)
      ([], StringSet.empty) schemas
  in
  match duplicates with
  | [] -> schemas
  | names ->
    invalid_arg
      (Printf.sprintf "%s: duplicate tool schema(s): %s"
         label
         (names |> List.sort_uniq String.compare |> String.concat ", "))

let require_unique_projections ~label projections =
  let duplicates, _ =
    List.fold_left
      (fun (duplicates, seen) (projection : projection) ->
        let key =
          Printf.sprintf "%s|%s"
            (match projection.surface with
            | Public_mcp -> "public_mcp"
            | Spawned_agent_mcp -> "spawned_agent_mcp"
            | Keeper -> "keeper")
            projection.tool_name
        in
        if StringSet.mem key seen
        then key :: duplicates, seen
        else duplicates, StringSet.add key seen)
      ([], StringSet.empty) projections
  in
  match duplicates with
  | [] -> projections
  | keys ->
    invalid_arg
      (Printf.sprintf "%s: duplicate tool projection(s): %s"
         label
         (keys |> List.sort_uniq String.compare |> String.concat ", "))

let prefixed_tool_names names =
  names |> List.map Tool_transport_prefix.add

let surface_to_string = function
  | Public_mcp -> "public_mcp"
  | Spawned_agent_mcp -> "spawned_agent_mcp"
  | Keeper -> "keeper"

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
      Option.value ~default:backend_tool_name capability_id;
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
         :: (if List.mem name spawned_agent_public_tool_names then [ Spawned_managed_agent ] else []))
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
    with_spawned
  in
  public_schemas |> List.concat_map make_public_seed

let keeper_projection_seeds : capability_seed list =
  Keeper_tool_descriptor.model_visible_descriptors ()
  |> List.concat_map (fun (descriptor : Keeper_tool_descriptor.t) ->
         Keeper_tool_descriptor.keeper_model_names descriptor
         |> List.map (fun model_name ->
                let schema : Masc_domain.tool_schema =
                  { name = model_name
                  ; description = descriptor.description
                  ; input_schema = descriptor.input_schema
                  }
                in
                make_seed ~capability_id:descriptor.capability_id
                  ~audiences:[ Keeper_agent ]
                  ~supports_audit_evidence:true
                  ~supports_direct_user_discovery:false
                  ~surface:Keeper
                  ~backend_tool_name:descriptor.internal_name
                  schema))

let all_projection_seeds_from (public_tool_source_schemas : Masc_domain.tool_schema list) :
    capability_seed list =
  public_projection_seeds_from public_tool_source_schemas
  @ keeper_projection_seeds

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
                  require_unique_projections
                    ~label:("capability " ^ seed.capability_id)
                    (existing.projections @ [ seed.projection ]);
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
      |> require_unique_schemas ~label:"public MCP capability surface"
  | _ ->
      all_projection_seeds_from public_tool_source_schemas
      |> List.filter (fun (seed : capability_seed) -> seed.projection.surface = surface)
      |> List.map (fun (seed : capability_seed) -> projection_to_schema seed.projection)
      |> require_unique_schemas ~label:"capability surface"

let surface_tool_names_from (public_tool_source_schemas : Masc_domain.tool_schema list)
    surface : string list =
  surface_tool_schemas_from public_tool_source_schemas surface
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)

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
let canonical_tool_schemas_from (public_tool_source_schemas : Masc_domain.tool_schema list) :
    Masc_domain.tool_schema list =
  require_unique_schemas ~label:"public tool catalog" public_tool_source_schemas
  |> Tool_help_registry.canonicalize_schemas

let visible_tool_schemas_from
    ?(include_hidden = false)
    (public_tool_source_schemas : Masc_domain.tool_schema list) : Masc_domain.tool_schema list =
  canonical_tool_schemas_from public_tool_source_schemas
  |> List.filter (fun (schema : Masc_domain.tool_schema) ->
         Tool_catalog.is_visible ~include_hidden schema.name)

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
      ("keeper", surface_json Keeper);
    ]
