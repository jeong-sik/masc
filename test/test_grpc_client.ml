(** Tests for MASC gRPC Client types and transport abstraction.

    Tests client-side serialization, response decoding, and transport
    selection logic without requiring a running gRPC server. *)

module T = Masc_grpc_types

(* ====== Client-side type round-trip tests ====== *)

let test_status_request_roundtrip () =
  let request = T.StatusRequest.{ auth_token = "status-token" } in
  let decoded = T.StatusRequest.of_bytes (T.StatusRequest.to_bytes request) in
  Alcotest.(check string) "auth token" request.auth_token decoded.auth_token
;;

let test_status_agents_response_roundtrip () =
  let resp =
    T.StatusResponse.
      { agents =
          [ { T.name = "codex"
            ; status = "active"
            ; capabilities = [ "code" ]
            ; last_seen_ms = 1000L
            ; session_bound_at_ms = 500L
            ; current_task_id = "T-001"
            }
          ]
      ; tasks = []
      ; message_count = 0
      ; workspace_path = "/tmp/grpc-client"
      }
  in
  let bytes = T.StatusResponse.to_bytes resp in
  let decoded = T.StatusResponse.of_bytes bytes in
  Alcotest.(check int) "agent count" 1 (List.length decoded.agents);
  let agent = List.hd decoded.agents in
  Alcotest.(check string) "agent name" "codex" agent.T.name;
  Alcotest.(check string) "agent task" "T-001" agent.T.current_task_id

let test_tool_call_error_response_roundtrip () =
  let resp =
    T.ToolCallResponse.
      { success = false
      ; result_json = "{}"
      ; error_message = "tool failed"
      ; error_code = 500
      }
  in
  let bytes = T.ToolCallResponse.to_bytes resp in
  let decoded = T.ToolCallResponse.of_bytes bytes in
  Alcotest.(check bool) "success" false decoded.success;
  Alcotest.(check string) "message" "tool failed" decoded.error_message

let test_heartbeat_ping_roundtrip () =
  let ping = T.HeartbeatPing.{
    agent_name = "keeper-sangsu";
    session_id = "sess-42";
    timestamp_ms = 1700000000000L;
    current_task_id = "T-99";
    auth_token = "heartbeat-token";
  } in
  let bytes = T.HeartbeatPing.to_bytes ping in
  let decoded = T.HeartbeatPing.of_bytes bytes in
  Alcotest.(check string) "agent_name" ping.agent_name decoded.agent_name;
  Alcotest.(check string) "session_id" ping.session_id decoded.session_id;
  Alcotest.(check int64) "timestamp_ms" ping.timestamp_ms decoded.timestamp_ms;
  Alcotest.(check string) "current_task_id" ping.current_task_id decoded.current_task_id

let test_heartbeat_ack_roundtrip () =
  let ack = T.HeartbeatAck.{
    timestamp_ms = 1700000001000L;
    active_agent_count = 5;
    pending_task_count = 3;
  } in
  let bytes = T.HeartbeatAck.to_bytes ack in
  let decoded = T.HeartbeatAck.of_bytes bytes in
  Alcotest.(check int64) "timestamp_ms" ack.timestamp_ms decoded.timestamp_ms;
  Alcotest.(check int) "agent_count" 5 decoded.active_agent_count;
  Alcotest.(check int) "task_count" 3 decoded.pending_task_count

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
  Alcotest.(check string) "result" resp.result_json decoded.result_json;
  Alcotest.(check int) "error_code" 0 decoded.error_code

let test_tool_call_request_roundtrip () =
  let req = T.ToolCallRequest.{
    agent_name = "claude";
    session_id = "s-1";
    tool_name = "masc_status";
    arguments_json = {|{"workspace":"main"}|};
    auth_token = "tool-token";
  } in
  let bytes = T.ToolCallRequest.to_bytes req in
  let decoded = T.ToolCallRequest.of_bytes bytes in
  Alcotest.(check string) "agent" req.agent_name decoded.agent_name;
  Alcotest.(check string) "tool" req.tool_name decoded.tool_name;
  Alcotest.(check string) "args" req.arguments_json decoded.arguments_json

let test_broadcast_request_roundtrip () =
  let req = T.BroadcastRequest.{
    agent_name = "gemini";
    message = "starting work";
    mentions = ["claude"; "codex"];
    auth_token = "broadcast-token";
  } in
  let bytes = T.BroadcastRequest.to_bytes req in
  let decoded = T.BroadcastRequest.of_bytes bytes in
  Alcotest.(check string) "agent" req.agent_name decoded.agent_name;
  Alcotest.(check string) "message" req.message decoded.message;
  Alcotest.(check (list string)) "mentions" req.mentions decoded.mentions

let test_broadcast_response_roundtrip () =
  let resp = T.BroadcastResponse.{ success = true; seq = 42L } in
  let bytes = T.BroadcastResponse.to_bytes resp in
  let decoded = T.BroadcastResponse.of_bytes bytes in
  Alcotest.(check bool) "success" true decoded.success;
  Alcotest.(check int64) "seq" 42L decoded.seq

let test_event_roundtrip () =
  let event = T.Event.{
    seq = 100L;
    event_type = "message";
    source_agent = "codex";
    timestamp_ms = 1700000000000L;
    payload_json = {|{"text":"hello"}|};
  } in
  let bytes = T.Event.to_bytes event in
  let decoded = T.Event.of_bytes bytes in
  Alcotest.(check int64) "seq" 100L decoded.seq;
  Alcotest.(check string) "type" "message" decoded.event_type;
  Alcotest.(check string) "source" "codex" decoded.source_agent;
  Alcotest.(check string) "payload" event.payload_json decoded.payload_json

let test_status_response_roundtrip () =
  let resp = T.StatusResponse.{
    agents = [{
      T.name = "claude"; status = "active";
      capabilities = ["code"; "review"];
      last_seen_ms = 1000L; session_bound_at_ms = 500L;
      current_task_id = "";
    }];
    tasks = [{
      T.id = "T-1"; title = "Fix bug"; status = "claimed";
      assigned_to = "claude"; priority = 2;
    }];
    message_count = 10;
    workspace_path = "/tmp/test-workspace";
  } in
  let bytes = T.StatusResponse.to_bytes resp in
  let decoded = T.StatusResponse.of_bytes bytes in
  Alcotest.(check int) "agents" 1 (List.length decoded.agents);
  Alcotest.(check int) "tasks" 1 (List.length decoded.tasks);
  Alcotest.(check int) "msg_count" 10 decoded.message_count;
  Alcotest.(check string) "workspace_path" "/tmp/test-workspace" decoded.workspace_path;
  let task = List.hd decoded.tasks in
  Alcotest.(check string) "task_id" "T-1" task.T.id;
  Alcotest.(check int) "priority" 2 task.T.priority

(* ====== Transport selection tests ====== *)

let test_transport_from_env_default () =
  (* When MASC_AGENT_TRANSPORT is not set, should return Local *)
  let saved = Sys.getenv_opt "MASC_AGENT_TRANSPORT" in
  Unix.putenv "MASC_AGENT_TRANSPORT" "";
  let t = Masc_grpc_transport.from_env () in
  (match saved with
   | Some v -> Unix.putenv "MASC_AGENT_TRANSPORT" v
   | None -> Unix.putenv "MASC_AGENT_TRANSPORT" "");
  Alcotest.(check string) "default is local"
    "local" (Masc_grpc_transport.to_string t)

let test_transport_to_string () =
  Alcotest.(check string) "http"
    "http" (Masc_grpc_transport.to_string Masc_grpc_transport.Http);
  Alcotest.(check string) "grpc"
    "grpc" (Masc_grpc_transport.to_string Masc_grpc_transport.Grpc);
  Alcotest.(check string) "local"
    "local" (Masc_grpc_transport.to_string Masc_grpc_transport.Local)

let test_subscribe_request_serde () =
  let req : T.SubscribeRequest.t = {
    agent_name = "test-agent";
    session_id = "sess-1";
    event_types = ["message"; "task"];
    since_seq = 0L;
    auth_token = "subscribe-token";
  } in
  let bytes = T.SubscribeRequest_serde.to_bytes req in
  let decoded = T.SubscribeRequest.of_bytes bytes in
  Alcotest.(check string) "agent" req.agent_name decoded.agent_name;
  Alcotest.(check string) "session" req.session_id decoded.session_id;
  Alcotest.(check (list string)) "types" req.event_types decoded.event_types;
  Alcotest.(check int64) "seq" req.since_seq decoded.since_seq

(* ====== Test runner ====== *)

let () =
  Alcotest.run "MASC gRPC Client" [
    "client-types", [
      Alcotest.test_case "status request roundtrip" `Quick test_status_request_roundtrip;
      Alcotest.test_case "status agents response roundtrip" `Quick test_status_agents_response_roundtrip;
      Alcotest.test_case "tool call error response roundtrip" `Quick test_tool_call_error_response_roundtrip;
      Alcotest.test_case "heartbeat ping roundtrip" `Quick test_heartbeat_ping_roundtrip;
      Alcotest.test_case "heartbeat ack roundtrip" `Quick test_heartbeat_ack_roundtrip;
      Alcotest.test_case "tool call response roundtrip" `Quick test_tool_call_response_roundtrip;
      Alcotest.test_case "tool call request roundtrip" `Quick test_tool_call_request_roundtrip;
      Alcotest.test_case "broadcast request roundtrip" `Quick test_broadcast_request_roundtrip;
      Alcotest.test_case "broadcast response roundtrip" `Quick test_broadcast_response_roundtrip;
      Alcotest.test_case "event roundtrip" `Quick test_event_roundtrip;
      Alcotest.test_case "status response roundtrip" `Quick test_status_response_roundtrip;
      Alcotest.test_case "subscribe request serde" `Quick test_subscribe_request_serde;
    ];
    "transport", [
      Alcotest.test_case "default is local" `Quick test_transport_from_env_default;
      Alcotest.test_case "to_string variants" `Quick test_transport_to_string;
    ];
  ]
