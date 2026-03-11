(** Generate Agent SDK tools for MASC control from the shared contract layer.

    SDK-facing tool names stay stable for prompts and tests, but execution and
    parameter schema come from Agent_swarm_contract so OAS and SDK consume the
    same source of truth. *)

open Agent_sdk

let tool_of_binding (client : Agent_swarm_client.t) ~sw
    (binding : Agent_swarm_contract.sdk_tool_binding) : Tool.t =
  let parameters =
    Agent_swarm_contract.tool_params_of_input_schema binding.input_schema
  in
  Tool.create ~name:binding.sdk_name ~description:binding.description ~parameters
    (fun input ->
      match
        Agent_swarm_contract.build_operation_arguments
          ~agent_name:client.agent_name binding input
      with
      | Error message -> Error message
      | Ok arguments_json -> (
          match
            Agent_swarm_client.call_operation_json ~sw client
              ~operation_id:binding.canonical_operation
              ~arguments_json
          with
          | Ok json -> Ok (Agent_swarm_tool_input.json_to_string json)
          | Error message -> Error message))

let make_tools (client : Agent_swarm_client.t) ~sw : Tool.t list =
  List.map (tool_of_binding client ~sw) Agent_swarm_contract.sdk_bindings
