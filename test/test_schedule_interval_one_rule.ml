(** A stored interval schedule and a newly requested one follow one rule
    (#38176).

    [create_request] (the create and modify path) and
    [schedule_request_of_yojson] (the path [Schedule_store] loads the ledger
    through) must accept exactly the same intervals. When they differ, a
    schedule written before a rule change keeps running on an interval that a
    new request with the same declaration is refused, and an operator who
    edits only its payload is refused too.

    Each case asks both paths the same question and requires the same answer. *)

open Alcotest

let actor =
  { Schedule_domain.id = "k1"
  ; kind = Schedule_domain.Automated_actor
  ; display_name = None
  }
;;

let requested_at = 1789570000.0

(* A payload [payload_of_yojson] accepts, so an interval is the only thing a
   case can be refused for. *)
let payload =
  `Assoc [ "kind", `String "consumer.note"; "body", `Assoc [ "text", `String "wake" ] ]
;;

let request interval_sec =
  Schedule_domain.create_request
    ~schedule_id:"sched-interval-rule"
    ~requested_by:actor
    ~scheduled_by:actor
    ~requested_at
    ~due_at:requested_at
    ~payload
    ~source:Schedule_domain.Automated_request
    ~recurrence:(Schedule_domain.Interval { interval_sec })
    ()
;;

(* A stored row carrying [interval_sec]: a row the codec itself wrote, with
   only its recurrence replaced, so every other field is one the loader
   accepts. *)
let stored_row interval_sec =
  let written =
    match request 3600 with
    | Ok written -> Schedule_domain.schedule_request_to_yojson written
    | Error err -> failf "fixture row was refused: %s" err
  in
  match written with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (name, value) ->
            if String.equal name "recurrence"
            then
              ( name
              , `Assoc [ "kind", `String "interval"; "interval_sec", `Int interval_sec ] )
            else name, value)
         fields)
  | _ -> failf "schedule_request_to_yojson did not write an object"
;;

let loaded interval_sec = Schedule_domain.schedule_request_of_yojson (stored_row interval_sec)

let accepted = function
  | Ok _ -> true
  | Error _ -> false
;;

let same_answer interval_sec =
  let requested = accepted (request interval_sec) in
  let stored = accepted (loaded interval_sec) in
  check
    bool
    (Printf.sprintf "interval %ds: request and stored row get the same answer" interval_sec)
    requested
    stored;
  requested
;;

(* Seconds below a minute, a minute, and an hour: the intervals a floor or a
   ceiling on the create path alone would split. *)
let positive_intervals = [ 1; 30; 59; 60; 3600 ]
let nonpositive_intervals = [ 0; -5 ]

let test_positive_intervals_run_everywhere () =
  List.iter
    (fun interval_sec ->
       check bool (Printf.sprintf "interval %ds accepted" interval_sec) true
         (same_answer interval_sec))
    positive_intervals
;;

let test_nonpositive_intervals_refused_everywhere () =
  List.iter
    (fun interval_sec ->
       check bool (Printf.sprintf "interval %ds refused" interval_sec) false
         (same_answer interval_sec))
    nonpositive_intervals
;;

let test_loaded_row_keeps_its_interval () =
  List.iter
    (fun interval_sec ->
       match loaded interval_sec with
       | Ok { Schedule_domain.recurrence = Schedule_domain.Interval { interval_sec = read }; _ } ->
         check int "stored interval read back unchanged" interval_sec read
       | Ok _ -> failf "interval %ds loaded as another recurrence kind" interval_sec
       | Error err -> failf "interval %ds refused on load: %s" interval_sec err)
    positive_intervals
;;

let () =
  run
    "schedule_interval_one_rule"
    [ ( "request and stored row"
      , [ test_case "positive intervals accepted by both" `Quick
            test_positive_intervals_run_everywhere
        ; test_case "non-positive intervals refused by both" `Quick
            test_nonpositive_intervals_refused_everywhere
        ; test_case "a loaded row keeps its interval" `Quick
            test_loaded_row_keeps_its_interval
        ] )
    ]
;;
