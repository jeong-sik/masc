(** Tests for Keeper_memory_lane (RFC-0252).

    The lane detaches post-turn memory work from the keeper turn lane:
    serialized within a keeper, independent across keepers, bounded, and
    leak-safe on a raising unit. *)

module Lane = Masc.Keeper_memory_lane

let base_path = "/tmp/test-memory-lane"

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
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          failwith "boom")
      in
      Eio.Fiber.yield ();
      Eio.Fiber.yield ();
      let _ =
        Lane.submit ~base_path ~keeper_name:"k1" (fun () ->
          ran_after := true)
      in
      Eio.Fiber.yield ();
      Eio.Fiber.yield ()));
  Alcotest.(check bool) "lane recovered after raise" true !ran_after;
  match Lane.For_testing.pending ~base_path ~keeper_name:"k1" with
  | Some 0 -> ()
  | Some n -> Alcotest.failf "pending leaked: %d" n
  | None -> Alcotest.fail "keeper entry missing"
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
            "serializes within keeper"
            `Quick
            test_serializes_within_keeper
        ; Alcotest.test_case
            "independent across keepers"
            `Quick
            test_independent_across_keepers
        ; Alcotest.test_case "saturation drops" `Quick test_saturation_drops
        ; Alcotest.test_case "releases on raise" `Quick test_releases_on_raise
        ] )
    ]
;;
