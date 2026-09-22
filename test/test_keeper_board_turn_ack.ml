(* Board routing, the Owner-internal turn and durable ACK use production code.
   The fixture seeds the runtime registry, injects one transient Board read and
   supplies a loopback model response to a short Board preview. It calls the
   cycle directly, so the outer heartbeat scheduler and its admission checks
   are outside this test. No sandbox tools are invoked. *)
open Masc

let require condition detail = if not condition then failwith detail
let get render = function Ok value -> value | Error error -> failwith (render error)
let save path text = Fs_compat.mkdir_p (Filename.dirname path); Fs_compat.save_file path text
let json path value = save path (Yojson.Safe.pretty_to_string value ^ "\n")
let keeper_name = "board-ack-probe"
let other_name = "board-ack-control"

let initialize_runtime ~base_path (server : Exact_output_fixture.test_server) =
  let model_id = "board-ack-protocol-fixture" in
  let catalog_path = Filename.concat base_path "model-catalog.toml" in
  save catalog_path (Printf.sprintf
    "[[models]]\nid_prefix = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 1048576\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = true\n"
    model_id);
  Llm_provider.Model_catalog.load_file catalog_path |> get Fun.id
  |> Llm_provider.Model_catalog.set_global;
  let path = Filename.concat
    (Filename.concat (Filename.concat base_path Common.masc_dirname) "config")
    "runtime.toml" in
  save path (Printf.sprintf
    "[runtime]\ndefault = \"fixture.sample\"\n[providers.fixture]\nprotocol = \"openai-compatible-http\"\nendpoint = %S\n[models.sample]\napi-name = %S\nmax-context = 1048576\nstreaming = true\n[fixture.sample]\n"
    server.Exact_output_fixture.base_url model_id);
  match Runtime.init_default_degraded_report ~config_path:path with
  | Ok Runtime.Initialized -> ()
  | Ok (Runtime.Initialized_degraded _) -> failwith "fixture runtime is degraded"
  | Error error -> failwith (Runtime.strict_init_error_to_string error)

let install_keeper config name =
  save (Filename.concat (Config_dir_resolver.keepers_dir_for_base_path
    ~base_path:config.Workspace.base_path) (name ^ ".toml"))
    "[keeper]\nsandbox_profile = \"docker\"\nnetwork_mode = \"none\"\nactivation_mode = \"autonomous\"\ninstructions = \"Acknowledge the synthetic Board message. Do not call tools.\"\n";
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name", `String name; "trace_id", `String ("trace-" ^ name)])
    |> get Fun.id in
  let created = Keeper_owner_registry.create_meta
    ~base_path:config.base_path meta
    |> get Keeper_owner_registry.command_error_to_string in
  require (Option.is_some created) "Owner did not persist the Keeper";
  let meta = match Keeper_meta_store.read_effective_meta config name |> get Fun.id with
    | Some meta -> meta | None -> failwith "effective Keeper metadata is absent" in
  require (meta.sandbox_profile = Keeper_types_profile_sandbox.Docker)
    "effective Keeper profile is not Docker";
  require (meta.network_mode = Keeper_types_profile_sandbox.Network_none)
    "effective Keeper network mode changed";
  let registry_entry =
    Keeper_registry.For_testing.register ~base_path:config.base_path name meta
  in
  meta, registry_entry

let queue config name =
  Keeper_registry_event_queue.snapshot_result ~base_path:config.Workspace.base_path name
  |> get Fun.id

let queue_count config name = Keeper_event_queue.length (queue config name)

let evidence config stimulus_id =
  match Keeper_reaction_ledger.event_queue_reaction_evidence_result
    ~base_path:config.Workspace.base_path ~keeper_name ~stimulus_id
    |> get Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string with
  | Keeper_reaction_ledger.Evidence_complete evidence -> evidence
  | Keeper_reaction_ledger.Evidence_quarantined _ -> failwith "reaction evidence quarantined"

let completed_record config =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  match Dated_jsonl.read_recent_result store 1 |> get Dated_jsonl.read_error_to_string with
  | [Dated_jsonl.Parsed row] ->
    let record = Turn_record.of_json row |> get Fun.id in
    require (record.finish_reason = Some
      (Keeper_execution_receipt.stop_reason_to_string Runtime_agent.Completed))
      "actual turn did not record Completed";
    row
  | [] | _ :: _ -> failwith "one strict completed TurnRecord was required"

let run base_path prompt_root =
  require (not (Filename.is_relative base_path)) "base path must be absolute";
  require (not (Sys.file_exists base_path)) "base path must be new";
  require (not (Filename.is_relative prompt_root)) "prompt root must be absolute";
  require (Sys.file_exists (Filename.concat prompt_root "keeper.md")) "prompt root is invalid";
  Unix.mkdir base_path 0o700;
  let base_path = Unix.realpath base_path in
  Unix.chdir base_path;
  Config_dir_resolver.reset ();
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs env#fs;
  require (Fs_compat.has_fs ()) "FileSystem is not installed";
  require (Fs_compat.execution_context () = Fs_compat.Eio_fiber) "not an Eio FileSystem caller";
  Masc_test_deps.init_eio_clock ~sw env;
  Eio_context.set_net env#net;
  Eio_context.set_mono_clock env#mono_clock;
  Process_eio.init ~cwd_default:Eio.Path.(env#fs / base_path)
    ~proc_mgr:env#process_mgr ~clock:env#clock;
  Masc_test_deps.ensure_rng_initialized ();
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Model_catalog.global () in
  Eio.Switch.on_release sw (fun () ->
    Keeper_heartbeat_stimulus_intake.For_testing.force_transient_board_reads 0;
    Board_dispatch.reset_for_test ();
    Board.reset_global_for_test ();
    Keeper_registry.For_testing.clear ();
    Runtime.For_testing.restore runtime_snapshot;
    match catalog_snapshot with
    | None -> Llm_provider.Model_catalog.clear_global ()
    | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
  let config = Workspace.default_config base_path in
  (match config.backend with
   | Workspace.FileSystem _ -> ()
   | Workspace.Memory _ -> failwith "probe requires a FileSystem workspace backend");
  ignore (Workspace.init config ~agent_name:(Some "board-probe-operator") : string);
  require (String.equal (Unix.realpath config.base_path) base_path) "Workspace escaped probe base";
  save (Filename.concat base_path "filesystem-proof.txt") "isolated FileSystem\n";
  require (Eio.Path.load Eio.Path.(env#fs / base_path / "filesystem-proof.txt")
    = "isolated FileSystem\n") "FileSystem write/read disagree";
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
    (* Keeper's progress observer uses the streaming Agent Core path. *)
    (Exact_output_fixture.Stream_reply
      {|data: {"id":"board-ack","model":"board-ack-protocol-fixture","choices":[{"index":0,"delta":{"role":"assistant","content":"Synthetic Board message observed."},"finish_reason":null}]}

data: {"id":"board-ack","model":"board-ack-protocol-fixture","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":5,"total_tokens":12}}

data: [DONE]

|}) in
  initialize_runtime ~base_path server;
  Prompt_registry.clear ();
  Prompt_registry.set_markdown_dir prompt_root;
  Prompt_defaults.init ();
  Masc_test_deps.init_unified_tool_registry ();
  Keeper_registry.For_testing.clear ();
  ignore (Keeper_owner_registry.install_from_store ~sw ~operation_runner:None
    ~on_turn_slot_released:None config |> get Keeper_owner_registry.install_error_to_string);
  let meta, registry_entry = install_keeper config keeper_name in
  (* The control Keeper receives no cycle, so it never starts a sandbox. *)
  ignore (install_keeper config other_name);
  Eio.Switch.on_release sw (fun () ->
    let cleanup = Keeper_turn_sandbox_runtime.teardown_keeper_sandbox
      ~timeout_sec:Exact_output_fixture.fixture_wait_seconds ~config ~meta () in
    json (Filename.concat base_path "sandbox-cleanup.json")
      (match cleanup with Ok () -> `Assoc ["ok", `Bool true]
       | Error detail -> `Assoc ["ok", `Bool false; "error", `String detail]);
    ignore (cleanup |> get Fun.id));
  Masc_test_deps.with_publication_recovery_registry ~sw ~fs:env#fs
    ~registry_root:(Workspace.masc_root_dir config) @@ fun publication_registry ->
  let ctx : _ Keeper_types_profile.context =
    { config; agent_name = "board-probe-operator"; sw; clock = env#clock
    ; proc_mgr = Some env#process_mgr; net = Some env#net
    ; publication_recovery_provider = Masc_test_deps.publication_recovery_provider publication_registry } in
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  Board_dispatch.set_board_signal_hook
    (Keeper_keepalive_signal.wakeup_relevant_keeper_for_board_signal ~config);
  let content = "@" ^ keeper_name ^ " Atlas staging uses PostgreSQL 15." in
  let post = Board_dispatch.create_post ~author:"synthetic-user" ~content
    ~post_kind:Board.Human_post ~visibility:Board.Internal () |> get Board.show_board_error in
  let post_id = Board.Post_id.to_string post.id in
  require (queue_count config keeper_name = 1) "direct mention did not enqueue exactly once";
  require (queue_count config other_name = 0) "direct mention reached the unaddressed Keeper";
  let pending = Keeper_event_queue.to_list (queue config keeper_name) in
  let stimulus_id = match pending with
    | [stimulus] -> Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus
    | _ -> failwith "expected one durable Board stimulus" in
  let shared_context = Agent_core.Context.create () in
  let cycle meta = Keeper_heartbeat_loop.run_keepalive_unified_turn
    ~wake:Keeper_world_observation.Attention_wake ~ctx ~registry_entry
    ~meta_after_triage:meta
    ~pending_board_events:[] ~stop:(Atomic.make false) ~proactive_warmup_elapsed:true
    ~reactive_wake:true ~shared_context ~deferred_runtime_lane:None
    ~on_deferred_runtime_consumed:(fun () -> ())
    ~record_deferred_runtime_lane:(fun _ -> failwith "unexpected runtime failover") in
  Keeper_heartbeat_stimulus_intake.For_testing.force_transient_board_reads 1;
  let first = cycle meta in
  require (not first.stimuli_acked) "transient read was ACKed";
  require (Exact_output_fixture.post_count server = 0) "transient read dispatched a model request";
  require (Keeper_event_queue.to_list (queue config keeper_name) = pending)
    "transient read changed the durable pending source";
  require (not (evidence config stimulus_id).event_queue_ack_seen) "transient read persisted ACK evidence";
  let second = cycle first.meta in
  require (second.stimuli_acked) "actual completed turn did not ACK its source";
  require (queue_count config keeper_name = 0) "source remains queued after completion";
  require (Exact_output_fixture.post_count server = 1) "expected exactly one model request";
  let row = completed_record config in
  json (Filename.concat base_path "completed-turn-record.json") row;
  let request = match Exact_output_fixture.request_bodies server with
    | [body] -> Yojson.Safe.from_string body | _ -> failwith "expected one captured request" in
  json (Filename.concat base_path "provider-input.json") request;
  let open Yojson.Safe.Util in
  require (member "stream" request = `Bool true)
    "the fixture did not exercise the streaming Keeper request";
  let request_texts = request |> member "messages" |> to_list
    |> List.map (fun message -> message |> member "content" |> to_string) in
  (* Production renders admitted Board evidence as quoted row fields. *)
  require (List.exists
    (Astring.String.is_infix ~affix:(Printf.sprintf "post_id=%S" post_id)) request_texts)
    "the actual request omitted the admitted Board post identity";
  require (List.exists
    (Astring.String.is_infix ~affix:(Printf.sprintf "preview=%S" content)) request_texts)
    "the actual request omitted the short Board preview";
  let settled = evidence config stimulus_id in
  (* Board input is persisted in the queue checked above. Its reaction ledger
     records the ACK; Schedule/HITL turn reactions are a different contract.
     Completion above comes from the actual TurnRecord. *)
  require (settled.event_queue_ack_seen && not settled.event_queue_cancelled_seen)
    (Printf.sprintf "Board ACK missing for %s (rows=%d, cancelled=%b)"
       stimulus_id settled.matched_record_count settled.event_queue_cancelled_seen);
  (* Inspect the next intake only: an empty queue does not forbid unrelated
     autonomous work, so another model turn would not itself prove redelivery. *)
  let third = Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
    ~ctx ~meta_after_triage:second.meta ~pending_board_events:[] in
  require (Keeper_heartbeat_source_batch.count third.source_batch = 0)
    "the completed source was admitted again";
  require (queue_count config keeper_name = 0 && queue_count config other_name = 0)
    "next tick repeated delivery";
  require (Exact_output_fixture.post_count server = 1) "intake unexpectedly dispatched";
  require ((evidence config stimulus_id).matched_record_count = settled.matched_record_count)
    "empty next intake added another reaction or ACK";
  (* A later batch contains four distinct sources on the same post. Replay
     contributes one identical comment, which must not hide the other three. *)
  let comment_body = "@" ^ keeper_name ^ " identical follow-up" in
  let add_comment () = Board_dispatch.add_comment ~post_id ~author:"synthetic-user"
      ~content:comment_body () |> get Board.show_board_error in
  let first_comment = add_comment () in
  let second_comment = add_comment () in
  let edit body = Board_dispatch.update_post ~post_id ~editor:"synthetic-user"
      ~content:body ~title:"edited thread" ~body () |> get Board.show_board_error in
  let first_edit = edit ("@" ^ keeper_name ^ " first edit") in
  let second_edit = edit ("@" ^ keeper_name ^ " second edit") in
  require (first_edit.content_updated_at <> second_edit.content_updated_at)
    "two actual persisted edits must carry distinct content update times";
  let pending = Keeper_event_queue.to_list (queue config keeper_name) in
  require (List.length pending = 4) "distinct comments/edits were lost before intake";
  let replay = Keeper_world_observation.pending_board_event_of_stimulus
      ~meta:second.meta (List.hd pending) |> get
        Keeper_world_observation_board_signal.unavailable_to_string in
  let replay = match replay with Some event -> event | None -> failwith "comment replay missing" in
  let intake = Masc_test_deps.with_process_env "MASC_KEEPER_ADMISSION_MAX_EVENTS"
      (Some (string_of_int (List.length pending))) (fun () ->
        Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
          ~ctx ~meta_after_triage:second.meta ~pending_board_events:[replay]) in
  require (Keeper_heartbeat_source_batch.count intake.source_batch = 4)
    "actual intake did not admit all four sources";
  require (List.length intake.pending_board_events = 4)
    "intake merged distinct post events or duplicated exact replay";
  let comments, edits = List.fold_left
    (fun (comments, edits) (event : Keeper_world_observation.pending_board_event) ->
      match event.event_kind with
      | Keeper_world_observation.Board_comment_added { Board_dispatch.comment_id; _ } ->
        Board.Comment_id.to_string comment_id :: comments, edits
      | Keeper_world_observation.Board_post_updated -> comments, event.updated_at :: edits
      | _ -> failwith "unexpected event kind in follow-up intake")
    ([], []) intake.pending_board_events in
  require (List.sort String.compare comments = List.sort String.compare
      [Board.Comment_id.to_string first_comment.id; Board.Comment_id.to_string second_comment.id])
    "same-body comment identities were not both shown";
  require (List.sort Float.compare edits = List.sort Float.compare
      [first_edit.content_updated_at; second_edit.content_updated_at])
    "distinct edit identities were not both shown";
  require (queue_count config keeper_name = 4)
    "preparing observations prematurely acknowledged queued sources";
  require (Exact_output_fixture.post_count server = 1) "intake unexpectedly ran a model";
  let summary = `Assoc
    ["post_id", `String post_id; "keeper", `String keeper_name
    ; "model_response", `String "synthetic loopback protocol"
    ; "transient_pending_preserved", `Bool true; "completed_ack", `Bool true
    ; "next_tick_duplicate", `Bool false; "http_requests", `Int 1] in
  json (Filename.concat base_path "probe-result.json") summary;
  print_endline (Yojson.Safe.to_string summary)

let test_board_source_is_acked_after_completed_turn () =
  let prompt_root = Masc_test_deps.source_path "config/prompts" |> Unix.realpath in
  let base_path = Filename.temp_dir "keeper-board-turn-ack-" "" |> Unix.realpath in
  Unix.rmdir base_path;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir cwd;
      Config_dir_resolver.reset ();
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
      Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some base_path) @@ fun () ->
      Masc_test_deps.with_process_env "MASC_CONFIG_DIR"
        (Some (Filename.concat (Filename.concat base_path Common.masc_dirname) "config"))
      @@ fun () ->
      Masc_test_deps.with_process_env "XDG_CONFIG_HOME"
        (Some (Filename.concat base_path "xdg-config"))
      @@ fun () ->
      run base_path prompt_root)

let () =
  Alcotest.run "keeper_board_turn_ack"
    [ "continuity",
      [ Alcotest.test_case "completed Keeper turn ACKs its Board source once"
          `Quick test_board_source_is_acked_after_completed_turn ] ]
