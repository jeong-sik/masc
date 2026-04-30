(** Tests for per-session Eio.Stream broadcast in Sse module.

    Verifies that [broadcast] pushes events into per-client streams
    and that [pop]/[try_pop] drain them correctly.  All tests run
    inside [Eio_main.run] to exercise the stream path (not the
    direct-push fallback). *)

open Masc_mcp

let reset () = ignore (Sse.close_all_clients ())

let _dummy_push _s = ()

(* ============================================================
   pop / try_pop
   ============================================================ *)

let test_try_pop_empty () =
  reset ();
  let result = Sse.try_pop "nonexistent" in
  Alcotest.(check bool) "None for missing session" true (result = None)

let test_try_pop_no_events () =
  reset ();
  ignore (Sse.register "s-pop-empty" ~last_event_id:0);
  let result = Sse.try_pop "s-pop-empty" in
  Alcotest.(check bool) "None when stream empty" true (result = None);
  Sse.unregister "s-pop-empty"

let test_broadcast_popable () =
  reset ();
  ignore (Sse.register "s-pop-bc" ~last_event_id:0);
  Sse.broadcast (`Assoc [("key", `String "val")]);
  let ev = Sse.try_pop "s-pop-bc" in
  Alcotest.(check bool) "got event from stream" true (ev <> None);
  (* Verify no more events queued *)
  let ev2 = Sse.try_pop "s-pop-bc" in
  Alcotest.(check bool) "no more events" true (ev2 = None);
  Sse.unregister "s-pop-bc"

let test_broadcast_multiple_clients_streams () =
  reset ();
  ignore (Sse.register "s-mc-1" ~last_event_id:0);
  ignore (Sse.register "s-mc-2" ~last_event_id:0);
  ignore (Sse.register "s-mc-3" ~last_event_id:0);
  Sse.broadcast (`Assoc [("multi", `Bool true)]);
  let got1 = Sse.try_pop "s-mc-1" in
  let got2 = Sse.try_pop "s-mc-2" in
  let got3 = Sse.try_pop "s-mc-3" in
  Alcotest.(check bool) "client 1 got event" true (got1 <> None);
  Alcotest.(check bool) "client 2 got event" true (got2 <> None);
  Alcotest.(check bool) "client 3 got event" true (got3 <> None);
  Sse.unregister "s-mc-1";
  Sse.unregister "s-mc-2";
  Sse.unregister "s-mc-3"

let test_send_to_popable () =
  reset ();
  ignore (Sse.register "s-st-1" ~last_event_id:0);
  ignore (Sse.register "s-st-2" ~last_event_id:0);
  Sse.send_to "s-st-1" (`Assoc [("direct", `Bool true)]);
  let got1 = Sse.try_pop "s-st-1" in
  let got2 = Sse.try_pop "s-st-2" in
  Alcotest.(check bool) "target got event" true (got1 <> None);
  Alcotest.(check bool) "other did not" true (got2 = None);
  Sse.unregister "s-st-1";
  Sse.unregister "s-st-2"

let test_pop_blocks_then_receives () =
  reset ();
  ignore (Sse.register "s-block" ~last_event_id:0);
  (* pop in a sub-fiber, broadcast from main fiber *)
  Eio.Fiber.both
    (fun () ->
      let ev = Sse.pop "s-block" in
      Alcotest.(check bool) "pop returned Some" true (ev <> None))
    (fun () ->
      (* Small yield so the pop fiber starts waiting *)
      Eio.Fiber.yield ();
      Sse.broadcast (`Assoc [("wakeup", `Bool true)]));
  Sse.unregister "s-block"

let test_broadcast_skips_already_seen () =
  reset ();
  (* Register with a high last_event_id so events are skipped *)
  ignore (Sse.register "s-skip" ~last_event_id:999_999_999);
  Sse.broadcast (`Assoc [("skip", `Bool true)]);
  let ev = Sse.try_pop "s-skip" in
  Alcotest.(check bool) "skipped (already seen)" true (ev = None);
  Sse.unregister "s-skip"

let test_broadcast_event_contains_data () =
  reset ();
  ignore (Sse.register "s-data" ~last_event_id:0);
  Sse.broadcast (`Assoc [("payload", `Int 42)]);
  match Sse.try_pop "s-data" with
  | None -> Alcotest.fail "expected an event"
  | Some ev ->
    (* SSE format: "id: N\nevent: message\ndata: {...}\n\n" *)
    Alcotest.(check bool) "contains data:" true
      (String.length ev > 0 &&
       let has_data = ref false in
       String.split_on_char '\n' ev
       |> List.iter (fun line ->
         if String.length line >= 5 && String.sub line 0 5 = "data:" then
           has_data := true);
       !has_data);
    Sse.unregister "s-data"

(* ============================================================
   broadcast_to targeting (session_kind separation)
   ============================================================ *)

let test_broadcast_to_observers_only () =
  reset ();
  ignore (Sse.register ~kind:Observer "s-obs" ~last_event_id:0);
  ignore (Sse.register ~kind:Coordinator "s-coord" ~last_event_id:0);
  Sse.broadcast_to Observers (`Assoc [("target", `String "observers")]);
  let got_obs = Sse.try_pop "s-obs" in
  let got_coord = Sse.try_pop "s-coord" in
  Alcotest.(check bool) "observer got event" true (got_obs <> None);
  Alcotest.(check bool) "coordinator did not" true (got_coord = None);
  Sse.unregister "s-obs";
  Sse.unregister "s-coord"

let test_broadcast_to_coordinators_only () =
  reset ();
  ignore (Sse.register ~kind:Observer "s-obs2" ~last_event_id:0);
  ignore (Sse.register ~kind:Coordinator "s-coord2" ~last_event_id:0);
  Sse.broadcast_to Coordinators (`Assoc [("target", `String "coordinators")]);
  let got_obs = Sse.try_pop "s-obs2" in
  let got_coord = Sse.try_pop "s-coord2" in
  Alcotest.(check bool) "observer did not get event" true (got_obs = None);
  Alcotest.(check bool) "coordinator got event" true (got_coord <> None);
  Sse.unregister "s-obs2";
  Sse.unregister "s-coord2"

let test_broadcast_to_all () =
  reset ();
  ignore (Sse.register ~kind:Observer "s-all-obs" ~last_event_id:0);
  ignore (Sse.register ~kind:Coordinator "s-all-coord" ~last_event_id:0);
  Sse.broadcast_to All (`Assoc [("target", `String "all")]);
  let got_obs = Sse.try_pop "s-all-obs" in
  let got_coord = Sse.try_pop "s-all-coord" in
  Alcotest.(check bool) "observer got event" true (got_obs <> None);
  Alcotest.(check bool) "coordinator got event" true (got_coord <> None);
  Sse.unregister "s-all-obs";
  Sse.unregister "s-all-coord"

let test_broadcast_equals_broadcast_to_all () =
  reset ();
  ignore (Sse.register ~kind:Observer "s-eq-obs" ~last_event_id:0);
  ignore (Sse.register ~kind:Coordinator "s-eq-coord" ~last_event_id:0);
  (* broadcast (no target) should reach everyone, same as broadcast_to All *)
  Sse.broadcast (`Assoc [("compat", `Bool true)]);
  let got_obs = Sse.try_pop "s-eq-obs" in
  let got_coord = Sse.try_pop "s-eq-coord" in
  Alcotest.(check bool) "observer got broadcast" true (got_obs <> None);
  Alcotest.(check bool) "coordinator got broadcast" true (got_coord <> None);
  Sse.unregister "s-eq-obs";
  Sse.unregister "s-eq-coord"

let test_broadcast_all_excludes_presence_sessions () =
  reset ();
  ignore (Sse.register ~kind:Presence "s-all-presence" ~last_event_id:0);
  ignore (Sse.register ~kind:Coordinator "s-all-coord-only" ~last_event_id:0);
  Sse.broadcast (`Assoc [("durable", `Bool true)]);
  let got_presence = Sse.try_pop "s-all-presence" in
  let got_coord = Sse.try_pop "s-all-coord-only" in
  Alcotest.(check bool) "presence did not get durable all" true
    (got_presence = None);
  Alcotest.(check bool) "coordinator got durable all" true (got_coord <> None);
  Sse.unregister "s-all-presence";
  Sse.unregister "s-all-coord-only"

let test_broadcast_presence_is_live_only () =
  reset ();
  let original_buffer = Atomic.get Sse.event_buffer in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Sse.event_buffer original_buffer;
      Sse.unregister "s-presence";
      Sse.unregister "s-observer")
    (fun () ->
      Atomic.set Sse.event_buffer [];
      ignore (Sse.register ~kind:Presence "s-presence" ~last_event_id:0);
      ignore (Sse.register ~kind:Observer "s-observer" ~last_event_id:0);
      let before_id = Sse.current_id () in
      Sse.broadcast_presence (`Assoc [("type", `String "keeper_heartbeat")]);
      let got_presence = Sse.try_pop "s-presence" in
      let got_observer = Sse.try_pop "s-observer" in
      Alcotest.(check bool) "presence got event" true (got_presence <> None);
      Alcotest.(check bool) "observer did not get presence" true
        (got_observer = None);
      (match got_presence with
       | Some event ->
           Alcotest.(check bool) "presence event type" true
             (List.exists
                (String.equal "event: presence")
                (String.split_on_char '\n' event))
       | None -> Alcotest.fail "expected presence event");
      Alcotest.(check (list string)) "presence not replay buffered" []
        (Sse.get_events_after before_id))

let test_register_defaults_to_coordinator () =
  reset ();
  (* Register without explicit kind *)
  ignore (Sse.register "s-default" ~last_event_id:0);
  (* Should be Coordinator: receives Coordinators-targeted broadcast *)
  Sse.broadcast_to Coordinators (`Assoc [("default_kind", `Bool true)]);
  let got = Sse.try_pop "s-default" in
  Alcotest.(check bool) "default kind is Coordinator" true (got <> None);
  (* Should not receive Observers-targeted broadcast *)
  Sse.broadcast_to Observers (`Assoc [("observer_only", `Bool true)]);
  let got2 = Sse.try_pop "s-default" in
  Alcotest.(check bool) "default does not receive Observers" true (got2 = None);
  Sse.unregister "s-default"

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Alcotest.run "sse-stream"
    [
      ( "try_pop",
        [
          Alcotest.test_case "nonexistent session" `Quick test_try_pop_empty;
          Alcotest.test_case "empty stream" `Quick test_try_pop_no_events;
        ] );
      ( "broadcast_stream",
        [
          Alcotest.test_case "broadcast popable" `Quick test_broadcast_popable;
          Alcotest.test_case "multiple clients" `Quick test_broadcast_multiple_clients_streams;
          Alcotest.test_case "skips already seen" `Quick test_broadcast_skips_already_seen;
          Alcotest.test_case "event contains data" `Quick test_broadcast_event_contains_data;
        ] );
      ( "send_to_stream",
        [
          Alcotest.test_case "send_to popable" `Quick test_send_to_popable;
        ] );
      ( "pop_blocking",
        [
          Alcotest.test_case "blocks then receives" `Quick test_pop_blocks_then_receives;
        ] );
      ( "broadcast_to_targeting",
        [
          Alcotest.test_case "observers only" `Quick test_broadcast_to_observers_only;
          Alcotest.test_case "coordinators only" `Quick test_broadcast_to_coordinators_only;
          Alcotest.test_case "all targets" `Quick test_broadcast_to_all;
          Alcotest.test_case "broadcast = broadcast_to All" `Quick test_broadcast_equals_broadcast_to_all;
          Alcotest.test_case "broadcast All excludes presence" `Quick test_broadcast_all_excludes_presence_sessions;
          Alcotest.test_case "presence live-only" `Quick test_broadcast_presence_is_live_only;
          Alcotest.test_case "default kind is Coordinator" `Quick test_register_defaults_to_coordinator;
        ] );
    ]
