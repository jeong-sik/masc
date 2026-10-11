type error = Source_reader_unavailable

let error_to_string = function
  | Source_reader_unavailable ->
    "canonical workspace artifact reader is absent from the offered Tool surface"
;;

let require_reader tools =
  let schema = Keeper_runtime_schemas_toml.artifact_read in
  match
    Agent_core.Types.tool_schema_of_input_schema
      ~name:schema.name
      ~description:schema.description
      ~input_schema:schema.input_schema
      ()
  with
  | Error _ -> Error Source_reader_unavailable
  | Ok schema ->
    let expected_wire = Agent_core.Tool.wire_json_of_schema schema in
    let expected_descriptor =
      Agent_core.Tool.descriptor_to_yojson
        (Some (Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent))
    in
    if
      List.exists
        (fun tool ->
           Agent_core.Tool.schema_to_json tool = expected_wire
           && Agent_core.Tool.descriptor_to_yojson (Agent_core.Tool.descriptor tool)
              = expected_descriptor)
        tools
    then Ok ()
    else Error Source_reader_unavailable
;;
