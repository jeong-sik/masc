type profile =
  { reference : Skill_reference.t
  ; kind : string
  ; activation_tool : string
  ; execution : string
  ; body_bytes : int
  ; eager_body_bytes : int
  ; discovery_bytes : int
  ; tool_schema_bytes : int option
  ; node_count : int
  ; batch_count : int
  ; parallel_batch_count : int
  ; max_parallelism : int
  ; statically_read_only : bool option
  ; declaration_span : Keeper_skill_body_ast.span option
  }

let tool_component_bytes (tool : Agent_core.Tool.t) =
  let schema = tool.schema in
  let input_schema =
    match schema.input_schema with
    | Some value -> value
    | None -> Agent_core.Types.params_to_input_schema schema.parameters
  in
  String.length schema.name
  + String.length schema.description
  + String.length (Yojson.Safe.to_string input_schema)
;;

let composition_tool_component_bytes entry =
  Keeper_tool_composition_surface.schema_tool_rows
    ~skill_compositions:[ entry, () ]
    ()
  |> List.find_map (function
    | Keeper_tool_composition_surface.Declared_composition (), tool ->
      Some (tool_component_bytes tool)
    | ( Keeper_tool_composition_surface.Plan_execute
      | Keeper_tool_composition_surface.Async_status
      | Keeper_tool_composition_surface.Async_cancel ), _ ->
      None)
;;

let schedule_profile plan =
  let batches = Keeper_tool_plan_executor.schedule plan in
  let parallel_width = function
    | Keeper_tool_plan_executor.Serial_batch _ -> 1
    | Keeper_tool_plan_executor.Concurrent_batch nodes -> List.length nodes
  in
  let widths = List.map parallel_width batches in
  let max_parallelism = List.fold_left max 0 widths in
  let parallel_batch_count =
    List.fold_left
      (fun count width -> if width > 1 then count + 1 else count)
      0
      widths
  in
  List.length batches, parallel_batch_count, max_parallelism
;;

let statically_read_only plan =
  Keeper_tool_plan.nodes plan
  |> List.for_all (fun (node : Keeper_tool_plan.node) ->
    match Keeper_tool_plan.descriptor plan node.id with
    | Some descriptor ->
      Keeper_tool_descriptor.readonly_static_hint descriptor = Some true
    | None -> false)
;;

let instruction_discovery_bytes reference description =
  String.length (Skill_reference.to_yojson reference |> Yojson.Safe.to_string)
  + 2
  + String.length description
;;

let of_skill_with_reference reference (skill : Keeper_skill_catalog.skill) =
  let body_bytes = String.length skill.body in
  match skill.surface with
     | Keeper_skill_catalog.Instruction ->
       { reference
         ; kind = "instruction"
         ; activation_tool = Keeper_tool_composition_catalog.skill_tool_name
         ; execution = "on_demand"
         ; body_bytes
         ; eager_body_bytes = 0
         ; discovery_bytes = instruction_discovery_bytes reference skill.description
         ; tool_schema_bytes = None
         ; node_count = 0
         ; batch_count = 0
         ; parallel_batch_count = 0
         ; max_parallelism = 0
         ; statically_read_only = None
         ; declaration_span = None
         }
     | Keeper_skill_catalog.Composition entry ->
       let batch_count, parallel_batch_count, max_parallelism =
         schedule_profile entry.plan
       in
       let tool_schema_bytes = composition_tool_component_bytes entry in
       { reference
         ; kind = "composition"
         ; activation_tool = Keeper_tool_composition_catalog.tool_name entry
         ; execution =
             Keeper_tool_composition_catalog.execution_mode_to_string entry.execution
         ; body_bytes
         ; eager_body_bytes = 0
         ; discovery_bytes = Option.value ~default:0 tool_schema_bytes
         ; tool_schema_bytes
         ; node_count = List.length (Keeper_tool_plan.nodes entry.plan)
         ; batch_count
         ; parallel_batch_count
         ; max_parallelism
         ; statically_read_only = Some (statically_read_only entry.plan)
         ; declaration_span = skill.composition_span
         }
;;

let of_skill (skill : Keeper_skill_catalog.skill) =
  Option.map (fun reference -> of_skill_with_reference reference skill) skill.reference
;;

let of_catalog catalog =
  Keeper_skill_catalog.skills catalog |> List.filter_map of_skill
;;

let to_yojson profile =
  `Assoc
    [ "reference", Skill_reference.to_yojson profile.reference
    ; "kind", `String profile.kind
    ; "activation_tool", `String profile.activation_tool
    ; "execution", `String profile.execution
    ; ( "capabilities"
      , `Assoc
          [ "as_skill", `Bool true
          ; "as_tool", `Bool (String.equal profile.kind "composition")
          ; "batch", `Bool (profile.node_count > 1)
          ; "parallel", `Bool (profile.max_parallelism > 1)
          ; "async", `Bool (String.equal profile.execution "async")
          ; ( "tool_scope"
            , `String
                (if String.equal profile.kind "composition"
                 then "registered_tools_only"
                 else "model_orchestrated") )
          ] )
    ; ( "context"
      , `Assoc
          [ "body_bytes", `Int profile.body_bytes
          ; "eager_body_bytes", `Int profile.eager_body_bytes
          ; "discovery_bytes", `Int profile.discovery_bytes
          ; ( "tool_schema_bytes"
            , match profile.tool_schema_bytes with
              | Some bytes -> `Int bytes
              | None -> `Null )
          ] )
    ; ( "plan"
      , `Assoc
          [ "node_count", `Int profile.node_count
          ; "batch_count", `Int profile.batch_count
          ; "parallel_batch_count", `Int profile.parallel_batch_count
          ; "max_parallelism", `Int profile.max_parallelism
          ; ( "statically_read_only"
            , match profile.statically_read_only with
              | Some value -> `Bool value
              | None -> `Null )
          ] )
    ; ( "declaration"
      , match profile.declaration_span with
        | None -> `Null
        | Some span ->
          `Assoc
            [ "start_line", `Int span.start_line
            ; "end_line", `Int span.end_line
            ] )
    ]
;;
