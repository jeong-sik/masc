open Alcotest
open Masc

module Effort = Llm_provider.Reasoning_effort
module Host = Keeper_official_client_host

let effort_string = Option.map Effort.to_string

let expect_effort label expected result =
  match result with
  | Ok actual -> check (option string) label (effort_string expected) (effort_string actual)
  | Error _ -> fail (label ^ ": unexpected configuration error")
;;

let test_absent_controls_are_omitted () =
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:None
  |> expect_effort "absent" None
;;

let test_explicit_efforts_are_preserved () =
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:(Some Effort.Medium)
  |> expect_effort "medium" (Some Effort.Medium);
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:(Some Effort.Low)
  |> expect_effort "low" (Some Effort.Low);
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:(Some Effort.None_)
  |> expect_effort "explicit none" (Some Effort.None_)
;;

let test_generic_toggle_is_rejected () =
  (match
     Host.resolve_reasoning_effort
       ~enable_thinking:(Some false)
       ~reasoning_effort:None
   with
   | Error _ -> ()
   | Ok _ -> fail "disabled generic toggle was admitted");
  match
    Host.resolve_reasoning_effort
      ~enable_thinking:(Some true)
      ~reasoning_effort:(Some Effort.Medium)
  with
  | Error _ -> ()
  | Ok _ -> fail "enabled generic toggle was admitted"
;;

let remove_trace_artifact path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> Unix.rmdir path
  | _ -> Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let break_trace_path path =
  Sys.remove path;
  Unix.mkdir path 0o700
;;

let with_active_raw_trace body =
  let path = Filename.temp_file "official-client-raw-authority-" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> remove_trace_artifact path)
    (fun () ->
       Eio_main.run (fun _env ->
         let sink =
           match Agent_core.Raw_trace.create ~path () with
           | Ok sink -> sink
           | Error error -> fail (Agent_core.Error.to_string error)
         in
         let active =
           match
             Agent_core.Raw_trace.start_run
               sink
               ~agent_name:"keeper-raw-authority"
               ~prompt:"test"
               ()
           with
           | Ok active -> active
           | Error error -> fail (Agent_core.Error.to_string error)
         in
         body ~path ~active))
;;

let one_dynamic_tool ~active handler =
  let tool =
    Agent_core.Tool.create
      ~name:"effect"
      ~description:"test effect"
      ~parameters:[]
      handler
  in
  let terminal_error = ref None in
  let projected =
    Host.dynamic_tools
      ~runtime_label:"test"
      ~keeper_name:"keeper-raw-authority"
      ~turn_count:1
      ~tools:[ tool ]
      ~hooks:Agent_core.Hooks.empty
      ~event_bus:None
      ~context_injector:None
      ~context:(Some (Agent_core.Context.create_sync ()))
      ~terminal_error
      ~raw_trace_run:(Some active)
  in
  match projected with
  | Ok [ tool ] -> tool, terminal_error
  | Ok _ -> fail "expected one projected dynamic tool"
  | Error error -> fail (Agent_core.Error.to_string error)
;;

let test_raw_start_failure_does_not_block_tool () =
  with_active_raw_trace (fun ~path ~active ->
    let executions = ref 0 in
    let tool, terminal_error =
      one_dynamic_tool ~active (fun _input ->
        incr executions;
        Ok { Agent_core.Types.content = "effect-complete"; _meta = None })
    in
    break_trace_path path;
    let result = tool.call ~call_id:"call-start-failure" (`Assoc []) in
    check int "effect executed once" 1 !executions;
    check bool "authoritative success preserved" true result.success;
    check string "authoritative content preserved" "effect-complete" result.content;
    check (option string) "trace failure is not terminal" None !terminal_error)
;;

let test_raw_observation_preserves_reserved_exceptions () =
  let raises_out_of_memory =
    try
      ignore
        (Host.observe_raw_trace
           ~keeper_name:"keeper-raw-authority"
           ~stage:Host.Run_start
           (fun () -> raise Out_of_memory));
      false
    with
    | Out_of_memory -> true
  in
  let raises_stack_overflow =
    try
      ignore
        (Host.observe_raw_trace
           ~keeper_name:"keeper-raw-authority"
           ~stage:Host.Run_start
           (fun () -> raise Stack_overflow));
      false
    with
    | Stack_overflow -> true
  in
  let raises_sys_break =
    try
      ignore
        (Host.observe_raw_trace
           ~keeper_name:"keeper-raw-authority"
           ~stage:Host.Run_start
           (fun () -> raise Sys.Break));
      false
    with
    | Sys.Break -> true
  in
  check bool "Out_of_memory propagates" true raises_out_of_memory;
  check bool "Stack_overflow propagates" true raises_stack_overflow;
  check bool "Sys.Break propagates" true raises_sys_break
;;

let test_raw_finish_failure_does_not_reverse_tool_success () =
  with_active_raw_trace (fun ~path ~active ->
    let executions = ref 0 in
    let tool, terminal_error =
      one_dynamic_tool ~active (fun _input ->
        incr executions;
        break_trace_path path;
        Ok { Agent_core.Types.content = "effect-committed"; _meta = None })
    in
    let result = tool.call ~call_id:"call-finish-failure" (`Assoc []) in
    check int "effect executed once" 1 !executions;
    check bool "committed effect remains successful" true result.success;
    check string "committed result preserved" "effect-committed" result.content;
    check (option string) "trace failure is not terminal" None !terminal_error)
;;

let test_cancellation_records_terminal_raw_observation () =
  with_active_raw_trace (fun ~path ~active ->
    let tool, terminal_error =
      one_dynamic_tool ~active (fun _input ->
        raise (Eio.Cancel.Cancelled (Failure "cancel dynamic tool")))
    in
    let cancelled =
      try
        ignore (tool.call ~call_id:"call-cancelled" (`Assoc []));
        false
      with
      | Eio.Cancel.Cancelled _ -> true
    in
    check bool "cancellation preserved" true cancelled;
    check (option string) "cancellation is not replaced" None !terminal_error;
    let records =
      match Agent_core.Raw_trace.read_all ~path () with
      | Ok records -> records
      | Error error -> fail (Agent_core.Error.to_string error)
    in
    let count kind =
      List.fold_left
        (fun total record ->
           if record.Agent_core.Raw_trace.record_type = kind then total + 1 else total)
        0
        records
    in
    check int "one tool start" 1 (count Agent_core.Raw_trace.Tool_execution_started);
    check int "one tool finish" 1 (count Agent_core.Raw_trace.Tool_execution_finished))
;;

let msg role content : Agent_core.Types.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }
;;

let text value = Agent_core.Types.Text value

let encoded_message_json message =
  let encoded = Host.encode_history_message message |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  check string
    "envelope schema"
    "masc.official-client-context-message.v1"
    (encoded |> member "schema" |> to_string);
  encoded |> member "message"
;;

let test_text_history_is_preserved_verbatim () =
  let message = msg Agent_core.Types.User [ text "first"; text "second" ] in
  check string "plain text" "first\nsecond" (Host.encode_history_message message)
;;

let test_tool_message_is_preserved_as_canonical_json () =
  let message =
    Agent_core.Types.tool_result_msg
      ~tool_use_id:"call-1"
      ~content:"tool output"
      ()
  in
  check string
    "canonical tool message"
    (Keeper_context_core.message_to_json message |> Yojson.Safe.to_string)
    (encoded_message_json message |> Yojson.Safe.to_string)
;;

let test_typed_blocks_are_preserved_as_canonical_json () =
  let message =
    msg
      Agent_core.Types.Assistant
      [ Agent_core.Types.Thinking
          { content = "prior provider reasoning"; signature = None }
      ; text "visible reply"
      ; Agent_core.Types.ToolUse
          { id = "call-1"
          ; name = "prior_tool"
          ; input = `Assoc [ "path", `String "README.md" ]
          }
      ]
  in
  check string
    "canonical typed message"
    (Keeper_context_core.message_to_json message |> Yojson.Safe.to_string)
    (encoded_message_json message |> Yojson.Safe.to_string)
;;

let () =
  run
    "keeper official-client host"
    [ ( "reasoning effort"
      , [ test_case
            "absent controls are omitted"
            `Quick
            test_absent_controls_are_omitted
        ; test_case
            "explicit efforts are preserved"
            `Quick
            test_explicit_efforts_are_preserved
        ; test_case
            "generic toggle is rejected"
            `Quick
            test_generic_toggle_is_rejected
        ; test_case
            "RAW start failure does not block tool"
            `Quick
            test_raw_start_failure_does_not_block_tool
        ; test_case
            "RAW observation preserves reserved exceptions"
            `Quick
            test_raw_observation_preserves_reserved_exceptions
        ; test_case
            "RAW finish failure preserves tool success"
            `Quick
            test_raw_finish_failure_does_not_reverse_tool_success
        ; test_case
            "cancellation records terminal RAW observation"
            `Quick
            test_cancellation_records_terminal_raw_observation
        ] )
    ; ( "history encoding"
      , [ test_case
            "text history is preserved verbatim"
            `Quick
            test_text_history_is_preserved_verbatim
        ; test_case
            "tool messages preserve canonical JSON"
            `Quick
            test_tool_message_is_preserved_as_canonical_json
        ; test_case
            "typed blocks preserve canonical JSON"
            `Quick
            test_typed_blocks_are_preserved_as_canonical_json
        ] )
    ]
;;
