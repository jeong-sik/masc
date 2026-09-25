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

let delta_inputs (resolved : Keeper_turn_spend.resolved list) =
  List.map
    (fun (resolved : Keeper_turn_spend.resolved) ->
       ( Keeper_usage_resolution.status_to_string resolved.resolution.status
       , Option.map
           (fun (sample : Keeper_usage_resolution.sample) -> sample.input_tokens)
           resolved.resolution.delta ))
    resolved
;;

let cursor_input (cursor : Keeper_usage_resolution.cursor option) =
  Option.map
    (fun (cursor : Keeper_usage_resolution.cursor) ->
       cursor.conversation_id, cursor.cumulative.input_tokens)
    cursor
;;

let resolve ?cursor t =
  Keeper_turn_spend.resolve ~cursor ~observed_at:0.0 (Keeper_turn_spend.attempts t)
;;

let second_attempt t =
  Keeper_turn_spend.start_attempt t ~routing_run_id:"run-1" ~runtime_id:"codex" ~lane_attempt_index:1
;;

(* A thread counted by two attempts is resolved in order: the second resumes
   from where the first left it, so the deltas add up to the last count. *)
let test_a_conversations_deltas_add_up_to_its_last_count () =
  let t = observe started (report (counted ~input:100 ~output:10)) in
  let t =
    observe
      (second_attempt t)
      (report ~position:Keeper_usage_resolution.Resumed (counted ~input:250 ~output:30))
  in
  let resolved, cursor = resolve t in
  check
    (list (pair string (option int)))
    "each attempt's delta"
    [ "exact_cost_unavailable", Some 100; "exact_cost_unavailable", Some 150 ]
    (delta_inputs resolved);
  check (option (pair string int)) "the cursor ends at the last count"
    (Some ("thread-1", 250)) (cursor_input cursor)
;;

let test_the_turn_resumes_from_the_cursor_it_started_with () =
  let cursor : Keeper_usage_resolution.cursor =
    { runtime_id = "codex"
    ; conversation_id = "thread-1"
    ; cumulative = Keeper_usage_resolution.sample_of_api_usage (usage ~input:40 ~output:4)
    }
  in
  let t =
    observe started (report ~position:Keeper_usage_resolution.Resumed (counted ~input:100 ~output:10))
  in
  let resolved, _ = resolve ~cursor t in
  check
    (list (pair string (option int)))
    "the count less the cursor"
    [ "exact_cost_unavailable", Some 60 ]
    (delta_inputs resolved)
;;

(* A repeat of the count the thread already reached adds nothing, even when
   another attempt reports it. *)
let test_a_repeated_count_adds_nothing () =
  let t = observe started (report (counted ~input:100 ~output:10)) in
  let t =
    observe
      (second_attempt t)
      (report ~position:Keeper_usage_resolution.Resumed (counted ~input:100 ~output:10))
  in
  let resolved, _ = resolve t in
  check
    (list (pair string (option int)))
    "the repeat resolves to zero"
    [ "exact_cost_unavailable", Some 100; "exact_cost_unavailable", Some 0 ]
    (delta_inputs resolved)
;;

(* The fill's thread spent up to its last real count, and counted from zero
   after it. Nothing before the overflow is lost, and nothing is counted
   twice. *)
let test_a_fill_loses_nothing_before_it_and_restarts_after_it () =
  let cursor : Keeper_usage_resolution.cursor =
    { runtime_id = "codex"
    ; conversation_id = "thread-1"
    ; cumulative = Keeper_usage_resolution.sample_of_api_usage (usage ~input:40 ~output:4)
    }
  in
  let t =
    List.fold_left
      observe
      started
      [ report ~position:Keeper_usage_resolution.Resumed (counted ~input:100 ~output:10)
      ; report ~position:Keeper_usage_resolution.Resumed Keeper_client_usage_report.Count_replaced
      ; report ~position:Keeper_usage_resolution.Resumed (counted ~input:30 ~output:3)
      ]
  in
  let resolved, cursor = resolve ~cursor t in
  check
    (list (pair string (option int)))
    "before the fill, then after it"
    [ "exact_cost_unavailable", Some 60; "exact_cost_unavailable", Some 30 ]
    (delta_inputs resolved);
  check (option (pair string int)) "the cursor is the count after the fill"
    (Some ("thread-1", 30)) (cursor_input cursor)
;;

let test_a_fill_that_ends_the_turn_leaves_the_cursor_at_zero () =
  let t =
    List.fold_left
      observe
      started
      [ report (counted ~input:100 ~output:10)
      ; report Keeper_client_usage_report.Count_replaced
      ]
  in
  let resolved, cursor = resolve t in
  check
    (list (pair string (option int)))
    "the count before the fill"
    [ "exact_cost_unavailable", Some 100 ]
    (delta_inputs resolved);
  check (option (pair string int)) "the next count starts from zero"
    (Some ("thread-1", 0)) (cursor_input cursor)
;;

(* A per-request or client-turn reading is its own spend and leaves the
   conversation cursor where it was. *)
let test_per_request_readings_leave_the_cursor_alone () =
  let t =
    match
      Keeper_turn_spend.observe_agent_core_response
        started
        ~response_id:"r-1"
        ~ordinal:1
        ~model:"agent-core-fixture"
        (Some { (usage ~input:5 ~output:1) with cost_usd = Some 0.01 })
    with
    | Ok t -> t
    | Error Keeper_turn_spend.No_attempt_started -> fail "a response found no attempt"
  in
  let resolved, cursor = resolve t in
  check
    (list (pair string (option int)))
    "the response's own count"
    [ "exact", Some 5 ]
    (delta_inputs resolved);
  check (option (pair string int)) "no cursor" None (cursor_input cursor)
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
    ; ( "resolve"
      , [ test_case "a conversation's deltas add up to its last count" `Quick
            test_a_conversations_deltas_add_up_to_its_last_count
        ; test_case "the turn resumes from the cursor it started with" `Quick
            test_the_turn_resumes_from_the_cursor_it_started_with
        ; test_case "a repeated count adds nothing" `Quick test_a_repeated_count_adds_nothing
        ; test_case "a fill loses nothing before it and restarts after it" `Quick
            test_a_fill_loses_nothing_before_it_and_restarts_after_it
        ; test_case "a fill that ends the turn leaves the cursor at zero" `Quick
            test_a_fill_that_ends_the_turn_leaves_the_cursor_at_zero
        ; test_case "per-request readings leave the cursor alone" `Quick
            test_per_request_readings_leave_the_cursor_alone
        ] )
    ]
;;
