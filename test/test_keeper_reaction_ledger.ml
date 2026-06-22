open Alcotest
open Masc
open Yojson.Safe.Util

let with_temp_base f =
  let base_path = Filename.temp_file "masc-krl-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  f base_path
;;

let board_payload ?updated_at ~post_id:(_ : string) () :
  Keeper_event_queue.stimulus_payload
  =
  Keeper_event_queue.Board_signal
    { kind = Keeper_event_queue.Post_created
    ; author = "operator"
    ; title = "Ship reaction ledger"
    ; content = "Please react"
    ; hearth = None
    ; updated_at
    }
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

let no_progress_recovery_stimulus ?(keeper_name = "no-progress-keeper") () :
  Keeper_event_queue.stimulus
  =
  { post_id = "no-progress-loop:" ^ keeper_name
  ; urgency = Immediate
  ; arrived_at = 1234.5
  ; payload = Keeper_event_queue.No_progress_recovery
  }
;;

let fusion_completed_stimulus ?(run_id = "fus-ledger-1") () :
  Keeper_event_queue.stimulus
  =
  { post_id = "fusion-run:" ^ run_id
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 1234.5
  ; payload =
      Keeper_event_queue.Fusion_completed
        { run_id; ok = true; resolved_answer = "use approach B"; board_post_id = "post-fus" }
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
  let config = Workspace.default_config base_path in
  let keeper_name = "receipt-keeper" in
  let receipt_json =
    `Assoc
      [ "schema", `String "keeper.execution_receipt.v1"
      ; "trace_id", `String "trace-1"
      ; "outcome", `String "receipt_failed"
      ; "terminal_reason_code", `String "completion_contract_violation"
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
    ~terminal_reason_code:"completion_contract_violation"
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
    "completion_contract_violation"
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

let test_no_progress_recovery_stimulus_is_typed () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "no-progress-keeper" in
  let stimulus = no_progress_recovery_stimulus ~keeper_name () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let row =
    Keeper_reaction_ledger.read_recent_for_keeper ~base_path ~keeper_name ~limit:1
    |> latest_row
  in
  check_member_string
    "no-progress stimulus kind"
    "no_progress_recovery"
    "kind"
    (row |> member "stimulus");
  check string "stable stimulus prefix" "stimulus:"
    (String.sub (row |> member "stimulus_id" |> to_string) 0 9)
;;

let test_no_progress_recovery_reaction_clears_pending () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "no-progress-keeper" in
  let stimulus = no_progress_recovery_stimulus ~keeper_name () in
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

(* RFC-0020: the stimulus payload is a typed closed variant, so a malformed
   payload is unrepresentable — the prior [test_malformed_typed_payload_degrades_summary]
   covered a parse-error path that can no longer occur and was removed. *)

(* RFC-0266 regression: a recorded [Fusion_completed] stimulus is a recognized
   closed-sum kind and must NOT be miscounted as an unsupported stimulus.  The
   prior string whitelist ([board_signal]/[bootstrap]/[no_progress_recovery])
   dropped [fusion_completed] into [unsupported_stimulus_count], degrading the
   summary on every async fusion wake.  (We assert only the unsupported counter:
   with no reaction row the stimulus is still legitimately pending.) *)
let test_fusion_completed_stimulus_is_supported () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "fusion-keeper" in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    (fusion_completed_stimulus ());
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "fusion_completed is not an unsupported stimulus" 0
    (summary |> member "unsupported_stimulus_count" |> to_int)
;;

(* Drift guard: [stimulus_kind_of_string] must stay the inverse of
   [stimulus_kind_to_string] for every closed-sum variant, and reject unknowns.
   Pairs with the exhaustive match in [note_stimulus_kind] so a new variant
   cannot silently fall back to [unsupported]. *)
let test_stimulus_kind_string_roundtrip () =
  let roundtrips k =
    match
      Keeper_reaction_ledger.stimulus_kind_of_string
        (Keeper_reaction_ledger.stimulus_kind_to_string k)
    with
    | Some k' ->
      String.equal
        (Keeper_reaction_ledger.stimulus_kind_to_string k')
        (Keeper_reaction_ledger.stimulus_kind_to_string k)
    | None -> false
  in
  List.iter
    (fun k ->
      check bool "stimulus_kind round-trips through string" true (roundtrips k))
    [ Keeper_reaction_ledger.Board_signal
    ; Keeper_reaction_ledger.Bootstrap
    ; Keeper_reaction_ledger.No_progress_recovery
    ; Keeper_reaction_ledger.Fusion_completed
    ];
  check bool "unknown stimulus kind string is None" true
    (Option.is_none (Keeper_reaction_ledger.stimulus_kind_of_string "totally_unknown"))
;;

(* Drift guard: [reaction_kind_of_string] is total — known strings round-trip to
   their typed variant, unknown strings preserve the original via
   [Unknown_reaction].  Pairs with the exhaustive match in [note_reaction_kind]. *)
let test_reaction_kind_string_roundtrip () =
  let roundtrips k =
    String.equal
      (Keeper_reaction_ledger.reaction_kind_to_string
         (Keeper_reaction_ledger.reaction_kind_of_string
            (Keeper_reaction_ledger.reaction_kind_to_string k)))
      (Keeper_reaction_ledger.reaction_kind_to_string k)
  in
  List.iter
    (fun k ->
      check bool "reaction_kind round-trips through string" true (roundtrips k))
    [ Keeper_reaction_ledger.Turn_started
    ; Keeper_reaction_ledger.Execution_receipt
    ; Keeper_reaction_ledger.Terminal_reason
    ; Keeper_reaction_ledger.Cursor_ack
    ; Keeper_reaction_ledger.Operator_escalation
    ; Keeper_reaction_ledger.Supervisor_recovery_requested
    ];
  check string "unknown reaction string preserved as Unknown_reaction" "legacy_custom"
    (Keeper_reaction_ledger.reaction_kind_to_string
       (Keeper_reaction_ledger.reaction_kind_of_string "legacy_custom"))
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
            "no-progress recovery stimulus is typed"
            `Quick
            test_no_progress_recovery_stimulus_is_typed
        ; test_case
            "no-progress recovery reaction clears pending"
            `Quick
            test_no_progress_recovery_reaction_clears_pending
        ; test_case
            "unknown reaction degrades summary"
            `Quick
            test_unknown_reaction_degrades_summary
        ; test_case
            "fusion_completed stimulus is supported (RFC-0266)"
            `Quick
            test_fusion_completed_stimulus_is_supported
        ; test_case
            "stimulus_kind string round-trip drift guard"
            `Quick
            test_stimulus_kind_string_roundtrip
        ; test_case
            "reaction_kind string round-trip drift guard"
            `Quick
            test_reaction_kind_string_roundtrip
        ] )
    ]
;;
