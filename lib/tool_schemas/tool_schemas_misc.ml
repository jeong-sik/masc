(** Tool schemas for Tool_misc — separated to break Config dependency cycle *)

open Masc_domain

type control_operation =
  | Pause
  | Resume
  | Pause_status

let control_operations = [ Pause; Resume; Pause_status ]

let control_operation_id = function
  | Pause -> "pause"
  | Resume -> "resume"
  | Pause_status -> "pause_status"
;;

let control_schema = function
  | Pause -> Tool_schemas_operator_surface.pause
  | Resume -> Tool_schemas_operator_surface.resume
  | Pause_status -> Tool_schemas_operator_surface.pause_status
;;

let control_schemas = List.map control_schema control_operations

let web_search_schema : tool_schema = Tool_schemas_misc_toml.web_search
let web_fetch_schema : tool_schema = Tool_schemas_misc_toml.web_fetch

let web_schemas = [ web_search_schema; web_fetch_schema ]

(* [schemas] is the public misc schema set, now read from
   config/tools/masc_*.toml. Operator control and web runtime schemas use the
   dedicated projections above. *)
let schemas : tool_schema list = Tool_schemas_operator_surface.schemas

type mcp_runtime_operation =
  | Start
  | Broadcast
  | Messages
  | Ask

let mcp_runtime_operations = [ Start; Broadcast; Messages; Ask ]

let mcp_runtime_tool_name = function
  | Start -> "masc_start"
  | Broadcast -> "masc_broadcast"
  | Messages -> "masc_messages"
  | Ask -> "masc_ask"
;;

let mcp_runtime_operation_of_tool_name = function
  | "masc_start" -> Some Start
  | "masc_broadcast" -> Some Broadcast
  | "masc_messages" -> Some Messages
  | "masc_ask" -> Some Ask
  | _ -> None
;;

let mcp_runtime_schema operation =
  let name = mcp_runtime_tool_name operation in
  match
    List.find_opt
      (fun (schema : tool_schema) -> String.equal schema.name name)
      schemas
  with
  | Some schema -> schema
  | None -> invalid_arg ("missing MCP runtime schema: " ^ name)
;;

let mcp_runtime_schemas = List.map mcp_runtime_schema mcp_runtime_operations
