(** Tests for per-session Eio.Stream broadcast in Sse module.

    Verifies that [broadcast] pushes events into per-client streams
    and that [pop]/[try_pop] drain them correctly.  All tests run
    inside [Eio_main.run] to exercise the stream path (not the
    direct-push fallback). *)

open Masc_mcp

let reset () = ignore (Sse.close_all_clients ())

let dummy_push _s = ()

(* ============================================================
   pop / try_pop
   ============================================================ *)

let test_try_pop_empty () =
  reset ();
  let result = Sse.try_pop "nonexistent" in
  Alcotest.(check bool) "None for missing session" true (result = None)

let test_try_pop_no_events () =
  reset ();
  ignore (Sse.register "s-pop-empty" ~push:dummy_push ~last_event_id:0);
  let result = Sse.try_pop "s-pop-empty" in
  Alcotest.(check bool) "None when stream empty" true (result = None);
  Sse.unregister "s-pop-empty"

let test_broadcast_popable () =
  reset ();
  ignore (Sse.register "s-pop-bc" ~push:dummy_push ~last_event_id:0);
  Sse.broadcast (`Assoc [("key", `String "val")]);
  let ev = Sse.try_pop "s-pop-bc" in
  Alcotest.(check bool) "got event from stream" true (ev <> None);
  (* Verify no more events queued *)
  let ev2 = Sse.try_pop "s-pop-bc" in
  Alcotest.(check bool) "no more events" true (ev2 = None);
  Sse.unregister "s-pop-bc"

let test_broadcast_multiple_clients_streams () =
  reset ();
  ignore (Sse.register "s-mc-1" ~push:dummy_push ~last_event_id:0);
  ignore (Sse.register "s-mc-2" ~push:dummy_push ~last_event_id:0);
  ignore (Sse.register "s-mc-3" ~push:dummy_push ~last_event_id:0);
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
  ignore (Sse.register "s-st-1" ~push:dummy_push ~last_event_id:0);
  ignore (Sse.register "s-st-2" ~push:dummy_push ~last_event_id:0);
  Sse.send_to "s-st-1" (`Assoc [("direct", `Bool true)]);
  let got1 = Sse.try_pop "s-st-1" in
  let got2 = Sse.try_pop "s-st-2" in
  Alcotest.(check bool) "target got event" true (got1 <> None);
  Alcotest.(check bool) "other did not" true (got2 = None);
  Sse.unregister "s-st-1";
  Sse.unregister "s-st-2"

let test_pop_blocks_then_receives () =
  reset ();
  ignore (Sse.register "s-block" ~push:dummy_push ~last_event_id:0);
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
  ignore (Sse.register "s-skip" ~push:dummy_push ~last_event_id:999_999_999);
  Sse.broadcast (`Assoc [("skip", `Bool true)]);
  let ev = Sse.try_pop "s-skip" in
  Alcotest.(check bool) "skipped (already seen)" true (ev = None);
  Sse.unregister "s-skip"

let test_broadcast_event_contains_data () =
  reset ();
  ignore (Sse.register "s-data" ~push:dummy_push ~last_event_id:0);
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

let () =
  Eio_main.run @@ fun _env ->
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
    ]
