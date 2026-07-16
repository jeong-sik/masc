(** Tests for Keeper_memory_lane (RFC-0257).

    The lane detaches post-turn memory work from the keeper turn lane:
    serialized within a keeper, independent across keepers, bounded, and
    leak-safe on a raising unit. *)

module Lane = Masc.Keeper_memory_lane

exception Test_boom
exception Cancel_lane_test

let base_path = Filename.concat (Filename.get_temp_dir_name ()) "test-memory-lane"

(* No executor switch set -> submit runs inline so no work is lost. *)
let test_inline_when_uninitialized () =
  Lane.For_testing.reset ();
  let ran = ref false in
  let outcome =
    Lane.submit ~base_path ~keeper_name:"k1" (fun () -> ran := true)
  in
  Alcotest.(check bool) "unit ran inline" true !ran;
  match outcome with
  | Lane.Ran_inline -> ()
  | Lane.Submitted -> Alcotest.fail "expected Ran_inline, got Submitted"
  | Lane.Dropped -> Alcotest.fail "expected Ran_inline, got Dropped"
;;

(* A raising unit in the inline path is contained and returns Ran_inline. *)
let test_inline_contains_raise () =
  Lane.For_testing.reset ();
  let outcome =
    Lane.submit ~base_path ~keeper_name:"k1" (fun () -> raise Test_boom)
  in
  match outcome with
  | Lane.Ran_inline -> ()
  | Lane.Submitted -> Alcotest.fail "expected Ran_inline, got Submitted"
  | Lane.Dropped -> Alcotest.fail "expected Ran_inline, got Dropped"
;;

(* Two units for the same keeper run one after another: the second only starts
   after the first releases the keeper's mutex. *)
let test_serializes_within_keeper () =
  Lane.For_testing.reset ();
  let order = ref [] in
  let add s = order := s :: !order in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let p_started, set_started = Eio.Promise.create () in
      let p_release, set_release = Eio.Promise.create () in
      let oa =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          add "a-start";
          Eio.Promise.resolve set_started ();
          Eio.Promise.await p_release;
          add "a-end")
      in
      Eio.Promise.await p_started;
      let ob =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () -> add "b")
      in
      (* Let B attempt (and fail) to acquire the keeper mutex held by A. *)
      Eio.Fiber.yield ();
      add "before-release";
      Eio.Promise.resolve set_release ();
      (match oa with
       | Lane.Submitted -> ()
       | _ -> Alcotest.fail "unit A not submitted");
      match ob with
      | Lane.Submitted -> ()
      | _ -> Alcotest.fail "unit B not submitted"));
  Alcotest.(check (list string))
    "B serialized behind A"
    [ "a-start"; "before-release"; "a-end"; "b" ]
    (List.rev !order)
;;

(* A unit for one keeper does not block a unit for another keeper. *)
let test_independent_across_keepers () =
  Lane.For_testing.reset ();
  let order = ref [] in
  let add s = order := s :: !order in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let p_started, set_started = Eio.Promise.create () in
      let p_release, set_release = Eio.Promise.create () in
      let _ =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await p_release;
          add "k1")
      in
      Eio.Promise.await p_started;
      let _ =
        Lane.submit ~base_path ~keeper_name:"k2" (fun () -> add "k2")
      in
      (* k2 runs to completion while k1 is still holding its own lane. *)
      Eio.Fiber.yield ();
      Eio.Fiber.yield ();
      Alcotest.(check bool) "k2 ran while k1 blocked" true (List.mem "k2" !order);
      Eio.Promise.resolve set_release ()));
  Alcotest.(check (list string)) "k2 before k1" [ "k2"; "k1" ] (List.rev !order)
;;

(* With max_pending = 2, a third concurrent unit for one keeper is dropped. *)
let test_saturation_drops () =
  Lane.For_testing.reset ();
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let p_release, set_release = Eio.Promise.create () in
      let o1 =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          Eio.Promise.await p_release)
      in
      let o2 = Lane.submit ~base_path ~keeper_name:"k1" (fun () -> ()) in
      let o3 = Lane.submit ~base_path ~keeper_name:"k1" (fun () -> ()) in
      (match o1 with
       | Lane.Submitted -> ()
       | _ -> Alcotest.fail "o1 not submitted");
      (match o2 with
       | Lane.Submitted -> ()
       | _ -> Alcotest.fail "o2 not submitted");
      (match o3 with
       | Lane.Dropped -> ()
       | Lane.Submitted -> Alcotest.fail "o3 should be Dropped, got Submitted"
       | Lane.Ran_inline -> Alcotest.fail "o3 should be Dropped, got Ran_inline");
      Eio.Promise.resolve set_release ()))
;;

(* A unit that raises releases the mutex and the pending slot, so the lane
   recovers and later units run. *)
let test_releases_on_raise () =
  Lane.For_testing.reset ();
  let ran_after = ref false in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let _ =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () -> raise Test_boom)
      in
      Eio.Fiber.yield ();
      Eio.Fiber.yield ();
      let _ =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () -> ran_after := true)
      in
      Eio.Fiber.yield ();
      Eio.Fiber.yield ()));
  Alcotest.(check bool) "lane recovered after raise" true !ran_after;
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked: %d" n
  | None -> Alcotest.fail "keeper entry missing"
;;

(* Cancellation during shutdown releases both the mutex and the pending slot. *)
let test_releases_on_cancel () =
  Lane.For_testing.reset ();
  (try
     Eio_main.run (fun _env ->
       Eio.Switch.run (fun sw ->
         Lane.init ~sw;
         let started, set_started = Eio.Promise.create () in
         let never, _set_never = Eio.Promise.create () in
         let outcome =
           Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
             Eio.Promise.resolve set_started ();
             Eio.Promise.await never)
         in
         (match outcome with
          | Lane.Submitted -> ()
         | Lane.Ran_inline -> Alcotest.fail "cancel test unexpectedly ran inline"
         | Lane.Dropped -> Alcotest.fail "cancel test unexpectedly dropped");
         Eio.Promise.await started;
         Eio.Switch.fail sw Cancel_lane_test))
   with
   | Cancel_lane_test -> ());
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked after cancel: %d" n
  | None -> Alcotest.fail "keeper entry missing after cancel"
;;

(* Submitting against a finished executor switch must not leak the pending
   reservation. Eio.Fiber.fork does not raise to the caller for an off switch, so
   the lane needs its own executor-switch release fallback. *)
let test_finished_switch_drops_without_leak () =
  Lane.For_testing.reset ();
  let finished_sw = ref None in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      finished_sw := Some sw));
  let sw =
    match !finished_sw with
    | Some sw -> sw
    | None -> Alcotest.fail "missing captured switch"
  in
  Lane.init ~sw;
  let outcome =
    Lane.submit ~base_path ~keeper_name:"k1" (fun () -> raise Test_boom)
  in
  (match outcome with
   | Lane.Dropped -> ()
   | Lane.Submitted -> Alcotest.fail "expected Dropped, got Submitted"
   | Lane.Ran_inline -> Alcotest.fail "expected Dropped, got Ran_inline");
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked after finished switch submit: %d" n
  | None -> Alcotest.fail "keeper entry missing after finished switch submit"
;;

(* Maintenance submission neither queues behind an active Keeper nor blocks a
   different Keeper's lane. The closure owns a unit-local child switch. *)
let test_submit_if_idle_is_keeper_local () =
  Lane.For_testing.reset ();
  (match
     Lane.submit_if_idle ~base_path ~keeper_name:"k1" (fun _sw -> ())
   with
   | Lane.Idle_executor_unavailable -> ()
   | _ -> Alcotest.fail "uninitialized idle submission was not rejected");
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let active, set_active = Eio.Promise.create () in
      let release, set_release = Eio.Promise.create () in
      let peer_done, set_peer_done = Eio.Promise.create () in
      let first =
        Lane.submit_if_idle ~base_path ~keeper_name:"k1" (fun _unit_sw ->
          Eio.Promise.resolve set_active ();
          Eio.Promise.await release)
      in
      (match first with
       | Lane.Idle_submitted -> ()
       | _ -> Alcotest.fail "first idle unit was not submitted");
      Eio.Promise.await active;
      let duplicate =
        Lane.submit_if_idle ~base_path ~keeper_name:"k1" (fun _sw -> ())
      in
      (match duplicate with
       | Lane.Idle_already_active -> ()
       | _ -> Alcotest.fail "active Keeper accepted duplicate maintenance");
      let peer =
        Lane.submit_if_idle ~base_path ~keeper_name:"k2" (fun _sw ->
          Eio.Promise.resolve set_peer_done ())
      in
      (match peer with
       | Lane.Idle_submitted -> ()
       | _ -> Alcotest.fail "peer Keeper did not get its independent lane");
      Eio.Promise.await peer_done;
      Eio.Promise.resolve set_release ()))
;;

let rec await_pending keeper_name expected =
  match Lane.For_testing.pending ~base_path ~keeper_name with
  | Some actual when actual = expected -> ()
  | None | Some _ ->
    Eio.Fiber.yield ();
    await_pending keeper_name expected
;;

(* A child fiber attached to a maintenance unit can fail the unit-local switch,
   but must not fail the executor switch. Cleanup releases the original lane,
   after which both that Keeper and a peer can run again. *)
let test_child_failure_is_lane_local () =
  Lane.For_testing.reset ();
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let child_started, set_child_started = Eio.Promise.create () in
      let failed_unit =
        Lane.submit_if_idle ~base_path ~keeper_name:"k1" (fun unit_sw ->
          Eio.Fiber.fork ~sw:unit_sw (fun () ->
            Eio.Promise.resolve set_child_started ();
            raise Test_boom))
      in
      (match failed_unit with
       | Lane.Idle_submitted -> ()
       | _ -> Alcotest.fail "child-failure unit was not submitted");
      Eio.Promise.await child_started;
      await_pending "k1" 0;
      let same_done, set_same_done = Eio.Promise.create () in
      let peer_done, set_peer_done = Eio.Promise.create () in
      let same =
        Lane.submit_if_idle ~base_path ~keeper_name:"k1" (fun _sw ->
          Eio.Promise.resolve set_same_done ())
      in
      let peer =
        Lane.submit_if_idle ~base_path ~keeper_name:"k2" (fun _sw ->
          Eio.Promise.resolve set_peer_done ())
      in
      (match same, peer with
       | Lane.Idle_submitted, Lane.Idle_submitted -> ()
       | _ -> Alcotest.fail "child failure stopped a Keeper lane or its peer");
      Eio.Promise.await same_done;
      Eio.Promise.await peer_done))
;;

let () =
  Alcotest.run
    "keeper_memory_lane"
    [ ( "lane"
      , [ Alcotest.test_case
            "inline when uninitialized"
            `Quick
            test_inline_when_uninitialized
        ; Alcotest.test_case
            "inline contains raise"
            `Quick
            test_inline_contains_raise
        ; Alcotest.test_case
            "serializes within keeper"
            `Quick
            test_serializes_within_keeper
        ; Alcotest.test_case
            "independent across keepers"
            `Quick
            test_independent_across_keepers
        ; Alcotest.test_case "saturation drops" `Quick test_saturation_drops
        ; Alcotest.test_case "releases on raise" `Quick test_releases_on_raise
        ; Alcotest.test_case "releases on cancel" `Quick test_releases_on_cancel
        ; Alcotest.test_case
            "finished switch drops without leak"
            `Quick
            test_finished_switch_drops_without_leak
        ; Alcotest.test_case
            "idle maintenance is Keeper-local"
            `Quick
            test_submit_if_idle_is_keeper_local
        ; Alcotest.test_case
            "child failure is Keeper-local"
            `Quick
            test_child_failure_is_lane_local
        ] )
    ]
;;
