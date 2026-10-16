module Plan = Keeper_tool_plan
module Request = Keeper_tool_plan_request
module Catalog = Keeper_tool_composition_catalog
module Surface = Keeper_capability_surface
module Inventory = Keeper_skill_inventory

type call =
  { alias : Plan.Node_id.t
  ; reference : Skill_reference.t
  ; args : Yojson.Safe.t
  ; node_mapping : (Plan.Node_id.t * Plan.Node_id.t) list
  ; exports : Plan.export list
  }

type t = { plan : Plan.t; calls : call list }

type error =
  | Request_rejected of Request.error
  | Invalid_call_field of { index : int; field : string; detail : string }
  | Invalid_reference of { index : int; error : Skill_reference.decode_error }
  | Reference_unavailable of
      { alias : Plan.Node_id.t
      ; reference : Skill_reference.t
      ; availability : Surface.capability_availability option
      }
  | Instruction_reference of Plan.Node_id.t
  | Async_child_requires_suspension of Plan.Node_id.t
  | Child_policy_mismatch of Plan.Node_id.t
  | Arguments_rejected of Plan.Node_id.t * Tool_input_validation.rejection
  | Binding_rejected of Plan.Node_id.t * Catalog.instantiation_error
  | Duplicate_alias of Plan.Node_id.t
  | Unknown_alias of Plan.Node_id.t
  | Child_output_requires_export of Plan.Node_id.t
  | Unknown_child_export of { alias : Plan.Node_id.t; name : string }
  | Unsupported_leaf of { node_id : Plan.Node_id.t; tool_name : string }
  | Inputs_rejected of Plan.Node_id.t * Plan.execution_error
  | Expanded_plan_rejected of Plan.error

type nested_node =
  { alias : Plan.Node_id.t
  ; reference : Skill_reference.t
  ; args : Yojson.Safe.t
  ; after : Plan.Node_id.t list
  }

type source_node = Ordinary of Plan.node | Nested of nested_node

type expanded_node =
  | Leaf of Plan.node * Plan.Node_id.t
  | Child of nested_node * Plan.t * call

let ( let* ) = Result.bind
let plan compiled = compiled.plan
let calls compiled = compiled.calls
let id_json id = `String (Plan.Node_id.to_string id)

let input_schema =
  let string_schema = `Assoc [ "type", `String "string"; "minLength", `Int 1 ] in
  let object_ properties required = `Assoc
      [ "type", `String "object"; "properties", `Assoc properties
      ; "required", `List (List.map (fun field -> `String field) required)
      ; "additionalProperties", `Bool false ] in
  let reference = object_
      [ "identity", object_ [ "source_id", string_schema; "package_id", string_schema; "name", string_schema ]
          [ "source_id"; "package_id"; "name" ]
      ; "content_revision", string_schema ] [ "identity"; "content_revision" ] in
  let nested = object_
      [ "id", string_schema; "skill_reference", reference
      ; "args", `Assoc [ "type", `String "object" ]
      ; "after", `Assoc [ "type", `String "array"; "items", string_schema ] ]
      [ "id"; "skill_reference"; "args" ] in
  match Request.input_schema with
  | `Assoc fields ->
    let properties = match List.assoc "properties" fields with
      | `Assoc fields -> fields | _ -> invalid_arg "plan schema properties" in
    let nodes = match List.assoc "nodes" properties with
      | `Assoc fields -> fields | _ -> invalid_arg "plan schema nodes" in
    let ordinary = List.assoc "items" nodes in
    let nodes = `Assoc (("items", `Assoc [ "oneOf", `List [ ordinary; nested ] ]) :: List.remove_assoc "items" nodes) in
    `Assoc (("properties", `Assoc (("nodes", nodes) :: List.remove_assoc "nodes" properties))
      :: List.remove_assoc "properties" fields)
  | _ -> invalid_arg "plan schema object"
;;

let field_error ~index ~field detail = Error (Invalid_call_field { index; field; detail })

let parse_call ~index fields =
  let* () = List.fold_left (fun acc (field, _) ->
      let* seen = acc in
      if List.mem field seen then field_error ~index ~field "duplicate field"
      else if not (List.mem field [ "id"; "skill_reference"; "args"; "after" ]) then
        field_error ~index ~field "unexpected field"
      else Ok (field :: seen)) (Ok []) fields |> Result.map (fun _ -> ()) in
  let id ~field = function
    | `String value -> (match Plan.Node_id.make value with
        | Ok value -> Ok value | Error Plan.Node_id.Empty -> field_error ~index ~field "empty node ID")
    | _ -> field_error ~index ~field "expected string node ID" in
  let* alias = match List.assoc_opt "id" fields with
    | Some json -> id ~field:"id" json | None -> field_error ~index ~field:"id" "missing field" in
  let* reference = match List.assoc_opt "skill_reference" fields with
    | Some json -> Skill_reference.of_yojson json |> Result.map_error (fun error -> Invalid_reference { index; error })
    | None -> field_error ~index ~field:"skill_reference" "missing exact pinned reference" in
  let* args = match List.assoc_opt "args" fields with
    | Some (`Assoc _ as args) -> Ok args
    | Some _ | None -> field_error ~index ~field:"args" "expected fixed argument object" in
  let* after = match List.assoc_opt "after" fields with
    | None -> Ok []
    | Some (`List values) -> List.fold_left (fun acc json ->
        let* ids = acc in let* value = id ~field:"after" json in Ok (value :: ids)) (Ok []) values |> Result.map List.rev
    | Some _ -> field_error ~index ~field:"after" "expected node ID array" in
  Ok { alias; reference; args; after }
;;

let source_node ~index = function
  | `Assoc fields when List.mem_assoc "skill_reference" fields -> parse_call ~index fields |> Result.map (fun node -> Nested node)
  | json -> Request.node_of_json ~index json
      |> Result.map (fun node -> Ordinary node) |> Result.map_error (fun error -> Request_rejected error)
;;

let source_id = function Ordinary node -> node.Plan.id | Nested node -> node.alias

let namespace path =
  (* JSON arrays are injective over complete string paths, including quotes,
     delimiters, Unicode and ordinary IDs that resemble a child path. *)
  match Plan.Node_id.make (Yojson.Safe.to_string (`List (List.map id_json path))) with
  | Ok id -> id
  | Error Plan.Node_id.Empty -> invalid_arg "nonempty encoded composition path"
;;

let entry_for_call ~capability_surface (node : nested_node) =
  let row = Surface.skill_capabilities capability_surface |> List.find_opt (fun (row : Surface.skill_capability) ->
      match row.identity with
      | Surface.Exact_skill (Inventory.Valid valid) -> Skill_reference.equal valid.reference node.reference
      | Surface.Exact_skill (Inventory.Invalid invalid) -> Option.exists (Skill_reference.equal node.reference) invalid.reference
      | Surface.Missing_configured_skill_name _ -> false) in
  match row with
  | None ->
    Error (Reference_unavailable { alias = node.alias; reference = node.reference; availability = None })
  | Some row ->
    (match row.identity, row.exposure, row.availability with
     | Surface.Exact_skill (Inventory.Valid valid), Surface.Model_visible, Surface.Active ->
       (match valid.kind with
        | Inventory.Instruction -> Error (Instruction_reference node.alias)
        | Inventory.Composition entry -> Ok entry)
     | ( Surface.Exact_skill (Inventory.Valid _)
       | Surface.Exact_skill (Inventory.Invalid _)
       | Surface.Missing_configured_skill_name _ )
     , (Surface.Model_visible | Surface.Operator_only)
     , ( Surface.Active | Surface.Outside_skill_surface | Surface.Not_model_invocable
       | Surface.Denied_by_profile | Surface.Refused_by_sandbox _
       | Surface.Node_tools_outside_surface _ | Surface.Invalid_definition
       | Surface.Missing_configured_skill ) ->
       Error (Reference_unavailable
         { alias = node.alias; reference = node.reference; availability = Some row.availability }))
;;

let expand ~capability_surface ~policy = function
  | Ordinary node -> Ok (Leaf (node, namespace [ node.id ]))
  | Nested node ->
    let* entry = entry_for_call ~capability_surface node in
    let* () = match entry.execution with
      | Catalog.Inline -> Ok () | Catalog.Async -> Error (Async_child_requires_suspension node.alias) in
    let* () = if Plan.branch_failure_policy entry.plan = policy then Ok () else Error (Child_policy_mismatch node.alias) in
    let* args = Tool_input_validation.validate ~schema:(Catalog.input_schema_of_params entry.params)
        ~name:(Catalog.tool_name entry) ~args:node.args ()
        |> Result.map_error (fun error -> Arguments_rejected (node.alias, error)) in
    let* plan = Catalog.instantiate ~descriptors:(Surface.descriptors capability_surface) ~args entry
        |> Result.map_error (fun error -> Binding_rejected (node.alias, error)) in
    let node_mapping = List.map (fun (leaf : Plan.node) -> leaf.id, namespace [ node.alias; leaf.id ]) (Plan.nodes plan) in
    let exports = List.map (fun (export : Plan.export) ->
        Plan.export ~name:export.name ~node_id:(List.assoc export.node_id node_mapping)
          ~pointer:export.pointer) (Plan.exports plan) in
    let call = { alias = node.alias; reference = node.reference; args; node_mapping; exports } in
    Ok (Child (node, plan, call))
;;

let expanded_id = function Leaf (node, _) -> node.Plan.id | Child (node, _, _) -> node.alias
let members = function Leaf (_, id) -> [ id ] | Child (_, _, call) -> List.map snd call.node_mapping

let find_expanded nodes id =
  match List.find_opt (fun node -> Plan.Node_id.equal (expanded_id node) id) nodes with
  | Some node -> Ok node | None -> Error (Unknown_alias id)
;;

let resolve_outer_output nodes ~node_id ~pointer =
  let* producer = find_expanded nodes node_id in
  match producer with
  | Leaf (_, id) -> Ok (id, pointer)
  | Child (_, plan, call) ->
    (match Plan.Json_pointer.uncons pointer with
     | None -> Error (Child_output_requires_export node_id)
     | Some (name, suffix) ->
       (match List.find_opt (fun (export : Plan.export) -> String.equal export.name name) (Plan.exports plan) with
        | None -> Error (Unknown_child_export { alias = node_id; name })
        | Some export ->
          let id = List.assoc export.node_id call.node_mapping in
          Ok (id, Plan.Json_pointer.append export.pointer suffix)))
;;

let rec map_template ~output = function
  | Plan.Json_template.Literal value -> Ok (Plan.Json_template.literal value)
  | Plan.Json_template.Param { name } -> Ok (Plan.Json_template.param ~name)
  | Plan.Json_template.Output { node_id; pointer } ->
    let* node_id, pointer = output ~node_id ~pointer in
    Ok (Plan.Json_template.output ~node_id ~pointer)
  | Plan.Json_template.Object fields ->
    let* fields = List.fold_left (fun acc (name, template) ->
        let* fields = acc in let* template = map_template ~output template in Ok ((name, template) :: fields)) (Ok []) fields in
    (match Plan.Json_template.object_ (List.rev fields) with
     | Ok template -> Ok template
     | Error (Plan.Json_template.Duplicate_field _) -> invalid_arg "validated template duplicate field")
  | Plan.Json_template.Array items ->
    let* items = List.fold_left (fun acc template ->
        let* items = acc in let* template = map_template ~output template in Ok (template :: items)) (Ok []) items in
    Ok (Plan.Json_template.array (List.rev items))
;;

let outer_dependencies nodes ids =
  List.fold_left (fun acc id -> let* dependencies = acc in
      let* node = find_expanded nodes id in Ok (List.rev_append (members node) dependencies)) (Ok []) ids
  |> Result.map List.rev
;;

let flatten nodes =
  List.fold_left (fun acc expanded ->
      let* flattened = acc in
      match expanded with
      | Leaf (node, id) ->
        let* input = map_template ~output:(resolve_outer_output nodes) node.input in
        (* An output reference to a child is a dependency on the child's whole
           invocation, not merely its chosen successful producer. *)
        let* after = outer_dependencies nodes (Plan.dependencies node) in
        Ok (Plan.node ~id ~tool_name:node.tool_name ~input ~after () :: flattened)
      | Child (node, child, call) ->
        let* outer_after = outer_dependencies nodes node.after in
        let local id = List.assoc id call.node_mapping in
        let* children = List.fold_left (fun acc (leaf : Plan.node) ->
            let* children = acc in
            let* input = map_template ~output:(fun ~node_id ~pointer -> Ok (local node_id, pointer)) leaf.input in
            let after = outer_after @ List.map local leaf.after in
            Ok (Plan.node ~id:(local leaf.id) ~tool_name:leaf.tool_name ~input ~after () :: children)) (Ok []) (Plan.nodes child) in
        Ok (children @ flattened)) (Ok []) nodes
  |> Result.map List.rev
;;

let validate_leaves plan =
  let* () = List.fold_left (fun acc (node : Plan.node) ->
      let* () = acc in
      match Plan.descriptor plan node.id with
      | Some descriptor -> (match descriptor.Keeper_tool_descriptor.execution, Keeper_tool_descriptor.readonly_static_hint descriptor with
          | Keeper_tool_descriptor.Ordinary _, Some true -> Ok ()
          | Keeper_tool_descriptor.Terminal, _ | Keeper_tool_descriptor.Ordinary _, (None | Some false) ->
            Error (Unsupported_leaf { node_id = node.id; tool_name = node.tool_name }))
      | None -> Error (Unsupported_leaf { node_id = node.id; tool_name = node.tool_name })) (Ok ()) (Plan.nodes plan) in
  Plan.prepare_inputs plan |> Result.map (fun _ -> ()) |> Result.map_error (fun (id, error) -> Inputs_rejected (id, error))
;;

let compile ~capability_surface json =
  let* request = Request.shape_of_json json |> Result.map_error (fun error -> Request_rejected error) in
  let* source = List.fold_left (fun acc (index, json) ->
      let* nodes = acc in let* node = source_node ~index json in Ok (node :: nodes)) (Ok [])
      (List.mapi (fun index json -> index, json) request.node_jsons) |> Result.map List.rev in
  let* () = List.fold_left (fun acc node ->
      let* ids = acc in let id = source_id node in
      if List.exists (Plan.Node_id.equal id) ids then Error (Duplicate_alias id) else Ok (id :: ids)) (Ok []) source
      |> Result.map (fun _ -> ()) in
  let* plan, calls =
    if List.for_all (function Ordinary _ -> true | Nested _ -> false) source then
      let* plan = Request.plan_of_json ~descriptors:(Surface.descriptors capability_surface) json
          |> Result.map_error (fun error -> Request_rejected error) in
      Ok (plan, [])
    else
      let* expanded = List.fold_left (fun acc node -> let* nodes = acc in
          let* node = expand ~capability_surface ~policy:request.branch_failure_policy node in Ok (node :: nodes)) (Ok []) source
          |> Result.map List.rev in
      let* nodes = flatten expanded in
      let* exports = List.fold_left (fun acc (export : Plan.export) ->
          let* exports = acc in
          let* node_id, pointer = resolve_outer_output expanded ~node_id:export.node_id ~pointer:export.pointer in
          Ok (Plan.export ~name:export.name ~node_id ~pointer :: exports)) (Ok []) request.exports |> Result.map List.rev in
      let* plan = Plan.create ~descriptors:(Surface.descriptors capability_surface)
          ~branch_failure_policy:request.branch_failure_policy ~exports nodes
          |> Result.map_error (fun error -> Expanded_plan_rejected error) in
      let calls = List.filter_map (function Leaf _ -> None | Child (_, _, call) -> Some call) expanded in
      Ok (plan, calls) in
  let* () = validate_leaves plan in
  Ok { plan; calls }
;;

let call_to_json (call : call) = `Assoc
    [ "alias", id_json call.alias
    ; "reference", Skill_reference.to_yojson call.reference
    ; "args", call.args
    ; "node_mapping", `List (List.map (fun (source, expanded) -> `Assoc
        [ "source", id_json source; "expanded", id_json expanded ]) call.node_mapping)
    ; "exports", `List (List.map (fun (export : Plan.export) -> `Assoc
        [ "name", `String export.name; "node", id_json export.node_id
        ; "pointer", `String (Plan.Json_pointer.to_string export.pointer) ]) call.exports) ]
;;

let calls_to_json compiled = `List (List.map call_to_json compiled.calls)
;;

let error_to_json error =
  let tag kind fields = `Assoc (("kind", `String kind) :: fields) in
  let node kind id = tag kind [ "node_id", id_json id ] in
  match error with
  | Request_rejected error -> Request.error_to_json error
  | Invalid_call_field { index; field; detail } -> tag "invalid_child_field"
      [ "index", `Int index; "field", `String field; "detail", `String detail ]
  | Invalid_reference { index; error = _ } -> tag "invalid_child_reference" [ "index", `Int index
      ; "detail", `String "Use the complete pinned identity and content_revision from the frozen Skill inventory." ]
  | Reference_unavailable { alias; reference; availability } -> tag "child_reference_unavailable"
      [ "node_id", id_json alias; "reference", Skill_reference.to_yojson reference
      ; "availability", (match availability with None -> `Null | Some value -> `String (Surface.capability_availability_to_string value)) ]
  | Instruction_reference id -> node "child_is_instruction" id
  | Async_child_requires_suspension id -> node "async_child_requires_suspension" id
  | Child_policy_mismatch id -> node "child_policy_mismatch" id
  | Arguments_rejected (id, rejection) -> tag "child_arguments_rejected" [ "node_id", id_json id; "detail", `String rejection.message ]
  | Binding_rejected (id, error) -> tag "child_binding_rejected" [ "node_id", id_json id; "error", Catalog.instantiation_error_to_json error ]
  | Duplicate_alias id -> node "duplicate_alias" id
  | Unknown_alias id -> node "unknown_alias" id
  | Child_output_requires_export id -> node "child_output_requires_export" id
  | Unknown_child_export { alias; name } -> tag "unknown_child_export" [ "node_id", id_json alias; "name", `String name ]
  | Unsupported_leaf { node_id; tool_name } -> tag "unsupported_leaf" [ "node_id", id_json node_id; "tool_name", `String tool_name ]
  | Inputs_rejected (id, error) -> tag "inputs_rejected" [ "node_id", id_json id
      ; "error", Keeper_tool_plan_error_projection.plan_execution_error_to_json error ]
  | Expanded_plan_rejected error -> tag "expanded_plan_rejected" [ "error", Plan.error_to_json error ]
;;
