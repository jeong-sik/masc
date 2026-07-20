(** Bounded lane acquisition (#25398, RFC-0348).

    A hung durable write keeps its lane on purpose — the lane mutex is the only
    serialiser of writes to a record path, so releasing it mid-write would let a
    stale write rename over a newer record (RFC-0348 §2). What these tests pin
    is the other half: a caller that cannot acquire the lane must give up at the
    floor with a typed rejection instead of waiting forever, and that rejection
    must never be treated as published or reconcilable. *)

open Alcotest
module Keeper_msg_async = Masc.Keeper_msg_async

let gate = Keeper_msg_async.For_testing.bounded_lane_gate

(* Short enough to keep the suite fast, long enough that a loaded CI machine
   still completes several poll iterations before the floor. *)
let test_floor_s = 0.3

(* The floor needs an ambient clock, which server bootstrap installs via
   [Eio_context.set_clock]. Without it the gate deliberately falls back to the
   pre-existing unbounded wait, so a test that skipped this setup would exercise
   the fallback rather than the bound. *)
let with_eio f =
  Eio_main.run (fun env ->
    Eio_context.set_clock (Eio.Stdenv.clock env);
    f env)
;;

let test_free_lane_runs_body () =
  with_eio (fun _env ->
    let mutex = Eio.Mutex.create () in
    let ran = ref false in
    match gate ~floor_s:test_floor_s mutex (fun () -> ran := true; 42) with
    | Ok value ->
      check int "body result" 42 value;
      check bool "body ran" true !ran;
      check bool "lane released" true (Eio.Mutex.try_lock mutex)
    | Error _ -> fail "free lane must be acquired")
;;

let test_held_lane_rejects_at_floor () =
  with_eio (fun env ->
    let clock = Eio.Stdenv.clock env in
    let mutex = Eio.Mutex.create () in
    Eio.Mutex.lock mutex;
    let body_ran = ref false in
    let started = Eio.Time.now clock in
    match gate ~floor_s:test_floor_s mutex (fun () -> body_ran := true) with
    | Ok () -> fail "a held lane must not be acquired"
    | Error { waited_s; floor_s } ->
      let elapsed = Eio.Time.now clock -. started in
      check (float 0.001) "reported floor" test_floor_s floor_s;
      check bool "waited at least the floor" true (waited_s >= test_floor_s);
      (* The counterfactual: before this change the call blocked forever. An
         upper bound is what proves the wait is bounded at all. *)
      check bool "returned near the floor" true (elapsed < test_floor_s *. 10.);
      check bool "body never ran" false !body_ran;
      (* The holder still owns the lane. Releasing it early is the rejected
         design; this assertion is the executable form of that invariant. *)
      check bool "lane still held by the holder" false (Eio.Mutex.try_lock mutex))
;;

let test_lane_released_by_holder_is_acquirable () =
  with_eio (fun _env ->
    let mutex = Eio.Mutex.create () in
    Eio.Mutex.lock mutex;
    Eio.Mutex.unlock mutex;
    match gate ~floor_s:test_floor_s mutex (fun () -> "acquired") with
    | Ok value -> check string "body result" "acquired" value
    | Error _ -> fail "a released lane must be acquirable")
;;

let test_body_exception_releases_lane () =
  with_eio (fun _env ->
    let mutex = Eio.Mutex.create () in
    (match gate ~floor_s:test_floor_s mutex (fun () -> failwith "boom") with
     | Ok () -> fail "exception must propagate"
     | Error _ -> fail "exception must propagate, not become a lane rejection"
     | exception Failure _ -> ());
    check bool "lane released after exception" true (Eio.Mutex.try_lock mutex))
;;

(* --- Real lane table -------------------------------------------------------

   The tests above use a standalone mutex, which proves the bound but says
   nothing about whether keepers actually get *separate* lanes. The whole
   premise of #25398 — that a hung durable write wedges one keeper and not the
   fleet — rests on the lane key being [{base_path; keeper_name}]. These
   exercise the real lane tables. *)

let keeper_name_exn name =
  match Keeper_id.Keeper_name.of_string name with
  | Ok keeper_name -> keeper_name
  | Error reason -> failwith reason
;;

let persistence_lane = Keeper_msg_async.For_testing.keeper_persistence_lane
let submission_lane = Keeper_msg_async.For_testing.keeper_submission_lane
let base_path = "/tmp/masc-lane-floor-test"

(* Runs [hold] holding a lane while [probe] executes, then releases. The held
   fiber parks on a promise so the lane stays taken for exactly as long as the
   probe needs, with no sleep-based racing. *)
let while_lane_held ~lane ~keeper ~probe =
  let release, resolve_release = Eio.Promise.create () in
  let probe_result = ref None in
  Eio.Fiber.both
    (fun () ->
       let held =
         lane ~floor_s:test_floor_s ~base_path ~keeper_name:(keeper_name_exn keeper)
           (fun () -> Eio.Promise.await release)
       in
       match held with
       | Ok () -> ()
       | Error _ -> fail "the holder must acquire a free lane")
    (fun () ->
       probe_result := Some (probe ());
       Eio.Promise.resolve resolve_release ());
  match !probe_result with
  | Some result -> result
  | None -> fail "probe did not run"
;;

let test_other_keeper_lane_is_unaffected () =
  with_eio (fun _env ->
    let acquired =
      while_lane_held ~lane:persistence_lane ~keeper:"keeper-alpha" ~probe:(fun () ->
        persistence_lane
          ~floor_s:test_floor_s
          ~base_path
          ~keeper_name:(keeper_name_exn "keeper-beta")
          (fun () -> "beta ran"))
    in
    match acquired with
    | Ok value -> check string "beta acquired while alpha is wedged" "beta ran" value
    | Error _ ->
      fail "a wedged lane on one keeper must not block a different keeper")
;;

let test_same_keeper_other_base_path_is_unaffected () =
  with_eio (fun _env ->
    let acquired =
      while_lane_held ~lane:persistence_lane ~keeper:"keeper-alpha" ~probe:(fun () ->
        persistence_lane
          ~floor_s:test_floor_s
          ~base_path:(base_path ^ "-other")
          ~keeper_name:(keeper_name_exn "keeper-alpha")
          (fun () -> "other store ran"))
    in
    match acquired with
    | Ok value -> check string "other base_path acquired" "other store ran" value
    | Error _ -> fail "the lane key includes base_path, so this must not block")
;;

let test_same_keeper_same_lane_hits_the_floor () =
  with_eio (fun _env ->
    let acquired =
      while_lane_held ~lane:persistence_lane ~keeper:"keeper-alpha" ~probe:(fun () ->
        persistence_lane
          ~floor_s:test_floor_s
          ~base_path
          ~keeper_name:(keeper_name_exn "keeper-alpha")
          (fun () -> fail "body must not run on a wedged lane"))
    in
    match acquired with
    | Ok () -> fail "the same keeper's held lane must not be acquired"
    | Error { floor_s; waited_s } ->
      check (float 0.001) "reported floor" test_floor_s floor_s;
      check bool "waited at least the floor" true (waited_s >= test_floor_s))
;;

let test_submission_and_persistence_lanes_are_separate () =
  with_eio (fun _env ->
    let acquired =
      while_lane_held ~lane:persistence_lane ~keeper:"keeper-alpha" ~probe:(fun () ->
        submission_lane
          ~floor_s:test_floor_s
          ~base_path
          ~keeper_name:(keeper_name_exn "keeper-alpha")
          (fun () -> "submission ran"))
    in
    match acquired with
    | Ok value ->
      check string "submission lane is a separate table" "submission ran" value
    | Error _ ->
      fail "persistence and submission lanes must not share a table")
;;

(* The rejection is a new exit path out of the lane gate. If it skipped the
   pending-counter cleanup, the gauge would drift upward on every wedged lane
   and mislead exactly the operator trying to diagnose the hang. *)
let test_rejection_does_not_leak_pending_gauge () =
  with_eio (fun _env ->
    let pending () =
      let _waits, pending, _in_flight =
        Keeper_msg_async.For_testing.persistence_lane_observation ()
      in
      pending
    in
    let before = pending () in
    let rejected =
      while_lane_held ~lane:persistence_lane ~keeper:"keeper-gauge" ~probe:(fun () ->
        persistence_lane
          ~floor_s:test_floor_s
          ~base_path
          ~keeper_name:(keeper_name_exn "keeper-gauge")
          (fun () -> ()))
    in
    (match rejected with
     | Ok () -> fail "expected the probe to be rejected"
     | Error _ -> ());
    check int "pending gauge returned to its starting value" before (pending ()))
;;

(* Wiring: a lane rejection must not be mistaken for a published write. This is
   what routes the caller to plain rejection instead of the reconciliation path
   that deletes record files (RFC-0348 §2.2). *)
let test_lane_rejection_is_not_published () =
  let json =
    Keeper_msg_async.submit_error_to_json
      (Keeper_msg_async.Submit_lane_unavailable { waited_s = 61.0; floor_s = 60.0 })
  in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
     | Some (`String code) -> check string "error code" "keeper_lane_unavailable" code
     | Some _ | None -> fail "submit error json must carry a string error code")
  | _ -> fail "submit error json must be an object"
;;

let test_floor_default_is_within_documented_bounds () =
  let floor = Keeper_msg_async.For_testing.lane_acquire_floor_seconds in
  check bool "floor at or above the documented minimum" true (floor >= 10.0);
  check bool "floor at or below the documented maximum" true (floor <= 600.0)
;;

let () =
  run
    "keeper_msg_async lane floor"
    [ ( "bounded acquisition"
      , [ test_case "free lane runs body" `Quick test_free_lane_runs_body
        ; test_case "held lane rejects at floor" `Quick test_held_lane_rejects_at_floor
        ; test_case
            "released lane is acquirable"
            `Quick
            test_lane_released_by_holder_is_acquirable
        ; test_case "body exception releases lane" `Quick test_body_exception_releases_lane
        ] )
    ; ( "lane isolation"
      , [ test_case
            "another keeper is unaffected"
            `Quick
            test_other_keeper_lane_is_unaffected
        ; test_case
            "same keeper in another store is unaffected"
            `Quick
            test_same_keeper_other_base_path_is_unaffected
        ; test_case
            "same keeper same lane hits the floor"
            `Quick
            test_same_keeper_same_lane_hits_the_floor
        ; test_case
            "submission and persistence lanes are separate"
            `Quick
            test_submission_and_persistence_lanes_are_separate
        ; test_case
            "rejection does not leak the pending gauge"
            `Quick
            test_rejection_does_not_leak_pending_gauge
        ] )
    ; ( "rejection wiring"
      , [ test_case
            "lane rejection is not published"
            `Quick
            test_lane_rejection_is_not_published
        ; test_case
            "floor default within documented bounds"
            `Quick
            test_floor_default_is_within_documented_bounds
        ] )
    ]
;;
