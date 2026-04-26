(** Quick-win tests for Heartbeat module.
    Covers: generate_id, start, stop, list, get, stop_by_agent. *)

let () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  (* Clear state before each test group *)
  let reset () =
    List.iter
      (fun (hb : Heartbeat.t) -> ignore (Heartbeat.stop hb.id))
      (Heartbeat.list ())
  in
  Alcotest.run
    "heartbeat-qw"
    [ ( "generate_id"
      , [ Alcotest.test_case "non-empty" `Quick (fun () ->
            let id = Heartbeat.generate_id () in
            Alcotest.(check bool) "non-empty" true (String.length id > 0))
        ; Alcotest.test_case "has hb- prefix" `Quick (fun () ->
            let id = Heartbeat.generate_id () in
            let prefix = String.sub id 0 3 in
            Alcotest.(check string) "prefix" "hb-" prefix)
        ; Alcotest.test_case "unique" `Quick (fun () ->
            let a = Heartbeat.generate_id () in
            let b = Heartbeat.generate_id () in
            Alcotest.(check bool) "different" true (a <> b))
        ] )
    ; ( "start"
      , [ Alcotest.test_case "returns id" `Quick (fun () ->
            reset ();
            let id = Heartbeat.start ~agent_name:"test-a" ~interval:60 ~message:"ping" in
            Alcotest.(check bool) "non-empty id" true (String.length id > 0);
            ignore (Heartbeat.stop id))
        ; Alcotest.test_case "registers in table" `Quick (fun () ->
            reset ();
            let id = Heartbeat.start ~agent_name:"test-b" ~interval:30 ~message:"hello" in
            let found = Heartbeat.get id in
            Alcotest.(check bool) "found" true (Option.is_some found);
            ignore (Heartbeat.stop id))
        ] )
    ; ( "stop"
      , [ Alcotest.test_case "existing returns true" `Quick (fun () ->
            reset ();
            let id = Heartbeat.start ~agent_name:"test-c" ~interval:10 ~message:"msg" in
            let removed = Heartbeat.stop id in
            Alcotest.(check bool) "removed" true removed)
        ; Alcotest.test_case "missing returns false" `Quick (fun () ->
            let removed = Heartbeat.stop "nonexistent-id" in
            Alcotest.(check bool) "not found" false removed)
        ; Alcotest.test_case "removes from table" `Quick (fun () ->
            reset ();
            let id = Heartbeat.start ~agent_name:"test-d" ~interval:10 ~message:"msg" in
            ignore (Heartbeat.stop id);
            let found = Heartbeat.get id in
            Alcotest.(check bool) "gone" true (Option.is_none found))
        ] )
    ; ( "list"
      , [ Alcotest.test_case "includes started" `Quick (fun () ->
            reset ();
            let id = Heartbeat.start ~agent_name:"test-e" ~interval:10 ~message:"msg" in
            let items = Heartbeat.list () in
            let ids = List.map (fun (hb : Heartbeat.t) -> hb.id) items in
            Alcotest.(check bool) "contains id" true (List.mem id ids);
            ignore (Heartbeat.stop id))
        ] )
    ; ( "get"
      , [ Alcotest.test_case "found" `Quick (fun () ->
            reset ();
            let id = Heartbeat.start ~agent_name:"test-f" ~interval:10 ~message:"msg" in
            let hb = Heartbeat.get id in
            Alcotest.(check bool) "some" true (Option.is_some hb);
            ignore (Heartbeat.stop id))
        ; Alcotest.test_case "not found" `Quick (fun () ->
            let hb = Heartbeat.get "bogus" in
            Alcotest.(check bool) "none" true (Option.is_none hb))
        ] )
    ; ( "stop_by_agent"
      , [ Alcotest.test_case "removes all for agent" `Quick (fun () ->
            reset ();
            let _a = Heartbeat.start ~agent_name:"alice" ~interval:10 ~message:"m1" in
            let _b = Heartbeat.start ~agent_name:"alice" ~interval:20 ~message:"m2" in
            let _c = Heartbeat.start ~agent_name:"bob" ~interval:10 ~message:"m3" in
            let removed = Heartbeat.stop_by_agent ~agent_name:"alice" in
            Alcotest.(check int) "removed 2" 2 removed;
            ignore (Heartbeat.stop _c))
        ; Alcotest.test_case "no match returns 0" `Quick (fun () ->
            reset ();
            let removed = Heartbeat.stop_by_agent ~agent_name:"nobody" in
            Alcotest.(check int) "removed 0" 0 removed)
        ; Alcotest.test_case "leaves others" `Quick (fun () ->
            reset ();
            let _a = Heartbeat.start ~agent_name:"alice" ~interval:10 ~message:"m1" in
            let b = Heartbeat.start ~agent_name:"bob" ~interval:10 ~message:"m2" in
            ignore (Heartbeat.stop_by_agent ~agent_name:"alice");
            let bob = Heartbeat.get b in
            Alcotest.(check bool) "bob still here" true (Option.is_some bob);
            ignore (Heartbeat.stop b))
        ] )
    ]
;;
