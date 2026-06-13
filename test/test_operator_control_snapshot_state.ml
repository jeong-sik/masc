(** White-box tests for [Operator_control_snapshot.with_keeper_slot]
    introduced by PR-C2 (follow-up to PR-B / PR #20583).

    PR-B replaced the [int Atomic.t] counter and its
    [Eio.Switch.on_release] decrement callback with a typed variant.
    PR-C1 spread the same pattern to [fd_accountant].  PR-C2 takes a
    *different* shape for [operator_control_snapshot] -- the per-slot
    semaphore release was paired with the body via
    [Eio.Switch.on_release (fun () -> Eio.Semaphore.release …)], which
    is *cancel-safe* (it fires on both normal exit and
    [Eio.Cancel.Cancelled] unwind) but *not exception-safe*: a
    [Log.Dashboard.info] failure inside the callback would skip the
    release and leak the slot.

    The fix wraps acquire/release in a single [Fun.protect ~finally]
    scope inside a [with_keeper_slot] helper, so:

    1. The slot is released on the normal-exit path (Fun.protect
       finally always runs).
    2. The slot is released on the exception path (Fun.protect
       finally runs even when [f] raises).
    3. The slot is released on the [Eio.Cancel.Cancelled] path
       (Fun.protect finally runs before the Cancelled exception
       propagates; the Cancelled exception itself is re-raised).
    4. The slot is *not* double-released: the release lives in
       exactly one finally block.

    The white-box tests below drive [with_keeper_slot] directly,
    independent of [keepers_json], to verify the slot accounting
    invariant.  The test body is wrapped in
    [Eio_main.run @@ fun _env -> Eio.Switch.run @@ fun _sw -> ...]
    following the PR-C1.1 pattern: Fun.protect internally uses
    [Protect.protect] which performs [Cancel.Get_context], and
    [Eio.Switch.run] is the only handler for that effect. *)

open Alcotest
module OCS = Operator_control_snapshot

let test_with_keeper_slot_releases_on_normal_exit () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  let sem = Eio.Semaphore.make 1 in
  let helper_ran = ref false in
  let result =
    OCS.with_keeper_slot ~sem ~name:"test_normal_exit" (fun () ->
        helper_ran := true;
        "body-returned")
  in
  check bool "helper body executed" true !helper_ran ;
  check string "body return value preserved" "body-returned" result ;
  (* The slot is released on the normal-exit path.  We can
     re-acquire it without blocking.  Use a short timeout-style
     release via Eio.Time.sleep? No -- we are synchronous after
     Switch.run returns; the helper is fully complete. *)
  let acquire_succeeded =
    try
      Eio.Semaphore.acquire sem;
      Eio.Semaphore.release sem;
      true
    with
    | _ -> false
  in
  check bool "semaphore re-acquirable after helper (slot released)" true
    acquire_succeeded

let test_with_keeper_slot_releases_on_exception () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  let sem = Eio.Semaphore.make 1 in
  let body_raised = ref false in
  let helper_result =
    try
      let (_ : string) =
        OCS.with_keeper_slot ~sem ~name:"test_exception_exit" (fun () ->
            body_raised := true;
            raise (Failure "intentional body failure"))
      in
      Ok ()
    with
    | Failure msg when msg = "intentional body failure" -> Error `Body_raised
    | _ -> Error `Unexpected
  in
  check bool "body executed before raising" true !body_raised ;
  (match helper_result with
   | Error `Body_raised -> ()
   | Error `Unexpected ->
     Alcotest.fail "helper re-raised an unexpected exception"
   | Ok () ->
     Alcotest.fail "helper returned normally (should have re-raised)") ;
  (* Slot must be released even on the exception path. *)
  let acquire_succeeded =
    try
      Eio.Semaphore.acquire sem;
      Eio.Semaphore.release sem;
      true
    with
    | _ -> false
  in
  check bool "slot released after exception path" true acquire_succeeded

let test_with_keeper_slot_releases_on_cancelled () =
  Eio_main.run @@ fun env ->
  (* Outer switch is *not* cancelled; the cancel happens on
     an inner switch so the assertions can run cleanly
     after the helper fiber unwinds. *)
  Eio.Switch.run @@ fun outer_sw ->
  let sem = Eio.Semaphore.make 1 in
  let clock = Eio.Stdenv.clock env in
  let helper_unwound = ref false in
  (* Inner switch: cancelled by [Eio.Switch.fail] below.
     Wrap in try/with to swallow the [Failure] injected
     via [Eio.Switch.fail] (which propagates when the inner
     switch unwinds).  This isolates the cancel to the inner
     scope only; the outer switch and the surrounding
     assertions remain unaffected. *)
  (try
     Eio.Switch.run @@ fun inner_sw ->
     Eio.Fiber.fork ~sw:inner_sw (fun () ->
         try
           OCS.with_keeper_slot ~sem ~name:"test_cancelled_exit" (fun () ->
               (* Suspend indefinitely -- we are cancelled from outside. *)
               Eio.Time.sleep clock 60.0)
         with
         | Eio.Cancel.Cancelled _ -> helper_unwound := true
         | _ -> ());
     (* Wait long enough for the helper fiber to acquire
        the slot and enter its 60s sleep. *)
     Eio.Time.sleep clock 0.5 ;
     Eio.Switch.fail inner_sw (Failure "test cancel driver");
     (* Wait for the helper fiber to unwind. *)
     Eio.Time.sleep clock 0.5
   with
   | _ -> ()) ;
  ignore outer_sw ;
  check bool "helper fiber re-raised Cancelled (unwound)" true
    !helper_unwound ;
  (* Slot must be released -- run this on the *outer* switch
     which has not been cancelled, so [Eio.Semaphore.acquire]
     is not constrained by a Cancelled context. *)
  let acquire_succeeded =
    try
      Eio.Semaphore.acquire sem;
      Eio.Semaphore.release sem;
      true
    with
    | _ -> false
  in
  check bool "slot released after Cancel.Cancelled path" true
    acquire_succeeded

let test_with_keeper_slot_no_double_release () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  (* A fresh semaphore of capacity 2; two helper invocations
     release exactly one slot each.  After both helpers complete,
     the semaphore is full again (capacity 2, available 2).
     A double-release would push available above capacity, but
     Eio.Semaphore.release is bounded by capacity, so we cannot
     observe that directly.  Instead we verify the simpler
     invariant: both helpers release the same slot they
     acquired, so two helpers + two re-acquires should be
     straightforward. *)
  let sem = Eio.Semaphore.make 2 in
  let a_ran = ref false in
  let b_ran = ref false in
  OCS.with_keeper_slot ~sem ~name:"test_no_double_a" (fun () -> a_ran := true) ;
  OCS.with_keeper_slot ~sem ~name:"test_no_double_b" (fun () -> b_ran := true) ;
  check bool "first helper ran" true !a_ran ;
  check bool "second helper ran" true !b_ran ;
  (* After both helpers, the semaphore should be back at full
     capacity (2/2).  If a helper had double-released, the
     semaphore would have no observable over-release, but the
     helpers would have completed cleanly with two refills --
     which is what we observe.  This is a smoke test, not a
     double-release detector. *)
  let can_acquire_two =
    try
      Eio.Semaphore.acquire sem;
      Eio.Semaphore.acquire sem;
      Eio.Semaphore.release sem;
      Eio.Semaphore.release sem;
      true
    with
    | _ -> false
  in
  check bool "two slots re-acquirable after two helpers" true can_acquire_two

let () =
  run "Operator_control_snapshot_state"
    [ "with_keeper_slot release on normal exit"
    , [ test_case "slot is released after body returns normally" `Quick
          test_with_keeper_slot_releases_on_normal_exit ]
    ; "with_keeper_slot release on exception"
    , [ test_case "slot is released after body raises non-Cancelled" `Quick
          test_with_keeper_slot_releases_on_exception ]
    ; "with_keeper_slot release on cancel"
    , [ test_case "slot is released after body is Cancelled" `Quick
          test_with_keeper_slot_releases_on_cancelled ]
    ; "with_keeper_slot accounting"
    , [ test_case "two helpers release cleanly" `Quick
          test_with_keeper_slot_no_double_release ]
    ]
;;
