(** A2A tools - Agent-to-Agent protocol.
    Deprecated tool handlers (discover/query_skill/delegate/subscribe/unsubscribe)
    removed. Only poll_events and heartbeat_result remain active. *)

open Tool_args

(* Context required by a2a tools *)
type context = {
  config: Room.config;
  agent_name: string;
}

type tool_result = bool * string

let handle_poll_events _ctx args =
  let subscription_id = get_string args "subscription_id" "" in
  if subscription_id = "" then
    (false, "subscription_id is required")
  else
  let clear = get_bool args "clear" true in
  match A2a_tools.poll_events ~subscription_id ~clear () with
  | Ok json -> (true, Yojson.Safe.to_string json)
  | Error e -> (false, Printf.sprintf "Poll events failed: %s" e)

(** A2A Worker submits heartbeat task result *)
let handle_heartbeat_result _ctx args =
  let worker_name = get_string args "worker_name" "" in
  let agent = get_string args "agent" "" in
  let status = get_string args "status" "" in
  let summary = get_string args "summary" "" in
  let tool_call_count = get_int args "tool_call_count" 0 in
  let tool_names =
    Safe_ops.json_string_list "tool_names" args
  in
  let decision_reason = get_string args "decision_reason" "" in
  let decision_confidence =
    Safe_ops.json_float ~default:(-1.0) "decision_confidence" args
  in
  let failure_reason = get_string_opt args "failure_reason" in
  if worker_name = "" || agent = "" || status = "" || summary = "" || decision_reason = "" then
    (false, "worker_name, agent, status, summary, and decision_reason are required")
  else if decision_confidence < 0.0 || decision_confidence > 1.0 then
    (false, "decision_confidence must be between 0.0 and 1.0")
  else
    match
      A2a_tools.submit_heartbeat_result ~worker_name ~agent ~status ~summary
        ~tool_call_count ~tool_names ~decision_reason ~decision_confidence
        ?failure_reason ()
    with
    | Ok json -> (true, Yojson.Safe.to_string json)
    | Error e -> (false, Printf.sprintf "Submit result failed: %s" e)

(* Dispatch function - returns None if tool not handled *)
let dispatch ctx ~name ~args : tool_result option =
  match name with
  | "masc_poll_events" -> Some (handle_poll_events ctx args)
  | "masc_heartbeat_result" -> Some (handle_heartbeat_result ctx args)
  | _ -> None

let schemas = Tool_schemas_a2a.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_a2a
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ()))
    schemas
