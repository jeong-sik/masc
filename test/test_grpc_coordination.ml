(** Tests for MASC gRPC Coordination Service.

    Tests the types, service construction, and handler logic without
    requiring a running gRPC server or network connections.

    Wire format: protobuf binary (not JSON). Tests verify roundtrip
    serialization/deserialization via of_bytes/to_bytes. *)

module T = Masc_mcp.Masc_grpc_types

let grpc_health_service = "grpc.health.v1.Health"

let encode_health_check_request ~service =
  if service = ""
  then ""
  else
    let len = String.length service in
    String.make 1 (Char.chr ((1 lsl 3) lor 2))
    ^ String.make 1 (Char.chr len)
    ^ service

let decode_health_check_status bytes =
  if String.length bytes < 2 then
    Alcotest.failf "health response too short: %d bytes" (String.length bytes);
  let tag = Char.code bytes.[0] in
  let field_num = tag lsr 3 in
  let wire_type = tag land 0x7 in
  Alcotest.(check int) "health field number" 1 field_num;
  Alcotest.(check int) "health wire type" 0 wire_type;
  Char.code bytes.[1]

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

let test_grpc_enabled_by_default () =
  (* With no MASC_GRPC_ENABLED env var, should be enabled *)
  let was_set = Sys.getenv_opt "MASC_GRPC_ENABLED" in
  (match was_set with Some _ -> Unix.putenv "MASC_GRPC_ENABLED" "" | None -> ());
  let result = Masc_mcp.Masc_grpc_server.is_enabled () in
  Alcotest.(check bool) "enabled by default" true result;
  (* Verify opt-out works *)
  Unix.putenv "MASC_GRPC_ENABLED" "0";
  let disabled = Masc_mcp.Masc_grpc_server.is_enabled () in
  Alcotest.(check bool) "disabled via env" false disabled;
  (* Restore *)
  (match was_set with Some v -> Unix.putenv "MASC_GRPC_ENABLED" v | None -> ())

let test_grpc_health_service_reports_serving () =
  let base_path = Filename.temp_dir "masc-grpc-health-" "" in
  Eio_main.run (fun env ->
    let room_config =
      Masc_mcp.Room.default_config base_path
      |> Masc_mcp.Room.config_with_resolved_scope
    in
    let server =
      Masc_mcp.Masc_grpc_server.create_server
        ~port:0
        ~room_config
        ~tool_dispatcher:(fun _tool_name _arguments_json -> Ok "{}")
        ()
    in
    Alcotest.(check bool) "health service registered"
      true (List.mem grpc_health_service (Grpc_eio.Server.list_services server));
    Alcotest.(check bool) "coordination service registered"
      true
      (List.mem Masc_mcp.Masc_grpc_service.service_name
         (Grpc_eio.Server.list_services server));
    let request_data =
      encode_health_check_request
        ~service:Masc_mcp.Masc_grpc_service.service_name
    in
    let request_body =
      match Grpc_core.Message.encode ~codec:Grpc_core.Codec.identity request_data with
      | Ok body -> body
      | Error err -> Alcotest.failf "health request encode failed: %s" err
    in
    match
      Grpc_eio.Server.handle_request
        server
        ~clock:(Eio.Stdenv.clock env)
        ~path:"/grpc.health.v1.Health/Check"
        ~metadata:[]
        ~body:request_body
        ~request_codec:Grpc_core.Codec.identity
        ~response_codec:Grpc_core.Codec.identity
    with
    | Error status ->
      Alcotest.failf "health check failed: %s"
        (Grpc_core.Status.to_string status)
    | Ok (response_body, trailers, _codec) ->
      Alcotest.(check bool) "grpc-status=0"
        true (List.mem ("grpc-status", "0") trailers);
      let response_data =
        match Grpc_core.Message.decode ~codec:Grpc_core.Codec.identity response_body with
        | Ok body -> body
        | Error err -> Alcotest.failf "health response decode failed: %s" err
      in
      let status = decode_health_check_status response_data in
      Alcotest.(check int) "service reports SERVING" 1 status)

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
        ] );
      ( "server_config",
        [
          Alcotest.test_case "default_port" `Quick test_grpc_default_port;
          Alcotest.test_case "enabled_by_default" `Quick test_grpc_enabled_by_default;
          Alcotest.test_case "health_service_reports_serving" `Quick test_grpc_health_service_reports_serving;
        ] );
    ]
