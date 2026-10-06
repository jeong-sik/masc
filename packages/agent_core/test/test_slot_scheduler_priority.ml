(* How a freed slot is shared between the two admission classes. One slot is
   held while the waiters queue in a stated order; releasing it lets each
   waiter run in turn, record itself and give the slot back, so the record
   is the order the scheduler granted. The mock backend runs every fiber
   until it blocks, so the queue order is the fork order. *)
open Alcotest
module Slot_scheduler = Llm_provider.Slot_scheduler
module Admission_class = Llm_provider.Admission_class

let label_class label : Admission_class.t =
  match label.[0] with
  | 'P' -> Priority
  | 'S' -> Standard
  | _ -> invalid_arg ("waiter label must start with P or S: " ^ label)
;;

(* Grants the slot to [waiters] after they have all queued behind a holder
   and returns the order they ran in. *)
let grant_order ~priority_run_limit waiters =
  Eio_mock.Backend.run
  @@ fun () ->
  let scheduler = Slot_scheduler.create ~max_slots:1 ~priority_run_limit in
  let granted = ref [] in
  (* The switch returns once every waiter has run and given its slot back. *)
  Eio.Switch.run (fun sw ->
    let release, resolve_release = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Slot_scheduler.with_permit ~admission_class:Standard scheduler (fun () ->
        Eio.Promise.await release));
    List.iter
      (fun label ->
         Eio.Fiber.fork ~sw (fun () ->
           Slot_scheduler.with_permit
             ~admission_class:(label_class label)
             scheduler
             (fun () -> granted := label :: !granted)))
      waiters;
    check
      int
      "every waiter queued behind the holder"
      (List.length waiters)
      (Slot_scheduler.snapshot scheduler).queue_length;
    Eio.Promise.resolve resolve_release ());
  let snapshot = Slot_scheduler.snapshot scheduler in
  check int "every slot came back" 0 snapshot.active;
  check int "nobody is left in the queue" 0 snapshot.queue_length;
  List.rev !granted
;;

let test_without_a_limit_both_classes_share_arrival_order () =
  check
    (list string)
    "arrival order"
    [ "S1"; "P1"; "S2"; "P2" ]
    (grant_order ~priority_run_limit:None [ "S1"; "P1"; "S2"; "P2" ])
;;

let test_priority_goes_first_until_its_run_limit () =
  check
    (list string)
    "three priority grants, then the oldest standard"
    [ "P1"; "P2"; "P3"; "S1"; "P4"; "P5"; "S2" ]
    (grant_order
       ~priority_run_limit:(Some 3)
       [ "S1"; "S2"; "P1"; "P2"; "P3"; "P4"; "P5" ])
;;

let test_priority_without_waiting_standard_is_not_counted () =
  (* Only priority waiters: no standard waiter is passed, so the run limit
     never applies and arrival order holds. *)
  check
    (list string)
    "priority alone keeps arrival order"
    [ "P1"; "P2"; "P3" ]
    (grant_order ~priority_run_limit:(Some 1) [ "P1"; "P2"; "P3" ])
;;

let test_a_priority_waiter_that_left_is_skipped () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  let scheduler = Slot_scheduler.create ~max_slots:1 ~priority_run_limit:(Some 1) in
  let granted = ref [] in
  (Eio.Switch.run
   @@ fun sw ->
  let release, resolve_release = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Slot_scheduler.with_permit ~admission_class:Standard scheduler (fun () ->
      Eio.Promise.await release));
  let enqueue label =
    Eio.Fiber.fork ~sw (fun () ->
      Slot_scheduler.with_permit
        ~admission_class:(label_class label)
        scheduler
        (fun () -> granted := label :: !granted))
  in
  enqueue "S1";
  let leaving =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Slot_scheduler.with_permit_until
        ~clock
        ~deadline_at:1.0
        ~admission_class:Priority
        scheduler
        (fun () -> fail "the expired waiter must not run"))
  in
  enqueue "P2";
  Eio_mock.Clock.set_time clock 1.0;
  (match Eio.Promise.await_exn leaving with
   | Error `Permit_wait_expired -> ()
   | Ok () -> fail "the waiter reported a slot it could not have been granted");
  check int "the expired waiter left its queue" 2 (Slot_scheduler.snapshot scheduler).queue_length;
  Eio.Promise.resolve resolve_release ());
  check int "every slot came back" 0 (Slot_scheduler.snapshot scheduler).active;
  check
    (list string)
    "the remaining priority waiter goes first, then standard"
    [ "P2"; "S1" ]
    (List.rev !granted)
;;

let test_a_run_limit_below_one_is_refused () =
  match Slot_scheduler.create ~max_slots:1 ~priority_run_limit:(Some 0) with
  | (_ : Slot_scheduler.t) -> fail "a run limit of zero was accepted"
  | exception Invalid_argument _ -> ()
;;

(* Every arrival order of a few waiters of each class, granted with a run
   limit: within a class the order is kept, every waiter is granted once,
   and while a standard waiter is still queued no more than [limit]
   priority grants come in a row. *)
let test_random_arrivals_keep_the_invariants () =
  let rng = Random.State.make [| 20261006 |] in
  for _case = 1 to 200 do
    let limit = 1 + Random.State.int rng 3 in
    let count = 2 + Random.State.int rng 8 in
    let p = ref 0
    and s = ref 0 in
    let waiters =
      List.init count (fun _ ->
        if Random.State.bool rng
        then (
          incr p;
          Printf.sprintf "P%d" !p)
        else (
          incr s;
          Printf.sprintf "S%d" !s))
    in
    let order = grant_order ~priority_run_limit:(Some limit) waiters in
    let name = String.concat " " waiters in
    check int (name ^ ": every waiter granted once") count (List.length order);
    let of_class c = List.filter (fun l -> label_class l = c) in
    check
      (list string)
      (name ^ ": priority in arrival order")
      (of_class Priority waiters)
      (of_class Priority order);
    check
      (list string)
      (name ^ ": standard in arrival order")
      (of_class Standard waiters)
      (of_class Standard order);
    let standard_left = ref !s in
    let run = ref 0 in
    List.iter
      (fun label ->
         match label_class label with
         | Standard ->
           decr standard_left;
           run := 0
         | Priority ->
           if !standard_left > 0
           then (
             incr run;
             if !run > limit
             then
               failf
                 "%s: %d priority grants in a row while standard waited (limit %d)"
                 name
                 !run
                 limit))
      order
  done
;;

let () =
  run
    "slot_scheduler_priority"
    [ ( "grant order"
      , [ test_case
            "without a limit both classes share arrival order"
            `Quick
            test_without_a_limit_both_classes_share_arrival_order
        ; test_case
            "priority goes first until its run limit"
            `Quick
            test_priority_goes_first_until_its_run_limit
        ; test_case
            "priority without a waiting standard is not counted"
            `Quick
            test_priority_without_waiting_standard_is_not_counted
        ; test_case
            "a priority waiter that left is skipped"
            `Quick
            test_a_priority_waiter_that_left_is_skipped
        ; test_case
            "a run limit below one is refused"
            `Quick
            test_a_run_limit_below_one_is_refused
        ; test_case
            "random arrivals keep the invariants"
            `Quick
            test_random_arrivals_keep_the_invariants
        ] )
    ]
;;
