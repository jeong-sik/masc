(* Changing a scheduler's allowance while one slot is held and waiters
   queue behind it. The mock backend runs every fiber until it blocks, so
   the queue order is the fork order and a woken waiter has run by the time
   the forking fiber is scheduled again. *)
open Alcotest
module Slot_scheduler = Llm_provider.Slot_scheduler
module Admission_class = Llm_provider.Admission_class

let label_class label : Admission_class.t =
  match label.[0] with
  | 'P' -> Priority
  | 'S' -> Standard
  | _ -> invalid_arg ("waiter label must start with P or S: " ^ label)
;;

let check_counts scheduler ~what ~active ~queued =
  let snapshot = Slot_scheduler.snapshot scheduler in
  check int (what ^ ": slots held") active snapshot.active;
  check int (what ^ ": waiters queued") queued snapshot.queue_length
;;

(* One slot is held while [before] queue; [change] runs, then [after]
   queue; then the holder gives its slot back. Returns the order the
   waiters ran in. *)
let grant_order ~priority_run_limit ~before ~change ~after =
  Eio_mock.Backend.run
  @@ fun () ->
  let scheduler = Slot_scheduler.create ~max_slots:1 ~priority_run_limit in
  let granted = ref [] in
  Eio.Switch.run (fun sw ->
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
    List.iter enqueue before;
    change scheduler;
    List.iter enqueue after;
    check_counts
      scheduler
      ~what:"before the holder returns"
      ~active:1
      ~queued:(List.length before + List.length after);
    Eio.Promise.resolve resolve_release ());
  check_counts scheduler ~what:"after every waiter ran" ~active:0 ~queued:0;
  List.rev !granted
;;

let test_raising_the_permits_grants_waiters_at_once () =
  Eio_mock.Backend.run
  @@ fun () ->
  let scheduler = Slot_scheduler.create ~max_slots:1 ~priority_run_limit:None in
  let granted = ref [] in
  Eio.Switch.run (fun sw ->
    let release, resolve_release = Eio.Promise.create () in
    let hold label =
      Eio.Fiber.fork ~sw (fun () ->
        Slot_scheduler.with_permit ~admission_class:Standard scheduler (fun () ->
          granted := label :: !granted;
          Eio.Promise.await release))
    in
    List.iter hold [ "holder"; "S1"; "S2"; "S3" ];
    check_counts scheduler ~what:"one permit" ~active:1 ~queued:3;
    Slot_scheduler.reconfigure scheduler ~max_slots:3 ~priority_run_limit:None;
    check_counts scheduler ~what:"three permits" ~active:3 ~queued:1;
    Eio.Fiber.yield ();
    check
      (list string)
      "the two oldest waiters ran without a slot coming back"
      [ "holder"; "S1"; "S2" ]
      (List.rev !granted);
    Eio.Promise.resolve resolve_release ());
  check_counts scheduler ~what:"after every holder returned" ~active:0 ~queued:0
;;

let test_lowering_the_permits_waits_for_holders_to_return () =
  Eio_mock.Backend.run
  @@ fun () ->
  let scheduler = Slot_scheduler.create ~max_slots:2 ~priority_run_limit:None in
  let waiter_ran = ref false in
  Eio.Switch.run (fun sw ->
    let release_a, resolve_a = Eio.Promise.create () in
    let release_b, resolve_b = Eio.Promise.create () in
    let hold release =
      Eio.Fiber.fork ~sw (fun () ->
        Slot_scheduler.with_permit ~admission_class:Standard scheduler (fun () ->
          Eio.Promise.await release))
    in
    hold release_a;
    hold release_b;
    Eio.Fiber.fork ~sw (fun () ->
      Slot_scheduler.with_permit ~admission_class:Standard scheduler (fun () ->
        waiter_ran := true));
    Slot_scheduler.reconfigure scheduler ~max_slots:1 ~priority_run_limit:None;
    let snapshot = Slot_scheduler.snapshot scheduler in
    check int "nothing is taken back from a holder" 2 snapshot.active;
    check int "no slot is reported free" 0 snapshot.available;
    Eio.Promise.resolve resolve_a ();
    Eio.Fiber.yield ();
    check bool "the returned slot is not handed on above the new count" false !waiter_ran;
    check_counts scheduler ~what:"one holder left" ~active:1 ~queued:1;
    Eio.Promise.resolve resolve_b ();
    (* The holder returns its slot on this yield; the waiter runs on the next. *)
    Eio.Fiber.yield ();
    check_counts scheduler ~what:"the last holder's slot goes to the waiter" ~active:1 ~queued:0;
    Eio.Fiber.yield ();
    check bool "the waiter ran" true !waiter_ran);
  check_counts scheduler ~what:"after every holder returned" ~active:0 ~queued:0
;;

let test_removing_the_limit_grants_the_waiting_priority_first () =
  (* With the limit kept, standard would get the second slot: P1 S1 P2 P3. *)
  check
    (list string)
    "priority waiters the limit queued go first, then arrival order"
    [ "P1"; "P2"; "S1"; "P3" ]
    (grant_order
       ~priority_run_limit:(Some 1)
       ~before:[ "S1"; "P1"; "P2" ]
       ~change:(fun scheduler ->
         Slot_scheduler.reconfigure scheduler ~max_slots:1 ~priority_run_limit:None)
       ~after:[ "P3" ])
;;

let test_adding_a_limit_applies_to_requests_queued_after_it () =
  (* Without a limit the waiters share one queue: S1 P1 P2. *)
  check
    (list string)
    "the later priority request goes first, earlier waiters keep arrival order"
    [ "P2"; "S1"; "P1" ]
    (grant_order
       ~priority_run_limit:None
       ~before:[ "S1"; "P1" ]
       ~change:(fun scheduler ->
         Slot_scheduler.reconfigure scheduler ~max_slots:1 ~priority_run_limit:(Some 1))
       ~after:[ "P2" ])
;;

let test_an_invalid_allowance_is_refused_and_changes_nothing () =
  let scheduler = Slot_scheduler.create ~max_slots:2 ~priority_run_limit:None in
  let refused ~max_slots ~priority_run_limit =
    match Slot_scheduler.reconfigure scheduler ~max_slots ~priority_run_limit with
    | () -> failf "max_slots %d was accepted" max_slots
    | exception Invalid_argument _ -> ()
  in
  refused ~max_slots:0 ~priority_run_limit:None;
  refused ~max_slots:3 ~priority_run_limit:(Some 0);
  check int "the permit count is unchanged" 2 (Slot_scheduler.snapshot scheduler).max_slots
;;

(* A config load changes the allowance outside any Eio fiber. *)
let test_a_change_outside_eio_takes_effect () =
  let scheduler = Slot_scheduler.create ~max_slots:1 ~priority_run_limit:None in
  Slot_scheduler.reconfigure scheduler ~max_slots:4 ~priority_run_limit:(Some 2);
  check int "the new permit count" 4 (Slot_scheduler.snapshot scheduler).max_slots
;;

let () =
  run
    "slot_scheduler_reconfigure"
    [ ( "reconfigure"
      , [ test_case
            "raising the permits grants waiters at once"
            `Quick
            test_raising_the_permits_grants_waiters_at_once
        ; test_case
            "lowering the permits waits for holders to return"
            `Quick
            test_lowering_the_permits_waits_for_holders_to_return
        ; test_case
            "removing the limit grants the waiting priority first"
            `Quick
            test_removing_the_limit_grants_the_waiting_priority_first
        ; test_case
            "adding a limit applies to requests queued after it"
            `Quick
            test_adding_a_limit_applies_to_requests_queued_after_it
        ; test_case
            "an invalid allowance is refused and changes nothing"
            `Quick
            test_an_invalid_allowance_is_refused_and_changes_nothing
        ; test_case
            "a change outside eio takes effect"
            `Quick
            test_a_change_outside_eio_takes_effect
        ] )
    ]
;;
