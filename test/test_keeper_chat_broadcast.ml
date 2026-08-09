module B = Masc.Keeper_chat_broadcast
module E = Masc.Keeper_chat_events
module P = Server_keeper_chat_agui_projection

let yojson_testable =
  Alcotest.testable
    (fun fmt json -> Format.fprintf fmt "%s" (Yojson.Safe.to_string json))
    ( = )

let fields_without_ts_unix json =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt "ts_unix" fields with
       | Some (`Float _) -> ()
       | _ -> Alcotest.fail "ts_unix missing or not a float");
      List.remove_assoc "ts_unix" fields
  | _ -> Alcotest.fail "expected assoc payload"

let test_text_delta_payload () =
  let event =
    Ag_ui.make_event ~timestamp:10.0 ~thread_id:"keeper-consumer:taskmaster"
      ~run_id:(Some "run-1") ~message_id:(Some "message-1")
      ~delta:(Some "안녕하세요") Ag_ui.Text_message_content
  in
  let json =
    B.turn_event_to_json ~keeper_name:"taskmaster"
      ~receipt_id:"chatq_00000000-0000-4000-8000-000000000001" ~event
  in
  Alcotest.(check (list (pair string yojson_testable)))
    "queued turn event payload"
    [ ("type", `String "keeper_chat_turn_event")
    ; ("name", `String "taskmaster")
    ; ("receipt_id", `String "chatq_00000000-0000-4000-8000-000000000001")
    ; ( "ag_ui_event"
      , `Assoc
          [ ("type", `String "TEXT_MESSAGE_CONTENT")
          ; ("threadId", `String "keeper-consumer:taskmaster")
          ; ("timestamp", `Float 10.0)
          ; ("runId", `String "run-1")
          ; ("messageId", `String "message-1")
          ; ("delta", `String "안녕하세요")
          ] )
    ]
    (fields_without_ts_unix json)

let test_thinking_payload () =
  let event =
    Ag_ui.make_event ~timestamp:11.0 ~thread_id:"keeper-consumer:taskmaster"
      ~run_id:(Some "run-1") ~custom_name:(Some "KEEPER_THINKING_DELTA")
      ~custom_value:(Some (`Assoc [ "index", `Int 0; "delta", `String "검토 중" ]))
      Ag_ui.Custom
  in
  let json =
    B.turn_event_to_json ~keeper_name:"taskmaster"
      ~receipt_id:"chatq_00000000-0000-4000-8000-000000000002" ~event
  in
  match List.assoc_opt "ag_ui_event" (fields_without_ts_unix json) with
  | Some (`Assoc fields) ->
      Alcotest.(check (option string)) "custom name"
        (Some "KEEPER_THINKING_DELTA")
        (match List.assoc_opt "name" fields with
         | Some (`String value) -> Some value
         | _ -> None)
  | _ -> Alcotest.fail "missing AG-UI event"

let project state event =
  P.project ~timestamp:12.0 ~redact_text:Fun.id ~redact_json:Fun.id state event

let projected_exn = function
  | _, Some event -> event
  | _, None -> Alcotest.fail "expected projected AG-UI event"

let test_projection_preserves_stream_identity () =
  let state, started =
    project P.initial
      (E.Run_started
         { run_id = "run-1"; thread_id = "keeper-consumer:taskmaster" })
  in
  ignore (projected_exn (state, started));
  let state, message_started =
    project state
      (E.Text_message_start
         { message_id = "message-1"; role = E.Assistant })
  in
  ignore (projected_exn (state, message_started));
  let _, projected = project state (E.Text_delta "hello") in
  let json = Ag_ui.event_to_json (projected_exn (state, projected)) in
  Alcotest.(check (option string)) "run identity"
    (Some "run-1")
    (Yojson.Safe.Util.member "runId" json |> Yojson.Safe.Util.to_string_option);
  Alcotest.(check (option string)) "message identity"
    (Some "message-1")
    (Yojson.Safe.Util.member "messageId" json |> Yojson.Safe.Util.to_string_option);
  Alcotest.(check (option string)) "text delta"
    (Some "hello")
    (Yojson.Safe.Util.member "delta" json |> Yojson.Safe.Util.to_string_option)

let test_projection_covers_thinking_and_tool_args () =
  let state, _ =
    project P.initial
      (E.Run_started
         { run_id = "run-2"; thread_id = "keeper-consumer:taskmaster" })
  in
  let _, thinking =
    project state
      (E.Agent_core_thinking_delta { index = 0; delta = "inspect" })
  in
  let thinking = Ag_ui.event_to_json (projected_exn (state, thinking)) in
  Alcotest.(check (option string)) "thinking custom event"
    (Some "KEEPER_THINKING_DELTA")
    (Yojson.Safe.Util.member "name" thinking |> Yojson.Safe.Util.to_string_option);
  let _, tool_args =
    project state
      (E.Tool_call_args
         { tool_call_id = "tc-1"; delta = "{\"path\":" })
  in
  let tool_args = Ag_ui.event_to_json (projected_exn (state, tool_args)) in
  Alcotest.(check (option string)) "tool args event"
    (Some "TOOL_CALL_ARGS")
    (Yojson.Safe.Util.member "type" tool_args |> Yojson.Safe.Util.to_string_option)

let test_projection_encodes_typed_terminal_event () =
  let _, projected =
    project P.initial
      (E.Request_terminal
         { request_id = Some "kmsg-request-1"
         ; keeper_name = "taskmaster"
         ; status = E.Error
         ; message = Some "typed failure"
         })
  in
  let projected = Ag_ui.event_to_json (projected_exn (P.initial, projected)) in
  Alcotest.(check (option string)) "typed event name"
    (Some "KEEPER_REQUEST_TERMINAL")
    (Yojson.Safe.Util.member "name" projected |> Yojson.Safe.Util.to_string_option);
  let value = Yojson.Safe.Util.member "value" projected in
  Alcotest.(check (option string)) "typed terminal status"
    (Some "error")
    (Yojson.Safe.Util.member "status" value |> Yojson.Safe.Util.to_string_option);
  Alcotest.(check bool) "typed terminal success" false
    (Yojson.Safe.Util.member "ok" value |> Yojson.Safe.Util.to_bool)

let () =
  Alcotest.run "keeper_chat_broadcast"
    [ ( "turn_event"
      , [ Alcotest.test_case "text delta payload" `Quick
            test_text_delta_payload
        ; Alcotest.test_case "thinking payload" `Quick
            test_thinking_payload
        ; Alcotest.test_case "projection preserves stream identity" `Quick
            test_projection_preserves_stream_identity
        ; Alcotest.test_case "projection covers thinking and tool args" `Quick
            test_projection_covers_thinking_and_tool_args
        ; Alcotest.test_case "projection encodes typed terminal event" `Quick
            test_projection_encodes_typed_terminal_event
        ] )
    ]
