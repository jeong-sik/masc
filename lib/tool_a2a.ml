(** A2A tools - Agent-to-Agent protocol *)

open Tool_args

(* Context required by a2a tools *)
type context = {
  config: Room.config;
  agent_name: string;
}

type result = bool * string

(* Individual handlers *)
let handle_a2a_discover ctx args =
  let endpoint = get_string_opt args "endpoint" in
  let capability = get_string_opt args "capability" in
  match A2a_tools.discover ctx.config ?endpoint ?capability ~schemas:Config.raw_all_tool_schemas () with
  | Ok json -> (true, Yojson.Safe.pretty_to_string json)
  | Error e -> (false, Printf.sprintf "❌ Discovery failed: %s" e)

let handle_a2a_query_skill ctx args =
  let ( let*! ) = Tool_args.( let*! ) in
  let*! skill_agent_name = get_string_required args "agent_name" in
  let*! skill_id = get_string_required args "skill_id" in
  match A2a_tools.query_skill ctx.config ~schemas:Config.raw_all_tool_schemas ~agent_name:skill_agent_name ~skill_id with
  | Ok json -> (true, Yojson.Safe.pretty_to_string json)
  | Error e -> (false, Printf.sprintf "❌ Query skill failed: %s" e)

let handle_a2a_delegate ctx args =
  let ( let*! ) = Tool_args.( let*! ) in
  (* Always use the authenticated caller's identity for the portal,
     not a user-supplied override. The caller cannot impersonate another agent. *)
  let delegate_agent_name = ctx.agent_name in
  let*! target = get_string_required args "target_agent" in
  let*! message = get_string_required args "message" in
  let task_type_str = get_string args "task_type" "async" in
  let timeout = get_int args "timeout" 300 in
  let artifacts =
    Safe_ops.json_list "artifacts" args
    |> List.filter_map (fun item ->
         match A2a_tools.artifact_of_yojson item with
         | Ok a -> Some a
         | Error _ -> None)
  in
  match A2a_tools.delegate ctx.config ~agent_name:delegate_agent_name ~target ~message
           ~task_type_str ~artifacts ~timeout () with
  | Ok json -> (true, Yojson.Safe.pretty_to_string json)
  | Error e -> (false, Printf.sprintf "❌ Delegation failed: %s" e)

let handle_a2a_subscribe _ctx args =
  let agent_filter = get_string_opt args "agent_name" in
  let events =
    Safe_ops.json_string_list "events" args
  in
  (try
    match A2a_tools.subscribe ?agent_filter ~events () with
    | Ok json -> (true, Yojson.Safe.pretty_to_string json)
    | Error e -> (false, Printf.sprintf "❌ Subscribe failed: %s" e)
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    (false, Printf.sprintf "❌ Subscribe exception: %s" (Printexc.to_string exn)))

let handle_a2a_unsubscribe _ctx args =
  let subscription_id = get_string args "subscription_id" "" in
  if subscription_id = "" then
    (false, "subscription_id is required")
  else
  match A2a_tools.unsubscribe ~subscription_id with
  | Ok json -> (true, Yojson.Safe.pretty_to_string json)
  | Error e -> (false, Printf.sprintf "❌ Unsubscribe failed: %s" e)

let handle_poll_events _ctx args =
  let subscription_id = get_string args "subscription_id" "" in
  if subscription_id = "" then
    (false, "subscription_id is required")
  else
  let clear = get_bool args "clear" true in
  match A2a_tools.poll_events ~subscription_id ~clear () with
  | Ok json -> (true, Yojson.Safe.pretty_to_string json)
  | Error e -> (false, Printf.sprintf "❌ Poll events failed: %s" e)

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
    (false, "❌ worker_name, agent, status, summary, and decision_reason are required")
  else if decision_confidence < 0.0 || decision_confidence > 1.0 then
    (false, "❌ decision_confidence must be between 0.0 and 1.0")
  else
    match
      A2a_tools.submit_heartbeat_result ~worker_name ~agent ~status ~summary
        ~tool_call_count ~tool_names ~decision_reason ~decision_confidence
        ?failure_reason ()
    with
    | Ok json -> (true, Yojson.Safe.pretty_to_string json)
    | Error e -> (false, Printf.sprintf "❌ Submit result failed: %s" e)

(* Dispatch function - returns None if tool not handled *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_a2a_discover" -> Some (handle_a2a_discover ctx args)
  | "masc_a2a_query_skill" -> Some (handle_a2a_query_skill ctx args)
  | "masc_a2a_delegate" -> Some (handle_a2a_delegate ctx args)
  | "masc_a2a_subscribe" -> Some (handle_a2a_subscribe ctx args)
  | "masc_a2a_unsubscribe" -> Some (handle_a2a_unsubscribe ctx args)
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
           ~module_tag:Tool_dispatch.Mod_misc
           ~input_schema:s.input_schema
           ()))
    schemas
