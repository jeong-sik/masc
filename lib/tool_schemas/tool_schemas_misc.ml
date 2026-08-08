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
  | Pause -> Tool_descriptors_gen.masc_pause_schema
  | Resume -> Tool_descriptors_gen.masc_resume_schema
  | Pause_status -> Tool_descriptors_gen.masc_pause_status_schema
;;

let control_schemas = List.map control_schema control_operations

(* [schemas] is the generated public misc schema set. Operator control schemas
   use the dedicated typed projection above so they remain registered without
   entering Config's public/front-door inventory. Descriptor-owned web backend
   names (masc_web_search / masc_web_fetch) are intentionally not generated
   here; [Config.raw_all_tool_schemas] projects them from
   [Keeper_tool_descriptor.public_descriptors] so the keeper universe still
   knows they exist without duplicating their schema ownership. *)
let schemas : tool_schema list = Tool_descriptors_gen.schemas

type mcp_runtime_operation =
  | Start
  | Broadcast
  | Messages

let mcp_runtime_operations = [ Start; Broadcast; Messages ]

let mcp_runtime_tool_name = function
  | Start -> "masc_start"
  | Broadcast -> "masc_broadcast"
  | Messages -> "masc_messages"
;;

let mcp_runtime_operation_of_tool_name = function
  | "masc_start" -> Some Start
  | "masc_broadcast" -> Some Broadcast
  | "masc_messages" -> Some Messages
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
