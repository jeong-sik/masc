open Alcotest
open Masc

let write path content =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel content)

let rec remove path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path

let start_context_refusal_server ~sw ~net =
  let requests = Atomic.make 0 in
  let callback _connection _request body =
    ignore (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) : string);
    ignore (Atomic.fetch_and_add requests 1 : int);
    Cohttp_eio.Server.respond_string ~status:`OK
      ~body:{|{"id":"fixture-overflow","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"model_context_window_exceeded"}],"usage":{"prompt_tokens":1,"completion_tokens":0,"total_tokens":1}}|} ()
  in
  let socket = Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port | _ -> fail "expected loopback TCP listener" in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun error -> raise error));
  Printf.sprintf "http://127.0.0.1:%d" port, requests

let test_a_large_request_reaches_the_peer_and_a_refusal_moves_the_lane () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Model_catalog.global () in
  let base_path = Filename.temp_file "keeper-no-body-gate-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    (match catalog_snapshot with
     | None -> Llm_provider.Model_catalog.clear_global ()
     | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    remove base_path);
  let server = Exact_output_fixture.start_server
    ~sw ~net:env#net ~clock:env#clock
    (Exact_output_fixture.Reply
      (Exact_output_fixture.openai_response (`Assoc ["answer", `String "accepted"]))) in
  (* An exact, long model ID keeps the final wire envelope larger than the
     short message's internal projection. The explicit-cap case therefore
     reaches final serialization instead of failing the history window. *)
  let model_id = "optional-cap-" ^ String.make 1024 'm' in
  let catalog_path = Filename.concat base_path "models.toml" in
  let catalog_row provider = Printf.sprintf
    "[[models]]\nid_prefix = %S\nprovider_name = %S\nbase = \"openai_chat\"\nmax_context_tokens = 1048576\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n"
    model_id provider in
  write catalog_path (catalog_row "fixture" ^ catalog_row "overflow");
  (match Llm_provider.Model_catalog.load_file catalog_path with
   | Error detail -> fail detail
   | Ok catalog -> Llm_provider.Model_catalog.set_global catalog);
  let config_path = Filename.concat base_path "runtime.toml" in
  let config_text =
    Printf.sprintf {|[runtime]
default = "fixture.sample"
[providers.fixture]
protocol = "openai-compatible-http"
endpoint = %S
[models.sample]
api-name = %S
max-context = 1048576
streaming = false
[fixture.sample]
|} server.base_url model_id
  in
  write config_path config_text;
  (match Runtime.init_default_degraded_report ~config_path with
   | Ok Runtime.Initialized -> ()
   | Ok (Runtime.Initialized_degraded _) -> fail "fixture catalog unexpectedly unavailable"
   | Error error -> fail (Runtime.strict_init_error_to_string error));
  let projection = Server_dashboard_runtime_resolved_json.build
    ~generated_at_iso:"2026-09-08T00:00:00Z"
    ~config:(Workspace.default_config base_path) in
  (match Tui_decode.decode_runtime_resolved projection with
   | Ok ([runtime], _) ->
     check string "API and TUI keep the runtime identity" "fixture.sample" runtime.ro_id
   | Ok _ -> fail "expected exactly one projected runtime"
   | Error detail -> fail detail);
  let observations = ref [] in
  let model_input_windows = ref 0 in
  let accepted_windows = ref [] in
  let attempt_errors = ref [] in
  let run ?(runtime_id = "fixture.sample") goal =
    Keeper_turn_driver.run_named
      ~system_prompt:"No body gate fixture."
      ~runtime_id ~keeper_name:"no-body-gate-proof" ~base_path
      ~agent_core_tools:[] ~goal ~sw ~net:env#net
      ~on_runtime_attempt_error:(fun ~runtime_id ~attempt:_ ~dispatch:_ error ->
        attempt_errors := (runtime_id, error) :: !attempt_errors)
      ~on_model_input_window_observation:(fun ~measurement:_ _ ->
        incr model_input_windows)
      ~on_model_input_window_accepted:(fun ~runtime_id ~measurement window ->
        accepted_windows := (runtime_id, measurement, window) :: !accepted_windows)
      ~on_request_wire_observation:(fun ~runtime_id:_ ~body_bytes ~serialized ->
        observations := (body_bytes, Option.is_some serialized) :: !observations)
      ()
  in
  let succeed goal = match run goal with
    | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error) in
  let large_goal = String.make (524288 + 1) 'x' in
  succeed large_goal;
  check int "the Keeper reaches the real HTTP peer" 1
    (Exact_output_fixture.post_count server);
  let large_body = List.hd (Exact_output_fixture.request_bodies server) in
  check bool "no client-side byte gate stands before the peer" true (String.length large_body > 524288);
  let messages = Yojson.Safe.Util.(Yojson.Safe.from_string large_body |> member "messages" |> to_list) in
  check bool "the full user input reaches the peer" true
    (List.exists (fun row -> Yojson.Safe.Util.member "content" row = `String large_goal) messages);
  check (option (pair int bool)) "the exact wire observation is the sent body"
    (Some (String.length large_body, true)) (List.nth_opt !observations 0);
  check int "the composition observed its window once" 1 !model_input_windows;
  check int "the real response confirms one carried window" 1 (List.length !accepted_windows);
  succeed "short";
  check int "a short request reaches the peer too" 2 (Exact_output_fixture.post_count server);
  let refused_url, refused_requests = start_context_refusal_server ~sw ~net:env#net in
  let recovery_config = config_text ^ Printf.sprintf {|
[providers.overflow]
protocol = "openai-compatible-http"
endpoint = %S
[overflow.sample]
[runtime.lanes.optional_recovery]
candidates = ["overflow.sample", "fixture.sample"]
|} refused_url in
  (match Runtime.save_config_text ~runtime_config_path:config_path recovery_config with
   | Ok _ -> () | Error detail -> fail detail);
  (match run ~runtime_id:"optional_recovery" "recover" with
   | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
  (match !attempt_errors with
   | ("overflow.sample", Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) :: _ -> ()
   | _ -> fail "the real peer response must produce a typed context overflow");
  check int "the peer's context refusal is attempted once, without an invented shrink seed" 1
    (Atomic.get refused_requests);
  check int "the next candidate completes the same lane turn" 3
    (Exact_output_fixture.post_count server);
  check int "the refused response adds no accepted window" 3 (List.length !accepted_windows);
  check bool "accepted windows retain the answering runtime and wire measurement" true
    (List.for_all
       (fun (runtime_id, measurement, _) ->
         runtime_id = "fixture.sample" && measurement = Turn_record.Wire_shape)
       !accepted_windows)

let test_the_runtime_demotes_historical_tool_results () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Model_catalog.global () in
  let base_path = Filename.temp_file "keeper-no-body-gate-demote-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    (match catalog_snapshot with
     | None -> Llm_provider.Model_catalog.clear_global ()
     | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    remove base_path);
  let tool_call_reply =
    {|{"id":"tool-call-1","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"active-call-1","type":"function","function":{"name":"fixture_tool","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
  in
  let final_reply =
    Exact_output_fixture.openai_response (`Assoc ["answer", `String "accepted"])
  in
  let server = Exact_output_fixture.start_server
    ~sw ~net:env#net ~clock:env#clock
    (Exact_output_fixture.Replies [tool_call_reply; final_reply]) in
  let model_id = "no-body-gate-demote" in
  let catalog_path = Filename.concat base_path "models.toml" in
  let catalog_row provider = Printf.sprintf
    "[[models]]\nid_prefix = %S\nprovider_name = %S\nbase = \"openai_chat\"\nmax_context_tokens = 1048576\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n"
    model_id provider in
  write catalog_path (catalog_row "fixture");
  (match Llm_provider.Model_catalog.load_file catalog_path with
   | Error detail -> fail detail
   | Ok catalog -> Llm_provider.Model_catalog.set_global catalog);
  let config_path = Filename.concat base_path "runtime.toml" in
  let config_text = Printf.sprintf {|[runtime]
default = "fixture.sample"
[providers.fixture]
protocol = "openai-compatible-http"
endpoint = %S
[models.sample]
api-name = %S
max-context = 1048576
streaming = false
[fixture.sample]
|} server.base_url model_id in
  write config_path config_text;
  (match Runtime.init_default_degraded_report ~config_path with
   | Ok Runtime.Initialized -> ()
   | Ok (Runtime.Initialized_degraded _) -> fail "fixture catalog unexpectedly unavailable"
   | Error error -> fail (Runtime.strict_init_error_to_string error));
  let active_payload = String.make 4000 'w' in
  let active_tool =
    Agent_core.Tool.create
      ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
      ~name:"fixture_tool"
      ~description:"Callable tool for current turn."
      ~parameters:[]
      (fun _ ->
         Ok
           { Agent_core.Types.content = active_payload
           ; content_blocks = None
           ; _meta = None
           })
  in
  let historical_payload = String.make 4000 'z' in
  let initial_messages : Agent_core.Types.message list =
    [ { role = Agent_core.Types.Assistant
      ; content = [ Agent_core.Types.Text "call tool" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { role = Agent_core.Types.Tool
      ; content =
          [ Agent_core.Types.ToolResult
              { tool_use_id = "call-demote-1"
              ; content = historical_payload
              ; outcome = Agent_core.Types.Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = Some "call-demote-1"
      ; metadata = []
      }
    ]
  in
  let result =
    Keeper_turn_driver.run_named
      ~system_prompt:"Demotion fixture."
      ~runtime_id:"fixture.sample"
      ~keeper_name:"demote-proof"
      ~base_path
      ~tools:[ active_tool ]
      ~agent_core_tools:[ active_tool ]
      ~goal:"execute tool"
      ~initial_messages
      ~sw ~net:env#net ()
  in
  (match result with
   | Ok _ -> ()
   | Error error -> fail (Agent_core.Error.to_string error));
  check int "the Keeper completed 2 requests" 2
    (Exact_output_fixture.post_count server);
  let second_body = List.nth (Exact_output_fixture.request_bodies server) 1 in
  check bool "historical tool body was demoted and not sent inline" false
    (String_util.contains_substring second_body historical_payload);
  check bool "current-turn tool body remained verbatim inline" true
    (String_util.contains_substring second_body active_payload);
  let messages = Yojson.Safe.Util.(Yojson.Safe.from_string second_body |> member "messages" |> to_list) in
  let tool_messages =
    List.filter
      (fun msg -> Yojson.Safe.Util.member "role" msg = `String "tool")
      messages
  in
  check int "exactly 2 tool messages on the wire" 2 (List.length tool_messages);
  let historical_msg =
    List.find
      (fun msg -> Yojson.Safe.Util.member "tool_call_id" msg = `String "call-demote-1")
      tool_messages
  in
  let historical_content = Yojson.Safe.Util.(member "content" historical_msg |> to_string) in
  check bool "historical tool message carries blob marker" true
    (Tool_output.is_marker historical_content);
  let active_msg =
    List.find
      (fun msg -> Yojson.Safe.Util.member "tool_call_id" msg = `String "active-call-1")
      tool_messages
  in
  let active_content = Yojson.Safe.Util.(member "content" active_msg |> to_string) in
  check bool "current turn tool message is not a marker" false
    (Tool_output.is_marker active_content);
  check string "current turn tool result is verbatim"
    active_payload
    active_content;
  let store = Tool_blob_store.create ~base_path in
  (match Tool_output.decode_from_agent_core historical_content with
   | Tool_output.Decoded artifact_ref ->
     (match Tool_blob_store.fetch store ~sha256:artifact_ref.sha256 with
      | Ok (Some fetched) ->
        check string "fetched blob matches historical payload" historical_payload fetched
      | Ok None ->
        fail "historical blob was not found in blob store"
      | Error err ->
        failf "failed to fetch stored blob: %s" (Tool_blob_store.fetch_error_to_string err))
   | _ -> fail "expected decoded artifact reference for historical tool message")

let test_accepted_window_survives_later_error usage () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Model_catalog.global () in
  Keeper_model_input_ledger.Table.For_testing.reset ();
  let base_path = Filename.temp_dir "keeper-accepted-window-" "" in
  Eio.Switch.on_release sw (fun () ->
    Keeper_model_input_ledger.Table.For_testing.reset ();
    Runtime.For_testing.restore runtime_snapshot;
    (match catalog_snapshot with
     | None -> Llm_provider.Model_catalog.clear_global ()
     | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    remove base_path);
  (* Synthetic protocol replies exercise the actual AfterTurn producer.
     The second response cannot decode, so the overall run fails after one
     accepted tool round. Neither reply is evidence of a live model call. *)
  let first_fields =
    Yojson.Safe.from_string
      {|{"id":"accepted-tool","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"accepted-call","type":"function","function":{"name":"fixture_tool","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}|}
    |> Yojson.Safe.Util.to_assoc
  in
  let first_reply =
    Yojson.Safe.to_string
      (`Assoc (first_fields @ Option.fold ~none:[] ~some:(fun value -> ["usage", value]) usage))
  in
  let server = Exact_output_fixture.start_server
    ~sw ~net:env#net ~clock:env#clock
    (Exact_output_fixture.Replies [first_reply; "{"]) in
  let model_id = "accepted-window" in
  let catalog_path = Filename.concat base_path "models.toml" in
  write catalog_path (Printf.sprintf
    "[[models]]\nid_prefix = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 1048576\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n"
    model_id);
  (match Llm_provider.Model_catalog.load_file catalog_path with
   | Error detail -> fail detail
   | Ok catalog -> Llm_provider.Model_catalog.set_global catalog);
  let config_path = Filename.concat base_path "runtime.toml" in
  write config_path (Printf.sprintf {|[runtime]
default = "fixture.sample"
[providers.fixture]
protocol = "openai-compatible-http"
endpoint = %S
[models.sample]
api-name = %S
max-context = 1048576
streaming = false
[fixture.sample]
|} server.base_url model_id);
  (match Runtime.init_default_degraded_report ~config_path with
   | Ok Runtime.Initialized -> ()
   | Ok (Runtime.Initialized_degraded _) -> fail "fixture catalog unexpectedly unavailable"
   | Error error -> fail (Runtime.strict_init_error_to_string error));
  let tool = Agent_core.Tool.create
    ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
    ~name:"fixture_tool" ~description:"Synthetic no-effect tool." ~parameters:[]
    (fun _ -> Ok { Agent_core.Types.content = "synthetic result"; content_blocks = None; _meta = None })
  in
  let attempted = ref [] in
  let accepted = ref [] in
  let response_usage = ref [] in
  let hooks = { Agent_core.Hooks.empty with
    after_turn = Some (function
      | Agent_core.Hooks.AfterTurn { response; _ } ->
        response_usage := response.Agent_core.Types.usage :: !response_usage;
        Agent_core.Hooks.Continue
      | Agent_core.Hooks.BeforeTurn _
      | Agent_core.Hooks.BeforeTurnParams _
      | Agent_core.Hooks.PreToolUse _
      | Agent_core.Hooks.PostToolUse _
      | Agent_core.Hooks.PostToolUseFailure _
      | Agent_core.Hooks.OnStop _
      | Agent_core.Hooks.OnError _
      | Agent_core.Hooks.OnToolError _ -> Agent_core.Hooks.Continue) }
  in
  let result = Keeper_turn_driver.run_named
    ~system_prompt:"Accepted window fixture."
    ~runtime_id:"fixture.sample" ~keeper_name:"accepted-window-proof" ~base_path
    ~tools:[tool] ~agent_core_tools:[tool] ~hooks
    ~goal:"Call fixture_tool once, then answer."
    ~on_model_input_window_observation:(fun ~measurement window ->
      attempted := (measurement, window) :: !attempted)
    ~on_model_input_window_accepted:(fun ~runtime_id ~measurement window ->
      accepted := (runtime_id, measurement, window) :: !accepted)
    ~sw ~net:env#net ()
  in
  check bool "later protocol failure fails the overall run" true (Result.is_error result);
  check int "both requests reached the HTTP peer" 2 (Exact_output_fixture.post_count server);
  check int "both attempted ranges remain observable" 2 (List.length !attempted);
  (match List.rev !attempted, !accepted with
   | (measurement, window) :: _, [(runtime_id, accepted_measurement, accepted_window)] ->
     check string "accepted callback owns the answering runtime" "fixture.sample" runtime_id;
     check bool "accepted callback keeps the exact first request range and digest" true
       (measurement = Turn_record.Wire_shape
        && accepted_measurement = measurement && accepted_window = window)
   | _ -> fail "expected only the first of two attempted windows to be accepted");
  (match usage, !response_usage with
   | None, [None] -> ()
   | Some _, [Some observed] ->
     check int "zero prompt usage is still an accepted response" 0 observed.input_tokens;
     check int "zero completion usage is preserved" 0 observed.output_tokens
   | _ -> fail "the actual AfterTurn usage differed from the synthetic response")

let () =
  Alcotest.run "keeper_no_request_body_gate"
    [ "actual-dispatch",
      [ test_case "a large request reaches the peer and a refusal moves the lane" `Quick
          test_a_large_request_reaches_the_peer_and_a_refusal_moves_the_lane
      ; test_case "the runtime demotes historical tool results" `Quick
          test_the_runtime_demotes_historical_tool_results
      ; test_case "accepted window without usage survives a later error" `Quick
          (test_accepted_window_survives_later_error None)
      ; test_case "accepted window with zero usage survives a later error" `Quick
          (test_accepted_window_survives_later_error
             (Some (`Assoc ["prompt_tokens", `Int 0; "completion_tokens", `Int 0; "total_tokens", `Int 0])))
      ]
    ]
