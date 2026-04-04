(** Portal tools - Agent-to-agent direct messaging *)

open Tool_args

(* Context required by portal tools *)
type context = {
  config: Room.config;
  agent_name: string;
}

type result = bool * string

let filter_visible_tool_names ctx tool_names =
  let portal_open =
    Option.is_some (Room.get_portal_target ctx.config ~agent_name:ctx.agent_name)
  in
  List.filter
    (fun name ->
      match name with
      | "masc_portal_status" -> true
      | "masc_portal_open" -> not portal_open
      | "masc_portal_send" | "masc_portal_close" -> portal_open
      | _ -> true)
    tool_names

(* Individual handlers *)
let handle_portal_open ctx args =
  let target_agent = get_string args "target_agent" "" in
  if target_agent = "" then
    (false, "target_agent is required")
  else
    let initial_message = get_string_opt args "initial_message" in
    match Room.portal_open_r ctx.config ~agent_name:ctx.agent_name ~target_agent ~initial_message with
  | Ok msg -> (true, msg)
  | Error e -> (false, Types.masc_error_to_string e)

let handle_portal_send ctx args =
  let message = get_string args "message" "" in
  if message = "" then
    (false, "message is required")
  else begin
  (* macOS notification for portal message *)
  (match Room.get_portal_target ctx.config ~agent_name:ctx.agent_name with
   | Some target -> Notify.notify_portal ~from_agent:ctx.agent_name ~target_agent:target ~message ()
   | None -> ());
  match Room.portal_send_r ctx.config ~agent_name:ctx.agent_name ~message with
  | Ok msg -> (true, msg)
  | Error e -> (false, Types.masc_error_to_string e)
  end

let handle_portal_close ctx _args =
  (true, Room.portal_close ctx.config ~agent_name:ctx.agent_name)

let handle_portal_status ctx _args =
  let json = Room.portal_status ctx.config ~agent_name:ctx.agent_name in
  (true, Yojson.Safe.pretty_to_string json)

(* Dispatch function - returns None if tool not handled *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_portal_open" -> Some (handle_portal_open ctx args)
  | "masc_portal_send" -> Some (handle_portal_send ctx args)
  | "masc_portal_close" -> Some (handle_portal_close ctx args)
  | "masc_portal_status" -> Some (handle_portal_status ctx args)
  | _ -> None

let schemas = Tool_schemas_portal.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only = [ "masc_portal_status" ]
let _tool_spec_requires_join = [ "masc_portal_open"; "masc_portal_send"; "masc_portal_close" ]

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_misc
           ~input_schema:s.input_schema
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ~requires_join:(List.mem s.name _tool_spec_requires_join)
           ()))
    schemas
