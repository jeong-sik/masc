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
  match A2a_tools.discover ctx.config ?endpoint ?capability () with
  | Ok json -> (true, Yojson.Safe.pretty_to_string json)
  | Error e -> (false, Printf.sprintf "❌ Discovery failed: %s" e)

let handle_a2a_query_skill ctx args =
  let skill_agent_name = get_string args "agent_name" "" in
  let skill_id = get_string args "skill_id" "" in
  match A2a_tools.query_skill ctx.config ~schemas:Config.raw_all_tool_schemas ~agent_name:skill_agent_name ~skill_id with
  | Ok json -> (true, Yojson.Safe.pretty_to_string json)
  | Error e -> (false, Printf.sprintf "❌ Query skill failed: %s" e)

let handle_a2a_delegate ctx args =
  let delegate_agent_name = get_string args "agent_name" ctx.agent_name in
  let target = get_string args "target_agent" "" in
  let message = get_string args "message" "" in
  let task_type_str = get_string args "task_type" "async" in
  let timeout = get_int args "timeout" 300 in
  let artifacts = match Yojson.Safe.Util.member "artifacts" args with
    | `Null -> []
    | `List items ->
        List.filter_map (fun item ->
          match A2a_tools.artifact_of_yojson item with
          | Ok a -> Some a
          | Error _ -> None) items
    | _ -> []
  in
  match A2a_tools.delegate ctx.config ~agent_name:delegate_agent_name ~target ~message
           ~task_type_str ~artifacts ~timeout () with
  | Ok json -> (true, Yojson.Safe.pretty_to_string json)
  | Error e -> (false, Printf.sprintf "❌ Delegation failed: %s" e)

let handle_a2a_subscribe _ctx args =
  let agent_filter = get_string_opt args "agent_name" in
  let events = match Yojson.Safe.Util.member "events" args with
    | `List items -> List.filter_map (function `String s -> Some s | _ -> None) items
    | _ -> []
  in
  (try
    match A2a_tools.subscribe ?agent_filter ~events () with
    | Ok json -> (true, Yojson.Safe.pretty_to_string json)
    | Error e -> (false, Printf.sprintf "❌ Subscribe failed: %s" e)
  with exn ->
    (false, Printf.sprintf "❌ Subscribe exception: %s" (Printexc.to_string exn)))

let handle_a2a_unsubscribe _ctx args =
  let subscription_id = get_string args "subscription_id" "" in
  match A2a_tools.unsubscribe ~subscription_id with
  | Ok json -> (true, Yojson.Safe.pretty_to_string json)
  | Error e -> (false, Printf.sprintf "❌ Unsubscribe failed: %s" e)

let handle_poll_events _ctx args =
  let subscription_id = get_string args "subscription_id" "" in
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
    match Yojson.Safe.Util.member "tool_names" args with
    | `List items -> List.filter_map (function `String s -> Some s | _ -> None) items
    | _ -> []
  in
  let decision_reason = get_string args "decision_reason" "" in
  let decision_confidence =
    match Yojson.Safe.Util.member "decision_confidence" args with
    | `Float f -> f
    | `Int n -> float_of_int n
    | _ -> -1.0
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

let schemas : Types.tool_schema list = [
  (* masc_poll_events *)
  {
    name = "masc_poll_events";
    description = "Poll buffered events for a subscription and optionally clear the buffer. \
Use when checking for async task updates or broadcast events between work steps. \
Workflow: masc_a2a_subscribe -> do work -> masc_poll_events periodically -> masc_a2a_unsubscribe.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("subscription_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Subscription ID to poll events from");
        ]);
        ("clear", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Clear buffer after reading (default: true)");
          ("default", `Bool true);
        ]);
      ]);
      ("required", `List [`String "subscription_id"]);
    ];
  };

  (* masc_heartbeat_result *)
  {
    name = "masc_heartbeat_result";
    description = "Submit heartbeat completion evidence after running an assigned heartbeat_task MCP tool loop. \
Call when a worker agent finishes its heartbeat action cycle with status (acted/skipped/failed). \
Reports tool usage and decision metadata. Pair with masc_heartbeat_start to initiate the cycle.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("worker_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Worker agent name (e.g., 'llm-worker-local')");
        ]);
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Original Lodge agent name (e.g., 'dreamer')");
        ]);
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Completion status: acted | skipped | failed");
          ("enum", `List [`String "acted"; `String "skipped"; `String "failed"]);
        ]);
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Short completion summary");
        ]);
        ("tool_call_count", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of MCP tool calls executed by the worker");
        ]);
        ("tool_names", `Assoc [
          ("type", `String "array");
          ("description", `String "Executed MCP tool names");
          ("items", `Assoc [("type", `String "string")]);
        ]);
        ("decision_reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Why the worker chose this outcome");
        ]);
        ("decision_confidence", `Assoc [
          ("type", `String "number");
          ("description", `String "Confidence score between 0.0 and 1.0");
        ]);
        ("failure_reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional explicit failure reason");
        ]);
      ]);
      ("required",
        `List
          [
            `String "worker_name";
            `String "agent";
            `String "status";
            `String "summary";
            `String "tool_call_count";
            `String "tool_names";
            `String "decision_reason";
            `String "decision_confidence";
          ]);
    ];
  };

]
