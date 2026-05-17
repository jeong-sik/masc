open Alcotest
open Masc_mcp
open Yojson.Safe.Util

let with_temp_base f =
  let base_path = Filename.temp_file "masc-krl-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  f base_path
;;

let board_payload ?updated_at ~post_id () =
  `Assoc
    ([ "source", `String "board_signal"
     ; "kind", `String "post_created"
     ; "post_id", `String post_id
     ; "author", `String "operator"
     ; "title", `String "Ship reaction ledger"
     ; "content", `String "Please react"
     ]
     @
     match updated_at with
     | Some value -> [ "updated_at_unix", `Float value ]
     | None -> [])
  |> Yojson.Safe.to_string
;;

let board_stimulus ?(post_id = "post-42") ?updated_at () :
  Keeper_event_queue.stimulus
  =
  { post_id
  ; urgency = Immediate
  ; arrived_at = 1234.5
  ; payload = board_payload ?updated_at ~post_id ()
  }
;;

let stay_silent_recovery_stimulus ?(keeper_name = "silent-keeper") () :
  Keeper_event_queue.stimulus
  =
  let payload =
    `Assoc
      [ "source", `String "stay_silent_recovery"
      ; "keeper", `String keeper_name
      ; "streak", `Int 10
      ; "threshold", `Int 10
      ]
    |> Yojson.Safe.to_string
  in
  { post_id = "stay-silent-loop:" ^ keeper_name
  ; urgency = Immediate
  ; arrived_at = 1234.5
  ; payload
  }
;;

let check_member_string label expected key json =
  check string label expected (json |> member key |> to_string)
;;

let latest_row rows =
  match List.rev rows with
  | row :: _ -> row
  | [] -> fail "expected at least one reaction ledger row"
;;

let test_event_queue_stimulus_and_turn_reaction () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "ledger-keeper" in
  let stimulus = board_stimulus () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Keeper_reaction_ledger.record_event_queue_reaction
    ~base_path
    ~keeper_name
    ~reaction_kind:Keeper_reaction_ledger.Turn_started
    stimulus;
  let rows =
    Keeper_reaction_ledger.read_recent_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "two rows persisted" 2 (List.length rows);
  let stimulus_row = List.nth rows 0 in
  check_member_string "stimulus schema" "keeper.reaction_ledger.v1" "schema" stimulus_row;
  check_member_string "stimulus record kind" "stimulus" "record_kind" stimulus_row;
  check_member_string "board stimulus id" "board:post-42" "stimulus_id" stimulus_row;
  check_member_string
    "stimulus kind"
    "board_signal"
    "kind"
    (stimulus_row |> member "stimulus");
  let reaction_row = List.nth rows 1 in
  check_member_string "reaction record kind" "reaction" "record_kind" reaction_row;
  check_member_string "reaction stimulus id" "board:post-42" "stimulus_id" reaction_row;
  check_member_string
    "reaction kind"
    "turn_started"
    "kind"
    (reaction_row |> member "reaction")
;;

let test_cursor_ack_is_replayable_state_entry () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "cursor-keeper" in
  Keeper_reaction_ledger.record_board_cursor_ack
    ~base_path
    ~keeper_name
    ~cursor_ts:5678.25
    ~post_id:(Some "post-99")
    ();
  let row =
    Keeper_reaction_ledger.read_recent_for_keeper ~base_path ~keeper_name ~limit:1
    |> latest_row
  in
  check_member_string "cursor ack record kind" "cursor_ack" "record_kind" row;
  check_member_string "cursor ack stimulus id" "board:post-99" "stimulus_id" row;
  check (float 0.0001) "cursor timestamp" 5678.25
    (row |> member "cursor" |> member "cursor_ts" |> to_float);
  check_member_string "cursor post id" "post-99" "post_id" (row |> member "cursor");
  check bool "cursor acked" true
    (row |> member "reaction" |> member "cursor_acked" |> to_bool)
;;

let test_execution_receipt_links_to_reaction_ledger () =
  with_temp_base @@ fun base_path ->
  let config = Coord.default_config base_path in
  let keeper_name = "receipt-keeper" in
  let receipt_json =
    `Assoc
      [ "schema", `String "keeper.execution_receipt.v1"
      ; "trace_id", `String "trace-1"
      ; "outcome", `String "receipt_failed"
      ; "terminal_reason_code", `String "tool_contract_violation"
      ]
  in
  Keeper_reaction_ledger.record_execution_receipt_reaction
    config
    ~keeper_name
    ~trace_id:"trace-1"
    ~turn_count:7
    ~current_task_id:(Some "task-275")
    ~goal_ids:[ "goal-world-reactivity-p0-20260517" ]
    ~outcome:"receipt_failed"
    ~terminal_reason_code:"tool_contract_violation"
    ~receipt_json
    ();
  let row =
    Keeper_reaction_ledger.read_recent_for_keeper ~base_path ~keeper_name ~limit:1
    |> latest_row
  in
  check_member_string "receipt reaction record kind" "reaction" "record_kind" row;
  check_member_string "receipt reaction stimulus id" "task:task-275" "stimulus_id" row;
  let reaction = row |> member "reaction" in
  check_member_string "terminal reaction kind" "terminal_reason" "kind" reaction;
  check_member_string
    "terminal reason"
    "tool_contract_violation"
    "terminal_reason_code"
    reaction;
  check_member_string
    "embedded receipt schema"
    "keeper.execution_receipt.v1"
    "schema"
    (reaction |> member "receipt")
;;

let test_summary_marks_unreacted_and_reacted_stimuli () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "summary-keeper" in
  let stimulus = board_stimulus ~post_id:"post-summary" () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let pending_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "pending summary status" "degraded" "status" pending_summary;
  check bool "pending summary asks for operator visibility" true
    (pending_summary |> member "operator_action_required" |> to_bool);
  check int "pending stimulus count" 1
    (pending_summary |> member "pending_stimulus_count" |> to_int);
  check string "pending stimulus id" "board:post-summary"
    (pending_summary
     |> member "pending_stimulus_ids"
     |> to_list
     |> List.hd
     |> to_string);
  Keeper_reaction_ledger.record_event_queue_reaction
    ~base_path
    ~keeper_name
    ~reaction_kind:Keeper_reaction_ledger.Turn_started
    stimulus;
  let reacted_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "reacted summary status" "ok" "status" reacted_summary;
  check bool "reacted summary clears operator action" false
    (reacted_summary |> member "operator_action_required" |> to_bool);
  check int "reacted pending stimulus count" 0
    (reacted_summary |> member "pending_stimulus_count" |> to_int);
  check int "turn started count" 1
    (reacted_summary |> member "turn_started_count" |> to_int)
;;

let test_summary_cursor_ack_sweeps_covered_board_stimuli () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "cursor-sweep-keeper" in
  let first = board_stimulus ~post_id:"post-1" ~updated_at:10.0 () in
  let second = board_stimulus ~post_id:"post-2" ~updated_at:20.0 () in
  let third = board_stimulus ~post_id:"post-3" ~updated_at:30.0 () in
  List.iter
    (Keeper_reaction_ledger.record_event_queue_stimulus ~base_path ~keeper_name)
    [ first; second ];
  Keeper_reaction_ledger.record_board_cursor_ack
    ~base_path
    ~keeper_name
    ~cursor_ts:20.0
    ~post_id:(Some "post-2")
    ();
  let swept_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "cursor-swept summary status" "ok" "status" swept_summary;
  check int "cursor-swept pending count" 0
    (swept_summary |> member "pending_stimulus_count" |> to_int);
  check int "cursor sweep count" 1
    (swept_summary |> member "cursor_swept_stimulus_count" |> to_int);
  Keeper_reaction_ledger.record_event_queue_stimulus ~base_path ~keeper_name third;
  let future_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "future stimulus remains degraded" "degraded" "status" future_summary;
  check int "future pending count" 1
    (future_summary |> member "pending_stimulus_count" |> to_int);
  check string "future pending stimulus id" "board:post-3"
    (future_summary
     |> member "pending_stimulus_ids"
     |> to_list
     |> List.hd
     |> to_string)
;;

let test_summary_cursor_ack_respects_post_id_tiebreaker () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "cursor-tiebreaker-keeper" in
  let first = board_stimulus ~post_id:"post-1" ~updated_at:50.0 () in
  let second = board_stimulus ~post_id:"post-2" ~updated_at:50.0 () in
  List.iter
    (Keeper_reaction_ledger.record_event_queue_stimulus ~base_path ~keeper_name)
    [ first; second ];
  Keeper_reaction_ledger.record_board_cursor_ack
    ~base_path
    ~keeper_name
    ~cursor_ts:50.0
    ~post_id:(Some "post-1")
    ();
  let partial_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "partial cursor summary status" "degraded" "status" partial_summary;
  check int "one post remains pending" 1
    (partial_summary |> member "pending_stimulus_count" |> to_int);
  check string "later same-timestamp post remains pending" "board:post-2"
    (partial_summary
     |> member "pending_stimulus_ids"
     |> to_list
     |> List.hd
     |> to_string);
  Keeper_reaction_ledger.record_board_cursor_ack
    ~base_path
    ~keeper_name
    ~cursor_ts:50.0
    ~post_id:(Some "post-2")
    ();
  let complete_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "complete cursor summary status" "ok" "status" complete_summary;
  check int "same timestamp posts cleared" 0
    (complete_summary |> member "pending_stimulus_count" |> to_int)
;;

let test_stay_silent_recovery_stimulus_is_typed () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "silent-keeper" in
  let stimulus = stay_silent_recovery_stimulus ~keeper_name () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let row =
    Keeper_reaction_ledger.read_recent_for_keeper ~base_path ~keeper_name ~limit:1
    |> latest_row
  in
  check_member_string
    "stay-silent stimulus kind"
    "stay_silent_recovery"
    "kind"
    (row |> member "stimulus");
  check string "stable stimulus prefix" "stimulus:"
    (String.sub (row |> member "stimulus_id" |> to_string) 0 9)
;;

let test_stay_silent_recovery_reaction_clears_pending () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "silent-keeper" in
  let stimulus = stay_silent_recovery_stimulus ~keeper_name () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let pending_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "pending recovery summary status" "degraded" "status" pending_summary;
  check int "recovery stimulus pending" 1
    (pending_summary |> member "pending_stimulus_count" |> to_int);
  Keeper_reaction_ledger.record_event_queue_reaction
    ~base_path
    ~keeper_name
    ~reaction_kind:Keeper_reaction_ledger.Turn_started
    stimulus;
  let reacted_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "reacted recovery summary status" "ok" "status" reacted_summary;
  check bool "reacted recovery needs no operator action" false
    (reacted_summary |> member "operator_action_required" |> to_bool);
  check int "recovery stimulus cleared" 0
    (reacted_summary |> member "pending_stimulus_count" |> to_int);
  check int "turn-start reaction counted" 1
    (reacted_summary |> member "turn_started_count" |> to_int)
;;

let test_unknown_reaction_degrades_summary () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "unknown-reaction-keeper" in
  let stimulus = board_stimulus ~post_id:"post-unknown-reaction" () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Keeper_reaction_ledger.record_event_queue_reaction
    ~base_path
    ~keeper_name
    ~reaction_kind:(Keeper_reaction_ledger.Unknown_reaction "legacy_custom")
    stimulus;
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "unknown reaction summary status" "degraded" "status" summary;
  check bool "unknown reaction requires operator action" true
    (summary |> member "operator_action_required" |> to_bool);
  check int "unknown reaction counted" 1
    (summary |> member "unknown_reaction_count" |> to_int);
  check int "pending cleared by reaction row" 0
    (summary |> member "pending_stimulus_count" |> to_int)
;;

let test_malformed_typed_payload_degrades_summary () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "malformed-payload-keeper" in
  let stimulus =
    { Keeper_event_queue.post_id = "bad-board"
    ; urgency = Immediate
    ; arrived_at = 1234.5
    ; payload = {|{"source":"board_signal"|}
    }
  in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "malformed payload summary status" "degraded" "status" summary;
  check bool "malformed payload requires operator action" true
    (summary |> member "operator_action_required" |> to_bool);
  check int "payload parse error counted" 1
    (summary |> member "payload_parse_error_count" |> to_int)
;;

let () =
  run
    "keeper_reaction_ledger"
    [ ( "ledger"
      , [ test_case
            "event queue stimulus and turn reaction are durable"
            `Quick
            test_event_queue_stimulus_and_turn_reaction
        ; test_case
            "cursor ack is replayable state entry"
            `Quick
            test_cursor_ack_is_replayable_state_entry
        ; test_case
            "execution receipt links to reaction ledger"
            `Quick
            test_execution_receipt_links_to_reaction_ledger
        ; test_case
            "summary marks unreacted and reacted stimuli"
            `Quick
            test_summary_marks_unreacted_and_reacted_stimuli
        ; test_case
            "summary cursor ack sweeps covered board stimuli"
            `Quick
            test_summary_cursor_ack_sweeps_covered_board_stimuli
        ; test_case
            "summary cursor ack respects board post id tiebreaker"
            `Quick
            test_summary_cursor_ack_respects_post_id_tiebreaker
        ; test_case
            "stay-silent recovery stimulus is typed"
            `Quick
            test_stay_silent_recovery_stimulus_is_typed
        ; test_case
            "stay-silent recovery reaction clears pending"
            `Quick
            test_stay_silent_recovery_reaction_clears_pending
        ; test_case
            "unknown reaction degrades summary"
            `Quick
            test_unknown_reaction_degrades_summary
        ; test_case
            "malformed typed payload degrades summary"
            `Quick
            test_malformed_typed_payload_degrades_summary
        ] )
    ]
;;
