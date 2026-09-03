(** Agent.run full-pipeline tests with mock HTTP server.
    Exercises: pipeline stages, api dispatch, tool execution,
    streaming, hooks, and context propagation.
    No real LLM — all responses are canned JSON. *)

open Agent_core
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


let openai_tool_use_response tool_name input_json =
  Printf.sprintf
    {|{"id":"chatcmpl-t","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"%s","arguments":"%s"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":15,"completion_tokens":10,"total_tokens":25}}|}
    tool_name
    (escape_json_string input_json)
;;

let openai_two_tool_use_response first_name second_name =
  Printf.sprintf
    {|{"id":"chatcmpl-t","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"%s","arguments":"{}"}},{"id":"call_2","type":"function","function":{"name":"%s","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":15,"completion_tokens":10,"total_tokens":25}}|}
    first_name
    second_name
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

(* ── Test 9: HTTP 500 → core_error ────────────────────── *)

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


(* ── Tool-name admission: the transcript must not replay an unroutable name ──

   masc#29337. A provider returned [Execute-1.1111e1111111] once; the block
   stayed in the transcript, so every later request carried it as a well-formed
   example of calling that tool and the model reproduced it 115 times over
   2h17m. The same byte string survived a lane switch between two unrelated
   providers, which only the transcript can explain.

   The measurement that matters is therefore not the reject message but the
   NEXT REQUEST BODY -- and specifically which role carries the name. What the
   model copies is its own prior turn: an assistant [tool_call] is a worked
   example. A user turn that quotes the name to refuse it is the opposite, and
   withholding the name there is what left the model nothing to correct. Live
   2026-09-02: one conversation carried six nameless refusals, each for a
   single call, because the model could not tell which of its calls was
   dropped -- the block is gone from its own history by then.

   So the assertion is per role: absent from every assistant turn, present in
   the user refusal.
*)

(* Kept local and dependency-free: the assertions below run against raw request
   bodies, and pulling [Str] into this suite for one substring scan would be a
   heavier change than the scan itself. *)
let string_contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  n = 0 || scan 0
;;

let unroutable_tool_name = "Execute-1.1111e1111111"

let execute_tool =
  Tool.create ~name:"Execute" ~description:"Run argv" ~parameters:[] (fun _ ->
    Ok { Types.content = "ran"; _meta = None })
;;

(* Role matters to the assertions below, so the body is read as messages
   rather than scanned as one string. *)
let request_messages body =
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "messages" fields with
     | Some (`List messages) ->
       List.filter_map
         (function
           | `Assoc message_fields as message ->
             (match List.assoc_opt "role" message_fields with
              | Some (`String role) -> Some (role, Yojson.Safe.to_string message)
              | _ -> None)
           | _ -> None)
         messages
     | _ -> failf "request body carries no messages array")
  | _ -> failf "request body is not a JSON object"
;;

let second_request_body bodies =
  match List.rev bodies with
  | _ :: second :: _ -> second
  | bodies -> failf "expected at least two requests, got %d" (List.length bodies)
;;

let test_unroutable_tool_name_is_refused_not_replayed () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let bodies = ref [] in
    let url =
      start_multi_mock
        ~on_body:(fun body -> bodies := body :: !bodies)
        ~sw
        ~net:env#net
        ~port:20041
        [ openai_tool_use_response unroutable_tool_name "{}"
        ; openai_text_response "done"
        ]
    in
    let agent = make_agent ~net:env#net ~tools:[ execute_tool ] url in
    (match Agent.run ~sw agent "call a tool" with
     | Ok _ -> ()
     | Error error ->
       (* The turn routed nowhere, but a keeper that cannot route one call is
          not a keeper that should stop taking turns. *)
       failf "run must survive an unroutable call: %s" (Error.to_string error));
    let body = second_request_body !bodies in
    let carried_by role =
      List.exists
        (fun (message_role, text) ->
           String.equal message_role role
           && string_contains ~needle:unroutable_tool_name text)
        (request_messages body)
    in
    check
      bool
      "no assistant turn replays the unroutable name as a call"
      false
      (carried_by "assistant");
    check
      bool
      "model is told the call was dropped"
      true
      (string_contains ~needle:"named no registered tool" body);
    check bool "the refusal names the call it dropped" true (carried_by "user");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* A turn that routes something and drops something else. Before this, the
   refusal was skipped entirely whenever any call routed: the model got results
   for what worked and silence for the rest, and its own dropped block is gone
   from the transcript by then, so silence left it nothing to correct.

   The refusal lands after the tool results, not before them -- a User message
   between the assistant's tool_use blocks and their tool_results is the one
   position the pairing cannot take. *)
let test_mixed_turn_refuses_the_call_it_dropped () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let bodies = ref [] in
    let url =
      start_multi_mock
        ~on_body:(fun body -> bodies := body :: !bodies)
        ~sw
        ~net:env#net
        ~port:20043
        [ openai_two_tool_use_response "Execute" unroutable_tool_name
        ; openai_text_response "done"
        ]
    in
    let agent = make_agent ~net:env#net ~tools:[ execute_tool ] url in
    (match Agent.run ~sw agent "call two tools" with
     | Ok _ -> ()
     | Error error ->
       failf "run must survive a partially unroutable turn: %s" (Error.to_string error));
    let body = second_request_body !bodies in
    let messages = request_messages body in
    let carried_by role =
      List.exists
        (fun (message_role, text) ->
           String.equal message_role role
           && string_contains ~needle:unroutable_tool_name text)
        messages
    in
    check
      bool
      "the routable call still ran"
      true
      (List.exists
         (fun (role, text) ->
            String.equal role "tool" && string_contains ~needle:"ran" text)
         messages);
    check
      bool
      "no assistant turn replays the unroutable name as a call"
      false
      (carried_by "assistant");
    check
      bool
      "the model is told about the dropped call"
      true
      (string_contains ~needle:"named no registered tool" body);
    check bool "the refusal names it" true (carried_by "user");
    (* Position, not just presence: a refusal that landed before the results
       would separate the tool_use blocks from their tool_results. *)
    let index_of predicate =
      let rec walk index = function
        | [] -> -1
        | entry :: rest -> if predicate entry then index else walk (index + 1) rest
      in
      walk 0 messages
    in
    let last_tool_index =
      let rec walk index found = function
        | [] -> found
        | (role, _) :: rest ->
          walk (index + 1) (if String.equal role "tool" then index else found) rest
      in
      walk 0 (-1) messages
    in
    let refusal_index =
      index_of (fun (role, text) ->
        String.equal role "user" && string_contains ~needle:"named no registered tool" text)
    in
    check bool "a tool result message exists" true (last_tool_index >= 0);
    check bool "the refusal follows the tool results" true (refusal_index > last_tool_index);
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* The call-number recovery landed in #29999 fixed dispatch but not the
   transcript: the fused spelling stayed in history and kept being replayed.
   Recovery is only complete when the next request carries the stem. *)
let test_recovered_tool_name_is_replayed_as_the_registered_name () =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let bodies = ref [] in
    let fused = "Execute1139645993.1" in
    let url =
      start_multi_mock
        ~on_body:(fun body -> bodies := body :: !bodies)
        ~sw
        ~net:env#net
        ~port:20042
        [ openai_tool_use_response fused "{}"; openai_text_response "done" ]
    in
    let agent = make_agent ~net:env#net ~tools:[ execute_tool ] url in
    (match Agent.run ~sw agent "call a tool" with
     | Ok _ -> ()
     | Error error -> failf "run failed: %s" (Error.to_string error));
    let body = second_request_body !bodies in
    check
      bool
      "next request does not replay the fused spelling"
      false
      (string_contains ~needle:fused body);
    check
      bool
      "next request carries the registered name"
      true
      (string_contains ~needle:{|"name":"Execute"|} body);
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

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
          (* Forced-tool completion-contract tests removed in Agent Core contract
             Option A (forced-tool enforcement moved out of agent core). *)
        ; test_case "tool error" `Quick test_agent_run_tool_error
        ; test_case "pre_tool hook" `Quick test_agent_run_pre_tool_hook
        ] )
    ; ( "tool name admission"
      , [ test_case
            "unroutable name is refused, not replayed"
            `Quick
            test_unroutable_tool_name_is_refused_not_replayed
        ; test_case
            "a mixed turn refuses the call it dropped"
            `Quick
            test_mixed_turn_refuses_the_call_it_dropped
        ; test_case
            "recovered name is replayed as the registered name"
            `Quick
            test_recovered_tool_name_is_replayed_as_the_registered_name
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
