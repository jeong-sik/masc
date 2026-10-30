(** Transport Integration Tests

    Verifies cross-layer event flow without starting a full HTTP server:
    1. SSE broadcast → gRPC Subscribe stream (via external subscriber)
    2. SSE broadcast → WebSocket sessions (via external subscriber)
    3. Dead external subscribers are dropped on the next broadcast
    4. Transport enum consistency across modules *)

module T = Masc_grpc_types

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
    Masc.Sse.subscribe_external ~id:sub_id
      ~callback:(fun (ev : Masc.Sse.external_event) ->
        let sse_event = ev.Masc.Sse.ext_frame in
        let seq = Int64.of_int (Atomic.fetch_and_add seq_counter 1) in
        let event = T.Event.{
          seq;
          event_type = "sse_broadcast";
          source_agent = "server";
          timestamp_ms = 0L;
          payload_json = sse_event;
        } in
        Grpc_eio.Stream.add stream (T.Event.to_bytes event)) ();
    (* Stream should be empty before broadcast *)
    Alcotest.(check bool) "empty before broadcast"
      true (Grpc_eio.Stream.is_empty stream);
    (* Fire an SSE broadcast *)
    Masc.Sse.broadcast (`Assoc [("type", `String "task_update")]);
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
    Masc.Sse.unsubscribe_external sub_id;
    Grpc_eio.Stream.close stream)

let test_grpc_subscribe_multiple_broadcasts () =
  Eio_main.run (fun _env ->
    let stream = Grpc_eio.Stream.create 16 in
    let sub_id = "integration-test-multi" in
    let seq_counter = Atomic.make 1 in
    Masc.Sse.subscribe_external ~id:sub_id
      ~callback:(fun (ev : Masc.Sse.external_event) ->
        let sse_event = ev.Masc.Sse.ext_frame in
        let seq = Int64.of_int (Atomic.fetch_and_add seq_counter 1) in
        let event = T.Event.{
          seq; event_type = "sse_broadcast"; source_agent = "server";
          timestamp_ms = 0L; payload_json = sse_event;
        } in
        Grpc_eio.Stream.add stream (T.Event.to_bytes event)) ();
    (* Fire 3 broadcasts *)
    Masc.Sse.broadcast (`Assoc [("n", `Int 1)]);
    Masc.Sse.broadcast (`Assoc [("n", `Int 2)]);
    Masc.Sse.broadcast (`Assoc [("n", `Int 3)]);
    (* Should have 3 events *)
    Alcotest.(check int) "3 events" 3 (Grpc_eio.Stream.length stream);
    (* Events should be in order *)
    let e1 = T.Event.of_bytes (Grpc_eio.Stream.take stream) in
    let e2 = T.Event.of_bytes (Grpc_eio.Stream.take stream) in
    let e3 = T.Event.of_bytes (Grpc_eio.Stream.take stream) in
    Alcotest.(check bool) "seq ordering" true
      (Int64.compare e1.seq e2.seq < 0
       && Int64.compare e2.seq e3.seq < 0);
    Masc.Sse.unsubscribe_external sub_id;
    Grpc_eio.Stream.close stream)

let test_grpc_unsubscribe_stops_events () =
  Eio_main.run (fun _env ->
    let stream = Grpc_eio.Stream.create 16 in
    let sub_id = "integration-test-unsub" in
    Masc.Sse.subscribe_external ~id:sub_id
      ~callback:(fun (ev : Masc.Sse.external_event) ->
        let sse_event = ev.Masc.Sse.ext_frame in
        let event = T.Event.{
          seq = 1L; event_type = "sse_broadcast"; source_agent = "server";
          timestamp_ms = 0L; payload_json = sse_event;
        } in
        Grpc_eio.Stream.add stream (T.Event.to_bytes event)) ();
    Masc.Sse.broadcast (`Assoc [("msg", `String "before")]);
    Alcotest.(check int) "1 event" 1 (Grpc_eio.Stream.length stream);
    (* Unsubscribe *)
    Masc.Sse.unsubscribe_external sub_id;
    Masc.Sse.broadcast (`Assoc [("msg", `String "after")]);
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
    Masc.Sse.subscribe_external ~id:sub_id
      ~callback:(fun (ev : Masc.Sse.external_event) ->
        received := ev.Masc.Sse.ext_frame :: !received) ();
    Masc.Sse.broadcast (`Assoc [("type", `String "ws_test")]);
    Alcotest.(check int) "ws received 1" 1 (List.length !received);
    let event = List.hd !received in
    Alcotest.(check bool) "contains ws_test data"
      true (try let _ = Str.search_forward
        (Str.regexp_string "ws_test") event 0 in true
            with Not_found -> false);
    Masc.Sse.unsubscribe_external sub_id)

(* Descendant of the #10194 regression test.  That bug was the WS transport
   feeding a whole SSE-formatted string into [Yojson.Safe.from_string], which
   silently returned None in production while unit tests passed because they
   fed pure JSON.  The frame parse is gone — the bus now hands the broadcast
   value over directly — so the wire-format trap it guarded cannot recur.

   What still needs guarding is the property that test was really about: what a
   WS session derives from a *real* [Sse.broadcast] must be the right dashboard
   event.  This fires an actual broadcast and asserts on the derivation, so a
   future change to either side of the bus contract fails here. *)
let test_ws_derives_dashboard_event_from_real_broadcast () =
  Eio_main.run (fun _env ->
    let sub_id = "integration-test-ws-derive" in
    let captured = ref None in
    Masc.Sse.subscribe_external ~id:sub_id
      ~callback:(fun (ev : Masc.Sse.external_event) -> captured := Some ev)
      ();
    Masc.Sse.broadcast
      (`Assoc [
        ("type", `String "execution_snapshot");
        ("payload", `Assoc [("keepers", `Int 4)]);
      ]);
    Masc.Sse.unsubscribe_external sub_id;
    match !captured with
    | None -> Alcotest.fail "callback never fired"
    | Some ev ->
        (* The frame still reaches subscribers that forward it verbatim. *)
        Alcotest.(check bool) "frame is still carried"
          true
          (String.length ev.Masc.Sse.ext_frame > 0);
        match Server_mcp_transport_ws.dashboard_event_of_external ev with
        | None ->
            Alcotest.fail
              "derivation returned None on a real broadcast"
        | Some parsed ->
            Alcotest.(check string) "event_type extracted"
              "execution_snapshot" parsed.event_type;
            Alcotest.(check (option string))
              "execution_snapshot maps to execution slice"
              (Some "execution") parsed.slice;
            Alcotest.(check bool) "delta carries the bus emission time"
              true
              (parsed.broadcast_ts = ev.Masc.Sse.ext_emitted_at))

(* ============================================================
   3. Dead External Subscriber Removal
   ============================================================ *)

let test_dead_subscriber_auto_removed () =
  Eio_main.run (fun _env ->
    let alive = ref true in
    let received = ref 0 in
    let sub_id = "integration-test-dead" in
    Masc.Sse.subscribe_external ~id:sub_id
      ~is_alive:(fun () -> !alive)
      ~callback:(fun _ev -> incr received)
      ();
    (* First broadcast: subscriber is alive *)
    Masc.Sse.broadcast (`Assoc [("n", `Int 1)]);
    Alcotest.(check int) "received while alive" 1 !received;
    (* Kill the subscriber *)
    alive := false;
    (* Second broadcast: subscriber should be auto-removed *)
    Masc.Sse.broadcast (`Assoc [("n", `Int 2)]);
    Alcotest.(check int) "not received after death" 1 !received;
    (* Verify it was removed from registry *)
    let count_before = Masc.Sse.external_subscriber_count () in
    Masc.Sse.unsubscribe_external sub_id; (* no-op if already removed *)
    let count_after = Masc.Sse.external_subscriber_count () in
    Alcotest.(check int) "no change from redundant unsub" count_before count_after)

let test_grpc_stream_closed_triggers_cleanup () =
  Eio_main.run (fun _env ->
    let stream = Grpc_eio.Stream.create 16 in
    let sub_id = "integration-test-stream-close" in
    let seq_counter = Atomic.make 1 in
    Masc.Sse.subscribe_external ~id:sub_id
      ~is_alive:(fun () -> not (Grpc_eio.Stream.is_closed stream))
      ~callback:(fun (ev : Masc.Sse.external_event) ->
        let sse_event = ev.Masc.Sse.ext_frame in
        if not (Grpc_eio.Stream.is_closed stream) then begin
          let seq = Int64.of_int (Atomic.fetch_and_add seq_counter 1) in
          let event = T.Event.{
            seq; event_type = "sse_broadcast"; source_agent = "server";
            timestamp_ms = 0L; payload_json = sse_event;
          } in
          Grpc_eio.Stream.add stream (T.Event.to_bytes event)
        end)
      ();
    (* Broadcast while stream is open *)
    Masc.Sse.broadcast (`Assoc [("n", `Int 1)]);
    Alcotest.(check int) "1 event in stream" 1 (Grpc_eio.Stream.length stream);
    (* Close the stream (simulates gRPC disconnect) *)
    Grpc_eio.Stream.close stream;
    (* Broadcast again — subscriber should be auto-removed via is_alive *)
    Masc.Sse.broadcast (`Assoc [("n", `Int 2)]);
    (* Stream should still have only 1 event *)
    Alcotest.(check int) "still 1 after close" 1 (Grpc_eio.Stream.length stream))

(* ============================================================
   4. Transport Enum Consistency
   ============================================================ *)

let test_all_protocol_variants_roundtrip () =
  let module Tr = Masc.Transport in
  let all = [Tr.JsonRpc; Tr.Rest; Tr.Grpc; Tr.Sse; Tr.Ws] in
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
  let module At = Masc_grpc_transport in
  let all = [At.Http; At.Grpc; At.Ws; At.Local] in
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
      Alcotest.test_case "parse handles real broadcast wire format" `Quick
        test_ws_derives_dashboard_event_from_real_broadcast;
    ]);
    ("auto_cleanup", [
      Alcotest.test_case "dead subscriber auto-removed" `Quick
        test_dead_subscriber_auto_removed;
      Alcotest.test_case "closed gRPC stream triggers cleanup" `Quick
        test_grpc_stream_closed_triggers_cleanup;
    ]);
    ("transport_enum", [
      Alcotest.test_case "all protocol variants roundtrip" `Quick
        test_all_protocol_variants_roundtrip;
      Alcotest.test_case "all agent transport variants" `Quick
        test_agent_transport_all_variants;
    ]);
  ]
