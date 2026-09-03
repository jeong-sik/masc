(* How one conversation's rows become turns, and what a turn's rows look like
   once it is assembled.

   These are the rules the pane draws by: a turn appears where its first row
   appeared, its rows read input then progress then tools then output, a user
   line the transcript already holds does not appear twice, and a turn stops
   claiming a number when its rows disagree about which turn it was. They were
   only checked through the surfaces that draw them, so the assembly could be
   rewritten without anything saying it had changed. *)

module Tui_types = Masc_tui_types

let row ?(keeper = "alpha") ?(request_id = "") ?turn_sequence
    ?(operation_seq = 0) ~role ~phase ~text at : Tui_types.msg_entry =
  { Tui_types.me_keeper_name = keeper
  ; me_role = role
  ; me_identity = Tui_types.Persisted_row (Printf.sprintf "%s-%s-%.0f" request_id text at)
  ; me_turn_phase = phase
  ; me_turn_sequence = turn_sequence
  ; me_operation_seq = operation_seq
  ; me_text = text
  ; me_memory_summary = None
  ; me_submitted_at = None
  ; me_tool_block = None
  ; me_skill_activity = None
  ; me_timestamp = ""
  ; me_request_id = request_id
  ; me_at = at
  }
;;

let user ?turn_sequence ?operation_seq ~request_id text at =
  row ?turn_sequence ?operation_seq ~request_id
    ~role:(Tui_types.Message_user (Tui_types.Sent_by_operator "you"))
    ~phase:Tui_types.Turn_input ~text at
;;

let keeper ?turn_sequence ?operation_seq ~request_id text at =
  row ?turn_sequence ?operation_seq ~request_id ~role:Tui_types.Message_keeper
    ~phase:Tui_types.Turn_output ~text at
;;

let tool ?operation_seq ~request_id text at =
  row ?operation_seq ~request_id ~role:Tui_types.Message_tool
    ~phase:Tui_types.Turn_tool ~text at
;;

let memory text at =
  row ~role:Tui_types.Message_memory ~phase:Tui_types.Turn_progress ~text at
;;

let unowned text at =
  row ~role:Tui_types.Message_status ~phase:Tui_types.Turn_progress ~text at
;;

let timeline rows =
  Tui_types.chat_timeline ~loaded:rows ~session:[] ~queued_request_ids:[]
;;

let items rows = (timeline rows).Tui_types.ctl_items

let turn_texts item =
  match item with
  | Tui_types.Chat_turn turn ->
      List.map (fun (r : Tui_types.msg_entry) -> r.me_text) turn.ct_rows
  | Tui_types.Chat_unowned r | Tui_types.Chat_memory r -> [ r.me_text ]
;;

let item_kinds rows =
  items rows
  |> List.map (function
       | Tui_types.Chat_turn turn -> "turn:" ^ turn.ct_request_id
       | Tui_types.Chat_unowned r -> "unowned:" ^ r.me_text
       | Tui_types.Chat_memory r -> "memory:" ^ r.me_text)
;;

let sole_turn rows =
  match items rows with
  | [ Tui_types.Chat_turn turn ] -> turn
  | other -> Alcotest.failf "expected one turn, got %d items" (List.length other)
;;

let test_a_turn_sits_where_its_first_row_did () =
  (* The second row of request a arrives after b has started; a stays first. *)
  let rows =
    [ user ~request_id:"a" "ask a" 1.0
    ; user ~request_id:"b" "ask b" 2.0
    ; keeper ~request_id:"a" "answer a" 3.0
    ]
  in
  Alcotest.(check (list string))
    "order of first appearance"
    [ "turn:a"; "turn:b" ]
    (item_kinds rows);
  Alcotest.(check (list string))
    "and the late row joined its own turn"
    [ "ask a"; "answer a" ]
    (turn_texts (List.hd (items rows)))
;;

let test_rows_read_input_progress_tools_output () =
  let rows =
    [ keeper ~request_id:"a" ~operation_seq:4 "answer" 4.0
    ; tool ~request_id:"a" ~operation_seq:3 "tool call" 3.0
    ; user ~request_id:"a" ~operation_seq:1 "ask" 1.0
    ]
  in
  Alcotest.(check (list string))
    "phases order the turn, whatever order the rows arrived in"
    [ "ask"; "tool call"; "answer" ]
    (List.map (fun (r : Tui_types.msg_entry) -> r.me_text) (sole_turn rows).ct_rows)
;;

let test_rows_of_one_phase_keep_their_sequence () =
  let rows =
    [ user ~request_id:"a" "ask" 1.0
    ; tool ~request_id:"a" ~operation_seq:9 "second call" 2.0
    ; tool ~request_id:"a" ~operation_seq:2 "first call" 3.0
    ]
  in
  Alcotest.(check (list string))
    "within a phase the operation sequence decides"
    [ "ask"; "first call"; "second call" ]
    (List.map (fun (r : Tui_types.msg_entry) -> r.me_text) (sole_turn rows).ct_rows)
;;

let test_the_same_user_line_appears_once () =
  let rows =
    [ user ~request_id:"a" "ask" 1.0
    ; user ~request_id:"a" "ask" 2.0
    ; keeper ~request_id:"a" "answer" 3.0
    ]
  in
  Alcotest.(check (list string))
    "the session copy and the persisted copy are one line"
    [ "ask"; "answer" ]
    (List.map (fun (r : Tui_types.msg_entry) -> r.me_text) (sole_turn rows).ct_rows)
;;

let test_two_tool_rows_with_one_text_are_two_calls () =
  let rows =
    [ user ~request_id:"a" "ask" 1.0
    ; tool ~request_id:"a" ~operation_seq:1 "read file" 2.0
    ; tool ~request_id:"a" ~operation_seq:2 "read file" 3.0
    ]
  in
  Alcotest.(check int)
    "only user rows fold"
    3
    (List.length (sole_turn rows).ct_rows)
;;

let test_a_turn_stops_claiming_a_number_when_its_rows_disagree () =
  let agreed =
    [ user ~request_id:"a" ~turn_sequence:7 "ask" 1.0
    ; keeper ~request_id:"a" "answer" 2.0
    ]
  in
  Alcotest.(check (option int))
    "a row that knows nothing does not erase the number"
    (Some 7)
    (sole_turn agreed).ct_turn_sequence;
  let disagreed =
    [ user ~request_id:"a" ~turn_sequence:7 "ask" 1.0
    ; keeper ~request_id:"a" ~turn_sequence:8 "answer" 2.0
    ]
  in
  Alcotest.(check (option int))
    "two numbers are no number"
    None
    (sole_turn disagreed).ct_turn_sequence
;;

let test_a_folded_row_still_carries_its_number () =
  let rows =
    [ user ~request_id:"a" "ask" 1.0
    ; user ~request_id:"a" ~turn_sequence:4 "ask" 2.0
    ]
  in
  let turn = sole_turn rows in
  Alcotest.(check int) "one line" 1 (List.length turn.ct_rows);
  Alcotest.(check (option int))
    "and the number the duplicate knew"
    (Some 4)
    turn.ct_turn_sequence
;;

let test_journal_and_unowned_lines_keep_their_places () =
  let rows =
    [ user ~request_id:"a" "ask" 1.0
    ; memory "journal" 2.0
    ; unowned "system said" 3.0
    ; keeper ~request_id:"a" "answer" 4.0
    ; memory "journal" 5.0
    ]
  in
  Alcotest.(check (list string))
    "each journal line is its own slot, and none joins a turn"
    [ "turn:a"; "memory:journal"; "unowned:system said"; "memory:journal" ]
    (item_kinds rows)
;;

let test_queued_requests_are_not_in_the_transcript () =
  let session = [ user ~request_id:"waiting" "queued line" 9.0 ] in
  let timeline =
    Tui_types.chat_timeline
      ~loaded:[ user ~request_id:"a" "ask" 1.0 ]
      ~session ~queued_request_ids:[ "waiting" ]
  in
  Alcotest.(check int)
    "a line still waiting is not a row"
    1
    (List.length timeline.Tui_types.ctl_items)
;;

let () =
  Alcotest.run
    "tui chat timeline assembly"
    [ ( "assembly",
        [ Alcotest.test_case "a turn sits where its first row did" `Quick
            test_a_turn_sits_where_its_first_row_did;
          Alcotest.test_case "rows read input, progress, tools, output" `Quick
            test_rows_read_input_progress_tools_output;
          Alcotest.test_case "rows of one phase keep their sequence" `Quick
            test_rows_of_one_phase_keep_their_sequence;
          Alcotest.test_case "the same user line appears once" `Quick
            test_the_same_user_line_appears_once;
          Alcotest.test_case "two tool rows with one text are two calls" `Quick
            test_two_tool_rows_with_one_text_are_two_calls;
          Alcotest.test_case "a turn stops claiming a number when its rows disagree"
            `Quick test_a_turn_stops_claiming_a_number_when_its_rows_disagree;
          Alcotest.test_case "a folded row still carries its number" `Quick
            test_a_folded_row_still_carries_its_number;
          Alcotest.test_case "journal and unowned lines keep their places" `Quick
            test_journal_and_unowned_lines_keep_their_places;
          Alcotest.test_case "queued requests are not in the transcript" `Quick
            test_queued_requests_are_not_in_the_transcript
        ] )
    ]
;;
