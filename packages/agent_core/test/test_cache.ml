(** Tests for prompt caching: usage parsing and add_usage with cache token
    fields. *)

open Agent_sdk.Types

(* ------------------------------------------------------------------ *)
(* parse_response: cache token extraction                               *)
(* ------------------------------------------------------------------ *)

let test_parse_usage_with_cache_tokens () =
  let json_str =
    {|{
    "id": "msg_cache",
    "model": "claude-sonnet-4-20250514",
    "stop_reason": "end_turn",
    "content": [{"type": "text", "text": "Hello"}],
    "usage": {
      "input_tokens": 100,
      "output_tokens": 50,
      "cache_creation_input_tokens": 2000,
      "cache_read_input_tokens": 1500
    }
  }|}
  in
  let json = Yojson.Safe.from_string json_str in
  let resp = Agent_sdk.Llm_provider.Backend_anthropic.parse_response json in
  match resp.usage with
  | Some u ->
    Alcotest.(check int) "input_tokens" 100 u.input_tokens;
    Alcotest.(check int) "output_tokens" 50 u.output_tokens;
    Alcotest.(check int) "cache_creation" 2000 u.cache_creation_input_tokens;
    Alcotest.(check int) "cache_read" 1500 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected usage"
;;

let test_parse_usage_without_cache_tokens () =
  let json_str =
    {|{
    "id": "msg_nocache",
    "model": "claude-sonnet-4-20250514",
    "stop_reason": "end_turn",
    "content": [{"type": "text", "text": "Hi"}],
    "usage": {
      "input_tokens": 80,
      "output_tokens": 30
    }
  }|}
  in
  let json = Yojson.Safe.from_string json_str in
  let resp = Agent_sdk.Llm_provider.Backend_anthropic.parse_response json in
  match resp.usage with
  | Some u ->
    Alcotest.(check int) "input_tokens" 80 u.input_tokens;
    Alcotest.(check int) "output_tokens" 30 u.output_tokens;
    Alcotest.(check int) "cache_creation defaults 0" 0 u.cache_creation_input_tokens;
    Alcotest.(check int) "cache_read defaults 0" 0 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected usage"
;;

(* ------------------------------------------------------------------ *)
(* add_usage: cache token accumulation                                  *)
(* ------------------------------------------------------------------ *)

let test_add_usage_cache_accumulation () =
  let u1 =
    { input_tokens = 100
    ; output_tokens = 50
    ; cache_creation_input_tokens = 2000
    ; cache_read_input_tokens = 0
    ; cost_usd = None
    }
  in
  let u2 =
    { input_tokens = 80
    ; output_tokens = 30
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 1800
    ; cost_usd = None
    }
  in
  let stats = add_usage (add_usage empty_usage u1) u2 in
  Alcotest.(check int) "total_input" 180 stats.total_input_tokens;
  Alcotest.(check int) "total_output" 80 stats.total_output_tokens;
  Alcotest.(check int) "cache_creation sum" 2000 stats.total_cache_creation_input_tokens;
  Alcotest.(check int) "cache_read sum" 1800 stats.total_cache_read_input_tokens;
  Alcotest.(check int) "api_calls" 2 stats.api_calls
;;

(* ------------------------------------------------------------------ *)
(* Openai: cache token parsing from prompt_tokens_details               *)
(* ------------------------------------------------------------------ *)

let test_openai_usage_with_cached_tokens () =
  let json_str =
    {|{
    "id": "chatcmpl-abc",
    "model": "gpt",
    "choices": [{
      "index": 0,
      "message": {"role": "assistant", "content": "Hello"},
      "finish_reason": "stop"
    }],
    "usage": {
      "prompt_tokens": 500,
      "completion_tokens": 20,
      "prompt_tokens_details": {
        "cached_tokens": 384
      }
    }
  }|}
  in
  let resp =
    match
      Agent_sdk.Llm_provider.Backend_openai_parse.parse_openai_response_result json_str
    with
    | Ok r -> r
    | Error msg -> failwith (Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  in
  match resp.usage with
  | Some u ->
    Alcotest.(check int) "input_tokens" 500 u.input_tokens;
    Alcotest.(check int) "output_tokens" 20 u.output_tokens;
    Alcotest.(check int) "cache_creation" 0 u.cache_creation_input_tokens;
    Alcotest.(check int) "cache_read" 384 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected usage"
;;

let test_openai_usage_without_cached_tokens () =
  let json_str =
    {|{
    "id": "chatcmpl-def",
    "model": "gpt",
    "choices": [{
      "index": 0,
      "message": {"role": "assistant", "content": "Hi"},
      "finish_reason": "stop"
    }],
    "usage": {
      "prompt_tokens": 100,
      "completion_tokens": 10
    }
  }|}
  in
  let resp =
    match
      Agent_sdk.Llm_provider.Backend_openai_parse.parse_openai_response_result json_str
    with
    | Ok r -> r
    | Error msg -> failwith (Llm_provider.Backend_openai_parse.parse_error_to_string msg)
  in
  match resp.usage with
  | Some u ->
    Alcotest.(check int) "input_tokens" 100 u.input_tokens;
    Alcotest.(check int) "output_tokens" 10 u.output_tokens;
    Alcotest.(check int) "cache_creation" 0 u.cache_creation_input_tokens;
    Alcotest.(check int) "cache_read" 0 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected usage"
;;

(* ------------------------------------------------------------------ *)
(* streaming: message_delta cache token parsing                        *)
(* ------------------------------------------------------------------ *)

let test_streaming_message_delta_with_cache () =
  let data_str =
    {|{
    "type": "message_delta",
    "delta": {"stop_reason": "end_turn"},
    "usage": {
      "output_tokens": 42,
      "cache_creation_input_tokens": 1500,
      "cache_read_input_tokens": 800
    }
  }|}
  in
  match
    Agent_sdk.Llm_provider.Streaming.parse_sse_event (Some "message_delta") data_str
  with
  | Some (MessageDelta { stop_reason; usage }) ->
    Alcotest.(check bool) "has stop_reason" true (Option.is_some stop_reason);
    (match usage with
     | Some u ->
       Alcotest.(check int) "output" 42 u.output_tokens;
       Alcotest.(check int) "cache_creation" 1500 u.cache_creation_input_tokens;
       Alcotest.(check int) "cache_read" 800 u.cache_read_input_tokens
     | None -> Alcotest.fail "expected usage in message_delta")
  | _ -> Alcotest.fail "expected MessageDelta event"
;;

let test_streaming_message_delta_without_cache () =
  let data_str =
    {|{
    "type": "message_delta",
    "delta": {"stop_reason": "end_turn"},
    "usage": {
      "output_tokens": 10
    }
  }|}
  in
  match
    Agent_sdk.Llm_provider.Streaming.parse_sse_event (Some "message_delta") data_str
  with
  | Some (MessageDelta { usage; _ }) ->
    (match usage with
     | Some u ->
       Alcotest.(check int) "output" 10 u.output_tokens;
       Alcotest.(check int) "cache_creation defaults 0" 0 u.cache_creation_input_tokens;
       Alcotest.(check int) "cache_read defaults 0" 0 u.cache_read_input_tokens
     | None -> Alcotest.fail "expected usage")
  | _ -> Alcotest.fail "expected MessageDelta event"
;;

(* ------------------------------------------------------------------ *)
(* Test runner                                                          *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run
    "prompt_caching"
    [ ( "parse_response"
      , [ test_case "usage with cache tokens" `Quick test_parse_usage_with_cache_tokens
        ; test_case
            "usage without cache tokens"
            `Quick
            test_parse_usage_without_cache_tokens
        ] )
    ; ( "add_usage"
      , [ test_case "cache token accumulation" `Quick test_add_usage_cache_accumulation ]
      )
    ; ( "openai_cache"
      , [ test_case "usage with cached_tokens" `Quick test_openai_usage_with_cached_tokens
        ; test_case
            "usage without cached_tokens"
            `Quick
            test_openai_usage_without_cached_tokens
        ] )
    ; ( "streaming_delta_cache"
      , [ test_case
            "message_delta with cache tokens"
            `Quick
            test_streaming_message_delta_with_cache
        ; test_case
            "message_delta without cache tokens"
            `Quick
            test_streaming_message_delta_without_cache
        ] )
    ]
;;
