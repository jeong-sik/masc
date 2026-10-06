(* A cancelled execution's readings stay raw rows in the cost ledger. Before
   the Keeper's next execution they are settled under their own turn, once,
   and nothing a commit already settled is settled again. *)
open Alcotest
open Masc

let keeper = "lost-keeper"
let trace = "trace-lost"

let with_ledger f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_file "masc-unsettled-spend-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)
;;

let sample ?cost_usd input : Keeper_usage_resolution.sample =
  { input_tokens = input
  ; output_tokens = 10
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = input / 2
  ; cost_usd
  }
;;

(* A raw row as an execution writes it: its counts, and the observation its
   spend read. [~recorded:false] is a row written before rows carried one. *)
let raw
      ~masc_root
      ?(agent = keeper)
      ?(scope = Runtime_usage_scope.Per_request)
      ?client
      ?(replaced = false)
      ?cost_usd
      ?(recorded = true)
      ?(usage_reported = true)
      ?(lane = 0)
      ~turn
      ~ordinal
      ~run
      ~input
      ()
  =
  let usage = sample ?cost_usd input in
  let response_id, conversation, observation =
    match client with
    | None ->
      ( None
      , None
      , Keeper_spend_observation.Agent_core_response
          { response_id = ""
          ; ordinal
          ; model = "glm-fixture"
          ; usage = (if usage_reported then Some usage else None)
          } )
    | Some (response_id, conversation_id) ->
      ( Some response_id
      , Some (conversation_id, Keeper_usage_resolution.Fresh)
      , Keeper_spend_observation.Client_report
          { official_turn = ordinal
          ; response_id
          ; model = "glm-fixture"
          ; conversation_id
          ; position = Keeper_usage_resolution.Fresh
          ; usage_scope = scope
          ; count =
              (if replaced
               then Keeper_client_usage_report.Count_replaced
               else
                 Keeper_client_usage_report.Running_count
                   (Keeper_usage_resolution.api_usage_of_sample usage))
          ; vendor_total_tokens = None
          } )
  in
  let spend_observation = if recorded then Some observation else None in
  Keeper_hooks_agent_core.emit_cost_event
    ~masc_root
    ~agent_name:agent
    ~task_id:(Some "task-lost")
    ~trace_id:trace
    ~keeper_turn_id:turn
    ~agent_core_turn_ordinal:ordinal
    ~model:"glm-fixture"
    ~input_tokens:input
    ~output_tokens:10
    ~cost_usd:0.0
    ~usage_projection:(Cost_ledger.Raw_observation scope)
    ?response_id
    ?conversation
    ?spend_observation
    ~runtime_attempt:(run, "glm-coding.fixture", lane)
    ~cache_read_input_tokens:(input / 2)
    ()
;;

(* What a commit writes for its turn: the resolved spend of its last reading. *)
let committed ~masc_root ?(agent = keeper) ~turn ~ordinal ~input () =
  Keeper_hooks_agent_core.emit_cost_event
    ~masc_root
    ~agent_name:agent
    ~task_id:None
    ~trace_id:trace
    ~keeper_turn_id:turn
    ~agent_core_turn_ordinal:ordinal
    ~model:"glm-fixture"
    ~input_tokens:input
    ~output_tokens:10
    ~cost_usd:0.0
    ~usage_projection:Cost_ledger.Resolved_delta
    ()
;;

let rows masc_root =
  Dated_jsonl.read_recent (Cost_ledger.store_of_masc_root masc_root) 1000
  |> List.map (fun json ->
    match Cost_ledger.of_json json with
    | Ok row -> row, json
    | Error error -> failf "ledger row: %s" (Cost_ledger.decode_error_to_string error))
;;

(* (turn, run, lane, reading, input, cache read) of every settled reading. *)
let settled masc_root =
  List.filter_map
    (fun ((row : Cost_ledger.t), json) ->
       match row.source, row.usage_projection, row.usage with
       | ( Cost_ledger.Auto_trajectory identity
         , Cost_ledger.Resolved_attempt_delta attempt
         , Cost_ledger.Usage_reported { input_tokens; _ } ) ->
         Some
           ( identity.keeper_turn_id
           , attempt.routing_run_id
           , attempt.lane_attempt_index
           , attempt.reading_index
           , input_tokens
           , Yojson.Safe.Util.(json |> member "cache_read_tokens" |> to_int) )
       | _ -> None)
    (rows masc_root)
  |> List.sort compare
;;

let settle masc_root =
  match Keeper_unsettled_spend.settle ~masc_root ~agent_name:keeper ~observed_at:1.0 with
  | Ok outcome -> outcome
  | Error error -> failf "settle: %s" (Dated_jsonl.read_error_to_string error)
;;

let settled_entry = list (pair int (pair string (pair int (pair int (pair int int)))))

let flatten = List.map (fun (turn, run, lane, reading, input, cache) ->
  turn, (run, (lane, (reading, (input, cache)))))

(* Turn 11 ran three requests and the server stopped before it committed. *)
let test_a_cancelled_executions_requests_are_settled_under_its_turn () =
  with_ledger (fun masc_root ->
    raw ~masc_root ~turn:10 ~ordinal:4 ~run:"run-a" ~input:90 ();
    committed ~masc_root ~turn:10 ~ordinal:4 ~input:90 ();
    raw ~masc_root ~turn:11 ~ordinal:5 ~run:"run-b" ~input:100 ();
    raw ~masc_root ~turn:11 ~ordinal:6 ~run:"run-b" ~input:200 ();
    raw ~masc_root ~turn:11 ~ordinal:7 ~run:"run-b" ~input:300 ();
    let outcome = settle masc_root in
    check int "one turn" 1 outcome.settled_turns;
    check int "three readings" 3 outcome.settled_readings;
    check settled_entry "each request is its own reading, with its cache reads"
      (flatten
         [ 11, "run-b", 0, 0, 100, 50; 11, "run-b", 0, 1, 200, 100; 11, "run-b", 0, 2, 300, 150 ])
      (flatten (settled masc_root)))
;;

let test_settling_again_writes_nothing () =
  with_ledger (fun masc_root ->
    committed ~masc_root ~turn:10 ~ordinal:4 ~input:90 ();
    raw ~masc_root ~turn:11 ~ordinal:5 ~run:"run-b" ~input:100 ();
    ignore (settle masc_root);
    let before = List.length (rows masc_root) in
    let again = settle masc_root in
    check int "no readings the second time" 0 again.settled_readings;
    check int "no rows the second time" before (List.length (rows masc_root)))
;;

(* The committed turn's raw rows lie below its resolved row. *)
let test_a_committed_turns_requests_are_left_alone () =
  with_ledger (fun masc_root ->
    raw ~masc_root ~turn:10 ~ordinal:3 ~run:"run-a" ~input:80 ();
    raw ~masc_root ~turn:10 ~ordinal:4 ~run:"run-a" ~input:90 ();
    committed ~masc_root ~turn:10 ~ordinal:4 ~input:90 ();
    let outcome = settle masc_root in
    check int "nothing to settle" 0 outcome.settled_readings;
    check settled_entry "no attempt readings" [] (flatten (settled masc_root)))
;;

(* A conversation count is read against the committed cursor; the next count
   of the same conversation covers it. *)
let test_conversation_counts_are_left_to_the_cursor () =
  with_ledger (fun masc_root ->
    committed ~masc_root ~turn:10 ~ordinal:4 ~input:90 ();
    raw ~masc_root ~scope:Runtime_usage_scope.Conversation_cumulative
      ~client:("resp-1", "thread-1") ~turn:11 ~ordinal:1 ~run:"run-b" ~input:5000 ();
    raw ~masc_root ~turn:11 ~ordinal:6 ~run:"run-b" ~input:200 ();
    let outcome = settle masc_root in
    check int "only the request" 1 outcome.settled_readings;
    check settled_entry "the per-request reading"
      (flatten [ 11, "run-b", 0, 0, 200, 100 ]) (flatten (settled masc_root)))
;;

(* A client restates its running turn count; the last count is the reading,
   as it is when the execution observes it live. *)
let test_a_client_turn_keeps_its_last_count () =
  with_ledger (fun masc_root ->
    committed ~masc_root ~turn:10 ~ordinal:4 ~input:90 ();
    raw ~masc_root ~scope:Runtime_usage_scope.Turn_total ~client:("resp-1", "thread-1")
      ~turn:11 ~ordinal:1 ~run:"run-b" ~input:100 ();
    raw ~masc_root ~scope:Runtime_usage_scope.Turn_total ~client:("resp-1", "thread-1")
      ~turn:11 ~ordinal:1 ~run:"run-b" ~input:150 ();
    let outcome = settle masc_root in
    check int "one reading" 1 outcome.settled_readings;
    check settled_entry "the last count"
      (flatten [ 11, "run-b", 0, 0, 150, 75 ]) (flatten (settled masc_root)))
;;

(* Another Keeper's resolved row does not stop the read, and its raw rows are
   not this Keeper's to settle. *)
let test_another_keepers_rows_are_not_settled () =
  with_ledger (fun masc_root ->
    committed ~masc_root ~turn:10 ~ordinal:4 ~input:90 ();
    raw ~masc_root ~turn:11 ~ordinal:5 ~run:"run-b" ~input:100 ();
    raw ~masc_root ~agent:"other-keeper" ~turn:3 ~ordinal:1 ~run:"run-x" ~input:700 ();
    committed ~masc_root ~agent:"other-keeper" ~turn:2 ~ordinal:1 ~input:600 ();
    let outcome = settle masc_root in
    check int "this keeper's one reading" 1 outcome.settled_readings;
    check settled_entry "this keeper's request"
      (flatten [ 11, "run-b", 0, 0, 100, 50 ]) (flatten (settled masc_root)))
;;

(* Two cancelled executions of one turn both ran lane attempt 0 and numbered
   their first reading 0. Their runs keep the rows apart, so a reader keeps
   both instead of dropping a shared key. *)
let test_two_cancelled_runs_of_one_turn_keep_distinct_keys () =
  with_ledger (fun masc_root ->
    committed ~masc_root ~turn:10 ~ordinal:4 ~input:90 ();
    raw ~masc_root ~scope:Runtime_usage_scope.Turn_total ~client:("resp-1", "thread-1")
      ~turn:11 ~ordinal:1 ~run:"run-b" ~input:100 ();
    raw ~masc_root ~scope:Runtime_usage_scope.Turn_total ~client:("resp-2", "thread-2")
      ~turn:11 ~ordinal:1 ~run:"run-c" ~input:120 ();
    let outcome = settle masc_root in
    check int "two readings" 2 outcome.settled_readings;
    let keys =
      List.filter_map
        (fun ((row : Cost_ledger.t), _) ->
           match row.usage_projection with
           | Cost_ledger.Resolved_attempt_delta _ -> Cost_ledger.inference_key row
           | Cost_ledger.Raw_observation _ | Cost_ledger.Resolved_delta -> None)
        (rows masc_root)
    in
    check int "two keys" 2 (List.length (List.sort_uniq Cost_ledger.compare_inference_key keys)))
;;

(* Rows written before rows carried their observation are not settled: their
   counts alone do not say what the spend read. *)
let test_a_row_without_its_observation_is_not_settled () =
  with_ledger (fun masc_root ->
    committed ~masc_root ~turn:10 ~ordinal:4 ~input:90 ();
    raw ~masc_root ~recorded:false ~turn:11 ~ordinal:5 ~run:"run-b" ~input:100 ();
    raw ~masc_root ~turn:11 ~ordinal:6 ~run:"run-b" ~input:200 ();
    let outcome = settle masc_root in
    check int "the recorded request only" 1 outcome.settled_readings;
    check int "the unrecorded row is not placed" 1 outcome.unplaced_rows;
    check settled_entry "the recorded request"
      (flatten [ 11, "run-b", 0, 0, 200, 100 ]) (flatten (settled masc_root)))
;;

let resolution_statuses masc_root =
  List.filter_map
    (fun ((row : Cost_ledger.t), json) ->
       match row.usage_projection with
       | Cost_ledger.Resolved_attempt_delta attempt ->
         Some
           ( attempt.reading_index
           , Yojson.Safe.Util.(json |> member "resolution_status" |> to_string) )
       | Cost_ledger.Raw_observation _ | Cost_ledger.Resolved_delta -> None)
    (rows masc_root)
  |> List.sort compare
;;

(* Whether the provider reported a cost survives: a reported 0.25 resolves
   exact and an unreported cost resolves without one, as they did live. *)
let test_a_reported_cost_is_kept_apart_from_no_report () =
  with_ledger (fun masc_root ->
    committed ~masc_root ~turn:10 ~ordinal:4 ~input:90 ();
    raw ~masc_root ~cost_usd:0.25 ~turn:11 ~ordinal:5 ~run:"run-b" ~input:100 ();
    raw ~masc_root ~turn:11 ~ordinal:6 ~run:"run-b" ~input:200 ();
    ignore (settle masc_root);
    check (list (pair int string)) "statuses as resolved live"
      [ 0, "exact"; 1, "exact_cost_unavailable" ]
      (resolution_statuses masc_root))
;;

(* A client count replaced by compaction counts nothing; it is observed as
   replaced, not as a count of zero. *)
let test_a_replaced_client_count_is_observed_as_replaced () =
  with_ledger (fun masc_root ->
    committed ~masc_root ~turn:10 ~ordinal:4 ~input:90 ();
    raw ~masc_root ~scope:Runtime_usage_scope.Turn_total ~client:("resp-1", "thread-1")
      ~replaced:true ~turn:11 ~ordinal:1 ~run:"run-b" ~input:0 ();
    let outcome = settle masc_root in
    check int "one reading" 1 outcome.settled_readings;
    let missing =
      List.filter
        (fun ((row : Cost_ledger.t), _) ->
           match row.usage_projection, row.usage with
           | Cost_ledger.Resolved_attempt_delta _, Cost_ledger.Usage_missing -> true
           | _ -> false)
        (rows masc_root)
    in
    check int "a reading with no count, not a count of zero" 1 (List.length missing))
;;

(* An Agent Core response that carried no usage is a reading with no count,
   as the execution observed it. *)
let test_a_response_without_usage_is_a_reading_with_no_count () =
  with_ledger (fun masc_root ->
    committed ~masc_root ~turn:10 ~ordinal:4 ~input:90 ();
    raw ~masc_root ~usage_reported:false ~turn:11 ~ordinal:5 ~run:"run-b" ~input:0 ();
    raw ~masc_root ~turn:11 ~ordinal:6 ~run:"run-b" ~input:200 ();
    let outcome = settle masc_root in
    check int "both readings" 2 outcome.settled_readings;
    check (list (pair int string)) "the first resolves as missing"
      [ 0, "usage_missing"; 1, "exact_cost_unavailable" ]
      (resolution_statuses masc_root))
;;

let observation_round_trips observation =
  match Keeper_spend_observation.of_json (Keeper_spend_observation.to_json observation) with
  | Ok decoded ->
    check string "round trip"
      (Yojson.Safe.to_string (Keeper_spend_observation.to_json observation))
      (Yojson.Safe.to_string (Keeper_spend_observation.to_json decoded))
  | Error error -> failf "decode: %s" error
;;

let test_observations_round_trip () =
  observation_round_trips
    (Keeper_spend_observation.Agent_core_response
       { response_id = "resp"; ordinal = 3; model = "m"; usage = None });
  observation_round_trips
    (Keeper_spend_observation.Agent_core_response
       { response_id = ""; ordinal = 4; model = "m"; usage = Some (sample ~cost_usd:0.5 120) });
  observation_round_trips
    (Keeper_spend_observation.Client_report
       { official_turn = 2
       ; response_id = "turn-2"
       ; model = "m"
       ; conversation_id = "thread"
       ; position = Keeper_usage_resolution.Resumed
       ; usage_scope = Runtime_usage_scope.Turn_total
       ; count = Keeper_client_usage_report.Count_replaced
       ; vendor_total_tokens = Some 900
       })
;;

let test_rows_above_the_newest_resolved_row () =
  let row ~agent ~projection =
    `Assoc
      [ "agent", `String agent
      ; "task_id", `Null
      ; "model", `String "m"
      ; "input_tokens", `Int 1
      ; "output_tokens", `Int 1
      ; "cost_usd", `Float 0.0
      ; "usage_missing", `Bool false
      ; "usage_projection", `String projection
      ; "usage_scope", (if String.equal projection "raw_observation" then `String "per_request" else `Null)
      ; "timestamp", `String "2026-10-06T00:00:00Z"
      ; "source", `String "auto_trajectory"
      ; "trace_id", `String trace
      ; "keeper_turn_id", `Int 1
      ; "agent_core_turn_ordinal", `Int 1
      ]
  in
  let newest_first =
    [ row ~agent:keeper ~projection:"raw_observation"
    ; row ~agent:"other-keeper" ~projection:"resolved_delta"
    ; row ~agent:keeper ~projection:"raw_observation"
    ; row ~agent:keeper ~projection:"resolved_delta"
    ; row ~agent:keeper ~projection:"raw_observation"
    ]
  in
  check int "the two raw rows above this keeper's resolved row" 2
    (List.length (Keeper_unsettled_spend.unsettled_rows ~agent_name:keeper newest_first))
;;

let () =
  run
    "keeper unsettled spend"
    [ ( "settle"
      , [ test_case "a cancelled execution's requests are settled under its turn" `Quick
            test_a_cancelled_executions_requests_are_settled_under_its_turn
        ; test_case "settling again writes nothing" `Quick test_settling_again_writes_nothing
        ; test_case "a committed turn's requests are left alone" `Quick
            test_a_committed_turns_requests_are_left_alone
        ; test_case "conversation counts are left to the cursor" `Quick
            test_conversation_counts_are_left_to_the_cursor
        ; test_case "a client turn keeps its last count" `Quick
            test_a_client_turn_keeps_its_last_count
        ; test_case "another keeper's rows are not settled" `Quick
            test_another_keepers_rows_are_not_settled
        ; test_case "two cancelled runs of one turn keep distinct keys" `Quick
            test_two_cancelled_runs_of_one_turn_keep_distinct_keys
        ; test_case "a row without its observation is not settled" `Quick
            test_a_row_without_its_observation_is_not_settled
        ; test_case "a reported cost is kept apart from no report" `Quick
            test_a_reported_cost_is_kept_apart_from_no_report
        ; test_case "a replaced client count is observed as replaced" `Quick
            test_a_replaced_client_count_is_observed_as_replaced
        ; test_case "a response without usage is a reading with no count" `Quick
            test_a_response_without_usage_is_a_reading_with_no_count
        ; test_case "observations round trip" `Quick test_observations_round_trip
        ; test_case "rows above the newest resolved row" `Quick
            test_rows_above_the_newest_resolved_row
        ] )
    ]
;;
