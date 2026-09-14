(* A slot granted in the same instant a waiter's deadline passes is the
   waiter's. [Eio.Time.with_timeout] races the wait against a timer with
   [Fiber.first], which keeps the first result and drops the second: when
   the timer's wake-up is queued ahead of the grant's, the wait used to end
   "expired" with the slot already handed over and counted, and nothing ever
   returned it. On a binding with one permit that was the endpoint saturated
   for the rest of the process. The mock clock puts the two wake-ups in the
   run queue in that order on purpose. *)
open Alcotest
module Slot_scheduler = Llm_provider.Slot_scheduler

let deadline_s = 1.0

let test_a_slot_granted_as_the_deadline_passes_is_owned_and_returned () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  let scheduler = Slot_scheduler.create ~max_slots:1 in
  Eio.Switch.run
  @@ fun sw ->
  let ran = ref false in
  let waiter =
    Slot_scheduler.with_permit scheduler (fun () ->
      (* The only slot is held here. The waiter joins the queue and sleeps
         toward its deadline; [fork_promise] runs it until it blocks. *)
      let waiter =
        Eio.Fiber.fork_promise ~sw (fun () ->
          Slot_scheduler.with_permit_until ~clock ~deadline_at:deadline_s scheduler (fun () ->
            ran := true))
      in
      check
        int
        "the waiter is queued behind the held slot"
        1
        (Slot_scheduler.snapshot scheduler).Slot_scheduler.queue_length;
      (* The deadline passes first: the timer's wake-up is queued. Returning
         from this function releases the slot, which grants it to the waiter
         and queues the waiter's wake-up behind the timer's. *)
      Eio_mock.Clock.set_time clock deadline_s;
      waiter)
  in
  (match Eio.Promise.await_exn waiter with
   | Ok () -> ()
   | Error `Permit_wait_expired -> fail "the slot granted at the deadline was dropped");
  check bool "the waiter ran with the slot it was granted" true !ran;
  let snapshot = Slot_scheduler.snapshot scheduler in
  check int "the slot came back" 0 snapshot.Slot_scheduler.active;
  check int "nobody is left in the queue" 0 snapshot.Slot_scheduler.queue_length
;;

(* The ordinary expiry: no grant arrives, the waiter leaves the queue and
   the slot stays with its holder. *)
let test_a_wait_that_ends_before_any_grant_leaves_the_queue () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  let scheduler = Slot_scheduler.create ~max_slots:1 in
  Eio.Switch.run
  @@ fun sw ->
  let release, resolve_release = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Slot_scheduler.with_permit scheduler (fun () -> Eio.Promise.await release));
  let waiter =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Slot_scheduler.with_permit_until ~clock ~deadline_at:deadline_s scheduler (fun () ->
        fail "no slot was free; the waiter must not run"))
  in
  Eio_mock.Clock.set_time clock deadline_s;
  (match Eio.Promise.await_exn waiter with
   | Error `Permit_wait_expired -> ()
   | Ok () -> fail "the waiter reported a slot it could not have been granted");
  let snapshot = Slot_scheduler.snapshot scheduler in
  check int "the holder still has the slot" 1 snapshot.Slot_scheduler.active;
  check int "the expired waiter left the queue" 0 snapshot.Slot_scheduler.queue_length;
  Eio.Promise.resolve resolve_release ();
  Eio.Fiber.yield ();
  check int "the holder returned the slot" 0 (Slot_scheduler.snapshot scheduler).Slot_scheduler.active
;;

let () =
  Alcotest.run
    "slot scheduler deadline ownership"
    [ ( "with_permit_until"
      , [ test_case
            "a slot granted as the deadline passes is owned and returned"
            `Quick
            test_a_slot_granted_as_the_deadline_passes_is_owned_and_returned
        ; test_case
            "a wait that ends before any grant leaves the queue"
            `Quick
            test_a_wait_that_ends_before_any_grant_leaves_the_queue
        ] )
    ]
;;
