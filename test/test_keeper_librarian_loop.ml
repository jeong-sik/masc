(** Tests for {!Masc.Keeper_librarian_loop} (RFC librarian-lifecycle §4.3,
    §4.5): a loop runs once at start and then only when woken, keeps a wake
    that arrives mid-run, does not run again after a failure until woken (I5),
    records how its last pass ended, and a retire cancels the pass and
    takes no wake afterwards. The pass is a fake: what a pass does is the
    consumer's business, tested with it. *)

open Alcotest

module Loop = Masc.Keeper_librarian_loop
module Consumer = Masc.Keeper_librarian_durable_consumer

let key = "/tmp/keepers/loop-under-test"

(* Let the daemon run until it parks or blocks. *)
let settle () =
  for _ = 1 to 20 do
    Eio.Fiber.yield ()
  done
;;

let with_loop ~pass f =
  Loop.For_testing.reset ();
  Eio_main.run
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  Loop.For_testing.start_with ~sw ~key ~pass;
  f ();
  (* The daemon parks on a promise nobody resolves; the release drops it. *)
  Loop.For_testing.retire_key key (fun () -> ())
;;

let test_a_loop_runs_once_at_start_then_parks () =
  let passes = ref 0 in
  with_loop
    ~pass:(fun () ->
      incr passes;
      Loop.Drained)
    (fun () ->
       settle ();
       check int "one pass at start" 1 !passes;
       check bool "then parked" true (Loop.For_testing.is_parked key);
       settle ();
       check int "no pass without a wake" 1 !passes;
       Loop.For_testing.wake_key key;
       settle ();
       check int "a wake runs one more" 2 !passes)
;;

(* A wake that lands while a pass runs is not lost: the pass is followed by
   another (§4.3). *)
let test_a_wake_during_a_run_is_kept () =
  let passes = ref 0 in
  let gate = ref None in
  let pass () =
    incr passes;
    (if !passes = 1
     then (
       let promise, resolver = Eio.Promise.create () in
       gate := Some resolver;
       Eio.Promise.await promise));
    Loop.Drained
  in
  with_loop ~pass (fun () ->
    settle ();
    check int "the first pass is running" 1 !passes;
    Loop.For_testing.wake_key key;
    settle ();
    check int "the wake waits for the running pass" 1 !passes;
    (match !gate with
     | Some resolver -> Eio.Promise.resolve resolver ()
     | None -> fail "the first pass did not block");
    settle ();
    check int "the kept wake runs a second pass" 2 !passes)
;;

(* After a pass that stopped, the loop waits for a wake; it does not retry
   on its own (I5). *)
let test_a_stopped_pass_waits_for_a_wake () =
  let passes = ref 0 in
  with_loop
    ~pass:(fun () ->
      incr passes;
      Loop.Stopped Consumer.Keeper_meta_absent)
    (fun () ->
       settle ();
       check int "one pass" 1 !passes;
       check bool "parked after the stop" true (Loop.For_testing.is_parked key);
       (match Loop.For_testing.measurement_key key with
        | Some { Loop.last_pass = Loop.Stopped Consumer.Keeper_meta_absent; unread; _ } ->
          (* A fake pass counts nothing; the production pass is what takes the
             number, and the consumer's own test pins it. *)
          check bool "a fake pass leaves no count" true (Option.is_none unread)
        | Some _ -> fail "the measurement does not say how the pass ended"
        | None -> fail "no measurement after a pass");
       Loop.For_testing.wake_key key;
       settle ();
       check int "a wake tries again" 2 !passes)
;;

(* A retire cancels the running pass, waits for the loop to exit, and a wake
   that follows it starts nothing until the release. The consumer keeps its
   own writes under a cancel shield, so a cancelled pass leaves nothing torn. *)
let test_a_retire_cancels_the_pass_and_takes_no_wake () =
  Loop.For_testing.reset ();
  Eio_main.run
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let passes = ref 0 in
  let finished = ref 0 in
  let pass () =
    incr passes;
    let promise, _resolver = Eio.Promise.create () in
    Eio.Promise.await promise;
    incr finished;
    Loop.Drained
  in
  Loop.For_testing.start_with ~sw ~key ~pass;
  settle ();
  check int "a pass is running" 1 !passes;
  Loop.For_testing.retire_key key (fun () ->
    check int "the pass did not run to its end" 0 !finished;
    Loop.For_testing.wake_key key;
    settle ();
    check int "a wake after retire starts nothing" 1 !passes);
  check bool "the tombstone is gone" false (Loop.For_testing.is_parked key)
;;

(* The callback owns the only interval in which a tombstone may exist. Even
   cancellation or another exception cannot strand it and silence all later
   wakes. Starting another loop proves the key became admissible again. *)
let test_a_retire_releases_the_tombstone_when_work_raises () =
  Loop.For_testing.reset ();
  Eio_main.run
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  check bool "the callback exception escapes" true
    (match Loop.For_testing.retire_key key (fun () -> raise Exit) with
     | exception Exit -> true
     | () -> false);
  let passes = ref 0 in
  Loop.For_testing.start_with ~sw ~key ~pass:(fun () -> incr passes; Loop.Drained);
  settle ();
  check int "the released key admits a new loop" 1 !passes;
  Loop.For_testing.retire_key key (fun () -> ())
;;

let () =
  run
    "keeper_librarian_loop"
    [ ( "loop"
      , [ test_case "runs once at start then parks" `Quick
            test_a_loop_runs_once_at_start_then_parks
        ; test_case "a wake during a run is kept" `Quick test_a_wake_during_a_run_is_kept
        ; test_case "a stopped pass waits for a wake" `Quick
            test_a_stopped_pass_waits_for_a_wake
        ; test_case "a retire cancels the pass and takes no wake" `Quick
            test_a_retire_cancels_the_pass_and_takes_no_wake
        ; test_case "a raising retire callback releases the tombstone" `Quick
            test_a_retire_releases_the_tombstone_when_work_raises
        ] )
    ]
;;
