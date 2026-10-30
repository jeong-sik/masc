(* How a freed slot is shared between admission classes. One slot is
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
  | 'B' -> Background
  | _ -> invalid_arg ("waiter label must start with P, S or B: " ^ label)
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
    [ "B1"; "S1"; "P1"; "S2"; "B2"; "P2" ]
    (grant_order ~priority_run_limit:None [ "B1"; "S1"; "P1"; "S2"; "B2"; "P2" ])
;;

let test_standard_precedes_background_with_bounded_service () =
  check
    (list string)
    "standard goes first; background runs after two foreground grants"
    [ "S1"; "S2"; "B1"; "S3"; "B2" ]
    (grant_order ~priority_run_limit:(Some 2) [ "B1"; "B2"; "S1"; "S2"; "S3" ])
;;

let test_background_does_not_erase_priority_debt_to_standard () =
  check
    (list string)
    "background interrupts priority grants without resetting standard's turn"
    [ "P1"; "P2"; "B1"; "S1"; "P3"; "B2"; "P4"; "S2"; "B3"; "P5"; "P6"; "S3" ]
    (grant_order
       ~priority_run_limit:(Some 2)
       [ "S1"; "S2"; "S3"; "P1"; "P2"; "P3"; "P4"; "P5"; "P6"; "B1"; "B2"; "B3" ])
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

(* Lets every runnable fiber run until it blocks. *)
let settle () =
  for _ = 1 to 20 do
    Eio.Fiber.yield ()
  done
;;

(* One slot, a run limit of one, and waiters that hold the slot until the
   test lets go, so arrivals and expiries can happen while a slot is held.
   [hold ?deadline_at label] queues a waiter (bounded by a deadline on the
   mock clock when given); [release label] gives its slot back; [expire_at]
   moves the clock. Returns the grant order. *)
let held_grant_order script =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  let scheduler = Slot_scheduler.create ~max_slots:1 ~priority_run_limit:(Some 1) in
  let granted = ref [] in
  let releases = Hashtbl.create 8 in
  Eio.Switch.run (fun sw ->
    let hold ?deadline_at label =
      let release, resolve = Eio.Promise.create () in
      Hashtbl.replace releases label resolve;
      let admission_class = label_class label in
      let body () =
        granted := label :: !granted;
        Eio.Promise.await release
      in
      Eio.Fiber.fork ~sw (fun () ->
        match deadline_at with
        | None -> Slot_scheduler.with_permit ~admission_class scheduler body
        | Some deadline_at ->
          (match
             Slot_scheduler.with_permit_until
               ~clock
               ~deadline_at
               ~admission_class
               scheduler
               body
           with
           | Ok () | Error `Permit_wait_expired -> ()));
      settle ()
    in
    let release label =
      Eio.Promise.resolve (Hashtbl.find releases label) ();
      settle ()
    in
    let expire_at now =
      Eio_mock.Clock.set_time clock now;
      settle ()
    in
    script ~hold ~release ~expire_at);
  let snapshot = Slot_scheduler.snapshot scheduler in
  check int "every slot came back" 0 snapshot.active;
  check int "nobody is left in the queue" 0 snapshot.queue_length;
  List.rev !granted
;;

let test_a_late_standard_waiter_is_not_charged_for_earlier_priority_grants () =
  check
    (list string)
    "P2 still goes ahead of the late S1; the run starts when S1 queues"
    [ "S0"; "P1"; "P2"; "S1"; "P3" ]
    (held_grant_order (fun ~hold ~release ~expire_at:_ ->
       hold "S0";
       hold "P1";
       hold "P2";
       (* P1 is granted while no standard waiter is queued. *)
       release "S0";
       hold "S1";
       hold "P3";
       List.iter release [ "P1"; "P2"; "S1"; "P3" ]))
;;

let test_a_standard_waiter_that_expired_leaves_no_run_behind () =
  check
    (list string)
    "P1 counted against S1, which left; P2 still goes ahead of the later S2"
    [ "S0"; "P1"; "P2"; "S2"; "P3" ]
    (held_grant_order (fun ~hold ~release ~expire_at ->
       hold "S0";
       hold "P1";
       hold ~deadline_at:5.0 "S1";
       (* P1 is granted while S1 waits. *)
       release "S0";
       (* S1 gives up; no standard waiter is queued any more. *)
       expire_at 5.0;
       hold "P2";
       hold "S2";
       hold "P3";
       List.iter release [ "P1"; "P2"; "S2"; "P3" ]))
;;

let test_a_late_background_waiter_starts_a_new_foreground_run () =
  check
    (list string)
    "earlier foreground work is not charged to a new background waiter"
    [ "S0"; "P1"; "P2"; "B1"; "P3" ]
    (held_grant_order (fun ~hold ~release ~expire_at:_ ->
       hold "S0";
       hold "P1";
       hold "P2";
       release "S0";
       hold "B1";
       hold "P3";
       List.iter release [ "P1"; "P2"; "B1"; "P3" ]))
;;

let test_an_expired_background_waiter_leaves_no_run_behind () =
  check
    (list string)
    "expired background work does not promote its later replacement"
    [ "S0"; "P1"; "P2"; "B2"; "P3" ]
    (held_grant_order (fun ~hold ~release ~expire_at ->
       hold "S0";
       hold "P1";
       hold ~deadline_at:5.0 "B1";
       release "S0";
       expire_at 5.0;
       hold "P2";
       hold "B2";
       hold "P3";
       List.iter release [ "P1"; "P2"; "B2"; "P3" ]))
;;

let test_both_lower_classes_progress_under_continuing_priority_arrivals () =
  check
    (list string)
    "priority arrivals cannot starve either standard or background work"
    [ "S0"; "P1"; "B1"; "S1"; "B2"; "P2"; "S2"; "P3"; "P4" ]
    (held_grant_order (fun ~hold ~release ~expire_at:_ ->
       List.iter hold [ "S0"; "S1"; "S2"; "B1"; "B2"; "P1" ];
       release "S0";
       hold "P2";
       release "P1";
       hold "P3";
       release "B1";
       hold "P4";
       List.iter release [ "S1"; "B2"; "P2"; "S2"; "P3"; "P4" ]))
;;

(* Random arrivals, releases and clock steps over one to three slots, with
   and without a run limit, some waiters bounded by a deadline. However the
   steps interleave: no more than [max_slots] waiters hold a slot at once;
   every waiter is either granted once or expired, never both; within a
   class the granted waiters are granted in arrival order; and once every
   holder lets go, every slot is back and nobody is queued. *)
let test_random_interleavings_never_leak_or_overfill () =
  let rng = Random.State.make [| 41316 |] in
  for case = 1 to 300 do
    Eio_mock.Backend.run
    @@ fun () ->
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock 0.0;
    let max_slots = 1 + Random.State.int rng 3 in
    let priority_run_limit =
      if Random.State.bool rng then None else Some (1 + Random.State.int rng 3)
    in
    let scheduler = Slot_scheduler.create ~max_slots ~priority_run_limit in
    let now = ref 0.0 in
    let held = ref 0
    and most_held = ref 0 in
    let holding = ref [] in
    let arrived = ref []
    and granted = ref []
    and expired = ref [] in
    let case_name = Printf.sprintf "case %d (max_slots %d)" case max_slots in
    Eio.Switch.run (fun sw ->
      let arrive index =
        let admission_class : Admission_class.t =
          match Random.State.int rng 3 with
          | 0 -> Priority
          | 1 -> Standard
          | _ -> Background
        in
        let label =
          Printf.sprintf
            "%c%d"
            (match admission_class with
             | Priority -> 'P'
             | Standard -> 'S'
             | Background -> 'B')
            index
        in
        arrived := label :: !arrived;
        let release, resolve = Eio.Promise.create () in
        let body () =
          incr held;
          most_held := max !most_held !held;
          granted := label :: !granted;
          holding := (label, resolve) :: !holding;
          Eio.Promise.await release;
          decr held
        in
        let deadline =
          if Random.State.int rng 3 = 0
          then Some (!now +. float_of_int (1 + Random.State.int rng 3))
          else None
        in
        Eio.Fiber.fork ~sw (fun () ->
          match deadline with
          | None -> Slot_scheduler.with_permit ~admission_class scheduler body
          | Some deadline_at ->
            (match
               Slot_scheduler.with_permit_until
                 ~clock
                 ~deadline_at
                 ~admission_class
                 scheduler
                 body
             with
             | Ok () -> ()
             | Error `Permit_wait_expired -> expired := label :: !expired))
      in
      let release_one () =
        match !holding with
        | [] -> ()
        | holders ->
          let label, resolve =
            List.nth holders (Random.State.int rng (List.length holders))
          in
          holding := List.filter (fun (other, _) -> other <> label) !holding;
          Eio.Promise.resolve resolve ()
      in
      let advance_clock seconds =
        now := !now +. seconds;
        Eio_mock.Clock.set_time clock !now
      in
      for index = 1 to 12 do
        (match Random.State.int rng 3 with
         | 0 -> arrive index
         | 1 -> release_one ()
         | _ -> advance_clock 1.0);
        settle ();
        if !held > max_slots
        then failf "%s: %d holders at once" case_name !held
      done;
      let rec drain rounds =
        if rounds = 0
        then failf "%s: the queue did not drain" case_name
        else if !holding = [] && (Slot_scheduler.snapshot scheduler).queue_length = 0
        then ()
        else (
          List.iter (fun (_, resolve) -> Eio.Promise.resolve resolve ()) !holding;
          holding := [];
          advance_clock 10.0;
          settle ();
          drain (rounds - 1))
      in
      drain 100);
    check bool (case_name ^ ": never more holders than slots") true (!most_held <= max_slots);
    List.iter
      (fun label ->
         let was_granted = List.mem label !granted in
         let was_expired = List.mem label !expired in
         if was_granted = was_expired
         then failf "%s: %s granted=%b expired=%b" case_name label was_granted was_expired)
      !arrived;
    let in_class c labels = List.filter (fun label -> label_class label = c) labels in
    let granted_in_arrival_order =
      List.filter (fun label -> List.mem label !granted) (List.rev !arrived)
    in
    List.iter
      (fun c ->
         check
           (list string)
           (case_name ^ ": arrival order within " ^ Admission_class.to_string c)
           (in_class c granted_in_arrival_order)
           (in_class c (List.rev !granted)))
      [ Admission_class.Priority; Admission_class.Standard; Admission_class.Background ];
    let snapshot = Slot_scheduler.snapshot scheduler in
    check int (case_name ^ ": every slot came back") 0 snapshot.active;
    check int (case_name ^ ": nobody is left queued") 0 snapshot.queue_length
  done
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
         | Background -> fail "this case only generates priority and standard work"
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

let test_mixed_arrivals_keep_both_service_bounds () =
  let rng = Random.State.make [| 20261019 |] in
  let classes = [ Admission_class.Priority; Admission_class.Standard; Admission_class.Background ] in
  for _case = 1 to 200 do
    let limit = 1 + Random.State.int rng 3 in
    let counts = Array.make 3 0 in
    let waiters =
      List.init 18 (fun _ ->
        let index = Random.State.int rng 3 in
        counts.(index) <- counts.(index) + 1;
        Printf.sprintf "%c%d" [| 'P'; 'S'; 'B' |].(index) counts.(index))
    in
    let order = grant_order ~priority_run_limit:(Some limit) waiters in
    let name = String.concat " " waiters in
    check int (name ^ ": every waiter granted once") (List.length waiters) (List.length order);
    List.iter
      (fun admission_class ->
         let in_class = List.filter (fun label -> label_class label = admission_class) in
         check (list string) (name ^ ": FIFO within " ^ Admission_class.to_string admission_class)
           (in_class waiters) (in_class order))
      classes;
    let standard_left = ref counts.(1)
    and background_left = ref counts.(2)
    and priority_run = ref 0
    and foreground_run = ref 0 in
    let foreground_grant () =
      if !background_left > 0 then (
        incr foreground_run;
        if !foreground_run > limit then
          failf "%s: background passed by %d foreground grants (limit %d)"
            name !foreground_run limit)
    in
    List.iter
      (fun label ->
         match label_class label with
         | Priority ->
           if !standard_left > 0 then (
             incr priority_run;
             if !priority_run > limit then
               failf "%s: standard passed by %d priority grants (limit %d)"
                 name !priority_run limit);
           foreground_grant ()
         | Standard ->
           decr standard_left;
           priority_run := 0;
           foreground_grant ()
         | Background ->
           decr background_left;
           foreground_run := 0)
      order
  done
;;

let () =
  run
    "slot_scheduler_priority"
    [ ( "grant order"
      , [ test_case
            "without a limit all classes share arrival order"
            `Quick
            test_without_a_limit_both_classes_share_arrival_order
        ; test_case
            "standard precedes background with bounded service"
            `Quick
            test_standard_precedes_background_with_bounded_service
        ; test_case
            "background preserves priority debt to standard"
            `Quick
            test_background_does_not_erase_priority_debt_to_standard
        ; test_case
            "late background starts a new foreground run"
            `Quick
            test_a_late_background_waiter_starts_a_new_foreground_run
        ; test_case
            "expired background leaves no foreground run"
            `Quick
            test_an_expired_background_waiter_leaves_no_run_behind
        ; test_case
            "both lower classes progress during priority arrivals"
            `Quick
            test_both_lower_classes_progress_under_continuing_priority_arrivals
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
            "a late standard waiter is not charged for earlier priority grants"
            `Quick
            test_a_late_standard_waiter_is_not_charged_for_earlier_priority_grants
        ; test_case
            "a standard waiter that expired leaves no run behind"
            `Quick
            test_a_standard_waiter_that_expired_leaves_no_run_behind
        ; test_case
            "random interleavings never leak or overfill"
            `Quick
            test_random_interleavings_never_leak_or_overfill
        ; test_case
            "a run limit below one is refused"
            `Quick
            test_a_run_limit_below_one_is_refused
        ; test_case
            "random arrivals keep the invariants"
            `Quick
            test_random_arrivals_keep_the_invariants
        ; test_case
            "mixed arrivals keep both service bounds"
            `Quick
            test_mixed_arrivals_keep_both_service_bounds
        ] )
    ]
;;
