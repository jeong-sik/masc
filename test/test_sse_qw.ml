(** Quick-win tests for Sse module.
    Covers: max_clients, touch, close_all_clients, cleanup_stale, register/unregister. *)

open Masc_mcp

let () =
  let reset () = ignore (Sse.close_all_clients ()) in
  let _dummy_push _s = () in
  Alcotest.run
    "sse-qw"
    [ ( "max_clients"
      , [ Alcotest.test_case "positive" `Quick (fun () ->
            Alcotest.(check bool) "positive" true (Sse.max_clients > 0))
        ; Alcotest.test_case "value is 200" `Quick (fun () ->
            Alcotest.(check int) "200" 200 Sse.max_clients)
        ] )
    ; ( "register_unregister"
      , [ Alcotest.test_case "register adds client" `Quick (fun () ->
            reset ();
            ignore (Sse.register "sess-1" ~last_event_id:0);
            Alcotest.(check bool) "exists" true (Sse.exists "sess-1");
            Sse.unregister "sess-1")
        ; Alcotest.test_case "unregister removes client" `Quick (fun () ->
            reset ();
            ignore (Sse.register "sess-2" ~last_event_id:0);
            Sse.unregister "sess-2";
            Alcotest.(check bool) "gone" false (Sse.exists "sess-2"))
        ; Alcotest.test_case "client_count" `Quick (fun () ->
            reset ();
            ignore (Sse.register "s-a" ~last_event_id:0);
            ignore (Sse.register "s-b" ~last_event_id:0);
            Alcotest.(check int) "count" 2 (Sse.client_count ());
            Sse.unregister "s-a";
            Sse.unregister "s-b")
        ] )
    ; ( "touch"
      , [ Alcotest.test_case "existing client" `Quick (fun () ->
            reset ();
            ignore (Sse.register "sess-3" ~last_event_id:0);
            Unix.sleepf 0.05;
            Sse.touch "sess-3";
            (* No exception = pass *)
            ();
            Sse.unregister "sess-3")
        ; Alcotest.test_case "nonexistent no error" `Quick (fun () ->
            Sse.touch "nonexistent";
            ())
        ] )
    ; ( "close_all_clients"
      , [ Alcotest.test_case "with clients" `Quick (fun () ->
            reset ();
            ignore (Sse.register "c-1" ~last_event_id:0);
            ignore (Sse.register "c-2" ~last_event_id:0);
            ignore (Sse.register "c-3" ~last_event_id:0);
            let closed = Sse.close_all_clients () in
            Alcotest.(check int) "closed 3" 3 closed;
            Alcotest.(check int) "now empty" 0 (Sse.client_count ()))
        ; Alcotest.test_case "empty" `Quick (fun () ->
            reset ();
            let closed = Sse.close_all_clients () in
            Alcotest.(check int) "closed 0" 0 closed)
        ] )
    ; ( "cleanup_stale"
      , [ Alcotest.test_case "fresh clients survive" `Quick (fun () ->
            reset ();
            ignore (Sse.register "fresh" ~last_event_id:0);
            let evicted = Sse.cleanup_stale () in
            Alcotest.(check int) "none evicted" 0 (List.length evicted);
            Sse.unregister "fresh")
        ; Alcotest.test_case "zero threshold evicts all" `Quick (fun () ->
            reset ();
            ignore (Sse.register "old" ~last_event_id:0);
            Unix.sleepf 0.05;
            let evicted = Sse.cleanup_stale ~max_age_s:0.0 () in
            Alcotest.(check bool) "evicted" true (List.length evicted > 0))
        ; Alcotest.test_case "returns evicted ids" `Quick (fun () ->
            reset ();
            ignore (Sse.register "target" ~last_event_id:0);
            Unix.sleepf 0.05;
            let evicted = Sse.cleanup_stale ~max_age_s:0.0 () in
            Alcotest.(check bool) "contains target" true (List.mem "target" evicted))
        ] )
    ]
;;
