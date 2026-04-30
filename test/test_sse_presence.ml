(** Isolation tests for {!Masc_mcp.Sse_presence}.

    These tests anchor the contract that the presence channel and the
    main SSE channel share *no* runtime state.  RFC PR-1.7 sec 4.4 stage 1
    explicitly relies on this independence — if a future refactor
    silently routes presence broadcasts through {!Sse}'s registry the
    dual-emit story collapses. *)

open Alcotest

let fresh_sid prefix =
  prefix ^ "_" ^ string_of_int (Random.int 1_000_000_000)

let test_register_does_not_leak_into_main () =
  let module SP = Masc_mcp.Sse_presence in
  let module S = Masc_mcp.Sse in
  let sid = fresh_sid "presence_only" in
  let main_count_before = S.client_count () in
  let presence_count_before = SP.client_count () in
  let (_id, _stream, _evicted) = SP.register sid ~last_event_id:0 in
  check bool "presence subscriber is visible to presence registry"
    true (SP.exists sid);
  check bool "presence subscriber is invisible to main SSE registry"
    false (S.exists sid);
  check int "main client count unchanged"
    main_count_before (S.client_count ());
  check int "presence client count incremented"
    (presence_count_before + 1) (SP.client_count ());
  SP.unregister sid

let test_broadcast_does_not_cross_channels () =
  let module SP = Masc_mcp.Sse_presence in
  let module S = Masc_mcp.Sse in
  let presence_sid = fresh_sid "p" in
  let main_sid = fresh_sid "m" in
  let (_pid, presence_stream, _) = SP.register presence_sid ~last_event_id:0 in
  let (_mid, main_stream, _) = S.register main_sid ~last_event_id:0 in
  Fun.protect
    ~finally:(fun () ->
      SP.unregister presence_sid;
      S.unregister main_sid)
    (fun () ->
      (* Sse_presence.broadcast must NOT reach a main-channel subscriber *)
      SP.broadcast (`Assoc [ "type", `String "keeper_heartbeat" ]);
      check int "main subscriber receives no presence broadcast"
        0 (Eio.Stream.length main_stream);
      check bool "presence subscriber receives presence broadcast (>=1)"
        true (Eio.Stream.length presence_stream >= 1);

      (* Sse.broadcast must NOT reach the presence subscriber *)
      let presence_queue_before = Eio.Stream.length presence_stream in
      S.broadcast (`Assoc [ "type", `String "masc:broadcast" ]);
      check int "presence subscriber receives no main broadcast"
        presence_queue_before (Eio.Stream.length presence_stream))

let test_event_counter_independence () =
  let module SP = Masc_mcp.Sse_presence in
  let module S = Masc_mcp.Sse in
  let main_before = S.current_id () in
  let presence_before = SP.current_id () in
  (* Bumping presence must not advance the main counter, and vice versa *)
  let _ = SP.next_id () in
  let _ = SP.next_id () in
  check int "main counter unaffected by presence next_id"
    main_before (S.current_id ());
  let _ = S.next_id () in
  check int "presence counter unaffected by main next_id"
    (presence_before + 2) (SP.current_id ())

let test_buffer_independence () =
  let module SP = Masc_mcp.Sse_presence in
  let module S = Masc_mcp.Sse in
  (* Anchor on the addresses of the Atomic.t cells: presence and main
     must not share storage.  If a future refactor unifies them the
     dual-emit + independent Last-Event-Id story breaks. *)
  check bool "client registries are distinct atomics"
    true (SP.clients != Obj.magic S.clients);
  check bool "event buffers are distinct atomics"
    true (SP.event_buffer != Obj.magic S.event_buffer)

let test_buffer_replay () =
  let module SP = Masc_mcp.Sse_presence in
  let id1 = SP.next_id () in
  SP.buffer_event id1 "id: 1\nevent: message\ndata: a\n\n";
  let id2 = SP.next_id () in
  SP.buffer_event id2 "id: 2\nevent: message\ndata: b\n\n";
  let replay = SP.get_events_after (id1 - 1) in
  check int "replay returns 2 events" 2 (List.length replay);
  let replay_after = SP.get_events_after id2 in
  check int "replay after newest returns 0" 0 (List.length replay_after)

let () =
  run "sse_presence"
    [
      ("registration",
        [
          test_case "presence register does not leak into main SSE"
            `Quick test_register_does_not_leak_into_main;
        ]);
      ("isolation",
        [
          test_case "broadcast does not cross channels"
            `Quick test_broadcast_does_not_cross_channels;
          test_case "event counters are independent"
            `Quick test_event_counter_independence;
          test_case "registries and buffers are distinct atomics"
            `Quick test_buffer_independence;
        ]);
      ("replay",
        [ test_case "buffer replay by last_event_id"
            `Quick test_buffer_replay;
        ]);
    ]
