open Alcotest

let repeat_string s n =
  let len = String.length s in
  let buf = Bytes.create (len * n) in
  for i = 0 to n - 1 do
    Bytes.blit_string s 0 buf (i * len) len
  done;
  Bytes.unsafe_to_string buf
;;

let deep_nested_array depth = repeat_string "[" depth ^ repeat_string "]" depth

let deep_nested_object depth =
  repeat_string "{\"a\":" depth ^ "0" ^ repeat_string "}" depth
;;

(* P0-11: Bounded JSON nesting depth across untrusted llm_provider decoders. *)
let test_json_depth_scanner_and_bounded_parse () =
  let max_d = Llm_provider.Json_util.max_json_nesting_depth in
  check bool "max_json_nesting_depth is 256" true (max_d = 256);
  (* Exactly at the limit succeeds. *)
  (match Llm_provider.Json_util.check_nesting_depth (deep_nested_array max_d) with
   | Ok () -> ()
   | Error e -> failf "expected depth %d to pass, got: %s" max_d e);
  (* One above the limit fails closed. *)
  (match Llm_provider.Json_util.check_nesting_depth (deep_nested_array (max_d + 1)) with
   | Error _ -> ()
   | Ok () -> failf "expected depth %d to fail" (max_d + 1));
  (* Brackets inside JSON string literals (including escaped quotes/backslashes
     and literal comment-like sequences such as "http://x/*y") do NOT count
     toward container nesting depth or trigger comment mode. *)
  let tricky_string =
    Printf.sprintf
      {|{"url":"http://x/*y","text":"%s\\\"\\\\%s"}|}
      (repeat_string "[" 500)
      (repeat_string "{" 500)
  in
  (match Llm_provider.Json_util.from_string_bounded tricky_string with
   | Ok (`Assoc _) -> ()
   | Ok _ -> fail "expected assoc for tricky string"
   | Error e -> failf "brackets/comment-like text inside string literal must not trip depth check: %s" e);
  (* Yojson C/C++ comments containing quotes must NOT flip string mode and
     bypass the nesting depth check. *)
  let deep_5000 = deep_nested_array 5000 in
  List.iter
    (fun (label, payload) ->
       (match Llm_provider.Json_util.check_nesting_depth payload with
        | Error _ -> ()
        | Ok () -> failf "comment bypass (%s) must be rejected by check_nesting_depth" label);
       match Llm_provider.Json_util.from_string_bounded payload with
       | Error _ -> ()
       | Ok _ -> failf "comment bypass (%s) must be rejected by from_string_bounded" label)
    [ "line comment with quote", "// \"\n" ^ deep_5000
    ; "line comment with CR then quote then LF", "// \r\"\n" ^ deep_5000
    ; "block comment with quote", "/* \" */ " ^ deep_5000
    ; "block comment with star-quote", "/* *\" */ " ^ deep_5000
    ; "block comment with double-star close", "/* **/ " ^ deep_5000
    ; "empty block comment before quote-free deep array", "/**/" ^ deep_5000
    ];
  (* 10,000-deep payloads must fail cleanly without Stack_overflow. *)
  let deep_arr = deep_nested_array 10_000 in
  let deep_obj = deep_nested_object 10_000 in
  (match Llm_provider.Json_util.from_string_bounded deep_arr with
   | Error _ -> ()
   | Ok _ -> fail "10000-deep array must be rejected");
  (match Llm_provider.Json_util.from_string_bounded deep_obj with
   | Error _ -> ()
   | Ok _ -> fail "10000-deep object must be rejected");
  (match Llm_provider.Json_util.from_string_bounded_exn deep_arr with
   | exception Yojson.Json_error _ -> ()
   | _ -> fail "from_string_bounded_exn must raise Yojson.Json_error on deep payload")
;;

let test_all_wire_decoders_reject_deep_json_without_stack_overflow () =
  let deep_obj = deep_nested_object 10_000 in
  (match Llm_provider.Backend_openai_parse.parse_openai_response_result deep_obj with
   | Error (Llm_provider.Backend_openai_parse.Unreadable_response _) -> ()
   | Ok _ -> fail "Backend_openai_parse accepted 10000-deep JSON"
   | Error e ->
     failf "unexpected Backend_openai_parse error: %s"
       (Llm_provider.Backend_openai_parse.parse_error_to_string e));
  (match Llm_provider.Backend_openai_responses.parse_response_result deep_obj with
   | Error _ -> ()
   | Ok _ -> fail "Backend_openai_responses accepted 10000-deep JSON");
  (match Llm_provider.Backend_ollama.parse_ollama_response deep_obj with
   | Error _ -> ()
   | Ok _ -> fail "Backend_ollama accepted 10000-deep JSON");
  (match
     Llm_provider.Openai_wire.parse_openai_sse_chunk
       ~streaming_reasoning:Llm_provider.Reasoning_dialect.No_streaming_reasoning
       deep_obj
   with
   | Llm_provider.Openai_wire.Openai_parse_failed _ -> ()
   | _ -> fail "Openai_wire did not return Openai_parse_failed for 10000-deep JSON");
  (match Llm_provider.Gemini_wire.parse_gemini_sse_chunk deep_obj with
   | Llm_provider.Gemini_wire.Gemini_parse_failed _ -> ()
   | _ -> fail "Gemini_wire did not return Gemini_parse_failed for 10000-deep JSON");
  (match Llm_provider.Ollama_wire.parse_ollama_ndjson_chunk deep_obj with
   | Llm_provider.Ollama_wire.Ollama_parse_failed _ -> ()
   | _ -> fail "Ollama_wire did not return Ollama_parse_failed for 10000-deep JSON");
  let sse_events = Llm_provider.Streaming.parse_sse_events (Some "message_start") deep_obj in
  check bool "Streaming.parse_sse_events returns SSEParseFailed without Stack_overflow" true
    (List.exists
       (function
         | Llm_provider.Types.SSEParseFailed _ -> true
         | _ -> false)
       sse_events);
  let state = Llm_provider.Streaming.create_openai_stream_state () in
  let resp_events, _ =
    Llm_provider.Streaming.responses_sse_to_events state (Some "response.completed") deep_obj
  in
  check bool "Responses_stream returns SSEParseFailed without Stack_overflow" true
    (List.exists
       (function
         | Llm_provider.Types.SSEParseFailed _ -> true
         | _ -> false)
       resp_events);
  check (option (float 0.0)) "Retry.resolve_retry_after returns None on deep body" None
    (Llm_provider.Retry.resolve_retry_after ~body:deep_obj ~header:None);
  check (option string) "Api_common.error_message_of_body returns None on deep body" None
    (Llm_provider.Api_common.error_message_of_body deep_obj);
  (match Llm_provider.Tool_call_input.parse_object deep_obj with
   | Error _ -> ()
   | Ok _ -> fail "Tool_call_input.parse_object accepted 10000-deep JSON");
  check bool "Types.try_parse_json returns None on 10000-deep JSON" true
    (Option.is_none (Llm_provider.Types.try_parse_json deep_obj));
  (match Llm_provider.Provider_files.parse_body_file_object deep_obj with
   | Error _ -> ()
   | Ok _ -> fail "Provider_files.parse_body_file_object accepted 10000-deep JSON");
  Llm_provider.Http_client_diagnostics.profile_opaque_client_error
    ~url:"https://api.example.com/v1/messages?key=secret"
    ~code:400
    ~resp_headers:(Http.Header.init ())
    ~request_headers:[ "x-goog-api-key", "secret" ]
    ~request_body:deep_obj
    ~response_body:deep_obj
;;

(* P1-11: Stream byte accumulation cap + thread-safe capability_drop_warned. *)
let test_stream_state_enforces_cumulative_byte_cap () =
  let open Llm_provider.Types in
  let cap = Llm_provider.Complete_stream_state.max_accumulated_stream_bytes in
  check bool "max_accumulated_stream_bytes is 32 MiB" true (cap = 32 * 1024 * 1024);
  let chunk = String.make (1024 * 1024) 'a' in
  let st = Llm_provider.Complete_stream_state.empty in
  let st, _ =
    Llm_provider.Complete_stream_state.transition_with_resolution
      st
      (MessageStart { id = "m1"; model = "test-model"; usage = None })
  in
  let st, _ =
    Llm_provider.Complete_stream_state.transition_with_resolution
      st
      (ContentBlockStart
         { index = 0; content_type = "text"; tool_id = None; tool_name = None })
  in
  let rec feed state n =
    if n = 0
    then state, None
    else (
      let next, res =
        Llm_provider.Complete_stream_state.transition_with_resolution
          state
          (ContentBlockDelta { index = 0; delta = TextDelta chunk })
      in
      match res with
      | Stream_event_rejected err -> next, Some err
      | Stream_event_accepted _ | Stream_event_suppressed -> feed next (n - 1))
  in
  let final_state, rejected = feed st 33 in
  (match rejected with
   | Some (Stream_parse_failed _) -> ()
   | Some _ -> fail "expected Stream_parse_failed when exceeding byte cap"
   | None -> fail "expected stream state to reject cumulative payload > 32 MiB");
  check bool "state marked failed after cap breach" true
    (Llm_provider.Complete_stream_state.has_failed final_state);
  check bool "accumulated bytes stays within cap" true
    (Llm_provider.Complete_stream_state.accumulated_bytes final_state <= cap);
  (match Llm_provider.Complete_stream_state.finalize final_state with
   | Llm_provider.Complete_stream_state.Failed (Stream_parse_failed _) -> ()
   | _ -> fail "finalize must return Failed (Stream_parse_failed _) after byte cap breach");
  (* Vector (a): ReasoningDetailsDelta with large [detail.raw] and [text = None]. *)
  let rd_st =
    let s = Llm_provider.Complete_stream_state.empty in
    let s, _ =
      Llm_provider.Complete_stream_state.transition_with_resolution
        s
        (MessageStart { id = "m-rd"; model = "test-model"; usage = None })
    in
    let s, _ =
      Llm_provider.Complete_stream_state.transition_with_resolution
        s
        (ContentBlockStart
           { index = 0
           ; content_type = "reasoning_details"
           ; tool_id = None
           ; tool_name = None
           })
    in
    s
  in
  let raw_detail : reasoning_detail =
    { raw = `Assoc [ "encrypted_data", `String chunk ]; text = None }
  in
  let rec feed_rd state n =
    if n = 0
    then state, None
    else (
      let next, res =
        Llm_provider.Complete_stream_state.transition_with_resolution
          state
          (ContentBlockDelta
             { index = 0
             ; delta =
                 ReasoningDetailsDelta
                   { reasoning_content = None; details = [ raw_detail ] }
             })
      in
      match res with
      | Stream_event_rejected err -> next, Some err
      | Stream_event_accepted _ | Stream_event_suppressed -> feed_rd next (n - 1))
  in
  let rd_final, rd_rej = feed_rd rd_st 33 in
  (match rd_rej with
   | Some (Stream_parse_failed _) -> ()
   | _ -> fail "ReasoningDetailsDelta with 33 MiB raw JSON must trip byte cap");
  check bool "rd_final marked failed" true
    (Llm_provider.Complete_stream_state.has_failed rd_final);
  (* Vector (b): ContentBlockStart flood carrying oversized tool_id/tool_name. *)
  let cbs_st, _ =
    Llm_provider.Complete_stream_state.transition_with_resolution
      Llm_provider.Complete_stream_state.empty
      (MessageStart { id = "m-cbs"; model = "test-model"; usage = None })
  in
  let rec feed_cbs state idx =
    if idx >= 33
    then state, None
    else (
      let next, res =
        Llm_provider.Complete_stream_state.transition_with_resolution
          state
          (ContentBlockStart
             { index = idx
             ; content_type = "tool_use"
             ; tool_id = Some (Printf.sprintf "call_%d" idx)
             ; tool_name = Some chunk
             })
      in
      match res with
      | Stream_event_rejected err -> next, Some err
      | Stream_event_accepted _ | Stream_event_suppressed -> feed_cbs next (idx + 1))
  in
  let _, cbs_rej = feed_cbs cbs_st 0 in
  (match cbs_rej with
   | Some (Stream_parse_failed _) -> ()
   | _ -> fail "ContentBlockStart flood > 32 MiB must trip byte cap");
  (* Vector (c): Empty TextDelta "" cons-cell flood. *)
  let rec feed_empty state n =
    if n = 0
    then state, None
    else (
      let next, res =
        Llm_provider.Complete_stream_state.transition_with_resolution
          state
          (ContentBlockDelta { index = 0; delta = TextDelta "" })
      in
      match res with
      | Stream_event_rejected err -> next, Some err
      | Stream_event_accepted _ | Stream_event_suppressed -> feed_empty next (n - 1))
  in
  let _, empty_rej = feed_empty st 1_100_000 in
  match empty_rej with
  | Some (Stream_parse_failed _) -> ()
  | _ -> fail "empty TextDelta flood must trip byte cap via per-delta overhead"
;;

let test_capability_drop_warned_thread_safe_and_bounded () =
  let workers =
    List.init 4 (fun worker_id ->
      Domain.spawn (fun () ->
        for i = 0 to 1500 do
          let model_id = Printf.sprintf "rt-model-%d-%d" worker_id i in
          Llm_provider.Backend_openai_request.warn_capability_drop
            ~model_id
            ~field:"temperature";
          Llm_provider.Backend_openai_request.warn_capability_drop
            ~model_id:"shared-model"
            ~field:"top_p"
        done))
  in
  List.iter Domain.join workers
;;

(* P1-12: Non-negative saturating token counts & tolerant Ollama numeric decoding. *)
let test_saturating_non_negative_helpers_and_usage_addition () =
  let open Llm_provider.Json_util in
  check int "clamp negative" 0 (clamp_non_negative (-42));
  check int "clamp min_int" 0 (clamp_non_negative Int.min_int);
  check int "clamp positive" 17 (clamp_non_negative 17);
  check int "sat add negative" 10 (saturating_add_non_negative (-5) 10);
  check int "sat add overflow" Int.max_int (saturating_add_non_negative Int.max_int 1);
  check int "sat add max+max" Int.max_int
    (saturating_add_non_negative Int.max_int Int.max_int);
  let open Agent_core_base.Types in
  let u1 : api_usage =
    { input_tokens = Int.max_int - 2
    ; output_tokens = -10
    ; cache_creation_input_tokens = Int.max_int
    ; cache_read_input_tokens = 5
    ; cost_usd = Some (-3.5)
    }
  in
  let u2 : api_usage =
    { input_tokens = 100
    ; output_tokens = 20
    ; cache_creation_input_tokens = 100
    ; cache_read_input_tokens = Int.max_int
    ; cost_usd = Some 1.25
    }
  in
  let sum = add_usage (add_usage empty_usage u1) u2 in
  check int "add_usage input saturates" Int.max_int sum.total_input_tokens;
  check int "add_usage output clamps negative" 20 sum.total_output_tokens;
  check int "add_usage cache_creation saturates" Int.max_int
    sum.total_cache_creation_input_tokens;
  check int "add_usage cache_read saturates" Int.max_int
    sum.total_cache_read_input_tokens
;;

let test_ollama_tolerant_numbers_and_non_negative_clamping () =
  let json =
    `Assoc
      [ "neg_int", `Int (-99)
      ; "float_val", `Float 1234.9
      ; "neg_float", `Float (-5.2)
      ; "nan_float", `Float Float.nan
      ; "huge_intlit", `Intlit "99999999999999999999999999999999"
      ; "neg_intlit", `Intlit "-500"
      ; "bad_str", `String "not-a-number"
      ]
  in
  let opt = Llm_provider.Ollama_wire.optional_non_negative_int_member in
  check (option int) "neg_int -> Some 0" (Some 0) (opt "neg_int" json);
  check (option int) "float_val -> Some 1234" (Some 1234) (opt "float_val" json);
  check (option int) "neg_float -> Some 0" (Some 0) (opt "neg_float" json);
  check (option int) "nan_float -> None" None (opt "nan_float" json);
  check (option int) "huge_intlit -> Some max_int" (Some Int.max_int) (opt "huge_intlit" json);
  check (option int) "neg_intlit -> Some 0" (Some 0) (opt "neg_intlit" json);
  check (option int) "bad_str -> None" None (opt "bad_str" json);
  let body =
    {|{"model":"qwen3","done":true,"done_reason":"stop","message":{"role":"assistant","content":"ok"},"prompt_eval_count":-10,"eval_count":7,"prompt_eval_duration":1500000.5,"eval_duration":999999999999999999999999999999,"load_duration":250.0}|}
  in
  (match Llm_provider.Ollama_wire.parse_ollama_ndjson_chunk body with
   | Llm_provider.Ollama_wire.Ollama_chunk chunk ->
     (match chunk.oll_usage with
      | Some u ->
        check int "ollama ndjson input_tokens clamped" 0 u.input_tokens;
        check int "ollama ndjson output_tokens preserved" 7 u.output_tokens
      | None -> fail "expected ollama ndjson usage");
     (match chunk.oll_timings with
      | Some t ->
        check (option (float 0.001)) "ollama float prompt_eval_duration decoded to ms"
          (Some 1.5) t.prompt_ms;
        check bool "ollama huge intlit eval_duration decoded to finite positive ms" true
          (match t.predicted_ms with
           | Some ms -> Float.is_finite ms && ms > 0.0
           | None -> false)
      | None -> fail "expected ollama ndjson timings")
   | _ -> fail "Ollama_wire failed on float/intlit durations");
  let all_neg_body =
    {|{"model":"qwen3","done":true,"done_reason":"stop","message":{"role":"assistant","content":"ok"},"prompt_eval_count":-10,"eval_count":-4}|}
  in
  (match Llm_provider.Ollama_wire.parse_ollama_ndjson_chunk all_neg_body with
   | Llm_provider.Ollama_wire.Ollama_chunk chunk ->
     check bool "ollama all-negative counts clamp to 0 and map to None usage" true
       (Option.is_none chunk.oll_usage)
   | _ -> fail "Ollama_wire failed on all-negative counts");
  match Llm_provider.Backend_ollama.parse_ollama_response body with
  | Ok resp ->
    (match resp.usage with
     | Some u ->
       check int "backend_ollama input_tokens clamped" 0 u.input_tokens;
       check int "backend_ollama output_tokens preserved" 7 u.output_tokens
     | None -> fail "expected backend_ollama usage")
  | Error e -> failf "Backend_ollama failed on float/intlit durations: %s" e
;;

let test_provider_usage_parsers_clamp_negatives_and_saturate () =
  (* Gemini sync + SSE *)
  let gemini_neg_thoughts_json =
    Yojson.Safe.from_string
      {|{"modelVersion":"gemini-2.5-pro","candidates":[{"content":{"role":"model","parts":[{"text":"hi"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":-12,"candidatesTokenCount":-7,"thoughtsTokenCount":-3,"cachedContentTokenCount":-9}}|}
  in
  let gemini_resp = Llm_provider.Backend_gemini.parse_response gemini_neg_thoughts_json in
  (match gemini_resp.usage with
   | Some u ->
     check int "gemini sync input clamped" 0 u.input_tokens;
     check int "gemini sync output clamped" 0 u.output_tokens;
     check int "gemini sync cache_read clamped" 0 u.cache_read_input_tokens
   | None -> fail "expected gemini sync usage");
  (match
     Llm_provider.Gemini_wire.parse_gemini_sse_chunk
       (Yojson.Safe.to_string gemini_neg_thoughts_json)
   with
   | Llm_provider.Gemini_wire.Gemini_parse_failed _ -> ()
   | _ -> fail "Gemini_wire must fail closed on negative thoughtsTokenCount");
  let gemini_sse_clamp_json =
    {|{"modelVersion":"gemini-2.5-pro","candidates":[{"content":{"role":"model","parts":[{"text":"hi"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":-12,"candidatesTokenCount":-7,"thoughtsTokenCount":2,"cachedContentTokenCount":-9}}|}
  in
  (match Llm_provider.Gemini_wire.parse_gemini_sse_chunk gemini_sse_clamp_json with
   | Llm_provider.Gemini_wire.Gemini_chunk chunk ->
     (match chunk.gem_usage with
      | Some u ->
        check int "gemini sse input clamped" 0 u.input_tokens;
        check int "gemini sse output folds thoughts without negative candidates" 2
          u.output_tokens;
        check int "gemini sse cache_read clamped" 0 u.cache_read_input_tokens
      | None -> fail "expected gemini sse usage")
   | _ -> fail "Gemini_wire failed on clampable negative usage");
  (* Anthropic SSE message_start & message_delta *)
  let start_events =
    Llm_provider.Streaming.parse_sse_events
      (Some "message_start")
      {|{"type":"message_start","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":-100,"output_tokens":-20,"cache_creation_input_tokens":-5,"cache_read_input_tokens":-15}}}|}
  in
  (match start_events with
   | [ Llm_provider.Types.MessageStart { usage = Some u; _ } ] ->
     check int "sse message_start input clamped" 0 u.input_tokens;
     check int "sse message_start output clamped" 0 u.output_tokens;
     check int "sse message_start cache_creation clamped" 0 u.cache_creation_input_tokens;
     check int "sse message_start cache_read clamped" 0 u.cache_read_input_tokens
   | _ -> fail "expected MessageStart with clamped usage");
  let delta_events =
    Llm_provider.Streaming.parse_sse_events
      (Some "message_delta")
      {|{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":-1,"output_tokens":-2,"cache_creation_input_tokens":-3,"cache_read_input_tokens":-4}}|}
  in
  (match delta_events with
   | [ Llm_provider.Types.MessageDelta { usage = Some u; _ } ] ->
     check (option int) "sse message_delta input clamped" (Some 0) u.input_tokens;
     check (option int) "sse message_delta output clamped" (Some 0) u.output_tokens;
     check (option int) "sse message_delta cache_creation clamped" (Some 0)
       u.cache_creation_input_tokens;
     check (option int) "sse message_delta cache_read clamped" (Some 0)
       u.cache_read_input_tokens
   | _ -> fail "expected MessageDelta with clamped usage");
  (* OpenAI Chat Completions usage + delta usage *)
  let openai_usage_json =
    `Assoc
      [ "usage"
      , `Assoc
          [ "prompt_tokens", `Int (-50)
          ; "completion_tokens", `Int (-25)
          ; "prompt_tokens_details", `Assoc [ "cached_tokens", `Int (-10) ]
          ]
      ]
  in
  (match Llm_provider.Backend_openai_parse.usage_of_openai_json openai_usage_json with
   | Some u ->
     check int "openai sync input clamped" 0 u.input_tokens;
     check int "openai sync output clamped" 0 u.output_tokens;
     check int "openai sync cache_read clamped" 0 u.cache_read_input_tokens
   | None -> fail "expected openai usage");
  (match Llm_provider.Backend_openai_parse.delta_usage_of_openai_json openai_usage_json with
   | Some u ->
     check (option int) "openai delta input clamped" (Some 0) u.input_tokens;
     check (option int) "openai delta output clamped" (Some 0) u.output_tokens;
     check (option int) "openai delta cache_read clamped" (Some 0) u.cache_read_input_tokens
   | None -> fail "expected openai delta usage");
  (* OpenAI Responses sync + streaming *)
  let responses_body =
    {|{"id":"resp_1","model":"gpt-5.4","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}]}],"usage":{"input_tokens":-30,"output_tokens":-15,"input_tokens_details":{"cached_tokens":-8}}}|}
  in
  (match Llm_provider.Backend_openai_responses.parse_response_result responses_body with
   | Ok parsed ->
     (match parsed.response.usage with
      | Some u ->
        check int "responses sync input clamped" 0 u.input_tokens;
        check int "responses sync output clamped" 0 u.output_tokens;
        check int "responses sync cache_read clamped" 0 u.cache_read_input_tokens
      | None -> fail "expected responses sync usage")
   | Error e -> failf "responses sync parse failed: %s" e.detail);
  let rstate = Llm_provider.Streaming.create_openai_stream_state () in
  let revents, _ =
    Llm_provider.Streaming.responses_sse_to_events
      rstate
      (Some "response.completed")
      (Printf.sprintf {|{"type":"response.completed","response":%s}|} responses_body)
  in
  check bool "responses stream clamps usage to >= 0" true
    (List.exists
       (function
         | Llm_provider.Types.MessageDelta { usage = Some u; _ } ->
           u.input_tokens = Some 0
           && u.output_tokens = Some 0
           && u.cache_read_input_tokens = Some 0
         | _ -> false)
       revents)
;;

let test_pricing_metrics_and_agent_turn_clamp_negatives_and_overflow () =
  let pricing : Llm_provider.Pricing.pricing =
    { input_per_million = 10.0
    ; output_per_million = 30.0
    ; cache_write_multiplier = Some 1.25
    ; cache_write_1h_multiplier = Some 2.0
    ; cache_read_multiplier = Some 0.1
    }
  in
  (match
     Llm_provider.Pricing.estimate_cost
       ~pricing
       ~cache_writes:Llm_provider.Pricing.Provider_default
       ~input_tokens:(-1000)
       ~output_tokens:(-500)
       ~cache_creation_input_tokens:(-200)
       ~cache_read_input_tokens:(-100)
       ()
   with
   | Llm_provider.Pricing.Estimated cost ->
     check bool "pricing cost is non-negative" true (cost >= 0.0 && cost = 0.0)
   | Llm_provider.Pricing.Incomplete _ -> fail "expected Estimated 0.0");
  let agg = Llm_provider.Metrics.Aggregating.create () in
  let hooks = Llm_provider.Metrics.Aggregating.to_hooks agg in
  hooks.on_token_usage
    ~provider:"p"
    ~model_id:"m"
    ~input_tokens:(-50)
    ~output_tokens:(Int.max_int - 1);
  hooks.on_token_usage
    ~provider:"p"
    ~model_id:"m"
    ~input_tokens:10
    ~output_tokens:100;
  hooks.on_tool_calls ~provider:"p" ~model_id:"m" ~count:(-5);
  hooks.on_tool_calls ~provider:"p" ~model_id:"m" ~count:Int.max_int;
  hooks.on_tool_calls ~provider:"p" ~model_id:"m" ~count:10;
  (match Llm_provider.Metrics.Aggregating.snapshot agg with
   | [ snap ] ->
     check int "metrics input clamped negative" 10 snap.input_tokens_total;
     check int "metrics output saturates" Int.max_int snap.output_tokens_total;
     check int "metrics tool_calls clamped and saturates" Int.max_int snap.tool_call_total
   | _ -> fail "expected single metrics snapshot");
  let next_usage =
    Agent_core.Agent_turn.accumulate_usage
      ~current_usage:Agent_core_base.Types.empty_usage
      ~response_model:(Some "test-model")
      ~response_usage:
        (Some
           { input_tokens = -100
           ; output_tokens = Int.max_int
           ; cache_creation_input_tokens = -5
           ; cache_read_input_tokens = -1
           ; cost_usd = Some (-42.0)
           })
  in
  check int "agent_turn input clamped" 0 next_usage.total_input_tokens;
  check int "agent_turn output preserved" Int.max_int next_usage.total_output_tokens;
  check bool "agent_turn negative cost clamped to 0.0" true
    (next_usage.estimated_cost_usd = 0.0)
;;

let () =
  run
    "red_team_wire_security"
    [ ( "P0-11 bounded JSON nesting depth"
      , [ test_case "scanner and bounded parser reject deep nesting" `Quick
            test_json_depth_scanner_and_bounded_parse
        ; test_case "all llm_provider wire decoders contain 10000-deep JSON" `Quick
            test_all_wire_decoders_reject_deep_json_without_stack_overflow
        ] )
    ; ( "P1-11 stream byte cap and concurrent warning table"
      , [ test_case "Complete_stream_state enforces 32 MiB byte cap" `Quick
            test_stream_state_enforces_cumulative_byte_cap
        ; test_case "capability_drop_warned is thread-safe and bounded" `Quick
            test_capability_drop_warned_thread_safe_and_bounded
        ] )
    ; ( "P1-12 non-negative saturating usage and tolerant Ollama numbers"
      , [ test_case "Json_util and Types.add_usage clamp and saturate" `Quick
            test_saturating_non_negative_helpers_and_usage_addition
        ; test_case "Ollama wire and backend tolerate floats/intlit and clamp negatives" `Quick
            test_ollama_tolerant_numbers_and_non_negative_clamping
        ; test_case "all provider usage parsers clamp negative counts" `Quick
            test_provider_usage_parsers_clamp_negatives_and_saturate
        ; test_case "Pricing, Metrics, and Agent_turn clamp negatives and saturate" `Quick
            test_pricing_metrics_and_agent_turn_clamp_negatives_and_overflow
        ] )
    ]
;;
