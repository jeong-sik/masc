(** Actual completed-history Execution/production queue -> configured Runtime -> Python worker ->
    common host Exact HTTP -> original domain/gate/Memory receipt/queue ACK.
    Only container launch/cleanup is substituted. These tests do not claim
    Docker, real paid providers, installed native binaries or visible UI. *)
open Alcotest
open Masc
module Execution = Keeper_librarian_durable_execution
module Consumer = Keeper_librarian_durable_consumer
module Refresh = Keeper_librarian_queue_refresh
module Source = Keeper_librarian_durable_capture
module Durable_owner = Keeper_librarian_durable_owner
module Boundary = Keeper_turn_boundaries
module Position = Keeper_librarian_progress
module Checkpoint = Keeper_checkpoint_store
module Memory_lane = Keeper_memory_lane
module Current = Keeper_memory_os_current
module Types = Keeper_memory_os_types
module Capture = Keeper_librarian_durable_request
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Store = Lane_addon_store
module Runtime = Lane_addon_runtime
module Protocol = Lane_addon_worker_protocol
module F = Exact_output_fixture
let get = function Ok value -> value | Error detail -> fail detail
let owned result=get (Result.map_error Owner.error_to_string result)
let member=Yojson.Safe.Util.member
let json=testable Yojson.Safe.pp Yojson.Safe.equal
let io f=Eio_unix.run_in_systhread f
let keeper_name="librarian-owner-fixture"
let ()=Mirage_crypto_rng_unix.use_default ()
let write path bytes=Fs_compat.mkdir_p (Filename.dirname path);Out_channel.with_open_bin path (fun c -> output_string c bytes)
let install_keeper ~config ~name ~trace_id =
  let instructions=name ^ " fixture instructions" in
  io (fun () ->
    Masc_test_deps.declare_fixture_keeper ~sandbox_image:"base"
      ~base_path:config.Workspace.base_path ~sandbox_profile:(Some Keeper_types_profile.Docker) name;
    Keeper_types_profile.invalidate_keeper_profile_snapshots ());
  let meta=Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String name;
    "instructions",`String instructions;"trace_id",`String trace_id]) |> get in
  Keeper_meta_store.replace_snapshot config meta |> get
let protocol_error = function
  | Protocol.Invalid_contract s | Protocol.Protocol_failed s | Protocol.Invalid_observation s -> s
  | Host_refusal (Lane_addon_call_context.Rejected s | Unavailable s | Activity_disabled s | Activity_unobserved s) -> s
  | Stopped -> "worker protocol stopped"
let invocation_error = function
  | Protocol.Host_refusal refusal -> Lane_addon_call_context.Host_refusal refusal
  | (Protocol.Invalid_contract _ | Protocol_failed _ | Invalid_observation _ | Stopped) as e ->
    Lane_addon_call_context.Transport_error (protocol_error e)
let current keepers_dir=Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get
let claims keepers_dir=match current keepers_dir with None -> [] | Some snapshot ->
  List.map (fun (f:Types.fact) -> f.claim) snapshot.facts |> List.sort String.compare
let originals_for ~keeper_name base_path keepers_dir store =
  Durable_owner.discover ~store ~base_path ~keepers_dir ~keeper_id:keeper_name
  |> Result.map_error Durable_owner.error_to_string |> get
let originals=originals_for ~keeper_name
let new_claim claim=`Assoc ["claim",`String claim;"category",`String "fact";
  "board_post_id",`Null;"board_comment_id",`Null;"supersedes",`Null;"absorbs",`List []]
let answer _capture = `Assoc ["new_claims",`List [new_claim "Knowledge from original completed history"];
  "dropped",`List [];"working_state",`Null;"working_contexts",`List []]
let publish_routes base_path urls =
  let slots=List.mapi (fun i url -> {F.id="librarian-candidate-" ^ string_of_int i;base_url=url}) urls in
  ignore (F.publish_registry ~lane_id:"librarian/durable" ~slot_ids:(List.map (fun (s:F.target_fixture) -> s.id) slots)
    (F.resolver_snapshot ~source:base_path slots) : Runtime_exact_output_registry.t)

let backend env base_path delivery delivery_observed : Runtime.For_testing.backend = {
  start=(fun ~sw ~state_owner ~instance_id ~installation_id:_ ~package ~binding:_ ~on_authority ~is_live_instance:_ ~on_created ->
    let state_owner=match state_owner with Some owner -> owner | None -> fail "persistent worker has no state owner" in
    let state=Filename.concat base_path ("worker-state-" ^ Store.digest (Lane_addon_worker_state.identity state_owner)) in
    Fs_compat.mkdir_p state;
    let contract=Protocol.contract_of_package package |> Result.map_error protocol_error |> get in
    let protocol=Protocol.create ~instance_id ~contract () in
    get (on_authority (Lane_addon_lifecycle.Container_authority
      {runtime=Lane_addon_types.Docker;engine=Lane_addon_lifecycle.Docker_engine "fixture-resource-launch"}));
    let client=Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env) ~command:"python3"
      ~args:[Filename.concat package.directory "server.py";"--state";state]
      ~max_response_bytes:contract.max_reply_bytes () |> Result.map_error Agent_core.Error.to_string |> get in
    Protocol.initialize protocol client |> Result.map_error protocol_error |> get;
    let connection : Runtime.For_testing.connection = {
      browser=None;resource=Lane_addon_lifecycle.Container_resource instance_id;
      await_exit=(fun () -> Format.asprintf "%a" Eio.Process.pp_status (Agent_core.Mcp.await_exit client));
      resolved_image=Some (Lane_addon_engine.image_of_inspect Lane_addon_types.Docker ("sha256:" ^ String.make 64 'a') |> get);
      observe=(fun ~binding ~sources -> Protocol.observe protocol ~binding ~sources |> Result.map_error protocol_error);
      exported_tools=(fun () -> Protocol.exported_tools protocol);
      call_exported_tool=(fun ~on_result ~authorize ~principal ~name ~arguments ->
        Protocol.call_exported_tool ~on_result ?authorize ~principal protocol ~name ~arguments
          |> Result.map_error invocation_error);
      action_schema=(fun () -> Protocol.action_schema protocol);
      act=(fun ~arguments -> Protocol.act protocol ~arguments |> Result.map_error protocol_error);
      stop=(fun () -> Protocol.close protocol;Ok (Lane_addon_lifecycle.Released
        {engine=Lane_addon_lifecycle.Docker_engine "fixture-resource-launch";container_id=Some instance_id}));
      host=Some {await_change=None;
        list_requests=(fun () ->
          Protocol.host_requests protocol |> Result.map_error protocol_error);
        deliver=(fun ~arguments ->
          let result=if !delivery then Error "controlled reply loss before worker delivery"
            else Protocol.host_result protocol ~arguments |> Result.map_error protocol_error in
          delivery_observed ();result)}} in
    on_created connection;Ok connection);
  package_ready=(fun ~package:_ -> Ok ());
  acquire=(fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_ ~read_browser_document:_ ~binding:_ -> Ok (`List []));
  recover_stop=(fun ~state_owner:_ ~instance_id:_ ~authority ~resource -> match authority,resource with
    | Lane_addon_lifecycle.Container_authority {engine;_},Some (Lane_addon_lifecycle.Container_resource id) ->
      Ok (Lane_addon_lifecycle.Released {engine;container_id=Some id})
    | Lane_addon_lifecycle.Container_authority {engine;_},None ->
      Ok (Lane_addon_lifecycle.Released {engine;container_id=None})
    | Lane_addon_lifecycle.Container_authority _,Some (Lane_addon_lifecycle.Native_resource _)
    | Lane_addon_lifecycle.Native_admission _,(None|Some _) ->
      Error (Lane_addon_lifecycle.Cleanup_unconfirmed "fixture owns container lifecycle only"));
  condition_met=(fun ~runtime:_ _ -> true);sweep=(fun ~runtime:_ ~is_live_instance:_ -> Ok []) }

type fixture = {
  base_path:string; config:Workspace.config; keepers_dir:string; store:Store.t;
  source:string; declaration:bool -> string; server:F.test_server;
  set_response:(Capture.t -> Cohttp.Code.status_code * string) -> unit;
  delivery_loss:bool ref; deliveries:int ref; delivery_changed:Eio.Condition.t;
  clock:float Eio.Time.clock_ty Eio.Resource.t;
}
let observed_originals fixture=originals fixture.base_path fixture.keepers_dir fixture.store
let start_memory_action ?(keeper_name=keeper_name) fixture action =
  let completed,resolve=Eio.Promise.create () in
  let outcome=Memory_lane.submit ~base_path:fixture.base_path ~keeper_name (fun () ->
    match action () with
    | outcome -> Eio.Promise.resolve resolve (Ok outcome)
    | exception exn ->
      let backtrace=Printexc.get_raw_backtrace () in
      ignore (Eio.Promise.try_resolve resolve (Error exn));
      Printexc.raise_with_backtrace exn backtrace) in
  (match outcome with Memory_lane.Submitted -> ()
   | Coalesced | Ran_inline | Dropped -> fail "actual serialized Memory lane did not own this fixture unit");
  completed
let memory_action fixture action=
  let result=Eio.Promise.await_exn (start_memory_action fixture action) in
  Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;result
let run_worker fixture=Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds
  (fun () -> memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name ~wake:(fun () -> ())))
let await_delivery fixture ~after=Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
  Eio.Condition.loop_no_mutex fixture.delivery_changed (fun () ->
    if !(fixture.deliveries)>after then Some () else None))
let advanced = function
  | Ok (Consumer.Progress_advanced _ | Official_advanced _) -> true
  | Ok (Nothing_to_read | Baseline_advanced _ | Memory_not_committed _ | Pending) -> false
  | Error error -> fail (Consumer.error_to_string error)
let drive_advanced fixture =
  let before= !(fixture.deliveries) in
  match run_worker fixture with
  | Ok (Consumer.Progress_advanced _ | Official_advanced _) -> ()
  | Ok Consumer.Pending ->
    await_delivery fixture ~after:before;
    check bool "original delivered answer completes local publication" true (advanced (run_worker fixture))
  | Ok (Nothing_to_read | Baseline_advanced _ | Memory_not_committed _) ->
    fail "actual completed-history source was not submitted"
  | Error error -> fail (Consumer.error_to_string error)
let reconcile fixture=Runtime.reconcile_configuration ~config:fixture.config
  ~directory:(Runtime.configuration_directory fixture.config) |> get |> ignore
let set_enabled fixture enabled=io (fun () -> write fixture.source (fixture.declaration enabled));reconcile fixture
let message text = Agent_core.Types.make_message ~role:Agent_core.Types.User [Agent_core.Types.Text text]
let checkpoint ~trace_id messages turn_count : Agent_core.Checkpoint.t =
  { version = Agent_core.Checkpoint.checkpoint_version
  ; session_id = trace_id
  ; agent_name = keeper_name
  ; model = "fixture-model"
  ; system_prompt = None
  ; messages
  ; usage = Agent_core.Types.empty_usage
  ; turn_count
  ; created_at = Float.of_int turn_count
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; reasoning_effort = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Agent_core.Types.Off
  ; cache_system_prompt = false
  ; context = Agent_core.Context.create_sync ()
  ; pending_input = None; mcp_sessions = []
  ; working_context = None
  }
;;

let save_checkpoint config ~trace_id messages turn_count =
  (* Directory preparation owns an Eio mutex; only the checkpoint store's
     blocking transaction runs on the systhread. *)
  let session_dir = Keeper_fs.keeper_session_dir config trace_id in
  let saved = checkpoint ~trace_id messages turn_count in
  match
    io (fun () -> Checkpoint.save_agent_core_classified
      ~session_dir
      ~history_retained:0
      saved)
  with
  | Ok (Checkpoint.Saved _) -> ()
  | Ok (Checkpoint.Stale_noop _) -> fail "fixture checkpoint was stale"
  | Error detail -> failf "save checkpoint: %s" detail
;;

let trace_id="completed-history-original"
let append_boundary config ~turn ~time ~history_at_start messages =
  Boundary.append ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
    {Boundary.recorded_at=time;event=Boundary.Turn_ended {
      turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:turn;
      task_context=Keeper_turn_task_context.No_task;history_at_start;
      position=Boundary.position_of_messages messages |> get}}
  |> Result.map_error Boundary.append_error_to_string |> get
let first_messages=[message "The already-read first turn"]
let selected_messages=first_messages @ [message "Original question to retain";
  Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text "Original completed answer"]]
type history_kind = Atoms | Official | Mixed
let official_turn config ~turn ~time =
  let turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:turn in
  let session=Keeper_context_core.create_session ~session_id:trace_id ~base_dir:(Keeper_fs.session_store_path config) in
  Keeper_context_core_history.persist_message ~keeper_name ~turn_ref ~source:"direct_user" session
    (message "Original official-client question");
  Keeper_context_core_history.persist_message ~keeper_name ~turn_ref ~source:"internal_assistant" session
    (Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text "Original official-client answer"]);
  Keeper_context_core_history.persist_tool_observation ~keeper_name ~turn_ref session ~tool_name:"read_file" ~outcome:Tool_result.Ok;
  Boundary.append ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
    {Boundary.recorded_at=time;event=Boundary.Turn_ended {turn_ref;task_context=Keeper_turn_task_context.No_task;
      history_at_start=Boundary.Continued_history;position=Boundary.No_atom_history}}
  |> Result.map_error Boundary.append_error_to_string |> get
let prepare_history config kind =
  let now=Time_compat.now () in
  (match kind with
   | Official -> ()
   | Atoms | Mixed ->
     save_checkpoint config ~trace_id first_messages 1;
     io (fun () -> append_boundary config ~turn:1 ~time:(now-.10.)
       ~history_at_start:(Boundary.history_at_start_of_messages first_messages) first_messages);
     (match Consumer.consume_one ~config ~keeper_name ~commit:(fun _ -> fail "baseline unexpectedly proposed Memory") with
      | Ok (Consumer.Baseline_advanced _) -> ()
      | Ok (Consumer.Nothing_to_read | Progress_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending) ->
        fail "actual baseline was not established"
      | Error error -> fail (Consumer.error_to_string error)));
  (match kind with
   | Atoms -> ()
   | Official -> io (fun () -> official_turn config ~turn:1 ~time:(now-.2.))
   | Mixed -> io (fun () -> official_turn config ~turn:2 ~time:(now-.2.)));
  (match kind with
   | Official -> ()
   | Atoms | Mixed ->
     let turn=match kind with Atoms -> 2 | Mixed -> 3 | Official -> fail "official has no checkpoint turn" in
     save_checkpoint config ~trace_id selected_messages turn;
     io (fun () -> append_boundary config ~turn ~time:(now-.1.)
         ~history_at_start:(Boundary.history_at_start_of_messages first_messages) selected_messages));
  let item : Keeper_external_attention.item = {
    event_id=Keeper_external_attention.event_id_of_dedupe_key "original-history-external";
    dedupe_key="original-history-external";keeper_name;
    conversation={conversation_id="agent:original-history";surface=Keeper_external_attention.Agent};
    external_message=None;source_label="agent";
    actor={actor_id=Some "original-agent";display_name=Some "Original agent";authority=Keeper_chat_store.External};
    urgency=Keeper_external_attention.Ambient;content_preview="Original admitted external evidence";
    content_ref=None;received_at=now -. 5.;metadata=[]} in
  (* Admission prepares its directory through Keeper_fs's Eio mutex. Keep
     the actual admission API on the fiber, like the source-capture fixture. *)
  match Keeper_external_attention.For_testing.record_with_clock
    ~now:(fun () -> now -. 5.) ~base_path:config.Workspace.base_path item with
  | `Recorded -> () | `Duplicate _ -> fail "duplicate original external fixture"
  | `Error detail -> fail detail
let progress fixture = io (fun () -> Position.read ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config)
  ~keeper_id:keeper_name |> Result.map_error Position.read_error_to_string |> get)
let with_fixture ?(history_kind=Atoms) f =
  let base_path=Filename.temp_dir "librarian-addon-owner-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path ".masc/config")) (fun () ->
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.librarian_env_key (Some "true") (fun () ->
  F.with_official_client_runtimes (fun () -> Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Eio_guard.enable ();Eio.Switch.on_release sw Eio_guard.disable;
    Fs_compat.set_fs (Eio.Stdenv.fs env);Masc_test_deps.init_eio_clock env;
    Process_eio.init ~cwd_default:(Eio.Stdenv.cwd env) ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
    Fun.protect ~finally:(fun () -> Process_eio.reset_for_testing ();Fs_compat.clear_fs ();Config_dir_resolver.reset ()) (fun () ->
    Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
      Config_dir_resolver.reset ();Runtime.For_testing.reset ();Memory_lane.For_testing.reset ();Memory_lane.init ~sw;
      Prompt_registry.set_markdown_dir "../config/prompts";Prompt_defaults.init ();
      Prompt_registry.clear_prompt_override Prompt_names.librarian;
      Prompt_registry.clear_prompt_override Prompt_names.librarian_working_contexts_rule;
      let original_policy=Runtime_typesafeai_policy.current () in
      Runtime_typesafeai_policy.publish {original_policy with absorb_gate=false};
      Fun.protect ~finally:(fun () -> Runtime_typesafeai_policy.publish original_policy) (fun () ->
      let config=Workspace.default_config base_path in
      let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
      let store=Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
      (* Metadata publication owns an Eio-aware directory lock. Keep it on
         this fiber; only the blocking declaration write goes to [io]. *)
      install_keeper ~config ~name:keeper_name ~trace_id;
      prepare_history config history_kind;
      let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
        |> Result.map_error Lane_addon_manifest.error_to_string |> get in
      let source=Filename.concat (Runtime.configuration_directory config) "librarian.toml" in
      let declaration enabled=Printf.sprintf "id=\"librarian\"\nenabled=%b\nrun_id=\"librarian-original-owner\"\nmanifest_path=%s\n[binding]\nsources=[]\n"
        enabled (Yojson.Safe.to_string (`String (Filename.concat package.directory "lane.toml"))) in
      io (fun () -> write source (declaration true));
      let response=ref (fun capture -> `OK,F.openai_response (answer capture)) in
      let original_for body=
        let body=Yojson.Safe.from_string body in
        let messages=member "messages" body in
        let response_format=match Llm_provider.Backend_openai_request.response_format_to_openai_json
          Agent_core.Types.JsonMode with
          | Some value -> value | None -> fail "JSON mode has no OpenAI wire projection" in
        check json "the actual declared fixture target requests JSON mode" response_format
          (member "response_format" body);
        (* The actual ordinary owner returns Pending independently of this
           HTTP answer. Join it before strict directory inventory so its last
           Dispatch_pending publication cannot race source discovery. *)
        Memory_lane.For_testing.await_idle ~base_path ~keeper_name;
        let captures=originals base_path keepers_dir store in
        let matches=List.filter (fun ((record:Owner.retained),capture) ->
          let original=Capture.request capture |> get in
          let schema=match original.Lane_addon_exact.schema with
            | Some schema -> schema | None -> fail "the captured admission schema is absent" in
          let requirement=Agent_core.Exact_output.make_output_requirement ~schema
            ~minimum_guarantee:Agent_core.Exact_output.Json_syntax in
          let message role text=`Assoc ["role",`String role;"content",`String text] in
          let sent=Option.to_list (Option.map (message "system") original.system)
            @ List.map (fun (item:Lane_addon_exact.message) ->
                let role=match item.role with User -> "user" | Assistant -> "assistant" in
                message role item.text) original.messages
            @ [message "user" (Agent_core.Exact_output.schema_instruction_text requirement)] in
          (* A new original may retry identical unread bytes after a terminal
             refusal; the provider is serving the live original, not that old ID. *)
          (match Progress.phase record.progress with Rejected _ -> false
           | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
           | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> true)
          && Yojson.Safe.equal (`List sent) messages) captures in
        match matches with [_,capture] -> capture
        | [] | _::_::_ -> fail "actual provider request has no unique fully restored original capture" in
      let start_server respond=F.start_server ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
        (F.Reply_with (fun _ body -> respond (original_for body))) in
      let server=start_server (fun capture -> !response capture) in
      publish_routes base_path [server.base_url];
      Runtime.register_exact_runner ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path)
        (Server_lane_addon_exact.runner ~base_path);
      let deliveries=ref 0 and delivery_changed=Eio.Condition.create () and delivery_loss=ref false in
      let delivery_observed ()=incr deliveries;Eio.Condition.broadcast delivery_changed in
      let fixture={base_path;config;keepers_dir;store;source;declaration;server;
        set_response=(fun callback -> response:=callback);delivery_loss;deliveries;delivery_changed;
        clock=Eio.Stdenv.clock env} in
      Runtime.For_testing.with_backend
        (backend env base_path delivery_loss delivery_observed) (fun () ->
        let exported,ready=Eio.Promise.create () in
        let stop=Runtime.subscribe_owner_events ~config ~package_id:Capture.package_id (function
          | Runtime.Export_inventory_changed -> ignore (Eio.Promise.try_resolve ready ())
          | Configuration_observed | Exact_result_delivered _ -> ()) in
        Fun.protect ~finally:stop (fun () ->
          reconcile fixture;
          Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await exported));
        (* The export event precedes publication of the stable Runtime metadata.
           Reconcile once after that actual event before dispatching original work. *)
        reconcile fixture;
        (match Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> f ~sw fixture) with
         | () -> ()
         | exception Eio.Time.Timeout ->
           let backtrace=Printexc.get_raw_backtrace () in
           Printexc.raise_with_backtrace Eio.Time.Timeout backtrace);
        Keeper_librarian_queue_signal.install (fun ~base_path:_ ~keeper_name:_ -> ());
        Memory_lane.For_testing.await_idle ~base_path ~keeper_name;
        set_enabled fixture false;
        Memory_lane.For_testing.reset ())))))))))))

let assert_pending = function
  | Ok Consumer.Pending -> ()
  | Ok (Consumer.Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _) ->
    fail "actual original request must remain Pending"
  | Error error -> fail (Consumer.error_to_string error)
let only_original fixture = match observed_originals fixture with
  | [record,capture] -> record,capture
  | [] | _::_::_ -> fail "expected one strictly restored original history request"
let latest fixture capture = io (fun () ->
  let exact=Capture.request capture |> get in
  let schema=match exact.Lane_addon_exact.schema with Some schema -> schema | None -> fail "missing schema" in
  Lane_addon_exact.read_latest_original_execution ~store:fixture.store ~declaration_id:"librarian" ~schema exact |> get)
let no_memory fixture = check (list string) "uncommitted original has no Memory facts" []
  (io (fun () -> claims fixture.keepers_dir))
let assert_unattached = function
  | Error error ->
    check bool "attachment is a blocked original publication" true (Consumer.publication_unfinished error);
    check bool "attachment refusal has an actual diagnostic" true (String.length (Consumer.error_to_string error)>0)
  | Ok _ -> fail "missing Addon must not silently return Pending or an empty report"
let test_unattached_reports_without_consuming () = with_fixture (fun ~sw:_ fixture ->
  let before=progress fixture in
  set_enabled fixture false;
  assert_unattached (run_worker fixture);
  check int "unattached source creates no original" 0 (List.length (observed_originals fixture));
  check int "unattached source calls no provider" 0 (F.post_count fixture.server);
  check bool "unattached source remains unread" true (progress fixture=before);
  no_memory fixture;
  check bool "production queue starts without a measurement" true
    (Option.is_none (Refresh.last_measurement ~config:fixture.config ~keeper_name));
  Refresh.submit_durable ~base_path:fixture.base_path ~keeper_name;
  Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
  (match Refresh.last_measurement ~config:fixture.config ~keeper_name with
   | Some {last_pass=Refresh.Stopped error;_} ->
     check bool "production queue retains blocked publication" true
       (Consumer.publication_unfinished error)
   | Some {last_pass=(Off | Lane_unconfigured | Drained | Yielded_to_waiting_unit
                    | Not_committed | Pending | Raised _);_}
   | None -> fail "production queue must retain the attachment failure");
  check int "unattached production queue creates no original" 0 (List.length (observed_originals fixture));
  check int "unattached production queue calls no provider" 0 (F.post_count fixture.server);
  check bool "unattached production queue preserves source progress" true (progress fixture=before);
  no_memory fixture;
  check bool "blocked publication skips continuity" false
    (io (fun () -> Sys.file_exists (Keeper_librarian_continuity.path ~config:fixture.config ~keeper_name))))
let test_terminal_refusal_allows_fresh_original () = with_fixture (fun ~sw:_ fixture ->
  let before=progress fixture in
  fixture.set_response (fun _ -> `Bad_request,
    {|{"error":{"message":"fixture refusal","type":"invalid_request_error"}}|});
  let deliveries= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  await_delivery fixture ~after:deliveries;
  (match run_worker fixture with
   | Ok (Consumer.Memory_not_committed [report]) ->
     let final=Lane_addon_exact.Call_final (Input_refused Invalid_request) in
     check string "retain the actual typed host refusal"
       ("Original history request refused: " ^ Yojson.Safe.to_string (Lane_addon_exact.final_to_json final)) report.detail;
     check bool "refusal grants no descent or skip" false
       (Keeper_librarian_runtime.may_descend_messages [report]);
     check bool "refusal invents no capacity evidence" true
       (report.input_capacity_evidence=No_input_capacity_refusal && report.provider_input_refusals=[])
   | Error error -> fail (Consumer.error_to_string error)
   | Ok (Consumer.Memory_not_committed ([] | _::_::_) | Nothing_to_read | Pending
         | Baseline_advanced _ | Progress_advanced _ | Official_advanced _) ->
     fail "terminal refusal must retain a nonempty diagnostic report");
  let rejected,capture=only_original fixture in
  let request_before=Capture.to_json capture and progress_before=Progress.to_json rejected.progress in
  check bool "terminal refusal is retained as Rejected" true
    (match Progress.phase rejected.progress with Rejected _ -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> false);
  check bool "refusal does not acknowledge source" true (progress fixture=before);
  no_memory fixture;
  fixture.set_response (fun capture -> `OK,F.openai_response (answer capture));
  drive_advanced fixture;
  let captures=observed_originals fixture in
  check int "fresh selection retains a separate original ID" 2 (List.length captures);
  let retained,restored=List.find (fun (record,_) -> record.Owner.request_id=rejected.request_id) captures in
  check json "old refused request remains exact" request_before (Capture.to_json restored);
  check json "old refusal never redispatched or rewritten" progress_before (Progress.to_json retained.progress);
  check int "one refused and one successful provider call" 2 (F.post_count fixture.server);
  check (list string) "new original alone publishes Memory"
    ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir)))
let test_actual_completed_history_path () = with_fixture (fun ~sw:_ fixture ->
  check bool "actual runtime and Memory configuration roots stay distinct" true
    (Workspace.keepers_runtime_dir fixture.config<>fixture.keepers_dir);
  let before=progress fixture in
  drive_advanced fixture;
  check (list string) "actual original proposal reaches current Memory"
    ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir));
  check bool "actual source progress advances after publication" true (progress fixture<>before);
  let record,capture=only_original fixture in
  check bool "complete original host record is durably Finished" true
    (match Progress.phase record.Owner.progress with Finished _ -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
  let selected=(Source.input (Capture.source capture)).Keeper_librarian.messages in
  check bool "complete selected question and answer remain the original typed history" true
    (selected=List.drop (List.length first_messages) selected_messages);
  check int "real common Exact runner executed one original request" 1 (F.post_count fixture.server);
  (match latest fixture capture with
   | Lane_addon_exact.Completed_latest {execution={outcome=Call_ended (Answered _);_};_} -> ()
   | No_completed_latest
   | Completed_latest {execution={outcome=Call_ended (Invalid_output _ | Input_refused _ | Output_limit_reached _) | Call_refused _;_};_} ->
     fail "no actual original provider proof");
  let request_before=Capture.to_json capture in
  let posts=F.post_count fixture.server in
  ignore (run_worker fixture);
  let _,restored=only_original fixture in
  check json "completed original restores the full retained input/preparation" request_before (Capture.to_json restored);
  check int "already consumed source never creates another provider request" posts (F.post_count fixture.server))
let test_actual_official_or_mixed_path kind () = with_fixture ~history_kind:kind (fun ~sw:_ fixture ->
  let atom_before=progress fixture in
  let official ()=io (fun () -> Keeper_librarian_official_progress.read
    ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_id:keeper_name
    |> Result.map_error Keeper_librarian_official_progress.read_error_to_string |> get) in
  let official_before=official () in
  drive_advanced fixture;
  let record,capture=only_original fixture in
  let source=Capture.source capture in
  check bool "actual selector retained the requested complete source kind" true
    (match kind,Source.source source with
     | Official,Source.Official_only _ | Mixed,Source.Mixed _ -> true
     | Atoms,(Checkpoint_only _ | Official_only _ | Mixed _)
     | Official,(Checkpoint_only _ | Mixed _) | Mixed,(Checkpoint_only _ | Official_only _) -> false);
  (match Source.range_id source with
   | None -> check bool "official-only path advances no atom cursor" true (progress fixture=atom_before)
   | Some expected ->
     check bool "mixed path advances the original atom cursor" true (progress fixture<>atom_before);
     check bool "mixed path commits its exact atom coverage" true
       (io (fun () -> Current.committed_durable_coverage ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
         ~receipt_scope:expected.receipt_scope |> get)=Some expected));
  let expected=Source.official_range_id source |> Option.get in
  check bool "actual original official coverage receipt is present" true
    (io (fun () -> Current.committed_official_coverage ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
      ~receipt_scope:expected.receipt_scope |> get)=Some expected);
  check bool "official position advances after original publication" true (official ()<>official_before);
  let cursor=io (fun () -> Keeper_external_read_cursor.observe
    ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
  let through=Keeper_librarian_input_sources.external_through (Source.counterparts source) in
  check bool "actual original external frontier is settled" true
    (Keeper_external_read_cursor.observation_matches_preparation cursor ~after:through ~through ~atom:None ~official:None);
  check bool "both receipt and cursor settlements precede Finished" true
    (match Progress.phase record.Owner.progress with Finished _ -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _ | Conflicted _
     | Rejected _ | Subdividing _ | Subdivided _ -> false);
  check (list string) "actual official source judgment publishes Memory" ["Knowledge from original completed history"]
    (io (fun () -> claims fixture.keepers_dir));
  check int "official or mixed source uses one original host HTTP request" 1 (F.post_count fixture.server))
let test_production_queue_pending_retains_all_sources () = with_fixture (fun ~sw:_ fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
    `OK,F.openai_response (answer capture));
  let before=progress fixture in
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    Refresh.submit_durable ~base_path:fixture.base_path ~keeper_name;
    Eio.Promise.await arrived;
    Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
    (match Refresh.last_measurement ~config:fixture.config ~keeper_name with
     | Some measurement -> check bool "production queue observed actual durable Pending" true
         (measurement.Refresh.last_pass=Refresh.Pending)
     | None -> fail "actual production queue did not observe its durable Pending result");
    check bool "Pending preserves original source progress" true (progress fixture=before);
    no_memory fixture;
    check bool "Pending did not publish a continuity document" false
      (io (fun () -> Sys.file_exists (Keeper_librarian_continuity.path ~config:fixture.config ~keeper_name)));
    check int "only the original durable provider request is active" 1 (F.post_count fixture.server);
    let before_delivery= !(fixture.deliveries) in
    ignore (Eio.Promise.try_resolve unblock ());await_delivery fixture ~after:before_delivery;
    check bool "later local publication completes without another provider delivery" true (advanced (run_worker fixture));
    check (list string) "a later real wake publishes the original result"
      ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir))))
let test_actual_result_bridge_uses_production_queue () = with_fixture (fun ~sw:_ fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
    `OK,F.openai_response (answer capture));
  Fun.protect ~finally:(fun () ->
    Keeper_librarian_queue_signal.install (fun ~base_path:_ ~keeper_name:_ -> ());
    ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    assert_pending (run_worker fixture);Eio.Promise.await arrived;
    let before=progress fixture in
    let queued,scheduled=Eio.Promise.create () and selected=ref [] in
    (* The instrumentation observes scheduling only; the original bridge
       chooses the Keeper and the public production queue runs every effect. *)
    Keeper_librarian_queue_signal.install (fun ~base_path ~keeper_name ->
      selected:=(base_path,keeper_name):: !selected;
      Refresh.submit_durable ~base_path ~keeper_name;
      ignore (Eio.Promise.try_resolve scheduled ()));
    Eio.Switch.run (fun bridge_switch ->
      Server_librarian_addon_wake.install ~sw:bridge_switch ~config:fixture.config;
      ignore (Eio.Promise.try_resolve unblock ());
      Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await queued);
      Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name);
    check bool "actual result hint and production queue advance original source" true (progress fixture<>before);
    check bool "actual result bridge selects only its original physical Keeper" true
      (!selected<>[] && List.for_all (fun selected -> selected=(fixture.base_path,keeper_name)) !selected);
    check (list string) "production queue publishes actual original answer"
      ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir));
    check int "result wake publishes the same original provider judgment" 1 (F.post_count fixture.server)))
let test_host_answer_without_gate_waits_while_off () = with_fixture (fun ~sw:_ fixture ->
  fixture.delivery_loss:=true;
  let before= !(fixture.deliveries) in
  assert_pending (run_worker fixture);await_delivery fixture ~after:before;
  let _,capture=only_original fixture in
  (match latest fixture capture with
   | Lane_addon_exact.Completed_latest {execution={outcome=Call_ended (Answered _);_};_} -> ()
   | No_completed_latest
   | Completed_latest {execution={outcome=Call_ended (Invalid_output _ | Input_refused _ | Output_limit_reached _) | Call_refused _;_};_} ->
     fail "lost worker delivery has no original host proof");
  no_memory fixture;
  let posts=F.post_count fixture.server and source_before=Capture.to_json capture and before=progress fixture in
  set_enabled fixture false;
  assert_pending (run_worker fixture);
  let _,restored=only_original fixture in
  check json "Off waiting preserves the complete original" source_before (Capture.to_json restored);
  check bool "Off cannot settle source before preparing its original gate" true (progress fixture=before);
  check int "Off never starts a replacement provider" posts (F.post_count fixture.server);
  no_memory fixture)
let runtime_export fixture =
  let snapshot=Runtime.tool_export_snapshot ~config:fixture.config ~reserved:[]
    ~access:Lane_addon_sources.Operator_configuration in
  match List.find_opt (fun (export:Runtime.tool_export) -> export.tool.name=Capture.tool) snapshot.exports with
  | Some export -> export | None -> fail "fixture's actual configured durable tool is unavailable"
let resume_with_settlement_fault fixture before_settlement = memory_action fixture (fun () ->
  let original,request=only_original fixture in
  let destination=Capture.destination request in
  let fresh_authority () =
    io (fun () -> Capture.confirm_owner request) |> get;
    Runtime.with_tool_request_destination ~config:fixture.config ~reserved:[]
      ~access:Lane_addon_sources.Operator_configuration ~export:(runtime_export fixture)
      ~publish:(fun (actual:Runtime.tool_request_destination) ->
        if actual.installation_id=destination.installation_id && actual.package_id=destination.package_id
          && actual.tool=destination.tool && actual.configuration_revision=destination.configuration_revision
        then Ok () else Error (Runtime.Host_refusal (Lane_addon_call_context.Rejected "original fixture destination changed")))
    |> Result.map_error (fun _ -> "actual original configured destination unavailable") in
  let call ~(expected:Capture.destination) ~original ~arguments =
    Runtime.call_captured_tool_request ~config:fixture.config ~reserved:[] ~export:(runtime_export fixture)
      ~access:Lane_addon_sources.Operator_configuration
      ~installation_id:expected.installation_id ~package_id:expected.package_id ~tool:expected.tool
      ~configuration_revision:expected.configuration_revision ~original ~arguments
    |> Result.map_error Lane_addon_submit_once.call_error_of_runtime in
  Durable_owner.resume ~store:fixture.store ~config:fixture.config ~reserved:[] ~original ~request ~call
    ~wake:(fun () -> ()) ~publish:(fun ~original ~request ~proposal ->
      Keeper_librarian_durable_commit.For_testing.publish ~before_settlement ~store:fixture.store
        ~config:fixture.config ~original ~request ~proposal ~fresh_authority
      |> Result.map_error (fun detail -> Durable_owner.Rejected detail)))
let test_real_memory_receipt_then_failed_ack_recovers_while_off () = with_fixture (fun ~sw:_ fixture ->
  fixture.delivery_loss:=true;
  let before_delivery= !(fixture.deliveries) in
  assert_pending (run_worker fixture);await_delivery fixture ~after:before_delivery;
  let record,request=only_original fixture in
  let source=Capture.source request in
  let before=progress fixture and posts=F.post_count fixture.server in
  let cursor_path=Keeper_external_read_cursor.path_for_keepers_dir
    ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_id:keeper_name in
  let original_cursor=io (fun () -> Fs_compat.load_file_opt cursor_path) in
  let injected=ref false in
  let restore_cursor ()=io (fun () -> match original_cursor with
    | None -> if Sys.file_exists cursor_path then Unix.unlink cursor_path
    | Some bytes -> write cursor_path bytes) in
  Fun.protect ~finally:restore_cursor (fun () ->
    let result=resume_with_settlement_fault fixture (fun () ->
      injected:=true;write cursor_path "{invalid cursor after actual Memory receipt}\n") in
    (match result with
     | Ok (Durable_owner.Publication_waiting _) -> ()
     | Ok (Pending _ | Refused _ | Finished _ | Basis_superseded _) -> fail "actual post-Memory cursor failure was not retained Pending"
     | Error error -> fail (Durable_owner.error_to_string error));
    check int "the original has nonempty admitted external evidence to acknowledge" 1
      (Keeper_librarian_input_sources.external_through (Source.counterparts source));
    check bool "fault ran only after an actual original Memory range receipt" true !injected;
    check (list string) "Pending can retain an actual committed Memory effect"
      ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir));
    let expected=Option.get (Source.range_id source) in
    let actual=io (fun () -> Current.committed_durable_coverage ~keepers_dir:fixture.keepers_dir
      ~keeper_id:keeper_name ~receipt_scope:expected.Current.receipt_scope |> get) in
    check bool "actual current Memory proves the original durable range" true (actual=Some expected);
    check bool "failed external ACK cannot advance source progress" true (progress fixture=before);
    let unfinished,_=only_original fixture in
    check bool "actual Memory alone is not a Finished publication" true
      (match Progress.phase unfinished.Owner.progress with Committing _ | Commit_unknown _ -> true
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Finished _ | Conflicted _ | Rejected _
       | Subdividing _ | Subdivided _ -> false);
    restore_cursor ();
    let revision=io (fun () -> current fixture.keepers_dir |> Option.map (fun (value:Current.t) -> value.revision)) in
    set_enabled fixture false;
    check bool "receipt-backed original settles locally while Off" true (advanced (run_worker fixture));
    check bool "Off settlement advances only original source positions" true (progress fixture<>before);
    check bool "Off recovery repeats no Memory effect" true
      (revision=io (fun () -> current fixture.keepers_dir |> Option.map (fun (value:Current.t) -> value.revision)));
    let finished,restored=only_original fixture in
    check string "Off settlement keeps the original execution identity" record.request_id finished.Owner.request_id;
    check json "Off settlement preserves full immutable request" (Capture.to_json request) (Capture.to_json restored);
    let settled_cursor=io (fun () -> Keeper_external_read_cursor.observe
      ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
    check int "Off recovery actually acknowledges the original external admission" 1
      (Keeper_external_read_cursor.observation_offset settled_cursor);
    check int "ACK recovery never repeats inference" posts (F.post_count fixture.server)))
type source_change = Replaced_checkpoint | Restarted_history
let test_source_replacement_cannot_publish_retained_answer change () = with_fixture (fun ~sw:_ fixture ->
  fixture.delivery_loss:=true;
  let before= !(fixture.deliveries) in
  assert_pending (run_worker fixture);await_delivery fixture ~after:before;
  let record,capture=only_original fixture in
  let original=Capture.to_json capture and progress_before=progress fixture in
  let replacement=first_messages @ [message "Replacement source question";
    Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text "Replacement answer"]] in
  (match change with
   | Replaced_checkpoint -> save_checkpoint fixture.config ~trace_id replacement 3
   | Restarted_history ->
     io (fun () -> Boundary.append ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_id:keeper_name
       {Boundary.recorded_at=Time_compat.now ();event=Boundary.History_restarted {trace_id}}
       |> Result.map_error Boundary.append_error_to_string |> get));
  let posts=F.post_count fixture.server in
  assert_pending (run_worker fixture);
  no_memory fixture;
  check bool "changed source cannot advance original progress" true (progress fixture=progress_before);
  let restored_record,restored=only_original fixture in
  check bool "real gate and commit intent precede source-locked save refusal" true
    (match Progress.phase restored_record.Owner.progress with
     | Progress.Committing _ | Commit_unknown _ -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Finished _ | Conflicted _ | Rejected _
     | Subdividing _ | Subdivided _ -> false);
  check string "source failure retains the original request ID" record.request_id restored_record.Owner.request_id;
  check json "source failure retains full original evidence" original (Capture.to_json restored);
  check int "source replacement starts no substitute provider" posts (F.post_count fixture.server))
let restart_actual_worker fixture ~sw =
  let old=(runtime_export fixture).Runtime.instance_id in
  let changed=Eio.Condition.create () in
  let stop=Runtime.subscribe_owner_events ~config:fixture.config ~package_id:Capture.package_id
    (fun (Configuration_observed | Export_inventory_changed | Exact_result_delivered _) ->
      Eio.Condition.broadcast changed) in
  Fun.protect ~finally:stop (fun () ->
    (* The actual maintenance owner's cleanup nudge schedules a new attach
       after the retiring entry is removed. No guessed poll/yield loop. *)
    Runtime.start_configuration_service ~config:fixture.config ~sw ~clock:fixture.clock;
    set_enabled fixture false;set_enabled fixture true;
    let attached=Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
      Eio.Condition.loop_no_mutex changed (fun () ->
        let snapshot=Runtime.tool_export_snapshot ~config:fixture.config ~reserved:[]
          ~access:Lane_addon_sources.Operator_configuration in
        List.find_opt (fun (export:Runtime.tool_export) -> export.tool.name=Capture.tool && export.instance_id<>old)
          snapshot.exports)) in
    let instances=Runtime.dispatch ~access:Lane_addon_sources.Operator_configuration ~config:fixture.config
      ~operation:Runtime.Inspect (`Assoc []) |> Result.map_error Runtime.error_to_string |> get
      |> member "instances" |> Yojson.Safe.Util.to_list in
    check bool "old actual Runtime incarnation is completely absent from live inventory" false
      (List.exists (fun instance -> member "runtime_presence" instance=`String "live"
        && member "instance_id" instance=`String old) instances);
    check bool "actual replacement worker exports a different usable incarnation" true (attached.instance_id<>old))
let test_purge_joins_unknown_then_worker_restart_does_not_resubmit () = with_fixture (fun ~sw fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
    `OK,F.openai_response (answer capture));
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    assert_pending (run_worker fixture);Eio.Promise.await arrived;
    let record,capture=only_original fixture in
    let original=Capture.to_json capture and before=progress fixture in
    let posts=F.post_count fixture.server in
    check int "actual provider remains registered after ordinary unit returned" 1
      (Memory_lane.For_testing.external_active ~base_path:fixture.base_path ~keeper_name);
    (match Memory_lane.with_librarian_purge ~base_path:fixture.base_path ~keeper_name (fun () ->
      check int "purge callback follows actual provider cancellation and unwind" 0
        (Memory_lane.For_testing.external_active ~base_path:fixture.base_path ~keeper_name)) with
     | Ok () -> () | Error error -> fail (Memory_lane.purge_cancel_error_to_string error));
    ignore (Eio.Promise.try_resolve unblock ());
    no_memory fixture;
    check bool "purge cancellation preserves original source progress" true (progress fixture=before);
    restart_actual_worker fixture ~sw;
    (match run_worker fixture with
     | Ok (Consumer.Pending | Memory_not_committed _) -> ()
     | Error error -> fail (Consumer.error_to_string error)
     | Ok (Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _) ->
       fail "unknown original became consumed after worker restart");
    let reopened,restored=only_original fixture in
    check string "worker restart keeps the original unknown ID" record.request_id reopened.Owner.request_id;
    check json "worker restart keeps its complete original input/preparation" original (Capture.to_json restored);
    check int "unknown work is never submitted to another provider" posts (F.post_count fixture.server);
    no_memory fixture))
let test_epoch_reset_refuses_old_original () = with_fixture (fun ~sw:_ fixture ->
  fixture.delivery_loss:=true;
  let before= !(fixture.deliveries) in
  assert_pending (run_worker fixture);await_delivery fixture ~after:before;
  let _,capture=only_original fixture in
  let original=Capture.to_json capture and progress_before=progress fixture in
  let posts=F.post_count fixture.server in
  (match Memory_lane.with_librarian_purge ~base_path:fixture.base_path ~keeper_name (fun () ->
    io (fun () -> Current.with_program_reset ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
      (fun () -> Ok ())) |> get) with
   | Ok () -> () | Error error -> fail (Memory_lane.purge_cancel_error_to_string error));
  (match run_worker fixture with Error _ -> ()
   | Ok _ -> fail "old original survived destructive Memory epoch invalidation");
  no_memory fixture;
  check bool "epoch reset cannot ACK an old original range" true (progress fixture=progress_before);
  let scope=Capture.scope (Capture.physical_owner capture) in
  let retained=io (fun () -> Owner.load ~store:fixture.store ~scope ~request_id:(Capture.request_id capture) |> owned) in
  let retained=Option.get retained in
  check json "old epoch evidence remains observable without restoring authority" original retained.Owner.request;
  check int "epoch invalidation starts no replacement provider" posts (F.post_count fixture.server))
let test_changed_memory_rebases_original_source_without_unknown_retry ?(lose_child_after_dispatch=false) ?(recover_unacked_child=false) () = with_fixture (fun ~sw fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  let child_arrived,child_signal=Eio.Promise.create () and child_release,child_unblock=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    if Option.is_none (Capture.predecessor capture) then (
      ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release)
    else if lose_child_after_dispatch then (
      ignore (Eio.Promise.try_resolve child_signal ());Eio.Promise.await child_release);
    `OK,F.openai_response (answer capture));
  Fun.protect ~finally:(fun () ->
    ignore (Eio.Promise.try_resolve unblock ());
    ignore (Eio.Promise.try_resolve child_unblock ())) (fun () ->
    assert_pending (run_worker fixture);Eio.Promise.await arrived;
    let original_record,original=only_original fixture in
    let source=Capture.source original in
    let request_before=Capture.to_json original and positions_before=progress fixture in
    let independent=Types.observed ~claim:"Independent explicit write" ~category:Types.Fact
      ~now:(Time_compat.now ()) ~origin:{kind=Types.Authored;trace_id="concurrent-history-writer"} in
    let written=io (fun () -> Current.upsert_fact ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
      ~now:(Time_compat.now ()) ~source:{kind=Current.Explicit_write;trace_id="concurrent-history-writer"}
      independent |> Result.map_error Current.upsert_error_to_string |> get) in
    let before_delivery= !(fixture.deliveries) in
    ignore (Eio.Promise.try_resolve unblock ());await_delivery fixture ~after:before_delivery;
    assert_pending (run_worker fixture);
    let superseded_record,superseded=only_original fixture in
    check bool "a typed pre-publication basis refusal is terminal rather than unknown" true
      (match Progress.phase superseded_record.Owner.progress with Conflicted _ -> true
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
       | Finished _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
    check json "known supersession preserves the complete original source and request"
      request_before (Capture.to_json superseded);
    check bool "basis refusal has no additional Memory revision" true
      (io (fun () -> current fixture.keepers_dir |> Option.map (fun (snapshot:Current.t) -> snapshot.revision))
       =Some written.revision);
    check (list string) "only the independent writer changed Memory" [independent.claim]
      (io (fun () -> claims fixture.keepers_dir));
    check bool "superseding an uncommitted basis does not ACK original positions" true
      (positions_before=progress fixture);
    check int "no replacement is admitted before the known refusal is durable" 1 (F.post_count fixture.server);
    set_enabled fixture false;
    assert_unattached (run_worker fixture);
    let parked,_=only_original fixture in
    check json "Off wake neither retries stale commit nor grows its event history"
      (Progress.to_json superseded_record.progress) (Progress.to_json parked.progress);
    check int "Off cannot infer a new basis" 1 (F.post_count fixture.server);
    if recover_unacked_child then (
      let rebased=Source.with_current ~expected_revision:(Some written.revision)
        ~current:(Some {Keeper_librarian.facts=written.facts}) source
        |> Result.map_error Source.error_to_string |> get in
      let preparation=Keeper_librarian_runtime.prepare_durable ~now:(Time_compat.now ()) (Source.input rebased) |> get in
      let owner=Capture.physical_owner original in
      let request_id=Capture.fresh_request_id owner in
      let child=io (fun () -> Capture.create
        ~predecessor:{request_id=original_record.request_id;request_digest=original_record.request_digest}
        ~request_id ~owner ~destination:(Capture.destination original) ~source:rebased ~preparation ()) |> get in
      let intended:Progress.preparation_intent={request_id;request=Capture.to_json child} in
      let parent=io (fun () -> match Owner.advance ~store:fixture.store ~expected:parked
          ~event:(Progress.Replacement_intended intended) with
        | Ok (Owner.Stored record | Already_stored record) -> record
        | Ok (Unconfirmed detail) -> fail detail
        | Error error -> fail (Owner.update_error_to_string error)) in
      check bool "full parent intent exists before any child retention" true
        (Option.is_some (Progress.replacement parent.progress));
      let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
        |> Result.map_error Lane_addon_manifest.error_to_string |> get in
      let authorize child=Server_librarian_addon_validation.authorize ~base_path:fixture.base_path
        ~store:fixture.store ~declaration_id:"librarian" ~package (Capture.request child |> get) in
      let retained=Durable_owner.retain ~store:fixture.store child
        |> Result.map_error Durable_owner.error_to_string |> get in
      (match authorize child with Error _ -> ()
       | Ok _ -> fail "unacknowledged child reached actual host Exact authorization");
      check bool "child remains Captured before parent acknowledgement" true
        (Progress.phase retained.progress=Progress.Captured);
      assert_pending (run_worker fixture);
      let parent=io (fun () -> Owner.load ~store:fixture.store ~scope:parent.scope
        ~request_id:parent.request_id |> owned) |> Option.get in
      (match Progress.replacement parent.progress with
       | Some (Preparation_confirmed successor) -> check string "Off recovery acknowledges the same child" request_id successor.request_id
       | None | Some (Preparation_pending _) -> fail "Off did not recover the original child publication");
      (match authorize child with
       | Ok (Some authorization) -> check bool "Off still refuses actual dispatch after local ACK" true
           (Result.is_error (authorization.before_dispatch ()))
       | Error (Exact.Unowned {reason}) -> fail reason
       | Error (Exact.Undecided {detail}) -> fail detail
       | Ok None -> fail "history request lost its actual host namespace");
      check int "local Off publication recovery does not call provider" 1 (F.post_count fixture.server);
      check bool "local Off publication recovery does not ACK source positions" true (progress fixture=positions_before));
    let changed=Eio.Condition.create () in
    let stop=Runtime.subscribe_owner_events ~config:fixture.config ~package_id:Capture.package_id
      (fun (Configuration_observed | Export_inventory_changed | Exact_result_delivered _) ->
        Eio.Condition.broadcast changed) in
    Fun.protect ~finally:stop (fun () ->
      Runtime.start_configuration_service ~config:fixture.config ~sw ~clock:fixture.clock;
      set_enabled fixture true;
      Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
        Eio.Condition.loop_no_mutex changed (fun () ->
          let snapshot=Runtime.tool_export_snapshot ~config:fixture.config ~reserved:[]
            ~access:Lane_addon_sources.Operator_configuration in
          List.find_opt (fun (export:Runtime.tool_export) -> export.tool.name=Capture.tool) snapshot.exports))
      |> ignore);
    reconcile fixture;
    if lose_child_after_dispatch then (
      assert_pending (run_worker fixture);
      Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await child_arrived);
      let found=observed_originals fixture in
      let child_record,child=match List.filter (fun (_,request) -> Option.is_some (Capture.predecessor request)) found with
        | [child] -> child | [] | _::_::_ -> fail "expected one admitted successor before physical loss" in
      let parent,_=List.find (fun (record,_) -> record.Owner.request_id=original_record.request_id) found in
      (match Progress.replacement parent.progress with
       | Some (Preparation_confirmed successor) ->
         check string "parent confirmed the exact admitted child" child_record.request_id successor.request_id;
         check json "parent durably retains full child before its actual HTTP" (Lane_addon_action.canonical (Capture.to_json child) |> get) successor.request
       | None | Some (Preparation_pending _) -> fail "child provider ran without durable parent acknowledgement");
      let retained_parent=Progress.to_json parent.progress in
      let path=Filename.concat (Store.root fixture.store)
        (Filename.concat Store.tool_request_owners_directory
          (Filename.concat (Store.digest child_record.scope) (Store.digest child_record.request_id ^ ".json"))) in
      io (fun () -> Unix.unlink path);
      let refuse_missing ()=match run_worker fixture with
        | Error _ -> () | Ok _ -> fail "confirmed missing child was treated as new-work permission" in
      refuse_missing ();
      let delivered= !(fixture.deliveries) in
      ignore (Eio.Promise.try_resolve child_unblock ());await_delivery fixture ~after:delivered;
      refuse_missing ();
      set_enabled fixture false;
      refuse_missing ();
      let parent_after,_=only_original fixture in
      check json "child loss preserves the full immutable forward intent and ACK"
        retained_parent (Progress.to_json parent_after.progress);
      check int "unknown lost child never authorizes a third inference" 2 (F.post_count fixture.server);
      check (list string) "lost child cannot publish its actual late answer"
        [independent.claim] (io (fun () -> claims fixture.keepers_dir));
      check bool "lost child never advances original positions" true (progress fixture=positions_before)
    ) else (
    drive_advanced fixture;
    let found=observed_originals fixture in
    let child_record,child=match List.filter (fun (_,request) -> Option.is_some (Capture.predecessor request)) found with
      | [child] -> child | [] | _::_::_ -> fail "expected exactly one linked fresh-basis successor" in
    let predecessor=Capture.predecessor child |> Option.get in
    check string "successor keeps its exact original predecessor ID" original_record.request_id predecessor.request_id;
    check string "successor keeps its exact original predecessor digest" original_record.request_digest predecessor.request_digest;
    let rebased=Source.with_current ~expected_revision:(Some written.revision)
      ~current:(Some {Keeper_librarian.facts=written.facts}) source
      |> Result.map_error Source.error_to_string |> get in
    check json "successor changes only original Memory basis, never source or external frontier"
      (Source.to_json rebased) (Source.to_json (Capture.source child));
    check bool "fresh-basis successor durably finishes" true
      (match Progress.phase child_record.Owner.progress with Finished _ -> true
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
       | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
    check (list string) "fresh judgment preserves the explicit write and consumes original history once"
      [independent.claim;"Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir));
    check int "exactly the original and its known fresh-basis successor reached provider" 2 (F.post_count fixture.server);
    check bool "only successful successor advances original read positions" true (progress fixture<>positions_before);
    let parent_after,_=List.find (fun (record,_) -> record.Owner.request_id=original_record.request_id) found in
    let expected_parent=Progress.append superseded_record.progress
      (Progress.Replacement_intended {request_id=child_record.request_id;request=Capture.to_json child}) |> get in
    let expected_parent=Progress.append expected_parent (Progress.Replacement_observed child_record.request_id) |> get in
    check json "historical supersession changes only by its exact child intent and ACK"
      (Progress.to_json expected_parent) (Progress.to_json parent_after.progress);
    (match Progress.replacement parent_after.progress with
     | Some (Preparation_confirmed successor) ->
       check string "parent ACK names exact successful child" child_record.request_id successor.request_id;
       check json "parent keeps the complete successful child" (Lane_addon_action.canonical (Capture.to_json child) |> get) successor.request
     | None | Some (Preparation_pending _) -> fail "successful child has no confirmed parent link");
    ignore (run_worker fixture);
    check int "later wake validates both originals without a third inference" 2 (F.post_count fixture.server);
    check int "later wake retains one original and one successor only" 2 (List.length (observed_originals fixture)))))

let () = Alcotest.run "keeper_librarian_durable_execution" ["actual configured completed-history",[
  test_case "missing attachment is reported without consuming source" `Quick test_unattached_reports_without_consuming;
  test_case "terminal refusal preserves reason and allows a fresh original" `Quick test_terminal_refusal_allows_fresh_original;
  test_case "actual original reaches Memory and source ACK" `Quick test_actual_completed_history_path;
  test_case "actual official-only original reaches Memory and official ACK" `Quick (test_actual_official_or_mixed_path Official);
  test_case "actual mixed original reaches Memory and both receipt/position kinds" `Quick (test_actual_official_or_mixed_path Mixed);
  test_case "production durable queue stops following phases on actual Pending" `Quick test_production_queue_pending_retains_all_sources;
  test_case "actual host result bridge resumes production queue" `Quick test_actual_result_bridge_uses_production_queue;
  test_case "host answer without original gate waits while Off" `Quick test_host_answer_without_gate_waits_while_off;
  test_case "actual Memory receipt with failed ACK settles while Off" `Quick test_real_memory_receipt_then_failed_ack_recovers_while_off;
  test_case "changed checkpoint source cannot publish retained original answer" `Quick
    (test_source_replacement_cannot_publish_retained_answer Replaced_checkpoint);
  test_case "same-trace restart cannot publish old retained checkpoint answer" `Quick
    (test_source_replacement_cannot_publish_retained_answer Restarted_history);
  test_case "purge joins actual provider and worker restart never resubmits unknown" `Quick test_purge_joins_unknown_then_worker_restart_does_not_resubmit;
  test_case "destructive Memory epoch reset refuses retained old owner" `Quick test_epoch_reset_refuses_old_original;
  test_case "concurrent explicit Memory write closes known basis and resumes original source once" `Quick
    (test_changed_memory_rebases_original_source_without_unknown_retry ~lose_child_after_dispatch:false);
  test_case "confirmed successor loss refuses fresh inference and late answer" `Quick
    (test_changed_memory_rebases_original_source_without_unknown_retry ~lose_child_after_dispatch:true);
  test_case "unacknowledged replacement is denied by host and locally recovered while Off" `Quick
    (test_changed_memory_rebases_original_source_without_unknown_retry ~recover_unacked_child:true);
]]
