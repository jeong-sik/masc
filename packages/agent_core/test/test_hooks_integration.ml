(** Integration tests for hooks — verify hook decisions affect Agent.run behavior.

    Uses a mock HTTP server (Cohttp_eio) to exercise the full agent loop
    without any real LLM. Each test gets a unique port to avoid bind conflicts.

    Pattern: test_integration.ml (OpenAI-compatible mock) *)

open Agent_sdk
open Types

(* ── Mock HTTP Server ────────────────────────────────── *)

let text_body text =
  Printf.sprintf
    {|{"id":"m1","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}|}
    text
;;

let tool_use_body ~tool_name ~input_json =
  Printf.sprintf
    {|{"id":"m2","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"tu_1","type":"function","function":{"name":"%s","arguments":"%s"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}|}
    tool_name
    (String.escaped input_json)
;;

let stateful_handler call_count _conn _req body =
  let _ = Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) in
  let n = !call_count in
  incr call_count;
  let response_body =
    if n = 0
    then tool_use_body ~tool_name:"echo" ~input_json:{|{"msg":"hi"}|}
    else text_body "done"
  in
  Cohttp_eio.Server.respond_string ~status:`OK ~body:response_body ()
;;

let sequence_handler responses _conn _req body =
  let _ = Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) in
  match !responses with
  | response_body :: rest ->
    responses := rest;
    Cohttp_eio.Server.respond_string ~status:`OK ~body:response_body ()
  | [] -> Cohttp_eio.Server.respond_string ~status:`OK ~body:(text_body "done") ()
;;

let text_only_handler _conn _req body =
  let _ = Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) in
  Cohttp_eio.Server.respond_string ~status:`OK ~body:(text_body "hello") ()
;;

let capturing_text_handler captured _conn _req body =
  let raw = Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) in
  captured := raw;
  Cohttp_eio.Server.respond_string ~status:`OK ~body:(text_body "ok") ()
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

let fresh_echo_tool () =
  let calls = ref 0 in
  let tool =
    Tool.create ~name:"echo" ~description:"Echo" ~parameters:[] (fun _input ->
      incr calls;
      Ok { Types.content = "echoed"; _meta = None })
  in
  tool, calls
;;

let local_provider ~base_url ~model_id =
  Provider_mock.local_provider_config
    ~base_url
    ~model_id
    ~request_path:"/v1/chat/completions"
    ()
;;

(* ── before_turn tests ───────────────────────────────── *)

(* [Nudge] appends a User-role message that reaches the model in the same turn. *)
let test_before_turn_continue_proceeds () =
  with_mock_server ~port:18102 text_only_handler (fun ~sw ~net ~base_url ->
    let fired = ref false in
    let options =
      { Agent.default_options with
        provider_config = Some (local_provider ~base_url ~model_id:"test-model")
      ; hooks =
          { Hooks.empty with
            before_turn =
              Some
                (fun _event ->
                  fired := true;
                  Hooks.Continue)
          }
      }
    in
    let agent =
      Agent.create ~config:(default_config ~model:"test-model") ~net ~options ()
    in
    match Agent.run ~sw agent "test" with
    | Ok resp ->
      Alcotest.(check bool) "hook fired" true !fired;
      let text =
        List.filter_map
          (function
            | Text s -> Some s
            | _ -> None)
          resp.content
        |> String.concat ""
      in
      Alcotest.(check string) "got response" "hello" text
    | Error e -> Alcotest.fail (Error.to_string e))
;;

let test_before_turn_receives_turn_number () =
  with_mock_server ~port:18103 text_only_handler (fun ~sw ~net ~base_url ->
    let received_turn = ref (-1) in
    let options =
      { Agent.default_options with
        provider_config = Some (local_provider ~base_url ~model_id:"test-model")
      ; hooks =
          { Hooks.empty with
            before_turn =
              Some
                (function
                  | Hooks.BeforeTurn { turn; _ } ->
                    received_turn := turn;
                    Hooks.Continue
                  | _ -> Hooks.Continue)
          }
      }
    in
    let agent =
      Agent.create ~config:(default_config ~model:"test-model") ~net ~options ()
    in
    (match Agent.run ~sw agent "test" with
     | Ok _ -> ()
     | Error e -> Alcotest.fail (Error.to_string e));
    Alcotest.(check int) "turn 0" 0 !received_turn)
;;

let test_before_turn_nudge_injected_into_request () =
  let captured = ref "" in
  with_mock_server
    ~port:18110
    (capturing_text_handler captured)
    (fun ~sw ~net ~base_url ->
       let options =
         { Agent.default_options with
           provider_config = Some (local_provider ~base_url ~model_id:"test-model")
         ; hooks =
             { Hooks.empty with
               before_turn =
                 Some (fun _event -> Hooks.Nudge "OAS_BEFORE_TURN_NUDGE_MARKER")
             }
         }
       in
       let agent =
         Agent.create ~config:(default_config ~model:"test-model") ~net ~options ()
       in
       (match Agent.run ~sw agent "first prompt" with
        | Ok _ -> ()
        | Error e -> Alcotest.fail (Error.to_string e));
       let body = !captured in
       let contains s sub =
         let n = String.length s
         and m = String.length sub in
         let rec loop i =
           if i + m > n
           then false
           else if String.sub s i m = sub
           then true
           else loop (i + 1)
         in
         loop 0
       in
       Alcotest.(check bool)
         "nudge marker reached the LLM request body"
         true
         (contains body "OAS_BEFORE_TURN_NUDGE_MARKER"))
;;

(* ── pre_tool_use tests ──────────────────────────────── *)

let test_pre_tool_block_blocks_execution () =
  let call_count = ref 0 in
  with_mock_server ~port:18104 (stateful_handler call_count) (fun ~sw ~net ~base_url ->
    let tool, tool_calls = fresh_echo_tool () in
    let options =
      { Agent.default_options with
        provider_config = Some (local_provider ~base_url ~model_id:"mock-model")
      ; hooks =
          { Hooks.empty with
            pre_tool_use =
              Some
                (function
                  | Hooks.PreToolUse _ -> Hooks.Block "blocked"
                  | _ -> Hooks.Continue)
          }
      }
    in
    let config = default_config ~model:"mock-model" in
    let agent = Agent.create ~net ~config ~options ~tools:[ tool ] () in
    (match Agent.run ~sw agent "test" with
     | Ok _ | Error _ -> ());
    Alcotest.(check int) "tool handler not called" 0 !tool_calls)
;;

(* ── post_tool_use tests ─────────────────────────────── *)

let test_post_tool_receives_output () =
  let call_count = ref 0 in
  with_mock_server ~port:18106 (stateful_handler call_count) (fun ~sw ~net ~base_url ->
    let received_content = ref "" in
    let tool, _ = fresh_echo_tool () in
    let options =
      { Agent.default_options with
        provider_config = Some (local_provider ~base_url ~model_id:"mock-model")
      ; hooks =
          { Hooks.empty with
            post_tool_use =
              Some
                (function
                  | Hooks.PostToolUse { output = Ok { content; _meta = _ }; _ } ->
                    received_content := content;
                    Hooks.Continue
                  | _ -> Hooks.Continue)
          }
      }
    in
    let config = default_config ~model:"mock-model" in
    let agent = Agent.create ~net ~config ~options ~tools:[ tool ] () in
    (match Agent.run ~sw agent "test" with
     | Ok _ | Error _ -> ());
    Alcotest.(check string) "received tool output" "echoed" !received_content)
;;

(* ── on_stop tests ───────────────────────────────────── *)

let test_on_stop_fires () =
  with_mock_server ~port:18107 text_only_handler (fun ~sw ~net ~base_url ->
    let stop_fired = ref false in
    let options =
      { Agent.default_options with
        provider_config = Some (local_provider ~base_url ~model_id:"test-model")
      ; hooks =
          { Hooks.empty with
            on_stop =
              Some
                (function
                  | Hooks.OnStop _ ->
                    stop_fired := true;
                    Hooks.Continue
                  | _ -> Hooks.Continue)
          }
      }
    in
    let agent =
      Agent.create ~config:(default_config ~model:"test-model") ~net ~options ()
    in
    (match Agent.run ~sw agent "test" with
     | Ok _ | Error _ -> ());
    Alcotest.(check bool) "on_stop fired" true !stop_fired)
;;

(* ── multiple hooks test ─────────────────────────────── *)

let test_multiple_hooks_all_fire () =
  with_mock_server ~port:18108 text_only_handler (fun ~sw ~net ~base_url ->
    let before_fired = ref false in
    let after_fired = ref false in
    let options =
      { Agent.default_options with
        provider_config = Some (local_provider ~base_url ~model_id:"test-model")
      ; hooks =
          { Hooks.empty with
            before_turn =
              Some
                (fun _ ->
                  before_fired := true;
                  Hooks.Continue)
          ; after_turn =
              Some
                (fun _ ->
                  after_fired := true;
                  Hooks.Continue)
          }
      }
    in
    let agent =
      Agent.create ~config:(default_config ~model:"test-model") ~net ~options ()
    in
    (match Agent.run ~sw agent "test" with
     | Ok _ | Error _ -> ());
    Alcotest.(check bool) "before fired" true !before_fired;
    Alcotest.(check bool) "after fired" true !after_fired)
;;

(* ── context_injector tests ──────────────────────────── *)

let test_context_injector_adds_data () =
  let call_count = ref 0 in
  with_mock_server ~port:18109 (stateful_handler call_count) (fun ~sw ~net ~base_url ->
    let tool, _ = fresh_echo_tool () in
    let injector ~tool_name:_ ~input:_ ~output:_ =
      Some
        Hooks.
          { context_updates = [ "injected_key", `String "injected_val" ]
          ; extra_messages = []
          }
    in
    let ctx = Context.create_sync () in
    let options =
      { Agent.default_options with
        provider_config = Some (local_provider ~base_url ~model_id:"mock-model")
      ; context_injector = Some injector
      }
    in
    let config = default_config ~model:"mock-model" in
    let agent = Agent.create ~net ~config ~options ~context:ctx ~tools:[ tool ] () in
    (match Agent.run ~sw agent "test" with
     | Ok _ | Error _ -> ());
    let value = Context.get ctx "injected_key" in
    Alcotest.(check bool)
      "injected data present"
      true
      (value = Some (`String "injected_val")))
;;

(* ── Suite ───────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run
    "Hooks_Integration"
    [ ( "before_turn"
      , [ test_case "continue proceeds" `Quick test_before_turn_continue_proceeds
        ; test_case "receives turn number" `Quick test_before_turn_receives_turn_number
        ; test_case
            "nudge injected into request body"
            `Quick
            test_before_turn_nudge_injected_into_request
        ] )
    ; ( "pre_tool_use"
      , [ test_case
            "block blocks tool execution"
            `Quick
            test_pre_tool_block_blocks_execution
        ] )
    ; ( "post_tool_use"
      , [ test_case "receives tool output" `Quick test_post_tool_receives_output ] )
    ; "on_stop", [ test_case "fires on completion" `Quick test_on_stop_fires ]
    ; ( "chaining"
      , [ test_case "multiple hooks all fire" `Quick test_multiple_hooks_all_fire ] )
    ; ( "context_injector"
      , [ test_case "adds data after tool use" `Quick test_context_injector_adds_data ] )
    ]
;;
