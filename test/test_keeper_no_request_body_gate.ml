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
  let bodies = ref [] in
  let callback _connection _request body =
    let body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    bodies := body :: !bodies;
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
  Printf.sprintf "http://127.0.0.1:%d" port, requests, bodies

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
    "[[models]]\nmodel_id = %S\nprovider_name = %S\nbase = \"openai_chat\"\nmax_context_tokens = 1048576\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n"
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
  let projected_requests = ref [] in
  let projection_count = ref 0 in
  let model_input_windows = ref 0 in
  let response_observed_model_inputs = ref [] in
  let attempt_errors = ref [] in
  let run ?(runtime_id = "fixture.sample") goal =
    Keeper_turn_driver.run_named ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "no-body-gate-proof" }) ~raw_trace:None ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
      ~system_prompt:"No body gate fixture."
      ~runtime_id ~keeper_name:"no-body-gate-proof" ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
      ~agent_core_tools:[] ~goal ~sw ~net:env#net
      ~model_input_projection:(fun messages ->
        incr projection_count;
        Ok (messages @ [Agent_core.Types.user_msg
          (Printf.sprintf "projection-fixture-%d" !projection_count)]))
      ~on_runtime_attempt_error:(fun ~runtime_id ~attempt:_ ~dispatch:_ error ->
        attempt_errors := (runtime_id, error) :: !attempt_errors)
      ~on_model_input_window_observation:(fun ~measurement:_ _ ->
        incr model_input_windows)
      ~on_response_observed_model_input:(fun observed ->
        response_observed_model_inputs :=
          observed :: !response_observed_model_inputs)
      ~on_request_wire_observation:(fun ~runtime_id ~body_bytes ~serialized ~projected_messages ->
        observations := (body_bytes, Option.is_some serialized) :: !observations;
        projected_requests := (runtime_id, projected_messages) :: !projected_requests)
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
  let refused_url, refused_requests, refused_bodies = start_context_refusal_server ~sw ~net:env#net in
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
  (match !projected_requests with
   | ("fixture.sample", Some accepted) :: ("overflow.sample", Some refused) :: _ ->
     List.iter (fun messages ->
       check bool "each lane's serialized request carries the current input" true
         (List.exists (fun message ->
           String_util.contains_substring (Agent_core.Types.text_of_message message) "recover") messages))
       [refused; accepted];
     let marker messages = match List.rev messages with
       | message :: _ -> Agent_core.Types.text_of_message message
       | [] -> fail "final projection has no marker" in
     let refused_marker = marker refused and accepted_marker = marker accepted in
     check bool "different attempts have different projections" true
       (refused_marker <> accepted_marker);
     let refused_body = match !refused_bodies with
       | [body] -> body | [] | _ :: _ :: _ -> fail "expected one refused request body" in
     let accepted_body = match List.rev (Exact_output_fixture.request_bodies server) with
       | body :: _ -> body | [] -> fail "accepted request body absent" in
     check bool "refused body matches only the refused projection" true
       (String_util.contains_substring refused_body refused_marker &&
        not (String_util.contains_substring refused_body accepted_marker));
     check bool "accepted body matches only the accepted projection" true
       (String_util.contains_substring accepted_body accepted_marker &&
        not (String_util.contains_substring accepted_body refused_marker))
   | _ -> fail "each serialized lane must report its own final projection");
  match !response_observed_model_inputs with
  | latest :: _ ->
    check string "the fallback response names its own runtime"
      "fixture.sample"
      latest.Turn_record.runtime_profile
  | [] -> fail "the fallback response observation is missing"

type argument_seed = Completed_seed | Open_seed | No_seed

let test_historical_tool_results ?(argument_seed = Completed_seed)
    ?(input_policy = Keeper_input_policy.Small) ~completed ~reader_available () =
  let module Observation = Agent_core.Base.Schema_observation in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let previous_pool = Domain_pool_ref.get () in
  let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Eio.Switch.on_release sw (fun () ->
    match previous_pool with
    | None -> Domain_pool_ref.clear_for_tests ()
    | Some previous -> Domain_pool_ref.set previous);
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
  let historical_input = `Assoc ["command", `String (String.make 4000 'h')] in
  let active_input = `Assoc ["command", `String (String.make 4000 'a')] in
  let tool_call_reply =
    Printf.sprintf
      {|{"id":"tool-call-1","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"active-call-1","type":"function","function":{"name":"fixture_tool","arguments":%s}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
      (Yojson.Safe.to_string (`String (Yojson.Safe.to_string active_input)))
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
    "[[models]]\nmodel_id = %S\nprovider_name = %S\nbase = \"openai_chat\"\nmax_context_tokens = 1048576\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n"
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
  let executed_inputs = ref [] in
  let command_param : Agent_core.Types.tool_param =
    { name = "command"; description = "Command supplied by this fixture."
    ; param_type = Agent_core.Types.String; required = true } in
  let active_tool =
    Agent_core.Tool.create
      ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
      ~name:"fixture_tool"
      ~description:"Callable tool for current turn."
      ~parameters:[command_param]
      (fun input ->
         executed_inputs := input :: !executed_inputs;
         Ok
           { Agent_core.Types.content = active_payload
           ; content_blocks = None
           ; _meta = None
           })
  in
  let historical_payload = String.make 4000 'z' in
  (* Atom 0 is the turn the Librarian has read; the completed tool exchange
     that follows is the one it has not. Only a completed turn the Librarian
     is behind on reaches the wire at all: with no Librarian position the
     request starts at the completed boundary (RFC keeper-context-window
     §13.4), and with one it starts there (§13.6). *)
  let initial_messages : Agent_core.Types.message list =
    [ { origin = Llm_provider.Types.Conversation;  role = Agent_core.Types.User
      ; content = [ Agent_core.Types.Text "earlier ask, already read by the Librarian" ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { origin = Llm_provider.Types.Conversation;  role = Agent_core.Types.Assistant
      ; content = [ Agent_core.Types.ToolUse
          { id = "call-demote-1"; name = "fixture_tool"; input = historical_input } ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { origin = Llm_provider.Types.Conversation;  role = Agent_core.Types.Tool
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
  let argument_demotion_seed = match argument_seed with
    | Completed_seed -> Some initial_messages
    | No_seed -> None
    | Open_seed ->
      (* The dispatch view already has a closer, but the raw pre-admission
         seed ends at the call. That closer cannot grant argument authority. *)
      Some (List.take 2 initial_messages) in
  let trace_id = "demote-proof-trace-" ^ Filename.basename base_path in
  if completed then (
    let position = match Keeper_turn_boundaries.position_of_messages initial_messages with
      | Ok position -> position | Error detail -> fail detail in
    let record : Keeper_turn_boundaries.record =
      { recorded_at = 1.; event = Keeper_turn_boundaries.Turn_ended
          { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1
          ; history_at_start = Keeper_turn_boundaries.Fresh_history
          ; position } } in
    let keepers_dir = Workspace.keepers_runtime_dir (Workspace.default_config base_path) in
    (match Keeper_turn_boundaries.append ~keepers_dir ~keeper_id:"demote-proof" record with
     | Ok () -> ()
     | Error error -> fail (Keeper_turn_boundaries.append_error_to_string error));
    let last_atom_digest =
      match Runtime_model_input_tail_window.atom_opening_digest initial_messages 0 with
      | Some digest -> digest
      | None -> fail "the fixture history opens atom 0" in
    match Keeper_librarian_progress.write ~keepers_dir ~keeper_id:"demote-proof"
      { position = { trace_id; end_atom = 1; last_atom_digest }; boundary_lines_seen = 1 } with
    | Ok () -> ()
    | Error error -> fail (Keeper_librarian_progress.write_error_to_string error));
  let reader =
    let schema = Keeper_runtime_schemas_toml.artifact_read in
    Tool_bridge.agent_core_tool_of_masc_with_execution_env
        ~base_path
        ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
        ~model_projection:(fun () -> Tool_output.bounded_inline_model_projection)
        ~name:schema.name ~description:schema.description ~input_schema:schema.input_schema
        (fun _ args ->
          let execution = Keeper_artifact_read.handle ~base_path ~args in
          match execution.disposition with
          | Tool_result.Completed () ->
            Tool_result.make_ok ~tool_name:schema.name ~start_time:(Tool_timing.start ())
              ?data:execution.data ()
          | Tool_result.Failed class_ ->
            Tool_result.make_err ~tool_name:schema.name ~class_
              ~start_time:(Tool_timing.start ()) execution.raw_output
          | Tool_result.Deferred () -> fail "artifact read unexpectedly deferred")
  in
  let tools = if reader_available then [active_tool; reader] else [active_tool] in
  check bool "only the canonical offered reader grants retrieval" reader_available
    (Result.is_ok (Keeper_recovery_transmission.require_reader tools));
  let expect_demoted = completed && reader_available
    && (match input_policy with Keeper_input_policy.Small -> true | Wide -> false) in
  let expect_arguments_demoted = expect_demoted
    && (match argument_seed with Completed_seed -> true | Open_seed | No_seed -> false) in
  let system_prompt = "Demotion fixture: \"quoted\"\nUTF-8 관측\\suffix." in
  let manifest_config = Workspace.default_config base_path in
  let manifest_context : Keeper_runtime_manifest.turn_context =
    { manifest_keeper_name = "demote-proof"
    ; manifest_trace_id = trace_id
    ; manifest_keeper_turn_id = Some 2
    }
  in
  check bool "the fresh trace has no earlier ledger" true
    (Keeper_model_input_ledger.Table.lookup
       ~keeper_name:"demote-proof" ~runtime_id:"fixture.sample" ~session_id:trace_id = None);
  let observer = Observation.create ~mode:Timed in
  let result =
    Observation.within observer (fun () ->
    Observation.with_wake ~keeper:"demote-proof" ~trace_id ~absolute_turn:2
      ~execution_scope:None ~cause:None (fun () ->
    Keeper_turn_driver.run_named ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = trace_id }) ~raw_trace:None ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
      ~input_policy ?argument_demotion_seed

      ~system_prompt
      ~runtime_id:"fixture.sample"
      ~keeper_name:"demote-proof"
      ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
      ~tools
      ~agent_core_tools:tools
      ~goal:"execute tool"
      ~initial_messages
      ~runtime_manifest_context:manifest_context
      ~runtime_manifest_append:(fun row ->
        Keeper_runtime_manifest.append_best_effort manifest_config row)
      ~sw ~net:env#net ()))
  in
  (match result with
   | Ok _ -> ()
   | Error error -> fail (Agent_core.Error.to_string error));
  check int "the Keeper completed 2 requests" 2
    (Exact_output_fixture.post_count server);
  check bool "the active tool executes once with the exact long original input" true
    (!executed_inputs = [active_input]);
  let request_bodies = Exact_output_fixture.request_bodies server in
  let expected_names = List.map (fun (tool : Agent_core.Tool.t) -> tool.schema.name) tools in
  List.iter (fun body ->
    let request = Yojson.Safe.from_string body in
    let names = Yojson.Safe.Util.(member "tools" request |> to_list)
      |> List.map (fun tool -> Yojson.Safe.Util.(member "function" tool |> member "name" |> to_string)) in
    check (list string) "the actual provider requests retain nonempty declared tool order"
      expected_names names;
    let first_message = Yojson.Safe.Util.(member "messages" request |> to_list) |> List.hd in
    check string "the actual first system message preserves escaped UTF-8 input"
      system_prompt Yojson.Safe.Util.(member "content" first_message |> to_string)) request_bodies;
  (* Compute expected byte and prefix values only after the real run, so
     their encoding cannot prime the worker's cold SDK count lookup. *)
  let expected_reserved_bytes =
    List.fold_left (fun bytes tool ->
      bytes + String.length (Yojson.Safe.to_string (Agent_core.Tool.schema_to_json tool)))
      (String.length (Yojson.Safe.to_string (`String system_prompt))) tools
  in
  let manifest_path = Keeper_runtime_manifest.path_for_trace manifest_config
    ~keeper_name:"demote-proof" ~trace_id in
  let manifest_rows = In_channel.with_open_bin manifest_path In_channel.input_all
    |> String.split_on_char '\n'
    |> List.filter (fun line -> line <> "")
    |> List.map (fun line ->
      match Keeper_runtime_manifest.decode_persisted_row (Yojson.Safe.from_string line) with
      | Ok (Keeper_runtime_manifest.Active_row row) -> row
      | Ok (Keeper_runtime_manifest.Unsupported_row _) -> fail "fixture retained an unsupported manifest event"
      | Error detail -> fail detail)
  in
  (match List.filter (fun (row : Keeper_runtime_manifest.t) ->
     row.event = Keeper_runtime_manifest.History_projection_observed) manifest_rows with
   | [row] ->
     check string "reserve manifest belongs to this Keeper" "demote-proof" row.keeper_name;
     check string "reserve manifest belongs to this fresh trace" trace_id row.trace_id;
     check (option int) "reserve manifest belongs to this original turn" (Some 2) row.keeper_turn_id;
     check string "the actual projection prepared its request" "history_projection_prepared" row.status;
     check int "the retained decision charges exact declared schema and escaped prompt bytes"
       expected_reserved_bytes Yojson.Safe.Util.(member "reserved_bytes" row.decision |> to_int)
   | _ -> fail "expected the real attempt's one retained history projection decision");
  (match Keeper_model_input_ledger.Table.lookup
     ~keeper_name:"demote-proof" ~runtime_id:"fixture.sample" ~session_id:trace_id with
   | Some ledger ->
     check string "the accepted request ledger consumes the exact declared prefix"
       (Keeper_model_input_ledger.prefix_digest ~system_prompt ~tools) ledger.prefix_digest
   | None -> fail "the completed real requests did not populate their ledger");
  let report = Observation.report_to_json (Observation.snapshot observer) in
  (match Observation.report_of_json report with
   | Ok _ -> ()
   | Error detail -> fail detail);
  let events = Yojson.Safe.Util.(member "events" report |> to_list) in
  let payload event = Yojson.Safe.Util.member "payload" event in
  let is_span kind site event =
    Yojson.Safe.Util.member "kind" (payload event) = `String kind
    && Yojson.Safe.Util.member "site" (payload event) = `String site in
  let sequence event = Yojson.Safe.Util.(member "sequence" event |> to_int) in
  let in_reserve event =
    Yojson.Safe.Util.(member "scope" event |> member "parent_site") = `String "reserve_encode" in
  let reserve = List.find (fun event ->
    is_span "span_started" "sdk_byte_count_lookup" event && in_reserve event) events in
  let prefixes = List.filter (is_span "span_started" "prefix_digest_encode") events in
  check int "the real prefix encodes every declared tool occurrence once"
    (List.length tools) (List.length prefixes);
  List.iter (fun event ->
    check bool "prefix encoding is outside the reserve dynamic scope" false
      (in_reserve event)) prefixes;
  let last_prefix = List.hd (List.rev prefixes) in
  let enclosing_workers = List.filter (fun start ->
    if not (is_span "span_started" "worker_work" start) then false
    else
      let span_id = Yojson.Safe.Util.member "span_id" (payload start) in
      let finish = List.find (fun event ->
        is_span "span_finished" "worker_work" event
        && Yojson.Safe.Util.member "span_id" (payload event) = span_id) events in
      sequence start < sequence reserve && sequence finish > sequence last_prefix) events in
  check int "one real worker invocation encloses reserve and the complete prefix" 1
    (List.length enclosing_workers);
  check bool "the real reserve retains cold SDK encoding" true
    (List.exists (fun event ->
       is_span "span_finished" "sdk_byte_count_encode" event && in_reserve event) events);
  check bool "the real reserve retains SDK count publication" true
    (List.exists (fun event ->
       is_span "span_finished" "sdk_byte_count_publication" event && in_reserve event) events);
  let second_body = List.nth (Exact_output_fixture.request_bodies server) 1 in
  check bool "historical body is replaced only with completion and reader" (not expect_demoted)
    (String_util.contains_substring second_body historical_payload);
  check bool "current-turn tool body remained verbatim inline" true
    (String_util.contains_substring second_body active_payload);
  let messages = Yojson.Safe.Util.(Yojson.Safe.from_string second_body |> member "messages" |> to_list) in
  let wire_arguments messages id =
    let calls = List.concat_map (fun message ->
      match Yojson.Safe.Util.member "tool_calls" message with
      | `List calls -> calls
      | `Null -> []
      | _ -> fail "tool_calls must be an array") messages in
    let call = List.find (fun call -> Yojson.Safe.Util.member "id" call = `String id) calls in
    Yojson.Safe.Util.(member "function" call |> member "arguments" |> to_string)
    |> Yojson.Safe.from_string in
  let historical_arguments = wire_arguments messages "call-demote-1" in
  check bool "current-turn arguments remain exact on the second HTTP request" true
    (wire_arguments messages "active-call-1" = active_input);
  let first_messages = Yojson.Safe.Util.(
    List.hd (Exact_output_fixture.request_bodies server)
    |> Yojson.Safe.from_string |> member "messages" |> to_list) in
  check bool "historical argument binding remains frozen across actual requests" true
    (wire_arguments first_messages "call-demote-1" = historical_arguments);
  (match Tool_output.normalized_artifact_ref_of_json historical_arguments with
   | Tool_output.Not_normalized_artifact_ref
   | Tool_output.Invalid_normalized_artifact_ref _ ->
     check bool "unproven or unreadable historical arguments stay exact" false expect_arguments_demoted;
     check bool "historical original JSON remains inline" true
       (historical_arguments = historical_input)
   | Tool_output.Decoded_normalized_artifact_ref reference ->
     check bool "only proven completed arguments become references" true expect_arguments_demoted;
     check string "argument artifact MIME" "application/json" reference.mime;
     let page = match Agent_core.Tool.execute reader
         (`Assoc ["sha256", `String reference.sha256]) with
       | Error error -> fail error.Agent_core.Types.message
       | Ok result -> Yojson.Safe.from_string result.content in
     check bool "canonical bridged reader returns the complete argument artifact" true
       Yojson.Safe.Util.(member "eof" page |> to_bool);
     let fetched = Yojson.Safe.Util.(member "content" page |> to_string) in
     check string "canonical reader restores exact original argument bytes"
       (Yojson.Safe.to_string historical_input) fetched;
     check bool "the retrieved argument JSON is reusable without loss" true
       (Yojson.Safe.from_string fetched = historical_input));
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
  check bool "historical tool message carries a retrievable reference only when safe" expect_demoted
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
  if not expect_demoted then
    check string "unproven or unreadable historical body stays verbatim"
      historical_payload historical_content
  else
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
          (test_historical_tool_results ~completed:true ~reader_available:true)
      ; test_case "without completion evidence historical bodies stay inline" `Quick
          (test_historical_tool_results ~completed:false ~reader_available:true)
      ; test_case "without a reader historical bodies stay inline" `Quick
          (test_historical_tool_results ~completed:true ~reader_available:false)
      ; test_case "without a raw seed historical arguments stay inline" `Quick
          (test_historical_tool_results ~argument_seed:No_seed ~completed:true ~reader_available:true)
      ; test_case "a dispatch closer cannot complete raw open arguments" `Quick
          (test_historical_tool_results ~argument_seed:Open_seed ~completed:true ~reader_available:true)
      ; test_case "Wide keeps historical arguments and results inline" `Quick
          (test_historical_tool_results ~input_policy:Keeper_input_policy.Wide ~completed:true ~reader_available:true)
      ]
    ]
