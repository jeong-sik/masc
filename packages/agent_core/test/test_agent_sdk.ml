open Alcotest
open Agent_sdk
open Types

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    (fun () ->
       Unix.putenv key value;
       f ())
;;

let test_model_string () =
  Alcotest.(check string)
    "exact model"
    "claude-sonnet-4"
    (model_to_string "claude-sonnet-4")
;;

let test_role_string () =
  Alcotest.(check string) "user" "user" (role_to_string User);
  Alcotest.(check string) "assistant" "assistant" (role_to_string Assistant)
;;

let test_stop_reason () =
  Alcotest.(check bool) "end_turn" true (stop_reason_of_string "end_turn" = EndTurn);
  Alcotest.(check bool) "tool_use" true (stop_reason_of_string "tool_use" = StopToolUse)
;;

let test_simple_tool () =
  let tool =
    Tool.create
      ~name:"echo"
      ~description:"Echo input"
      ~parameters:
        [ { name = "msg"; description = "Message"; param_type = String; required = true }
        ]
      (fun input ->
         let msg = Yojson.Safe.Util.(input |> member "msg" |> to_string) in
         Ok { Types.content = msg; _meta = None })
  in
  let input = `Assoc [ "msg", `String "hello" ] in
  match Tool.execute tool input with
  | Ok { content; _meta = _ } -> Alcotest.(check string) "echo output" "hello" content
  | Error _ -> Alcotest.fail "Tool execution failed"
;;

let test_extract_text () =
  let content =
    [ Text "Hello"; ToolUse { id = "1"; name = "t"; input = `Null }; Text " World" ]
  in
  let text =
    List.filter_map
      (function
        | Text s -> Some s
        | _ -> None)
      content
    |> String.concat ""
  in
  Alcotest.(check string) "extract text" "Hello World" text
;;

let test_agent_create () =
  Eio_main.run
  @@ fun env ->
  let agent =
    Agent.create ~config:(Types.default_config ~model:"test-model") ~net:env#net ()
  in
  let st = Agent.state agent in
  Alcotest.(check int) "initial turn count" 0 st.turn_count;
  Alcotest.(check int) "initial messages" 0 (List.length st.messages)
;;

let test_agent_accessors () =
  Eio_main.run
  @@ fun env ->
  let agent =
    Agent.create ~config:(Types.default_config ~model:"test-model") ~net:env#net ()
  in
  Alcotest.(check int) "no tools" 0 (Tool_set.size (Agent.tools agent));
  Alcotest.(check bool) "no lifecycle" true (Option.is_none (Agent.lifecycle agent));
  let opts = Agent.options agent in
  Alcotest.(check bool) "no provider config" true (Option.is_none opts.provider_config)
;;

let test_version_info () =
  Alcotest.(check string) "version" Agent_sdk.Sdk_version.version Agent_sdk.version;
  Alcotest.(check string) "sdk_name" "agent_sdk" Agent_sdk.sdk_name
;;

let test_build_safe_valid () =
  Eio_main.run
  @@ fun env ->
  let result =
    Builder.create ~net:env#net ~model:"claude-sonnet-4-6"
    |> Builder.with_system_prompt "test"
    |> Builder.with_max_tokens 1024
    |> Builder.build_safe
  in
  Alcotest.(check bool) "build_safe ok" true (Result.is_ok result)
;;

let test_build_safe_explicit_thinking_budget () =
  Eio_main.run
  @@ fun env ->
  let result =
    Builder.create ~net:env#net ~model:"claude-sonnet-4-6"
    |> Builder.with_thinking_budget 1000
    |> Builder.build_safe
  in
  Alcotest.(check bool) "explicit thinking budget" true (Result.is_ok result)
;;

let () =
  run
    "Agent SDK"
    [ ( "types"
      , [ test_case "model_string" `Quick test_model_string
        ; test_case "role_string" `Quick test_role_string
        ; test_case "stop_reason" `Quick test_stop_reason
        ] )
    ; "tool", [ test_case "simple_tool" `Quick test_simple_tool ]
    ; "api", [ test_case "extract_text" `Quick test_extract_text ]
    ; ( "agent"
      , [ test_case "create" `Quick test_agent_create
        ; test_case "accessors" `Quick test_agent_accessors
        ; test_case "version info" `Quick test_version_info
        ] )
    ; ( "builder"
      , [ test_case "build_safe valid" `Quick test_build_safe_valid
        ; test_case "build_safe thinking" `Quick test_build_safe_explicit_thinking_budget
        ] )
    ]
;;
