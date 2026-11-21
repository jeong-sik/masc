(* One call of an account at a time ([Runtime_account_call]): the door that
   refuses, the door that waits its turn, and what the two do to each other.

   A fiber that is forked is given the processor before the next step of the
   test looks, by a yield, so no case waits on a clock. *)

open Alcotest

module Call = Runtime_account_call
module Id = Authz_types.Provider_account_id

exception Cancel_waiter
exception Work_failed

let account_of hex =
  match Id.of_string (String.make 64 hex) with
  | Ok id -> id
  | Error _ -> fail "a made-up account id was refused"
;;

let one = account_of 'a'
let other = account_of 'b'

(* Whether a call that does not wait gets the account now. *)
let free account = Call.one_call_of account ~busy:() (fun _ -> Ok ()) = Ok ()

let test_refused_while_a_call_runs () =
  Eio_main.run
  @@ fun _env ->
  let inner =
    Call.one_call_of one ~busy:() (fun call ->
      check bool "the call names its account" true (Id.equal one (Call.account call));
      Ok (free one))
  in
  check bool "a second call is refused while the first runs" true (inner = Ok false);
  check bool "the account is free after the call" true (free one)
;;

let test_another_account_is_not_held () =
  Eio_main.run
  @@ fun _env ->
  let inner = Call.one_call_of one ~busy:() (fun _ -> Ok (free other)) in
  check bool "a call of another account runs meanwhile" true (inner = Ok true)
;;

let test_free_after_the_work_raises () =
  Eio_main.run
  @@ fun _env ->
  (match Call.one_call_of one ~busy:() (fun _ -> raise Work_failed) with
   | exception Work_failed -> ()
   | Ok () | Error () -> fail "the exception of the work did not surface");
  check bool "free after the call that does not wait raised" true (free one);
  (match Call.call_in_turn_of one (fun _ -> raise Work_failed) with
   | exception Work_failed -> ()
   | () -> fail "the exception of the work did not surface");
  check bool "free after the call that waits raised" true (free one)
;;

let test_waiting_calls_run_in_the_order_they_came () =
  Eio_main.run
  @@ fun _env ->
  let ran = ref [] in
  let first_may_end, end_first = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      Call.call_in_turn_of one (fun _ ->
        Eio.Promise.await first_may_end;
        ran := 0 :: !ran));
    Eio.Fiber.yield ();
    List.iter
      (fun n ->
         Eio.Fiber.fork ~sw (fun () ->
           Call.call_in_turn_of one (fun _ -> ran := n :: !ran));
         Eio.Fiber.yield ())
      [ 1; 2; 3 ];
    check (list int) "no call ran while the first holds the account" [] !ran;
    check bool "a call that does not wait is refused meanwhile" false (free one);
    check bool "another account is free meanwhile" true (free other);
    Eio.Promise.resolve end_first ();
    (* The first call ends and hands the account on while this fiber is behind
       it; the call it was handed to has not run yet. *)
    Eio.Fiber.yield ();
    check (list int) "only the first call ran so far" [ 0 ] (List.rev !ran);
    check bool "refused while the account is handed on" false (free one));
  check (list int) "the calls ran in the order they came" [ 0; 1; 2; 3 ] (List.rev !ran);
  check bool "the account is free after the last of them" true (free one)
;;

let test_a_cancelled_wait_does_not_take_the_call () =
  Eio_main.run
  @@ fun _env ->
  let ran = ref [] in
  let first_may_end, end_first = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      Call.call_in_turn_of one (fun _ ->
        Eio.Promise.await first_may_end;
        ran := "first" :: !ran));
    Eio.Fiber.yield ();
    (* Only the switch of the waiter fails, so the steps after it still run. *)
    (match
       Eio.Switch.run (fun waiter_sw ->
         Eio.Fiber.fork ~sw:waiter_sw (fun () ->
           Call.call_in_turn_of one (fun _ -> ran := "cancelled" :: !ran));
         Eio.Fiber.yield ();
         Eio.Switch.fail waiter_sw Cancel_waiter)
     with
     | () -> fail "the failure of the switch did not surface"
     | exception Cancel_waiter -> ());
    Eio.Fiber.fork ~sw (fun () ->
      Call.call_in_turn_of one (fun _ -> ran := "next" :: !ran));
    Eio.Fiber.yield ();
    check (list string) "nothing ran while the first holds the account" [] !ran;
    Eio.Promise.resolve end_first ());
  check
    (list string)
    "the cancelled wait never ran, and the one after it did"
    [ "first"; "next" ]
    (List.rev !ran);
  check bool "the account is free afterwards" true (free one)
;;

let test_a_wait_cancelled_after_the_hand_over_does_not_run () =
  Eio_main.run
  @@ fun _env ->
  let ran = ref [] in
  let first_may_end, end_first = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      Call.call_in_turn_of one (fun _ ->
        Eio.Promise.await first_may_end;
        ran := "first" :: !ran));
    Eio.Fiber.yield ();
    match
      Eio.Switch.run (fun waiter_sw ->
        Eio.Fiber.fork ~sw:waiter_sw (fun () ->
          Call.call_in_turn_of one (fun _ -> ran := "handed" :: !ran));
        (* The first call ends and hands the account to the waiter. The
           switch of the waiter fails before the waiter runs again. *)
        Eio.Promise.resolve end_first ();
        Eio.Fiber.yield ();
        (* The first call ended, so it handed the account to the waiter, and
           the waiter has not run. A schedule that cancels the waiter in the
           queue, or runs it first, fails here and does not pass unseen. *)
        check
          (list string)
          "the first call ended and handed the account on"
          [ "first" ]
          (List.rev !ran);
        Eio.Switch.fail waiter_sw Cancel_waiter)
    with
    | () -> fail "the failure of the switch did not surface"
    | exception Cancel_waiter -> ());
  check (list string) "the call handed to a cancelled wait did not run" [ "first" ] (List.rev !ran);
  check bool "the account is free afterwards" true (free one)
;;

let test_a_cancelled_fiber_does_not_run_on_a_free_account () =
  Eio_main.run
  @@ fun _env ->
  let ran = ref false in
  (match
     Eio.Switch.run (fun sw ->
       Eio.Switch.fail sw Cancel_waiter;
       Call.call_in_turn_of one (fun _ -> ran := true))
   with
   | () -> fail "the failure of the switch did not surface"
   | exception Cancel_waiter -> ());
  check bool "the work did not run" false !ran;
  check bool "the account is free afterwards" true (free one)
;;

(* A domain that runs no Eio loop has no fiber to wait in. Without the check
   before the lock, its call leaves the mutex inside the lock held, and the
   first call never ends. *)
let test_a_call_outside_a_fiber_leaves_a_busy_account_usable () =
  Eio_main.run
  @@ fun _env ->
  let ran = ref [] in
  let first_may_end, end_first = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      Call.call_in_turn_of one (fun _ ->
        Eio.Promise.await first_may_end;
        ran := "first" :: !ran));
    let raised =
      Domain.join
        (Domain.spawn (fun () ->
           match Call.call_in_turn_of one (fun _ -> ()) with
           | () -> false
           | exception Effect.Unhandled _ -> true))
    in
    check bool "the call from outside a fiber raised" true raised;
    Eio.Promise.resolve end_first ());
  check (list string) "the first call ended" [ "first" ] !ran;
  check bool "the account is free afterwards" true (free one)
;;

let test_try_acquire_returns_account_busy_without_blocking () =
  Eio_main.run
  @@ fun _env ->
  let held, release = Eio.Promise.create () in
  let started, mark_started = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      ignore
        (Call.try_acquire one (fun _ ->
           Eio.Promise.resolve mark_started ();
           Eio.Promise.await held;
           "holder")));
    Eio.Promise.await started;
    (match Call.try_acquire one (fun _ -> "unexpected") with
     | Call.Account_busy acct ->
       check bool "busy reports the contended account id" true (Id.equal one acct)
     | Call.Acquired _ -> fail "contended account was acquired concurrently");
    (match Call.try_acquire other (fun _ -> "sibling-ok") with
     | Call.Acquired "sibling-ok" -> ()
     | Call.Acquired _ | Call.Account_busy _ ->
       fail "sibling account was blocked by contended account");
    Eio.Promise.resolve release ());
  match Call.try_acquire one (fun _ -> "free-again") with
  | Call.Acquired "free-again" -> ()
  | Call.Acquired _ | Call.Account_busy _ ->
    fail "account was not released after holder completed"
;;

let () =
  run
    "runtime_account_call"
    [ ( "one call of an account at a time"
      , [ test_case "refused while a call runs" `Quick test_refused_while_a_call_runs
        ; test_case
            "try_acquire returns typed Account_busy without blocking"
            `Quick
            test_try_acquire_returns_account_busy_without_blocking
        ; test_case "another account is not held" `Quick test_another_account_is_not_held
        ; test_case "free after the work raises" `Quick test_free_after_the_work_raises
        ; test_case
            "waiting calls run in the order they came"
            `Quick
            test_waiting_calls_run_in_the_order_they_came
        ; test_case
            "a cancelled wait does not take the call"
            `Quick
            test_a_cancelled_wait_does_not_take_the_call
        ; test_case
            "a wait cancelled after the hand over does not run"
            `Quick
            test_a_wait_cancelled_after_the_hand_over_does_not_run
        ; test_case
            "a cancelled fiber does not run on a free account"
            `Quick
            test_a_cancelled_fiber_does_not_run_on_a_free_account
        ; test_case
            "a call outside a fiber leaves a busy account usable"
            `Quick
            test_a_call_outside_a_fiber_leaves_a_busy_account_usable
        ] )
    ]
;;
