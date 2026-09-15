(* [Watched_work.run] keeps the work's outcome when the work finished as
   its watcher fired. The mock clock puts the watcher's wake-up ahead of
   the work's in the run queue on purpose: the work waits on a promise that
   is resolved right after the clock passes the watcher's deadline. *)
open Alcotest

let deadline_s = 1.0

let watcher clock () =
  Eio.Time.sleep clock deadline_s;
  Error "the watcher's verdict"
;;

let test_work_that_finished_as_the_watcher_fired_is_the_result () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let answer, arrive = Eio.Promise.create () in
  let raced =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Watched_work.run ~watcher:(watcher clock) (fun () -> Ok (Eio.Promise.await answer)))
  in
  Eio_mock.Clock.set_time clock deadline_s;
  Eio.Promise.resolve arrive "the answer";
  match Eio.Promise.await_exn raced with
  | Ok answer -> check string "the work's result stands" "the answer" answer
  | Error verdict -> failf "the work's result was dropped for %s" verdict
;;

let test_work_that_never_finishes_takes_the_watchers_verdict () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let never, _ = Eio.Promise.create () in
  let raced =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Watched_work.run ~watcher:(watcher clock) (fun () -> Ok (Eio.Promise.await never)))
  in
  Eio_mock.Clock.set_time clock deadline_s;
  match Eio.Promise.await_exn raced with
  | Error verdict -> check string "the watcher decided" "the watcher's verdict" verdict
  | Ok () -> fail "the work never finished, yet the watcher's verdict was not the result"
;;

(* The work's own failure is the work's outcome too, not the watcher's. *)
let test_work_that_failed_as_the_watcher_fired_keeps_its_failure () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let answer, arrive = Eio.Promise.create () in
  let raced =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Watched_work.run ~watcher:(watcher clock) (fun () ->
        Eio.Promise.await answer;
        Error "the work's own failure"))
  in
  Eio_mock.Clock.set_time clock deadline_s;
  Eio.Promise.resolve arrive ();
  match Eio.Promise.await_exn raced with
  | Error failure -> check string "the work's failure stands" "the work's own failure" failure
  | Ok () -> fail "the work failed, yet something reported success"
;;

(* The watcher is armed before the work starts, so its deadline counts from
   the call. A work that spends the whole budget before it pauses for the
   first time is already past the deadline at that pause; a watcher that only
   armed there would hand the work the budget a second time. *)
let test_the_budget_counts_from_the_call_not_from_the_works_first_pause () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  match
    Watched_work.run ~watcher:(watcher clock) (fun () ->
      Eio_mock.Clock.set_time clock (deadline_s +. 1.0);
      Eio.Fiber.yield ();
      Ok "the answer")
  with
  | Error verdict -> check string "the watcher decided" "the watcher's verdict" verdict
  | Ok answer ->
    failf "the budget was gone before the work paused, yet it returned %s" answer
;;

let () =
  Alcotest.run
    "watched work"
    [ ( "the work's outcome stands"
      , [ test_case
            "work that finished as the watcher fired is the result"
            `Quick
            test_work_that_finished_as_the_watcher_fired_is_the_result
        ; test_case
            "work that never finishes takes the watcher's verdict"
            `Quick
            test_work_that_never_finishes_takes_the_watchers_verdict
        ; test_case
            "work that failed as the watcher fired keeps its failure"
            `Quick
            test_work_that_failed_as_the_watcher_fired_keeps_its_failure
        ; test_case
            "the budget counts from the call, not from the work's first pause"
            `Quick
            test_the_budget_counts_from_the_call_not_from_the_works_first_pause
        ] )
    ]
;;
