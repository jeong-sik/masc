open Alcotest
open Masc_mcp
open Yojson.Safe.Util

let with_temp_base f =
  let base_path = Filename.temp_file "masc-krl-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  f base_path
;;

let board_payload ~post_id =
  `Assoc
    [ "source", `String "board_signal"
    ; "kind", `String "post_created"
    ; "post_id", `String post_id
    ; "author", `String "operator"
    ; "title", `String "Ship reaction ledger"
    ; "content", `String "Please react"
    ]
  |> Yojson.Safe.to_string
;;

let board_stimulus ?(post_id = "post-42") () : Keeper_event_queue.stimulus =
  { post_id
  ; urgency = Immediate
  ; arrived_at = 1234.5
  ; payload = board_payload ~post_id
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
        ] )
    ]
;;
