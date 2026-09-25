open Alcotest
open Masc

let usage ~input ~output : Agent_core.Types.api_usage =
  { Agent_core.Types.empty_usage with input_tokens = input; output_tokens = output }
;;

let report
      ?(scope = Runtime_usage_scope.Conversation_cumulative)
      ?(conversation_id = "thread-1")
      ?(position = Keeper_usage_resolution.Fresh)
      ?(response_id = "turn-1")
      ?(official_turn = 1)
      ?(model = "gpt-fixture")
      count
  : Keeper_client_usage_report.t
  =
  { official_turn
  ; response_id
  ; model
  ; conversation_id
  ; position
  ; usage_scope = scope
  ; count
  ; vendor_total_tokens = None
  }
;;

let counted ~input ~output = Keeper_client_usage_report.Running_count (usage ~input ~output)

let started =
  Keeper_turn_spend.start_attempt
    Keeper_turn_spend.empty
    ~routing_run_id:"run-1"
    ~runtime_id:"codex"
    ~lane_attempt_index:0
;;

let observe t r =
  match Keeper_turn_spend.observe_client_report t r with
  | Ok t -> t
  | Error Keeper_turn_spend.No_attempt_started -> fail "a report found no attempt"
;;

let readings t =
  match Keeper_turn_spend.attempts t with
  | [ attempt ] -> attempt.readings
  | attempts -> failf "expected one attempt, got %d" (List.length attempts)
;;

let input_of (reading : Keeper_turn_spend.reading) =
  Option.map
    (fun (sample : Keeper_usage_resolution.sample) -> sample.input_tokens)
    reading.observation
;;

let position_of (reading : Keeper_turn_spend.reading) =
  match reading.basis with
  | Keeper_usage_resolution.Conversation_counter { position; runtime_id; _ } ->
    Some (runtime_id, Keeper_usage_resolution.position_to_string position)
  | Keeper_usage_resolution.Per_request
  | Keeper_usage_resolution.Turn_total
  | Keeper_usage_resolution.Unavailable -> None
;;

(* A frame repeats the running count; a newer frame moves it. Either way the
   conversation is one reading holding its newest count. *)
let test_a_conversations_frames_are_one_reading () =
  let t =
    List.fold_left
      observe
      started
      [ report (counted ~input:100 ~output:10)
      ; report (counted ~input:100 ~output:10)
      ; report ~official_turn:2 ~response_id:"turn-2" (counted ~input:250 ~output:30)
      ]
  in
  match readings t with
  | [ reading ] ->
    check int "first reading" 0 reading.reading_index;
    check (option int) "the newest count" (Some 250) (input_of reading);
    check string "the newest client turn" "turn-2" reading.response_id;
    check int "its ordinal" 2 reading.ordinal;
    check
      (option (pair string string))
      "keyed by the attempt's runtime"
      (Some ("codex", "fresh"))
      (position_of reading)
  | readings -> failf "expected one reading, got %d" (List.length readings)
;;

(* A shrink retry opens a new thread inside the same attempt, and may number
   its client turn 1 again. The two threads stay two readings. *)
let test_two_conversations_of_one_attempt_stay_apart () =
  let t =
    List.fold_left
      observe
      started
      [ report ~conversation_id:"thread-1" (counted ~input:100 ~output:10)
      ; report ~conversation_id:"thread-2" (counted ~input:40 ~output:4)
      ]
  in
  check
    (list (pair int (option int)))
    "one reading per thread, in the order seen"
    [ 0, Some 100; 1, Some 40 ]
    (List.map
       (fun (reading : Keeper_turn_spend.reading) -> reading.reading_index, input_of reading)
       (readings t))
;;

(* A fill replaces the thread's count after its last real one. That count
   stays the reading's; the thread's next count starts from zero and resumes
   from it as a reading of its own. *)
let test_a_fill_keeps_the_last_count_and_splits_what_follows () =
  let t =
    List.fold_left
      observe
      started
      [ report (counted ~input:100 ~output:10)
      ; report Keeper_client_usage_report.Count_replaced
      ; report (counted ~input:30 ~output:3)
      ]
  in
  match readings t with
  | [ before; after ] ->
    check (option int) "the count before the fill" (Some 100) (input_of before);
    check bool "the fill restarts the count" true
      (before.count_after = Keeper_turn_spend.Count_restarts_from_zero);
    check (option int) "the count after the fill" (Some 30) (input_of after);
    check
      (option (pair string string))
      "what follows resumes from zero"
      (Some ("codex", "resumed"))
      (position_of after);
    check bool "and continues" true (after.count_after = Keeper_turn_spend.Count_continues)
  | readings -> failf "expected two readings, got %d" (List.length readings)
;;

let test_a_fill_before_any_count_counted_nothing () =
  let t =
    List.fold_left
      observe
      started
      [ report Keeper_client_usage_report.Count_replaced
      ; report Keeper_client_usage_report.Count_replaced
      ]
  in
  match readings t with
  | [ reading ] ->
    check (option int) "nothing counted" None (input_of reading);
    check bool "the count restarts" true
      (reading.count_after = Keeper_turn_spend.Count_restarts_from_zero)
  | readings -> failf "expected one reading, got %d" (List.length readings)
;;

(* A client-turn total is keyed by its client turn: a repeat of one result
   is one reading, and two results are two. *)
let test_client_turn_totals_are_keyed_by_their_turn () =
  let turn_total = report ~scope:Runtime_usage_scope.Turn_total in
  let t =
    List.fold_left
      observe
      started
      [ turn_total ~response_id:"uuid-1" (counted ~input:10 ~output:1)
      ; turn_total ~response_id:"uuid-1" (counted ~input:12 ~output:1)
      ; turn_total ~response_id:"uuid-2" (counted ~input:7 ~output:1)
      ]
  in
  check
    (list (pair string (option int)))
    "one reading per client turn"
    [ "uuid-1", Some 12; "uuid-2", Some 7 ]
    (List.map
       (fun (reading : Keeper_turn_spend.reading) -> reading.response_id, input_of reading)
       (readings t))
;;

let test_agent_core_responses_are_each_a_reading () =
  let observe_response t ~response_id ~ordinal usage =
    match
      Keeper_turn_spend.observe_agent_core_response
        t
        ~response_id
        ~ordinal
        ~model:"agent-core-fixture"
        usage
    with
    | Ok t -> t
    | Error Keeper_turn_spend.No_attempt_started -> fail "a response found no attempt"
  in
  let t = observe_response started ~response_id:"r-1" ~ordinal:1 (Some (usage ~input:5 ~output:1)) in
  let t = observe_response t ~response_id:"r-2" ~ordinal:2 None in
  check
    (list (pair int (option int)))
    "each response, with or without a count"
    [ 1, Some 5; 2, None ]
    (List.map
       (fun (reading : Keeper_turn_spend.reading) -> reading.ordinal, input_of reading)
       (readings t))
;;

(* Attempts keep their order and their own readings; a later attempt that
   resumes the same thread is its own reading. *)
let test_attempts_keep_their_own_readings () =
  let t = observe started (report (counted ~input:100 ~output:10)) in
  let t =
    Keeper_turn_spend.start_attempt
      t
      ~routing_run_id:"run-1"
      ~runtime_id:"antigravity"
      ~lane_attempt_index:1
  in
  let t = observe t (report ~position:Keeper_usage_resolution.Resumed (counted ~input:120 ~output:12)) in
  check
    (list (pair int (list (option int))))
    "each attempt, its readings"
    [ 0, [ Some 100 ]; 1, [ Some 120 ] ]
    (List.map
       (fun (attempt : Keeper_turn_spend.attempt) ->
          attempt.lane_attempt_index, List.map input_of attempt.readings)
       (Keeper_turn_spend.attempts t))
;;

let test_a_report_before_any_attempt_is_unplaced () =
  match
    Keeper_turn_spend.observe_client_report
      Keeper_turn_spend.empty
      (report (counted ~input:1 ~output:1))
  with
  | Error Keeper_turn_spend.No_attempt_started -> ()
  | Ok _ -> fail "a report was placed with no attempt"
;;

let () =
  run
    "Keeper_turn_spend"
    [ ( "readings"
      , [ test_case "a conversation's frames are one reading" `Quick
            test_a_conversations_frames_are_one_reading
        ; test_case "two conversations of one attempt stay apart" `Quick
            test_two_conversations_of_one_attempt_stay_apart
        ; test_case "a fill keeps the last count and splits what follows" `Quick
            test_a_fill_keeps_the_last_count_and_splits_what_follows
        ; test_case "a fill before any count counted nothing" `Quick
            test_a_fill_before_any_count_counted_nothing
        ; test_case "client-turn totals are keyed by their turn" `Quick
            test_client_turn_totals_are_keyed_by_their_turn
        ; test_case "Agent Core responses are each a reading" `Quick
            test_agent_core_responses_are_each_a_reading
        ; test_case "attempts keep their own readings" `Quick
            test_attempts_keep_their_own_readings
        ; test_case "a report before any attempt is unplaced" `Quick
            test_a_report_before_any_attempt_is_unplaced
        ] )
    ]
;;
