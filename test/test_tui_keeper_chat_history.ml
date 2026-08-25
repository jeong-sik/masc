open Alcotest

module History = Masc_tui_keeper_chat_history
module Transcript = Masc_tui_keeper_chat_transcript

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

let row ?(ts = 1.0) ~role ?kind ?tool_call_id ?tool_call_name ?delivery_key
    ?transcript_slot ?turn_ref content =
  `Assoc
    ([ "id", `String "row"
     ; "role", `String role
     ; "content", `String content
     ; "ts", `Float ts
     ]
     @ (match kind with None -> [] | Some k -> [ "kind", `String k ])
     @ (match delivery_key with None -> [] | Some json -> [ "delivery_key", json ])
     @ (match transcript_slot with
        | None -> []
        | Some json -> [ "transcript_slot", json ])
     @ (match turn_ref with None -> [] | Some id -> [ "turn_ref", `String id ])
     @ (match tool_call_id with
        | None -> []
        | Some id -> [ "tool_call_id", `String id ])
     @ (match tool_call_name with
        | None -> []
        | Some name -> [ "tool_call_name", `String name ]))

let operation_key id =
  `Assoc [ "kind", `String "operation"; "operation_id", `String id ]

let transcript_slot kind = `Assoc [ "kind", `String kind ]

let tool_transcript_slot execution_id ordinal =
  `Assoc
    [ "kind", `String "tool_call"
    ; "execution_id", `String execution_id
    ; "ordinal", `Int ordinal
    ]

let origin_request_id = function
  | History.Delivery_failed { origin_request_id } -> origin_request_id
  | History.Addressed_to_keeper _ | History.Said_by_keeper
  | History.Autonomous_reply
  | History.Tool_calls _ | History.Reasoning _ | History.Memory_activity -> None

let full_tool_rows = History.tool_rows

let kind_to_string : History.kind -> string = function
  | History.Addressed_to_keeper { speaker; surface } ->
      Printf.sprintf "addressed(%s)" (History.addressed_label speaker surface)
  | History.Said_by_keeper -> "keeper"
  | History.Autonomous_reply -> "autonomous"
  | History.Delivery_failed _ -> "delivery_failed"
  | History.Tool_calls block ->
      Printf.sprintf "tools[%s]" (String.concat " | " (full_tool_rows block))
  | History.Reasoning lines ->
      Printf.sprintf "thinking[%s]" (String.concat " | " lines)
  | History.Memory_activity -> "memory"

(* An assistant row the way an autonomous turn persists it: the server's
   [autonomous_turn] marker, a blank [content], and a [t: "trace"] block of
   steps. [content] is [null] on the wire when the turn said nothing
   ([server_dashboard_http_keeper_api.ml], the autonomous row encoder), so
   the default here is the wire's shape, not an empty string. *)
let autonomous_turn ?(ts = 1.0) ?(content = `Null) ?(marked = true) ?omitted
    ?turn_ref steps =
  `Assoc
    ([ "id", `String "autonomous:trace-1#54"
     ; "role", `String "assistant"
     ; "content", content
     ; "ts", `Float ts
     ]
    @ (match turn_ref with None -> [] | Some id -> [ "turn_ref", `String id ])
    @ (if marked then
         [ "autonomous_turn", `Assoc [ "turn_id", `String "trace-1#54" ] ]
       else [])
    @ [ ( "blocks"
      , `List
          [ `Assoc
              ([ "t", `String "trace"; "trace", `List steps ]
               @ (match omitted with None -> [] | Some n -> [ "omitted", `Int n ]))
          ] )
      ])

let think_withheld =
  `Assoc [ "kind", `String "think"; "text", `String ""; "content_withheld", `Bool true ]

let reason text = `Assoc [ "kind", `String "reason"; "text", `String text ]

let tool ?call_id ?status ?dur name =
  `Assoc
    ([ "kind", `String "tool"; "name", `String name ]
     @ (match call_id with
        | None -> []
        | Some id -> [ "tool_call_id", `String id ])
     @ (match status with None -> [] | Some s -> [ "status", `String s ])
     @ (match dur with None -> [] | Some d -> [ "dur", `String d ]))

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

(* The pane writes its own row when a turn fails, because most error rows are
   notices the server has no row for. A failed turn is the one it does record,
   and it comes back under the operation the client dispatched -- which is what
   lets the pane drop its own copy instead of drawing the failure twice.

   Only an operation key names a turn this client dispatched. A row the server
   wrote under another producer's key reads as [None] rather than handing back
   an id that belongs to someone else. *)
let test_a_failed_turn_names_the_request_it_came_from () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"assistant" ~kind:"transport_failure"
             ~delivery_key:(operation_key "tui-28e58beb") "provider closed the connection"
         ; row ~ts:2.0 ~role:"assistant" ~kind:"transport_failure"
             ~delivery_key:
               (`Assoc
                  [ "kind", `String "fusion_run"; "request_id", `String "fusion-1" ])
             "provider closed the connection"
         ; row ~ts:3.0 ~role:"assistant" ~kind:"transport_failure"
             "provider closed the connection"
         ])
  in
  check int "nothing was dropped" 0 decoded.History.dropped;
  check (list (option string)) "an operation key is the request, anything else is not"
    [ Some "tui-28e58beb"; None; None ]
    (List.map (fun r -> origin_request_id r.History.kind) decoded.History.rows)
;;

let test_rows_retain_the_exact_turn_identity () =
  let key = operation_key "tui-turn-42" in
  let decoded =
    decode
      (`List
         [ row ~role:"user" ~delivery_key:key
             ~transcript_slot:(transcript_slot "accepted_user") "check it"
         ; row ~role:"tool" ~delivery_key:key
             ~transcript_slot:(tool_transcript_slot "exec-1" 0)
             ~tool_call_name:"Read" "{}"
         ; row ~role:"assistant" ~delivery_key:key
             ~transcript_slot:(transcript_slot "terminal_assistant") "done"
         ])
  in
  check (list (option string)) "every row keeps the producer's operation id"
    [ Some "tui-turn-42"; Some "tui-turn-42"; Some "tui-turn-42" ]
    (List.map (fun row -> row.History.turn_id) decoded.History.rows)
;;

let test_consecutive_tools_from_different_turns_do_not_merge () =
  let tool turn execution =
    row ~role:"tool" ~delivery_key:(operation_key turn)
      ~transcript_slot:(tool_transcript_slot execution 0)
      ~tool_call_name:"Read" "{}"
  in
  let decoded =
    decode (`List [ tool "turn-one" "exec-1"; tool "turn-two" "exec-2" ])
  in
  check int "two turn identities produce two blocks" 2
    (List.length decoded.History.rows);
  check (list (option string)) "each block keeps its own turn"
    [ Some "turn-one"; Some "turn-two" ]
    (List.map (fun row -> row.History.turn_id) decoded.History.rows)
;;

let test_autonomous_trace_rows_keep_the_turn_ref () =
  let decoded =
    decode
      (`List
         [ autonomous_turn ~turn_ref:"trace-1#54"
             [ reason "look"; tool "Read" ]
         ])
  in
  check (list (option string)) "reasoning, tools and reply share the turn_ref"
    [ Some "trace-1#54"; Some "trace-1#54" ]
    (List.map (fun row -> row.History.turn_id) decoded.History.rows)
;;

(* A [role: "user"] row is whatever was put in front of the keeper, and most of
   them are not the operator. One live keeper carried 92 such rows from 23
   distinct speakers — a keeper, an MCP client, the exact-lane verifier, a
   dozen canaries — and the pane drew every one as "you", which told the
   operator they had said things they had never seen. *)
let test_an_addressed_row_is_labelled_by_who_sent_it () =
  let label json =
    match (List.hd (decode (`List [ json ])).History.rows).History.kind with
    | History.Addressed_to_keeper { speaker; surface } ->
        History.addressed_label speaker surface
    | History.Said_by_keeper | History.Autonomous_reply
    | History.Delivery_failed _ | History.Tool_calls _
    | History.Reasoning _ | History.Memory_activity ->
        failf "expected an addressed row"
  in
  let surface kind extra = `Assoc (("kind", `String kind) :: extra) in
  check string "an unnamed row is still the operator" "you"
    (label (addressed "hello"));
  check string "the dashboard is an operator surface, so it adds nothing"
    "vincent"
    (label (addressed ~speaker_name:"vincent" ~surface:(surface "dashboard" []) "hi"));
  check string "an agent is named and marked" "bandleader \xc2\xb7 agent"
    (label
       (addressed ~speaker_name:"bandleader" ~surface:(surface "agent" []) "routed"));
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
       | History.Tool_calls block ->
           let rows = full_tool_rows block in
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
       | History.Autonomous_reply
       | History.Delivery_failed _ | History.Reasoning _
       | History.Memory_activity ->
           fail "expected the middle row to be a tool block");
      check (float 0.0) "the block is keyed to its first call" 2.0
        tools.History.at
  | rows -> failf "expected three rows, got %d" (List.length rows)

let test_history_keeps_producer_tool_call_identity () =
  let args_a = "{\"file_path\":\"lib/a.ml\"}" in
  let args_b = "{\"file_path\":\"lib/b.ml\"}" in
  let decoded =
    decode
      (`List
         [ row ~ts:2.0 ~role:"tool" ~tool_call_id:"c1"
             ~tool_call_name:"read_file" args_a
         ; row ~ts:3.0 ~role:"tool" ~tool_call_id:"c2"
             ~tool_call_name:"edit_file" args_b
         ])
  in
  match decoded.History.rows with
  | [ { History.kind = History.Tool_calls block; _ } ] ->
      let activities = block.activities in
      check (list (option string)) "producer identities stay in source order"
        [ Some "c1"; Some "c2" ]
        (List.map
           (fun (activity : Transcript.tool_activity) -> activity.call_id)
           activities);
      check (list string) "the same subject authority names both calls"
        [ "lib/a.ml"; "lib/b.ml" ]
        (List.map
           (fun (activity : Transcript.tool_activity) ->
             Option.value ~default:"" activity.subject)
           activities);
      check (list (option string)) "direct rows do not invent durations"
        [ None; None ]
        (List.map
           (fun (activity : Transcript.tool_activity) -> activity.duration)
           activities)
  | rows -> failf "expected one history tool block, got %d rows" (List.length rows)

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

(* On one live keeper 32 of 183 assistant rows had a blank [content] and a
   trace block behind it -- 1,333 tool steps and 917 withheld reasoning steps
   -- and every one drew as a timestamp over an empty line. *)
let test_an_autonomous_turn_draws_what_it_did () =
  let decoded =
    decode
      (`List
         [ autonomous_turn ~ts:5.0
             [ think_withheld
             ; tool ~call_id:"trace-1" ~status:"ok" ~dur:"32ms"
                 "masc_task_history"
             ; think_withheld
             ; tool ~call_id:"trace-2" ~status:"err" ~dur:"1200ms"
                 "tool_execute"
             ; tool ~call_id:"trace-3" ~status:"pending"
                 "keeper_task_claim"
             ; tool "read_file"
             ]
         ])
  in
  check int "nothing was dropped" 0 decoded.History.dropped;
  match decoded.History.rows with
  | [ thinking; tools ] ->
      check string "the withheld reasoning is counted, not drawn blank"
        "thinking[(2 reasoning steps, content withheld)]"
        (kind_to_string thinking.History.kind);
      (match tools.History.kind with
       | History.Tool_calls block ->
           let rows = full_tool_rows block in
           check int "every tool step is a row" 4 (List.length rows);
           let activities = block.activities in
           check (list (option string)) "trace identities stay typed"
             [ Some "trace-1"; Some "trace-2"; Some "trace-3"; None ]
             (List.map
                (fun (activity : Transcript.tool_activity) -> activity.call_id)
                activities);
           check (list (option string)) "trace durations are not inferred"
             [ Some "32ms"; Some "1200ms"; None; None ]
             (List.map
                (fun (activity : Transcript.tool_activity) -> activity.duration)
                activities);
           let starts_with prefix row =
             String.length row >= String.length prefix
             && String.equal (String.sub row 0 (String.length prefix)) prefix
           in
           let row n = List.nth rows n in
           check bool "a call that returned carries the finished glyph" true
             (starts_with "\xe2\x9c\x93 masc_task_history" (row 0));
           check bool "and its duration" true
             (starts_with "\xe2\x9c\x93 masc_task_history \xc2\xb7 32ms" (row 0));
           check bool "a call that returned an error carries its own glyph" true
             (starts_with "\xe2\x9c\x97 tool_execute" (row 1));
           check bool "a call the trace never saw finish carries the open glyph"
             true
             (starts_with "\xc2\xb7 keeper_task_claim" (row 2));
           check bool "a step with no status says it was not recorded" true
             (starts_with "? read_file" (row 3))
       | History.Addressed_to_keeper _ | History.Said_by_keeper
       | History.Autonomous_reply
       | History.Delivery_failed _ | History.Reasoning _
       | History.Memory_activity ->
           fail "expected the second row to be a tool block");
      check (float 0.0) "both rows are keyed to the turn" 5.0 tools.History.at
  | rows -> failf "expected two rows, got %d" (List.length rows)

let test_a_turn_that_also_spoke_keeps_the_order_it_ran_in () =
  let decoded =
    decode
      (`List
         [ autonomous_turn ~ts:6.0
             ~content:(`String "\xea\xb3\xa0\xec\xb3\xa4\xec\x96\xb4\xec\x9a\x94")
             [ reason "the test names the old label"
             ; tool ~status:"ok" "edit_file"
             ]
         ])
  in
  check (list string) "reasoning, then calls, then what it said"
    [ "thinking[the test names the old label]"; "tools"; "autonomous" ]
    (decoded.History.rows
     |> List.map (fun r ->
            match r.History.kind with
            | History.Tool_calls _ -> "tools"
            | other -> kind_to_string other));
  check string "the text is the keeper's own row"
    "\xea\xb3\xa0\xec\xb3\xa4\xec\x96\xb4\xec\x9a\x94"
    (List.nth decoded.History.rows 2).History.text

let test_steps_the_server_dropped_are_counted () =
  let decoded =
    decode (`List [ autonomous_turn ~omitted:3 [ tool ~status:"ok" "read_file" ] ])
  in
  match decoded.History.rows with
  | [ { History.kind = History.Tool_calls block; _ } ] ->
      let rows = full_tool_rows block in
      check string "the count closes the block"
        "(3 steps not carried by the transcript)"
        (List.nth rows (List.length rows - 1))
  | _ -> fail "expected one tool block"

(* A direct-conversation turn can carry a trace block too: the server joins
   the raw trace onto rows that have a turn ref. Its calls are already in the
   transcript as [role: "tool"] rows, so reading the block as well drew every
   call twice. The marker the server puts on autonomous rows is what tells
   the two apart. *)
let test_a_direct_turn_s_trace_is_not_drawn_twice () =
  let decoded =
    decode
      (`List
         [ row ~ts:1.0 ~role:"tool" ~tool_call_name:"read_file" "{}"
         ; autonomous_turn ~ts:2.0 ~marked:false ~content:(`String "done")
             [ think_withheld; tool ~status:"ok" "read_file" ]
         ])
  in
  check (list string) "one tool block from the tool rows, then the text"
    [ "tools"; "keeper" ]
    (decoded.History.rows
     |> List.map (fun r ->
            match r.History.kind with
            | History.Tool_calls _ -> "tools"
            | other -> kind_to_string other))

let test_a_null_content_is_the_wire_s_blank () =
  let decoded =
    decode (`List [ autonomous_turn ~ts:3.0 [ tool ~status:"ok" "read_file" ] ])
  in
  check (list string) "null content draws the trace and no text row"
    [ "tools" ]
    (decoded.History.rows
     |> List.map (fun r ->
            match r.History.kind with
            | History.Tool_calls _ -> "tools"
            | other -> kind_to_string other))

let test_a_blank_turn_with_no_trace_keeps_its_line () =
  (* The server holds an empty row for it; drawing nothing would hide that a
     turn happened. Unchanged from before trace blocks were read. *)
  let decoded = decode (`List [ row ~ts:7.0 ~role:"assistant" "" ]) in
  check (list string) "one keeper row, blank" [ "keeper" ]
    (List.map (fun r -> kind_to_string r.History.kind) decoded.History.rows)

let test_a_blank_autonomous_turn_has_an_explicit_origin () =
  let decoded = decode (`List [ autonomous_turn ~ts:8.0 [] ]) in
  check (list string) "one autonomous row" [ "autonomous" ]
    (List.map (fun r -> kind_to_string r.History.kind) decoded.History.rows)

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
  | [ { History.kind = History.Tool_calls block; _ } ] ->
      let rows = full_tool_rows block in
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

let contains text needle =
  let rec loop at =
    if at + String.length needle > String.length text
    then false
    else if String.sub text at (String.length needle) = needle
    then true
    else loop (at + 1)
  in
  loop 0
;;

let test_memory_commit_names_added_removed_and_drop_reason () =
  let payload =
    `Assoc
      [ ( "entries"
        , `List
            [ `Assoc
                [ "ok", `Bool true
                ; "outcome", `String "committed"
                ; "recorded_at", `Float 1_700_000_010.0
                ; "revision", `Int 7
                ; "source", `Assoc [ "kind", `String "librarian" ]
                ; ( "change"
                  , `Assoc
                      [ ( "added"
                        , `List
                            [ `Assoc
                                [ "category", `String "fact"
                                ; "claim", `String "the probe uses HTTP/2"
                                ]
                            ] )
                      ; ( "removed"
                        , `List
                            [ `Assoc
                                [ "category", `String "constraint"
                                ; "claim", `String "use the old endpoint"
                                ]
                            ] )
                      ; "retained", `Int 3
                      ] )
                ; ( "dropped"
                  , `List
                      [ `Assoc
                          [ "memory_id", `String "memory-old"
                          ; "reason", `String "superseded by live evidence"
                          ]
                      ] )
                ]
            ] )
      ]
  in
  match History.memory_rows_of_json payload with
  | Error detail -> failf "memory journal decode failed: %s" detail
  | Ok { History.rows = [ row ]; dropped = 0 } ->
      check (float 0.0) "journal timestamp retained" 1_700_000_010.0 row.at;
      check bool "typed as memory activity" true (row.kind = History.Memory_activity);
      List.iter
        (fun needle ->
           check bool needle true (contains row.text needle))
        [ "Librarian committed current memory revision 7"
        ; "DELTA: 1 added (now present)"
        ; "1 removed (now absent)"
        ; "3 retained from previous"
        ; "+ ADDED (now in current memory) [fact] the probe uses HTTP/2"
        ; "- REMOVED (no longer in current memory) [constraint] use the old endpoint"
        ; "drop memory-old \xe2\x80\x94 superseded by live evidence"
        ]
  | Ok decoded ->
      failf "expected one decoded memory row, got %d/%d"
        (List.length decoded.rows) decoded.dropped
;;

let test_memory_failure_keeps_kind_and_detail () =
  let payload =
    `Assoc
      [ ( "entries"
        , `List
            [ `Assoc
                [ "ok", `Bool true
                ; "outcome", `String "failed"
                ; "recorded_at", `Float 1_700_000_020.0
                ; "kind", `String "exact_execution_failure"
                ; "detail", `String "provider returned 503"
                ; "snapshot_present", `Bool true
                ; "cadence_deferred", `Bool false
                ]
            ] )
      ]
  in
  match History.memory_rows_of_json payload with
  | Ok { History.rows = [ row ]; dropped = 0 } ->
      check bool "failure kind survives" true
        (contains row.text "exact_execution_failure");
      check bool "failure detail survives" true
        (contains row.text "provider returned 503")
  | Ok decoded ->
      failf "expected one failed memory row, got %d/%d"
        (List.length decoded.rows) decoded.dropped
  | Error detail -> failf "memory failure decode failed: %s" detail
;;

let () =
  run "tui_keeper_chat_history"
    [ ( "rows"
      , [ test_case "roles map to what the pane draws" `Quick
            test_roles_map_to_what_the_pane_draws
        ; test_case "a failed turn names the request it came from" `Quick
            test_a_failed_turn_names_the_request_it_came_from
        ; test_case "rows retain the exact turn identity" `Quick
            test_rows_retain_the_exact_turn_identity
        ; test_case "different turns do not merge their tool blocks" `Quick
            test_consecutive_tools_from_different_turns_do_not_merge
        ; test_case "autonomous trace rows retain turn_ref" `Quick
            test_autonomous_trace_rows_keep_the_turn_ref
        ; test_case "an addressed row is labelled by who sent it" `Quick
            test_an_addressed_row_is_labelled_by_who_sent_it
        ; test_case "consecutive tool rows become one block" `Quick
            test_consecutive_tool_rows_become_one_block
        ; test_case "history keeps producer tool-call identity" `Quick
            test_history_keeps_producer_tool_call_identity
        ; test_case "speech splits tool blocks" `Quick
            test_tool_blocks_separated_by_speech_stay_separate
        ; test_case "the server's order is kept" `Quick test_server_order_is_kept
        ; test_case "an autonomous turn draws what it did" `Quick
            test_an_autonomous_turn_draws_what_it_did
        ; test_case "blank autonomous turn keeps its origin" `Quick
            test_a_blank_autonomous_turn_has_an_explicit_origin
        ; test_case "a turn that also spoke keeps the order it ran in" `Quick
            test_a_turn_that_also_spoke_keeps_the_order_it_ran_in
        ; test_case "steps the server dropped are counted" `Quick
            test_steps_the_server_dropped_are_counted
        ; test_case "a blank turn with no trace keeps its line" `Quick
            test_a_blank_turn_with_no_trace_keeps_its_line
        ; test_case "a direct turn's trace is not drawn twice" `Quick
            test_a_direct_turn_s_trace_is_not_drawn_twice
        ; test_case "a null content is the wire's blank" `Quick
            test_a_null_content_is_the_wire_s_blank
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
    ; ( "memory journal"
      , [ test_case "commit names added removed and drop reason" `Quick
            test_memory_commit_names_added_removed_and_drop_reason
        ; test_case "failure keeps kind and detail" `Quick
            test_memory_failure_keeps_kind_and_detail
        ] )
    ]
