open Alcotest
open Agent_core
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

(* A deferred tool surface hands the model an index and supplies the schema
   when it is asked for, so the callable set has to grow while the turn that
   asked is still running. The tool-round loop in [Agent.run] captures one
   [Agent.t] and passes the same value to every round, so growth has to be
   visible through that value rather than through a rebound copy. *)
let test_extend_tools_widens_the_callable_set () =
  Eio_main.run
  @@ fun env ->
  let tool name =
    Tool.create ~name ~description:name ~parameters:[] (fun _ ->
      Ok { Types.content = name; _meta = None })
  in
  let agent =
    Agent.create
      ~config:(Types.default_config ~model:"test-model")
      ~tools:[ tool "index" ]
      ~net:env#net
      ()
  in
  Alcotest.(check bool)
    "a tool that was not supplied is not callable"
    false
    (Tool_set.mem "loaded" (Agent.tools agent));
  Agent.extend_tools agent [ tool "loaded" ];
  Alcotest.(check bool)
    "the supplied tool is callable through the same agent value"
    true
    (Tool_set.mem "loaded" (Agent.tools agent));
  Alcotest.(check bool)
    "the tool that was already there stays"
    true
    (Tool_set.mem "index" (Agent.tools agent));
  Alcotest.(check int) "and nothing else appeared" 2 (Tool_set.size (Agent.tools agent))
;;

(* [Tool_set.merge] is last-occurrence-wins, so merging a name the agent
   already holds would rebind it to a different closure mid-turn: the model
   calls what it was shown and is answered by something else. *)
let test_extend_tools_does_not_rebind_an_existing_name () =
  Eio_main.run
  @@ fun env ->
  let tool name body =
    Tool.create ~name ~description:name ~parameters:[] (fun _ ->
      Ok { Types.content = body; _meta = None })
  in
  let agent =
    Agent.create
      ~config:(Types.default_config ~model:"test-model")
      ~tools:[ tool "search" "original" ]
      ~net:env#net
      ()
  in
  Agent.extend_tools agent [ tool "search" "replacement" ];
  Alcotest.(check int) "no duplicate entry" 1 (Tool_set.size (Agent.tools agent));
  let ran =
    match Tool_set.find "search" (Agent.tools agent) with
    | None -> Alcotest.fail "the tool disappeared"
    | Some (t : Tool.t) ->
      (match Tool.execute t (`Assoc []) with
       | Ok result -> result.Types.content
       | Error _ -> Alcotest.fail "the tool failed to run")
  in
  Alcotest.(check string) "the original definition still answers" "original" ran
;;

(* Widening only matters if the next provider request carries the new tool.
   The turn is prepared from [agent.tools] on every round, so a tool added
   between rounds reaches the wire -- and until it does, the model calling
   that name has its [tool_use] dropped before the history sees it
   ([Agent_tools.admit_tool_use_names]). *)
let test_a_widened_tool_reaches_the_next_request () =
  Eio_main.run
  @@ fun env ->
  let tool name =
    Tool.create ~name ~description:name ~parameters:[] (fun _ ->
      Ok { Types.content = name; _meta = None })
  in
  let agent =
    Agent.create
      ~config:(Types.default_config ~model:"test-model")
      ~tools:[ tool "index" ]
      ~net:env#net
      ()
  in
  let offered_this_round () =
    match
      Agent_turn.prepare_turn
        ~tools:(Agent.tools agent)
        ~messages:[]
        ~turn_params:Hooks.default_turn_params
        ()
    with
    | Error error -> Alcotest.fail (Agent_core.Error.to_string error)
    | Ok prep -> prep.Agent_turn.visible_tool_names
  in
  Alcotest.(check (list string)) "the first round offers what it was built with"
    [ "index" ] (offered_this_round ());
  Agent.extend_tools agent [ tool "loaded" ];
  Alcotest.(check (list string)) "the next round offers the widened set"
    [ "index"; "loaded" ]
    (List.sort String.compare (offered_this_round ()))
;;

let test_extend_tools_with_nothing_changes_nothing () =
  Eio_main.run
  @@ fun env ->
  let agent =
    Agent.create ~config:(Types.default_config ~model:"test-model") ~net:env#net ()
  in
  Agent.extend_tools agent [];
  Alcotest.(check int) "still empty" 0 (Tool_set.size (Agent.tools agent))
;;

let test_version_info () =
  Alcotest.(check string) "version" Agent_core.Version.version Agent_core.version;
  Alcotest.(check string) "name" "agent_core" Agent_core.name
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
    "Agent Core"
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
        ; test_case "extend_tools widens the callable set" `Quick
            test_extend_tools_widens_the_callable_set
        ; test_case "extend_tools does not rebind an existing name" `Quick
            test_extend_tools_does_not_rebind_an_existing_name
        ; test_case "extend_tools with nothing changes nothing" `Quick
            test_extend_tools_with_nothing_changes_nothing
        ; test_case "a widened tool reaches the next request" `Quick
            test_a_widened_tool_reaches_the_next_request
        ; test_case "version info" `Quick test_version_info
        ] )
    ; ( "builder"
      , [ test_case "build_safe valid" `Quick test_build_safe_valid
        ; test_case "build_safe thinking" `Quick test_build_safe_explicit_thinking_budget
        ] )
    ]
;;
