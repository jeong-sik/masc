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

(* [submit] must return control to the keeper turn before the detached memory
   unit begins. Eio.Fiber.fork runs the child immediately unless it yields. *)
let test_submit_detaches_before_job_runs () =
  Lane.For_testing.reset ();
  let submit_returned = ref false in
  let job_observed_submit_returned = ref false in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let outcome =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          job_observed_submit_returned := !submit_returned)
      in
      (match outcome with
       | Lane.Submitted -> ()
       | Lane.Ran_inline -> Alcotest.fail "detachment test ran inline"
       | Lane.Dropped -> Alcotest.fail "detachment test was dropped");
      submit_returned := true));
  Alcotest.(check bool)
    "job began after submit returned"
    true
    !job_observed_submit_returned
;;

(* Two units for the same keeper run one after another: the worker does not
   begin the second until the first completes. *)
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

(* Backlog is kept in FIFO order instead of being discarded at an arbitrary
   pending bound. The turn-side submitter does not wait for the first unit. *)
let test_backlog_is_queued_without_loss () =
  Lane.For_testing.reset ();
  let order = ref [] in
  let outcomes = ref [] in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let p_started, set_started = Eio.Promise.create () in
      let p_release, set_release = Eio.Promise.create () in
      let o1 =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await p_release;
          order := "a" :: !order)
      in
      Eio.Promise.await p_started;
      let o2 =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          order := "b" :: !order)
      in
      let o3 =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          order := "c" :: !order)
      in
      outcomes := [ o1; o2; o3 ];
      Alcotest.(check (option int))
        "all three units remain pending"
        (Some 3)
        (Lane.For_testing.pending ~base_path ~keeper_name:"k1");
      Eio.Promise.resolve set_release ()))
  ;
  List.iter
    (function
      | Lane.Submitted -> ()
      | Lane.Ran_inline -> Alcotest.fail "queued unit unexpectedly ran inline"
      | Lane.Dropped -> Alcotest.fail "accepted backlog unit was dropped")
    !outcomes;
  Alcotest.(check (list string))
    "FIFO order preserved"
    [ "a"; "b"; "c" ]
    (List.rev !order);
  Alcotest.(check (option int))
    "pending drained"
    (Some 0)
    (Lane.For_testing.pending ~base_path ~keeper_name:"k1")
;;

(* A unit that raises releases its pending slot, so the worker continues and
   later units run. *)
let test_releases_on_raise () =
  Lane.For_testing.reset ();
  let ran_after = ref false in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let started, set_started = Eio.Promise.create () in
      let release, set_release = Eio.Promise.create () in
      let first =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await release;
          raise Test_boom)
      in
      Eio.Promise.await started;
      let second =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () -> ran_after := true)
      in
      (match first, second with
       | Lane.Submitted, Lane.Submitted -> ()
       | _ -> Alcotest.fail "raising unit backlog was not submitted");
      Eio.Promise.resolve set_release ()));
  Alcotest.(check bool) "lane recovered after raise" true !ran_after;
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked: %d" n
  | None -> Alcotest.fail "keeper entry missing"
;;

(* Cancellation during shutdown releases both the mutex and the pending slot. *)
let test_releases_on_cancel () =
  Lane.For_testing.reset ();
  let queued_unit_ran = ref false in
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
         let queued =
           Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
             queued_unit_ran := true)
         in
         (match queued with
          | Lane.Submitted -> ()
          | Lane.Ran_inline -> Alcotest.fail "queued cancel unit ran inline"
          | Lane.Dropped -> Alcotest.fail "queued cancel unit was not accepted");
         Alcotest.(check (option int))
           "in-flight and queued before cancellation"
           (Some 2)
           (Lane.For_testing.pending ~base_path ~keeper_name:"k1");
         Eio.Switch.fail sw Cancel_lane_test))
   with
   | Cancel_lane_test -> ());
  Alcotest.(check bool)
    "queued unit did not run after cancellation"
    false
    !queued_unit_ran;
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
            "submit detaches before job runs"
            `Quick
            test_submit_detaches_before_job_runs
        ; Alcotest.test_case
            "serializes within keeper"
            `Quick
            test_serializes_within_keeper
        ; Alcotest.test_case
            "independent across keepers"
            `Quick
            test_independent_across_keepers
        ; Alcotest.test_case
            "backlog queued without loss"
            `Quick
            test_backlog_is_queued_without_loss
        ; Alcotest.test_case "releases on raise" `Quick test_releases_on_raise
        ; Alcotest.test_case "releases on cancel" `Quick test_releases_on_cancel
        ; Alcotest.test_case
            "finished switch drops without leak"
            `Quick
            test_finished_switch_drops_without_leak
        ] )
    ]
;;
