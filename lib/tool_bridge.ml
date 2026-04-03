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

    Convert MASC JSON Schema (input_schema) to OAS [tool_param list].
    MASC schemas use raw JSON objects; OAS uses typed [tool_param] records. *)

let param_type_of_string = function
  | "string" -> Agent_sdk.Types.String
  | "integer" -> Agent_sdk.Types.Integer
  | "number" -> Agent_sdk.Types.Number
  | "boolean" -> Agent_sdk.Types.Boolean
  | "array" -> Agent_sdk.Types.Array
  | "object" -> Agent_sdk.Types.Object
  | _ -> Agent_sdk.Types.String

(** Extract OAS [tool_param list] from a MASC [input_schema] JSON object.

    Reads ["properties"] and ["required"] fields from the JSON Schema.
    Unknown types default to [String]. *)
let params_of_json_schema (schema : Yojson.Safe.t) : Agent_sdk.Types.tool_param list =
  let open Yojson.Safe.Util in
  let props =
    try schema |> member "properties" |> to_assoc
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> []
  in
  let required_keys =
    try schema |> member "required" |> to_list |> List.filter_map (fun j ->
      try Some (to_string j) with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None)
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> []
  in
  List.filter_map (fun (key, prop) ->
    try
      let type_str =
        try prop |> member "type" |> to_string
        with Eio.Cancel.Cancelled _ as e -> raise e | _ -> "string"
      in
      let description =
        try prop |> member "description" |> to_string
        with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ""
      in
      Some {
        Agent_sdk.Types.name = key;
        description;
        param_type = param_type_of_string type_str;
        required = List.mem key required_keys;
      }
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None
  ) props

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
  let descriptor : Agent_sdk.Tool.descriptor =
    { kind = None; shell = None; mutation_class = None; concurrency_class = None; notes = []; examples = [] }
  in
  Agent_sdk.Tool.create ~descriptor ~name ~description ~parameters oas_handler
