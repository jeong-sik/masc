(* The exact lane walker (RFC exact-lane-walks-one-slot-list sections 3.3,
   3.5 and 3.6) over fake slots. Each slot's seats come from a scheduler the
   test owns, and its visit answers what the test scripted. *)

open Alcotest
open Masc
module Walk = Exact_lane_walk
module Provider_admission = Llm_provider.Provider_admission
module Slot_scheduler = Llm_provider.Slot_scheduler

type outcome =
  | Answers
  | Fails of { rests : bool }
  | Stops

type slot =
  { id : string
  ; kind : Walk.kind
  ; seats : Walk.seats
  ; outcome : outcome
  ; backpressure : Runtime_candidate_backpressure.candidate option
  }

let make ?backpressure id kind seats outcome = { id; kind; seats; outcome; backpressure }
let scheduler () = Slot_scheduler.create ~max_slots:1 ~priority_run_limit:None

let taken_elsewhere () =
  let scheduler = scheduler () in
  check bool "the only seat is taken outside the walk" true (Slot_scheduler.try_acquire scheduler);
  scheduler
;;

let seats_of scheduler =
  Walk.Seats_of
    (Provider_admission.Scheduler_seats
       { scheduler; admission_class = Llm_provider.Admission_class.Standard })
;;

let active scheduler = (Slot_scheduler.snapshot scheduler).Slot_scheduler.active
let queued scheduler = (Slot_scheduler.snapshot scheduler).Slot_scheduler.queue_length

(* Each visit is noted with whether it held a seat. *)
let visit visited slot seat =
  visited := !visited @ [ slot.id, Option.is_some seat ];
  match slot.outcome with
  | Answers -> Walk.Answer slot.id
  | Fails { rests } -> Walk.Advance (slot.id, rests)
  | Stops -> Walk.Stop slot.id
;;

let walk ?(on_advance = fun ~failed:_ ~next:_ -> Ok ()) visited slots =
  Walk.walk
    ~now:Unix.gettimeofday
    ~kind:(fun slot -> slot.kind)
    ~quota_scope_of:(fun (_ : slot) -> None)
    ~candidate_backpressure_of:(fun slot -> slot.backpressure)
    ~seats:(fun slot -> slot.seats)
    ~visit:(visit visited)
    ~on_advance
    ~rests:(fun ((_ : string), rests) -> rests)
    slots
;;

let passed_names passed =
  List.map
    (function
      | Walk.Held { slot; until = _ } -> "held " ^ slot.id
      | Walk.Seats_full slot -> "full " ^ slot.id
      | Walk.Failed { slot; failure = _ } -> "failed " ^ slot.id)
    passed
;;

let answered = function
  | Walk.Answered { slot; value = _; passed } -> slot.id, passed_names passed
  | Walk.Exhausted { passed; standing = _ } ->
    failf "the walk was exhausted: %s" (String.concat ", " (passed_names passed))
  | Walk.Stopped { slot; stop = _; passed = _ } -> failf "the walk stopped at %s" slot.id
;;

let visits = list (pair string bool)

let test_a_full_slot_is_passed_for_a_free_slot_of_the_other_kind () =
  let busy = taken_elsewhere () in
  let free = scheduler () in
  let visited = ref [] in
  let called, passed =
    answered
      (walk visited [ make "h1" Walk.Http (seats_of busy) Answers
                    ; make "c1" Walk.Cli (seats_of free) Answers ])
  in
  check string "the free CLI slot answered" "c1" called;
  check (list string) "the full HTTP slot was passed" [ "full h1" ] passed;
  check visits "only the free slot was visited, holding a seat" [ "c1", true ] !visited;
  check int "the seat went back when the visit ended" 0 (active free);
  check int "the full slot's seat was not touched" 1 (active busy);
  check int "nothing waits on the full slot" 0 (queued busy)
;;

let test_a_failed_slot_moves_on_and_the_move_is_recorded () =
  let visited = ref [] in
  let moves = ref [] in
  let on_advance ~failed:(failed_id, (_ : bool)) ~next =
    moves := !moves @ [ failed_id, next.id ];
    Ok ()
  in
  let called, passed =
    answered
      (walk ~on_advance visited
         [ make "h1" Walk.Http (seats_of (scheduler ())) (Fails { rests = false })
         ; make "c1" Walk.Cli (seats_of (scheduler ())) Answers
         ])
  in
  check string "the next slot answered" "c1" called;
  check (list string) "the failed slot is passed" [ "failed h1" ] passed;
  check visits "both were visited in order" [ "h1", true; "c1", true ] !visited;
  check (list (pair string string)) "the move names the failure and the next slot"
    [ "h1", "c1" ] !moves
;;

let test_a_refused_move_stops_before_the_next_slot_and_returns_its_seat () =
  let next_seats = scheduler () in
  let visited = ref [] in
  let on_advance ~failed:_ ~next:_ = Error "the move was not recorded" in
  (match
     walk ~on_advance visited
       [ make "h1" Walk.Http (seats_of (scheduler ())) (Fails { rests = false })
       ; make "c1" Walk.Cli (seats_of next_seats) Answers
       ]
   with
   | Walk.Stopped { slot; stop; passed } ->
     check string "the walk stopped at the next slot" "c1" slot.id;
     check string "with the refusal" "the move was not recorded" stop;
     check (list string) "after the failed slot" [ "failed h1" ] (passed_names passed)
   | Walk.Answered _ | Walk.Exhausted _ -> fail "a refused move did not stop the walk");
  check visits "the next slot was not visited" [ "h1", true ] !visited;
  check int "its seat went back" 0 (active next_seats)
;;

let test_a_stopping_visit_ends_the_walk () =
  let stopping = scheduler () in
  let visited = ref [] in
  (match
     walk visited
       [ make "h1" Walk.Http (seats_of stopping) Stops
       ; make "c1" Walk.Cli (seats_of (scheduler ())) Answers
       ]
   with
   | Walk.Stopped { slot; stop = _; passed } ->
     check string "the walk stopped where the visit stopped" "h1" slot.id;
     check (list string) "nothing was passed" [] (passed_names passed)
   | Walk.Answered _ | Walk.Exhausted _ -> fail "a stopping visit did not end the walk");
  check visits "no later slot was visited" [ "h1", true ] !visited;
  check int "the seat went back" 0 (active stopping)
;;

(* A seatless slot sends nothing, so the walk does not wait behind a full
   slot ahead of it. *)
let test_a_seatless_slot_is_called_when_the_walk_reaches_it () =
  let busy = taken_elsewhere () in
  let visited = ref [] in
  let called, passed =
    answered
      (walk visited
         [ make "h1" Walk.Http (seats_of busy) Answers
         ; make "h2" Walk.Http Walk.Seatless (Fails { rests = false })
         ; make "c1" Walk.Cli (seats_of (scheduler ())) Answers
         ])
  in
  check string "the slot after it answered" "c1" called;
  check (list string) "the full slot, then the seatless one" [ "full h1"; "failed h2" ] passed;
  check visits "the seatless slot was visited without a seat" [ "h2", false; "c1", true ]
    !visited;
  check int "nothing waits on the full slot" 0 (queued busy)
;;

let rec await_queued scheduler =
  if queued scheduler > 0
  then ()
  else (
    Eio.Fiber.yield ();
    await_queued scheduler)
;;

let test_when_every_slot_is_full_the_first_seat_to_free_is_called () =
  Eio_main.run
  @@ fun _env ->
  let http = taken_elsewhere () in
  let cli = taken_elsewhere () in
  let visited = ref [] in
  let result = ref None in
  Eio.Fiber.both
    (fun () ->
       result
       := Some
            (walk visited
               [ make "h1" Walk.Http (seats_of http) Answers
               ; make "c1" Walk.Cli (seats_of cli) Answers
               ]))
    (fun () ->
       await_queued http;
       await_queued cli;
       Slot_scheduler.release cli);
  match !result with
  | None -> fail "the walk did not end"
  | Some result ->
    let called, passed = answered result in
    check string "the slot whose seat freed first answered" "c1" called;
    check (list string) "the slot ahead of it was passed as full" [ "full h1" ] passed;
    check visits "only that slot was visited" [ "c1", true ] !visited;
    check int "its seat went back" 0 (active cli);
    check int "the other wait was withdrawn" 0 (queued http);
    check int "the other seat is still held outside" 1 (active http)
;;

(* The rate limit is noted inside Eio, as the walks note it. *)
let test_a_slot_its_provider_holds_is_passed_and_not_called () =
  Eio_main.run
  @@ fun _env ->
  let backpressure =
    Runtime_candidate_backpressure.create_candidate
      ~binding:Runtime_candidate_backpressure.Official_client_binding
  in
  Runtime_candidate_backpressure.note_rate_limit ~candidate:backpressure ~retry_after:(Some 600.);
  let held_seats = scheduler () in
  let visited = ref [] in
  let called, passed =
    answered
      (walk visited
         [ make ~backpressure "h1" Walk.Http (seats_of held_seats) Answers
         ; make "h2" Walk.Http (seats_of (scheduler ())) Answers
         ])
  in
  check string "the next slot answered" "h2" called;
  check (list string) "the held slot was passed" [ "held h1" ] passed;
  check visits "the held slot was not visited" [ "h2", true ] !visited;
  check int "its seat was not taken" 0 (active held_seats)
;;

let standing_after slots =
  match walk (ref []) slots with
  | Walk.Exhausted { passed = _; standing } -> standing
  | Walk.Answered _ | Walk.Stopped _ -> fail "the walk was meant to be exhausted"
;;

let is_resting = function
  | Walk.Every_slot_resting -> true
  | Walk.Not_every_slot_resting -> false
;;

let test_a_lane_rests_only_when_every_slot_refused_for_its_standing () =
  check bool "every slot refused for its account's standing" true
    (is_resting
       (standing_after
          [ make "h1" Walk.Http (seats_of (scheduler ())) (Fails { rests = true })
          ; make "c1" Walk.Cli (seats_of (scheduler ())) (Fails { rests = true })
          ]));
  check bool "one slot failed for another reason" false
    (is_resting
       (standing_after
          [ make "h1" Walk.Http (seats_of (scheduler ())) (Fails { rests = true })
          ; make "c1" Walk.Cli (seats_of (scheduler ())) (Fails { rests = false })
          ]));
  check bool "a lane with no slot does not rest" false (is_resting (standing_after []))
;;

let test_http_slots_are_walked_before_cli_slots_until_the_hard_cut () =
  let visited = ref [] in
  (match
     walk visited
       [ make "c1" Walk.Cli (seats_of (scheduler ())) (Fails { rests = false })
       ; make "h1" Walk.Http (seats_of (scheduler ())) (Fails { rests = false })
       ]
   with
   | Walk.Exhausted { passed; standing = _ } ->
     check (list string) "the HTTP slot first" [ "failed h1"; "failed c1" ] (passed_names passed)
   | Walk.Answered _ | Walk.Stopped _ -> fail "the walk was meant to be exhausted");
  check visits "in that order" [ "h1", true; "c1", true ] !visited
;;

let () =
  run
    "exact_lane_walk"
    [ ( "seats"
      , [ test_case
            "a full slot is passed for a free slot of the other kind"
            `Quick
            test_a_full_slot_is_passed_for_a_free_slot_of_the_other_kind
        ; test_case
            "a seatless slot is called when the walk reaches it"
            `Quick
            test_a_seatless_slot_is_called_when_the_walk_reaches_it
        ; test_case
            "when every slot is full the first seat to free is called"
            `Quick
            test_when_every_slot_is_full_the_first_seat_to_free_is_called
        ] )
    ; ( "steps"
      , [ test_case
            "a failed slot moves on and the move is recorded"
            `Quick
            test_a_failed_slot_moves_on_and_the_move_is_recorded
        ; test_case
            "a refused move stops before the next slot and returns its seat"
            `Quick
            test_a_refused_move_stops_before_the_next_slot_and_returns_its_seat
        ; test_case "a stopping visit ends the walk" `Quick test_a_stopping_visit_ends_the_walk
        ] )
    ; ( "order"
      , [ test_case
            "a slot its provider holds is passed and not called"
            `Quick
            test_a_slot_its_provider_holds_is_passed_and_not_called
        ; test_case
            "HTTP slots are walked before CLI slots until the hard cut"
            `Quick
            test_http_slots_are_walked_before_cli_slots_until_the_hard_cut
        ; test_case
            "a lane rests only when every slot refused for its standing"
            `Quick
            test_a_lane_rests_only_when_every_slot_refused_for_its_standing
        ] )
    ]
;;
