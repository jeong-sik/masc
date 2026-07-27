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
    Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () -> ran := true)
  in
  Alcotest.(check bool) "unit ran inline" true !ran;
  match outcome with
  | Lane.Ran_inline -> ()
  | Lane.Submitted -> Alcotest.fail "expected Ran_inline, got Submitted"
  | Lane.Coalesced -> Alcotest.fail "expected Ran_inline, got Coalesced"
  | Lane.Dropped -> Alcotest.fail "expected Ran_inline, got Dropped"
;;

(* A raising unit in the inline path is contained and returns Ran_inline. *)
let test_inline_contains_raise () =
  Lane.For_testing.reset ();
  let outcome =
    Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () -> raise Test_boom)
  in
  match outcome with
  | Lane.Ran_inline -> ()
  | Lane.Submitted -> Alcotest.fail "expected Ran_inline, got Submitted"
  | Lane.Coalesced -> Alcotest.fail "expected Ran_inline, got Coalesced"
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
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
          add "a-start";
          Eio.Promise.resolve set_started ();
          Eio.Promise.await p_release;
          add "a-end")
      in
      Eio.Promise.await p_started;
      let ob =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () -> add "b")
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
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await p_release;
          add "k1")
      in
      Eio.Promise.await p_started;
      let _ =
        Lane.submit ~base_path ~keeper_name:"k2" ~lane:Lane.Librarian (fun () -> add "k2")
      in
      (* k2 runs to completion while k1 is still holding its own lane. *)
      Eio.Fiber.yield ();
      Eio.Fiber.yield ();
      Alcotest.(check bool) "k2 ran while k1 blocked" true (List.mem "k2" !order);
      Eio.Promise.resolve set_release ()));
  Alcotest.(check (list string)) "k2 before k1" [ "k2"; "k1" ] (List.rev !order)
;;

(* The deterministic lane retains its existing bounded-drop policy. *)
let test_deterministic_saturation_drops () =
  Lane.For_testing.reset ();
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let p_release, set_release = Eio.Promise.create () in
      let o1 =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Deterministic (fun () ->
          Eio.Promise.await p_release)
      in
      let o2 =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Deterministic (fun () -> ())
      in
      let o3 =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Deterministic (fun () -> ())
      in
      (match o1 with
       | Lane.Submitted -> ()
       | _ -> Alcotest.fail "o1 not submitted");
      (match o2 with
       | Lane.Submitted -> ()
       | _ -> Alcotest.fail "o2 not submitted");
      (match o3 with
       | Lane.Dropped -> ()
       | Lane.Submitted -> Alcotest.fail "o3 should be Dropped, got Submitted"
       | Lane.Coalesced -> Alcotest.fail "deterministic lane must not coalesce"
       | Lane.Ran_inline -> Alcotest.fail "o3 should be Dropped, got Ran_inline");
      Eio.Promise.resolve set_release ()))
;;

(* Librarian saturation keeps one running unit and one overwriteable latest
   snapshot. Every submit returns immediately; only the newest pending snapshot
   evaluates after the blocker. *)
let test_librarian_saturation_coalesces_latest () =
  Lane.For_testing.reset ();
  let evaluated = ref [] in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let started, set_started = Eio.Promise.create () in
      let release, set_release = Eio.Promise.create () in
      let running =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await release;
          evaluated := "running" :: !evaluated)
      in
      Eio.Promise.await started;
      let snapshot trace generation messages () =
        evaluated :=
          Printf.sprintf "%s:%d:%s" trace generation (String.concat "," messages)
          :: !evaluated
      in
      let stale =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian
          (snapshot "trace-stale" 1 [ "stale" ])
      in
      let newer =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian
          (snapshot "trace-newer" 2 [ "newer" ])
      in
      let newest =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian
          (snapshot "trace-newest" 3 [ "newest-a"; "newest-b" ])
      in
      (match running, stale, newer, newest with
       | Lane.Submitted, Lane.Submitted, Lane.Coalesced, Lane.Coalesced -> ()
       | _ -> Alcotest.fail "unexpected Librarian coalescing outcomes");
      (match Lane.For_testing.pending ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian with
       | Some 2 -> ()
       | Some n -> Alcotest.failf "running+latest bound should be 2, got %d" n
       | None -> Alcotest.fail "missing Librarian lane entry");
      Eio.Promise.resolve set_release ()));
  Alcotest.(check (list string))
    "only running and newest snapshot evaluate"
    [ "running"; "trace-newest:3:newest-a,newest-b" ]
    (List.rev !evaluated);
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked after coalesced drain: %d" n
  | None -> Alcotest.fail "Librarian lane entry missing"
;;

(* The regression this split exists for: a saturated librarian lane must not
   consume the deterministic lane's budget. A librarian unit parked in a
   provider round trip plus one queued behind it fills the librarian lane, and
   the deterministic write — one-shot, no retry — must still be admitted and
   must run while the librarian is still blocked. Before the split both kinds
   shared one budget, so this deterministic unit was dropped: measured live on
   2026-07-20 at 220 drops fleet-wide, keeper `analyst` losing 144 of 280. *)
let test_lanes_have_independent_budgets () =
  Lane.For_testing.reset ();
  let det_ran = ref false in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let p_release, set_release = Eio.Promise.create () in
      let lib1 =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
          Eio.Promise.await p_release)
      in
      let lib2 =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () -> ())
      in
      let lib3 =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () -> ())
      in
      let det =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Deterministic (fun () ->
          det_ran := true)
      in
      (match lib1, lib2 with
       | Lane.Submitted, Lane.Submitted -> ()
       | _ -> Alcotest.fail "librarian lane should admit two units");
      (match lib3 with
       | Lane.Coalesced -> ()
       | _ -> Alcotest.fail "librarian lane should coalesce at the bound");
      (match det with
       | Lane.Submitted -> ()
       | Lane.Coalesced ->
         Alcotest.fail "deterministic unit must not use Librarian coalescing"
       | Lane.Dropped ->
         Alcotest.fail "deterministic unit dropped by a saturated librarian lane"
       | Lane.Ran_inline -> Alcotest.fail "deterministic unit ran inline");
      (* Still blocked on the librarian round trip; the deterministic write must
         not be waiting behind it. *)
      Eio.Fiber.yield ();
      Eio.Fiber.yield ();
      Alcotest.(check bool)
        "deterministic write ran while librarian was in flight"
        true
        !det_ran;
      Eio.Promise.resolve set_release ()))
;;

(* A unit that raises releases the mutex and the pending slot, so the lane
   recovers and later units run. *)
let test_releases_on_raise () =
  Lane.For_testing.reset ();
  let latest_ran = ref false in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      Lane.init ~sw;
      let started, set_started = Eio.Promise.create () in
      let release, set_release = Eio.Promise.create () in
      let first =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
          Eio.Promise.resolve set_started ();
          Eio.Promise.await release;
          raise Test_boom)
      in
      Eio.Promise.await started;
      let latest =
        Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
          latest_ran := true)
      in
      (match first, latest with
       | Lane.Submitted, Lane.Submitted -> ()
       | _ -> Alcotest.fail "raise fixture submissions were not accepted");
      Eio.Promise.resolve set_release ()));
  Alcotest.(check bool) "latest runs after raising unit" true !latest_ran;
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked: %d" n
  | None -> Alcotest.fail "keeper entry missing"
;;

(* Cancellation during shutdown releases both the mutex and the pending slot. *)
let test_releases_on_cancel () =
  Lane.For_testing.reset ();
  let latest_ran = ref false in
  (try
     Eio_main.run (fun _env ->
       Eio.Switch.run (fun sw ->
         Lane.init ~sw;
         let started, set_started = Eio.Promise.create () in
         let never, _set_never = Eio.Promise.create () in
         let outcome =
           Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
             Eio.Promise.resolve set_started ();
             Eio.Promise.await never)
         in
         let latest =
           Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () ->
             latest_ran := true)
         in
         (match outcome with
          | Lane.Submitted -> ()
          | Lane.Coalesced -> Alcotest.fail "first cancel unit unexpectedly coalesced"
          | Lane.Ran_inline -> Alcotest.fail "cancel test unexpectedly ran inline"
          | Lane.Dropped -> Alcotest.fail "cancel test unexpectedly dropped");
         (match latest with
          | Lane.Submitted -> ()
          | Lane.Coalesced -> Alcotest.fail "first latest unit unexpectedly coalesced"
         | Lane.Ran_inline -> Alcotest.fail "latest cancel unit unexpectedly ran inline"
          | Lane.Dropped -> Alcotest.fail "latest cancel unit unexpectedly dropped");
         Eio.Promise.await started;
         Eio.Switch.fail sw Cancel_lane_test))
   with
   | Cancel_lane_test -> ());
  Alcotest.(check bool) "latest did not run after switch cancel" false !latest_ran;
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian with
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
    Lane.submit ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian (fun () -> raise Test_boom)
  in
  (match outcome with
   | Lane.Dropped -> ()
   | Lane.Submitted -> Alcotest.fail "expected Dropped, got Submitted"
   | Lane.Coalesced -> Alcotest.fail "expected Dropped, got Coalesced"
   | Lane.Ran_inline -> Alcotest.fail "expected Dropped, got Ran_inline");
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" ~lane:Lane.Librarian with
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
            "serializes within keeper"
            `Quick
            test_serializes_within_keeper
        ; Alcotest.test_case
            "independent across keepers"
            `Quick
            test_independent_across_keepers
        ; Alcotest.test_case
            "deterministic saturation drops"
            `Quick
            test_deterministic_saturation_drops
        ; Alcotest.test_case
            "librarian saturation coalesces latest"
            `Quick
            test_librarian_saturation_coalesces_latest
        ; Alcotest.test_case
            "lanes have independent budgets"
            `Quick
            test_lanes_have_independent_budgets
        ; Alcotest.test_case "releases on raise" `Quick test_releases_on_raise
        ; Alcotest.test_case "releases on cancel" `Quick test_releases_on_cancel
        ; Alcotest.test_case
            "finished switch drops without leak"
            `Quick
            test_finished_switch_drops_without_leak
        ] )
    ]
;;
