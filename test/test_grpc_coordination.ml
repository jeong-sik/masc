(** Tests for MASC gRPC Coordination Service.

    Tests the types, service construction, and handler logic without
    requiring a running gRPC server or network connections.

    Wire format: protobuf binary (not JSON). Tests verify roundtrip
    serialization/deserialization via of_bytes/to_bytes. *)

module T = Masc_mcp.Masc_grpc_types

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () -> f dir)

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

let test_join_response_roundtrip () =
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
  let decoded = T.JoinResponse.of_bytes bytes in
  Alcotest.(check bool) "success" true decoded.success;
  Alcotest.(check string) "message" "Joined room" decoded.message;
  Alcotest.(check string) "session_id" "grpc-test-001" decoded.session_id;
  Alcotest.(check int) "active_agents count" 1 (List.length decoded.active_agents);
  let agent = List.hd decoded.active_agents in
  Alcotest.(check string) "agent name" "claude-swift-fox" agent.T.name;
  Alcotest.(check string) "agent status" "active" agent.T.status;
  Alcotest.(check (list string)) "agent capabilities" ["code"] agent.T.capabilities

let test_broadcast_request_roundtrip () =
  let req = T.BroadcastRequest.{
    agent_name = "codex-running-bear";
    message = "CI fixed, ready to merge";
    mentions = ["claude"; "gemini"];
  } in
  let bytes = T.BroadcastRequest.to_bytes req in
  let decoded = T.BroadcastRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" req.agent_name decoded.agent_name;
  Alcotest.(check string) "message" req.message decoded.message;
  Alcotest.(check (list string)) "mentions" req.mentions decoded.mentions

let test_broadcast_response_roundtrip () =
  let resp = T.BroadcastResponse.{ success = true; seq = 42L } in
  let bytes = T.BroadcastResponse.to_bytes resp in
  let decoded = T.BroadcastResponse.of_bytes bytes in
  Alcotest.(check bool) "success" true decoded.success;
  Alcotest.(check int64) "seq" 42L decoded.seq

let test_heartbeat_ping_roundtrip () =
  let ping = T.HeartbeatPing.{
    agent_name = "test-agent";
    session_id = "sess-1";
    timestamp_ms = 1700000000000L;
    current_task_id = "task-42";
  } in
  let bytes = T.HeartbeatPing.to_bytes ping in
  let decoded = T.HeartbeatPing.of_bytes bytes in
  Alcotest.(check string) "agent_name" "test-agent" decoded.agent_name;
  Alcotest.(check string) "session_id" "sess-1" decoded.session_id;
  Alcotest.(check int64) "timestamp_ms" 1700000000000L decoded.timestamp_ms;
  Alcotest.(check string) "current_task_id" "task-42" decoded.current_task_id

let test_heartbeat_ack_roundtrip () =
  let ack = T.HeartbeatAck.{
    timestamp_ms = 1700000000001L;
    active_agent_count = 5;
    pending_task_count = 3;
    directives = ["rebalance"];
  } in
  let bytes = T.HeartbeatAck.to_bytes ack in
  let decoded = T.HeartbeatAck.of_bytes bytes in
  Alcotest.(check int64) "timestamp_ms" 1700000000001L decoded.timestamp_ms;
  Alcotest.(check int) "active_agent_count" 5 decoded.active_agent_count;
  Alcotest.(check int) "pending_task_count" 3 decoded.pending_task_count;
  Alcotest.(check (list string)) "directives" ["rebalance"] decoded.directives

let test_subscribe_request_roundtrip () =
  let req = T.SubscribeRequest.{
    agent_name = "test";
    session_id = "s1";
    event_types = ["message"; "task"];
    since_seq = 100L;
  } in
  let bytes = Masc_mcp.Masc_grpc_types.SubscribeRequest_serde.to_bytes req in
  let decoded = T.SubscribeRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" "test" decoded.agent_name;
  Alcotest.(check (list string)) "event_types" ["message"; "task"] decoded.event_types;
  Alcotest.(check int64) "since_seq" 100L decoded.since_seq

let test_event_roundtrip () =
  let event = T.Event.{
    seq = 42L;
    event_type = "broadcast";
    source_agent = "claude";
    timestamp_ms = 1700000000000L;
    payload_json = {|{"text":"hello"}|};
  } in
  let bytes = T.Event.to_bytes event in
  let decoded = T.Event.of_bytes bytes in
  Alcotest.(check int64) "seq" 42L decoded.seq;
  Alcotest.(check string) "event_type" "broadcast" decoded.event_type;
  Alcotest.(check string) "source_agent" "claude" decoded.source_agent;
  Alcotest.(check int64) "timestamp_ms" 1700000000000L decoded.timestamp_ms;
  Alcotest.(check string) "payload_json" {|{"text":"hello"}|} decoded.payload_json

let test_tool_call_request_roundtrip () =
  let req = T.ToolCallRequest.{
    agent_name = "test";
    session_id = "s1";
    tool_name = "masc_status";
    arguments_json = "{}";
  } in
  let bytes = T.ToolCallRequest.to_bytes req in
  let decoded = T.ToolCallRequest.of_bytes bytes in
  Alcotest.(check string) "agent_name" "test" decoded.agent_name;
  Alcotest.(check string) "tool_name" "masc_status" decoded.tool_name;
  Alcotest.(check string) "arguments_json" "{}" decoded.arguments_json

let test_tool_call_response_roundtrip () =
  let resp = T.ToolCallResponse.{
    success = true;
    result_json = {|{"status":"ok"}|};
    error_message = "";
    error_code = 0;
  } in
  let bytes = T.ToolCallResponse.to_bytes resp in
  let decoded = T.ToolCallResponse.of_bytes bytes in
  Alcotest.(check bool) "success" true decoded.success;
  Alcotest.(check string) "result_json" {|{"status":"ok"}|} decoded.result_json;
  Alcotest.(check string) "error_message" "" decoded.error_message;
  Alcotest.(check int) "error_code" 0 decoded.error_code

let test_status_response_roundtrip () =
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
  let decoded = T.StatusResponse.of_bytes bytes in
  Alcotest.(check int) "message_count" 10 decoded.message_count;
  Alcotest.(check string) "room_path" "/tmp/test" decoded.room_path;
  Alcotest.(check int) "agents count" 1 (List.length decoded.agents);
  Alcotest.(check int) "tasks count" 1 (List.length decoded.tasks);
  let task = List.hd decoded.tasks in
  Alcotest.(check string) "task title" "Fix bug" task.T.title;
  Alcotest.(check string) "task assigned_to" "a1" task.T.assigned_to;
  Alcotest.(check int) "task priority" 2 task.T.priority

(* ====== Service construction test ====== *)

let test_service_name () =
  Alcotest.(check string) "service name"
    "masc.coordination.v1.MascCoordination"
    Masc_mcp.Masc_grpc_service.service_name

(* ====== gRPC server config tests ====== *)

let test_grpc_default_port () =
  Alcotest.(check int) "default port" 8936
    Masc_mcp.Masc_grpc_server.default_port

let test_grpc_default_on_enablement () =
  (* With no MASC_GRPC_ENABLED env var, gRPC stays enabled. *)
  let was_set = Sys.getenv_opt "MASC_GRPC_ENABLED" in
  (match was_set with Some _ -> Unix.putenv "MASC_GRPC_ENABLED" "" | None -> ());
  let result = Masc_mcp.Masc_grpc_server.is_enabled () in
  Alcotest.(check bool) "enabled by default" true result;
  (* Verify explicit enable still works. *)
  Unix.putenv "MASC_GRPC_ENABLED" "1";
  let enabled = Masc_mcp.Masc_grpc_server.is_enabled () in
  Alcotest.(check bool) "enabled via env" true enabled;
  (* Verify explicit disable still works. *)
  Unix.putenv "MASC_GRPC_ENABLED" "0";
  let disabled = Masc_mcp.Masc_grpc_server.is_enabled () in
  Alcotest.(check bool) "disabled via env" false disabled;
  (* Restore *)
  (match was_set with Some v -> Unix.putenv "MASC_GRPC_ENABLED" v | None -> ())

let test_grpc_server_registers_health_service () =
  let was_storage = Sys.getenv_opt "MASC_STORAGE_TYPE" in
  Unix.putenv "MASC_STORAGE_TYPE" "filesystem";
  Fun.protect
    ~finally:(fun () ->
      match was_storage with
      | Some value -> Unix.putenv "MASC_STORAGE_TYPE" value
      | None -> Unix.putenv "MASC_STORAGE_TYPE" "")
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      with_temp_dir "masc-grpc-health" (fun dir ->
          let room_config = Room_utils.default_config dir in
          let server =
            Masc_mcp.Masc_grpc_server.create_server
              ~port:Masc_mcp.Masc_grpc_server.default_port
              ~room_config
              ~tool_dispatcher:(fun _tool _payload -> Ok "{}")
          in
          let services = Grpc_eio.Server.list_services server in
          Alcotest.(check bool) "coordination service registered" true
            (List.mem Masc_mcp.Masc_grpc_service.service_name services);
          Alcotest.(check bool) "reflection v1 service registered" true
            (List.mem "grpc.reflection.v1.ServerReflection" services);
          Alcotest.(check bool) "reflection v1alpha service registered" true
            (List.mem "grpc.reflection.v1alpha.ServerReflection" services);
          Alcotest.(check bool) "health service registered" true
            (List.mem "grpc.health.v1.Health" services)))

let test_get_status_projects_backlog_tasks () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-grpc-status" (fun dir ->
      let room_config = Room_utils.default_config dir in
      ignore (Masc_mcp.Room.init room_config ~agent_name:(Some "alpha"));
      ignore
        (Masc_mcp.Room.add_task room_config
           ~title:"Fix stale projection" ~priority:1
           ~description:"Use backlog SSOT for gRPC status");
      ignore (Masc_mcp.Room.claim_next room_config ~agent_name:"alpha");
      let service =
        Masc_mcp.Masc_grpc_service.create_service
          ~room_config
          ~tool_dispatcher:(fun _tool _payload -> Ok "{}")
      in
      match Grpc_eio.Service.get_method service "GetStatus" with
      | Some { handler = `Unary handler; _ } ->
          let resp = T.StatusResponse.of_bytes (handler "") in
          Alcotest.(check int) "tasks count" 1 (List.length resp.tasks);
          let task = List.hd resp.tasks in
          Alcotest.(check string) "task id" "task-001" task.T.id;
          Alcotest.(check string) "task title" "Fix stale projection" task.T.title;
          Alcotest.(check string) "task status" "claimed" task.T.status;
          Alcotest.(check string) "task assignee" "alpha" task.T.assigned_to;
          Alcotest.(check int) "task priority" 1 task.T.priority
      | _ -> Alcotest.fail "GetStatus unary handler missing")

let test_empty_request_handling () =
  (* Verify graceful handling of empty protobuf message (all defaults). *)
  let bytes = T.JoinRequest.to_bytes {
    agent_name = "";
    capabilities = [];
    metadata = [];
  } in
  let req = T.JoinRequest.of_bytes bytes in
  Alcotest.(check string) "empty agent_name" "" req.agent_name;
  Alcotest.(check (list string)) "empty capabilities" [] req.capabilities

let test_protobuf_binary_format () =
  (* Verify that serialized output is protobuf binary, not JSON. *)
  let req = T.JoinRequest.{
    agent_name = "test";
    capabilities = [];
    metadata = [];
  } in
  let bytes = T.JoinRequest.to_bytes req in
  (* Protobuf binary does not start with '{' like JSON. *)
  Alcotest.(check bool) "not JSON"
    true
    (String.length bytes = 0 || bytes.[0] <> '{')

(* ====== Test suite ====== *)

let () =
  Alcotest.run "masc_grpc_coordination"
    [
      ( "types_roundtrip",
        [
          Alcotest.test_case "JoinRequest" `Quick test_join_request_roundtrip;
          Alcotest.test_case "LeaveRequest" `Quick test_leave_request_roundtrip;
          Alcotest.test_case "JoinResponse" `Quick test_join_response_roundtrip;
          Alcotest.test_case "BroadcastRequest" `Quick test_broadcast_request_roundtrip;
          Alcotest.test_case "BroadcastResponse" `Quick test_broadcast_response_roundtrip;
          Alcotest.test_case "HeartbeatPing" `Quick test_heartbeat_ping_roundtrip;
          Alcotest.test_case "HeartbeatAck" `Quick test_heartbeat_ack_roundtrip;
          Alcotest.test_case "SubscribeRequest" `Quick test_subscribe_request_roundtrip;
          Alcotest.test_case "Event" `Quick test_event_roundtrip;
          Alcotest.test_case "ToolCallRequest" `Quick test_tool_call_request_roundtrip;
          Alcotest.test_case "ToolCallResponse" `Quick test_tool_call_response_roundtrip;
          Alcotest.test_case "StatusResponse" `Quick test_status_response_roundtrip;
          Alcotest.test_case "empty_request" `Quick test_empty_request_handling;
          Alcotest.test_case "protobuf_binary" `Quick test_protobuf_binary_format;
        ] );
      ( "service",
        [
          Alcotest.test_case "service_name" `Quick test_service_name;
          Alcotest.test_case "get_status_projects_backlog_tasks" `Quick
            test_get_status_projects_backlog_tasks;
        ] );
      ( "server_config",
        [
          Alcotest.test_case "default_port" `Quick test_grpc_default_port;
          Alcotest.test_case "default_on_enablement" `Quick test_grpc_default_on_enablement;
          Alcotest.test_case "registers_health_service" `Quick
            test_grpc_server_registers_health_service;
        ] );
    ]
