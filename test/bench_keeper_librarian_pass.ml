(** Measures one completed-history Librarian pass against the size of the
    history the Keeper had already read before it.

    The fixture is the one test_keeper_librarian_durable_execution.ml uses:
    production durable queue -> configured Runtime -> Python worker -> common
    host Exact HTTP -> original domain/gate/Memory receipt. Only container
    launch is substituted. Each run keeps the unread range to one small turn
    and grows the already-read prefix, so a pass whose cost follows the unread
    range stays flat and one whose cost follows the whole checkpoint grows.

    Run from _build/default/test (the fixture reads ../config and ../addons):
    ./bench_keeper_librarian_pass.exe 1 5 20     (prefix sizes in MB)
    ./bench_keeper_librarian_pass.exe 5:1        (prefix MB : unread MB) *)
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
(* A 20 MB prefix pass can take longer than the test fixture's 30 s. *)
let bench_wait_seconds = 600.0
(* A turn the worker frame refuses is read one message per pass, so a run is
   hundreds of passes. Each wait keeps the limit above; the whole run gets this one. *)
let bench_run_seconds = 7200.0
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
let run_worker fixture=Eio.Time.with_timeout_exn fixture.clock bench_wait_seconds
  (fun () -> memory_action fixture (fun () -> Execution.consume_one ~config:fixture.config ~keeper_name ~wake:(fun () -> ())))
let await_delivery fixture ~after=Eio.Time.with_timeout_exn fixture.clock bench_wait_seconds (fun () ->
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
(* A turn the worker frame refuses is read message by message, one pass per
   step: the first two passes are refused, as the consumer narrows its read,
   and the rest wait on the worker. Returns the passes it took. *)
let progress_line passes =
  if passes mod 25 = 0 then Printf.eprintf "pass %d at %.0fs\n%!" passes (Unix.gettimeofday ())
let drive_until_advanced fixture =
  let rec go passes =
    let before= !(fixture.deliveries) in
    match run_worker fixture with
    | Ok (Consumer.Progress_advanced _ | Official_advanced _) -> passes
    | Ok Consumer.Pending -> await_delivery fixture ~after:before;progress_line passes;go (passes+1)
    | Ok (Consumer.Memory_not_committed _) -> go (passes+1)
    | Ok (Nothing_to_read | Baseline_advanced _) -> fail "actual completed-history source was not submitted"
    | Error error -> fail (Consumer.error_to_string error) in
  go 1
let step_answer n = `Assoc ["new_claims",`List [`Assoc ["claim",`String (Printf.sprintf "claim number %d" n);
    "category",`String "fact";"board_post_id",`Null;"board_comment_id",`Null;"supersedes",`Null;"absorbs",`List []]];
  "dropped",`List [];"working_contexts",`List [];"working_state",`String (Printf.sprintf "working state %d" n)]
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
(* The bench sets these before each fixture: an already-read prefix of a
   chosen size, then one small unread turn. *)
let first_messages_ref=ref [message "The already-read first turn"]
let selected_messages_ref=ref []
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
     save_checkpoint config ~trace_id !first_messages_ref 1;
     io (fun () -> append_boundary config ~turn:1 ~time:(now-.10.)
       ~history_at_start:(Boundary.history_at_start_of_messages !first_messages_ref) !first_messages_ref);
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
     save_checkpoint config ~trace_id !selected_messages_ref turn;
     io (fun () -> append_boundary config ~turn ~time:(now-.1.)
         ~history_at_start:(Boundary.history_at_start_of_messages !first_messages_ref) !selected_messages_ref));
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
      (* A request that is no history original is a floor step. *)
      let step_response=ref (fun _ -> fail "a floor step has no answer in this run") in
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
          Eio.Time.with_timeout_exn fixture.clock bench_wait_seconds (fun () -> Eio.Promise.await exported));
        (* The export event precedes publication of the stable Runtime metadata.
           Reconcile once after that actual event before dispatching original work. *)
        reconcile fixture;
        (match Eio.Time.with_timeout_exn fixture.clock bench_run_seconds (fun () -> f ~sw fixture) with
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

let mib = 1024 * 1024
let turn_bytes = 16 * 1024

(* Text that does not repeat inside a message. *)
let filler ~seed bytes =
  let buffer = Buffer.create (bytes + 128) in
  let line = ref 0 in
  while Buffer.length buffer < bytes do
    Printf.bprintf buffer "turn %d line %d: the operator asked about item %d and the Keeper answered it. "
      seed !line ((seed * 7919) + !line);
    incr line
  done;
  Buffer.sub buffer 0 bytes

let prefix_messages ~bytes =
  let turns = max 1 (bytes / (2 * turn_bytes)) in
  List.concat (List.init turns (fun turn ->
    [ message (filler ~seed:turn turn_bytes)
    ; Agent_core.Types.make_message ~role:Agent_core.Types.Assistant
        [ Agent_core.Types.Text (filler ~seed:(turn + 1_000_000) turn_bytes) ] ]))

(* Words allocated on this domain since start. The Librarian pass runs on the
   fixture's domain and its systhreads; the Python worker is another process. *)
let allocated_bytes () =
  let s = Gc.quick_stat () in
  (s.minor_words +. s.major_words -. s.promoted_words) *. float_of_int (Sys.word_size / 8)

let rec fold_files path ~init ~f =
  match (Unix.lstat path).st_kind with
  | Unix.S_DIR ->
    Array.fold_left (fun acc name -> fold_files (Filename.concat path name) ~init:acc ~f) init (Sys.readdir path)
  | Unix.S_REG -> f init (Unix.lstat path).st_size
  | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> init
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> init

let file_size path =
  match Unix.stat path with
  | { Unix.st_size; _ } -> st_size
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> 0

let measure ~prefix_mib ~unread_mib =
  first_messages_ref := prefix_messages ~bytes:(prefix_mib * mib);
  let unread_turns = if unread_mib = 0 then []
    else List.map (fun (m : Agent_core.Types.message) ->
      { m with content = List.map (function
          | Agent_core.Types.Text text -> Agent_core.Types.Text ("unread " ^ text)
          | ( Agent_core.Types.Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
            | ToolResult _ | Image _ | Document _ | Audio _ ) as block -> block) m.content })
      (prefix_messages ~bytes:(unread_mib * mib)) in
  selected_messages_ref := !first_messages_ref @ unread_turns @
    [ message "Unread question after the long history"
    ; Agent_core.Types.make_message ~role:Agent_core.Types.Assistant
        [ Agent_core.Types.Text "Unread answer" ] ];
  with_fixture (fun ~sw:_ fixture ->
    let session_dir = Keeper_fs.keeper_session_dir fixture.config trace_id in
    let checkpoint_bytes = file_size (Filename.concat session_dir (trace_id ^ ".json")) in
    let store_root = Filename.concat (Workspace.masc_dir fixture.config) "lane-addons" in
    let stored_before = fold_files store_root ~init:0 ~f:( + ) in
    let allocated_before = allocated_bytes () in
    let started = Unix.gettimeofday () in
    let steps=ref 0 in
    fixture.set_step_response (fun _ -> incr steps;`OK,F.openai_response (step_answer !steps));
    let passes=drive_until_advanced fixture in
    let wall_s = Unix.gettimeofday () -. started in
    let allocated = allocated_bytes () -. allocated_before in
    let stored_after = fold_files store_root ~init:0 ~f:( + ) in
    let largest = fold_files store_root ~init:0 ~f:max in
    let unread = List.drop (List.length !first_messages_ref) !selected_messages_ref in
    let unread_bytes =
      List.fold_left (fun acc m ->
        acc + String.length (Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json m))) 0 unread in
    print_endline (Yojson.Safe.to_string (`Assoc
      [ "prefix_mib", `Int prefix_mib
      ; "unread_mib", `Int unread_mib
      ; "checkpoint_bytes", `Int checkpoint_bytes
      ; "unread_message_bytes", `Int unread_bytes
      ; "pass_allocated_bytes", `Float allocated
      ; "pass_stored_bytes", `Int (stored_after - stored_before)
      ; "largest_store_file_bytes", `Int largest
      ; "pass_wall_s", `Float wall_s
      ; "passes", `Int passes
      ; "floor_steps", `Int !steps
      ; "provider_posts", `Int (F.post_count fixture.server) ])))

let () =
  let size argument =
    match String.split_on_char ':' argument with
    | [ prefix ] -> int_of_string prefix, 0
    | [ prefix; unread ] -> int_of_string prefix, int_of_string unread
    | _ -> invalid_arg ("size is PREFIX_MB or PREFIX_MB:UNREAD_MB, got " ^ argument)
  in
  let sizes =
    match Array.to_list Sys.argv with
    | [] | [ _ ] -> [ 1, 0; 5, 0; 20, 0 ]
    | _ :: sizes -> List.map size sizes
  in
  List.iter (fun (prefix_mib, unread_mib) -> measure ~prefix_mib ~unread_mib) sizes
