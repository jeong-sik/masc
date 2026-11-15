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
      host=Some {list_requests=(fun () ->
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
  set_step_response:(string -> Cohttp.Code.status_code * string) -> unit;
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
let official_empty_turn config ~turn ~time =
  let turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:turn in
  Boundary.append ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
    {Boundary.recorded_at=time;event=Boundary.Turn_ended {turn_ref;task_context=Keeper_turn_task_context.No_task;
      history_at_start=Boundary.Continued_history;position=Boundary.No_atom_history}}
  |> Result.map_error Boundary.append_error_to_string |> get
let official_turn config ~turn ~time =
  let turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:turn in
  let session=Keeper_context_core.create_session ~session_id:trace_id ~base_dir:(Keeper_fs.session_store_path config) in
  Keeper_context_core_history.persist_message ~keeper_name ~turn_ref ~source:Masc.Keeper_types_support.Direct_user session
    (message "Original official-client question");
  Keeper_context_core_history.persist_message ~keeper_name ~turn_ref ~source:Masc.Keeper_types_support.Internal_assistant session
    (Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text "Original official-client answer"]);
  Keeper_context_core_history.persist_tool_observation ~keeper_name ~turn_ref session ~tool_name:"read_file" ~outcome:Tool_result.Ok;
  official_empty_turn config ~turn ~time
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

let test_retained_answer_with_invalid_working_context_recovers () = with_fixture (fun ~sw:_ fixture ->
  let output capture = match answer capture with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
      if key="working_contexts" then key,`List [`Assoc [
        "merge_contexts",`List [];"sources",`List [`String "fixture-source"];
        "context",`String "original context";"next_steps",`List [];
        "completeness",`String "current"]]
      else key,value) fields)
    | _ -> fail "fixture answer is not an object" in
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
  check bool "strict consumer schema rejects the additional nested field" true
    (Result.is_error (Exact.final_of_json ~schema wire));
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
    (io (fun () -> Result.is_error (Capture.decode_final ~store:fixture.store capture changed)));
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
    (io (fun () -> Result.is_error (Capture.decode_final ~store:empty_store capture wire)));
  let invalid_memory=match output capture with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
        if key="new_claims" then key,`List [new_claim ""] else key,value) fields)
    | _ -> fail "fixture answer is not an object" in
  check bool "invalid Memory is still rejected by its domain" true
    (Result.is_error (Capture.validate_proposal capture invalid_memory));
  let hold=memory_action fixture (fun () ->
    Durable_owner.resume ~store:fixture.store ~config:fixture.config ~reserved:[]
      ~original:record ~request:capture
      ~call:(fun ~expected:_ ~original:_ ~arguments:_ -> fail "proved host answer must not call the worker")
      ~publish:(fun ~original:_ ~request:_ ~proposal:_ ->
        Ok (Durable_owner.Publication_pending "fixture holds publication after judgment"))
      ~wake:(fun () -> ())) in
  (match hold with
   | Ok (Durable_owner.Publication_waiting _) -> ()
   | Ok (Pending _ | Refused _ | Finished _ | Basis_superseded _) -> fail "original did not retain its judgment"
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
  let rejected=io (fun () -> Gate.validate_payload ~owner:(Capture.physical_owner capture)
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
let replace_actual_worker_configuration fixture ~sw source =
  let old=(runtime_export fixture).Runtime.instance_id in
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
        List.find_opt (fun (export:Runtime.tool_export) -> export.tool.name=Capture.tool && export.instance_id<>old)
          snapshot.exports)) |> ignore;
    reconcile fixture)
(* An official turn can have no turn-tagged fragments while its independent
   counterpart sources still have unread evidence. Exercise the configured
   Addon path, including the actual receipt and both source acknowledgements. *)
let test_counterpart_only_provider_capacity_refusal_is_source_preserving () =
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
    (* The operator chose to end a permanent over-capacity refusal rather than
       block its destination for ever: the next wake abandons exactly that
       range, with a typed diagnosis, and the destination is free again. *)
    (match run_worker fixture with
     | Ok _ -> ()
     | Error error -> fail (Consumer.error_to_string error));
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
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
    `OK,F.openai_response (answer capture));
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
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
    let assert_actual_unknown ()=check json "the host's unknown cause stays original"
      (Exact.retained_final_to_json original_host_final) (Exact.retained_final_to_json (actual_unknown ())) in
    (* First observe the actual terminal through the ordinary owner. The old
       behavior returned Memory_not_committed here, then selected a fresh ID. *)
    assert_pending (run_worker fixture);
    let retained_unknown,_=only_original fixture in
    (match Progress.phase retained_unknown.Owner.progress with
     | Rejected {stage=Execution;evidence} ->
       check json "original refusal retains the actual host unknown terminal"
         (Exact.retained_final_to_json original_host_final) evidence
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Rejected {stage=Before_dispatch;_} | Subdividing _ | Subdivided _ ->
       fail "the actual terminal was not retained on its original execution");
    let unknown_progress=Progress.to_json retained_unknown.progress in
    let assert_preserved ()=
      assert_actual_unknown ();
      let reopened,restored=only_original fixture in
      check string "all wakes keep the original unknown ID" record.request_id reopened.Owner.request_id;
      check json "all wakes keep its complete input and preparation" original (Capture.to_json restored);
      check json "later wakes never rewrite the terminal original" unknown_progress (Progress.to_json reopened.progress);
      check bool "unknown never acknowledges checkpoint history" true (progress fixture=before);
      check (list (pair string (option string))) "unknown keeps Memory, WAL and both source preparations exact"
        before_state (state ());
      check bool "unknown grants no absorption judgment" true
        (io (fun () -> Keeper_librarian_durable_gate.root ~store:fixture.store
          ~owner:(Capture.physical_owner capture) ~capture |> get |> Option.is_none));
      check int "unknown never authorizes another provider call" posts (F.post_count fixture.server);
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
       | None -> fail "production wake did not report its durable result");
      assert_preserved () in
    assert_preserved ();
    ordinary_wake ();
    ordinary_wake ();
    (* Restart again after Rejected/Outcome_unknown is durable, so this is
       recovery of that phase, not only a Dispatch_pending transport observation. *)
    restart_actual_worker fixture ~sw;
    ordinary_wake ();
    set_enabled fixture false;
    assert_pending (run_worker fixture);
    assert_preserved ()))
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
let retain_absent_history_original fixture =
  let captured = ref None in
  (match memory_action fixture (fun () -> Consumer.consume_one ~config:fixture.config ~keeper_name
    ~commit:(fun source -> captured := Some source; Consumer.Memory_refused [])) with
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
  let original = advance original Progress.Dispatch_intended in
  let original = advance original (Progress.Execution_observed (Progress.Absent (`Assoc []))) in
  original, request
let fence_preview fixture request = io (fun () ->
  Resolution.preview ~config:fixture.config ~keeper_name ~request_id:(Capture.request_id request)
  |> Result.map_error Resolution.error_to_string |> get)
let refuse_fenced_resume fixture original request =
  let before = io (fun () -> current fixture.keepers_dir), progress fixture in
  let result = memory_action fixture (fun () -> Durable_owner.resume ~store:fixture.store
    ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ()) ~original ~request
    ~call:(fun ~expected:_ ~original:_ ~arguments:_ -> fail "fenced original reached its worker")
    ~publish:(fun ~original:_ ~request:_ ~proposal:_ -> fail "fenced original reached Memory publication")
    ~wake:(fun () -> fail "fenced original scheduled a replacement")) in
  check bool "fenced original refuses before any worker or Memory action" true (Result.is_error result);
  check bool "fence refusal preserves Memory and source position" true
    (before = (io (fun () -> current fixture.keepers_dir), progress fixture))
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
      | Requested | Refused _ | Fenced | Child_intended _ -> fail "nested fixture has no confirmed child" in
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
     | Ok () | Error (Invalid _ | Conflict _ | Publication_uncertain _) -> false);
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
     | Requested | Refused Observation_changed | Fenced | Child_intended _ | Child_confirmed _ -> false);
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
     | Ok _ | Error (Invalid _ | Unavailable _ | Publication_uncertain _) -> false);
  run_ok ();
  drive_advanced fixture;
  check int "ordinary fresh history runs after the durable refusal" 1 (F.post_count fixture.server);
  check bool "fresh history actually commits Memory" true (io (fun () -> claims fixture.keepers_dir)<>[]);
  check bool "the unknown original stays live and unchanged" true
    (Option.map Owner.to_json (io (fun () -> Owner.load ~store:fixture.store ~scope:original.scope
      ~request_id:original.request_id |> owned))=Some (Owner.to_json original));
  refuse_fenced_resume fixture original request)
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
     | Ok () | Error (Invalid _ | Conflict _ | Publication_uncertain _) -> false);
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
     | Ok () | Error (Invalid _ | Conflict _ | Publication_uncertain _) -> false);
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
  let lineage ()=io (fun () -> Lineage.confirm_predecessor ~store:fixture.store ~require_confirmed:true child_request) in
  io (fun () -> Sys.remove parent_body);
  check (result unit string) "lineage of a resolution child passes without the parent's body" (Ok ()) (lineage ());
  check bool "the host's lineage check still reads the parent's body" true
    (Result.is_error (io (fun () -> Lineage.confirm_predecessor_by_body ~store:fixture.store
      ~require_confirmed:true child_request)));
  io (fun () -> write parent_body parent_bytes);
  check (result unit string) "the host's lineage check passes with the parent's body" (Ok ())
    (io (fun () -> Lineage.confirm_predecessor_by_body ~store:fixture.store ~require_confirmed:true child_request));
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
  check (result unit string) "a parent index with another source basis breaks the lineage"
    (Error "History resolution child changed its original source or owner")
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
     | Ok () | Error (Invalid _ | Conflict _ | Publication_uncertain _) -> false);
  io (fun () -> Sys.remove stray);
  let resume_descendant ()=
    let original,request=load_child descendant_id in
    memory_action fixture (fun () -> Durable_owner.resume ~store:fixture.store ~config:fixture.config
      ~reserved:(Keeper_librarian_durable_edge.reserved ()) ~original ~request ~wake:(fun () -> ())
      ~call:(Keeper_librarian_durable_edge.call ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ()))
      ~publish:(fun ~original ~request ~proposal ->
        Keeper_librarian_durable_commit.publish ~store:fixture.store ~config:fixture.config
          ~original ~request ~proposal ~fresh_authority:(Keeper_librarian_durable_edge.fresh_authority
            ~config:fixture.config ~reserved:(Keeper_librarian_durable_edge.reserved ())
            ~owner:(Capture.physical_owner request) ~expected:(Capture.destination request))
        |> Result.map_error (fun detail -> Durable_owner.Rejected detail))) in
  let delivered= !(fixture.deliveries) in
  (match resume_descendant () with
   | Ok (Durable_owner.Pending _) -> ()
   | Error error -> fail (Durable_owner.error_to_string error)
   | Ok _ -> fail "descendant did not dispatch its actual worker request");
  await_delivery fixture ~after:delivered;
  (match resume_descendant () with
   | Ok (Durable_owner.Finished _) -> ()
   | Error error -> fail (Durable_owner.error_to_string error)
   | Ok _ -> fail "descendant did not finish its actual Memory publication");
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
  | Ok Chain.Superseded -> fail "the chain's initial facts were superseded"
  | Error detail -> failf "the chain refused: %s" detail
let program_claims (program:Program.t) =
  List.concat_map (fun (stage:Program.stage) ->
    List.map (fun (fact:Types.fact) -> fact.claim) stage.decision.new_claims) program.stages
let steps_of fixture request =
  Step_owner.discover ~store:fixture.store ~owner:(Capture.physical_owner request)
  |> Result.map_error Step_owner.error_to_string |> get
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
let candidate_and_request fixture =
  let _,request=only_original fixture in
  match candidate_of fixture with
  | Some candidate -> candidate,request
  | None -> fail "the refused original must be a floor candidate"
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
   | Ok (Chain.Finished _ | Chain.Pending _ | Chain.Stopped _ | Chain.Superseded) ->
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
module Commit = Keeper_librarian_durable_commit
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
        ~rule_prompt:preparation.rule_prompt ~prompt:preparation.prompt
        ~output_schema:preparation.output_schema |> get in
      let request_id = Step.fresh_request_id owner in
      let payload = match Step.to_json step with
        | `Assoc fields -> `Assoc (List.map (function
            | "request_id", _ -> "request_id", `String request_id
            | "preparation", _ -> "preparation", Keeper_librarian_durable_question.to_json omitted.preparation
            | field -> field) fields)
        | _ -> fail "floor step must encode as an object" in
      let destination = Step.destination step in
      io (fun () -> Owner.retain ~store:fixture.store ~scope:(Step.scope owner) ~request_id
        ~installation_id:destination.installation_id ~package_id:destination.package_id
        ~tool:destination.tool ~summary:`Null ~request:payload) |> owned;
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
(* RFC-0500. The attempt a stopped server leaves: started by another
   incarnation, with no outcome and no proof. *)
let stopped_incarnation="0123456789abcdef0123456789abcdef"
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
    io (fun () ->
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
      |> get);
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
      ~policy:seed.policy ~rule_prompt:seed.rule_prompt ~prompt:seed.prompt ~output_schema:seed.output_schema |> get in
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
let test_legacy_omitted_original_refuses_admission_but_observes_pending () =
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
    (match authorization.before_dispatch () with
     | Error detail -> check bool "actual host dispatch names the omitted input" true
         (Astring.String.is_infix ~affix:"counterpart_observations" detail)
     | Ok () -> fail "actual host dispatch admitted an omitted retained question");
    Prompt_registry.clear_prompt_override Prompt_names.librarian;
    assert_omitted_original_blocked (run_worker fixture);
    let dispatched=advance_legacy fixture held Progress.Dispatch_intended in
    assert_pending (run_worker fixture);
    let pending,restored=only_original fixture in
    check string "unknown delivery keeps the old ID" dispatched.request_id pending.Owner.request_id;
    check json "pending observation never rerenders the question" source_json (Capture.to_json restored);
    check json "no external preparation is ACKed" cursor_before (cursor ());
    check bool "no read position advances" true (progress fixture=position_before);
    check int "admission, provider guard and pending wakes dispatch no model" 0 (F.post_count fixture.server);
    no_memory fixture))
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
      ~original ~arguments:(`Assoc ["kind",`String "submit";"request",Exact.request_to_json (Capture.request request |> get)])
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
        ~reserved:[] ~original ~request ~wake:(fun () -> fail "unsafe publication cannot wake completion")
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

let () = Alcotest.run "keeper_librarian_durable_execution" ["actual configured completed-history",[
  test_case "proved original survives invalid working context on resume" `Quick
    test_retained_answer_with_invalid_working_context_recovers;
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
  test_case "a gate request names its parent by digest instead of copying it" `Quick
    test_gate_request_names_its_parent_by_digest;
  test_case "actual official-only original reaches Memory and official ACK" `Quick (test_actual_official_or_mixed_path Official);
  test_case "actual mixed original reaches Memory and both receipt/position kinds" `Quick (test_actual_official_or_mixed_path Mixed);
  test_case "counterpart-only capacity refusal preserves source and ACK" `Quick
    test_counterpart_only_provider_capacity_refusal_is_source_preserving;
  test_case "a different equal chat row cannot release the original refusal" `Quick
    test_refusal_does_not_accept_a_different_equal_chat_row;
  test_case "ordinary counterpart refusals preserve narrowed source identities" `Quick
    test_counterpart_non_capacity_refusal_preserves_narrowed_sources;
  test_case "legacy omitted original blocks admission but observes pending" `Quick
    test_legacy_omitted_original_refuses_admission_but_observes_pending;
  test_case "legacy omitted answer blocks Judged and commit publication" `Quick
    test_legacy_omitted_answer_blocks_judged_and_commit_publication;
  test_case "missing counterpart substitution preserves fresh source until corrected" `Quick
    test_counterpart_prompt_omission_preserves_fresh_source;
  test_case "untagged official counterparts reach Memory once" `Quick
    test_untagged_official_counterparts_reach_memory_once;
  test_case "production durable queue stops following phases on actual Pending" `Quick test_production_queue_pending_retains_all_sources;
  test_case "actual host result bridge resumes production queue" `Quick test_actual_result_bridge_uses_production_queue;
  test_case "host answer without original gate waits while Off" `Quick test_host_answer_without_gate_waits_while_off;
  test_case "actual Memory receipt with failed ACK settles while Off" `Quick test_real_memory_receipt_then_failed_ack_recovers_while_off;
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
  test_case "destructive Memory epoch reset refuses retained old owner" `Quick test_epoch_reset_refuses_old_original;
  test_case "an explicit history fence blocks late observations and unreadable fence state" `Quick
    test_history_fence_retains_unknown_and_blocks_late_observations;
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
