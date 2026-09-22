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
  let response_without_usage =
    match
      Exact_output_fixture.openai_response
        (`Assoc [ "answer", `String "accepted" ])
      |> Yojson.Safe.from_string
    with
    | `Assoc fields ->
      `Assoc (List.remove_assoc "usage" fields) |> Yojson.Safe.to_string
    | _ -> fail "fixture response is not an object"
  in
  let server =
    Exact_output_fixture.start_server
      ~sw
      ~net:env#net
      ~clock:env#clock
      (Exact_output_fixture.Reply response_without_usage)
  in
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
  let response_observed_model_inputs = ref [] in
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
      ~on_response_observed_model_input:(fun observed ->
        response_observed_model_inputs :=
          observed :: !response_observed_model_inputs)
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
  check int "the response certifies that exact window once" 1
    (List.length !response_observed_model_inputs);
  succeed "short";
  check int "a short request reaches the peer too" 2 (Exact_output_fixture.post_count server);
  check int "the second response certifies its window" 2
    (List.length !response_observed_model_inputs);
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
  check int "the typed refusal did not certify its attempted window" 3
    (List.length !response_observed_model_inputs);
  match !response_observed_model_inputs with
  | latest :: _ ->
    check string "the fallback response names its own runtime"
      "fixture.sample"
      latest.Turn_record.runtime_profile
  | [] -> fail "the fallback response observation is missing"

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
  (* #37602 gates body externalization on completed-turn evidence: the small
     input policy (the default) only demotes atoms a durable turn-boundary
     line already covers ([completed_end_atom > 0]), plus a reader tool the
     demoted content's blob marker can be answered with. Neither is present
     by default, so this fixture seeds them: a durable boundary line says the
     two seed messages above are already a completed turn's history, built
     the same way Keeper_turn_boundaries' own tests build one
     (test_keeper_librarian_range.ml), and the run below joins that trace by
     session id. Anything the turn appends live -- the active tool's own call
     and result -- lands past that boundary and stays inline. *)
  let trace_id = "trace-demote-proof" in
  let historical_position =
    match Keeper_turn_boundaries.position_of_messages initial_messages with
    | Ok position -> position
    | Error detail -> fail ("fixture boundary position: " ^ detail)
  in
  let keepers_dir = Workspace.keepers_runtime_dir (Workspace.default_config base_path) in
  let append_boundary record =
    match Keeper_turn_boundaries.append ~keepers_dir ~keeper_id:"demote-proof" record with
    | Ok () -> ()
    | Error error -> fail (Keeper_turn_boundaries.append_error_to_string error)
  in
  append_boundary
    { Keeper_turn_boundaries.recorded_at = 0.
    ; event = Keeper_turn_boundaries.History_restarted { trace_id }
    };
  append_boundary
    { Keeper_turn_boundaries.recorded_at = 0.
    ; event =
        Keeper_turn_boundaries.Turn_ended
          { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1
          ; history_at_start = Keeper_turn_boundaries.Fresh_history
          ; position = historical_position
          }
    };
  let reader_tool =
    let schema = Keeper_runtime_schemas_toml.artifact_read in
    match
      Agent_core.Types.tool_schema_of_input_schema
        ~name:schema.name ~description:schema.description
        ~input_schema:schema.input_schema ()
    with
    | Error detail -> fail ("fixture reader schema: " ^ detail)
    | Ok schema ->
      Agent_core.Tool.of_schema
        ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
        schema
        (Agent_core.Tool.ignoring_execution_env (fun _ ->
           Ok { Agent_core.Types.content = "{}"; content_blocks = None; _meta = None }))
  in
  let result =
    Keeper_turn_driver.run_named
      ~system_prompt:"Demotion fixture."
      ~runtime_id:"fixture.sample"
      ~keeper_name:"demote-proof"
      ~base_path
      ~session_id:trace_id
      ~tools:[ active_tool ]
      ~agent_core_tools:[ active_tool; reader_tool ]
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

let () =
  Alcotest.run "keeper_no_request_body_gate"
    [ "actual-dispatch",
      [ test_case "a large request reaches the peer and a refusal moves the lane" `Quick
          test_a_large_request_reaches_the_peer_and_a_refusal_moves_the_lane
      ; test_case "the runtime demotes historical tool results" `Quick
          test_the_runtime_demotes_historical_tool_results
      ]
    ]
