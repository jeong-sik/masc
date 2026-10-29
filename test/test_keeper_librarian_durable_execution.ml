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
      call_exported_tool=(fun ~companion:_ ~on_result ~on_dispatch ~authorize ~principal ~name ~arguments ->
        Protocol.call_exported_tool ~on_result ~on_dispatch ?authorize ~principal protocol ~name ~arguments
          |> Result.map_error invocation_error);
      operator_schema=(fun () -> None);
      companion_tools=(fun () -> []);
      observation_effect=(fun _ -> Lane_addon_call_context.May_change);
      call_operator=(fun ~admit:_ ~arguments:_ -> Error Masc.Lane_addon_worker_protocol.Operator_unavailable);
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
module Gate = Keeper_librarian_durable_gate
let canonical request=Lane_addon_action.canonical request |> get
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
let settled_on fixture ~date (record:Owner.retained) =
  io (fun () -> Owner.settled ~store:fixture.store ~scope:record.scope ~date ~request_id:record.request_id) |> owned
let settle_only fixture ~date (record:Owner.retained) =
  io (fun () -> Owner.settle ~store:fixture.store ~date (Owner.listed record))
  |> Result.map_error Owner.settle_error_to_string |> get
(* A settled original as the archive holds it: its progress, and the request
   body its record names. *)
let archived fixture ~date (record:Owner.retained) =
  let read path=io (fun () -> Yojson.Safe.from_file (Filename.concat (Store.root fixture.store) path)) in
  let stored=read (Store.tool_request_archive_record_path ~scope:record.scope ~date ~request_id:record.request_id) in
  Progress.of_json (member "progress" stored) |> get,
  read (Store.tool_request_archive_body_path ~scope:record.scope ~date
    ~request_digest:(Yojson.Safe.Util.to_string (member "request_digest" stored)))
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
  let fresh,_=only_original fixture in
  check bool "fresh selection retains a separate original ID" true (fresh.Owner.request_id<>rejected.request_id);
  let settled,request=archived fixture ~date:(day_of rejected.request_id) rejected in
  check json "settled refused request remains exact" (canonical request_before) request;
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
   | Ok (Consumer.Memory_not_committed ([] | _::_::_) | Nothing_to_read | Pending
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
   | Ok (Consumer.Memory_not_committed ([] | _::_::_) | Nothing_to_read | Pending
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
  let request_before=Capture.to_json capture in
  let posts=F.post_count fixture.server in
  let gates=gate_records fixture capture in
  check bool "the finished original has gate records to settle" true (List.length gates>0);
  ignore (run_worker fixture);
  check int "the next pass settles the finished original" 0 (List.length (observed_originals fixture));
  let date=day_of record.Owner.request_id in
  let settled,restored=archived fixture ~date record in
  check json "settled original keeps the full retained input/preparation" (canonical request_before) restored;
  check json "settled original keeps its finished progress" (Progress.to_json record.progress) (Progress.to_json settled);
  check bool "its gate records settle under the same day" true (List.for_all (settled_on fixture ~date) gates);
  check int "no gate record stays for validation" 0 (List.length (gate_records fixture capture));
  check int "already consumed source never creates another provider request" posts (F.post_count fixture.server))
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
   | Ok (Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending) ->
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
      "Original gate request is not version 2" detail
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
      Refresh.submit_durable ~base_path:fixture.base_path ~keeper_name;
      Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
      (match Refresh.last_measurement ~config:fixture.config ~keeper_name with
       | Some measurement -> check bool "production wake retains terminal unknown as Pending" true
           (measurement.Refresh.last_pass=Refresh.Pending)
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
      let request_id=minted_a_day_before (Capture.fresh_request_id owner) in
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
let size_refusal = `Request_entity_too_large, {|{"error":{"message":"fixture body too large","type":"invalid_request_error"}}|}
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
  | Ok (Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Pending) ->
    fail "the failed read did not stop at the unread turn"
  | Error error -> fail (Consumer.error_to_string error)
let ended_by_one_refusal = function
  | Ok (Consumer.Memory_not_committed [_]) -> ()
  | Error error -> fail (Consumer.error_to_string error)
  | Ok (Consumer.Memory_not_committed ([] | _::_::_) | Nothing_to_read | Pending | Baseline_advanced _
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
  "board_post_id",`Null;"board_comment_id",`Null;"supersedes",`Null;"absorbs",`List []]
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
  | Ok (Chain.Pending detail) -> failf "the chain was still pending: %s" detail
  | Ok (Chain.Stopped {position;report}) -> failf "the chain stopped at %d: %s" position report.detail
  | Error detail -> failf "the chain refused: %s" detail
let program_claims (program:Program.t) =
  List.concat_map (fun (stage:Program.stage) ->
    List.map (fun (fact:Types.fact) -> fact.claim) stage.decision.new_claims) program.stages
let steps_of fixture request =
  Step_owner.discover ~store:fixture.store ~owner:(Capture.physical_owner request)
  |> Result.map_error Step_owner.error_to_string |> get
(* The claims of the facts the chain's first step was asked from. *)
let first_step_facts fixture request =
  match List.find_opt (fun (_,(header:Keeper_librarian_floor_step_request.header)) -> header.position=0)
    (steps_of fixture request) with
  | None -> fail "the chain has no first step"
  | Some (record,_) ->
    let step=Keeper_librarian_floor_step_request.restore ~owner:(Capture.physical_owner request) record |> get in
    (match (Keeper_librarian_floor_step_request.step step).preparation.source_input.current with
     | Some current -> List.sort String.compare (List.map (fun (fact:Types.fact) -> fact.claim) current.facts)
     | None -> [])
let candidate_and_request fixture =
  let _,request=only_original fixture in
  match candidate_of fixture with
  | Some candidate -> candidate,request
  | None -> fail "the refused original must be a floor candidate"
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
   | Ok (Chain.Finished _ | Chain.Pending _ | Chain.Stopped _) ->
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
  | Ok (Nothing_to_read | Baseline_advanced _ | Memory_not_committed _ | Pending) ->
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
  io (fun () -> Current.upsert_fact ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
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
    Current.For_testing.apply_program_with_publication_io
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
   | Ok (Nothing_to_read | Baseline_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending) ->
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
    | Ok Consumer.Pending when attempts>0 ->
      if !wakes=woken then await_delivery fixture ~after:before;
      go (attempts-1)
    | result -> result in
  go 16
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
   | Ok (Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending) ->
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
       selected:=Some source;Consumer.Memory_pending)) with
   | Ok Consumer.Pending -> ()
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
   | Ok (Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending) ->
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
   | Ok (Nothing_to_read | Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Pending
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
   | Ok (Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending) ->
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
  io (fun () -> Current.upsert_fact ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
    ~now:(Time_compat.now ()) ~source:{kind=Current.Explicit_write;trace_id="concurrent-floor-writer"}
    independent |> Result.map_error Current.upsert_error_to_string |> get |> ignore);
  check bool "the chain that began on the old Memory is dropped, and a new one finishes" true
    (advanced (run_until_done ~wakes fixture));
  check int "dropping it asked the lane for one more pass" 1 !wakes;
  check int "each chain asked the provider for each message" 4 (F.post_count fixture.server-posts);
  check (list string) "Memory holds the independent write and the second chain's claims"
    ["Independent explicit write";"claim number 1";"claim number 2"] (io (fun () -> claims fixture.keepers_dir));
  (match run_worker fixture with
   | Ok Consumer.Nothing_to_read -> ()
   | Ok (Baseline_advanced _ | Progress_advanced _ | Official_advanced _ | Memory_not_committed _ | Pending) ->
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
let test_settling_a_position_no_step_holds_is_an_error () = with_fixture (fun ~sw:_ fixture ->
  provider_refuses_one_turn fixture size_refusal;
  let candidate,request=candidate_and_request fixture in
  fixture.set_step_response (answering_steps ["Original question to retain";"Original completed answer"]);
  ignore (finished (descend fixture candidate));
  (match Cleanup.settle_step ~store:fixture.store ~owner:(Capture.physical_owner request) candidate ~position:5 with
   | Error detail -> check bool "the error names the position" true (contains detail "position 5")
   | Ok moved -> failf "%d records settled for a position no step holds" moved);
  check (list int) "and no step moved" [0;1] (sorted_positions fixture request))

let () = Alcotest.run "keeper_librarian_durable_execution" ["actual configured completed-history",[
  test_case "missing attachment is reported without consuming source" `Quick test_unattached_reports_without_consuming;
  test_case "terminal refusal preserves reason and allows a fresh original" `Quick test_terminal_refusal_allows_fresh_original;
  test_case "a worker frame refusal ends the original instead of blocking publication" `Quick
    test_worker_body_refusal_ends_the_original;
  test_case "a retained provider body refusal shows descent from its receipt" `Quick
    test_retained_body_refusal_shows_descent_from_its_receipt;
  test_case "a refusal the latest execution did not end in shows nothing" `Quick
    test_a_refusal_the_latest_execution_did_not_end_in_shows_nothing;
  test_case "actual original reaches Memory and source ACK" `Quick test_actual_completed_history_path;
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
  test_case "destructive Memory epoch reset refuses retained old owner" `Quick test_epoch_reset_refuses_old_original;
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
  test_case "settling a position no step holds is an error" `Quick
    test_settling_a_position_no_step_holds_is_an_error;
]]
