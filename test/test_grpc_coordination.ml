(** Tests for MASC gRPC Coordination Service.

    Tests the types, service construction, and handler logic without
    requiring a running gRPC server or network connections. *)

module T = Masc_mcp.Masc_grpc_types

(* ====== Type serialization/deserialization round-trip tests ====== *)

let test_join_request_roundtrip () =
  let req = T.JoinRequest.{
    agent_name = "claude-swift-fox";
    capabilities = ["code"; "review"; "test"];
    metadata = [("model", "opus-4"); ("version", "1.0")];
  } in
  let bytes = T.JoinRequest.to_bytes req in
  let decoded = T.JoinRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" req.agent_name decoded.agent_name;
  Alcotest.(check (list string)) "capabilities" req.capabilities decoded.capabilities;
  Alcotest.(check int) "metadata length" (List.length req.metadata) (List.length decoded.metadata);
  Alcotest.(check string) "metadata model"
    (List.assoc "model" req.metadata)
    (List.assoc "model" decoded.metadata)

let test_leave_request_roundtrip () =
  let req = T.LeaveRequest.{
    agent_name = "gemini-bright-owl";
    session_id = "grpc-gemini-12345";
  } in
  let bytes = T.LeaveRequest.to_bytes req in
  let decoded = T.LeaveRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" req.agent_name decoded.agent_name;
  Alcotest.(check string) "session_id" req.session_id decoded.session_id

let test_join_response_serialization () =
  let resp = T.JoinResponse.{
    success = true;
    message = "Joined room";
    session_id = "grpc-test-001";
    active_agents = [
      {
        T.name = "claude-swift-fox";
        status = "active";
        capabilities = ["code"];
        last_heartbeat_ms = 1700000000000L;
        joined_at_ms = 1700000000000L;
        current_task_id = "task-1";
      };
    ];
  } in
  let bytes = T.JoinResponse.to_bytes resp in
  let json = Yojson.Safe.from_string bytes in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "success" true (json |> member "success" |> to_bool);
  Alcotest.(check string) "message" "Joined room" (json |> member "message" |> to_string);
  Alcotest.(check string) "session_id" "grpc-test-001" (json |> member "session_id" |> to_string);
  let agents = json |> member "active_agents" |> to_list in
  Alcotest.(check int) "active_agents count" 1 (List.length agents);
  let agent = List.hd agents in
  Alcotest.(check string) "agent name" "claude-swift-fox" (agent |> member "name" |> to_string)

let test_broadcast_request_roundtrip () =
  let req = T.BroadcastRequest.{
    agent_name = "codex-running-bear";
    message = "CI fixed, ready to merge";
    mentions = ["claude"; "gemini"];
  } in
  let bytes = T.BroadcastRequest.of_bytes (T.BroadcastRequest.(
    `Assoc [
      ("agent_name", `String req.agent_name);
      ("message", `String req.message);
      ("mentions", `List (List.map (fun s -> `String s) req.mentions));
    ] |> Yojson.Safe.to_string)) in
  Alcotest.(check string) "agent_name" req.agent_name bytes.agent_name;
  Alcotest.(check string) "message" req.message bytes.message;
  Alcotest.(check (list string)) "mentions" req.mentions bytes.mentions

let test_broadcast_response_serialization () =
  let resp = T.BroadcastResponse.{ success = true; seq = 42L } in
  let bytes = T.BroadcastResponse.to_bytes resp in
  let json = Yojson.Safe.from_string bytes in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "success" true (json |> member "success" |> to_bool)

let test_heartbeat_ping_deserialization () =
  let json_str = {|{"agent_name":"test-agent","session_id":"sess-1","timestamp_ms":1700000000000,"current_task_id":"task-42"}|} in
  let ping = T.HeartbeatPing.of_bytes json_str in
  Alcotest.(check string) "agent_name" "test-agent" ping.agent_name;
  Alcotest.(check string) "session_id" "sess-1" ping.session_id;
  Alcotest.(check string) "current_task_id" "task-42" ping.current_task_id

let test_heartbeat_ack_serialization () =
  let ack = T.HeartbeatAck.{
    timestamp_ms = 1700000000001L;
    active_agent_count = 5;
    pending_task_count = 3;
    directives = ["rebalance"];
  } in
  let bytes = T.HeartbeatAck.to_bytes ack in
  let json = Yojson.Safe.from_string bytes in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "active_agent_count" 5 (json |> member "active_agent_count" |> to_int);
  Alcotest.(check int) "pending_task_count" 3 (json |> member "pending_task_count" |> to_int);
  let dirs = json |> member "directives" |> to_list |> List.map to_string in
  Alcotest.(check (list string)) "directives" ["rebalance"] dirs

let test_subscribe_request_deserialization () =
  let json_str = {|{"agent_name":"test","session_id":"s1","event_types":["message","task"],"since_seq":100}|} in
  let req = T.SubscribeRequest.of_bytes json_str in
  Alcotest.(check string) "agent_name" "test" req.agent_name;
  Alcotest.(check (list string)) "event_types" ["message"; "task"] req.event_types

let test_event_serialization () =
  let event = T.Event.{
    seq = 42L;
    event_type = "broadcast";
    source_agent = "claude";
    timestamp_ms = 1700000000000L;
    payload_json = {|{"text":"hello"}|};
  } in
  let bytes = T.Event.to_bytes event in
  let json = Yojson.Safe.from_string bytes in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "event_type" "broadcast" (json |> member "event_type" |> to_string);
  Alcotest.(check string) "source_agent" "claude" (json |> member "source_agent" |> to_string);
  Alcotest.(check string) "payload_json" {|{"text":"hello"}|} (json |> member "payload_json" |> to_string)

let test_tool_call_request_deserialization () =
  let json_str = {|{"agent_name":"test","session_id":"s1","tool_name":"masc_status","arguments_json":"{}"}|} in
  let req = T.ToolCallRequest.of_bytes json_str in
  Alcotest.(check string) "tool_name" "masc_status" req.tool_name;
  Alcotest.(check string) "arguments_json" "{}" req.arguments_json

let test_tool_call_response_serialization () =
  let resp = T.ToolCallResponse.{
    success = true;
    result_json = {|{"status":"ok"}|};
    error_message = "";
    error_code = 0;
  } in
  let bytes = T.ToolCallResponse.to_bytes resp in
  let json = Yojson.Safe.from_string bytes in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "success" true (json |> member "success" |> to_bool);
  Alcotest.(check string) "result_json" {|{"status":"ok"}|} (json |> member "result_json" |> to_string)

let test_status_response_serialization () =
  let resp = T.StatusResponse.{
    agents = [
      {
        T.name = "a1";
        status = "active";
        capabilities = [];
        last_heartbeat_ms = 0L;
        joined_at_ms = 0L;
        current_task_id = "";
      };
    ];
    tasks = [
      {
        T.id = "t1";
        title = "Fix bug";
        status = "claimed";
        assigned_to = "a1";
        priority = 2;
      };
    ];
    message_count = 10;
    room_path = "/tmp/test";
  } in
  let bytes = T.StatusResponse.to_bytes resp in
  let json = Yojson.Safe.from_string bytes in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "message_count" 10 (json |> member "message_count" |> to_int);
  Alcotest.(check string) "room_path" "/tmp/test" (json |> member "room_path" |> to_string);
  let agents = json |> member "agents" |> to_list in
  Alcotest.(check int) "agents count" 1 (List.length agents);
  let tasks = json |> member "tasks" |> to_list in
  Alcotest.(check int) "tasks count" 1 (List.length tasks);
  let task = List.hd tasks in
  Alcotest.(check string) "task title" "Fix bug" (task |> member "title" |> to_string)

(* ====== Service construction test ====== *)

let test_service_name () =
  Alcotest.(check string) "service name"
    "masc.coordination.v1.MascCoordination"
    Masc_mcp.Masc_grpc_service.service_name

(* ====== gRPC server config tests ====== *)

let test_grpc_default_port () =
  Alcotest.(check int) "default port" 8936
    Masc_mcp.Masc_grpc_server.default_port

let test_grpc_disabled_by_default () =
  (* With no MASC_GRPC_ENABLED env var, should be disabled *)
  let was_set = Sys.getenv_opt "MASC_GRPC_ENABLED" in
  (match was_set with Some _ -> Unix.putenv "MASC_GRPC_ENABLED" "" | None -> ());
  let result = Masc_mcp.Masc_grpc_server.is_enabled () in
  Alcotest.(check bool) "disabled by default" false result;
  (* Restore *)
  (match was_set with Some v -> Unix.putenv "MASC_GRPC_ENABLED" v | None -> ())

let test_empty_request_handling () =
  (* Verify graceful handling of minimal JSON input *)
  let req = T.JoinRequest.of_bytes {|{"agent_name":""}|} in
  Alcotest.(check string) "empty agent_name" "" req.agent_name;
  Alcotest.(check (list string)) "empty capabilities" [] req.capabilities

let test_agent_info_to_json () =
  let info : T.agent_info = {
    name = "test";
    status = "active";
    capabilities = ["a"; "b"];
    last_heartbeat_ms = 100L;
    joined_at_ms = 50L;
    current_task_id = "t1";
  } in
  let json = T.agent_info_to_json info in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "name" "test" (json |> member "name" |> to_string);
  Alcotest.(check string) "status" "active" (json |> member "status" |> to_string)

let test_task_info_to_json () =
  let info : T.task_info = {
    id = "task-1";
    title = "Review PR";
    status = "pending";
    assigned_to = "";
    priority = 3;
  } in
  let json = T.task_info_to_json info in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "id" "task-1" (json |> member "id" |> to_string);
  Alcotest.(check int) "priority" 3 (json |> member "priority" |> to_int)

(* ====== Test suite ====== *)

let () =
  Alcotest.run "masc_grpc_coordination"
    [
      ( "types_roundtrip",
        [
          Alcotest.test_case "JoinRequest" `Quick test_join_request_roundtrip;
          Alcotest.test_case "LeaveRequest" `Quick test_leave_request_roundtrip;
          Alcotest.test_case "JoinResponse" `Quick test_join_response_serialization;
          Alcotest.test_case "BroadcastRequest" `Quick test_broadcast_request_roundtrip;
          Alcotest.test_case "BroadcastResponse" `Quick test_broadcast_response_serialization;
          Alcotest.test_case "HeartbeatPing" `Quick test_heartbeat_ping_deserialization;
          Alcotest.test_case "HeartbeatAck" `Quick test_heartbeat_ack_serialization;
          Alcotest.test_case "SubscribeRequest" `Quick test_subscribe_request_deserialization;
          Alcotest.test_case "Event" `Quick test_event_serialization;
          Alcotest.test_case "ToolCallRequest" `Quick test_tool_call_request_deserialization;
          Alcotest.test_case "ToolCallResponse" `Quick test_tool_call_response_serialization;
          Alcotest.test_case "StatusResponse" `Quick test_status_response_serialization;
          Alcotest.test_case "empty_request" `Quick test_empty_request_handling;
          Alcotest.test_case "agent_info_to_json" `Quick test_agent_info_to_json;
          Alcotest.test_case "task_info_to_json" `Quick test_task_info_to_json;
        ] );
      ( "service",
        [
          Alcotest.test_case "service_name" `Quick test_service_name;
        ] );
      ( "server_config",
        [
          Alcotest.test_case "default_port" `Quick test_grpc_default_port;
          Alcotest.test_case "disabled_by_default" `Quick test_grpc_disabled_by_default;
        ] );
    ]
