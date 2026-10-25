(* Actual Owner/heartbeat/model/checkpoint/ACK, followed by a fresh process reader.
   HTTP is a synthetic provider; no sandbox tools or external messages execute. *)
open Masc

let require condition detail = if not condition then failwith detail
let get render = function Ok value -> value | Error error -> failwith (render error)
let save path text = Fs_compat.mkdir_p (Filename.dirname path); Fs_compat.save_file path text
let keeper_name = "informational-checkpoint-probe"

let initialize_runtime ~base_path (server : Exact_output_fixture.test_server) =
  let model_id = "informational-protocol-fixture" in
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
    "[keeper]\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\nnetwork_mode = \"none\"\nactivation_mode = \"autonomous\"\ninstructions = \"Observe the synthetic completion results, then inspect context status.\"\n";
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


module Q = Keeper_event_queue
let later_work : Q.stimulus =
  { post_id = "later-work-26165"; urgency = Q.Low; arrived_at = 100.
  ; payload = Q.Bootstrap }
let informational_sources () =
  let channel = Keeper_continuation_channel.dashboard ~thread_id:("keeper:" ^ keeper_name)
    |> get Fun.id in
  let fusion : Q.fusion_completion =
    { run_id = "fusion-26165"; terminal = Q.Fusion_succeeded "fusion-result-26165"
    ; board_post_id = ""; channel } in
  let delegate : Q.delegate_completion =
    { dc_operation_id = "delegate-26165"; dc_keeper = "peer-fixture"
    ; dc_terminal = Q.Delegate_replied "delegate-result-26165" } in
  let composition : Q.composition_completion =
    { cc_request_id = "composition-26165"; cc_tool = "keeper_compose_memory-proof"
    ; cc_terminal = Q.Composition_failed "composition-result-26165" } in
  [ { Q.post_id = Q.fusion_completion_post_id fusion; urgency = Q.High
      ; arrived_at = 1.; payload = Q.Fusion_completed fusion }
  ; { Q.post_id = Q.delegate_completion_post_id delegate; urgency = Q.High
      ; arrived_at = 2.; payload = Q.Delegate_completed delegate }
  ; { Q.post_id = Q.composition_completion_post_id composition; urgency = Q.High
      ; arrived_at = 3.; payload = Q.Composition_completed composition } ]
let evidence config source =
  let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue source in
  match Keeper_reaction_ledger.event_queue_reaction_evidence_result
    ~base_path:config.Workspace.base_path ~keeper_name ~stimulus_id
    |> get Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string with
  | Keeper_reaction_ledger.Evidence_complete evidence -> evidence
  | Keeper_reaction_ledger.Evidence_quarantined _ -> failwith "reaction evidence quarantined"
let check_sources_visible text =
  List.iter (fun marker -> require (Astring.String.is_infix ~affix:marker text)
    ("model input or checkpoint omitted " ^ marker))
    [ "fusion-result-26165"; "delegate-result-26165"; "composition-result-26165" ]
let check_checkpoint config meta =
  let checkpoint = Keeper_checkpoint_store.load_agent_core
    ~session_dir:(Keeper_types_support.keeper_session_dir config keeper_name)
    ~session_id:(Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id)
    |> get Keeper_checkpoint_store.checkpoint_load_error_to_string in
  check_sources_visible (Agent_core.Checkpoint.to_string checkpoint)
let queue_chat config =
  let operation_id = Keeper_chat_operation.Operation_id.of_string "kmsg-checkpoint-person" |> get Fun.id in
  let thread_id = "keeper:" ^ keeper_name in
  let channel = Keeper_continuation_channel.dashboard ~thread_id |> get Fun.id in
  let source = Keeper_chat_operation_payload.source_to_json ~submitted_by:"operator"
    ~thread_id ~continuation_channel:channel
    ~surface:(Surface_ref.Dashboard {session_id=None})
    ~channel:"" ~channel_user_id:"" ~channel_user_name:"" ~channel_workspace_id:""
    ~conversation_id:None ~external_message_id:None ~workspace_id:None ~extra_mentions:[]
    ~sender_keeper:None ~user_row_origin:Keeper_chat_store.Needs_append |> get Fun.id in
  let input = Keeper_chat_operation_payload.input_to_json ~message:"Person waits after checkpoint"
    ~user_blocks:[] ~turn_instructions:None ~surface_context:None ~attachments:[] in
  ignore (Keeper_owner_registry.submit_operation ~base_path:config.Workspace.base_path
    ~keeper_name ~operation_id ~source ~input |> get Keeper_owner_registry.command_error_to_string)
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
  (* The call ledger is initialized by the server bootstrap, which this probe
     does not run; initialize it to capture the probe's actual tool receipts. *)
  Keeper_tool_call_log.init ~base_path ();
  Masc_test_deps.write_sandbox_image_catalog ~base_path
    ["base", Masc_test_deps.live_sandbox_image_tag];
  require (String.equal (Unix.realpath config.base_path) base_path) "Workspace escaped probe base";
  save (Filename.concat base_path "filesystem-proof.txt") "isolated FileSystem\n";
  require (Eio.Path.load Eio.Path.(env#fs / base_path / "filesystem-proof.txt")
    = "isolated FileSystem\n") "FileSystem write/read disagree";
  let first_request = ref true in
  let on_request_before_reply () =
    if !first_request then (
      first_request := false;
      Keeper_registry_event_queue.enqueue_durable_result ~base_path keeper_name later_work |> get Fun.id;
      queue_chat config)
  in
  let server = Exact_output_fixture.start_server ~on_request_before_reply
    ~sw ~net:env#net ~clock:env#clock
    (Exact_output_fixture.Stream_reply
      {|data: {"id":"information-checkpoint","model":"informational-protocol-fixture","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"context-call-26165","type":"function","function":{"name":"keeper_context_status","arguments":"{}"}}]},"finish_reason":null}]}

data: {"id":"information-checkpoint","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":7,"completion_tokens":5,"total_tokens":12}}

data: [DONE]

|}) in
  initialize_runtime ~base_path server;
  Prompt_registry.clear (); Prompt_registry.set_markdown_dir prompt_root; Prompt_defaults.init ();
  Masc_test_deps.init_unified_tool_registry (); Keeper_registry.For_testing.clear ();
  let operation_runner : Keeper_owner.operation_runner =
    { ready = (fun ~keeper_name:_ -> true)
    ; execute = (fun ~sw:_ ~keeper_name:_ ~claim ->
        require (Option.is_some (claim () |> get Keeper_owner.error_to_string)) "chat claim absent";
        Keeper_owner.Operation_succeeded {outcome_ref="person-after-checkpoint"})
    ; on_execution_settled = (fun ~keeper_name:_ ~claimed_operation_id:_ ~operations:_ ~execution:_ -> ()) } in
  ignore (Keeper_owner_registry.install_from_store ~sw ~operation_runner:(Some operation_runner)
    ~on_turn_slot_released:None config |> get Keeper_owner_registry.install_error_to_string);
  let meta, registry_entry = install_keeper config keeper_name in
  Eio.Switch.on_release sw (fun () ->
    Keeper_turn_sandbox_runtime.teardown_keeper_sandbox
      ~timeout_sec:Exact_output_fixture.fixture_wait_seconds ~config ~meta () |> get Fun.id);
  Masc_test_deps.with_publication_recovery_registry ~sw ~fs:env#fs
    ~registry_root:(Workspace.masc_dir config) @@ fun publication_registry ->
  let ctx : _ Keeper_types_profile.context =
    { config; agent_name="informational-probe"; sw; clock=env#clock
    ; proc_mgr=Some env#process_mgr; net=Some env#net
    ; publication_recovery_provider=Masc_test_deps.publication_recovery_provider publication_registry } in
  let async_entry : Keeper_msg_async.entry =
    { request_id="composition-26165";keeper_name;base_path;submitted_by=keeper_name
    ;request_context=Some ["composition_tool",`String "keeper_compose_memory-proof"]
    ;status=Keeper_msg_async.Done {ok=false;body="composition-result-26165";data=None}
    ;submitted_at=1.;completed_at=Some 2. } in
  Keeper_msg_async.For_testing.persist_terminal_record async_entry |> get Fun.id;
  List.iter (fun source -> Keeper_registry_event_queue.enqueue_durable_result
    ~base_path keeper_name source |> get Fun.id) (informational_sources ());
  require (queue_count config keeper_name=3) "expected three completion sources";
  let outcome = Keeper_heartbeat_loop.run_keepalive_unified_turn
    ~wake:Keeper_world_observation.Attention_wake ~ctx ~registry_entry ~meta_after_triage:meta
    ~pending_board_events:[] ~stop:(Atomic.make false) ~proactive_warmup_elapsed:true
    ~reactive_wake:true ~shared_context:(Agent_core.Context.create ()) ~deferred_runtime_lane:None
    ~on_deferred_runtime_consumed:(fun () -> ())
    ~settle_deferred_runtime_lane:(function Some _ -> failwith "unexpected runtime failover" | None -> ()) in
  require outcome.stimuli_acked "actual checkpoint did not ACK informational batch";
  (match Keeper_last_turn_stop.get ~base_path ~keeper:keeper_name with
   | Some Keeper_turn_checkpoint_reason.Operation_queued -> ()
   | Some _ | None -> failwith "actual cycle did not checkpoint for queued person chat");
  require (Exact_output_fixture.post_count server=1) "expected one actual provider round";
  let request = match Exact_output_fixture.request_bodies server with
    | [body] -> body | _ -> failwith "expected one captured provider request" in
  check_sources_visible request;
  check_checkpoint config outcome.meta;
  let pending = Keeper_event_queue.to_list (queue config keeper_name) in
  require (List.map (fun (s:Q.stimulus)->s.post_id) pending = [later_work.post_id])
    "ACK lost later work or retained delivered completions";
  List.iter (fun source ->
    let observed=evidence config source in
    require (observed.event_queue_ack_seen && not observed.event_queue_cancelled_seen)
      "completion has no durable ACK evidence") (informational_sources ());
  print_endline (Yojson.Safe.to_string (`Assoc ["phase",`String "actual-checkpoint"
    ;"provider_rounds",`Int 1;"informational_acks",`Int 3;"later_work_retained",`Bool true]))

let reopen base_path =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs env#fs; Masc_test_deps.init_eio_clock ~sw env;
  Masc_test_deps.ensure_rng_initialized ();
  Config_dir_resolver.reset ();
  let config=Workspace.default_config base_path in
  let meta=match Keeper_meta_store.read_effective_meta config keeper_name |> get Fun.id with
    | Some meta->meta | None->failwith "reopen metadata absent" in
  ignore (Keeper_registry.For_testing.register ~base_path keeper_name meta);
  Eio.Switch.on_release sw Keeper_registry.For_testing.clear;
  let ctx : _ Keeper_types_profile.context =
    {config;agent_name="informational-reader";sw;clock=env#clock;proc_mgr=None;net=None
    ;publication_recovery_provider=Masc_test_deps.non_runtime_publication_recovery_provider} in
  check_checkpoint config meta;
  let intake=Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
    ~ctx ~meta_after_triage:meta ~pending_board_events:[] in
  require (List.map (fun (s:Q.stimulus)->s.post_id)
    (Keeper_heartbeat_source_batch.stimuli intake.source_batch)=[later_work.post_id])
    "fresh process re-admitted delivered informational input or lost later work";
  List.iter(fun source->require (evidence config source).event_queue_ack_seen
    "fresh process lost ACK evidence") (informational_sources ());
  print_endline (Yojson.Safe.to_string (`Assoc ["phase",`String "new-process-reopen"
    ;"pid",`Int (Unix.getpid ());"redelivered_completions",`Int 0;"later_work_admitted",`Bool true]))

let test () =
  let prompt_root=Masc_test_deps.source_path "config/prompts" |> Unix.realpath in
  let base=Filename.temp_dir "keeper-information-checkpoint-" "" |> Unix.realpath in
  Unix.rmdir base;
  let cwd=Sys.getcwd () in
  let executable=Unix.realpath Sys.executable_name in
  Fun.protect ~finally:(fun()->Sys.chdir cwd;Config_dir_resolver.reset ();
    Masc_test_deps.cleanup_test_workspace base) (fun()->
    Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some base) @@ fun()->
    Masc_test_deps.with_process_env "MASC_CONFIG_DIR"
      (Some(Filename.concat(Filename.concat base Common.masc_dirname)"config")) @@ fun()->
    Masc_test_deps.with_process_env "XDG_CONFIG_HOME" (Some(Filename.concat base "xdg-config")) @@ fun()->
    run base prompt_root;
    let pid=Unix.create_process executable [|executable;"--reopen";base|]
      Unix.stdin Unix.stdout Unix.stderr in
    require (pid<>Unix.getpid ()) "reader did not cross process boundary";
    match snd(Unix.waitpid [] pid) with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->failwith "fresh reader failed")

let () = match Array.to_list Sys.argv with
  | [_;"--reopen";base] -> reopen base
  | _ -> Alcotest.run "informational_checkpoint_ack"
      ["production cycle",[Alcotest.test_case "completion input checkpoints, ACKs, and stays delivered after restart" `Quick test]]
