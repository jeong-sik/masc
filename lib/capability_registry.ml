(** Capability_registry — canonical tool/capability SSOT.

    Public MCP tools and internal agent-facing tool surfaces are projections
    over one capability inventory. Some surfaces intentionally reuse the same
    tool name with a narrower schema (for example local worker projections).
*)

open Masc_domain

module StringSet = Set_util.StringSet
module CapabilityMap = Map.Make (struct
  type t = Tool_capability_id.t

  let compare = Tool_capability_id.compare
end)

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
  | Managed_agent_mcp
  | Spawned_agent_mcp
  | Local_worker
  | Keeper_standard
  | Keeper_privileged
  | Privileged_executor_surface

let surface_to_string = function
  | Public_mcp -> "public_mcp"
  | Managed_agent_mcp -> "managed_agent_mcp"
  | Spawned_agent_mcp -> "spawned_agent_mcp"
  | Local_worker -> "local_worker"
  | Keeper_standard -> "keeper_standard"
  | Keeper_privileged -> "keeper_privileged"
  | Privileged_executor_surface -> "privileged_executor"
;;

let surface_rank = function
  | Public_mcp -> 0
  | Managed_agent_mcp -> 1
  | Spawned_agent_mcp -> 2
  | Local_worker -> 3
  | Keeper_standard -> 4
  | Keeper_privileged -> 5
  | Privileged_executor_surface -> 6
;;

module SurfaceToolMap = Map.Make (struct
  type t = surface * string

  let compare (left_surface, left_name) (right_surface, right_name) =
    match Int.compare (surface_rank left_surface) (surface_rank right_surface) with
    | 0 -> String.compare left_name right_name
    | ordering -> ordering
end)

type projection = {
  surface : surface;
  tool_name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  backend_tool_name : string;
}

type capability_def = {
  capability_id : Tool_capability_id.t;
  risk_class : risk_class;
  audiences : audience list;
  supports_audit_evidence : bool;
  supports_direct_user_discovery : bool;
  projections : projection list;
}

type capability_seed = {
  capability_id : Tool_capability_id.t;
  risk_class : risk_class;
  audiences : audience list;
  supports_audit_evidence : bool;
  supports_direct_user_discovery : bool;
  projection : projection;
}

type projection_error =
  | Conflicting_surface_projection of
      { surface : surface
      ; tool_name : string
      ; capability_ids : Tool_capability_id.t list
      }
  | Multiple_keeper_model_names of
      { capability_id : Tool_capability_id.t
      ; tool_names : string list
      }

let projection_error_kind = function
  | Conflicting_surface_projection _ -> "conflicting_surface_projection"
  | Multiple_keeper_model_names _ -> "multiple_keeper_model_names"
;;

let projection_error_to_json = function
  | Conflicting_surface_projection { surface; tool_name; capability_ids } ->
    `Assoc
      [ "error_kind", `String "conflicting_surface_projection"
      ; "surface", `String (surface_to_string surface)
      ; "tool_name", `String tool_name
      ; ( "capability_ids"
        , `List
            (List.map
               (fun capability_id ->
                  `String
                    (Tool_capability_id.to_string capability_id))
               capability_ids) )
      ]
  | Multiple_keeper_model_names { capability_id; tool_names } ->
    `Assoc
      [ "error_kind", `String "multiple_keeper_model_names"
      ; ( "capability_id"
        , `String
            (Tool_capability_id.to_string capability_id) )
      ; "tool_names", `List (List.map (fun name -> `String name) tool_names)
      ]
;;

let risk_rank = function
  | Safe -> 0
  | Audited -> 1
  | Privileged -> 2

let max_risk left right =
  if risk_rank left >= risk_rank right then left else right


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
            | Managed_agent_mcp -> "managed_agent_mcp"
            | Spawned_agent_mcp -> "spawned_agent_mcp"
            | Local_worker -> "local_worker"
            | Keeper_standard -> "keeper_standard"
            | Keeper_privileged -> "keeper_privileged"
            | Privileged_executor_surface -> "privileged_executor")
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
  Tool_capability_id.route
    (match (Tool_catalog.metadata tool_name).Tool_catalog.canonical_name with
     | Some canonical_name -> canonical_name
     | None -> tool_name)


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

let projection_to_schema (projection : projection) : Masc_domain.tool_schema =
  {
    Masc_domain.name = projection.tool_name;
    description = projection.description;
    input_schema = projection.input_schema;
  }

let make_seed ?capability_id ?(risk_class = Safe)
    ?(audiences = [ External_mcp_client ]) ?(supports_audit_evidence = false)
    ?(supports_direct_user_discovery = true) ~surface ?backend_tool_name
    (schema : Masc_domain.tool_schema) : capability_seed =
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
  Tool_catalog_surfaces.spawned_agent_surface_tools

let spawned_agent_prefixed_tools : string list =
  prefixed_tool_names Tool_catalog_surfaces.spawned_agent_surface_tools

let local_worker_public_tool_names : string list =
  Tool_catalog_surfaces.local_worker_surface_tools

let local_worker_internal_schemas : Masc_domain.tool_schema list =
  Keeper_tool_surfaces.local_worker_internal_schemas

let local_worker_reserved_tool_names =
  (local_worker_internal_schemas @ Sdk_tool_contract.sdk_tool_schemas)
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
  |> Json_util.dedupe_keep_order

(* RFC-0182: masc_spawn removed (dead). privileged_public_tool_names is
   currently empty — no remaining public tool requires Privileged
   risk_class. Kept as extension point. *)
let privileged_public_tool_names : string list = []

let privileged_keeper_tool_names : string list =
  [ "tool_execute"; "tool_edit_file"; "tool_write_file" ]

let capability_id_for_backend backend_tool_name =
  match Tool_name.Board_name.of_string backend_tool_name with
  | Some board_name -> Tool_capability_id.board_operation board_name
  | None -> canonical_capability_id backend_tool_name
;;

let public_projection_seeds_from (public_tool_source_schemas : Masc_domain.tool_schema list) :
    capability_seed list =
  let source_schemas =
    Tool_help_registry.canonicalize_schemas public_tool_source_schemas
  in
  let make_surface_seeds schema =
    let name = schema.Masc_domain.name in
    let capability_id = capability_id_for_backend name in
    let is_spawned = List.mem name spawned_agent_public_tool_names in
    let is_local_worker =
      List.mem name local_worker_public_tool_names
      && not (List.mem name local_worker_reserved_tool_names)
    in
    let risk_class =
      if List.mem name privileged_public_tool_names then
        Privileged
      else if is_spawned then
        Audited
      else
        Safe
    in
    let audiences =
      Json_util.dedupe_keep_order
        ((if Tool_catalog.is_public_mcp name then [ External_mcp_client ] else [])
         @ (if is_spawned then [ Spawned_managed_agent ] else [])
         @ (if is_local_worker then [ Local_worker_agent ] else []))
    in
    let supports_audit_evidence = is_spawned in
    (if Tool_catalog.is_public_mcp name && Tool_catalog.is_visible name
     then
       [ make_seed ~capability_id ~risk_class ~audiences
           ~supports_audit_evidence ~supports_direct_user_discovery:true
           ~surface:Public_mcp schema ]
     else [])
    @ (if is_spawned
       then
         [ make_seed ~capability_id ~risk_class ~audiences
             ~supports_audit_evidence ~supports_direct_user_discovery:false
             ~surface:Spawned_agent_mcp schema ]
       else [])
    @ (if is_local_worker
       then
         [ make_seed ~capability_id ~risk_class ~audiences
             ~supports_audit_evidence ~supports_direct_user_discovery:false
             ~surface:Local_worker schema ]
       else [])
  in
  source_schemas |> List.concat_map make_surface_seeds

let managed_agent_projection_seeds_from public_tool_source_schemas =
  let sdk_names =
    Sdk_tool_contract.sdk_bindings
    |> List.map (fun binding -> binding.Sdk_tool_contract.sdk_name)
  in
  let sdk_seeds =
    Sdk_tool_contract.sdk_bindings
    |> List.map (fun binding ->
      let schema : Masc_domain.tool_schema =
        { name = binding.sdk_name
        ; description = binding.description
        ; input_schema = binding.input_schema
        }
      in
      make_seed
        ~capability_id:(capability_id_for_backend binding.canonical_operation)
        ~risk_class:Audited
        ~audiences:[ Spawned_managed_agent ]
        ~supports_audit_evidence:true
        ~supports_direct_user_discovery:false
        ~surface:Managed_agent_mcp
        ~backend_tool_name:binding.canonical_operation
        schema)
  in
  let passthrough_seeds =
    Tool_help_registry.canonicalize_schemas public_tool_source_schemas
    |> List.filter (fun (schema : Masc_domain.tool_schema) ->
      List.mem schema.name spawned_agent_public_tool_names
      && not (List.mem schema.name sdk_names)
      && Tool_catalog.is_visible ~include_hidden:true schema.name)
    |> List.map (fun schema ->
      make_seed
        ~capability_id:(capability_id_for_backend schema.Masc_domain.name)
        ~risk_class:Audited
        ~audiences:[ Spawned_managed_agent ]
        ~supports_audit_evidence:true
        ~supports_direct_user_discovery:false
        ~surface:Managed_agent_mcp
        schema)
  in
  sdk_seeds @ passthrough_seeds

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

let local_worker_contract_seeds : capability_seed list =
  let internal_names =
    List.map
      (fun (schema : Masc_domain.tool_schema) -> schema.name)
      local_worker_internal_schemas
  in
  Sdk_tool_contract.sdk_bindings
  |> List.filter (fun binding -> not (List.mem binding.sdk_name internal_names))
  |> List.map (fun binding ->
    let schema : Masc_domain.tool_schema =
      { name = binding.sdk_name
      ; description = binding.description
      ; input_schema = binding.input_schema
      }
    in
    make_seed
      ~capability_id:(capability_id_for_backend binding.canonical_operation)
      ~risk_class:Audited
      ~audiences:[ Local_worker_agent ]
      ~supports_audit_evidence:true
      ~supports_direct_user_discovery:false
      ~surface:Local_worker
      ~backend_tool_name:binding.canonical_operation
      schema)

let keeper_projection_seeds : capability_seed list =
  let descriptors = Keeper_tool_descriptor.all_descriptors () in
  let descriptor_owned_names =
    descriptors
    |> List.concat_map (fun descriptor ->
      Keeper_tool_descriptor.internal_names descriptor
      @ Keeper_tool_descriptor.keeper_model_names descriptor)
    |> Json_util.dedupe_keep_order
  in
  let descriptor_seeds =
    descriptors
    |> List.concat_map (fun descriptor ->
      Keeper_tool_descriptor.keeper_model_names descriptor
      |> List.concat_map (fun model_name ->
        let schema : Masc_domain.tool_schema =
          { name = model_name
          ; description = descriptor.description
          ; input_schema = descriptor.input_schema
          }
        in
        let backend_tool_name = descriptor.internal_name in
        let privileged = List.mem backend_tool_name privileged_keeper_tool_names in
        let primary_surface =
          if privileged then Keeper_privileged else Keeper_standard
        in
        let primary_seed =
          make_seed
            ~capability_id:descriptor.capability_id
            ~risk_class:(if privileged then Privileged else Audited)
            ~audiences:
              (if privileged
               then [ Keeper_agent; Privileged_executor ]
               else [ Keeper_agent ])
            ~supports_audit_evidence:true
            ~supports_direct_user_discovery:false
            ~surface:primary_surface
            ~backend_tool_name
            schema
        in
        if privileged
        then
          let executor_schema = { schema with name = backend_tool_name } in
          [ primary_seed
          ; make_seed
              ~capability_id:primary_seed.capability_id
              ~risk_class:Privileged
              ~audiences:[ Privileged_executor ]
              ~supports_audit_evidence:true
              ~supports_direct_user_discovery:false
              ~surface:Privileged_executor_surface
              ~backend_tool_name
              executor_schema
          ]
        else [ primary_seed ]))
  in
  let fallback_seeds =
    Tool_shard.keeper_model_tools
    |> List.filter (fun (tool : Masc_domain.tool_schema) ->
      not (List.mem tool.name descriptor_owned_names))
    |> List.map (fun schema ->
      make_seed
        ~risk_class:Audited
        ~audiences:[ Keeper_agent ]
        ~supports_audit_evidence:true
        ~supports_direct_user_discovery:false
        ~surface:Keeper_standard
        schema)
  in
  descriptor_seeds @ fallback_seeds

let unchecked_projection_seeds_from
    (public_tool_source_schemas : Masc_domain.tool_schema list) :
    capability_seed list =
  public_projection_seeds_from public_tool_source_schemas
  @ managed_agent_projection_seeds_from public_tool_source_schemas
  @ local_worker_internal_seeds
  @ local_worker_contract_seeds
  @ keeper_projection_seeds

let same_projection_contract left right =
  Tool_capability_id.equal
    left.capability_id
    right.capability_id
  && String.equal
       left.projection.backend_tool_name
       right.projection.backend_tool_name
  && String.equal left.projection.description right.projection.description
  && left.projection.input_schema = right.projection.input_schema
;;

let validate_projection_seeds seeds =
  let _, surface_errors =
    List.fold_left
      (fun (seen, errors) (seed : capability_seed) ->
        let key = seed.projection.surface, seed.projection.tool_name in
        match SurfaceToolMap.find_opt key seen with
        | None -> SurfaceToolMap.add key seed seen, errors
        | Some existing when same_projection_contract existing seed -> seen, errors
        | Some existing ->
          let capability_ids =
            [ existing.capability_id; seed.capability_id ]
            |> List.sort_uniq Tool_capability_id.compare
          in
          ( seen
          , Conflicting_surface_projection
              { surface = seed.projection.surface
              ; tool_name = seed.projection.tool_name
              ; capability_ids
              }
            :: errors ))
      (SurfaceToolMap.empty, [])
      seeds
  in
  let keeper_names =
    List.fold_left
      (fun by_capability (seed : capability_seed) ->
        match seed.projection.surface with
        | Keeper_standard | Keeper_privileged ->
          let current =
            match CapabilityMap.find_opt seed.capability_id by_capability with
            | Some names -> names
            | None -> []
          in
          CapabilityMap.add
            seed.capability_id
            (Json_util.dedupe_keep_order (current @ [ seed.projection.tool_name ]))
            by_capability
        | Public_mcp
        | Managed_agent_mcp
        | Spawned_agent_mcp
        | Local_worker
        | Privileged_executor_surface -> by_capability)
      CapabilityMap.empty
      seeds
  in
  let keeper_errors =
    CapabilityMap.fold
      (fun capability_id tool_names errors ->
        match tool_names with
        | [] | [ _ ] -> errors
        | _ -> Multiple_keeper_model_names { capability_id; tool_names } :: errors)
      keeper_names
      []
  in
  match List.rev_append surface_errors keeper_errors with
  | [] -> Ok ()
  | errors -> Error errors
;;

let record_projection_errors errors =
  List.iter
    (fun error ->
      let kind = projection_error_kind error in
      let details = projection_error_to_json error in
      Log.Config.emit
        Log.Error
        ~category:Log.Boundary
        ~details
        "capability projection rejected";
      Otel_metric_store.inc_counter
        "masc_capability_projection_error_total"
        ~labels:[ "kind", kind ]
        ())
    errors
;;

let all_projection_seeds_from_result public_tool_source_schemas =
  let seeds = unchecked_projection_seeds_from public_tool_source_schemas in
  match validate_projection_seeds seeds with
  | Ok () -> Ok seeds
  | Error _ as error -> error
;;

let all_projection_seeds_from public_tool_source_schemas =
  match all_projection_seeds_from_result public_tool_source_schemas with
  | Ok seeds -> seeds
  | Error errors ->
    record_projection_errors errors;
    invalid_arg
      (Yojson.Safe.to_string
         (`Assoc
            [ "error", `String "capability_projection_invalid"
            ; ( "details"
              , `List (List.map projection_error_to_json errors) )
            ]))
;;

let all_capabilities_from (public_tool_source_schemas : Masc_domain.tool_schema list) :
    capability_def list =
  let seeds = all_projection_seeds_from public_tool_source_schemas in
  let tbl, ordered_ids =
    List.fold_left
      (fun (tbl, ordered_ids) (seed : capability_seed) ->
        match CapabilityMap.find_opt seed.capability_id tbl with
        | None ->
            let def =
              {
                capability_id = seed.capability_id;
                risk_class = seed.risk_class;
                audiences = Json_util.dedupe_keep_order seed.audiences;
                supports_audit_evidence = seed.supports_audit_evidence;
                supports_direct_user_discovery = seed.supports_direct_user_discovery;
                projections = [ seed.projection ];
              }
            in
            ( CapabilityMap.add seed.capability_id def tbl,
              seed.capability_id :: ordered_ids )
        | Some existing ->
            let def =
              {
                capability_id = existing.capability_id;
                risk_class = max_risk existing.risk_class seed.risk_class;
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
            (CapabilityMap.add seed.capability_id def tbl, ordered_ids))
      (CapabilityMap.empty, []) seeds
  in
  List.rev ordered_ids |> List.filter_map (fun id -> CapabilityMap.find_opt id tbl)

let surface_tool_schemas_from (public_tool_source_schemas : Masc_domain.tool_schema list)
    surface : Masc_domain.tool_schema list =
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
   the guarded entry so pre-hook chain ([governance_pipeline:203],
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

let keeper_safe_tool_names : string list =
  Tool_shard.keeper_model_tools
  |> List.map (fun tool -> tool.Masc_domain.name)
  |> List.filter (fun name -> not (List.mem name privileged_keeper_tool_names))
  |> Json_util.dedupe_keep_order

let keeper_privileged_tool_names : string list =
  privileged_keeper_tool_names

let surface_snapshot_json
    (public_tool_source_schemas : Masc_domain.tool_schema list) =
  let seeds = all_projection_seeds_from public_tool_source_schemas in
  let surface_json surface =
    let names =
      seeds
      |> List.filter (fun (seed : capability_seed) ->
        seed.projection.surface = surface)
      |> List.map (fun seed -> seed.projection.tool_name)
      |> Json_util.dedupe_keep_order
    in
    `Assoc
      [ "count", `Int (List.length names)
      ; "tools", `List (List.map (fun name -> `String name) names)
      ]
  in
  `Assoc
    [ "public_mcp", surface_json Public_mcp
    ; "managed_agent_mcp", surface_json Managed_agent_mcp
    ; "spawned_agent_mcp", surface_json Spawned_agent_mcp
    ; "local_worker", surface_json Local_worker
    ; "keeper_standard", surface_json Keeper_standard
    ; "keeper_privileged", surface_json Keeper_privileged
    ; "privileged_executor", surface_json Privileged_executor_surface
    ]

let capability_to_json (capability : capability_def) =
  `Assoc
    [
      ( "capability_id"
      , `String
          (Tool_capability_id.to_string capability.capability_id) );
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
