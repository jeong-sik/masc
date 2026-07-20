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
