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

let test_operation_event_has_singular_identity () =
  let event =
    Ag_ui.make_event
      ~timestamp:13.0
      ~thread_id:"keeper:taskmaster"
      ~delta:(Some "live")
      Ag_ui.Text_message_content
  in
  let fields =
    B.operation_event_to_json
      ~keeper_name:"taskmaster"
      ~operation_id:"kmsg-operation-1"
      ~event
    |> fields_without_ts_unix
  in
  Alcotest.(check (option yojson_testable))
    "operation id"
    (Some (`String "kmsg-operation-1"))
    (List.assoc_opt "operation_id" fields);
  Alcotest.(check (option yojson_testable))
    "receipt identity absent"
    None
    (List.assoc_opt "receipt_id" fields)
;;

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

let () =
  Alcotest.run "keeper_chat_broadcast"
    [ ( "turn_event"
      , [ Alcotest.test_case "operation event uses singular identity" `Quick
            test_operation_event_has_singular_identity
        ; Alcotest.test_case "projection preserves stream identity" `Quick
            test_projection_preserves_stream_identity
        ; Alcotest.test_case "projection covers thinking and tool args" `Quick
            test_projection_covers_thinking_and_tool_args
        ] )
    ]
