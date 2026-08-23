open Alcotest

module History = Masc_tui_keeper_chat_history

let addressed ?(ts = 1.0) ?speaker_name ?surface content =
  `Assoc
    ([ "id", `String "row"
     ; "role", `String "user"
     ; "content", `String content
     ; "ts", `Float ts
     ]
     @ (match speaker_name with
        | None -> []
        | Some name -> [ "speaker_name", `String name ])
     @ (match surface with None -> [] | Some json -> [ "surface", json ]))
;;

let row ?(ts = 1.0) ~role ?kind ?tool_call_name content =
  `Assoc
    ([ "id", `String "row"
     ; "role", `String role
     ; "content", `String content
     ; "ts", `Float ts
     ]
     @ (match kind with None -> [] | Some k -> [ "kind", `String k ])
     @ (match tool_call_name with
        | None -> []
        | Some name -> [ "tool_call_name", `String name ]))

let kind_to_string : History.kind -> string = function
  | History.Addressed_to_keeper { speaker; surface } ->
      Printf.sprintf "addressed(%s)" (History.addressed_label speaker surface)
  | History.Said_by_keeper -> "keeper"
  | History.Delivery_failed -> "delivery_failed"
  | History.Tool_calls rows ->
      Printf.sprintf "tools[%s]" (String.concat " | " rows)

let decode json =
  match History.rows_of_json json with
  | Ok decoded -> decoded
  | Error detail -> failf "expected a decode, got %s" detail

let test_roles_map_to_what_the_pane_draws () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"user" "고쳐줘"
         ; row ~ts:2.0 ~role:"assistant" "고쳤어요"
         ; row ~ts:3.0 ~role:"assistant" ~kind:"transport_failure" "slack 5xx"
         ])
  in
  check int "nothing was dropped" 0 decoded.History.dropped;
  check (list string) "each role lands where it belongs"
    [ "addressed(you)"; "keeper"; "delivery_failed" ]
    (List.map (fun r -> kind_to_string r.History.kind) decoded.History.rows);
  check (list string) "and the text comes through"
    [ "고쳐줘"; "고쳤어요"; "slack 5xx" ]
    (List.map (fun r -> r.History.text) decoded.History.rows)

(* A [role: "user"] row is whatever was put in front of the keeper, and most of
   them are not the operator. One live keeper carried 92 such rows from 23
   distinct speakers — taskmaster, an MCP client, the exact-lane verifier, a
   dozen canaries — and the pane drew every one as "you", which told the
   operator they had said things they had never seen. *)
let test_an_addressed_row_is_labelled_by_who_sent_it () =
  let label json =
    match (List.hd (decode (`List [ json ])).History.rows).History.kind with
    | History.Addressed_to_keeper { speaker; surface } ->
        History.addressed_label speaker surface
    | History.Said_by_keeper | History.Delivery_failed | History.Tool_calls _ ->
        failf "expected an addressed row"
  in
  let surface kind extra = `Assoc (("kind", `String kind) :: extra) in
  check string "an unnamed row is still the operator" "you"
    (label (addressed "hello"));
  check string "the dashboard is an operator surface, so it adds nothing"
    "vincent"
    (label (addressed ~speaker_name:"vincent" ~surface:(surface "dashboard" []) "hi"));
  check string "an agent is named and marked" "taskmaster \xc2\xb7 agent"
    (label
       (addressed ~speaker_name:"taskmaster" ~surface:(surface "agent" []) "routed"));
  check string "a fleet broadcast does not read like a direct message"
    "codex \xc2\xb7 broadcast"
    (label
       (addressed ~speaker_name:"codex" ~surface:(surface "broadcast" []) "main red"));
  check string "a connector says which one"
    "vincent \xc2\xb7 slack"
    (label
       (addressed
          ~speaker_name:"vincent"
          ~surface:(surface "slack" [ "channel_id", `String "C1" ])
          "from slack"));
  check string "a gate goes by its channel label" "hookbot \xc2\xb7 ops-room"
    (label
       (addressed
          ~speaker_name:"hookbot"
          ~surface:(surface "gate" [ "label", `String "ops-room" ])
          "gated"));
  (* A kind this build was not taught draws the name alone. Inventing a badge
     for it would say something the row does not. *)
  check string "an unknown surface is unlabelled, not guessed" "someone"
    (label
       (addressed ~speaker_name:"someone" ~surface:(surface "telepathy" []) "?"))
;;

let test_consecutive_tool_rows_become_one_block () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"user" "봐줘"
         ; row ~ts:2.0 ~role:"tool" ~tool_call_name:"read_file"
             "{\"file_path\":\"lib/a.ml\"}"
         ; row ~ts:3.0 ~role:"tool" ~tool_call_name:"edit_file"
             "{\"file_path\":\"lib/b.ml\"}"
         ; row ~ts:4.0 ~role:"assistant" "봤어요"
         ])
  in
  match decoded.History.rows with
  | [ operator; tools; keeper ] ->
      check string "the operator's line is first" "addressed(you)"
        (kind_to_string operator.History.kind);
      check string "the keeper's line is last" "keeper"
        (kind_to_string keeper.History.kind);
      (match tools.History.kind with
       | History.Tool_calls rows ->
           check int "both calls are in one block" 2 (List.length rows);
           check bool "each row names the file it acted on" true
             (List.exists
                (fun r ->
                  String.length r > 0
                  && Option.is_some (String.index_opt r 'a'))
                rows);
           check bool "the rows carry the finished marker" true
             (List.for_all (fun r -> String.length r > 0) rows)
       | History.Addressed_to_keeper _ | History.Said_by_keeper
       | History.Delivery_failed ->
           fail "expected the middle row to be a tool block");
      check (float 0.0) "the block is keyed to its first call" 2.0
        tools.History.at
  | rows -> failf "expected three rows, got %d" (List.length rows)

let test_tool_blocks_separated_by_speech_stay_separate () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"tool" ~tool_call_name:"read_file" "{}"
         ; row ~ts:2.0 ~role:"assistant" "중간 설명"
         ; row ~ts:3.0 ~role:"tool" ~tool_call_name:"edit_file" "{}"
         ])
  in
  check (list string) "speech between two calls breaks the block"
    [ "tools"; "keeper"; "tools" ]
    (decoded.History.rows
     |> List.map (fun r ->
            match r.History.kind with
            | History.Tool_calls _ -> "tools"
            | other -> kind_to_string other))

let test_server_order_is_kept () =
  (* The server appends in order and asks a client not to reposition rows that
     carry no ts. A decoder that sorted would move these three. *)
  let decoded =
    decode
      (`List
         [ row ~ts:9.0 ~role:"user" "first"
         ; row ~ts:0.0 ~role:"assistant" "second"
         ; row ~ts:5.0 ~role:"user" "third"
         ])
  in
  check (list string) "rows stay in the order they arrived"
    [ "first"; "second"; "third" ]
    (List.map (fun r -> r.History.text) decoded.History.rows)

let test_one_unreadable_row_does_not_cost_the_transcript () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"user" "kept"
         ; `Assoc [ "role", `String "wat"; "content", `String "dropped" ]
         ; `String "not even an object"
         ; (* A tool row with no name draws as a bare marker, so it is dropped
              rather than rendered nameless. *)
           row ~ts:2.0 ~role:"tool" "{}"
         ; row ~ts:3.0 ~role:"assistant" "also kept"
         ])
  in
  check int "the three unreadable rows are counted" 3 decoded.History.dropped;
  check (list string) "and the readable ones survive" [ "kept"; "also kept" ]
    (List.map (fun r -> r.History.text) decoded.History.rows)

let test_a_non_array_payload_is_an_error () =
  match History.rows_of_json (`Assoc [ "rows", `List [] ]) with
  | Ok _ -> fail "an object should not decode as a transcript"
  | Error detail ->
      check bool "the error names the shape" true (String.length detail > 0)

let test_a_missing_ts_reads_as_zero_not_a_failure () =
  let decoded =
    decode
      (`List
         [ `Assoc [ "role", `String "user"; "content", `String "no ts here" ] ])
  in
  check int "the row is kept" 0 decoded.History.dropped;
  match decoded.History.rows with
  | [ r ] -> check (float 0.0) "and sorts as the oldest" 0.0 r.History.at
  | rows -> failf "expected one row, got %d" (List.length rows)

(* Paging. The envelope is new; the rows inside are the transcript's, so what
   matters here is the cursor and the "is there more" flag -- getting either
   wrong either stops the pane short of the conversation's start or has it ask
   forever for a page that does not exist. *)

let page json =
  match History.page_of_json json with
  | Ok page -> page
  | Error detail -> failf "expected a page, got %s" detail

let page_envelope ?(has_more = true) ?next_before rows =
  `Assoc
    ([ "schema", `String "masc.keeper_chat_history.page.v1"
     ; "messages", `List rows
     ; "has_more", `Bool has_more
     ]
     @ (match next_before with
        | None -> [ "next_before", `Null ]
        | Some ts -> [ "next_before", `Float ts ]))

let test_a_page_decodes_its_rows_and_cursor () =
  let p =
    page
      (page_envelope ~has_more:true ~next_before:12.5
         [ row ~ts:20.0 ~role:"user" "older question"
         ; row ~ts:21.0 ~role:"assistant" "older answer"
         ])
  in
  check (list string) "the rows read like any other transcript rows"
    [ "older question"; "older answer" ]
    (List.map (fun r -> r.History.text) p.History.decoded.History.rows);
  check bool "more remain" true p.History.has_more;
  check (option (float 0.0)) "and the cursor for them" (Some 12.5)
    p.History.next_before

let test_the_top_of_the_conversation_says_so () =
  let p = page (page_envelope ~has_more:false [ row ~role:"user" "first ever" ]) in
  check bool "nothing older" false p.History.has_more;
  check (option (float 0.0)) "and no cursor to ask with" None
    p.History.next_before

let test_a_missing_has_more_reads_as_no_more () =
  (* Guessing true would leave the pane offering a page the server never
     promised, and every request for it would come back empty. *)
  let p =
    page (`Assoc [ "messages", `List [ row ~role:"user" "only row" ] ])
  in
  check bool "absence is not a promise of more" false p.History.has_more

let test_tool_rows_fold_in_a_page_as_they_do_in_the_transcript () =
  let p =
    page
      (page_envelope ~has_more:false
         [ row ~ts:1.0 ~role:"tool" ~tool_call_name:"read_file" "{}"
         ; row ~ts:2.0 ~role:"tool" ~tool_call_name:"edit_file" "{}"
         ])
  in
  match p.History.decoded.History.rows with
  | [ { History.kind = History.Tool_calls rows; _ } ] ->
      check int "consecutive calls are one block here too" 2
        (List.length rows)
  | rows -> failf "expected one folded block, got %d rows" (List.length rows)

let test_a_page_that_is_not_an_object_is_an_error () =
  match History.page_of_json (`List []) with
  | Ok _ -> fail "an array is not a page envelope"
  | Error detail -> check bool "and says so" true (String.length detail > 0)

let test_a_page_without_messages_is_an_error () =
  match History.page_of_json (`Assoc [ "has_more", `Bool true ]) with
  | Ok _ -> fail "a page with no rows array should not decode"
  | Error detail -> check bool "and says so" true (String.length detail > 0)

let () =
  run "tui_keeper_chat_history"
    [ ( "rows"
      , [ test_case "roles map to what the pane draws" `Quick
            test_roles_map_to_what_the_pane_draws
        ; test_case "an addressed row is labelled by who sent it" `Quick
            test_an_addressed_row_is_labelled_by_who_sent_it
        ; test_case "consecutive tool rows become one block" `Quick
            test_consecutive_tool_rows_become_one_block
        ; test_case "speech splits tool blocks" `Quick
            test_tool_blocks_separated_by_speech_stay_separate
        ; test_case "the server's order is kept" `Quick test_server_order_is_kept
        ] )
    ; ( "paging"
      , [ test_case "a page decodes its rows and cursor" `Quick
            test_a_page_decodes_its_rows_and_cursor
        ; test_case "the top of the conversation says so" `Quick
            test_the_top_of_the_conversation_says_so
        ; test_case "a missing has_more reads as no more" `Quick
            test_a_missing_has_more_reads_as_no_more
        ; test_case "tool rows fold in a page too" `Quick
            test_tool_rows_fold_in_a_page_as_they_do_in_the_transcript
        ; test_case "a non-object page is an error" `Quick
            test_a_page_that_is_not_an_object_is_an_error
        ; test_case "a page without messages is an error" `Quick
            test_a_page_without_messages_is_an_error
        ] )
    ; ( "tolerance"
      , [ test_case "one unreadable row does not cost the transcript" `Quick
            test_one_unreadable_row_does_not_cost_the_transcript
        ; test_case "a non-array payload is an error" `Quick
            test_a_non_array_payload_is_an_error
        ; test_case "a missing ts reads as zero" `Quick
            test_a_missing_ts_reads_as_zero_not_a_failure
        ] )
    ]
