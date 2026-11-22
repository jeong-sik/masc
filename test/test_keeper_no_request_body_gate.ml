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
  let catalog_snapshot = Llm_provider.Catalog_snapshot.current () in
  let base_path = Filename.temp_file "keeper-no-body-gate-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    (Llm_provider.Catalog_snapshot.publish catalog_snapshot);
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
   | Ok catalog -> (Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some (catalog)) ~providers:(None))));
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
  (match Yojson.Safe.Util.(projection |> member "runtimes" |> to_list) with
   | [runtime] ->
     check string "API keeps the runtime identity" "fixture.sample"
       Yojson.Safe.Util.(runtime |> member "id" |> to_string)
   | _ -> fail "expected exactly one projected runtime");
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

let () =
  Alcotest.run "keeper_no_request_body_gate"
    [ "actual-dispatch",
      [ test_case "a large request reaches the peer and a refusal moves the lane" `Quick
          test_a_large_request_reaches_the_peer_and_a_refusal_moves_the_lane
      ]
    ]
