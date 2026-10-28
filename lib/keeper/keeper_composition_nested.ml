module Plan = Keeper_tool_plan
module Request = Keeper_tool_plan_request
module Catalog = Keeper_tool_composition_catalog
module Surface = Keeper_capability_surface
module Inventory = Keeper_skill_inventory

type arguments = Fixed of Yojson.Safe.t | Upstream of Plan.Json_template.t

type scope =
  | Inline of { argument_node : Plan.Node_id.t option; mapping : (Plan.Node_id.t * Plan.Node_id.t) list }
  | Async of { submission : Plan.Node_id.t; result : Plan.Node_id.t }

type call =
  { alias : Plan.Node_id.t
  ; reference : Skill_reference.t
  ; arguments : arguments
  ; scope : scope
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
  | Child_output_requires_export of { alias : Plan.Node_id.t; available_exports : string list }
  | Unknown_child_export of { alias : Plan.Node_id.t; name : string; available_exports : string list }
  | Unsupported_leaf of { node_id : Plan.Node_id.t; tool_name : string }
  | Inputs_rejected of Plan.Node_id.t * Plan.execution_error
  | Expanded_plan_rejected of Plan.error

type nested_node =
  { alias : Plan.Node_id.t
  ; reference : Skill_reference.t
  ; arguments : arguments
  ; after : Plan.Node_id.t list
  }

type source_node = Ordinary of Plan.node | Nested of nested_node

type expanded_node =
  | Leaf of Plan.node * Plan.Node_id.t
  | Inline_child of nested_node * Plan.t * call * Plan.inline_arguments option
  | Async_child of nested_node * Plan.async_child * call

open Result.Syntax
let plan compiled = compiled.plan
let calls compiled = compiled.calls
let id_json id = `String (Plan.Node_id.to_string id)

(* A node chooses one closed shape, but each field's definition is shared.
   Moving property checks to the enclosing object is equivalent only when
   every occurrence of a field has the same schema. Required fields stay in
   their own alternative; fields absent from that alternative are explicitly
   forbidden, so sharing definitions never admits mixed Tool/Skill nodes or
   both args and input. This is schema representation, not plan admission. *)
let shared_node_schema alternatives =
  let rows = List.map (function
    | `Assoc fields ->
      (match List.assoc_opt "type" fields, List.assoc_opt "properties" fields,
             List.assoc_opt "required" fields, List.assoc_opt "additionalProperties" fields with
       | Some (`String "object"), Some (`Assoc properties), Some (`List required), Some (`Bool false)
         when List.length fields = 4 -> properties, required
       | _ -> invalid_arg "composition node alternatives must be closed objects")
    | _ -> invalid_arg "composition node alternative must be an object") alternatives in
  let properties = List.fold_left (fun merged (fields, _) ->
    List.fold_left (fun merged (name, schema) ->
      match List.assoc_opt name merged with
      | None -> merged @ [name, schema]
      | Some existing when Yojson.Safe.equal existing schema -> merged
      | Some _ -> invalid_arg "composition node alternatives disagree on a field schema")
      merged fields) [] rows in
  let alternatives = List.map (fun (fields, required) ->
    let forbidden = List.filter_map (fun (name, _) ->
      if List.mem_assoc name fields then None
      else Some (`Assoc ["required", `List [`String name]])) properties in
    let exclusions = match forbidden with
      | [] -> []
      | [one] -> ["not", one]
      | _ :: _ :: _ -> ["not", `Assoc ["anyOf", `List forbidden]] in
    `Assoc (("required", `List required) :: exclusions)) rows in
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "additionalProperties", `Bool false
    ; "oneOf", `List alternatives ]

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
  let nested field schema = object_
      [ "id", string_schema; "skill_reference", reference; field, schema
      ; "after", `Assoc [ "type", `String "array"; "items", string_schema ] ]
      [ "id"; "skill_reference"; field ] in
  match Request.input_schema with
  | `Assoc fields ->
    let properties = match List.assoc "properties" fields with
      | `Assoc fields -> fields | _ -> invalid_arg "plan schema properties" in
    let nodes = match List.assoc "nodes" properties with
      | `Assoc fields -> fields | _ -> invalid_arg "plan schema nodes" in
    let ordinary = List.assoc "items" nodes in
    let ordinary = match ordinary with
      | `Assoc ["oneOf",`List alternatives] -> alternatives
      | _ -> invalid_arg "ordinary plan node alternatives" in
    let alternatives = ordinary @ [nested "args" (`Assoc ["type",`String "object"]);
        nested "input" (`Assoc ["$ref",`String "#/$defs/template"])] in
    let nodes = `Assoc (("items", shared_node_schema alternatives)
        :: List.remove_assoc "items" nodes) in
    `Assoc (("properties", `Assoc (("nodes", nodes) :: List.remove_assoc "nodes" properties))
      :: List.remove_assoc "properties" fields)
  | _ -> invalid_arg "plan schema object"
;;

let field_error ~index ~field detail = Error (Invalid_call_field { index; field; detail })

let parse_call ~index fields =
  let* () = List.fold_left (fun acc (field, _) ->
      let* seen = acc in
      if List.mem field seen then field_error ~index ~field "duplicate field"
      else if not (List.mem field [ "id"; "skill_reference"; "args"; "input"; "after" ]) then
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
  let* arguments = match List.assoc_opt "args" fields,List.assoc_opt "input" fields with
    | Some (`Assoc _ as args),None -> Ok (Fixed args)
    | None,Some input -> Request.template_of_json input
      |> Result.map (fun input -> Upstream input)
      |> Result.map_error (fun error -> Request_rejected (Request.Node_template_error {index;error}))
    | Some _,None -> field_error ~index ~field:"args" "expected fixed argument object"
    | Some _,Some _ | None,None -> field_error ~index ~field:"input" "provide exactly one of args or input" in
  let* after = match List.assoc_opt "after" fields with
    | None -> Ok []
    | Some (`List values) -> List.fold_left (fun acc json ->
        let* ids = acc in let* value = id ~field:"after" json in Ok (value :: ids)) (Ok []) values |> Result.map List.rev
    | Some _ -> field_error ~index ~field:"after" "expected node ID array" in
  Ok { alias; reference; arguments; after }
;;

let source_node ~index = function
  | `Assoc fields when List.mem_assoc "skill_reference" fields -> parse_call ~index fields |> Result.map (fun node -> Nested node)
  | json -> Request.node_of_json ~index json
      |> Result.map (fun node -> Ordinary node) |> Result.map_error (fun error -> Request_rejected error)
;;

let source_id = function Ordinary node -> node.Plan.id | Nested node -> node.alias

let namespace_segments path =
  (* JSON arrays are injective over complete string paths, including quotes,
     delimiters, Unicode and ordinary IDs that resemble a child path. *)
  match Plan.Node_id.make (Yojson.Safe.to_string (`List (List.map (fun value -> `String value) path))) with
  | Ok id -> id
  | Error Plan.Node_id.Empty -> invalid_arg "nonempty encoded composition path"
;;

let namespace path = namespace_segments (List.map Plan.Node_id.to_string path)

let entry_for_call ~capability_surface (node : nested_node) =
  let row = Surface.skill_capabilities capability_surface |> List.find_opt (fun (row : Surface.skill_capability) ->
      match row.identity with
      | Surface.Exact_skill (Inventory.Valid valid) -> Skill_reference.equal valid.reference node.reference
      | Surface.Exact_skill (Inventory.Invalid invalid) -> Option.exists (Skill_reference.equal node.reference) invalid.reference
      | Surface.Missing_configured_skill_name _ -> false) in
  match row with
  | Some row ->
    let unavailable () =
      Error (Reference_unavailable
        { alias = node.alias; reference = node.reference; availability = Some row.availability })
    in
    (match row.availability with
     | Surface.Active ->
       (match row.exposure with
        | Surface.Model_visible ->
          (match row.identity with
           | Surface.Exact_skill (Inventory.Valid valid) ->
             (match valid.kind with
              | Inventory.Instruction -> Error (Instruction_reference node.alias)
              | Inventory.Composition entry -> Ok entry)
           | Surface.Exact_skill (Inventory.Invalid _)
           | Surface.Missing_configured_skill_name _ -> unavailable ())
        | Surface.Operator_only -> unavailable ())
     | Surface.Outside_skill_surface | Surface.Not_model_invocable | Surface.Denied_by_profile
     | Surface.Refused_by_sandbox _ | Surface.Node_tools_outside_surface _
     | Surface.Invalid_definition | Surface.Missing_configured_skill -> unavailable ())
  | None -> Error (Reference_unavailable { alias = node.alias; reference = node.reference; availability = None })
;;

let expand ~execution ~capability_surface ~policy = function
  | Ordinary node -> Ok (Leaf (node, namespace [ node.id ]))
  | Nested node ->
    let* entry = entry_for_call ~capability_surface node in
    let* () = match entry.execution,execution with
      | Catalog.Inline,(Catalog.Inline | Catalog.Async) | Catalog.Async,Catalog.Async -> Ok ()
      | Catalog.Async,Catalog.Inline -> Error (Async_child_requires_suspension node.alias) in
    let* () = if Plan.branch_failure_policy entry.plan = policy then Ok () else Error (Child_policy_mismatch node.alias) in
    let input_schema = Catalog.input_schema_of_params entry.params in
    let* arguments,plan = match node.arguments,entry.execution with
      | Upstream input,(Catalog.Inline | Catalog.Async) -> Ok (Upstream input,entry.plan)
      | Fixed args,(Catalog.Inline | Catalog.Async) ->
        let* args = Tool_input_validation.validate ~schema:input_schema
            ~name:(Catalog.tool_name entry) ~args ()
          |> Result.map_error (fun error -> Arguments_rejected (node.alias,error)) in
        let* plan = Catalog.instantiate ~descriptors:(Surface.descriptors capability_surface) ~args entry
          |> Result.map_error (fun error -> Binding_rejected (node.alias,error)) in
        Ok (Fixed args,plan) in
    match entry.execution with
    | Catalog.Inline ->
      let mapping = List.map (fun (leaf : Plan.node) -> leaf.id, namespace [ node.alias; leaf.id ]) (Plan.nodes plan) in
      let exports = List.map (fun (export : Plan.export) ->
          Plan.export ~name:export.name ~node_id:(List.assoc export.node_id mapping)
            ~pointer:export.pointer) (Plan.exports plan) in
      let argument = match arguments with
        | Fixed _ -> None
        | Upstream input ->
          let id = namespace_segments [Plan.Node_id.to_string node.alias;"arguments";"validated"] in
          Some (Plan.inline_arguments ~alias:node.alias ~reference:node.reference ~id
            ~tool_name:(Catalog.tool_name entry) ~input ~input_schema
            ~output_schema:(Catalog.output_schema_of_params entry.params) ()) in
      let argument_node = Option.map (fun (argument : Plan.inline_arguments) -> argument.node.id) argument in
      let call = {alias=node.alias;reference=node.reference;arguments;scope=Inline {argument_node;mapping};exports} in
      Ok (Inline_child (node,plan,call,argument))
    | Catalog.Async ->
      let alias = Plan.Node_id.to_string node.alias in
      let submission = namespace_segments [alias;"submission"]
      and result = namespace_segments [alias;"result"] in
      let input = match arguments with Fixed args -> Plan.Json_template.literal args | Upstream input -> input in
      let child = Plan.dynamic_async_child ~alias:node.alias ~reference:node.reference
          ~tool_name:(Catalog.tool_name entry) ~input ~input_schema ~declared_plan:plan in
      let exports = List.map (fun (export : Plan.export) ->
        Plan.export ~name:export.name ~node_id:result ~pointer:(Plan.Json_pointer.of_segments [export.name])) (Plan.exports plan) in
      let call = {alias=node.alias;reference=node.reference;arguments;scope=Async {submission;result};exports} in
      Ok (Async_child (node,child,call))
;;

let expanded_id = function
  | Leaf (node,_) -> node.Plan.id
  | Inline_child (node,_,_,_) | Async_child (node,_,_) -> node.alias
let members = function
  | Leaf (_,id) -> [id]
  | Inline_child (_,plan,call,argument) ->
    Option.to_list (Option.map (fun (argument : Plan.inline_arguments) -> argument.node.id) argument)
    @ List.map (fun (leaf : Plan.node) -> namespace [call.alias;leaf.id]) (Plan.nodes plan)
  | Async_child (_,_,call) -> (match call.scope with Async {result;_} -> [result] | Inline _ -> invalid_arg "async child scope")

let find_expanded nodes id =
  match List.find_opt (fun node -> Plan.Node_id.equal (expanded_id node) id) nodes with
  | Some node -> Ok node | None -> Error (Unknown_alias id)
;;

let resolve_outer_output nodes ~node_id ~pointer =
  let* producer = find_expanded nodes node_id in
  match producer with
  | Leaf (_, id) -> Ok (id, pointer)
  | Inline_child (_,_,call,_) | Async_child (_,_,call) ->
    let available_exports = List.map (fun (export : Plan.export) -> export.name) call.exports in
    (match Plan.Json_pointer.uncons pointer with
     | None -> Error (Child_output_requires_export { alias = node_id; available_exports })
     | Some (name, suffix) ->
       (match List.find_opt (fun (export : Plan.export) -> String.equal export.name name) call.exports with
        | None -> Error (Unknown_child_export { alias = node_id; name; available_exports })
        | Some export ->
          Ok (export.node_id, Plan.Json_pointer.append export.pointer suffix)))
;;

let rec map_template ?(param=(fun ~name -> Ok (Plan.Json_template.param ~name))) ~output = function
  | Plan.Json_template.Literal value -> Ok (Plan.Json_template.literal value)
  | Plan.Json_template.Param { name } -> param ~name
  | Plan.Json_template.Output { node_id; pointer } ->
    let* node_id, pointer = output ~node_id ~pointer in
    Ok (Plan.Json_template.output ~node_id ~pointer)
  | Plan.Json_template.Object fields ->
    let* fields = List.fold_left (fun acc (name, template) ->
        let* fields = acc in let* template = map_template ~param ~output template in Ok ((name, template) :: fields)) (Ok []) fields in
    (match Plan.Json_template.object_ (List.rev fields) with
     | Ok template -> Ok template
     | Error (Plan.Json_template.Duplicate_field _) -> invalid_arg "validated template duplicate field")
  | Plan.Json_template.Array items ->
    let* items = List.fold_left (fun acc template ->
        let* items = acc in let* template = map_template ~param ~output template in Ok (template :: items)) (Ok []) items in
    Ok (Plan.Json_template.array (List.rev items))
;;

let outer_dependencies nodes ids =
  List.fold_left (fun acc id -> let* dependencies = acc in
      let* node = find_expanded nodes id in Ok (List.rev_append (members node) dependencies)) (Ok []) ids
  |> Result.map List.rev
;;

let flatten nodes =
  List.fold_left (fun acc expanded ->
      let* flattened,compiled,arguments = acc in
      match expanded with
      | Leaf (node, id) ->
        let* input = map_template ~output:(resolve_outer_output nodes) node.input in
        (* An output reference to a child is a dependency on the child's whole
           invocation, not merely its chosen successful producer. *)
        let* after = outer_dependencies nodes (Plan.dependencies node) in
        Ok (Plan.node ~id ~tool_name:node.tool_name ~input ~after () :: flattened,compiled,arguments)
      | Inline_child (node, child, call, argument) ->
        let input_dependencies = match argument with None -> []
          | Some argument -> Plan.Json_template.dependencies argument.node.input in
        let* outer_after = outer_dependencies nodes (node.after @ input_dependencies) in
        let* argument = match argument with
          | None -> Ok None
          | Some (argument : Plan.inline_arguments) ->
            let* input = map_template ~output:(resolve_outer_output nodes) argument.node.input in
            Ok (Some (Plan.inline_arguments ~alias:argument.alias ~reference:argument.reference
              ~id:argument.node.id ~tool_name:argument.node.tool_name ~input
              ~input_schema:argument.input_schema ~output_schema:argument.output_schema ~after:outer_after ())) in
        let local id = namespace [call.alias;id] in
        let param ~name = Ok (match argument with
          | None -> Plan.Json_template.param ~name
          | Some argument -> Plan.Json_template.output ~node_id:argument.node.id
              ~pointer:(Plan.Json_pointer.of_segments [name])) in
        let argument_ids = Option.to_list (Option.map (fun (argument : Plan.inline_arguments) -> argument.node.id) argument) in
        let* children = List.fold_left (fun acc (leaf : Plan.node) ->
            let* children = acc in
            let* input = map_template ~param ~output:(fun ~node_id ~pointer -> Ok (local node_id, pointer)) leaf.input in
            let after = argument_ids @ outer_after @ List.map local leaf.after in
            Ok (Plan.node ~id:(local leaf.id) ~tool_name:leaf.tool_name ~input ~after () :: children)) (Ok []) (Plan.nodes child) in
        let flattened = children @ flattened in
        (match argument with
         | None -> Ok (flattened,compiled,arguments)
         | Some argument -> Ok (argument.node::flattened,compiled,argument::arguments))
      | Async_child (node,child,call) ->
        let original_input = Plan.child_input child in
        let* after = outer_dependencies nodes (node.after @ Plan.Json_template.dependencies original_input) in
        let* input = map_template ~output:(resolve_outer_output nodes) original_input in
        let child = Plan.dynamic_async_child ~alias:(Plan.child_alias child)
            ~reference:(Plan.child_reference child) ~tool_name:(Plan.child_tool_name child)
            ~input ~input_schema:(Plan.child_input_schema child) ~declared_plan:(Plan.child_plan child) in
        let submission_id,result_id = match call.scope with
          | Async {submission;result} -> submission,result
          | Inline _ -> invalid_arg "async child scope" in
        let child = Plan.child_nodes ~child ~submission_id ~result_id ~after () in
        Ok (child.result::child.submission::flattened,child::compiled,arguments)) (Ok ([],[],[])) nodes
  |> Result.map (fun (nodes,children,arguments) -> List.rev nodes,List.rev children,List.rev arguments)
;;

let rec validate_leaves ~execution ?(parameterized=false) plan =
  let* () = List.fold_left (fun acc (node : Plan.node) ->
      let* () = acc in
      match Plan.contract plan node.id with
      | Some {target=Plan.Descriptor_target descriptor;_} -> (match Keeper_tool_descriptor.prepared_leaf_admission descriptor with
          | Read_only_ordinary_leaf | Owned_job_launch_leaf | Owned_ask_leaf -> Ok ()
          | Owned_file_mutation_leaf ->
            (match execution with
             | Catalog.Inline -> Ok ()
             | Catalog.Async -> Error (Unsupported_leaf { node_id = node.id; tool_name = node.tool_name }))
          | Direct_only ->
            Error (Unsupported_leaf { node_id = node.id; tool_name = node.tool_name }))
      | Some {target=Plan.Child_submission child;_} ->
          validate_leaves ~execution:Catalog.Async ~parameterized:true (Plan.child_plan child.child)
      | Some {target=(Plan.Child_arguments _ | Plan.Child_result _);_} -> Ok ()
      | None -> Error (Unsupported_leaf { node_id = node.id; tool_name = node.tool_name })) (Ok ()) (Plan.nodes plan) in
  (if parameterized then Plan.validate_parameterized_inputs plan
   else Plan.prepare_inputs plan |> Result.map (fun _ -> ()))
  |> Result.map_error (fun (id, error) -> Inputs_rejected (id, error))
;;

let compile_with ~descriptors ~execution ~capability_surface json =
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
      let* plan = Request.plan_of_json ~descriptors json
          |> Result.map_error (fun error -> Request_rejected error) in
      Ok (plan, [])
    else
      let* expanded = List.fold_left (fun acc node -> let* nodes = acc in
          let* node = expand ~execution ~capability_surface ~policy:request.branch_failure_policy node in Ok (node :: nodes)) (Ok []) source
          |> Result.map List.rev in
      let* nodes,children,arguments = flatten expanded in
      let* exports = List.fold_left (fun acc (export : Plan.export) ->
          let* exports = acc in
          let* node_id, pointer = resolve_outer_output expanded ~node_id:export.node_id ~pointer:export.pointer in
          Ok (Plan.export ~name:export.name ~node_id ~pointer :: exports)) (Ok []) request.exports |> Result.map List.rev in
      let* plan = Plan.create_compiled ~children ~arguments ~descriptors
          ~branch_failure_policy:request.branch_failure_policy ~exports nodes
          |> Result.map_error (fun error -> Expanded_plan_rejected error) in
      let calls = List.filter_map (function Leaf _ -> None | Inline_child (_,_,call,_) | Async_child (_,_,call) -> Some call) expanded in
      Ok (plan, calls) in
  let* () = validate_leaves ~execution plan in
  Ok { plan; calls }
;;

let compile ~execution ~capability_surface json =
  compile_with ~descriptors:(Surface.descriptors capability_surface) ~execution ~capability_surface json
;;

let compile_for_refusal ~execution ~capability_surface json =
  let descriptors = Surface.tool_capabilities capability_surface |> List.filter_map
      (fun (row : Surface.tool_capability) -> match row.availability with
        | Active | Denied_by_profile -> Some row.descriptor
        | Outside_skill_surface | Not_model_invocable | Refused_by_sandbox _
        | Node_tools_outside_surface _ | Invalid_definition | Missing_configured_skill -> None) in
  compile_with ~descriptors ~execution ~capability_surface json
;;

let call_to_json (call : call) = `Assoc
    [ "alias", id_json call.alias
    ; "reference", Skill_reference.to_yojson call.reference
    ; "arguments", (match call.arguments with
        | Fixed value -> `Assoc ["kind",`String "fixed";"value",value]
        | Upstream input ->
          let input = match Request.template_to_yojson input with Ok input -> input
            | Error (Request.Unsubstituted_param _) -> invalid_arg "public child input contains an unbound parameter" in
          `Assoc ["kind",`String "upstream";"input",input])
    ; "scope", (match call.scope with
        | Inline {argument_node;mapping} -> `Assoc (["kind",`String "inline";"node_mapping",`List (List.map (fun (source,expanded) ->
            `Assoc ["source",id_json source;"expanded",id_json expanded]) mapping)]
            @ match argument_node with None -> [] | Some id -> ["argument_node",id_json id])
        | Async {submission;result} -> `Assoc ["kind",`String "async";"submission",id_json submission;"result",id_json result])
    ; "exports", `List (List.map (fun (export : Plan.export) -> `Assoc
        [ "name", `String export.name; "node", id_json export.node_id
        ; "pointer", `String (Plan.Json_pointer.to_string export.pointer) ]) call.exports) ]
;;

let calls_to_json compiled = `List (List.map call_to_json compiled.calls)
;;

let error_to_json error =
  let tag kind fields = `Assoc (("kind", `String kind) :: fields) in
  let node kind id = tag kind [ "node_id", id_json id ] in
  let exports names =
    [ "available_exports", `List (List.map (fun name -> `Assoc
        [ "name", `String name
        ; "pointer", `String (Plan.Json_pointer.to_string (Plan.Json_pointer.of_segments [name])) ]) names)
    ; "detail", `String "A child exposes only its declared named exports. Use an available_exports pointer with this child node_id; the root and internal tool fields are not child outputs." ] in
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
  | Child_output_requires_export { alias; available_exports } ->
    tag "child_output_requires_export" ([ "node_id", id_json alias ] @ exports available_exports)
  | Unknown_child_export { alias; name; available_exports } ->
    tag "unknown_child_export" ([ "node_id", id_json alias; "name", `String name ] @ exports available_exports)
  | Unsupported_leaf { node_id; tool_name } -> tag "unsupported_leaf" [ "node_id", id_json node_id; "tool_name", `String tool_name ]
  | Inputs_rejected (id, error) -> tag "inputs_rejected" [ "node_id", id_json id
      ; "error", Keeper_tool_plan_error_projection.plan_execution_error_to_json error ]
  | Expanded_plan_rejected error -> tag "expanded_plan_rejected" [ "error", Plan.error_to_json error ]
;;
