type surface =
  | Instruction_skill

let kind_label = function
  | Instruction_skill -> "instruction"
;;

let execution_label = function
  | Instruction_skill -> "on_demand"
;;

let surfaces = [ Instruction_skill ]

type io =
  | Model_orchestrated

type profile =
  { reference : Skill_reference.t
  ; surface : surface
  ; activation_tool : string
  ; body_bytes : int
  ; discovery_bytes : int
  ; tool_schema_bytes : int option
  ; node_count : int
  ; batch_count : int
  ; parallel_batch_count : int
  ; max_parallelism : int
  ; statically_read_only : bool option
  ; io : io
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

let instruction_discovery_bytes reference description =
  String.length
    (Skill_reference.identity_to_yojson reference.Skill_reference.identity
     |> Yojson.Safe.to_string)
  + 2
  + String.length description
;;

let of_skill_with_reference reference (skill : Keeper_skill_catalog.skill) =
  { reference
  ; surface = Instruction_skill
  ; activation_tool = Keeper_instruction_skill.skill_tool_name
  ; body_bytes = String.length skill.body
  ; discovery_bytes = instruction_discovery_bytes reference skill.description
  ; tool_schema_bytes = None
  ; node_count = 0
  ; batch_count = 0
  ; parallel_batch_count = 0
  ; max_parallelism = 0
  ; statically_read_only = None
  ; io = Model_orchestrated
  }
;;

let of_skill (skill : Keeper_skill_catalog.skill) =
  Option.map (fun reference -> of_skill_with_reference reference skill) skill.reference
;;

let of_catalog catalog =
  Keeper_skill_catalog.skills catalog |> List.filter_map of_skill
;;

let to_fields profile =
  [ "reference", Skill_reference.to_yojson profile.reference
  ; "kind", `String (kind_label profile.surface)
  ; "activation_tool", `String profile.activation_tool
  ; "execution", `String (execution_label profile.surface)
  ; ( "capabilities"
    , `Assoc
        [ "as_skill", `Bool true
        ; "as_tool", `Bool false
        ; "batch", `Bool false
        ; "parallel", `Bool false
        ; "async", `Bool false
        ; "tool_scope", `String "model_orchestrated"
        ] )
  ; ( "context"
    , `Assoc
        [ "body_bytes", `Int profile.body_bytes
        ; "discovery_bytes", `Int profile.discovery_bytes
        ; "tool_schema_bytes", `Null
        ] )
  ; ( "plan"
    , `Assoc
        [ "node_count", `Int 0
        ; "batch_count", `Int 0
        ; "parallel_batch_count", `Int 0
        ; "max_parallelism", `Int 0
        ; "statically_read_only", `Null
        ] )
  ; "declaration", `Null
  ; "io", `Assoc [ "kind", `String "model_orchestrated" ]
  ; "flow", `Null
  ]
;;

let to_yojson profile = `Assoc (to_fields profile)
