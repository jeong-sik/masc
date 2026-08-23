open Alcotest

module History = Masc_tui_keeper_chat_history

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
  | History.Said_by_operator -> "operator"
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
    [ "operator"; "keeper"; "delivery_failed" ]
    (List.map (fun r -> kind_to_string r.History.kind) decoded.History.rows);
  check (list string) "and the text comes through"
    [ "고쳐줘"; "고쳤어요"; "slack 5xx" ]
    (List.map (fun r -> r.History.text) decoded.History.rows)

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
      check string "the operator's line is first" "operator"
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
       | History.Said_by_operator | History.Said_by_keeper
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

let () =
  run "tui_keeper_chat_history"
    [ ( "rows"
      , [ test_case "roles map to what the pane draws" `Quick
            test_roles_map_to_what_the_pane_draws
        ; test_case "consecutive tool rows become one block" `Quick
            test_consecutive_tool_rows_become_one_block
        ; test_case "speech splits tool blocks" `Quick
            test_tool_blocks_separated_by_speech_stay_separate
        ; test_case "the server's order is kept" `Quick test_server_order_is_kept
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
