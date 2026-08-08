(** Agent.run full-pipeline tests with mock HTTP server.
    Exercises: pipeline stages, api dispatch, tool execution,
    streaming, hooks, and context propagation.
    No real LLM — all responses are canned JSON. *)

open Agent_sdk
open Alcotest

(* ── Mock server: stateful, multi-response ──────────── *)

(* Openai Chat Completions format — Local provider routes through this since PR #308 *)
let openai_text_response ?(id = "chatcmpl-1") text =
  Printf.sprintf
    {|{"id":"%s","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}|}
    id
    text
;;

let escape_json_string s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
       match c with
       | '"' -> Buffer.add_string buf "\\\""
       | '\\' -> Buffer.add_string buf "\\\\"
       | _ -> Buffer.add_char buf c)
    s;
  Buffer.contents buf
;;

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if needle_len = 0
    then true
    else if idx + needle_len > haystack_len
    then false
    else if String.sub haystack idx needle_len = needle
    then true
    else loop (idx + 1)
  in
  loop 0
;;

let openai_tool_use_response tool_name input_json =
  Printf.sprintf
    {|{"id":"chatcmpl-t","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"%s","arguments":"%s"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":15,"completion_tokens":10,"total_tokens":25}}|}
    tool_name
    (escape_json_string input_json)
;;

(** Multi-response mock: returns responses in order, cycling. *)
let start_multi_mock ?(on_body = fun _ -> ()) ~sw ~net ~port (responses : string list) =
  let idx = Atomic.make 0 in
  let handler _conn _req body =
    let body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    on_body body;
    let n = List.length responses in
    let i = Atomic.fetch_and_add idx 1 in
    let resp = List.nth responses (i mod n) in
    Cohttp_eio.Server.respond_string ~status:`OK ~body:resp ()
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

let make_agent
      ~net
      ?(tools = [])
      ?hooks
      ?tool_choice
      ?pre_dispatch_serialization_observer
      ?(model_id = "mock-model")
      base_url
  =
  let config =
    { (Types.default_config ~model:"test-model") with name = "test-agent"; tool_choice }
  in
  let provider_config =
    Provider_mock.local_provider_config
      ~base_url
      ~model_id
      ~request_path:"/v1/chat/completions"
      ()
  in
  let options =
    { Agent.default_options with
      provider_config = Some provider_config
    ; hooks =
        (match hooks with
         | Some h -> h
         | None -> Hooks.empty)
    }
  in
  Agent.create ~net ~config ~tools ~options ?pre_dispatch_serialization_observer ()
;;

let extract_text (resp : Types.api_response) =
  List.filter_map
    (function
      | Types.Text s -> Some s
      | _ -> None)
    resp.content
  |> String.concat ""
;;

(* ── Test 1: Simple text response ────────────────────── *)

let test_agent_run_simple () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_multi_mock
        ~sw
        ~net:env#net
        ~port:20001
        [ openai_text_response "hello pipeline" ]
    in
    let agent = make_agent ~net:env#net url in
    match Agent.run ~sw agent "test prompt" with
    | Ok resp ->
      check string "text" "hello pipeline" (extract_text resp);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── Test 2: Tool use → tool result → final text ─────── *)

let test_agent_run_tool_use () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let responses =
      [ (* Turn 1: model calls a tool *)
        openai_tool_use_response "get_time" {|{"timezone": "UTC"}|}
      ; (* Turn 2: model responds with text after tool result *)
        openai_text_response "The time is 12:00 UTC"
      ]
    in
    let url = start_multi_mock ~sw ~net:env#net ~port:20002 responses in
    (* Define the tool *)
    let time_tool =
      Tool.create
        ~name:"get_time"
        ~description:"Get current time"
        ~parameters:
          [ { name = "timezone"
            ; param_type = Types.String
            ; description = "tz"
            ; required = true
            }
          ]
        (fun _input -> Ok { Types.content = "12:00 UTC"; _meta = None })
    in
    let agent = make_agent ~net:env#net ~tools:[ time_tool ] url in
    match Agent.run ~sw agent "what time is it?" with
    | Ok resp ->
      check string "final text" "The time is 12:00 UTC" (extract_text resp);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

let test_agent_run_long_tool_sequence_completes () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let responses =
      List.init 12 (fun i ->
        openai_tool_use_response "loop_tool" (Printf.sprintf {|{"i":%d}|} i))
      @ [ openai_text_response "done" ]
    in
    let url = start_multi_mock ~sw ~net:env#net ~port:20032 responses in
    let loop_tool =
      Tool.create
        ~name:"loop_tool"
        ~description:"Called repeatedly"
        ~parameters:
          [ { Types.name = "i"
            ; description = "iteration"
            ; param_type = Types.Integer
            ; required = false
            }
          ]
        (fun _input -> Ok { Types.content = "looped"; _meta = None })
    in
    let agent = make_agent ~net:env#net ~tools:[ loop_tool ] url in
    match Agent.run ~sw agent "complete a long tool sequence" with
    | Ok resp ->
      check string "final text" "done" (extract_text resp);
      check bool "turn count observed" true ((Agent.state agent).turn_count > 10);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── Test 4: With hooks ──────────────────────────────── *)

let test_agent_run_with_hooks () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_multi_mock ~sw ~net:env#net ~port:20004 [ openai_text_response "hooked" ]
    in
    let before_count = ref 0 in
    let after_count = ref 0 in
    let hooks =
      { Hooks.empty with
        before_turn =
          Some
            (fun _event ->
              incr before_count;
              Hooks.Continue)
      ; after_turn =
          Some
            (fun _event ->
              incr after_count;
              Hooks.Continue)
      }
    in
    let agent = make_agent ~net:env#net ~hooks url in
    match Agent.run ~sw agent "hook test" with
    | Ok resp ->
      check string "text" "hooked" (extract_text resp);
      check bool "before called" true (!before_count > 0);
      check bool "after called" true (!after_count > 0);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── Test 6: Agent.run_stream ────────────────────────── *)

let openai_sse text =
  Printf.sprintf
    "data: \
     {\"id\":\"chatcmpl-s1\",\"object\":\"chat.completion.chunk\",\"model\":\"mock\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n\
     data: \
     {\"id\":\"chatcmpl-s1\",\"object\":\"chat.completion.chunk\",\"model\":\"mock\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"%s\"},\"finish_reason\":null}]}\n\n\
     data: \
     {\"id\":\"chatcmpl-s1\",\"object\":\"chat.completion.chunk\",\"model\":\"mock\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n\
     data: [DONE]\n\n"
    text
;;

let start_sse_mock ?(on_body = fun _ -> ()) ~sw ~net ~port sse_body =
  let handler _conn _req body =
    let body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    on_body body;
    let headers = Cohttp.Header.of_list [ "content-type", "text/event-stream" ] in
    Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body:sse_body ()
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

let test_agent_run_stream () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_sse_mock ~sw ~net:env#net ~port:20006 (openai_sse "stream pipeline")
    in
    let agent = make_agent ~net:env#net url in
    let events = ref [] in
    match
      Agent.run_stream ~sw ~on_event:(fun e -> events := e :: !events) agent "stream test"
    with
    | Ok resp ->
      check string "text" "stream pipeline" (extract_text resp);
      check bool "events" true (List.length !events > 0);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

let check_pre_dispatch_serialization ~label ~body observations =
  match List.rev observations with
  | [ observation ] ->
    check
      bool
      (label ^ " phase")
      true
      (observation.Llm_provider.Request_wire_observer.phase
       = Llm_provider.Request_wire_observer.Pre_dispatch_serialization);
    check int (label ^ " body bytes") (String.length body) observation.body_bytes;
    check
      string
      (label ^ " body digest")
      Digestif.SHA256.(to_hex (digest_string body))
      observation.body_sha256
  | observations -> failf "%s observer called %d times" label (List.length observations)
;;

let test_agent_run_observes_pre_dispatch_serialization () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let bodies = ref [] in
    let observations = ref [] in
    let url =
      start_multi_mock
        ~on_body:(fun body -> bodies := body :: !bodies)
        ~sw
        ~net:env#net
        ~port:20033
        [ openai_text_response "observed sync" ]
    in
    let agent =
      make_agent
        ~net:env#net
        ~pre_dispatch_serialization_observer:(fun observation ->
          observations := observation :: !observations;
          Ok ())
        url
    in
    (match Agent.run ~sw agent "observe sync serialization" with
     | Ok _ -> ()
     | Error error -> fail (Error.to_string error));
    (match List.rev !bodies with
     | [ body ] ->
       check_pre_dispatch_serialization
         ~label:"Agent.run compatibility"
         ~body
         !observations
     | bodies -> failf "sync server received %d bodies" (List.length bodies));
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_agent_run_stream_observes_pre_dispatch_serialization () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let bodies = ref [] in
    let observations = ref [] in
    let url =
      start_sse_mock
        ~on_body:(fun body -> bodies := body :: !bodies)
        ~sw
        ~net:env#net
        ~port:20034
        (openai_sse "observed stream")
    in
    let agent =
      make_agent
        ~net:env#net
        ~pre_dispatch_serialization_observer:(fun observation ->
          observations := observation :: !observations;
          Ok ())
        url
    in
    (match
       Agent.run_stream ~sw ~on_event:(fun _ -> ()) agent "observe stream serialization"
     with
     | Ok _ -> ()
     | Error error -> fail (Error.to_string error));
    (match List.rev !bodies with
     | [ body ] ->
       check_pre_dispatch_serialization
         ~label:"Agent.run_stream compatibility"
         ~body
         !observations
     | bodies -> failf "stream server received %d bodies" (List.length bodies));
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── Test 7: Tool handler error ──────────────────────── *)

let test_agent_run_tool_error () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let responses =
      [ openai_tool_use_response "fail_tool" {|{}|}
      ; openai_text_response "recovered from tool error"
      ]
    in
    let url = start_multi_mock ~sw ~net:env#net ~port:20007 responses in
    let fail_tool =
      Tool.create
        ~name:"fail_tool"
        ~description:"Always fails"
        ~parameters:[]
        (fun _input ->
           Error { Types.message = "tool broke"; recoverable = true; error_class = None })
    in
    let agent = make_agent ~net:env#net ~tools:[ fail_tool ] url in
    match Agent.run ~sw agent "trigger error" with
    | Ok resp ->
      check string "recovered" "recovered from tool error" (extract_text resp);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── Test 8: PreToolUse hook blocks tool ─────────────── *)

let test_agent_run_pre_tool_hook () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let responses =
      [ openai_tool_use_response "blocked_tool" {|{}|}
      ; openai_text_response "after block"
      ]
    in
    let url = start_multi_mock ~sw ~net:env#net ~port:20008 responses in
    let blocked_tool =
      Tool.create
        ~name:"blocked_tool"
        ~description:"Should be blocked"
        ~parameters:[]
        (fun _input -> Ok { Types.content = "should not run"; _meta = None })
    in
    let hooks =
      { Hooks.empty with pre_tool_use = Some (fun _event -> Hooks.Block "blocked") }
    in
    let agent = make_agent ~net:env#net ~tools:[ blocked_tool ] ~hooks url in
    match Agent.run ~sw agent "block tool" with
    | Ok _resp -> Eio.Switch.fail sw Exit
    | Error e ->
      let _ = Error.to_string e in
      Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── Test 9: HTTP 500 → sdk_error ────────────────────── *)

let start_error_mock ~sw ~net ~port status =
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    Cohttp_eio.Server.respond_string ~status ~body:"server error" ()
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

let start_status_mock ~sw ~net ~port (responses : (Cohttp.Code.status_code * string) list)
  =
  let idx = Atomic.make 0 in
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let n = List.length responses in
    let i = Atomic.fetch_and_add idx 1 in
    let status, body = List.nth responses (if i < n then i else n - 1) in
    Cohttp_eio.Server.respond_string ~status ~body ()
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
  Printf.sprintf "http://127.0.0.1:%d" port, idx
;;

let test_agent_run_http_error () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_error_mock ~sw ~net:env#net ~port:20009 `Internal_server_error in
    let agent = make_agent ~net:env#net url in
    match Agent.run ~sw agent "should fail" with
    | Ok _ -> fail "expected Error"
    | Error e ->
      let msg = Error.to_string e in
      check bool "error message" true (String.length msg > 0);
      Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_agent_run_context_like_http_400_is_unknown_invalid_request_without_retry () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let context_like_error_body =
      {|{"error":{"message":"This model's maximum context length is 128000 tokens. available context size (128)"}}|}
    in
    let url, calls =
      start_status_mock
        ~sw
        ~net:env#net
        ~port:20020
        [ `Bad_request, context_like_error_body
        ; `OK, openai_text_response "should not retry"
        ]
    in
    let provider_config =
      Provider_mock.local_provider_config
        ~base_url:url
        ~model_id:"mock-model"
        ~request_path:"/v1/chat/completions"
        ()
    in
    let config =
      { (Types.default_config ~model:"test-model") with name = "context-overflow-owner" }
    in
    let options = { Agent.default_options with provider_config = Some provider_config } in
    let agent = Agent.create ~net:env#net ~config ~options () in
    let history =
      [ { Types.role = User
        ; content = [ Text "summarize the large result" ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      ; { Types.role = Assistant
        ; content =
            [ ToolUse
                { id = "tool_1"; name = "search"; input = `Assoc [ "q", `String "logs" ] }
            ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      ; { Types.role = Tool
        ; content =
            [ ToolResult
                { tool_use_id = "tool_1"
                ; content = String.make 2000 'x'
                ; outcome = Tool_succeeded
                ; json = None
                ; content_blocks = None
                }
            ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      ]
    in
    Agent.update_state agent (fun state -> { state with messages = history });
    match Agent.run ~sw agent "continue" with
    | Ok _ -> fail "expected InvalidRequest Unknown_invalid_request"
    | Error
        (Error.Api
           (Retry.InvalidRequest { reason = Retry.Unknown_invalid_request; message = _ }))
      ->
      check int "no internal retry" 1 (Atomic.get calls);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── Runner ──────────────────────────────────────────── *)

let () =
  run
    "agent_pipeline"
    [ ( "basic"
      , [ test_case "simple text" `Quick test_agent_run_simple
        ; test_case
            "long tool sequence completes"
            `Quick
            test_agent_run_long_tool_sequence_completes
        ; test_case "http error" `Quick test_agent_run_http_error
        ; test_case
            "context-like HTTP 400 is unknown invalid request without retry"
            `Quick
            test_agent_run_context_like_http_400_is_unknown_invalid_request_without_retry
        ] )
    ; ( "tools"
      , [ test_case "tool use cycle" `Quick test_agent_run_tool_use
          (* Forced-tool completion-contract tests removed in RFC-OAS-025
             Option A (forced-tool enforcement moved out of the SDK). *)
        ; test_case "tool error" `Quick test_agent_run_tool_error
        ; test_case "pre_tool hook" `Quick test_agent_run_pre_tool_hook
        ] )
    ; ( "streaming"
      , [ test_case "run_stream" `Quick test_agent_run_stream
        ; test_case
            "run_stream pre-dispatch serialization observer"
            `Quick
            test_agent_run_stream_observes_pre_dispatch_serialization
        ] )
    ; "hooks", [ test_case "hooks" `Quick test_agent_run_with_hooks ]
    ; ( "observation"
      , [ test_case
            "run pre-dispatch serialization observer"
            `Quick
            test_agent_run_observes_pre_dispatch_serialization
        ] )
    ]
;;
