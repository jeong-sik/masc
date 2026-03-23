(** Transport Integration Tests

    Verifies cross-layer event flow without starting a full HTTP server:
    1. SSE broadcast → gRPC Subscribe stream (via external subscriber)
    2. SSE broadcast → WebSocket sessions (via external subscriber)
    3. WebRTC signaling full offer/answer/cleanup lifecycle
    4. Transport enum consistency across modules *)

module T = Masc_mcp.Masc_grpc_types
module Wrtc = Masc_mcp.Server_webrtc_transport

(* ============================================================
   1. gRPC Subscribe ← SSE Broadcast Integration
   ============================================================ *)

let test_grpc_subscribe_receives_sse_broadcast () =
  Eio_main.run (fun _env ->
    (* Simulate what handle_subscribe does: create a gRPC stream and
       register as SSE external subscriber *)
    let stream = Grpc_eio.Stream.create 16 in
    let sub_id = "integration-test-grpc" in
    let seq_counter = Atomic.make 1 in
    Masc_mcp.Sse.subscribe_external ~id:sub_id
      ~callback:(fun sse_event ->
        let seq = Int64.of_int (Atomic.fetch_and_add seq_counter 1) in
        let event = T.Event.{
          seq;
          event_type = "sse_broadcast";
          source_agent = "server";
          timestamp_ms = 0L;
          payload_json = sse_event;
        } in
        Grpc_eio.Stream.add stream (T.Event.to_bytes event));
    (* Stream should be empty before broadcast *)
    Alcotest.(check bool) "empty before broadcast"
      true (Grpc_eio.Stream.is_empty stream);
    (* Fire an SSE broadcast *)
    Masc_mcp.Sse.broadcast (`Assoc [("type", `String "task_update")]);
    (* The gRPC stream should now have an event *)
    Alcotest.(check bool) "not empty after broadcast"
      false (Grpc_eio.Stream.is_empty stream);
    (* Verify the event content *)
    let raw = Grpc_eio.Stream.take stream in
    let event = T.Event.of_bytes raw in
    Alcotest.(check string) "event_type" "sse_broadcast" event.event_type;
    Alcotest.(check bool) "payload contains data:"
      true (try let _ = Str.search_forward
        (Str.regexp_string "data:") event.payload_json 0 in true
            with Not_found -> false);
    (* Cleanup *)
    Masc_mcp.Sse.unsubscribe_external sub_id;
    Grpc_eio.Stream.close stream)

let test_grpc_subscribe_multiple_broadcasts () =
  Eio_main.run (fun _env ->
    let stream = Grpc_eio.Stream.create 16 in
    let sub_id = "integration-test-multi" in
    let seq_counter = Atomic.make 1 in
    Masc_mcp.Sse.subscribe_external ~id:sub_id
      ~callback:(fun sse_event ->
        let seq = Int64.of_int (Atomic.fetch_and_add seq_counter 1) in
        let event = T.Event.{
          seq; event_type = "sse_broadcast"; source_agent = "server";
          timestamp_ms = 0L; payload_json = sse_event;
        } in
        Grpc_eio.Stream.add stream (T.Event.to_bytes event));
    (* Fire 3 broadcasts *)
    Masc_mcp.Sse.broadcast (`Assoc [("n", `Int 1)]);
    Masc_mcp.Sse.broadcast (`Assoc [("n", `Int 2)]);
    Masc_mcp.Sse.broadcast (`Assoc [("n", `Int 3)]);
    (* Should have 3 events *)
    Alcotest.(check int) "3 events" 3 (Grpc_eio.Stream.length stream);
    (* Events should be in order *)
    let e1 = T.Event.of_bytes (Grpc_eio.Stream.take stream) in
    let e2 = T.Event.of_bytes (Grpc_eio.Stream.take stream) in
    let e3 = T.Event.of_bytes (Grpc_eio.Stream.take stream) in
    Alcotest.(check bool) "seq ordering" true
      (Int64.compare e1.seq e2.seq < 0
       && Int64.compare e2.seq e3.seq < 0);
    Masc_mcp.Sse.unsubscribe_external sub_id;
    Grpc_eio.Stream.close stream)

let test_grpc_unsubscribe_stops_events () =
  Eio_main.run (fun _env ->
    let stream = Grpc_eio.Stream.create 16 in
    let sub_id = "integration-test-unsub" in
    Masc_mcp.Sse.subscribe_external ~id:sub_id
      ~callback:(fun sse_event ->
        let event = T.Event.{
          seq = 1L; event_type = "sse_broadcast"; source_agent = "server";
          timestamp_ms = 0L; payload_json = sse_event;
        } in
        Grpc_eio.Stream.add stream (T.Event.to_bytes event));
    Masc_mcp.Sse.broadcast (`Assoc [("msg", `String "before")]);
    Alcotest.(check int) "1 event" 1 (Grpc_eio.Stream.length stream);
    (* Unsubscribe *)
    Masc_mcp.Sse.unsubscribe_external sub_id;
    Masc_mcp.Sse.broadcast (`Assoc [("msg", `String "after")]);
    (* Should still have only 1 event *)
    Alcotest.(check int) "still 1 event" 1 (Grpc_eio.Stream.length stream);
    Grpc_eio.Stream.close stream)

(* ============================================================
   2. WebSocket ← SSE Broadcast Integration
   ============================================================ *)

let test_ws_external_subscriber_receives_broadcast () =
  Eio_main.run (fun _env ->
    (* Simulate what server_mcp_transport_ws does: register as
       external subscriber and capture events *)
    let received = ref [] in
    let sub_id = "integration-test-ws" in
    Masc_mcp.Sse.subscribe_external ~id:sub_id
      ~callback:(fun sse_event -> received := sse_event :: !received);
    Masc_mcp.Sse.broadcast (`Assoc [("type", `String "ws_test")]);
    Alcotest.(check int) "ws received 1" 1 (List.length !received);
    let event = List.hd !received in
    Alcotest.(check bool) "contains ws_test data"
      true (try let _ = Str.search_forward
        (Str.regexp_string "ws_test") event 0 in true
            with Not_found -> false);
    Masc_mcp.Sse.unsubscribe_external sub_id)

(* ============================================================
   3. WebRTC Signaling Full Flow
   ============================================================ *)

let test_webrtc_full_signaling_flow () =
  Eio_main.run (fun _env ->
    (* Agent A creates an offer *)
    let offer_body =
      {|{"agent_name":"agent-a","ice_candidates":["candidate:1 udp 2130706431 192.168.1.1 54321 typ host"],"dtls_fingerprint":"sha-256:AA:BB:CC"}|}
    in
    let offer_result = Wrtc.handle_offer_request offer_body in
    Alcotest.(check bool) "offer ok" true (Result.is_ok offer_result);
    let offer_json = Yojson.Safe.from_string (Result.get_ok offer_result) in
    let offer_id = Yojson.Safe.Util.(member "offer_id" offer_json |> to_string) in
    (* Verify offer is pending *)
    Alcotest.(check bool) "offer pending"
      true (Wrtc.pending_offer_count () > 0);
    (* Agent B retrieves the offer *)
    let offer = Wrtc.get_offer offer_id in
    Alcotest.(check bool) "offer found" true (Option.is_some offer);
    let o = Option.get offer in
    Alcotest.(check string) "from agent-a" "agent-a" o.from_agent;
    Alcotest.(check int) "1 ICE candidate" 1 (List.length o.ice_candidates);
    (* Agent B accepts the offer *)
    let answer_body = Printf.sprintf
      {|{"offer_id":"%s","agent_name":"agent-b"}|} offer_id in
    let answer_result = Wrtc.handle_answer_request answer_body in
    Alcotest.(check bool) "answer ok" true (Result.is_ok answer_result);
    let answer_json = Yojson.Safe.from_string (Result.get_ok answer_result) in
    let peer_id = Yojson.Safe.Util.(member "peer_id" answer_json |> to_string) in
    let remote = Yojson.Safe.Util.(member "remote_agent" answer_json |> to_string) in
    Alcotest.(check string) "remote is agent-a" "agent-a" remote;
    (* Offer should be consumed *)
    Alcotest.(check bool) "offer consumed"
      true (Option.is_none (Wrtc.get_offer offer_id));
    (* Peer should be active *)
    Alcotest.(check bool) "peer active"
      true (Wrtc.active_peer_count () > 0);
    (* Mark connected and cleanup *)
    Wrtc.mark_connected peer_id;
    Wrtc.remove_peer peer_id;
    Alcotest.(check int) "no active peers after cleanup"
      0 (Wrtc.active_peer_count ()))

(* ============================================================
   4. Transport Enum Consistency
   ============================================================ *)

let test_all_protocol_variants_roundtrip () =
  let module Tr = Masc_mcp.Transport in
  let all = [Tr.JsonRpc; Tr.Rest; Tr.Grpc; Tr.Sse; Tr.Ws; Tr.Webrtc] in
  List.iter (fun p ->
    let s = Tr.protocol_to_string p in
    match Tr.protocol_of_string s with
    | Some p' ->
      Alcotest.(check bool) (Printf.sprintf "%s roundtrip" s)
        true (p = p')
    | None ->
      Alcotest.fail (Printf.sprintf "roundtrip failed for %s" s)
  ) all

let test_agent_transport_all_variants () =
  let module At = Masc_mcp.Masc_grpc_transport in
  let all = [At.Http; At.Grpc; At.Ws; At.Webrtc; At.Local] in
  List.iter (fun t ->
    let s = At.to_string t in
    Alcotest.(check bool) (Printf.sprintf "%s non-empty" s)
      true (String.length s > 0)
  ) all

let () =
  Alcotest.run "Transport Integration" [
    ("grpc_subscribe_sse", [
      Alcotest.test_case "broadcast reaches gRPC stream" `Quick
        test_grpc_subscribe_receives_sse_broadcast;
      Alcotest.test_case "multiple broadcasts in order" `Quick
        test_grpc_subscribe_multiple_broadcasts;
      Alcotest.test_case "unsubscribe stops events" `Quick
        test_grpc_unsubscribe_stops_events;
    ]);
    ("ws_sse", [
      Alcotest.test_case "broadcast reaches WS subscriber" `Quick
        test_ws_external_subscriber_receives_broadcast;
    ]);
    ("webrtc_signaling", [
      Alcotest.test_case "full offer/answer/cleanup flow" `Quick
        test_webrtc_full_signaling_flow;
    ]);
    ("transport_enum", [
      Alcotest.test_case "all protocol variants roundtrip" `Quick
        test_all_protocol_variants_roundtrip;
      Alcotest.test_case "all agent transport variants" `Quick
        test_agent_transport_all_variants;
    ]);
  ]
