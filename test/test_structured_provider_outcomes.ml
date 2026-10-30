module Types = Agent_core.Types
module Structured = Agent_core.Structured
module Error = Agent_core.Error
module Vt = Masc.Keeper_vision_tool
module Keeper_tool_call_log = Masc.Keeper_tool_call_log
module Parse = Llm_provider.Backend_openai_parse
module Responses = Llm_provider.Backend_openai_responses
module Streaming = Llm_provider.Streaming
module Acc = Llm_provider.Complete_stream_acc

let answer = {|{"text":"visible answer"}|}
let private_refusal = "private refusal evidence"

let check_refusal (response : Types.api_response) =
  Alcotest.(check bool) "authoritative refusal" true
    (response.stop_reason = Types.Refusal);
  let visible = Types.visible_text_of_response response in
  Alcotest.(check bool) "refusal prose is not visible answer content" true
    (visible = "" || visible = answer);
  (match Structured.inspect_response_json response with
   | Structured.Refused Error.Policy_refusal -> ()
   | Structured.Ready _ | Awaiting_tool_results | Refused Content_filtered
   | Truncated _ | Interrupted _ | Invalid _ ->
     Alcotest.fail "provider refusal did not reach structured state");
  (match Vt.outcome_of_response ~runtime_id:"fixture.vision" ~requested_model:"fixture"
           response with
   | Vt.Vo_provider { failure_class = Tool_result.Policy_rejection; _ } -> ()
   | Vt.Vo_provider { failure_class = (Tool_result.Workflow_rejection | Runtime_failure
       | Dependency_unavailable | Operator_cancelled); _ }
   | Vt.Vo_ok _ | Vo_invalid_request _ | Vo_no_runtime _ | Vo_timeout
   | Vo_invalid_structured_response _ | Vo_official_failure _ | Vo_empty | Vo_truncated ->
     Alcotest.fail "provider refusal did not reach vision policy rejection");
  match Structured.extract_response_json response with
  | Error error ->
    Alcotest.(check string) "safe public projection"
      "Structured output response state: provider_refusal"
      (Error.to_string error)
  | Ok _ -> Alcotest.fail "refusal accepted as final structured result"

let chat_json ?(content = `Null) ?(refusal = `String private_refusal)
      ?(finish = "stop") ?(tools = `Null) () =
  `Assoc
    [ "id", `String "chat-fixture"
    ; "model", `String "fixture"
    ; "choices", `List
        [ `Assoc
            [ "finish_reason", `String finish
            ; "message", `Assoc
                [ "role", `String "assistant"
                ; "content", content; "refusal", refusal; "tool_calls", tools ]
            ]
        ]
    ]

let parse_chat json =
  match Parse.parse_openai_response_result_json json with
  | Ok response -> response
  | Error error -> Alcotest.fail (Parse.parse_error_to_string error)

let response_json ?(status = "completed") ?(parts = []) ?(extra_output = []) () =
  `Assoc
    [ "id", `String "response-fixture"
    ; "model", `String "fixture"
    ; "status", `String status
    ; "output", `List
        (extra_output @ [`Assoc [ "type", `String "message"; "id", `String "message-fixture"
                ; "role", `String "assistant"; "status", `String "completed"
                ; "content", `List parts ]])
    ]

let refusal_part = `Assoc [ "type", `String "refusal"; "refusal", `String private_refusal ]
let text_part = `Assoc [ "type", `String "output_text"; "text", `String answer ]

let parse_responses json =
  match Responses.parse_response_result (Yojson.Safe.to_string json) with
  | Ok response -> response
  | Error detail -> Alcotest.fail detail

let responses_stream frames =
  let state = Streaming.create_openai_stream_state () in
  let acc = Acc.create_stream_acc () in
  List.iter
    (fun (kind, json) ->
       let events, _ =
         Streaming.responses_sse_to_events state (Some kind) (Yojson.Safe.to_string json)
       in
       List.iter (Acc.accumulate_event acc) events)
    frames;
  match Acc.finalize_stream_acc acc with
  | Ok response -> response
  | Error _ -> Alcotest.fail "Responses stream failed to preserve terminal outcome"

let completed json = "response.completed", `Assoc [ "response", json ]
let refusal_event kind =
  let field = match kind with
    | "response.refusal.done" -> "refusal"
    | _ -> "delta"
  in
  kind, `Assoc [ "type", `String kind; field, `String private_refusal
              ; "item_id", `String "message-fixture"; "output_index", `Int 0
              ; "content_index", `Int 0; "sequence_number", `Int 1 ]
let text_event = "response.output_text.delta", `Assoc [ "delta", `String answer ]

let chat_stream deltas =
  let state = Streaming.create_openai_stream_state () in
  let acc = Acc.create_stream_acc () in
  List.iter
    (fun (delta, finish) ->
       let json = `Assoc
           [ "id", `String "chat-fixture"; "model", `String "fixture"
           ; "choices", `List
               [ `Assoc [ "index", `Int 0; "delta", `Assoc delta
                         ; "finish_reason", finish ] ] ] in
       let result = Streaming.parse_openai_sse_chunk
           ~streaming_reasoning:Llm_provider.Reasoning_dialect.No_streaming_reasoning
           (Yojson.Safe.to_string json) in
       let events, _ = Streaming.openai_sse_parse_result_to_events state result in
       List.iter (Acc.accumulate_event acc) events)
    deltas;
  let events, _ = Streaming.openai_sse_parse_result_to_events state Streaming.Openai_done in
  List.iter (Acc.accumulate_event acc) events;
  match Acc.finalize_stream_acc acc with
  | Ok response -> response
  | Error _ -> Alcotest.fail "Chat stream failed to preserve terminal outcome"

let test_chat_refusal_empty () = check_refusal (parse_chat (chat_json ()))
let test_chat_refusal_over_valid_json () =
  check_refusal (parse_chat (chat_json ~content:(`String answer) ()))
let test_chat_refusal_over_tool_calls () =
  let tools = `List [`Assoc
      [ "id", `String "call-fixture"; "type", `String "function"
      ; "function", `Assoc ["name", `String "observe"; "arguments", `String "{}"] ]] in
  check_refusal (parse_chat (chat_json ~finish:"tool_calls" ~tools ()))
let test_responses_refusal_empty () =
  check_refusal (parse_responses (response_json ~parts:[refusal_part] ()))
let test_responses_refusal_over_valid_json () =
  check_refusal (parse_responses (response_json ~parts:[text_part;refusal_part] ()))
let test_responses_stream_refusal_delta () =
  check_refusal (responses_stream
    [refusal_event "response.refusal.delta"; completed (response_json ())])
let test_responses_stream_refusal_done () =
  check_refusal (responses_stream
    [refusal_event "response.refusal.done"; completed (response_json ())])
let test_responses_stream_refusal_over_valid_json () =
  check_refusal (responses_stream
    [text_event;refusal_event "response.refusal.delta"; completed (response_json ~parts:[text_part] ())])
let test_responses_stream_terminal_refusal () =
  check_refusal (responses_stream [completed (response_json ~parts:[refusal_part] ())])
let test_refusal_delta_does_not_invent_terminal () =
  let state = Streaming.create_openai_stream_state () in
  let acc = Acc.create_stream_acc () in
  let kind, json = refusal_event "response.refusal.delta" in
  let events, _ = Streaming.responses_sse_to_events state (Some kind) (Yojson.Safe.to_string json) in
  List.iter (Acc.accumulate_event acc) events;
  Alcotest.(check bool) "missing terminal remains incomplete" true
    (Result.is_error (Acc.finalize_stream_acc acc))
let test_chat_stream_refusal_empty () =
  check_refusal (chat_stream
    [["refusal", `String private_refusal], `Null; [], `String "stop"])
let test_chat_stream_refusal_over_valid_json () =
  check_refusal (chat_stream
    [["content", `String answer], `Null;
     ["refusal", `String private_refusal], `Null; [], `String "stop"])
let test_normal_empty_stays_empty_failure () =
  match Parse.parse_openai_response_result_json (chat_json ~refusal:`Null ()) with
  | Error (Parse.Empty_completion _) -> ()
  | Ok _ | Error (Parse.Provider_error _ | Unreadable_response _) ->
    Alcotest.fail "ordinary empty completion must remain fail closed"
let test_normal_json_stays_ready () =
  let response = parse_chat (chat_json ~refusal:`Null ~content:(`String answer) ()) in
  match Structured.inspect_response_json response with
  | Structured.Ready json -> Alcotest.(check string) "answer" answer (Yojson.Safe.to_string json)
  | Structured.Awaiting_tool_results | Refused _ | Truncated _ | Interrupted _ | Invalid _ ->
    Alcotest.fail "ordinary final JSON changed"

let check_token_limit response =
  (match Structured.inspect_response_json response with
   | Structured.Truncated Error.Token_limit -> ()
   | Structured.Ready _ | Awaiting_tool_results | Refused _
   | Truncated (Error.Repetition_limit | Context_limit) | Interrupted _ | Invalid _ ->
     Alcotest.fail "token cut lost its structured state");
  match Vt.outcome_of_response ~runtime_id:"fixture.vision" ~requested_model:"fixture" response with
  | Vt.Vo_truncated -> ()
  | Vt.Vo_ok _ | Vo_invalid_request _ | Vo_no_runtime _ | Vo_timeout
  | Vo_invalid_structured_response _ | Vo_official_failure _ | Vo_empty | Vo_provider _ ->
    Alcotest.fail "token cut lost its vision outcome"

let test_chat_empty_token_cut () =
  check_token_limit (parse_chat (chat_json ~refusal:`Null ~finish:"length" ()))

let through_complete ~stream response =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let transport : Llm_provider.Llm_transport.t =
    Llm_provider.Llm_transport.custom ({ complete_sync = (fun _ -> { response = Ok response; latency_ms = None })
    ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _ -> Ok response) })
  in
  let config = Llm_provider.Provider_config.make
      ~kind:OpenAI_compat ~model_id:"fixture"
      ~base_url:"http://127.0.0.1:1" () in
  let result =
    if stream then
      (Llm_provider.Complete.complete_stream ~sw ~net:env#net ~transport ~config
        ~messages:[ Llm_provider.Types.user_msg "controlled terminal response" ]
        ~on_event:(fun _ -> ()) ()).Llm_provider.Completion_outcome.result
    else
      (Llm_provider.Complete.complete ~sw ~net:env#net ~transport ~config
        ~messages:[ Llm_provider.Types.user_msg "controlled terminal response" ] ()).Llm_provider.Completion_outcome.result
  in
  match result with
  | Ok response -> response
  | Error _ -> Alcotest.fail "public completion erased authoritative terminal state"

let check_policy_or_truncation expected response =
  match expected with
  | Types.Refusal -> check_refusal response
  | MaxTokens -> check_token_limit response
  | ContentFilter | RepetitionTruncation ->
    let expected_structured =
      match expected with
      | Types.ContentFilter -> Structured.Refused Error.Content_filtered
      | RepetitionTruncation -> Structured.Truncated Error.Repetition_limit
      | EndTurn | StopToolUse | MaxTokens | StopSequence | Refusal
      | PauseTurn | Compaction | ContextWindowExceeded | UnmatchedToolCalls | Unknown _ ->
        Alcotest.fail "invalid policy/truncation fixture"
    in
    Alcotest.(check bool) "structured terminal reason reaches consumer" true
      (Structured.inspect_response_json response = expected_structured);
    (match Vt.outcome_of_response ~runtime_id:"fixture.vision" ~requested_model:"fixture"
             response with
     | Vt.Vo_provider failure ->
       let expected_class = if expected = ContentFilter then
           Tool_result.Policy_rejection else Tool_result.Runtime_failure in
       Alcotest.(check bool) "vision keeps policy versus repetition failure" true
         (failure.failure_class = expected_class)
     | Vo_ok _ | Vo_invalid_request _ | Vo_no_runtime _ | Vo_timeout
     | Vo_invalid_structured_response _ | Vo_official_failure _ | Vo_empty | Vo_truncated ->
       Alcotest.fail "vision lost policy/truncation failure")
  | EndTurn | StopToolUse | StopSequence | PauseTurn | Compaction
  | ContextWindowExceeded | UnmatchedToolCalls | Unknown _ ->
    Alcotest.fail "invalid terminal fixture"

let test_complete_sync_terminal_reaches_consumers () =
  List.iter (fun (finish, expected) ->
    parse_chat (chat_json ~refusal:`Null ~finish ())
    |> through_complete ~stream:false
    |> check_policy_or_truncation expected)
    [ "refusal", Types.Refusal; "length", MaxTokens
    ; "content_filter", ContentFilter; "repetition_truncation", RepetitionTruncation ]

let test_complete_stream_terminal_reaches_consumers () =
  List.iter (fun (finish, expected) ->
    chat_stream [[], `String finish]
    |> through_complete ~stream:true
    |> check_policy_or_truncation expected)
    [ "refusal", Types.Refusal; "length", MaxTokens
    ; "content_filter", ContentFilter; "repetition_truncation", RepetitionTruncation ]

let test_refusal_is_not_output_limit_failover () =
  check_refusal (parse_chat (chat_json ~finish:"length" ~content:(`String answer) ()))

let test_responses_stream_token_cut () =
  let json = response_json ~status:"incomplete" ~parts:[text_part] () in
  let json = match json with
    | `Assoc fields -> `Assoc (("incomplete_details", `Assoc ["reason", `String "max_output_tokens"]) :: fields)
    | `Null | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ ->
      Alcotest.fail "response fixture was not an object"
  in
  check_token_limit (responses_stream ["response.incomplete", `Assoc ["response", json]])

let serialization_error = function
  | Error (Error.Serialization error) -> error
  | Error ((Error.Api _ | Provider _ | Agent _ | Mcp _ | Config _ | Io _
            | Orchestration _ | Internal _ | Internal_carried _ | Media _) as error) ->
    Alcotest.fail (Error.to_string error)
  | Ok _ -> Alcotest.fail "structured result unexpectedly succeeded"

let test_tool_turn_then_final_schema () =
  let tools = `List [`Assoc
      [ "id", `String "call-fixture"; "type", `String "function"
      ; "function", `Assoc ["name", `String "observe"; "arguments", `String "{}"] ]] in
  let intermediate = parse_chat (chat_json ~refusal:`Null ~finish:"tool_calls" ~tools ()) in
  let parses = ref 0 in
  let schema : Yojson.Safe.t Structured.schema =
    { params = []; parse = (fun json -> incr parses; Ok json) } in
  (match serialization_error (Structured.extract_response ~schema intermediate) with
   | Error.StructuredOutputStateError state ->
     Alcotest.(check bool) "tool turn awaits results" true (state = Error.Awaiting_tool_results)
   | Error.JsonParseError _ | StructuredOutputParseError _ | VersionMismatch _ | UnknownVariant _ ->
     Alcotest.fail "tool turn was not typed as awaiting results");
  Alcotest.(check int) "schema not run on intermediate tool turn" 0 !parses;
  let final = parse_chat (chat_json ~refusal:`Null ~content:(`String answer) ()) in
  (match Structured.extract_response ~schema final with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Error.to_string error));
  Alcotest.(check int) "schema run on final answer" 1 !parses

let test_multiple_text_parts_are_not_joined () =
  let response = parse_responses (response_json ~parts:[text_part;text_part] ()) in
  match serialization_error (Structured.extract_response_json response) with
  | Error.StructuredOutputParseError { reason; _ } ->
    Alcotest.(check bool) "multiple text parts refused" true (reason = Error.Multiple_text_blocks)
  | Error.JsonParseError _ | StructuredOutputStateError _ | VersionMismatch _ | UnknownVariant _ ->
    Alcotest.fail "multiple provider text parts became a single final JSON"

let test_thinking_precedes_final_text () =
  let reasoning = `Assoc ["type", `String "reasoning"; "summary", `List
      [`Assoc ["type", `String "summary_text"; "text", `String "private reasoning"]]] in
  let response = parse_responses (response_json ~parts:[text_part] ~extra_output:[reasoning] ()) in
  match Structured.extract_response_json response with
  | Ok json -> Alcotest.(check string) "visible final text only" answer (Yojson.Safe.to_string json)
  | Error error -> Alcotest.fail (Error.to_string error)

let test_malformed_refusal_is_not_final_json () =
  match Parse.parse_openai_response_result_json
          (chat_json ~refusal:(`Int 1) ~content:(`String answer) ()) with
  | Error (Parse.Unreadable_response _) -> ()
  | Error (Parse.Provider_error _ | Empty_completion _) | Ok _ ->
    Alcotest.fail "malformed refusal carrier accepted"

let gemini_response reason =
  Llm_provider.Backend_gemini.parse_response (`Assoc
    [ "modelVersion", `String "fixture"
    ; "candidates", `List [`Assoc
        [ "finishReason", `String reason
        ; "content", `Assoc ["parts", `List [`Assoc ["text", `String answer]]] ]] ])

let test_gemini_safety_is_refusal () = check_refusal (gemini_response "SAFETY")
let test_gemini_token_cut_is_truncation () = check_token_limit (gemini_response "MAX_TOKENS")

let vision_config = {|
[runtime]
default = "p1.vision-a"
media_failover = ["p1.vision-a", "p2.vision-b"]
[providers.p1]
protocol = "openai-compatible-http"
endpoint = "https://p1.invalid/v1"
[providers.p2]
protocol = "openai-compatible-http"
endpoint = "https://p2.invalid/v1"
[models.vision-a]
api-name = "vision-a"
max-context = 4096
[models.vision-a.capabilities]
supports-image-input = true
supports-multimodal-inputs = true
[models.vision-b]
api-name = "vision-b"
max-context = 4096
[models.vision-b.capabilities]
supports-image-input = true
supports-multimodal-inputs = true
[p1.vision-a]
[p2.vision-b]
|}

let with_vision_runtime f =
  let base = Filename.temp_file "structured-vision-runtime-" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let path = Filename.concat base "runtime.toml" in
  let previous_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let rec remove path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    | { Unix.st_kind = (Unix.S_REG | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK); _ } ->
      Unix.unlink path
  in
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel vision_config);
  Fun.protect ~finally:(fun () ->
    Keeper_tool_call_log.reset_for_testing ();
    (match previous_base with
     | Some value -> Unix.putenv "MASC_BASE_PATH" value
     | None -> Unix.unsetenv "MASC_BASE_PATH");
    Config_dir_resolver.reset ();
    remove base) (fun () ->
    Unix.putenv "MASC_BASE_PATH" base;
    Config_dir_resolver.reset ();
    Keeper_tool_call_log.init ~base_path:base ();
    match Runtime.init_default ~config_path:path with
    | Error detail -> Alcotest.fail detail
    | Ok () -> f ())

let run_vision complete =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Vt.run_vision ~complete ~sw ~clock:(Eio.Stdenv.clock env)
      ~net:(Eio.Stdenv.net env) ~query:"read the image"
      ~media_type:"image/png" ~bytes:"\x89PNG\r\n\x1a\nraw" ()))

let test_actual_vision_walk_does_not_retry_wire_refusal () =
  with_vision_runtime (fun () ->
    let calls = ref 0 in
    let complete ~sw:_ ~net:_ ~clock:_ ~config:_ ~messages:_ ?tools:_ () =
      incr calls;
      Ok (parse_chat (chat_json ~content:(`String answer) ())) in
    let outcome = run_vision complete in
    Alcotest.(check int) "refusal ends candidate walk" 1 !calls;
    match outcome with
    | Vt.Vo_provider { failure_class = Tool_result.Policy_rejection; _ } -> ()
    | Vt.Vo_provider { failure_class = (Tool_result.Workflow_rejection | Runtime_failure
        | Dependency_unavailable | Operator_cancelled); _ }
    | Vt.Vo_ok _ | Vo_invalid_request _ | Vo_no_runtime _ | Vo_timeout
    | Vo_invalid_structured_response _ | Vo_official_failure _ | Vo_empty | Vo_truncated ->
      Alcotest.fail "actual vision walk accepted or retried refusal")

let test_actual_vision_walk_advances_after_empty_token_cut () =
  with_vision_runtime (fun () ->
    let calls = ref 0 in
    let complete ~sw:_ ~net:_ ~clock:_ ~config:_ ~messages:_ ?tools:_ () =
      incr calls;
      Ok (parse_chat (if !calls = 1
        then chat_json ~refusal:`Null ~finish:"length" ()
        else chat_json ~refusal:`Null ~content:(`String answer) ())) in
    let outcome = run_vision complete in
    Alcotest.(check int) "token cut advances to next configured candidate" 2 !calls;
    match outcome with
    | Vt.Vo_ok reading ->
      Alcotest.(check string) "later candidate reading" "visible answer" reading.text;
      Alcotest.(check string) "later candidate identity" "p2.vision-b" reading.runtime_id
    | Vt.Vo_provider _ | Vo_invalid_request _ | Vo_no_runtime _ | Vo_timeout
    | Vo_invalid_structured_response _ | Vo_official_failure _ | Vo_empty | Vo_truncated ->
      Alcotest.fail "actual vision walk lost token-limit recovery")

let () = Alcotest.run "provider structured outcomes"
  [ "wire to consumer",
    [ Alcotest.test_case "Chat empty refusal" `Quick test_chat_refusal_empty
    ; Alcotest.test_case "Chat mixed refusal" `Quick test_chat_refusal_over_valid_json
    ; Alcotest.test_case "Chat refusal over tools" `Quick test_chat_refusal_over_tool_calls
    ; Alcotest.test_case "Responses empty refusal" `Quick test_responses_refusal_empty
    ; Alcotest.test_case "Responses mixed refusal" `Quick test_responses_refusal_over_valid_json
    ; Alcotest.test_case "Responses refusal delta" `Quick test_responses_stream_refusal_delta
    ; Alcotest.test_case "Responses refusal done" `Quick test_responses_stream_refusal_done
    ; Alcotest.test_case "Responses stream mixed refusal" `Quick test_responses_stream_refusal_over_valid_json
    ; Alcotest.test_case "Responses terminal refusal" `Quick test_responses_stream_terminal_refusal
    ; Alcotest.test_case "refusal delta is not terminal" `Quick test_refusal_delta_does_not_invent_terminal
    ; Alcotest.test_case "Chat stream empty refusal" `Quick test_chat_stream_refusal_empty
    ; Alcotest.test_case "Chat stream mixed refusal" `Quick test_chat_stream_refusal_over_valid_json
    ; Alcotest.test_case "ordinary empty control" `Quick test_normal_empty_stays_empty_failure
    ; Alcotest.test_case "ordinary JSON control" `Quick test_normal_json_stays_ready
    ; Alcotest.test_case "empty token cut" `Quick test_chat_empty_token_cut
    ; Alcotest.test_case "public sync terminal reaches consumers" `Quick
        test_complete_sync_terminal_reaches_consumers
    ; Alcotest.test_case "public stream terminal reaches consumers" `Quick
        test_complete_stream_terminal_reaches_consumers
    ; Alcotest.test_case "refusal over token cut" `Quick test_refusal_is_not_output_limit_failover
    ; Alcotest.test_case "Responses stream token cut" `Quick test_responses_stream_token_cut
    ; Alcotest.test_case "tool then final schema" `Quick test_tool_turn_then_final_schema
    ; Alcotest.test_case "multiple text parts" `Quick test_multiple_text_parts_are_not_joined
    ; Alcotest.test_case "thinking and final text" `Quick test_thinking_precedes_final_text
    ; Alcotest.test_case "malformed refusal" `Quick test_malformed_refusal_is_not_final_json
    ; Alcotest.test_case "Gemini safety" `Quick test_gemini_safety_is_refusal
    ; Alcotest.test_case "Gemini token cut" `Quick test_gemini_token_cut_is_truncation
    ; Alcotest.test_case "actual vision refusal terminal" `Quick test_actual_vision_walk_does_not_retry_wire_refusal
    ; Alcotest.test_case "actual vision token recovery" `Quick test_actual_vision_walk_advances_after_empty_token_cut
    ] ]
