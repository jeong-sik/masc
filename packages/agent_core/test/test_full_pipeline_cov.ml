(** Full-pipeline coverage tests with mock HTTP server.
    Exercises Agent.run end-to-end: api.ml, provider_intf.ml, pipeline.ml,
    backend_openai.ml, complete.ml, streaming.ml, structured.ml,
    agent_tools.ml, provider routing, mcp, error paths.

    All responses are canned JSON. No real LLM calls. *)

open Agent_sdk
open Alcotest

let card_interfaces =
  Agent_card.create_supported_interface
    ~url:"https://test-agent.example/a2a"
    ~protocol_binding:"JSONRPC"
    ~protocol_version:"1.0"
    ()
  |> Result.get_ok
  |> fun interface -> Agent_card.supported_interfaces interface []
;;

(* ── Mock server helpers ──────────────────────────────────────── *)

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

let openai_text_response ?(id = "chatcmpl-1") text =
  Printf.sprintf
    {|{"id":"%s","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}|}
    id
    (escape_json_string text)
;;

let openai_tool_use ?(id = "chatcmpl-t") tool_name input_json =
  Printf.sprintf
    {|{"id":"%s","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"%s","arguments":"%s"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":15,"completion_tokens":10,"total_tokens":25}}|}
    id
    tool_name
    (escape_json_string input_json)
;;

let openai_multi_content tool_name input_json text =
  Printf.sprintf
    {|{"id":"chatcmpl-m","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"%s","tool_calls":[{"id":"call_2","type":"function","function":{"name":"%s","arguments":"%s"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":20,"completion_tokens":15,"total_tokens":35}}|}
    (escape_json_string text)
    tool_name
    (escape_json_string input_json)
;;

let openai_response text =
  Printf.sprintf
    {|{"id":"chatcmpl-1","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}|}
    (escape_json_string text)
;;

let openai_sse text =
  Printf.sprintf
    "data: \
     {\"id\":\"chatcmpl-s1\",\"object\":\"chat.completion.chunk\",\"model\":\"mock\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"%s\"},\"finish_reason\":null}]}\n\n\
     data: \
     {\"id\":\"chatcmpl-s1\",\"object\":\"chat.completion.chunk\",\"model\":\"mock\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}\n\n\
     data: [DONE]\n\n"
    (escape_json_string text)
;;

(** Multi-response mock server cycling through responses. *)
let start_multi ~sw ~net ~port responses =
  let idx = Atomic.make 0 in
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
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

let start_sse ~sw ~net ~port body =
  let handler _conn _req b =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int b |> take_all) in
    let headers = Cohttp.Header.of_list [ "content-type", "text/event-stream" ] in
    Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body ()
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

let start_error ~sw ~net ~port status =
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

let start_malformed_json ~sw ~net ~port =
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    Cohttp_eio.Server.respond_string ~status:`OK ~body:"not json at all {{{" ()
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

let local_provider_config ~base_url ~model_id =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~provider_id:"test"
    ~model_id
    ~base_url
    ~api_key:""
    ~headers:[ "Content-Type", "application/json" ]
    ~request_path:"/v1/chat/completions"
    ()
;;

let make_agent ~net ?(tools = []) ?hooks ?provider_config base_url =
  let config = { (Types.default_config ~model:"test-model") with name = "cov-agent" } in
  let provider_config =
    match provider_config with
    | Some p -> Some p
    | None -> Some (local_provider_config ~base_url ~model_id:"mock-model")
  in
  let options =
    { Agent.default_options with
      provider_config
    ; hooks =
        (match hooks with
         | Some h -> h
         | None -> Hooks.empty)
    }
  in
  Agent.create ~net ~config ~tools ~options ()
;;

let extract_text (resp : Types.api_response) =
  List.filter_map
    (function
      | Types.Text s -> Some s
      | _ -> None)
    resp.content
  |> String.concat ""
;;

(* ── 1. Basic text completion ──────────────────────────────────── *)

let test_basic_text () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_multi ~sw ~net:env#net ~port:21001 [ openai_text_response "hello coverage" ]
    in
    let agent = make_agent ~net:env#net url in
    match Agent.run ~sw agent "hi" with
    | Ok resp ->
      check string "text" "hello coverage" (extract_text resp);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── 2. Tool calling loop ─────────────────────────────────────── *)

let test_tool_call_loop () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let responses =
      [ openai_tool_use "calc" {|{"x":42}|}; openai_text_response "result is 42" ]
    in
    let url = start_multi ~sw ~net:env#net ~port:21002 responses in
    let tool =
      Tool.create
        ~name:"calc"
        ~description:"Calculate"
        ~parameters:
          [ { name = "x"
            ; param_type = Types.Integer
            ; description = "number"
            ; required = true
            }
          ]
        (fun input ->
           let x = Yojson.Safe.Util.(input |> member "x" |> to_int) in
           Ok { Types.content = string_of_int x; _meta = None })
    in
    let agent = make_agent ~net:env#net ~tools:[ tool ] url in
    match Agent.run ~sw agent "calc 42" with
    | Ok resp ->
      check string "final" "result is 42" (extract_text resp);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── 3. Multiple tool calls in one response ────────────────────── *)

let test_multi_content_tool () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let responses =
      [ openai_multi_content "greet" {|{"name":"test"}|} "thinking..."
      ; openai_text_response "done"
      ]
    in
    let url = start_multi ~sw ~net:env#net ~port:21003 responses in
    let tool =
      Tool.create
        ~name:"greet"
        ~description:"Greet"
        ~parameters:
          [ { name = "name"
            ; param_type = Types.String
            ; description = "who"
            ; required = true
            }
          ]
        (fun _input -> Ok { Types.content = "hello"; _meta = None })
    in
    let agent = make_agent ~net:env#net ~tools:[ tool ] url in
    match Agent.run ~sw agent "greet" with
    | Ok resp ->
      check string "text" "done" (extract_text resp);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── 4. Streaming SSE ──────────────────────────────────────────── *)

let test_streaming_sse () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_sse ~sw ~net:env#net ~port:21004 (openai_sse "streamed text") in
    let agent = make_agent ~net:env#net url in
    let events = ref [] in
    match
      Agent.run_stream ~sw ~on_event:(fun e -> events := e :: !events) agent "stream"
    with
    | Ok resp ->
      check string "text" "streamed text" (extract_text resp);
      check bool "events collected" true (List.length !events > 0);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── 5. HTTP 500 error ─────────────────────────────────────────── *)

let test_http_500 () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_error ~sw ~net:env#net ~port:21005 `Internal_server_error in
    let agent = make_agent ~net:env#net url in
    match Agent.run ~sw agent "boom" with
    | Ok _ -> fail "expected error"
    | Error e ->
      check bool "error msg" true (String.length (Error.to_string e) > 0);
      Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── 6. HTTP 429 rate limit ───────────────────────────────────── *)

let test_http_429 () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_error ~sw ~net:env#net ~port:21006 `Too_many_requests in
    let agent = make_agent ~net:env#net url in
    match Agent.run ~sw agent "rate limited" with
    | Ok _ -> fail "expected error"
    | Error e ->
      check bool "error" true (String.length (Error.to_string e) > 0);
      Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── 7. Malformed JSON response ────────────────────────────────── *)

let test_malformed_json () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_malformed_json ~sw ~net:env#net ~port:21007 in
    let agent = make_agent ~net:env#net url in
    match Agent.run ~sw agent "bad json" with
    | Ok _ -> fail "expected error"
    | Error e ->
      check bool "error" true (String.length (Error.to_string e) > 0);
      Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── 8. Tool error recovery ───────────────────────────────────── *)

let test_tool_error_recovery () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let responses =
      [ openai_tool_use "bad_tool" {|{}|}; openai_text_response "recovered" ]
    in
    let url = start_multi ~sw ~net:env#net ~port:21008 responses in
    let tool =
      Tool.create ~name:"bad_tool" ~description:"Fails" ~parameters:[] (fun _input ->
        Error { Types.message = "broken"; recoverable = true; error_class = None })
    in
    let agent = make_agent ~net:env#net ~tools:[ tool ] url in
    match Agent.run ~sw agent "fail" with
    | Ok resp ->
      check string "text" "recovered" (extract_text resp);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── 10. Hooks: before_turn, after_turn ───────────────────────── *)

let test_hooks_turn () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_multi ~sw ~net:env#net ~port:21010 [ openai_text_response "hooked" ]
    in
    let before_count = ref 0 in
    let after_count = ref 0 in
    let hooks =
      { Hooks.empty with
        before_turn =
          Some
            (fun _e ->
              incr before_count;
              Hooks.Continue)
      ; after_turn =
          Some
            (fun _e ->
              incr after_count;
              Hooks.Continue)
      }
    in
    let agent = make_agent ~net:env#net ~hooks url in
    match Agent.run ~sw agent "test" with
    | Ok _ ->
      check bool "before" true (!before_count > 0);
      check bool "after" true (!after_count > 0);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* PreToolUse hook block. *)

let test_pre_tool_block () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let responses =
      [ openai_tool_use "blocked" {|{}|}; openai_text_response "blocked result" ]
    in
    let url = start_multi ~sw ~net:env#net ~port:21013 responses in
    let tool =
      Tool.create ~name:"blocked" ~description:"Blocked" ~parameters:[] (fun _input ->
        Ok { Types.content = "should not run"; _meta = None })
    in
    let hooks =
      { Hooks.empty with pre_tool_use = Some (fun _e -> Hooks.Block "blocked") }
    in
    let agent = make_agent ~net:env#net ~tools:[ tool ] ~hooks url in
    match Agent.run ~sw agent "block" with
    | Ok _ -> Eio.Switch.fail sw Exit
    | Error _ -> Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── 14. OpenAI-compatible provider ───────────────────────────── *)

let test_openai_compat () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_multi ~sw ~net:env#net ~port:21014 [ openai_response "openai hello" ]
    in
    let provider_config = local_provider_config ~base_url:url ~model_id:"mock-openai" in
    let config =
      { (Types.default_config ~model:"test-model") with name = "openai-agent" }
    in
    let options = { Agent.default_options with provider_config = Some provider_config } in
    let a = Agent.create ~net:env#net ~config ~options () in
    match Agent.run ~sw a "hello" with
    | Ok resp ->
      check string "text" "openai hello" (extract_text resp);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── 15. Agent clone and run ──────────────────────────────────── *)

let test_agent_clone_run () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let url =
      start_multi ~sw ~net:env#net ~port:21015 [ openai_text_response "cloned" ]
    in
    let agent = make_agent ~net:env#net url in
    let cloned = Agent.clone agent in
    match Agent.run ~sw cloned "test clone" with
    | Ok resp ->
      check string "text" "cloned" (extract_text resp);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── 16. Structured output via provider-native JSON schema ────── *)

let test_structured_extract () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let body = openai_text_response {|{"name":"test","age":25}|} in
    let url = start_multi ~sw ~net:env#net ~port:21016 [ body ] in
    let provider_id = "full-pipeline-structured-mock" in
    let previous_provider_catalog = Llm_provider.Provider_catalog.global () in
    Eio.Switch.on_release sw (fun () ->
      match previous_provider_catalog with
      | Some catalog -> Llm_provider.Provider_catalog.set_global catalog
      | None -> Llm_provider.Provider_catalog.clear_global ());
    let provider_capabilities =
      { Llm_provider.Capabilities.default_capabilities with
        supports_response_format_json = true
      ; supports_structured_output = true
      }
    in
    let provider_entry : Llm_provider.Provider_catalog.entry =
      { id = provider_id
      ; aliases = []
      ; kind = Llm_provider.Provider_config.OpenAI_compat
      ; base_url = url
      ; request_path = "/v1/chat/completions"
      ; api_key_env = ""
      ; auth = Llm_provider.Provider_catalog.No_auth
      ; default_model = Some "test-model"
      ; max_context = None
      ; capabilities = provider_capabilities
      ; credential_scope = None
      }
    in
    let provider_catalog =
      match Llm_provider.Provider_catalog.of_entries [ provider_entry ] with
      | Ok catalog -> catalog
      | Error msg -> fail msg
    in
    Llm_provider.Provider_catalog.set_global provider_catalog;
    let schema : (string * int) Structured.schema =
      { params =
          [ { name = "name"
            ; param_type = Types.String
            ; description = "name"
            ; required = true
            }
          ; { name = "age"
            ; param_type = Types.Integer
            ; description = "age"
            ; required = true
            }
          ]
      ; parse =
          (fun json ->
            let open Yojson.Safe.Util in
            Ok (json |> member "name" |> to_string, json |> member "age" |> to_int))
      }
    in
    let config =
      { (Types.default_config ~model:"test-model") with name = "struct-agent" }
    in
    let provider_config =
      Llm_provider.Provider_config.make
        ~kind:Llm_provider.Provider_config.OpenAI_compat
        ~provider_id
        ~model_id:"test-model"
        ~base_url:url
        ~api_key:""
        ~headers:[ "Content-Type", "application/json" ]
        ~request_path:"/v1/chat/completions"
        ~supports_structured_output_override:true
        ~model_capabilities_override:provider_capabilities
        ()
    in
    match
      Structured.extract ~sw ~net:env#net ~provider_config ~config ~schema "extract"
    with
    | Ok (name, age) ->
      check string "name" "test" name;
      check int "age" 25 age;
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── 17. Structured schema_to_json_schema ───────────────────────── *)

let test_schema_to_json () =
  let schema : unit Structured.schema =
    { params =
        [ { name = "x"; param_type = Types.Integer; description = "num"; required = true }
        ; { name = "y"; param_type = Types.String; description = "str"; required = false }
        ]
    ; parse = (fun _ -> Ok ())
    }
  in
  let json = Structured.schema_to_json_schema schema in
  let open Yojson.Safe.Util in
  check string "schema type" "object" (json |> member "type" |> to_string);
  check
    string
    "x type"
    "integer"
    (json |> member "properties" |> member "x" |> member "type" |> to_string)
;;

let test_agent_card () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun _sw ->
  let url = "http://127.0.0.1:21019" in
  let agent = make_agent ~net:env#net url in
  let card = Agent.card ~supported_interfaces:card_interfaces agent in
  check string "card name" "cov-agent" card.name
;;

(* ── 20. Context-aware tool ───────────────────────────────────── *)

let test_context_tool () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let responses =
      [ openai_tool_use "ctx_tool" {|{"key":"val"}|}; openai_text_response "ctx done" ]
    in
    let url = start_multi ~sw ~net:env#net ~port:21020 responses in
    let tool =
      Tool.of_schema
        (Types.tool_schema_of_params
           ~name:"ctx_tool"
           ~description:"Context tool"
           ~parameters:
             [ { name = "key"
               ; param_type = Types.String
               ; description = "k"
               ; required = true
               }
             ]
           ())
        (Tool.requiring_context (fun _ctx _input ->
           Ok { Types.content = "ctx_result"; _meta = None }))
    in
    let agent = make_agent ~net:env#net ~tools:[ tool ] url in
    match Agent.run ~sw agent "ctx" with
    | Ok resp ->
      check string "text" "ctx done" (extract_text resp);
      Eio.Switch.fail sw Exit
    | Error e -> fail (Error.to_string e)
  with
  | Exit -> ()
;;

(* ── Suite ─────────────────────────────────────────────────────── *)

let () =
  run
    "full_pipeline_cov"
    [ ( "basic"
      , [ test_case "text completion" `Quick test_basic_text
        ; test_case "openai compat" `Quick test_openai_compat
        ; test_case "agent clone" `Quick test_agent_clone_run
        ; test_case "agent card" `Quick test_agent_card
        ] )
    ; ( "tools"
      , [ test_case "tool call loop" `Quick test_tool_call_loop
        ; test_case "multi content" `Quick test_multi_content_tool
        ; test_case "tool error recovery" `Quick test_tool_error_recovery
        ; test_case "context tool" `Quick test_context_tool
        ; test_case "pre_tool block" `Quick test_pre_tool_block
        ] )
    ; "streaming", [ test_case "sse streaming" `Quick test_streaming_sse ]
    ; ( "structured"
      , [ test_case "extract" `Quick test_structured_extract
        ; test_case "schema json" `Quick test_schema_to_json
        ] )
    ; ( "errors"
      , [ test_case "http 500" `Quick test_http_500
        ; test_case "http 429" `Quick test_http_429
        ; test_case "malformed json" `Quick test_malformed_json
        ] )
    ; "hooks", [ test_case "turn hooks" `Quick test_hooks_turn ]
    ]
;;
