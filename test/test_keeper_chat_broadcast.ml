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
      ~thread_id:"keeper:fixture-keeper"
      ~delta:(Some "live")
      Ag_ui.Text_message_content
  in
  let fields =
    B.operation_event_to_json
      ~keeper_name:"fixture-keeper"
      ~operation_id:"kmsg-operation-1"
      ~seq:None
      ~event
    |> fields_without_ts_unix
  in
  Alcotest.(check (option yojson_testable))
    "operation id"
    (Some (`String "kmsg-operation-1"))
    (List.assoc_opt "operation_id" fields);
  Alcotest.(check (list string))
    "closed envelope keys"
    [ "ag_ui_event"; "name"; "operation_id"; "type" ]
    (fields |> List.map fst |> List.sort String.compare)
;;

let project state event =
  P.project ~timestamp:12.0 ~redact_text:Fun.id state event

let projected_exn = function
  | _, Some event -> event
  | _, None -> Alcotest.fail "expected projected AG-UI event"

let test_projection_preserves_stream_identity () =
  let state, started =
    project P.initial
      (E.Run_started
         { run_id = "run-1"; thread_id = "keeper-consumer:fixture-keeper" })
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
         { run_id = "run-2"; thread_id = "keeper-consumer:fixture-keeper" })
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
         { occurrence =
             { E.stream_scope = 3
             ; provider_message_id = Some "provider-message-3"
             ; block_index = 7
             }
         ; tool_call_id = Some "tc-1"
         ; delta = "{\"path\":"
         })
  in
  let tool_args = Ag_ui.event_to_json (projected_exn (state, tool_args)) in
  Alcotest.(check (option string)) "tool args event"
    (Some "TOOL_CALL_ARGS")
    (Yojson.Safe.Util.member "type" tool_args |> Yojson.Safe.Util.to_string_option);
  Alcotest.(check (option int)) "tool stream scope"
    (Some 3)
    (Yojson.Safe.Util.member "toolStreamScope" tool_args
     |> Yojson.Safe.Util.to_int_option);
  Alcotest.(check (option int)) "tool block index"
    (Some 7)
    (Yojson.Safe.Util.member "toolCallBlockIndex" tool_args
     |> Yojson.Safe.Util.to_int_option)

let test_tool_result_ready_projection_has_exact_identity () =
  let state, _ =
    project P.initial
      (E.Run_started
         { run_id = "run-3"; thread_id = "keeper-consumer:fixture-keeper" })
  in
  let _, ready =
    project state
      (E.Tool_result_ready
         { occurrence =
             { E.stream_scope = 3
             ; provider_message_id = Some "provider-message-3"
             ; block_index = 7
             }
         ; tool_call_id = Some "tool-use-7"
         ; execution_id = Ids.Execution_id.of_string "exec-7"
         })
  in
  let ready = Ag_ui.event_to_json (projected_exn (state, ready)) in
  Alcotest.(check (option string)) "result-ready custom event"
    (Some "KEEPER_TOOL_RESULT_READY")
    (Yojson.Safe.Util.member "name" ready |> Yojson.Safe.Util.to_string_option);
  Alcotest.(check (option string)) "exact tool identity"
    (Some "tool-use-7")
    (Yojson.Safe.Util.member "value" ready
     |> Yojson.Safe.Util.member "toolCallId"
     |> Yojson.Safe.Util.to_string_option);
  Alcotest.(check (option string)) "canonical execution identity"
    (Some "exec-7")
    (Yojson.Safe.Util.member "value" ready
     |> Yojson.Safe.Util.member "executionId"
     |> Yojson.Safe.Util.to_string_option);
  Alcotest.(check (option int)) "result occurrence scope"
    (Some 3)
    (Yojson.Safe.Util.member "value" ready
     |> Yojson.Safe.Util.member "toolStreamScope"
     |> Yojson.Safe.Util.to_int_option)

let test_operation_event_carries_seq_when_given () =
  let event =
    Ag_ui.make_event
      ~timestamp:13.0
      ~thread_id:"keeper:fixture-keeper"
      ~delta:(Some "live")
      Ag_ui.Text_message_content
  in
  let fields =
    B.operation_event_to_json
      ~keeper_name:"fixture-keeper"
      ~operation_id:"kmsg-operation-1"
      ~seq:(Some 7)
      ~event
    |> fields_without_ts_unix
  in
  Alcotest.(check (option yojson_testable))
    "journal seq rides the broadcast payload"
    (Some (`Int 7))
    (List.assoc_opt "seq" fields)
;;

let test_projection_redacts_content_without_rewriting_protocol () =
  let path = Filename.temp_file "keeper-projection-secrets" ".txt" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    let output = open_out_bin path in
    Fun.protect ~finally:(fun () -> close_out output) (fun () ->
      output_string output "heartbeat_reported\nelapsed_seconds\ncall-secret\nprivate-note\n");
    let redaction = Masc.Keeper_secret_redaction.snapshot_with_additional_secret_files
      ~redact_identity_scalars:false ~additional_secret_files:[path]
      ~base_path:(Filename.dirname path) ~keeper_name:"projection-fixture" in
    let redact_text = Masc.Keeper_secret_redaction.redact_text redaction in
    let tool : E.native_tool =
      { occurrence = {stream_scope=2; block_index=3; provider_message_id=Some "call-secret"}
      ; tool_call_id=Some "call-secret"; tool_call_name=Some "Read" } in
    let value event =
      let projected = P.project ~timestamp:12.0 ~redact_text P.initial event |> projected_exn in
      Ag_ui.event_to_json projected |> Yojson.Safe.Util.member "value" in
    let heartbeat = value (E.Native_tool_progress
      (tool, Runtime_native_tools.Heartbeat_reported {elapsed_seconds=30})) in
    Alcotest.(check yojson_testable) "typed heartbeat remains decodable despite secret collisions"
      (`Assoc ["kind",`String "heartbeat_reported"; "elapsed_seconds",`Int 30])
      (Yojson.Safe.Util.member "progress" heartbeat);
    Alcotest.(check yojson_testable) "correlation identity remains stable"
      (`String "call-secret") (Yojson.Safe.Util.member "toolCallId" heartbeat);
    let message = value (E.Native_tool_progress
      (tool, Runtime_native_tools.Message_reported {message="private-note"})) in
    Alcotest.(check yojson_testable) "human progress remains redacted"
      (`String "[REDACTED]")
      (message |> Yojson.Safe.Util.member "progress" |> Yojson.Safe.Util.member "message");
    let thinking = value (E.Agent_core_thinking_delta {index=3; delta="private-note"}) in
    Alcotest.(check yojson_testable) "reasoning content remains redacted"
      (`String "[REDACTED]") (Yojson.Safe.Util.member "delta" thinking);
    let diagnostic = value (E.Agent_core_stream_protocol_error
      {kind=E.Sse_error; quarantined_occurrence=Some tool.occurrence; index=None;
       tool_call_id=tool.tool_call_id; event_type=Some "private-note"; reason=None; raw_bytes=None}) in
    Alcotest.(check yojson_testable) "provider diagnostic is content, not a closed enum"
      (`String "[REDACTED]") (Yojson.Safe.Util.member "event_type" diagnostic);
    Alcotest.(check yojson_testable) "closed error kind survives content redaction"
      (`String "sse_error") (Yojson.Safe.Util.member "kind" diagnostic))
;;

let () =
  Alcotest.run "keeper_chat_broadcast"
    [ ( "turn_event"
      , [ Alcotest.test_case "operation event uses singular identity" `Quick
            test_operation_event_has_singular_identity
        ; Alcotest.test_case "operation event carries seq when given" `Quick
            test_operation_event_carries_seq_when_given
        ; Alcotest.test_case "projection preserves stream identity" `Quick
            test_projection_preserves_stream_identity
        ; Alcotest.test_case "projection covers thinking and tool args" `Quick
            test_projection_covers_thinking_and_tool_args
        ; Alcotest.test_case "protocol identity survives exact secret collisions" `Quick
            test_projection_redacts_content_without_rewriting_protocol
        ; Alcotest.test_case "tool result readiness preserves exact identity" `Quick
            test_tool_result_ready_projection_has_exact_identity
        ] )
    ]
