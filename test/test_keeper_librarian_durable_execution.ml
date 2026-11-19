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
module Commit = Keeper_librarian_durable_commit
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
module Resolution = Keeper_librarian_history_resolution
module Fence = Keeper_librarian_history_resolution_state
module Resolution_work = Keeper_librarian_history_resolution_work
module Resolution_intent = Keeper_librarian_history_resolution_intent
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
  |> List.map (fun listed -> Durable_owner.load ~store listed
    |> Result.map_error Durable_owner.error_to_string |> get)
let originals=originals_for ~keeper_name
let new_claim claim=`Assoc ["claim",`String claim;"category",`String "fact";
  "board_post_id",`Null;"board_comment_id",`Null;"supersedes",`Null;"absorbs",`List []; "evidence", `Assoc ["conversation",`List [];"tools",`List [];"counterpart",`Bool false;"task_contexts",`Bool false]]
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
      call_exported_tool=(fun ~on_result ~on_dispatch ~authorize ~principal ~name ~arguments ->
        Protocol.call_exported_tool ~on_result ~on_dispatch ?authorize ~principal protocol ~name ~arguments
          |> Result.map_error invocation_error);
      operator_schema=(fun () -> None);
      observation_effect=(fun _ -> Lane_addon_call_context.May_change);
      call_operator=(fun ~admit:_ ~arguments:_ -> Error Masc.Lane_addon_worker_protocol.Operator_unavailable);
      action_schema=(fun () -> Protocol.action_schema protocol);
      act=(fun ~arguments -> Protocol.act protocol ~arguments |> Result.map_error protocol_error);
      stop=(fun () -> Protocol.close protocol;Ok (Lane_addon_lifecycle.Released
        {engine=Lane_addon_lifecycle.Docker_engine "fixture-resource-launch";container_id=Some instance_id}));
      host=Some {list_requests=(fun ~after ->
          Protocol.host_requests protocol ~after |> Result.map_error protocol_error);
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
  set_step_response:(string -> Cohttp.Code.status_code * string) -> unit;
  delivery_loss:bool ref; deliveries:int ref; delivery_changed:Eio.Condition.t;
  clock:float Eio.Time.clock_ty Eio.Resource.t;
  io_pool:Domain_pool.t option;
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
let advance_original fixture original event=io (fun () ->
  match Owner.advance ~store:fixture.store ~expected:original ~event with
  | Ok (Owner.Stored original | Already_stored original) -> original
  | Ok (Unconfirmed detail) -> fail detail
  | Error error -> fail (Owner.update_error_to_string error))
let run_worker fixture=Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds
  (fun () -> memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name ~wake:(fun () -> ())))
let await_delivery fixture ~after=Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
  Eio.Condition.loop_no_mutex fixture.delivery_changed (fun () ->
    if !(fixture.deliveries)>after then Some () else None))
let advanced = function
  | Ok (Consumer.Progress_advanced _ | Official_advanced _) -> true
  | Ok (Nothing_to_read | Baseline_advanced _ | Memory_not_committed _ | Pending _) -> false
  | Error error -> fail (Consumer.error_to_string error)
let drive_advanced fixture =
  let before= !(fixture.deliveries) in
  match run_worker fixture with
  | Ok (Consumer.Progress_advanced _ | Official_advanced _) -> ()
  | Ok (Consumer.Pending _) ->
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
  { provider_binding = None; version = Agent_core.Checkpoint.checkpoint_version
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
  ; pending_input = None
  ; working_context = None
  }
;;

let save_checkpoint config ~trace_id messages turn_count =
  (* Directory preparation owns an Eio mutex; only the checkpoint store's
     blocking transaction runs on the systhread. *)
  let session_dir = Keeper_fs.keeper_session_dir config trace_id in
  let saved = checkpoint ~trace_id messages turn_count in
  match
    io (fun () -> Checkpoint.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes
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
let official_empty_turn ?(trace_id=trace_id) config ~turn ~time =
  let turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:turn in
  Boundary.append ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
    {Boundary.recorded_at=time;event=Boundary.Turn_ended {turn_ref;task_context=Keeper_turn_task_context.No_task;
      history_at_start=Boundary.Continued_history;position=Boundary.No_atom_history}}
  |> Result.map_error Boundary.append_error_to_string |> get
let official_turn ?(trace_id=trace_id) config ~turn ~time =
  let turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:turn in
  let session=Keeper_context_core.create_session ~session_id:trace_id ~base_dir:(Keeper_fs.session_store_path config) in
  Keeper_context_core_history.persist_message ~keeper_name ~turn_ref ~source:Masc.Keeper_types_support.Direct_user session
    (message "Original official-client question");
  Keeper_context_core_history.persist_message ~keeper_name ~turn_ref ~source:Masc.Keeper_types_support.Internal_assistant session
    (Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text "Original official-client answer"]);
  Keeper_context_core_history.persist_tool_observation ~keeper_name ~turn_ref session ~tool_name:"read_file" ~outcome:Tool_result.Ok;
  official_empty_turn ~trace_id config ~turn ~time
let prepare_history ?(with_external_attention=true) config kind =
  let now=Time_compat.now () in
  (match kind with
   | Official -> ()
   | Atoms | Mixed ->
     save_checkpoint config ~trace_id first_messages 1;
     io (fun () -> append_boundary config ~turn:1 ~time:(now-.10.)
       ~history_at_start:(Boundary.history_at_start_of_messages first_messages) first_messages);
     (match Consumer.consume_one ~config ~keeper_name ~commit:(fun _ -> fail "baseline unexpectedly proposed Memory") with
      | Ok (Consumer.Baseline_advanced _) -> ()
      | Ok (Consumer.Nothing_to_read | Progress_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending _) ->
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
  if with_external_attention then (
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
  | `Error detail -> fail detail)
let progress fixture = io (fun () -> Position.read ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config)
  ~keeper_id:keeper_name |> Result.map_error Position.read_error_to_string |> get)
let with_fixture ?(history_kind=Atoms) ?(with_io_pool=false) ?(with_external_attention=true) f =
  let base_path=Filename.temp_dir "librarian-addon-owner-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path ".masc/config")) (fun () ->
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.librarian_env_key (Some "true") (fun () ->
  F.with_official_client_runtimes (fun () -> Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Eio_guard.enable ();Eio.Switch.on_release sw Eio_guard.disable;
    let io_pool=if with_io_pool then
      Some (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env)) else None in
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
      prepare_history ~with_external_attention config history_kind;
      let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
        |> Result.map_error Lane_addon_manifest.error_to_string |> get in
      let source=Filename.concat (Runtime.configuration_directory config) "librarian.toml" in
      let declaration enabled=Printf.sprintf "id=\"librarian\"\nenabled=%b\nrun_id=\"librarian-original-owner\"\nmanifest_path=%s\n[binding]\nsources=[]\n"
        enabled (Yojson.Safe.to_string (`String (Filename.concat package.directory "lane.toml"))) in
      io (fun () -> write source (declaration true));
      let response=ref (fun capture -> `OK,F.openai_response (answer capture)) in
      (* A request that is no history original is a floor step. Tests that run
         steps say how the provider answers them; any other test fails on it. *)
      let step_response=ref (fun _ -> fail "actual provider request has no unique fully restored original capture") in
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
          let unfenced=io (fun () -> Fence.read ~store ~scope:record.scope ~request_id:record.request_id |> get)=None in
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
          unfenced && (match Progress.phase record.progress with Rejected _ -> false
           | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
           | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> true)
          && Yojson.Safe.equal (`List sent) messages) captures in
        match matches with [_,capture] -> Some capture
        | [] -> None
        | _::_::_ -> fail "actual provider request has no unique fully restored original capture" in
      let start_server respond=F.start_server ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
        (F.Reply_with (fun _ body -> match original_for body with
          | Some capture -> respond capture
          | None -> !step_response body)) in
      let server=start_server (fun capture -> !response capture) in
      publish_routes base_path [server.base_url];
      Runtime.register_exact_runner ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path)
        (Server_lane_addon_exact.runner ~base_path);
      let deliveries=ref 0 and delivery_changed=Eio.Condition.create () and delivery_loss=ref false in
      let delivery_observed ()=incr deliveries;Eio.Condition.broadcast delivery_changed in
      let fixture={base_path;config;keepers_dir;store;source;declaration;server;
        set_response=(fun callback -> response:=callback);
        set_step_response=(fun callback -> step_response:=callback);delivery_loss;deliveries;delivery_changed;
        clock=Eio.Stdenv.clock env;io_pool} in
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

(* A guard's own failed read, and a declaration that is off, say nothing
   about a replacement: the request waits. *)
let guard_waits before_dispatch = match before_dispatch () with
  | Error (Exact.Not_now _) -> true | Ok () | Error Exact.Declaration_replaced -> false
let assert_pending = function
  | Ok (Consumer.Pending _) -> ()
  | Ok (Consumer.Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _) ->
    fail "actual original request must remain Pending"
  | Error error -> fail (Consumer.error_to_string error)
let only_original fixture = match observed_originals fixture with
  | [record,capture] -> record,capture
  | found -> fail (Printf.sprintf "expected one strictly restored original history request, found %d: %s"
      (List.length found)
      (String.concat "; " (List.map (fun ((record:Owner.retained),_) ->
        Printf.sprintf "%s settled=%b" record.request_id (Option.is_some (Progress.settlement record.progress))) found)))
let latest fixture capture = io (fun () ->
  let exact=Capture.request capture |> get in
  let schema=match exact.Lane_addon_exact.schema with Some schema -> schema | None -> fail "missing schema" in
  Lane_addon_exact.read_latest_original_execution ~store:fixture.store ~declaration_id:"librarian" ~schema exact |> get)
let no_memory fixture = check (list string) "uncommitted original has no Memory facts" []
  (io (fun () -> claims fixture.keepers_dir))
module Gate = Keeper_librarian_durable_gate
let day_of request_id=Capture.minted_on request_id |> get
(* The same history request ID minted one UTC day earlier, for a chain whose
   root and successor fall on different days. *)
let day_ms=86_400_000L
let minted_a_day_before request_id =
  match Yojson.Safe.from_string request_id with
  | `List [kind;hash;`String nonce] ->
    let time=Printf.sprintf "%012Lx" (Int64.sub (Random_id.uuid_v7_time_ms nonce |> get) day_ms) in
    let nonce=String.sub time 0 8 ^ "-" ^ String.sub time 8 4 ^ String.sub nonce 13 (String.length nonce-13) in
    Yojson.Safe.to_string (`List [kind;hash;`String nonce])
  | _ -> fail "a history request ID lists its kind, owner hash and nonce"
(* Every gate record the owner's gate scope holds now. *)
let gate_records fixture capture =
  let inventory=io (fun () -> Gate.Inventory.read ~store:fixture.store ~owner:(Capture.physical_owner capture)) |> get in
  List.concat_map (fun execution_id -> Gate.Inventory.execution_records inventory ~execution_id)
    (Gate.Inventory.executions inventory)
let with_absorb_guidance_gap ~empty f =
  let original=Prompt_registry.get_markdown_dir () |> Option.get in
  let key=Prompt_names.librarian_absorb_forward in
  let override=(Prompt_registry.resolve_prompt key).override_value in
  let directory=io (fun () ->
    let directory=Filename.temp_dir "history-absorb-policy-gap-" "" in
    let text=Fs_compat.load_file (Filename.concat original "librarian.md") in
    let _,lines=List.fold_left (fun (skipping,lines) line ->
      if line="### absorb_forward" then true,(if empty then ""::line::lines else lines)
      else if skipping && not (String.starts_with ~prefix:"### " line) then true,lines
      else false,line::lines) (false,[]) (String.split_on_char '\n' text) in
    write (Filename.concat directory "librarian.md") (String.concat "\n" (List.rev lines));directory) in
  Fun.protect ~finally:(fun () ->
    Prompt_registry.set_markdown_dir original;
    (match override with None -> Prompt_registry.clear_prompt_override key
     | Some text -> Prompt_registry.set_override key text |> get);
    io (fun () -> Fs_compat.remove_tree directory)) (fun () ->
    Prompt_registry.clear_prompt_override key;
    Prompt_registry.set_markdown_dir directory;f ())
let with_enabled_absorb_gate (fixture:fixture) f =
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "unused-absorb-key") (fun () ->
    Masc_test_deps.with_typesafeai_policy
      {Runtime_schema.default_typesafeai with lane_enabled=true;absorb_gate=true;excluded_keepers=[];
       destinations=({Runtime_schema.endpoint=fixture.server.base_url;model="unused-absorb-model";
         api_key_env="TYPESAFEAI_API_KEY"},[])} f)
let add_absorption (proposal:Yojson.Safe.t) =
  let fields=Yojson.Safe.Util.to_assoc proposal in
  let claims=List.assoc "new_claims" fields |> Yojson.Safe.Util.to_list in
  let claims=match claims with
    | `Assoc first::rest -> `Assoc (("absorbs",`List [`String "m1"])::List.remove_assoc "absorbs" first)::rest
    | [] | _::_ -> fail "the absorbing fixture requires a new claim" in
  `Assoc (("new_claims",`List claims)::List.remove_assoc "new_claims" fields)
let seed_absorb_source (fixture:fixture) = memory_action fixture (fun () -> io (fun () ->
  Current.replace ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name ~expected_revision:None
    ~now:50. ~source:{Current.kind=Current.Librarian;trace_id="unused-absorb-policy"}
    ~facts:[Types.observed ~claim:"Earlier complete source memory." ~category:Types.Fact ~now:50.
      ~origin:{kind=Types.Authored;trace_id="unused-absorb-policy"}] () |> get |> ignore))
let answered_proposal (record:Owner.retained) (request:Exact.request) =
  let judgment=match Progress.phase record.progress with
    | Judged judgment -> judgment | _ -> fail "expected an answered original before gate preparation" in
  match Exact.final_of_json ~schema:(Option.get request.schema) judgment |> get with
  | Call_final (Answered {output;_}) -> Exact.checked_json output
  | _ -> fail "expected the original host-checked answer"
let test_history_guidance_is_required_only_for_actual_absorptions () =
  List.iter (fun (empty,absorbing) -> with_fixture (fun ~sw:_ fixture ->
    seed_absorb_source fixture;
    fixture.set_response (fun capture ->
      let proposal=answer capture in `OK,F.openai_response (if absorbing then add_absorption proposal else proposal));
    with_enabled_absorb_gate fixture (fun () -> with_absorb_guidance_gap ~empty (fun () ->
      let before= !(fixture.deliveries) in
      assert_pending (run_worker fixture);await_delivery fixture ~after:before;
      if absorbing then check bool "nonempty history cannot prepare without guidance" true (Result.is_error (run_worker fixture))
      else drive_advanced fixture;
      let parent,capture=only_original fixture in
      let owner=Capture.physical_owner capture in
      let authority=Keeper_librarian_absorb_gate.resolve ~keeper_id:keeper_name in
      let missing_policy=match Keeper_librarian_absorb_gate.guidance_of_authority authority with
        | Error detail -> detail | Ok _ -> fail "enabled guidance must remain explicitly unavailable" in
      if absorbing then (
        let proposal=answered_proposal parent (Capture.request capture |> get) in
        check bool "the host retained real nonempty absorption" true
          ((Capture.validate_proposal capture proposal |> get).absorption.absorbed<>[]);
        let request_id=Random_id.uuid_v7 () in
        check (result unit string) "nonempty history root requires guidance" (Error missing_policy)
          (io (fun () -> Gate.prepare_root ~store:fixture.store ~owner ~capture ~parent ~proposal ~request_id ~authority) |> Result.map (fun _ -> ()));
        check (result unit string) "nonempty history retention requires guidance" (Error missing_policy)
          (io (fun () -> Gate.retain ~store:fixture.store ~owner ~capture ~parent ~proposal ~request_id ~authority ~predecessor:None) |> Result.map (fun _ -> ()));
        check int "no invalid history gate was retained" 0 (List.length (gate_records fixture capture)))
      else (
        let gate=match gate_records fixture capture with [gate] -> gate | _ -> fail "one empty history gate expected" in
        check json "empty history captures explicit guidance absence" `Null (member "guidance" gate.request);
        let parent=memory_action fixture (fun () -> io (fun () -> Gate.recover_root ~store:fixture.store ~owner ~capture) |> get) in
        let gate=memory_action fixture (fun () -> io (fun () -> Gate.retain ~store:fixture.store ~owner ~capture ~parent
          ~proposal:(member "proposal" gate.request) ~request_id:gate.request_id ~authority ~predecessor:None) |> get) in
        let result=memory_action fixture (fun () -> Gate.resume ~store:fixture.store ~owner ~capture ~record:gate ~live_authority:None
          ~request_clock:(fun () -> fail "empty history acquired a gate clock")
          ~before_dispatch:(fun () -> fail "empty history dispatched a gate request") |> get) in
        let result=match result with Gate.Complete (result,_) -> result | Pending _ -> fail "empty history must complete locally" in
        check bool "empty history replays as No_absorptions" true
          (match result with Keeper_librarian_absorb_gate.Skipped {reason=No_absorptions;absorbed=[]} -> true | _ -> false);
        let replayed=io (fun () -> Gate.restore_latest_result ~store:fixture.store ~owner ~parent_execution:capture
          ~gate_request_id:gate.request_id) |> get in
        check json "empty history survives strict replay" (Keeper_librarian_absorb_gate.run_result_to_yojson result)
          (Keeper_librarian_absorb_gate.run_result_to_yojson replayed));
      check int "only the original history provider was called" 1 (F.post_count fixture.server)))))
    [false,false;true,false;false,true;true,true]
let settled_on fixture ~date (record:Owner.retained) =
  io (fun () -> Owner.settled ~store:fixture.store ~scope:record.scope ~date ~request_id:record.request_id) |> owned
let settle_only fixture ~date (record:Owner.retained) =
  io (fun () -> Owner.settle ~store:fixture.store ~date (Owner.listed record))
  |> Result.map_error Owner.settle_error_to_string |> get
(* A settled original as the archive holds it: its progress. The request body
   its record names is in neither its scope nor the settled day. *)
let archived fixture ~date (record:Owner.retained) =
  let root=Store.root fixture.store in
  let record_path=Filename.concat root
    (Store.tool_request_archive_record_path ~scope:record.scope ~date ~request_id:record.request_id) in
  let stored=io (fun () -> Yojson.Safe.from_file record_path) in
  let request_digest=Yojson.Safe.Util.to_string (member "request_digest" stored) in
  check bool "the settled body left its scope" false (io (fun () ->
    Sys.file_exists (Filename.concat root (Store.tool_request_body_path ~scope:record.scope ~request_digest))));
  check (list string) "the settled day keeps no body" ["records"] (io (fun () ->
    Sys.readdir (Filename.dirname (Filename.dirname record_path)) |> Array.to_list));
  Progress.of_json (member "progress" stored) |> get
let assert_unattached = function
  | Error error ->
    check bool "attachment is a blocked original publication" true (Consumer.publication_unfinished error);
    check bool "attachment refusal has an actual diagnostic" true (String.length (Consumer.error_to_string error)>0)
  | Ok _ -> fail "missing Addon must not silently return Pending or an empty report"
let test_retained_source_root_alias () = with_fixture ~history_kind:Official (fun ~sw:_ fixture ->
  let alias=Filename.concat fixture.base_path "workspace-alias" in
  io (fun () -> Unix.symlink fixture.base_path alias);
  Fun.protect ~finally:(fun () -> io (fun () -> Unix.unlink alias)) (fun () ->
    let config={fixture.config with Workspace.base_path=alias} in
    let source=ref None in
    (match memory_action fixture (fun () -> Consumer.consume_one ~config ~keeper_name
      ~commit:(fun captured -> source:=Some captured;Consumer.Memory_refused [])) with
     | Ok (Consumer.Memory_not_committed _) -> ()
     | Ok (Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Pending _) ->
       fail "the aliased source was not captured"
     | Error error -> fail (Consumer.error_to_string error));
    let source=Option.to_result ~none:"the consumer retained no aliased source" !source |> get in
    check string "the public source producer preserves its supplied path"
      (Workspace.keepers_runtime_dir config) (Source.runtime_keepers_dir source);
    let owner=io (fun () ->
      ignore (Current.capture_program_anchor ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get);
      Capture.observe_owner ~base_path:fixture.base_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get) in
    check bool "the physical owner uses another spelling of the same root" false
      (Source.runtime_keepers_dir source=Capture.runtime_keepers_dir owner);
    let preparation=Keeper_librarian_runtime.prepare_durable ~source_lines:[] ~now:(Time_compat.now ()) (Source.input source) |> get in
    let destination=Keeper_librarian_durable_edge.with_destination ~config:fixture.config
      ~reserved:(Keeper_librarian_durable_edge.reserved ()) (fun destination -> Ok destination) |> get in
    let capture=io (fun () -> Capture.create ~request_id:(Capture.fresh_request_id owner)
      ~owner ~destination ~source ~preparation ()) |> get in
    let record=memory_action fixture (fun () -> Durable_owner.retain ~store:fixture.store capture)
      |> Result.map_error Durable_owner.error_to_string |> get in
    let preflight ()=io (fun () -> Lane_addon_store_preflight.scan
      ~validate_tool_request:Keeper_librarian_store_preflight.preflight
      Lane_addon_store_preflight.Store.Tool_request_owners ~base_path:fixture.base_path) |> get in
    check int "the retained alias passes current payload preflight" 0 (List.length (preflight ()).refusals);
    let restored=io (fun () -> Capture.restore ~owner record) |> get in
    check json "runtime restoration preserves the exact captured source spelling"
      (Capture.to_json capture) (Capture.to_json restored);
    let another_workspace=Filename.concat fixture.base_path "another-workspace" in
    io (fun () ->
      Fs_compat.mkdir_p (Common.keepers_runtime_dir_of_base ~base_path:another_workspace);
      Unix.unlink alias;
      Unix.symlink another_workspace alias);
    check int "pure payload inspection grants no physical source authority" 0 (List.length (preflight ()).refusals);
    (match io (fun () -> Capture.restore ~owner record) with
     | Error detail -> check string "a retargeted alias is another physical source"
         "Original history source came from another physical runtime/output root" detail
     | Ok _ -> fail "a different physical source root was restored");
    check int "source inspection and retention dispatch no provider request" 0 (F.post_count fixture.server)))
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
  ignore (Refresh.submit_durable ~base_path:fixture.base_path ~keeper_name);
  Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
  (match Refresh.last_measurement ~config:fixture.config ~keeper_name with
   | Some {last_pass=Refresh.Stopped error;_} ->
     check bool "production queue retains blocked publication" true
       (Consumer.publication_unfinished error)
   | Some {last_pass=(Off | Lane_unconfigured | Drained | Yielded_to_waiting_unit
                    | Not_committed | Pending _ | Raised _);_}
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
   | Ok (Consumer.Memory_not_committed ([] | _::_::_) | Nothing_to_read | Pending _
         | Baseline_advanced _ | Progress_advanced _ | Official_advanced _) ->
     fail "terminal refusal must retain a nonempty diagnostic report");
  let rejected,_=only_original fixture in
  let progress_before=Progress.to_json rejected.progress in
  check bool "terminal refusal is retained as Rejected" true
    (match Progress.phase rejected.progress with Rejected _ -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> false);
  check bool "refusal does not acknowledge source" true (progress fixture=before);
  no_memory fixture;
  fixture.set_response (fun capture -> `OK,F.openai_response (answer capture));
  drive_advanced fixture;
  let fresh,_=only_original fixture in
  check bool "fresh selection retains a separate original ID" true (fresh.Owner.request_id<>rejected.request_id);
  let settled=archived fixture ~date:(day_of rejected.request_id) rejected in
  check json "old refusal never redispatched or rewritten" progress_before (Progress.to_json settled);
  check int "one refused and one successful provider call" 2 (F.post_count fixture.server);
  check (list string) "new original alone publishes Memory"
    ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir)))
let test_retained_body_refusal_shows_descent_from_its_receipt () = with_fixture (fun ~sw:_ fixture ->
  fixture.set_response (fun _ -> `Request_entity_too_large,
    {|{"error":{"message":"fixture body too large","type":"invalid_request_error"}}|});
  let deliveries= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  await_delivery fixture ~after:deliveries;
  (match run_worker fixture with
   | Ok (Consumer.Memory_not_committed [report]) ->
     check bool "a provider body refusal the host retained shows that reading less may help" true
       (Keeper_librarian_runtime.may_descend_messages [report]);
     check bool "the report names the provider's cause" true
       (report.provider_input_refusals=[Keeper_librarian_input_refusal.Request_body_refused])
   | Error error -> fail (Consumer.error_to_string error)
   | Ok (Consumer.Memory_not_committed ([] | _::_::_) | Nothing_to_read | Pending _
         | Baseline_advanced _ | Progress_advanced _ | Official_advanced _) ->
     fail "a retained body refusal must give one report");
  check int "the provider refused once and no later pass called it again" 1 (F.post_count fixture.server))
let test_a_refusal_the_latest_execution_did_not_end_in_shows_nothing () = with_fixture (fun ~sw:_ fixture ->
  fixture.set_response (fun _ -> `Request_entity_too_large,
    {|{"error":{"message":"fixture body too large","type":"invalid_request_error"}}|});
  let deliveries= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  await_delivery fixture ~after:deliveries;
  ignore (run_worker fixture);
  let _,capture=only_original fixture in
  let evidence final=io (fun () -> Capture.refusal_evidence ~store:fixture.store capture final) |> get in
  let refused kind=Lane_addon_exact.Call_final (Input_refused kind) in
  check bool "the final the host actually ended in shows the provider's cause" true
    ((evidence (refused Request_body_refused)).provider_input_refusals
     =[Keeper_librarian_input_refusal.Request_body_refused]);
  (* A retry or a stale report can name a refusal the latest completed
     execution did not end in. The host's receipt belongs to another final, so
     it must not stand for this one. *)
  check bool "a different input refusal shows nothing" true
    (evidence (refused Input_capacity)=Keeper_exact_walk_failure.empty);
  check bool "a refusal that names no size shows nothing" true
    (evidence (refused Invalid_request)=Keeper_exact_walk_failure.empty);
  check bool "an outcome that is not a refusal shows nothing" true
    (evidence Lane_addon_exact.Outcome_unknown=Keeper_exact_walk_failure.empty))
let size_refusal = `Request_entity_too_large, {|{"error":{"message":"fixture body too large","type":"invalid_request_error"}}|}
let scope_directory fixture scope=Filename.concat (Store.root fixture.store)
  (Filename.concat Store.tool_request_owners_directory (Store.digest scope))
let proof_path fixture request=Filename.concat (Store.root fixture.store) (Exact.Retained_key.proof_path
  (Exact.Retained_key.of_request ~declaration_id:"librarian" request))
(* The deploy check's refusals of the Librarian originals. *)
let librarian_refusals fixture=(io (fun () -> Lane_addon_store_preflight.scan
  ~validate_tool_request:Keeper_librarian_store_preflight.preflight
  Lane_addon_store_preflight.Store.Tool_request_owners ~base_path:fixture.base_path) |> get).refusals
(* What the Exact check deletes. *)
let exact_deletes fixture=(io (fun () -> Lane_addon_store_preflight.scan
  Lane_addon_store_preflight.Store.Exact_requests ~base_path:fixture.base_path) |> get).refusals
  |> List.concat_map (fun (refusal:Lane_addon_store_preflight.refusal) -> refusal.delete)
(* A version 1 proof holds the request body. [run] refuses to read it, so the
   Exact check deletes the record with it (L2b-3). *)
let version_1_proof fixture request=
  let path=proof_path fixture request in
  let version_1=function
    | `Assoc fields -> `Assoc (("request",Exact.request_to_json request)
        :: List.map (fun (key,value) -> key,if String.equal key "version" then `Int 1 else value) fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "a proof is an object" in
  let executions=function
    | `List entries -> `List (List.map version_1 entries)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
      fail "a proof link lists its executions" in
  match Yojson.Safe.from_string (io (fun () -> Fs_compat.load_file path)) with
  | `Assoc fields -> io (fun () -> write path (Yojson.Safe.to_string (`Assoc (List.map (fun (key,value) ->
      key,if String.equal key "executions" then executions value else value) fields))))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "a proof link is an object"
(* The deploy check refuses [original], kept in [scope], on the Exact files it
   reads, and refuses no other record outside [gate]. A gate follows its
   parent, so a refusal in [gate] is one of the same reason. Every refusal
   deletes [scope], and [gate] when the store holds it. Whether a gate is
   refused at all is [refused_in]'s to check. *)
let refuses_original fixture ~(original:Owner.retained) (scope,gate)
    (refusals:Lane_addon_store_preflight.refusal list)=
  let scope=scope_directory fixture scope and gate=scope_directory fixture gate in
  let path=Filename.concat scope (Store.digest original.request_id ^ ".json") in
  let deletes_owner (refusal:Lane_addon_store_preflight.refusal)=
    refusal.decoder=Lane_addon_store_preflight.Tool_request_exact_reads && List.mem scope refusal.delete
    && (not (io (fun () -> Sys.file_exists gate)) || List.mem gate refusal.delete) in
  List.exists (fun (refusal:Lane_addon_store_preflight.refusal) -> String.equal refusal.path path) refusals
  && List.for_all (fun (refusal:Lane_addon_store_preflight.refusal) ->
      deletes_owner refusal
      && (String.equal refusal.path path || String.equal (Filename.dirname refusal.path) gate)) refusals
let refused_in fixture scope (refusals:Lane_addon_store_preflight.refusal list)=
  List.exists (fun (refusal:Lane_addon_store_preflight.refusal) ->
    String.equal (Filename.dirname refusal.path) (scope_directory fixture scope)) refusals
let history_scopes capture=let owner=Capture.physical_owner capture in Capture.scope owner,Gate.scope owner
(* The one history original, which waits for the final the worker lost. *)
let lost_final fixture=
  let record,capture=only_original fixture in
  match Progress.phase record.progress with
  | Progress.Dispatch_pending _ -> record,capture
  | Captured | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
  | Rejected _ | Subdividing _ | Subdivided _ -> fail "expected the original to wait for the final the worker lost"
let lose_the_final fixture=
  fixture.delivery_loss:=true;
  let before= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  await_delivery fixture ~after:before;
  lost_final fixture
(* History builds the evidence of a body refusal from the final alone
   (Final.refusal_evidence) and reads no size evidence through the record, so
   the deploy check passes the original when the Exact check deletes that
   record (RFC exact-request-skips-a-slot-that-refused-its-input, section 5). *)
let test_preflight_passes_a_history_body_refusal_whose_record_goes () = with_fixture (fun ~sw:_ fixture ->
  fixture.set_response (fun _ -> size_refusal);
  let deliveries= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  await_delivery fixture ~after:deliveries;
  ignore (run_worker fixture);
  let refused,capture=only_original fixture in
  check bool "the host's body refusal ends the original at execution" true
    (match Progress.phase refused.progress with
     | Progress.Rejected {stage=Progress.Execution;_} -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Rejected {stage=Progress.Before_dispatch;_} | Subdividing _ | Subdivided _ ->
       false);
  let request=Capture.request capture |> get in
  let proof_path=proof_path fixture request in
  check int "the refusal passes while its record and proof are kept" 0 (List.length (librarian_refusals fixture));
  check (list string) "the Exact check keeps the record with its version 2 proof" [] (exact_deletes fixture);
  version_1_proof fixture request;
  check bool "the Exact check deletes the record with its version 1 proof" true
    (List.mem proof_path (exact_deletes fixture));
  check int "with a version 1 proof the final alone gives history its evidence, so the original passes" 0
    (List.length (librarian_refusals fixture));
  (* A proof link that is not JSON: the Exact check deletes the record with it. *)
  io (fun () -> write proof_path "{");
  check int "the final alone gives history its evidence, so the original passes" 0
    (List.length (librarian_refusals fixture)))
(* The host answers and keeps the record; the worker loses that final.
   Resume confirms the final it recovers through the record, so once the
   Exact check deletes the record, no record confirms the answer. *)
let test_preflight_refuses_a_lost_history_answer_whose_proof_is_version_1 () = with_fixture (fun ~sw:_ fixture ->
  let original,capture=lose_the_final fixture in
  check bool "the host retains its answer" true
    (match latest fixture capture with
     | Exact.Completed_latest {execution={outcome=Call_ended (Answered _);_};_} -> true
     | No_completed_latest
     | Completed_latest {execution={outcome=Call_ended (Invalid_output _ | Input_refused _ | Output_limit_reached _)
         | Call_refused _;_};_} -> false);
  let request=Capture.request capture |> get in
  check int "with its version 2 proof resume confirms the answer it recovers" 0
    (List.length (librarian_refusals fixture));
  version_1_proof fixture request;
  check bool "the Exact check deletes the finished record with its version 1 proof" true
    (List.mem (proof_path fixture request) (exact_deletes fixture));
  check bool "the deploy check refuses the history owner on the record the Exact check deletes" true
    (refuses_original fixture ~original (history_scopes capture) (librarian_refusals fixture)))
(* The host ends the request with its only slot's body refusal and keeps the
   record; the worker loses that final. History needs no record for the
   refusal's evidence, so the deploy check passes once the record goes. *)
let test_preflight_passes_a_lost_history_body_refusal_whose_record_goes () = with_fixture (fun ~sw:_ fixture ->
  fixture.set_response (fun _ -> size_refusal);
  let _,capture=lose_the_final fixture in
  check bool "the host retains its only slot's body refusal" true
    (match latest fixture capture with
     | Exact.Completed_latest {execution={outcome=Call_ended (Input_refused Request_body_refused);_};_} -> true
     | No_completed_latest
     | Completed_latest {execution={outcome=Call_ended (Answered _ | Invalid_output _ | Output_limit_reached _
         | Input_refused (Input_capacity | Context_overflow | Invalid_request)) | Call_refused _;_};_} -> false);
  let request=Capture.request capture |> get in
  check int "with its version 2 proof resume confirms the body refusal" 0
    (List.length (librarian_refusals fixture));
  version_1_proof fixture request;
  check bool "the Exact check deletes the finished record with its version 1 proof" true
    (List.mem (proof_path fixture request) (exact_deletes fixture));
  check int "the final alone gives history its evidence, so the lost body refusal passes" 0
    (List.length (librarian_refusals fixture)))
(* The Librarian worker's declared reply frame is 4 MiB; a request whose host
   listing cannot fit is refused by the worker before the host retains it. *)
let oversized_turn_bytes = 4_500_000
let test_worker_body_refusal_ends_the_original () = with_fixture (fun ~sw:_ fixture ->
  let oversized=selected_messages @ [message (String.init oversized_turn_bytes (fun index -> Char.chr (97 + index mod 26)));
    Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text "Oversized answer"]] in
  save_checkpoint fixture.config ~trace_id oversized 3;
  io (fun () -> append_boundary fixture.config ~turn:3 ~time:(Time_compat.now ())
    ~history_at_start:(Boundary.history_at_start_of_messages selected_messages) oversized);
  let before=progress fixture in
  (match run_worker fixture with
   | Ok (Consumer.Memory_not_committed [report]) ->
     let final=Lane_addon_exact.Call_final (Input_refused Request_body_refused) in
     check string "the worker's typed frame refusal ends the pass"
       ("Original history request refused: " ^ Yojson.Safe.to_string (Lane_addon_exact.final_to_json final)) report.detail
     ;check bool "a frame refusal shows that reading less may help" true
       (Keeper_librarian_runtime.may_descend_messages [report]);
     check bool "the frame refusal names its cause and no provider ran" true
       (report.provider_input_refusals=[Keeper_librarian_input_refusal.Request_body_refused]
        && not report.smaller_range_meets_same_failure)
   | Error error -> fail (Consumer.error_to_string error)
   | Ok (Consumer.Memory_not_committed ([] | _::_::_) | Nothing_to_read | Pending _
         | Baseline_advanced _ | Progress_advanced _ | Official_advanced _) ->
     fail "an unlistable request must end as one refusal");
  let refused,_=only_original fixture in
  check bool "the refused original is finished, not left at dispatch" true
    (match Progress.phase refused.progress with Rejected _ -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> false);
  check int "no model ran for the refused request" 0 (F.post_count fixture.server);
  check bool "refusal does not acknowledge source" true (progress fixture=before))
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
  let posts=F.post_count fixture.server in
  let gates=gate_records fixture capture in
  check bool "the finished original has gate records to settle" true (List.length gates>0);
  ignore (run_worker fixture);
  check int "the next pass settles the finished original" 0 (List.length (observed_originals fixture));
  let date=day_of record.Owner.request_id in
  let settled=archived fixture ~date record in
  check json "settled original keeps its finished progress" (Progress.to_json record.progress) (Progress.to_json settled);
  check bool "its gate records settle under the same day" true (List.for_all (settled_on fixture ~date) gates);
  check int "no gate record stays for validation" 0 (List.length (gate_records fixture capture));
  check int "already consumed source never creates another provider request" posts (F.post_count fixture.server))

(* The object has the required wire shape, but its source reference is not
   one of the aliases in the captured input. The domain refuses organization
   without refusing the Memory answer. Extra fields test the earlier wire
   boundary separately. *)
let answer_with_invalid_working_context ~extra_fields capture = match answer capture with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
      if key="working_contexts" then key,`List [`Assoc ([
        "merge_contexts",`List [];"sources",`List [`String "fixture-source"];
        "context",`String "original context";"next_steps",`List []] @ extra_fields)]
      else key,value) fields)
    | _ -> fail "fixture answer is not an object"
let test_working_context_with_an_unallowed_field_is_not_an_answer () = with_fixture (fun ~sw:_ fixture ->
  let output=answer_with_invalid_working_context
    ~extra_fields:["completeness",`String "current"] in
  fixture.set_response (fun capture -> `OK,F.openai_response (output capture));
  let before=progress fixture and delivered= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  await_delivery fixture ~after:delivered;
  let _,capture=only_original fixture in
  (match latest fixture capture with
   | Exact.Completed_latest {execution={outcome=Call_ended (Invalid_output _);_};_} -> ()
   | No_completed_latest
   | Completed_latest {execution={outcome=Call_ended (Answered _ | Input_refused _ | Output_limit_reached _)
       | Call_refused _;_};_} -> fail "an unallowed nested field must not become an answered original");
  (match run_worker fixture with
   | Ok (Consumer.Memory_not_committed [_]) -> ()
   | Ok (Memory_not_committed ([] | _::_::_) | Nothing_to_read | Pending _
       | Baseline_advanced _ | Progress_advanced _ | Official_advanced _) ->
       fail "the invalid wire answer must end the pass as one refusal"
   | Error error -> fail (Consumer.error_to_string error));
  no_memory fixture;
  check bool "a wire shape refusal consumes no original source" true (progress fixture=before))
let test_retained_answer_with_invalid_working_context_recovers () = with_fixture (fun ~sw:_ fixture ->
  let output=answer_with_invalid_working_context ~extra_fields:[] in
  fixture.set_response (fun capture -> `OK,F.openai_response (output capture));
  let before=progress fixture and delivered= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  await_delivery fixture ~after:delivered;
  let record,capture=only_original fixture in
  let exact=Capture.request capture |> get in
  let schema=Option.get exact.Exact.schema in
  let final=match latest fixture capture with
    | Exact.Completed_latest {execution={outcome=Call_ended (Answered _ as answer);_};_} -> Exact.Call_final answer
    | _ -> fail "actual original answer and proof were not retained" in
  let wire=Exact.final_to_json final in
  check bool "the original answer has the required wire shape" true
    (Result.is_ok (Exact.final_of_json ~schema wire));
  let decoded=io (fun () -> Capture.decode_final ~store:fixture.store capture wire) |> get in
  check json "recovery preserves the exact host answer" wire (Exact.final_to_json decoded);
  let proposal=Capture.validate_proposal capture (output capture) |> get in
  (match proposal.Keeper_librarian_runtime.accepted.selection.working_contexts with
   | Keeper_librarian.Working_contexts_invalid _ -> ()
   | Working_contexts_organized _ | Working_contexts_missing -> fail "invalid context must remain refused");
  let changed=match wire with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
        if key="slot" then key,`String "different-slot" else key,value) fields)
    | _ -> fail "final is not an object" in
  check bool "a different worker result cannot borrow the host answer" true
    (io (fun () -> Result.is_error (Result.bind
      (Capture.decode_final ~store:fixture.store capture changed)
      (Capture.confirm_final ~store:fixture.store capture))));
  check bool "a different schema cannot observe this original" true
    (io (fun () -> Result.is_error (Exact.observe_retained ~store:fixture.store
      ~declaration_id:"librarian" ~schema:(`Assoc []) exact)));
  let strict_forgery=match wire with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
        if key="output" then key,answer capture else key,value) fields)
    | _ -> fail "final is not an object" in
  let strict_final=io (fun () -> Capture.decode_final ~store:fixture.store capture strict_forgery) |> get in
  check bool "a strict forged answer still fails the host confirmation boundary" true
    (io (fun () -> Result.is_error (Capture.confirm_final ~store:fixture.store capture strict_final)));
  let empty_store=Store.create ~root:(Filename.concat fixture.base_path "missing-original-proof") in
  let host=io (fun () -> Store.load_exact_request fixture.store ~declaration_id:"librarian"
    ~request_id:exact.request_id |> get |> Option.get) in
  io (fun () -> Store.save_exact_request empty_store ~declaration_id:"librarian"
    ~request_id:exact.request_id host |> get);
  check bool "a terminal without its execution proof cannot recover" true
    (io (fun () -> Result.is_error (Result.bind
      (Capture.decode_final ~store:empty_store capture wire)
      (Capture.confirm_final ~store:empty_store capture))));
  let invalid_memory=match output capture with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
        if key="new_claims" then key,`List [new_claim ""] else key,value) fields)
    | _ -> fail "fixture answer is not an object" in
  check bool "invalid Memory is still rejected by its domain" true
    (Result.is_error (Capture.validate_proposal capture invalid_memory));
  let hold=memory_action fixture (fun () ->
    Durable_owner.resume ~store:fixture.store ~config:fixture.config ~reserved:[]
      ~original:(Durable_owner.Read (record,capture))
      ~call:(fun ~expected:_ ~original:_ ~arguments:_ -> fail "proved host answer must not call the worker")
      ~publish:(fun ~original:_ ~request:_ ~proposal:_ ->
        Ok (Durable_owner.Publication_pending "fixture holds publication after judgment"))
      ~wake:(fun () -> ())) in
  (match hold with
   | Ok (Durable_owner.Resumed (Publication_waiting _,_)) -> ()
   | Ok (Waited _ | Original_replaced _ | Resumed ((Refused _ | Finished _ | Basis_superseded _ | Ended_unadmitted _),_)) -> fail "original did not retain its judgment"
   | Error error -> fail (Durable_owner.error_to_string error));
  let judged,_=only_original fixture in
  (match Progress.phase judged.Owner.progress with
   | Progress.Judged actual -> check json "the real submit machine retained the original answer" wire actual
   | _ -> fail "original is not waiting with its proven judgment");
  let posts=F.post_count fixture.server in
  check bool "the retained original completes publication" true (advanced (run_worker fixture));
  check (list string) "valid original Memory was committed"
    ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir));
  check bool "source progress follows the committed original" true (progress fixture<>before);
  let range=Option.get (Source.range_id (Capture.source capture)) in
  let coverage=io (fun () -> Current.committed_durable_coverage ~keepers_dir:fixture.keepers_dir
    ~keeper_id:keeper_name ~receipt_scope:range.Current.receipt_scope |> get) in
  check bool "the original Memory receipt covers the source range" true (coverage=Some range);
  let finished,_=only_original fixture in
  (match Progress.phase finished.Owner.progress with
   | Progress.Finished commit -> check json "finished judgment remains unchanged" wire commit.judgment
   | _ -> fail "original judgment did not finish");
  let gate=match gate_records fixture capture with
    | [gate] -> gate
    | [] | _::_::_ -> fail "expected the retained gate for the original answer" in
  let report=io (fun () -> Lane_addon_store_preflight.scan
    ~validate_tool_request:Keeper_librarian_store_preflight.preflight
    Lane_addon_store_preflight.Store.Tool_request_owners ~base_path:fixture.base_path) |> get in
  check bool "preflight examined the parent and gate" true (report.rows>=2);
  check int "preflight reads the host-shaped original parent and gate" 0 (List.length report.refusals);
  let fields=Yojson.Safe.Util.to_assoc gate.request in
  let changed_request=`Assoc
    (("proposal",answer capture)::List.remove_assoc "proposal" fields) in
  let changed_store=Store.create ~root:(Filename.concat fixture.base_path "changed-gate") in
  let changed_gate=io (fun () ->
    Owner.retain ~store:changed_store ~scope:gate.scope ~request_id:gate.request_id
      ~installation_id:gate.installation_id ~package_id:gate.package_id ~tool:gate.tool
      ~summary:gate.summary ~request:changed_request |> owned;
    match Owner.load ~store:changed_store ~scope:gate.scope ~request_id:gate.request_id |> owned with
    | Some record -> record
    | None -> fail "the changed gate was not retained") in
  let rejected=io (fun () -> Gate.validate_payload ~proofs:(Gate.proofs ()) ~owner:(Capture.physical_owner capture)
    ~capture ~parent:finished ~record:changed_gate
    ~read:(fun ~scope:_ ~request_id:_ -> fail "a changed proposal must refuse before ancestry lookup")
    ~read_body:(fun ~scope:_ ~request_digest:_ -> fail "a changed proposal must refuse before body lookup")) in
  check (result unit string) "preflight refuses a gate with a different original answer"
    (Error "Gate proposal differs from the original answered judgment") rejected;
  check int "the original provider request is not resubmitted" posts (F.post_count fixture.server))
(* A settle that stopped between a history record and its gate records leaves
   gates of an archived execution. A pass with no original reads no gate
   scope, so the pass of the next original settles them. *)
let test_stopped_settle_leaves_gates_for_the_next_original () = with_fixture (fun ~sw:_ fixture ->
  drive_advanced fixture;
  let record,capture=only_original fixture in
  let gates=gate_records fixture capture in
  let date=day_of record.Owner.request_id in
  settle_only fixture ~date record;
  (match run_worker fixture with
   | Ok Consumer.Nothing_to_read -> ()
   | Ok (Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending _) ->
     fail "a consumed source has nothing to read"
   | Error error -> fail (Consumer.error_to_string error));
  check int "a pass without an original leaves the stopped gates" (List.length gates)
    (List.length (gate_records fixture capture));
  let next=selected_messages @ [message "Second question to retain";
    Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text "Second completed answer"]] in
  save_checkpoint fixture.config ~trace_id next 3;
  io (fun () -> append_boundary fixture.config ~turn:3 ~time:(Time_compat.now ())
    ~history_at_start:(Boundary.history_at_start_of_messages selected_messages) next);
  drive_advanced fixture;
  check bool "the stopped gates settle under their execution's day" true (List.for_all (settled_on fixture ~date) gates);
  check bool "only the new original's gate records stay" true
    (List.for_all (fun (gate:Owner.retained) ->
       not (List.exists (fun (old:Owner.retained) -> old.request_id=gate.request_id) gates))
       (gate_records fixture capture));
  check int "each original reached the provider once" 2 (F.post_count fixture.server))

let test_inventory_observation_reuses_verified_inputs () = with_fixture (fun ~sw:_ fixture ->
  let module Journal = Keeper_librarian_durable_gate in
  let module Commit = Keeper_librarian_durable_commit in
  drive_advanced fixture;
  let parent,capture=only_original fixture in
  let owner=Capture.physical_owner capture in
  let gates=io (fun () -> Owner.load_scope ~store:fixture.store ~scope:(Journal.scope owner)) |> owned in
  let gate=match gates with [gate] -> gate | [] | _::_::_ -> fail "expected one completed gate" in
  let posts=F.post_count fixture.server and positions=progress fixture in
  memory_action fixture (fun () ->
    let inventory=io (fun () -> Journal.Inventory.read ~store:fixture.store ~owner) |> get in
    let validate ()=io (fun () -> Commit.validate_inventory ~inventory ~store:fixture.store
      ~request:capture ~record:parent) in
    List.iter (fun (record : Owner.retained) ->
      let path=Filename.concat (Store.root fixture.store) (Filename.concat Store.tool_request_bodies_directory
        (Filename.concat (Store.digest record.scope) (record.request_digest ^ ".json"))) in
      Eio.Switch.run (fun sw ->
        let hidden=path ^ ".fixture-hidden" in
        io (fun () -> Unix.rename path hidden);
        Eio.Switch.on_release sw (fun () -> io (fun () -> Unix.rename hidden path));
        check bool "one read-only pass reuses its verified parent and gate bodies" true
          (validate ()=Ok Commit.Settled);
        check bool "fresh validation never obtains authority from that observation" true
          (io (fun () -> Commit.validate ~store:fixture.store ~request:capture ~record:parent)
           |> Result.is_error);
        check bool "recovery reloads the original parent and acknowledged gate" true
          (io (fun () -> Journal.recover_root ~store:fixture.store ~owner ~capture)
           |> Result.is_error);
        if record.request_id=gate.request_id then
          check bool "a new inventory refuses an unreadable published gate body" true
            (io (fun () -> Journal.Inventory.read ~store:fixture.store ~owner)
             |> Result.is_error))) [parent;gate]);
  check int "read-only observations do not invoke the provider" posts (F.post_count fixture.server);
  check bool "read-only observations do not acknowledge new source" true (progress fixture=positions);
  ignore (run_worker fixture);
  check int "fresh post-observation wake never redispatches the settled original" posts (F.post_count fixture.server))

let test_inventory_observation_rejects_mixed_parent_and_bad_scope () = with_fixture (fun ~sw:_ fixture ->
  let module Journal = Keeper_librarian_durable_gate in
  let module Commit = Keeper_librarian_durable_commit in
  drive_advanced fixture;
  let parent,capture=only_original fixture in
  let owner=Capture.physical_owner capture in
  memory_action fixture (fun () ->
    let inventory=io (fun () -> Journal.Inventory.read ~store:fixture.store ~owner) |> get in
    let other=Store.create ~root:(Filename.concat fixture.base_path "changed-parent-owner") in
    io (fun () -> Owner.retain ~store:other ~scope:parent.scope ~request_id:parent.request_id
      ~installation_id:parent.installation_id ~package_id:parent.package_id ~tool:parent.tool
      ~summary:parent.summary ~request:(`Assoc ["replaced",`Bool true])) |> owned;
    let changed=io (fun () -> Owner.load ~store:other ~scope:parent.scope ~request_id:parent.request_id)
      |> owned |> Option.get in
    check bool "an observation cannot borrow a different original capture" true
      (io (fun () -> Commit.validate_inventory ~inventory ~store:fixture.store ~request:capture
        ~record:changed) |> Result.is_error));
  let posts=F.post_count fixture.server and positions=progress fixture in
  io (fun () -> Owner.retain ~store:fixture.store ~scope:(Journal.scope owner)
    ~request_id:"unrelated-invalid-gate" ~installation_id:parent.installation_id
    ~package_id:parent.package_id ~tool:parent.tool ~summary:`Null
    ~request:(`Assoc ["version",`Int 1;"unrelated",`Bool true])) |> owned;
  check bool "complete inventory rejects corruption outside the selected execution" true
    (io (fun () -> Journal.Inventory.read ~store:fixture.store ~owner) |> Result.is_error);
  check bool "production wake refuses the corrupt scope before new selection or dispatch" true
    (Result.is_error (run_worker fixture));
  check int "corrupt inventory cannot trigger a fresh provider call" posts (F.post_count fixture.server);
  check bool "corrupt inventory preserves source acknowledgements" true (progress fixture=positions))

let test_librarian_transcript_refuses_foreign_facts transport () = with_fixture (fun ~sw:_ fixture ->
  let module Approval = Lane_addon_request_approval in
  let module Fingerprint = Keeper_approval_request_fingerprint in
  drive_advanced fixture;
  let _,capture = only_original fixture in
  let owner = Capture.physical_owner capture in
  let gate = match gate_records fixture capture with
    | [gate] -> gate | [] | _ :: _ :: _ -> fail "expected one complete original gate" in
  let posts = F.post_count fixture.server and positions = progress fixture in
  memory_action fixture (fun () ->
    io (fun () ->
      Gate.validate ~store:fixture.store ~owner ~capture ~record:gate |> get;
      let exact = Fingerprint.exact_request ~base_path:fixture.base_path ~keeper_name
          ~operation:"fixture_media_read" ~input:(`Assoc ["source",`String "foreign media approval"])
          ~origin:Keeper_approval_origin.unavailable ~task_id:None ~goal_id:None
          ~continuation_channel:(Keeper_continuation_channel.unrouted "foreign approval fixture") |> get in
      let intent = Approval.intent ~request_id:gate.request_id ~request_digest:gate.request_digest
          ~request:exact |> get in
      let wait = Approval.wait intent ~approval_id:"foreign-media-approval"
          ~input_hash:(Fingerprint.input_hash exact) |> get in
      let prefix = Progress.append Progress.captured (Progress.Approval_intended intent) |> get in
      let prefix = Progress.append prefix (Progress.Approval_wait_retained wait) |> get in
      let transport_evidence = `Assoc ["foreign_transport",`String "owned elsewhere"] in
      let prefix = if transport then
          Progress.append Progress.captured (Progress.Transport_observed transport_evidence) |> get
        else prefix in
      let with_foreign = List.fold_left (fun state event ->
        Result.bind state (fun state -> Progress.append state event))
          (Ok prefix) (Progress.events gate.progress) |> get in
      let metadata = match Owner.to_json gate with
        | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
            key, if key="progress" then Progress.to_json with_foreign else value) fields)
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
          fail "owner metadata is not an object" in
      Store.save_tool_request_owner fixture.store ~scope:gate.scope ~request_id:gate.request_id
        (Lane_addon_action.canonical metadata |> get) |> get;
      let changed = match Owner.load ~store:fixture.store ~scope:gate.scope ~request_id:gate.request_id |> owned with
        | Some record -> record | None -> fail "foreign event erased the original gate" in
      check string "generic restore keeps the real gate body digest" gate.request_digest changed.request_digest;
      check json "generic restore keeps the complete gate request" gate.request changed.request;
      check bool "generic fold preserves the completed phase" true
        (Progress.phase changed.progress=Progress.phase gate.progress);
      check bool "generic fold accepts the well-formed foreign fact" true
        (if transport then Progress.transport_observation changed.progress=Some transport_evidence
         else match Progress.approval changed.progress with
         | Some (Progress.Waiting_for_approval (seen,linked)) ->
           Approval.equal_intent intent seen && Approval.equal_wait wait linked
         | None | Some (Progress.Intent_pending _) -> false);
      check (result unit string) "the actual Librarian transcript rejects foreign facts"
        (Error "Unexpected event in original gate journal")
        (Gate.validate ~store:fixture.store ~owner ~capture ~record:changed)));
  check int "read-only validation makes no further provider call" posts (F.post_count fixture.server);
  check bool "read-only validation preserves source acknowledgement" true (progress fixture=positions))

(* A gate request and the parent's publication intent name the parent by ID
   and body digest, so the history body is stored once. The earlier shape
   carried a copy of the parent and has no reader. *)
let test_gate_request_names_its_parent_by_digest () = with_fixture (fun ~sw:_ fixture ->
  drive_advanced fixture;
  let parent,capture=only_original fixture in
  let gate=match gate_records fixture capture with [gate] -> gate | [] | _::_::_ -> fail "expected one completed gate" in
  let intent=match Progress.preparation parent.progress with
    | Some (Preparation_confirmed intent) -> intent
    | None | Some (Preparation_pending _) -> fail "a finished original holds its confirmed gate intent" in
  check json "the parent's intent is the gate request it published" gate.request intent.request;
  check bool "the gate request holds no copy of its parent" true (member "capture" gate.request=`Null);
  check string "the gate request names its parent by ID" parent.request_id
    (Yojson.Safe.Util.to_string (member "execution_id" gate.request));
  check string "and its parent's body by digest" parent.request_digest
    (Yojson.Safe.Util.to_string (member "execution_digest" gate.request));
  let earlier=match gate.request with
    | `Assoc fields -> `Assoc (("capture",Capture.to_json capture)::List.map (fun (name,value) ->
        match name with
        | "version" -> name,`Int 1
        | "request_id" -> name,`String "earlier-gate-shape"
        | _ -> name,value) fields)
    | _ -> fail "a gate request is an object" in
  io (fun () -> Owner.retain ~store:fixture.store ~scope:gate.scope ~request_id:"earlier-gate-shape"
    ~installation_id:gate.installation_id ~package_id:gate.package_id ~tool:gate.tool ~summary:`Null
    ~request:earlier) |> owned;
  match io (fun () -> Gate.Inventory.read ~store:fixture.store ~owner:(Capture.physical_owner capture)) with
  | Error detail -> check string "a gate request in the earlier shape is refused by its version"
      "Original gate request is not version 3" detail
  | Ok _ -> fail "a gate request that copies its parent was read")
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
     | Official,Source.Held.Official_only _ | Mixed,Source.Held.Mixed _ -> true
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

(* Preserve the upstream narrowed-range regression for ordinary invalid-request
   refusals. The capacity-only path now retains a durable stop; an independent
   failure still narrows without losing counterpart identities or ACK ordering. *)
let test_counterpart_non_capacity_refusal_preserves_narrowed_sources () =
  with_fixture ~history_kind:Official (fun ~sw:_ fixture ->
    let content = "begin counterpart\n" ^ String.make 65536 'x' ^ "\nend counterpart" in
    let speaker : Keeper_chat_store.speaker =
      {speaker_id=Some "external";speaker_name=Some "External";
       speaker_authority=Keeper_chat_store.External} in
    Keeper_chat_store.append_user_message ~base_dir:fixture.base_path ~keeper_name
      ~content ~speaker ();
    io (fun () ->
      official_turn fixture.config ~turn:2 ~time:(Time_compat.now () +. 10.);
      let session_dir=Keeper_fs.keeper_session_dir fixture.config trace_id in
      let path file=Keeper_turn_fragments.path ~session_dir file in
      write (path Keeper_turn_fragments.Main)
        ({|{"ts_unix":1.0,"role":"user","content_blocks":[{"type":"text","text":"old"}]}|} ^ "\n");
      write (path Keeper_turn_fragments.Internal) "");
    let official ()=io (fun () -> Keeper_librarian_official_progress.read
      ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_id:keeper_name
      |> Result.map_error Keeper_librarian_official_progress.read_error_to_string |> get) in
    let before=official () in
    let external_observation : Keeper_counterpart_observation.t =
      {origin=Connector_attention;channel="agent";workspace_id=None;
       user_id=Some "original-agent";user_name=Some "Original agent";
       authority=External;content="Original admitted external evidence"} in
    let chat_observation : Keeper_counterpart_observation.t =
      {origin=Durable_chat;channel="direct";workspace_id=None;
       user_id=Some "external";user_name=Some "External";
       authority=External;content} in
    let observations capture =
      let input=Capture.source capture |> Source.input in
      List.length input.messages, List.length input.tool_observations, input.counterpart_observations in
    let check_complete capture =
      check bool "the provider request retains both complete counterpart identities and bytes" true
        (observations capture = (0,0,[external_observation;chat_observation])) in
    let initial_requests = ref [] in
    fixture.set_response (fun capture ->
      initial_requests := !initial_requests @ [observations capture];
      `Bad_request,
        {|{"error":{"message":"fixture invalid request","type":"invalid_request_error"}}|});
    let deliveries= !(fixture.deliveries) in
    assert_pending (run_worker fixture);
    await_delivery fixture ~after:deliveries;
    check bool "the refused request retains both complete counterpart identities and bytes" true
      (!initial_requests = [0,0,[external_observation;chat_observation]]);
    (match run_worker fixture with
     | Ok (Consumer.Memory_not_committed [report]) ->
       let official_range=Source.official_range_id (Capture.source (snd (only_original fixture))) in
       check bool "ordinary invalid-request refusal invents no capacity evidence" true
         (report.provider_input_refusals=[] && not report.input_capacity_only);
       check bool "the operator can locate both original official rows" true
         (Option.map (fun (range:Current.official_range_id) -> List.map fst range.turns) official_range=Some [1;2])
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "ordinary counterpart refusal did not return its actual report");
    check bool "the refusal does not advance official history" true (official ()=before);
    let cursor ()=io (fun () -> Keeper_external_read_cursor.observe
      ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
    check bool "the refusal does not acknowledge the external row" true
      (Keeper_external_read_cursor.observation_matches_preparation (cursor ())
        ~after:0 ~through:1 ~atom:None
        ~official:(Source.official_range_id (Capture.source (snd (only_original fixture)))));
    no_memory fixture;
    let rejected,original=only_original fixture in
    check_complete original;
    let source_json=Source.to_json (Capture.source original) in
    let restored=Source.of_json source_json |> Result.map_error Source.error_to_string |> get in
    check json "the whole refused original survives strict restoration" source_json (Source.to_json restored);
    check int "only one actual provider request was refused" 1 (F.post_count fixture.server);
    let narrowed_refusal = ref [] in
    fixture.set_response (fun capture ->
      narrowed_refusal := !narrowed_refusal @ [observations capture];
      `Bad_request,
        {|{"error":{"message":"fixture invalid request","type":"invalid_request_error"}}|});
    let deliveries= !(fixture.deliveries) in
    assert_pending (run_worker fixture);
    await_delivery fixture ~after:deliveries;
    (match run_worker fixture with
     | Ok (Consumer.Memory_not_committed [report]) ->
       let official_range=Source.official_range_id (Capture.source (snd (only_original fixture))) in
       check bool "the narrowed invalid-request refusal invents no capacity evidence" true
         (report.provider_input_refusals=[] && not report.input_capacity_only);
       check bool "the narrowed refusal names only the first boundary" true
         (Option.map (fun (range:Current.official_range_id) -> List.map fst range.turns) official_range=Some [1])
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "ordinary narrowed refusal did not return its actual report");
    let narrowed,narrowed_capture=only_original fixture in
    check bool "the narrowed refusal uses a distinct original" true
      (narrowed.Owner.request_id<>rejected.request_id);
    check bool "the narrowed request preserved the complete external identity and bytes" true
      (!narrowed_refusal = [0,0,[external_observation]] && observations narrowed_capture = (0,0,[external_observation]));
    check bool "a second refusal leaves the official cursor unread" true (official ()=before);
    check bool "a second refusal still has not acknowledged the external row" true
      (Keeper_external_read_cursor.observation_matches_preparation (cursor ())
        ~after:0 ~through:1 ~atom:None
        ~official:(Source.official_range_id (Capture.source narrowed_capture)));
    no_memory fixture;
    check int "both refused requests reached the provider" 2 (F.post_count fixture.server);
    (* The refused original covered both official boundaries. A failed wide
       pass narrows to the oldest boundary on its next wake: the external row
       precedes that boundary, while the chat was appended after it. Observe
       both successful requests before checking their payloads so a failing
       test assertion does not get swallowed inside the HTTP fixture fiber. *)
    let recovered = ref [] in
    fixture.set_response (fun capture ->
      recovered := !recovered @ [observations capture];
      `OK,F.openai_response (answer capture));
    drive_advanced fixture;
    let fresh,fresh_capture=only_original fixture in
    check bool "fresh reprocessing uses a new original, not replaying the refused request" true
      (fresh.Owner.request_id<>narrowed.request_id && fresh.request_id<>rejected.request_id);
    check bool "the first successful request holds only the complete older external row" true
      (!recovered = [0,0,[external_observation]]);
    check (option int) "the first successful commit advances only the first official boundary"
      (Some 1) (Option.map (fun (cursor:Keeper_librarian_official_progress.t) -> cursor.boundary_line) (official ()));
    let check_coverage expected_line capture =
      let range=Source.official_range_id (Capture.source capture) |> Option.get in
      check (list int) "the original names its own official boundary" [expected_line] (List.map fst range.turns);
      check bool "Memory records the exact successful original's official coverage" true
        (io (fun () -> Current.committed_official_coverage ~keepers_dir:fixture.keepers_dir
          ~keeper_id:keeper_name ~receipt_scope:range.receipt_scope |> get) = Some range) in
    check_coverage 1 fresh_capture;
    check bool "external evidence is acknowledged only after its successful commit" true
      (Keeper_external_read_cursor.observation_matches_preparation (cursor ())
        ~after:1 ~through:1 ~atom:None ~official:None);
    drive_advanced fixture;
    let final,final_capture=only_original fixture in
    check bool "the later boundary has its own original request" true
      (final.Owner.request_id<>fresh.request_id && final.request_id<>narrowed.request_id
       && final.request_id<>rejected.request_id);
    check bool "both successful requests preserve counterpart origins and bytes in order" true
      (!recovered = [0,0,[external_observation]; 0,0,[chat_observation]]);
    check (option int) "the second successful commit advances the remaining official boundary"
      (Some 2) (Option.map (fun (cursor:Keeper_librarian_official_progress.t) -> cursor.boundary_line) (official ()));
    check_coverage 2 final_capture;
    check bool "the later chat does not change the settled external acknowledgment" true
      (Keeper_external_read_cursor.observation_matches_preparation (cursor ())
        ~after:1 ~through:1 ~atom:None ~official:None);
    check int "two refused and two successful requests reached the provider" 4 (F.post_count fixture.server);
    (match run_worker fixture with
     | Ok Consumer.Nothing_to_read -> ()
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "successfully consumed counterpart input remained unread");
    check int "the settled input is not sent again" 4 (F.post_count fixture.server))

let test_counterpart_prompt_omission_preserves_fresh_source () =
  with_fixture ~history_kind:Official (fun ~sw:_ fixture ->
    let previous=(Prompt_registry.resolve_prompt Prompt_names.librarian).override_value in
    Fun.protect ~finally:(fun () -> match previous with
      | None -> Prompt_registry.clear_prompt_override Prompt_names.librarian
      | Some value -> Prompt_registry.set_override Prompt_names.librarian value |> get) (fun () ->
      let speaker : Keeper_chat_store.speaker =
        {speaker_id=Some "external";speaker_name=Some "External";
         speaker_authority=Keeper_chat_store.External} in
      Keeper_chat_store.append_user_message ~base_dir:fixture.base_path ~keeper_name
        ~content:"Independent speaker evidence" ~speaker ();
      io (fun () ->
        official_turn fixture.config ~turn:2 ~time:(Time_compat.now () +. 10.);
        let session_dir=Keeper_fs.keeper_session_dir fixture.config trace_id in
        let path file=Keeper_turn_fragments.path ~session_dir file in
        write (path Keeper_turn_fragments.Main)
          ({|{"ts_unix":1.0,"role":"user","content_blocks":[{"type":"text","text":"old"}]}|} ^ "\n");
        write (path Keeper_turn_fragments.Internal) "");
      let official ()=io (fun () -> Keeper_librarian_official_progress.read
        ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_id:keeper_name
        |> Result.map_error Keeper_librarian_official_progress.read_error_to_string |> get) in
      let before=official () in
      Prompt_registry.set_override Prompt_names.librarian "Summarize the available history" |> get;
      (match run_worker fixture with
       | Error (Consumer.Original_publication_blocked detail) ->
         check bool "failure names the missing substitution" true
           (Astring.String.is_infix ~affix:"counterpart_observations" detail)
       | Error error -> fail (Consumer.error_to_string error)
       | Ok _ -> fail "a fresh original with the missing counterpart substitution was accepted");
      check int "no incomplete original was retained" 0 (List.length (observed_originals fixture));
      check int "no request reached the provider" 0 (F.post_count fixture.server);
      check bool "official position remains unread" true (official ()=before);
      let cursor=io (fun () -> Keeper_external_read_cursor.observe
        ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
      check int "external input was not acknowledged" 0 (Keeper_external_read_cursor.observation_offset cursor);
      check bool "the existing cursor preparation can remain pending" true
        (member "pending" (Keeper_external_read_cursor.observation_to_json cursor) <> `Null);
      no_memory fixture;
      Prompt_registry.clear_prompt_override Prompt_names.librarian;
      let observed=ref [] in
      fixture.set_response (fun capture ->
        observed := (Capture.source capture |> Source.input).counterpart_observations;
        `OK,F.openai_response (answer capture));
      drive_advanced fixture;
      check (list string) "restoring the prompt retries the preserved counterpart source"
        ["Independent speaker evidence";"Original admitted external evidence"]
        (List.map (fun (o:Keeper_counterpart_observation.t) -> o.content) !observed |> List.sort String.compare);
      let record,capture=only_original fixture in
      let source=Capture.source capture in
      let expected=Source.official_range_id source |> Option.get in
      check bool "Memory receipt names the corrected original's official range" true
        (io (fun () -> Current.committed_official_coverage ~keepers_dir:fixture.keepers_dir
          ~keeper_id:keeper_name ~receipt_scope:expected.receipt_scope |> get)=Some expected);
      check (list string) "the corrected provider result is committed to Memory"
        ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir));
      let through=Keeper_librarian_input_sources.external_through (Source.counterparts source) in
      check int "the corrected original reads the external admission" 1 through;
      let settled_cursor=io (fun () -> Keeper_external_read_cursor.observe
        ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
      check bool "the external admission is acknowledged through its original frontier" true
        (Keeper_external_read_cursor.observation_matches_preparation settled_cursor
          ~after:through ~through ~atom:None ~official:None);
      check bool "the original is finished after its receipt and ACK" true
        (match Progress.phase record.Owner.progress with Finished _ -> true
         | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
         | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
      check bool "successful recovery advances the official position" true (official ()<>before);
      check int "only the corrected prompt reached the provider" 1 (F.post_count fixture.server)))

let test_untagged_official_counterparts_reach_memory_once () =
  with_fixture ~history_kind:Official (fun ~sw:_ fixture ->
    let speaker : Keeper_chat_store.speaker =
      {speaker_id=Some "external";speaker_name=Some "External";
       speaker_authority=Keeper_chat_store.External} in
    Keeper_chat_store.append_user_message ~base_dir:fixture.base_path ~keeper_name
      ~content:"Independent speaker evidence" ~speaker ();
    let session_dir=Keeper_fs.keeper_session_dir fixture.config trace_id in
    io (fun () ->
      (* The second boundary ends after the appended chat. The pre-existing
         external fixture is also before it, and neither turn has a fragment
         that names its turn. *)
      official_turn fixture.config ~turn:2 ~time:(Time_compat.now () +. 10.);
      let path file=Keeper_turn_fragments.path ~session_dir file in
      write (path Keeper_turn_fragments.Main)
        ({|{"ts_unix":1.0,"role":"user","content_blocks":[{"type":"text","text":"old"}]}|} ^ "\n");
      write (path Keeper_turn_fragments.Internal) "");
    let official ()=io (fun () -> Keeper_librarian_official_progress.read
      ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_id:keeper_name
      |> Result.map_error Keeper_librarian_official_progress.read_error_to_string |> get) in
    let before=official () in
    let provider_calls=ref 0 in
    fixture.set_response (fun capture ->
      incr provider_calls;
      let input=Capture.source capture |> Source.input in
      check int "the provider original has no tagged messages" 0 (List.length input.messages);
      check int "the provider original has no tagged tool observations" 0 (List.length input.tool_observations);
      check (list string) "the provider original holds both independent observations"
        ["Independent speaker evidence";"Original admitted external evidence"]
        (List.map (fun (o:Keeper_counterpart_observation.t) -> o.content)
           input.counterpart_observations |> List.sort String.compare);
      `OK,F.openai_response (answer capture));
    drive_advanced fixture;
    let record,capture=only_original fixture in
    let source=Capture.source capture in
    let expected=Source.official_range_id source |> Option.get in
    check bool "the official receipt covers the original untagged turns" true
      (io (fun () -> Current.committed_official_coverage ~keepers_dir:fixture.keepers_dir
        ~keeper_id:keeper_name ~receipt_scope:expected.receipt_scope |> get)=Some expected);
    check bool "the original has no atom receipt" true (Option.is_none (Source.range_id source));
    check bool "official position advances after the receipt" true (official ()<>before);
    let cursor ()=io (fun () -> Keeper_external_read_cursor.observe
      ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
    let through=Keeper_librarian_input_sources.external_through (Source.counterparts source) in
    check int "one external admission was read" 1 through;
    check bool "the external admission was acknowledged" true
      (Keeper_external_read_cursor.observation_matches_preparation (cursor ())
        ~after:through ~through ~atom:None ~official:None);
    check bool "the actual original is finished" true
      (match Progress.phase record.Owner.progress with Finished _ -> true
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
       | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
    check (list string) "the provider result was published to Memory"
      ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir));
    check int "one actual provider request held the counterparts" 1 !provider_calls;
    let official_after=official () in
    (match run_worker fixture with
     | Ok Consumer.Nothing_to_read -> ()
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "a settled counterpart-only turn was read again");
    check bool "the next call leaves the official position" true (official ()=official_after);
    check bool "the next call leaves the external acknowledgement" true
      (Keeper_external_read_cursor.observation_matches_preparation (cursor ())
        ~after:through ~through ~atom:None ~official:None);
    check int "the next call makes no duplicate provider request" 1 (F.post_count fixture.server))

let test_production_queue_pending_retains_all_sources () = with_fixture (fun ~sw:_ fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
    `OK,F.openai_response (answer capture));
  let before=progress fixture in
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    ignore (Refresh.submit_durable ~base_path:fixture.base_path ~keeper_name);
    Eio.Promise.await arrived;
    Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
    (match Refresh.last_measurement ~config:fixture.config ~keeper_name with
     | Some measurement -> check bool "production queue observed actual durable Pending" true
         (match measurement.Refresh.last_pass with
          | Refresh.Pending _ -> true
          | Off | Lane_unconfigured | Drained | Yielded_to_waiting_unit
          | Not_committed | Stopped _ | Raised _ -> false)
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
      ignore (Refresh.submit_durable ~base_path ~keeper_name);
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
      ~configuration_revision:expected.configuration_revision ~original
      ~prepare_arguments:(fun ~max_reply_bytes ->
        Keeper_librarian_worker_request.prepare ~max_reply_bytes
          ~request_id:(Owner.Record.request_id original) ~tool:expected.tool ~arguments)
    |> Result.map_error Lane_addon_submit_once.call_error_of_runtime in
  Durable_owner.resume ~store:fixture.store ~config:fixture.config ~reserved:[]
    ~original:(Durable_owner.Read (original,request)) ~call
    ~wake:(fun () -> ()) ~publish:(fun ~original ~request ~proposal ->
      Keeper_librarian_durable_commit.For_testing.publish ~before_settlement ~store:fixture.store
        ~config:fixture.config ~original ~request ~proposal ~fresh_authority
      |> Result.map_error (fun detail -> Durable_owner.Rejected detail)))
let test_a_worker_call_reads_the_record_and_writes_nothing () = with_fixture (fun ~sw:_ fixture ->
  drive_advanced fixture;
  let original,capture=only_original fixture in
  let destination=Capture.destination capture in
  let root=Store.root fixture.store in
  let body=Filename.concat root
    (Store.tool_request_body_path ~scope:original.scope ~request_digest:original.request_digest) in
  let record=Filename.concat root (Filename.concat Store.tool_request_owners_directory
    (Filename.concat (Store.digest original.scope) (Store.digest original.request_id ^ ".json"))) in
  let call ()=Runtime.call_captured_tool_request ~config:fixture.config ~reserved:[] ~export:(runtime_export fixture)
    ~access:Lane_addon_sources.Operator_configuration ~installation_id:destination.installation_id
    ~package_id:destination.package_id ~tool:destination.tool
    ~configuration_revision:destination.configuration_revision ~original:(Owner.listed original)
    ~prepare_arguments:(fun ~max_reply_bytes ->
      Keeper_librarian_worker_request.prepare ~max_reply_bytes ~request_id:original.request_id
        ~tool:destination.tool ~arguments:(`Assoc ["kind",`String "read";"request_id",`String original.request_id])) in
  check bool "the fixture's original has a body and a record" true (Sys.file_exists body && Sys.file_exists record);
  Sys.remove body;
  check bool "the call reaches the worker without the body" true (Result.is_ok (call ()));
  check bool "and writes no body" false (Sys.file_exists body);
  Sys.remove record;
  check bool "an absent record is unavailable before the worker" true (match call () with
    | Error (Runtime.Unavailable _) -> true
    | Error (Runtime.Outcome_unknown _ | Runtime.Host_refusal _) | Ok _ -> false);
  check bool "and no record is written" false (Sys.file_exists record))
(* RFC librarian-waiting-pass-reads-records-not-bodies, section 8. The files of
   the one history original: its body, its record, its host Exact record and
   the proof of its latest execution. *)
let original_files fixture (original:Owner.retained) capture =
  let root=Store.root fixture.store in
  Filename.concat root (Store.tool_request_body_path ~scope:original.scope ~request_digest:original.request_digest),
  Filename.concat root (Filename.concat Store.tool_request_owners_directory
    (Filename.concat (Store.digest original.scope) (Store.digest original.request_id ^ ".json"))),
  Filename.concat root (Store.exact_request_path ~declaration_id:"librarian" ~request_id:original.request_id),
  proof_path fixture (Capture.request capture |> get)
let read_file path=io (fun () -> In_channel.with_open_bin path In_channel.input_all)
let refused_pass fixture detail=match run_worker fixture with
  | Error error -> Consumer.error_to_string error
  | Ok _ -> fail detail
let body_missing="original request body named by its record is missing"
(* An original admitted to its worker goes on as its record and index while
   its host record is open, so the pass reads no body. When the host record
   holds the answer, the pass reads the body before anything else. *)
let test_a_waiting_pass_reads_no_body () = with_fixture (fun ~sw:_ fixture ->
  let arrived,reached=Eio.Promise.create () and released,release=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve reached ());Eio.Promise.await released;
    `OK,F.openai_response (answer capture));
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve release ())) (fun () ->
  assert_pending (run_worker fixture);
  Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await arrived);
  let original,capture=only_original fixture in
  let body,record,_,_=original_files fixture original capture in
  let honest=read_file body and positions=progress fixture and posts=F.post_count fixture.server in
  io (fun () -> Sys.remove body);
  (match run_worker fixture with
   | Ok (Consumer.Pending (Keeper_librarian_pending.Worker {wait=Processing;request_id;_})) ->
     check string "the pass waits on the listed original" original.request_id request_id
   | Ok (Consumer.Pending _) -> fail "the waiting original did not reach its worker"
   | Ok (Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _) ->
     fail "the waiting original did not stay pending"
   | Error error -> fail (Consumer.error_to_string error));
  check bool "the waiting pass writes no body" false (io (fun () -> Sys.file_exists body));
  check int "and sends nothing more to the provider" posts (F.post_count fixture.server);
  (* The host answers and the worker never hears it. *)
  fixture.delivery_loss:=true;
  let delivered= !(fixture.deliveries) in
  ignore (Eio.Promise.try_resolve release ());
  await_delivery fixture ~after:delivered;
  let waited=read_file record in
  let missing=refused_pass fixture "a host answer was taken without the original's body" in
  check bool "the host answer needs the body" true (Astring.String.is_infix ~affix:body_missing missing);
  check string "the refused pass leaves the record as it was" waited (read_file record);
  check bool "and moves no read position" true (progress fixture=positions);
  no_memory fixture;
  io (fun () -> write body "{\"request\":\"another\"}");
  check bool "a body of other bytes is not the original's" true
    (Astring.String.is_infix ~affix:"original request body does not match its record's digest"
      (refused_pass fixture "a host answer was taken with another body"));
  io (fun () -> write body honest);
  let changed=match Yojson.Safe.from_string waited with
    | `Assoc fields -> `Assoc (List.map (fun (field,stored) -> match field,stored with
        | "summary",`Assoc summary -> field,`Assoc (List.map (fun (key,old) -> match key,old with
            | "destination",`Assoc destination -> key,`Assoc (List.map (fun (name,value) ->
                if name="configuration_revision" then name,`String "another-revision" else name,value) destination)
            | _ -> key,old) summary)
        | _ -> field,stored) fields)
    | _ -> fail "the original's record is not an object" in
  io (fun () -> write record (Yojson.Safe.to_string changed));
  let other_destination=refused_pass fixture "a host answer was taken under another destination" in
  check bool "a summary whose destination is not the body's is refused where the body is read" true
    (Astring.String.is_infix ~affix:"Original history index differs from its request" other_destination);
  io (fun () -> write record waited);
  check string "the refused passes leave the record as it was" waited (read_file record);
  check bool "and move no read position" true (progress fixture=positions);
  no_memory fixture))
(* The host record of a finished original can be gone: the deploy check
   deletes Exact records it cannot read. The worker's finished answer is then
   read after the body, so a missing body writes nothing. *)
let test_a_finished_worker_answer_reads_the_body_first () = with_fixture (fun ~sw:_ fixture ->
  let delivered= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  await_delivery fixture ~after:delivered;
  let original,capture=only_original fixture in
  let body,record,exact,proof=original_files fixture original capture in
  check bool "the host kept a record and a proof" true (io (fun () -> Sys.file_exists exact && Sys.file_exists proof));
  io (fun () -> Sys.remove exact;Sys.remove proof;Sys.remove body);
  let waited=read_file record and positions=progress fixture in
  let missing=refused_pass fixture "a finished answer was taken without the original's body" in
  check bool "the finished answer needs the body" true (Astring.String.is_infix ~affix:body_missing missing);
  check string "and the record stays as it was" waited (read_file record);
  check bool "no read position moves" true (progress fixture=positions);
  no_memory fixture)
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
     | Ok (Durable_owner.Resumed (Publication_waiting _,_)) -> ()
     | Ok (Waited _ | Original_replaced _ | Resumed ((Refused _ | Finished _ | Basis_superseded _ | Ended_unadmitted _),_)) ->
       fail "actual post-Memory cursor failure was not retained Pending"
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
let test_receipt_proved_partial_ack_keeps_source_locks_without_rereading_prefix () =
  with_fixture (fun ~sw:_ fixture ->
    fixture.delivery_loss:=true;
    let delivered= !(fixture.deliveries) in
    assert_pending (run_worker fixture);await_delivery fixture ~after:delivered;
    let original,request=only_original fixture in
    let positions=progress fixture and posts=F.post_count fixture.server in
    let proved_revision=ref None in
    let result=resume_with_settlement_fault fixture (fun () ->
      check bool "the partial settlement starts only after actual range receipts" true
        (io (fun () -> Keeper_librarian_durable_commit.receipt_state request |> get));
      proved_revision:=io (fun () -> Option.map (fun (snapshot:Current.t) -> snapshot.revision) (current fixture.keepers_dir));
      io (fun () -> Keeper_external_read_cursor.acknowledge
        ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get);
      check bool "external ACK can precede atom settlement" true (progress fixture=positions);
      (* Memory now owns the read prefix; acknowledgement must not need a
         second copy of it after retention has pruned the checkpoint. *)
      let turn=Ids.Turn_ref.absolute_turn (Source.input (Capture.source request)).turn_ref in
      save_checkpoint fixture.config ~trace_id [] turn;
      let session_dir=Keeper_fs.keeper_session_dir fixture.config trace_id in
      io (fun () -> Checkpoint.with_agent_core_exact_snapshot ~session_dir ~session_id:trace_id
        (fun snapshot -> check int "the canonical prefix was actually pruned" 0
          (List.length (Checkpoint.exact_snapshot_messages snapshot)))
        |> Result.map_error Checkpoint.checkpoint_ref_load_error_to_string |> get)) in
    (match result with
     | Ok (Durable_owner.Resumed (Finished completed,_)) ->
       check string "the same original finishes the partial settlement" original.request_id completed.Owner.request_id
     | Ok (Waited _ | Original_replaced _ | Resumed ((Refused _ | Publication_waiting _ | Basis_superseded _ | Ended_unadmitted _),_)) ->
       fail "receipt-proved partial ACK did not finish under the source locks"
     | Error error -> fail (Durable_owner.error_to_string error));
    check bool "partial settlement advances the original atom frontier" true (progress fixture<>positions);
    check bool "receipt-proved ACK writes no second Memory revision" true
      (!proved_revision=io (fun () -> Option.map (fun (snapshot:Current.t) -> snapshot.revision) (current fixture.keepers_dir)));
    check int "settlement dispatches no additional model request" posts (F.post_count fixture.server))
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
let restart_actual_worker ?(while_off=fun () -> ()) fixture ~sw =
  let old=(runtime_export fixture).Runtime.instance_id in
  let changed=Eio.Condition.create () in
  let stop=Runtime.subscribe_owner_events ~config:fixture.config ~package_id:Capture.package_id
    (fun (Configuration_observed | Export_inventory_changed | Exact_result_delivered _) ->
      Eio.Condition.broadcast changed) in
  Fun.protect ~finally:stop (fun () ->
    (* The actual maintenance owner's cleanup nudge schedules a new attach
       after the retiring entry is removed. No guessed poll/yield loop. *)
    Runtime.start_configuration_service ~config:fixture.config ~sw ~clock:fixture.clock;
    set_enabled fixture false;while_off ();set_enabled fixture true;
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
(* Writes [source] and waits for a worker of another incarnation than [old];
   [None] waits for the first one. *)
let await_configured_worker fixture ~sw ~old source =
  let changed=Eio.Condition.create () in
  let stop=Runtime.subscribe_owner_events ~config:fixture.config ~package_id:Capture.package_id
    (fun (Configuration_observed | Export_inventory_changed | Exact_result_delivered _) ->
      Eio.Condition.broadcast changed) in
  Fun.protect ~finally:stop (fun () ->
    Runtime.start_configuration_service ~config:fixture.config ~sw ~clock:fixture.clock;
    io (fun () -> write fixture.source source);reconcile fixture;
    Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
      Eio.Condition.loop_no_mutex changed (fun () ->
        let snapshot=Runtime.tool_export_snapshot ~config:fixture.config ~reserved:[]
          ~access:Lane_addon_sources.Operator_configuration in
        List.find_opt (fun (export:Runtime.tool_export) -> export.tool.name=Capture.tool
          && Some export.instance_id<>old) snapshot.exports)) |> ignore;
    reconcile fixture)
let replace_actual_worker_configuration fixture ~sw source =
  await_configured_worker fixture ~sw ~old:(Some (runtime_export fixture).Runtime.instance_id) source
(* The Add-on is off and no worker is attached. *)
let attach_actual_worker_configuration fixture ~sw source =
  await_configured_worker fixture ~sw ~old:None source
let test_answered_history_gate_follows_replacement ~foreign_installation () =
  with_fixture (fun ~sw fixture ->
    fixture.delivery_loss:=true;
    let delivered= !(fixture.deliveries) in
    assert_pending (run_worker fixture);await_delivery fixture ~after:delivered;
    let original,capture=only_original fixture in
    let captured=Capture.to_json capture and posts=F.post_count fixture.server and positions=progress fixture in
    let replacement=fixture.declaration true |> String.split_on_char '\n'
      |> List.map (function
        | "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-answered-gate\""
        | "id=\"librarian\"" when foreign_installation -> "id=\"different-librarian\""
        | line -> line) |> String.concat "\n" in
    io (fun () -> write fixture.source replacement);
    assert_pending (run_worker fixture);
    check bool "a changed file alone grants no Gate authority" true (progress fixture=positions);
    no_memory fixture;
    io (fun () -> write fixture.source (fixture.declaration true));reconcile fixture;
    replace_actual_worker_configuration fixture ~sw replacement;
    if foreign_installation then (
      assert_pending (run_worker fixture);
      no_memory fixture;
      check bool "a different installation cannot settle the original source" true (progress fixture=positions);
      check int "a different installation cannot prepare a Gate for this history answer" 0
        (List.length (gate_records fixture capture)))
    else (
      drive_advanced fixture;
      check (list string) "the retained answer commits through its Gate after replacement"
        ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir));
      check bool "only receipt-backed completion moves source progress" true (progress fixture<>positions);
      check int "the same history answer has exactly one Gate" 1 (List.length (gate_records fixture capture)));
    let current,restored=only_original fixture in
    check string "the original history ID remains authoritative" original.request_id current.request_id;
    check json "the complete source and original proposal input stay frozen" captured (Capture.to_json restored);
    check int "the answered history request is never sent to the replacement worker" posts (F.post_count fixture.server))

(* An official turn can have no turn-tagged fragments while its independent
   counterpart sources still have unread evidence. Exercise the configured
   Addon path, including the actual receipt and both source acknowledgements. *)
let test_counterpart_only_provider_capacity_refusal_is_source_preserving ~recover_partial_ack () =
  with_fixture ~history_kind:Official (fun ~sw fixture ->
    let content = "begin counterpart\n" ^ String.make 65536 'x' ^ "\nend counterpart" in
    let speaker : Keeper_chat_store.speaker =
      {speaker_id=Some "external";speaker_name=Some "External";
       speaker_authority=Keeper_chat_store.External} in
    Keeper_chat_store.append_user_message ~base_dir:fixture.base_path ~keeper_name
      ~conversation_id:"agent:original-chat" ~external_message_id:"original-chat-message"
      ~content ~speaker ();
    io (fun () ->
      official_turn fixture.config ~turn:2 ~time:(Time_compat.now () +. 10.);
      let session_dir=Keeper_fs.keeper_session_dir fixture.config trace_id in
      let path file=Keeper_turn_fragments.path ~session_dir file in
      write (path Keeper_turn_fragments.Main)
        ({|{"ts_unix":1.0,"role":"user","content_blocks":[{"type":"text","text":"old"}]}|} ^ "\n");
      write (path Keeper_turn_fragments.Internal) "");
    let official ()=io (fun () -> Keeper_librarian_official_progress.read
      ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_id:keeper_name
      |> Result.map_error Keeper_librarian_official_progress.read_error_to_string |> get) in
    let before=official () in
    let external_observation : Keeper_counterpart_observation.t =
      {origin=Connector_attention;channel="agent";workspace_id=None;
       user_id=Some "original-agent";user_name=Some "Original agent";
       authority=External;content="Original admitted external evidence"} in
    let chat_observation : Keeper_counterpart_observation.t =
      {origin=Durable_chat;channel="direct";workspace_id=None;
       user_id=Some "external";user_name=Some "External";
       authority=External;content} in
    let expected=[external_observation;chat_observation] in
    let observations capture =
      let input=Capture.source capture |> Source.input in
      List.map (fun (message : Agent_core.Types.message) ->
        message.role,Agent_core.Types.text_of_message message) input.messages,input.tool_observations,
        List.sort Stdlib.compare input.counterpart_observations in
    let check_complete ?(expected=expected) ~messages ~tools capture =
      let actual_messages,actual_tools,actual_counterparts=observations capture in
      check bool "the original retains all expected messages and roles" true (actual_messages=messages);
      check bool "the original retains all expected tool observations" true (actual_tools=tools);
      check bool "the original retains complete counterpart identities and bytes" true
        (actual_counterparts=List.sort Stdlib.compare expected) in
    let provider_inputs=ref [] in
    fixture.set_response (fun capture ->
      provider_inputs:= !provider_inputs @ [observations capture];
      `Request_entity_too_large,
        {|{"error":{"message":"fixture body too large","type":"invalid_request_error"}}|});
    let deliveries= !(fixture.deliveries) in
    assert_pending (run_worker fixture);
    await_delivery fixture ~after:deliveries;
    check bool "the refused HTTP input retains both original counterparts" true
      (!provider_inputs=[[],[],List.sort Stdlib.compare expected]);
    (match run_worker fixture with
     | Error (Consumer.Counterpart_input_capacity_refused {official_range;counterpart_digest;reports=[report];_} as refusal) ->
       check bool "capacity refusal suspends later Memory phases of the wake" true
         (Consumer.publication_unfinished refusal);
       check string "the refusal binds the exact counterpart digest"
         (Keeper_counterpart_observation.digest (Source.input (Capture.source (snd (only_original fixture)))).counterpart_observations)
         counterpart_digest;
       check bool "the host receipt names its actual provider input refusal" true
         (report.provider_input_refusals=[Keeper_librarian_input_refusal.Request_body_refused]);
       check bool "the operator can locate both original official rows" true
         (Option.map (fun (range:Current.official_range_id) -> List.map fst range.turns) official_range=Some [1;2])
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "a retained counterpart-only capacity refusal was not explicit");
    check bool "the refusal does not advance official history" true (official ()=before);
    let cursor ()=io (fun () -> Keeper_external_read_cursor.observe
      ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
    check bool "the refusal does not acknowledge the external row" true
      (Keeper_external_read_cursor.observation_matches_preparation (cursor ())
        ~after:0 ~through:1 ~atom:None
        ~official:(Source.official_range_id (Capture.source (snd (only_original fixture)))));
    no_memory fixture;
    let rejected,original=only_original fixture in
    check_complete ~messages:[] ~tools:[] original;
    let source_json=Source.to_json (Capture.source original) in
    let restored=Source.of_json source_json |> Result.map_error Source.error_to_string |> get in
    check json "the whole refused original survives strict restoration" source_json (Source.to_json restored);
    check int "only one actual provider request was refused" 1 (F.post_count fixture.server);
    let receipt_revision=if not recover_partial_ack then None else (
      let module Refusal=Keeper_librarian_durable_refusal in
      let completed=Refusal.inventory [rejected,original] |> get in
      let stop=Refusal.retained_stop ~store:fixture.store ~completed ~record:rejected ~request:original
        |> get |> Option.to_result ~none:"fixture has no actual permanent refusal stop" |> get in
      check bool "the ordinary refusal has a typed permanent diagnosis" true
        (Option.is_some (Refusal.diagnosis stop));
      let session_dir=Keeper_fs.keeper_session_dir fixture.config trace_id in
      let main=Keeper_turn_fragments.path ~session_dir Keeper_turn_fragments.Main in
      let internal=Keeper_turn_fragments.path ~session_dir Keeper_turn_fragments.Internal in
      check bool "the fixture has a real fragment prefix to prune" true
        (io (fun () -> Option.fold ~none:false ~some:(fun bytes -> bytes<>"")
          (Fs_compat.load_file_opt main)));
      let interrupted="fixture interrupted after range receipts and external ACK" in
      let result=memory_action fixture (fun () -> io (fun () ->
        Commit.For_testing.settle_refused ~store:fixture.store ~request:original ~record:rejected
          ~before_settlement:(fun () ->
            check bool "only actual refusal range receipts permit the partial ACK" true
              (Commit.receipt_state original |> get);
            Keeper_external_read_cursor.acknowledge
              ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get;
            let unchanged=Keeper_librarian_official_progress.read
              ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_id:keeper_name
              |> Result.map_error Keeper_librarian_official_progress.read_error_to_string |> get in
            check bool "official history is still unacknowledged at the interruption" true (unchanged=before);
            write main "";write internal "";
            check bool "the official fragment prefix was actually pruned" true
              (Fs_compat.load_file_opt main=Some "" && Fs_compat.load_file_opt internal=Some "");
            Error interrupted))) in
      (match result with Error detail -> check string "the real refusal settlement was interrupted" interrupted detail
       | Ok _ -> fail "the injected refusal settlement unexpectedly completed");
      let pending,_=only_original fixture in
      check bool "partial ACK records no final refusal settlement" true
        (Option.is_none (Progress.settlement pending.progress));
      check bool "partial ACK advances only the external frontier" true
        (Keeper_external_read_cursor.observation_offset (cursor ())=1 && official ()=before);
      Some (io (fun () -> Option.map (fun (snapshot:Current.t) -> snapshot.revision) (current fixture.keepers_dir)))) in
    (* The operator chose to end a permanent over-capacity refusal rather than
       block its destination for ever: the next wake abandons exactly that
       range, with a typed diagnosis, and the destination is free again. *)
    (match run_worker fixture with
     | Ok _ -> ()
     | Error error -> fail (Consumer.error_to_string error));
    Option.iter (fun revision -> check bool "ordinary refusal recovery repeats no Memory effect" true
      (revision=io (fun () -> Option.map (fun (snapshot:Current.t) -> snapshot.revision) (current fixture.keepers_dir)))) receipt_revision;
    (* A settled original leaves its scope for the settled day: the archive
       holds its progress, and nothing is left to retain or read. *)
    check int "a settled refusal leaves no retained original" 0 (List.length (observed_originals fixture));
    let settled_progress=archived fixture ~date:(day_of rejected.request_id) rejected in
    check bool "settlement leaves the refusal phase alone" true
      (Progress.phase settled_progress=Progress.phase rejected.progress);
    check bool "settlement keeps every earlier progress event in order" true
      (let before_events=Progress.events rejected.progress in
       List.filteri (fun index _ -> index<List.length before_events)
         (Progress.events settled_progress)=before_events);
    (match Progress.settlement settled_progress with
     | Some diagnosis ->
       check string "the diagnosis names its kind" "librarian-capacity-refusal-settled"
         (diagnosis |> member "kind" |> Yojson.Safe.Util.to_string);
       check string "the diagnosis names the abandoned request" rejected.request_id
         (diagnosis |> member "refused_request_id" |> Yojson.Safe.Util.to_string);
       check string "the diagnosis names the abandoned counterpart digest"
         (Keeper_counterpart_observation.digest
            (Source.input (Capture.source original)).counterpart_observations)
         (diagnosis |> member "counterpart_digest" |> Yojson.Safe.Util.to_string)
     | None -> fail "the permanent capacity refusal was not settled");
    check bool "official history reaches the end of the abandoned range" true (official ()<>before);
    check bool "the external row is acknowledged through the abandoned range" true
      (Keeper_external_read_cursor.observation_matches_preparation (cursor ())
        ~after:1 ~through:1 ~atom:None ~official:None);
    check int "settling the refusal sends no model request" 1 (F.post_count fixture.server);
    no_memory fixture;
    (* The durable state alone, readable while the Addon is detached. *)
    let check_state () =
      check int "a settled refusal sends no model request" 1 (F.post_count fixture.server);
      check int "a settled refusal stays out of the retained originals" 0
        (List.length (observed_originals fixture));
      check bool "the settlement survives every wake" true
        (Option.is_some (Progress.settlement (archived fixture ~date:(day_of rejected.request_id) rejected))) in
    let check_free () =
      (match run_worker fixture with
       | Ok Consumer.Nothing_to_read -> ()
       | Ok _ -> fail "a settled refusal must leave nothing to read"
       | Error error -> fail (Consumer.error_to_string error));
      check_state () in
    check_free ();
    Consumer.For_testing.reset_process_state ();
    restart_actual_worker ~while_off:check_state fixture ~sw;
    check_free ();
    let appended="Counterpart appended after the refusal" in
    (* The abandoned range ends at turn 2 (now+10): the later counterpart is
       recorded after it, then the next official turn closes the later range. *)
    let appended_time=Time_compat.now () +. 15. in
    let appended_item : Keeper_external_attention.item = {
      event_id=Keeper_external_attention.event_id_of_dedupe_key "appended-after-refusal";
      dedupe_key="appended-after-refusal";keeper_name;
      conversation={conversation_id="agent:appended-after-refusal";surface=Keeper_external_attention.Agent};
      external_message=Some {surface=Keeper_external_attention.Agent;message_id="appended-message";reply_to_message_id=None};
      source_label="agent";
      actor={actor_id=Some "external";display_name=Some "External";authority=Keeper_chat_store.External};
      urgency=Keeper_external_attention.Ambient;content_preview=appended;
      content_ref=None;received_at=appended_time;metadata=[]} in
    (match Keeper_external_attention.For_testing.record_with_clock
       ~now:(fun () -> appended_time) ~base_path:fixture.base_path appended_item with
     | `Recorded -> () | `Duplicate _ -> fail "the later counterpart was not recorded"
     | `Error detail -> fail detail);
    io (fun () -> official_turn fixture.config ~turn:3 ~time:(appended_time +. 10.));
    fixture.set_response (fun capture ->
      provider_inputs:= !provider_inputs @ [observations capture];
      `OK,F.openai_response (answer capture));
    drive_advanced fixture;
    let fresh,fresh_capture=observed_originals fixture
      |> List.filter (fun ((record:Owner.retained),_) -> record.request_id<>rejected.request_id)
      |> function [original] -> original | _ -> fail "one new original must own the later input" in
    check bool "the later original really finished" true
      (match Progress.phase fresh.progress with Finished _ -> true
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
       | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
    let _,_,fresh_counterparts=observations fresh_capture in
    check bool "the later input carries the counterpart appended after the refusal" true
      (List.exists (fun (observation:Keeper_counterpart_observation.t) ->
        observation.content=appended) fresh_counterparts);
    check bool "the abandoned oversized counterpart is never read again" false
      (List.exists (fun (observation:Keeper_counterpart_observation.t) ->
        observation.content=content) fresh_counterparts);
    check int "one refused and one successful request" 2 (F.post_count fixture.server);
    check bool "the settlement is untouched by the later original" true
      (Option.is_some (Progress.settlement (archived fixture ~date:(day_of rejected.request_id) rejected))))

(* The same projected chat observation can come from a different source row.
   The later delivery suppresses the refused row in the successful question's
   deduplication, while another chat row supplies the same displayed content. *)
let test_refusal_does_not_accept_a_different_equal_chat_row () =
  with_fixture ~history_kind:Official (fun ~sw fixture ->
    let module Sources = Keeper_librarian_input_sources in
    let content = "identical projected counterpart content" in
    let speaker : Keeper_chat_store.speaker =
      {speaker_id=Some "external";speaker_name=Some "External";
       speaker_authority=Keeper_chat_store.External} in
    Keeper_chat_store.append_user_message ~base_dir:fixture.base_path ~keeper_name
      ~conversation_id:"agent:source-identity" ~external_message_id:"original-message"
      ~content ~speaker ();
    Keeper_chat_store.append_user_message ~base_dir:fixture.base_path ~keeper_name
      ~content:"shared original counterpart" ~speaker ();
    io (fun () ->
      official_empty_turn fixture.config ~turn:2 ~time:(Time_compat.now () +. 10.);
      let session_dir=Keeper_fs.keeper_session_dir fixture.config trace_id in
      let path file=Keeper_turn_fragments.path ~session_dir file in
      write (path Keeper_turn_fragments.Main)
        ({|{"ts_unix":1.0,"role":"user","content_blocks":[{"type":"text","text":"old"}]}|} ^ "\n");
      write (path Keeper_turn_fragments.Internal) "");
    fixture.set_response (fun _ ->
      `Request_entity_too_large,
      {|{"error":{"message":"fixture body too large","type":"invalid_request_error"}}|});
    let deliveries= !(fixture.deliveries) in
    assert_pending (run_worker fixture);
    await_delivery fixture ~after:deliveries;
    (match run_worker fixture with
     | Error (Consumer.Counterpart_input_capacity_refused _) -> ()
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "expected the original counterpart capacity refusal");
    let rejected,original=only_original fixture in
    let original_source=Capture.source original in
    let original_snapshot=Source.counterparts original_source in
    let before=Sources.counterpart_snapshot_to_json original_snapshot
      |> member "before" |> Yojson.Safe.Util.to_float in
    Keeper_chat_store.append_user_message ~base_dir:fixture.base_path ~keeper_name
      ~content ~speaker ();
    let delivery_time=before +. 1. in
    let surface=Keeper_external_attention.Agent in
    let delivery : Keeper_external_attention.item = {
      event_id=Keeper_external_attention.event_id_of_dedupe_key "different-source-delivery";
      dedupe_key="different-source-delivery";keeper_name;
      conversation={conversation_id="agent:source-identity";surface};
      external_message=Some {surface;message_id="original-message";reply_to_message_id=None};
      source_label="agent";
      actor={actor_id=Some "external";display_name=Some "External";authority=Keeper_chat_store.External};
      urgency=Keeper_external_attention.Ambient;content_preview="separate delivery preview";
      content_ref=None;received_at=delivery_time;metadata=[]} in
    (match Keeper_external_attention.For_testing.record_with_clock
       ~now:(fun () -> delivery_time) ~base_path:fixture.base_path delivery with
     | `Recorded -> () | `Duplicate _ -> fail "the later delivery was not recorded"
     | `Error detail -> fail detail);
    io (fun () -> official_turn fixture.config ~turn:3 ~time:(delivery_time +. 10.));
    let sent_observations=ref None in
    fixture.set_response (fun capture ->
      sent_observations:=Some (Source.input (Capture.source capture)).counterpart_observations;
      `OK,F.openai_response (answer capture));
    let configured_b=fixture.declaration true |> String.split_on_char '\n'
      |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-capacity-retry\"" | line -> line)
      |> String.concat "\n" in
    replace_actual_worker_configuration fixture ~sw configured_b;
    drive_advanced fixture;
    let witness,witness_capture=observed_originals fixture
      |> List.filter (fun ((record:Owner.retained),_) -> record.request_id<>rejected.request_id)
      |> function [original] -> original | _ -> fail "expected one completed witness" in
    check bool "the later original really finished" true
      (match Progress.phase witness.progress with Finished _ -> true
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
       | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
    let witness_source=Capture.source witness_capture in
    let witness_snapshot=Source.counterparts witness_source in
    let witness_gates=gate_records fixture witness_capture |> List.filter (fun gate ->
      Gate.parent_execution_id gate |> get |> String.equal witness.request_id) in
    check bool "the partly overlapping completion has Gate evidence" true (witness_gates<>[]);
    let original_input=(Source.input original_source).counterpart_observations in
    let witness_input=(Source.input witness_source).counterpart_observations in
    let shared_rows snapshot =
      Sources.counterpart_snapshot_to_json snapshot |> member "chat_rows" |> Yojson.Safe.Util.to_list
      |> List.filter (fun row -> row |> member "raw_line" |> Yojson.Safe.Util.to_string
        |> Astring.String.is_infix ~affix:"shared original counterpart") in
    check int "the original captured the shared chat source once" 1
      (List.length (shared_rows original_snapshot));
    check int "the abandoned range's shared chat source is not read again" 0
      (List.length (shared_rows witness_snapshot));
    let equal_content_rows input=List.length (List.filter
      (fun (observation:Keeper_counterpart_observation.t) -> observation.content=content) input) in
    check int "the original input held the equal chat content once" 1 (equal_content_rows original_input);
    check int "the later input does not hold the abandoned row's content" 0 (equal_content_rows witness_input);
    check (list string) "the later input holds only the different delivery"
      ["separate delivery preview"]
      (List.map (fun (o:Keeper_counterpart_observation.t) -> o.content) witness_input);
    check bool "the same value does not establish the selected original row" false
      (Sources.counterpart_selection_covers ~original:(Sources.select_counterparts original_snapshot)
        ~witness:(Sources.select_counterparts witness_snapshot));
    check bool "the provider received the later selected projections" true
      (!sent_observations=Some witness_input);
    let exact=Capture.request witness_capture |> get in
    let rendered=Keeper_counterpart_observation.render_for_prompt witness_input in
    check bool "the exact question includes those selected projections" true
      (List.exists (fun (message:Exact.message) -> Astring.String.is_infix ~affix:rendered message.text)
        exact.messages);
    let cursor ()=io (fun () -> Keeper_external_read_cursor.observe
      ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
    check int "the successful input acknowledged its later delivery" 2
      (Keeper_external_read_cursor.observation_offset (cursor ()));
    check bool "the original source frontier is otherwise past" true
      (io (fun () -> Keeper_librarian_refusal_frontier.past_original original |> get));
    check int "a settled refusal leaves only the later original retained" 1
      (List.length (observed_originals fixture));
    check bool "the refusal was settled by abandoning its range" true
      (Option.is_some (Progress.settlement (archived fixture ~date:(day_of rejected.request_id) rejected)));
    replace_actual_worker_configuration fixture ~sw (fixture.declaration true);
    let calls=F.post_count fixture.server in
    (* While the Addon is detached no wake can run; only the durable state is readable. *)
    let check_state () =
      check int "the settled destination dispatches nothing" calls (F.post_count fixture.server) in
    let check_free () =
      (match run_worker fixture with
       | Ok Consumer.Nothing_to_read -> ()
       | Ok _ -> fail "returning to a settled destination must leave nothing to read"
       | Error error -> fail (Consumer.error_to_string error));
      check_state () in
    check_free ();
    Consumer.For_testing.reset_process_state ();
    restart_actual_worker ~while_off:check_state fixture ~sw;
    check_free ())

let test_purge_joins_unknown_then_worker_restart_does_not_resubmit history_kind () =
  with_fixture ~history_kind (fun ~sw fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  let child_arrived,child_signal=Eio.Promise.create () and child_release,unblock_child=Eio.Promise.create () in
  let provider_ids=ref [] in
  fixture.set_response (fun capture ->
    let first=match !provider_ids with [] -> true | _::_ -> false in
    provider_ids:=Capture.request_id capture :: !provider_ids;
    if first then (ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release)
    else (ignore (Eio.Promise.try_resolve child_signal ());Eio.Promise.await child_release);
    `OK,F.openai_response (answer capture));
  Fun.protect ~finally:(fun () ->
    ignore (Eio.Promise.try_resolve unblock ());ignore (Eio.Promise.try_resolve unblock_child ())) (fun () ->
    assert_pending (run_worker fixture);Eio.Promise.await arrived;
    let record,capture=only_original fixture in
    let original=Capture.to_json capture and before=progress fixture in
    let source=Capture.source capture in
    check int "unknown work retains actual external evidence" 1
      (Keeper_librarian_input_sources.external_through (Source.counterparts source));
    let runtime_keepers_dir=Workspace.keepers_runtime_dir fixture.config in
    let cursor ()=io (fun () -> Keeper_external_read_cursor.observe
      ~runtime_keepers_dir ~keeper_name |> get) in
    check json "the original external preparation is actually pending"
      (Keeper_external_read_cursor.observation_to_json (Source.external_prepared source))
      (Keeper_external_read_cursor.observation_to_json (cursor ()));
    check int "the pending external evidence is not acknowledged" 0
      (Keeper_external_read_cursor.observation_offset (cursor ()));
    let state_paths=[
      Current.path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name;
      Current.journal_path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name;
      Current.durable_range_receipt_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name;
      Current.publication_receipt_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name;
      Keeper_librarian_continuity.path ~config:fixture.config ~keeper_name;
      Keeper_external_read_cursor.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name;
      Keeper_librarian_official_progress.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name] in
    let state ()=io (fun () -> List.map (fun path -> path,Fs_compat.load_file_opt path) state_paths) in
    let before_state=state () in
    let posts=F.post_count fixture.server and before_delivery= !(fixture.deliveries) in
    check int "actual provider remains registered after ordinary unit returned" 1
      (Memory_lane.For_testing.external_active ~base_path:fixture.base_path ~keeper_name);
    (match Memory_lane.with_librarian_purge ~base_path:fixture.base_path ~keeper_name (fun () ->
      check int "purge callback follows actual provider cancellation and unwind" 0
        (Memory_lane.For_testing.external_active ~base_path:fixture.base_path ~keeper_name)) with
     | Ok () -> () | Error error -> fail (Memory_lane.purge_cancel_error_to_string error));
    ignore (Eio.Promise.try_resolve unblock ());
    no_memory fixture;
    restart_actual_worker fixture ~sw;
    await_delivery fixture ~after:before_delivery;
    let exact=Capture.request capture |> get in
    let schema=match exact.Exact.schema with
      | Some schema -> schema | None -> fail "unknown original has no schema" in
    let actual_unknown ()=
      match io (fun () -> Exact.observe_retained ~store:fixture.store
        ~declaration_id:"librarian" ~schema exact |> get) with
      | Exact.Retained_terminal (Exact.Retained_unknown (Interrupted | Cut | Raised) as retained) -> retained
      | Retained_absent | Retained_open
      | Retained_terminal (Retained_call _ | Retained_not_allowed _ | Retained_request_id_reused) ->
        fail "the actual host must retain terminal Outcome_unknown before testing later wakes" in
    let original_host_final=actual_unknown () in
    (match original_host_final with
     | Exact.Retained_unknown Cut -> ()
     | Retained_unknown (Interrupted | Raised) | Retained_call _ | Retained_not_allowed _ | Retained_request_id_reused ->
       fail "the joined same-incarnation purge did not retain its actual Cut");
    let assert_actual_unknown ()=check json "the host's unknown cause stays original"
      (Exact.retained_final_to_json original_host_final) (Exact.retained_final_to_json (actual_unknown ())) in
    let load_original request_id=io (fun () ->
      let retained=Owner.load ~store:fixture.store ~scope:record.scope ~request_id |> owned
        |> Option.to_result ~none:"the exact retained history request disappeared" |> get in
      retained,Capture.restore ~owner:(Capture.physical_owner capture) retained |> get) in
    (* The ordinary owner retains the root Cut and prepares its authorized
       continuation. It does not recursively dispatch that child here. *)
    assert_pending (run_worker fixture);
    let retained_unknown,_=load_original record.request_id in
    (match Progress.phase retained_unknown.Owner.progress with
     | Rejected {stage=Execution;evidence} ->
       check json "original refusal retains the actual host unknown terminal"
         (Exact.retained_final_to_json original_host_final) evidence
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Rejected {stage=Before_dispatch;_} | Subdividing _ | Subdivided _ ->
       fail "the actual terminal was not retained on its original execution");
    let unknown_progress=Progress.to_json retained_unknown.progress in
    let read_intent ()=match io (fun () -> Resolution_intent.read ~config:fixture.config ~keeper_name
      ~request_id:record.request_id |> Result.map_error Resolution_intent.error_to_string |> get) with
      | [intent] -> intent
      | [] | _::_::_ -> fail "the Cut does not retain exactly one resolution command" in
    let intent=read_intent () in
    let child=match intent.phase with
      | Resolution_intent.Child_confirmed child -> child
      | Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _ ->
        fail "the actual Cut has no confirmed continuation" in
    (match intent.origin with Same_binding_cut _ -> () | Worker_absence -> fail "the Cut acquired absence authority");
    let child_record,child_request=load_original child.request_id in
    let child_body=Capture.to_json child_request in
    check bool "the continuation waits for a later unit before dispatch" true (Progress.phase child_record.progress=Captured);
    check bool "the continuation names the actual Cut predecessor" true
      (Capture.predecessor child_request=Some {Capture.request_id=record.request_id;request_digest=record.request_digest});
    check json "the continuation keeps the complete original source basis"
      (Source.basis_json source) (Source.basis_json (Capture.source child_request));
    io (fun () -> Keeper_librarian_history_resolution_lineage.confirm_predecessor_by_body
      ~store:fixture.store ~require_confirmed:true child_request) |> get;
    let assert_preserved ~child_started ()=
      assert_actual_unknown ();
      let reopened,restored=load_original record.request_id in
      check string "all wakes keep the original unknown ID" record.request_id reopened.Owner.request_id;
      check json "all wakes keep its complete input and preparation" original (Capture.to_json restored);
      check json "later wakes never rewrite the terminal original" unknown_progress (Progress.to_json reopened.progress);
      check bool "the pending continuation never acknowledges checkpoint history" true (progress fixture=before);
      check (list (pair string (option string))) "the pending continuation keeps Memory, WAL and source preparations exact"
        before_state (state ());
      check bool "unknown grants no absorption judgment" true
        (io (fun () -> Keeper_librarian_durable_gate.root ~store:fixture.store
          ~owner:(Capture.physical_owner capture) ~capture |> get |> Option.is_none));
      let current=read_intent () in
      check string "all wakes reuse the same Cut command" intent.intent_id current.intent_id;
      check bool "all wakes reuse its one confirmed child without completion" true
        (Resolution_intent.child current=Some child && current.memory_commit=None);
      let current_child,restored_child=load_original child.request_id in
      check string "the child body keeps its retained digest" child.request_digest current_child.request_digest;
      check json "all wakes keep the complete child question" child_body (Capture.to_json restored_child);
      check int "only the root and its authorized continuation remain" 2 (List.length (observed_originals fixture));
      check int "no wake replays the original provider request" 1
        (List.length (List.filter (String.equal record.request_id) !provider_ids));
      check int "the same child is sent only after its next unit" (if child_started then 1 else 0)
        (List.length (List.filter (String.equal child.request_id) !provider_ids));
      check int "no unrelated provider request is introduced" (posts+(if child_started then 1 else 0))
        (F.post_count fixture.server);
      no_memory fixture in
    let ordinary_wake ()=
      ignore (Refresh.submit_durable ~base_path:fixture.base_path ~keeper_name);
      Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
      (match Refresh.last_measurement ~config:fixture.config ~keeper_name with
       | Some measurement -> check bool "production wake retains terminal unknown as Pending" true
           (match measurement.Refresh.last_pass with
          | Refresh.Pending _ -> true
          | Off | Lane_unconfigured | Drained | Yielded_to_waiting_unit
          | Not_committed | Stopped _ | Raised _ -> false)
       | None -> fail "production wake did not report its durable result") in
    assert_preserved ~child_started:false ();
    (* Restart after both the root Cut and child publication are durable,
       before the child's first dispatch. Recovery must reuse that exact ID. *)
    restart_actual_worker fixture ~sw;
    assert_preserved ~child_started:false ();
    ordinary_wake ();Eio.Promise.await child_arrived;
    assert_preserved ~child_started:true ();
    ordinary_wake ();
    assert_preserved ~child_started:true ();
    ordinary_wake ();
    assert_preserved ~child_started:true ();
    set_enabled fixture false;
    (match run_worker fixture with
     | Ok (Consumer.Pending _) | Error (Original_publication_blocked _) -> ()
     | Error error -> fail (Consumer.error_to_string error)
     | Ok (Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _) ->
       fail "a disabled pending continuation released its source");
    assert_preserved ~child_started:true ()))
(* Observe the actual retained host ending through its owner, before the
   execution consumer's separate automatic continuation ingress. *)
let observe_retained_cut fixture =
  let original=only_original fixture in
  let result=memory_action fixture (fun () -> Durable_owner.resume ~store:fixture.store
    ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ())
    ~original:(Durable_owner.Read original)
    ~call:(fun ~expected:_ ~original:_ ~arguments:_ -> fail "retained Cut replayed its original RPC")
    ~publish:(fun ~original:_ ~request:_ ~proposal:_ -> fail "retained Cut published Memory")
    ~wake:(fun () -> ())) |> Result.map_error Durable_owner.error_to_string |> get in
  match result with
  | Durable_owner.Waited (Worker_unknown,_) -> ()
  | Waited ((Worker_pending | Worker_unreachable | Missing_after_dispatch | Journal_recheck),_)
  | Resumed _ | Original_replaced _ -> fail "actual host Cut did not remain a retained unknown"
let test_cut_replacement_releases_unread_source_and_survives_rollback () = with_fixture (fun ~sw fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
    `OK,F.openai_response (answer capture));
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    assert_pending (run_worker fixture);Eio.Promise.await arrived;
    let _,capture=only_original fixture in
    let source=Capture.source capture and exact=Capture.request capture |> get in
    let positions=progress fixture in
    let cursor ()=io (fun () -> Keeper_external_read_cursor.observe
      ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get)
      |> Keeper_external_read_cursor.observation_to_json in
    let cursor_before=cursor () and delivered= !(fixture.deliveries) in
    (match Memory_lane.with_librarian_purge ~base_path:fixture.base_path ~keeper_name (fun () -> ()) with
     | Ok () -> () | Error error -> fail (Memory_lane.purge_cancel_error_to_string error));
    ignore (Eio.Promise.try_resolve unblock ());
    fixture.set_response (fun capture -> `OK,F.openai_response (answer capture));
    restart_actual_worker fixture ~sw;
    await_delivery fixture ~after:delivered;
    let wakes=ref 0 in
    let pass ()=memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name
      ~wake:(fun () -> incr wakes)) in
    observe_retained_cut fixture;
    let cut,_=only_original fixture in
    (match Progress.phase cut.progress with
     | Progress.Rejected {stage=Execution;evidence} ->
       let schema=Option.to_result ~none:"cut original schema" exact.schema |> get in
       check bool "the actual cancelled provider leaves a host Cut refusal" true
         ((Exact.retained_final_of_json ~schema evidence |> get) = Exact.Retained_unknown Exact.Cut)
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Rejected {stage=Before_dispatch;_} | Subdividing _ | Subdivided _ ->
       fail "the actual interrupted worker did not leave an execution refusal");
    observe_retained_cut fixture;
    check int "the retained owner never wakes a Cut replay" 0 !wakes;
    let replacement=fixture.declaration true |> String.split_on_char '\n'
      |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-cut-replacement\"" | line -> line)
      |> String.concat "\n" in
    io (fun () -> write fixture.source replacement);
    assert_pending (pass ());
    check int "a changed file without its ready worker grants no Cut replay" 0 !wakes;
    io (fun () -> write fixture.source (fixture.declaration true));
    replace_actual_worker_configuration fixture ~sw replacement;
    let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
      |> Result.map_error Lane_addon_manifest.error_to_string |> get in
    let claimed,signal_claimed=Eio.Promise.create () and allow,signal_allow=Eio.Promise.create () in
    let finished,signal_finished=Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      let outcome=Exact.run ~store:fixture.store ~declaration_id:"librarian" ~package
        ~runner:(Server_lane_addon_exact.runner ~base_path:fixture.base_path)
        ~authorize_request:(fun ~store:_ ~declaration_id:_ ~package:_ _ ->
          Eio.Promise.resolve signal_claimed ();Eio.Promise.await allow;
          Error (Exact.Undecided {detail="fixture releases its retained-final claim"})) exact in
      Eio.Promise.resolve signal_finished outcome);
    Eio.Promise.await claimed;
    let proof=proof_path fixture exact in
    let original_proof=io (fun () -> Fs_compat.load_file_opt proof) in
    io (fun () -> Fs_compat.mkdir_p (Filename.dirname proof);write proof "unreadable original execution proof");
    (match pass () with
     | Error (Consumer.Original_publication_blocked _) -> ()
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "an active host claim hid an unreadable execution proof and authorized Cut replay");
    check int "an unreadable proof under an active claim grants no wake" 0 !wakes;
    check int "an unreadable proof under an active claim grants no provider replay" 1 (F.post_count fixture.server);
    io (fun () -> match original_proof with Some bytes -> write proof bytes | None -> Sys.remove proof);
    Eio.Promise.resolve signal_allow ();
    (match Eio.Promise.await finished with Error _ -> ()
     | Ok _ -> fail "the held retained-final claim unexpectedly dispatched or changed the original");
    (match pass () with
     | Ok (Consumer.Memory_not_committed _) -> ()
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "a ready replacement did not release its Cut original");
    let ended,_=only_original fixture in
    check bool "the original Cut evidence is never rewritten" true
      (Progress.phase cut.progress=Progress.phase ended.progress);
    check bool "the separate source-unconsumed disposition is durable" true
      (Option.is_some (Progress.settlement ended.progress));
    check int "preflight accepts the same strict Cut disposition as inventory" 0
      (List.length (librarian_refusals fixture));
    let host=io (fun () -> Store.load_exact_request fixture.store ~declaration_id:"librarian"
      ~request_id:exact.request_id |> get |> Option.get) in
    let raised_host=match host with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
          key,if key="attempts" then `List [`Assoc ["status",`String "outcome_unknown";
            "cause",`String "raised";"exception",`String "fixture retained another host cause"]] else value) fields)
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "expected host record" in
    let schema=Option.to_result ~none:"Cut original schema" exact.schema |> get in
    check bool "the other typed cause has the same delivered outcome but decodes as Raised" true
      ((Exact.observe_record ~declaration_id:"librarian" ~schema exact (Some raised_host) |> get)
        =Exact.Retained_terminal (Exact.Retained_unknown Exact.Raised));
    io (fun () -> Store.save_exact_request fixture.store ~declaration_id:"librarian"
      ~request_id:exact.request_id raised_host |> get);
    check bool "preflight cannot confirm Cut replacement through a Raised host ending" true
      (List.exists (fun (refusal:Lane_addon_store_preflight.refusal) ->
        refusal.decoder=Lane_addon_store_preflight.Tool_request_exact_reads) (librarian_refusals fixture));
    check bool "inventory also refuses a different typed host ending" true
      (Result.is_error (io (fun () -> Commit.validate ~store:fixture.store ~request:capture ~record:ended)));
    io (fun () -> Store.save_exact_request fixture.store ~declaration_id:"librarian"
      ~request_id:exact.request_id host |> get);
    check int "the completed disposition wakes the next pass" 1 !wakes;
    check bool "Cut release advances no read position" true (progress fixture=positions);
    check json "Cut release advances no external ACK" cursor_before (cursor ());
    no_memory fixture;
    check int "recording the disposition does not repeat the old provider call" 1 (F.post_count fixture.server);
    let retained=Owner.record_to_json (Owner.listed ended) in
    let field name update = function
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,if key=name then update value else value) fields)
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "expected an owner evidence object" in
    let corrupt=field "progress" (function
      | `List events -> `List (List.map (fun event ->
          if member "event" event=`String "refusal_settled" then
            field "evidence" (field "replacement" (fun _ ->
              Lane_addon_captured_destination.to_json (Capture.destination capture))) event
          else event) events)
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> fail "expected progress events") retained in
    io (fun () -> Store.save_tool_request_owner fixture.store ~scope:ended.scope ~request_id:ended.request_id corrupt |> get);
    check bool "preflight refuses a Cut disposition without a replacement declaration" true
      (List.exists (fun (refusal:Lane_addon_store_preflight.refusal) ->
        refusal.decoder=Lane_addon_store_preflight.Tool_request_payload) (librarian_refusals fixture));
    (match pass () with
     | Error (Consumer.Original_publication_blocked _) -> ()
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "a stored disposition without a different declaration authorized replay");
    check int "invalid stored evidence creates no wake" 1 !wakes;
    check int "invalid stored evidence creates no provider replay" 1 (F.post_count fixture.server);
    check bool "invalid stored evidence consumes no source" true (progress fixture=positions);
    io (fun () -> Store.save_tool_request_owner fixture.store ~scope:ended.scope ~request_id:ended.request_id retained |> get);
    replace_actual_worker_configuration fixture ~sw (fixture.declaration true);
    check bool "inventory uses the stored disposition after rollback" true
      ((io (fun () -> Commit.validate ~store:fixture.store ~request:capture ~record:ended) |> get) = Commit.Settled);
    drive_advanced fixture;
    let fresh,fresh_capture=only_original fixture in
    check bool "the released source gets a new original ID" true (fresh.request_id<>cut.request_id);
    check bool "the new original retains the whole unread history" true
      ((Source.input (Capture.source fresh_capture)).messages=(Source.input source).messages);
    check bool "the new original retains the unread counterpart input" true
      ((Source.input (Capture.source fresh_capture)).counterpart_observations=(Source.input source).counterpart_observations);
    check bool "the new original is not narrowed by the old Cut" true
      (Source.extent (Capture.source fresh_capture)=Keeper_librarian_range.All_unread);
    check bool "the archive retains why the old original was released" true
      (Option.is_some (Progress.settlement (archived fixture ~date:(day_of cut.request_id) cut)));
    check int "one cancelled original and one authorized fresh provider call" 2 (F.post_count fixture.server)))

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
let retain_absent_history_original ?(failed_selection=true) ?(admitted=true) fixture =
  let captured = ref None in
  (match memory_action fixture (fun () -> Consumer.consume_one ~config:fixture.config ~keeper_name
    ~commit:(fun source -> captured := Some source;
      if failed_selection then Consumer.Memory_refused [] else Consumer.Memory_replaced [])) with
   | Ok (Consumer.Memory_not_committed _) -> ()
   | Ok (Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Pending _)
   | Error _ -> fail "fixture did not retain an unread history source");
  let source = Option.to_result ~none:"missing fixture source" !captured |> get in
  let owner = io (fun () ->
    ignore (Current.capture_program_anchor ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get);
    Capture.observe_owner ~base_path:fixture.base_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get) in
  let preparation = Keeper_librarian_runtime.prepare_durable ~source_lines:[] ~now:(Time_compat.now ()) (Source.input source) |> get in
  let destination = Keeper_librarian_durable_edge.with_destination ~config:fixture.config
    ~reserved:(Keeper_librarian_durable_edge.reserved ()) (fun destination -> Ok destination) |> get in
  let request = io (fun () -> Capture.create ~request_id:(Capture.fresh_request_id owner)
    ~owner ~destination ~source ~preparation ()) |> get in
  let original = memory_action fixture (fun () -> Durable_owner.retain ~store:fixture.store request)
    |> Result.map_error Durable_owner.error_to_string |> get in
  let advance original event = io (fun () ->
    match Owner.advance ~store:fixture.store ~expected:original ~event with
    | Ok (Owner.Stored original | Already_stored original) -> original
    | Ok (Unconfirmed detail) -> fail detail
    | Error error -> fail (Owner.update_error_to_string error)) in
  let original = if admitted then (
    let original = advance original Progress.Dispatch_intended in
    advance original (Progress.Execution_observed (Progress.Absent (`Assoc [])))) else original in
  original, request
let test_replaced_raised_original_stays_unknown () = with_fixture (fun ~sw fixture ->
  let original,capture=retain_absent_history_original ~failed_selection:false fixture in
  let exact=Capture.request capture |> get in
  io (fun () ->
    Store.save_exact_request fixture.store ~declaration_id:"librarian" ~request_id:exact.request_id
      (`Assoc ["declaration_id",`String "librarian";"request_id",`String exact.request_id;
        "digest",`String (Exact.digest exact);"request",Exact.request_to_json exact;
        "attempts",`List [`Assoc ["status",`String "outcome_unknown";"cause",`String "raised";
          "exception",`String "fixture raised after dispatch"]];"final",Exact.final_to_json Exact.Outcome_unknown]) |> get);
  let raised=memory_action fixture (fun () -> io (fun () ->
    match Owner.advance ~store:fixture.store ~expected:original
      ~event:(Progress.Refused {stage=Execution;
        evidence=Exact.retained_final_to_json (Exact.Retained_unknown Exact.Raised)}) with
    | Ok (Owner.Stored record | Already_stored record) -> record
    | Ok (Unconfirmed detail) -> fail detail
    | Error error -> fail (Owner.update_error_to_string error))) in
  let replacement=fixture.declaration true |> String.split_on_char '\n'
    |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-raised-replacement\"" | line -> line)
    |> String.concat "\n" in
  replace_actual_worker_configuration fixture ~sw replacement;
  let wakes=ref 0 in
  assert_pending (memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name
    ~wake:(fun () -> incr wakes)));
  let actual,_=only_original fixture in
  check json "Raised keeps its original evidence and no release disposition"
    (Progress.to_json raised.progress) (Progress.to_json actual.progress);
  check int "Raised grants no replacement wake" 0 !wakes;
  check int "Raised grants no provider replay" 0 (F.post_count fixture.server))
let test_unadmitted_replacement_needs_no_body_and_survives_rollback ~capacity_wait () =
  with_fixture (fun ~sw fixture ->
    let original,request=retain_absent_history_original ~failed_selection:false ~admitted:false fixture in
    let advance original event=io (fun () -> match Owner.advance ~store:fixture.store ~expected:original ~event with
      | Ok (Owner.Stored original | Already_stored original) -> original
      | Ok (Unconfirmed detail) -> fail detail
      | Error error -> fail (Owner.update_error_to_string error)) in
    let original=if capacity_wait then (
      let original=advance original Progress.Dispatch_intended in
      advance original (Progress.Admission_declined (`Assoc ["state",`String "capacity_wait"]))) else original in
    let original_record=Owner.listed original in
    let original_input=Source.input (Capture.source request) in
    let positions=progress fixture in
    let cursor ()=io (fun () -> Keeper_external_read_cursor.observe
      ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get)
      |> Keeper_external_read_cursor.observation_to_json in
    let cursor_before=cursor () in
    let body=Filename.concat (Store.root fixture.store)
      (Store.tool_request_body_path ~scope:original.scope ~request_digest:original.request_digest) in
    io (fun () -> write body "unreadable original body";
      write fixture.source (fixture.declaration false));
    check bool "an unended original still needs its body at deploy" true
      (librarian_refusals fixture<>[]);
    let wakes=ref 0 in
    let pass ()=memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name
      ~wake:(fun () -> incr wakes)) in
    assert_pending (pass ());
    check int "an unavailable fresh declaration creates no replacement wake" 0 !wakes;
    let held ()=io (fun () -> Owner.load_record ~store:fixture.store ~scope:original.scope
      ~request_id:original.request_id |> owned |> Option.get) in
    check json "waiting never changes the unadmitted original" (Progress.to_json original.progress)
      (Progress.to_json (Owner.Record.progress (held ())));
    io (fun () -> write fixture.source (fixture.declaration true));
    let replacement=fixture.declaration true |> String.split_on_char '\n'
      |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-replacement\"" | line -> line)
      |> String.concat "\n" in
    replace_actual_worker_configuration fixture ~sw replacement;
    (match pass () with
     | Ok (Consumer.Memory_not_committed _) -> ()
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "a ready replacement did not end the unadmitted original without its body");
    check int "only confirmed replacement wakes the next pass" 1 !wakes;
    check bool "the replacement refusal binds both original destinations" true
      (Keeper_librarian_declaration_replacement.retained ~original:(held ())
        ~captured:(Capture.destination request) |> get);
    check bool "before-admission replacement advances no source position" true (progress fixture=positions);
    check json "before-admission replacement advances no external ACK" cursor_before (cursor ());
    check int "the unadmitted original was never dispatched" 0 (F.post_count fixture.server);
    no_memory fixture;
    let accepts_ending label=check int label 0 (List.length (librarian_refusals fixture)) in
    accepts_ending "deploy accepts the runtime-recoverable ending with a damaged body";
    io (fun () -> Sys.remove body);
    accepts_ending "deploy accepts the same ending with no body";
    io (fun () -> write fixture.source (fixture.declaration false));
    accepts_ending "a stored ending does not need a currently enabled declaration";
    replace_actual_worker_configuration fixture ~sw (fixture.declaration true);
    accepts_ending "declaration rollback preserves the stored ending at deploy";
    drive_advanced fixture;
    let fresh,capture=only_original fixture in
    check bool "rollback creates a separate original instead of reviving the old one" true
      (fresh.request_id<>Owner.Record.request_id original_record);
    check bool "the fresh original retains the full unread history" true
      ((Source.input (Capture.source capture)).messages=original_input.messages);
    check bool "the fresh original retains all counterpart input" true
      ((Source.input (Capture.source capture)).counterpart_observations=original_input.counterpart_observations);
    (match Progress.phase (archived fixture ~date:(day_of original.request_id) original) with
     | Progress.Rejected {stage=Before_dispatch;_} -> ()
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Rejected {stage=Execution;_} | Subdividing _ | Subdivided _ ->
       fail "the original refusal was not archived without its body");
    check int "only the fresh original reaches a provider" 1 (F.post_count fixture.server))
let test_unadmitted_replacement_preserves_existing_host_execution () = with_fixture (fun ~sw fixture ->
  let original,request=retain_absent_history_original ~failed_selection:false ~admitted:false fixture in
  let exact=Capture.request request |> get in
  io (fun () -> Store.save_exact_request fixture.store ~declaration_id:"librarian" ~request_id:exact.request_id
    (`Assoc ["declaration_id",`String "librarian";"request_id",`String exact.request_id;
      "digest",`String (Exact.digest exact);"request",Exact.request_to_json exact;
      "attempts",`List [`Assoc ["started",`String "0123456789abcdef0123456789abcdef"]];"final",`Null]) |> get);
  let replacement=fixture.declaration true |> String.split_on_char '\n'
    |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-replacement\"" | line -> line)
    |> String.concat "\n" in
  replace_actual_worker_configuration fixture ~sw replacement;
  let positions=progress fixture and wakes=ref 0 in
  (match memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name
     ~wake:(fun () -> incr wakes)) with
   | Error (Consumer.Original_publication_blocked _) -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "an original with host execution evidence was replaced before admission");
  let held=io (fun () -> Owner.load_record ~store:fixture.store ~scope:original.scope
    ~request_id:original.request_id |> owned |> Option.get) in
  check json "host execution uncertainty leaves the original phase intact"
    (Progress.to_json original.progress) (Progress.to_json (Owner.Record.progress held));
  check int "uncertain execution grants no replacement wake" 0 !wakes;
  check int "uncertain execution grants no provider replay" 0 (F.post_count fixture.server);
  check bool "uncertain execution advances no source position" true (progress fixture=positions);
  no_memory fixture)
let test_preflight_preserves_before_dispatch_ending_evidence () = with_fixture (fun ~sw fixture ->
  let original,request=retain_absent_history_original ~failed_selection:false ~admitted:false fixture in
  let exact=Capture.request request |> get in
  let replacement=fixture.declaration true |> String.split_on_char '\n'
    |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-preflight-replacement\"" | line -> line)
    |> String.concat "\n" in
  replace_actual_worker_configuration fixture ~sw replacement;
  (match run_worker fixture with
   | Ok (Consumer.Memory_not_committed _) -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "fixture did not retain its before-dispatch ending");
  let ended=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
    ~request_id:original.request_id |> owned |> Option.get) in
  check int "no host record or proof is valid before dispatch" 0 (List.length (librarian_refusals fixture));
  let body=Filename.concat (Store.root fixture.store)
    (Store.tool_request_body_path ~scope:ended.scope ~request_digest:ended.request_digest) in
  io (fun () -> write body "damaged body after the strict ending");
  check int "the original body is not needed to validate a stored isolated ending" 0
    (List.length (librarian_refusals fixture));
  (* A contradictory retained Gate still refers to the full parent. It must
     not be hidden by the parent's otherwise valid bodyless ending. *)
  let gate_scope=Gate.scope (Capture.physical_owner request) in
  let gate_id="fixture-gate-refers-to-ended-original" in
  let gate_request=`Assoc ["version",`Int 3;"kind",`String "librarian-durable-gate";
    "request_id",`String gate_id;"owner",Capture.owner_to_json (Capture.physical_owner request);
    "execution_id",`String ended.request_id;"execution_digest",`String ended.request_digest;
    "proposal",`Null;"authority",`Null;"guidance",`Null;"predecessor",`Null] in
  io (fun () -> Owner.retain ~store:fixture.store ~scope:gate_scope ~request_id:gate_id
    ~installation_id:ended.installation_id ~package_id:ended.package_id ~tool:ended.tool
    ~summary:`Null ~request:gate_request |> owned);
  let owner_path=Filename.concat (scope_directory fixture ended.scope) (Store.digest ended.request_id ^ ".json") in
  check bool "a Gate reference keeps the complete parent body required" true
    (List.exists (fun (refusal:Lane_addon_store_preflight.refusal) ->
       refusal.path=owner_path && refusal.decoder=Lane_addon_store_preflight.Tool_request_owner)
      (librarian_refusals fixture));
  let gate_digest=Owner.request_digest gate_request |> get in
  io (fun () ->
    Sys.remove (Filename.concat (scope_directory fixture gate_scope) (Store.digest gate_id ^ ".json"));
    Sys.remove (Filename.concat (Store.root fixture.store)
      (Store.tool_request_body_path ~scope:gate_scope ~request_digest:gate_digest)));
  check int "removing the contradictory fixture restores isolated ending inspection" 0
    (List.length (librarian_refusals fixture));
  let positions=progress fixture and wakes=ref 0 in
  let scope=Capture.scope (Capture.physical_owner request) in
  let refuses ()=check bool "preflight preserves the consumer's lack of replacement authority" true
    (refuses_original fixture ~original:ended (scope,gate_scope) (librarian_refusals fixture)) in
  let runtime_refuses ()=
    match memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name
      ~wake:(fun () -> incr wakes)) with
    | Error (Consumer.Original_publication_blocked _) -> ()
    | Error error -> fail (Consumer.error_to_string error)
    | Ok _ -> fail "host evidence was converted into permission to replace a before-dispatch original" in
  let record_path=Filename.concat (Store.root fixture.store)
    (Store.exact_request_path ~declaration_id:"librarian" ~request_id:exact.request_id) in
  io (fun () -> Store.save_exact_request fixture.store ~declaration_id:"librarian" ~request_id:exact.request_id
    (`Assoc ["declaration_id",`String "librarian";"request_id",`String exact.request_id;
      "digest",`String (Exact.digest exact);"request",Exact.request_to_json exact;
      "attempts",`List [`Assoc ["started",`String "0123456789abcdef0123456789abcdef"]];"final",`Null]) |> get);
  check bool "the Exact scan keeps this valid original host record" false
    (List.mem record_path (exact_deletes fixture));
  refuses ();runtime_refuses ();
  io (fun () -> write record_path "{unreadable original host record");
  check bool "the Exact scan would remove this malformed record" true
    (List.mem record_path (exact_deletes fixture));
  (* Pruning cannot turn the host record into proof that dispatch never ran. *)
  refuses ();runtime_refuses ();
  io (fun () -> Sys.remove record_path);
  let proof=proof_path fixture exact in
  io (fun () -> write proof "{unreadable original execution proof");
  refuses ();runtime_refuses ();
  check int "contradictory host evidence grants no wake" 0 !wakes;
  check int "no preflight or failed resume calls a provider" 0 (F.post_count fixture.server);
  check bool "contradictory evidence consumes no input" true (progress fixture=positions);
  no_memory fixture;
  io (fun () -> Sys.remove proof);
  check int "restoring actual absence also restores the read-only verdict" 0
    (List.length (librarian_refusals fixture));
  io (fun () -> write body (Yojson.Safe.to_string ended.request));
  replace_actual_worker_configuration fixture ~sw (fixture.declaration true);
  drive_advanced fixture;
  check int "only the new request runs after the evidence is restored" 1 (F.post_count fixture.server))
let test_replacement_terminal_survives_worker_gap ~rollback () = with_fixture (fun ~sw fixture ->
  let _,request=retain_absent_history_original ~failed_selection:false fixture in
  let original_input=Source.input (Capture.source request) in
  let positions=progress fixture in
  let cursor ()=io (fun () -> Keeper_external_read_cursor.observe
    ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get)
    |> Keeper_external_read_cursor.observation_to_json in
  let cursor_before=cursor () in
  let replacement=fixture.declaration true |> String.split_on_char '\n'
    |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-replacement\"" | line -> line)
    |> String.concat "\n" in
  replace_actual_worker_configuration fixture ~sw replacement;
  let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
    |> Result.map_error Lane_addon_manifest.error_to_string |> get in
  let exact=Capture.request request |> get in
  let result=memory_action fixture (fun () -> Exact.run ~store:fixture.store
    ~declaration_id:"librarian" ~package ~runner:(Server_lane_addon_exact.runner ~base_path:fixture.base_path)
    ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path:fixture.base_path) exact) |> get in
  (match result with Exact.Final (Not_allowed _) -> ()
   | Final _ | Not_final _ -> fail "fresh replacement did not end the unstarted original");
  let schema=Option.to_result ~none:"unstarted replacement fixture has no schema" exact.Exact.schema |> get in
  (match io (fun () -> Exact.read_latest_original_execution ~store:fixture.store
    ~declaration_id:"librarian" ~schema exact) |> get with
   | No_completed_latest -> ()
   | Completed_latest _ -> fail "an unstarted replacement cannot have a completed latest attempt");
  check int "the actual host replacement sends no model request" 0 (F.post_count fixture.server);
  if rollback then replace_actual_worker_configuration fixture ~sw (fixture.declaration true)
  else set_enabled fixture false;
  let wakes=ref 0 in
  (match memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name
     ~wake:(fun () -> incr wakes)) with
   | Ok (Consumer.Memory_not_committed _) -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "the original host cause was lost after its worker changed");
  check int "the completed replacement requests one next pass" 1 !wakes;
  let record,_=only_original fixture in
  let target=Keeper_librarian_original_final.target
    ~installation_id:(Capture.destination request).installation_id exact |> get in
  check bool "the immutable host cause survives current worker state" true
    (io (fun () -> Keeper_librarian_original_final.declaration_replaced ~store:fixture.store target record) |> get);
  let selected=ref None in
  (match memory_action fixture (fun () -> Consumer.consume_one ~config:fixture.config ~keeper_name
     ~commit:(fun source -> selected:=Some (Source.input source);Consumer.Memory_replaced [])) with
   | Ok (Consumer.Memory_not_committed _) -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "the untouched unread source was not selected again");
  let selected=Option.to_result ~none:"missing fresh source selection" !selected |> get in
  check bool "replacement never narrows the original unread history" true
    (selected.messages=original_input.messages);
  check bool "replacement retains all original counterpart input" true
    (selected.counterpart_observations=original_input.counterpart_observations);
  check bool "replacement advances no read position" true (progress fixture=positions);
  check json "replacement advances no external ACK" cursor_before (cursor ());
  check int "neither the missing worker nor rollback replays the original" 0 (F.post_count fixture.server);
  no_memory fixture)
let fence_preview fixture request = io (fun () ->
  Resolution.preview ~config:fixture.config ~keeper_name ~request_id:(Capture.request_id request)
  |> Result.map_error Resolution.error_to_string |> get)
let refuse_fenced_resume fixture original request =
  let before = io (fun () -> current fixture.keepers_dir), progress fixture in
  let result = memory_action fixture (fun () -> Durable_owner.resume ~store:fixture.store
    ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ())
    ~original:(Durable_owner.Read (original,request))
    ~call:(fun ~expected:_ ~original:_ ~arguments:_ -> fail "fenced original reached its worker")
    ~publish:(fun ~original:_ ~request:_ ~proposal:_ -> fail "fenced original reached Memory publication")
    ~wake:(fun () -> fail "fenced original scheduled a replacement")) in
  check bool "fenced original refuses before any worker or Memory action" true (Result.is_error result);
  check bool "fence refusal preserves Memory and source position" true
    (before = (io (fun () -> current fixture.keepers_dir), progress fixture))
(* Actual host cancellation/join and worker restoration. Observe through the
   owner so each test can choose its consumer/continuation entry afterward. *)
let with_same_binding_cut ?(history_kind=Atoms) ?(with_io_pool=false)
    ?(before_capture=(fun _ -> ())) use =
  with_fixture ~history_kind ~with_io_pool (fun ~sw fixture ->
    before_capture fixture;
    let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
    fixture.set_response (fun capture ->
      ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
      `OK,F.openai_response (answer capture));
    Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
      assert_pending (run_worker fixture);Eio.Promise.await arrived;
      let before_delivery= !(fixture.deliveries) in
      (match Memory_lane.with_librarian_purge ~base_path:fixture.base_path ~keeper_name (fun () -> ()) with
       | Ok () -> () | Error error -> fail (Memory_lane.purge_cancel_error_to_string error));
      ignore (Eio.Promise.try_resolve unblock ());
      fixture.set_response (fun capture -> `OK,F.openai_response (answer capture));
      restart_actual_worker fixture ~sw;
      await_delivery fixture ~after:before_delivery;
      observe_retained_cut fixture;
      let original,request=only_original fixture in
      let exact=Capture.request request |> get in
      let schema=Option.to_result ~none:"Cut original schema" exact.Exact.schema |> get in
      (match Progress.phase original.progress with
       | Rejected {stage=Execution;evidence} ->
         check bool "fixture joined the actual cancelled host and retained Cut" true
           ((Exact.retained_final_of_json ~schema evidence |> get) = Exact.Retained_unknown Exact.Cut)
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
       | Finished _ | Conflicted _ | Rejected {stage=Before_dispatch;_} | Subdividing _ | Subdivided _ ->
         fail "actual cancellation did not retain an execution-stage Cut");
      use fixture original request exact schema))
let cut_preview fixture original = io (fun () ->
  Resolution.preview_cut ~config:fixture.config ~keeper_name ~request_id:original.Owner.request_id
  |> Result.map_error Resolution.error_to_string |> get)
let cut_fence fixture original expected = memory_action fixture (fun () -> io (fun () ->
  Resolution.fence_cut_serialized ~config:fixture.config ~keeper_name ~request_id:original.Owner.request_id
    ~expected ~actor:"operator" ~reason:"Exclude this original's future local effects"
    ~now:(Time_compat.now ())))
let cut_source_positions fixture = io (fun () ->
  let runtime_keepers_dir=Workspace.keepers_runtime_dir fixture.config in
  let atom=Position.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
    |> Result.map_error Position.read_error_to_string |> get in
  let official=Keeper_librarian_official_progress.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
    |> Result.map_error Keeper_librarian_official_progress.read_error_to_string |> get in
  let external_cursor=Keeper_external_read_cursor.observe ~runtime_keepers_dir ~keeper_name |> get in
  atom,official,Keeper_external_read_cursor.observation_to_json external_cursor)
let cut_memory_bytes fixture = io (fun () ->
  List.map (fun path -> path,Fs_compat.load_file_opt path) [
    Current.path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name;
    Current.journal_path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name;
    Current.durable_range_receipt_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name;
    Current.publication_receipt_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name])
let test_interrupted_evidence_cannot_release_another_actual_host_cause ~raised () =
  let check_mismatch fixture (original:Owner.retained) request cause =
    let exact=Capture.request request |> get in
    let schema=Option.to_result ~none:"unknown original lacks its schema" exact.Exact.schema |> get in
    let actual=Exact.Retained_unknown cause in
    check bool "the regression is an unlinked complete unread capture" true
      (Capture.predecessor request=None && Source.extent (Capture.source request)=Keeper_librarian_range.All_unread);
    check bool "no fence can mask the retained-cause regression" true
      (io (fun () -> Fence.read ~store:fixture.store ~scope:original.scope ~request_id:original.request_id |> get)=None);
    check bool "the configured host produced the actual unknown cause" true
      ((io (fun () -> Exact.observe_retained ~store:fixture.store ~declaration_id:"librarian" ~schema exact) |> get)
       = Exact.Retained_terminal actual);
    io (fun () -> Capture.confirm_retained_final ~store:fixture.store request actual |> get);
    (match io (fun () -> Commit.validate ~store:fixture.store ~request ~record:original) |> get with
     | Commit.Unfinished -> () | Settled -> fail "the actual Cut/Raised cause must remain unfinished");
    let progress=List.fold_left (fun result event ->
      let event=match event with
        | Progress.Refused {stage=Execution;_} -> Progress.Refused {stage=Execution;
            evidence=Exact.retained_final_to_json (Exact.Retained_unknown Interrupted)}
        | Transport_observed _ | Dispatch_intended | Admission_declined _ | Approval_intended _ | Approval_wait_retained _
        | Execution_observed _ | Judgment_retained _
        | Preparation_intended _ | Preparation_observed _ | Replacement_intended _ | Replacement_observed _
        | Commit_intended _ | Commit_uncertain _ | Commit_retry_observed _ | Commit_observed _
        | Commit_conflicted _ | Refused {stage=Before_dispatch;_} | Refusal_settled _
        | Successor_intended _ | Successor_observed _ | Observer _ -> event in
      Result.bind result (fun progress -> Progress.append progress event))
      (Ok Progress.captured) (Progress.events original.progress) |> get in
    (* Only the retained consumer row is damaged. The actual host terminal,
       schema, request, source and execution evidence are not fabricated. *)
    let metadata=match Owner.record_to_json (Owner.listed original) with
      | `Assoc fields -> `Assoc (List.map (fun (name,value) ->
          name,if name="progress" then Progress.to_json progress else value) fields)
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        fail "the original owner metadata is not an object" in
    let damaged_record=Owner.decode_published
      ~directory_name:(Filename.basename (scope_directory fixture original.scope))
      ~file_name:(Store.digest original.request_id ^ ".json") metadata |> get in
    let damaged=Owner.rebind original damaged_record
      |> Option.to_result ~none:"damaged consumer row changed its immutable binding" |> get in
    io (fun () -> Store.save_tool_request_owner fixture.store ~scope:original.scope
      ~request_id:original.request_id metadata |> get);
    let positions=cut_source_positions fixture and memory=cut_memory_bytes fixture
    and posts=F.post_count fixture.server and wakes=ref 0 in
    let ids ()=List.map (fun ((record:Owner.retained),_) -> record.request_id) (observed_originals fixture) in
    let before_ids=ids () and before_record=Owner.record_to_json (Owner.listed damaged) in
    check bool "the typed request port rejects another unknown cause" true
      (Result.is_error (io (fun () -> Capture.confirm_retained_final ~store:fixture.store request
        (Exact.Retained_unknown Interrupted))));
    check bool "direct inventory validation rejects the mismatched retained cause" true
      (Result.is_error (io (fun () -> Commit.validate ~store:fixture.store ~request ~record:damaged)));
    (match memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name
      ~wake:(fun () -> incr wakes)) with
     | Error (Consumer.Original_publication_blocked _) -> ()
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "mismatched Interrupted evidence reached archive or source reselection");
    check bool "the mismatched original is not archived" false
      (settled_on fixture ~date:(day_of original.request_id) original);
    check (list string) "no replacement or fresh root ID is retained" before_ids (ids ());
    let current,_=only_original fixture in
    check json "the contradictory row is preserved for repair" before_record (Owner.record_to_json (Owner.listed current));
    check bool "the actual host cause remains unchanged" true
      ((io (fun () -> Exact.observe_retained ~store:fixture.store ~declaration_id:"librarian" ~schema exact) |> get)
       = Exact.Retained_terminal actual);
    check bool "the mismatch changes no atom, official or external ACK" true (cut_source_positions fixture=positions);
    check bool "the mismatch writes no Memory, journal or receipts" true (cut_memory_bytes fixture=memory);
    check int "the mismatch schedules no fresh pass" 0 !wakes;
    check int "the mismatch invokes no provider" posts (F.post_count fixture.server) in
  if not raised then
    with_same_binding_cut (fun fixture original request _exact _schema ->
      check_mismatch fixture original request Exact.Cut)
  else with_fixture (fun ~sw:_ fixture ->
    let original,request=retain_absent_history_original ~failed_selection:false fixture in
    let exact=Capture.request request |> get in
    let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
      |> Result.map_error Lane_addon_manifest.error_to_string |> get in
    (* Exercise the real configured authority and Exact exception producer.
       Only the call failure after its actual Generation guard is injected. *)
    let runner ~before_dispatch ~admission_class:_ ~lane_key:_ ~schema:_ ~size_refused:_ _ =
      Ok (fun ~validate:_ -> before_dispatch Exact.Generation |> get;
        raise (Failure "fixture call raised after the actual dispatch marker")) in
    (match Exact.run ~store:fixture.store ~declaration_id:"librarian" ~package ~runner
      ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path:fixture.base_path) exact |> get with
     | Exact.Final Outcome_unknown -> () | Final (Call_final _ | Not_allowed _ | Request_id_reused) | Not_final _ ->
       fail "the real host did not retain its raised call");
    (match memory_action fixture (fun () -> Durable_owner.resume ~store:fixture.store ~config:fixture.config
      ~reserved:(Keeper_librarian_durable_edge.reserved ()) ~original:(Durable_owner.Read (original,request))
      ~call:(fun ~expected:_ ~original:_ ~arguments:_ -> fail "a retained Raised cause cannot send an RPC")
      ~publish:(fun ~original:_ ~request:_ ~proposal:_ -> fail "a retained Raised cause cannot publish")
      ~wake:(fun () -> ())) |> Result.map_error Durable_owner.error_to_string |> get with
     | Waited (Worker_unknown,_) -> ()
     | Waited ((Worker_pending | Worker_unreachable | Missing_after_dispatch | Journal_recheck),_)
     | Resumed _ | Original_replaced _ -> fail "the actual raised cause did not stay pending");
    let original=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
      ~request_id:original.request_id |> owned |> Option.get) in
    check_mismatch fixture original request Exact.Raised)
let test_cut_effect_fence_preserves_unknown_without_a_successor history_kind () =
  with_same_binding_cut ~history_kind (fun fixture original request exact _schema ->
    let positions=cut_source_positions fixture and posts=F.post_count fixture.server in
    let memory_before=cut_memory_bytes fixture in
    let parent=Owner.to_json original in
    let host=io (fun () -> Store.load_exact_request fixture.store ~declaration_id:"librarian"
      ~request_id:exact.Exact.request_id |> get) in
    check bool "absence preview never borrows terminal Cut authority" true
      (Result.is_error (io (fun () -> Resolution.preview ~config:fixture.config
        ~keeper_name ~request_id:original.request_id)));
    let preview=cut_preview fixture original in
    (* Submission records work; the serial consumer decides its authority. *)
    let accepted=io (fun () -> Resolution_work.submit ~config:fixture.config ~keeper_name
      ~request_id:original.request_id ~expected:preview.expected ~actor:"operator"
      ~reason:"Exclude this original's future local effects" ~now:(Time_compat.now ())
      |> Result.map_error Resolution_intent.error_to_string |> get) in
    let fence=cut_fence fixture original preview.expected |> Result.map_error Resolution.error_to_string |> get in
    let roundtrip=Fence.of_json (Fence.to_json fence) |> get in
    (match roundtrip.authority with
     | Fence.Excluded_cut basis ->
       check string "Cut basis names the original ID" original.request_id basis.request_id;
       check string "Cut basis binds the Exact digest" (Exact.digest exact) basis.exact_digest;
       check bool "Cut basis retains the real attempt" true (basis.attempt_ordinal>0)
     | Worker_absent -> fail "Cut was relabelled as worker absence");
    check json "fence preserves the complete original Unknown" parent fence.original_record;
    check bool "fence consumes no checkpoint, official or external source" true (cut_source_positions fixture=positions);
    no_memory fixture;
    check int "fence makes no further provider call" posts (F.post_count fixture.server);
    check bool "fence retains the host outcome exactly" true
      (io (fun () -> Store.load_exact_request fixture.store ~declaration_id:"librarian"
        ~request_id:exact.request_id |> get)=host);
    let current_parent=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
      ~request_id:original.request_id |> owned |> Option.get) in
    check json "parent progress was not settled or rewritten" parent (Owner.to_json current_parent);
    check bool "direct refusal settlement cannot abandon an effect-fenced original" true
      (Result.is_error (memory_action fixture (fun () -> io (fun () ->
        Keeper_librarian_durable_commit.settle_refused ~store:fixture.store ~request
          ~record:current_parent))));
    check bool "the serial consumer refuses Cut as a successor grant" true
      (Result.is_error (memory_action fixture (fun () ->
        Resolution_work.run_serialized ~config:fixture.config ~keeper_name)));
    let intents=io (fun () -> Resolution_intent.read ~config:fixture.config ~keeper_name
      ~request_id:original.request_id |> Result.map_error Resolution_intent.error_to_string |> get) in
    check bool "Cut fence leaves the submitted intent without a child or completion" true
      (match intents with
       | [intent] -> intent.Resolution_intent.intent_id=accepted.intent.intent_id
         && intent.phase=Resolution_intent.Requested && Option.is_none intent.memory_commit
       | [] | _::_::_ -> false);
    check bool "Cut fencing and refused continuation preserve snapshot, journal, receipts and publication bytes" true
      (cut_memory_bytes fixture=memory_before);
    refuse_fenced_resume fixture current_parent request)
let test_cut_effect_fence_refuses_a_busy_claim_and_late_bad_proof () =
  with_same_binding_cut (fun fixture original _request exact schema ->
    let preview=cut_preview fixture original in
    let positions=cut_source_positions fixture in
    let held=memory_action fixture (fun () -> io (fun () ->
      Exact.with_cut_exclusion ~store:fixture.store ~declaration_id:"librarian"
      ~schema exact ~use:(fun _ ->
        check bool "another Cut claim cannot authorize the fence" true
          (Result.is_error (Resolution.fence_cut_serialized ~config:fixture.config ~keeper_name
            ~request_id:original.request_id ~expected:preview.expected ~actor:"operator"
            ~reason:"busy is no authority" ~now:(Time_compat.now ()))))))
      |> Result.map_error Exact.describe_recovery_error |> get in
    (match held with Exact.Cut_excluded () -> ()
     | Cut_busy | Cut_not_retained _ -> fail "fixture failed to acquire its original claim");
    let proof=proof_path fixture exact in
    io (fun () -> write proof "{late unreadable execution proof");
    check bool "proof changed after preview cannot authorize a fence" true
      (Result.is_error (cut_fence fixture original preview.expected));
    check bool "both denied attempts leave no fence" true
      (io (fun () -> Fence.read ~store:fixture.store ~scope:original.scope ~request_id:original.request_id |> get)=None);
    check bool "denied attempts acknowledge no source" true (cut_source_positions fixture=positions);
    no_memory fixture)
let test_cut_effect_fence_refuses_an_actual_range_receipt () =
  with_same_binding_cut (fun fixture original request _exact _schema ->
    let source=Capture.source request and positions=cut_source_positions fixture in
    memory_action fixture (fun () -> io (fun () -> Current.apply_disposition
      ~pass:Keeper_memory_commit_pass.Durable ?durable_range_id:(Source.range_id source)
      ?official_range_id:(Source.official_range_id source) ~absorbed:[] ~revisions:[]
      ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name ~now:(Time_compat.now ())
      ~source:{kind=Current.Librarian;trace_id} ~new_claims:[] () |> get)) |> ignore;
    (match io (fun () -> Resolution.preview_cut ~config:fixture.config ~keeper_name
       ~request_id:original.request_id) with
     | Error Resolution.Range_already_recorded -> ()
     | Error error -> fail (Resolution.error_to_string error)
     | Ok _ -> fail "an actual Memory range receipt permitted a Cut fence");
    check bool "apply-first does not create a Cut fence" true
      (io (fun () -> Fence.read ~store:fixture.store ~scope:original.scope ~request_id:original.request_id |> get)=None);
    check bool "the denied fence does not move positions" true (cut_source_positions fixture=positions))
let test_cut_effect_fence_refuses_moved_source_positions () =
  with_same_binding_cut (fun fixture original request _exact _schema ->
    let preview=cut_preview fixture original in
    let range=Source.range_id (Capture.source request) |> Option.get in
    let next:Position.t={position={trace_id=range.trace_id;end_atom=range.end_atom;
      last_atom_digest=range.last_atom_digest};boundary_lines_seen=range.boundary_lines_seen} in
    io (fun () -> Position.write ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config)
      ~keeper_id:keeper_name next |> Result.map_error Position.write_error_to_string |> get);
    let positions=cut_source_positions fixture in
    check bool "a changed source position invalidates the Cut preview" true
      (Result.is_error (cut_fence fixture original preview.expected));
    check bool "the refusal does not change positions again" true (cut_source_positions fixture=positions);
    no_memory fixture)
let test_cut_fence_is_not_direct_child_or_host_authority () =
  with_same_binding_cut (fun fixture original request _exact _schema ->
    let expected=(cut_preview fixture original).expected in
    let accepted=io (fun () -> Resolution_work.submit ~config:fixture.config ~keeper_name
      ~request_id:original.request_id ~expected ~actor:"operator"
      ~reason:"Exclude this original's future local effects" ~now:(Time_compat.now ())
      |> Result.map_error Resolution_intent.error_to_string |> get) in
    let fence=cut_fence fixture original expected |> Result.map_error Resolution.error_to_string |> get in
    let before=cut_memory_bytes fixture,cut_source_positions fixture,F.post_count fixture.server in
    check bool "direct intent confirmation cannot promote a Cut fence to successor authority" true
      (Result.is_error (memory_action fixture (fun () -> io (fun () ->
        Resolution_intent.confirm_fence ~store:fixture.store ~expected:accepted.intent fence))));
    let owner=Capture.physical_owner request in
    let child=io (fun () -> Capture.create ~request_id:(Capture.fresh_request_id owner)
      ~predecessor:{request_id=original.request_id;request_digest=original.request_digest}
      ~owner ~destination:(Capture.destination request) ~source:(Capture.source request)
      ~preparation:(Capture.preparation request) ()) |> get in
    (* Existing or externally supplied metadata must not bypass the effect
       check merely by already claiming an acknowledged child. *)
    io (fun () ->
      let stored=Store.load_history_resolution fixture.store ~scope:original.scope
        ~request_id:original.request_id |> get |> Option.get in
      let phase=`Assoc ["kind",`String "child_confirmed";"child",`Assoc [
        "request_id",`String (Capture.request_id child);"request_digest",`String (Capture.body_digest child)]] in
      let next=`Assoc (List.map (fun (name,value) -> if name="intents" then
          name,`List (List.map (fun json -> `Assoc (List.map (fun (name,value) ->
            if name="phase" then name,phase else name,value) (Yojson.Safe.Util.to_assoc json)))
            (Yojson.Safe.Util.to_list value))
          else name,value) (Yojson.Safe.Util.to_assoc stored)) in
      (match Store.publish_history_resolution fixture.store ~scope:original.scope
        ~request_id:original.request_id ~expected:(Some stored) ~next |> get with
       | Store.History_resolution_stored -> ()
       | History_resolution_changed | History_resolution_unconfirmed _ -> fail "fixture child metadata was not retained");
      let destination=Capture.destination child in
      let index=Capture.index child |> get in
      Owner.retain ~store:fixture.store ~scope:original.scope ~request_id:(Capture.request_id child)
        ~installation_id:destination.installation_id ~package_id:destination.package_id ~tool:destination.tool
        ~summary:(Capture.index_to_json index) ~request:(Capture.to_json child) |> owned);
    check bool "direct lineage consumption refuses an already acknowledged Cut child" true
      (Result.is_error (io (fun () -> Keeper_librarian_history_resolution_lineage.confirm_predecessor_by_body
        ~store:fixture.store ~require_confirmed:true child)));
    let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
      |> Result.map_error Lane_addon_manifest.error_to_string |> get in
    check bool "actual host authorization refuses Cut metadata before any provider dispatch" true
      (Result.is_error (Server_librarian_addon_validation.authorize ~base_path:fixture.base_path
        ~store:fixture.store ~declaration_id:"librarian" ~package (Capture.request child |> get)));
    check bool "denied authority changes no Memory, source position or provider count" true
      (before=(cut_memory_bytes fixture,cut_source_positions fixture,F.post_count fixture.server)))
let submit_cut_command fixture original =
  let preview,basis=Resolution.preview_cut_command ~config:fixture.config
    ~keeper_name ~request_id:original.Owner.request_id |> Result.map_error Resolution.error_to_string |> get in
  io (fun () -> Resolution_work.submit_cut ~config:fixture.config ~keeper_name ~request_id:original.request_id
    ~expected:preview.expected ~basis ~actor:"operator" ~reason:"Continue this same-binding Cut"
    ~now:(Time_compat.now ()) |> Result.map_error Resolution_intent.error_to_string |> get)
let last_cut_intent fixture original =
  io (fun () -> Resolution_intent.read ~config:fixture.config ~keeper_name ~request_id:original.Owner.request_id
    |> Result.map_error Resolution_intent.error_to_string |> get) |> List.rev |> List.hd
let run_cut_command fixture = memory_action fixture (fun () ->
  Resolution_work.run_serialized ~config:fixture.config ~keeper_name)
let test_automatic_cut_continuation_commits_and_retains_compact_proof history_kind () =
  with_same_binding_cut ~history_kind (fun fixture original request exact _schema ->
    let before=cut_source_positions fixture and posts=F.post_count fixture.server in
    let parent=Owner.to_json original in
    let host=io (fun () -> Store.load_exact_request fixture.store ~declaration_id:"librarian"
      ~request_id:exact.Exact.request_id |> get) in
    let wakes=ref 0 in
    assert_pending (memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config
      ~keeper_name ~wake:(fun () -> incr wakes)));
    let intent=last_cut_intent fixture original in
    (match intent.origin with
     | Resolution_intent.Same_binding_cut basis -> check string "Cut origin binds the actual original" original.request_id basis.request_id
     | Worker_absence -> fail "actual Cut borrowed absence authority");
    let child=match intent.phase with
      | Resolution_intent.Child_confirmed child -> child
      | Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _ ->
        fail "fresh actual Cut did not retain its explicit confirmed continuation" in
    check int "automatic Cut yields one durable wake" 1 !wakes;
    check int "the grant does not inline-dispatch another provider request" posts (F.post_count fixture.server);
    check bool "child confirmation alone cannot release fresh selection" true
      (Result.is_error (io (fun () -> Keeper_librarian_history_resolution_selection.check ~config:fixture.config ~keeper_name)));
    check bool "grant consumes no original source" true (cut_source_positions fixture=before);
    drive_advanced fixture;
    let completed=last_cut_intent fixture original in
    check bool "actual descendant Finished retains its committed receipt set" true
      (match completed.memory_commit with Some proof -> proof.request_id=child.request_id && proof.receipts<>[] | None -> false);
    check int "one new question, without replaying the original" (posts+1) (F.post_count fixture.server);
    let through=Keeper_librarian_input_sources.external_through (Source.counterparts (Capture.source request)) in
    check bool "actual original external frontier was ACKed" true (io (fun () ->
      let cursor=Keeper_external_read_cursor.observe ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config)
        ~keeper_name |> get in
      Keeper_external_read_cursor.observation_matches_preparation cursor ~after:through ~through ~atom:None ~official:None));
    check bool "original host Unknown is retained" true (host=io (fun () ->
      Store.load_exact_request fixture.store ~declaration_id:"librarian" ~request_id:exact.request_id |> get));
    check json "fenced parent bytes remain unchanged" parent (io (fun () ->
      Owner.load ~store:fixture.store ~scope:original.scope ~request_id:original.request_id |> owned |> Option.get |> Owner.to_json));
    io (fun () ->
      List.iter (fun digest -> let path=Filename.concat (Store.root fixture.store)
        (Store.tool_request_body_path ~scope:original.scope ~request_digest:digest) in
        if Sys.file_exists path then Sys.remove path) [original.request_digest;child.request_digest];
      let receipts=Current.durable_range_receipt_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
      if Sys.file_exists receipts then Sys.remove receipts);
    check bool "compact completion survives raw body and rolling receipt pruning" true
      (Result.is_ok (io (fun () -> Keeper_librarian_history_resolution_selection.check ~config:fixture.config ~keeper_name))))
type retained_replacement_stage = Captured_question | Host_ended_question
  | Replacement_intent_saved | Replacement_child_saved | Replacement_ack_saved
  | Replacement_intent_rollback | Later_captured_question
let retain_actual_floor_first fixture request =
  let module Step=Keeper_librarian_floor_step_request in
  let module Steps=Keeper_librarian_floor_step_owner in
  let module M=Keeper_librarian_message_floor.Machine in
  let module R=Keeper_librarian_runtime in
  let open Result.Syntax in
  let owner=Capture.physical_owner request in
  let identity:R.retained_step_source={request_id=Capture.request_id request;
    request_digest=Capture.body_digest request;source_basis_digest=Capture.source_basis_digest request |> get} in
  let transaction_id=Keeper_librarian_message_floor.fresh_transaction_id () in
  let basis,question,preparation=memory_action fixture (fun () -> io (fun () ->
    Keeper_librarian_durable_source_lock.with_original_manifest ~request (fun manifest ->
      let* anchor=Current.capture_program_anchor ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
      let current=Option.map (fun (snapshot:Current.t) ->
        ({Keeper_librarian.facts=snapshot.facts}:Keeper_librarian.current_selection))
        (Current.program_anchor_snapshot anchor) in
      let* unread_messages=Current.read_unread_messages ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
      let input=Source.input (Capture.source request) in
      let* read=M.read ~keeper_name ~sources:manifest.ordered_sources ~unread_messages ~previous_state:None input in
      let* plan=Keeper_librarian_memory_plan.create_over ~keeper_id:input.keeper_id ~turn_ref:input.turn_ref ~current
        |> Result.map_error Keeper_librarian_memory_plan.error_to_string in
      let* machine=M.start ~transaction_id ~plan read in
      let* next=M.next machine in
      match next with
      | M.Finished _ -> Error "Actual retained fixture has no first message"
      | Ask question ->
        let context:R.durable_step_context={previous_state=question.previous_state;unread_messages=question.unread_messages} in
        let+ preparation=R.prepare_retained_durable_step ~source:identity
          ~original:(Capture.preparation request) ~context question.input in
        ({Step.anchor=Current.program_anchor_evidence anchor;sources=manifest.ordered_sources},question,preparation)))) |> get in
  memory_action fixture (fun () -> Keeper_librarian_durable_edge.with_destination ~config:fixture.config
    ~reserved:(Keeper_librarian_durable_edge.reserved ()) (fun destination ->
      let* step=Step.create ~basis ~request_id:(Step.fresh_request_id owner) ~owner ~destination
        ~transaction_id ~range:{request_id=identity.request_id;request_digest=identity.request_digest}
        ~previous:None ~question ~step:preparation () in
      let+ record=Steps.retain ~store:fixture.store step |> Result.map_error Steps.error_to_string in record,step)) |> get
let retain_actual_floor_later fixture request =
  let module Step=Keeper_librarian_floor_step_request in
  let module Steps=Keeper_librarian_floor_step_owner in
  let module Journal=Keeper_librarian_floor_step_gate in
  let module Judgment=Keeper_librarian_floor_step_judgment in
  let module Edge=Keeper_librarian_durable_edge in
  let module M=Keeper_librarian_message_floor.Machine in
  let module R=Keeper_librarian_runtime in
  let first,step=retain_actual_floor_first fixture request in
  let owner=Step.physical_owner step in
  let output=`Assoc ["new_claims",`List [new_claim "The earlier retained coordinate was read"];
    "dropped",`List [];"working_state",`String "Earlier retained coordinate state";"working_contexts",`List []] in
  fixture.set_step_response (fun _ -> `OK,F.openai_response output);
  let dispatched=advance_original fixture first Progress.Dispatch_intended in
  let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
    |> Result.map_error Lane_addon_manifest.error_to_string |> get in
  (* The actual host's external-effect scope owns the synchronous generation.
     Keep the ordinary Memory drain idle: this fixture's provider inspects that
     drain before it reads the retained request. *)
  (match Exact.run ~store:fixture.store ~declaration_id:"librarian" ~package
      ~runner:(Server_lane_addon_exact.runner ~base_path:fixture.base_path)
      ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path:fixture.base_path)
      (Step.request step |> get) |> get with
   | Exact.Final (Call_final (Answered _)) -> ()
   | Final _ | Not_final _ -> fail "the actual earlier coordinate has no provider answer");
  let answer,current=memory_action fixture (fun () ->
    match Steps.resume ~store:fixture.store ~config:fixture.config ~reserved:(Edge.reserved ())
      ~original:dispatched ~step ~call:(fun ~expected:_ ~original:_ ~arguments:_ ->
        fail "the earlier coordinate was dispatched twice") |> Result.map_error Steps.error_to_string |> get with
    | Steps.Answered (answer,current) -> answer,current
    | Pending _ | Refused _ | Before_dispatch_replaced _ -> fail "the earlier coordinate lost its actual answer") in
  let inventory=io (fun () -> Journal.Inventory.read ~store:fixture.store ~owner) |> get in
  let decision=memory_action fixture (fun () -> Judgment.judge ~store:fixture.store ~step ~record:current ~answer
    ~fresh_authority:(Edge.fresh_gate_authority ~config:fixture.config ~reserved:(Edge.reserved ()) ~owner
      ~expected:(Step.destination step)) ~inventory) |> get in
  let decision=match decision with Judgment.Decided decision -> decision
    | Pending _ -> fail "the earlier coordinate's actual nonabsorbing Gate did not settle" in
  let basis=Step.chain_basis step |> Option.get and preparation=Step.step step in
  let next=let open Result.Syntax in
    let input=Source.input (Capture.source request) in
    let* read=M.read ~keeper_name ~sources:basis.sources ~unread_messages:preparation.context.unread_messages
      ~previous_state:preparation.context.previous_state input in
    let* plan=Keeper_librarian_memory_plan.create_over ~keeper_id:input.keeper_id ~turn_ref:input.turn_ref
      ~current:preparation.preparation.source_input.current |> Result.map_error Keeper_librarian_memory_plan.error_to_string in
    let* machine=M.start ~transaction_id:(Step.transaction_id step) ~plan read in
    let* machine=M.answered machine decision in M.next machine in
  let question=match next |> get with M.Ask question -> question
    | Finished _ -> fail "the real retained source has no later coordinate" in
  check int "the replacement fixture reaches a later actual question" 1 question.position;
  let source=match preparation.mode with R.Retained_original source -> source
    | Ordinary_floor -> fail "the later fixture lost its retained original preparation" in
  let context:R.durable_step_context={previous_state=question.previous_state;unread_messages=question.unread_messages} in
  let preparation=R.prepare_retained_durable_step ~source ~original:(Capture.preparation request) ~context question.input |> get in
  memory_action fixture (fun () -> Edge.with_destination ~config:fixture.config ~reserved:(Edge.reserved ())
    (fun destination -> let open Result.Syntax in
      let* later=Step.create ~request_id:(Step.fresh_request_id owner) ~owner ~destination
        ~transaction_id:(Step.transaction_id step) ~range:(Step.range step)
        ~previous:(Some {request_id=current.request_id;request_digest=current.request_digest}) ~question ~step:preparation () in
      let+ record=Steps.retain ~store:fixture.store later |> Result.map_error Steps.error_to_string in record,later)) |> get
let seed_floor_replacement fixture ~stage record step =
  let module Step=Keeper_librarian_floor_step_request in
  let module Steps=Keeper_librarian_floor_step_owner in
  let ended=memory_action fixture (fun () -> Steps.resume ~store:fixture.store ~config:fixture.config
    ~reserved:(Keeper_librarian_durable_edge.reserved ()) ~original:record ~step
    ~call:(fun ~expected:_ ~original:_ ~arguments:_ -> fail "known pre-admission ending called a worker"))
    |> Result.map_error Steps.error_to_string |> get in
  let record=match ended with Steps.Before_dispatch_replaced record -> record
    | Pending _ | Answered _ | Refused _ -> fail "seeded captured question was not actually ended" in
  let actual=memory_action fixture (fun () -> Keeper_librarian_durable_edge.observe_destination
    ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ()) (Step.destination step))
    |> Result.map_error Lane_addon_submit_once.error_to_string |> get in
  let child=Step.replace_declaration ~request_id:(Step.fresh_request_id (Step.physical_owner step))
    ~destination:actual step |> get in
  let intended:Progress.preparation_intent={request_id=Step.request_id child;request=Step.to_json child} in
  let parent=advance_original fixture record (Progress.Replacement_intended intended) in
  (match stage with
   | Replacement_intent_saved -> ()
   | Replacement_child_saved | Replacement_ack_saved ->
     ignore (memory_action fixture (fun () -> Steps.retain ~store:fixture.store child)
       |> Result.map_error Steps.error_to_string |> get);
     if stage=Replacement_ack_saved then ignore (advance_original fixture parent (Progress.Replacement_observed intended.request_id))
   | Captured_question | Host_ended_question | Replacement_intent_rollback | Later_captured_question ->
     fail "replacement seed stage has no intended publication");
  intended.request_id
let test_cut_owned_full_source_floor ?(production=false) ?(change_semantic=false) ?replacement ?after_capture
    ?(interrupt_after_ack=false) history_kind ~refuse_message () =
  let module Floor=Keeper_librarian_history_resolution_floor in
  let module Steps=Keeper_librarian_floor_step_owner in
  let module Step=Keeper_librarian_floor_step_request in
  let module Settled=Keeper_librarian_history_program_settlement in
  with_same_binding_cut ~history_kind (fun fixture original parent_request exact _schema ->
    Eio.Switch.run (fun sw ->
    let positions=cut_source_positions fixture and parent=Owner.to_json original in
    let host=io (fun () -> Store.load_exact_request fixture.store ~declaration_id:"librarian"
      ~request_id:exact.Exact.request_id |> get) in
    let original_override=(Prompt_registry.resolve_prompt Prompt_names.librarian).override_value in
    let restore_prompt ()=match original_override with
      | None -> Prompt_registry.clear_prompt_override Prompt_names.librarian
      | Some value -> Prompt_registry.set_override Prompt_names.librarian value |> get in
    let blocked,arrived=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
    Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () ->
      ignore (Eio.Promise.try_resolve unblock ());
      (match Memory_lane.with_librarian_purge ~base_path:fixture.base_path ~keeper_name (fun () -> ()) with
       | Ok () -> () | Error error -> fail (Memory_lane.purge_cancel_error_to_string error));
      restore_prompt ())) (fun () ->
      let leaf_template=(Prompt_registry.resolve_prompt Prompt_names.librarian).effective ^ "\nFrozen leaf floor template" in
      Prompt_registry.set_override Prompt_names.librarian leaf_template |> get;
      assert_pending (memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config
        ~keeper_name ~wake:(fun () -> ())));
      let child=match (last_cut_intent fixture original).phase with
        | Child_confirmed child -> child
        | Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _ -> fail "Cut has no confirmed child" in
      fixture.set_response (fun capture ->
        check string "the capacity refusal belongs only to the exact child" child.request_id (Capture.request_id capture);
        size_refusal);
      let before= !(fixture.deliveries) in
      assert_pending (run_worker fixture);await_delivery fixture ~after:before;
      (match run_worker fixture with
       | Ok (Consumer.Memory_not_committed _) -> ()
       | Ok _ -> fail "the exact child did not retain its actual input refusal"
       | Error error -> fail (Consumer.error_to_string error));
      let leaf,request=io (fun () ->
        let leaf=Owner.load ~store:fixture.store ~scope:original.scope ~request_id:child.request_id |> owned |> Option.get in
        leaf,Capture.restore ~owner:(Capture.physical_owner parent_request) leaf |> get) in
      check bool "the definite leaf owns a different sealed template from its Cut parent" true
        ((Capture.preparation request).prompt<>(Capture.preparation parent_request).prompt);
      if change_semantic then (
        let changed=fixture.declaration true |> String.split_on_char '\n'
          |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-fresh-retained-floor\"" | line -> line)
          |> String.concat "\n" in
        replace_actual_worker_configuration fixture ~sw changed);
      let selected=Floor.candidate ~store:fixture.store ~record:leaf ~request |> get
        |> Option.to_result ~none:"actual Cut capacity descendant was not a floor candidate" |> get in
      let replaced=Option.map (fun stage ->
        let record,step=match stage with
          | Later_captured_question -> retain_actual_floor_later fixture request
          | Captured_question | Host_ended_question | Replacement_intent_saved | Replacement_child_saved
          | Replacement_ack_saved | Replacement_intent_rollback -> retain_actual_floor_first fixture request in
        let captured=io (fun () -> Fs_compat.load_file (Filename.concat
          (Store.directory ~masc_dir:(Common.masc_dir_from_base_path ~base_path:fixture.base_path))
          (Store.tool_request_body_path ~scope:record.scope ~request_digest:record.request_digest))) in
        let dispatched=match stage with
          | Host_ended_question -> advance_original fixture record Progress.Dispatch_intended
          | Captured_question | Replacement_intent_saved | Replacement_child_saved | Replacement_ack_saved
          | Replacement_intent_rollback | Later_captured_question -> record in
        let changed=fixture.declaration true |> String.split_on_char '\n'
          |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-captured-floor-replacement\"" | line -> line)
          |> String.concat "\n" in
        replace_actual_worker_configuration fixture ~sw changed;
        let expected_child=match stage with
          | Captured_question | Later_captured_question -> None
          | Host_ended_question ->
            let exact=Step.request step |> get in
            let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
              |> Result.map_error Lane_addon_manifest.error_to_string |> get in
            (match memory_action fixture (fun () -> Exact.run ~store:fixture.store ~declaration_id:"librarian"
                ~package ~runner:(Server_lane_addon_exact.runner ~base_path:fixture.base_path)
                ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path:fixture.base_path) exact) |> get with
             | Exact.Final (Not_allowed {reason=Replaced_declaration}) -> ()
             | Final _ | Not_final _ -> fail "actual host did not retain the typed step declaration ending");
            ignore dispatched;None
          | Replacement_intent_saved | Replacement_child_saved | Replacement_ack_saved ->
            Some (seed_floor_replacement fixture ~stage record step)
          | Replacement_intent_rollback ->
            let child_id=seed_floor_replacement fixture ~stage:Replacement_intent_saved record step in
            let parent=io (fun () -> Owner.load ~store:fixture.store ~scope:record.scope ~request_id:record.request_id
              |> owned |> Option.get) in
            let intended=match Progress.replacement parent.progress with Some (Preparation_pending intended) -> intended
              | None | Some (Preparation_confirmed _) -> fail "rollback has no original full pending intent" in
            let posts=F.post_count fixture.server and memory=cut_memory_bytes fixture in
            replace_actual_worker_configuration fixture ~sw (fixture.declaration true);
            let recovered=memory_action fixture (fun () -> Keeper_librarian_retained_step_replacement.resume
              ~store:fixture.store ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ())
              ~original:parent ~step) |> get in
            check string "rollback retains and ACKs the same already intended child" child_id recovered;
            let child=io (fun () -> Owner.load ~store:fixture.store ~scope:record.scope ~request_id:child_id
              |> owned |> Option.get) in
            check json "rollback cannot rewrite the pending child's captured declaration or question"
              (Lane_addon_action.canonical intended.request |> get) (Lane_addon_action.canonical child.request |> get);
            check int "rollback publication asks no provider question" posts (F.post_count fixture.server);
            check bool "rollback publication moves no source or Memory frontier" true
              (cut_source_positions fixture=positions && cut_memory_bytes fixture=memory);
            None in
        check int "the complete retained coordinate graph passes deployment preflight" 0
          (List.length (librarian_refusals fixture));
        Option.iter (fun check -> check ~sw fixture leaf request record step) after_capture;
        record,step,captured,expected_child) replacement in
      let step_calls=ref 0 in
      fixture.set_step_response (fun body ->
        incr step_calls;
        check bool "the provider receives the definite leaf's frozen template" true
          (Astring.String.is_infix ~affix:"Frozen leaf floor template" body);
        check bool "later live template changes do not reach a retained question" false
          (Astring.String.is_infix ~affix:"Changed live template" body);
        if !step_calls=1 then (ignore (Eio.Promise.try_resolve arrived ());Eio.Promise.await release);
        if refuse_message then size_refusal else `OK,F.openai_response (`Assoc [
          "new_claims",`List [new_claim (Printf.sprintf "Retained message %d was read" !step_calls)];
          "dropped",`List [];"working_state",`String "Retained source state";"working_contexts",`List []]));
      let run ()=if production then
          (match memory_action fixture (fun () -> Resolution_work.run_pending_serialized
             ~config:fixture.config ~keeper_name) |> Result.map_error Resolution_intent.error_to_string |> get with
           | Some pending -> `Pending pending
           | None -> `Completed)
        else match memory_action fixture (fun () -> Floor.descend ~config:fixture.config
          ~reserved:(Keeper_librarian_durable_edge.reserved ()) selected) |> get with
          | Floor.Pending pending -> `Pending pending
          | Attention attention -> `Attention attention
          | Prepared prepared -> `Prepared prepared in
      let initial=run () in
      let initial=match replaced,initial with
        | Some _,`Pending (Keeper_librarian_pending.Message_floor _) -> run ()
        | (None | Some _),(`Pending _ | `Attention _ | `Prepared _ | `Completed) -> initial in
      let waiting=match initial with
        | `Pending (Keeper_librarian_pending.Worker worker) -> worker.request_id
        | `Pending _ | `Attention _ | `Prepared _ | `Completed -> fail "the first retained message did not await its actual worker" in
      Eio.Promise.await blocked;
      (match replaced with
       | None -> ()
       | Some (parent,old_step,captured,expected_child) ->
         check bool "replacement never submits the ended original step again" true (waiting<>parent.request_id);
         Option.iter (fun expected -> check string "durable boundary recovery keeps its exact intended child ID" expected waiting) expected_child;
         let old=io (fun () -> Owner.load ~store:fixture.store ~scope:parent.scope ~request_id:parent.request_id |> owned |> Option.get) in
         let intended=match Progress.replacement old.progress with Some (Preparation_confirmed intended) -> intended
           | None | Some (Preparation_pending _) -> fail "child ran before the parent's exact publication ACK" in
         (match replacement with
          | Some Replacement_ack_saved ->
            let posts=F.post_count fixture.server and memory=cut_memory_bytes fixture
              and positions=cut_source_positions fixture in
            let repeated=memory_action fixture (fun () -> Keeper_librarian_retained_step_replacement.resume
              ~store:fixture.store ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ())
              ~original:old ~step:old_step) |> get in
            check string "a confirmed publication keeps its same child while the actual provider is pending"
              intended.request_id repeated;
            let reread=io (fun () -> Owner.load ~store:fixture.store ~scope:parent.scope ~request_id:parent.request_id
              |> owned |> Option.get) in
            check json "confirmed reobservation appends no second publication ACK or other parent event"
              (Owner.to_json old) (Owner.to_json reread);
            check int "confirmed reobservation sends no additional provider question" posts (F.post_count fixture.server);
            check bool "confirmed reobservation writes no Memory or range receipt" true (cut_memory_bytes fixture=memory);
            check bool "confirmed reobservation advances no source ACK" true (cut_source_positions fixture=positions)
          | None | Some (Captured_question | Host_ended_question | Replacement_intent_saved | Replacement_child_saved
            | Replacement_intent_rollback | Later_captured_question) -> ());
         let dispatched=match replacement with
           | Some Replacement_intent_rollback ->
             let retained=io (fun () -> Owner.load ~store:fixture.store ~scope:parent.scope ~request_id:intended.request_id
               |> owned |> Option.get) in
             check json "rollback preserves the complete originally intended intermediate question"
               (Lane_addon_action.canonical intended.request |> get) (Lane_addon_action.canonical retained.request |> get);
             (match Progress.replacement retained.progress with
              | Some (Preparation_confirmed next) ->
                let posts=F.post_count fixture.server in
                let repeated=memory_action fixture (fun () -> Keeper_librarian_retained_step_replacement.resume
                  ~store:fixture.store ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ())
                  ~original:old ~step:old_step) |> get in
                check string "an older confirmed publication still returns its same child after another replacement"
                  intended.request_id repeated;
                check int "observing an older confirmed publication adds no provider call" posts (F.post_count fixture.server);
                next.request_id
              | None | Some (Preparation_pending _) -> fail "the rolled-back intermediate question has no confirmed successor")
           | None | Some (Captured_question | Host_ended_question | Replacement_intent_saved
             | Replacement_child_saved | Replacement_ack_saved | Later_captured_question) -> intended.request_id in
         check string "confirmed publication lineage names the actual dispatched child" waiting dispatched;
         let actual=io (fun () -> Owner.load ~store:fixture.store ~scope:parent.scope ~request_id:waiting |> owned |> Option.get) in
         let child=Step.restore ~owner:(Step.physical_owner old_step) actual |> get in
         let expected=Step.replace_declaration ~request_id:waiting ~destination:(Step.destination child) old_step |> get in
         check json "saved child keeps the complete frozen question, coordinate and initial basis"
           (Lane_addon_action.canonical (Step.to_json expected) |> get) (Lane_addon_action.canonical actual.request |> get);
         check string "the sole original basis body is preserved byte for byte" captured
           (io (fun () -> Fs_compat.load_file (Filename.concat
             (Store.directory ~masc_dir:(Common.masc_dir_from_base_path ~base_path:fixture.base_path))
             (Store.tool_request_body_path ~scope:parent.scope ~request_digest:parent.request_digest))));
         check bool "no source was acknowledged while the replacement request is pending" true (cut_source_positions fixture=positions));
      let first_basis,transaction_id=let owner=Capture.physical_owner request in
        let identity:Keeper_librarian_runtime.retained_step_source={request_id=Capture.request_id request;
          request_digest=Capture.body_digest request;source_basis_digest=Capture.source_basis_digest request |> get} in
        let found=io (fun () -> Keeper_librarian_retained_step_replacement.read ~store:fixture.store ~owner
          ~range:{request_id=identity.request_id;request_digest=identity.request_digest} ~source:identity) |> get in
        let first=match Keeper_librarian_retained_step_replacement.steps found with
          | (_,first)::_ -> first
          | [] -> fail "actual floor has no selected initial question" in
        if change_semantic then check bool "the fresh first question captured the actual changed Runtime configuration" true
          (match Lane_addon_captured_destination.relation ~captured:(Capture.destination request)
            ~current:(Step.destination first) with
           | Lane_addon_captured_destination.Replaced -> true
           | Same | Other_owner -> false);
        Step.chain_basis first |> Option.get,Step.transaction_id first in
      let posts=F.post_count fixture.server in
      check int "ordinary cleanup cannot archive the retained Cut's in-flight question" 0
        (memory_action fixture (fun () -> Keeper_librarian_floor_cleanup.cleanup ~store:fixture.store
          ~owner:(Capture.physical_owner request) ~candidates:[] ~settled:[]) |> get);
      let unrelated=Types.observed ~claim:"Unrelated concurrent Memory" ~category:Types.Fact
        ~now:42. ~origin:{kind=Types.Authored;trace_id="cut-floor-concurrent"} in
      memory_action fixture (fun () -> io (fun () -> Current.apply_disposition ~pass:Keeper_memory_commit_pass.Durable
        ~absorbed:[] ~revisions:[] ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name ~now:(Time_compat.now ())
        ~source:{kind=Current.Librarian;trace_id} ~new_claims:[unrelated] () |> get)) |> ignore;
      Prompt_registry.set_override Prompt_names.librarian (leaf_template ^ "\nChanged live template") |> get;
      (match run () with
       | `Pending (Keeper_librarian_pending.Worker worker) ->
         check string "basis change pins the actual pending message ID" waiting worker.request_id
       | `Pending _ | `Attention _ | `Prepared _ | `Completed -> fail "basis change dropped or replaced pending work");
      check int "reobservation sends no new provider question" posts (F.post_count fixture.server);
      let before= !(fixture.deliveries) in
      ignore (Eio.Promise.try_resolve unblock ());await_delivery fixture ~after:before;
      let rec drive remaining =
        let before= !(fixture.deliveries) in
        match run () with
        | `Pending (Keeper_librarian_pending.Worker _) when remaining>0 ->
          await_delivery fixture ~after:before;drive (remaining-1)
        | result -> result in
      let result=drive (List.length (Source.input (Capture.source request)).messages) in
      if refuse_message then (
        (match result with `Attention (Floor.Message_refused {position=0;_}) -> ()
         | `Pending _ | `Attention _ | `Prepared _ | `Completed -> fail "a refused single message became a completed program");
        check bool "a refused message publishes no program" true (Floor.recover_committed selected |> get=None);
        let posts=F.post_count fixture.server in
        ignore (run ());check int "a stopped message retains its final instead of minting another question" posts
          (F.post_count fixture.server))
      else (
        let proof=match result with
          | `Prepared prepared ->
            let publish ()=memory_action fixture (fun () -> Floor.publish selected prepared) in
            let proof=publish () |> get in
            let positions=cut_source_positions fixture and memory=cut_memory_bytes fixture in
            let replay=publish () |> get in
            check bool "repeated direct publication returns the same canonical proof" true
              (replay.publication=proof.publication);
            check bool "repeated direct publication never automatically ACKs receipts" true
              (cut_source_positions fixture=positions && cut_memory_bytes fixture=memory);
            let journal=Current.journal_path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
            let original_journal=io (fun () -> Fs_compat.load_file_opt journal |> Option.get) in
            let removed=ref 0 in
            let unmarked=String.split_on_char '\n' original_journal |> List.map (function
              | "" -> ""
              | line ->
                let json=Yojson.Safe.from_string line in
                (match Keeper_memory_os_journal_codec.journal_entry_of_json json |> get with
                 | Keeper_memory_os_current_types.Journal_committed {program=Some publication;_}
                     when publication.execution.program.transaction_id=transaction_id ->
                   incr removed;
                   (match json with
                    | `Assoc fields -> Yojson.Safe.to_string (`Assoc (List.remove_assoc "ordered_program" fields))
                    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
                      fail "actual program journal is not an object")
                 | Journal_committed _ | Journal_failed _ | Journal_quarantined _ -> line))
              |> String.concat "\n" in
            check int "the negative fixture removes exactly the actual canonical transaction marker" 1 !removed;
            Fun.protect ~finally:(fun () -> io (fun () -> write journal original_journal)) (fun () ->
              io (fun () -> write journal unmarked);
              check bool "range receipts without the canonical program cannot republish" true (Result.is_error (publish ()));
              check bool "failed canonical readback never prematurely ACKs a receipt" true (cut_source_positions fixture=positions));
            proof
          | `Completed when production -> memory_action fixture (fun () -> io (fun () ->
              Keeper_librarian_durable_source_lock.with_original_settlement ~request (fun () ->
                Current.read_committed_program ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
                  ~transaction_id))) |> get |> Option.get
          | `Pending _ | `Attention _ | `Completed -> fail "the complete retained source did not reach a finished program" in
        check int "all original source range kinds commit together" (if history_kind=Mixed then 2 else 1)
          (List.length proof.receipts);
        check bool "every original message is read, with no unread holes" true
          (proof.publication.execution.program.unread=[]
           && proof.publication.execution.program.sources=first_basis.sources);
        check bool "publication retains concurrent unrelated Memory" true
          (List.mem "Unrelated concurrent Memory" (io (fun () -> claims fixture.keepers_dir)));
        if not production then
          check bool "a real canonical program before ACK is not source settlement evidence" true
            (Result.is_error (memory_action fixture (fun () -> io (fun () ->
              Settled.observe ~store:fixture.store ~request ~record:leaf ~program:proof))));
        if interrupt_after_ack then (
          let bytes=cut_memory_bytes fixture and posts=F.post_count fixture.server in
          let interrupted=try
            ignore (memory_action fixture (fun () -> io (fun () ->
              Commit.For_testing.settle_program ~after_settlement:(fun () -> raise Exit)
                ~store:fixture.store ~floor:selected ~program:proof)) |> get);
            false
          with Exit -> true in
          check bool "the real post-ACK path was interrupted before returning completion evidence" true interrupted;
          check bool "the source ACK persisted before the interruption" true (cut_source_positions fixture<>positions);
          check bool "the interrupted unit did not retain completion" true
            ((last_cut_intent fixture original).memory_commit=None);
          check bool "ordinary Work recovers the same actual program after post-ACK interruption" true
            (memory_action fixture (fun () -> Resolution_work.run_pending_serialized
               ~config:fixture.config ~keeper_name) |> Result.map_error Resolution_intent.error_to_string |> get=None);
          check bool "post-ACK recovery writes no second Memory or range receipt" true (cut_memory_bytes fixture=bytes);
          check int "post-ACK recovery replays no provider request" posts (F.post_count fixture.server));
        if production || interrupt_after_ack then (
          let completed=last_cut_intent fixture original in
          check bool "ordinary Work retains actual program completion for the exact refused child" true
            (match completed.memory_commit with
             | Some completed -> completed.request_id=leaf.request_id && completed.receipts=proof.receipts
             | None -> false);
          check bool "actual program completion releases the original selection fence" true
            (Result.is_ok (io (fun () -> Keeper_librarian_history_resolution_selection.check
              ~config:fixture.config ~keeper_name)));
          check bool "ordinary Work actually ACKs all original source positions" true
            (cut_source_positions fixture<>positions);
          let through=Keeper_librarian_input_sources.external_through (Source.counterparts (Capture.source request)) in
          check bool "external ACK is the original full counterpart frontier" true (io (fun () ->
            let cursor=Keeper_external_read_cursor.observe ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config)
              ~keeper_name |> get in
            Keeper_external_read_cursor.observation_matches_preparation cursor ~after:through ~through ~atom:None ~official:None));
          let actual=memory_action fixture (fun () -> io (fun () ->
            Settled.observe ~store:fixture.store ~request ~record:leaf ~program:proof)) |> get in
          let retained=Settled.retained actual in
          check bool "integral original fact timestamps remain in the actual proof" true
            (List.exists (fun (fact:Types.fact) -> fact.first_seen=42. && fact.last_seen=42.)
              retained.publication.execution.initial_facts);
          let canonical=Lane_addon_action.canonical (Settled.retained_to_json retained) |> get in
          let restored=Settled.retained_of_json canonical |> get in
          check bool "outer intent normalization preserves exact publication evidence" true
            (restored.publication=retained.publication);
          let receipt_path=Current.durable_range_receipt_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
          let receipt_bytes=io (fun () -> Fs_compat.load_file receipt_path) in
          let receipts,_=io (fun () -> Keeper_memory_os_current_range_codec.read_durable_range_receipts
            ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get) in
          let partial=List.filter (fun receipt -> match Keeper_memory_os_current_receipt_store.receipt_range_id receipt with
            | Keeper_memory_os_current_types.Atom_range _ -> true
            | Official_range _ | Explicit_candidate _ | Explicit_candidate_with_recall _ -> false) receipts in
          Fun.protect ~finally:(fun () -> io (fun () -> write receipt_path receipt_bytes)) (fun () ->
            io (fun () -> Keeper_memory_os_current_receipt_store.write_durable_range_receipts
              ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name partial |> get);
            check bool "post-ACK proof refuses an actual missing Mixed receipt" true
              (Result.is_error (memory_action fixture (fun () -> io (fun () -> Settled.observe
                ~store:fixture.store ~request ~record:leaf ~program:proof)))));
          let first=Steps.discover ~store:fixture.store ~owner:(Capture.physical_owner request)
            |> Result.map_error Steps.error_to_string |> get
            |> List.find (fun (_, (index:Step.index)) -> index.header.range.request_id=leaf.request_id
              && index.header.position=0) in
          let first_record,_=Steps.load ~store:fixture.store first |> Result.map_error Steps.error_to_string |> get in
          let first_path=Filename.concat (Store.root fixture.store)
            (Store.tool_request_body_path ~scope:first_record.scope ~request_digest:first_record.request_digest) in
          let first_bytes=io (fun () -> Fs_compat.load_file first_path) in
          Fun.protect ~finally:(fun () -> io (fun () -> write first_path first_bytes)) (fun () ->
            io (fun () -> Sys.remove first_path);
            check bool "Memory and ACK alone cannot replace the actual retained first question" true
              (Result.is_error (memory_action fixture (fun () -> io (fun () -> Settled.observe
                ~store:fixture.store ~request ~record:leaf ~program:proof)))));
          let owner=Capture.physical_owner request in
          let unrelated=Keeper_librarian_durable_edge.with_destination ~config:fixture.config
            ~reserved:(Keeper_librarian_durable_edge.reserved ()) (fun destination ->
              let request=Capture.create ~request_id:(Capture.fresh_request_id owner) ~owner ~destination
                ~source:(Capture.source request) ~preparation:(Capture.preparation request) () |> get in
              Durable_owner.retain ~store:fixture.store request
                |> Result.map_error Durable_owner.error_to_string) |> get in
          let honest=io (fun () -> Store.load_history_resolution fixture.store ~scope:original.scope
            ~request_id:original.request_id |> get |> Option.get) in
          let publish_intent expected next=io (fun () ->
            match Store.publish_history_resolution fixture.store ~scope:original.scope
              ~request_id:original.request_id ~expected:(Some expected) ~next |> get with
            | Store.History_resolution_stored -> ()
            | History_resolution_changed | History_resolution_unconfirmed _ -> fail "fixture intent CAS did not commit") in
          let other=match honest with
            | `Assoc fields -> `Assoc (List.map (fun (name,value) -> name,
                if name<>"intents" then value else match value with
                | `List intents -> `List (List.map (function
                    | `Assoc fields -> `Assoc (List.map (fun (name,value) -> name,
                        if name="memory_commit" then `Null else if name="phase" then
                          `Assoc ["kind",`String "child_confirmed";"child",`Assoc [
                            "request_id",`String unrelated.request_id;"request_digest",`String unrelated.request_digest]]
                        else value) fields)
                    | _ -> fail "fixture intent is not an object") intents)
                | _ -> fail "fixture intents are not a list") fields)
            | _ -> fail "fixture intent envelope is not an object" in
          Fun.protect ~finally:(fun () ->
            publish_intent other honest;
            io (fun () -> Owner.settle ~store:fixture.store
              ~date:(Capture.minted_on unrelated.request_id |> get) (Owner.listed unrelated)
              |> Result.map_error Owner.settle_error_to_string |> get)) (fun () ->
            publish_intent honest other;
            let changed=Resolution_intent.decode_published ~scope:original.scope ~request_id:original.request_id other
              |> get |> List.rev |> List.hd in
            check bool "an actual same-source unrelated child cannot borrow a completed descendant proof" true
              (Result.is_error (memory_action fixture (fun () -> io (fun () ->
                Resolution_intent.observe_program_commit ~store:fixture.store ~expected:changed ~settled:actual)))));
          let bytes=cut_memory_bytes fixture and positions=cut_source_positions fixture and posts=F.post_count fixture.server in
          for _=1 to 2 do
            (match run_worker fixture with Ok _ -> () | Error error -> fail (Consumer.error_to_string error));
            check bool "repeated ordinary wakes write no additional Memory or receipt" true (cut_memory_bytes fixture=bytes);
            check bool "repeated ordinary wakes preserve the already settled frontiers" true (cut_source_positions fixture=positions);
            check int "repeated ordinary wakes replay no parent, child or floor RPC" posts (F.post_count fixture.server)
          done)
        else (
          let recovered=Floor.recover_committed selected |> get |> Option.get in
          check bool "restart reads the same canonical publication" true (recovered.publication=proof.publication)));
      let owner=Capture.physical_owner request in
      let steps=Steps.discover ~store:fixture.store ~owner |> Result.map_error Steps.error_to_string |> get in
      List.iter (fun listed ->
        let record,_=Steps.load ~store:fixture.store listed |> Result.map_error Steps.error_to_string |> get in
        let step=Step.restore ~owner record |> get |> Step.step in
        check bool "steps use the definite leaf's frozen template and complete working context" true
          (step.preparation.prompt=(Capture.preparation request).prompt
           && step.preparation.source_input.working_context=(Capture.preparation request).source_input.working_context)) steps;
      if not (production || interrupt_after_ack) then check bool "neither floor decisions nor Memory publication ACK the source" true
        (cut_source_positions fixture=positions);
      check json "the Cut parent Unknown remains unchanged" parent (io (fun () ->
        Owner.load ~store:fixture.store ~scope:original.scope ~request_id:original.request_id |> owned |> Option.get |> Owner.to_json));
      check bool "no wake replays or changes the original host Cut request" true
        (host=io (fun () -> Store.load_exact_request fixture.store ~declaration_id:"librarian"
          ~request_id:exact.request_id |> get));
      if production || interrupt_after_ack then (
        let completed=last_cut_intent fixture original in
        let first=List.find (fun (_, (index:Step.index)) -> index.header.range.request_id=leaf.request_id
          && index.header.position=0) steps |> fst in
        let first_path=Filename.concat (Store.root fixture.store) (Store.tool_request_body_path
          ~scope:(Owner.Record.scope first) ~request_digest:(Owner.Record.request_digest first)) in
        let receipt_path=Current.durable_range_receipt_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
        let first_bytes,receipt_bytes=io (fun () -> Fs_compat.load_file first_path,Fs_compat.load_file receipt_path) in
        Fun.protect ~finally:(fun () -> io (fun () -> write first_path first_bytes;write receipt_path receipt_bytes)) (fun () ->
          io (fun () -> Sys.remove first_path;
            Keeper_memory_os_current_receipt_store.write_durable_range_receipts
              ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name [] |> get);
          let reread=last_cut_intent fixture original in
          check json "durable ordered completion survives unavailable step bytes and moving receipts"
            (Resolution_intent.to_public_json completed) (Resolution_intent.to_public_json reread);
          check bool "stored completion retains the full canonical program" true
            (match reread.memory_commit with Some {program=Some _;_} -> true | None | Some {program=None;_} -> false);
          check bool "selection reads retained completion independently of old storage artifacts" true
            (Result.is_ok (io (fun () -> Keeper_librarian_history_resolution_selection.check
              ~config:fixture.config ~keeper_name))))))))

type unsafe_retained_question = Unknown_question | Permission_question | Malformed_question_proof
  | Completed_question_proof | Gate_question | Changed_replacement_question | Unacknowledged_question_dispatch
  | Wrong_retained_child
exception Retained_question_negative_checked
let test_retained_question_replacement_refuses_unsafe_state unsafe () =
  let module Step=Keeper_librarian_floor_step_request in
  let module Replacement=Keeper_librarian_retained_step_replacement in
  let checked ~sw fixture (leaf:Owner.retained) request (original:Owner.retained) step =
    let step_output=`Assoc ["new_claims",`List [new_claim "Actual retained negative-fixture message"];
      "dropped",`List [];"working_state",`String "Retained fixture state";"working_contexts",`List []] in
    let owner=Step.physical_owner step and exact=Step.request step |> get in
    let positions=cut_source_positions fixture and memory=cut_memory_bytes fixture in
    let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
      |> Result.map_error Lane_addon_manifest.error_to_string |> get in
    let run_exact ()=Exact.run ~store:fixture.store ~declaration_id:"librarian"
      ~package ~runner:(Server_lane_addon_exact.runner ~base_path:fixture.base_path)
      ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path:fixture.base_path) exact in
    let replace source=replace_actual_worker_configuration fixture ~sw source in
    let changed=fixture.declaration true |> String.split_on_char '\n'
      |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-negative-step-replacement\"" | line -> line)
      |> String.concat "\n" in
    let write_progress progress=io (fun () ->
      let record=Owner.record_to_json (Owner.listed original) in
      let record=match record with `Assoc fields -> `Assoc (List.map (fun (name,value) ->
          name,if name="progress" then Progress.to_json progress else value) fields)
        | _ -> fail "original owner metadata is not an object" in
      Store.save_tool_request_owner fixture.store ~scope:original.scope ~request_id:original.request_id record |> get) in
    let before_ending () =
      let current=memory_action fixture (fun () -> Keeper_librarian_durable_edge.observe_destination
        ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ()) (Step.destination step))
        |> Result.map_error Lane_addon_submit_once.error_to_string |> get in
      Progress.append Progress.captured (Progress.Refused {stage=Before_dispatch;
        evidence=Keeper_librarian_declaration_replacement.replaced_to_json
          {captured=Step.destination step;current}}) |> get in
    let after_execution final =
      Progress.append Progress.captured Progress.Dispatch_intended |> get
      |> fun progress -> Progress.append progress (Progress.Refused {stage=Execution;
        evidence=Exact.retained_final_to_json final}) |> get in
    (match unsafe with
     | Unknown_question ->
       replace (fixture.declaration true);
       ignore (advance_original fixture original Progress.Dispatch_intended);
       let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
       let stopped,finish=Eio.Promise.create () in
       fixture.set_step_response (fun _ ->
         ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
         `OK,F.openai_response step_output);
       Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () ->
         ignore (Eio.Promise.try_resolve unblock ());Eio.Promise.await stopped)) (fun () ->
         Eio.Fiber.fork ~sw (fun () -> Eio.Fiber.yield ();
           Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve finish ())) (fun () ->
             match run_exact () with
             | Ok _ | Error _ -> ()
             | exception Eio.Cancel.Cancelled _ -> ()));
         Eio.Promise.await arrived;
         (match Memory_lane.with_librarian_purge ~base_path:fixture.base_path ~keeper_name (fun () -> ()) with
          | Ok () -> () | Error error -> fail (Memory_lane.purge_cancel_error_to_string error));
         Eio.Promise.await stopped);
       let posts=F.post_count fixture.server in
       (* Reenter the actual host after the cancelled generation joined. Its
          Started marker becomes Cut here; read-only recovery does not close it. *)
       (match run_exact () |> get with
        | Exact.Final Outcome_unknown -> ()
        | Final (Call_final _ | Not_allowed _ | Request_id_reused) | Not_final _ ->
          fail "the joined original was not recovered as an unknown host outcome");
       check int "recovering the joined original sends no provider request" posts (F.post_count fixture.server);
       let retained=io (fun () -> Exact.recover_retained ~store:fixture.store ~declaration_id:"librarian"
         ~schema:(Option.get exact.schema) exact |> Result.map_error Exact.describe_recovery_error |> get) in
       (match retained with Exact.Retained_terminal (Retained_unknown Cut) -> ()
        | Retained_absent | Retained_open | Retained_terminal _ -> fail "the actual cancelled step has no host Cut evidence");
       write_progress (after_execution (Retained_unknown Cut));
       replace changed
     | Permission_question ->
       write_progress (after_execution (Retained_not_allowed {reason=Permission_refused {detail="ordinary original permission refusal"}}))
     | Malformed_question_proof ->
       write_progress (before_ending ());
       let path=Filename.concat (Store.root fixture.store)
         (Exact.Retained_key.proof_path (Exact.Retained_key.of_request ~declaration_id:"librarian" exact)) in
       io (fun () -> write path "{\"malformed_proof\":true}")
     | Completed_question_proof | Gate_question ->
       replace (fixture.declaration true);
       fixture.set_step_response (fun _ -> `OK,F.openai_response step_output);
       let answered=match run_exact () |> get with Exact.Final (Call_final (Answered _ as answered)) -> answered
         | Final _ | Not_final _ -> fail "the negative fixture lacks an actual completed generation proof" in
       (match unsafe with
        | Gate_question ->
          let module Journal=Keeper_librarian_floor_step_gate in
          let pending=advance_original fixture original Progress.Dispatch_intended in
          let judged=advance_original fixture pending (Progress.Judgment_retained (Exact.final_to_json (Call_final answered))) in
          let proposal=match answered with Exact.Answered {output;_} -> Exact.checked_json output
            | Invalid_output _ | Input_refused _ | Output_limit_reached _ -> fail "actual gate fixture lacks an answer" in
          let authority=Keeper_librarian_absorb_gate.resolve ~keeper_id:keeper_name in
          let intended=io (fun () -> Journal.prepare_root ~store:fixture.store ~owner ~capture:step ~parent:judged
            ~proposal ~request_id:(Random_id.uuid_v7 ()) ~authority) |> get in
          ignore (advance_original fixture judged (Progress.Preparation_intended intended));
          ignore (memory_action fixture (fun () -> io (fun () -> Journal.recover_root ~store:fixture.store ~owner ~capture:step)) |> get);
          let gates=io (fun () -> Journal.Inventory.read ~store:fixture.store ~owner) |> get in
          check bool "the refusal fixture has an actual orphan Gate" true
            (Journal.Inventory.execution_records gates ~execution_id:original.request_id<>[])
        | Completed_question_proof -> ()
        | Unknown_question | Permission_question | Malformed_question_proof | Changed_replacement_question
        | Unacknowledged_question_dispatch | Wrong_retained_child ->
          fail "wrong completed-proof fixture branch");
       replace changed;
       write_progress (before_ending ())
     | Changed_replacement_question ->
       let _=seed_floor_replacement fixture ~stage:Replacement_intent_saved original step in
       let parent=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope ~request_id:original.request_id |> owned |> Option.get) in
       let intended=match Progress.replacement parent.progress with Some (Preparation_pending intended) -> intended
         | None | Some (Preparation_confirmed _) -> fail "invalid child fixture lacks the full pending intent" in
       let changed_child=match intended.request with
         | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,
             if key="transaction_id" then `String "another-retained-program" else value) fields)
         | _ -> fail "saved replacement is not a full step object" in
       let progress=Progress.append Progress.captured
         (Progress.Refused {stage=Before_dispatch;evidence=Keeper_librarian_declaration_replacement.replaced_to_json
           {captured=Step.destination step;current=Step.destination (Step.of_json ~owner changed_child |> get)}}) |> get in
       let progress=Progress.append progress (Progress.Replacement_intended {intended with request=changed_child}) |> get in
       write_progress progress
     | Unacknowledged_question_dispatch ->
       let child_id=seed_floor_replacement fixture ~stage:Replacement_child_saved original step in
       let child=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope ~request_id:child_id
         |> owned |> Option.get) in
       let child=Step.restore ~owner child |> get in
       let posts=F.post_count fixture.server in
       let child_exact=Step.request child |> get in
       let run_child ()=Exact.run ~store:fixture.store ~declaration_id:"librarian" ~package
         ~runner:(Server_lane_addon_exact.runner ~base_path:fixture.base_path)
         ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path:fixture.base_path) child_exact in
       let authority=match Server_lane_addon_exact.authorize_request ~base_path:fixture.base_path
         ~store:fixture.store ~declaration_id:"librarian" ~package child_exact with
         | Ok authority -> authority
         | Error (Exact.Unowned {reason}) -> fail reason
         | Error (Undecided {detail}) -> fail detail in
       (match authority.Exact.before_dispatch () with
        | Error (Exact.Not_now _) -> ()
        | Ok () | Error Declaration_replaced -> fail "an unacknowledged child lacks its temporary dispatch veto");
       check bool "direct host dispatch waits for the parent ACK" true (Result.is_error (run_child ()));
       check int "direct host dispatch before the actual parent ACK reaches no provider" posts (F.post_count fixture.server);
       check bool "temporary dispatch veto retains no Exact record" true
         (io (fun () -> Store.load_exact_request fixture.store ~declaration_id:"librarian"
           ~request_id:child_id |> get)=None);
       check (option string) "temporary dispatch veto retains no execution proof" None
         (io (fun () -> Fs_compat.load_file_opt (proof_path fixture child_exact)));
       check int "an unexecuted pending child remains readable for deployment" 0 (List.length (librarian_refusals fixture));
       let parent=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
         ~request_id:original.request_id |> owned |> Option.get) in
       check bool "the veto leaves the same child pending its parent ACK" true
         (match Progress.replacement parent.progress with
          | Some (Preparation_pending intended) -> intended.request_id=child_id
          | None | Some (Preparation_confirmed _) -> false);
       let child_record=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
         ~request_id:child_id |> owned |> Option.get) in
       check bool "the veto preserves the unexecuted child phase" true (Progress.phase child_record.progress=Captured);
       let resumed=memory_action fixture (fun () -> Replacement.resume ~store:fixture.store
         ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ()) ~original:parent ~step) |> get in
       check string "normal ACK recovery reuses the retained child" child_id resumed;
       let acknowledged=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
         ~request_id:original.request_id |> owned |> Option.get) in
       check bool "normal recovery confirms the exact child publication" true
         (match Progress.replacement acknowledged.progress with
          | Some (Preparation_confirmed intended) -> intended.request_id=child_id
          | None | Some (Preparation_pending _) -> false);
       io (fun () -> Replacement.confirm_selected ~store:fixture.store child) |> get;
       check int "parent ACK itself reaches no provider" posts (F.post_count fixture.server);
       fixture.set_step_response (fun _ -> `OK,F.openai_response step_output);
       ignore (advance_original fixture child_record Progress.Dispatch_intended);
       (match run_child () |> get with
        | Exact.Final (Call_final (Answered _)) -> ()
        | Final (Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
            | Outcome_unknown | Not_allowed _ | Request_id_reused) | Not_final _ ->
          fail "the same child did not dispatch after its real parent ACK");
       check int "only the acknowledged child reaches the provider once" (posts+1) (F.post_count fixture.server);
       check bool "host recovery publishes no Memory or source ACK" true
         (cut_source_positions fixture=positions && cut_memory_bytes fixture=memory);
       raise Retained_question_negative_checked
     | Wrong_retained_child ->
       let module Steps=Keeper_librarian_floor_step_owner in
       let child_id=seed_floor_replacement fixture ~stage:Replacement_intent_saved original step in
       let parent=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope ~request_id:original.request_id
         |> owned |> Option.get) in
       let intended=match Progress.replacement parent.progress with Some (Preparation_pending intended) -> intended
         | None | Some (Preparation_confirmed _) -> fail "wrong-child fixture has no full pending intent" in
       let changed=match intended.request with
         | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,
             if key="transaction_id" then `String "wrong-retained-child-transaction" else value) fields)
         | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "the full child is not an object" in
       let child=Step.of_json ~owner changed |> get in
       check string "the conflicting retained child occupies the actual intended ID" child_id (Step.request_id child);
       ignore (memory_action fixture (fun () -> Steps.retain ~store:fixture.store child)
         |> Result.map_error Steps.error_to_string |> get));
    let posts=F.post_count fixture.server in
    let actual=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope ~request_id:original.request_id |> owned |> Option.get) in
    let records=io (fun () -> Owner.discover ~store:fixture.store ~scope:original.scope |> owned |> List.map Owner.record_to_json) in
    let retained_bodies ()=io (fun () -> Owner.discover ~store:fixture.store ~scope:original.scope |> owned
      |> List.map (fun record -> let path=Store.tool_request_body_path ~scope:(Owner.Record.scope record)
          ~request_digest:(Owner.Record.request_digest record) in
        path,Fs_compat.load_file (Filename.concat (Store.root fixture.store) path))) in
    let bodies=retained_bodies () in
    check bool "unsafe retained original cannot authorize a replacement child" true
      (Result.is_error (memory_action fixture (fun () -> Replacement.resume ~store:fixture.store ~config:fixture.config
        ~reserved:(Keeper_librarian_durable_edge.reserved ()) ~original:actual ~step)));
    check bool "a refused replacement preserves all original owner metadata" true
      (records=io (fun () -> Owner.discover ~store:fixture.store ~scope:original.scope |> owned |> List.map Owner.record_to_json));
    check bool "a refused replacement cannot overwrite any existing immutable body" true (retained_bodies ()=bodies);
    (match memory_action fixture (fun () -> Resolution_work.run_pending_serialized ~config:fixture.config ~keeper_name) with
     | Error _ | Ok (Some _) -> ()
     | Ok None -> fail "unsafe step was treated as complete source");
    check int "unsafe-state observation dispatches no new provider request" posts (F.post_count fixture.server);
    check bool "unsafe-state refusal preserves every source ACK frontier" true (cut_source_positions fixture=positions);
    check bool "unsafe-state refusal writes no Memory or receipt" true (cut_memory_bytes fixture=memory);
    check bool "the actual capacity-refused leaf still owns the same retained source" true
      (leaf.request_id=Capture.request_id request);
    raise Retained_question_negative_checked in
  try
    test_cut_owned_full_source_floor ~production:true ~replacement:Captured_question ~after_capture:checked
      Mixed ~refuse_message:false ();
    fail "the negative fixture did not reach the captured-step boundary"
  with Retained_question_negative_checked -> ()

let test_cut_command_recovers_fence_before_grant_after_memory_rebase () =
  with_same_binding_cut (fun fixture original _request _exact _schema ->
    let accepted=submit_cut_command fixture original in
    let basis=match accepted.intent.origin with Same_binding_cut basis -> basis | Worker_absence -> fail "Cut command origin" in
    let escaped=ref None in
    let interrupted=memory_action fixture (fun () ->
      Resolution.with_cut_fence_serialized ~config:fixture.config ~keeper_name ~request_id:original.request_id
        ~expected:accepted.intent.expected ~basis ~actor:accepted.intent.actor ~reason:accepted.intent.reason
        ~now:(Time_compat.now ()) ~use:(fun grant -> escaped:=Some grant;raise Exit)) in
    check bool "interruption after fence has an uncertain publication result" true
      (match interrupted with Error (Resolution.Publication_uncertain _) -> true
       | Ok _ | Error (Original_absent | Ineligible _ | Observation_changed | Range_already_recorded
         | Already_fenced _ | Unavailable _ | Host_claim_busy) -> false);
    check bool "the same command is still Requested" true ((last_cut_intent fixture original).phase=Requested);
    check bool "an escaped claim-scoped grant cannot persist Fenced" true
      (Result.is_error (io (fun () -> Resolution_intent.confirm_cut_fence ~store:fixture.store
        ~expected:accepted.intent (Option.get !escaped))));
    let fact=Types.observed ~claim:"Independent current Memory" ~category:Types.Fact
      ~now:(Time_compat.now ()) ~origin:{kind=Types.Authored;trace_id="independent-writer"} in
    memory_action fixture (fun () -> io (fun () -> Current.apply_disposition ~pass:Keeper_memory_commit_pass.Durable
      ~absorbed:[] ~revisions:[] ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
      ~now:(Time_compat.now ()) ~source:{kind=Current.Librarian;trace_id} ~new_claims:[fact] () |> get)) |> ignore;
    run_cut_command fixture |> Result.map_error Resolution_intent.error_to_string |> get;
    let intent=last_cut_intent fixture original in
    check string "recovery does not mint another command" accepted.intent.intent_id intent.intent_id;
    check bool "same fenced command recovers its child despite unrelated Memory" true
      (match intent.phase with Child_confirmed _ -> true
       | Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _ -> false);
    let first=Resolution_intent.child intent |> Option.get in
    run_cut_command fixture |> Result.map_error Resolution_intent.error_to_string |> get;
    check bool "later recovery retains that same child" true
      (Resolution_intent.child (last_cut_intent fixture original)=Some first))
let prepare_counterpart_only_cut (fixture:fixture) =
    let speaker : Keeper_chat_store.speaker =
      {speaker_id=Some "external";speaker_name=Some "External";speaker_authority=External} in
    Keeper_chat_store.append_user_message ~base_dir:fixture.base_path ~keeper_name
      ~conversation_id:"agent:cut-counterpart" ~external_message_id:"cut-counterpart-message"
      ~content:("Retained Cut counterpart " ^ String.make 65536 'x') ~speaker ();
    io (fun () ->
      official_turn fixture.config ~turn:2 ~time:(Time_compat.now () +. 10.);
      let session_dir=Keeper_fs.keeper_session_dir fixture.config trace_id in
      write (Keeper_turn_fragments.path ~session_dir Keeper_turn_fragments.Main)
        ({|{"ts_unix":1.0,"role":"user","content_blocks":[{"type":"text","text":"old"}]}|} ^ "\n");
      write (Keeper_turn_fragments.path ~session_dir Keeper_turn_fragments.Internal) "")
let test_capacity_refusal_checks_no_host_proof ~frame_refusal () =
  with_fixture ~history_kind:(if frame_refusal then Atoms else Official) (fun ~sw:_ fixture ->
    let module Refusal=Keeper_librarian_durable_refusal in
    if frame_refusal then (
      let oversized=selected_messages @ [message (String.init oversized_turn_bytes
        (fun index -> Char.chr (97 + index mod 26)));
        Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text "Oversized answer"]] in
      save_checkpoint fixture.config ~trace_id oversized 3;
      io (fun () -> append_boundary fixture.config ~turn:3 ~time:(Time_compat.now ())
        ~history_at_start:(Boundary.history_at_start_of_messages selected_messages) oversized))
    else prepare_counterpart_only_cut fixture;
    fixture.set_response (fun _ -> size_refusal);
    let refused=if frame_refusal then run_worker fixture else (
      let deliveries= !(fixture.deliveries) in
      assert_pending (run_worker fixture);
      await_delivery fixture ~after:deliveries;
      run_worker fixture) in
    (match frame_refusal,refused with
     | true,Ok (Consumer.Memory_not_committed [_])
     | false,Error (Consumer.Counterpart_input_capacity_refused _) -> ()
     | _,Error error -> fail (Consumer.error_to_string error)
     | _,Ok _ -> fail "the actual input was not refused by the expected owner");
    let record,request=only_original fixture in
    let exact=Capture.request request |> get in
    let schema=Option.to_result ~none:"capacity original schema" exact.Exact.schema |> get in
    let final=Exact.Call_final (Input_refused Request_body_refused) in
    let host_path=Filename.concat (Store.root fixture.store)
      (Store.exact_request_path ~declaration_id:"librarian" ~request_id:exact.request_id) in
    let proof=proof_path fixture exact in
    let host_bytes,proof_bytes=io (fun () -> Fs_compat.load_file_opt host_path,Fs_compat.load_file_opt proof) in
    check bool "only the worker frame refusal lacks host state" true
      (Option.is_none host_bytes=frame_refusal && Option.is_none proof_bytes=frame_refusal);
    check (result unit string) "the actual original refusal is confirmed" (Ok ())
      (io (fun () -> Capture.confirm_final ~store:fixture.store request final));
    check bool "the actual refusal supplies its named capacity evidence" true
      ((io (fun () -> Capture.refusal_evidence ~store:fixture.store request final) |> get)
       .Keeper_exact_walk_failure.provider_input_refusals=[Keeper_librarian_input_refusal.Request_body_refused]);
    if not frame_refusal then
      check bool "the valid counterpart refusal retains its ordinary abandonment policy" true
        (Result.is_ok (io (fun () -> Refusal.abandonment ~store:fixture.store ~record ~request)));
    let memory=cut_memory_bytes fixture and positions=cut_source_positions fixture in
    let progress_before=Progress.to_json record.progress and posts=F.post_count fixture.server in
    let restore ()=Eio.Cancel.protect (fun () -> io (fun () ->
      let file path = function
        | Some bytes -> write path bytes
        | None -> if Sys.file_exists path then Sys.remove path in
      file host_path host_bytes;file proof proof_bytes)) in
    Fun.protect ~finally:restore (fun () ->
      io (fun () -> if Sys.file_exists host_path then Sys.remove host_path);
      let corruptions=Option.to_list (Option.map (fun bytes -> "actual orphan execution proof",bytes) proof_bytes)
        @ ["unreadable execution proof","{"] in
      List.iter (fun (label,bytes) ->
        io (fun () -> write proof bytes);
        check bool (label ^ " has no host record") true
          ((io (fun () -> Exact.observe_retained ~store:fixture.store ~declaration_id:"librarian" ~schema exact)
            |> get)=Exact.Retained_absent);
        check bool (label ^ " is rejected by the actual proof reader") true
          (Result.is_error (io (fun () -> Exact.read_latest_original_execution
            ~store:fixture.store ~declaration_id:"librarian" ~schema exact)));
        check bool (label ^ " cannot confirm the worker's final") true
          (Result.is_error (io (fun () -> Capture.confirm_final ~store:fixture.store request final)));
        check bool (label ^ " supplies no capacity authority") true
          (Result.is_error (io (fun () -> Capture.refusal_evidence ~store:fixture.store request final)));
        if not frame_refusal then (
          check bool (label ^ " cannot authorize abandonment") true
            (Result.is_error (io (fun () -> Refusal.abandonment ~store:fixture.store ~record ~request)));
          check bool (label ^ " cannot use the public settlement adapter") true
            (Result.is_error (memory_action fixture (fun () -> io (fun () ->
              Commit.settle_refused ~store:fixture.store ~record ~request)))));
        check bool (label ^ " writes no Memory or receipt") true (cut_memory_bytes fixture=memory);
        check bool (label ^ " acknowledges no source") true (cut_source_positions fixture=positions);
        check json (label ^ " preserves the refusal") progress_before
          (io (fun () -> Owner.load ~store:fixture.store ~scope:record.scope ~request_id:record.request_id
            |> owned |> Option.get |> fun retained -> Progress.to_json retained.progress));
        check int (label ^ " starts no provider call") posts (F.post_count fixture.server)) corruptions);
    check (result unit string) "restoring actual host state confirms the same refusal" (Ok ())
      (io (fun () -> Capture.confirm_final ~store:fixture.store request final));
    if not frame_refusal then
      check bool "restoring actual proof restores the same ordinary abandonment policy" true
        (Result.is_ok (io (fun () -> Refusal.abandonment ~store:fixture.store ~record ~request)));
    check int "only the provider refusal called the fixture model" (if frame_refusal then 0 else 1)
      (F.post_count fixture.server))
let test_cut_ancestry_rejects_a_truncated_fenced_index () =
  with_same_binding_cut ~history_kind:Official ~before_capture:prepare_counterpart_only_cut
    (fun fixture original request _exact _schema ->
      let module Lineage=Keeper_librarian_history_resolution_lineage in
      let module Refusal=Keeper_librarian_durable_refusal in
      assert_pending (run_worker fixture);
      let middle=Resolution_intent.child (last_cut_intent fixture original) |> Option.get in
      let load id=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope ~request_id:id
        |> owned |> Option.get) in
      let advance record event=io (fun () -> match Owner.advance ~store:fixture.store ~expected:record ~event with
        | Ok (Owner.Stored record | Already_stored record) -> record
        | Ok (Unconfirmed detail) -> fail detail
        | Error error -> fail (Owner.update_error_to_string error)) in
      (* Simulate the retained journal after a dispatch lost its admission.
         The real resolver still has to prove host/proof absence and fence it. *)
      let absent=advance (load middle.request_id) Progress.Dispatch_intended in
      ignore (advance absent (Progress.Execution_observed (Progress.Absent (`Assoc []))));
      assert_pending (run_worker fixture);
      let middle_record=load middle.request_id in
      let middle_intent=last_cut_intent fixture middle_record in
      (match middle_intent.origin with
       | Resolution_intent.Worker_absence -> ()
       | Same_binding_cut _ -> fail "the intermediate original needs an actual absence resolution");
      let child=Resolution_intent.child middle_intent |> Option.get in
      let deliveries= !(fixture.deliveries) in
      fixture.set_response (fun capture ->
        check string "only the final descendant reaches the provider" child.request_id (Capture.request_id capture);
        size_refusal);
      assert_pending (run_worker fixture);
      await_delivery fixture ~after:deliveries;
      (match run_worker fixture with
       | Error (Consumer.Counterpart_input_capacity_refused _) -> ()
       | Error error -> fail (Consumer.error_to_string error)
       | Ok _ -> fail "the actual descendant did not retain its capacity refusal");
      let rejected=load child.request_id in
      let descendant=io (fun () -> Capture.restore ~owner:(Capture.physical_owner request) rejected |> get) in
      let obligation ()=io (fun () -> Lineage.refusal_obligation ~store:fixture.store descendant) in
      let check_cut ()=match obligation () |> get with
        | Lineage.Cut_read_required id -> check string "the intermediate absence preserves the Cut obligation" original.request_id id
        | No_cut_ancestor -> fail "the actual Cut ancestor disappeared" in
      check_cut ();
      let root=Store.root fixture.store in
      let record_path=Filename.concat (scope_directory fixture original.scope) (Store.digest middle.request_id ^ ".json") in
      let body_path=Filename.concat root (Store.tool_request_body_path ~scope:original.scope
        ~request_digest:middle.request_digest) in
      let record_bytes,body_bytes=io (fun () -> Fs_compat.load_file record_path,Fs_compat.load_file body_path) in
      let memory=cut_memory_bytes fixture and positions=cut_source_positions fixture in
      let rejected_before=Owner.to_json rejected and posts=F.post_count fixture.server in
      Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> io (fun () ->
        write record_path record_bytes;write body_path body_bytes))) (fun () ->
        io (fun () -> Sys.remove body_path);
        check_cut ();
        let changed=match Yojson.Safe.from_string record_bytes with
          | `Assoc fields -> `Assoc (List.map (fun (field,value) -> match field,value with
              | "summary",`Assoc summary -> field,`Assoc (List.map (fun (key,stored) ->
                  key,if key="predecessor" then `Null else stored) summary)
              | _ -> field,value) fields)
          | _ -> fail "the original record is not an object" in
        check bool "only the intermediate summary is changed" true
          (Yojson.Safe.to_string changed<>record_bytes);
        io (fun () -> write record_path (Yojson.Safe.to_string changed));
        let changed_record=io (fun () -> Owner.load_record ~store:fixture.store ~scope:original.scope
          ~request_id:middle.request_id |> owned |> Option.get) in
        check bool "the damaged index remains structurally valid" true
          (Result.is_ok (Capture.index_of_summary changed_record));
        check bool "the fence rejects the truncated predecessor without reading a pruned body" true
          (Result.is_error (obligation ()));
        check bool "a truncated ancestry cannot authorize source abandonment" true
          (Result.is_error (io (fun () -> Refusal.abandonment ~store:fixture.store ~record:rejected ~request:descendant)));
        check bool "the public adapter refuses the corrupted ancestry" true
          (Result.is_error (memory_action fixture (fun () -> io (fun () ->
            Commit.settle_refused ~store:fixture.store ~record:rejected ~request:descendant))));
        check bool "no empty Memory or receipt is written" true (cut_memory_bytes fixture=memory);
        check bool "no original source is acknowledged" true (cut_source_positions fixture=positions);
        check json "the descendant refusal is unchanged" rejected_before (Owner.to_json (load child.request_id));
        check int "the corrupt ancestry dispatches no provider request" posts (F.post_count fixture.server));
      check_cut ())
let test_root_cut_cannot_use_the_public_refusal_adapter () =
  with_same_binding_cut ~history_kind:Official ~before_capture:prepare_counterpart_only_cut
    (fun fixture original request exact schema ->
      let module Refusal=Keeper_librarian_durable_refusal in
      let module Lineage=Keeper_librarian_history_resolution_lineage in
      let input=Source.input (Capture.source request) in
      check bool "the actual root Cut is counterpart-only" true
        (input.messages=[] && input.tool_observations=[] && input.counterpart_observations<>[]);
      check bool "the root Cut has no effect fence yet" true (io (fun () ->
        Fence.read ~store:fixture.store ~scope:original.scope ~request_id:original.request_id |> get)=None);
      (match io (fun () -> Lineage.refusal_obligation ~store:fixture.store request |> get) with
       | No_cut_ancestor -> ()
       | Cut_read_required _ -> fail "fixture unexpectedly has a Cut ancestor");
      check bool "no Gate, replacement or settlement is present" true
        (Progress.preparation original.progress=None && Progress.replacement original.progress=None
         && Progress.settlement original.progress=None);
      check bool "the actual host still retains terminal Cut" true (io (fun () ->
        Exact.observe_retained ~store:fixture.store ~declaration_id:"librarian" ~schema exact |> get)
        = Exact.Retained_terminal (Exact.Retained_unknown Exact.Cut));
      let positions=cut_source_positions fixture and memory=cut_memory_bytes fixture in
      let parent=Owner.to_json original and posts=F.post_count fixture.server in
      check bool "Unknown has no typed capacity abandonment evidence" true
        (Result.is_error (io (fun () -> Refusal.abandonment ~store:fixture.store ~record:original ~request)));
      check bool "the public adapter rejects a real unfenced root Unknown" true
        (Result.is_error (memory_action fixture (fun () -> io (fun () ->
          Commit.settle_refused ~store:fixture.store ~request ~record:original))));
      check bool "root Unknown writes no Memory or receipt" true (cut_memory_bytes fixture=memory);
      check bool "root Unknown moves no source ACK" true (cut_source_positions fixture=positions);
      check json "root Unknown progress is preserved" parent (io (fun () ->
        Owner.load ~store:fixture.store ~scope:original.scope ~request_id:original.request_id
        |> owned |> Option.get |> Owner.to_json));
      check int "the adapter sends no original RPC" posts (F.post_count fixture.server))
let test_counterpart_cut_capacity_refusal_preserves_original_obligation () =
  with_same_binding_cut ~history_kind:Official ~before_capture:prepare_counterpart_only_cut (fun fixture original request exact _schema ->
    let module Refusal=Keeper_librarian_durable_refusal in
    let module Lineage=Keeper_librarian_history_resolution_lineage in
    let original_source=Capture.source request in
    let input=Source.input original_source in
    check bool "the actual Cut owns counterpart-only input" true
      (input.messages=[] && input.tool_observations=[] && input.counterpart_observations<>[]);
    let parent=Owner.to_json original in
    let host=io (fun () -> Store.load_exact_request fixture.store ~declaration_id:"librarian"
      ~request_id:exact.Exact.request_id |> get) in
    let fact=Types.observed ~claim:("Unrelated Memory growth " ^ String.make 1024 'm')
      ~category:Types.Fact ~now:(Time_compat.now ()) ~origin:{kind=Types.Authored;trace_id="unrelated-writer"} in
    memory_action fixture (fun () -> io (fun () -> Current.apply_disposition
      ~pass:Keeper_memory_commit_pass.Durable ~absorbed:[] ~revisions:[]
      ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name ~now:(Time_compat.now ())
      ~source:{kind=Current.Librarian;trace_id} ~new_claims:[fact] () |> get)) |> ignore;
    assert_pending (run_worker fixture);
    let child=Resolution_intent.child (last_cut_intent fixture original) |> Option.get in
    let load_child ()=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
      ~request_id:child.request_id |> owned |> Option.get) in
    let captured=load_child () in
    let child_request=io (fun () -> Capture.restore ~owner:(Capture.physical_owner request) captured |> get) in
    let child_source=Capture.source child_request in
    check bool "the child rebased only its actual current Memory" true
      (Source.expected_revision child_source<>Source.expected_revision original_source
       && (Source.input child_source).current<>input.current);
    check json "the child retains every original source byte and counterpart" (Source.basis_json original_source)
      (Source.basis_json child_source);
    let positions=cut_source_positions fixture and memory=cut_memory_bytes fixture in
    let posts=F.post_count fixture.server and deliveries= !(fixture.deliveries) in
    fixture.set_response (fun capture ->
      check string "only the confirmed Cut child reaches the provider" child.request_id (Capture.request_id capture);
      `Request_entity_too_large,
        {|{"error":{"message":"fixture body too large","type":"invalid_request_error"}}|});
    assert_pending (run_worker fixture);
    await_delivery fixture ~after:deliveries;
    (match run_worker fixture with
     | Error (Consumer.Counterpart_input_capacity_refused _) -> ()
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "the actual child capacity refusal was not retained");
    let rejected=load_child () in
    let evidence=match Progress.phase rejected.progress with
      | Rejected {stage=Execution;evidence} -> evidence
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Rejected {stage=Before_dispatch;_} | Subdividing _ | Subdivided _ ->
        fail "child has no actual execution refusal" in
    let child_exact=Capture.request child_request |> get in
    let schema=Option.to_result ~none:"child schema" child_exact.schema |> get in
    check bool "the actual host proof confirms a provider capacity refusal" true
      (Exact.delivered (Exact.retained_final_of_json ~schema evidence |> get)
       = Exact.Call_final (Input_refused Request_body_refused));
    check bool "the child itself has no effect fence" true (io (fun () ->
      Fence.read ~store:fixture.store ~scope:original.scope ~request_id:child.request_id |> get)=None);
    (match io (fun () -> Lineage.refusal_obligation ~store:fixture.store child_request |> get) with
     | Lineage.Cut_read_required id -> check string "the read obligation names the actual Cut" original.request_id id
     | No_cut_ancestor -> fail "the confirmed Cut ancestry disappeared");
    let completed=Refusal.inventory [rejected,child_request] |> get in
    let stop=Refusal.retained_stop ~store:fixture.store ~completed ~record:rejected ~request:child_request
      |> get |> Option.to_result ~none:"actual Cut child refusal has no retained stop" |> get in
    check bool "a Cut refusal has no abandonment diagnosis" true (Refusal.diagnosis stop=None);
    check bool "the public adapter cannot abandon the confirmed Cut source" true
      (Result.is_error (memory_action fixture (fun () -> io (fun () -> Commit.settle_refused
        ~store:fixture.store ~request:child_request ~record:rejected))));
    check bool "direct refusal settlement writes no Memory or receipt" true (cut_memory_bytes fixture=memory);
    check bool "direct refusal settlement ACKs no original frontier" true (cut_source_positions fixture=positions);
    for _=1 to 2 do
      (match run_worker fixture with
       | Ok (Consumer.Pending (Keeper_librarian_pending.Message_floor pending)) ->
         check string "the pending floor retains the same refused Cut child" child.request_id pending.request_id
       | Ok (Pending pending) -> fail ("expected the Cut message floor: " ^ Keeper_librarian_pending.description pending)
       | Error error -> fail (Consumer.error_to_string error)
       | Ok (Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _) ->
         fail "an unresolved Cut source was released as completed");
      check bool "automatic refusal settlement writes no Memory or receipt" true (cut_memory_bytes fixture=memory);
      check bool "automatic refusal settlement ACKs no original frontier" true (cut_source_positions fixture=positions)
    done;
    check bool "the actual Cut source still lacks committed range receipts" true
      (not (io (fun () -> Commit.receipt_state child_request |> get)));
    check bool "a rejected child supplies no compact completion proof" true
      ((last_cut_intent fixture original).memory_commit=None);
    check bool "fresh selection stays blocked by the Cut obligation" true
      (Result.is_error (io (fun () -> Keeper_librarian_history_resolution_selection.check
        ~config:fixture.config ~keeper_name)));
    check int "the refusal retries neither parent nor child RPC" (posts+1) (F.post_count fixture.server);
    check bool "the same confirmed child remains the only continuation" true
      (Resolution_intent.child (last_cut_intent fixture original)=Some child
       && List.length (observed_originals fixture)=2);
    check bool "the child records no abandonment settlement" true
      (Progress.settlement (load_child ()).progress=None);
    check json "the original Cut record remains byte-equivalent" parent (io (fun () ->
      Owner.load ~store:fixture.store ~scope:original.scope ~request_id:original.request_id |> owned |> Option.get |> Owner.to_json));
    check bool "the original host Unknown evidence is preserved" true
      (host=io (fun () -> Store.load_exact_request fixture.store ~declaration_id:"librarian"
        ~request_id:exact.request_id |> get)))
let test_cut_fence_outer_cancellation_joins_fs_scope () =
  with_same_binding_cut ~history_kind:Mixed ~with_io_pool:true (fun fixture original request exact schema ->
    let pool=match fixture.io_pool with Some pool -> pool | None -> fail "fixture has no actual IO pool" in
    let accepted=submit_cut_command fixture original in
    let basis=match accepted.intent.origin with
      | Resolution_intent.Same_binding_cut basis -> basis
      | Worker_absence -> fail "Cut command origin" in
    let ids=let checkpoint (value:Source.Held.checkpoint)=Keeper_id.Trace_id.to_string value.trace_id in
      let official (value:Source.Held.official)=List.map (fun (trace:Source.Held.trace) -> trace.id) value.traces in
      (match Source.source (Capture.source request) with
       | Source.Held.Checkpoint_only value -> [checkpoint value]
       | Official_only value -> official value
       | Mixed (left,right) -> checkpoint left::official right) |> List.sort_uniq String.compare in
    let lock_paths=io (fun () -> List.map (fun id ->
      let session_dir=Filename.concat (Keeper_fs.session_store_path_for_base_path fixture.base_path) id in
      Checkpoint.with_session_lock ~session_dir (fun canonical -> canonical ^ ".checkpoint.lock") |> get) ids) in
    let protected_paths=[
      Filename.concat (scope_directory fixture original.scope) (Store.digest original.request_id ^ ".json");
      Filename.concat (Store.root fixture.store) (Store.tool_request_body_path
        ~scope:original.scope ~request_digest:original.request_digest);
      Filename.concat (Store.root fixture.store) (Store.exact_request_path
        ~declaration_id:"librarian" ~request_id:exact.Exact.request_id);
      proof_path fixture exact] in
    let protected_bytes ()=io (fun () -> List.map (fun path -> path,Fs_compat.load_file_opt path) protected_paths) in
    let protected_before=protected_bytes () and positions=cut_source_positions fixture in
    let memory_before=cut_memory_bytes fixture and posts=F.post_count fixture.server in
    let published,published_u=Eio.Promise.create () and owner_context,owner_context_u=Eio.Promise.create () in
    let pool_invocation_done,pool_invocation_done_u=Eio.Promise.create () in
    let source_scope_joined=Atomic.make None and runtime_owner_joined=Atomic.make None in
    let worker_entries=Atomic.make 0 in
    let cancel_requested=Atomic.make false and readback_after_cancel=Atomic.make false in
    let confirmed=Atomic.make None and escaped=Atomic.make None in
    let mutex=Stdlib.Mutex.create () and condition=Stdlib.Condition.create () and released=ref false in
    let release ()=Stdlib.Mutex.protect mutex (fun () ->
      if not !released then (released:=true;Stdlib.Condition.broadcast condition)) in
    let after_publish ()=
      Stdlib.Mutex.lock mutex;
      Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock mutex) (fun () ->
        Eio.Promise.resolve published_u ();
        while not !released do Stdlib.Condition.wait condition mutex done) in
    let cancelled,pending,claim_busy,source_held,sibling_worker,published_bytes,blocked_intent,blocked_positions,blocked_memory =
      Eio.Switch.run (fun cleanup_sw ->
        (* The cancelled context belongs to the actual submitting Memory action,
           not to a fiber that merely awaits that action's result promise. *)
        let owner=start_memory_action fixture (fun () ->
          try
            Eio.Cancel.sub (fun context ->
              Eio.Promise.resolve owner_context_u context;
              ignore (Domain_pool.submit_io ~name:__FUNCTION__ pool (fun () ->
                Atomic.incr worker_entries;
                Fun.protect ~finally:(fun () -> Eio.Promise.resolve pool_invocation_done_u ()) (fun () ->
                  Resolution.For_testing.with_cut_fence_serialized ~after_publish
                    ~config:fixture.config ~keeper_name ~request_id:original.request_id
                    ~expected:accepted.intent.expected ~basis ~actor:accepted.intent.actor ~reason:accepted.intent.reason
                    ~now:(Time_compat.now ()) ~use:(fun grant ->
                      Atomic.set escaped (Some grant);
                      Atomic.set readback_after_cancel (Atomic.get cancel_requested);
                      let result=Resolution_intent.confirm_cut_fence ~store:fixture.store ~expected:accepted.intent grant in
                      Atomic.set confirmed (Some result);result))));
              false)
          with Eio.Cancel.Cancelled _ -> true) in
        (* A cancelled cross-domain Runtime waiter may finish before its actual
           owner callback. First drain the held source locks, then pass that
           callback's configuration/action serializers. Neither barrier writes
           product state. A failing baseline must join these scopes as well. *)
        Eio.Switch.on_release cleanup_sw (fun () -> Eio.Cancel.protect (fun () ->
          release ();
          let sources=io (fun () -> List.map (fun lock_path ->
            File_lock_eio.with_durable_lock ~lock_path (fun () -> ())) lock_paths) in
          Atomic.set source_scope_joined (Some sources);
          let joined=Keeper_librarian_durable_edge.with_destination ~config:fixture.config
            ~reserved:(Keeper_librarian_durable_edge.reserved ()) (fun actual ->
              Ok (Lane_addon_captured_destination.same_semantic actual (Capture.destination request))) in
          Atomic.set runtime_owner_joined (Some joined);
          (* Preserve an action exception for the ordinary observer; it cannot
             skip the actual owner/source barriers during cleanup. *)
          ignore (Eio.Promise.await owner);
          Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name));
        let context=Eio.Promise.await owner_context in
        Eio.Promise.await published;
        Eio.Cancel.cancel context Exit;
        Atomic.set cancel_requested true;
        Eio.Fiber.yield ();
        let sibling_worker=Domain_pool.submit_io ~name:__FUNCTION__ pool Executor_pool_ref.in_worker_context in
        let claim_busy=io (fun () -> match Exact.with_cut_exclusion
          ~store:fixture.store ~declaration_id:"librarian" ~schema exact ~use:(fun _ -> ()) with
          | Ok Exact.Cut_busy -> true
          | Ok (Cut_not_retained _ | Cut_excluded ()) | Error _ -> false) in
        let source_held=io (fun () -> List.map (fun lock_path ->
          match File_lock_eio.try_with_durable_lock_observed ~lock_path (fun () -> ()) with
          | File_lock_eio.Lock_held_elsewhere -> true
          | Lock_attempted (Lock_not_acquired _ | Body_completed _) -> false) lock_paths) in
        let published_bytes=io (fun () -> Fs_compat.load_file_opt (Filename.concat (Store.root fixture.store)
          (Store.history_fence_path ~scope:original.scope ~request_id:original.request_id))) in
        let blocked_intent=last_cut_intent fixture original in
        let blocked_positions=cut_source_positions fixture and blocked_memory=cut_memory_bytes fixture in
        let pending=not (Eio.Promise.is_resolved owner) && not (Eio.Promise.is_resolved pool_invocation_done) in
        release ();
        let cancelled=Eio.Promise.await_exn owner in
        Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
        cancelled,pending,claim_busy,source_held,sibling_worker,published_bytes,blocked_intent,blocked_positions,blocked_memory) in
    check bool "actual fence bytes exist before the cancelled submission can finish" true (Option.is_some published_bytes);
    check bool "outer cancellation waits for the held filesystem worker" true pending;
    check bool "another actual pool worker progresses while the first joins" true sibling_worker;
    check bool "the original Exact claim remains excluded after cancellation" true claim_busy;
    check bool "the actual original trace locks remain held after cancellation" true
      (source_held<>[] && List.for_all Fun.id source_held);
    check bool "blocked fence grants no child" true
      (blocked_intent.intent_id=accepted.intent.intent_id && blocked_intent.phase=Requested);
    check bool "blocked fence advances no source ACK" true (blocked_positions=positions);
    check bool "blocked fence writes no Memory" true (blocked_memory=memory_before);
    check bool "the actual submitting fiber propagates cancellation" true cancelled;
    check bool "pool invocation finished before the Memory lane drained" true (Eio.Promise.is_resolved pool_invocation_done);
    check bool "cleanup joined the actual source scope before filesystem teardown" true
      (match Atomic.get source_scope_joined with
       | Some sources -> sources<>[] && List.for_all Result.is_ok sources
       | None -> false);
    check bool "cleanup crossed the same Runtime owner serializers after source release" true
      (Atomic.get runtime_owner_joined=Some (Ok true));
    check int "cancelled filesystem work is never replayed" 1 (Atomic.get worker_entries);
    check bool "strict fence readback runs after outer cancellation" true (Atomic.get readback_after_cancel);
    let fenced=match Atomic.get confirmed with
      | Some result -> result |> Result.map_error Resolution_intent.error_to_string |> get
      | None -> fail "cancelled filesystem scope never reached actual grant readback" in
    check bool "the joined worker retained only the same command's Fenced CAS" true
      (fenced.intent_id=accepted.intent.intent_id && fenced.phase=Fenced);
    check bool "the released grant has no authority" true
      (match Atomic.get escaped with None -> false | Some grant ->
        Result.is_error (io (fun () -> Resolution.confirm_cut_grant ~store:fixture.store grant)));
    check bool "cancelled fence preserves original owner, body, Unknown and proof bytes" true (protected_bytes ()=protected_before);
    check bool "cancelled fence preserves all original source frontiers" true (cut_source_positions fixture=positions);
    check bool "cancelled fence preserves every Memory publication file" true (cut_memory_bytes fixture=memory_before);
    check int "cancelled fence sends no provider call" posts (F.post_count fixture.server);
    let observed=io (fun () -> Resolution.read ~config:fixture.config ~keeper_name ~request_id:original.request_id
      |> Result.map_error Resolution.error_to_string |> get) |> Option.get in
    check bool "actual strict readback binds the same Cut" true (observed.Fence.authority=Excluded_cut basis);
    run_cut_command fixture |> Result.map_error Resolution_intent.error_to_string |> get;
    let first=last_cut_intent fixture original in
    let child=match first.phase with
      | Child_confirmed child -> child
      | Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _ -> fail "same command did not recover one child" in
    run_cut_command fixture |> Result.map_error Resolution_intent.error_to_string |> get;
    check bool "ordinary recovery retains one command and one child identity" true
      (let intents=io (fun () -> Resolution_intent.read ~config:fixture.config ~keeper_name ~request_id:original.request_id
         |> Result.map_error Resolution_intent.error_to_string |> get) in
       List.length intents=1 && (last_cut_intent fixture original).intent_id=accepted.intent.intent_id
       && Resolution_intent.child (last_cut_intent fixture original)=Some child);
    check bool "child preparation still consumes no original source" true (cut_source_positions fixture=positions);
    check bool "child preparation still writes no Memory" true (cut_memory_bytes fixture=memory_before);
    check bool "child preparation still preserves parent bytes" true (protected_bytes ()=protected_before);
    check int "child preparation does not dispatch a provider" posts (F.post_count fixture.server);
    drive_advanced fixture;
    let completed=last_cut_intent fixture original in
    check bool "only actual descendant Memory receipts prove completion" true
      (match completed.memory_commit with Some proof -> proof.request_id=child.request_id && proof.receipts<>[] | None -> false);
    check int "only the descendant adds one provider request" (posts+1) (F.post_count fixture.server);
    let through=Keeper_librarian_input_sources.external_through (Source.counterparts (Capture.source request)) in
    check bool "actual descendant settlement ACKs the original external frontier" true (io (fun () ->
      let cursor=Keeper_external_read_cursor.observe ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config)
        ~keeper_name |> get in
      Keeper_external_read_cursor.observation_matches_preparation cursor ~after:through ~through ~atom:None ~official:None));
    check json "descendant completion preserves the parent's retained Unknown" (Owner.to_json original)
      (io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope ~request_id:original.request_id
        |> owned |> Option.get |> Owner.to_json)))
let test_cut_command_busy_and_late_proof_keep_requested () =
  with_same_binding_cut (fun fixture original _request exact schema ->
    let accepted=submit_cut_command fixture original and before=cut_source_positions fixture in
    let held=memory_action fixture (fun () -> Exact.with_cut_exclusion
      ~store:fixture.store ~declaration_id:"librarian" ~schema exact ~use:(fun _ ->
        check bool "busy is a typed retryable command result" true
          (match Resolution_work.run_serialized ~config:fixture.config ~keeper_name with
           | Error Resolution_intent.Host_claim_busy -> true
           | Ok () | Error (Invalid _ | Conflict _ | Unavailable _ | Publication_uncertain _) -> false)))
      |> Result.map_error Exact.describe_recovery_error |> get in
    (match held with Exact.Cut_excluded () -> () | Cut_busy | Cut_not_retained _ -> fail "actual claim was not held");
    check bool "busy retains Requested and the original intent ID" true
      (let current=last_cut_intent fixture original in current.intent_id=accepted.intent.intent_id && current.phase=Requested);
    io (fun () -> write (proof_path fixture exact) "{late unreadable execution proof");
    check bool "late proof prevents a grant" true (Result.is_error (run_cut_command fixture));
    check bool "late proof neither refuses the command nor consumes source" true
      ((last_cut_intent fixture original).phase=Requested && cut_source_positions fixture=before);
    no_memory fixture)
let test_cut_fence_without_intent_blocks_every_fresh_history_path ~remove_owner () =
  with_same_binding_cut (fun fixture original request _exact _schema ->
    let expected=(cut_preview fixture original).expected in
    ignore (cut_fence fixture original expected |> Result.map_error Resolution.error_to_string |> get);
    check bool "the Cut fence really has no resolution intent" true
      (io (fun () -> Resolution_intent.read ~config:fixture.config ~keeper_name
        ~request_id:original.request_id |> Result.map_error Resolution_intent.error_to_string |> get)=[]);
    let owner_path=Filename.concat (scope_directory fixture original.scope)
      (Store.digest original.request_id ^ ".json") in
    if remove_owner then io (fun () -> Sys.remove owner_path);
    let positions=cut_source_positions fixture and memory=cut_memory_bytes fixture in
    let posts=F.post_count fixture.server in
    let body_directory=Filename.dirname (Filename.concat (Store.root fixture.store)
      (Store.tool_request_body_path ~scope:original.scope ~request_digest:original.request_digest)) in
    let bodies ()=io (fun () -> Sys.readdir body_directory |> Array.to_list |> List.sort String.compare
      |> List.map (fun name -> name,Fs_compat.load_file_opt (Filename.concat body_directory name))) in
    let before_bodies=bodies () in
    let original_count=List.length (observed_originals fixture) in
    let blocked = function
      | Error (Consumer.Original_publication_blocked _) -> ()
      | Error error -> fail (Consumer.error_to_string error)
      | Ok _ -> fail "a Cut fence permitted fresh history selection" in
    blocked (run_worker fixture);
    blocked (memory_action fixture (fun () -> Consumer.consume_one ~config:fixture.config ~keeper_name
      ~commit:(fun _ -> fail "direct Consumer reached a fresh commit callback")));
    blocked (memory_action fixture (fun () -> Consumer.consume_one_with_runtime
      ~config:fixture.config ~keeper_name ()));
    check bool "the exported production commit edge cannot bypass source selection" true
      (match memory_action fixture (fun () -> Consumer.commit_with_runtime
         ~base_path:fixture.base_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
         (Capture.source request)) with
       | Consumer.Memory_pending (Keeper_librarian_pending.Local_failure _) -> true
       | Memory_pending _ | Memory_committed | Memory_replaced _ | Memory_refused _ -> false);
    memory_action fixture (fun () -> Refresh.For_testing.run_continuity
      ~base_path:fixture.base_path ~keeper_name ());
    let module Observation=Keeper_continuity_observation in
    check bool "direct continuity reports the retained resolution boundary" true
      (match Observation.latest_synthesis ~config:fixture.config ~keeper_name with
       | Some value -> value.state=Observation.Source_unavailable
         && value.stop_reason=Some Observation.History_resolution_required
       | None -> false);
    ignore (Refresh.submit_durable ~base_path:fixture.base_path ~keeper_name);
    Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
    check bool "the production queue keeps this publication unfinished" true
      (match Refresh.last_measurement ~config:fixture.config ~keeper_name with
       | Some value -> (match value.Refresh.last_pass with
         | Refresh.Stopped (Consumer.Original_publication_blocked _) -> true
         | Off | Lane_unconfigured | Drained | Yielded_to_waiting_unit | Not_committed
         | Pending _ | Stopped _ | Raised _ -> false)
       | None -> false);
    check int "no path dispatches another provider request" posts (F.post_count fixture.server);
    check int "no path creates an unparented original" original_count (List.length (observed_originals fixture));
    check bool "no path stages another original body" true (bodies ()=before_bodies);
    check bool "every source frontier and external ACK stays exact" true (cut_source_positions fixture=positions);
    check bool "no path publishes even empty Memory or receipts" true (cut_memory_bytes fixture=memory);
    if not remove_owner then refuse_fenced_resume fixture original request;
    let fence_path=Filename.concat (Store.root fixture.store)
      (Store.history_fence_path ~scope:original.scope ~request_id:original.request_id) in
    io (fun () -> write fence_path "{unreadable retained Cut fence");
    blocked (run_worker fixture);
    check bool "unreadable fence evidence cannot become fresh-work permission" true
      (bodies ()=before_bodies && cut_source_positions fixture=positions
       && cut_memory_bytes fixture=memory && F.post_count fixture.server=posts))
let test_missing_history_recovers_without_operator_submission history_kind () =
  with_fixture ~history_kind (fun ~sw:_ fixture ->
  let original,request=retain_absent_history_original fixture in
  let before=progress fixture in
  let wakes=ref 0 in
  let first=memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name
    ~wake:(fun () -> incr wakes)) in
  check bool "automatic recovery yields before dispatching its continuation" true
    (match first with Ok (Consumer.Pending (Keeper_librarian_pending.Publication _)) -> true
     | Ok (Pending _ | Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _
       | Memory_not_committed _) -> false
     | Error error -> fail (Consumer.error_to_string error));
  check int "one durable recovery schedules the next lane unit" 1 !wakes;
  check int "preparing recovery makes no provider call" 0 (F.post_count fixture.server);
  no_memory fixture;
  check bool "recovery does not acknowledge its source" true (progress fixture=before);
  let observe ()=io (fun () -> Resolution_work.read ~config:fixture.config ~keeper_name
    ~request_id:original.request_id |> Result.map_error Resolution_intent.error_to_string |> get) in
  let prepared=observe () in
  let child_id=match prepared.intents with
    | [{Resolution_intent.actor="librarian";phase=Child_confirmed child;_}] -> child.request_id
    | _ -> fail "the Memory lane did not retain one automatic continuation" in
  check bool "a prepared continuation is not a completed Memory write" true
    (prepared.completion=Resolution_work.Not_observed && Option.is_some prepared.fence);
  (* A later lane scope restores the retained child, just as after a stop. *)
  memory_action fixture (fun () -> Resolution_work.run_serialized ~config:fixture.config ~keeper_name
    |> Result.map_error Resolution_intent.error_to_string |> get);
  check bool "a later unit restores the same child before any provider call" true
    (match (observe ()).intents with
     | [{Resolution_intent.phase=Child_confirmed child;_}] ->
       child.request_id=child_id && F.post_count fixture.server=0
     | _ -> false);
  drive_advanced fixture;
  check int "only the continuation calls the provider" 1 (F.post_count fixture.server);
  check bool "the source position advances after the actual commit" true (progress fixture<>before);
  check bool "the automatic continuation leaves actual Memory facts" true
    (io (fun () -> claims fixture.keepers_dir)<>[]);
  check bool "completion names the actual committed continuation" true
    ((observe ()).completion=Resolution_work.Memory_committed {request_id=child_id});
  let retained=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
    ~request_id:original.request_id |> owned |> Option.get) in
  check json "automatic recovery preserves the unknown original's input" original.request retained.request;
  check bool "the unknown original remains unresolved evidence" true
    (match Progress.phase retained.progress with
     | Dispatch_pending (Some (Absent _)) -> true
     | Captured | Admission_wait _ | Dispatch_pending (None | Some (Waiting _ | Outcome_unknown _))
     | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _ | Rejected _
     | Subdividing _ | Subdivided _ -> false);
  refuse_fenced_resume fixture retained request)
let test_automatic_history_reuses_an_operator_intent () = with_fixture (fun ~sw:_ fixture ->
  let original,request=retain_absent_history_original fixture in
  let preview=fence_preview fixture request in
  let accepted=io (fun () -> Resolution_work.submit ~config:fixture.config ~keeper_name
    ~request_id:original.request_id ~expected:preview.expected ~actor:"operator"
    ~reason:"Resume this original after checking its retained evidence" ~now:(Time_compat.now ())
    |> Result.map_error Resolution_intent.error_to_string |> get) in
  let recovered=memory_action fixture (fun () -> Resolution_work.resolve_missing_serialized
    ~config:fixture.config ~keeper_name ~request_id:original.request_id
    |> Result.map_error Resolution_intent.error_to_string |> get) in
  check bool "automatic recovery continues the operator's durable work" true
    (recovered=Resolution_work.Resume_history);
  let observed=io (fun () -> Resolution_work.read ~config:fixture.config ~keeper_name
    ~request_id:original.request_id |> Result.map_error Resolution_intent.error_to_string |> get) in
  check bool "the operator's identity and one child survive automatic recovery" true
    (match observed.intents with
     | [{Resolution_intent.intent_id;actor="operator";phase=Child_confirmed _;_}] ->
       intent_id=accepted.intent.intent_id
     | _ -> false);
  no_memory fixture;
  check int "continuing a retained intent does not call a provider" 0 (F.post_count fixture.server))
let test_missing_history_progresses_through_the_production_queue () =
  with_fixture ~history_kind:Mixed (fun ~sw:_ fixture ->
  let original,request=retain_absent_history_original fixture in
  let before=progress fixture in
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  let drained,finish=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve signal ());
    Eio.Promise.await release;
    `OK,F.openai_response (answer capture));
  let stop=Refresh.install_change_observer (fun ~config ~keeper_name:observed ->
    if config.Workspace.base_path=fixture.base_path && observed=keeper_name then
      match Refresh.last_measurement ~config ~keeper_name with
      | Some {last_pass=Refresh.Drained;_} -> ignore (Eio.Promise.try_resolve finish ())
      | None | Some {last_pass=(Off | Lane_unconfigured | Yielded_to_waiting_unit
          | Not_committed | Pending _ | Stopped _ | Raised _);_} -> ()) in
  Fun.protect ~finally:(fun () ->
    stop ();
    Keeper_librarian_queue_signal.install (fun ~base_path:_ ~keeper_name:_ -> ());
    ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    Refresh.install ();
    Eio.Switch.run (fun bridge_switch ->
      Server_librarian_addon_wake.install ~sw:bridge_switch ~config:fixture.config;
      (* This is the only external catch-up request. Resolution, dispatch and
         publication must schedule each other through the real queue. *)
      ignore (Refresh.submit_durable ~base_path:fixture.base_path ~keeper_name);
      Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await arrived);
      Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
      no_memory fixture;
      check bool "the queued continuation leaves source unread while its provider is active" true
        (progress fixture=before);
      let prepared=io (fun () -> Resolution_work.read ~config:fixture.config ~keeper_name
        ~request_id:original.request_id |> Result.map_error Resolution_intent.error_to_string |> get) in
      let child_id=match prepared.intents with
        | [{Resolution_intent.phase=Child_confirmed child;_}] -> child.request_id
        | _ -> fail "one production wake did not dispatch its automatic continuation" in
      ignore (Eio.Promise.try_resolve unblock ());
      Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await drained);
      Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
      let complete=io (fun () -> Resolution_work.read ~config:fixture.config ~keeper_name
        ~request_id:original.request_id |> Result.map_error Resolution_intent.error_to_string |> get) in
      check bool "the result bridge commits the same automatically retained child" true
        (complete.completion=Resolution_work.Memory_committed {request_id=child_id});
      check bool "one external signal advances actual source progress" true (progress fixture<>before);
      let through=Keeper_librarian_input_sources.external_through (Source.counterparts (Capture.source request)) in
      let cursor=io (fun () -> Keeper_external_read_cursor.observe
        ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
      check bool "the automatically committed range also acknowledges external input" true
        (Keeper_external_read_cursor.observation_matches_preparation cursor
          ~after:through ~through ~atom:None ~official:None);
      check (list string) "the actual queued provider result reaches Memory"
        ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir));
      check int "the production queue never replays the missing original" 1 (F.post_count fixture.server))))
let test_an_absent_continuation_yields_before_its_next_child () = with_fixture (fun ~sw:_ fixture ->
  let original,_request=retain_absent_history_original fixture in
  assert_pending (run_worker fixture);
  let observe request_id=io (fun () -> Resolution_work.read ~config:fixture.config ~keeper_name
    ~request_id |> Result.map_error Resolution_intent.error_to_string |> get) in
  let child_id observation=match observation.Resolution_work.intents with
    | [{Resolution_intent.phase=Child_confirmed child;_}] -> child.request_id
    | _ -> fail "automatic recovery did not retain one confirmed child" in
  let first_child=child_id (observe original.request_id) in
  let child=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
    ~request_id:first_child |> owned |> Option.get) in
  (* A second interrupted dispatch has its own durable absence. The first
     unknown original and its fence are still retained. *)
  let advance child event=io (fun () -> match Owner.advance ~store:fixture.store ~expected:child ~event with
    | Ok (Owner.Stored child | Already_stored child) -> child
    | Ok (Unconfirmed detail) -> fail detail
    | Error error -> fail (Owner.update_error_to_string error)) in
  let child=advance child Progress.Dispatch_intended in
  ignore (advance child (Progress.Execution_observed (Progress.Absent (`Assoc []))));
  let wakes=ref 0 in
  assert_pending (memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name
    ~wake:(fun () -> incr wakes)));
  let next_child=child_id (observe first_child) in
  check bool "a newly absent child gets its own continuation" true (next_child<>first_child);
  check int "a second absence schedules one later lane unit" 1 !wakes;
  check int "that unit does not inline-dispatch the next child" 0 (F.post_count fixture.server);
  check bool "the ancestor still names its same child" true
    (child_id (observe original.request_id)=first_child);
  no_memory fixture;
  drive_advanced fixture;
  check int "only the final continuation reaches the provider" 1 (F.post_count fixture.server);
  check bool "the actual descendant commit completes the ancestor's original range" true
    ((observe original.request_id).completion=Resolution_work.Memory_committed {request_id=next_child}))
let test_history_fence_retains_unknown_and_blocks_late_observations () = with_fixture (fun ~sw:_ fixture ->
  let original, request = retain_absent_history_original fixture in
  let original_range = Source.range_id (Capture.source request) |> Option.get in
  let previous_range : Current.durable_range_id = match Boundary.position_of_messages first_messages |> get with
    | Boundary.Atom_history {end_atom;last_atom_digest} ->
      {original_range with start_atom=0;end_atom;last_atom_digest;end_boundary_line=1;boundary_lines_seen=1}
    | Empty_atom_history | No_atom_history | Stale_noop -> fail "fixture prefix has no atom history" in
  let fact = Types.observed ~claim:"Independent Memory after the original capture" ~category:Types.Fact
    ~now:(Time_compat.now ()) ~origin:{kind=Types.Authored;trace_id="independent-writer"} in
  memory_action fixture (fun () -> io (fun () -> Current.apply_disposition ~pass:Keeper_memory_commit_pass.Durable
    ~durable_range_id:previous_range ~absorbed:[] ~revisions:[]
    ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name ~now:(Time_compat.now ())
    ~source:{kind=Current.Librarian;trace_id} ~new_claims:[fact] () |> get)) |> ignore;
  let preview = fence_preview fixture request in
  check bool "preview uses current Memory, not the original captured revision" true
    (preview.expected.memory_revision <> Source.expected_revision (Capture.source request));
  let fence = memory_action fixture (fun () -> io (fun () ->
    Resolution.fence_serialized ~config:fixture.config ~keeper_name ~request_id:original.request_id
      ~expected:preview.expected ~actor:"operator" ~reason:"discard only this unknown result"
      ~now:(Time_compat.now ()) |> Result.map_error Resolution.error_to_string |> get)) in
  check json "original unknown record is preserved" (Owner.to_json original) fence.original_record;
  let changed = io (fun () -> match Owner.advance ~store:fixture.store ~expected:original
    ~event:(Progress.Execution_observed (Progress.Waiting (`Assoc []))) with
    | Ok (Owner.Stored value | Already_stored value) -> value
    | Ok (Unconfirmed detail) -> fail detail
    | Error error -> fail (Owner.update_error_to_string error)) in
  refuse_fenced_resume fixture changed request;
  let path = Filename.concat (Store.root fixture.store)
    (Store.history_fence_path ~scope:original.scope ~request_id:original.request_id) in
  io (fun () -> write path "{unreadable fence");
  refuse_fenced_resume fixture changed request)
let test_actual_history_guard_rechecks_own_fence_for_replacement () = with_fixture (fun ~sw fixture ->
  let original,request=retain_absent_history_original ~failed_selection:false fixture in
  let exact=Capture.request request |> get in
  let schema=Option.to_result ~none:"fenced replacement has no schema" exact.Exact.schema |> get in
  let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
    |> Result.map_error Lane_addon_manifest.error_to_string |> get in
  let authorization=Server_librarian_addon_validation.authorize ~base_path:fixture.base_path
    ~store:fixture.store ~declaration_id:"librarian" ~package exact
    |> Result.map_error (function Exact.Unowned {reason} -> reason | Undecided {detail} -> detail)
    |> get |> Option.get in
  check (result unit string) "the original guard is current before its own fence" (Ok ())
    (authorization.before_dispatch () |> Result.map_error Exact.dispatch_veto_detail);
  let preview=fence_preview fixture request in
  ignore (memory_action fixture (fun () -> io (fun () ->
    Resolution.fence_serialized ~config:fixture.config ~keeper_name ~request_id:original.request_id
      ~expected:preview.expected ~actor:"operator" ~reason:"Exclude this original's future effects"
      ~now:(Time_compat.now ()) |> Result.map_error Resolution.error_to_string |> get)));
  let replacement=fixture.declaration true |> String.split_on_char '\n'
    |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-fenced-replacement\"" | line -> line)
    |> String.concat "\n" in
  replace_actual_worker_configuration fixture ~sw replacement;
  let positions=cut_source_positions fixture and memory=cut_memory_bytes fixture in
  check bool "the previously captured host guard rereads its own fence" true
    (guard_waits authorization.before_dispatch);
  (match memory_action fixture (fun () -> Keeper_librarian_durable_edge.reconcile_replacement
      ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ())
      ~original:(Owner.listed original) ~request:exact)
      |> Result.map_error Lane_addon_submit_once.error_to_string |> get with
   | Exact.Reconciliation_pending (Declaration_unavailable _) -> ()
   | Reconciliation_pending (Replacement_claim_busy | Declaration_current | Execution_unresolved)
   | Reconciled_terminal _ -> fail "an own fence was treated as replacement authority");
  check bool "the actual runner-free Runtime port creates no host ending" true
    ((io (fun () -> Exact.observe_retained ~store:fixture.store ~declaration_id:"librarian" ~schema exact) |> get)
      =Exact.Retained_absent);
  let current,_=only_original fixture in
  check json "the fenced original record is unchanged" (Owner.to_json original) (Owner.to_json current);
  check bool "the fenced reconciliation changes no source ACK" true (cut_source_positions fixture=positions);
  check bool "the fenced reconciliation changes no Memory publication" true (cut_memory_bytes fixture=memory);
  check int "the fenced reconciliation sends no model request" 0 (F.post_count fixture.server))
let test_history_fence_allows_the_next_history_pass () = with_fixture (fun ~sw:_ fixture ->
  let original,request=retain_absent_history_original fixture in
  let preview=fence_preview fixture request in
  ignore (memory_action fixture (fun () -> io (fun () ->
    Resolution.fence_serialized ~config:fixture.config ~keeper_name ~request_id:original.request_id
      ~expected:preview.expected ~actor:"operator" ~reason:"rejudge the unread history"
      ~now:(Time_compat.now ()) |> Result.map_error Resolution.error_to_string |> get)));
  refuse_fenced_resume fixture original request;
  no_memory fixture;
  (* The pass reads a fenced original with no predecessor as its record and
     index. Without its body file the inventory still lists it. The file
     is back before any dispatch, whose host-side check reads it; the pass
     itself is run without the file below. *)
  let body=Filename.concat (Store.root fixture.store)
    (Store.tool_request_body_path ~scope:original.scope ~request_digest:original.request_digest) in
  let bytes=io (fun () -> In_channel.with_open_bin body In_channel.input_all) in
  io (fun () -> Sys.remove body);
  let listed=memory_action fixture (fun () -> Durable_owner.discover ~store:fixture.store
    ~base_path:fixture.base_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name)
    |> Result.map_error Durable_owner.error_to_string |> get in
  check int "the inventory lists the original without its body" 1 (List.length listed);
  check bool "reading that original's body fails" true
    (Result.is_error (memory_action fixture (fun () -> Durable_owner.load ~store:fixture.store (List.hd listed))));
  (* The host's wake finds a history original's Keeper from the record. *)
  let wake event=io (fun () -> Server_librarian_addon_wake.For_testing.discover ~config:fixture.config
    ~store:fixture.store ~after_inventory:(fun () -> ())
    ~on_original:(fun _ -> fail "the wake read a history original's body") ~event) in
  (match wake Runtime.Configuration_observed with
   | Ok (_,refusals,original_keepers) ->
     check (list string) "a configuration scan finds the Keeper without the body" [keeper_name] original_keepers;
     check (list string) "and refuses nothing" [] refusals
   | Error detail -> fail detail);
  (match wake (Runtime.Exact_result_delivered {installation_id=(Capture.destination request).installation_id;
     instance_id="fixture-instance";request_id=original.request_id}) with
   | Ok (keepers,_,_) -> check (list string) "a result hint finds the Keeper without the body" [keeper_name] keepers
   | Error detail -> fail detail);
  check bool "a result hint from another installation is refused for its installation" true
    (wake (Runtime.Exact_result_delivered {installation_id="another-installation";
      instance_id="fixture-instance";request_id=original.request_id})
     =Error "Librarian result hint belongs to a different original installation");
  io (fun () -> write body bytes);
  drive_advanced fixture;
  check int "only the newly captured original reaches the provider" 1 (F.post_count fixture.server);
  check bool "the next history pass actually commits Memory" true
    (io (fun () -> claims fixture.keepers_dir)<>[]);
  let retained=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
    ~request_id:original.request_id |> owned) in
  check bool "the fenced unknown record stays live without a claimed completion" true
    (Option.map Owner.to_json retained=Some (Owner.to_json original));
  refuse_fenced_resume fixture original request;
  let path=Filename.concat (Store.root fixture.store)
    (Store.history_fence_path ~scope:original.scope ~request_id:original.request_id) in
  let honest_fence=io (fun () -> In_channel.with_open_bin path In_channel.input_all) in
  io (fun () -> write path "{unreadable fence");
  check bool "an unreadable fence still stops inventory" true (Result.is_error (run_worker fixture));
  io (fun () -> write path honest_fence);
  (* With the Add-on detached a pass dispatches nothing and stops after its
     inventory and lineage. It stops the same way without the fenced
     original's body file. *)
  set_enabled fixture false;
  let stopped ()=match run_worker fixture with
    | Error error -> Consumer.error_to_string error
    | Ok _ -> fail "a pass without its Add-on did not stop" in
  let with_body=stopped () in
  assert_unattached (run_worker fixture);
  io (fun () -> Sys.remove body);
  check string "a pass ends the same without the fenced original's body" with_body (stopped ()))
(* The deploy check reads no Exact file of a fenced original, as resume reads
   none (RFC exact-request-skips-a-slot-that-refused-its-input, section 6, L2b-2). *)
let test_preflight_reads_no_exact_file_of_a_fenced_original () = with_fixture (fun ~sw:_ fixture ->
  let original,request=retain_absent_history_original fixture in
  let exact=Capture.request request |> get in
  let record_path=Filename.concat (Store.root fixture.store)
    (Store.exact_request_path ~declaration_id:"librarian" ~request_id:exact.request_id) in
  (* A record the Exact check cannot read: resume stops on it. *)
  io (fun () -> write record_path "{");
  check bool "an unfenced original whose record the Exact check deletes is refused" true
    (List.exists (fun (refusal:Lane_addon_store_preflight.refusal) ->
       refusal.decoder=Lane_addon_store_preflight.Tool_request_exact_reads) (librarian_refusals fixture));
  io (fun () -> Sys.remove record_path);
  let preview=fence_preview fixture request in
  ignore (memory_action fixture (fun () -> io (fun () ->
    Resolution.fence_serialized ~config:fixture.config ~keeper_name ~request_id:original.request_id
      ~expected:preview.expected ~actor:"operator" ~reason:"the original's Exact record is gone"
      ~now:(Time_compat.now ()) |> Result.map_error Resolution.error_to_string |> get)));
  io (fun () -> write record_path "{");
  check int "a fenced original is read by no consumer" 0 (List.length (librarian_refusals fixture)))
let test_history_fence_refuses_a_real_range_commit () = with_fixture (fun ~sw:_ fixture ->
  let original, request = retain_absent_history_original fixture in
  let source = Capture.source request in
  memory_action fixture (fun () -> io (fun () -> Current.apply_disposition ~pass:Keeper_memory_commit_pass.Durable
    ?durable_range_id:(Source.range_id source) ?official_range_id:(Source.official_range_id source)
    ~absorbed:[] ~revisions:[] ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
    ~now:(Time_compat.now ()) ~source:{kind=Current.Librarian;trace_id} ~new_claims:[] () |> get)) |> ignore;
  (match io (fun () -> Resolution.preview ~config:fixture.config ~keeper_name ~request_id:original.request_id) with
   | Error Resolution.Range_already_recorded -> ()
   | Error error -> fail (Resolution.error_to_string error)
   | Ok _ -> fail "a real original range receipt still allowed an apply fence");
  let automatic=memory_action fixture (fun () -> Resolution_work.resolve_missing_serialized
    ~config:fixture.config ~keeper_name ~request_id:original.request_id
    |> Result.map_error Resolution_intent.error_to_string |> get) in
  check bool "an actual range receipt also refuses automatic recovery" true
    (automatic=Resolution_work.Original_waiting);
  check bool "a committed range acquires no automatic continuation" true
    (io (fun () -> Resolution_intent.read ~config:fixture.config ~keeper_name
      ~request_id:original.request_id |> Result.map_error Resolution_intent.error_to_string |> get)=[]);
  check bool "apply-first does not manufacture a fence" true
    (io (fun () -> Fence.read ~store:fixture.store ~scope:original.scope ~request_id:original.request_id |> get) = None))
let test_history_fence_uncertain_publication_still_blocks () = with_fixture (fun ~sw:_ fixture ->
  let original, request = retain_absent_history_original fixture in
  let preview = fence_preview fixture request in
  let fence = Fence.create ~request ~original ~expected:preview.expected ~actor:"operator"
    ~reason:"explicit unknown-result decision" ~now:(Time_compat.now ()) |> get in
  let result = io (fun () -> Store.For_testing.publish_history_fence
    ~write_fence:(fun path bytes ->
      let open Result.Syntax in
      let* () = Fs_compat.save_file_atomic_strict path bytes in
      Error "publication reported an error after replacement")
    fixture.store ~scope:original.scope ~request_id:original.request_id
    ~expected_owner:(Owner.to_json original) ~fence:(Fence.to_json fence)) |> get in
  (match result with
   | Store.History_fence_unconfirmed _ -> ()
   | History_fence_stored | History_fence_already_stored | History_fence_owner_changed ->
     fail "post-replacement error was reported as a confirmed fence");
  refuse_fenced_resume fixture original request)
(* A deferred host attempt has neither a result nor an open started marker. *)
let await_deferral fixture request_id =
  let deferred () =
    match io (fun () -> Store.load_exact_request fixture.store ~declaration_id:"librarian" ~request_id) |> get with
    | None -> false
    | Some stored ->
      member "final" stored = `Null
      && (match List.rev (Yojson.Safe.Util.to_list (member "attempts" stored)) with
          | `Assoc fields::_ -> not (List.mem_assoc "started" fields)
          | [] | _::_ -> false) in
  Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
    while not (deferred ()) do Eio.Time.sleep fixture.clock 0.01 done)
let stopped_incarnation="0123456789abcdef0123456789abcdef"
let mark_stopped_incarnation fixture (exact:Exact.request) = io (fun () ->
  let fields=match Store.load_exact_request fixture.store ~declaration_id:"librarian" ~request_id:exact.request_id |> get with
    | Some (`Assoc fields) -> fields
    | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) | None ->
      fail "expected the retained host request" in
  let attempts=match List.assoc_opt "attempts" fields with
    | Some (`List attempts) -> attempts
    | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) | None ->
      fail "expected the host attempt history" in
  let earlier=match List.rev attempts with
    | `Assoc ["started",`String started_by]::earlier when started_by<>stopped_incarnation -> List.rev earlier
    | [] | _::_ -> fail "the open attempt must be started by this process with no outcome" in
  Store.save_exact_request fixture.store ~declaration_id:"librarian" ~request_id:exact.request_id
    (`Assoc (List.map (fun (key,value) -> key,
      if key="attempts" then `List (earlier @ [`Assoc ["started",`String stopped_incarnation]]) else value) fields))
  |> get)
type competing_ending = Replaced_waiter | Interrupted_waiter
let retain_competing_waiter fixture request ending =
  let root,root_request=memory_action fixture (fun () ->
    Keeper_librarian_durable_edge.with_destination ~config:fixture.config
      ~reserved:(Keeper_librarian_durable_edge.reserved ()) (fun destination ->
        let owner=Capture.physical_owner request in
        (* A later independent capture can show a different file-source budget.
           Keep the actual source/coverage, and let the real preparation factory
           make a distinct question so the HTTP fixture binds its exact owner. *)
        let preparation=Keeper_librarian_runtime.prepare_durable ~now:(Time_compat.now ())
          ~source_lines:["Independent waiting root fixture source"] (Source.input (Capture.source request)) |> get in
        let root_request=io (fun () -> Capture.create ~request_id:(Capture.fresh_request_id owner)
          ~owner ~destination ~source:(Capture.source request) ~preparation ()) |> get in
        let original_exact=Capture.request request |> get and root_exact=Capture.request root_request |> get in
        check bool "the provider question identifies the independent retained root" true
          (original_exact.system<>root_exact.system || original_exact.messages<>root_exact.messages);
        let root=Durable_owner.retain ~store:fixture.store root_request
          |> Result.map_error Durable_owner.error_to_string |> get in
        Ok (root,root_request))) |> get in
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    check string "only the independent root is submitted during setup" root.request_id (Capture.request_id capture);
    ignore (Eio.Promise.try_resolve signal ());
    match ending with
    | Replaced_waiter -> `Too_many_requests,{|{"error":{"message":"fixture refusal","type":"rate_limit_error"}}|}
    | Interrupted_waiter -> Eio.Promise.await release;`OK,F.openai_response (answer capture));
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    (match memory_action fixture (fun () -> Durable_owner.resume ~store:fixture.store ~config:fixture.config
      ~reserved:(Keeper_librarian_durable_edge.reserved ()) ~original:(Durable_owner.Read (root,root_request))
      ~call:(Keeper_librarian_durable_edge.call ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ()))
      ~publish:(fun ~original:_ ~request:_ ~proposal:_ -> fail "setup cannot publish the waiting root")
      ~wake:(fun () -> ())) |> Result.map_error Durable_owner.error_to_string |> get with
     | Waited (Worker_pending,_) -> ()
     | Waited ((Worker_unknown | Worker_unreachable | Missing_after_dispatch | Journal_recheck),_)
     | Resumed _ | Original_replaced _ -> fail "the independent root was not admitted to its actual worker");
    Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await arrived);
    (match ending with
     | Replaced_waiter -> await_deferral fixture root.request_id
     | Interrupted_waiter ->
       (* Simulate the stopped incarnation on the real in-flight host record,
          then join its cancellation. The actual next host run names Interrupted. *)
       mark_stopped_incarnation fixture (Capture.request root_request |> get);
       (match Memory_lane.with_librarian_purge ~base_path:fixture.base_path ~keeper_name (fun () -> ()) with
        | Ok () -> () | Error error -> fail (Memory_lane.purge_cancel_error_to_string error)));
    root,root_request)
type linked_recovery = Ended_only | Intent_only | Child_before_ack
let test_linked_replacement_preserves_the_resolution_protocol ?competing_ending ~cut ~recovery () = with_fixture (fun ~sw fixture ->
  let parent,parent_request=retain_absent_history_original ~failed_selection:false fixture in
  let expected=(fence_preview fixture parent_request).expected in
  io (fun () -> Resolution_work.submit ~config:fixture.config ~keeper_name ~request_id:parent.request_id
    ~expected ~actor:"operator" ~reason:"resume the exact source"
    ~now:(Time_compat.now ()) |> Result.map_error Resolution_intent.error_to_string |> get |> ignore);
  memory_action fixture (fun () -> Resolution_work.run_serialized ~config:fixture.config ~keeper_name)
    |> Result.map_error Resolution_intent.error_to_string |> get;
  let view ()=io (fun () -> Resolution_work.read ~config:fixture.config ~keeper_name ~request_id:parent.request_id
    |> Result.map_error Resolution_intent.error_to_string |> get) in
  let child_id=match (List.hd (List.rev (view ()).intents)).phase with
    | Resolution_intent.Child_confirmed child -> child.request_id
    | Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _ -> fail "the operator resolution has no confirmed child" in
  let child,request=io (fun () ->
    let child=Owner.load ~store:fixture.store ~scope:parent.scope ~request_id:child_id |> owned |> Option.get in
    let request=Capture.restore ~owner:(Capture.physical_owner parent_request) child |> get in
    child,request) in
  check bool "the actual continuation is linked to its fenced parent" true (Option.is_some (Capture.predecessor request));
  let exact=Capture.request request |> get in
  let advance child event=io (fun () -> match Owner.advance ~store:fixture.store ~expected:child ~event with
    | Ok (Owner.Stored child | Already_stored child) -> child
    | Ok (Unconfirmed detail) -> fail detail
    | Error error -> fail (Owner.update_error_to_string error)) in
  let child=if not cut then child else (
    io (fun () -> Store.save_exact_request fixture.store ~declaration_id:"librarian" ~request_id:exact.request_id
      (`Assoc ["declaration_id",`String "librarian";"request_id",`String exact.request_id;
        "digest",`String (Exact.digest exact);"request",Exact.request_to_json exact;
        "attempts",`List [Exact.retained_final_to_json (Exact.Retained_unknown Exact.Cut)];
        "final",Exact.final_to_json Exact.Outcome_unknown]) |> get);
    let child=advance child Progress.Dispatch_intended in
    advance child (Progress.Refused {stage=Execution;
      evidence=Exact.retained_final_to_json (Exact.Retained_unknown Exact.Cut)})) in
  let competing=Option.map (retain_competing_waiter fixture request) competing_ending in
  let positions=progress fixture in
  let replacement=fixture.declaration true |> String.split_on_char '\n'
    |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-linked-replacement\"" | line -> line)
    |> String.concat "\n" in
  replace_actual_worker_configuration fixture ~sw replacement;
  Option.iter (fun ((root:Owner.retained),root_request) ->
    let root_exact=Capture.request root_request |> get in
    let schema=Option.to_result ~none:"waiting root lacks its schema" root_exact.Exact.schema |> get in
    let expected=match competing_ending with
      | Some Replaced_waiter -> Exact.Retained_not_allowed {reason=Replaced_declaration}
      | Some Interrupted_waiter -> Exact.Retained_unknown Interrupted
      | None -> fail "competing root has no ending fixture" in
    Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
      let rec wait ()=match io (fun () -> Exact.observe_retained ~store:fixture.store
          ~declaration_id:"librarian" ~schema root_exact) |> get with
        | Exact.Retained_terminal actual -> check bool "the actual host produced the named ending" true (actual=expected)
        | Retained_absent | Retained_open -> Eio.Time.sleep fixture.clock 0.01;wait () in
      wait ());
    (* Match the incident: the old linked child already ended, but the
       independent root's domain owner still only knows worker Waiting. *)
    (match memory_action fixture (fun () -> Durable_owner.resume ~store:fixture.store ~config:fixture.config
      ~reserved:(Keeper_librarian_durable_edge.reserved ()) ~original:(Durable_owner.Read (child,request))
      ~call:(fun ~expected:_ ~original:_ ~arguments:_ -> fail "the linked ending cannot send an RPC")
      ~publish:(fun ~original:_ ~request:_ ~proposal:_ -> fail "the linked ending cannot publish")
      ~wake:(fun () -> ())) |> Result.map_error Durable_owner.error_to_string |> get with
     | Original_replaced _ -> () | Waited _ | Resumed _ -> fail "the linked child did not end before dispatch");
    let root=io (fun () -> Owner.load ~store:fixture.store ~scope:root.scope ~request_id:root.request_id |> owned |> Option.get) in
    check bool "the independent owner's ending has not yet been recovered" true
      (match Progress.phase root.progress with Dispatch_pending _ -> true
       | Captured | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _ | Finished _
       | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false)) competing;
  let completion_provider_ids=ref [] in
  fixture.set_response (fun capture ->
    completion_provider_ids:=Capture.request_id capture:: !completion_provider_ids;
    `OK,F.openai_response (answer capture));
  let ending_posts=F.post_count fixture.server in
  let ending_memory=cut_memory_bytes fixture and ending_positions=cut_source_positions fixture in
  let wakes=ref 0 in
  let refuse_damaged_competing_proof ()=Option.iter (fun ((root:Owner.retained),root_request) ->
    let path=proof_path fixture (Capture.request root_request |> get) in
    let original_proof=io (fun () -> Fs_compat.load_file_opt path) in
    let restore_proof ()=match original_proof with
      | Some bytes -> write path bytes
      | None -> if Sys.file_exists path then Sys.remove path in
    let state ()=List.map (fun ((record:Owner.retained),_) -> Owner.record_to_json (Owner.listed record))
      (observed_originals fixture) in
    let before_records=state () and before_memory=cut_memory_bytes fixture
    and before_positions=cut_source_positions fixture and before_wakes= !wakes in
    let before_intents=(view ()).intents in
    let damages=[
      (fun () -> write path "{malformed actual original proof"),restore_proof;
      (fun () -> if Sys.file_exists path then Sys.remove path; Unix.mkdir path 0o700),
        (fun () -> Unix.rmdir path;restore_proof ())] in
    List.iter (fun (damage,restore) ->
      io damage;
      Fun.protect ~finally:(fun () -> io restore) (fun () ->
        (match memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name
          ~wake:(fun () -> incr wakes)) with
         | Error (Consumer.Original_publication_blocked _) -> ()
         | Error error -> fail (Consumer.error_to_string error)
         | Ok _ -> fail "a damaged competing proof reached archive or fresh capture");
        check (list json) "proof failure preserves every original record" before_records (state ());
        check bool "proof failure leaves the independent root unarchived" false
          (settled_on fixture ~date:(day_of root.request_id) root);
        check bool "proof failure preserves Memory and all publication files" true (cut_memory_bytes fixture=before_memory);
        check bool "proof failure preserves atom, official and external ACK" true (cut_source_positions fixture=before_positions);
        check bool "proof failure preserves the original resolution obligation" true ((view ()).intents=before_intents);
        check int "proof failure schedules no pass" before_wakes !wakes;
        check int "proof failure sends no model request" ending_posts (F.post_count fixture.server))) damages) competing in
  (* The first check guards the new ending-only ingress; the second guards a
     later inventory after the ending is durable but before any archive. *)
  refuse_damaged_competing_proof ();
  (match memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name
    ~wake:(fun () -> incr wakes)) with
   | Ok (Consumer.Memory_not_committed _) when Option.is_none competing -> ()
   | Ok (Consumer.Pending _) when Option.is_some competing -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "a linked continuation did not retain its declaration ending");
  Option.iter (fun ((root:Owner.retained),root_request) ->
    let current=io (fun () -> Owner.load ~store:fixture.store ~scope:root.scope ~request_id:root.request_id |> owned |> Option.get) in
    let schema=Option.get (Capture.request root_request |> get).Exact.schema in
    check bool "the independent root retains the actual host ending, not a commit" true
      (match Progress.phase current.progress,competing_ending with
       | Rejected {stage=Execution;evidence},Some Replaced_waiter ->
         (Exact.retained_final_of_json ~schema evidence |> get) = Exact.Retained_not_allowed {reason=Replaced_declaration}
       | Rejected {stage=Execution;evidence},Some Interrupted_waiter ->
         (Exact.retained_final_of_json ~schema evidence |> get) = Exact.Retained_unknown Interrupted
       | (Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
         | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _),
         (None | Some (Replaced_waiter | Interrupted_waiter)) -> false);
    check bool "the ending-only unit did not archive the root using old counts" false
      (settled_on fixture ~date:(day_of root.request_id) root)) competing;
  refuse_damaged_competing_proof ();
  let actual=io (fun () -> Owner.load ~store:fixture.store ~scope:child.scope ~request_id:child.request_id |> owned |> Option.get) in
  check bool "a linked original has a host-confirmed declaration ending" true
    (io (fun () -> Keeper_librarian_declaration_replacement.ended ~store:fixture.store
      ~original:(Owner.listed actual) ~exact ~captured:(Capture.destination request) |> get));
  let body=Filename.concat (Store.root fixture.store)
    (Store.tool_request_body_path ~scope:actual.scope ~request_digest:actual.request_digest) in
  io (fun () -> write body "damaged linked original body");
  let owner_path=Filename.concat (scope_directory fixture actual.scope) (Store.digest actual.request_id ^ ".json") in
  check bool "a linked ending still requires its complete body at deploy" true
    (List.exists (fun (refusal:Lane_addon_store_preflight.refusal) ->
      refusal.path=owner_path && refusal.decoder=Lane_addon_store_preflight.Tool_request_owner)
      (librarian_refusals fixture));
  io (fun () -> write body (Yojson.Safe.to_string actual.request));
  if cut then check bool "Cut keeps its original refusal and separate disposition" true
    (Progress.phase actual.progress=Progress.phase child.progress
      && Option.is_some (Progress.settlement actual.progress));
  check int "the retained ending wakes the serialized lane once" 1 !wakes;
  check int "ending alone sends no new model request" ending_posts (F.post_count fixture.server);
  check bool "ending alone advances no source" true (progress fixture=positions);
  check bool "ending recovery writes no Memory, journal or receipts" true (cut_memory_bytes fixture=ending_memory);
  check bool "ending recovery changes no atom, official or external ACK" true (cut_source_positions fixture=ending_positions);
  check bool "ending is not the operator resolution's Memory completion" true
    ((view ()).completion=Resolution_work.Not_observed);
  let intended_id=match recovery with
  | Ended_only ->
    (* The ending is durable before an intent exists. A rollback still makes
       a new request; it cannot revive the ended original. *)
    replace_actual_worker_configuration fixture ~sw (fixture.declaration true);
    None
  | Intent_only | Child_before_ack ->
    let owner=Capture.physical_owner request in
    let request_id=Capture.fresh_request_id owner in
    let successor=Keeper_librarian_durable_edge.with_destination ~config:fixture.config
      ~reserved:(Keeper_librarian_durable_edge.reserved ()) (fun destination ->
        io (fun () -> Capture.create ~request_id ~owner ~destination
          ~predecessor:{request_id=child.request_id;request_digest=child.request_digest}
          ~source:(Capture.source request) ~preparation:(Capture.preparation request) ())) |> get in
    let intended:Progress.preparation_intent={request_id;
      request=Lane_addon_action.canonical (Capture.to_json successor) |> get} in
    let parent=advance actual (Progress.Replacement_intended intended) in
    let inspect ~require_confirmed ()=io (fun () -> Keeper_librarian_history_resolution_lineage.validate_predecessor_payload
      ~read:(fun ~scope ~request_id -> Owner.load ~store:fixture.store ~scope ~request_id
        |> Result.map_error Owner.error_to_string)
      ~read_fence:(Store.load_history_fence fixture.store)
      ~read_resolution:(Store.load_history_resolution fixture.store) ~require_confirmed successor) in
    inspect ~require_confirmed:false () |> get;
    check bool "the staged whole request does not claim its parent's ACK" true
      (Result.is_error (inspect ~require_confirmed:true ()));
    if cut then (
      let raised=List.fold_left (fun result event ->
        let event=match event with
          | Progress.Refused {stage=Execution;_} -> Progress.Refused {stage=Execution;
              evidence=Exact.retained_final_to_json (Exact.Retained_unknown Exact.Raised)}
          | Transport_observed _ | Approval_intended _ | Approval_wait_retained _
          | Dispatch_intended | Admission_declined _ | Execution_observed _ | Judgment_retained _
          | Preparation_intended _ | Preparation_observed _ | Replacement_intended _ | Replacement_observed _
          | Commit_intended _ | Commit_uncertain _ | Commit_retry_observed _ | Commit_observed _
          | Commit_conflicted _ | Refused {stage=Before_dispatch;_} | Refusal_settled _
          | Successor_intended _ | Successor_observed _ | Observer _ -> event in
        Result.bind result (fun progress -> Progress.append progress event))
        (Ok Progress.captured) (Progress.events parent.progress) |> get in
      let metadata=match Owner.record_to_json (Owner.listed parent) with
        | `Assoc fields -> `Assoc (List.map (fun (name,value) ->
            name,if name="progress" then Progress.to_json raised else value) fields)
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
          fail "fixture owner metadata is not an object" in
      let forged_record=Owner.decode_published
        ~directory_name:(Filename.basename (scope_directory fixture parent.scope))
        ~file_name:(Store.digest parent.request_id ^ ".json") metadata |> get in
      let forged=Owner.rebind parent forged_record
        |> Option.to_result ~none:"fixture record no longer binds its original body" |> get in
      check bool "preflight does not turn a linked Raised into replacement permission" true
        (Result.is_error (io (fun () -> Keeper_librarian_history_resolution_lineage.validate_predecessor_payload
          ~read:(fun ~scope ~request_id ->
            if request_id=parent.request_id then Ok (Some forged)
            else Owner.load ~store:fixture.store ~scope ~request_id |> Result.map_error Owner.error_to_string)
          ~read_fence:(Store.load_history_fence fixture.store)
          ~read_resolution:(Store.load_history_resolution fixture.store) ~require_confirmed:false successor))));
    (match recovery with
     | Ended_only -> fail "unexpected recovery branch"
     | Intent_only -> ()
     | Child_before_ack ->
       let retained=Durable_owner.retain ~store:fixture.store successor
         |> Result.map_error Durable_owner.error_to_string |> get in
       check bool "the child is retained before its parent's ACK" true
         (Progress.phase retained.progress=Progress.Captured);
       let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
         |> Result.map_error Lane_addon_manifest.error_to_string |> get in
       check bool "actual Exact authorization refuses a child before the parent's ACK" true
         (Result.is_error (Server_librarian_addon_validation.authorize ~base_path:fixture.base_path
           ~store:fixture.store ~declaration_id:"librarian" ~package (Capture.request successor |> get))));
    check bool "staged publication preserves the one parent intent" true
      (Progress.replacement parent.progress=Some (Progress.Preparation_pending intended));
    check int "an interrupted publication has no provider effect after the ending" ending_posts (F.post_count fixture.server);
    Some request_id in
  drive_advanced fixture;
  Option.iter (fun ((root:Owner.retained),_) ->
    check bool "fresh inventory archives only the ended independent root" true
      (settled_on fixture ~date:(day_of root.request_id) root)) competing;
  let view=view () in
  let completed_id=match view.completion with
    | Resolution_work.Memory_committed {request_id} -> request_id
    | Not_observed -> fail "the original operator resolution lost its descendant completion"
    | Completion_unavailable detail -> fail detail in
  check bool "the new committed request has another identity" true (completed_id<>child_id);
  Option.iter (fun intended -> check string "restart recovers the same staged child" intended completed_id) intended_id;
  let completed,completed_request=io (fun () ->
    let completed=Owner.load ~store:fixture.store ~scope:child.scope ~request_id:completed_id |> owned |> Option.get in
    let request=Capture.restore ~owner:(Capture.physical_owner request) completed |> get in
    completed,request) in
  check bool "completion belongs to a descendant of the ended original" true
    (Capture.predecessor completed_request=Some {Capture.request_id=child.request_id;request_digest=child.request_digest});
  check json "the committed descendant preserves the exact original source"
    (Source.to_json (Capture.source request)) (Source.to_json (Capture.source completed_request));
  check bool "actual Memory commit is the completion evidence" true
    (match Progress.phase completed.progress with
     | Finished _ -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
  check int "only the new linked request reaches the provider after the ending" (ending_posts+1) (F.post_count fixture.server);
  check (list string) "the sole new provider call names the retained linked descendant"
    [completed_id] !completion_provider_ids;
  check bool "source positions advance only after the descendant commit" false (progress fixture=positions);
  let through=Keeper_librarian_input_sources.external_through (Source.counterparts (Capture.source completed_request)) in
  let external_cursor=io (fun () -> Keeper_external_read_cursor.observe
    ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
  check bool "the real descendant commit ACKs the exact original external frontier" true
    (Keeper_external_read_cursor.observation_matches_preparation external_cursor
      ~after:through ~through ~atom:None ~official:None);
  check int "the original resolution retains committed range receipts" 1
    (List.length (List.filter (fun intent -> Option.is_some intent.Resolution_intent.memory_commit) view.intents));
  check bool "the fenced parent and ended child remain available to completion recovery" true
    (io (fun () -> Owner.load_record ~store:fixture.store ~scope:parent.scope ~request_id:parent.request_id |> owned |> Option.is_some)
      && io (fun () -> Owner.load_record ~store:fixture.store ~scope:child.scope ~request_id:child.request_id |> owned |> Option.is_some)))
let test_fenced_resolution_survives_cursor_advance ~nested () = with_fixture (fun ~sw:_ fixture ->
  let submit request expected=io (fun () -> Resolution_work.submit ~config:fixture.config ~keeper_name
    ~request_id:(Capture.request_id request) ~expected ~actor:"operator" ~reason:"resume the exact history"
    ~now:(Time_compat.now ())) in
  let read request=io (fun () -> Resolution_work.read ~config:fixture.config ~keeper_name
    ~request_id:(Capture.request_id request) |> Result.map_error Resolution_intent.error_to_string |> get) in
  let last request=List.rev (read request).intents |> List.hd in
  let run ()=memory_action fixture (fun () -> Resolution_work.run_serialized ~config:fixture.config ~keeper_name) in
  let run_ok ()=run () |> Result.map_error Resolution_intent.error_to_string |> get in
  let original,request=retain_absent_history_original fixture in
  let original,request=if not nested then original,request else (
    ignore (submit request (fence_preview fixture request).expected
      |> Result.map_error Resolution_intent.error_to_string |> get);
    run_ok ();
    let child_id=match (last request).phase with
      | Child_confirmed child -> child.request_id
      | Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _ -> fail "nested fixture has no confirmed child" in
    let child,request=io (fun () ->
      let child=Owner.load ~store:fixture.store ~scope:original.scope ~request_id:child_id |> owned |> Option.get in
      let request=Capture.restore ~owner:(Capture.physical_owner request) child |> get in child,request) in
    let advance child event=io (fun () -> match Owner.advance ~store:fixture.store ~expected:child ~event with
      | Ok (Owner.Stored child | Already_stored child) -> child
      | Ok (Unconfirmed detail) -> fail detail
      | Error error -> fail (Owner.update_error_to_string error)) in
    let child=advance child Progress.Dispatch_intended in
    advance child (Progress.Execution_observed (Progress.Absent (`Assoc []))),request) in
  let preview=fence_preview fixture request in
  let submission=submit request preview.expected |> Result.map_error Resolution_intent.error_to_string |> get in
  let fenced=memory_action fixture (fun () -> io (fun () ->
    let fence=Resolution.fence_serialized ~config:fixture.config ~keeper_name ~request_id:original.request_id
      ~expected:preview.expected ~actor:"operator" ~reason:"resume the exact history" ~now:(Time_compat.now ())
      |> Result.map_error Resolution.error_to_string |> get in
    Resolution_intent.confirm_fence ~store:fixture.store ~expected:submission.intent fence
      |> Result.map_error Resolution_intent.error_to_string |> get)) in
  check bool "the interruption is after fence but before any child intent" true
    (fenced.phase=Resolution_intent.Fenced && Resolution_intent.child fenced=None);
  let owner=Capture.physical_owner request in
  let cursor_path=Keeper_external_read_cursor.path_for_keepers_dir
    ~keepers_dir:(Capture.runtime_keepers_dir owner) ~keeper_id:keeper_name in
  io (fun () -> write cursor_path "{unreadable cursor");
  check bool "unreadable source state stays unavailable rather than terminal" true
    (match run () with Error (Resolution_intent.Unavailable _) -> true
     | Ok () | Error (Invalid _ | Conflict _ | Publication_uncertain _ | Host_claim_busy) -> false);
  check bool "an unavailable read preserves the fenced phase" true ((last request).phase=Resolution_intent.Fenced);
  (* Model the durable cursor left by another operation during the crash cut;
     resolution itself must neither advance it nor restore the older offset. *)
  let cursor=Keeper_external_read_cursor.observation_of_json (`Assoc [
    "after",`Int (Keeper_external_read_cursor.observation_offset (Source.external_before (Capture.source request))+1);
    "pending",`Null]) |> get in
  io (fun () -> write cursor_path (Yojson.Safe.to_string (Keeper_external_read_cursor.observation_to_json cursor)));
  run_ok ();
  check bool "a definite post-fence cursor change is durably refused" true
    (match (last request).phase with Refused (No_longer_eligible _) -> true
     | Requested | Refused Observation_changed | Fenced | Child_prepared _ | Child_intended _ | Child_confirmed _ -> false);
  check bool "terminal refusal has no child or claimed Memory receipt" true
    (Resolution_intent.child (last request)=None && (read request).completion=Resolution_work.Not_observed);
  check bool "refusal does not move the externally observed cursor" true
    (io (fun () -> Keeper_external_read_cursor.observe ~runtime_keepers_dir:(Capture.runtime_keepers_dir owner)
      ~keeper_name |> get)=cursor);
  no_memory fixture;
  check int "recovery dispatched no provider request" 0 (F.post_count fixture.server);
  refuse_fenced_resume fixture original request;
  let retry=submit request preview.expected |> Result.map_error Resolution_intent.error_to_string |> get in
  check bool "an identical retry observes the same terminal intent" true
    (retry.reobserved && retry.intent.intent_id=fenced.intent_id && retry.intent.phase=(last request).phase);
  let changed={preview.expected with cursors_sha256=Store.digest "another observation"} in
  check bool "another guard cannot remove or retarget the immutable fence" true
    (match submit request changed with Error (Resolution_intent.Conflict _) -> true
     | Ok _ | Error (Invalid _ | Unavailable _ | Publication_uncertain _ | Host_claim_busy) -> false);
  run_ok ();
  drive_advanced fixture;
  check int "ordinary fresh history runs after the durable refusal" 1 (F.post_count fixture.server);
  check bool "fresh history actually commits Memory" true (io (fun () -> claims fixture.keepers_dir)<>[]);
  check bool "the unknown original stays live and unchanged" true
    (Option.map Owner.to_json (io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
      ~request_id:original.request_id |> owned))=Some (Owner.to_json original));
  refuse_fenced_resume fixture original request)
let prepare_resolution_fixture fixture =
  let original,request=retain_absent_history_original fixture in
  let expected=(fence_preview fixture request).expected in
  let accepted=io (fun () -> Resolution_work.submit ~config:fixture.config ~keeper_name
    ~request_id:original.request_id ~expected ~actor:"operator"
    ~reason:"Retain one complete successor before staging" ~now:(Time_compat.now ())
    |> Result.map_error Resolution_intent.error_to_string |> get) in
  let fenced=memory_action fixture (fun () -> io (fun () ->
    let fence=Resolution.fence_serialized ~config:fixture.config ~keeper_name
      ~request_id:original.request_id ~expected ~actor:accepted.intent.actor
      ~reason:accepted.intent.reason ~now:(Time_compat.now ())
      |> Result.map_error Resolution.error_to_string |> get in
    Resolution_intent.confirm_fence ~store:fixture.store ~expected:accepted.intent fence
      |> Result.map_error Resolution_intent.error_to_string |> get)) in
  let owner=Capture.physical_owner request in
  let child ()=io (fun () -> Capture.create ~request_id:(Capture.fresh_request_id owner)
    ~predecessor:{request_id=original.request_id;request_digest=original.request_digest}
    ~owner ~destination:(Capture.destination request) ~source:(Capture.source request)
    ~preparation:(Capture.preparation request) ()) |> get in
  original,request,fenced,child
type resolution_preparation_cut = Before_body | Body_before_compaction | Compaction_before_owner
let test_resolution_preparation_recovers_exact_bytes cut () = with_fixture (fun ~sw:_ fixture ->
  let original,_request,fenced,make_child=prepare_resolution_fixture fixture in
  let child=make_child () and losing_child=make_child () in
  let before=progress fixture,F.post_count fixture.server in
  ignore (memory_action fixture (fun () -> io (fun () ->
    Resolution_intent.prepare_child ~store:fixture.store ~expected:fenced child
      |> Result.map_error Resolution_intent.error_to_string |> get)));
  let load_resolution ()=io (fun () -> Store.load_history_resolution fixture.store
    ~scope:original.scope ~request_id:original.request_id |> get |> Option.get) in
  let original_preparation=load_resolution () in
  (* Reloaded canonical JSON can order nested schema fields differently from
     the live request. The same ID and verified digest still name its bytes. *)
  let prepared=io (fun () -> Resolution_intent.read ~config:fixture.config ~keeper_name
    ~request_id:original.request_id |> Result.map_error Resolution_intent.error_to_string |> get)
    |> List.hd in
  let body_path=Filename.concat (Store.root fixture.store)
    (Store.tool_request_body_path ~scope:original.scope ~request_digest:(Capture.body_digest child)) in
  check bool "the complete preparation exists before its body or child owner" true
    (not (Sys.file_exists body_path) && Resolution_intent.child prepared=None
      && io (fun () -> Owner.load_record ~store:fixture.store ~scope:original.scope
        ~request_id:(Capture.request_id child) |> owned)=None);
  check bool "the prepared phase is not execution authority" true
    (Result.is_error (memory_action fixture (fun () -> Durable_owner.retain ~store:fixture.store child)));
  let public_phase=member "phase" (Resolution_intent.to_public_json prepared) in
  check json "the public phase contains identifiers without the private request"
    (`Assoc ["kind",`String "child_prepared";"child",`Assoc [
      "request_id",`String (Capture.request_id child);"request_digest",`String (Capture.body_digest child)]]) public_phase;
  check bool "a competing preparation cannot remint or overwrite the winner" true
    (Result.is_error (memory_action fixture (fun () -> io (fun () ->
      Resolution_intent.prepare_child ~store:fixture.store ~expected:fenced losing_child)))
      && load_resolution ()=original_preparation);
  let preflight ()=io (fun () -> Lane_addon_store_preflight.scan
    ~validate_tool_request:Keeper_librarian_store_preflight.preflight
    ~validate_history_resolution:Resolution_intent.check_published_file
    Lane_addon_store_preflight.Store.Tool_request_owners ~base_path:fixture.base_path |> get) in
  check int "deployment preflight accepts the complete prepared intermediate state" 0
    (List.length (preflight ()).refusals);
  (match cut with
   | Before_body -> ()
   | Body_before_compaction ->
     ignore (io (fun () -> Owner.prepare_successor ~store:fixture.store ~scope:original.scope
       ~request_id:(Capture.request_id child) ~request:(Capture.to_json child) |> owned));
     check json "a crash after the body leaves the same complete preparation"
       original_preparation (load_resolution ())
   | Compaction_before_owner ->
     ignore (memory_action fixture (fun () -> io (fun () ->
       Resolution_intent.intend_child ~store:fixture.store ~expected:prepared child
         |> Result.map_error Resolution_intent.error_to_string |> get))));
  let written_inode=if Sys.file_exists body_path then Some (Unix.lstat body_path).st_ino else None in
  let fact=Types.observed ~claim:"Memory changed while the complete child waited" ~category:Types.Fact
    ~now:(Time_compat.now ()) ~origin:{kind=Types.Authored;trace_id="prepared-child-writer"} in
  io (fun () -> Current.upsert_fact ~pass:Keeper_memory_commit_pass.Keeper_write
    ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name ~now:(Time_compat.now ())
    ~source:{kind=Current.Explicit_write;trace_id="prepared-child-writer"} fact
    |> Result.map_error Current.upsert_error_to_string |> get) |> ignore;
  let previous=(Prompt_registry.resolve_prompt Prompt_names.librarian).override_value in
  Fun.protect ~finally:(fun () -> match previous with
    | None -> Prompt_registry.clear_prompt_override Prompt_names.librarian
    | Some value -> Prompt_registry.set_override Prompt_names.librarian value |> get) (fun () ->
    Prompt_registry.set_override Prompt_names.librarian "A changed template must not rerender a retained preparation." |> get;
    memory_action fixture (fun () -> Resolution_work.run_serialized ~config:fixture.config ~keeper_name)
      |> Result.map_error Resolution_intent.error_to_string |> get);
  let intent=io (fun () -> Resolution_intent.read ~config:fixture.config ~keeper_name
    ~request_id:original.request_id |> Result.map_error Resolution_intent.error_to_string |> get)
    |> List.hd in
  (match intent.phase with
   | Resolution_intent.Child_confirmed confirmed ->
     check string "restart acknowledges the retained child ID" (Capture.request_id child) confirmed.request_id;
     check string "restart acknowledges the retained body digest" (Capture.body_digest child) confirmed.request_digest
   | Requested | Refused _ | Fenced | Child_prepared _ | Child_intended _ -> fail "retained preparation was not recovered");
  let retained=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
    ~request_id:(Capture.request_id child) |> owned |> Option.get) in
  check json "changed Memory, template and clock do not change prepared request bytes"
    (Lane_addon_action.canonical (Capture.to_json child) |> get) retained.request;
  check bool "an existing exact body is reobserved without replacing its inode" true
    (Option.fold ~none:true ~some:(fun inode -> inode=(Unix.lstat body_path).st_ino) written_inode);
  check bool "publication of the child advances no source and calls no provider" true
    (before=(progress fixture,F.post_count fixture.server));
  check bool "compaction removes the private request from the resolution envelope" true
    (member "request" (member "phase" (Yojson.Safe.Util.to_list (member "intents" (load_resolution ())) |> List.hd))=`Null);
  check bool "the losing candidate has no body or owner record" true
    (not (Sys.file_exists (Filename.concat (Store.root fixture.store)
       (Store.tool_request_body_path ~scope:original.scope ~request_digest:(Capture.body_digest losing_child))))
      && io (fun () -> Owner.load_record ~store:fixture.store ~scope:original.scope
        ~request_id:(Capture.request_id losing_child) |> owned)=None))
let test_resolution_preparation_preserves_conflicting_body () = with_fixture (fun ~sw:_ fixture ->
  let original,_request,fenced,make_child=prepare_resolution_fixture fixture in
  let child=make_child () in
  let prepared=memory_action fixture (fun () -> io (fun () ->
    Resolution_intent.prepare_child ~store:fixture.store ~expected:fenced child
      |> Result.map_error Resolution_intent.error_to_string |> get)) in
  let before=io (fun () -> Store.load_history_resolution fixture.store ~scope:original.scope
    ~request_id:original.request_id |> get) in
  let path=Filename.concat (Store.root fixture.store)
    (Store.tool_request_body_path ~scope:original.scope ~request_digest:(Capture.body_digest child)) in
  let conflicting="conflicting retained body evidence" in
  io (fun () -> write path conflicting);
  check bool "a conflicting content address cannot be repaired by overwriting evidence" true
    (Result.is_error (memory_action fixture (fun () -> io (fun () ->
      Resolution_intent.intend_child ~store:fixture.store ~expected:prepared child))));
  check string "the conflicting bytes are preserved" conflicting
    (io (fun () -> In_channel.with_open_bin path In_channel.input_all));
  check bool "failure keeps the complete preparation and publishes no child" true
    (io (fun () -> Store.load_history_resolution fixture.store ~scope:original.scope
      ~request_id:original.request_id |> get)=before
      && io (fun () -> Owner.load_record ~store:fixture.store ~scope:original.scope
        ~request_id:(Capture.request_id child) |> owned)=None);
  no_memory fixture)
let test_history_resolution_rejects_stale_then_continues_the_same_original () = with_fixture (fun ~sw:_ fixture ->
  let original,request=retain_absent_history_original fixture in
  let preview=fence_preview fixture request in
  let submit_for request_id expected=io (fun () -> Resolution_work.submit ~config:fixture.config ~keeper_name
    ~request_id ~expected ~actor:"operator" ~reason:"rejudge this exact unknown range"
    ~now:(Time_compat.now ()) |> Result.map_error Resolution_intent.error_to_string |> get) in
  let submit=submit_for original.request_id in
  let initial=submit preview.expected in
  let fact=Types.observed ~claim:"A concurrent fact changes the preview basis" ~category:Types.Fact
    ~now:(Time_compat.now ()) ~origin:{kind=Types.Authored;trace_id="concurrent-writer"} in
  io (fun () -> Current.upsert_fact ~pass:Keeper_memory_commit_pass.Keeper_write ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
    ~now:(Time_compat.now ()) ~source:{kind=Current.Explicit_write;trace_id="concurrent-writer"} fact
    |> Result.map_error Current.upsert_error_to_string |> get) |> ignore;
  let run_resolution ()=memory_action fixture (fun () -> Resolution_work.run_serialized
    ~config:fixture.config ~keeper_name |> Result.map_error Resolution_intent.error_to_string |> get) in
  run_resolution ();
  let repeated=submit preview.expected in
  check bool "a stale submission is durably refused and the identical retry observes it" true
    (repeated.reobserved && repeated.intent.intent_id=initial.intent.intent_id
     && repeated.intent.phase=Resolution_intent.Refused Observation_changed);
  let fresh=fence_preview fixture request in
  let accepted=submit fresh.expected in
  check bool "a new explicit observation has a different durable identity" true
    (not accepted.reobserved && accepted.intent.intent_id<>initial.intent.intent_id);
  run_resolution ();
  let observe ()=io (fun () -> Resolution_work.read ~config:fixture.config ~keeper_name
    ~request_id:original.request_id |> Result.map_error Resolution_intent.error_to_string |> get) in
  let prepared=observe () in
  let child_id=match List.rev prepared.intents with
    | {Resolution_intent.phase=Child_confirmed child;_}::_ -> child.request_id
    | _ -> fail "resolution did not durably acknowledge its child" in
  run_resolution ();
  check bool "another serialized wake restores the same child without an RPC" true
    (match List.rev (observe ()).intents with
     | {Resolution_intent.phase=Child_confirmed child;_}::_ -> child.request_id=child_id && F.post_count fixture.server=0
     | _ -> false);
  (* The resolution record names its child by ID and digest. The child's
     request is the body file that digest names, and nowhere else. *)
  let resolution_json ()=io (fun () -> Store.load_history_resolution fixture.store ~scope:original.scope
    ~request_id:original.request_id |> get |> Option.get) in
  let child_digest=match List.rev prepared.intents with
    | {Resolution_intent.phase=Child_confirmed child;_}::_ -> child.request_digest
    | _ -> fail "resolution did not durably acknowledge its child" in
  let root=Store.root fixture.store in
  let child_body=Filename.concat root (Store.tool_request_body_path ~scope:original.scope ~request_digest:child_digest) in
  let child_record=Filename.concat root (Filename.concat Store.tool_request_owners_directory
    (Filename.concat (Store.digest original.scope) (Store.digest child_id ^ ".json"))) in
  let body_bytes=io (fun () -> In_channel.with_open_bin child_body In_channel.input_all) in
  check bool "the resolution record carries no copy of the child request" true
    (String.length (Yojson.Safe.to_string (resolution_json ())) < String.length body_bytes);
  (* A crash after the intent and before the child record: the next wake
     retains the child from the staged body. *)
  let unacknowledge ()=
    let stored=resolution_json () in
    io (fun () ->
    let rec rewrite = function
      | `Assoc fields -> `Assoc (List.map (fun (name,value) -> match name,value with
          | "kind",`String "child_confirmed" -> name,`String "child_intended"
          | _ -> name,rewrite value) fields)
      | `List values -> `List (List.map rewrite values)
      | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as leaf -> leaf in
    (match Store.publish_history_resolution fixture.store ~scope:original.scope ~request_id:original.request_id
       ~expected:(Some stored) ~next:(rewrite stored) |> get with
     | Store.History_resolution_stored -> ()
     | History_resolution_changed | History_resolution_unconfirmed _ -> fail "fixture could not rewind the resolution phase");
    Sys.remove child_record) in
  unacknowledge ();
  run_resolution ();
  check bool "a lost child record is retained again from the staged body" true
    (match List.rev (observe ()).intents with
     | {Resolution_intent.phase=Child_confirmed child;_}::_ ->
       child.request_id=child_id && child.request_digest=child_digest && Sys.file_exists child_record
     | _ -> false);
  (* Without the staged body the child is not made again. *)
  unacknowledge ();
  io (fun () -> Sys.remove child_body);
  check bool "a lost staged body stops the resolution" true
    (match memory_action fixture (fun () -> Resolution_work.run_serialized ~config:fixture.config ~keeper_name) with
     | Error (Resolution_intent.Unavailable _) -> not (Sys.file_exists child_record)
     | Ok () | Error (Invalid _ | Conflict _ | Publication_uncertain _ | Host_claim_busy) -> false);
  io (fun () -> write child_body body_bytes);
  run_resolution ();
  (* The record names a child by ID and digest only. A record made to name
     another original of the scope is refused by that original's own
     predecessor. *)
  let stranger_request=io (fun () -> Capture.create ~request_id:(Capture.fresh_request_id (Capture.physical_owner request))
    ~owner:(Capture.physical_owner request) ~destination:(Capture.destination request)
    ~source:(Capture.source request) ~preparation:(Capture.preparation request) ()) |> get in
  let stranger=memory_action fixture (fun () -> Durable_owner.retain ~store:fixture.store stranger_request)
    |> Result.map_error Durable_owner.error_to_string |> get in
  let original_resolution=Filename.concat root (Store.history_resolution_path ~scope:original.scope ~request_id:original.request_id) in
  let honest=io (fun () -> In_channel.with_open_bin original_resolution In_channel.input_all) in
  let rec rebind = function
    | `Assoc fields when List.assoc_opt "kind" fields=Some (`String "child_confirmed") ->
      `Assoc (List.map (fun (name,value) -> match name with
        | "child" -> name,`Assoc ["request_id",`String stranger.request_id;"request_digest",`String stranger.request_digest]
        | _ -> name,value) fields)
    | `Assoc fields -> `Assoc (List.map (fun (name,value) -> name,rebind value) fields)
    | `List values -> `List (List.map rebind values)
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as leaf -> leaf in
  let rebound=Yojson.Safe.to_string (rebind (Yojson.Safe.from_string honest)) in
  check bool "the fixture rebinds the child" true (rebound<>honest);
  io (fun () -> write original_resolution rebound);
  check bool "a record naming an original that is not its child stops the resolution" true
    (match memory_action fixture (fun () -> Resolution_work.run_serialized ~config:fixture.config ~keeper_name) with
     | Error (Resolution_intent.Unavailable detail) -> detail="Resolution child has no original predecessor"
     | Ok () | Error (Invalid _ | Conflict _ | Publication_uncertain _ | Host_claim_busy) -> false);
  io (fun () -> write original_resolution honest;
    Sys.remove (Filename.concat root (Filename.concat Store.tool_request_owners_directory
      (Filename.concat (Store.digest original.scope) (Store.digest stranger.request_id ^ ".json")))));
  run_resolution ();
  let load_child id=io (fun () ->
    let record=Owner.load ~store:fixture.store ~scope:original.scope ~request_id:id |> owned |> Option.get in
    let request=Capture.restore ~owner:(Capture.physical_owner request) record |> get in record,request) in
  let child,child_request=load_child child_id in
  (* The Keeper's lineage check reads the fenced parent as its record and
     the index in that record's summary. *)
  let module Lineage=Keeper_librarian_history_resolution_lineage in
  let record_path id=Filename.concat root (Filename.concat Store.tool_request_owners_directory
    (Filename.concat (Store.digest original.scope) (Store.digest id ^ ".json"))) in
  let parent_body=Filename.concat root (Store.tool_request_body_path ~scope:original.scope
    ~request_digest:original.request_digest) in
  let parent_bytes=io (fun () -> In_channel.with_open_bin parent_body In_channel.input_all) in
  let module Published=Owner.Published_reader in
  let read_text path=if Sys.file_exists path then
      Ok (Some (In_channel.with_open_bin path In_channel.input_all)) else Ok None in
  let published=Published.create ~read_body:(fun ~scope ~request_digest ->
    read_text (Filename.concat root (Store.tool_request_body_path ~scope ~request_digest))) in
  let read ~scope ~request_id =
    let open Result.Syntax in
    let* bytes=read_text (record_path request_id) in
    match bytes with
    | None -> Ok None
    | Some bytes ->
      let* json=try Ok (Yojson.Safe.from_string bytes) with Yojson.Json_error detail -> Error detail in
      Result.map Option.some (Published.read published ~directory_name:(Store.digest scope)
        ~file_name:(Store.digest request_id ^ ".json") json) in
  let indexes=Lineage.payload_indexes () in
  let payload_lineage ?indexes ()=io (fun () -> Lineage.validate_predecessor_payload ?indexes
    ~read ~read_fence:(Store.load_history_fence fixture.store)
    ~read_resolution:(Store.load_history_resolution fixture.store)
    ~require_confirmed:true child_request) in
  check (result unit string) "preflight proves the ancestor index" (Ok ()) (payload_lineage ~indexes ());
  check (result unit string) "preflight reuses the same verified ancestor" (Ok ()) (payload_lineage ~indexes ());
  let compare_payload label=check (result unit string) label
    (payload_lineage ()) (payload_lineage ~indexes ()) in
  io (fun () -> Sys.remove parent_body);
  compare_payload "a missing ancestor body cannot borrow a preflight index";
  io (fun () -> write parent_body parent_bytes);
  check (result unit string) "restored bytes can be verified again" (Ok ()) (payload_lineage ~indexes ());
  let corrupt=Bytes.of_string parent_bytes in
  Bytes.set corrupt 0 (if Bytes.get corrupt 0='{' then '[' else '{');
  io (fun () -> write parent_body (Bytes.to_string corrupt));
  compare_payload "same-length corruption cannot borrow a preflight index";
  io (fun () -> write parent_body parent_bytes);
  check (result unit string) "preflight accepts restored bytes again" (Ok ()) (payload_lineage ~indexes ());
  let lineage ()=io (fun () -> Lineage.confirm_predecessor ~store:fixture.store ~require_confirmed:true child_request) in
  io (fun () -> Sys.remove parent_body);
  check (result unit string) "lineage of a resolution child passes without the parent's body" (Ok ()) (lineage ());
  check bool "the host's lineage check still reads the parent's body" true
    (Result.is_error (io (fun () -> Lineage.confirm_predecessor_by_body ~store:fixture.store
      ~require_confirmed:true child_request)));
  io (fun () -> write parent_body parent_bytes);
  check (result unit string) "the host's lineage check passes with the parent's body" (Ok ())
    (io (fun () -> Lineage.confirm_predecessor_by_body ~store:fixture.store ~require_confirmed:true child_request));
  let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
    |> Result.map_error Lane_addon_manifest.error_to_string |> get in
  let authorization=Server_librarian_addon_validation.authorize ~base_path:fixture.base_path
    ~store:fixture.store ~declaration_id:"librarian" ~package (Capture.request child_request |> get)
    |> Result.map_error (function Exact.Unowned {reason} -> reason | Undecided {detail} -> detail)
    |> get |> Option.get in
  let guard ()=authorization.before_dispatch () |> Result.map_error Exact.dispatch_veto_detail in
  check (result unit string) "an unchanged fenced ancestor passes the actual dispatch recheck" (Ok ()) (guard ());
  let posts=F.post_count fixture.server and positions=progress fixture in
  let preserve_parent action=Fun.protect
    ~finally:(fun () -> Eio.Cancel.protect (fun () -> io (fun () -> write parent_body parent_bytes))) action in
  preserve_parent (fun () ->
    io (fun () -> Sys.remove parent_body);
    check bool "a missing ancestor body refuses actual dispatch" true (guard_waits authorization.before_dispatch));
  preserve_parent (fun () ->
    let corrupted=Bytes.of_string parent_bytes in
    Bytes.set corrupted 0 (if Bytes.get corrupted 0='{' then '[' else '{');
    io (fun () -> write parent_body (Bytes.to_string corrupted));
    check bool "same-length ancestor corruption refuses actual dispatch" true
      (guard_waits authorization.before_dispatch));
  let proof=io (fun () -> Lineage.verify_predecessors ~store:fixture.store
    ~require_confirmed:true child_request |> get) in
  let copied=io (fun () -> Capture.restore ~owner:(Capture.physical_owner request) child |> get) in
  check bool "another request object cannot borrow an authorization's ancestor proof" true
    (Result.is_error (io (fun () -> Lineage.recheck_predecessors ~store:fixture.store
      ~require_confirmed:true copied proof)));
  check bool "another store object cannot borrow an authorization's ancestor proof" true
    (Result.is_error (io (fun () -> Lineage.recheck_predecessors
      ~store:(Store.create ~root) ~require_confirmed:true child_request proof)));
  check int "ancestor rechecks call no provider" posts (F.post_count fixture.server);
  check bool "ancestor rechecks acknowledge no source" true (progress fixture=positions);
  let with_summary_json id name value f=
    let path=record_path id in
    let honest=io (fun () -> In_channel.with_open_bin path In_channel.input_all) in
    let changed=match Yojson.Safe.from_string honest with
      | `Assoc fields -> `Assoc (List.map (fun (field,stored) -> match field,stored with
          | "summary",`Assoc summary -> field,`Assoc (List.map (fun (key,old) ->
              if key=name then key,value else key,old) summary)
          | _ -> field,stored) fields)
      | _ -> fail "original record is not an object" in
    let changed=Yojson.Safe.to_string changed in
    check bool ("the fixture changes the index value "^name) true (changed<>honest);
    io (fun () -> write path changed);
    let result=f () in
    io (fun () -> write path honest);
    result in
  let with_summary_value id name value f=with_summary_json id name (`String value) f in
  ignore (with_summary_value original.request_id "source_digest" (String.make 64 '0') (fun () ->
    compare_payload "a changed root summary cannot borrow a fully checked ancestor index"));
  check (result unit string) "preflight proves the restored summary again" (Ok ()) (payload_lineage ~indexes ());
  check bool "a changed ancestor summary refuses actual dispatch" true
    (with_summary_value original.request_id "source_digest" (String.make 64 '0')
      (fun () -> guard_waits authorization.before_dispatch));
  check (result unit string) "restoring the ancestor lets the same authorization recheck again" (Ok ()) (guard ());
  (* The resolution pass reads a waiting pair as two records and their
     indexes, and neither body. *)
  let resolution_pass ()=memory_action fixture (fun () -> Resolution_work.run_serialized
    ~config:fixture.config ~keeper_name) |> Result.map_error Resolution_intent.error_to_string in
  io (fun () -> Sys.remove parent_body;Sys.remove child_body);
  check (result unit string) "the resolution pass reads neither body of a waiting pair" (Ok ()) (resolution_pass ());
  io (fun () -> write parent_body parent_bytes;write child_body body_bytes);
  check (result unit string) "a parent index with another source digest differs from its fence"
    (Error "History fence immutable binding differs; publication remains blocked")
    (with_summary_value original.request_id "source_digest" (String.make 64 '0') resolution_pass);
  check (result unit string) "a child index naming another predecessor digest stops the resolution"
    (Error "Resolution child has another original predecessor")
    (with_summary_json child_id "predecessor" (`Assoc ["request_digest",`String (String.make 64 '0');
      "request_id",`String original.request_id]) resolution_pass);
  check (result unit string) "a child index with another source basis breaks the lineage the pass confirms"
    (Error "History resolution child changed its original source or owner")
    (with_summary_value child_id "source_basis_digest" (String.make 64 '0') resolution_pass);
  check (result unit string) "the unchanged pair passes again" (Ok ()) (resolution_pass ());
  check (result unit string) "a parent index with another source basis differs from its fence"
    (Error "History fence immutable binding differs; publication remains blocked")
    (with_summary_value original.request_id "source_basis_digest" (String.make 64 '0') lineage);
  check (result unit string) "the unchanged parent index passes again" (Ok ()) (lineage ());
  check bool "a record whose index differs from its body is refused where the body is read" true
    (with_summary_value child_id "exact_digest" (String.make 64 '0') (fun () -> io (fun () ->
      match Owner.load ~store:fixture.store ~scope:original.scope ~request_id:child_id with
      | Ok (Some record) -> Capture.restore ~owner:(Capture.physical_owner request) record
        =Error "Original history index differs from its request"
      | Ok None | Error _ -> false)));
  let advance child event=io (fun () -> match Owner.advance ~store:fixture.store ~expected:child ~event with
    | Ok (Owner.Stored child | Already_stored child) -> child
    | Ok (Unconfirmed detail) -> fail detail
    | Error error -> fail (Owner.update_error_to_string error)) in
  let child=advance child Progress.Dispatch_intended in
  ignore (advance child (Progress.Execution_observed (Progress.Absent (`Assoc []))));
  let child_preview=fence_preview fixture child_request in
  ignore (submit_for child_id child_preview.expected);
  run_resolution ();
  let descendant=io (fun () -> Resolution_work.read ~config:fixture.config ~keeper_name ~request_id:child_id
    |> Result.map_error Resolution_intent.error_to_string |> get) in
  let descendant_id=match List.rev descendant.intents with
    | {Resolution_intent.phase=Child_confirmed child;_}::_ -> child.request_id
    | _ -> fail "nested resolution did not acknowledge its exact child" in
  let preflight=io (fun () -> Lane_addon_store_preflight.scan
    ~validate_tool_request:Keeper_librarian_store_preflight.preflight
    Lane_addon_store_preflight.Store.Tool_request_owners ~base_path:fixture.base_path |> get) in
  check int "strict preflight reads the real fenced-parent child link" 0 (List.length preflight.refusals);
  (* A pass decodes every resolution record of its scope. Preflight refuses
     one of another schema that no original leads to, and fresh state deletes
     the scope it stops. *)
  let scan ()=io (fun () -> Lane_addon_store_preflight.scan
    ~validate_tool_request:Keeper_librarian_store_preflight.preflight
    ~validate_history_resolution:Resolution_intent.check_published_file
    Lane_addon_store_preflight.Store.Tool_request_owners ~base_path:fixture.base_path |> get) in
  check int "preflight reads every current resolution record" 0 (List.length (scan ()).refusals);
  let scope_group=Store.digest original.scope in
  let absent_id=Capture.fresh_request_id (Capture.physical_owner request) in
  let stray=Filename.concat root (Store.history_resolution_path ~scope:original.scope ~request_id:absent_id) in
  io (fun () -> write stray (Yojson.Safe.to_string (`Assoc ["schema",`String "keeper.librarian.history-resolution.v1";
    "scope",`String original.scope;"request_id",`String absent_id;"intents",`List []])));
  let scope_directory namespace=Filename.concat root (Filename.concat namespace scope_group) in
  check bool "preflight refuses a resolution record of another schema whose original has no record" true
    (match (scan ()).refusals with
     | [refusal] -> refusal.path=stray && refusal.decoder=Lane_addon_store_preflight.History_resolution
       && List.for_all (fun namespace -> List.mem (scope_directory namespace) refusal.delete)
         [Store.tool_request_owners_directory;Store.tool_request_bodies_directory;
          Store.history_fences_directory;Store.history_resolutions_directory]
     | [] | _::_::_ -> false);
  check bool "that record stops the Keeper's resolution pass" true
    (match memory_action fixture (fun () -> Resolution_work.run_serialized ~config:fixture.config ~keeper_name) with
     | Error (Resolution_intent.Unavailable _) -> true
     | Ok () | Error (Invalid _ | Conflict _ | Publication_uncertain _ | Host_claim_busy) -> false);
  io (fun () -> Sys.remove stray);
  let resume_descendant ()=
    let original,request=load_child descendant_id in
    memory_action fixture (fun () -> Durable_owner.resume ~store:fixture.store ~config:fixture.config
      ~reserved:(Keeper_librarian_durable_edge.reserved ()) ~original:(Durable_owner.Read (original,request))
      ~wake:(fun () -> ())
      ~call:(Keeper_librarian_durable_edge.call ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ()))
      ~publish:(fun ~original ~request ~proposal ->
        Keeper_librarian_durable_commit.publish ~store:fixture.store ~config:fixture.config
          ~original ~request ~proposal ~fresh_authority:(Keeper_librarian_durable_edge.fresh_gate_authority
            ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ())
            ~owner:(Capture.physical_owner request) ~expected:(Capture.destination request))
        |> Result.map_error (fun detail -> Durable_owner.Rejected detail))) in
  let delivered= !(fixture.deliveries) in
  (match resume_descendant () with
   | Ok (Durable_owner.Waited _) -> ()
   | Error error -> fail (Durable_owner.error_to_string error)
   | Ok (Resumed _ | Original_replaced _) -> fail "descendant did not dispatch its actual worker request");
  await_delivery fixture ~after:delivered;
  (match resume_descendant () with
   | Ok (Durable_owner.Resumed (Finished _,_)) -> ()
   | Error error -> fail (Durable_owner.error_to_string error)
   | Ok (Waited _ | Original_replaced _ | Resumed ((Publication_waiting _ | Refused _ | Basis_superseded _ | Ended_unadmitted _),_)) ->
     fail "descendant did not finish its actual Memory publication");
  check bool "the crash cut precedes durable completion observation" true
    ((observe ()).completion=Resolution_work.Not_observed);
  run_resolution ();
  let finished=observe () in
  check bool "the new child has an actual durable Memory commit observation" true
    (match finished.completion with Resolution_work.Memory_committed result -> result.request_id=descendant_id
     | Not_observed | Completion_unavailable _ -> false);
  check int "only the new original reaches the provider" 1 (F.post_count fixture.server);
  let retained=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
    ~request_id:original.request_id |> owned) in
  check bool "successful continuation preserves the original unknown body and progress" true
    (Option.exists (fun (record:Owner.retained) -> record.request=original.request && record.progress=original.progress) retained);
  let saved ()=io (fun () -> Store.load_history_resolution fixture.store ~scope:original.scope
    ~request_id:original.request_id |> get),progress fixture,io (fun () -> current fixture.keepers_dir) in
  let before=saved () in
  ignore (observe ());
  check bool "GET observation writes neither resolution nor Memory nor read position" true (saved ()=before))
let test_changed_memory_rebases_original_source_without_unknown_retry ?(lose_child_after_dispatch=false) ?(recover_unacked_child=false) ?(interrupt_settle=false) () = with_fixture (fun ~sw fixture ->
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
    let written=io (fun () -> Current.upsert_fact ~pass:Keeper_memory_commit_pass.Keeper_write ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
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
      let preparation=Keeper_librarian_runtime.prepare_durable ~source_lines:[] ~now:(Time_compat.now ()) (Source.input rebased) |> get in
      let owner=Capture.physical_owner original in
      let request_id=minted_a_day_before (Capture.fresh_request_id owner) in
      let child=io (fun () -> Capture.create
        ~predecessor:{request_id=original_record.request_id;request_digest=original_record.request_digest}
        ~request_id ~owner ~destination:(Capture.destination original) ~source:rebased ~preparation ()) |> get in
      let read ~scope ~request_id = Owner.load ~store:fixture.store ~scope ~request_id
        |> Result.map_error Owner.error_to_string in
      let inspect ?(read=read) ~require_confirmed child = io (fun () ->
        Capture.validate_predecessor_payload ~read ~require_confirmed child) in
      check bool "preflight refuses a missing history predecessor" true
        (Result.is_error (inspect ~read:(fun ~scope:_ ~request_id:_ -> Ok None) ~require_confirmed:false child));
      let wrong_digest=io (fun () -> Capture.create
        ~predecessor:{request_id=original_record.request_id;request_digest=String.make 64 '0'}
        ~request_id ~owner ~destination:(Capture.destination original) ~source:rebased ~preparation ()) |> get in
      check bool "preflight refuses a changed history predecessor digest" true
        (Result.is_error (inspect ~require_confirmed:false wrong_digest));
      check bool "preflight requires the parent's full replacement intent" true
        (Result.is_error (inspect ~require_confirmed:false child));
      let intended:Progress.preparation_intent={request_id;request=Capture.to_json child} in
      let parent=io (fun () -> match Owner.advance ~store:fixture.store ~expected:parked
          ~event:(Progress.Replacement_intended intended) with
        | Ok (Owner.Stored record | Already_stored record) -> record
        | Ok (Unconfirmed detail) -> fail detail
        | Error error -> fail (Owner.update_error_to_string error)) in
      check bool "full parent intent exists before any child retention" true
        (Option.is_some (Progress.replacement parent.progress));
      inspect ~require_confirmed:false child |> get;
      check bool "a pending history child cannot claim acknowledged publication" true
        (Result.is_error (inspect ~require_confirmed:true child));
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
      inspect ~require_confirmed:true child |> get;
      (match authorize child with
       | Ok (Some authorization) -> check bool "Off still refuses actual dispatch after local ACK" true
           (guard_waits authorization.before_dispatch)
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
      (* A child of a known-basis lineage is read with its body: the lineage
         check compares that body with its parent's intent. *)
      let child_body=Filename.concat (Store.root fixture.store)
        (Store.tool_request_body_path ~scope:child_record.scope ~request_digest:child_record.request_digest) in
      let child_bytes=read_file child_body in
      io (fun () -> Sys.remove child_body);
      check bool "a waiting child of a known-basis lineage reads its body" true
        (Astring.String.is_infix ~affix:body_missing (refused_pass fixture "a lineage child went on without its body"));
      io (fun () -> write child_body child_bytes);
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
    let root_day=day_of original_record.request_id in
    let gates=gate_records fixture child in
    check (list string) "both executions hold gate records"
      (List.sort String.compare [original_record.request_id;child_record.request_id])
      (List.sort_uniq String.compare (List.map (fun gate -> Gate.parent_execution_id gate |> get) gates));
    if recover_unacked_child then
      check bool "the successor was minted on another day than its root" false
        (String.equal (day_of child_record.request_id) root_day);
    (* The settle moves the successor's history record first. *)
    if interrupt_settle then settle_only fixture ~date:root_day child_record;
    ignore (run_worker fixture);
    check int "later wake settles both originals without a third inference" 2 (F.post_count fixture.server);
    check int "the finished chain leaves the scope" 0 (List.length (observed_originals fixture));
    check bool "the successor settles under its root's day" true (settled_on fixture ~date:root_day child_record);
    check bool "the root settles under its own day" true (settled_on fixture ~date:root_day parent_after);
    if recover_unacked_child then
      check bool "nothing settles under the successor's own day" false
        (settled_on fixture ~date:(day_of child_record.request_id) child_record);
    check bool "both executions' gate records settle under that day" true
      (List.for_all (settled_on fixture ~date:root_day) gates);
    check int "no gate record stays for validation" 0 (List.length (gate_records fixture child)))))

(* The durable message floor's way down: which refused originals descend, and
   what the chain reads from them. *)
module Descent = Keeper_librarian_floor_descent
module Chain = Keeper_librarian_floor_chain
module Cleanup = Keeper_librarian_floor_cleanup
module Step_owner = Keeper_librarian_floor_step_owner
module Program = Keeper_memory_os_program
let contains haystack needle = Astring.String.is_infix ~affix:needle haystack
let reply text = Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text text]
let filler tag bytes = tag ^ " " ^ String.init bytes (fun index -> Char.chr (97 + index mod 26))
let candidate_of fixture =
  let record,request = only_original fixture in
  memory_action fixture (fun () -> Descent.candidate ~store:fixture.store ~record ~request) |> get
(* A read that fails leaves the consumer's mark that narrows its next fresh
   read to one turn. *)
let narrow_next_read fixture =
  match memory_action fixture (fun () ->
    Consumer.consume_one ~config:fixture.config ~keeper_name ~commit:(fun _ -> Consumer.Memory_refused [])) with
  | Ok (Consumer.Memory_not_committed _) -> ()
  | Ok (Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Pending _) ->
    fail "the failed read did not stop at the unread turn"
  | Error error -> fail (Consumer.error_to_string error)
let ended_by_one_refusal = function
  | Ok (Consumer.Memory_not_committed [_]) -> ()
  | Error error -> fail (Consumer.error_to_string error)
  | Ok (Consumer.Memory_not_committed ([] | _::_::_) | Nothing_to_read | Pending _ | Baseline_advanced _
        | Progress_advanced _ | Official_advanced _) -> fail "the pass must end in one refusal report"
(* The provider refuses the one-turn read, and the host keeps the refusal. *)
let provider_refuses_one_turn fixture response =
  fixture.set_response (fun _ -> response);
  narrow_next_read fixture;
  let before= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  await_delivery fixture ~after:before;
  ended_by_one_refusal (run_worker fixture)
(* An admission that arrives after the first read, so the next read of the
   range sees one more than Memory holds. *)
let record_external_admission ?(name="admitted-after-the-first-read") fixture =
  let now=Time_compat.now () in
  let item : Keeper_external_attention.item = {
    event_id=Keeper_external_attention.event_id_of_dedupe_key name;
    dedupe_key=name;keeper_name;
    conversation={conversation_id="agent:" ^ name;surface=Keeper_external_attention.Agent};
    external_message=None;source_label="agent";
    actor={actor_id=Some "original-agent";display_name=Some "Original agent";authority=Keeper_chat_store.External};
    urgency=Keeper_external_attention.Ambient;content_preview="Admitted after the first read";
    content_ref=None;received_at=now;metadata=[]} in
  match Keeper_external_attention.For_testing.record_with_clock ~now:(fun () -> now)
    ~base_path:fixture.config.Workspace.base_path item with
  | `Recorded -> ()
  | `Duplicate _ -> fail "duplicate external fixture"
  | `Error detail -> fail detail
(* Turn 2 is consumed first, so the turn added here is the whole backlog. *)
let add_unread_turn ?(external_admission=false) fixture turn =
  drive_advanced fixture;
  if external_admission then record_external_admission fixture;
  let all=selected_messages @ turn in
  save_checkpoint fixture.config ~trace_id all 3;
  io (fun () -> append_boundary fixture.config ~turn:3 ~time:(Time_compat.now ())
    ~history_at_start:(Boundary.history_at_start_of_messages selected_messages) all)
(* The worker's frame refuses the whole backlog, then the one turn the next
   read narrows to. *)
let frame_refuses_the_turn_twice fixture =
  ended_by_one_refusal (run_worker fixture);
  ended_by_one_refusal (run_worker fixture)
let step_claim n = `Assoc ["claim",`String (Printf.sprintf "claim number %d" n);"category",`String "fact";
  "board_post_id",`Null;"board_comment_id",`Null;"supersedes",`Null;"absorbs",`List []; "evidence", `Assoc ["conversation",`List [];"tools",`List [];"counterpart",`Bool false;"task_contexts",`Bool false]]
let step_answer n = `Assoc ["new_claims",`List [step_claim n];"dropped",`List [];"working_contexts",`List [];
  "working_state",`String (Printf.sprintf "working state %d" n)]
(* The provider numbers its answer by the first of [tags] the request carries.
   No claim or state repeats a tag, so a later request names only its own. *)
let answering_steps tags body =
  match List.find_opt (fun (_,tag) -> contains body tag) (List.mapi (fun index tag -> index+1,tag) tags) with
  | Some (n,_) -> `OK,F.openai_response (step_answer n)
  | None -> fail "a floor step carries none of the messages of the turn"
(* Run the descent as the consumer's wakes do: a chain that waits on a worker
   runs again after the worker's delivery, never earlier. *)
let descend fixture candidate =
  let rec go attempts =
    let before= !(fixture.deliveries) in
    let result=Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
      memory_action fixture (fun () ->
        Descent.descend ~store:fixture.store ~config:fixture.config
          ~reserved:(Keeper_librarian_durable_edge.reserved ()) candidate)) in
    match result with
    | Ok (Chain.Pending _) when attempts>0 -> await_delivery fixture ~after:before;go (attempts-1)
    | result -> result in
  go 12
let finished = function
  | Ok (Chain.Finished finished) -> finished
  | Ok (Chain.Pending pending) ->
    failf "the chain was still pending: %s" (Keeper_librarian_pending.description pending)
  | Ok (Chain.Stopped {position;report}) -> failf "the chain stopped at %d: %s" position report.detail
  | Ok (Chain.Declaration_replaced {position;request_id}) ->
    failf "the declaration of step %d was replaced: %s" position request_id
  | Ok Chain.Superseded -> fail "the chain's initial facts were superseded"
  | Error detail -> failf "the chain refused: %s" detail
let program_claims (program:Program.t) =
  List.concat_map (fun (stage:Program.stage) ->
    List.map (fun (fact:Types.fact) -> fact.claim) stage.decision.new_claims) program.stages
let steps_of fixture request =
  Step_owner.discover ~store:fixture.store ~owner:(Capture.physical_owner request)
  |> Result.map_error Step_owner.error_to_string |> get
  |> List.map (fun listed -> Step_owner.load ~store:fixture.store listed
      |> Result.map_error Step_owner.error_to_string |> get)
(* The chain's first step: its record and the step restored from it. *)
let first_step fixture request =
  match List.find_opt (fun (_,(header:Keeper_librarian_floor_step_request.header)) -> header.position=0)
    (steps_of fixture request) with
  | None -> fail "the chain has no first step"
  | Some (record,_) ->
    record,Keeper_librarian_floor_step_request.restore ~owner:(Capture.physical_owner request) record |> get
(* The claims of the facts the chain's first step was asked from. *)
let first_step_facts fixture request =
  let _,step=first_step fixture request in
  match (Keeper_librarian_floor_step_request.step step).preparation.source_input.current with
  | Some current -> List.sort String.compare (List.map (fun (fact:Types.fact) -> fact.claim) current.facts)
  | None -> []
let test_dispatch_rechecks_owner_without_restoring_the_body () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let original,capture=only_original fixture in
  let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
    |> Result.map_error Lane_addon_manifest.error_to_string |> get in
  let authorization=Server_librarian_addon_validation.authorize ~base_path:fixture.base_path
    ~store:fixture.store ~declaration_id:"librarian" ~package (Capture.request capture |> get)
    |> Result.map_error (function Exact.Unowned {reason} -> reason | Undecided {detail} -> detail)
    |> get |> Option.get in
  authorization.before_dispatch () |> Result.map_error Exact.dispatch_veto_detail |> get;
  let posts=F.post_count fixture.server and positions=progress fixture in
  let body=Filename.concat (Store.root fixture.store)
    (Store.tool_request_body_path ~scope:original.scope ~request_digest:original.request_digest) in
  let held=body ^ ".fixture-held" in
  io (fun () -> Unix.rename body held);
  Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> io (fun () ->
    Unix.rename held body;
    Store.save_tool_request_owner fixture.store ~scope:original.scope ~request_id:original.request_id
      (Owner.to_json original) |> get))) (fun () ->
    (* The authorization already holds this body's verified canonical value.
       The recheck must still read the current owner and its immutable identity. *)
    authorization.before_dispatch () |> Result.map_error Exact.dispatch_veto_detail |> get;
    let changed=match Owner.to_json original with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
          key, if key="summary" then `Null else value) fields)
      | `Null | `Bool _ | `Float _ | `Int _ | `Intlit _ | `String _ | `List _ ->
        fail "the retained owner is not an object" in
    io (fun () -> Store.save_tool_request_owner fixture.store ~scope:original.scope
      ~request_id:original.request_id changed |> get);
    check bool "a changed owner summary refuses the previously validated body" true
      (guard_waits authorization.before_dispatch);
    check int "dispatch authorization calls no model" posts (F.post_count fixture.server);
    check bool "dispatch authorization acknowledges no source position" true (progress fixture=positions)))

let candidate_and_request fixture =
  let _,request=only_original fixture in
  match candidate_of fixture with
  | Some candidate -> candidate,request
  | None -> fail "the refused original must be a floor candidate"
let test_answered_floor_gate_follows_replacement ~foreign_installation () =
  with_fixture (fun ~sw fixture ->
    let module Step=Keeper_librarian_floor_step_request in
    let module Journal=Keeper_librarian_floor_step_gate in
    let module Judgment=Keeper_librarian_floor_step_judgment in
    let module Edge=Keeper_librarian_durable_edge in
    seed_absorb_source fixture;
    provider_refuses_one_turn fixture size_refusal;
    let candidate,request=candidate_and_request fixture in
    fixture.set_step_response (fun _ -> `OK,F.openai_response (add_absorption (step_answer 1)));
    with_enabled_absorb_gate fixture (fun () -> with_absorb_guidance_gap ~empty:true (fun () ->
      check bool "an actual answered step remains before its first Gate" true
        (Result.is_error (descend fixture candidate))));
    let parent,step=first_step fixture request in
    check bool "the answered step has no Gate preparation" true (Progress.preparation parent.progress=None);
    let captured=Step.to_json step and posts=F.post_count fixture.server and positions=progress fixture in
    let replacement=fixture.declaration true |> String.split_on_char '\n'
      |> List.map (function
        | "run_id=\"librarian-original-owner\"" -> "run_id=\"answered-floor-gate\""
        | "id=\"librarian\"" when foreign_installation -> "id=\"different-librarian\""
        | line -> line) |> String.concat "\n" in
    replace_actual_worker_configuration fixture ~sw replacement;
    let owner=Capture.physical_owner request in
    let answer,current=memory_action fixture (fun () ->
      match Step_owner.resume ~store:fixture.store ~config:fixture.config ~reserved:[] ~original:parent ~step
        ~call:(fun ~expected:_ ~original:_ ~arguments:_ -> fail "an answered floor step was resubmitted")
        |> Result.map_error Step_owner.error_to_string |> get with
      | Step_owner.Answered (answer,current) -> answer,current
      | Pending _ | Refused _ | Before_dispatch_replaced _ -> fail "the original step lost its host answer") in
    let inventory=io (fun () -> Journal.Inventory.read ~store:fixture.store ~owner) |> get in
    let result=memory_action fixture (fun () -> Judgment.judge ~store:fixture.store ~step ~record:current ~answer
      ~fresh_authority:(Edge.fresh_gate_authority ~config:fixture.config ~reserved:[] ~owner
        ~expected:(Step.destination step)) ~inventory |> get) in
    (match result with
     | Judgment.Pending _ -> check bool "only a foreign installation keeps the Gate waiting" true foreign_installation
     | Decided decision ->
       check bool "the same owner can finish the original Gate" false foreign_installation;
       check (list string) "the original step's claim survives declaration replacement" ["claim number 1"]
         (List.map (fun (fact:Types.fact) -> fact.claim) decision.new_claims));
    let gate=io (fun () -> Journal.root ~store:fixture.store ~owner ~capture:step) |> get in
    check int "only the same installation may prepare the first floor Gate" (if foreign_installation then 0 else 1)
      (Option.fold ~none:0 ~some:(fun _ -> 1) gate);
    check json "the full answered floor input stays unchanged" captured (Step.to_json step);
    check bool "a floor judgment alone never settles history progress" true (progress fixture=positions);
    check int "the floor answer is never requested again" posts (F.post_count fixture.server))

let test_floor_guidance_is_required_only_for_actual_absorptions () =
  let module Journal = Keeper_librarian_floor_step_gate in
  let module Step = Keeper_librarian_floor_step_request in
  List.iter (fun (empty,absorbing) -> with_fixture (fun ~sw:_ fixture ->
    seed_absorb_source fixture;
    provider_refuses_one_turn fixture size_refusal;
    let candidate,request=candidate_and_request fixture in
    let posts=F.post_count fixture.server in
    let answers=ref 0 in
    fixture.set_step_response (fun _ ->
      incr answers;
      let proposal=step_answer !answers in `OK,F.openai_response (if absorbing then add_absorption proposal else proposal));
    with_enabled_absorb_gate fixture (fun () -> with_absorb_guidance_gap ~empty (fun () ->
      let outcome=descend fixture candidate in
      if absorbing then check bool "nonempty floor cannot prepare without guidance" true (Result.is_error outcome)
      else ignore (finished outcome);
      let owner=Capture.physical_owner request in
      let steps=steps_of fixture request in
      check int "each source message has exactly its original provider answer" (if absorbing then 1 else 2)
        (F.post_count fixture.server-posts);
      let authority=Keeper_librarian_absorb_gate.resolve ~keeper_id:keeper_name in
      let missing_policy=match Keeper_librarian_absorb_gate.guidance_of_authority authority with
        | Error detail -> detail | Ok _ -> fail "enabled floor guidance must remain explicitly unavailable" in
      List.iter (fun ((parent:Owner.retained),_) ->
        let step=io (fun () -> Step.restore ~owner parent) |> get in
        let proposal=answered_proposal parent (Step.request step |> get) in
        let validated:Keeper_librarian_runtime.durable_step_proposal=Step.validate_proposal step proposal |> get in
        check bool "the original step retains its actual absorption shape" absorbing
          (validated.proposal.absorption.absorbed<>[]);
        if absorbing then (
          let request_id=Random_id.uuid_v7 () in
          check (result unit string) "nonempty floor root requires guidance" (Error missing_policy)
            (io (fun () -> Journal.prepare_root ~store:fixture.store ~owner ~capture:step ~parent ~proposal ~request_id ~authority) |> Result.map (fun _ -> ()));
          check (result unit string) "nonempty floor retention requires guidance" (Error missing_policy)
            (io (fun () -> Journal.retain ~store:fixture.store ~owner ~capture:step ~parent ~proposal ~request_id ~authority ~predecessor:None) |> Result.map (fun _ -> ()));
          check bool "no invalid floor gate was prepared" true (Progress.preparation parent.progress=None))
        else (
          let parent=memory_action fixture (fun () -> io (fun () -> Journal.recover_root ~store:fixture.store ~owner ~capture:step) |> get) in
          let gate=io (fun () -> Journal.root ~store:fixture.store ~owner ~capture:step) |> get |> Option.get in
          check json "empty floor captures explicit guidance absence" `Null (member "guidance" gate.request);
          let gate=memory_action fixture (fun () -> io (fun () -> Journal.retain ~store:fixture.store ~owner ~capture:step ~parent
            ~proposal ~request_id:gate.request_id ~authority ~predecessor:None) |> get) in
          let result=memory_action fixture (fun () -> Journal.resume ~store:fixture.store ~owner ~capture:step ~record:gate
            ~live_authority:None ~request_clock:(fun () -> fail "empty floor acquired a gate clock")
            ~before_dispatch:(fun () -> fail "empty floor dispatched a gate request") |> get) in
          let result=match result with Journal.Complete (result,_) -> result | Pending _ -> fail "empty floor must complete locally" in
          check bool "empty floor replays as No_absorptions" true
            (match result with Keeper_librarian_absorb_gate.Skipped {reason=No_absorptions;absorbed=[]} -> true | _ -> false);
          let replayed=io (fun () -> Journal.restore_latest_result ~store:fixture.store ~owner ~parent_execution:step
            ~gate_request_id:gate.request_id) |> get in
          check json "empty floor survives strict replay" (Keeper_librarian_absorb_gate.run_result_to_yojson result)
            (Keeper_librarian_absorb_gate.run_result_to_yojson replayed))) steps;
      check int "gate recovery and replay add no provider call" (if absorbing then 1 else 2)
        (F.post_count fixture.server-posts))))) [false,false;true,false;false,true;true,true]
let test_a_kept_size_refusal_of_one_turn_is_a_candidate () = with_fixture (fun ~sw:_ fixture ->
  fixture.set_response (fun _ -> size_refusal);
  narrow_next_read fixture;
  let before= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  check bool "an original the host has not refused is no candidate" true (Option.is_none (candidate_of fixture));
  await_delivery fixture ~after:before;
  ended_by_one_refusal (run_worker fixture);
  let record,_=only_original fixture in
  match candidate_of fixture with
  | Some candidate ->
    check string "the candidate is the refused original" record.Owner.request_id (Descent.record candidate).Owner.request_id;
    check string "and the range its steps name" record.request_id
      (Descent.range candidate).Keeper_librarian_floor_step_request.request_id;
    check string "by the digest of its request" record.request_digest
      (Descent.range candidate).Keeper_librarian_floor_step_request.request_digest
  | None -> fail "a size refusal the host kept for one turn must be a candidate")
(* A record that is not the request's own is an error, never a dropped candidate. *)
let test_a_record_that_is_not_the_requests_own_is_an_error () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture (`Bad_request,{|{"error":{"message":"fixture refusal","type":"invalid_request_error"}}|});
  let refused,_=only_original fixture in
  (* Nothing in this refusal shows that reading less may help, so the next pass
     settles the refused original and reads the turn again as an original. *)
  assert_pending (run_worker fixture);
  let _,request=only_original fixture in
  check bool "the pass read the turn again as an original of its own" true
    (refused.Owner.request_id<>Capture.request_id request);
  match memory_action fixture (fun () -> Descent.candidate ~store:fixture.store ~record:refused ~request) with
  | Error _ -> ()
  | Ok _ -> fail "a record that is not the request's own was taken for it")
let test_a_refusal_that_shows_nothing_about_reading_less_is_no_candidate () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture (`Bad_request,{|{"error":{"message":"fixture refusal","type":"invalid_request_error"}}|});
  let record,_=only_original fixture in
  check bool "the original is refused" true
    (match Progress.phase record.Owner.progress with Rejected _ -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> false);
  check bool "but nothing in it shows that reading less may help" true (Option.is_none (candidate_of fixture)))
(* The first read takes everything unread. Whatever it holds, it is not the
   narrowed read of one turn, so a refusal of it does not descend. *)
let a_refused_first_read ?(second_turn=false) () = with_fixture (fun ~sw:_ fixture ->
  if second_turn then (
    let both=selected_messages @ [message "A second unread turn";reply "Its answer"] in
    save_checkpoint fixture.config ~trace_id both 3;
    io (fun () -> append_boundary fixture.config ~turn:3 ~time:(Time_compat.now ())
      ~history_at_start:(Boundary.history_at_start_of_messages selected_messages) both));
  fixture.set_response (fun _ -> size_refusal);
  let before= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  await_delivery fixture ~after:before;
  ended_by_one_refusal (run_worker fixture);
  let _,request=only_original fixture in
  check bool "the first read takes everything unread" true
    (Source.extent (Capture.source request)=Keeper_librarian_range.All_unread);
  check bool "of one turn or of two" second_turn
    (List.length (Source.input (Capture.source request)).Keeper_librarian.messages>2);
  check bool "a size refusal of that read does not descend" true (Option.is_none (candidate_of fixture)))
let test_a_read_the_consumer_did_not_narrow_is_no_candidate () = a_refused_first_read ()
let test_a_read_of_two_turns_is_no_candidate () = a_refused_first_read ~second_turn:true ()
let test_the_floor_reads_a_turn_the_provider_refuses_one_message_at_a_time () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  let memory_before=io (fun () -> claims fixture.keepers_dir) and position=progress fixture in
  let posts=F.post_count fixture.server in
  fixture.set_step_response (answering_steps ["Original question to retain";"Original completed answer"]);
  let first=finished (descend fixture candidate) in
  check (list string) "every message has a decision, in order"
    ["claim number 1";"claim number 2"] (program_claims first.program);
  check int "no message is unread" 0 (List.length first.program.unread);
  check int "each message asked the provider once" 2 (F.post_count fixture.server-posts);
  check int "and retained one step" 2 (List.length (steps_of fixture request));
  check (list string) "nothing reached Memory" memory_before (io (fun () -> claims fixture.keepers_dir));
  check bool "and the position did not move" true (progress fixture=position);
  let again=finished (descend fixture candidate) in
  check json "a restart makes the same program" (Program.to_json first.program) (Program.to_json again.program);
  check int "and asks the provider nothing" 2 (F.post_count fixture.server-posts);
  check int "and retains no more steps" 2 (List.length (steps_of fixture request)))
let test_a_message_the_frame_refuses_alone_stays_unread () = with_fixture (fun ~sw:_ fixture ->
  let huge=message (filler "huge-message" oversized_turn_bytes) in
  add_unread_turn fixture [huge;reply "Oversized answer"];
  frame_refuses_the_turn_twice fixture;
  let candidate,request=candidate_and_request fixture in
  let posts=F.post_count fixture.server in
  fixture.set_step_response (answering_steps ["huge-message";"Oversized answer"]);
  let first=finished (descend fixture candidate) in
  check (list string) "only the readable message has a decision" ["claim number 2"] (program_claims first.program);
  (match first.program.unread with
   | [hole] ->
     let digest=match hole.source with
       | Keeper_librarian_unread.Atom {message_sha256;_} | Official_turn {message_sha256;_} -> message_sha256 in
     check string "the hole is the message the frame refused" (Keeper_librarian_unread.message_digest huge) digest;
     check bool "with the cause the host named" true
       (hole.reasons=[Keeper_librarian_input_refusal.Request_body_refused])
   | [] | _::_::_ -> fail "the refused message is the one unread hole");
  check int "the refused message never reached the provider" 1 (F.post_count fixture.server-posts);
  check int "both messages have a step" 2 (List.length (steps_of fixture request));
  check (list string) "the chain starts from the Memory of the moment" ["Knowledge from original completed history"]
    (first_step_facts fixture request);
  let again=finished (descend fixture candidate) in
  check json "a restart keeps the hole and the decision" (Program.to_json first.program) (Program.to_json again.program);
  check int "and asks the provider nothing" 1 (F.post_count fixture.server-posts))
let first_step_request fixture request=
  let record,step=first_step fixture request in
  record,Keeper_librarian_floor_step_request.request step |> get
let floor_scopes request=let owner=Capture.physical_owner request in
  Keeper_librarian_floor_step_request.scope owner,Keeper_librarian_floor_step_gate.scope owner
(* An answered step holds the judgment of its answer (Judged), which resume
   confirms through the step's Exact record. Once the Exact check deletes that
   record, no record confirms the answer, so the deploy check refuses the
   floor owner. *)
let test_preflight_refuses_a_floor_step_whose_proof_is_version_1 () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  fixture.set_step_response (answering_steps ["Original question to retain";"Original completed answer"]);
  ignore (finished (descend fixture candidate));
  let original,step=first_step_request fixture request in
  check bool "the first step holds the judgment of its answer" true
    (match Progress.phase original.progress with
     | Progress.Judged _ -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _ | Finished _
     | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
  check int "with version 2 proofs the deploy check passes the floor" 0
    (List.length (librarian_refusals fixture));
  version_1_proof fixture step;
  check bool "the Exact check deletes the step's record with its version 1 proof" true
    (List.mem (proof_path fixture step) (exact_deletes fixture));
  let refusals=librarian_refusals fixture in
  check bool "the deploy check refuses the first step on its Exact files" true
    (refuses_original fixture ~original (floor_scopes request) refusals);
  check bool "and the gate the step's answer was judged by" true
    (refused_in fixture (snd (floor_scopes request)) refusals))
(* The host ends a step with its only slot's body refusal, and the floor
   leaves that message unread. The floor builds the refusal's evidence from
   the final alone, as history does, so the deploy check passes the step once
   the Exact check deletes its record. *)
let test_preflight_passes_a_floor_body_refusal_whose_record_goes () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  fixture.set_step_response (fun body ->
    if contains body "Original question to retain" then size_refusal
    else answering_steps ["Original question to retain";"Original completed answer"] body);
  let fin=finished (descend fixture candidate) in
  check int "the refused message is the program's one hole" 1 (List.length fin.program.unread);
  let record,step=first_step_request fixture request in
  check bool "the host's body refusal ends the step at execution" true
    (match Progress.phase record.progress with
     | Progress.Rejected {stage=Progress.Execution;_} -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Rejected {stage=Progress.Before_dispatch;_} | Subdividing _ | Subdivided _ ->
       false);
  check int "with its version 2 proof the deploy check passes the floor" 0
    (List.length (librarian_refusals fixture));
  version_1_proof fixture step;
  check bool "the Exact check deletes the step's record with its version 1 proof" true
    (List.mem (proof_path fixture step) (exact_deletes fixture));
  check int "the final alone gives the floor its evidence, so the step passes" 0
    (List.length (librarian_refusals fixture)))
let test_the_floor_reads_an_official_turn_from_its_retained_messages () = with_fixture ~history_kind:Official (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  let posts=F.post_count fixture.server in
  fixture.set_step_response (answering_steps ["Original official-client question";"Original official-client answer"]);
  let first=finished (descend fixture candidate) in
  check (list string) "both messages of the turn have a decision, in order"
    ["claim number 1";"claim number 2"] (program_claims first.program);
  check int "each asked the provider once" 2 (F.post_count fixture.server-posts);
  check int "and retained one step" 2 (List.length (steps_of fixture request));
  no_memory fixture)
(* The turn's own messages are the same, so only the source lock can tell that
   the checkpoint is no longer the one the original read. *)
let test_a_checkpoint_whose_read_prefix_changed_stops_the_descent_before_any_step () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  let posts=F.post_count fixture.server in
  save_checkpoint fixture.config ~trace_id (message "The already-read first turn, rewritten"
    :: List.drop (List.length first_messages) selected_messages) 3;
  fixture.set_step_response (fun _ -> fail "a changed source reached the provider");
  (match descend fixture candidate with
   | Error _ -> ()
   | Ok (Chain.Finished _ | Chain.Pending _ | Chain.Stopped _ | Chain.Declaration_replaced _ | Chain.Superseded) ->
     fail "the floor read a checkpoint the original did not read");
  check int "no step was retained" 0 (List.length (steps_of fixture request));
  check int "and the provider was not asked" 0 (F.post_count fixture.server-posts))
(* The source lock allows history appended after the original, which is why
   the chain numbers the original's messages against the checkpoint as it is
   now. The appended turn is not asked about. *)
let test_history_appended_after_the_original_does_not_stop_the_descent () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  let later=selected_messages @ [message "A turn after the refused one";reply "Its answer"] in
  save_checkpoint fixture.config ~trace_id later 3;
  io (fun () -> append_boundary fixture.config ~turn:3 ~time:(Time_compat.now ())
    ~history_at_start:(Boundary.history_at_start_of_messages selected_messages) later);
  fixture.set_step_response (answering_steps ["Original question to retain";"Original completed answer"]);
  check (list string) "the chain reads the turn the original read" ["claim number 1";"claim number 2"]
    (program_claims (finished (descend fixture candidate)).program);
  check int "and no step asks about the appended turn" 2 (List.length (steps_of fixture request)))
let test_a_refused_original_whose_read_position_moved_is_no_longer_a_candidate () =
  with_fixture ~history_kind:Official (fun ~sw:_ fixture ->
    provider_refuses_one_turn fixture size_refusal;
    check bool "the refused original is a candidate" true (Option.is_some (candidate_of fixture));
    (* A publication elsewhere moved the official position past the turn. *)
    io (fun () -> Keeper_librarian_official_progress.write ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config)
      ~keeper_id:keeper_name {Keeper_librarian_official_progress.boundary_line=2}
      |> Result.map_error Keeper_librarian_official_progress.write_error_to_string |> get);
    check bool "the range the next pass selects is not the original's, so it is no candidate" true
      (Option.is_none (candidate_of fixture)))
(* Every pass that selects the range prepares the external cursor again, so by
   the time a chain finishes it is not as the original captured it. *)
let test_the_descent_reads_on_while_the_external_cursor_moves () = with_fixture ~history_kind:Official (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  let runtime_keepers_dir=Workspace.keepers_runtime_dir fixture.config in
  let cursor_json () =
    io (fun () -> Keeper_external_read_cursor.observe ~runtime_keepers_dir ~keeper_name |> get)
    |> Keeper_external_read_cursor.observation_to_json in
  let captured=cursor_json () in
  io (fun () ->
    let token=Keeper_external_read_cursor.read ~memory_keepers_dir:fixture.keepers_dir ~runtime_keepers_dir
      ~keeper_name |> get in
    Keeper_external_read_cursor.prepare ~memory_keepers_dir:fixture.keepers_dir ~runtime_keepers_dir ~keeper_name token
      ~through:(Keeper_external_read_cursor.offset token+5) ~atom:None
      ~official:(Source.official_range_id (Capture.source request)) |> get);
  check bool "the cursor is no longer as it was" false (Yojson.Safe.equal captured (cursor_json ()));
  fixture.set_step_response (answering_steps ["Original official-client question";"Original official-client answer"]);
  check (list string) "the chain still reads the turn" ["claim number 1";"claim number 2"]
    (program_claims (finished (descend fixture candidate)).program))

(* Publication of a finished chain. The commit is the whole of it: the receipt
   check, the cursor's acknowledgement and the move of the position are the
   consumer's own tail, which these tests run through the consumer. *)
module Publish = Keeper_librarian_floor_publish
let publish fixture candidate finished =
  Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
    memory_action fixture (fun () -> Publish.publish ~candidate ~finished))
let published = function
  | Ok Publish.Published -> ()
  | Ok Publish.Superseded -> fail "the Memory was still the one the program judged"
  | Error detail -> failf "the publication refused: %s" detail
(* The consumer finds the range committed and moves its position without
   asking a model. *)
let consumer_tail fixture =
  match memory_action fixture (fun () ->
    Consumer.consume_one ~config:fixture.config ~keeper_name
      ~commit:(fun _ -> fail "a range Memory already holds must not be read again")) with
  | Ok (Consumer.Progress_advanced _ | Official_advanced _) -> ()
  | Ok (Nothing_to_read | Baseline_advanced _ | Memory_not_committed _ | Pending _) ->
    fail "the consumer did not move the position of a committed range"
  | Error error -> fail (Consumer.error_to_string error)
let test_a_finished_chain_commits_its_program_and_the_consumer_moves_the_position () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  fixture.set_step_response (answering_steps ["Original question to retain";"Original completed answer"]);
  let fin=finished (descend fixture candidate) in
  let position=progress fixture in
  published (publish fixture candidate fin);
  check (list string) "Memory holds the claims of both messages" ["claim number 1";"claim number 2"]
    (io (fun () -> claims fixture.keepers_dir));
  check bool "the position has not moved: that is the consumer's tail" true (progress fixture=position);
  check bool "the range reads as published" true (io (fun () -> Commit.receipt_state request) |> get);
  let revision () = io (fun () ->
    Option.map (fun (snapshot : Current.t) -> snapshot.revision) (current fixture.keepers_dir)) in
  let written=revision () in
  published (publish fixture candidate fin);
  check bool "a second call writes no new revision, whatever the facts" true (revision ()=written);
  check (list string) "and no more claims" ["claim number 1";"claim number 2"]
    (io (fun () -> claims fixture.keepers_dir));
  consumer_tail fixture;
  check bool "the consumer moved the position" true (progress fixture<>position);
  check bool "and the published range is no candidate" true (Option.is_none (candidate_of fixture)))

let test_published_floor_with_valid_prompts_recovers_its_pending_ack () =
  with_fixture (fun ~sw:_ fixture ->
    provider_refuses_one_turn fixture size_refusal;
    let candidate, request = candidate_and_request fixture in
    fixture.set_step_response (answering_steps ["Original question to retain"; "Original completed answer"]);
    let fin = finished (descend fixture candidate) in
    published (publish fixture candidate fin);
    let source = Capture.source request in
    let runtime_keepers_dir = Workspace.keepers_runtime_dir fixture.config in
    let cursor () = io (fun () -> Keeper_external_read_cursor.observe
      ~runtime_keepers_dir ~keeper_name |> get) in
    let after = Keeper_external_read_cursor.observation_offset (Source.external_before source) in
    let through = Keeper_librarian_input_sources.external_through (Source.counterparts source) in
    check bool "the published floor has a pending external acknowledgement" true
      (Keeper_external_read_cursor.observation_matches_floor_preparation (cursor ()) ~after ~through
         ~atom:(Source.range_id source) ~official:(Source.official_range_id source));
    let posts = F.post_count fixture.server in
    check bool "a valid committed floor recovers the source position" true (advanced (run_worker fixture));
    check int "recovery does not ask the model again" posts (F.post_count fixture.server);
    check int "the external acknowledgement advances after recovery" through
      (Keeper_external_read_cursor.observation_offset (cursor ())))

let test_published_floor_with_omitted_observations_keeps_pending_ack () =
  with_fixture (fun ~sw:_ fixture ->
    provider_refuses_one_turn fixture size_refusal;
    let candidate, request = candidate_and_request fixture in
    fixture.set_step_response (answering_steps ["Original question to retain"; "Original completed answer"]);
    let fin = finished (descend fixture candidate) in
    published (publish fixture candidate fin);
    let module Step = Keeper_librarian_floor_step_request in
    let module R = Keeper_librarian_runtime in
    let owner = Capture.physical_owner request in
    let record, _ = List.find (fun (_, (header : Step.header)) -> header.position = 0)
      (steps_of fixture request) in
    let step = io (fun () -> Step.restore ~owner record |> get) in
    let valid = Step.step step in
    let input = valid.preparation.source_input in
    check bool "the original step carried external observations" true (input.counterpart_observations <> []);
    let previous = (Prompt_registry.resolve_prompt Prompt_names.librarian).override_value in
    Fun.protect ~finally:(fun () -> match previous with
      | None -> Prompt_registry.clear_prompt_override Prompt_names.librarian
      | Some value -> Prompt_registry.set_override Prompt_names.librarian value |> get) (fun () ->
      Prompt_registry.set_override Prompt_names.librarian "Old floor question without counterpart substitution" |> get;
      let seed = R.prepare_durable_step ~source_lines:[] ~now:(Time_compat.now ()) ~context:valid.context
        {input with counterpart_observations=[]} |> get in
      let preparation = seed.preparation in
      let omitted = R.restore_durable_step_preparation ~context:valid.context ~source_input:input
        ~parsing_now:preparation.parsing_now ~policy:preparation.policy
        ~rule_prompt:preparation.rule_prompt ~turn_prompts:preparation.turn_prompts ~prompt:preparation.prompt
        ~output_schema:preparation.output_schema |> get in
      let request_id = Step.fresh_request_id owner in
      let payload = match Step.to_json step with
        | `Assoc fields -> `Assoc (List.map (function
            | "request_id", _ -> "request_id", `String request_id
            | "preparation", _ -> "preparation", Keeper_librarian_durable_question.to_json omitted.preparation
            | field -> field) fields)
        | _ -> fail "floor step must encode as an object" in
      let destination = Step.destination step in
      let captured = Step.of_json ~owner payload |> get in
      let summary = Step.index captured |> get |> Step.index_to_json in
      io (fun () -> Owner.retain ~store:fixture.store ~scope:(Step.scope owner) ~request_id
        ~installation_id:destination.installation_id ~package_id:destination.package_id
        ~tool:destination.tool ~summary ~request:payload) |> owned;
      let legacy = io (fun () -> Owner.load ~store:fixture.store ~scope:(Step.scope owner) ~request_id)
        |> owned |> Option.get in
      ignore (io (fun () -> Step.restore ~owner legacy |> get));
      let runtime_keepers_dir = Workspace.keepers_runtime_dir fixture.config in
      let cursor () = io (fun () -> Keeper_external_read_cursor.observe
        ~runtime_keepers_dir ~keeper_name |> get) |> Keeper_external_read_cursor.observation_to_json in
      let before = cursor () and posts = F.post_count fixture.server in
      (match run_worker fixture with
       | Error error -> check bool "the omitted input is visible in the refusal" true
           (contains (Consumer.error_to_string error) "counterpart_observations")
       | Ok _ -> fail "an omitted floor question must not authorize an ACK");
      check json "the pending external cursor is unchanged" before (cursor ());
      check int "recovery does not repeat the model request" posts (F.post_count fixture.server);
      check bool "the omitted step remains retained" true
        (List.exists (fun ((held : Owner.retained), _) -> held.request_id=request_id) (steps_of fixture request))))
let test_a_hole_travels_in_the_receipt_and_in_the_external_cursor () = with_fixture (fun ~sw:_ fixture ->
  let huge=message (filler "huge-message" oversized_turn_bytes) in
  add_unread_turn ~external_admission:true fixture [huge;reply "Oversized answer"];
  frame_refuses_the_turn_twice fixture;
  let candidate,request=candidate_and_request fixture in
  let through=Keeper_librarian_input_sources.external_through (Source.counterparts (Capture.source request)) in
  check int "the original saw the admission that came after the first read" 2 through;
  fixture.set_step_response (answering_steps ["huge-message";"Oversized answer"]);
  let fin=finished (descend fixture candidate) in
  check int "the program has its hole" 1 (List.length fin.program.unread);
  published (publish fixture candidate fin);
  let runtime_keepers_dir=Workspace.keepers_runtime_dir fixture.config in
  (match io (fun () -> Current.committed_durable_coverage ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
           ~receipt_scope:runtime_keepers_dir |> get) with
   | Some range -> check bool "the receipt carries the hole" true (range.unread_messages=fin.program.unread)
   | None -> fail "the range has no receipt");
  check bool "and still reads as the original's range" true (io (fun () -> Commit.receipt_state request) |> get);
  check bool "so it is no candidate before the consumer has moved the position" true
    (Option.is_none (candidate_of fixture));
  check int "the cursor was prepared with that receipt, so reading it acknowledges the admissions" through
    (io (fun () -> Keeper_external_read_cursor.read ~memory_keepers_dir:fixture.keepers_dir ~runtime_keepers_dir
       ~keeper_name |> get |> Keeper_external_read_cursor.offset));
  consumer_tail fixture;
  check bool "reading the committed ledger archives the hole of the receipt" true
    (io (fun () -> Current.committed_unread_messages ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get)
     =fin.program.unread))
(* The turn has a hole and an admission after the first read, so the cursor the
   publication would prepare differs from the one the consumer prepared. *)
let test_a_memory_that_changed_since_the_chain_began_supersedes_the_program () = with_fixture (fun ~sw:_ fixture ->
  let huge=message (filler "huge-message" oversized_turn_bytes) in
  add_unread_turn ~external_admission:true fixture [huge;reply "Oversized answer"];
  frame_refuses_the_turn_twice fixture;
  let candidate,_=candidate_and_request fixture in
  fixture.set_step_response (answering_steps ["huge-message";"Oversized answer"]);
  let fin=finished (descend fixture candidate) in
  let independent=Types.observed ~claim:"Independent explicit write" ~category:Types.Fact
    ~now:(Time_compat.now ()) ~origin:{kind=Types.Authored;trace_id="concurrent-floor-writer"} in
  io (fun () -> Current.upsert_fact ~pass:Keeper_memory_commit_pass.Keeper_write ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
    ~now:(Time_compat.now ()) ~source:{kind=Current.Explicit_write;trace_id="concurrent-floor-writer"}
    independent |> Result.map_error Current.upsert_error_to_string |> get |> ignore);
  let position=progress fixture in
  let cursor () = io (fun () -> Keeper_external_read_cursor.observe
    ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
  let cursor_before=cursor () in
  (match publish fixture candidate fin with
   | Ok Publish.Superseded -> ()
   | Ok Publish.Published -> fail "a program that judged another Memory was committed"
   | Error detail -> failf "the publication refused: %s" detail);
  check (list string) "only the independent write joined the earlier turn's claim in Memory"
    ["Independent explicit write";"Knowledge from original completed history"]
    (io (fun () -> claims fixture.keepers_dir));
  check bool "and the position did not move" true (progress fixture=position);
  check bool "and the external cursor was not prepared" true (cursor ()=cursor_before))
(* A program that changes no fact still writes a receipt and a revision, so a
   second call that did not see the first would write them again. *)
let test_a_second_publication_of_a_program_that_changes_no_fact_writes_nothing () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  fixture.set_step_response (fun body ->
    if contains body "Original question to retain" || contains body "Original completed answer"
    then `OK,F.openai_response (`Assoc ["new_claims",`List [];"dropped",`List [];"working_contexts",`List [];
      "working_state",`String "nothing to keep"])
    else fail "a floor step carries none of the messages of the turn");
  let fin=finished (descend fixture candidate) in
  published (publish fixture candidate fin);
  check bool "the range reads as published" true (io (fun () -> Commit.receipt_state request) |> get);
  let revision () = io (fun () ->
    Option.map (fun (snapshot : Current.t) -> snapshot.revision) (current fixture.keepers_dir)) in
  let receipts () = io (fun () -> Fs_compat.load_file_opt
    (Current.durable_range_receipt_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name)) in
  let written=revision () and sidecar=receipts () in
  published (publish fixture candidate fin);
  check bool "a second call writes no new revision" true (revision ()=written);
  check bool "and no new receipt" true (receipts ()=sidecar))
(* The persistence of the snapshot fails after the rename: the commit says it
   could not confirm durability, and the range is in Memory all the same. *)
let test_a_commit_error_after_the_snapshot_was_renamed_does_not_hide_the_receipt () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  fixture.set_step_response (answering_steps ["Original question to retain";"Original completed answer"]);
  let fin=finished (descend fixture candidate) in
  let apply ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program =
    Current.For_testing.apply_program_with_publication_io ~pass:Keeper_memory_commit_pass.Durable
      ~write_snapshot:(Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
        ~sync_file:(fun _ -> ()) ~sync_parent:(fun _ -> failwith "after the snapshot rename"))
      ~sync_snapshot:(fun _ -> Error "snapshot durability deliberately unconfirmed")
      ~before_journal:(fun () -> ()) ~on_committed:(fun _ -> ())
      ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program in
  (match Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
     memory_action fixture (fun () -> Publish.For_testing.publish_with ~apply ~candidate ~finished:fin)) with
   | Ok Publish.Published -> ()
   | Ok Publish.Superseded -> fail "the Memory was still the one the program judged"
   | Error detail -> failf "the range was in Memory, but the publication said: %s" detail);
  check bool "the range reads as published" true (io (fun () -> Commit.receipt_state request) |> get);
  check (list string) "and Memory holds the claims of both messages" ["claim number 1";"claim number 2"]
    (io (fun () -> claims fixture.keepers_dir));
  consumer_tail fixture)
(* The consumer prepares the cursor for the admissions it sees now. The commit
   callback publishes the chain that read the admissions of its original and
   returns, and the consumer's tail runs in the same pass: it acknowledges what
   the chain read, never an admission that came after the original. *)
let test_the_consumers_tail_runs_in_the_pass_that_published () = with_fixture (fun ~sw:_ fixture ->
  let huge=message (filler "huge-message" oversized_turn_bytes) in
  add_unread_turn ~external_admission:true fixture [huge;reply "Oversized answer"];
  frame_refuses_the_turn_twice fixture;
  let candidate,request=candidate_and_request fixture in
  let through=Keeper_librarian_input_sources.external_through (Source.counterparts (Capture.source request)) in
  check int "the original saw the admission that came after the first read" 2 through;
  fixture.set_step_response (answering_steps ["huge-message";"Oversized answer"]);
  let fin=finished (descend fixture candidate) in
  check int "the program has its hole" 1 (List.length fin.program.unread);
  record_external_admission ~name:"admitted-after-the-candidate" fixture;
  let position=progress fixture in
  (match memory_action fixture (fun () ->
     Consumer.consume_one ~config:fixture.config ~keeper_name ~commit:(fun _ ->
       match Publish.publish ~candidate ~finished:fin with
       | Ok Publish.Published -> Consumer.Memory_committed
       | Ok Publish.Superseded -> fail "the Memory was still the one the program judged"
       | Error detail -> failf "the publication refused: %s" detail)) with
   | Ok (Consumer.Progress_advanced _) -> ()
   | Ok (Nothing_to_read | Baseline_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending _) ->
     fail "the pass that published must move the position"
   | Error error -> fail (Consumer.error_to_string error));
  check bool "the position moved" true (progress fixture<>position);
  check int "the tail acknowledged the admissions the chain read, not the later one" through
    (io (fun () -> Keeper_external_read_cursor.read ~memory_keepers_dir:fixture.keepers_dir
       ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get
       |> Keeper_external_read_cursor.offset)))
let test_an_official_turn_is_published_with_its_own_receipt () = with_fixture ~history_kind:Official (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  fixture.set_step_response (answering_steps ["Original official-client question";"Original official-client answer"]);
  let fin=finished (descend fixture candidate) in
  published (publish fixture candidate fin);
  check (list string) "Memory holds the claims of both messages" ["claim number 1";"claim number 2"]
    (io (fun () -> claims fixture.keepers_dir));
  check bool "the official range reads as published" true (io (fun () -> Commit.receipt_state request) |> get);
  consumer_tail fixture;
  check bool "and is no candidate" true (Option.is_none (candidate_of fixture)))

(* The production pass descends: the pass that selects the range of a refused
   one-turn original reads it message by message under that original, and what
   the floor retained is settled with the finished history. *)
let plain_refusal = `Bad_request,{|{"error":{"message":"fixture refusal","type":"invalid_request_error"}}|}
let run_worker_waking fixture wakes =
  Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
    memory_action fixture (fun () ->
      Execution.consume_one ~config:fixture.config ~keeper_name ~wake:(fun () -> incr wakes)))
(* Passes as the Memory lane's wakes run them, until one is not Pending. A pass
   that waits on a worker runs again after the worker's delivery, never
   earlier; a pass that asked for a wake runs again at once. *)
let run_until_done ?(wakes=ref 0) fixture =
  let rec go attempts =
    let before= !(fixture.deliveries) and woken= !wakes in
    match run_worker_waking fixture wakes with
    | Ok (Consumer.Pending _) when attempts>0 ->
      if !wakes=woken then await_delivery fixture ~after:before;
      go (attempts-1)
    | result -> result in
  go 16
(* The attempt a stopped server leaves: started by another
   incarnation, with no outcome and no proof. *)
let test_interrupted_original_settles_and_its_range_is_read_again ()=with_fixture (fun ~sw:_ fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  let hold=Atomic.make true in
  fixture.set_response (fun capture ->
    if Atomic.get hold then (ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release);
    `OK,F.openai_response (answer capture));
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    assert_pending (run_worker fixture);Eio.Promise.await arrived;
    let record,capture=only_original fixture in
    let exact=Capture.request capture |> get in
    (* Written before the cut, so no host pass reads this process's marker. *)
    mark_stopped_incarnation fixture exact;
    Atomic.set hold false;
    (match Memory_lane.with_librarian_purge ~base_path:fixture.base_path ~keeper_name (fun () -> ()) with
     | Ok () -> () | Error error -> fail (Memory_lane.purge_cancel_error_to_string error));
    let posts=F.post_count fixture.server in
    (* No delivery follows the pass that retains the interrupted refusal, so
       the passes reach the commit only through that pass's wake. *)
    check bool "the next passes read the same range again and commit it" true (advanced (run_until_done fixture));
    check bool "the interrupted original moved to the settled archive" true
      (settled_on fixture ~date:(day_of record.request_id) record);
    check bool "a new provider call judged the range" true (F.post_count fixture.server>posts);
    check (list string) "the new original's answer reached Memory"
      ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir))))
(* RFC librarian-ends-waiting-requests-of-a-replaced-declaration 3.2, 3.4 and
   3.6. An original the worker holds and the host has not run ends when its
   declaration is replaced. The pass that reads that end does not narrow the
   next read and does not wait for another signal. *)
(* The fixture declaration under another [run_id]: the same installation,
   package and tool with another semantic revision. *)
let replaced_declaration ?(enabled=true) fixture =
  let replaced=fixture.declaration enabled |> String.split_on_char '\n'
    |> List.map (function "run_id=\"librarian-original-owner\"" -> "run_id=\"librarian-replaced\"" | line -> line)
    |> String.concat "\n" in
  check bool "the fixture declaration names the run a test replaces" true (replaced<>fixture.declaration enabled);
  replaced
(* The provider is busy, so the host's attempt ends without a result and the
   request stays with its worker. The declaration is then replaced: the
   replacement worker lists the request it inherited, and the host ends it and
   delivers that end. Returns the original that was waiting. *)
let host_ends_the_original_of_a_replaced_declaration fixture ~sw =
  fixture.set_response (fun _ ->
    `Too_many_requests,{|{"error":{"message":"fixture refusal","type":"rate_limit_error"}}|});
  assert_pending (run_worker fixture);
  let waiting,waiting_capture=only_original fixture in
  check bool "the first read took everything unread" true
    (Source.extent (Capture.source waiting_capture)=Keeper_librarian_range.All_unread);
  await_deferral fixture waiting.request_id;
  check int "the provider was asked once and gave no result" 1 (F.post_count fixture.server);
  fixture.set_response (fun capture -> `OK,F.openai_response (answer capture));
  let deliveries= !(fixture.deliveries) in
  replace_actual_worker_configuration fixture ~sw (replaced_declaration fixture);
  await_delivery fixture ~after:deliveries;
  check int "the request of the replaced declaration was not sent again" 1 (F.post_count fixture.server);
  waiting
(* RFC 3.2. A floor step's guard gives the Runtime's answer as it is, and a
   failed read of the step's own record is not an answer about the
   declaration. *)
let test_a_floor_step_guard_tells_a_replaced_declaration_from_a_failed_read () =
  with_fixture (fun ~sw fixture ->
    provider_refuses_one_turn fixture size_refusal;
    let candidate,request=candidate_and_request fixture in
    fixture.set_step_response (answering_steps ["Original question to retain";"Original completed answer"]);
    ignore (finished (descend fixture candidate));
    let record,step=first_step_request fixture request in
    let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
      |> Result.map_error Lane_addon_manifest.error_to_string |> get in
    let authorization=Server_librarian_addon_validation.authorize ~base_path:fixture.base_path
      ~store:fixture.store ~declaration_id:"librarian" ~package step
      |> Result.map_error (function Exact.Unowned {reason} -> reason | Undecided {detail} -> detail)
      |> get |> Option.get in
    authorization.before_dispatch () |> Result.map_error Exact.dispatch_veto_detail |> get;
    replace_actual_worker_configuration fixture ~sw (replaced_declaration fixture);
    check bool "under a replaced declaration the step's guard says so" true
      (match authorization.before_dispatch () with
       | Error Exact.Declaration_replaced -> true | Ok () | Error (Exact.Not_now _) -> false);
    (* The stored record now names another request body, so the guard's own
       reload refuses it before the declaration is read. *)
    let changed=match Owner.to_json record with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
          key, if key="request_digest" then `String (String.make 64 '0') else value) fields)
      | `Null | `Bool _ | `Float _ | `Int _ | `Intlit _ | `String _ | `List _ ->
        fail "the retained step is not an object" in
    check bool "the fixture changes the step's stored digest" true (changed<>Owner.to_json record);
    io (fun () -> Store.save_tool_request_owner fixture.store ~scope:record.scope
      ~request_id:record.request_id changed |> get);
    check bool "a step record that cannot be confirmed is not a replaced declaration" true
      (guard_waits authorization.before_dispatch))
let test_a_replaced_declaration_ends_a_waiting_original_and_its_range_is_read_whole_again () =
  with_fixture (fun ~sw fixture ->
    let waiting=host_ends_the_original_of_a_replaced_declaration fixture ~sw in
    let wakes=ref 0 in
    ended_by_one_refusal (run_worker_waking fixture wakes);
    check int "the pass that read that end asks for the next pass itself" 1 !wakes;
    (* The woken pass moves the ended original and reads the range again. *)
    assert_pending (run_worker_waking fixture wakes);
    check bool "the ended original moved to the settled archive" true
      (settled_on fixture ~date:(day_of waiting.request_id) waiting);
    let fresh,fresh_capture=only_original fixture in
    check bool "a new original read the range" true (fresh.Owner.request_id<>waiting.request_id);
    check bool "and it read everything unread, not up to the first cut point" true
      (Source.extent (Capture.source fresh_capture)=Keeper_librarian_range.All_unread);
    check bool "the next passes commit it" true (advanced (run_until_done ~wakes fixture));
    check int "one more provider call judged the range" 2 (F.post_count fixture.server);
    check (list string) "the new original's answer reached Memory"
      ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir)))
let test_runner_free_replacement_recovers_an_unlisted_dispatch_pending_original () =
  with_fixture (fun ~sw fixture ->
    let original,request=retain_absent_history_original ~failed_selection:false fixture in
    let exact=Capture.request request |> get in
    let schema=Option.to_result ~none:"waiting replacement has no schema" exact.Exact.schema |> get in
    check bool "the dispatched owner has no actual host record or proof" true
      ((io (fun () -> Exact.observe_retained ~store:fixture.store ~declaration_id:"librarian" ~schema exact) |> get)
       =Exact.Retained_absent);
    replace_actual_worker_configuration fixture ~sw (replaced_declaration fixture);
    let positions=cut_source_positions fixture and memory=cut_memory_bytes fixture and wakes=ref 0 in
    ended_by_one_refusal (run_worker_waking fixture wakes);
    check int "normal owner reconciliation asks for its next pass" 1 !wakes;
    let ended,ended_request=only_original fixture in
    check string "the ending belongs to the same original" original.request_id ended.Owner.request_id;
    check json "the ending preserves its immutable request" original.request ended.request;
    check json "the restored ending keeps the same captured body" (Capture.to_json request) (Capture.to_json ended_request);
    let expected=Exact.Retained_not_allowed {reason=Replaced_declaration} in
    io (fun () -> Capture.confirm_retained_final ~store:fixture.store request expected |> get);
    (match io (fun () -> Exact.read_latest_original_execution ~store:fixture.store
       ~declaration_id:"librarian" ~schema exact) |> get with
     | Exact.No_completed_latest -> ()
     | Completed_latest _ -> fail "the ending fabricated an original host execution");
    check bool "ending alone leaves the original live until fresh inventory" false
      (settled_on fixture ~date:(day_of original.request_id) original);
    check bool "ending alone changes no source ACK" true (cut_source_positions fixture=positions);
    check bool "ending alone changes no Memory, journal or receipts" true (cut_memory_bytes fixture=memory);
    check int "the replaced original never reaches the model" 0 (F.post_count fixture.server);
    let provider_ids=ref [] in
    fixture.set_response (fun capture ->
      let id=Capture.request_id capture in
      check bool "only a fresh original reaches the provider" true (id<>original.request_id);
      provider_ids:=id:: !provider_ids;
      `OK,F.openai_response (answer capture));
    assert_pending (run_worker_waking fixture wakes);
    check bool "fresh inventory moves the actual ended original" true
      (settled_on fixture ~date:(day_of original.request_id) original);
    let fresh,fresh_request=only_original fixture in
    check bool "the next request has a fresh identity" true (fresh.Owner.request_id<>original.request_id);
    check bool "the complete unread range is selected again" true
      (Source.extent (Capture.source fresh_request)=Keeper_librarian_range.All_unread);
    drive_advanced fixture;
    check (list string) "only the fresh retained original was dispatched" [fresh.request_id] !provider_ids;
    check (list string) "the actual fresh answer reached Memory"
      ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir));
    check bool "only that completed read advances source ACK" false (cut_source_positions fixture=positions))
(* Two independent originals can wait before either worker accepted them. A
   changed declaration must retain one actual no-send ending before the
   multiplicity guard, then yield so the next pass uses a fresh inventory. *)
let test_two_absent_originals_drain_replaced_endings_before_fresh_selection () =
  with_fixture (fun ~sw fixture ->
    let first,first_request=retain_absent_history_original ~failed_selection:false fixture in
    let second,second_request=memory_action fixture (fun () ->
      Keeper_librarian_durable_edge.with_destination ~config:fixture.config
        ~reserved:(Keeper_librarian_durable_edge.reserved ()) (fun destination ->
          let owner=Capture.physical_owner first_request in
          let preparation=Keeper_librarian_runtime.prepare_durable ~now:(Time_compat.now ())
            ~source_lines:["Second independent waiting original fixture source"]
            (Source.input (Capture.source first_request)) |> get in
          let request=io (fun () -> Capture.create ~request_id:(Capture.fresh_request_id owner)
            ~owner ~destination ~source:(Capture.source first_request) ~preparation ()) |> get in
          let record=Durable_owner.retain ~store:fixture.store request
            |> Result.map_error Durable_owner.error_to_string |> get in
          let record=advance_original fixture record Progress.Dispatch_intended in
          let record=advance_original fixture record (Progress.Execution_observed (Progress.Absent (`Assoc []))) in
          Ok (record,request))) |> get in
    let first_exact=Capture.request first_request |> get and second_exact=Capture.request second_request |> get in
    check bool "the factory gives the two original questions distinct HTTP identities" true
      (first_exact.system<>second_exact.system || first_exact.messages<>second_exact.messages);
    check string "both originals preserve the same source obligation"
      (Capture.source_basis_digest first_request |> get) (Capture.source_basis_digest second_request |> get);
    let originals=[first,first_request;second,second_request] in
    let ids=List.map (fun ((record:Owner.retained),_) -> record.request_id) originals |> List.sort String.compare in
    let live_ids ()=List.map (fun ((record:Owner.retained),_) -> record.request_id)
      (observed_originals fixture) |> List.sort String.compare in
    let live request_id=List.find_opt (fun ((record:Owner.retained),_) -> record.request_id=request_id)
      (observed_originals fixture) |> Option.to_result ~none:"expected a retained waiting original" |> get in
    let assert_no_host request =
      let exact=Capture.request request |> get in
      let schema=Option.to_result ~none:"waiting original has no schema" exact.Exact.schema |> get in
      check bool "the waiting original has no actual host record" true
        ((io (fun () -> Exact.observe_retained ~store:fixture.store ~declaration_id:"librarian" ~schema exact) |> get)
          =Exact.Retained_absent);
      check bool "the waiting original has no completed host proof" true
        (latest fixture request=Exact.No_completed_latest) in
    List.iter (fun (_,request) -> assert_no_host request) originals;
    let positions=cut_source_positions fixture and memory=cut_memory_bytes fixture and wakes=ref 0 in
    let no_effects () =
      check bool "ending recovery moves no source cursor or ACK" true (cut_source_positions fixture=positions);
      check bool "ending recovery changes no Memory, journal or receipts" true (cut_memory_bytes fixture=memory);
      check int "neither waiting original reaches the provider" 0 (F.post_count fixture.server) in
    (match run_worker_waking fixture wakes with
     | Error (Consumer.Original_publication_blocked _) -> ()
     | Error error -> fail (Consumer.error_to_string error)
     | Ok _ -> fail "two current-declaration originals must retain the multiplicity refusal");
    check int "the unchanged declaration requests no next pass" 0 !wakes;
    check (list string) "multiplicity creates or archives no original ID" ids (live_ids ());
    List.iter (fun ((record:Owner.retained),request) ->
      let actual,_=live record.request_id in
      check json "multiplicity refuses without rewriting either owner" (Owner.to_json record) (Owner.to_json actual);
      assert_no_host request) originals;
    no_effects ();
    replace_actual_worker_configuration fixture ~sw (replaced_declaration fixture);
    List.iter (fun (_,request) -> assert_no_host request) originals;
    let ended_id=match run_worker_waking fixture wakes with
      | Ok (Consumer.Pending (Keeper_librarian_pending.Publication {request_id;_})) -> request_id
      | Error error -> fail (Consumer.error_to_string error)
      | Ok (Consumer.Pending _ | Nothing_to_read | Baseline_advanced _ | Progress_advanced _
          | Official_advanced _ | Memory_not_committed _) ->
        fail "one retained no-send ending must yield before reusing frontier counts" in
    check int "one changed ending requests exactly one fresh pass" 1 !wakes;
    check (list string) "the ending pass creates or archives no original ID" ids (live_ids ());
    let ended,ended_request=live ended_id in
    let assert_ending ((record:Owner.retained),request) =
      let exact=Capture.request request |> get in
      let schema=Option.to_result ~none:"ended original has no schema" exact.Exact.schema |> get in
      let expected=Exact.Retained_not_allowed {reason=Replaced_declaration} in
      (match Progress.phase record.progress with
       | Rejected {stage=Execution;evidence} ->
         check bool "the original retains the actual typed replacement cause" true
           ((Exact.retained_final_of_json ~schema evidence |> get)=expected)
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
       | Finished _ | Conflicted _ | Rejected {stage=Before_dispatch;_} | Subdividing _ | Subdivided _ ->
         fail "the original has no execution-stage replacement ending");
      io (fun () -> Capture.confirm_retained_final ~store:fixture.store request expected |> get);
      check bool "the ending introduces no completed host execution" true
        (latest fixture request=Exact.No_completed_latest) in
    assert_ending (ended,ended_request);
    let other_id=List.find_opt (fun id -> id<>ended_id) ids
      |> Option.to_result ~none:"the fixture must retain two distinct original IDs" |> get in
    let other,other_request=live other_id in
    assert_no_host other_request;
    List.iter (fun ((record:Owner.retained),request) ->
      let actual,actual_request=live record.request_id in
      check json "the ending pass preserves the exact original body" (Capture.to_json request) (Capture.to_json actual_request);
      check json "the ending pass preserves the owner's immutable request" record.request actual.request;
      check bool "the first ending pass archives neither original" false
        (settled_on fixture ~date:(day_of record.request_id) record)) originals;
    no_effects ();
    ended_by_one_refusal (run_worker_waking fixture wakes);
    check int "the second real ending requests its next pass" 2 !wakes;
    check bool "fresh inventory archives the first confirmed ending" true
      (settled_on fixture ~date:(day_of ended.request_id) ended);
    let other_ended,other_ended_request=only_original fixture in
    check string "the remaining original ends under its same ID" other_id other_ended.Owner.request_id;
    assert_ending (other_ended,other_ended_request);
    check bool "the second ending waits for its own fresh inventory" false
      (settled_on fixture ~date:(day_of other.request_id) other);
    no_effects ();
    let provider_ids=ref [] in
    fixture.set_response (fun request ->
      let id=Capture.request_id request in
      check bool "only a fresh identity may reach the provider" false (List.mem id ids);
      provider_ids:=id:: !provider_ids;
      `OK,F.openai_response (answer request));
    assert_pending (run_worker_waking fixture wakes);
    List.iter (fun ((record:Owner.retained),_) ->
      check bool "both real no-send endings are archived before fresh selection" true
        (settled_on fixture ~date:(day_of record.request_id) record)) originals;
    let fresh,fresh_request=only_original fixture in
    check bool "one fresh original owns the complete unread source" true
      (not (List.mem fresh.Owner.request_id ids)
       && Capture.predecessor fresh_request=None
       && Source.extent (Capture.source fresh_request)=Keeper_librarian_range.All_unread);
    let original_source=Capture.source first_request and fresh_source=Capture.source fresh_request in
    (* The first capture prepared the external read before its simulated
       Memory_replaced return. A fresh capture observes that same preparation
       as its starting state, while retaining every source and receipt field. *)
    check bool "the initial capture preceded the pending external preparation" true
      (Source.external_before original_source<>Source.external_prepared original_source);
    check bool "fresh selection observes the exact existing external preparation" true
      (Source.external_before fresh_source=Source.external_prepared original_source);
    let expected_basis=match Source.basis_json original_source with
      | `Assoc fields -> `Assoc (List.map (function
          | "external_before",_ -> "external_before",Keeper_external_read_cursor.observation_to_json
              (Source.external_prepared original_source)
          | field -> field) fields)
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        fail "the original source basis must be an object" in
    check json "fresh selection preserves the complete original source obligation"
      expected_basis (Source.basis_json fresh_source);
    drive_advanced fixture;
    let completed,_=only_original fixture in
    check string "the actual committed answer belongs to that fresh original" fresh.request_id completed.Owner.request_id;
    check bool "the fresh original finishes only after real publication and ACK" true
      (match Progress.phase completed.progress with Finished _ -> true
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
       | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
    check bool "the fresh original has actual Memory range receipts" true
      (io (fun () -> Commit.receipt_state fresh_request) |> get);
    check (list string) "exactly that fresh original reaches the provider" [fresh.request_id] !provider_ids;
    check int "both obsolete originals remain unsent" 1 (F.post_count fixture.server);
    check (list string) "the fresh answer reaches actual Memory"
      ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir));
    check bool "only the fresh committed read advances source positions" false (cut_source_positions fixture=positions);
    let through=Keeper_librarian_input_sources.external_through (Source.counterparts (Capture.source fresh_request)) in
    let cursor=io (fun () -> Keeper_external_read_cursor.observe
      ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
    check bool "the fresh commit ACKs the exact original external frontier" true
      (Keeper_external_read_cursor.observation_matches_preparation cursor ~after:through ~through ~atom:None ~official:None))
(* A real host no-send ending can already be retained as Rejected. Submit
   recovery is then skipped, so the chain's recreation decision must read the
   actual proof link independently before cleanup can move that step. *)
let test_a_retained_replaced_floor_step_requires_its_actual_proof_link () =
  with_fixture (fun ~sw fixture ->
    let module Step=Keeper_librarian_floor_step_request in
    provider_refuses_one_turn fixture size_refusal;
    let candidate,request=candidate_and_request fixture in
    let original_exact=Capture.request request |> get in
    let original_schema=Option.to_result ~none:"original fixture has no schema" original_exact.Exact.schema |> get in
    (match io (fun () -> Exact.read_latest_original_execution ~store:fixture.store
      ~declaration_id:"librarian" ~schema:original_schema original_exact) |> get with
     | Exact.Completed_latest _ -> ()
     | No_completed_latest -> fail "the provider's actual size refusal must retain its completed proof");
    let foreign_completed_proof=io (fun () -> Fs_compat.load_file (proof_path fixture original_exact)) in
    fixture.set_step_response (fun _ ->
      `Too_many_requests,{|{"error":{"message":"fixture refusal","type":"rate_limit_error"}}|});
    let chain ()=memory_action fixture (fun () -> Descent.descend ~store:fixture.store
      ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ()) candidate) in
    (match chain () with
     | Ok (Chain.Pending _) -> ()
     | Error detail -> fail detail
     | Ok (Finished _ | Stopped _ | Declaration_replaced _ | Superseded) ->
       fail "the busy provider must leave one actual pending floor step");
    let waiting,step=first_step fixture request in
    let exact=Step.request step |> get in
    await_deferral fixture exact.request_id;
    let deliveries= !(fixture.deliveries) in
    replace_actual_worker_configuration fixture ~sw (replaced_declaration fixture);
    await_delivery fixture ~after:deliveries;
    let replacement ()=match chain () with
      | Ok (Chain.Declaration_replaced {position=0;request_id}) ->
        check string "replacement names the same first step" waiting.Owner.request_id request_id
      | Error detail -> fail detail
      | Ok (Declaration_replaced _ | Finished _ | Pending _ | Stopped _ | Superseded) ->
        fail "the actual no-send ending must permit this step's recreation" in
    replacement ();
    let ended,_=first_step fixture request in
    let schema=Option.to_result ~none:"step fixture has no schema" exact.Exact.schema |> get in
    (match Progress.phase ended.progress with
     | Rejected {stage=Execution;evidence} ->
       (match Exact.retained_final_of_json ~schema evidence |> get with
        | Retained_not_allowed {reason=Replaced_declaration} -> ()
        | Retained_call _ | Retained_unknown _ | Retained_not_allowed {reason=Permission_refused _}
        | Retained_request_id_reused -> fail "the actual host did not retain a typed replacement ending")
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Rejected {stage=Before_dispatch;_} | Subdividing _ | Subdivided _ ->
       fail "the step must already hold its execution refusal before the proof is damaged");
    let path=proof_path fixture exact in
    (match io (fun () -> Exact.read_latest_original_execution ~store:fixture.store
      ~declaration_id:"librarian" ~schema exact) |> get with
     | Completed_latest {execution={outcome=Exact.Call_refused _;_};_} -> ()
     | No_completed_latest | Completed_latest {execution={outcome=Exact.Call_ended _;_};_} ->
       fail "the actual 429 must leave a bound closed-deferral proof before the replacement ending");
    let lineage_ending ()=io (fun () -> Keeper_librarian_declaration_replacement.ended
      ~store:fixture.store ~original:(Owner.listed ended) ~exact ~captured:(Step.destination step)) in
    check bool "the actual lineage ending preserves the earlier closed deferral" true (lineage_ending () |> get);
    (* Replacement adds no attempt ordinal: its latest proof is the previous
       actual Call_refused deferral, not a result of the replacement ending. *)
    let original_proof=io (fun () -> Fs_compat.load_file_opt path) in
    let restore_proof ()=match original_proof with
      | Some bytes -> write path bytes
      | None -> if Sys.file_exists path then Sys.remove path in
    let posts=F.post_count fixture.server and positions=progress fixture and wakes=ref 0 in
    let runtime_keepers_dir=Workspace.keepers_runtime_dir fixture.config in
    let cursor ()=io (fun () -> Keeper_external_read_cursor.observe ~runtime_keepers_dir ~keeper_name |> get)
      |> Keeper_external_read_cursor.observation_to_json in
    let official ()=io (fun () -> Keeper_librarian_official_progress.read ~keepers_dir:runtime_keepers_dir
      ~keeper_id:keeper_name |> Result.map_error Keeper_librarian_official_progress.read_error_to_string |> get) in
    let before_cursor=cursor () and before_official=official () in
    let snapshot ()=io (fun () -> Fs_compat.load_file_opt
      (Current.path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name)) in
    let original_ids ()=List.map (fun ((record:Owner.retained),_) -> record.request_id) (observed_originals fixture) in
    let before_snapshot=snapshot () and before_ids=original_ids () in
    let before=Owner.record_to_json (Owner.listed ended) in
    let date=Step.minted_on ended.request_id |> get in
    let damages=[
      (fun () -> write path "{malformed actual execution proof"),restore_proof;
      (fun () -> write path foreign_completed_proof),restore_proof;
      (fun () -> if Sys.file_exists path then Sys.remove path; Unix.mkdir path 0o700),
        (fun () -> Unix.rmdir path; restore_proof ())] in
    List.iter (fun (damage,restore) ->
      io damage;
      check bool "the actual latest-proof reader refuses the damaged link" true
        (Result.is_error (io (fun () -> Exact.read_latest_original_execution ~store:fixture.store
          ~declaration_id:"librarian" ~schema exact)));
      (match chain () with
       | Error _ -> ()
       | Ok _ -> fail "a retained replacement bypassed its actual malformed or contradictory proof");
      check bool "the actual replacement lineage refuses the same damaged proof" true
        (Result.is_error (lineage_ending ()));
      (match run_worker_waking fixture wakes with
       | Error (Consumer.Original_publication_blocked _) -> ()
       | Error error -> fail (Consumer.error_to_string error)
       | Ok _ -> fail "invalid replacement proof reached cleanup or fresh selection");
      check bool "the refused step is not archived" false (settled_on fixture ~date ended);
      let observed,_=first_step fixture request in
      check json "the same rejected original and its progress remain" before (Owner.record_to_json (Owner.listed observed));
      check int "no replacement step ID is created" 1 (List.length (steps_of fixture request));
      check (list string) "no new history original is retained" before_ids (original_ids ());
      check int "the blocked pass requests no new pass" 0 !wakes;
      check int "proof refusal calls no provider" posts (F.post_count fixture.server);
      check bool "proof refusal moves no atom position" true (progress fixture=positions);
      check bool "proof refusal moves no official position" true (official ()=before_official);
      check json "proof refusal leaves the complete external ACK unchanged" before_cursor (cursor ());
      check bool "proof refusal preserves the exact Memory snapshot" true (snapshot ()=before_snapshot);
      no_memory fixture;
      io restore;
      replacement ();
      check bool "restoring the exact prior proof also restores lineage confirmation" true (lineage_ending () |> get)) damages)
(* RFC 3.4. A stored replacement ending remains that ending even when the
   original declaration is restored before its Keeper reads it. *)
let test_a_declaration_put_back_before_the_end_is_read_preserves_the_ending () =
  with_fixture (fun ~sw fixture ->
    let waiting=host_ends_the_original_of_a_replaced_declaration fixture ~sw in
    replace_actual_worker_configuration fixture ~sw (fixture.declaration true);
    let wakes=ref 0 in
    ended_by_one_refusal (run_worker_waking fixture wakes);
    check int "the recorded replacement ending asks for the next pass" 1 !wakes;
    assert_pending (run_worker_waking fixture wakes);
    let fresh,fresh_capture=only_original fixture in
    check bool "a new original read the range" true (fresh.Owner.request_id<>waiting.request_id);
    check bool "rollback does not narrow the next read" true
      (Source.extent (Capture.source fresh_capture)=Keeper_librarian_range.All_unread);
    check bool "the next passes commit it" true (advanced (run_until_done ~wakes fixture)))
(* Inventory may archive an unlinked Rejected before the Owner's resume path
   runs again. Confirm the actual typed host ending at that earlier boundary,
   including when all unread history makes this original no floor candidate. *)
let test_a_retained_replaced_history_original_checks_its_proof_before_inventory_settlement () =
  with_fixture (fun ~sw fixture ->
    let waiting=host_ends_the_original_of_a_replaced_declaration fixture ~sw in
    let wakes=ref 0 in
    ended_by_one_refusal (run_worker_waking fixture wakes);
    let ended,request=only_original fixture in
    check string "the actual ending still owns the original ID" waiting.Owner.request_id ended.Owner.request_id;
    check bool "the inventory regression is unlinked and reads all unread history" true
      (Capture.predecessor request=None && Source.extent (Capture.source request)=Keeper_librarian_range.All_unread);
    let exact=Capture.request request |> get in
    let schema=Option.to_result ~none:"ended history fixture has no schema" exact.Exact.schema |> get in
    (match io (fun () -> Exact.observe_retained ~store:fixture.store ~declaration_id:"librarian" ~schema exact) |> get with
     | Retained_terminal (Retained_not_allowed {reason=Replaced_declaration}) -> ()
     | Retained_absent | Retained_open
     | Retained_terminal (Retained_call _ | Retained_unknown _ | Retained_not_allowed {reason=Permission_refused _}
       | Retained_request_id_reused) -> fail "the actual host did not retain its typed declaration ending");
    (match Progress.phase ended.progress with
     | Rejected {stage=Execution;_} -> ()
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Rejected {stage=Before_dispatch;_} | Subdividing _ | Subdivided _ ->
       fail "the original must already be Rejected before its next inventory read");
    check bool "the all-unread replaced original is not a floor candidate" true
      (Option.is_none (candidate_of fixture));
    (match latest fixture request with
     | Exact.Completed_latest {execution={outcome=Exact.Call_refused _;_};_} -> ()
     | No_completed_latest | Completed_latest {execution={outcome=Exact.Call_ended _;_};_} ->
       fail "the actual replaced original must retain its earlier closed-deferral proof");
    let validates ()=io (fun () -> Commit.validate ~store:fixture.store ~request ~record:ended) in
    (match validates () |> get with Commit.Settled -> () | Unfinished -> fail "a valid declaration ending was not settled");
    (* Produce a foreign completed proof through real configured Runtime and
       Exact HTTP. Its definite capacity refusal is validated and archived by
       the ordinary public policy; it consumes no source or Memory. *)
    fixture.set_response (fun _ -> size_refusal);
    let foreign,record,foreign_exact=memory_action fixture (fun () ->
      let owner=Capture.physical_owner request in
      Keeper_librarian_durable_edge.with_destination ~config:fixture.config
        ~reserved:(Keeper_librarian_durable_edge.reserved ()) (fun destination ->
          let foreign=io (fun () -> Capture.create ~request_id:(Capture.fresh_request_id owner)
            ~owner ~destination ~source:(Capture.source request) ~preparation:(Capture.preparation request) ()) |> get in
          let record=Durable_owner.retain ~store:fixture.store foreign
            |> Result.map_error Durable_owner.error_to_string |> get in
          let record=advance_original fixture record Progress.Dispatch_intended in
          Ok (foreign,record,Capture.request foreign |> get)) |> get) in
    (* The HTTP fixture waits for the submitting Memory unit to become idle,
       just as the configured worker executes after its submit returned. *)
    let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
      |> Result.map_error Lane_addon_manifest.error_to_string |> get in
    (match Exact.run ~store:fixture.store ~declaration_id:"librarian" ~package
      ~runner:(Server_lane_addon_exact.runner ~base_path:fixture.base_path)
      ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path:fixture.base_path) foreign_exact |> get with
     | Final (Call_final (Input_refused _)) -> ()
     | Final (Call_final (Answered _ | Invalid_output _ | Output_limit_reached _) | Outcome_unknown
         | Not_allowed _ | Request_id_reused) | Not_final _ -> fail "the foreign original has no actual capacity result");
    let foreign_completed_proof=memory_action fixture (fun () ->
      let foreign_schema=Option.to_result ~none:"foreign original lacks its schema" foreign_exact.Exact.schema |> get in
      let retained=match io (fun () -> Exact.observe_retained ~store:fixture.store ~declaration_id:"librarian"
        ~schema:foreign_schema foreign_exact) |> get with
        | Retained_terminal (Retained_call (Input_refused _) as retained) -> retained
        | Retained_absent | Retained_open | Retained_terminal (Retained_call (Answered _ | Invalid_output _
            | Output_limit_reached _) | Retained_unknown _ | Retained_not_allowed _ | Retained_request_id_reused) ->
          fail "the foreign host proof has no retained capacity result" in
      let record=advance_original fixture record
        (Progress.Refused {stage=Execution;evidence=Exact.retained_final_to_json retained}) in
      (match io (fun () -> Commit.validate ~store:fixture.store ~request:foreign ~record) |> get with
       | Settled -> () | Unfinished -> fail "the definite foreign refusal was not settled");
      let bytes=io (fun () -> Fs_compat.load_file (proof_path fixture foreign_exact)) in
      settle_only fixture ~date:(day_of record.request_id) record;
      bytes) in
    fixture.set_response (fun capture -> `OK,F.openai_response (answer capture));
    let path=proof_path fixture exact in
    let original_proof=io (fun () -> Fs_compat.load_file_opt path) in
    let restore_proof ()=match original_proof with
      | Some bytes -> write path bytes
      | None -> if Sys.file_exists path then Sys.remove path in
    let before_record=Owner.record_to_json (Owner.listed ended) in
    let ids ()=List.map (fun ((record:Owner.retained),_) -> record.request_id) (observed_originals fixture) in
    let before_ids=ids () and posts=F.post_count fixture.server and before_wakes= !wakes in
    let runtime_keepers_dir=Workspace.keepers_runtime_dir fixture.config in
    let cursor ()=io (fun () -> Keeper_external_read_cursor.observe ~runtime_keepers_dir ~keeper_name |> get)
      |> Keeper_external_read_cursor.observation_to_json in
    let official ()=io (fun () -> Keeper_librarian_official_progress.read ~keepers_dir:runtime_keepers_dir
      ~keeper_id:keeper_name |> Result.map_error Keeper_librarian_official_progress.read_error_to_string |> get) in
    let snapshot ()=io (fun () -> Fs_compat.load_file_opt
      (Current.path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name)) in
    let atom=progress fixture and before_official=official () and before_cursor=cursor () and memory=snapshot () in
    let damages=[
      (fun () -> write path "{malformed actual original proof"),restore_proof;
      (fun () -> write path foreign_completed_proof),restore_proof;
      (fun () -> if Sys.file_exists path then Sys.remove path; Unix.mkdir path 0o700),
        (fun () -> Unix.rmdir path; restore_proof ())] in
    List.iter (fun (damage,restore) ->
      io damage;
      check bool "inventory validation refuses the actual damaged original proof" true (Result.is_error (validates ()));
      (match run_worker_waking fixture wakes with
       | Error (Consumer.Original_publication_blocked _) -> ()
       | Error error -> fail (Consumer.error_to_string error)
       | Ok _ -> fail "an invalid retained declaration ending reached inventory archive or fresh selection");
      check bool "the retained ending remains unarchived" false
        (settled_on fixture ~date:(day_of ended.request_id) ended);
      check (list string) "no fresh original is retained" before_ids (ids ());
      let current,_=only_original fixture in
      check json "the exact original and its refusal remain" before_record (Owner.record_to_json (Owner.listed current));
      check int "invalid inventory proof schedules no fresh pass" before_wakes !wakes;
      check int "invalid inventory proof calls no provider" posts (F.post_count fixture.server);
      check bool "invalid inventory proof moves no atom position" true (progress fixture=atom);
      check bool "invalid inventory proof moves no official position" true (official ()=before_official);
      check json "invalid inventory proof preserves external ACK" before_cursor (cursor ());
      check bool "invalid inventory proof preserves exact Memory bytes" true (snapshot ()=memory);
      io restore;
      (match validates () |> get with Settled -> () | Unfinished -> fail "restored actual proof did not restore the ending")) damages)
(* A history original captured for the declaration of now that no worker has
   received. The pass that takes its source ends Pending, so it leaves no
   narrowing mark. [declined] is the same original after a submit the host
   refused before sending. *)
let retain_unadmitted_history_original fixture ~declined =
  let captured=ref None in
  (match memory_action fixture (fun () -> Consumer.consume_one ~config:fixture.config ~keeper_name
    ~commit:(fun source -> captured:=Some source;
      Consumer.Memory_pending (Keeper_librarian_pending.Local_failure "the fixture takes the source only"))) with
   | Ok (Consumer.Pending _) -> ()
   | Ok (Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _)
   | Error _ -> fail "the fixture did not take an unread history source");
  let source=Option.to_result ~none:"missing fixture source" !captured |> get in
  let owner=io (fun () ->
    ignore (Current.capture_program_anchor ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get);
    Capture.observe_owner ~base_path:fixture.base_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get) in
  let preparation=Keeper_librarian_runtime.prepare_durable ~source_lines:[] ~now:(Time_compat.now ())
    (Source.input source) |> get in
  let destination=Keeper_librarian_durable_edge.with_destination ~config:fixture.config
    ~reserved:(Keeper_librarian_durable_edge.reserved ()) (fun destination -> Ok destination) |> get in
  let request=io (fun () -> Capture.create ~request_id:(Capture.fresh_request_id owner)
    ~owner ~destination ~source ~preparation ()) |> get in
  let original=memory_action fixture (fun () -> Durable_owner.retain ~store:fixture.store request)
    |> Result.map_error Durable_owner.error_to_string |> get in
  if declined then
    advance_original fixture (advance_original fixture original Progress.Dispatch_intended)
      (Progress.Admission_declined (`Assoc ["not_sent",`String "fixture: the Add-on was restarting"]))
  else original
(* RFC librarian-ends-waiting-requests-of-a-replaced-declaration 3.3 and 3.6.
   No worker received the original, so the host never sees it: the Keeper's
   pass ends it, asks for the next pass, and that pass reads the same range
   whole under the declaration of then. *)
let a_replaced_declaration_ends_an_original_no_worker_received ~declined () =
  with_fixture (fun ~sw fixture ->
    let unadmitted=retain_unadmitted_history_original fixture ~declined in
    replace_actual_worker_configuration fixture ~sw (replaced_declaration fixture);
    let wakes=ref 0 in
    ended_by_one_refusal (run_worker_waking fixture wakes);
    check int "the pass that ended it asks for the next pass itself" 1 !wakes;
    let ended,ended_capture=only_original fixture in
    check string "the same original ended" unadmitted.Owner.request_id ended.Owner.request_id;
    let evidence=match Progress.phase ended.Owner.progress with
      | Rejected {stage=Progress.Before_dispatch;evidence} -> evidence
      | Rejected {stage=Progress.Execution;_} | Captured | Admission_wait _ | Dispatch_pending _
      | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
      | Subdividing _ | Subdivided _ -> fail "the original did not end before dispatch" in
    (* The end holds the destination the original was captured for and the
       one the configuration named when it ended. Nothing else reads as it. *)
    let captured : Capture.destination=Capture.destination ended_capture in
    let replaced : Capture.replaced=Capture.confirm_replaced ended_capture evidence |> get in
    check bool "the end names the original's destination and another revision of it" true
      (replaced.captured=captured
       && replaced.current.configuration_revision<>captured.configuration_revision);
    let refused evidence=Result.is_error (Capture.confirm_replaced ended_capture evidence) in
    check bool "the same destination twice is not a replaced declaration" true
      (refused (Capture.replaced_to_json {Capture.captured;current=captured}));
    check bool "another installation is not a replaced declaration" true
      (refused (Capture.replaced_to_json {Capture.captured;
        current={replaced.current with installation_id="another-installation"}}));
    check bool "an end captured for another destination is not this original's" true
      (refused (Capture.replaced_to_json {Capture.captured=replaced.current;current=captured}));
    check bool "evidence of another shape is refused" true
      (refused (`Assoc ["declaration_replaced",`String "not two destinations"]));
    (* The woken pass moves the ended original and reads the range again. *)
    assert_pending (run_worker_waking fixture wakes);
    check int "the pass that moved it and read again asks for no pass" 1 !wakes;
    check bool "the ended original moved to the settled archive" true
      (settled_on fixture ~date:(day_of unadmitted.request_id) unadmitted);
    let fresh,fresh_capture=only_original fixture in
    check bool "a new original read the range" true (fresh.Owner.request_id<>unadmitted.request_id);
    check bool "and it read everything unread, not up to the first cut point" true
      (Source.extent (Capture.source fresh_capture)=Keeper_librarian_range.All_unread);
    check bool "the next passes commit it" true (advanced (run_until_done ~wakes fixture));
    check int "one provider call judged the range" 1 (F.post_count fixture.server);
    check (list string) "the new original's answer reached Memory"
      ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir)))
(* Only the Librarian's own evidence ends an original before dispatch. A
   record that holds the phase with anything else stops the pass. *)
let test_a_pre_dispatch_refusal_with_other_evidence_stops_the_pass () =
  with_fixture (fun ~sw:_ fixture ->
    let unadmitted=retain_unadmitted_history_original fixture ~declined:false in
    let refused=advance_original fixture unadmitted (Progress.Refused {stage=Progress.Before_dispatch;
      evidence=`Assoc ["declaration_replaced",`String "not two destinations"]}) in
    let wakes=ref 0 in
    (match run_worker_waking fixture wakes with
     | Error _ -> ()
     | Ok _ -> fail "a pre-dispatch refusal with other evidence was read as an end");
    check int "the pass asks for no other pass" 0 !wakes;
    check bool "the record is not archived" false
      (settled_on fixture ~date:(day_of refused.Owner.request_id) refused);
    check int "no provider was asked" 0 (F.post_count fixture.server))
(* The same original under the declaration it was captured for is admitted. *)
let an_unadmitted_original_of_the_same_declaration_is_admitted ~declined () =
  with_fixture (fun ~sw:_ fixture ->
    let unadmitted=retain_unadmitted_history_original fixture ~declined in
    let wakes=ref 0 in
    check bool "the passes admit it and commit it" true (advanced (run_until_done ~wakes fixture));
    check bool "the same original holds the answer" true
      (settled_on fixture ~date:(day_of unadmitted.Owner.request_id) unadmitted
       || (match observed_originals fixture with
           | [(record:Owner.retained),_] ->
             record.request_id=unadmitted.Owner.request_id
             && (match Progress.phase record.progress with
                 | Finished _ -> true
                 | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
                 | Commit_unknown _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false)
           | [] | _::_::_ -> false));
    check int "one provider call judged the range" 1 (F.post_count fixture.server))
(* The Add-on is off, so the destination of now cannot be read. Nothing says
   the declaration was replaced: the original waits as it did. *)
let test_an_unadmitted_original_waits_while_the_addon_is_off () =
  with_fixture (fun ~sw:_ fixture ->
    let unadmitted=retain_unadmitted_history_original fixture ~declined:false in
    set_enabled fixture false;
    let wakes=ref 0 in
    assert_pending (run_worker_waking fixture wakes);
    check int "a wait asks for no pass" 0 !wakes;
    let waiting,_=only_original fixture in
    check bool "the original is still the one no worker received" true
      (waiting.Owner.request_id=unadmitted.Owner.request_id
       && (match Progress.phase waiting.Owner.progress with
           | Captured -> true
           | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
           | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false));
    check int "no provider was asked" 0 (F.post_count fixture.server))
(* RFC librarian-ends-waiting-requests-of-a-replaced-declaration 3.5. The
   declaration is replaced while the host is asking the provider. Retiring
   the old worker cuts that attempt off, and the host of the replacement
   worker ends the request with an unknown outcome and delivers it. Returns
   the original whose attempt was cut. *)
let a_replaced_declaration_cuts_the_running_original fixture ~sw =
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  let hold=Atomic.make true in
  fixture.set_response (fun capture ->
    if Atomic.get hold then (ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release);
    `OK,F.openai_response (answer capture));
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    assert_pending (run_worker fixture);Eio.Promise.await arrived;
    let record,capture=only_original fixture in
    let deliveries= !(fixture.deliveries) in
    Atomic.set hold false;
    replace_actual_worker_configuration fixture ~sw (replaced_declaration fixture);
    await_delivery fixture ~after:deliveries;
    let exact=Capture.request capture |> get in
    let schema=match exact.Exact.schema with
      | Some schema -> schema | None -> fail "the original has no schema" in
    (match io (fun () -> Exact.observe_retained ~store:fixture.store ~declaration_id:"librarian" ~schema exact |> get) with
     | Exact.Retained_terminal (Exact.Retained_unknown Exact.Cut) -> ()
     | Retained_absent | Retained_open
     | Retained_terminal (Retained_unknown (Interrupted | Raised) | Retained_call _
         | Retained_not_allowed _ | Retained_request_id_reused) ->
       fail "the host did not end the attempt as cut off in this process");
    record,capture)
(* Read only the actual owner here. The production pass has a separate
   same-binding Cut continuation through exclusion, fence and child intent. *)
let resume_cut_owner fixture wakes =
  let record,request=only_original fixture in
  memory_action fixture (fun () -> Durable_owner.resume ~store:fixture.store
    ~config:fixture.config ~reserved:[] ~original:(Durable_owner.Read (record,request))
    ~wake:(fun () -> incr wakes)
    ~call:(fun ~expected:_ ~original:_ ~arguments:_ -> fail "a retained Cut must not dispatch its original")
    ~publish:(fun ~original:_ ~request:_ ~proposal:_ -> fail "a retained Cut has no answer to publish"))
  |> Result.map_error Durable_owner.error_to_string |> get
let cut_release_observed fixture =
  let record,request=only_original fixture in
  let exact=Capture.request request |> get in
  io (fun () -> Keeper_librarian_declaration_replacement.released_cut ~store:fixture.store
    ~original:(Owner.listed record) ~exact ~captured:(Capture.destination request)) |> get
let require_cut_wait fixture (cut:Owner.retained) wakes =
  (match resume_cut_owner fixture wakes with
   | Durable_owner.Waited (wait,record) ->
     check string "the owner still holds its original" cut.Owner.request_id (Owner.Record.request_id record);
     check bool "the owner preserves execution uncertainty" true (wait=Durable_owner.Worker_unknown)
   | Resumed _ | Original_replaced _ -> fail "an unreleased Cut must remain unknown at its owner");
  check bool "no declaration release was stored" false (cut_release_observed fixture)
let require_cut_release fixture (cut:Owner.retained) wakes =
  let positions=progress fixture and posts=F.post_count fixture.server in
  (match run_worker_waking fixture wakes with
   | Ok (Consumer.Memory_not_committed _) -> ()
   | Ok (Nothing_to_read | Pending _ | Baseline_advanced _ | Progress_advanced _ | Official_advanced _) -> fail "the replaced Cut must retain its ending first"
   | Error error -> fail (Consumer.error_to_string error));
  let record,_=only_original fixture in
  check string "the ending stays on its original" cut.Owner.request_id record.Owner.request_id;
  check bool "the strict durable Cut ending is observable" true (cut_release_observed fixture);
  check bool "ending alone moves no read position" true (progress fixture=positions);
  check int "ending alone makes no provider call" posts (F.post_count fixture.server);
  no_memory fixture
let test_a_replaced_declaration_settles_a_cut_original_and_its_range_is_read_whole_again () =
  with_fixture (fun ~sw fixture ->
    let cut,_=a_replaced_declaration_cuts_the_running_original fixture ~sw in
    let posts=F.post_count fixture.server and wakes=ref 0 in
    require_cut_release fixture cut wakes;
    check int "the newly retained ending asks for the next pass" 1 !wakes;
    assert_pending (run_worker_waking fixture wakes);
    check bool "the ended original moves to the settled archive" true
      (settled_on fixture ~date:(day_of cut.request_id) cut);
    let fresh,fresh_capture=only_original fixture in
    check bool "a new original read the range" true (fresh.Owner.request_id<>cut.request_id);
    check bool "the complete unread range is preserved" true
      (Source.extent (Capture.source fresh_capture)=Keeper_librarian_range.All_unread);
    check bool "the next passes commit the range" true (advanced (run_until_done ~wakes fixture));
    check bool "a new provider call judged the range" true (F.post_count fixture.server>posts);
    check (list string) "the new original's answer reached Memory"
      ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir)))
let test_a_cut_original_waits_when_its_declaration_is_put_back () =
  with_fixture (fun ~sw fixture ->
    let cut,_=a_replaced_declaration_cuts_the_running_original fixture ~sw in
    replace_actual_worker_configuration fixture ~sw (fixture.declaration true);
    let posts=F.post_count fixture.server and wakes=ref 0 in
    require_cut_wait fixture cut wakes;
    require_cut_wait fixture cut wakes;
    check int "the unchanged declaration grants no replacement wake" 0 !wakes;
    check bool "the owner does not archive an unreleased Cut" false
      (settled_on fixture ~date:(day_of cut.request_id) cut);
    check int "the owner does not send the original again" posts (F.post_count fixture.server))
(* Once stored, the ending is historical authority. Rollback cannot revive
   the old unknown request or replace that ending with today's configuration. *)
let test_a_cut_original_keeps_its_ending_when_its_declaration_is_put_back_before_it_is_moved () =
  with_fixture (fun ~sw fixture ->
    let cut,_=a_replaced_declaration_cuts_the_running_original fixture ~sw in
    let wakes=ref 0 in
    require_cut_release fixture cut wakes;
    replace_actual_worker_configuration fixture ~sw (fixture.declaration true);
    check bool "rollback retains the actual original-bound ending" true (cut_release_observed fixture);
    check bool "ordinary passes complete the preserved range after rollback" true
      (advanced (run_until_done ~wakes fixture));
    check bool "rollback cannot revive the old original" true
      (settled_on fixture ~date:(day_of cut.request_id) cut);
    check (list string) "only the new original answer is in Memory"
      ["Knowledge from original completed history"] (io (fun () -> claims fixture.keepers_dir)))
let test_a_cut_original_waits_while_the_destination_of_now_is_unknown () =
  with_fixture (fun ~sw fixture ->
    let cut,_=a_replaced_declaration_cuts_the_running_original fixture ~sw in
    io (fun () -> write fixture.source (replaced_declaration ~enabled:false fixture));reconcile fixture;
    let wakes=ref 0 in
    require_cut_wait fixture cut wakes;
    require_cut_wait fixture cut wakes;
    check int "an unavailable destination grants no replacement wake" 0 !wakes;
    check bool "no release archives the original" false (settled_on fixture ~date:(day_of cut.request_id) cut);
    attach_actual_worker_configuration fixture ~sw (replaced_declaration fixture);
    require_cut_release fixture cut wakes;
    check bool "ready replacement allows ordinary passes to commit" true
      (advanced (run_until_done ~wakes fixture));
    check bool "the ended original moves to the settled archive" true
      (settled_on fixture ~date:(day_of cut.request_id) cut))
(* A pass reads and sends its range, and the provider's refusal reaches the
   next pass. *)
let provider_refuses_the_read fixture =
  let before= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  await_delivery fixture ~after:before;
  ended_by_one_refusal (run_worker fixture)
(* The first read takes everything unread. Once the host's refusal has reached
   the pass, it narrows the next read to the one turn by itself. *)
let provider_refuses_the_read_twice fixture response =
  fixture.set_response (fun _ -> response);
  provider_refuses_the_read fixture;
  provider_refuses_the_read fixture
let positions_of steps =
  List.map (fun (_,(header:Keeper_librarian_floor_step_request.header)) -> header.position) steps
(* The gate records of the steps' judgments: one for each step the chain asked. *)
let step_gate_record_count fixture request =
  Keeper_librarian_floor_step_gate.Inventory.read ~store:fixture.store ~owner:(Capture.physical_owner request)
  |> get |> Keeper_librarian_floor_step_gate.Inventory.record_count
let nothing_left fixture request =
  check int "no retained step is left" 0 (List.length (steps_of fixture request));
  check int "and no gate record of a step" 0 (step_gate_record_count fixture request);
  check int "and no original" 0 (List.length (observed_originals fixture))
let test_the_pass_reads_a_refused_turn_message_by_message kind tags () = with_fixture ~history_kind:kind (fun ~sw:_ fixture ->
  provider_refuses_the_read_twice fixture size_refusal;
  let _,request=only_original fixture in
  check bool "the refusal that reached the pass narrowed its next read to one turn" true
    (Source.extent (Capture.source request)=Keeper_librarian_range.To_first_cut_point);
  check bool "so the provider's refusal of that turn made a candidate" true (Option.is_some (candidate_of fixture));
  let posts=F.post_count fixture.server in
  fixture.set_step_response (answering_steps tags);
  check bool "the next passes read it message by message and move the position" true
    (advanced (run_until_done fixture));
  check (list string) "Memory holds a claim of each message" ["claim number 1";"claim number 2"]
    (io (fun () -> claims fixture.keepers_dir));
  check int "each message asked the provider once" 2 (F.post_count fixture.server-posts);
  check bool "the published range is no candidate" true (Option.is_none (candidate_of fixture));
  (match run_worker fixture with
   | Ok Consumer.Nothing_to_read -> ()
   | Ok (Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending _) ->
     fail "the published range was read again"
   | Error error -> fail (Consumer.error_to_string error));
  nothing_left fixture request)
(* The two reads cover the same turn, but only the narrowed one is the range the
   candidate read. *)
let test_a_candidate_covers_only_the_range_it_read () = with_fixture (fun ~sw:_ fixture ->
  fixture.set_response (fun _ -> size_refusal);
  provider_refuses_the_read fixture;
  let _,wide=only_original fixture in
  provider_refuses_the_read fixture;
  let candidate,narrowed=candidate_and_request fixture in
  check bool "the first read took everything unread" true
    (Source.extent (Capture.source wide)=Keeper_librarian_range.All_unread);
  check bool "the candidate covers the range of its own original" true
    (Descent.covers candidate (Capture.source narrowed));
  check bool "and not a read of everything unread" false (Descent.covers candidate (Capture.source wide)))
(* A pass takes the count of boundary lines when it selects, and the log has
   grown since the original's pass: the count says when a range was read, not
   which range it is. *)
let append_a_later_turn fixture =
  let later=selected_messages @ [message "A turn after the refused one";reply "Its answer"] in
  save_checkpoint fixture.config ~trace_id later 3;
  io (fun () -> append_boundary fixture.config ~turn:3 ~time:(Time_compat.now ())
    ~history_at_start:(Boundary.history_at_start_of_messages selected_messages) later)
(* The range the next pass selects, without committing it. *)
let next_selected_range fixture =
  let selected=ref None in
  (match memory_action fixture (fun () ->
     Consumer.consume_one ~config:fixture.config ~keeper_name ~commit:(fun source ->
       selected:=Some source;Consumer.Memory_pending (Masc.Keeper_librarian_pending.Publication { request_id = "fixture-original"; detail = "publication is unfinished" }))) with
   | Ok (Consumer.Pending _) -> ()
   | Ok (Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _) ->
     fail "the pass must stop at the commit that asked to wait"
   | Error error -> fail (Consumer.error_to_string error));
  match !selected with
  | Some source -> source
  | None -> fail "the pass selected no range"
let atom_range source = match Source.range_id source with
  | Some range -> range
  | None -> fail "the range is not an atom range"
let test_a_candidate_covers_its_range_after_the_log_grew () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_the_read_twice fixture size_refusal;
  let candidate,narrowed=candidate_and_request fixture in
  append_a_later_turn fixture;
  let source=next_selected_range fixture in
  check bool "the log grew since the original's pass" true
    ((atom_range source).Current.boundary_lines_seen>(atom_range (Capture.source narrowed)).Current.boundary_lines_seen);
  check bool "yet the candidate covers the range the pass selected" true (Descent.covers candidate source))
(* A later line that states the same position moves the line that witnesses the
   range's end. It is the same range: the atoms and their digest did not change.
   The test writes that line itself; a real turn that restates an atom position
   was not shown to exist. *)
let test_a_candidate_covers_its_range_when_a_later_turn_end_states_the_same_position () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_the_read_twice fixture size_refusal;
  let candidate,narrowed=candidate_and_request fixture in
  io (fun () -> append_boundary fixture.config ~turn:3 ~time:(Time_compat.now ())
    ~history_at_start:(Boundary.history_at_start_of_messages selected_messages) selected_messages);
  let source=next_selected_range fixture in
  check bool "the witness line of the range's end moved to the later turn end" true
    ((atom_range source).Current.end_boundary_line>(atom_range (Capture.source narrowed)).Current.end_boundary_line);
  check bool "yet the candidate covers the range the pass selected" true (Descent.covers candidate source))
let test_a_turn_that_ended_after_the_original_does_not_stop_the_pass () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_the_read_twice fixture size_refusal;
  append_a_later_turn fixture;
  let posts=F.post_count fixture.server in
  fixture.set_step_response (answering_steps ["Original question to retain";"Original completed answer"]);
  check bool "the pass reads the refused turn message by message and moves the position" true
    (advanced (run_until_done fixture));
  check int "each message of that turn asked the provider once, the later turn none" 2
    (F.post_count fixture.server-posts);
  check (list string) "Memory holds a claim of each message" ["claim number 1";"claim number 2"]
    (io (fun () -> claims fixture.keepers_dir)))
(* A restart loses the consumer's mark that narrows its read. The candidate
   still says the range is too wide, so the pass reads one turn all the same. *)
let test_a_message_the_frame_refused_is_published_as_a_hole () = with_fixture (fun ~sw:_ fixture ->
  let huge=message (filler "huge-message" oversized_turn_bytes) in
  add_unread_turn ~external_admission:true fixture [huge;reply "Oversized answer"];
  frame_refuses_the_turn_twice fixture;
  let _,request=only_original fixture in
  Consumer.For_testing.reset_process_state ();
  let posts=F.post_count fixture.server in
  fixture.set_step_response (answering_steps ["huge-message";"Oversized answer"]);
  check bool "the pass reads the turn and moves the position" true (advanced (run_until_done fixture));
  check int "only the message the frame accepts reached the provider" 1 (F.post_count fixture.server-posts);
  check (list string) "Memory holds the earlier turn's claim and the readable message's"
    ["Knowledge from original completed history";"claim number 2"] (io (fun () -> claims fixture.keepers_dir));
  (match io (fun () -> Current.committed_unread_messages ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get) with
   | [hole] ->
     let digest=match hole.source with
       | Keeper_librarian_unread.Atom {message_sha256;_} | Official_turn {message_sha256;_} -> message_sha256 in
     check string "the unread ledger holds the message the frame refused" (Keeper_librarian_unread.message_digest huge) digest
   | [] | _::_::_ -> fail "the refused message is the one unread hole");
  (match run_worker fixture with
   | Ok Consumer.Nothing_to_read -> ()
   | Ok (Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending _) ->
     fail "the published range was read again"
   | Error error -> fail (Consumer.error_to_string error));
  nothing_left fixture request)
let test_a_refusal_that_shows_nothing_about_reading_less_is_read_again_as_before () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_the_read_twice fixture plain_refusal;
  let refused,request=only_original fixture in
  check bool "the refused turn is no candidate" true (Option.is_none (candidate_of fixture));
  let posts=F.post_count fixture.server and before= !(fixture.deliveries) in
  assert_pending (run_worker fixture);
  await_delivery fixture ~after:before;
  let again,_=only_original fixture in
  check bool "the pass settled it and captured a new original of the turn" true
    (again.Owner.request_id<>refused.Owner.request_id);
  check int "which asked the provider as an original" 1 (F.post_count fixture.server-posts);
  check int "and retained no step" 0 (List.length (steps_of fixture request)))
let test_a_step_the_host_refused_is_asked_again_under_a_new_id () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_the_read_twice fixture size_refusal;
  let _,request=only_original fixture in
  let refused_once=ref false in
  let tags=["Original question to retain";"Original completed answer"] in
  fixture.set_step_response (fun body ->
    if contains body "Original completed answer" && not !refused_once then (refused_once:=true;plain_refusal)
    else answering_steps tags body);
  let posts=F.post_count fixture.server in
  (match run_until_done fixture with
   | Ok (Consumer.Memory_not_committed [_]) -> ()
   | Ok (Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Pending _
        | Memory_not_committed ([] | _::_::_)) -> fail "the refused step must end the pass in one refusal report"
   | Error error -> fail (Consumer.error_to_string error));
  check (list int) "the step before it stays" [0] (positions_of (steps_of fixture request));
  check (list string) "nothing reached Memory" [] (io (fun () -> claims fixture.keepers_dir));
  check bool "the next passes ask that position again and finish" true (advanced (run_until_done fixture));
  check int "the first message asked once and the refused one twice" 3 (F.post_count fixture.server-posts);
  check (list string) "Memory holds a claim of each message" ["claim number 1";"claim number 2"]
    (io (fun () -> claims fixture.keepers_dir));
  (match run_worker fixture with
   | Ok Consumer.Nothing_to_read -> ()
   | Ok (Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending _) ->
     fail "the published range was read again"
   | Error error -> fail (Consumer.error_to_string error));
  nothing_left fixture request)
let test_a_pass_starts_the_chain_again_when_memory_changed_under_it () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_the_read_twice fixture size_refusal;
  let _,request=only_original fixture in
  let posts=F.post_count fixture.server and wakes=ref 0 in
  fixture.set_step_response (answering_steps ["Original question to retain";"Original completed answer"]);
  let before= !(fixture.deliveries) in
  assert_pending (run_worker_waking fixture wakes);
  await_delivery fixture ~after:before;
  let independent=Types.observed ~claim:"Independent explicit write" ~category:Types.Fact
    ~now:(Time_compat.now ()) ~origin:{kind=Types.Authored;trace_id="concurrent-floor-writer"} in
  io (fun () -> Current.upsert_fact ~pass:Keeper_memory_commit_pass.Keeper_write ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
    ~now:(Time_compat.now ()) ~source:{kind=Current.Explicit_write;trace_id="concurrent-floor-writer"}
    independent |> Result.map_error Current.upsert_error_to_string |> get |> ignore);
  check bool "the chain that began on the old Memory is dropped, and a new one finishes" true
    (advanced (run_until_done ~wakes fixture));
  check int "dropping it asked the lane for one more pass" 1 !wakes;
  check int "the obsolete chain asks no further message before the fresh chain" 3 (F.post_count fixture.server-posts);
  check (list string) "Memory holds the independent write and the second chain's claims"
    ["Independent explicit write";"claim number 1";"claim number 2"] (io (fun () -> claims fixture.keepers_dir));
  (match run_worker fixture with
   | Ok Consumer.Nothing_to_read -> ()
   | Ok (Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending _) ->
     fail "the published range was read again"
   | Error error -> fail (Consumer.error_to_string error));
  nothing_left fixture request)
(* A pass that published and stopped before the consumer moved the position:
   the range is no candidate any more, so the next pass settles its steps and
   original, and the consumer finds the range committed. *)
let test_the_steps_of_a_published_range_are_settled_by_the_next_pass () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  fixture.set_step_response (answering_steps ["Original question to retain";"Original completed answer"]);
  let fin=finished (descend fixture candidate) in
  published (publish fixture candidate fin);
  check int "the chain's steps are retained" 2 (List.length (steps_of fixture request));
  let posts=F.post_count fixture.server in
  check bool "the next pass moves the position" true (advanced (run_worker fixture));
  check int "without asking the provider" 0 (F.post_count fixture.server-posts);
  check (list string) "and writes nothing more" ["claim number 1";"claim number 2"]
    (io (fun () -> claims fixture.keepers_dir));
  nothing_left fixture request)

let test_floor_cleanup_loads_only_the_steps_it_settles () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  fixture.set_step_response (answering_steps ["Original question to retain";"Original completed answer"]);
  ignore (finished (descend fixture candidate));
  let owner=Capture.physical_owner request in
  let first,_=first_step fixture request in
  let body=Filename.concat (Store.root fixture.store)
    (Store.tool_request_body_path ~scope:first.scope ~request_digest:first.request_digest) in
  let posts=F.post_count fixture.server and positions=progress fixture in
  io (fun () -> write body "damaged floor capture");
  check int "cleanup leaves all steps of a live candidate alone" 0
    (memory_action fixture (fun () -> Cleanup.cleanup ~store:fixture.store ~owner ~candidates:[candidate] ~settled:[]) |> get);
  check int "and retains both of its gate journals" 2 (step_gate_record_count fixture request);
  check int "settling the other position reads and moves only that step and its gate" 2
    (memory_action fixture (fun () -> Cleanup.settle_step ~store:fixture.store ~owner candidate ~position:1) |> get);
  check int "the damaged step's gate remains live" 1 (step_gate_record_count fixture request);
  (match memory_action fixture (fun () -> Cleanup.settle_chain ~store:fixture.store ~owner candidate) with
   | Error detail -> check bool "selecting the damaged body refuses settlement" true (contains detail "body does not match")
   | Ok _ -> fail "cleanup settled a selected damaged body");
  let remaining=Step_owner.discover ~store:fixture.store ~owner |> Result.map_error Step_owner.error_to_string |> get in
  check (list string) "the selected damaged original remains retained" [first.request_id]
    (List.map (fun (record,_) -> Owner.Record.request_id record) remaining);
  check int "cleanup never calls the provider" posts (F.post_count fixture.server);
  check bool "cleanup advances no source position" true (progress fixture=positions);
  check (list string) "cleanup writes no Memory" [] (io (fun () -> claims fixture.keepers_dir)))
(* The chain resumes from the steps at positions 0 to k and refuses any other
   leftover, so a settle that stops part way must leave such a prefix. *)
let four_messages=[message "Third question";reply "Third answer";message "Fourth question";reply "Fourth answer"]
let four_tags=["Third question";"Third answer";"Fourth question";"Fourth answer"]
let lowest_position_first steps =
  List.sort (fun (_,(a:Keeper_librarian_floor_step_request.header)) (_,(b:Keeper_librarian_floor_step_request.header)) ->
    Int.compare a.position b.position) steps
let sorted_positions fixture request = List.sort Int.compare (positions_of (steps_of fixture request))
(* The move of a step record, which stops the settle after [moves] of them. *)
let settle_stopping_after ~moves =
  let moved=ref [] in
  let settle ~store ~date (record:Owner.retained) =
    if List.length !moved>=moves then Error "injected stop" else begin
      moved:=record.request_id :: !moved;
      Owner.settle ~store ~date (Owner.listed record) |> Result.map_error Owner.settle_error_to_string
    end in
  settle,(fun () -> List.rev !moved)
let test_a_settle_that_stops_part_way_leaves_the_steps_the_chain_resumes_from () = with_fixture (fun ~sw:_ fixture ->
  add_unread_turn fixture four_messages;
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  fixture.set_step_response (answering_steps four_tags);
  ignore (finished (descend fixture candidate));
  let owner=Capture.physical_owner request in
  let given=lowest_position_first (steps_of fixture request) in
  check (list int) "the chain has four steps" [0;1;2;3] (positions_of given);
  check int "and a gate record of each step's judgment" 4 (step_gate_record_count fixture request);
  let position_of_id=List.map (fun ((record:Owner.retained),(header:Keeper_librarian_floor_step_request.header)) ->
    record.request_id,header.position) given in
  let settle,moved=settle_stopping_after ~moves:2 in
  (match Cleanup.For_testing.settle_steps_with ~settle ~store:fixture.store ~owner given with
   | Error _ -> ()
   | Ok _ -> fail "the injected stop must end the settle");
  check (list int) "the settle took the highest positions first, though it was given the lowest first" [3;2]
    (List.map (fun id -> List.assoc id position_of_id) (moved ()));
  check (list int) "so the steps left are the first two" [0;1] (sorted_positions fixture request);
  let posts=F.post_count fixture.server in
  let resumed=finished (descend fixture candidate) in
  check (list string) "the chain resumes from them and decides every message"
    ["claim number 1";"claim number 2";"claim number 3";"claim number 4"] (program_claims resumed.program);
  check int "asking the provider only for the two messages it lost" 2 (F.post_count fixture.server-posts);
  check (list int) "and has four steps again" [0;1;2;3] (sorted_positions fixture request);
  (* The order matters because of what the chain does with any other leftover:
     without its first step it starts again, and the steps after it name a step
     it never asked. *)
  (match Cleanup.settle_step ~store:fixture.store ~owner candidate ~position:0 with
   | Ok 2 -> ()
   | Ok moved -> failf "the first step and its gate record are two records, not %d" moved
   | Error detail -> fail detail);
  check int "the gate record of the settled step moved with it" 3 (step_gate_record_count fixture request);
  match descend fixture candidate with
  | Error _ -> ()
  | Ok _ -> fail "steps that skip the first position must be refused")
let test_a_stale_prefix_left_by_failed_cleanup_restarts_from_current_memory () = with_fixture (fun ~sw fixture ->
  add_unread_turn fixture four_messages;
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  fixture.set_step_response (answering_steps four_tags);
  let fin=finished (descend fixture candidate) in
  let independent=Types.observed ~claim:"Independent explicit write" ~category:Types.Fact
    ~now:(Time_compat.now ()) ~origin:{kind=Types.Authored;trace_id="partial-floor-cleanup"} in
  io (fun () -> Current.upsert_fact ~pass:Keeper_memory_commit_pass.Keeper_write ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
    ~now:(Time_compat.now ()) ~source:{kind=Current.Explicit_write;trace_id="partial-floor-cleanup"}
    independent |> Result.map_error Current.upsert_error_to_string |> get |> ignore);
  (match publish fixture candidate fin with
   | Ok Publish.Superseded -> ()
   | Ok Publish.Published -> fail "the old program was published over different facts"
   | Error detail -> fail detail);
  let owner=Capture.physical_owner request in
  let blocked,_=List.find (fun (_,(header:Keeper_librarian_floor_step_request.header)) -> header.position=1)
    (steps_of fixture request) in
  let date=Keeper_librarian_floor_step_request.minted_on blocked.Owner.request_id |> get in
  let blocker=Filename.concat (Store.root fixture.store)
    (Store.tool_request_archive_record_path ~scope:blocked.scope ~date ~request_id:blocked.request_id) in
  io (fun () -> Fs_compat.mkdir_p blocker);
  Eio.Switch.on_release sw (fun () -> io (fun () ->
    if Sys.file_exists blocker && Sys.is_directory blocker then Unix.rmdir blocker));
  (match memory_action fixture (fun () -> Cleanup.settle_chain ~store:fixture.store ~owner candidate) with
   | Error _ -> ()
   | Ok _ -> fail "a record cannot be renamed onto the blocker directory");
  check (list int) "the real failed rename leaves the old prefix" [0;1] (sorted_positions fixture request);
  let old_basis_refusals=ref 0 in
  fixture.set_step_response (fun body ->
    if contains body independent.claim then answering_steps four_tags body
    else (incr old_basis_refusals;plain_refusal));
  let posts=F.post_count fixture.server and wakes=ref 0 in
  (match run_worker_waking fixture wakes with
   | Error _ -> ()
   | Ok _ -> fail "the unfinished cleanup was bypassed to resume its old tail");
  check int "an unavailable cleanup asks no model" posts (F.post_count fixture.server);
  check (list int) "and preserves the prefix for another cleanup" [0;1] (sorted_positions fixture request);
  io (fun () -> Unix.rmdir blocker);
  check bool "the next passes finish a chain over current facts" true (advanced (run_until_done ~wakes fixture));
  check int "no tail was asked from obsolete facts" 0 !old_basis_refusals;
  check bool "the fresh first step includes the independent write" true
    (List.mem independent.claim (first_step_facts fixture request));
  check int "only the fresh four message steps reached the model" 4 (F.post_count fixture.server-posts);
  check int "successful cleanup requested the fresh pass" 1 !wakes)

let test_settling_a_position_no_step_holds_is_an_error () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  fixture.set_step_response (answering_steps ["Original question to retain";"Original completed answer"]);
  ignore (finished (descend fixture candidate));
  (match Cleanup.settle_step ~store:fixture.store ~owner:(Capture.physical_owner request) candidate ~position:5 with
   | Error detail -> check bool "the error names the position" true (contains detail "position 5")
   | Ok moved -> failf "%d records settled for a position no step holds" moved);
  check (list int) "and no step moved" [0;1] (sorted_positions fixture request))

(* Reconstruct a pre-policy question from its captured parts. This deliberately
   uses structural restoration, not the fresh preparation API that now refuses
   it. The source, original store, worker and host receipts remain real. *)
let with_legacy_omitted_original fixture f =
  let previous=(Prompt_registry.resolve_prompt Prompt_names.librarian).override_value in
  Fun.protect ~finally:(fun () -> match previous with
    | None -> Prompt_registry.clear_prompt_override Prompt_names.librarian
    | Some value -> Prompt_registry.set_override Prompt_names.librarian value |> get) (fun () ->
    let captured=ref None in
    assert_pending (memory_action fixture (fun () -> Consumer.consume_one ~config:fixture.config ~keeper_name
      ~commit:(fun source -> captured:=Some source;Consumer.Memory_pending (Masc.Keeper_librarian_pending.Publication { request_id = "fixture-original"; detail = "publication is unfinished" }))));
    let source=Option.get !captured in
    let input=Source.input source in
    check bool "legacy original has observations the old question could omit" true
      (input.counterpart_observations<>[]);
    Prompt_registry.set_override Prompt_names.librarian "Legacy history question without observation substitution" |> get;
    let module R=Keeper_librarian_runtime in
    let seed=R.prepare_durable ~source_lines:[] ~now:(Time_compat.now ()) {input with counterpart_observations=[]} |> get in
    let preparation=R.restore_durable_preparation ~source_input:input ~parsing_now:seed.parsing_now
      ~policy:seed.policy ~rule_prompt:seed.rule_prompt ~turn_prompts:seed.turn_prompts ~prompt:seed.prompt ~output_schema:seed.output_schema |> get in
    R.validate_durable_preparation preparation |> get;
    let original,request=memory_action fixture (fun () ->
      let owner=io (fun () ->
        (* Normal durable capture obtains the program anchor before observing
           the physical owner, creating the empty Memory epoch if needed. *)
        let _=Current.capture_program_anchor ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get in
        Capture.observe_owner ~base_path:fixture.base_path
          ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name) |> get in
      Keeper_librarian_durable_edge.with_destination ~config:fixture.config ~reserved:[] (fun destination ->
        let request=io (fun () -> Capture.create ~request_id:(Capture.fresh_request_id owner)
          ~owner ~destination ~source ~preparation ()) |> get in
        let original=Durable_owner.retain ~store:fixture.store request
          |> Result.map_error Durable_owner.error_to_string |> get in
        Ok (original,request)) |> get) in
    f original request)
let assert_omitted_original_blocked = function
  | Error error ->
    check bool "the original remains a blocked publication" true (Consumer.publication_unfinished error);
    check bool "blocked reason names the frozen omitted input" true
      (Astring.String.is_infix ~affix:"counterpart_observations" (Consumer.error_to_string error))
  | Ok _ -> fail "an unsafe retained question reached a fresh effect"
let advance_legacy fixture original event =
  io (fun () -> match Owner.advance ~store:fixture.store ~expected:original ~event with
    | Ok (Owner.Stored record | Already_stored record) -> record
    | Ok (Unconfirmed detail) -> fail detail
    | Error error -> fail (Owner.update_error_to_string error))
let test_legacy_omitted_original_refuses_admission_but_prepares_safe_continuation () =
  with_fixture (fun ~sw:_ fixture -> with_legacy_omitted_original fixture (fun original request ->
    let source_json=Capture.to_json request and events=Progress.to_json original.Owner.progress in
    let cursor ()=io (fun () -> Keeper_external_read_cursor.observe
      ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get)
      |> Keeper_external_read_cursor.observation_to_json in
    let cursor_before=cursor () and position_before=progress fixture in
    assert_omitted_original_blocked (run_worker fixture);
    let held,restored=only_original fixture in
    check json "rejected admission leaves the original progress unchanged" events (Progress.to_json held.progress);
    check json "rejected admission retains the exact old question" source_json (Capture.to_json restored);
    let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
      |> Result.map_error Lane_addon_manifest.error_to_string |> get in
    let authorization=Server_lane_addon_exact.authorize_request ~base_path:fixture.base_path
      ~store:fixture.store ~declaration_id:"librarian" ~package (Capture.request request |> get)
      |> Result.map_error (function Exact.Unowned {reason} -> reason | Undecided {detail} -> detail) |> get in
    (match authorization.before_dispatch () |> Result.map_error Exact.dispatch_veto_detail with
     | Error detail -> check bool "actual host dispatch names the omitted input" true
         (Astring.String.is_infix ~affix:"counterpart_observations" detail)
     | Ok () -> fail "actual host dispatch admitted an omitted retained question");
    Prompt_registry.clear_prompt_override Prompt_names.librarian;
    assert_omitted_original_blocked (run_worker fixture);
    let dispatched=advance_legacy fixture held Progress.Dispatch_intended in
    assert_pending (run_worker fixture);
    (* Observe the immutable original and one confirmed safe continuation
       before driving it; the existing completion checks below then run it. *)
    let retained ()=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
      ~request_id:original.request_id |> owned |> Option.get) in
    let recovery ()=io (fun () -> Resolution_work.read ~config:fixture.config ~keeper_name
      ~request_id:dispatched.request_id |> Result.map_error Resolution_intent.error_to_string |> get) in
    let prepared=recovery () in
    let child_id=match prepared.intents with
      | [{Resolution_intent.actor="librarian";phase=Child_confirmed child;_}] -> child.request_id
      | _ -> fail "the absent original did not retain one automatic continuation" in
    check bool "the continuation has a durable fence and no Memory completion" true
      (Option.is_some prepared.fence && prepared.completion=Resolution_work.Not_observed);
    check bool "the continuation has its own ID" true (child_id<>dispatched.request_id);
    let captures=observed_originals fixture in
    check (list string) "only the exact original and its confirmed child are retained"
      (List.sort String.compare [dispatched.request_id;child_id])
      (List.map (fun ((record:Owner.retained),_) -> record.request_id) captures |> List.sort String.compare);
    let by_id request_id=match List.filter (fun ((record:Owner.retained),_) ->
      record.request_id=request_id) captures with
      | [capture] -> capture
      | [] | _::_ -> fail "expected one strictly restored original for the exact request ID" in
    let pending,restored=by_id dispatched.request_id in
    let _,child=by_id child_id in
    check string "unknown delivery keeps the old ID" dispatched.request_id pending.Owner.request_id;
    check json "pending observation never rerenders the question" source_json (Capture.to_json restored);
    check bool "the child binds its exact original predecessor" true
      (Capture.predecessor child=Some {Capture.request_id=dispatched.request_id;
        request_digest=dispatched.request_digest});
    io (fun () -> Keeper_librarian_history_resolution_lineage.confirm_predecessor
      ~store:fixture.store ~require_confirmed:true child |> get);
    check string "the new question retains the exact original source basis"
      (Capture.source_basis_digest request |> get) (Capture.source_basis_digest child |> get);
    check bool "the frozen original still fails its input guard" true
      (Result.is_error (Keeper_librarian_runtime.require_counterpart_template (Capture.preparation restored)));
    Keeper_librarian_runtime.require_counterpart_template (Capture.preparation child) |> get;
    check bool "the fresh question keeps every original counterpart observation" true
      ((Source.input (Capture.source child)).counterpart_observations=
       (Source.input (Capture.source request)).counterpart_observations);
    check json "no external preparation is ACKed" cursor_before (cursor ());
    check bool "no read position advances" true (progress fixture=position_before);
    check int "admission, provider guard and pending wakes dispatch no model" 0 (F.post_count fixture.server);
    no_memory fixture;
    drive_advanced fixture;
    check int "only the safe new question reaches the provider" 1 (F.post_count fixture.server);
    check bool "the new question reaches Memory and advances the atom position" true
      ((recovery ()).completion=Resolution_work.Memory_committed {request_id=child_id}
        && progress fixture<>position_before);
    let through=Keeper_librarian_input_sources.external_through (Source.counterparts (Capture.source request)) in
    let acknowledged=io (fun () -> Keeper_external_read_cursor.observe
      ~runtime_keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_name |> get) in
    check bool "the safe new question acknowledges the original counterpart frontier" true
      (Keeper_external_read_cursor.observation_matches_preparation acknowledged
        ~after:through ~through ~atom:None ~official:None);
    check json "recovery leaves the blocked original question unchanged" source_json (retained ()).request))
(* Seed one actual host answer using the pre-policy authority boundary. This
   test-only dispatcher removes the new guard only while modeling that earlier
   HTTP call; original binding/schema/domain validation and receipts stay real. *)
let seed_legacy_original_answer fixture original request =
  let current_authorize=Server_lane_addon_exact.authorize_request ~base_path:fixture.base_path in
  let runner=Server_lane_addon_exact.runner ~base_path:fixture.base_path in
  let old_authorize ~store ~declaration_id ~package request =
    Result.map (fun (authority:Exact.request_authorization) ->
      {authority with before_dispatch=(fun () -> Ok ())})
      (current_authorize ~store ~declaration_id ~package request) in
  Fun.protect ~finally:(fun () -> Runtime.register_exact_runner ~authorize_request:current_authorize runner) (fun () ->
    Runtime.register_exact_runner ~authorize_request:old_authorize runner;
    let original=advance_legacy fixture original Progress.Dispatch_intended in
    let destination=Capture.destination request in
    let before= !(fixture.deliveries) in
    Runtime.call_captured_tool_request ~config:fixture.config ~reserved:[] ~export:(runtime_export fixture)
      ~access:Lane_addon_sources.Operator_configuration ~installation_id:destination.installation_id
      ~package_id:destination.package_id ~tool:destination.tool ~configuration_revision:destination.configuration_revision
      ~original:(Owner.listed original) ~prepare_arguments:(fun ~max_reply_bytes ->
        Keeper_librarian_worker_request.prepare ~max_reply_bytes ~request_id:original.request_id
          ~tool:destination.tool ~arguments:(`Assoc ["kind",`String "submit";
            "request",Exact.request_to_json (Capture.request request |> get)]))
      |> Result.map_error (fun _ -> "legacy fixture submit was refused before its modeled old effect") |> get |> ignore;
    await_delivery fixture ~after:before)
let test_legacy_omitted_answer_blocks_judged_and_commit_publication () =
  with_fixture (fun ~sw:_ fixture -> with_legacy_omitted_original fixture (fun original request ->
    let source_json=Capture.to_json request in
    seed_legacy_original_answer fixture original request;
    check int "the fixture retained one real pre-policy host request" 1 (F.post_count fixture.server);
    assert_omitted_original_blocked (run_worker fixture);
    let judged,restored=only_original fixture in
    check bool "actual host answer remains a judged original" true
      (match Progress.phase judged.Owner.progress with Judged _ -> true
       | Captured | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _ | Finished _
       | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
    check json "new publication refuses without rewriting the actual old question" source_json (Capture.to_json restored);
    let proposal=Capture.validate_proposal request (answer request)
      |> get in
    let direct=memory_action fixture (fun () -> Keeper_librarian_durable_commit.publish ~store:fixture.store
      ~config:fixture.config ~request ~original:judged ~proposal
      ~fresh_authority:(fun () -> fail "omitted original must stop before a new Gate effect")) in
    (match direct with
     | Error detail -> check bool "direct publication names its omitted input" true
         (Astring.String.is_infix ~affix:"counterpart_observations" detail)
     | Ok _ -> fail "direct publication admitted an omitted retained question");
    check int "no new Gate original is created" 0 (List.length (gate_records fixture request));
    let check_owner_phase original =
      let result=memory_action fixture (fun () -> Durable_owner.resume ~store:fixture.store ~config:fixture.config
        ~reserved:[] ~original:(Durable_owner.Read (original,request))
        ~wake:(fun () -> fail "unsafe publication cannot wake completion")
        ~call:(Keeper_librarian_durable_edge.call ~config:fixture.config ~reserved:[])
        ~publish:(fun ~original:_ ~request:_ ~proposal:_ -> fail "unsafe original cannot enter a publication callback")) in
      (match result with
       | Error error -> check bool "commit phase remains explicitly blocked" true
           (Astring.String.is_infix ~affix:"counterpart_observations" (Durable_owner.error_to_string error))
       | Ok _ -> fail "an unsafe retained commit phase reached an effect") in
    (* These legal journal transitions test the owner's effect boundary. They
       do not fabricate a Gate/Memory receipt or claim a completed commit. *)
    let committing=advance_legacy fixture judged (Progress.Commit_intended {before=`String "before";after=`String "after"}) in
    check_owner_phase committing;
    let unknown=advance_legacy fixture committing (Progress.Commit_uncertain (`Assoc ["detail",`String "legacy interrupted effect"])) in
    check_owner_phase unknown;
    check json "every blocked phase preserves the original source/question" source_json
      (Capture.to_json (snd (only_original fixture)));
    check int "publication never replays the original provider request" 1 (F.post_count fixture.server);
    no_memory fixture))

(* Capture an old full mixed input without retaining an executor for it. A
   different actual configured read then consumes a larger canonical prefix.
   Only afterwards retain a fresh request that reads the unchanged old input
   against the new Memory basis. No cursor or Memory result is fabricated. *)
let retain_old_mixed_input_after_a_later_actual_read fixture =
  let captured=ref None in
  (match memory_action fixture (fun () -> Consumer.consume_one ~config:fixture.config ~keeper_name
    ~commit:(fun source -> captured:=Some source;Consumer.Memory_replaced [])) with
   | Ok (Consumer.Memory_not_committed []) -> ()
   | Ok _ | Error _ -> fail "the fixture did not capture the original full mixed input");
  let original=Option.to_result ~none:"old mixed source is absent" !captured |> get in
  check bool "the old input has both immutable range components" true
    (Source.range_id original<>None && Source.official_range_id original<>None);
  let later_messages=selected_messages @ [message "Later canonical question";
    Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text "Later canonical answer"]] in
  let now=Time_compat.now () in
  save_checkpoint fixture.config ~trace_id later_messages 4;
  io (fun () ->
    append_boundary fixture.config ~turn:4 ~time:(now+.1.)
      ~history_at_start:(Boundary.history_at_start_of_messages selected_messages) later_messages;
    official_turn ~trace_id:"later-official-client" fixture.config ~turn:5 ~time:(now+.2.));
  drive_advanced fixture;
  let later_record,later_request=only_original fixture in
  check bool "the later Memory is from an actual finished configured read" true
    (match Progress.phase later_record.progress with Finished _ -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
  check bool "the larger actual read has real Memory receipts" true
    (io (fun () -> Commit.receipt_state later_request) |> get);
  (match run_worker fixture with
   | Ok Consumer.Nothing_to_read -> ()
   | Ok _ | Error _ -> fail "the larger completed original was not normally archived");
  check int "the completed larger read leaves no live original" 0 (List.length (observed_originals fixture));
  let old_atom=Option.get (Source.range_id original) and old_official=Option.get (Source.official_range_id original) in
  let atom,official,_=cut_source_positions fixture in
  check bool "actual atom and official cursors are beyond the old input" true
    (Option.exists (fun (p:Position.t) -> p.position.end_atom>old_atom.end_atom) atom
     && Option.exists (fun (p:Keeper_librarian_official_progress.t) ->
       p.boundary_line>List.fold_left (fun line (next,_) -> max line next)
         old_official.after_boundary_line old_official.turns) official);
  let record,request=memory_action fixture (fun () ->
    Keeper_librarian_durable_edge.with_destination ~config:fixture.config
      ~reserved:(Keeper_librarian_durable_edge.reserved ()) (fun destination ->
        let source,owner=io (fun () ->
          let anchor=Current.capture_program_anchor ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get in
          let snapshot=Current.program_anchor_snapshot anchor in
          let source=Source.with_current
            ~expected_revision:(Option.map (fun (snapshot:Current.t) -> snapshot.revision) snapshot)
            ~current:(Option.map (fun (snapshot:Current.t) ->
              ({Keeper_librarian.facts=snapshot.facts}:Keeper_librarian.current_selection)) snapshot) original
            |> Result.map_error Source.error_to_string |> get in
          let owner=Capture.observe_owner ~base_path:fixture.base_path ~keepers_dir:fixture.keepers_dir
            ~keeper_id:keeper_name |> get in
          source,owner) in
        let preparation=Keeper_librarian_runtime.prepare_durable ~now:(Time_compat.now ())
          ~source_lines:["Retained full mixed input, at a fresh Memory basis"] (Source.input source) |> get in
        let request=io (fun () -> Capture.create ~request_id:(Capture.fresh_request_id owner)
          ~owner ~destination ~source ~preparation ()) |> get in
        let record=Durable_owner.retain ~store:fixture.store request
          |> Result.map_error Durable_owner.error_to_string |> get in
        Ok (record,request))) |> get in
  check bool "the fresh question preserves every old historical source coordinate" true
    (Source.range_id (Capture.source request)=Source.range_id original
     && Source.official_range_id (Capture.source request)=Source.official_range_id original
     && Source.positions (Capture.source request)=Source.positions original
     && (Source.input (Capture.source request)).messages=(Source.input original).messages);
  check bool "a superset receipt does not prove the exact old ranges" false
    (io (fun () -> Commit.receipt_state request) |> get);
  record,request,later_messages

let answer_retained_old_input request =
  let fields=Yojson.Safe.Util.to_assoc (answer request) in
  `Assoc (("new_claims",`List [new_claim "Knowledge from newly reading the complete retained mixed input"])
    :: List.remove_assoc "new_claims" fields)

let test_an_old_mixed_answer_publishes_new_receipts_without_rewinding_later_frontiers ~lose_ack () =
  with_fixture ~history_kind:Mixed ~with_external_attention:false (fun ~sw:_ fixture ->
    let original,request,_=retain_old_mixed_input_after_a_later_actual_read fixture in
    let before=cut_source_positions fixture and memory=cut_memory_bytes fixture in
    let provider_ids=ref [] in
    fixture.set_response (fun actual ->
      check string "only the fresh old-input question reaches the provider"
        original.Owner.request_id (Capture.request_id actual);
      provider_ids:=Capture.request_id actual:: !provider_ids;
      `OK,F.openai_response (answer_retained_old_input actual));
    if lose_ack then (
      let deliveries= !(fixture.deliveries) in
      assert_pending (run_worker fixture);await_delivery fixture ~after:deliveries;
      let cursor_path=Keeper_external_read_cursor.path_for_keepers_dir
        ~keepers_dir:(Workspace.keepers_runtime_dir fixture.config) ~keeper_id:keeper_name in
      let original_cursor=io (fun () -> Fs_compat.load_file_opt cursor_path)
        |> Option.to_result ~none:"the configured read did not prepare its external cursor" |> get in
      Fun.protect ~finally:(fun () -> io (fun () -> write cursor_path original_cursor)) (fun () ->
        let result=resume_with_settlement_fault fixture (fun () ->
          io (fun () -> write cursor_path "{invalid cursor after actual old-range Memory publication}")) in
        (match result with
         | Ok (Durable_owner.Resumed (Publication_waiting _,_)) -> ()
         | Ok (Waited _ | Original_replaced _ | Resumed ((Refused _ | Finished _ | Basis_superseded _ | Ended_unadmitted _),_)) ->
           fail "the actual old-input publication must remain unfinished after its ACK read fails"
         | Error error -> fail (Durable_owner.error_to_string error));
        check bool "ACK recovery begins with both actual old-range Memory receipts" true
          (io (fun () -> Commit.receipt_state request) |> get));
      let committed=cut_memory_bytes fixture in
      check bool "a fresh scope recovers the same old-input question" true (advanced (run_worker fixture));
      check bool "ACK recovery repeats no Memory effect" true (cut_memory_bytes fixture=committed))
    else drive_advanced fixture;
    let finished,actual=only_original fixture in
    check string "the actual finished result keeps its retained question identity"
      original.request_id finished.Owner.request_id;
    check json "publication keeps the immutable original preparation" (Capture.to_json request) (Capture.to_json actual);
    check bool "only the new complete old-input read finishes" true
      (match Progress.phase finished.progress with Finished _ -> true
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
       | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
    check bool "both exact old-range receipts are newly committed" true
      (io (fun () -> Commit.receipt_state request) |> get);
    check bool "a fresh actual Memory publication occurred" false (cut_memory_bytes fixture=memory);
    check (list string) "both actual configured reads retain their distinct Memory facts"
      ["Knowledge from newly reading the complete retained mixed input";"Knowledge from original completed history"]
      (io (fun () -> claims fixture.keepers_dir));
    check bool "later atom, official and exact zero external ACK remain unchanged" true
      (cut_source_positions fixture=before);
    check (list string) "the old-input question is evaluated exactly once" [original.request_id] !provider_ids;
    check int "only the larger read and this new old-input read call the provider" 2 (F.post_count fixture.server))

type later_frontier_damage = Wrong_atom_digest | Wrong_atom_trace | Restarted_history
  | Nonofficial_frontier | Unreadable_frontier | Changed_original_prefix
let test_old_input_publication_refuses_unproved_later_frontiers damage () =
  with_fixture ~history_kind:Mixed ~with_external_attention:false (fun ~sw:_ fixture ->
    let original,request,later_messages=retain_old_mixed_input_after_a_later_actual_read fixture in
    fixture.set_response (fun actual -> `OK,F.openai_response (answer_retained_old_input actual));
    let deliveries= !(fixture.deliveries) in
    assert_pending (run_worker fixture);await_delivery fixture ~after:deliveries;
    let runtime_keepers_dir=Workspace.keepers_runtime_dir fixture.config in
    let atom,_,_=cut_source_positions fixture in
    let atom=Option.to_result ~none:"fixture lacks its actual later atom position" atom |> get in
    (match damage with
     | Wrong_atom_digest -> io (fun () ->
       Position.write ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
         {atom with position={atom.position with last_atom_digest=String.make 64 '0'}}
       |> Result.map_error Position.write_error_to_string |> get)
     | Wrong_atom_trace -> io (fun () ->
       Position.write ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
         {atom with position={atom.position with trace_id="foreign-later-trace"}}
       |> Result.map_error Position.write_error_to_string |> get)
     | Restarted_history -> io (fun () ->
       Boundary.append ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
         {Boundary.recorded_at=Time_compat.now ();event=History_restarted {trace_id}}
       |> Result.map_error Boundary.append_error_to_string |> get)
     | Nonofficial_frontier -> io (fun () ->
       let lines=Boundary.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name |> get in
       let line=List.find_map (function
         | line,Ok {Boundary.event=Turn_ended {position=Atom_history _;_};_}
             when line>List.fold_left (fun last (line,_) -> max last line)
               (Option.get (Source.official_range_id (Capture.source request))).after_boundary_line
               (Option.get (Source.official_range_id (Capture.source request))).turns -> Some line
         | _,Ok {Boundary.event=Turn_ended {position=(Atom_history _ | No_atom_history | Empty_atom_history | Stale_noop);_};_}
         | _,Ok {event=History_restarted _;_} | _,Error _ -> None) lines
         |> Option.to_result ~none:"fixture lacks a later atom boundary" |> get in
       Keeper_librarian_official_progress.write ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
         {boundary_line=line} |> Result.map_error Keeper_librarian_official_progress.write_error_to_string |> get)
     | Unreadable_frontier -> io (fun () ->
       write (Position.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name) "[")
     | Changed_original_prefix ->
       let changed=List.mapi (fun index message ->
         if index=1 then Agent_core.Types.make_message ~role:Agent_core.Types.User
           [Agent_core.Types.Text "Contradictory original canonical question"] else message) later_messages in
       save_checkpoint fixture.config ~trace_id changed 6);
    let files=[Position.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name;
      Keeper_librarian_official_progress.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name;
      Keeper_external_read_cursor.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name] in
    let frontiers ()=io (fun () -> List.map (fun path -> path,Fs_compat.load_file_opt path) files) in
    let positions=frontiers () and memory=cut_memory_bytes fixture in
    (match run_worker fixture with
     | Ok (Consumer.Pending _) | Error (Consumer.Original_publication_blocked _) -> ()
     | Ok _ | Error _ -> fail "unproved later frontiers must block the actual old-input publication");
    let retained,actual=only_original fixture in
    check string "failed canonical proof creates no replacement ID" original.Owner.request_id retained.Owner.request_id;
    check json "failed canonical proof preserves the full immutable input" (Capture.to_json request) (Capture.to_json actual);
    check bool "failed canonical proof never publishes old-range receipts" false
      (io (fun () -> Commit.receipt_state request) |> get);
    check bool "failed canonical proof changes no Memory or journal" true (cut_memory_bytes fixture=memory);
    check bool "failed canonical proof rewrites no cursor" true (frontiers ()=positions);
    check int "proof failure does not repeat either provider evaluation" 2 (F.post_count fixture.server))

let test_an_originals_own_fence_denies_publication_after_canonical_positions_advance () =
  with_fixture ~history_kind:Mixed ~with_external_attention:false (fun ~sw:_ fixture ->
    let original,request=retain_absent_history_original ~failed_selection:false fixture in
    let preview=fence_preview fixture request in
    let fence=memory_action fixture (fun () -> io (fun () ->
      Resolution.fence_serialized ~config:fixture.config ~keeper_name ~request_id:original.request_id
        ~expected:preview.expected ~actor:"operator" ~reason:"Retain this old unknown original without effects"
        ~now:(Time_compat.now ()) |> Result.map_error Resolution.error_to_string |> get)) in
    let later_messages=selected_messages @ [message "A later independently selected question";
      Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text "A later completed answer"]] in
    save_checkpoint fixture.config ~trace_id later_messages 4;
    let now=Time_compat.now () in
    io (fun () ->
      append_boundary fixture.config ~turn:4 ~time:(now+.1.)
        ~history_at_start:(Boundary.history_at_start_of_messages selected_messages) later_messages;
      official_turn ~trace_id:"later-official-client" fixture.config ~turn:5 ~time:(now+.2.));
    drive_advanced fixture;
    check bool "the actual fence still binds the exact immutable old source" true
      (io (fun () -> Fence.read ~store:fixture.store ~scope:original.scope ~request_id:original.request_id |> get)
        =Some fence);
    check bool "the old input has no exact completed old-range receipt" false
      (io (fun () -> Commit.receipt_state request) |> get);
    let positions=cut_source_positions fixture and memory=cut_memory_bytes fixture in
    (* Canonical position compatibility is data, not a fence override or an
       answered original. The actual effect ports must still refuse it. *)
    memory_action fixture (fun () -> io (fun () ->
      Keeper_librarian_durable_source_lock.with_original_publication ~request (fun plan ->
        Keeper_librarian_durable_source_lock.recheck_before plan))) |> get;
    refuse_fenced_resume fixture original request;
    let proposal=Capture.validate_proposal request (answer request) |> get in
    check bool "public Commit rejects the fenced original before granting any effect" true
      (Result.is_error (memory_action fixture (fun () -> Commit.publish ~store:fixture.store
        ~config:fixture.config ~request ~original ~proposal
        ~fresh_authority:(fun () -> fail "a fenced original cannot request fresh Gate authority"))));
    check bool "fence denial preserves all source positions and external ACK" true (cut_source_positions fixture=positions);
    check bool "fence denial preserves actual Memory, journal and receipts" true (cut_memory_bytes fixture=memory);
    let kept=io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope ~request_id:original.request_id) |> owned |> Option.get in
    check json "fence denial preserves the original uncertainty" (Owner.to_json original) (Owner.to_json kept);
    check int "only the independently selected later question reached the provider" 1 (F.post_count fixture.server))

let () = Alcotest.run "keeper_librarian_durable_execution" ["actual configured completed-history",[
  test_case "an old full mixed input gets new Memory receipts while canonical later frontiers stay" `Quick
    (test_an_old_mixed_answer_publishes_new_receipts_without_rewinding_later_frontiers ~lose_ack:false);
  test_case "an old full mixed input recovers its real Memory receipt after ACK read failure" `Quick
    (test_an_old_mixed_answer_publishes_new_receipts_without_rewinding_later_frontiers ~lose_ack:true);
  test_case "old input refuses a later atom whose opening digest is false" `Quick
    (test_old_input_publication_refuses_unproved_later_frontiers Wrong_atom_digest);
  test_case "old input refuses an unwitnessed later trace" `Quick
    (test_old_input_publication_refuses_unproved_later_frontiers Wrong_atom_trace);
  test_case "old input refuses the original trace after a restart" `Quick
    (test_old_input_publication_refuses_unproved_later_frontiers Restarted_history);
  test_case "old input refuses a later official cursor that names an atom row" `Quick
    (test_old_input_publication_refuses_unproved_later_frontiers Nonofficial_frontier);
  test_case "old input refuses an unreadable later cursor" `Quick
    (test_old_input_publication_refuses_unproved_later_frontiers Unreadable_frontier);
  test_case "old input refuses a changed canonical original prefix" `Quick
    (test_old_input_publication_refuses_unproved_later_frontiers Changed_original_prefix);
  test_case "an own fence still denies old-input publication after canonical frontiers advance" `Quick
    test_an_originals_own_fence_denies_publication_after_canonical_positions_advance;
  test_case "dispatch rechecks the owner without restoring the verified body" `Quick
    test_dispatch_rechecks_owner_without_restoring_the_body;
  test_case "proved original survives invalid working context on resume" `Quick
    test_retained_answer_with_invalid_working_context_recovers;
  test_case "an unallowed working-context field ends before Memory publication" `Quick
    test_working_context_with_an_unallowed_field_is_not_an_answer;
  test_case "retained source aliases preserve runtime physical-root checks" `Quick test_retained_source_root_alias;
  test_case "missing attachment is reported without consuming source" `Quick test_unattached_reports_without_consuming;
  test_case "terminal refusal preserves reason and allows a fresh original" `Quick test_terminal_refusal_allows_fresh_original;
  test_case "a worker frame refusal ends the original instead of blocking publication" `Quick
    test_worker_body_refusal_ends_the_original;
  test_case "a retained provider body refusal shows descent from its receipt" `Quick
    test_retained_body_refusal_shows_descent_from_its_receipt;
  test_case "the deploy check passes a history body refusal whose record goes" `Quick
    test_preflight_passes_a_history_body_refusal_whose_record_goes;
  test_case "the deploy check refuses a lost history answer whose proof is version 1" `Quick
    test_preflight_refuses_a_lost_history_answer_whose_proof_is_version_1;
  test_case "the deploy check passes a lost history body refusal whose record goes" `Quick
    test_preflight_passes_a_lost_history_body_refusal_whose_record_goes;
  test_case "a refusal the latest execution did not end in shows nothing" `Quick
    test_a_refusal_the_latest_execution_did_not_end_in_shows_nothing;
  test_case "actual original reaches Memory and source ACK" `Quick test_actual_completed_history_path;
  test_case "history guidance is required only for actual absorptions" `Quick
    test_history_guidance_is_required_only_for_actual_absorptions;
  test_case "floor guidance is required only for actual absorptions" `Quick
    test_floor_guidance_is_required_only_for_actual_absorptions;
  test_case "a settle stopped before its gate records finishes with the next original" `Quick
    test_stopped_settle_leaves_gates_for_the_next_original;
  test_case "one inventory observation reuses verified gate and parent bodies without effect authority" `Quick
    test_inventory_observation_reuses_verified_inputs;
  test_case "inventory observation rejects mixed parents and unrelated malformed gates" `Quick
    test_inventory_observation_rejects_mixed_parent_and_bad_scope;
  test_case "Librarian transcript rejects otherwise valid foreign approval facts" `Quick
    (test_librarian_transcript_refuses_foreign_facts false);
  test_case "Librarian transcript rejects otherwise valid foreign transport facts" `Quick
    (test_librarian_transcript_refuses_foreign_facts true);
  test_case "a gate request names its parent by digest instead of copying it" `Quick
    test_gate_request_names_its_parent_by_digest;
  test_case "actual official-only original reaches Memory and official ACK" `Quick (test_actual_official_or_mixed_path Official);
  test_case "actual mixed original reaches Memory and both receipt/position kinds" `Quick (test_actual_official_or_mixed_path Mixed);
  test_case "counterpart-only capacity refusal preserves source and ACK" `Quick
    (test_counterpart_only_provider_capacity_refusal_is_source_preserving ~recover_partial_ack:false);
  test_case "a receipt-proved refusal recovers partial ACK after fragment pruning" `Quick
    (test_counterpart_only_provider_capacity_refusal_is_source_preserving ~recover_partial_ack:true);
  test_case "a different equal chat row cannot release the original refusal" `Quick
    test_refusal_does_not_accept_a_different_equal_chat_row;
  test_case "a host replacement survives its ready worker disappearing" `Quick
    (test_replacement_terminal_survives_worker_gap ~rollback:false);
  test_case "a host replacement survives declaration rollback without replay" `Quick
    (test_replacement_terminal_survives_worker_gap ~rollback:true);
  test_case "Captured replacement ends and archives without reading its body" `Quick
    (test_unadmitted_replacement_needs_no_body_and_survives_rollback ~capacity_wait:false);
  test_case "Admission_wait replacement ends and archives without reading its body" `Quick
    (test_unadmitted_replacement_needs_no_body_and_survives_rollback ~capacity_wait:true);
  test_case "pre-admission replacement refuses an original with host execution evidence" `Quick
    test_unadmitted_replacement_preserves_existing_host_execution;
  test_case "preflight cannot turn removed host evidence into before-dispatch replacement authority" `Quick
    test_preflight_preserves_before_dispatch_ending_evidence;
  test_case "a ready replacement releases an actual Cut once and survives rollback" `Quick
    test_cut_replacement_releases_unread_source_and_survives_rollback;
  test_case "a replacement does not release an original Raised outcome" `Quick
    test_replaced_raised_original_stays_unknown;
  test_case "retained Interrupted cannot archive an actual host Cut" `Quick
    (test_interrupted_evidence_cannot_release_another_actual_host_cause ~raised:false);
  test_case "retained Interrupted cannot archive an actual host Raised" `Quick
    (test_interrupted_evidence_cannot_release_another_actual_host_cause ~raised:true);
  test_case "a linked Captured keeps resolution completion after ending and rollback" `Quick
    (test_linked_replacement_preserves_the_resolution_protocol ~cut:false ~recovery:Ended_only);
  test_case "a confirmed source child survives an independent host-replaced waiting root" `Quick
    (test_linked_replacement_preserves_the_resolution_protocol ~competing_ending:Replaced_waiter ~cut:false ~recovery:Ended_only);
  test_case "a confirmed source child survives an independent interrupted waiting root" `Quick
    (test_linked_replacement_preserves_the_resolution_protocol ~competing_ending:Interrupted_waiter ~cut:false ~recovery:Ended_only);
  test_case "a linked Cut keeps resolution completion after ending and rollback" `Quick
    (test_linked_replacement_preserves_the_resolution_protocol ~cut:true ~recovery:Ended_only);
  test_case "a linked Captured recovers the same full child intent" `Quick
    (test_linked_replacement_preserves_the_resolution_protocol ~cut:false ~recovery:Intent_only);
  test_case "a linked Cut recovers the same full child intent" `Quick
    (test_linked_replacement_preserves_the_resolution_protocol ~cut:true ~recovery:Intent_only);
  test_case "a linked Captured child cannot dispatch before its parent ACK" `Quick
    (test_linked_replacement_preserves_the_resolution_protocol ~cut:false ~recovery:Child_before_ack);
  test_case "a linked Cut child cannot dispatch before its parent ACK" `Quick
    (test_linked_replacement_preserves_the_resolution_protocol ~cut:true ~recovery:Child_before_ack);
  test_case "ordinary counterpart refusals preserve narrowed source identities" `Quick
    test_counterpart_non_capacity_refusal_preserves_narrowed_sources;
  test_case "legacy omitted original blocks admission but prepares a safe continuation" `Quick
    test_legacy_omitted_original_refuses_admission_but_prepares_safe_continuation;
  test_case "legacy omitted answer blocks Judged and commit publication" `Quick
    test_legacy_omitted_answer_blocks_judged_and_commit_publication;
  test_case "missing counterpart substitution preserves fresh source until corrected" `Quick
    test_counterpart_prompt_omission_preserves_fresh_source;
  test_case "untagged official counterparts reach Memory once" `Quick
    test_untagged_official_counterparts_reach_memory_once;
  test_case "production durable queue stops following phases on actual Pending" `Quick test_production_queue_pending_retains_all_sources;
  test_case "actual host result bridge resumes production queue" `Quick test_actual_result_bridge_uses_production_queue;
  test_case "host answer without original gate waits while Off" `Quick test_host_answer_without_gate_waits_while_off;
  test_case "an answered history Gate waits for the replacement worker then commits the same answer" `Quick
    (test_answered_history_gate_follows_replacement ~foreign_installation:false);
  test_case "a different installation cannot prepare an answered history Gate" `Quick
    (test_answered_history_gate_follows_replacement ~foreign_installation:true);
  test_case "an answered floor step keeps its answer when its first Gate follows a replacement" `Quick
    (test_answered_floor_gate_follows_replacement ~foreign_installation:false);
  test_case "a different installation cannot prepare an answered floor Gate" `Quick
    (test_answered_floor_gate_follows_replacement ~foreign_installation:true);
  test_case "actual Memory receipt with failed ACK settles while Off" `Quick test_real_memory_receipt_then_failed_ack_recovers_while_off;
  test_case "receipt-proved partial ACK holds source locks without requiring the pruned prefix" `Quick
    test_receipt_proved_partial_ack_keeps_source_locks_without_rereading_prefix;
  test_case "a worker call reads the record and writes nothing" `Quick test_a_worker_call_reads_the_record_and_writes_nothing;
  test_case "a waiting pass reads no body" `Quick test_a_waiting_pass_reads_no_body;
  test_case "a finished worker answer reads the body first" `Quick test_a_finished_worker_answer_reads_the_body_first;
  test_case "changed checkpoint source cannot publish retained original answer" `Quick
    (test_source_replacement_cannot_publish_retained_answer Replaced_checkpoint);
  test_case "same-trace restart cannot publish old retained checkpoint answer" `Quick
    (test_source_replacement_cannot_publish_retained_answer Restarted_history);
  test_case "purge joins actual provider and worker restart never resubmits unknown" `Quick
    (test_purge_joins_unknown_then_worker_restart_does_not_resubmit Atoms);
  test_case "mixed checkpoint and official source stay pending after actual terminal unknown" `Quick
    (test_purge_joins_unknown_then_worker_restart_does_not_resubmit Mixed);
  test_case "an original a stopped server interrupted settles and its range is read again" `Quick
    test_interrupted_original_settles_and_its_range_is_read_again;
  test_case "a floor step guard tells a replaced declaration from a failed read" `Quick
    test_a_floor_step_guard_tells_a_replaced_declaration_from_a_failed_read;
  test_case "a replaced declaration ends a waiting original and its range is read whole again" `Quick
    test_a_replaced_declaration_ends_a_waiting_original_and_its_range_is_read_whole_again;
  test_case "a normal waiting pass ends its unlisted replaced original without a runner" `Quick
    test_runner_free_replacement_recovers_an_unlisted_dispatch_pending_original;
  test_case "two absent originals retain actual replacement endings before fresh selection" `Quick
    test_two_absent_originals_drain_replaced_endings_before_fresh_selection;
  test_case "a retained replaced floor step checks its actual proof before recreation" `Quick
    test_a_retained_replaced_floor_step_requires_its_actual_proof_link;
  test_case "retained history inventory checks a replaced original's actual proof before archive" `Quick
    test_a_retained_replaced_history_original_checks_its_proof_before_inventory_settlement;
  test_case "a declaration put back before the end is read preserves the recorded ending" `Quick
    test_a_declaration_put_back_before_the_end_is_read_preserves_the_ending;
  test_case "a replaced declaration ends a captured original no worker received" `Quick
    (a_replaced_declaration_ends_an_original_no_worker_received ~declined:false);
  test_case "a replaced declaration ends a declined original no worker received" `Quick
    (a_replaced_declaration_ends_an_original_no_worker_received ~declined:true);
  test_case "a pre-dispatch refusal with other evidence stops the pass" `Quick
    test_a_pre_dispatch_refusal_with_other_evidence_stops_the_pass;
  test_case "an unadmitted original of the same declaration is admitted" `Quick
    (an_unadmitted_original_of_the_same_declaration_is_admitted ~declined:false);
  test_case "a declined original of the same declaration is admitted" `Quick
    (an_unadmitted_original_of_the_same_declaration_is_admitted ~declined:true);
  test_case "an unadmitted original waits while the Add-on is off" `Quick
    test_an_unadmitted_original_waits_while_the_addon_is_off;
  test_case "a replaced declaration settles a cut original and its range is read whole again" `Quick
    test_a_replaced_declaration_settles_a_cut_original_and_its_range_is_read_whole_again;
  test_case "a cut original waits when its declaration is put back" `Quick
    test_a_cut_original_waits_when_its_declaration_is_put_back;
  test_case "a cut original keeps its ending after rollback before archive" `Quick
    test_a_cut_original_keeps_its_ending_when_its_declaration_is_put_back_before_it_is_moved;
  test_case "a cut original waits while the destination of now is unknown" `Quick
    test_a_cut_original_waits_while_the_destination_of_now_is_unknown;
  test_case "destructive Memory epoch reset refuses retained old owner" `Quick test_epoch_reset_refuses_old_original;
  test_case "a missing history original automatically continues and commits its exact source" `Quick
    (test_missing_history_recovers_without_operator_submission Atoms);
  test_case "automatic recovery commits mixed atom and official history before acknowledging" `Quick
    (test_missing_history_recovers_without_operator_submission Mixed);
  test_case "automatic history recovery preserves an existing operator intent" `Quick
    test_automatic_history_reuses_an_operator_intent;
  test_case "one production catch-up signal automatically recovers missing history through Memory and ACK" `Quick
    test_missing_history_progresses_through_the_production_queue;
  test_case "an absent automatic child yields before dispatching its own continuation" `Quick
    test_an_absent_continuation_yields_before_its_next_child;
  test_case "an explicit history fence blocks late observations and unreadable fence state" `Quick
    test_history_fence_retains_unknown_and_blocks_late_observations;
  test_case "the actual host guard rereads its own fence before a replacement ending" `Quick
    test_actual_history_guard_rechecks_own_fence_for_replacement;
  test_case "a same-binding Cut effect fence preserves Unknown without creating a successor" `Quick
    (test_cut_effect_fence_preserves_unknown_without_a_successor Atoms);
  test_case "a mixed-source Cut effect fence preserves every original frontier" `Quick
    (test_cut_effect_fence_preserves_unknown_without_a_successor Mixed);
  test_case "a Cut effect fence refuses active claims and a proof changed after preview" `Quick
    test_cut_effect_fence_refuses_a_busy_claim_and_late_bad_proof;
  test_case "a Cut effect fence refuses an actual original Memory range receipt" `Quick
    test_cut_effect_fence_refuses_an_actual_range_receipt;
  test_case "a Cut effect fence refuses source positions moved after preview" `Quick
    test_cut_effect_fence_refuses_moved_source_positions;
  test_case "a Cut fence grants no direct intent, lineage or host execution authority" `Quick
    test_cut_fence_is_not_direct_child_or_host_authority;
  test_case "actual Cut continuation commits atoms and survives proof pruning" `Slow
    (test_automatic_cut_continuation_commits_and_retains_compact_proof Atoms);
  test_case "actual Cut continuation commits mixed source and ACK" `Slow
    (test_automatic_cut_continuation_commits_and_retains_compact_proof Mixed);
  test_case "Cut-owned atom floor retains pending identity and frozen leaf assets" `Slow
    (test_cut_owned_full_source_floor Atoms ~refuse_message:false);
  test_case "Cut-owned mixed floor publishes both original ranges together" `Slow
    (test_cut_owned_full_source_floor Mixed ~refuse_message:false);
  test_case "Cut-owned atom message refusal cannot become an unread hole" `Slow
    (test_cut_owned_full_source_floor Atoms ~refuse_message:true);
  test_case "Cut-owned mixed message refusal cannot become an unread hole" `Slow
    (test_cut_owned_full_source_floor Mixed ~refuse_message:true);
  test_case "ordinary Work completes a Cut-owned mixed floor with real full-source ACK and compact proof" `Slow
    (test_cut_owned_full_source_floor ~production:true Mixed ~refuse_message:false);
  test_case "fresh current configuration completes the retained Cut source without changing pending IDs" `Quick
    (test_cut_owned_full_source_floor ~production:true ~change_semantic:true Mixed ~refuse_message:false);
  test_case "a declaration changed after actual retained step capture completes one full program" `Slow
    (test_cut_owned_full_source_floor ~production:true ~replacement:Captured_question Mixed ~refuse_message:false);
  test_case "an actual typed host step ending continues the same retained Cut coordinate" `Slow
    (test_cut_owned_full_source_floor ~production:true ~replacement:Host_ended_question Mixed ~refuse_message:false);
  test_case "retained step replacement resumes its full saved intent without minting another ID" `Slow
    (test_cut_owned_full_source_floor ~production:true ~replacement:Replacement_intent_saved Mixed ~refuse_message:false);
  test_case "retained step replacement confirms the already saved child before dispatch" `Slow
    (test_cut_owned_full_source_floor ~production:true ~replacement:Replacement_child_saved Mixed ~refuse_message:false);
  test_case "retained step replacement resumes the acknowledged child after reload" `Slow
    (test_cut_owned_full_source_floor ~production:true ~replacement:Replacement_ack_saved Mixed ~refuse_message:false);
  test_case "rollback after a full retained intent keeps its exact child before fresh continuation" `Slow
    (test_cut_owned_full_source_floor ~production:true ~replacement:Replacement_intent_rollback Mixed ~refuse_message:false);
  test_case "a declaration replaced after an actual later retained coordinate completes the full program" `Slow
    (test_cut_owned_full_source_floor ~production:true ~replacement:Later_captured_question Mixed ~refuse_message:false);
  test_case "an actual unknown retained step is never declaration-replaced or replayed" `Slow
    (test_retained_question_replacement_refuses_unsafe_state Unknown_question);
  test_case "an ordinary permission refusal grants no retained step replacement" `Slow
    (test_retained_question_replacement_refuses_unsafe_state Permission_question);
  test_case "a malformed actual proof blocks retained step replacement" `Slow
    (test_retained_question_replacement_refuses_unsafe_state Malformed_question_proof);
  test_case "an actual completed generation blocks retained step replacement" `Slow
    (test_retained_question_replacement_refuses_unsafe_state Completed_question_proof);
  test_case "an actual orphan Gate blocks retained step replacement without metadata preparation" `Slow
    (test_retained_question_replacement_refuses_unsafe_state Gate_question);
  test_case "a saved child cannot change its retained coordinate transaction or question" `Slow
    (test_retained_question_replacement_refuses_unsafe_state Changed_replacement_question);
  test_case "direct host dispatch before the real parent ACK cannot run an unacknowledged retained child" `Slow
    (test_retained_question_replacement_refuses_unsafe_state Unacknowledged_question_dispatch);
  test_case "a wrong retained child at the exact intended ID is preserved and refuses publication" `Slow
    (test_retained_question_replacement_refuses_unsafe_state Wrong_retained_child);
  test_case "post-ACK interruption recovers one Cut program and durable completion without replay" `Quick
    (test_cut_owned_full_source_floor ~interrupt_after_ack:true Mixed ~refuse_message:false);
  test_case "Cut command recovers fence before grant with rebased Memory" `Slow
    test_cut_command_recovers_fence_before_grant_after_memory_rebase;
  test_case "Cut command busy and late proof stay Requested" `Slow
    test_cut_command_busy_and_late_proof_keep_requested;
  test_case "counterpart Cut capacity refusal cannot abandon the original read obligation" `Slow
    test_counterpart_cut_capacity_refusal_preserves_original_obligation;
  test_case "a Cut obligation survives an absence-fenced ancestor with a truncated summary" `Slow
    test_cut_ancestry_rejects_a_truncated_fenced_index;
  test_case "an actual worker frame refusal requires actual host proof absence" `Slow
    (test_capacity_refusal_checks_no_host_proof ~frame_refusal:true);
  test_case "an actual orphan capacity proof cannot impersonate a no-host frame refusal" `Slow
    (test_capacity_refusal_checks_no_host_proof ~frame_refusal:false);
  test_case "an actual unfenced root Cut cannot use the public refusal adapter" `Slow
    test_root_cut_cannot_use_the_public_refusal_adapter;
  test_case "outer cancellation joins the actual Cut fence write before readback and recovery" `Slow
    test_cut_fence_outer_cancellation_joins_fs_scope;
  test_case "a Cut fence without an intent blocks ordinary, direct and queued fresh history" `Quick
    (test_cut_fence_without_intent_blocks_every_fresh_history_path ~remove_owner:false);
  test_case "a Cut fence still blocks fresh history after its live owner record disappears" `Quick
    (test_cut_fence_without_intent_blocks_every_fresh_history_path ~remove_owner:true);
  test_case "a fenced unknown original does not block the next history pass" `Quick
    test_history_fence_allows_the_next_history_pass;
  test_case "the deploy check reads no Exact file of a fenced original" `Quick
    test_preflight_reads_no_exact_file_of_a_fenced_original;
  test_case "a post-fence cursor change terminates only its continuation" `Quick
    (test_fenced_resolution_survives_cursor_advance ~nested:false);
  test_case "a refused nested continuation does not block its ancestor or fresh history" `Quick
    (test_fenced_resolution_survives_cursor_advance ~nested:true);
  test_case "an actual original range commit refuses a later fence" `Quick
    test_history_fence_refuses_a_real_range_commit;
  test_case "uncertain visible fence publication still blocks the original" `Quick
    test_history_fence_uncertain_publication_still_blocks;
  test_case "history resolution survives stale preview and continues one exact range" `Quick
    test_history_resolution_rejects_stale_then_continues_the_same_original;
  test_case "resolution recovers complete preparation after a crash before body publication" `Quick
    (test_resolution_preparation_recovers_exact_bytes Before_body);
  test_case "resolution recovers the same prepared child after body publication before compaction" `Quick
    (test_resolution_preparation_recovers_exact_bytes Body_before_compaction);
  test_case "resolution recovers compacted intent before child ownership publication" `Quick
    (test_resolution_preparation_recovers_exact_bytes Compaction_before_owner);
  test_case "resolution preserves conflicting body evidence and its complete preparation" `Quick
    test_resolution_preparation_preserves_conflicting_body;
  test_case "concurrent explicit Memory write closes known basis and resumes original source once" `Quick
    (test_changed_memory_rebases_original_source_without_unknown_retry ~lose_child_after_dispatch:false);
  test_case "confirmed successor loss refuses fresh inference and late answer" `Quick
    (test_changed_memory_rebases_original_source_without_unknown_retry ~lose_child_after_dispatch:true);
  test_case "unacknowledged replacement is denied by host and locally recovered while Off" `Quick
    (test_changed_memory_rebases_original_source_without_unknown_retry ~recover_unacked_child:true);
  test_case "a chain settle stopped after its successor finishes from the root" `Quick
    (test_changed_memory_rebases_original_source_without_unknown_retry ~interrupt_settle:true);
  test_case "a chain across two UTC days settles and finishes under its root's day" `Quick
    (test_changed_memory_rebases_original_source_without_unknown_retry ~recover_unacked_child:true ~interrupt_settle:true);
  test_case "a size refusal the host kept for one turn is a floor candidate" `Quick
    test_a_kept_size_refusal_of_one_turn_is_a_candidate;
  test_case "a record that is not the request's own is an error" `Quick
    test_a_record_that_is_not_the_requests_own_is_an_error;
  test_case "a refusal that shows nothing about reading less is no floor candidate" `Quick
    test_a_refusal_that_shows_nothing_about_reading_less_is_no_candidate;
  test_case "a read the consumer did not narrow is no floor candidate" `Quick
    test_a_read_the_consumer_did_not_narrow_is_no_candidate;
  test_case "a read of two turns is no floor candidate" `Quick test_a_read_of_two_turns_is_no_candidate;
  test_case "the floor reads a turn the provider refuses one message at a time" `Quick
    test_the_floor_reads_a_turn_the_provider_refuses_one_message_at_a_time;
  test_case "a message the frame refuses alone stays unread" `Quick test_a_message_the_frame_refuses_alone_stays_unread;
  test_case "the deploy check refuses a floor step whose proof is version 1" `Quick
    test_preflight_refuses_a_floor_step_whose_proof_is_version_1;
  test_case "the deploy check passes a floor body refusal whose record goes" `Quick
    test_preflight_passes_a_floor_body_refusal_whose_record_goes;
  test_case "the floor reads an official turn from its retained messages" `Quick
    test_the_floor_reads_an_official_turn_from_its_retained_messages;
  test_case "a checkpoint whose read prefix changed stops the descent before any step" `Quick
    test_a_checkpoint_whose_read_prefix_changed_stops_the_descent_before_any_step;
  test_case "history appended after the original does not stop the descent" `Quick
    test_history_appended_after_the_original_does_not_stop_the_descent;
  test_case "a refused original whose read position moved is no longer a candidate" `Quick
    test_a_refused_original_whose_read_position_moved_is_no_longer_a_candidate;
  test_case "the descent reads on while the external cursor moves" `Quick
    test_the_descent_reads_on_while_the_external_cursor_moves;
  test_case "a finished chain commits its program and the consumer moves the position" `Quick
    test_a_finished_chain_commits_its_program_and_the_consumer_moves_the_position;
  test_case "a published floor with valid prompts recovers its pending ACK" `Quick
    test_published_floor_with_valid_prompts_recovers_its_pending_ack;
  test_case "a published floor with omitted observations retains its pending ACK" `Quick
    test_published_floor_with_omitted_observations_keeps_pending_ack;
  test_case "a hole travels in the receipt and in the external cursor" `Quick
    test_a_hole_travels_in_the_receipt_and_in_the_external_cursor;
  test_case "a memory that changed since the chain began supersedes the program" `Quick
    test_a_memory_that_changed_since_the_chain_began_supersedes_the_program;
  test_case "a second publication of a program that changes no fact writes nothing" `Quick
    test_a_second_publication_of_a_program_that_changes_no_fact_writes_nothing;
  test_case "a commit error after the snapshot was renamed does not hide the receipt" `Quick
    test_a_commit_error_after_the_snapshot_was_renamed_does_not_hide_the_receipt;
  test_case "the consumer's tail runs in the pass that published" `Quick
    test_the_consumers_tail_runs_in_the_pass_that_published;
  test_case "an official turn is published with its own receipt" `Quick
    test_an_official_turn_is_published_with_its_own_receipt;
  test_case "the pass reads a turn the provider refused message by message" `Quick
    (test_the_pass_reads_a_refused_turn_message_by_message Atoms ["Original question to retain";"Original completed answer"]);
  test_case "the pass reads an official turn the provider refused message by message" `Quick
    (test_the_pass_reads_a_refused_turn_message_by_message Official
       ["Original official-client question";"Original official-client answer"]);
  test_case "a candidate covers only the range it read" `Quick test_a_candidate_covers_only_the_range_it_read;
  test_case "a message the frame refused is published as a hole" `Quick
    test_a_message_the_frame_refused_is_published_as_a_hole;
  test_case "a refusal that shows nothing about reading less is read again as before" `Quick
    test_a_refusal_that_shows_nothing_about_reading_less_is_read_again_as_before;
  test_case "a step the host refused is asked again under a new ID" `Quick
    test_a_step_the_host_refused_is_asked_again_under_a_new_id;
  test_case "a pass starts the chain again when Memory changed under it" `Quick
    test_a_pass_starts_the_chain_again_when_memory_changed_under_it;
  test_case "the steps of a published range are settled by the next pass" `Quick
    test_the_steps_of_a_published_range_are_settled_by_the_next_pass;
  test_case "floor cleanup loads only the steps it settles" `Quick
    test_floor_cleanup_loads_only_the_steps_it_settles;
  test_case "a candidate covers its range after the log grew" `Quick
    test_a_candidate_covers_its_range_after_the_log_grew;
  test_case "a turn that ended after the original does not stop the pass" `Quick
    test_a_turn_that_ended_after_the_original_does_not_stop_the_pass;
  test_case "a candidate covers its range when a later turn end states the same position" `Quick
    test_a_candidate_covers_its_range_when_a_later_turn_end_states_the_same_position;
  test_case "a settle that stops part way leaves the steps the chain resumes from" `Quick
    test_a_settle_that_stops_part_way_leaves_the_steps_the_chain_resumes_from;
  test_case "a stale prefix left by failed cleanup restarts from current Memory" `Quick
    test_a_stale_prefix_left_by_failed_cleanup_restarts_from_current_memory;
  test_case "settling a position no step holds is an error" `Quick
    test_settling_a_position_no_step_holds_is_an_error;
]]
