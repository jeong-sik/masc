(** HTTP-level tests for Complete module using mock cohttp-eio server.
    Tests one-shot complete and complete_stream.
    No real LLM calls — all responses are canned JSON. *)

open Alcotest
open Llm_provider

(* ── Mock server ─────────────────────────────────────── *)

let anthropic_response ?(id = "msg-1") ?(model = "mock") ?(stop_reason = "end_turn") text =
  Printf.sprintf
    {|{"id":"%s","type":"message","role":"assistant","model":"%s","content":[{"type":"text","text":"%s"}],"stop_reason":"%s","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}|}
    id
    model
    text
    stop_reason
;;

let anthropic_empty_response stop_reason =
  Printf.sprintf
    {|{"id":"msg-empty","type":"message","role":"assistant","model":"mock","content":[],"stop_reason":"%s","usage":{"input_tokens":10,"output_tokens":0}}|}
    stop_reason
;;

let anthropic_empty_sse stop_reason =
  Printf.sprintf
    "event: message_start\n\
     data: \
     {\"type\":\"message_start\",\"message\":{\"id\":\"msg-empty\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"mock\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n\
     event: message_delta\n\
     data: \
     {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"%s\"},\"usage\":{\"output_tokens\":0}}\n\n\
     event: message_stop\n\
     data: {\"type\":\"message_stop\"}\n\n"
    stop_reason
;;

let openai_response text =
  Printf.sprintf
    {|{"id":"chatcmpl-1","object":"chat.completion","model":"gpt-4","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}|}
    text
;;

let openai_mlx_vlm_response text =
  Printf.sprintf
    {|{"id":"chatcmpl-mlx-1","object":"chat.completion","model":"gpt-4","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"input_tokens":11,"output_tokens":5,"prompt_tps":21.55,"generation_tps":81.56},"peak_memory":52.66}|}
    text
;;

let openai_responses_tool_call_response () =
  {|{"id":"resp-1","model":"gpt-5.5","status":"completed","output":[
      {"id":"rs-1","type":"reasoning","summary":[{"type":"summary_text","text":"Need a lookup."}]},
      {"id":"fc-1","type":"function_call","call_id":"call_lookup","name":"lookup","arguments":"{\"q\":\"weather\"}"}
    ],
    "usage":{"input_tokens":12,"output_tokens":8,"output_tokens_details":{"reasoning_tokens":3}}}|}
;;

let ollama_tool_call_response () =
  {|{"model":"dashscope-3:8b","done":true,"done_reason":"tool_calls",
     "message":{"role":"assistant","content":"",
       "tool_calls":[
         {"function":{"index":0,"name":"get_temperature","arguments":{"city":"New York"}}},
         {"function":{"index":1,"name":"get_conditions","arguments":{"city":"London"}}}
       ]}}|}
;;

let fresh_port () =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt s Unix.SO_REUSEADDR true;
  Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname s with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "not inet"
  in
  Unix.close s;
  port
;;

let start_mock_server
      ~sw
      ~net
      ?(status = `OK)
      ?(delay_sec = 0.0)
      ?clock
      ?capture_body
      ?capture_path
      ?on_request
      response_body
  =
  let port = fresh_port () in
  let handler _conn req body =
    let request_body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    (match capture_body with
     | Some seen -> seen := Some request_body
     | None -> ());
    (match capture_path with
     | Some seen -> seen := Some (Cohttp.Request.uri req |> Uri.path)
     | None -> ());
    (match on_request with
     | Some f -> f ()
     | None -> ());
    (match clock with
     | Some clk when delay_sec > 0.0 -> Eio.Time.sleep clk delay_sec
     | _ -> ());
    Cohttp_eio.Server.respond_string ~status ~body:response_body ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

let start_header_capture_server ~sw ~net ~seen response_body =
  let port = fresh_port () in
  let handler _conn req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let headers = Cohttp.Request.headers req in
    seen
    := Some
         ( Cohttp.Header.get headers "traceparent"
         , Cohttp.Header.get headers "tracestate"
         , Cohttp.Header.get headers "x-custom" );
    Cohttp_eio.Server.respond_string ~status:`OK ~body:response_body ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

(* ── Helper: make Provider_config ────────────────────── *)

let make_config
      ?(kind = Provider_config.Anthropic)
      ?(request_path = "/v1/messages")
      base_url
  =
  Provider_config.make
    ~kind
    ~model_id:"test-model"
    ~base_url
    ~request_path
    ~temperature:0.0
    ~max_tokens:100
    ()
;;

let make_openai_config base_url =
  Provider_config.make
    ~kind:Provider_config.OpenAI_compat
    ~model_id:"gpt-4"
    ~base_url
    ~request_path:"/v1/chat/completions"
    ~temperature:0.0
    ~max_tokens:100
    ()
;;

let make_kimi_config ?request_path base_url =
  Provider_config.make
    ~kind:Provider_config.Kimi
    ~model_id:"kimi-for-coding"
    ~base_url
    ?request_path
    ~system_prompt:"Kimi system"
    ~temperature:0.0
    ~max_tokens:100
    ()
;;

let messages = [ Types.user_msg "hello" ]

let contains_substring ~sub text =
  let sub_len = String.length sub in
  let text_len = String.length text in
  let rec loop idx =
    if idx + sub_len > text_len
    then false
    else if String.sub text idx sub_len = sub
    then true
    else loop (idx + 1)
  in
  sub_len = 0 || loop 0
;;

let mock_transport_response text =
  { Types.id = "transport-response"
  ; model = "transport-model"
  ; stop_reason = Types.EndTurn
  ; content = [ Types.Text text ]
  ; usage = None
  ; telemetry = None
  }
;;

let make_transport response : Llm_transport.t =
  { complete_sync = (fun _ -> { Llm_transport.response; latency_ms = Some 7 })
  ; complete_stream = (fun ?on_telemetry:_ ~on_event:_ _ -> response)
  }
;;

let check_typed_empty_completion expected = function
  | Error
      (Http_client.ProviderFailure
         { kind = Http_client.Empty_completion { stop_reason }; _ }) ->
    check bool "typed stop reason" true (stop_reason = expected)
  | Ok _ -> fail "expected empty completion error, got Ok"
  | Error _ -> fail "expected typed empty completion provider failure"
;;

(* ── complete: success ───────────────────────────────── *)

let test_complete_anthropic_ok () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net (anthropic_response "mock response") in
    let config = make_config url in
    match Complete.complete ~sw ~net:env#net ~config ~messages () with
    | Ok resp ->
      check string "model" "mock" resp.model;
      let text =
        List.filter_map
          (function
            | Types.Text s -> Some s
            | _ -> None)
          resp.content
        |> String.concat ""
      in
      check string "text" "mock response" text;
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok"
  with
  | Exit -> ()
;;

let test_complete_http_rejects_typed_empty_completion () =
  let run expected wire_stop_reason =
    Eio_main.run
    @@ fun env ->
    try
      Eio.Switch.run
      @@ fun sw ->
      let url =
        start_mock_server ~sw ~net:env#net (anthropic_empty_response wire_stop_reason)
      in
      Complete.complete ~sw ~net:env#net ~config:(make_config url) ~messages ()
      |> check_typed_empty_completion expected;
      Eio.Switch.fail sw Exit
    with
    | Exit -> ()
  in
  List.iter
    (fun (expected, wire) -> run expected wire)
    [ Types.EndTurn, "end_turn"; Types.MaxTokens, "max_tokens" ]
;;

let test_complete_stream_http_rejects_typed_empty_completion () =
  let run expected wire_stop_reason =
    Eio_main.run
    @@ fun env ->
    try
      Eio.Switch.run
      @@ fun sw ->
      let url =
        start_mock_server ~sw ~net:env#net (anthropic_empty_sse wire_stop_reason)
      in
      Complete.complete_stream
        ~sw
        ~net:env#net
        ~config:(make_config url)
        ~messages
        ~on_event:(fun _ -> ())
        ()
      |> check_typed_empty_completion expected;
      Eio.Switch.fail sw Exit
    with
    | Exit -> ()
  in
  List.iter
    (fun (expected, wire) -> run expected wire)
    [ Types.EndTurn, "end_turn"; Types.MaxTokens, "max_tokens" ]
;;

(* ── complete: HTTP error ────────────────────────────── *)

let test_complete_http_error () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_mock_server ~sw ~net:env#net ~status:`Bad_request "bad request body"
    in
    let config = make_config url in
    match Complete.complete ~sw ~net:env#net ~config ~messages () with
    | Ok _ -> fail "expected Error"
    | Error (Http_client.HttpError { code; _ }) ->
      check int "status 400" 400 code;
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected HttpError"
  with
  | Exit -> ()
;;

let check_request_body_too_large ~label = function
  | Error
      (Http_client.ProviderFailure
         { kind = Http_client.Request_body_too_large { actual_bytes; limit_bytes }; _ })
    ->
    check int (label ^ " limit") 1 limit_bytes;
    check bool (label ^ " measured serialized bytes") true (actual_bytes > limit_bytes)
  | Ok _ -> failf "%s unexpectedly succeeded" label
  | Error _ -> failf "%s returned the wrong typed error" label
;;

let test_complete_request_body_limit_rejects_before_io () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let request_count = ref 0 in
    let observed_request_count = ref 0 in
    let base_url =
      start_mock_server
        ~sw
        ~net:env#net
        ~on_request:(fun () -> incr request_count)
        (anthropic_response "must not arrive")
    in
    let config =
      Provider_config.make
        ~kind:Provider_config.Anthropic
        ~model_id:"request-body-limit"
        ~base_url
        ~max_tokens:100
        ~max_request_body_bytes:1
        ()
    in
    let request_wire_observer _observation =
      incr observed_request_count;
      Ok ()
    in
    check_request_body_too_large
      ~label:"sync request-body admission"
      (Complete.complete ~sw ~net:env#net ~request_wire_observer ~config ~messages ());
    check_request_body_too_large
      ~label:"stream request-body admission"
      (Complete.complete_stream
         ~sw
         ~net:env#net
         ~request_wire_observer
         ~config
         ~messages
         ~on_event:(fun _ -> ())
         ());
    check int "request-body admission performs no HTTP request" 0 !request_count;
    check int "rejected body produces no serialization evidence" 0 !observed_request_count;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_request_wire_observer_sees_exact_sync_body () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let captured_body = ref None in
    let observed = ref [] in
    let base_url =
      start_mock_server
        ~sw
        ~net:env#net
        ~capture_body:captured_body
        (openai_response "observed")
    in
    let request_wire_observer observation =
      observed := observation :: !observed;
      Ok ()
    in
    (match
       Complete.complete
         ~sw
         ~net:env#net
         ~capture_id:"sync-request-1"
         ~request_wire_observer
         ~config:(make_openai_config base_url)
         ~messages
         ()
     with
     | Error _ -> fail "request observation changed the provider result"
     | Ok _ -> ());
    (match !captured_body, !observed with
     | Some body, [ observation ] ->
       check
         (option string)
         "capture id"
         (Some "sync-request-1")
         observation.Request_wire_observer.capture_id;
       check string "provider" "openai_compat" observation.provider;
       check string "model" "gpt-4" observation.model;
       check string "codec" "openai-chat" observation.http_codec;
       check bool "sync" false observation.stream;
       check int "exact bytes" (String.length body) observation.body_bytes;
       check
         string
         "exact digest"
         Digestif.SHA256.(to_hex (digest_string body))
         observation.body_sha256
     | None, _ -> fail "mock server did not capture the request body"
     | Some _, _ -> fail "request observer was not invoked exactly once");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_stream_rechecks_limit_after_final_wire_injection () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let request_count = ref 0 in
    let base_url =
      start_mock_server
        ~sw
        ~net:env#net
        ~on_request:(fun () -> incr request_count)
        "must not arrive"
    in
    let unlimited = make_openai_config base_url in
    let pre_injection_bytes =
      match
        Complete_common.serialize_http_request
          ~stream:true
          ~config:unlimited
          ~messages
          ~tools:[]
      with
      | Error _ -> fail "fixture serialization failed"
      | Ok (_, body) -> String.length body
    in
    let final_bytes =
      match
        Complete.inspect_serialized_request ~stream:true ~config:unlimited ~messages ()
      with
      | Error _ -> fail "final request inspection failed"
      | Ok observation -> observation.Request_wire_observer.body_bytes
    in
    check
      bool
      "stream injection grows the final body"
      true
      (final_bytes > pre_injection_bytes);
    let config =
      Provider_config.make
        ~kind:Provider_config.OpenAI_compat
        ~model_id:"gpt-4"
        ~base_url
        ~request_path:"/v1/chat/completions"
        ~temperature:0.0
        ~max_tokens:100
        ~max_request_body_bytes:(final_bytes - 1)
        ()
    in
    (match Complete.inspect_serialized_request ~stream:true ~config ~messages () with
     | Error _ -> fail "inspection incorrectly applied the dispatch byte ceiling"
     | Ok observation ->
       check int "inspection exact final bytes" final_bytes observation.body_bytes);
    (match
       Complete.complete_stream
         ~sw
         ~net:env#net
         ~config
         ~messages
         ~on_event:(fun _ -> ())
         ()
     with
     | Error
         (Http_client.ProviderFailure
            { kind = Http_client.Request_body_too_large { actual_bytes; limit_bytes }; _ })
       ->
       check int "declared final limit" (final_bytes - 1) limit_bytes;
       check int "admission exact final bytes" final_bytes actual_bytes
     | Ok _ -> fail "final stream body bypassed the serialized byte limit"
     | Error _ -> fail "final stream body returned the wrong typed rejection");
    check int "no HTTP dispatch" 0 !request_count;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_http_empty_error_body_has_context () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net ~status:`Not_found "" in
    let config =
      Provider_config.make
        ~kind:Provider_config.Anthropic
        ~model_id:"test-model"
        ~base_url:url
        ~request_path:"/v1/messages?api_key=secret"
        ~temperature:0.0
        ~max_tokens:100
        ()
    in
    match Complete.complete ~sw ~net:env#net ~config ~messages () with
    | Ok _ -> fail "expected Error"
    | Error (Http_client.HttpError { code; body; _ }) ->
      check int "status 404" 404 code;
      check
        string
        "diagnostic body"
        (Printf.sprintf
           "empty HTTP 404 response from provider=anthropic model=test-model base_url=%s \
            request_path=/v1/messages url=%s/v1/messages"
           url
           url)
        body;
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected HttpError"
  with
  | Exit -> ()
;;

(* ── complete: Openai compat ─────────────────────────── *)

let test_complete_openai_ok () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net (openai_response "openai reply") in
    let config = make_openai_config url in
    match Complete.complete ~sw ~net:env#net ~config ~messages () with
    | Ok resp ->
      let text =
        List.filter_map
          (function
            | Types.Text s -> Some s
            | _ -> None)
          resp.content
        |> String.concat ""
      in
      check string "text" "openai reply" text;
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok for openai"
  with
  | Exit -> ()
;;

let test_complete_openai_responses_sync_ok () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_mock_server ~sw ~net:env#net (openai_responses_tool_call_response ())
    in
    let config =
      Provider_config.make
        ~kind:Provider_config.OpenAI_compat
        ~model_id:"gpt-5.5"
        ~base_url:url
        ~request_path:"/v1/responses"
        ~temperature:0.0
        ~max_tokens:100
        ()
    in
    match Complete.complete ~sw ~net:env#net ~config ~messages () with
    | Ok resp ->
      check bool "stop tool use" true (resp.stop_reason = Types.StopToolUse);
      (match resp.content with
       | [ Types.Thinking { content; _ }; Types.ToolUse { id; name; input } ] ->
         check string "reasoning" "Need a lookup." content;
         check string "tool id" "call_lookup" id;
         check string "tool name" "lookup" name;
         check
           string
           "tool arg"
           "weather"
           (Yojson.Safe.Util.member "q" input |> Yojson.Safe.Util.to_string)
       | _ -> fail "expected reasoning + tool use");
      (match resp.telemetry with
       | Some telemetry ->
         check (option int) "reasoning tokens" (Some 3) telemetry.reasoning_tokens
       | None -> fail "expected telemetry");
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok for OpenAI Responses sync"
  with
  | Exit -> ()
;;

let test_complete_openai_responses_json_mode_body () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let captured = ref None in
    let url =
      start_mock_server
        ~sw
        ~net:env#net
        ~capture_body:captured
        (openai_responses_tool_call_response ())
    in
    let config =
      Provider_config.make
        ~kind:Provider_config.OpenAI_compat
        ~model_id:"gpt-5.5"
        ~base_url:url
        ~request_path:"/v1/responses"
        ~response_format:Types.JsonMode
        ~temperature:0.0
        ~max_tokens:100
        ()
    in
    (match Complete.complete ~sw ~net:env#net ~config ~messages () with
     | Ok _ -> ()
     | Error _ -> fail "expected Ok for OpenAI Responses JSON mode");
    match !captured with
    | Some body ->
      let json = Yojson.Safe.from_string body in
      check
        string
        "responses text.format"
        "json_object"
        Yojson.Safe.Util.(
          json |> member "text" |> member "format" |> member "type" |> to_string);
      Eio.Switch.fail sw Exit
    | None -> fail "server did not capture request body"
  with
  | Exit -> ()
;;

let start_responses_sse_server ~sw ~net response_body =
  let port = fresh_port () in
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let headers = Cohttp.Header.of_list [ "content-type", "text/event-stream" ] in
    Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body:response_body ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

let openai_responses_sse_tool_call_response () =
  "event: response.created\n\
   data: \
   {\"type\":\"response.created\",\"response\":{\"id\":\"resp-stream-1\",\"model\":\"gpt-5.5\",\"status\":\"in_progress\",\"usage\":null}}\n\n\
   event: response.reasoning_summary_text.delta\n\
   data: \
   {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"delta\":\"Need \
   a lookup.\"}\n\n\
   event: response.output_item.added\n\
   data: \
   {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_lookup\",\"name\":\"lookup\",\"arguments\":\"\"}}\n\n\
   event: response.function_call_arguments.delta\n\
   data: \
   {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"item_id\":\"fc_1\",\"delta\":\"{\\\"q\\\":\\\"weather\\\"}\"}\n\n\
   event: response.completed\n\
   data: \
   {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-stream-1\",\"model\":\"gpt-5.5\",\"status\":\"completed\",\"output\":[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Need \
   a \
   lookup.\"}],\"encrypted_content\":\"enc_reasoning_1\"},{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_lookup\",\"name\":\"lookup\",\"arguments\":\"{\\\"q\\\":\\\"weather\\\"}\"}],\"usage\":{\"input_tokens\":12,\"output_tokens\":8,\"input_tokens_details\":{\"cached_tokens\":2}}}}\n\n"
;;

let test_complete_stream_openai_responses_ok () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_responses_sse_server
        ~sw
        ~net:env#net
        (openai_responses_sse_tool_call_response ())
    in
    let config =
      Provider_config.make
        ~kind:Provider_config.OpenAI_compat
        ~model_id:"gpt-5.5"
        ~base_url:url
        ~request_path:"/v1/responses"
        ~temperature:0.0
        ~max_tokens:100
        ()
    in
    let events = ref [] in
    match
      Complete.complete_stream
        ~sw
        ~net:env#net
        ~config
        ~messages
        ~on_event:(fun evt -> events := evt :: !events)
        ()
    with
    | Ok resp ->
      check string "stream id" "resp-stream-1" resp.id;
      check bool "stop tool use" true (resp.stop_reason = Types.StopToolUse);
      check bool "events emitted" true (List.length !events >= 5);
      (match resp.content with
       | [ Types.RedactedThinking raw_reasoning; Types.ToolUse { id; name; input } ] ->
         let reasoning = Yojson.Safe.from_string raw_reasoning in
         check
           string
           "reasoning type"
           "reasoning"
           (Yojson.Safe.Util.member "type" reasoning |> Yojson.Safe.Util.to_string);
         check
           string
           "encrypted reasoning"
           "enc_reasoning_1"
           (Yojson.Safe.Util.member "encrypted_content" reasoning
            |> Yojson.Safe.Util.to_string);
         check string "tool id" "call_lookup" id;
         check string "tool name" "lookup" name;
         check
           string
           "tool arg"
           "weather"
           (Yojson.Safe.Util.member "q" input |> Yojson.Safe.Util.to_string)
       | _ -> fail "expected redacted reasoning + tool use");
      (match resp.usage with
       | Some usage ->
         check int "input tokens" 12 usage.input_tokens;
         check int "output tokens" 8 usage.output_tokens;
         check int "cached tokens" 2 usage.cache_read_input_tokens
       | None -> fail "expected usage");
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok for Responses streaming"
  with
  | Exit -> ()
;;

let test_complete_trace_context_headers () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let seen = ref None in
    let url =
      start_header_capture_server ~sw ~net:env#net ~seen (anthropic_response "ok")
    in
    let config =
      { (make_config url) with
        Provider_config.headers = [ "traceparent", "stale"; "x-custom", "yes" ]
      }
    in
    let trace_context =
      [ "traceparent", "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01"
      ; "tracestate", "vendor=value"
      ]
    in
    (match Complete.complete ~sw ~net:env#net ~config ~messages ~trace_context () with
     | Ok _ -> ()
     | Error _ -> fail "expected Ok");
    match !seen with
    | Some (traceparent, tracestate, custom) ->
      check
        (option string)
        "traceparent"
        (Some "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")
        traceparent;
      check (option string) "tracestate" (Some "vendor=value") tracestate;
      check (option string) "custom header preserved" (Some "yes") custom;
      Eio.Switch.fail sw Exit
    | None -> fail "server did not capture headers"
  with
  | Exit -> ()
;;

let test_complete_openai_mlx_vlm_telemetry () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_mock_server
        ~sw
        ~net:env#net
        ~delay_sec:0.02
        ~clock
        (openai_mlx_vlm_response "mlx reply")
    in
    let config = make_openai_config url in
    match Complete.complete ~sw ~net:env#net ~config ~messages () with
    | Ok resp ->
      let text =
        List.filter_map
          (function
            | Types.Text s -> Some s
            | _ -> None)
          resp.content
        |> String.concat ""
      in
      check string "text" "mlx reply" text;
      (match resp.usage with
       | Some usage ->
         check int "input_tokens" 11 usage.input_tokens;
         check int "output_tokens" 5 usage.output_tokens
       | None -> fail "expected usage");
      (match resp.telemetry with
       | Some t ->
         check
           bool
           "latency patched"
           true
           (Option.value ~default:0 t.request_latency_ms > 0);
         check (option string) "canonical model id" (Some "gpt-4") t.canonical_model_id;
         check (option (float 0.001)) "peak memory" (Some 52.66) t.peak_memory_gb;
         (match t.timings with
          | Some timings ->
            check
              (option (float 0.001))
              "prompt tps"
              (Some 21.55)
              timings.prompt_per_second;
            check
              (option (float 0.001))
              "generation tps"
              (Some 81.56)
              timings.predicted_per_second
          | None -> fail "expected timings")
       | None -> fail "expected telemetry");
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok for mlx-vlm openai compat"
  with
  | Exit -> ()
;;

let test_complete_sync_latency_uses_injected_clock () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock 10.0;
    let url =
      start_mock_server
        ~sw
        ~net:env#net
        ~on_request:(fun () -> Eio_mock.Clock.set_time clock 11.25)
        (anthropic_response "clocked")
    in
    let config = make_config url in
    match Complete.complete ~sw ~net:env#net ~clock ~config ~messages () with
    | Ok resp ->
      (match resp.telemetry with
       | Some telemetry ->
         check
           (option int)
           "latency from injected clock"
           (Some 1250)
           telemetry.request_latency_ms
       | None -> fail "expected telemetry");
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok"
  with
  | Exit -> ()
;;

let test_latency_counter_clamps_negative_injected_clock () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 10.0;
  let counter = Complete_common.start_latency_counter ~clock () in
  Eio_mock.Clock.set_time clock 9.0;
  check (option int) "latency clamped" (Some 0) (Complete_common.latency_ms_int counter)
;;

(* ── complete with cache ─────────────────────────────── *)

let test_complete_cache_store_and_hit () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net (anthropic_response "cached") in
    let config = make_config url in
    let store : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 4 in
    let cache : Cache.t =
      { get = (fun ~key -> Hashtbl.find_opt store key)
      ; set = (fun ~key ~ttl_sec:_ value -> Hashtbl.replace store key value)
      }
    in
    (* First call — cache miss, HTTP hit *)
    (match Complete.complete ~sw ~net:env#net ~config ~messages ~cache () with
     | Ok _ -> check bool "stored in cache" true (Hashtbl.length store > 0)
     | Error _ -> fail "expected Ok first call");
    (* Second call — cache hit, no HTTP *)
    match Complete.complete ~sw ~net:env#net ~config ~messages ~cache () with
    | Ok resp ->
      let text =
        List.filter_map
          (function
            | Types.Text s -> Some s
            | _ -> None)
          resp.content
        |> String.concat ""
      in
      check string "from cache" "cached" text;
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok second call"
  with
  | Exit -> ()
;;

(* ── complete with metrics ───────────────────────────── *)

let test_complete_metrics () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net (anthropic_response "metrics test") in
    let config = make_config url in
    let hit_count = ref 0 in
    let miss_count = ref 0 in
    let start_count = ref 0 in
    let end_count = ref 0 in
    let status_calls = ref [] in
    let metrics : Metrics.t =
      { Metrics.noop with
        on_cache_hit = (fun ~model_id:_ -> incr hit_count)
      ; on_cache_miss = (fun ~model_id:_ -> incr miss_count)
      ; on_request_start = (fun ~model_id:_ -> incr start_count)
      ; on_request_end = (fun ~model_id:_ ~latency_ms:_ -> incr end_count)
      ; on_error = (fun ~model_id:_ ~error:_ -> ())
      ; on_http_status =
          (fun ~provider ~model_id ~status ->
            status_calls := (provider, model_id, status) :: !status_calls)
      }
    in
    (* No cache provided → on_cache_miss not called *)
    match Complete.complete ~sw ~net:env#net ~config ~messages ~metrics () with
    | Ok _ ->
      check int "no cache = no miss" 0 !miss_count;
      check int "start" 1 !start_count;
      check int "end" 1 !end_count;
      check int "no hit" 0 !hit_count;
      (* on_http_status fired once with the actual 200 code *)
      check int "status callback count" 1 (List.length !status_calls);
      (match !status_calls with
       | [ (_, _, code) ] -> check int "status code" 200 code
       | _ -> fail "expected exactly one status call");
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok"
  with
  | Exit -> ()
;;

let test_complete_tool_call_metrics () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net (ollama_tool_call_response ()) in
    let config =
      Provider_config.make
        ~kind:Provider_config.Ollama
        ~model_id:"dashscope-3:8b"
        ~base_url:url
        ~request_path:"/api/chat"
        ~temperature:0.0
        ~max_tokens:100
        ()
    in
    let tool_calls = ref [] in
    let metrics : Metrics.t =
      { Metrics.noop with
        on_tool_calls =
          (fun ~provider ~model_id ~count ->
            tool_calls := (provider, model_id, count) :: !tool_calls)
      }
    in
    match Complete.complete ~sw ~net:env#net ~config ~messages ~metrics () with
    | Ok resp ->
      check bool "stop tool use" true (resp.stop_reason = Types.StopToolUse);
      (match !tool_calls with
       | [ (provider, model_id, count) ] ->
         check string "provider" "ollama" provider;
         check string "model" "dashscope-3:8b" model_id;
         check int "tool call count" 2 count
       | _ -> fail "expected one tool-call metric");
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok"
  with
  | Exit -> ()
;;

(* ── complete: 401 non-retryable ─────────────────────── *)

let test_complete_non_retryable () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net ~status:`Unauthorized "unauthorized" in
    let config = make_config url in
    match Complete.complete ~sw ~net:env#net ~config ~messages () with
    | Ok _ -> fail "expected Error"
    | Error (Http_client.HttpError { code; _ }) ->
      check int "401" 401 code;
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected HttpError"
  with
  | Exit -> ()
;;

(* ── complete: error metrics ─────────────────────────── *)

let test_complete_error_metrics () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net ~status:`Bad_request "bad" in
    let config = make_config url in
    let error_count = ref 0 in
    let status_calls = ref [] in
    let metrics : Metrics.t =
      { Metrics.noop with
        on_cache_hit = (fun ~model_id:_ -> ())
      ; on_cache_miss = (fun ~model_id:_ -> ())
      ; on_request_start = (fun ~model_id:_ -> ())
      ; on_request_end = (fun ~model_id:_ ~latency_ms:_ -> ())
      ; on_error = (fun ~model_id:_ ~error:_ -> incr error_count)
      ; on_http_status =
          (fun ~provider ~model_id ~status ->
            status_calls := (provider, model_id, status) :: !status_calls)
      }
    in
    match Complete.complete ~sw ~net:env#net ~config ~messages ~metrics () with
    | Ok _ -> fail "expected Error"
    | Error _ ->
      check int "error callback" 1 !error_count;
      (* 400 HTTP response must also emit on_http_status before error fires *)
      check int "status callback count" 1 (List.length !status_calls);
      (match !status_calls with
       | [ (_, _, 400) ] -> ()
       | [ (_, _, code) ] -> fail (Printf.sprintf "expected 400, got %d" code)
       | _ -> fail "expected exactly one status call");
      Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_stream_http_error_metrics_uses_fallback () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net ~status:`Bad_request "bad stream" in
    let config = make_config url in
    let status_calls = ref [] in
    let metrics : Metrics.t =
      { Metrics.noop with
        on_http_status =
          (fun ~provider ~model_id ~status ->
            status_calls := (provider, model_id, status) :: !status_calls)
      }
    in
    (match
       Complete_stream.complete_stream_http
         ~sw
         ~net:env#net
         ~metrics
         ~config
         ~messages
         ~tools:[]
         ~on_event:(fun _ -> ())
         ()
     with
     | Error (Http_client.HttpError { code = 400; _ }) -> ()
     | Error _ -> fail "expected streaming HTTP 400"
     | Ok _ -> fail "expected streaming HTTP error");
    (match !status_calls with
     | [ ("anthropic", "test-model", 400) ] -> ()
     | [ (_, _, status) ] -> fail (Printf.sprintf "expected 400, got %d" status)
     | _ -> fail "expected exactly one direct streaming status call");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_transport_http_metrics_ok () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let config = make_openai_config "http://unused.test" in
    let status_calls = ref [] in
    let metrics : Metrics.t =
      { Metrics.noop with
        on_http_status =
          (fun ~provider ~model_id ~status ->
            status_calls := (provider, model_id, status) :: !status_calls)
      }
    in
    let transport = make_transport (Ok (mock_transport_response "transport ok")) in
    match Complete.complete ~sw ~net:env#net ~transport ~config ~messages ~metrics () with
    | Ok _ ->
      (match !status_calls with
       | [ ("openai_compat", "gpt-4", 200) ] -> Eio.Switch.fail sw Exit
       | [ (_, _, code) ] -> fail (Printf.sprintf "expected 200, got %d" code)
       | _ -> fail "expected exactly one transport status call")
    | Error _ -> fail "expected Ok"
  with
  | Exit -> ()
;;

let test_complete_transport_http_metrics_error () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let config = make_openai_config "http://unused.test" in
    let status_calls = ref [] in
    let metrics : Metrics.t =
      { Metrics.noop with
        on_http_status =
          (fun ~provider ~model_id ~status ->
            status_calls := (provider, model_id, status) :: !status_calls)
      }
    in
    let transport =
      make_transport
        (Error
           (Http_client.HttpError
              { code = 429; body = "rate limited"; retry_after_header = None }))
    in
    match Complete.complete ~sw ~net:env#net ~transport ~config ~messages ~metrics () with
    | Ok _ -> fail "expected Error"
    | Error (Http_client.HttpError { code; _ }) ->
      check int "status 429" 429 code;
      (match !status_calls with
       | [ ("openai_compat", "gpt-4", 429) ] -> Eio.Switch.fail sw Exit
       | [ (_, _, seen) ] -> fail (Printf.sprintf "expected 429, got %d" seen)
       | _ -> fail "expected exactly one transport status call")
    | Error _ -> fail "expected HttpError"
  with
  | Exit -> ()
;;

let test_complete_transport_mock_emits_status () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let config =
      Provider_config.make
        ~kind:Provider_config.Anthropic
        ~model_id:"codex-mini"
        ~base_url:""
        ()
    in
    let hits = ref 0 in
    let metrics : Metrics.t =
      { Metrics.noop with
        on_http_status = (fun ~provider:_ ~model_id:_ ~status:_ -> incr hits)
      }
    in
    let transport = make_transport (Ok (mock_transport_response "cli ok")) in
    match Complete.complete ~sw ~net:env#net ~transport ~config ~messages ~metrics () with
    | Ok _ ->
      check int "mock transport emits status" 1 !hits;
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok"
  with
  | Exit -> ()
;;

(* ── Global metrics registry ──────────────────────────── *)

let test_metrics_global_default_is_noop () =
  let g = Metrics.get_global () in
  (* Default state: the noop callbacks should not raise and should be
     distinguishable by reference from a custom instance below. *)
  g.on_cache_hit ~model_id:"m";
  g.on_request_end ~model_id:"m" ~latency_ms:(Some 1);
  g.on_http_status ~provider:"ollama" ~model_id:"m" ~status:200;
  (* No side effects observable. *)
  check bool "default global accepts noop calls" true true
;;

let test_metrics_global_set_and_get () =
  let hits = ref 0 in
  let previous = Metrics.get_global () in
  (* Fun.protect guarantees the global is restored even if a check
     assertion raises inside the body, preventing cross-test pollution
     through the shared process-wide sink. *)
  Fun.protect
    ~finally:(fun () -> Metrics.set_global previous)
    (fun () ->
       let custom : Metrics.t =
         { Metrics.noop with
           on_http_status = (fun ~provider:_ ~model_id:_ ~status:_ -> incr hits)
         }
       in
       Metrics.set_global custom;
       let g = Metrics.get_global () in
       g.on_http_status ~provider:"ollama" ~model_id:"m" ~status:429;
       g.on_http_status ~provider:"glm" ~model_id:"m" ~status:429;
       check int "global metric fired twice" 2 !hits)
;;

let test_metrics_global_used_when_no_per_call_metrics () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_mock_server ~sw ~net:env#net (anthropic_response "global metrics test")
    in
    let config = make_config url in
    let status_calls = ref [] in
    let previous = Metrics.get_global () in
    let bridge : Metrics.t =
      { Metrics.noop with
        on_http_status =
          (fun ~provider ~model_id ~status ->
            status_calls := (provider, model_id, status) :: !status_calls)
      }
    in
    Metrics.set_global bridge;
    Fun.protect
      ~finally:(fun () -> Metrics.set_global previous)
      (fun () ->
         (* Deliberately do NOT pass ~metrics — global should take effect. *)
         match Complete.complete ~sw ~net:env#net ~config ~messages () with
         | Ok _ ->
           check int "global on_http_status fired once" 1 (List.length !status_calls);
           Eio.Switch.fail sw Exit
         | Error _ -> fail "expected Ok")
  with
  | Exit -> ()
;;

(* ── complete_stream: SSE ─────────────────────────────── *)

let anthropic_sse_response text =
  Printf.sprintf
    "event: message_start\n\
     data: \
     {\"type\":\"message_start\",\"message\":{\"id\":\"msg-1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"mock\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n\n\
     event: content_block_start\n\
     data: \
     {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n\
     event: content_block_delta\n\
     data: \
     {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"%s\"}}\n\n\
     event: content_block_stop\n\
     data: {\"type\":\"content_block_stop\",\"index\":0}\n\n\
     event: message_delta\n\
     data: \
     {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n\
     event: message_stop\n\
     data: {\"type\":\"message_stop\"}\n\n"
    text
;;

let anthropic_sse_thinking_signature_tool_response =
  "event: message_start\n\
   data: \
   {\"type\":\"message_start\",\"message\":{\"id\":\"msg-1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"mock\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n\n\
   event: content_block_start\n\
   data: \
   {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}\n\n\
   event: content_block_delta\n\
   data: \
   {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Need \
   a lookup.\"}}\n\n\
   event: content_block_delta\n\
   data: \
   {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig_opaque\"}}\n\n\
   event: content_block_stop\n\
   data: {\"type\":\"content_block_stop\",\"index\":0}\n\n\
   event: content_block_start\n\
   data: \
   {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"lookup\",\"input\":{}}}\n\n\
   event: content_block_delta\n\
   data: \
   {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"q\\\":\\\"weather\\\"}\"}}\n\n\
   event: content_block_stop\n\
   data: {\"type\":\"content_block_stop\",\"index\":1}\n\n\
   event: message_delta\n\
   data: \
   {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":5}}\n\n\
   event: message_stop\n\
   data: {\"type\":\"message_stop\"}\n\n"
;;

let anthropic_sse_frame_message_start =
  "event: message_start\n\
   data: \
   {\"type\":\"message_start\",\"message\":{\"id\":\"msg-1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"mock\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n\n"
;;

let anthropic_sse_frame_content_block_start =
  "event: content_block_start\n\
   data: \
   {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
;;

let anthropic_sse_frame_delta text =
  Printf.sprintf
    "event: content_block_delta\n\
     data: \
     {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"%s\"}}\n\n"
    text
;;

let anthropic_sse_frame_stop =
  "event: content_block_stop\n\
   data: {\"type\":\"content_block_stop\",\"index\":0}\n\n\
   event: message_delta\n\
   data: \
   {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n\
   event: message_stop\n\
   data: {\"type\":\"message_stop\"}\n\n"
;;

let anthropic_sse_frame_thinking_block_start =
  "event: content_block_start\n\
   data: \
   {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n"
;;

let anthropic_sse_frame_thinking_delta text =
  Printf.sprintf
    "event: content_block_delta\n\
     data: \
     {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"%s\"}}\n\n"
    text
;;

(* Thinking-only prelude (block 0) followed by a deliverable text answer
   (block 1). Used by the mock-clock cutoff tests: the cutoff must fire
   while still inside the block-0 thinking deltas, and the trailing text
   answer lets the no-advance control finalize [Ok]. *)
let anthropic_thinking_then_answer_frames ~frame_gap_s =
  [ 0.0, anthropic_sse_frame_message_start
  ; frame_gap_s, anthropic_sse_frame_thinking_block_start
  ; frame_gap_s, anthropic_sse_frame_thinking_delta "t1"
  ; frame_gap_s, anthropic_sse_frame_thinking_delta "t2"
  ; frame_gap_s, anthropic_sse_frame_thinking_delta "t3"
  ; ( frame_gap_s
    , "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
    )
  ; ( frame_gap_s
    , "event: content_block_start\n\
       data: \
       {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
    )
  ; ( frame_gap_s
    , "event: content_block_delta\n\
       data: \
       {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"answer\"}}\n\n"
    )
  ; ( frame_gap_s
    , "event: content_block_stop\n\
       data: {\"type\":\"content_block_stop\",\"index\":1}\n\n\
       event: message_delta\n\
       data: \
       {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n\
       event: message_stop\n\
       data: {\"type\":\"message_stop\"}\n\n" )
  ]
;;

let read_http_request flow =
  let reader = Eio.Buf_read.of_flow flow ~max_size:8192 in
  let _request_line = Eio.Buf_read.line reader in
  let rec read_headers content_length =
    match Eio.Buf_read.line reader with
    | "" -> content_length
    | line ->
      let lower = String.lowercase_ascii line in
      let content_length =
        if String.starts_with ~prefix:"content-length:" lower
        then (
          let value = String.sub line 15 (String.length line - 15) |> String.trim in
          match int_of_string_opt value with
          | Some n -> n
          | None -> content_length)
        else content_length
      in
      read_headers content_length
    | exception End_of_file -> content_length
  in
  let content_length = read_headers 0 in
  if content_length > 0 then ignore (Eio.Buf_read.take content_length reader : string)
;;

let start_raw_sync_server ~sw ~net ~clock ~body_delay_sec response_body =
  let port = fresh_port () in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Net.accept_fork
      ~sw
      socket
      ~on_error:(fun _ -> ())
      (fun flow _addr ->
         try
           read_http_request flow;
           Eio.Flow.copy_string
             (Printf.sprintf
                "HTTP/1.1 200 OK\r\n\
                 Content-Type: application/json\r\n\
                 Content-Length: %d\r\n\
                 Connection: close\r\n\
                 \r\n"
                (String.length response_body))
             flow;
           Eio.Time.sleep clock body_delay_sec;
           Eio.Flow.copy_string response_body flow
         with
         | _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

let start_raw_sse_server ~sw ~net ~clock delayed_frames =
  let port = fresh_port () in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Net.accept_fork
      ~sw
      socket
      ~on_error:(fun _ -> ())
      (fun flow _addr ->
         try
           read_http_request flow;
           Eio.Flow.copy_string
             "HTTP/1.1 200 OK\r\n\
              Content-Type: text/event-stream\r\n\
              Connection: close\r\n\
              \r\n"
             flow;
           List.iter
             (fun (delay_sec, frame) ->
                if delay_sec > 0.0 then Eio.Time.sleep clock delay_sec;
                Eio.Flow.copy_string frame flow)
             delayed_frames
         with
         | _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

(* Advance beyond both removed provider-kind defaults (60s cloud, 600s
   Ollama) while the client is awaiting its first protocol line. [Connected]
   proves the HTTP body callback has started before the controller jumps the
   mock clock and releases the server body. *)
let removed_provider_idle_defaults_upper_bound_s = 601.0

let start_clock_jump_stream_server ~sw ~net ~release_body ~content_type body =
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> invalid_arg "expected a TCP listening socket"
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Net.accept_fork
      ~sw
      socket
      ~on_error:(fun _ -> ())
      (fun flow _addr ->
         try
           read_http_request flow;
           Eio.Flow.copy_string
             (Printf.sprintf
                "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nConnection: close\r\n\r\n"
                content_type)
             flow;
           Eio.Promise.await release_body;
           Eio.Flow.copy_string body flow
         with
         | _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

let start_sse_server
      ~sw
      ~net
      ?capture_body
      ?capture_path
      ?(content_type = "text/event-stream")
      response_body
  =
  let port = fresh_port () in
  let handler _conn req body =
    let request_body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    (match capture_body with
     | Some seen -> seen := Some request_body
     | None -> ());
    (match capture_path with
     | Some seen -> seen := Some (Cohttp.Request.uri req |> Uri.path)
     | None -> ());
    let headers = Cohttp.Header.of_list [ "content-type", content_type ] in
    Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body:response_body ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

let test_complete_injected_http_transport_preserves_stream_status_metrics () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_sse_server ~sw ~net:env#net (anthropic_sse_response "streamed") in
    let transport = Complete.make_http_transport ~sw ~net:env#net () in
    let status_calls = ref [] in
    let metrics : Metrics.t =
      { Metrics.noop with
        on_http_status =
          (fun ~provider ~model_id ~status ->
            status_calls := (provider, model_id, status) :: !status_calls)
      }
    in
    (match
       Complete.complete_stream
         ~sw
         ~net:env#net
         ~transport
         ~config:(make_config url)
         ~messages
         ~metrics
         ~on_event:(fun _ -> ())
         ()
     with
     | Ok _ -> ()
     | Error _ -> fail "expected injected HTTP transport stream to succeed");
    check
      (list (triple string string int))
      "injected HTTP transport preserves response status"
      [ "anthropic", "test-model", 200 ]
      (List.rev !status_calls);
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let text_of_response (resp : Types.api_response) =
  List.filter_map
    (function
      | Types.Text s -> Some s
      | _ -> None)
    resp.content
  |> String.concat ""
;;

let check_kimi_anthropic_request ~expected_path ~stream ~captured_body ~captured_path =
  (match captured_path with
   | Some path -> check string "Kimi request path" expected_path path
   | None -> fail "server did not capture Kimi request path");
  match captured_body with
  | Some body ->
    let json = Yojson.Safe.from_string body in
    let open Yojson.Safe.Util in
    check string "Kimi model" "kimi-for-coding" (json |> member "model" |> to_string);
    check
      string
      "Anthropic top-level system"
      "Kimi system"
      (json |> member "system" |> to_string);
    check bool "stream flag" stream (json |> member "stream" |> to_bool);
    (match json |> member "stream_options" with
     | `Null -> ()
     | _ -> fail "Anthropic Messages request must not carry OpenAI stream_options")
  | None -> fail "server did not capture Kimi request body"
;;

let test_complete_kimi_path_override_stays_anthropic_codec () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let captured_body = ref None in
    let captured_path = ref None in
    let url =
      start_mock_server
        ~sw
        ~net:env#net
        ~capture_body:captured_body
        ~capture_path:captured_path
        (anthropic_response "kimi sync")
    in
    let request_path = "/v1/chat/completions" in
    (match
       Complete.complete
         ~sw
         ~net:env#net
         ~config:(make_kimi_config ~request_path url)
         ~messages
         ()
     with
     | Ok resp -> check string "Kimi sync text" "kimi sync" (text_of_response resp)
     | Error _ -> fail "expected Kimi sync Anthropic Messages response to parse");
    check_kimi_anthropic_request
      ~expected_path:request_path
      ~stream:false
      ~captured_body:!captured_body
      ~captured_path:!captured_path;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_kimi_anthropic_stream_codec () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let captured_body = ref None in
    let captured_path = ref None in
    let url =
      start_sse_server
        ~sw
        ~net:env#net
        ~capture_body:captured_body
        ~capture_path:captured_path
        (anthropic_sse_response "kimi stream")
    in
    (match
       Complete.complete_stream
         ~sw
         ~net:env#net
         ~config:(make_kimi_config url)
         ~messages
         ~on_event:(fun _ -> ())
         ()
     with
     | Ok resp -> check string "Kimi stream text" "kimi stream" (text_of_response resp)
     | Error _ -> fail "expected Kimi Anthropic Messages SSE response to parse");
    check_kimi_anthropic_request
      ~expected_path:"/v1/messages"
      ~stream:true
      ~captured_body:!captured_body
      ~captured_path:!captured_path;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_request_wire_observer_sees_exact_stream_body () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let captured_body = ref None in
    let observed = ref [] in
    let url =
      start_sse_server
        ~sw
        ~net:env#net
        ~capture_body:captured_body
        (anthropic_sse_response "observed stream")
    in
    let request_wire_observer observation =
      observed := observation :: !observed;
      Ok ()
    in
    (match
       Complete.complete_stream
         ~sw
         ~net:env#net
         ~capture_id:"stream-request-1"
         ~request_wire_observer
         ~config:(make_kimi_config url)
         ~messages
         ~on_event:(fun _ -> ())
         ()
     with
     | Ok resp -> check string "stream response" "observed stream" (text_of_response resp)
     | Error _ -> fail "request observation changed the streaming provider result");
    (match !captured_body, !observed with
     | Some body, [ observation ] ->
       check
         (option string)
         "capture id"
         (Some "stream-request-1")
         observation.Request_wire_observer.capture_id;
       check string "provider" "kimi" observation.provider;
       check string "model" "kimi-for-coding" observation.model;
       check string "codec" "anthropic-messages" observation.http_codec;
       check bool "stream" true observation.stream;
       check int "exact bytes" (String.length body) observation.body_bytes;
       check
         string
         "exact digest"
         Digestif.SHA256.(to_hex (digest_string body))
         observation.body_sha256
     | None, _ -> fail "SSE server did not capture the request body"
     | Some _, _ -> fail "stream request observer was not invoked exactly once");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_openai_compatible_kimi_uses_openai_codec () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let captured_body = ref None in
    let captured_path = ref None in
    let url =
      start_mock_server
        ~sw
        ~net:env#net
        ~capture_body:captured_body
        ~capture_path:captured_path
        (openai_response "kimi openai")
    in
    let config =
      Provider_config.make
        ~kind:Provider_config.OpenAI_compat
        ~model_id:"kimi-for-coding"
        ~base_url:url
        ~request_path:"/v1/chat/completions"
        ~system_prompt:"Kimi OpenAI system"
        ~max_tokens:100
        ()
    in
    (match Complete.complete ~sw ~net:env#net ~config ~messages () with
     | Ok resp -> check string "Kimi OpenAI text" "kimi openai" (text_of_response resp)
     | Error _ -> fail "expected OpenAI-compatible Kimi response to parse");
    (match !captured_path with
     | Some path -> check string "Kimi OpenAI path" "/v1/chat/completions" path
     | None -> fail "server did not capture OpenAI-compatible Kimi path");
    (match !captured_body with
     | Some body ->
       let json = Yojson.Safe.from_string body in
       let open Yojson.Safe.Util in
       check bool "no Anthropic top-level system" true (json |> member "system" = `Null);
       (match json |> member "messages" |> to_list with
        | first_message :: _ ->
          check
            string
            "OpenAI system message"
            "system"
            (first_message |> member "role" |> to_string)
        | [] -> fail "OpenAI-compatible request omitted messages")
     | None -> fail "server did not capture OpenAI-compatible Kimi body");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_stream_ok () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_sse_server ~sw ~net:env#net (anthropic_sse_response "streamed text")
    in
    let config = make_config url in
    let events = ref [] in
    let on_event evt = events := evt :: !events in
    match Complete.complete_stream ~sw ~net:env#net ~config ~messages ~on_event () with
    | Ok resp ->
      let text =
        List.filter_map
          (function
            | Types.Text s -> Some s
            | _ -> None)
          resp.content
        |> String.concat ""
      in
      check string "text" "streamed text" text;
      check bool "events received" true (List.length !events > 0);
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok"
  with
  | Exit -> ()
;;

let test_complete_stream_preserves_thinking_signature () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_sse_server ~sw ~net:env#net anthropic_sse_thinking_signature_tool_response
    in
    let config = make_config url in
    match
      Complete.complete_stream
        ~sw
        ~net:env#net
        ~config
        ~messages
        ~on_event:(fun _ -> ())
        ()
    with
    | Ok resp ->
      check bool "stop tool use" true (resp.stop_reason = Types.StopToolUse);
      (match resp.content with
       | [ Types.Thinking { signature; content }; Types.ToolUse { id; name; input } ] ->
         check bool "thinking signature" true (signature = Some "sig_opaque");
         check string "thinking content" "Need a lookup." content;
         check string "tool id" "tu_1" id;
         check string "tool name" "lookup" name;
         check
           string
           "tool arg"
           "weather"
           (Yojson.Safe.Util.member "q" input |> Yojson.Safe.Util.to_string)
       | _ -> fail "expected thinking + tool use");
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok"
  with
  | Exit -> ()
;;

let test_complete_stream_malformed_payload_is_wire_error () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_sse_server ~sw ~net:env#net "data: {not-json\n\n" in
    let status_calls = ref [] in
    let metrics : Metrics.t =
      { Metrics.noop with
        on_http_status =
          (fun ~provider ~model_id ~status ->
            status_calls := (provider, model_id, status) :: !status_calls)
      }
    in
    (match
       Complete.complete_stream
         ~sw
         ~net:env#net
         ~config:(make_config url)
         ~messages
         ~metrics
         ~on_event:(fun _ -> ())
         ()
     with
     | Error
         (Http_client.ProviderFailure
            { kind =
                Http_client.Provider_wire_error
                  { format = Http_client.Sse; kind = Http_client.Malformed_payload }
            ; _
            }) -> ()
     | Error _ -> fail "expected typed malformed SSE payload"
     | Ok _ -> fail "malformed SSE payload must not complete successfully");
    (match !status_calls with
     | [ ("anthropic", "test-model", 200) ] -> ()
     | [ (_, _, status) ] -> fail (Printf.sprintf "expected 200, got %d" status)
     | _ -> fail "expected exactly one status call for malformed SSE");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* A structurally valid provider error envelope is NOT a wire failure. The
   summary used to say [sse_wire_error] while the returned error said
   [Provider_reported_error] — the two halves of the same stream disagreed. *)
let test_complete_provider_error_envelope_is_not_a_wire_error () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_sse_server
        ~sw
        ~net:env#net
        "data: {\"error\":{\"type\":\"rate_limit_exceeded\",\"message\":\"slow down\"}}\n\n"
    in
    let telemetry = ref [] in
    (match
       Complete.complete_stream
         ~sw
         ~net:env#net
         ~config:(make_openai_config url)
         ~messages
         ~on_event:(fun _ -> ())
         ~on_telemetry:(fun event -> telemetry := event :: !telemetry)
         ()
     with
     | Error
         (Http_client.ProviderFailure
            { kind = Http_client.Provider_reported_error { error_type = Some _ }; _ }) ->
       ()
     | Error _ -> fail "expected a typed provider-reported error"
     | Ok _ -> fail "a provider error envelope must not complete successfully");
    let terminal =
      List.find_map
        (function
          | Telemetry_event.Streaming_summary { terminal; _ } -> Some terminal
          | _ -> None)
        !telemetry
    in
    check
      (option (testable Telemetry_event.pp_streaming_terminal ( = )))
      "provider-reported envelope is not summarised as a wire failure"
      (Some (Telemetry_event.Terminal_error "provider_stream_error"))
      terminal;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_ollama_malformed_ndjson_is_wire_error () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_sse_server ~sw ~net:env#net ~content_type:"application/x-ndjson" "{not-json\n"
    in
    let telemetry = ref [] in
    (match
       Complete.complete_stream
         ~sw
         ~net:env#net
         ~config:(make_config ~kind:Provider_config.Ollama ~request_path:"/api/chat" url)
         ~messages
         ~on_event:(fun _ -> ())
         ~on_telemetry:(fun event -> telemetry := event :: !telemetry)
         ()
     with
     | Error
         (Http_client.ProviderFailure
            { kind =
                Http_client.Provider_wire_error
                  { format = Http_client.Ndjson; kind = Http_client.Malformed_payload }
            ; _
            }) -> ()
     | Error _ -> fail "expected typed malformed NDJSON payload"
     | Ok _ -> fail "malformed NDJSON payload must not complete successfully");
    let terminal =
      List.find_map
        (function
          | Telemetry_event.Streaming_summary { terminal; _ } -> Some terminal
          | _ -> None)
        !telemetry
    in
    check
      (option (testable Telemetry_event.pp_streaming_terminal ( = )))
      "NDJSON telemetry keeps its wire format"
      (Some (Telemetry_event.Terminal_error "ndjson_wire_error"))
      terminal;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_ollama_provider_error_is_not_wire_error () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_sse_server
        ~sw
        ~net:env#net
        ~content_type:"application/x-ndjson"
        {|{"error":"model failed"}
|}
    in
    let telemetry = ref [] in
    let events = ref [] in
    (match
       Complete.complete_stream
         ~sw
         ~net:env#net
         ~config:(make_config ~kind:Provider_config.Ollama ~request_path:"/api/chat" url)
         ~messages
         ~on_event:(fun event -> events := event :: !events)
         ~on_telemetry:(fun event -> telemetry := event :: !telemetry)
         ()
     with
     | Error
         (Http_client.ProviderFailure
            { kind = Http_client.Provider_reported_error { error_type = None }; _ }) -> ()
     | Error _ -> fail "expected a typed provider-reported error"
     | Ok _ -> fail "a provider error envelope must not complete successfully");
    let ndjson_errors =
      List.filter_map
        (function
          | Types.NDJSONError { message; error_type = None; raw } -> Some (message, raw)
          | Types.NDJSONError { error_type = Some _; _ } -> None
          | _ -> None)
        !events
    in
    check
      bool
      "Ollama provider error is not relabelled as SSE"
      true
      (not
         (List.exists
            (function
              | Types.SSEError _ -> true
              | _ -> false)
            !events));
    (match ndjson_errors with
     | [ (message, raw) ] ->
       check string "NDJSON provider error message" "model failed" message;
       check string "NDJSON provider error raw" {|{"error":"model failed"}|} raw
     | _ -> fail "Ollama provider error must remain exactly one NDJSON event");
    let terminal =
      List.find_map
        (function
          | Telemetry_event.Streaming_summary { terminal; _ } -> Some terminal
          | _ -> None)
        !telemetry
    in
    check
      (option (testable Telemetry_event.pp_streaming_terminal ( = )))
      "provider error telemetry is not a wire failure"
      (Some (Telemetry_event.Terminal_error "provider_stream_error"))
      terminal;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_ollama_missing_required_ndjson_field_is_wire_error () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_sse_server
        ~sw
        ~net:env#net
        ~content_type:"application/x-ndjson"
        {|{"model":"test-model","message":{"role":"assistant","content":"before"},"done":false}
{}
{"model":"test-model","message":{"role":"assistant","content":"after"},"done":true,"done_reason":"stop"}
|}
    in
    (match
       Complete.complete_stream
         ~sw
         ~net:env#net
         ~config:(make_config ~kind:Provider_config.Ollama ~request_path:"/api/chat" url)
         ~messages
         ~on_event:(fun _ -> ())
         ~on_telemetry:(fun _ -> ())
         ()
     with
     | Error
         (Http_client.ProviderFailure
            { kind =
                Http_client.Provider_wire_error
                  { format = Http_client.Ndjson; kind = Http_client.Malformed_payload }
            ; _
            }) -> ()
     | Error _ -> fail "expected typed malformed NDJSON payload"
     | Ok _ -> fail "missing required NDJSON field must not complete successfully");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_ollama_incomplete_ndjson_preserves_wire_format () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_sse_server
        ~sw
        ~net:env#net
        ~content_type:"application/x-ndjson"
        {|{"model":"test-model","message":{"role":"assistant","content":"partial"},"done":false}
|}
    in
    let telemetry = ref [] in
    (match
       Complete.complete_stream
         ~sw
         ~net:env#net
         ~config:(make_config ~kind:Provider_config.Ollama ~request_path:"/api/chat" url)
         ~messages
         ~on_event:(fun _ -> ())
         ~on_telemetry:(fun event -> telemetry := event :: !telemetry)
         ()
     with
     | Error
         (Http_client.ProviderFailure
            { kind =
                Http_client.Provider_wire_error
                  { format = Http_client.Ndjson; kind = Http_client.Incomplete_stream }
            ; _
            }) -> ()
     | Error _ -> fail "expected typed incomplete NDJSON stream"
     | Ok _ -> fail "unterminated NDJSON stream must not complete successfully");
    let terminal =
      List.find_map
        (function
          | Telemetry_event.Streaming_summary { terminal; _ } -> Some terminal
          | _ -> None)
        !telemetry
    in
    check
      (option (testable Telemetry_event.pp_streaming_terminal ( = )))
      "incomplete NDJSON telemetry is not successful"
      (Some (Telemetry_event.Terminal_error "ndjson_wire_error"))
      terminal;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_stream_on_event_exception_is_nonfatal () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_sse_server ~sw ~net:env#net (anthropic_sse_response "streamed text")
    in
    let config = make_config url in
    let calls = ref 0 in
    let on_event _evt =
      incr calls;
      failwith "stream observer failed"
    in
    match Complete.complete_stream ~sw ~net:env#net ~config ~messages ~on_event () with
    | Ok resp ->
      check string "text" "streamed text" (text_of_response resp);
      check bool "callback invoked" true (!calls > 0);
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok"
  with
  | Exit -> ()
;;

let test_complete_stream_wire_observer_rejection_is_typed_nonfatal () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let token = "Authorization: Bearer opaque-token" in
    let url = start_sse_server ~sw ~net:env#net (anthropic_sse_response token) in
    let config = make_config url in
    let observations = ref [] in
    let telemetry = ref [] in
    let wire_observer observation =
      observations := observation :: !observations;
      Error Wire_observer.{ reason = "caller queue unavailable" }
    in
    match
      Complete.complete_stream
        ~sw
        ~net:env#net
        ~capture_id:"request-wire-1"
        ~wire_observer
        ~config
        ~messages
        ~on_event:(fun _ -> ())
        ~on_telemetry:(fun event -> telemetry := event :: !telemetry)
        ()
    with
    | Error _ -> fail "wire observer rejection changed the provider result"
    | Ok response ->
      check string "provider response preserved" token (text_of_response response);
      check bool "raw chunks were offered" true (List.length !observations > 0);
      List.iter
        (fun (observation : Wire_observer.observation) ->
           check
             (option string)
             "exact capture id"
             (Some "request-wire-1")
             observation.capture_id;
           check string "exact provider" "anthropic" observation.provider;
           check string "exact model" "test-model" observation.model;
           check
             bool
             "raw token absent"
             false
             (contains_substring ~sub:token observation.redacted_chunk))
        !observations;
      check
        bool
        "redacted token observed"
        true
        (List.exists
           (fun (observation : Wire_observer.observation) ->
              contains_substring ~sub:"[REDACTED]" observation.redacted_chunk)
           !observations);
      let failures =
        List.filter_map
          (function
            | Telemetry_event.Wire_observer_failure failure -> Some failure
            | _ -> None)
          !telemetry
      in
      check
        int
        "one failure per rejected offer"
        (List.length !observations)
        (List.length failures);
      List.iter
        (fun (failure : Wire_observer.failure) ->
           match failure.cause with
           | Observer_rejected { reason } ->
             check string "exact rejection" "caller queue unavailable" reason
           | Observer_raised _ -> fail "rejection was relabelled as an exception")
        failures;
      Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_stream_wire_failure_telemetry_exception_is_nonfatal () =
  let diagnostics = ref [] in
  Diag.with_sink
    (fun _level ~ctx message -> diagnostics := (ctx, message) :: !diagnostics)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       try
         Eio.Switch.run
         @@ fun sw ->
         let url =
           start_sse_server ~sw ~net:env#net (anthropic_sse_response "streamed text")
         in
         let config = make_config url in
         let observer_calls = ref 0 in
         let wire_observer _observation =
           incr observer_calls;
           failwith "wire observer unavailable"
         in
         let on_telemetry = function
           | Telemetry_event.Wire_observer_failure _ ->
             failwith "telemetry observer unavailable"
           | _ -> ()
         in
         (match
            Complete.complete_stream
              ~sw
              ~net:env#net
              ~wire_observer
              ~config
              ~messages
              ~on_event:(fun _ -> ())
              ~on_telemetry
              ()
          with
          | Error _ ->
            fail "wire failure telemetry callback exception changed the provider result"
          | Ok response ->
            check
              string
              "provider response preserved"
              "streamed text"
              (text_of_response response));
         check bool "wire observer invoked" true (!observer_calls > 0);
         check
           bool
           "telemetry callback failure reached diagnostic fallback"
           true
           (List.exists
              (fun (ctx, message) ->
                 String.equal ctx "wire_observer"
                 && contains_substring ~sub:"telemetry observer unavailable" message
                 && contains_substring ~sub:"wire observer unavailable" message)
              !diagnostics);
         Eio.Switch.fail sw Exit
       with
       | Exit -> ())
;;

let test_complete_stream_transport_on_event_exception_is_nonfatal () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let calls = ref 0 in
  let transport =
    { (make_transport (Ok (mock_transport_response "transport streamed"))) with
      complete_stream =
        (fun ?on_telemetry:_ ~on_event _req ->
          on_event
            (Types.ContentBlockDelta { index = 0; delta = Types.TextDelta "ignored" });
          Ok (mock_transport_response "transport streamed"))
    }
  in
  let on_event _evt =
    incr calls;
    failwith "transport observer failed"
  in
  let config = make_config "http://unused.test" in
  match
    Complete.complete_stream ~sw ~net:env#net ~transport ~config ~messages ~on_event ()
  with
  | Ok resp ->
    check string "text" "transport streamed" (text_of_response resp);
    check int "callback invoked" 1 !calls
  | Error _ -> fail "expected Ok"
;;

let test_complete_stream_active_chunks_can_exceed_idle_timeout_total () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_raw_sse_server
        ~sw
        ~net:env#net
        ~clock:env#clock
        [ 0.0, anthropic_sse_frame_message_start
        ; 0.03, anthropic_sse_frame_content_block_start
        ; 0.03, anthropic_sse_frame_delta "active "
        ; 0.03, anthropic_sse_frame_delta "long "
        ; 0.03, anthropic_sse_frame_delta "stream"
        ; 0.03, anthropic_sse_frame_stop
        ]
    in
    let config = make_config url in
    let events = ref [] in
    let on_event evt = events := evt :: !events in
    match
      Complete.complete_stream
        ~sw
        ~net:env#net
        ~clock:env#clock
        ~stream_idle_timeout_s:0.08
        ~config
        ~messages
        ~on_event
        ()
    with
    | Ok resp ->
      check string "text" "active long stream" (text_of_response resp);
      check bool "events received" true (List.length !events > 0);
      Eio.Switch.fail sw Exit
    | Error err ->
      fail
        (Printf.sprintf
           "expected active stream to complete, got %s"
           (match err with
            | Http_client.NetworkError { message; _ }
            | Http_client.TimeoutError { message; _ } -> message
            | Http_client.HttpError { code; _ } -> Printf.sprintf "HTTP %d" code
            | Http_client.AcceptRejected { reason } -> reason
            | Http_client.ProviderTerminal { message; _ } -> message
            | Http_client.ProviderFailure { message; _ } -> message))
  with
  | Exit -> ()
;;

let test_complete_stream_idle_timeout_still_fires () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_raw_sse_server
        ~sw
        ~net:env#net
        ~clock:env#clock
        [ 0.12, anthropic_sse_frame_message_start
        ; 0.0, anthropic_sse_frame_content_block_start
        ; 0.0, anthropic_sse_frame_delta "late"
        ; 0.0, anthropic_sse_frame_stop
        ]
    in
    let config = make_config url in
    let on_event _evt = () in
    match
      Complete.complete_stream
        ~sw
        ~net:env#net
        ~clock:env#clock
        ~stream_idle_timeout_s:0.03
        ~config
        ~messages
        ~on_event
        ()
    with
    | Error (Http_client.TimeoutError { phase = Http_client.First_token; message }) ->
      let prefix = "stream_idle_timeout_s deadline exceeded" in
      check
        bool
        "stream idle message"
        true
        (String.length message >= String.length prefix
         && String.equal (String.sub message 0 (String.length prefix)) prefix);
      Eio.Switch.fail sw Exit
    | Error (Http_client.TimeoutError { phase; _ }) ->
      fail
        (Printf.sprintf
           "unexpected timeout phase %s"
           (Http_client.timeout_phase_to_label phase))
    | Ok _ -> fail "expected stream idle timeout"
    | Error _ -> fail "expected TimeoutError{phase=First_token}"
  with
  | Exit -> ()
;;

(* Bug #10 regression (38-bug campaign): actively streaming reasoning
   deltas are stream LIVENESS, not idleness. Each hidden-reasoning delta
   advances the injected mock clock by 6s, so the cumulative
   thinking-only span crosses the 10s idle budget on the third delta —
   the exact condition the deleted thinking-only wall-clock cutoff used
   to abort on (TimeoutError{Stream_idle Streaming_thinking}, then MASC
   retried and re-killed the round, losing the turn). Inter-event gaps
   (6s) stay under the 10s idle deadline, so the line-idle timer must
   not fire either: the stream must finalize [Ok] with the answer. *)
let test_complete_stream_long_thinking_is_not_cut_off () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let mock_clock = Eio_mock.Clock.make () in
    let url =
      start_raw_sse_server
        ~sw
        ~net:env#net
        ~clock:env#clock
        (anthropic_thinking_then_answer_frames ~frame_gap_s:0.01)
    in
    let config = make_config url in
    let mock_now = ref 0.0 in
    let on_event = function
      | Types.ContentBlockDelta { delta = Types.ThinkingDelta _; _ } ->
        mock_now := !mock_now +. 6.0;
        Eio_mock.Clock.set_time mock_clock !mock_now
      | _ -> ()
    in
    match
      Complete.complete_stream
        ~sw
        ~net:env#net
        ~clock:mock_clock
        ~stream_idle_timeout_s:10.0
        ~config
        ~messages
        ~on_event
        ()
    with
    | Ok resp ->
      check string "text" "answer" (text_of_response resp);
      Eio.Switch.fail sw Exit
    | Error err ->
      fail
        (Printf.sprintf
           "long thinking must stream to completion, got %s"
           (match err with
            | Http_client.NetworkError { message; _ }
            | Http_client.TimeoutError { message; _ } -> message
            | Http_client.HttpError { code; _ } -> Printf.sprintf "HTTP %d" code
            | Http_client.AcceptRejected { reason } -> reason
            | Http_client.ProviderTerminal { message; _ } -> message
            | Http_client.ProviderFailure { message; _ } -> message))
  with
  | Exit -> ()
;;

let omitted_idle_test_case ~transport_arm ~kind ~request_path ~content_type ~body () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let mock_clock = Eio_mock.Clock.make () in
    let connected, resolve_connected = Eio.Promise.create () in
    let release_body, resolve_release_body = Eio.Promise.create () in
    let url =
      start_clock_jump_stream_server ~sw ~net:env#net ~release_body ~content_type body
    in
    let config =
      Provider_config.make
        ~kind
        ~model_id:"test-model"
        ~base_url:url
        ~request_path
        ~temperature:0.0
        ~max_tokens:100
        ()
    in
    let transport =
      if transport_arm
      then Some (Complete.make_http_transport ~clock:mock_clock ~sw ~net:env#net ())
      else None
    in
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.await connected;
      Eio.Fiber.yield ();
      Eio_mock.Clock.set_time mock_clock removed_provider_idle_defaults_upper_bound_s;
      Eio.Fiber.yield ();
      Eio.Promise.resolve resolve_release_body ());
    match
      Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
        Complete.complete_stream
          ~sw
          ~net:env#net
          ~clock:mock_clock
          ?transport
          ~config
          ~messages
          ~on_event:(function
            | Types.Connected -> Eio.Promise.resolve resolve_connected ()
            | _ -> ())
          ())
    with
    | Ok resp ->
      check string "text" "default-disabled" (text_of_response resp);
      Eio.Switch.fail sw Exit
    | Error _ -> fail "omitted stream idle timeout must remain disabled"
    | exception Eio.Time.Timeout -> fail "clock-jump fixture did not terminate"
  with
  | Exit -> ()
;;

let test_anthropic_omitted_idle_has_no_provider_default =
  omitted_idle_test_case
    ~transport_arm:false
    ~kind:Provider_config.Anthropic
    ~request_path:"/v1/messages"
    ~content_type:"text/event-stream"
    ~body:(anthropic_sse_response "default-disabled")
;;

let test_ollama_omitted_idle_has_no_provider_default =
  omitted_idle_test_case
    ~transport_arm:false
    ~kind:Provider_config.Ollama
    ~request_path:"/api/chat"
    ~content_type:"application/x-ndjson"
    ~body:
      "{\"model\":\"test-model\",\"message\":{\"role\":\"assistant\",\"content\":\"default-disabled\"},\"done\":true,\"done_reason\":\"stop\",\"prompt_eval_count\":10,\"eval_count\":5}\n"
;;

let test_transport_anthropic_omitted_idle_has_no_provider_default =
  omitted_idle_test_case
    ~transport_arm:true
    ~kind:Provider_config.Anthropic
    ~request_path:"/v1/messages"
    ~content_type:"text/event-stream"
    ~body:(anthropic_sse_response "default-disabled")
;;

let test_clock_jump_fixture_fires_explicit_idle_timeout () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let mock_clock = Eio_mock.Clock.make () in
    let connected, resolve_connected = Eio.Promise.create () in
    let release_body, resolve_release_body = Eio.Promise.create () in
    let url =
      start_clock_jump_stream_server
        ~sw
        ~net:env#net
        ~release_body
        ~content_type:"text/event-stream"
        (anthropic_sse_response "too-late")
    in
    let config = make_config url in
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.await connected;
      Eio.Fiber.yield ();
      Eio_mock.Clock.set_time mock_clock removed_provider_idle_defaults_upper_bound_s;
      Eio.Fiber.yield ();
      Eio.Promise.resolve resolve_release_body ());
    match
      Eio.Time.with_timeout_exn env#clock 5.0 (fun () ->
        Complete.complete_stream
          ~sw
          ~net:env#net
          ~clock:mock_clock
          ~stream_idle_timeout_s:600.0
          ~config
          ~messages
          ~on_event:(function
            | Types.Connected -> Eio.Promise.resolve resolve_connected ()
            | _ -> ())
          ())
    with
    | Error (Http_client.TimeoutError { phase = Http_client.First_token; _ }) ->
      Eio.Switch.fail sw Exit
    | Ok _ -> fail "explicit idle timeout must fire across the clock jump"
    | Error _ -> fail "expected typed first-token timeout"
    | exception Eio.Time.Timeout -> fail "clock-jump fixture did not terminate"
  with
  | Exit -> ()
;;

let test_complete_stream_metrics () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_sse_server ~sw ~net:env#net (anthropic_sse_response "streamed text")
    in
    let config = make_config url in
    let first_chunks = ref [] in
    let inter_chunks = ref [] in
    let metrics : Metrics.t =
      { Metrics.noop with
        on_streaming_first_chunk =
          (fun ~provider ~model_id ~ttfrc_ms ->
            first_chunks := (provider, model_id, ttfrc_ms) :: !first_chunks)
      ; on_streaming_chunk =
          (fun ~provider ~model_id ~chunk_index ~inter_chunk_ms ->
            inter_chunks
            := (provider, model_id, chunk_index, inter_chunk_ms) :: !inter_chunks)
      }
    in
    let on_event _evt = () in
    match
      Complete.complete_stream ~sw ~net:env#net ~config ~messages ~on_event ~metrics ()
    with
    | Ok _ ->
      check int "first chunk count" 1 (List.length !first_chunks);
      (match !first_chunks with
       | [ (provider, model_id, ttfrc_ms) ] ->
         check string "provider" "anthropic" provider;
         check string "model_id" "test-model" model_id;
         check bool "ttfrc non-negative" true (ttfrc_ms >= 0.0)
       | _ -> fail "expected one first chunk");
      check bool "inter chunk metrics" true (List.length !inter_chunks > 0);
      List.iter
        (fun (provider, model_id, chunk_index, inter_chunk_ms) ->
           check string "inter provider" "anthropic" provider;
           check string "inter model_id" "test-model" model_id;
           check bool "chunk_index non-negative" true (chunk_index >= 0);
           check bool "inter chunk non-negative" true (inter_chunk_ms >= 0.0))
        !inter_chunks;
      Eio.Switch.fail sw Exit
    | Error _ -> fail "expected Ok"
  with
  | Exit -> ()
;;

let test_complete_stream_unknown_latency_stays_unknown () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_sse_server ~sw ~net:env#net (anthropic_sse_response "streamed text")
    in
    let config = make_config url in
    let telemetry_events = ref [] in
    let first_chunk_metrics = ref 0 in
    let inter_chunk_metrics = ref 0 in
    let status_calls = ref [] in
    let metrics : Metrics.t =
      { Metrics.noop with
        on_streaming_first_chunk =
          (fun ~provider:_ ~model_id:_ ~ttfrc_ms:_ -> incr first_chunk_metrics)
      ; on_streaming_chunk =
          (fun ~provider:_ ~model_id:_ ~chunk_index:_ ~inter_chunk_ms:_ ->
            incr inter_chunk_metrics)
      ; on_http_status =
          (fun ~provider ~model_id ~status ->
            status_calls := (provider, model_id, status) :: !status_calls)
      }
    in
    let result =
      Complete_stream.complete_stream_http
        ~sw
        ~net:env#net
        ~latency_counter:Complete_common.Unknown_latency
        ~on_telemetry:(fun evt -> telemetry_events := evt :: !telemetry_events)
        ~metrics
        ~config
        ~messages
        ~tools:[]
        ~on_event:(fun _evt -> ())
        ()
    in
    (match result with
     | Ok resp ->
       (match resp.telemetry with
        | Some t ->
          check (option int) "response latency unknown" None t.request_latency_ms;
          check (option (float 0.001)) "response ttfrc unknown" None t.ttfrc_ms
        | None -> fail "expected response telemetry")
     | Error _ -> fail "expected Ok");
    let first_chunk =
      List.find_map
        (function
          | Telemetry_event.Streaming_first_chunk r -> Some r.ttfrc_ms
          | _ -> None)
        !telemetry_events
    in
    let summary =
      List.find_map
        (function
          | Telemetry_event.Streaming_summary
              { total_ms; inter_chunk_ms_p50; inter_chunk_ms_p95; inter_chunk_ms_max; _ }
            -> Some (total_ms, inter_chunk_ms_p50, inter_chunk_ms_p95, inter_chunk_ms_max)
          | _ -> None)
        !telemetry_events
    in
    check
      (option (option (float 0.001)))
      "first chunk latency event"
      (Some None)
      first_chunk;
    (match summary with
     | Some (total_ms, inter_chunk_ms_p50, inter_chunk_ms_p95, inter_chunk_ms_max) ->
       check (option (float 0.001)) "summary total unknown" None total_ms;
       check (option (float 0.001)) "summary p50 unknown" None inter_chunk_ms_p50;
       check (option (float 0.001)) "summary p95 unknown" None inter_chunk_ms_p95;
       check (option (float 0.001)) "summary max unknown" None inter_chunk_ms_max
     | None -> fail "expected streaming summary");
    check int "first chunk metrics skipped" 0 !first_chunk_metrics;
    check int "inter chunk metrics skipped" 0 !inter_chunk_metrics;
    (match !status_calls with
     | [ ("anthropic", "test-model", 200) ] -> ()
     | [ (_, _, status) ] -> fail (Printf.sprintf "expected 200, got %d" status)
     | _ -> fail "expected exactly one streaming status call");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* RFC-OAS-026: drive the [Some t] transport dispatch arm. The high-level
   [stream_idle_timeout_s] must reach [read_sse] via the request-borne carrier field on
   [Llm_transport.completion_request]; pre-F1 the dispatch dropped it and a
   first-token stall hung until an external watchdog. The sibling idle-timeout
   tests above call [complete_stream] WITHOUT [~transport] (the [None] arm,
   which always armed idle), so they pass even with the dispatch drop — this one
   guards the transport arm specifically. *)
let test_complete_stream_transport_arm_idle_timeout () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_raw_sse_server
        ~sw
        ~net:env#net
        ~clock:env#clock
        [ 0.15, anthropic_sse_frame_message_start
        ; 0.0, anthropic_sse_frame_content_block_start
        ; 0.0, anthropic_sse_frame_delta "late"
        ; 0.0, anthropic_sse_frame_stop
        ]
    in
    let config = make_config url in
    (* The request-borne deadline is the sole idle-timeout source. *)
    let transport = Complete.make_http_transport ~clock:env#clock ~sw ~net:env#net () in
    match
      Complete.complete_stream
        ~sw
        ~net:env#net
        ~clock:env#clock
        ~stream_idle_timeout_s:0.03
        ~transport
        ~config
        ~messages
        ~on_event:(fun _ -> ())
        ()
    with
    | Error (Http_client.TimeoutError { phase = Http_client.First_token; _ }) ->
      Eio.Switch.fail sw Exit
    | Ok _ -> fail "expected idle timeout via the Some-t dispatch — carrier dropped?"
    | Error _ -> fail "expected TimeoutError{phase=First_token} via the transport arm"
  with
  | Exit -> ()
;;

(* ── complete: body_timeout_s ─────────────────────────── *)

let test_complete_body_timeout_fires () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    (* Server delays response by 2.0s; caller deadline 0.3s must fire first
       and produce TimeoutError{phase=Non_streaming_body} with a body-deadline message. *)
    let url =
      start_mock_server
        ~sw
        ~net:env#net
        ~clock:env#clock
        ~delay_sec:2.0
        (anthropic_response "should not arrive")
    in
    let config = make_config url in
    let t0 = Unix.gettimeofday () in
    (match
       Complete.complete
         ~sw
         ~net:env#net
         ~clock:env#clock
         ~config
         ~messages
         ~body_timeout_s:0.3
         ()
     with
     | Ok _ -> fail "expected Error (body_timeout_s should have fired)"
     | Error
         (Http_client.TimeoutError { phase = Http_client.Non_streaming_body; message }) ->
       let elapsed = Unix.gettimeofday () -. t0 in
       check bool "fires under server delay" true (elapsed < 1.5);
       check
         bool
         "message identifies body deadline"
         true
         (let prefix = "body_timeout_s deadline exceeded" in
          String.length message >= String.length prefix
          && String.equal (String.sub message 0 (String.length prefix)) prefix)
     | Error _ ->
       fail "unexpected error variant (expected TimeoutError{phase=Non_streaming_body})");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_body_timeout_does_not_fire_on_fast_response () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    (* No server delay; generous body_timeout_s must not interfere. *)
    let url = start_mock_server ~sw ~net:env#net (anthropic_response "fast response") in
    let config = make_config url in
    (match
       Complete.complete
         ~sw
         ~net:env#net
         ~clock:env#clock
         ~config
         ~messages
         ~body_timeout_s:60.0
         ()
     with
     | Ok resp ->
       let text =
         List.filter_map
           (function
             | Types.Text s -> Some s
             | _ -> None)
           resp.content
         |> String.concat ""
       in
       check string "text" "fast response" text
     | Error _ -> fail "unexpected error on fast path with body_timeout_s set");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_sync_uses_only_outer_body_timeout () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_raw_sync_server
        ~sw
        ~net:env#net
        ~clock:env#clock
        ~body_delay_sec:0.08
        (anthropic_response "slow body")
    in
    let config = { (make_config url) with connect_timeout_s = Some 0.02 } in
    (match
       Complete.complete
         ~sw
         ~net:env#net
         ~clock:env#clock
         ~config
         ~messages
         ~body_timeout_s:0.5
         ()
     with
     | Ok response -> check string "body" "slow body" (text_of_response response)
     | Error _ -> fail "nested connect timeout incorrectly capped sync body");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_body_timeout_without_clock_rejected_before_request () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let request_count = ref 0 in
    let url =
      start_mock_server
        ~sw
        ~net:env#net
        ~on_request:(fun () -> incr request_count)
        (anthropic_response "must not arrive")
    in
    let config = make_config url in
    (match
       Complete.complete ~sw ~net:env#net ~config ~messages ~body_timeout_s:60.0 ()
     with
     | Error (Http_client.AcceptRejected _) ->
       check int "request rejected before HTTP I/O" 0 !request_count
     | Ok _ -> fail "expected AcceptRejected for body_timeout_s without clock"
     | Error _ -> fail "expected typed AcceptRejected for body_timeout_s without clock");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_body_timeout_requires_finite_positive_value_before_request () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let request_count = ref 0 in
    let url =
      start_mock_server
        ~sw
        ~net:env#net
        ~on_request:(fun () -> incr request_count)
        (anthropic_response "positive timeout")
    in
    let config = make_config url in
    let invalid_cases =
      [ "zero", 0.0
      ; "negative", -1.0
      ; "nan", Float.nan
      ; "positive infinity", Float.infinity
      ; "negative infinity", Float.neg_infinity
      ]
    in
    List.iter
      (fun (label, body_timeout_s) ->
         match
           Complete.complete
             ~sw
             ~net:env#net
             ~clock:env#clock
             ~config
             ~messages
             ~body_timeout_s
             ()
         with
         | Error (Http_client.AcceptRejected _) ->
           check int (label ^ " rejected before HTTP I/O") 0 !request_count
         | Ok _ -> failf "%s timeout was accepted" label
         | Error _ -> failf "%s timeout returned the wrong typed error" label)
      invalid_cases;
    (match
       Complete.complete
         ~sw
         ~net:env#net
         ~clock:env#clock
         ~config
         ~messages
         ~body_timeout_s:60.0
         ()
     with
     | Ok resp ->
       let text =
         List.filter_map
           (function
             | Types.Text value -> Some value
             | _ -> None)
           resp.content
         |> String.concat ""
       in
       check string "positive timeout response" "positive timeout" text;
       check int "positive timeout performs one request" 1 !request_count
     | Error _ -> fail "positive timeout was rejected");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_without_body_timeout_or_clock_succeeds () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock_server ~sw ~net:env#net (anthropic_response "unbounded") in
    let config = make_config url in
    (match Complete.complete ~sw ~net:env#net ~config ~messages () with
     | Ok resp ->
       let text =
         List.filter_map
           (function
             | Types.Text value -> Some value
             | _ -> None)
           resp.content
         |> String.concat ""
       in
       check string "no-timeout response" "unbounded" text
     | Error _ -> fail "no timeout and no clock must preserve unbounded HTTP behavior");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_injected_transport_without_timeout_is_unbounded () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let calls = ref 0 in
  let response = mock_transport_response "injected unbounded" in
  let transport =
    { (make_transport (Ok response)) with
      complete_sync =
        (fun _ ->
          incr calls;
          { Llm_transport.response = Ok response; latency_ms = Some 1 })
    }
  in
  match
    Complete.complete ~sw ~net:env#net ~transport ~config:(make_config "") ~messages ()
  with
  | Ok resp ->
    check
      string
      "unbounded injected response"
      "injected unbounded"
      (text_of_response resp);
    check int "unbounded injected call count" 1 !calls
  | Error _ -> fail "injected transport without body_timeout_s was rejected"
;;

let test_complete_injected_transport_rejects_invalid_deadlines_before_call () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let calls = ref 0 in
  let response = mock_transport_response "must not run" in
  let transport =
    { (make_transport (Ok response)) with
      complete_sync =
        (fun _ ->
          incr calls;
          { Llm_transport.response = Ok response; latency_ms = Some 1 })
    }
  in
  let config = make_config "" in
  (match
     Complete.complete
       ~sw
       ~net:env#net
       ~transport
       ~config
       ~messages
       ~body_timeout_s:1.0
       ()
   with
   | Error (Http_client.AcceptRejected _) -> ()
   | Ok _ -> fail "injected timeout without clock was accepted"
   | Error _ -> fail "injected timeout without clock returned the wrong typed error");
  let invalid_cases =
    [ "zero", 0.0
    ; "negative", -1.0
    ; "nan", Float.nan
    ; "positive infinity", Float.infinity
    ; "negative infinity", Float.neg_infinity
    ]
  in
  List.iter
    (fun (label, body_timeout_s) ->
       match
         Complete.complete
           ~sw
           ~net:env#net
           ~clock:env#clock
           ~transport
           ~config
           ~messages
           ~body_timeout_s
           ()
       with
       | Error (Http_client.AcceptRejected _) -> ()
       | Ok _ -> failf "%s injected timeout was accepted" label
       | Error _ -> failf "%s injected timeout returned the wrong typed error" label)
    invalid_cases;
  check int "invalid deadlines call injected transport zero times" 0 !calls
;;

let test_complete_injected_transport_positive_timeout_succeeds () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let calls = ref 0 in
  let response = mock_transport_response "injected bounded" in
  let transport =
    { (make_transport (Ok response)) with
      complete_sync =
        (fun _ ->
          incr calls;
          { Llm_transport.response = Ok response; latency_ms = Some 1 })
    }
  in
  match
    Complete.complete
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~transport
      ~config:(make_config "")
      ~messages
      ~body_timeout_s:1.0
      ()
  with
  | Ok resp ->
    check string "bounded injected response" "injected bounded" (text_of_response resp);
    check int "bounded injected call count" 1 !calls
  | Error _ -> fail "positive injected body_timeout_s was rejected"
;;

let test_complete_injected_transport_timeout_is_typed () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let calls = ref 0 in
  let response = mock_transport_response "must time out" in
  let transport =
    { (make_transport (Ok response)) with
      complete_sync =
        (fun _ ->
          incr calls;
          Eio.Time.sleep env#clock 1.0;
          { Llm_transport.response = Ok response; latency_ms = Some 1 })
    }
  in
  match
    Complete.complete
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~transport
      ~config:(make_config "")
      ~messages
      ~body_timeout_s:0.01
      ()
  with
  | Error (Http_client.TimeoutError { phase = Http_client.Non_streaming_body; message })
    ->
    check
      string
      "injected timeout message preserves exact caller deadline"
      "body_timeout_s deadline exceeded after 0.01s (Complete.complete injected sync \
       transport)"
      message;
    check int "expired injected transport call count" 1 !calls
  | Ok _ -> fail "slow injected transport escaped body_timeout_s"
  | Error _ -> fail "injected expiry returned the wrong typed error"
;;

let test_complete_injected_transport_inner_timeout_is_not_relabelled () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let calls = ref 0 in
  let response = mock_transport_response "must raise" in
  let transport =
    { (make_transport (Ok response)) with
      complete_sync =
        (fun _ ->
          incr calls;
          raise Eio.Time.Timeout)
    }
  in
  let propagated =
    try
      ignore
        (Complete.complete
           ~sw
           ~net:env#net
           ~clock:env#clock
           ~transport
           ~config:(make_config "")
           ~messages
           ~body_timeout_s:1.0
           ());
      false
    with
    | Eio.Time.Timeout -> true
  in
  check bool "transport-owned timeout exception propagates" true propagated;
  check int "inner timeout transport call count" 1 !calls
;;

let test_complete_deadline_preflight_precedes_cache_hit () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let cache_reads = ref 0 in
  let transport_calls = ref 0 in
  let response = mock_transport_response "cached" in
  let cache : Cache.t =
    { get =
        (fun ~key:_ ->
          incr cache_reads;
          Some (Cache.response_to_json response))
    ; set = (fun ~key:_ ~ttl_sec:_ _ -> ())
    }
  in
  let transport =
    { (make_transport (Ok response)) with
      complete_sync =
        (fun _ ->
          incr transport_calls;
          { Llm_transport.response = Ok response; latency_ms = Some 1 })
    }
  in
  match
    Complete.complete
      ~sw
      ~net:env#net
      ~transport
      ~config:(make_config "")
      ~messages
      ~cache
      ~body_timeout_s:1.0
      ()
  with
  | Error (Http_client.AcceptRejected _) ->
    check int "deadline preflight precedes cache lookup" 0 !cache_reads;
    check int "deadline preflight precedes transport" 0 !transport_calls
  | Ok _ -> fail "cache hit silently bypassed invalid deadline contract"
  | Error _ -> fail "cache preflight returned the wrong typed error"
;;

let check_accept_rejected ~label ~needle = function
  | Error (Http_client.AcceptRejected { reason }) ->
    check bool (label ^ " reason") true (contains_substring ~sub:needle reason)
  | Ok _ -> failf "%s unexpectedly succeeded" label
  | Error _ -> failf "%s returned a non-AcceptRejected error" label
;;

let test_complete_rejects_unsupported_reasoning_before_io () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let request_count = ref 0 in
    let base_url =
      start_mock_server
        ~sw
        ~net:env#net
        ~on_request:(fun () -> incr request_count)
        (anthropic_response "must not arrive")
    in
    let capabilities =
      { Capabilities.gemini_capabilities with
        accepted_reasoning_efforts = Some [ Reasoning_effort.Low ]
      }
    in
    let config =
      Provider_config.make
        ~kind:Provider_config.Gemini
        ~model_id:"explicit-gemini-contract"
        ~base_url
        ~reasoning_effort:Reasoning_effort.High
        ~model_capabilities_override:capabilities
        ()
    in
    check_accept_rejected
      ~label:"sync unsupported reasoning effort"
      ~needle:"does not accept reasoning effort"
      (Complete.complete ~sw ~net:env#net ~config ~messages ());
    check_accept_rejected
      ~label:"stream unsupported reasoning effort"
      ~needle:"does not accept reasoning effort"
      (Complete.complete_stream
         ~sw
         ~net:env#net
         ~config
         ~messages
         ~on_event:(fun _ -> ())
         ());
    check int "unsupported effort performs no HTTP request" 0 !request_count;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_complete_rejects_missing_anthropic_output_ceiling_before_io () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let request_count = ref 0 in
    let base_url =
      start_mock_server
        ~sw
        ~net:env#net
        ~on_request:(fun () -> incr request_count)
        (anthropic_response "must not arrive")
    in
    let config =
      Provider_config.make
        ~kind:Provider_config.Anthropic
        ~model_id:"undeclared-anthropic-model"
        ~base_url
        ()
    in
    check_accept_rejected
      ~label:"sync missing Anthropic output ceiling"
      ~needle:"requires max_tokens"
      (Complete.complete ~sw ~net:env#net ~config ~messages ());
    check_accept_rejected
      ~label:"stream missing Anthropic output ceiling"
      ~needle:"requires max_tokens"
      (Complete.complete_stream
         ~sw
         ~net:env#net
         ~config
         ~messages
         ~on_event:(fun _ -> ())
         ());
    check int "missing output ceiling performs no HTTP request" 0 !request_count;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── Runner ──────────────────────────────────────────── *)

let () =
  run
    "complete_http"
    [ ( "complete"
      , [ test_case "anthropic ok" `Quick test_complete_anthropic_ok
        ; test_case
            "Kimi path override stays Anthropic"
            `Quick
            test_complete_kimi_path_override_stays_anthropic_codec
        ; test_case
            "OpenAI-compatible Kimi uses OpenAI codec"
            `Quick
            test_complete_openai_compatible_kimi_uses_openai_codec
        ; test_case
            "HTTP rejects typed empty completion"
            `Quick
            test_complete_http_rejects_typed_empty_completion
        ; test_case "http error" `Quick test_complete_http_error
        ; test_case
            "request body limit rejects before I/O"
            `Quick
            test_complete_request_body_limit_rejects_before_io
        ; test_case
            "wire observer sees exact sync body"
            `Quick
            test_complete_request_wire_observer_sees_exact_sync_body
        ; test_case
            "stream body limit includes final wire injection"
            `Quick
            test_complete_stream_rechecks_limit_after_final_wire_injection
        ; test_case
            "empty http error body has context"
            `Quick
            test_complete_http_empty_error_body_has_context
        ; test_case "openai ok" `Quick test_complete_openai_ok
        ; test_case
            "openai responses sync ok"
            `Quick
            test_complete_openai_responses_sync_ok
        ; test_case
            "openai responses json mode body"
            `Quick
            test_complete_openai_responses_json_mode_body
        ; test_case
            "openai responses stream ok"
            `Quick
            test_complete_stream_openai_responses_ok
        ; test_case
            "openai mlx-vlm telemetry"
            `Quick
            test_complete_openai_mlx_vlm_telemetry
        ; test_case
            "sync latency uses injected clock"
            `Quick
            test_complete_sync_latency_uses_injected_clock
        ; test_case
            "latency clamps negative injected clock"
            `Quick
            test_latency_counter_clamps_negative_injected_clock
        ; test_case "trace context headers" `Quick test_complete_trace_context_headers
        ; test_case "non-retryable" `Quick test_complete_non_retryable
        ; test_case
            "body_timeout_s fires under server delay"
            `Quick
            test_complete_body_timeout_fires
        ; test_case
            "body_timeout_s no-op on fast response"
            `Quick
            test_complete_body_timeout_does_not_fire_on_fast_response
        ; test_case
            "sync uses only outer body timeout"
            `Quick
            test_complete_sync_uses_only_outer_body_timeout
        ; test_case
            "body_timeout_s without clock rejects before request"
            `Quick
            test_complete_body_timeout_without_clock_rejected_before_request
        ; test_case
            "body_timeout_s requires a finite positive value before request"
            `Quick
            test_complete_body_timeout_requires_finite_positive_value_before_request
        ; test_case
            "no body timeout and no clock stays unbounded"
            `Quick
            test_complete_without_body_timeout_or_clock_succeeds
        ; test_case
            "injected transport without body timeout stays unbounded"
            `Quick
            test_complete_injected_transport_without_timeout_is_unbounded
        ; test_case
            "injected transport rejects invalid deadlines before call"
            `Quick
            test_complete_injected_transport_rejects_invalid_deadlines_before_call
        ; test_case
            "injected transport accepts a positive body timeout"
            `Quick
            test_complete_injected_transport_positive_timeout_succeeds
        ; test_case
            "injected transport expiry is a typed body timeout"
            `Quick
            test_complete_injected_transport_timeout_is_typed
        ; test_case
            "injected transport inner timeout is not relabelled"
            `Quick
            test_complete_injected_transport_inner_timeout_is_not_relabelled
        ; test_case
            "deadline preflight precedes cache hit"
            `Quick
            test_complete_deadline_preflight_precedes_cache_hit
        ; test_case
            "unsupported reasoning rejects before sync or stream I/O"
            `Quick
            test_complete_rejects_unsupported_reasoning_before_io
        ; test_case
            "missing Anthropic output ceiling rejects before sync or stream I/O"
            `Quick
            test_complete_rejects_missing_anthropic_output_ceiling_before_io
        ] )
    ; "cache", [ test_case "store and hit" `Quick test_complete_cache_store_and_hit ]
    ; ( "metrics"
      , [ test_case "callbacks" `Quick test_complete_metrics
        ; test_case "tool call callback" `Quick test_complete_tool_call_metrics
        ; test_case "error callback" `Quick test_complete_error_metrics
        ; test_case
            "direct streaming HTTP error uses metrics fallback"
            `Quick
            test_complete_stream_http_error_metrics_uses_fallback
        ; test_case
            "injected HTTP transport preserves streaming status"
            `Quick
            test_complete_injected_http_transport_preserves_stream_status_metrics
        ; test_case "transport http ok" `Quick test_complete_transport_http_metrics_ok
        ; test_case
            "transport http error"
            `Quick
            test_complete_transport_http_metrics_error
        ; test_case
            "transport mock emits status"
            `Quick
            test_complete_transport_mock_emits_status
        ; test_case "global default is noop" `Quick test_metrics_global_default_is_noop
        ; test_case "global set and get" `Quick test_metrics_global_set_and_get
        ; test_case
            "global used when no per-call metrics"
            `Quick
            test_metrics_global_used_when_no_per_call_metrics
        ] )
    ; ( "stream"
      , [ test_case "sse ok" `Quick test_complete_stream_ok
        ; test_case
            "malformed SSE payload is a typed wire error"
            `Quick
            test_complete_stream_malformed_payload_is_wire_error
        ; test_case
            "provider error envelope is not a wire failure"
            `Quick
            test_complete_provider_error_envelope_is_not_a_wire_error
        ; test_case
            "malformed Ollama NDJSON preserves its wire format"
            `Quick
            test_complete_ollama_malformed_ndjson_is_wire_error
        ; test_case
            "Ollama provider errors are not wire failures"
            `Quick
            test_complete_ollama_provider_error_is_not_wire_error
        ; test_case
            "missing Ollama NDJSON fields are wire errors"
            `Quick
            test_complete_ollama_missing_required_ndjson_field_is_wire_error
        ; test_case
            "incomplete Ollama NDJSON preserves its wire format"
            `Quick
            test_complete_ollama_incomplete_ndjson_preserves_wire_format
        ; test_case
            "Kimi Anthropic Messages SSE codec"
            `Quick
            test_complete_kimi_anthropic_stream_codec
        ; test_case
            "wire observer sees exact stream body"
            `Quick
            test_complete_request_wire_observer_sees_exact_stream_body
        ; test_case
            "HTTP stream rejects typed empty completion"
            `Quick
            test_complete_stream_http_rejects_typed_empty_completion
        ; test_case
            "preserves thinking signature"
            `Quick
            test_complete_stream_preserves_thinking_signature
        ; test_case
            "on_event exceptions are nonfatal"
            `Quick
            test_complete_stream_on_event_exception_is_nonfatal
        ; test_case
            "wire observer rejection is typed and nonfatal"
            `Quick
            test_complete_stream_wire_observer_rejection_is_typed_nonfatal
        ; test_case
            "wire failure telemetry exception is nonfatal"
            `Quick
            test_complete_stream_wire_failure_telemetry_exception_is_nonfatal
        ; test_case
            "transport on_event exceptions are nonfatal"
            `Quick
            test_complete_stream_transport_on_event_exception_is_nonfatal
        ; test_case
            "active chunks exceed idle total"
            `Quick
            test_complete_stream_active_chunks_can_exceed_idle_timeout_total
        ; test_case
            "stream idle timeout still fires"
            `Quick
            test_complete_stream_idle_timeout_still_fires
        ; test_case "streaming metrics" `Quick test_complete_stream_metrics
        ; test_case
            "unknown stream latency stays unknown"
            `Quick
            test_complete_stream_unknown_latency_stays_unknown
        ; test_case
            "transport arm idle timeout (RFC-OAS-026)"
            `Quick
            test_complete_stream_transport_arm_idle_timeout
        ; test_case
            "long thinking is not cut off (bug #10 regression)"
            `Quick
            test_complete_stream_long_thinking_is_not_cut_off
        ; test_case
            "Anthropic omitted idle has no provider default"
            `Quick
            test_anthropic_omitted_idle_has_no_provider_default
        ; test_case
            "Ollama omitted idle has no provider default"
            `Quick
            test_ollama_omitted_idle_has_no_provider_default
        ; test_case
            "transport Anthropic omitted idle has no provider default"
            `Quick
            test_transport_anthropic_omitted_idle_has_no_provider_default
        ; test_case
            "clock-jump fixture fires explicit idle timeout"
            `Quick
            test_clock_jump_fixture_fires_explicit_idle_timeout
        ] )
    ]
;;
