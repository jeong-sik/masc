(* What a queue watcher ([on_queue]) sees, and that a watcher that raises
   leaves no slot held and no waiter queued. One slot is held while a second
   request asks for it; the record lists what the watcher and the request
   did, in order. *)
open Alcotest
module Slot_scheduler = Llm_provider.Slot_scheduler

let settle () =
  for _ = 1 to 20 do
    Eio.Fiber.yield ()
  done
;;

let watcher record =
  fun () ->
  record "queued";
  function
  | Slot_scheduler.Wait_granted -> record "granted"
  | Slot_scheduler.Wait_expired -> record "expired"
;;

let check_empty scheduler =
  let snapshot = Slot_scheduler.snapshot scheduler in
  check int "no slot is held" 0 snapshot.active;
  check int "nobody is queued" 0 snapshot.queue_length
;;

(* Runs [request] while one slot of one is held, lets the holder go once
   [request] has had its turn, and returns the record. *)
let with_held_slot request =
  Eio_mock.Backend.run
  @@ fun () ->
  let scheduler = Slot_scheduler.create ~max_slots:1 ~priority_run_limit:None in
  let log = ref [] in
  let record entry = log := entry :: !log in
  let release, resolve = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      Slot_scheduler.with_permit ~admission_class:Standard scheduler (fun () ->
        Eio.Promise.await release));
    settle ();
    request ~sw ~scheduler ~record;
    settle ();
    Eio.Promise.resolve resolve ());
  check_empty scheduler;
  List.rev !log
;;

let test_a_slot_granted_at_once_is_not_watched () =
  Eio_mock.Backend.run
  @@ fun () ->
  let scheduler = Slot_scheduler.create ~max_slots:1 ~priority_run_limit:None in
  let log = ref [] in
  let record entry = log := entry :: !log in
  Slot_scheduler.with_permit
    ~on_queue:(watcher record)
    ~admission_class:Standard
    scheduler
    (fun () -> record "body");
  check (list string) "only the body ran" [ "body" ] (List.rev !log);
  check_empty scheduler
;;

let test_a_granted_wait_is_reported_before_the_body () =
  check
    (list string)
    "queued, granted, then the body"
    [ "queued"; "granted"; "body" ]
    (with_held_slot (fun ~sw ~scheduler ~record ->
       Eio.Fiber.fork ~sw (fun () ->
         Slot_scheduler.with_permit
           ~on_queue:(watcher record)
           ~admission_class:Priority
           scheduler
           (fun () -> record "body"))))
;;

let test_an_expired_wait_is_reported_and_runs_no_body () =
  check
    (list string)
    "queued, then expired"
    [ "queued"; "expired"; "refused" ]
    (with_held_slot (fun ~sw ~scheduler ~record ->
       let clock = Eio_mock.Clock.make () in
       Eio_mock.Clock.set_time clock 0.0;
       Eio.Fiber.fork ~sw (fun () ->
         match
           Slot_scheduler.with_permit_until
             ~on_queue:(watcher record)
             ~clock
             ~deadline_at:1.0
             ~admission_class:Standard
             scheduler
             (fun () -> record "body")
         with
         | Ok () -> ()
         | Error `Permit_wait_expired -> record "refused");
       settle ();
       Eio_mock.Clock.set_time clock 1.0))
;;

let test_a_cancelled_wait_reports_only_that_it_queued () =
  check
    (list string)
    "queued, then nothing"
    [ "queued"; "cancelled" ]
    (with_held_slot (fun ~sw ~scheduler ~record ->
       let stop, resolve_stop = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         Eio.Fiber.first
           (fun () ->
              Slot_scheduler.with_permit
                ~on_queue:(watcher record)
                ~admission_class:Standard
                scheduler
                (fun () -> record "body"))
           (fun () ->
              Eio.Promise.await stop;
              record "cancelled"));
       settle ();
       Eio.Promise.resolve resolve_stop ()))
;;

exception Watcher_failed

let test_a_raising_watcher_leaves_no_waiter_queued () =
  check
    (list string)
    "the request failed before it waited"
    [ "watcher raised" ]
    (with_held_slot (fun ~sw ~scheduler ~record ->
       Eio.Fiber.fork ~sw (fun () ->
         match
           Slot_scheduler.with_permit
             ~on_queue:(fun () -> raise Watcher_failed)
             ~admission_class:Standard
             scheduler
             (fun () -> record "body")
         with
         | () -> ()
         | exception Watcher_failed -> record "watcher raised")))
;;

let test_a_raising_finisher_gives_the_slot_back () =
  check
    (list string)
    "the request failed after it was granted"
    [ "queued"; "finisher raised" ]
    (with_held_slot (fun ~sw ~scheduler ~record ->
       Eio.Fiber.fork ~sw (fun () ->
         match
           Slot_scheduler.with_permit
             ~on_queue:(fun () ->
               record "queued";
               fun (_ : Slot_scheduler.wait_end) -> raise Watcher_failed)
             ~admission_class:Standard
             scheduler
             (fun () -> record "body")
         with
         | () -> ()
         | exception Watcher_failed -> record "finisher raised")))
;;

let () =
  run
    "Slot_scheduler queue watch"
    [ ( "on_queue"
      , [ test_case
            "a slot granted at once is not watched"
            `Quick
            test_a_slot_granted_at_once_is_not_watched
        ; test_case
            "a granted wait is reported before the body"
            `Quick
            test_a_granted_wait_is_reported_before_the_body
        ; test_case
            "an expired wait is reported and runs no body"
            `Quick
            test_an_expired_wait_is_reported_and_runs_no_body
        ; test_case
            "a cancelled wait reports only that it queued"
            `Quick
            test_a_cancelled_wait_reports_only_that_it_queued
        ; test_case
            "a raising watcher leaves no waiter queued"
            `Quick
            test_a_raising_watcher_leaves_no_waiter_queued
        ; test_case
            "a raising finisher gives the slot back"
            `Quick
            test_a_raising_finisher_gives_the_slot_back
        ] )
    ]
;;
