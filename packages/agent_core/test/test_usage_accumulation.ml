(** Integration tests for usage accumulation across turns.

    Uses a mock HTTP server to verify [Agent.run] accumulates response
    usage into [Agent.state.usage] across the multi-turn tool loop.
    Restored from test_cost_integration.ml's accumulation section when
    Cost_tracker was removed (2026-07-21 test-only surface cut) — these
    cases never touched Cost_tracker and are the only end-to-end guard
    on the run-loop usage wiring.

    Pattern: test_integration.ml (Anthropic Messages API mock) *)

open Agent_core
open Types

(* ── Mock HTTP helpers ───────────────────────────────── *)

(** Build response with specific token counts for usage tracking. *)
let text_body_with_usage ~input_tokens ~output_tokens text =
  Printf.sprintf
    {|{"id":"c1","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":%d,"completion_tokens":%d,"total_tokens":%d}}|}
    text
    input_tokens
    output_tokens
    (input_tokens + output_tokens)
;;

let tool_body_with_usage ~input_tokens ~output_tokens ~tool_name =
  Printf.sprintf
    {|{"id":"c2","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"tu_c","type":"function","function":{"name":"%s","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":%d,"completion_tokens":%d,"total_tokens":%d}}|}
    tool_name
    input_tokens
    output_tokens
    (input_tokens + output_tokens)
;;

let with_mock_server ~port handler f =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let socket =
      Eio.Net.listen
        env#net
        ~sw
        ~backlog:128
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let server = Cohttp_eio.Server.make ~callback:handler () in
    Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
    f ~sw ~net:env#net ~base_url;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let local_provider ~base_url =
  Provider_mock.local_provider_config
    ~base_url
    ~model_id:"mock-model"
    ~request_path:"/v1/chat/completions"
    ()
;;

let require_run_success label = function
  | Ok _ -> ()
  | Error error -> Alcotest.failf "%s: %s" label (Error.to_string error)
;;

(* ── Token accumulation tests ────────────────────────── *)

let test_tokens_accumulate_across_turns () =
  let call_count = ref 0 in
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) in
    incr call_count;
    let response_body =
      if !call_count <= 2
      then tool_body_with_usage ~input_tokens:100 ~output_tokens:50 ~tool_name:"echo"
      else text_body_with_usage ~input_tokens:100 ~output_tokens:50 "done"
    in
    Cohttp_eio.Server.respond_string ~status:`OK ~body:response_body ()
  in
  with_mock_server ~port:18301 handler (fun ~sw ~net ~base_url ->
    let tool =
      Tool.create ~name:"echo" ~description:"echo" ~parameters:[] (fun _input ->
        Ok { content = "ok"; _meta = None })
    in
    let options =
      { Agent.default_options with provider_config = Some (local_provider ~base_url) }
    in
    let config = default_config ~model:"mock-model" in
    let agent = Agent.create ~net ~config ~options ~tools:[ tool ] () in
    Agent.run ~sw agent "test" |> require_run_success "usage accumulation run";
    let st = Agent.state agent in
    (* 3 API calls: tool, tool, text — each with 100 input + 50 output *)
    Alcotest.(check int) "api calls" 3 st.usage.api_calls;
    Alcotest.(check int) "input tokens" 300 st.usage.total_input_tokens;
    Alcotest.(check int) "output tokens" 150 st.usage.total_output_tokens)
;;

let test_single_turn_usage () =
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) in
    let response_body =
      text_body_with_usage ~input_tokens:200 ~output_tokens:75 "hello"
    in
    Cohttp_eio.Server.respond_string ~status:`OK ~body:response_body ()
  in
  with_mock_server ~port:18302 handler (fun ~sw ~net ~base_url ->
    let options =
      { Agent.default_options with provider_config = Some (local_provider ~base_url) }
    in
    let agent =
      Agent.create ~config:(Types.default_config ~model:"mock-model") ~net ~options ()
    in
    Agent.run ~sw agent "test" |> require_run_success "single-turn usage run";
    let st = Agent.state agent in
    Alcotest.(check int) "1 api call" 1 st.usage.api_calls;
    Alcotest.(check int) "input" 200 st.usage.total_input_tokens;
    Alcotest.(check int) "output" 75 st.usage.total_output_tokens)
;;

(* ── Anthropic exclusive → inclusive normalisation (#27912) ──────────

   The Messages wire reports input_tokens exclusive of the cache
   components while api_usage.input_tokens is the inclusive prompt
   total, so a consumer deriving cache-miss input subtracts the two
   cache fields from it. Copy an exclusive wire count in verbatim and
   that subtraction takes the cache tokens off twice: the miss figure
   goes negative exactly when caching is working.

   The cases below pin the arithmetic and both parses the contract
   names -- sync response and SSE message_start. The rest of this file
   mocks the OpenAI shape, whose prompt_tokens is already inclusive,
   so none of it can see this. *)

let anthropic_response_body ~input_tokens ~cache_creation ~cache_read =
  Printf.sprintf
    {|{"id":"msg_1","type":"message","role":"assistant","model":"claude-x","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":%d,"output_tokens":7,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d}}|}
    input_tokens
    cache_creation
    cache_read
;;

(* [wire_input] is what the Messages wire called input_tokens, i.e. the
   regular input a consumer recovers by subtracting the cache components
   from the inclusive total. Under a verbatim copy that subtraction
   yields [wire_input - creation - read], which is negative here. *)
let check_usage label (u : Types.api_usage) ~wire_input ~creation ~read =
  Alcotest.(check int)
    (label ^ ": inclusive prompt total")
    (wire_input + creation + read)
    u.input_tokens;
  Alcotest.(check int) (label ^ ": cache creation") creation u.cache_creation_input_tokens;
  Alcotest.(check int) (label ^ ": cache read") read u.cache_read_input_tokens;
  Alcotest.(check int)
    (label ^ ": derived cache-miss input")
    wire_input
    (u.input_tokens - u.cache_creation_input_tokens - u.cache_read_input_tokens)
;;

let test_constructor_adds_cache_components () =
  let u =
    Llm_provider.Backend_anthropic.usage_of_wire_counts
      ~input_tokens:100
      ~output_tokens:7
      ~cache_creation_input_tokens:10
      ~cache_read_input_tokens:20
  in
  check_usage "constructor" u ~wire_input:100 ~creation:10 ~read:20
;;

let test_sync_response_parse_normalises () =
  let json =
    Yojson.Safe.from_string
      (anthropic_response_body ~input_tokens:100 ~cache_creation:10 ~cache_read:20)
  in
  let resp = Llm_provider.Backend_anthropic.parse_response json in
  match resp.usage with
  | None -> Alcotest.fail "sync response carried no usage"
  | Some u -> check_usage "sync parse" u ~wire_input:100 ~creation:10 ~read:20
;;

let test_message_start_parse_normalises () =
  let data =
    {|{"type":"message_start","message":{"id":"msg_1","model":"claude-x","usage":{"input_tokens":100,"output_tokens":7,"cache_creation_input_tokens":10,"cache_read_input_tokens":20}}}|}
  in
  match Llm_provider.Streaming.parse_sse_event (Some "message_start") data with
  | Some (MessageStart { usage = Some u; _ }) ->
    check_usage "message_start" u ~wire_input:100 ~creation:10 ~read:20
  | Some (MessageStart { usage = None; _ }) ->
    Alcotest.fail "message_start carried no usage"
  | Some _ | None -> Alcotest.fail "message_start did not parse"
;;

let test_uncached_request_is_unchanged () =
  let json =
    Yojson.Safe.from_string
      (anthropic_response_body ~input_tokens:100 ~cache_creation:0 ~cache_read:0)
  in
  let resp = Llm_provider.Backend_anthropic.parse_response json in
  match resp.usage with
  | None -> Alcotest.fail "sync response carried no usage"
  | Some u ->
    Alcotest.(check int) "no cache components, no adjustment" 100 u.input_tokens
;;

(* ── Suite ───────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run
    "Usage_accumulation"
    [ ( "accumulation"
      , [ test_case "tokens across turns" `Quick test_tokens_accumulate_across_turns
        ; test_case "single turn usage" `Quick test_single_turn_usage
        ] )
    ; ( "anthropic-inclusive-normalisation"
      , [ test_case
            "constructor adds cache components"
            `Quick
            test_constructor_adds_cache_components
        ; test_case
            "sync response parse normalises"
            `Quick
            test_sync_response_parse_normalises
        ; test_case
            "message_start parse normalises"
            `Quick
            test_message_start_parse_normalises
        ; test_case
            "uncached request is unchanged"
            `Quick
            test_uncached_request_is_unchanged
        ] )
    ]
;;
