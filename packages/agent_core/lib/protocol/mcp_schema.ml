open Types
module Sdk_types = Mcp_protocol.Mcp_types

(* ── JSON Schema -> SDK tool_param (oas-specific bridge) ─────────── *)

(* The conversion itself lives in {!Types}, next to the constructor that has to
   apply it to keep [tool_schema.parameters] in agreement with
   [tool_schema.input_schema]. These are re-exports for existing callers. *)

let json_schema_type_to_param_type_result = Types.json_schema_type_to_param_type_result
let json_schema_to_params_result = Types.json_schema_to_params_result

let json_schema_type_to_param_type value =
  match json_schema_type_to_param_type_result value with
  | Ok param_type -> param_type
  | Error detail -> invalid_arg detail
;;

let json_schema_to_params schema =
  match json_schema_to_params_result schema with
  | Ok params -> params
  | Error detail -> invalid_arg detail
;;

(* ── MCP tool type (oas-local, bridged from SDK) ─────────────────── *)

type mcp_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  }

type mcp_resource = Sdk_types.resource
type mcp_resource_contents = Sdk_types.resource_contents
type mcp_prompt = Sdk_types.prompt
type mcp_prompt_result = Sdk_types.prompt_result

(** Convert SDK {!Sdk_types.tool} to oas {!mcp_tool}. *)
let mcp_tool_of_sdk_tool (t : Sdk_types.tool) : mcp_tool =
  { name = t.name
  ; description = Option.value ~default:"" t.description
  ; input_schema = t.input_schema
  }
;;

(** Build a {!Tool.t} from one authoritative JSON Schema. The parameter view is
    derived from that same schema, so [parameters] and [input_schema] cannot
    disagree, and the schema reaches providers verbatim — keeping [minimum],
    [maximum], [default], [enum] and nested properties that
    {!Types.params_to_input_schema} would drop. *)
let tool_of_input_schema_result
      ?descriptor
      ?strict
      ~name
      ~description
      ~input_schema
      call_fn
  =
  match Types.tool_schema_of_input_schema ?strict ~name ~description ~input_schema () with
  | Ok schema ->
    Ok (Tool.of_schema ?descriptor schema (Tool.ignoring_execution_env call_fn))
  | Error detail -> Error (Printf.sprintf "tool %S schema invalid: %s" name detail)
;;

(** Convert {!mcp_tool} to SDK {!Tool.t} with the given call handler. *)
let mcp_tool_to_sdk_tool_result ~call_fn mcp_tool =
  tool_of_input_schema_result
    ~name:mcp_tool.name
    ~description:mcp_tool.description
    ~input_schema:mcp_tool.input_schema
    call_fn
;;

let mcp_tool_to_sdk_tool ~call_fn mcp_tool =
  match mcp_tool_to_sdk_tool_result ~call_fn mcp_tool with
  | Ok tool_ -> tool_
  | Error detail -> invalid_arg detail
;;

[@@@coverage off]
(* === Inline tests === *)

let%test "json_schema_type_to_param_type string" =
  json_schema_type_to_param_type "string" = Types.String
;;

let%test "json_schema_type_to_param_type integer" =
  json_schema_type_to_param_type "integer" = Types.Integer
;;

let%test "json_schema_type_to_param_type number" =
  json_schema_type_to_param_type "number" = Types.Number
;;

let%test "json_schema_type_to_param_type boolean" =
  json_schema_type_to_param_type "boolean" = Types.Boolean
;;

let%test "json_schema_type_to_param_type array" =
  json_schema_type_to_param_type "array" = Types.Array
;;

let%test "json_schema_type_to_param_type object" =
  json_schema_type_to_param_type "object" = Types.Object
;;

let%test "json_schema_type_to_param_type_result unknown fails" =
  match json_schema_type_to_param_type_result "foobar" with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "json_schema_to_params basic schema" =
  let schema =
    `Assoc
      [ "type", `String "object"
      ; ( "properties"
        , `Assoc
            [ ( "name"
              , `Assoc [ "type", `String "string"; "description", `String "the name" ] )
            ; ( "count"
              , `Assoc [ "type", `String "integer"; "description", `String "a count" ] )
            ] )
      ; "required", `List [ `String "name" ]
      ]
  in
  let params = json_schema_to_params schema in
  List.length params = 2
  && (List.find (fun (p : Types.tool_param) -> p.name = "name") params).required = true
  && (List.find (fun (p : Types.tool_param) -> p.name = "count") params).required = false
;;

let%test "json_schema_to_params empty properties" =
  let schema = `Assoc [ "properties", `Assoc [] ] in
  json_schema_to_params schema = []
;;

let%test "json_schema_to_params no properties key" =
  let schema = `Assoc [] in
  json_schema_to_params schema = []
;;

let%test "json_schema_to_params_result non-assoc properties fails" =
  let schema = `Assoc [ "properties", `List [] ] in
  match json_schema_to_params_result schema with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "mcp_tool_of_sdk_tool converts correctly" =
  let sdk_tool : Sdk_types.tool =
    { name = "test_tool"
    ; description = Some "A test tool"
    ; input_schema = `Assoc [ "type", `String "object" ]
    ; title = None
    ; annotations = None
    ; icon = None
    ; output_schema = None
    ; execution = None
    }
  in
  let result = mcp_tool_of_sdk_tool sdk_tool in
  result.name = "test_tool" && result.description = "A test tool"
;;

let%test "mcp_tool_of_sdk_tool None description becomes empty" =
  let sdk_tool : Sdk_types.tool =
    { name = "tool2"
    ; description = None
    ; input_schema = `Assoc []
    ; title = None
    ; annotations = None
    ; icon = None
    ; output_schema = None
    ; execution = None
    }
  in
  let result = mcp_tool_of_sdk_tool sdk_tool in
  result.description = ""
;;
