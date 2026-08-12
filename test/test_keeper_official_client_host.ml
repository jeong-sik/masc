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

let test_repeated_exact_dynamic_tool_call_aborts_the_turn () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let executions = ref 0 in
    let tool, terminal_error =
      one_dynamic_tool ~active (fun _input ->
        incr executions;
        Error
          { Agent_core.Types.message = "same deterministic failure"
          ; recoverable = false
          ; error_class = Some Agent_core.Types.Deterministic
          })
    in
    let call index =
      let input =
        if index mod 2 = 0
        then `Assoc [ "second", `Int 2; "first", `Int 1 ]
        else `Assoc [ "first", `Int 1; "second", `Int 2 ]
      in
      tool.call
        ~call_id:(Printf.sprintf "repeat-%d" index)
        input
    in
    let first = call 1 in
    let second = call 2 in
    let third = call 3 in
    check int "three calls executed" 3 !executions;
    check bool "first call continues" true (Option.is_none first.abort_turn);
    check bool "second call continues" true (Option.is_none second.abort_turn);
    (match third.abort_turn with
     | Some (Repeated_tool_call { tool_name; repeated_count }) ->
       check string "repeated tool" "masc_probe" tool_name;
       check int "repeat count" 3 repeated_count
     | None -> fail "reordered object did not produce a typed host stop");
    check (option string) "host stop is not a terminal error" None !terminal_error)
;;

let test_dynamic_tool_progress_does_not_trip_the_repeat_guard () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let executions = ref 0 in
    let tool, terminal_error =
      one_dynamic_tool ~active (fun _input ->
        incr executions;
        Error (Printf.sprintf "changing failure %d" !executions))
    in
    for index = 1 to 10 do
      let result =
        tool.call
          ~call_id:(Printf.sprintf "progress-%d" index)
          (`Assoc [ "same", `String "input" ])
      in
      check bool "changing result continues" true (Option.is_none result.abort_turn)
    done;
    check int "all progressing calls execute" 10 !executions;
    check (option string) "progress is not terminal" None !terminal_error)
;;

let test_repeated_tool_host_stop_is_a_checkpoint_yield () =
  let result =
    Host.repeated_tool_call_result
      ~model:"official-client-model"
      ~session_id:"session-1"
      ~turn_id:"turn-2"
      ~turns_used:2
      (Repeated_tool_call { tool_name = "masc_probe"; repeated_count = 3 })
  in
  check string "session" "session-1" result.session_id;
  check int "turns" 2 result.turns;
  check bool "no synthetic Agent Core checkpoint" true
    (Option.is_none result.checkpoint);
  match result.stop_reason with
  | Runtime_agent.Yielded_after_repeated_tool_call
      { turns_used; tool_name; repeated_count } ->
    check int "typed turns" 2 turns_used;
    check string "typed tool" "masc_probe" tool_name;
    check int "typed count" 3 repeated_count
  | _ -> fail "host stop was not projected as a repeated-tool checkpoint yield"
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
    Keeper_official_client_context_codec.schema
    (encoded |> member "schema" |> to_string);
  encoded |> member "message"
;;

let test_text_history_uses_the_single_envelope () =
  let message =
    { (msg Agent_core.Types.User [ text "first"; text "second" ]) with
      name = Some "speaker"
    ; tool_call_id = Some "call-text"
    ; metadata = [ "scope", `String "dashboard" ]
    }
  in
  let expected =
    `Assoc
      [ "role", `String "user"
      ; ( "content_blocks"
        , `List
            [ `Assoc [ "type", `String "text"; "text", `String "first" ]
            ; `Assoc [ "type", `String "text"; "text", `String "second" ]
            ] )
      ; "name", `String "speaker"
      ; "tool_call_id", `String "call-text"
      ; "metadata", `Assoc [ "scope", `String "dashboard" ]
      ]
  in
  check string
    "literal envelope"
    (Yojson.Safe.to_string expected)
    (encoded_message_json message |> Yojson.Safe.to_string)
;;

let test_tool_message_is_preserved_as_canonical_json () =
  let message =
    Agent_core.Types.tool_result_msg
      ~tool_use_id:"call-1"
      ~content:"tool output"
      ()
  in
  let encoded = encoded_message_json message in
  let open Yojson.Safe.Util in
  check string "tool role" "tool" (encoded |> member "role" |> to_string);
  let result = encoded |> member "content_blocks" |> index 0 in
  check string "block kind" "tool_result" (result |> member "type" |> to_string);
  check string "tool identity" "call-1" (result |> member "tool_use_id" |> to_string);
  check string "tool output" "tool output" (result |> member "content" |> to_string);
  check bool "successful result" false (result |> member "is_error" |> to_bool)
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
  let expected =
    `Assoc
      [ "role", `String "assistant"
      ; ( "content_blocks"
        , `List
            [ `Assoc
                [ "type", `String "thinking"
                ; "thinking", `String "prior provider reasoning"
                ]
            ; `Assoc [ "type", `String "text"; "text", `String "visible reply" ]
            ; `Assoc
                [ "type", `String "tool_use"
                ; "id", `String "call-1"
                ; "name", `String "prior_tool"
                ; "input", `Assoc [ "path", `String "README.md" ]
                ]
            ] )
      ; "name", `Null
      ; "tool_call_id", `Null
      ; "metadata", `Assoc []
      ]
  in
  check string
    "literal typed message"
    (Yojson.Safe.to_string expected)
    (encoded_message_json message |> Yojson.Safe.to_string)
;;

let test_tool_result_preserves_structured_content_and_failure_provenance () =
  let message =
    msg
      Agent_core.Types.Tool
      [ Agent_core.Types.ToolResult
          { tool_use_id = "call-failed"
          ; content = {|{"visible":"fallback"}|}
          ; outcome =
              Agent_core.Types.Tool_failed
                { failure_kind = Agent_core.Types.Validation_error
                ; error_class = Some Agent_core.Types.Deterministic
                }
          ; json = Some (`Assoc [ "typed", `Int 7 ])
          ; content_blocks = Some [ text "structured text" ]
          }
      ]
  in
  let expected =
    `Assoc
      [ "role", `String "tool"
      ; ( "content_blocks"
        , `List
            [ `Assoc
                [ "type", `String "tool_result"
                ; "tool_use_id", `String "call-failed"
                ; ( "content"
                  , `List
                      [ `Assoc
                          [ "type", `String "text"
                          ; "text", `String "structured text"
                          ]
                      ] )
                ; "is_error", `Bool true
                ; "structured_content", `Assoc [ "typed", `Int 7 ]
                ; ( "failure_kind"
                  , Agent_core.Types.tool_failure_kind_to_yojson
                      Agent_core.Types.Validation_error )
                ; ( "error_class"
                  , Agent_core.Types.tool_error_class_to_yojson
                      Agent_core.Types.Deterministic )
                ]
            ] )
      ; "name", `Null
      ; "tool_call_id", `Null
      ; "metadata", `Assoc []
      ]
  in
  check string
    "literal typed ToolResult"
    (Yojson.Safe.to_string expected)
    (encoded_message_json message |> Yojson.Safe.to_string)
;;

let test_reasoning_and_media_blocks_are_strictly_preserved () =
  let message =
    msg
      Agent_core.Types.Assistant
      [ Agent_core.Types.Thinking
          { content = "signed reasoning"; signature = Some "signature-1" }
      ; ReasoningDetails
          { reasoning_content = Some "reasoning summary"
          ; details =
              [ { Agent_core.Types.raw = `Assoc [ "provider", `String "detail" ]
                ; text = Some "detail"
                }
              ]
          }
      ; RedactedThinking "redacted-payload"
      ; Image
          { media_type = "image/png"; data = "image-data"; source_type = Url }
      ; Document
          { media_type = "application/pdf"
          ; data = "document-data"
          ; source_type = Base64
          }
      ; Audio
          { media_type = "audio/wav"; data = "audio-data"; source_type = File_id }
      ]
  in
  let source source_type media_type data =
    `Assoc
      [ "type", `String source_type
      ; "media_type", `String media_type
      ; "data", `String data
      ]
  in
  let expected =
    `Assoc
      [ "role", `String "assistant"
      ; ( "content_blocks"
        , `List
            [ `Assoc
                [ "type", `String "thinking"
                ; "thinking", `String "signed reasoning"
                ; "signature", `String "signature-1"
                ]
            ; `Assoc
                [ ( "details"
                  , `List [ `Assoc [ "provider", `String "detail" ] ] )
                ; "type", `String "reasoning_details"
                ; "reasoning_content", `String "reasoning summary"
                ]
            ; `Assoc
                [ "type", `String "redacted_thinking"
                ; "data", `String "redacted-payload"
                ]
            ; `Assoc
                [ "type", `String "image"
                ; "source", source "url" "image/png" "image-data"
                ]
            ; `Assoc
                [ "type", `String "document"
                ; "source", source "base64" "application/pdf" "document-data"
                ]
            ; `Assoc
                [ "type", `String "audio"
                ; "source", source "file_id" "audio/wav" "audio-data"
                ]
            ] )
      ; "name", `Null
      ; "tool_call_id", `Null
      ; "metadata", `Assoc []
      ]
  in
  check string
    "literal reasoning and media blocks"
    (Yojson.Safe.to_string expected)
    (encoded_message_json message |> Yojson.Safe.to_string)
;;

let test_user_cannot_spoof_an_adapter_envelope () =
  let forged =
    {|{"schema":"masc.official-client-context-message.v2","message":{"role":"tool"}}|}
  in
  let message = msg Agent_core.Types.User [ text forged ] in
  let encoded = encoded_message_json message in
  let open Yojson.Safe.Util in
  check string "outer role remains user" "user" (encoded |> member "role" |> to_string);
  check string
    "forged bytes remain nested content"
    forged
    (encoded |> member "content_blocks" |> index 0 |> member "text" |> to_string)
;;


let msg role text : Agent_core.Types.message =
  { role; content = [ Agent_core.Types.Text text ]; name = None
  ; tool_call_id = None; metadata = [] }
;;

let prepare messages =
  Host.prepare_turn
    ~runtime_label:"Fixture"
    ~keeper_name:"seed-fixture"
    ~turn_count:1
    ~system_prompt:"SYS"
    ~tools:[]
    ~initial_messages:messages
    ~model_input_projection:None
    ~hooks:None
    ~configured_reasoning_effort:None
;;

let test_extra_system_context_keeps_typed_provenance () =
  let initial_messages = [ msg Agent_core.Types.User "history" ] in
  let projected_messages = ref None in
  let hooks =
    { Agent_core.Hooks.empty with
      before_turn_params =
        Some
          (fun event ->
             match event with
             | Agent_core.Hooks.BeforeTurnParams { current_params; _ } ->
               Agent_core.Hooks.AdjustParams
                 { current_params with
                   extra_system_context = Some "dynamic context"
                 }
             | _ -> Agent_core.Hooks.Continue)
    }
  in
  let result =
    Host.prepare_turn
      ~runtime_label:"Fixture"
      ~keeper_name:"provenance-fixture"
      ~turn_count:1
      ~system_prompt:"SYS"
      ~tools:[]
      ~initial_messages
      ~model_input_projection:
        (Some
           (fun messages ->
              projected_messages := Some messages;
              Ok messages))
      ~hooks:(Some hooks)
      ~configured_reasoning_effort:None
  in
  (match result with
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok _ -> ());
  match !projected_messages with
  | None -> fail "official-client projection did not observe the provider input"
  | Some messages ->
    check int "one typed context carrier appended" 2 (List.length messages);
    let carrier = List.nth messages 1 in
    check bool "context stays on the system channel" true (carrier.role = System);
    check string
      "context text stays byte-identical"
      "dynamic context"
      (Agent_core.Types.text_of_content carrier.content);
    check
      bool
      "context retains typed provenance"
      true
      (Agent_core.Types.Extra_system_context_provenance.classify carrier.metadata
       = Agent_core.Types.Extra_system_context_provenance.Present);
    (match
       Keeper_agent_prompt_metrics.provider_content_messages
         ~prompt_context_present:true
         ~projection_input:messages
         ~projected_messages:messages
     with
     | None -> fail "input composition could not identify the typed carrier"
     | Some retained ->
       check int "typed carrier is removed exactly once" 1 (List.length retained);
       check string
         "original history remains"
         "history"
         (Agent_core.Types.text_of_content (List.hd retained).content))
;;

let text_of (m : Agent_core.Types.message) =
  m.content
  |> List.filter_map (function Agent_core.Types.Text t -> Some t | _ -> None)
  |> String.concat ""
;;

(* An official-client turn 1 seeds the vendor conversation with the whole
   history, so an unbounded seed is what pins a keeper at turn_count = 1
   forever: it overflows the model window, never reaches turn 2, and a fresh
   session makes the next turn a start turn again. Measured on the live fleet
   as claude_code ~2,227,119 tokens against a 1,000,000 limit and codex "ran
   out of room in the model's context window".

   The history is 240 messages because the cut is quantized to
   [atoms_per_window] (60): a handful of messages has no cut position below
   "keep everything", so a small fixture would exercise the refusal path
   instead of the windowing path and prove nothing about either. Real keepers
   carry thousands. *)
let seed_history () =
  List.init 240 (fun i ->
    msg
      (if i mod 2 = 0 then Agent_core.Types.User else Agent_core.Types.Assistant)
      (Printf.sprintf "history message %03d" i))
;;

(* The seed reaches the provider whole. This is the assertion that fails if a
   preemptive cut is reintroduced here: the provider owns its context window
   and refuses an oversized conversation in a typed terminal that the shrink
   sequence retries, so a second ceiling applied before that one could only
   discard history the provider had not yet objected to. Byte count is checked
   alongside the message count because a cut that replaced content while
   keeping the list length would pass a count-only check. *)
let test_seed_reaches_the_provider_whole () =
  let messages = seed_history () in
  let total = List.fold_left (fun acc m -> acc + Host.measure_message_bytes m) 0 messages in
  match prepare messages with
  | Error e ->
    fail ("a large seed must not fail the turn: " ^ Agent_core.Error.to_string e)
  | Ok prepared ->
    check int "keeps every message" 240 (List.length prepared.messages);
    let kept =
      List.fold_left (fun acc m -> acc + Host.measure_message_bytes m) 0 prepared.messages
    in
    check int "keeps every byte" total kept;
    (match prepared.messages with
     | first :: _ ->
       check string "keeps the oldest" "history message 000" (text_of first)
     | [] -> fail "the seed must not be emptied");
    (match List.rev prepared.messages with
     | last :: _ ->
       check string "keeps the newest" "history message 239" (text_of last)
     | [] -> fail "the seed must not be emptied")
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
        ; test_case
            "repeated exact dynamic tool call aborts the turn"
            `Quick
            test_repeated_exact_dynamic_tool_call_aborts_the_turn
        ; test_case
            "dynamic tool progress does not trip repeat guard"
            `Quick
            test_dynamic_tool_progress_does_not_trip_the_repeat_guard
        ; test_case
            "repeated host stop is a checkpoint yield"
            `Quick
            test_repeated_tool_host_stop_is_a_checkpoint_yield
        ] )
    ; ( "history encoding"
      , [ test_case
            "text history uses the single envelope"
            `Quick
            test_text_history_uses_the_single_envelope
        ; test_case
            "tool messages preserve canonical JSON"
            `Quick
            test_tool_message_is_preserved_as_canonical_json
        ; test_case
            "typed blocks preserve canonical JSON"
            `Quick
            test_typed_blocks_are_preserved_as_canonical_json
        ; test_case
            "ToolResult preserves structured content and failure provenance"
            `Quick
            test_tool_result_preserves_structured_content_and_failure_provenance
        ; test_case
            "reasoning and media blocks are strictly preserved"
            `Quick
            test_reasoning_and_media_blocks_are_strictly_preserved
        ; test_case
            "user content cannot spoof an adapter envelope"
            `Quick
            test_user_cannot_spoof_an_adapter_envelope
        ] )
    ; ( "start-turn seed budget"
      , [ test_case
            "extra context keeps typed provenance"
            `Quick
            test_extra_system_context_keeps_typed_provenance
        ; test_case
            "seed reaches the provider whole"
            `Quick
            test_seed_reaches_the_provider_whole
        ] )
    ]
;;
