(** Actual Memory-lane Worker.run -> configured Runtime -> Python worker ->
    common host Exact HTTP -> original domain/gate/Memory receipt/queue ACK.
    Only container launch/cleanup is substituted. These tests do not claim
    Docker, real paid providers, installed native binaries or visible UI. *)
open Alcotest
open Masc
module Worker = Keeper_memory_admission_worker
module Memory_lane = Keeper_memory_lane
module Queue = Keeper_memory_admission_queue
module Current = Keeper_memory_os_current
module Types = Keeper_memory_os_types
module Capture = Keeper_librarian_admission_capture
module Parts = Keeper_librarian_admission_parts
module Gate = Keeper_librarian_admission_gate
module Commit = Keeper_librarian_admission_commit
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
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
let fact claim=Types.observed ~claim ~category:Types.Fact ~now:100.
  ~origin:{kind=Types.Authored;trace_id="original-librarian-owner-test"}
let append keepers_dir id claim=Queue.append ~keepers_dir ~keeper_id:keeper_name ~request_id:id (fact claim)
  |> Result.map_error Queue.append_error_to_string |> get
let pending keepers_dir=Queue.read_pending ~keepers_dir ~keeper_id:keeper_name |> get
let pending_rows keepers_dir=match pending keepers_dir with None -> [] | Some batch -> Queue.candidates batch
let current keepers_dir=Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get
let claims keepers_dir=match current keepers_dir with None -> [] | Some snapshot ->
  List.map (fun (f:Types.fact) -> f.claim) snapshot.facts |> List.sort String.compare
let original_owner base_path keepers_dir=Capture.observe_owner ~base_path ~keepers_dir ~keeper_id:keeper_name |> get
let originals_for ~keeper_name base_path keepers_dir store =
  let owner=Capture.observe_owner ~base_path ~keepers_dir ~keeper_id:keeper_name |> get in
  let inventory=Parts.discover ~store ~owner ~restore_gate:(Gate.restore_size_evidence ~store ~owner) |> get in
  Owner.load_scope ~store ~scope:(Capture.scope owner) |> owned |> List.map (fun record ->
    let capture=Capture.restore ~owner ~load_parent:(Parts.load_parent inventory) record |> get in record,capture)
let originals=originals_for ~keeper_name
let new_claim claim=`Assoc ["claim",`String claim;"category",`String "fact";
  "board_post_id",`Null;"board_comment_id",`Null;"supersedes",`Null;"absorbs",`List []]
let answer select capture =
  let rows=Queue.candidates (Capture.batch capture) in
  let selected=List.filter select rows in
  let has_current claim=match (Capture.input capture).Keeper_librarian.current with
    | None -> false | Some snapshot -> List.exists (fun (f:Types.fact) -> f.claim=claim) snapshot.facts in
  let additions=List.filter (fun (row:Queue.candidate) -> not (has_current row.fact.claim)) selected in
  `Assoc ["memory",`Assoc ["new_claims",`List (List.map (fun (row:Queue.candidate) -> new_claim row.fact.claim) additions);
    "dropped",`List [];"working_state",`Null;"working_contexts",`List []];
    "candidates",`List (List.map (fun (row:Queue.candidate) ->
      let settle=select row in
      `Assoc ["request_id",`String row.request_id;
        "outcome",`String (if settle then if has_current row.fact.claim then "already_represented" else "incorporated" else "deferred");
        "memory_claim",(if settle then `String row.fact.claim else `Null);
        "reason",`String "The original complete candidate is judged against this captured Memory."]) rows);
    "change_support",`List (List.map (fun (row:Queue.candidate) -> `String row.request_id) selected)]
let publish_routes base_path urls =
  let slots=List.mapi (fun i url -> {F.id="librarian-candidate-" ^ string_of_int i;base_url=url}) urls in
  ignore (F.publish_registry ~lane_id:"librarian/admission" ~slot_ids:(List.map (fun (s:F.target_fixture) -> s.id) slots)
    (F.resolver_snapshot ~source:base_path slots) : Runtime_exact_output_registry.t)

let backend env base_path delivery delivery_observed observation_observed after_submit transform_reply observe_listing : Runtime.For_testing.backend = {
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
      observe=(fun ~binding ~sources ->
        let result=Protocol.observe protocol ~binding ~sources |> Result.map_error protocol_error in
        observation_observed ();result);
      exported_tools=(fun () -> Protocol.exported_tools protocol);
      call_exported_tool=(fun ~companion:_ ~on_result ~on_dispatch ~authorize ~principal ~name ~arguments ->
        let result=Protocol.call_exported_tool ~on_result ~on_dispatch ?authorize ~principal protocol ~name ~arguments
          |> Result.map_error invocation_error in
        (match member "kind" arguments with `String "submit" -> after_submit ()
         | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> ());
        Result.map (transform_reply arguments) result);
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
          let result=Protocol.host_requests protocol |> Result.map_error protocol_error in
          Result.iter observe_listing result;result);
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
  observations:int ref; observation_changed:Eio.Condition.t; response_checkpoint:int ref;
  extra_server:(Capture.t -> Cohttp.Code.status_code * string) -> F.test_server;
  submit_barrier:(unit -> unit) ref;
  host_listings:Yojson.Safe.t list ref;
  transform_reply:(Yojson.Safe.t -> Mcp_protocol.Mcp_types.tool_result -> Mcp_protocol.Mcp_types.tool_result) ref;
}
let observed_originals fixture=io (fun () -> originals fixture.base_path fixture.keepers_dir fixture.store)
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
let start_worker fixture=start_memory_action fixture (fun () ->
  Worker.run ~base_path:fixture.base_path ~keeper_name)
let memory_action ?(keeper_name=keeper_name) fixture action=
  let result=Eio.Promise.await_exn (start_memory_action ~keeper_name fixture action) in
  Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;result
let run_worker fixture=Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds
  (fun () ->
    let outcome=Eio.Promise.await_exn (start_worker fixture) in
    Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
    outcome)
let await_delivery fixture ~after=Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
  Eio.Condition.loop_no_mutex fixture.delivery_changed (fun () ->
    if !(fixture.deliveries)>after then Some () else None))
let await_host_cycle fixture =
  Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
    Eio.Condition.loop_no_mutex fixture.observation_changed (fun () ->
      if !(fixture.observations)> !(fixture.response_checkpoint) then Some () else None))
let drive_until fixture predicate =
  Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
    let rec loop ()=
      let before= !(fixture.deliveries) in
      let outcome=run_worker fixture in
      if predicate outcome then outcome
      else match outcome with
        | Worker.Unavailable detail -> fail detail
        | Addon_unattached _ -> fail "The configured Addon has no live exported admission tool"
        | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ ->
          await_delivery fixture ~after:before;loop () in loop ())
let assert_settled = function Worker.Settled _ -> ()
  | Disabled | Idle | Recheck_new_input | Pending _ | Addon_unattached _ | Unavailable _ -> fail "actual original decision did not commit Memory"
let settled = function Worker.Settled _ -> true
  | Disabled | Idle | Recheck_new_input | Pending _ | Addon_unattached _ | Unavailable _ -> false
let terminal (original,capture)=match Progress.phase original.Owner.progress with
  | Progress.Finished _ | Conflicted _ | Rejected _ | Subdivided _ -> true
  | Judged judgment ->
    let request=Capture.request capture |> get in
    let schema=match request.Lane_addon_exact.schema with Some schema -> schema
      | None -> fail "typed original schema is missing" in
    (match Lane_addon_exact.final_of_json ~schema judgment |> get with
     | Call_final (Answered {output;_}) ->
       (match Capture.validate_proposal capture (Lane_addon_exact.checked_json output) |> get with
        | Keeper_librarian_runtime.Deferred -> true | Accepted _ -> false)
     | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
     | Outcome_unknown | Not_allowed _ | Request_id_reused -> fail "original Judged phase is not a valid answer")
  | Captured | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _ | Subdividing _ -> false
let drive_original_terminal fixture =
  ignore (drive_until fixture (fun _ ->
    let rows=observed_originals fixture in rows<>[] && List.for_all terminal rows))
let reconcile fixture=Runtime.reconcile_configuration ~config:fixture.config
  ~directory:(Runtime.configuration_directory fixture.config) |> get |> ignore
let set_enabled fixture enabled=io (fun () -> write fixture.source (fixture.declaration enabled));reconcile fixture
let timeout_diagnostic fixture =
  io (fun () ->
    let queue=match Queue.read_pending ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name with
      | Error detail -> `Assoc ["error",`String detail]
      | Ok None -> `List []
      | Ok (Some batch) -> `List (List.map (fun (row:Queue.candidate) ->
          `Assoc ["request_id",`String row.request_id;"sequence",`Int row.sequence]) (Queue.candidates batch)) in
    let originals=match Capture.observe_owner ~base_path:fixture.base_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name with
      | Error detail -> `Assoc ["owner_error",`String detail]
      | Ok owner -> (match Owner.load_scope ~store:fixture.store ~scope:(Capture.scope owner) with
        | Error error -> `Assoc ["discovery_error",`String (Owner.error_to_string error)]
        | Ok records -> `List (List.map (fun (record:Owner.retained) ->
            `Assoc ["request_id",`String record.request_id;"progress",Progress.to_json record.progress]) records)) in
    `Assoc ["pending_candidates",queue;"originals",originals;
      "http_posts",`Int (F.post_count fixture.server);"deliveries",`Int !(fixture.deliveries);
      "observations",`Int !(fixture.observations)])
let with_fixture ?(initial=["a","Durable A";"b","Durable B"]) f =
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
      install_keeper ~config ~name:keeper_name ~trace_id:"librarian-original-owner";
      io (fun () -> List.iter (fun (id,claim) -> ignore (append keepers_dir id claim)) initial);
      let package=Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
        |> Result.map_error Lane_addon_manifest.error_to_string |> get in
      let source=Filename.concat (Runtime.configuration_directory config) "librarian.toml" in
      let declaration enabled=Printf.sprintf "id=\"librarian\"\nenabled=%b\nrun_id=\"librarian-original-owner\"\nmanifest_path=%s\n[binding]\nsources=[]\n"
        enabled (Yojson.Safe.to_string (`String (Filename.concat package.directory "lane.toml"))) in
      io (fun () -> write source (declaration true));
      let observations=ref 0 and observation_changed=Eio.Condition.create () and response_checkpoint=ref 0 in
      let observation_observed ()=incr observations;Eio.Condition.broadcast observation_changed in
      let response=ref (fun capture -> `OK,F.openai_response (answer (fun _ -> true) capture)) in
      let original_for body=
        let body=Yojson.Safe.from_string body in
        let messages=member "messages" body in
        let response_format=match Llm_provider.Backend_openai_request.response_format_to_openai_json
          Agent_core.Types.JsonMode with
          | Some value -> value | None -> fail "JSON mode has no OpenAI wire projection" in
        check json "the actual declared fixture target requests JSON mode" response_format
          (member "response_format" body);
        let captures=io (fun () ->
          Queue.list_keeper_ids ~keepers_dir |> get
          |> List.concat_map (fun keeper_name -> originals_for ~keeper_name base_path keepers_dir store)) in
        let matches=List.filter (fun (_,capture) ->
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
          Yojson.Safe.equal (`List sent) messages) captures in
        match matches with [_,capture] -> capture
        | [] | _::_::_ -> fail "actual provider request has no unique fully restored original capture" in
      let start_server respond=F.start_server ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
        (F.Reply_with (fun _ body ->
          response_checkpoint:= !observations;respond (original_for body))) in
      let server=start_server (fun capture -> !response capture) in
      publish_routes base_path [server.base_url];
      Runtime.register_exact_runner ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path)
        (Server_lane_addon_exact.runner ~base_path);
      let deliveries=ref 0 and delivery_changed=Eio.Condition.create () and delivery_loss=ref false in
      let delivery_observed ()=incr deliveries;Eio.Condition.broadcast delivery_changed in
      let submit_barrier=ref (fun () -> ()) in
      let transform_reply=ref (fun _ response -> response) in
      let host_listings=ref [] in
      let fixture={base_path;config;keepers_dir;store;source;declaration;server;
        set_response=(fun callback -> response:=callback);delivery_loss;deliveries;delivery_changed;
        clock=Eio.Stdenv.clock env;observations;observation_changed;response_checkpoint;
        extra_server=start_server;submit_barrier;transform_reply;host_listings} in
      Runtime.For_testing.with_backend
        (backend env base_path delivery_loss delivery_observed observation_observed
          (fun () -> !submit_barrier ()) (fun arguments response -> !transform_reply arguments response)
          (fun listing -> host_listings:=listing :: !host_listings)) (fun () ->
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
           Format.eprintf "Original Librarian timeout: %a@." Yojson.Safe.pp (timeout_diagnostic fixture);
           Printexc.raise_with_backtrace Eio.Time.Timeout backtrace);
        Memory_lane.For_testing.await_idle ~base_path ~keeper_name;
        set_enabled fixture false;
        Memory_lane.For_testing.reset ())))))))))))

let test_actual_happy_path ()=with_fixture (fun ~sw:_ fixture ->
  let ids=io (fun () -> match pending fixture.keepers_dir with Some batch -> Queue.candidate_ids batch
    | None -> fail "fixture inputs are absent") in
  drive_until fixture settled |> assert_settled;
  check (list string) "actual complete proposal becomes current Memory" ["Durable A";"Durable B"]
    (io (fun () -> claims fixture.keepers_dir));
  check int "receipt-backed ACK consumes the original candidates" 0
    (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
  let generation=(List.hd ids).Current.queue_generation in
  let receipts=io (fun () -> Current.committed_explicit_candidates ~keepers_dir:fixture.keepers_dir
    ~keeper_id:keeper_name ~queue_generation:generation |> get) in
  check bool "every original full input has an actual Memory consumption receipt" true
    (List.for_all (fun id -> List.mem id receipts) ids);
  check bool "HTTP was served by the real common Exact runner" true (F.post_count fixture.server>0);
  let before=List.map (fun (_,capture) -> Capture.request capture |> get |> Lane_addon_exact.request_to_json)
    (observed_originals fixture) in
  check bool "the actual owner retains its complete immutable original" true (before<>[]);
  let record,capture=List.hd (observed_originals fixture) in
  let history_input={(Capture.input capture) with Keeper_librarian.messages=[Agent_core.Types.user_msg "Original history"]} in
  let retained_input=Keeper_librarian_input_capture.to_json history_input in
  check bool "the shared data codec retains nonempty history" true
    (Keeper_librarian_input_capture.of_json retained_input=Ok history_input);
  let request=match record.Owner.request with
    | `Assoc fields -> `Assoc (("input_text",`String (Yojson.Safe.to_string retained_input))
        ::List.remove_assoc "input_text" fields)
    | _ -> fail "the actual retained capture must be an object" in
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let restored=io (fun () ->
    let store=Store.create ~root:(Filename.concat fixture.base_path "history-purpose-check") in
    Owner.retain ~store ~scope:record.scope ~request_id:record.request_id
      ~installation_id:record.installation_id ~package_id:record.package_id
      ~tool:record.tool ~summary:record.summary ~request |> owned;
    let retained=match Owner.load ~store ~scope:record.scope ~request_id:record.request_id |> owned with
      | Some retained -> retained | None -> fail "the altered history capture was not retained" in
    Capture.restore ~owner ~load_parent:(fun ~request_id:_ -> Ok (Capture.batch capture)) retained) in
  check bool "complete data restoration grants no admission authority over history" true
    (match restored with Error detail ->
       detail="Explicit-candidate execution cannot replace another Librarian pass's original input"
     | Ok _ -> false);
  let original_limit=Env_config.KeeperMemoryOs.facts_max_bytes () in
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.facts_max_bytes_env_key
    (Some (if original_limit=1 then "2" else "1")) (fun () ->
      let after=List.map (fun (_,capture) -> Capture.request capture |> get |> Lane_addon_exact.request_to_json)
        (observed_originals fixture) in
      check (list json) "actual Store restoration uses original prompt policy despite current cap changes" before after))

let test_unchanged_deferred_does_not_remint ()=with_fixture (fun ~sw:_ fixture ->
  fixture.set_response (fun capture -> `OK,F.openai_response (answer (fun _ -> false) capture));
  drive_original_terminal fixture;
  let before=List.map (fun (record,_) -> record.Owner.request_id,record.request,
    Progress.to_json record.progress) (observed_originals fixture) in
  let posts=F.post_count fixture.server in
  ignore (run_worker fixture);
  let after=List.map (fun (record,_) -> record.Owner.request_id,record.request,
    Progress.to_json record.progress) (observed_originals fixture) in
  check bool "unchanged deferred originals keep exact ID/input/progress" true (before=after);
  check int "unchanged deferred wake starts no new provider" posts (F.post_count fixture.server);
  check int "semantic deferral does not consume input" 2 (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
  check (list string) "semantic deferral does not create Memory" [] (io (fun () -> claims fixture.keepers_dir)))

let test_gap_and_new_tail_are_rejudged_together ()=with_fixture (fun ~sw:_ fixture ->
  fixture.set_response (fun capture -> `OK,F.openai_response (answer (fun (row:Queue.candidate) -> row.request_id="b") capture));
  drive_until fixture settled |> assert_settled;
  check (list int) "original partial commit leaves a sparse gap" [1]
    (io (fun () -> List.map (fun (row:Queue.candidate) -> row.sequence) (pending_rows fixture.keepers_dir)));
  io (fun () -> ignore (append fixture.keepers_dir "c" "Durable C"));
  let observed=ref [] in
  fixture.set_response (fun capture ->
    observed:=List.map (fun (row:Queue.candidate) -> row.request_id) (Queue.candidates (Capture.batch capture)) :: !observed;
    check (list string) "new root reads the actually committed Memory" ["Durable B"]
      (match (Capture.input capture).Keeper_librarian.current with None -> [] | Some state ->
        List.map (fun (f:Types.fact) -> f.claim) state.facts);
    `OK,F.openai_response (answer (fun _ -> true) capture));
  drive_until fixture settled |> assert_settled;
  check bool "new input causes the whole deferred gap plus tail to be judged" true (List.mem ["a";"c"] !observed);
  check (list string) "all independently retained knowledge survives" ["Durable A";"Durable B";"Durable C"]
    (io (fun () -> claims fixture.keepers_dir));
  check int "the new decision ACKs only its original complete candidates" 0
    (io (fun () -> List.length (pending_rows fixture.keepers_dir))))

let latest_execution fixture capture=io (fun () ->
  let exact=Capture.request capture |> get in
  let schema=match exact.Lane_addon_exact.schema with Some schema -> schema
    | None -> fail "original request did not preserve its output schema" in
  match Lane_addon_exact.read_latest_original_execution ~store:fixture.store ~declaration_id:"librarian" ~schema exact |> get with
  | Lane_addon_exact.Completed_latest {execution;_} -> execution
  | No_completed_latest -> fail "actual original host walk has no completed durable proof")
let test_retained_host_terminal_commits_off ()=with_fixture (fun ~sw:_ fixture ->
  fixture.delivery_loss:=true;
  let before= !(fixture.deliveries) in
  ignore (run_worker fixture);
  await_delivery fixture ~after:before;
  let capture=match observed_originals fixture with [_,capture] -> capture
    | [] | _::_::_ -> fail "expected one original host execution" in
  let execution=latest_execution fixture capture in
  check bool "real host proof contains the validated provider answer before lost delivery" true
    (match execution.Lane_addon_exact.outcome with
     | Call_ended (Answered _) -> true
     | Call_ended (Invalid_output _ | Input_refused _ | Output_limit_reached _) | Call_refused _ -> false);
  check int "host answer alone does not ACK a candidate" 2
    (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
  let posts=F.post_count fixture.server in
  set_enabled fixture false;
  drive_until fixture settled |> assert_settled;
  check int "accepted original recovery while Off starts no provider" posts (F.post_count fixture.server);
  check int "only the actual local domain commit authorizes queue ACK" 0
    (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
  check (list string) "the original full answer reaches Memory while Off" ["Durable A";"Durable B"]
    (io (fun () -> claims fixture.keepers_dir)))

let refusal error_type=Yojson.Safe.to_string (`Assoc ["error",`Assoc ["type",`String error_type;
  "message",`String "Controlled fixture provider refusal"]])
type veto = Quota | Invalid
let test_actual_mixed_walk_blocks_partition kind ()=with_fixture (fun ~sw:_ fixture ->
  fixture.set_response (fun _ -> `Request_entity_too_large,refusal "invalid_request_error");
  let other=fixture.extra_server (fun _ -> match kind with
    | Quota -> `Too_many_requests,refusal "rate_limit_error"
    | Invalid -> `OK,F.openai_response (`Assoc ["not_an_admission_judgment",`Bool true])) in
  publish_routes fixture.base_path [fixture.server.base_url;other.base_url];
  ignore (run_worker fixture);
  F.await_first_request other;
  await_host_cycle fixture;
  let capture=match observed_originals fixture with [_,capture] -> capture
    | [] | _::_::_ -> fail "mixed refusal minted more than one original before inspection" in
  let evidence=Keeper_exact_walk_receipt.failure_evidence (latest_execution fixture capture).receipt in
  check bool "the actual typed named input refusal survives the other visit" true evidence.named_input_capacity;
  (match kind with
   | Quota ->
     check bool "actual quota visit vetoes smaller input" true evidence.size_independent_execution_failure;
     check bool "quota does not erase the independent named capacity observation" true
       (Keeper_exact_walk_failure.refuses_input_capacity evidence)
   | Invalid ->
     check bool "actual schema/domain rejection vetoes smaller input" true evidence.invalid_output;
     check bool "invalid output vetoes the derived capacity classification" false
       (Keeper_exact_walk_failure.refuses_input_capacity evidence));
  ignore (run_worker fixture);
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let inventory=io (fun () -> Parts.discover ~store:fixture.store ~owner
    ~restore_gate:(Gate.restore_size_evidence ~store:fixture.store ~owner) |> get) in
  let parent=Parts.find inventory ~part_id:(Capture.parent_part_id capture) |> get in
  check bool "the actual original proof refuses size-only partition authority" true
    (io (fun () -> Parts.execution_size_evidence ~store:fixture.store ~owner ~inventory
      ~parent ~execution_id:(Capture.request_id capture)) |> Result.is_error);
  check int "the original mixed failure never creates a partition child" 1 (List.length (Parts.runnable inventory));
  check bool "the remaining part is the original root" true
    (List.for_all (fun part -> Parts.predecessor part=None) (Parts.runnable inventory));
  check int "mixed failure consumes no candidate" 2 (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
  check (list string) "mixed failure publishes no Memory" [] (io (fun () -> claims fixture.keepers_dir)))

let test_sparse_whole_candidate_partition_reads_fresh_memory ()=
  with_fixture ~initial:["a","Durable A";"b","Durable B";"c","Durable C"] (fun ~sw:_ fixture ->
    (* Real prior Memory consumption creates the sparse pending rows. No fake
       judge or forged queue bytes replace the production owner under test. *)
    io (fun () ->
      let batch=match pending fixture.keepers_dir with Some batch -> batch | None -> fail "missing original inputs" in
      let b=List.filter (fun (id:Current.explicit_candidate_id) -> id.request_id="b") (Queue.candidate_ids batch) in
      Current.apply_disposition ~explicit_candidate_ids:b ~absorbed:[] ~revisions:[]
        ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name ~now:101.
        ~source:{kind=Current.Librarian;trace_id="previous-real-consumption"} ~new_claims:[fact "Durable B"] () |> get |> ignore;
      Queue.acknowledge_committed ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get);
    check (list int) "prior receipt leaves original sparse whole candidates" [1;3]
      (io (fun () -> List.map (fun (row:Queue.candidate) -> row.sequence) (pending_rows fixture.keepers_dir)));
    let visits=ref [] in
    fixture.set_response (fun capture ->
      let rows=Queue.candidates (Capture.batch capture) in
      let before=match (Capture.input capture).Keeper_librarian.current with None -> [] | Some state ->
        List.map (fun (f:Types.fact) -> f.claim) state.facts |> List.sort String.compare in
      visits:=(List.map (fun (row:Queue.candidate) -> row.sequence) rows,before) :: !visits;
      if List.length rows>1 then `Request_entity_too_large,refusal "invalid_request_error"
      else `OK,F.openai_response (answer (fun _ -> true) capture));
    ignore (drive_until fixture (fun _ -> io (fun () -> pending_rows fixture.keepers_dir=[])));
    let chronological=List.rev !visits in
    check bool "actual capacity caused the original disjoint whole-input split" true
      (List.map fst chronological=[[1;3];[1];[3]]);
    check bool "the right child reads Memory committed by the left child" true
      (List.mem ([3],["Durable A";"Durable B"]) chronological);
    check (list string) "sequential children preserve every prior and admitted fact" ["Durable A";"Durable B";"Durable C"]
      (io (fun () -> claims fixture.keepers_dir)))

let test_purge_cancels_waiting_memory_unit_without_consumption ()=with_fixture (fun ~sw fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  fixture.submit_barrier:=(fun () ->
    ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release);
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    let before=io (fun () -> Fs_compat.load_file (Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name)) in
    let completed=start_worker fixture in
    Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await arrived);
    (* The real worker has retained the submit before its actual callback
       returns. Forking starts purge cancellation and blocks on real lane
       cleanup; release that same RPC rather than inventing an answer. *)
    let cancelled=Eio.Fiber.fork_promise ~sw (fun () ->
      Memory_lane.cancel_and_await_librarian ~base_path:fixture.base_path ~keeper_name) in
    ignore (Eio.Promise.try_resolve unblock ());
    (match Eio.Promise.await_exn cancelled with Ok () -> ()
     | Error error -> fail (Memory_lane.purge_cancel_error_to_string error));
    (match Eio.Promise.await completed with
     | Error (Eio.Cancel.Cancelled _) -> ()
     | Ok _ -> fail "actual active Memory unit ignored purge cancellation"
     | Error exn -> raise exn);
    check string "cancelled dispatch cannot ACK unknown original work" before
      (io (fun () -> Fs_compat.load_file (Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name)));
    check (list string) "cancellation applies no Memory judgment" []
      (io (fun () -> claims fixture.keepers_dir))))

let original_path fixture ~scope ~request_id=Filename.concat (Store.root fixture.store)
  (Filename.concat "tool-request-owners" (Filename.concat (Store.digest scope) (Store.digest request_id ^ ".json")))
let assert_unavailable = function Worker.Unavailable _ -> ()
  | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Addon_unattached _ -> fail "invalid complete original history must refuse before local repair"
let test_invalid_original_blocks_receipt_backed_ack ()=with_fixture (fun ~sw:_ fixture ->
  let queue_path=Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
  let original_queue=io (fun () -> Fs_compat.load_file queue_path) in
  drive_until fixture settled |> assert_settled;
  let record=match observed_originals fixture with [record,_] -> record
    | [] | _::_::_ -> fail "expected one actual completed original" in
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let path=original_path fixture ~scope:(Capture.scope owner) ~request_id:record.request_id in
  (* Replay the byte-exact pre-ACK queue after the genuine HTTP/domain commit.
     This retains real Current receipts; no success or consumed ID is forged. *)
  io (fun () -> write queue_path original_queue;write path "{controlled-original-capture-corruption");
  run_worker fixture |> assert_unavailable;
  check string "unrelated original corruption cannot consume even receipted pending bytes" original_queue
    (io (fun () -> Fs_compat.load_file queue_path)))
let test_missing_finished_gate_is_not_recreated ()=with_fixture (fun ~sw:_ fixture ->
  drive_until fixture settled |> assert_settled;
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let gates=io (fun () -> Owner.load_scope ~store:fixture.store ~scope:(Gate.scope owner) |> owned) in
  let gate=match gates with [gate] -> gate
    | [] | _::_::_ -> fail "finished actual execution must retain its one original gate" in
  let originals_before=List.map (fun (record,_) -> record.Owner.request_id,Progress.to_json record.progress)
    (observed_originals fixture) in
  let memory_path=Current.path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
  let memory_before=io (fun () -> Fs_compat.load_file memory_path) in
  let posts=F.post_count fixture.server in
  io (fun () -> Unix.unlink (original_path fixture ~scope:(Gate.scope owner) ~request_id:gate.request_id));
  run_worker fixture |> assert_unavailable;
  check int "missing original gate cannot mint a replacement journal" 0
    (io (fun () -> Owner.load_scope ~store:fixture.store ~scope:(Gate.scope owner) |> owned |> List.length));
  check string "missing gate leaves the committed Memory unchanged" memory_before
    (io (fun () -> Fs_compat.load_file memory_path));
  check int "missing gate cannot repeat the original model call" posts (F.post_count fixture.server);
  let originals_after=io (fun () -> Owner.load_scope ~store:fixture.store ~scope:(Capture.scope owner) |> owned)
    |> List.map (fun record -> record.Owner.request_id,Progress.to_json record.progress) in
  check (list (pair string json)) "original completion is preserved for diagnosis" originals_before originals_after)

type epoch_drift = Missing_epoch | Replaced_epoch
let test_original_epoch_drift_cannot_remint drift ()=with_fixture (fun ~sw:_ fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
    `OK,F.openai_response (answer (fun _ -> true) capture));
  let epoch_path=Current.epoch_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
  ignore (run_worker fixture);
  Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await arrived);
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let scope=Capture.scope owner in
  let records=io (fun () -> Owner.load_scope ~store:fixture.store ~scope |> owned) in
  let original=match records with [record] -> record
    | [] | _::_::_ -> fail "fixture did not retain exactly one actual dispatched original" in
  let path=original_path fixture ~scope ~request_id:original.request_id in
  let original_bytes,epoch_bytes,queue_bytes,memory_before,generation=io (fun () ->
    Fs_compat.load_file path,Fs_compat.load_file epoch_path,
    Fs_compat.load_file (Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name),
    Fs_compat.load_file_opt (Current.path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name),
    (Queue.read_generation ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get)) in
  let posts=F.post_count fixture.server in
  Fun.protect ~finally:(fun () ->
    io (fun () -> write epoch_path epoch_bytes);ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    io (fun () -> match drift with
      | Missing_epoch -> Unix.unlink epoch_path
      | Replaced_epoch -> write epoch_path (Yojson.Safe.to_string (`Assoc [
          "schema_version",`Int 1;"epoch",`String (Random_id.uuid_v7 ())])));
    run_worker fixture |> assert_unavailable;
    let after_owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
    check string "same physical Keeper/generation still addresses the original scope" scope (Capture.scope after_owner);
    check (option string) "epoch drift cannot change the original queue generation" generation
      (io (fun () -> Queue.read_generation ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get));
    check string "epoch drift cannot ACK or rewrite original pending inputs" queue_bytes
      (io (fun () -> Fs_compat.load_file (Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name)));
    check string "epoch drift preserves the exact original request and progress bytes" original_bytes
      (io (fun () -> Fs_compat.load_file path));
    check int "epoch drift cannot mint a replacement request in the same generation" 1
      (io (fun () -> Owner.load_scope ~store:fixture.store ~scope |> owned |> List.length));
    check (option string) "epoch drift grants no Memory disposition" memory_before
      (io (fun () -> Fs_compat.load_file_opt (Current.path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name)));
    check int "epoch drift starts no replacement provider" posts (F.post_count fixture.server)))

let test_actual_result_bridge_resumes_original_memory_lane ()=with_fixture (fun ~sw:_ fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
    `OK,F.openai_response (answer (fun _ -> true) capture));
  Fun.protect ~finally:(fun () ->
    Keeper_librarian_queue_signal.install (fun ~base_path:_ ~keeper_name:_ -> ());
    ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    ignore (run_worker fixture);
    Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await arrived);
    let unrelated_keeper="unrelated-librarian-queue" in
    let unrelated_path=Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:unrelated_keeper in
    let unrelated_before=io (fun () ->
      Queue.append ~keepers_dir:fixture.keepers_dir ~keeper_id:unrelated_keeper
        ~request_id:"unrelated-original" (fact "Unrelated original input")
      |> Result.map_error Queue.append_error_to_string |> get |> ignore;
      Fs_compat.load_file unrelated_path) in
    let resumed,complete=Eio.Promise.create () and wakes=ref [] in
    (* This is fixture scheduling, not production Queue_refresh.install. The
       actual bridge must choose the original Keeper; its callback submits
       the public Worker.run through the unchanged serialized Memory lane. *)
    Keeper_librarian_queue_signal.install (fun ~base_path ~keeper_name ->
      wakes:=(base_path,keeper_name):: !wakes;
      let scheduling=Memory_lane.submit ~base_path ~keeper_name (fun () ->
        match Worker.run ~base_path ~keeper_name with
        | outcome -> ignore (Eio.Promise.try_resolve complete (Ok outcome))
        | exception exn ->
          let backtrace=Printexc.get_raw_backtrace () in
          ignore (Eio.Promise.try_resolve complete (Error exn));
          Printexc.raise_with_backtrace exn backtrace) in
      match scheduling with
      | Memory_lane.Submitted | Coalesced -> ()
      | Ran_inline | Dropped ->
        ignore (Eio.Promise.try_resolve complete (Error (Failure "result hint did not enter the actual Memory lane"))));
    Eio.Switch.run (fun bridge_switch ->
      Server_librarian_addon_wake.install ~sw:bridge_switch ~config:fixture.config;
      ignore (Eio.Promise.try_resolve unblock ());
      Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
        Eio.Promise.await_exn resumed) |> assert_settled;
      Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name);
    check bool "actual result event signals only its strictly restored original Keeper" true
      (!wakes<>[] && List.for_all (fun name -> name=(fixture.base_path,keeper_name)) !wakes);
    check (list string) "the actual bridge wake commits the original answer to Memory" ["Durable A";"Durable B"]
      (io (fun () -> claims fixture.keepers_dir));
    check int "automatic original resumption ACKs only its actual candidates" 0
      (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
    check string "a result hint cannot consume another Keeper's pending inputs" unrelated_before
      (io (fun () -> Fs_compat.load_file unrelated_path))))

let test_configuration_wake_completes_before_concurrent_settle () =
  with_fixture (fun ~sw fixture ->
  drive_original_terminal fixture;
  let admission=match observed_originals fixture with
    | [record,_] -> record
    | [] | _::_::_ -> fail "expected one original admission" in
  let scope="wake-settle-fixture" and request_id="another-original" in
  io (fun () -> Owner.retain ~store:fixture.store ~scope ~request_id
    ~installation_id:"fixture" ~package_id:"fixture" ~tool:"fixture" ~summary:`Null
    ~request:(`Assoc ["input",`String "another original"]) |> owned);
  let record=match io (fun () -> Owner.discover ~store:fixture.store ~scope |> owned) with
    | [record] -> record | [] | _::_::_ -> fail "expected one other original" in
  let gate=Stdlib.Mutex.create () and changed=Condition.create () and released=ref false in
  let release ()=Stdlib.Mutex.protect gate (fun () -> released:=true; Condition.broadcast changed) in
  let inventoried,inventoried_resolver=Eio.Promise.create () in
  let scanning,scanning_resolver=Eio.Promise.create () in
  let moving,moving_resolver=Eio.Promise.create () in
  let restored=ref [] in
  Fun.protect ~finally:release (fun () ->
    Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
      Eio.Fiber.fork ~sw (fun () ->
        let result=Server_librarian_addon_wake.For_testing.discover ~config:fixture.config ~store:fixture.store
          ~event:Runtime.Configuration_observed
          ~after_inventory:(fun () ->
            Eio.Promise.resolve inventoried_resolver ();
            Stdlib.Mutex.protect gate (fun () ->
              while not !released do Condition.wait changed gate done))
          ~on_original:(fun original -> restored:=original.Owner.request_id:: !restored) in
        Eio.Promise.resolve scanning_resolver result);
      Eio.Promise.await inventoried;
      Eio.Fiber.fork ~sw (fun () ->
        let result=Owner.settle ~store:fixture.store ~date:"2026-10-23" record in
        Eio.Promise.resolve moving_resolver result);
      let key=Filename.concat (Unix.realpath (Store.root fixture.store)) "tool-request-settlement-barrier" in
      let rec await_mover () =
        if File_lock_eio.For_testing.holders_and_waiters ~lock_path:key=2 then ()
        else (Eio.Fiber.yield (); await_mover ()) in
      await_mover ();
      release ();
      let keepers,refusals,original_keepers=Eio.Promise.await scanning |> get in
      check bool "actual admission original enters the wake callback" true
        (List.mem admission.request_id !restored);
      check bool "actual nested Parts discovery keeps its Keeper" true (List.mem keeper_name keepers);
      check (list string) "the original itself supplies its Keeper" [keeper_name] original_keepers;
      check (list string) "the wake inventory has no refusals" [] refusals;
      (match Eio.Promise.await moving with
       | Ok () -> () | Error error -> fail (Owner.settle_error_to_string error));
      check bool "the other original moves after wake discovery" true
        (io (fun () -> Owner.settled ~store:fixture.store ~scope ~date:"2026-10-23" ~request_id |> owned)))))

let test_configuration_wake_keeps_queued_keeper_when_global_inventory_is_invalid ()=
  with_fixture (fun ~sw:_ fixture ->
  let queue_path=Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
  let queued_before=io (fun () -> Fs_compat.load_file queue_path) in
  let invalid_scope=Filename.concat (Store.root fixture.store) "tool-request-owners/unknown-scope" in
  io (fun () -> Fs_compat.mkdir_p invalid_scope);
  let require_invalid_inventory ()=match io (fun () -> Owner.discover_all ~store:fixture.store) with
    | Error _ -> ()
    | Ok _ -> fail "unknown scope must remain a strict original-inventory refusal" in
  require_invalid_inventory ();
  let woke,signal=Eio.Promise.create () and wakes=ref [] in
  let posts=F.post_count fixture.server in
  Fun.protect ~finally:(fun () ->
    Keeper_librarian_queue_signal.install (fun ~base_path:_ ~keeper_name:_ -> ())) (fun () ->
    Keeper_librarian_queue_signal.install (fun ~base_path ~keeper_name ->
      wakes:=(base_path,keeper_name):: !wakes;
      ignore (Eio.Promise.try_resolve signal ()));
    Eio.Switch.run (fun bridge_switch ->
      Server_librarian_addon_wake.install ~sw:bridge_switch ~config:fixture.config;
      (* The real configuration publisher emits the hint; the bridge, not this
         test callback, discovers the independently queued Keeper. *)
      set_enabled fixture false;
      Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await woke));
    check bool "global inventory corruption cannot discard the actual queued Keeper wake" true
      (!wakes<>[] && List.for_all (fun name -> name=(fixture.base_path,keeper_name)) !wakes);
    check string "wake discovery cannot consume or rewrite valid queued input" queued_before
      (io (fun () -> Fs_compat.load_file queue_path));
    require_invalid_inventory ();
    check int "a suspect scope grants no provider dispatch" posts (F.post_count fixture.server);
    check (list string) "a configuration wake grants no Memory effect" []
      (io (fun () -> claims fixture.keepers_dir))))

let test_purge_joins_provider_after_memory_unit_returned ()=with_fixture (fun ~sw:_ fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
    `OK,F.openai_response (answer (fun _ -> true) capture));
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    (match run_worker fixture with Worker.Pending _ -> ()
     | Disabled | Idle | Recheck_new_input | Settled _ | Addon_unattached _ | Unavailable _ ->
       fail "the actual ordinary Memory unit must return while its provider is pending");
    Eio.Promise.await arrived;
    Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
    check int "the real provider outlives the exited ordinary Memory unit" 1
      (Memory_lane.For_testing.external_active ~base_path:fixture.base_path ~keeper_name);
    let queue_path=Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
    let queue_before=io (fun () -> Fs_compat.load_file queue_path) in
    let posts=F.post_count fixture.server in
    let result=Memory_lane.with_librarian_purge ~base_path:fixture.base_path ~keeper_name (fun () ->
      check int "purge callback follows actual external cancellation and cleanup" 0
        (Memory_lane.For_testing.external_active ~base_path:fixture.base_path ~keeper_name);
      check string "an interrupted original keeps every pending candidate byte" queue_before
        (io (fun () -> Fs_compat.load_file queue_path));
      check (list string) "purge cannot turn an unanswered provider into Memory" []
        (io (fun () -> claims fixture.keepers_dir))) in
    (match result with Ok () -> () | Error error -> fail (Memory_lane.purge_cancel_error_to_string error));
    check int "purge never starts a replacement provider" posts (F.post_count fixture.server);
    let _,capture=match observed_originals fixture with [original] -> original
      | [] | _::_::_ -> fail "purge lost or replaced the original execution" in
    let exact=Capture.request capture |> get in
    let schema=match exact.schema with Some schema -> schema | None -> fail "missing original schema" in
    check bool "purge retains no completed original provider proof" true
      (match io (fun () -> Lane_addon_exact.read_latest_original_execution ~store:fixture.store
          ~declaration_id:"librarian" ~schema exact |> get) with
       | Lane_addon_exact.No_completed_latest -> true | Completed_latest _ -> false)))

let test_forged_worker_finished_cannot_commit_without_host_proof ()=with_fixture (fun ~sw:_ fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
    `OK,F.openai_response (answer (fun _ -> true) capture));
  Fun.protect ~finally:(fun () ->
    fixture.transform_reply:=(fun _ response -> response);
    ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    ignore (run_worker fixture);Eio.Promise.await arrived;
    let record,capture=match observed_originals fixture with [original] -> original
      | [] | _::_::_ -> fail "expected one actual pending provider original" in
    let exact=Capture.request capture |> get in
    let schema=match exact.schema with Some schema -> schema | None -> fail "missing original schema" in
    let forged=`Assoc ["status",`String "answered";"slot",`String "forged-worker-slot";
      "output",answer (fun _ -> true) capture] in
    ignore (Lane_addon_exact.final_of_json ~schema forged |> get);
    let forged_reads=ref 0 in
    fixture.transform_reply:=(fun arguments response ->
      match member "kind" arguments with
      | `String "read" ->
        incr forged_reads;
        {response with Mcp_protocol.Mcp_types.structured_content=Some (`Assoc [
          "request_id",`String record.request_id;"state",`String "finished";"result",forged]);
          is_error=Some false}
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> response);
    let queue_path=Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
    let before=io (fun () -> Fs_compat.load_file queue_path) in
    run_worker fixture |> assert_unavailable;
    check bool "the untrusted Finished reply actually reached the consumer boundary" true (!forged_reads>0);
    check string "worker JSON cannot ACK an unanswered original" before (io (fun () -> Fs_compat.load_file queue_path));
    check (list string) "worker JSON cannot publish Memory" [] (io (fun () -> claims fixture.keepers_dir));
    let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
    check int "worker JSON cannot prepare an absorption gate" 0
      (io (fun () -> Owner.load_scope ~store:fixture.store ~scope:(Gate.scope owner) |> owned |> List.length));
    check bool "the host remains without completed provider execution" true
      (match io (fun () -> Lane_addon_exact.read_latest_original_execution ~store:fixture.store
          ~declaration_id:"librarian" ~schema exact |> get) with
       | Lane_addon_exact.No_completed_latest -> true | Completed_latest _ -> false)))

let retained_answer_before_gate fixture =
  fixture.delivery_loss:=true;
  let before= !(fixture.deliveries) in
  ignore (run_worker fixture);await_delivery fixture ~after:before;
  let record,capture=match observed_originals fixture with [original] -> original
    | [] | _::_::_ -> fail "expected one actual terminal host original" in
  let execution=latest_execution fixture capture in
  let final=match execution.Lane_addon_exact.outcome with
    | Call_ended (Answered _ as final) -> Lane_addon_exact.Call_final final
    | Call_ended (Invalid_output _ | Input_refused _ | Output_limit_reached _) | Call_refused _ ->
      fail "controlled real provider did not answer the original" in
  record,capture,final
let retain_judgment fixture record final = io (fun () ->
  match Owner.advance ~store:fixture.store ~expected:record
    ~event:(Progress.Judgment_retained (Lane_addon_exact.final_to_json final)) with
  | Ok (Owner.Stored next | Already_stored next) -> next
  | Ok (Unconfirmed detail) -> fail detail
  | Error error -> fail (Owner.update_error_to_string error))
let test_mismatched_retained_judgment_cannot_borrow_host_proof ()=with_fixture (fun ~sw:_ fixture ->
  let record,capture,final=retained_answer_before_gate fixture in
  let mismatched=match final with
    | Lane_addon_exact.Call_final (Answered answered) ->
      Lane_addon_exact.Call_final (Answered {answered with slot=answered.slot ^ "-different-origin"})
    | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
    | Outcome_unknown | Not_allowed _ | Request_id_reused -> fail "expected an actual answered final" in
  memory_action fixture (fun () -> ignore (retain_judgment fixture record mismatched));
  let posts=F.post_count fixture.server in
  run_worker fixture |> assert_unavailable;
  check int "a different final cannot borrow or repeat the real provider" posts (F.post_count fixture.server);
  check int "a different final consumes no candidate" 2
    (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
  check (list string) "a different final publishes no Memory" [] (io (fun () -> claims fixture.keepers_dir));
  check bool "the genuine host final is still independently confirmable" true
    (io (fun () -> Capture.confirm_final ~store:fixture.store capture final=Ok ())))

let test_admission_confirms_a_final_the_host_never_retained ()=with_fixture (fun ~sw:_ fixture ->
  let _record,capture,answered=retained_answer_before_gate fixture in
  let never_retained=Store.create ~root:(Filename.concat fixture.base_path "never-retained-store") in
  let refused kind=Lane_addon_exact.Call_final (Input_refused kind) in
  let confirmed final=io (fun () -> Capture.confirm_final ~store:never_retained capture final=Ok ()) in
  check bool "the worker's unlistable-request refusal is confirmed without a host record" true
    (confirmed (refused Lane_addon_exact.Request_body_refused));
  check bool "an answer still needs its host terminal" false (confirmed answered);
  check bool "another input refusal still needs its host terminal" false
    (confirmed (refused Lane_addon_exact.Input_capacity));
  check bool "the exception does not apply once the host holds a different terminal" false
    (io (fun () -> Capture.confirm_final ~store:fixture.store capture
       (refused Lane_addon_exact.Request_body_refused)=Ok ())))

type root_publication_cut = Before_child | Child_before_ack | Acknowledged_then_missing
let test_original_gate_root_publication_recovery cut ()=with_fixture (fun ~sw:_ fixture ->
  let record,capture,final=retained_answer_before_gate fixture in
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let request_id=Random_id.uuid_v7 () in
  let parent=memory_action fixture (fun () ->
    let record=retain_judgment fixture record final in
    let authority=Keeper_librarian_absorb_gate.resolve ~keeper_id:keeper_name in
    match Commit.begin_gate ~store:fixture.store ~owner ~capture ~record
      ~gate_root_id:request_id ~authority |> get with
    | Commit.Prepared parent -> parent
    | Reload_original -> fail "the first real gate preparation must be newly retained") in
  let successor=match Progress.preparation parent.progress with
    | Some (Progress.Preparation_pending successor) -> successor
    | None | Some (Preparation_confirmed _) -> fail "the original preparation intent is absent or already acknowledged" in
  check string "the interrupted intent retains its one immutable child identity" request_id successor.request_id;
  check bool "preparation never claims a Memory disposition started" true
    (match Progress.phase parent.progress with Progress.Judged _ -> true
     | Captured | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false);
  check int "preparation alone cannot consume a candidate" 2
    (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
  (match cut with
   | Before_child -> ()
   | Child_before_ack -> io (fun () ->
       Owner.retain ~store:fixture.store ~scope:(Gate.scope owner) ~request_id
         ~installation_id:parent.installation_id ~package_id:parent.package_id ~tool:parent.tool ~summary:`Null
         ~request:successor.request |> owned)
   | Acknowledged_then_missing ->
     memory_action fixture (fun () -> ignore (Gate.recover_root ~store:fixture.store ~owner ~capture |> get));
     io (fun () -> Unix.unlink (original_path fixture ~scope:(Gate.scope owner) ~request_id)));
  let posts=F.post_count fixture.server in
  set_enabled fixture false;
  (match cut with
   | Before_child | Child_before_ack ->
     run_worker fixture |> assert_settled;
     let root=io (fun () -> Owner.load ~store:fixture.store ~scope:(Gate.scope owner) ~request_id |> owned) in
     let root=match root with Some root -> root | None -> fail "the same original gate was not recovered" in
     check json "local recovery uses the full original immutable child request" successor.request root.request;
     check int "local recovery publishes exactly the original child" 1
       (io (fun () -> Owner.load_scope ~store:fixture.store ~scope:(Gate.scope owner) |> owned |> List.length));
     check int "original receipt-backed commit ACKs both candidates" 0
       (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
     check (list string) "recovered original gate permits the real Memory disposition" ["Durable A";"Durable B"]
       (io (fun () -> claims fixture.keepers_dir))
   | Acknowledged_then_missing ->
     run_worker fixture |> assert_unavailable;
     check int "an acknowledged missing child is never recreated" 0
       (io (fun () -> Owner.load_scope ~store:fixture.store ~scope:(Gate.scope owner) |> owned |> List.length));
     check int "missing acknowledged proof keeps both candidates pending" 2
       (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
     check (list string) "missing acknowledged proof grants no Memory disposition" []
       (io (fun () -> claims fixture.keepers_dir)));
  check int "publication recovery and refusal never repeat the original provider" posts (F.post_count fixture.server))

let test_production_refresh_new_tail_quiesces_while_provider_pending ()=with_fixture (fun ~sw:_ fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  fixture.set_response (fun capture ->
    ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release;
    `OK,F.openai_response (answer (fun _ -> true) capture));
  Fun.protect ~finally:(fun () ->
    Keeper_librarian_queue_signal.install (fun ~base_path:_ ~keeper_name:_ -> ());
    ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    (match run_worker fixture with Worker.Pending _ -> ()
     | Disabled | Idle | Recheck_new_input | Settled _ | Addon_unattached _ | Unavailable _ ->
       fail "the original actual provider must remain pending");
    Eio.Promise.await arrived;
    Keeper_librarian_queue_refresh.install ();
    io (fun () -> ignore (append fixture.keepers_dir "new-tail" "Durable tail"));
    Keeper_librarian_queue_signal.changed ~base_path:fixture.base_path ~keeper_name;
    (* This awaits the production consumer, not a synthetic outcome callback.
       A self-waking refresh never releases its drain while the HTTP answer
       remains blocked; only the enclosing fixture bounds a broken test. *)
    Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
    check (list string) "a later tail cannot ACK any pending original input" ["a";"b";"new-tail"]
      (io (fun () -> List.map (fun (row:Queue.candidate) -> row.request_id) (pending_rows fixture.keepers_dir)));
    check (list string) "refresh does not turn pending provider work into Memory" []
      (io (fun () -> claims fixture.keepers_dir));
    check int "the original provider remains the only active external execution" 1
      (Memory_lane.For_testing.external_active ~base_path:fixture.base_path ~keeper_name);
    check int "the pending tail starts no replacement provider" 1 (F.post_count fixture.server)))

let only_live_instance fixture =
  Runtime.dispatch ~access:Lane_addon_sources.Operator_configuration ~config:fixture.config
    ~operation:Runtime.Inspect (`Assoc []) |> Result.map_error Runtime.error_to_string |> get
  |> member "instances" |> Yojson.Safe.Util.to_list
  |> function [instance] -> instance | [] | _::_::_ -> fail "expected one shared configured worker incarnation"
let test_purged_original_does_not_block_another_keeper ()=with_fixture (fun ~sw:_ fixture ->
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  let second_keeper="librarian-after-purged-owner" in
  fixture.set_response (fun capture ->
    let actual=Keeper_identity.Keeper_id.to_string (Capture.input capture).Keeper_librarian.keeper_id in
    if actual=keeper_name then (
      ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release);
    `OK,F.openai_response (answer (fun _ -> true) capture));
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    (match run_worker fixture with Worker.Pending _ -> ()
     | Disabled | Idle | Recheck_new_input | Settled _ | Addon_unattached _ | Unavailable _ -> fail "first actual provider must be pending");
    Eio.Promise.await arrived;
    let record,capture=match observed_originals fixture with [original] -> original
      | [] | _::_::_ -> fail "expected the one original belonging to the purged Keeper" in
    let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
    let original_file=original_path fixture ~scope:(Capture.scope owner) ~request_id:record.request_id in
    let original_bytes=io (fun () -> Fs_compat.load_file original_file) in
    let incarnation=member "instance_id" (only_live_instance fixture) in
    let purged=Memory_lane.with_librarian_purge ~base_path:fixture.base_path ~keeper_name (fun () ->
      check int "deletion follows real original provider cancellation and cleanup" 0
        (Memory_lane.For_testing.external_active ~base_path:fixture.base_path ~keeper_name);
      io (fun () ->
        Unix.unlink (Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name);
        Unix.unlink (Current.epoch_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name);
        let memory=Current.path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
        match Fs_compat.load_file_opt memory with None -> () | Some _ -> Unix.unlink memory)) in
    (match purged with Ok () -> () | Error error -> fail (Memory_lane.purge_cancel_error_to_string error));
    (* The Python worker keeps A's unanswered request. Neither its state nor
       the host original Store is cleared to let B pass. *)
    install_keeper ~config:fixture.config ~name:second_keeper ~trace_id:"second-librarian-original-owner";
    io (fun () ->
      Queue.append ~keepers_dir:fixture.keepers_dir ~keeper_id:second_keeper
        ~request_id:"second-original" (fact "Durable second Keeper")
        |> Result.map_error Queue.append_error_to_string |> get |> ignore);
    let rec drive_second ()=
      let before= !(fixture.deliveries) in
      let outcome=memory_action ~keeper_name:second_keeper fixture (fun () ->
        Worker.run ~base_path:fixture.base_path ~keeper_name:second_keeper) in
      match outcome with
      | Worker.Settled _ -> ()
      | Pending _ | Recheck_new_input -> await_delivery fixture ~after:before;drive_second ()
      | Disabled | Idle | Addon_unattached _ | Unavailable _ -> fail "a stale original prevented the other Keeper from making progress" in
    drive_second ();
    let second_record=io (fun () -> originals_for ~keeper_name:second_keeper
      fixture.base_path fixture.keepers_dir fixture.store) |> function
      | [record,_] -> record | [] | _::_::_ -> fail "expected the second Keeper's one original" in
    check bool "the same actual worker lists stale A beside B without clearing A" true
      (List.exists (fun listing ->
        let requests=member "requests" listing |> Yojson.Safe.Util.to_list in
        let includes id=List.exists (fun request -> member "request_id" request=`String id) requests in
        includes record.request_id && includes second_record.request_id) !(fixture.host_listings));
    check json "the second Keeper uses the same live configured worker" incarnation
      (member "instance_id" (only_live_instance fixture));
    check (list string) "the second Keeper commits its actual complete provider answer" ["Durable second Keeper"]
      (io (fun () -> match Current.read_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:second_keeper |> get with
        | None -> [] | Some snapshot -> List.map (fun (f:Types.fact) -> f.claim) snapshot.facts));
    check bool "the second Keeper ACK follows its real Memory receipt" true
      (io (fun () -> Queue.read_pending ~keepers_dir:fixture.keepers_dir ~keeper_id:second_keeper |> get |> Option.is_none));
    check string "the purged Keeper's original request and progress remain inspectable" original_bytes
      (io (fun () -> Fs_compat.load_file original_file));
    let issue=member "issue" (member "host_requests" (only_live_instance fixture)) in
    check string "the stale original retains its request-local host diagnostic" "exact_record_failed"
      (member "kind" issue |> Yojson.Safe.Util.to_string);
    check string "the diagnostic remains bound to the purged original" record.request_id
      (member "request_id" issue |> Yojson.Safe.Util.to_string);
    let exact=Capture.request capture |> get in
    let schema=match exact.schema with Some schema -> schema | None -> fail "missing original schema" in
    check bool "progress by another Keeper cannot invent a completed proof for the purged original" true
      (match io (fun () -> Lane_addon_exact.read_latest_original_execution ~store:fixture.store
          ~declaration_id:"librarian" ~schema exact |> get) with
       | Lane_addon_exact.No_completed_latest -> true | Completed_latest _ -> false)))

let await_installation_detached fixture =
  Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
    let rec loop ()=
      let snapshot=Runtime.tool_export_snapshot ~config:fixture.config
        ~access:Lane_addon_sources.Operator_configuration ~reserved:[] in
      if List.exists (fun (export : Runtime.tool_export) -> export.tool.name=Capture.tool) snapshot.exports
         || Lane_addon_unready.declaring ~name:Capture.tool snapshot.unready <> []
      then (Eio.Time.sleep fixture.clock 0.02;loop ()) in
    loop ())
let test_unattached_addon_reports_off_and_keeps_candidates ()=with_fixture (fun ~sw:_ fixture ->
  set_enabled fixture false;
  (* Retiring is unready, not absent. Off is asserted after the original
     installation has finished its real lifecycle cleanup. *)
  await_installation_detached fixture;
  let posts=F.post_count fixture.server in
  (match run_worker fixture with
   | Worker.Addon_unattached {pending} -> check int "every explicit candidate is reported waiting" 2 pending
   | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Unavailable _ ->
     fail "a missing keeper-librarian Add-on must report explicit admission off");
  check int "no original capture is minted without the Add-on" 0 (List.length (observed_originals fixture));
  check int "no provider call starts without the Add-on" posts (F.post_count fixture.server);
  check int "the explicit candidates stay queued" 2 (io (fun () -> List.length (pending_rows fixture.keepers_dir))))

let test_attach_wakes_persisted_keeper_without_queue_or_original ()=
  with_fixture ~initial:[] (fun ~sw:_ fixture ->
  set_enabled fixture false;
  await_installation_detached fixture;
  let names=io (fun () -> Keeper_meta_store.persisted_keeper_names_read_only_result fixture.config |> get) in
  check bool "the history owner exists independently of a queue" true (List.mem keeper_name names);
  check (list string) "no explicit queue can supply this wake" []
    (io (fun () -> Queue.list_keeper_ids ~keepers_dir:fixture.keepers_dir |> get));
  check int "no retained original can supply this wake" 0
    (io (fun () -> Owner.discover_all ~store:fixture.store |> owned |> List.length));
  let attached,signal=Eio.Promise.create () in
  let posts=F.post_count fixture.server in
  Fun.protect ~finally:(fun () ->
    Keeper_librarian_queue_signal.install (fun ~base_path:_ ~keeper_name:_ -> ())) (fun () ->
    Keeper_librarian_queue_signal.install (fun ~base_path ~keeper_name:observed ->
      check string "wake keeps the served workspace" fixture.base_path base_path;
      check string "wake keeps the persisted owner" keeper_name observed;
      match Keeper_librarian_addon.resolve ~config:fixture.config ~reserved:[] Keeper_librarian_addon.Durable with
      | Ok _ -> ignore (Eio.Promise.try_resolve signal ())
      | Error (Unattached | Unready _ | Export_conflict _ | Wrong_package _ | Manual_installation) -> ());
    Eio.Switch.run (fun bridge_switch ->
      Server_librarian_addon_wake.install ~sw:bridge_switch ~config:fixture.config;
      set_enabled fixture true;
      Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await attached)));
  check int "availability discovery sends no provider request" posts (F.post_count fixture.server);
  check (list string) "availability discovery fabricates no admission queue" []
    (io (fun () -> Queue.list_keeper_ids ~keepers_dir:fixture.keepers_dir |> get));
  check int "availability discovery fabricates no original" 0
    (io (fun () -> Owner.discover_all ~store:fixture.store |> owned |> List.length)))

(* The work under test can block inside a system-thread mutex. An Eio timeout
   cannot join a truly deadlocked system thread, so run this one scenario in
   its own process group and kill it if the outer hang guard expires. *)
let run_guarded_scenario key =
  let program = "import os,signal,subprocess,sys\n" ^
    "env=os.environ.copy(); env[sys.argv[2]]='1'\n" ^
    "child=subprocess.Popen([sys.argv[1]],env=env,start_new_session=True)\n" ^
    "try: code=child.wait(timeout=180)\n" ^
    "except subprocess.TimeoutExpired:\n" ^
    " os.killpg(child.pid,signal.SIGKILL); child.wait(); sys.exit(124)\n" ^
    "sys.exit(code if code>=0 else 128-code)\n" in
  let exe = Unix.realpath Sys.executable_name in
  let pid=Unix.create_process "python3" [|"python3";"-c";program;exe;key|]
    Unix.stdin Unix.stdout Unix.stderr in
  match snd (Unix.waitpid [] pid) with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED 124 -> Alcotest.fail "scenario exceeded the process hang guard"
  | Unix.WEXITED code -> Alcotest.fail (Printf.sprintf "scenario exited %d" code)
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
    Alcotest.fail (Printf.sprintf "scenario ended with signal %d" signal)

let () =
  if Sys.getenv_opt "MASC_TEST_46252_WAKE" = Some "1" then (
    test_configuration_wake_completes_before_concurrent_settle (); exit 0);
  run "Actual Addon Librarian explicit-candidate owner" ["production",[
  test_case "actual Memory lane, worker, HTTP, domain validation and receipt-backed ACK" `Quick test_actual_happy_path;
  test_case "unchanged semantic deferral preserves the same original" `Quick test_unchanged_deferred_does_not_remint;
  test_case "new tail rejudges the complete old sparse gap against current Memory" `Quick test_gap_and_new_tail_are_rejudged_together;
  test_case "original host answer recovers locally while Addon is Off" `Quick test_retained_host_terminal_commits_off;
  test_case "actual capacity plus quota preserves the original whole batch" `Quick (test_actual_mixed_walk_blocks_partition Quota);
  test_case "actual capacity plus invalid output preserves the original whole batch" `Quick (test_actual_mixed_walk_blocks_partition Invalid);
  test_case "actual size split keeps sparse whole inputs and rereads Memory between siblings" `Quick test_sparse_whole_candidate_partition_reads_fresh_memory;
  test_case "actual Memory-lane cancellation after worker submission cannot consume candidates" `Quick test_purge_cancels_waiting_memory_unit_without_consumption;
  test_case "complete original corruption blocks receipt-backed ACK" `Quick test_invalid_original_blocks_receipt_backed_ack;
  test_case "a missing Finished gate refuses without replacement" `Quick test_missing_finished_gate_is_not_recreated;
  test_case "missing epoch cannot hide or replace a dispatched original" `Quick (test_original_epoch_drift_cannot_remint Missing_epoch);
  test_case "replaced epoch cannot hide or replace a dispatched original" `Quick (test_original_epoch_drift_cannot_remint Replaced_epoch);
  test_case "actual result bridge resumes only the original serialized Memory lane" `Quick test_actual_result_bridge_resumes_original_memory_lane;
  test_case "configuration wake completes its admission discovery before a concurrent settle" `Quick
    (fun () -> run_guarded_scenario "MASC_TEST_46252_WAKE");
  test_case "configuration wake preserves queued Keepers despite a corrupt global original inventory" `Quick
    test_configuration_wake_keeps_queued_keeper_when_global_inventory_is_invalid;
  test_case "purge joins the actual provider after the Memory unit returned Pending" `Quick test_purge_joins_provider_after_memory_unit_returned;
  test_case "forged worker Finished cannot commit without original host execution proof" `Quick test_forged_worker_finished_cannot_commit_without_host_proof;
  test_case "mismatched retained final cannot borrow real original host proof" `Quick test_mismatched_retained_judgment_cannot_borrow_host_proof;
  test_case "admission confirms a final the host never retained" `Quick test_admission_confirms_a_final_the_host_never_retained;
  test_case "pending first gate intent recovers the same absent child while Off" `Quick (test_original_gate_root_publication_recovery Before_child);
  test_case "published first gate before ACK recovers the same child while Off" `Quick (test_original_gate_root_publication_recovery Child_before_ack);
  test_case "acknowledged missing first gate refuses without replacement" `Quick (test_original_gate_root_publication_recovery Acknowledged_then_missing);
  test_case "production refresh quiesces with a new tail while its provider remains pending" `Quick test_production_refresh_new_tail_quiesces_while_provider_pending;
  test_case "a purged pending original cannot block another Keeper in the same shared worker" `Quick test_purged_original_does_not_block_another_keeper;
  test_case "attachment wakes a persisted history owner without queue or original" `Quick test_attach_wakes_persisted_keeper_without_queue_or_original;
  test_case "no attached Add-on reports explicit admission off and keeps every candidate" `Quick test_unattached_addon_reports_off_and_keeps_candidates]]
