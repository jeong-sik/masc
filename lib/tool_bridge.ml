(** OAS boundary adapter for tool results, schemas, and tool definitions.

    MASC tools use [(bool * string)] internally (success flag + message).
    OAS uses [Agent_sdk.Types.tool_result = (tool_output, tool_error) result].

    This module converts at the OAS boundary only — internal MASC
    tool handlers keep their existing convention unchanged.

    @since 2.95.1 — result conversion
    @since 2.110.0 — schema conversion + OAS Tool.t creation *)

(** {1 Result Conversion} *)

let to_oas_tool_result ?(recoverable = true) (success, msg)
  : Agent_sdk.Types.tool_result =
  if success then Ok { Agent_sdk.Types.content = msg }
  else Error { Agent_sdk.Types.message = msg; recoverable }

let of_oas_tool_result : Agent_sdk.Types.tool_result -> bool * string = function
  | Ok { content } -> (true, content)
  | Error { message; _ } -> (false, message)

(** {1 Schema Conversion}

    Delegates to [Agent_sdk.Mcp.json_schema_to_params] — the canonical
    JSON Schema to OAS [tool_param list] conversion.

    @since 2.221.0 — delegates to OAS Mcp module (removes 40-line duplicate) *)

let param_type_of_string = Agent_sdk.Mcp.json_schema_type_to_param_type

let params_of_json_schema = Agent_sdk.Mcp.json_schema_to_params

(** {1 OAS Tool.t Creation}

    Create OAS [Tool.t] from MASC schema definition + dispatch handler.
    This allows incremental migration: each tool can be converted independently. *)

(** Create an OAS [Tool.t] from a MASC tool schema and a handler function.

    [handler] receives raw JSON args and returns MASC [(bool * string)].
    The bridge converts the result to OAS [tool_result] automatically.

    {[
      let oas_tool = oas_tool_of_masc
        ~name:"masc_board_post"
        ~description:"Post to the board..."
        ~input_schema:schema_json
        (fun args -> handle_board_post ctx args)
    ]} *)
let oas_tool_of_masc ~name ~description ~input_schema
    handler : Agent_sdk.Tool.t =
  let parameters = params_of_json_schema input_schema in
  let oas_handler json_args =
    let success, msg = handler json_args in
    to_oas_tool_result (success, msg)
  in
  Agent_sdk.Tool.create ~name ~description ~parameters oas_handler
