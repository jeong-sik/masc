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
module Closure = Keeper_librarian_admission_closure
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
  let inventory=Parts.discover ~store ~owner |> get in
  Owner.load_scope ~store ~scope:(Capture.scope owner) |> owned |> List.map (fun record ->
    let capture=Capture.restore ~owner ~load_parent:(Parts.load_parent inventory) record |> get in record,capture)
let originals=originals_for ~keeper_name
let new_claim claim=`Assoc ["claim",`String claim;"category",`String "fact";
  "board_post_id",`Null;"board_comment_id",`Null;"supersedes",`Null;"absorbs",`List []; "evidence", `Assoc ["conversation",`List [];"tools",`List [];"counterpart",`Bool false;"task_contexts",`Bool false]]
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
      call_exported_tool=(fun ~on_result ~on_dispatch ~authorize ~principal ~name ~arguments ->
        let result=Protocol.call_exported_tool ~on_result ~on_dispatch ?authorize ~principal protocol ~name ~arguments
          |> Result.map_error invocation_error in
        (match member "kind" arguments with `String "submit" -> after_submit ()
         | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> ());
        Result.map (transform_reply arguments) result);
      operator_schema=(fun () -> None);
      observation_effect=(fun _ -> Lane_addon_call_context.May_change);
      call_operator=(fun ~admit:_ ~arguments:_ -> Error Masc.Lane_addon_worker_protocol.Operator_unavailable);
      action_schema=(fun () -> Protocol.action_schema protocol);
      act=(fun ~arguments -> Protocol.act protocol ~arguments |> Result.map_error protocol_error);
      stop=(fun () -> Protocol.close protocol;Ok (Lane_addon_lifecycle.Released
        {engine=Lane_addon_lifecycle.Docker_engine "fixture-resource-launch";container_id=Some instance_id}));
      host=Some {list_requests=(fun () ->
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
        | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Awaiting_worker _ ->
          await_delivery fixture ~after:before;loop () in loop ())
let assert_settled = function Worker.Settled _ -> ()
  | Disabled | Idle | Recheck_new_input | Pending _ | Awaiting_worker _ | Addon_unattached _ | Unavailable _ -> fail "actual original decision did not commit Memory"
let settled = function Worker.Settled _ -> true
  | Disabled | Idle | Recheck_new_input | Pending _ | Awaiting_worker _ | Addon_unattached _ | Unavailable _ -> false
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
      Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
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

let closure_inputs fixture = io (fun () ->
  let owner=original_owner fixture.base_path fixture.keepers_dir in
  let inventory=Parts.discover ~store:fixture.store ~owner |> get in
  let candidates=Parts.completion_candidates inventory
    |> Option.to_result ~none:"fixture forest is not structurally complete" |> get in
  let originals=List.concat_map (fun (kind,scope) ->
    Owner.load_scope ~store:fixture.store ~scope |> owned
    |> List.map (fun record -> kind,record))
    [Closure.Part,Parts.scope owner;Closure.Partition,Parts.partition_scope owner;
     Closure.Execution,Capture.scope owner;Closure.Gate,Gate.scope owner] in
  owner,candidates,originals)
let closure_manifest fixture =
  let owner,candidates,originals=closure_inputs fixture in
  let manifest=io (fun () -> Closure.retain ~store:fixture.store ~owner
    ~request_id:(Capture.fresh_request_id owner) ~candidates ~originals |> get) in
  owner,manifest
let preflight_scan fixture = io (fun () ->
  Lane_addon_store_preflight.scan ~validate_tool_request:Keeper_librarian_store_preflight.preflight
    Lane_addon_store_preflight.Store.Tool_request_owners ~base_path:fixture.base_path)
let closure_preflight fixture = preflight_scan fixture |> get
let close_member fixture manifest member = io (fun () ->
  Owner.settle ~store:fixture.store ~date:(Closure.date manifest) (Closure.member_record member)
  |> Result.map_error Owner.settle_error_to_string |> get)
(* An original's Exact record and proof link, as the store keeps them. *)
let exact_files fixture capture =
  let request=Capture.request capture |> get in
  let root=Store.root fixture.store in
  Filename.concat root (Store.exact_request_path ~declaration_id:"librarian" ~request_id:request.request_id),
  Filename.concat root (Lane_addon_exact.Retained_key.proof_path
    (Lane_addon_exact.Retained_key.of_request ~declaration_id:"librarian" request))
let with_field name value = function
  | `Assoc fields when List.mem_assoc name fields ->
    `Assoc (List.map (fun (key,old) -> key,if String.equal key name then value else old) fields)
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    fail ("expected a JSON object with the field " ^ name)
let scope_directory fixture scope=Filename.concat (Store.root fixture.store)
  (Filename.concat Store.tool_request_owners_directory (Store.digest scope))
(* The one refusal of a record kept in [scope]: an original whose consumer
   stops on the Exact files it reads. A gate follows its parent, so the scan
   also refuses the gate, in the gate's scope. *)
let exact_refusal fixture scope (report:Lane_addon_store_preflight.report)=
  match List.filter (fun (refusal:Lane_addon_store_preflight.refusal) ->
      String.equal (Filename.dirname refusal.path) (scope_directory fixture scope)) report.refusals with
  | [{Lane_addon_store_preflight.decoder=Tool_request_exact_reads;_} as refusal] -> refusal
  | [] | _::_ -> fail "expected one refusal in the scope, of an original on the Exact files it reads"
(* The scan refuses the owner's original, deletes its scope, and refuses no
   record outside the original and its gate. *)
let refuses_owner fixture owner (report:Lane_addon_store_preflight.report)=
  let scope=Capture.scope owner in
  let owned=[scope_directory fixture scope;scope_directory fixture (Gate.scope owner)] in
  List.for_all (fun (refusal:Lane_addon_store_preflight.refusal) ->
      List.mem (Filename.dirname refusal.path) owned) report.refusals
  && List.mem (scope_directory fixture scope) (exact_refusal fixture scope report).delete
let test_closure_projection_preserves_each_partial_move ()=with_fixture (fun ~sw:_ fixture ->
  drive_until fixture settled |> assert_settled;
  let owner,manifest=closure_manifest fixture in
  let posts=F.post_count fixture.server in
  let memory_path=Current.path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
  let queue_path=Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
  let memory_before=io (fun () -> Fs_compat.load_file memory_path) in
  let queue_before=io (fun () -> Fs_compat.load_file queue_path) in
  let manifest=memory_action fixture (fun () -> io (fun () -> Closure.intend ~store:fixture.store manifest |> get)) in
  (match Progress.phase (Closure.record manifest).progress with
   | Progress.Committing _ -> ()
   | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Commit_unknown _ | Finished _
   | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> fail "closure observed completion before moving members");
  List.iter (fun member ->
    memory_action fixture (fun () -> close_member fixture manifest member);
    let report=closure_preflight fixture in
    check int "each interrupted movement remains compatible" 0 (List.length report.refusals);
    let archived=io (fun () ->
      let record=Closure.member_record member in
      Owner.load_settled ~store:fixture.store ~scope:(Owner.Record.scope record)
        ~date:(Closure.date manifest) ~request_id:(Owner.Record.request_id record) |> owned) in
    check bool "a moved member has exact archived metadata" true
      (match archived with None -> false | Some actual ->
        Yojson.Safe.equal (Owner.record_to_json actual) (Owner.record_to_json (Closure.member_record member)));
    let sweep=io (fun () -> Server_settled_archive_sweep.run ~store:fixture.store
      |> Result.map_error Server_settled_archive_sweep.error_to_string |> get) in
    check int "the live closure protects every required archive marker" 0 sweep.removed_records)
    (Closure.members manifest);
  let manifest=memory_action fixture (fun () -> io (fun () -> Closure.confirm ~store:fixture.store manifest |> get)) in
  check int "the after-state remains readable before the anchor moves" 0
    (List.length (closure_preflight fixture).refusals);
  memory_action fixture (fun () -> io (fun () ->
    Owner.settle ~store:fixture.store ~date:(Closure.date manifest) (Owner.listed (Closure.record manifest))
    |> Result.map_error Owner.settle_error_to_string |> get));
  check int "the closure leaves no active original" 0
    (io (fun () -> Owner.discover_all ~store:fixture.store |> owned |> List.length));
  check int "the finished forest is absent" 0
    (io (fun () -> Parts.discover ~store:fixture.store ~owner |> get |> Parts.roots |> List.length));
  check string "closing never rewrites Memory" memory_before (io (fun () -> Fs_compat.load_file memory_path));
  check string "closing never acknowledges a queue row" queue_before (io (fun () -> Fs_compat.load_file queue_path));
  check int "closing and preflight never dispatch" posts (F.post_count fixture.server))
let test_captured_closure_cannot_explain_a_missing_member ()=with_fixture (fun ~sw:_ fixture ->
  drive_until fixture settled |> assert_settled;
  let _,manifest=closure_manifest fixture in
  memory_action fixture (fun () -> close_member fixture manifest (List.hd (Closure.members manifest)));
  check bool "retaining a manifest is not permission to omit a member" true
    ((closure_preflight fixture).refusals<>[]))
let test_closing_manifest_does_not_hide_changed_or_missing_evidence missing ()=with_fixture (fun ~sw:_ fixture ->
  drive_until fixture settled |> assert_settled;
  let _,manifest=closure_manifest fixture in
  let manifest=memory_action fixture (fun () -> io (fun () -> Closure.intend ~store:fixture.store manifest |> get)) in
  let member=List.hd (Closure.members manifest) in
  let record=Closure.member_record member in
  if missing then (
    memory_action fixture (fun () -> close_member fixture manifest member);
    io (fun () -> Sys.remove (Filename.concat (Store.root fixture.store)
      (Store.tool_request_archive_record_path ~scope:(Owner.Record.scope record)
        ~date:(Closure.date manifest) ~request_id:(Owner.Record.request_id record)))))
  else io (fun () ->
    let json=Owner.record_to_json record in
    let json=match json with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,if key="tool" then `String "changed" else value) fields)
      | _ -> fail "owner metadata is not an object" in
    Store.save_tool_request_owner fixture.store ~scope:(Owner.Record.scope record)
      ~request_id:(Owner.Record.request_id record) json |> get);
  check bool "the closure cannot borrow missing or changed evidence" true
    ((closure_preflight fixture).refusals<>[]))
let test_foreign_closure_id_is_refused_before_publication ()=with_fixture (fun ~sw:_ fixture ->
  drive_until fixture settled |> assert_settled;
  let owner,candidates,originals=closure_inputs fixture in
  let other=match Capture.owner_to_json owner with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
        key,if key="keeper_id" then `String "other-closure-owner" else value) fields)
      |> Capture.owner_of_json |> get
    | _ -> fail "owner is not an object" in
  let result=memory_action fixture (fun () -> io (fun () -> Closure.retain ~store:fixture.store ~owner
    ~request_id:(Capture.fresh_request_id other) ~candidates ~originals)) in
  check bool "a foreign ID is refused" true (Result.is_error result);
  check int "no bad closure record is published" 0
    (io (fun () -> Owner.discover ~store:fixture.store ~scope:(Closure.scope owner) |> owned |> List.length));
  check bool "no closure body directory is created" false (io (fun () ->
    Sys.file_exists (Filename.concat (Store.root fixture.store)
      (Filename.concat Store.tool_request_bodies_directory (Store.digest (Closure.scope owner)))))))
let test_preflight_rechecks_a_closure_created_after_an_empty_observation ()=with_fixture (fun ~sw:_ fixture ->
  drive_until fixture settled |> assert_settled;
  let validate=Keeper_librarian_store_preflight.validator ()
    ~read_fence:(Store.load_history_fence fixture.store)
    ~read_resolution:(Store.load_history_resolution fixture.store) in
  let read ~scope ~request_id=Owner.load ~store:fixture.store ~scope ~request_id |> Result.map_error Owner.error_to_string in
  let read_scope ~scope=Owner.load_scope ~store:fixture.store ~scope |> Result.map_error Owner.error_to_string in
  let body=Owner.Published_reader.create ~read_body:(fun ~scope ~request_digest ->
    Store.load_tool_request_body fixture.store ~scope ~request_digest) in
  let read_body=Owner.Published_reader.request body in
  let read_archive ~scope ~date ~request_id=Owner.load_settled ~store:fixture.store ~scope ~date ~request_id
    |> Result.map_error Owner.error_to_string in
  let original=match observed_originals fixture with (record,_)::_ -> record | [] -> fail "no original" in
  io (fun () -> validate ~read ~read_scope ~read_body ~read_archive original |> get);
  let _,manifest=closure_manifest fixture in
  let manifest=memory_action fixture (fun () -> io (fun () -> Closure.intend ~store:fixture.store manifest |> get)) in
  let member=List.hd (Closure.members manifest) in
  memory_action fixture (fun () -> close_member fixture manifest member);
  io (fun () -> validate ~read ~read_scope ~read_body ~read_archive original |> get);
  io (fun () -> validate ~read ~read_scope ~read_body ~read_archive (Closure.record manifest) |> get);
  let record=Closure.member_record member in
  io (fun () -> Sys.remove (Filename.concat (Store.root fixture.store)
    (Store.tool_request_archive_record_path ~scope:(Owner.Record.scope record)
      ~date:(Closure.date manifest) ~request_id:(Owner.Record.request_id record))));
  List.iter (fun record ->
    check bool "a previously empty scope grants no stale closure verdict" true
      (io (fun () -> validate ~read ~read_scope ~read_body ~read_archive record |> Result.is_error)))
    [Closure.record manifest;original])
let test_owner_recovers_a_partial_closure prefix ()=with_fixture (fun ~sw:_ fixture ->
  drive_until fixture settled |> assert_settled;
  let original=match observed_originals fixture with (record,_)::_ -> record | [] -> fail "no original" in
  let body_path=Filename.concat (Store.root fixture.store)
    (Store.tool_request_body_path ~scope:original.scope ~request_digest:original.request_digest) in
  let body=io (fun () -> Fs_compat.load_file body_path) in
  let memory_path=Current.path_for_keepers_dir ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
  let queue_path=Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
  let memory=io (fun () -> Fs_compat.load_file memory_path) and queue=io (fun () -> Fs_compat.load_file queue_path) in
  let posts=F.post_count fixture.server and moved=ref 0 in
  let interrupted=memory_action fixture (fun () ->
    Keeper_librarian_admission_owner.For_testing.run ~base_path:fixture.base_path ~keeper_name
      ~after_settle:(fun _ -> incr moved;if !moved=prefix then Error "fixture stopped after moving a member" else Ok ())) in
  check bool "the owner stops before finishing its anchor" true
    (match interrupted with Worker.Unavailable _ -> true
     | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Awaiting_worker _ | Addon_unattached _ -> false);
  if prefix=2 then io (fun () -> Fs_compat.save_file_atomic_strict body_path body |> get);
  check int "a restart can still install over the partial closure" 0 (List.length (closure_preflight fixture).refusals);
  let keepers,refusals,_=io (fun () -> Server_librarian_addon_wake.For_testing.discover
    ~config:fixture.config ~store:fixture.store ~after_inventory:(fun () -> ()) ~on_original:(fun _ -> ())
    ~event:Runtime.Configuration_observed |> get) in
  check bool "configuration wake still finds the closing owner" true (List.mem keeper_name keepers);
  check int "configuration wake understands the partial forest" 0 (List.length refusals);
  check bool "the normal owner finishes the same closure and is idle" true
    (match run_worker fixture with Worker.Idle -> true
     | Disabled | Recheck_new_input | Settled _ | Pending _ | Awaiting_worker _ | Addon_unattached _ | Unavailable _ -> false);
  check int "all original records leave the active inventory" 0
    (io (fun () -> Owner.discover_all ~store:fixture.store |> owned |> List.length));
  check bool "a body left after its record moved is removed on recovery" false
    (io (fun () -> Sys.file_exists body_path));
  check string "recovery does not write Memory" memory (io (fun () -> Fs_compat.load_file memory_path));
  check string "recovery does not rewrite queue ACKs" queue (io (fun () -> Fs_compat.load_file queue_path));
  check int "recovery makes no provider call" posts (F.post_count fixture.server))
let test_closure_recovery_refuses_pending_ack ()=with_fixture (fun ~sw:_ fixture ->
  let queue_path=Queue.path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
  let pending=io (fun () -> Fs_compat.load_file queue_path) in
  drive_until fixture settled |> assert_settled;
  let _,manifest=closure_manifest fixture in
  io (fun () -> Fs_compat.save_file_atomic_strict queue_path pending |> get);
  let posts=F.post_count fixture.server in
  check bool "a retained manifest cannot acknowledge its own candidates" true
    (match run_worker fixture with Worker.Unavailable _ -> true
     | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Awaiting_worker _ | Addon_unattached _ -> false);
  check string "recovery leaves pending candidates untouched" pending (io (fun () -> Fs_compat.load_file queue_path));
  check int "no member moved before ACK proof" (List.length (Closure.members manifest))
    (io (fun () -> Owner.discover_all ~store:fixture.store |> owned |> List.length) - 1);
  check int "no provider call is used to repair closure evidence" posts (F.post_count fixture.server))

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

let test_pass_without_new_input_after_commit_is_idle ()=with_fixture (fun ~sw:_ fixture ->
  drive_until fixture settled |> assert_settled;
  let posts=F.post_count fixture.server in
  check bool "a pass with no new input over finished parts reports Idle" true
    (match run_worker fixture with Worker.Idle -> true
     | Disabled | Recheck_new_input | Settled _ | Pending _ | Awaiting_worker _ | Addon_unattached _ | Unavailable _ -> false);
  check int "the idle pass starts no provider call" posts (F.post_count fixture.server);
  check int "the idle pass closes the fully committed forest" 0
    (io (fun () -> Owner.discover_all ~store:fixture.store |> owned |> List.length)))

let test_production_lane_closes_without_another_external_event ()=with_fixture (fun ~sw:_ fixture ->
  Fun.protect ~finally:(fun () ->
    Keeper_librarian_queue_signal.install (fun ~base_path:_ ~keeper_name:_ -> ())) (fun () ->
    Keeper_librarian_queue_refresh.install ();
    drive_until fixture settled |> assert_settled;
    Memory_lane.For_testing.await_idle ~base_path:fixture.base_path ~keeper_name;
    check int "the actual installed lane closes a quiet completed Keeper" 0
      (io (fun () -> Owner.discover_all ~store:fixture.store |> owned |> List.length));
    check int "the closure pass repeats no original provider" 1 (F.post_count fixture.server);
    check (list string) "the real committed Memory remains" ["Durable A";"Durable B"]
      (io (fun () -> claims fixture.keepers_dir))))

let test_a_new_tail_survives_closing_the_finished_forest ()=with_fixture (fun ~sw:_ fixture ->
  drive_until fixture settled |> assert_settled;
  let previous=observed_originals fixture in
  io (fun () -> ignore (append fixture.keepers_dir "new-tail" "Durable tail"));
  let seen=ref [] in
  fixture.set_response (fun capture ->
    seen:=List.map (fun (row:Queue.candidate) -> row.request_id) (Queue.candidates (Capture.batch capture)) :: !seen;
    `OK,F.openai_response (answer (fun _ -> true) capture));
  drive_until fixture settled |> assert_settled;
  check (list (list string)) "only the distinct new input reaches the next provider" [["new-tail"]] (List.rev !seen);
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  List.iter (fun (record,_) ->
    let original=io (fun () -> Owner.load ~store:fixture.store ~scope:record.Owner.scope
      ~request_id:record.request_id |> owned) in
    check bool "old execution is no longer active" true (Option.is_none original)) previous;
  check int "the new root does not retain a supersession link to a closed forest" 1
    (io (fun () -> Parts.discover ~store:fixture.store ~owner |> get |> Parts.roots |> List.length));
  check (list string) "old admitted facts and the tail remain" ["Durable A";"Durable B";"Durable tail"]
    (io (fun () -> claims fixture.keepers_dir)))

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
  let originals=observed_originals fixture in
  check bool "a partial commit retains original input before whole-batch completion" true (originals<>[]);
  (* The partial commit added B to actual Memory. That changed context can
     legitimately retain a new original for gap A before another queue tail.
     Wait for that real Deferred answer before changing the fixture response. *)
  drive_original_terminal fixture;
  List.iter (fun (original,_) ->
    let retained=io (fun () -> Owner.load ~store:fixture.store ~scope:original.Owner.scope
      ~request_id:original.request_id |> owned) in
    check bool "Finished subset preserves each original input" true
      (match retained with Some current -> current.request_digest=original.request_digest | None -> false)) originals;
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  check int "a deferred original gap prevents closure publication" 0
    (io (fun () -> Owner.discover ~store:fixture.store ~scope:(Closure.scope owner) |> owned |> List.length));
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
    (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
  ignore (run_worker fixture);
  check int "a fully committed supersession forest closes together" 0
    (io (fun () -> Owner.discover_all ~store:fixture.store |> owned |> List.length)))

(* #46372: the answer revises a Memory another writer removes before the
   commit. The locked plan refuses the revised claim, so the destination the
   answer writes into is absent. The original must end Conflicted after one
   attempt, not retry the same input, and the queue judges the candidate again
   against the Memory that refused it. *)
let test_absent_destination_ends_the_original_and_is_judged_again ()=
  with_fixture ~initial:["a","Durable A"] (fun ~sw:_ fixture ->
  let source={Current.kind=Current.Librarian;trace_id="absent-destination"} in
  let seeded=memory_action fixture (fun () -> io (fun () ->
    Current.replace ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name ~expected_revision:None
      ~now:50. ~source ~facts:[fact "Earlier version of A"] () |> get)) in
  let revising capture =
    let rows=Queue.candidates (Capture.batch capture) in
    `Assoc ["memory",`Assoc ["new_claims",`List [`Assoc ["claim",`String "Durable A";"category",`String "fact";
        "board_post_id",`Null;"board_comment_id",`Null;"supersedes",`String "m1";"absorbs",`List [];
        "evidence",`Assoc ["conversation",`List [];"tools",`List [];"counterpart",`Bool false;"task_contexts",`Bool false]]];
      "dropped",`List [`Assoc ["memory_id",`String "m1";"reason",`String "Revised by the candidate"]];
      "working_state",`Null;"working_contexts",`List []];
      "candidates",`List (List.map (fun (row:Queue.candidate) -> `Assoc ["request_id",`String row.request_id;
        "outcome",`String "incorporated";"memory_claim",`String row.fact.claim;
        "reason",`String "The candidate revises the captured Memory."]) rows);
      "change_support",`List (List.map (fun (row:Queue.candidate) -> `String row.request_id) rows)] in
  let judged=ref [] in
  fixture.set_response (fun capture ->
    let current=match (Capture.input capture).Keeper_librarian.current with
      | None -> [] | Some state -> List.map (fun (f:Types.fact) -> f.claim) state.facts in
    judged:=current :: !judged;
    match current with
    | ["Earlier version of A"] ->
      (* Another writer removes the revised source while the answer is out. *)
      io (fun () -> Current.replace ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
        ~expected_revision:(Some seeded.revision) ~now:60. ~source ~facts:[] () |> get |> ignore);
      `OK,F.openai_response (revising capture)
    | _ -> `OK,F.openai_response (answer (fun _ -> true) capture));
  drive_original_terminal fixture;
  let first=match observed_originals fixture with [record,_] -> record
    | [] | _::_::_ -> fail "expected one original execution" in
  let uncertain=List.exists (function Progress.Commit_uncertain _ -> true
    | Dispatch_intended | Admission_declined _ | Execution_observed _ | Judgment_retained _
    | Preparation_intended _ | Preparation_observed _ | Replacement_intended _ | Replacement_observed _
    | Commit_intended _ | Commit_retry_observed _ | Commit_observed _ | Commit_conflicted _ | Refused _
    | Refusal_settled _ | Successor_intended _ | Successor_observed _ | Observer _ -> false)
    (Progress.events first.Owner.progress) in
  check bool "the refused destination records no uncertain commit" false uncertain;
  (match Progress.phase first.progress with
   | Progress.Conflicted (_,conflict) ->
     ignore (Commit.destination_absent_of_json first conflict |> get)
   | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
   | Finished _ | Rejected _ | Subdividing _ | Subdivided _ -> fail "the original did not end Conflicted");
  check int "the refused candidate stays queued" 1 (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
  drive_until fixture settled |> assert_settled;
  check bool "the replacement is judged against the Memory that refused the first answer" true
    (List.mem [] !judged);
  check (list string) "the candidate enters Memory from the second answer" ["Durable A"]
    (io (fun () -> claims fixture.keepers_dir));
  check int "the second answer ACKs the candidate" 0 (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
  (* #51485: the next pass reads the Conflicted original after the
     replacement committed the candidate it handed over. *)
  (match run_worker fixture with
   | Worker.Unavailable detail -> fail ("the pass after the replacement commit is unavailable: " ^ detail)
   | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Awaiting_worker _ | Addon_unattached _ -> ());
  (* The replacement took the candidate over and committed it, so the forest
     that holds the Conflicted original is complete and that pass closed it. *)
  check int "the forest that holds the Conflicted original closes together" 0
    (io (fun () -> Owner.discover_all ~store:fixture.store |> owned |> List.length));
  (* A later candidate starts a root of its own. *)
  io (fun () -> ignore (append fixture.keepers_dir "new-tail" "Durable tail"));
  drive_until fixture settled |> assert_settled;
  check (list string) "the later candidate enters Memory" ["Durable A";"Durable tail"]
    (io (fun () -> claims fixture.keepers_dir));
  check int "the later candidate is ACKed" 0 (io (fun () -> List.length (pending_rows fixture.keepers_dir))))

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
  let exact=Capture.request capture |> get in
  io (fun () ->
    let stored=Store.load_exact_request fixture.store ~declaration_id:"librarian" ~request_id:exact.request_id |> get
      |> Option.value ~default:`Null in
    let denial=Lane_addon_exact.final_to_json (Not_allowed {reason="legacy delivery refusal"}) in
    let with_denial=match stored with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,
          if key="attempts" then (match value with `List entries -> `List (entries @ [denial])
            | _ -> fail "expected actual host attempt history") else value) fields)
      | _ -> fail "expected actual retained host request" in
    Store.save_exact_request fixture.store ~declaration_id:"librarian" ~request_id:exact.request_id with_denial |> get);
  let recovered=latest_execution fixture capture in
  check bool "delivery refusal does not replace the actual provider proof" true (recovered=execution);
  drive_until fixture settled |> assert_settled;
  check int "accepted original recovery while Off starts no provider" posts (F.post_count fixture.server);
  check int "only the actual local domain commit authorizes queue ACK" 0
    (io (fun () -> List.length (pending_rows fixture.keepers_dir)));
  check (list string) "the original full answer reaches Memory while Off" ["Durable A";"Durable B"]
    (io (fun () -> claims fixture.keepers_dir)))

let refusal error_type=Yojson.Safe.to_string (`Assoc ["error",`Assoc ["type",`String error_type;
  "message",`String "Controlled fixture provider refusal"]])
let test_actual_output_limit_then_capacity_keeps_both_causes ()=with_fixture (fun ~sw:_ fixture ->
  fixture.set_response (fun _ -> `OK,
    {|{"id":"mixed-output-limit","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":"{}"},"finish_reason":"length"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|});
  let other=fixture.extra_server (fun _ -> `Request_entity_too_large,refusal "invalid_request_error") in
  publish_routes fixture.base_path [fixture.server.base_url;other.base_url];
  ignore (run_worker fixture);
  F.await_first_request other;
  await_host_cycle fixture;
  let capture=match observed_originals fixture with [_,capture] -> capture
    | [] | _::_::_ -> fail "mixed output/input refusal minted a different original" in
  let execution=latest_execution fixture capture in
  check bool "the last actual provider visit reports HTTP input refusal" true
    (match execution.Lane_addon_exact.outcome with
     | Call_ended (Input_refused Request_body_refused) -> true
     | Call_ended (Answered _ | Invalid_output _ | Output_limit_reached _
         | Input_refused (Input_capacity | Context_overflow | Invalid_request)) | Call_refused _ -> false);
  let evidence=Keeper_exact_walk_receipt.failure_evidence execution.receipt in
  check bool "the earlier output failure survives the retained host receipt" true
    evidence.non_capacity_execution_failure;
  check bool "the last named input refusal also survives" true evidence.named_input_capacity;
  let report=Keeper_librarian_runtime.not_committed_of_failure ~detail:"actual output limit then HTTP 413" evidence in
  check bool "the Runtime report does not mislabel the whole walk capacity-only" false report.input_capacity_only;
  check int "observing the mixed host receipt does not consume candidates" 2
    (io (fun () -> List.length (pending_rows fixture.keepers_dir))))

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
    |> get) in
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
      Current.apply_disposition ~pass:Keeper_memory_commit_pass.Admission ~explicit_candidate_ids:b ~absorbed:[] ~revisions:[]
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
      (io (fun () -> claims fixture.keepers_dir));
    (* One owner now holds a root, two children, the split between them, three
       executions and three gates, and each of those records names the same
       forest of parts and partitions. The deploy preflight reads that forest
       once for the scan. Before it kept the proof, every record read both
       scopes again, and a workspace with dozens of records per owner took
       minutes to scan. *)
    let forest_reads=ref 0 and closure_reads=ref 0 and validated=ref 0 in
    let counting ()=
      let validate=Keeper_librarian_store_preflight.validator () in
      fun ~read ~read_scope ~read_body ~read_archive ~read_fence ~read_resolution ~read_exact:_ record ->
        incr validated;
        match validate ~read ~read_body ~read_archive ~read_fence ~read_resolution record
          ~read_scope:(fun ~scope ->
            if Keeper_librarian_admission_closure.is_scope scope then incr closure_reads
            else incr forest_reads;
            read_scope ~scope) with
        | Ok () -> Lane_addon_store_preflight.Payload_valid
        | Error detail -> Lane_addon_store_preflight.Payload_invalid detail in
    let report=io (fun () -> Lane_addon_store_preflight.scan ~validate_tool_request:counting
      Lane_addon_store_preflight.Store.Tool_request_owners ~base_path:fixture.base_path) |> get in
    check int "the preflight refuses none of the owner's real records" 0 (List.length report.refusals);
    check bool "the scan validated several records of the one owner" true (!validated>2);
    check int "the owner's parts and partitions are read once for the whole scan" 2 !forest_reads;
    check int "closure presence is reobserved for every scanned original" !validated !closure_reads;
    check int "the Librarian check reads the split forest's Exact files and refuses none" 0
      (List.length (closure_preflight fixture).refusals);
    (* Discovery compares the partition's evidence with the latest execution
       of the original that refused its whole input. *)
    let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
    let split=match List.filter (fun (_,capture) -> List.length (Queue.candidates (Capture.batch capture))>1)
        (observed_originals fixture) with
      | [_,capture] -> capture
      | [] | _::_::_ -> fail "expected the one original that refused its whole input" in
    let record_path,proof_path=exact_files fixture split in
    (* Set aside and put back by rename, so the closure below reads the same files. *)
    let aside path=path ^ ".aside" in
    io (fun () -> List.iter (fun path -> Sys.rename path (aside path)) [record_path;proof_path]);
    let partitions=scope_directory fixture (Parts.partition_scope owner) in
    check bool "a partition whose source execution lost its Exact files is refused" true
      (List.exists (fun (refusal:Lane_addon_store_preflight.refusal) ->
         refusal.decoder=Lane_addon_store_preflight.Tool_request_exact_reads
         && String.equal (Filename.dirname refusal.path) partitions)
        (closure_preflight fixture).refusals);
    io (fun () -> List.iter (fun path -> Sys.rename (aside path) path) [record_path;proof_path]);
    let _,manifest=closure_manifest fixture in
    let posts=F.post_count fixture.server in
    List.iteri (fun index _ ->
      let moved=ref 0 in
      let outcome=memory_action fixture (fun () ->
        Keeper_librarian_admission_owner.For_testing.run ~base_path:fixture.base_path ~keeper_name
          ~after_settle:(fun _ -> incr moved;if !moved=index+1 then Error "fixture restart during a split closure" else Ok ())) in
      check bool "a split closure stops at the selected move" true
        (match outcome with Worker.Unavailable _ -> true
         | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Awaiting_worker _ | Addon_unattached _ -> false);
      check int "every partial split forest remains compatible" 0 (List.length (closure_preflight fixture).refusals))
      (Closure.members manifest);
    ignore (run_worker fixture);
    check int "all split parents, children, executions and gates leave together" 0
      (io (fun () -> Owner.discover_all ~store:fixture.store |> owned |> List.length));
    check int "split closure never repeats a provider call" posts (F.post_count fixture.server))

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
  | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Awaiting_worker _ | Addon_unattached _ -> fail "invalid complete original history must refuse before local repair"
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
    let waiting = match run_worker fixture with Worker.Awaiting_worker waiting -> waiting
     | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Addon_unattached _ | Unavailable _ ->
       fail "the actual ordinary Memory unit must return while its provider is pending" in
    Eio.Promise.await arrived;
    let original = match observed_originals fixture with
      | [original, _] -> original
      | [] | _ :: _ :: _ -> fail "a pending admission worker must retain exactly one original" in
    check string "the admission wait retains its actual installation"
      original.installation_id waiting.installation_id;
    check string "the admission wait retains its actual request" original.request_id waiting.request_id;
    check bool "the actual admission worker is processing" true
      (waiting.wait = Keeper_librarian_pending.Processing);
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

(* RFC-0500. One original whose provider call is open, cut by a purge.
   [before_cut] sees the retained host attempt fields before the cut, so no
   host pass can recover the attempt in between. Later provider calls answer. *)
let with_cut_original fixture ~before_cut k =
  let arrived,signal=Eio.Promise.create () and release,unblock=Eio.Promise.create () in
  let hold=Atomic.make true in
  fixture.set_response (fun capture ->
    if Atomic.get hold then (ignore (Eio.Promise.try_resolve signal ());Eio.Promise.await release);
    `OK,F.openai_response (answer (fun _ -> true) capture));
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    (match run_worker fixture with Worker.Awaiting_worker _ -> ()
     | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Addon_unattached _ | Unavailable _ ->
       fail "the first provider call must still be open");
    Eio.Promise.await arrived;
    let record,capture=match observed_originals fixture with [original] -> original
      | [] | _::_::_ -> fail "expected the one original whose provider call is open" in
    let exact=Capture.request capture |> get in
    io (fun () ->
      let fields=match Store.load_exact_request fixture.store ~declaration_id:"librarian" ~request_id:exact.request_id |> get with
        | Some (`Assoc fields) -> fields
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) | None ->
          fail "expected the retained host request" in
      match before_cut fields with
      | None -> ()
      | Some fields -> Store.save_exact_request fixture.store ~declaration_id:"librarian"
          ~request_id:exact.request_id (`Assoc fields) |> get);
    Atomic.set hold false;
    (match Memory_lane.with_librarian_purge ~base_path:fixture.base_path ~keeper_name (fun () -> ()) with
     | Ok () -> () | Error error -> fail (Memory_lane.purge_cancel_error_to_string error));
    k record)
let archived fixture (record:Owner.retained)=
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let date=Capture.minted_on record.request_id |> get in
  io (fun () -> Owner.settled ~store:fixture.store ~scope:(Capture.scope owner) ~date
    ~request_id:record.request_id |> owned)
let listed fixture (record:Owner.retained)=
  List.exists (fun ((current:Owner.retained),_) -> current.request_id=record.request_id) (observed_originals fixture)
(* The attempt a stopped server leaves: started by another incarnation, with
   no outcome and no proof. *)
let stopped_incarnation="0123456789abcdef0123456789abcdef"
let started_by_stopped_server fields=
  let attempts=match List.assoc_opt "attempts" fields with
    | Some (`List attempts) -> attempts
    | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) | None ->
      fail "expected the host attempt history" in
  let earlier=match List.rev attempts with
    | `Assoc ["started",`String started_by]::earlier when started_by<>stopped_incarnation -> List.rev earlier
    | [] | _::_ -> fail "the open attempt must be started by this process with no outcome" in
  Some (List.map (fun (key,value) -> key,
    if key="attempts" then `List (earlier @ [`Assoc ["started",`String stopped_incarnation]]) else value) fields)

let test_interrupted_original_is_prepared_again ()=with_fixture (fun ~sw:_ fixture ->
  with_cut_original fixture ~before_cut:started_by_stopped_server (fun record ->
    let posts=F.post_count fixture.server in
    drive_until fixture settled |> assert_settled;
    check bool "the interrupted original moved to the settled archive" true (archived fixture record);
    check bool "the scope no longer lists the interrupted original" false (listed fixture record);
    check bool "a new provider call judged the same part" true (F.post_count fixture.server>posts);
    check (list string) "the new judgment commits the candidates" ["Durable A";"Durable B"]
      (io (fun () -> claims fixture.keepers_dir));
    check int "every candidate is acknowledged" 0
      (io (fun () -> List.length (pending_rows fixture.keepers_dir)))))

let test_cut_original_keeps_its_part_waiting ()=with_fixture (fun ~sw:_ fixture ->
  with_cut_original fixture ~before_cut:(fun _ -> None) (fun record ->
    let posts=F.post_count fixture.server in
    let rec until_refused ()=
      let before= !(fixture.deliveries) in
      (match run_worker fixture with Worker.Pending _ | Awaiting_worker _ -> ()
       | Disabled | Idle | Recheck_new_input | Settled _ | Addon_unattached _ | Unavailable _ ->
         fail "a cut original must keep its part waiting");
      match observed_originals fixture with
      | [current,_] when current.request_id=record.request_id ->
        (match Progress.phase current.progress with
         | Progress.Rejected {stage=Progress.Execution;_} -> ()
         | Captured | Admission_wait _ | Dispatch_pending _ -> await_delivery fixture ~after:before;until_refused ()
         | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
         | Rejected {stage=Progress.Before_dispatch;_} | Subdividing _ | Subdivided _ ->
           fail "a cut original reaches only an execution refusal")
      | [] | _::_ -> fail "the cut original must stay the part's only execution" in
    until_refused ();
    (match run_worker fixture with Worker.Pending _ | Awaiting_worker _ -> ()
     | Disabled | Idle | Recheck_new_input | Settled _ | Addon_unattached _ | Unavailable _ ->
       fail "a refused cut original must keep its part waiting");
    check bool "the cut original stays in its scope" true (listed fixture record);
    check bool "the cut original is not archived" false (archived fixture record);
    check int "no provider call follows the cut" posts (F.post_count fixture.server);
    check int "no candidate is acknowledged" 2 (io (fun () -> List.length (pending_rows fixture.keepers_dir)))))

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
let retained_absorbing_answer_before_gate fixture =
  memory_action fixture (fun () -> io (fun () ->
    Current.replace ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name ~expected_revision:None
      ~now:50. ~source:{Current.kind=Current.Librarian;trace_id="absorb-policy-gap"}
      ~facts:[fact "Earlier complete source memory."] () |> get |> ignore));
  fixture.set_response (fun capture ->
    let response=answer (fun _ -> true) capture |> Yojson.Safe.Util.to_assoc in
    let memory=List.assoc "memory" response |> Yojson.Safe.Util.to_assoc in
    let claims=List.assoc "new_claims" memory |> Yojson.Safe.Util.to_list in
    let claims=match claims with
      | `Assoc first::rest ->
        (* The only captured current memory has the canonical first wire token. *)
        `Assoc (("absorbs",`List [`String "m1"])::List.remove_assoc "absorbs" first)::rest
      | [] | _::_ -> fail "an absorbing admission needs its first proposed claim" in
    `OK,F.openai_response (`Assoc (("memory",`Assoc (("new_claims",`List claims)::
      List.remove_assoc "new_claims" memory))::List.remove_assoc "memory" response)));
  retained_answer_before_gate fixture
let retain_judgment_json fixture record judgment = io (fun () ->
  match Owner.advance ~store:fixture.store ~expected:record ~event:(Progress.Judgment_retained judgment) with
  | Ok (Owner.Stored next | Already_stored next) -> next
  | Ok (Unconfirmed detail) -> fail detail
  | Error error -> fail (Owner.update_error_to_string error))
let retain_judgment fixture record final =
  retain_judgment_json fixture record (Lane_addon_exact.final_to_json final)
let with_policy_overrides keys f =
  let originals=List.map (fun key -> key,(Prompt_registry.resolve_prompt key).override_value) keys in
  Fun.protect ~finally:(fun () -> List.iter (fun (key,value) -> match value with
    | None -> Prompt_registry.clear_prompt_override key
    | Some value -> Prompt_registry.set_override key value |> get) originals) f
let with_missing_librarian_fragment ?(empty=false) marker f =
  let original=Prompt_registry.get_markdown_dir () |> Option.to_result ~none:"prompts not pinned" |> get in
  let directory=io (fun () ->
    let directory=Filename.temp_dir "librarian-policy-missing-" "" in
    let text=Fs_compat.load_file (Filename.concat original "librarian.md") in
    let _,lines=List.fold_left (fun (skipping,lines) line ->
      if line="### " ^ marker then true,(if empty then ""::line::lines else lines)
      else if skipping && not (String.starts_with ~prefix:"### " line) then true,lines
      else false,line::lines) (false,[]) (String.split_on_char '\n' text) in
    write (Filename.concat directory "librarian.md") (String.concat "\n" (List.rev lines));
    directory) in
  Fun.protect ~finally:(fun () -> Prompt_registry.set_markdown_dir original;
    io (fun () -> Fs_compat.remove_tree directory)) (fun () ->
    Prompt_registry.set_markdown_dir directory;f ())

let with_absorb_gate_policy ~enabled ~excluded f =
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "unused-absorb-key") (fun () ->
    Masc_test_deps.with_typesafeai_policy
      {Runtime_schema.default_typesafeai with lane_enabled=true;absorb_gate=enabled;
       excluded_keepers=(if excluded then [keeper_name] else []);
       destinations=({Runtime_schema.endpoint="http://127.0.0.1:9/unused";
         model="unused-absorb-model";api_key_env="TYPESAFEAI_API_KEY"},[])} f)

let with_absorb_guidance_gap ~empty f =
  with_policy_overrides [Prompt_names.librarian_absorb_forward] (fun () ->
    Prompt_registry.clear_prompt_override Prompt_names.librarian_absorb_forward;
    with_missing_librarian_fragment ~empty "absorb_forward" f)

let with_retirement_guidance_gap ~empty f =
  with_policy_overrides [Prompt_names.librarian_retirement_policy] (fun () ->
    Prompt_registry.clear_prompt_override Prompt_names.librarian_retirement_policy;
    with_missing_librarian_fragment ~empty "retirement_policy" f)

let retain_gate_payload (fixture:fixture) ~owner ~(parent:Owner.retained) ~request_id ~request =
  io (fun () ->
    let store=Store.create ~root:(Filename.concat fixture.base_path "decoder-gate-payload") in
    let scope=Gate.scope owner in
    Owner.retain ~store ~scope ~request_id ~installation_id:parent.installation_id
      ~package_id:parent.package_id ~tool:parent.tool ~summary:`Null ~request |> owned;
    Owner.load ~store ~scope ~request_id |> owned
      |> Option.to_result ~none:"decoder fixture gate was not retained" |> get)

let test_admission_capture_keeps_original_policy ()=with_fixture (fun ~sw:_ fixture ->
  let admission=Prompt_names.librarian_admission_policy and retirement=Prompt_names.librarian_retirement_policy in
  with_policy_overrides [admission;retirement] (fun () ->
    Prompt_registry.set_override admission "Original admission policy" |> get;
    Prompt_registry.set_override retirement "Original retirement policy" |> get;
    let record,capture,_=retained_answer_before_gate fixture in
    let original=Capture.request capture |> get in
    let prepared=member "preparation" (Capture.to_json capture) in
    check json "admission policy is captured with the original request" (`String "Original admission policy")
      (member "effective" (member "admission_prompt" prepared));
    check json "no matching archive captures explicit unused-policy absence" `Null
      (member "retirement_prompt" prepared);
    Prompt_registry.set_override admission "Changed admission policy" |> get;
    Prompt_registry.set_override retirement "Changed retirement policy" |> get;
    let restored=match observed_originals fixture with [_,capture] -> capture
      | [] | _::_::_ -> fail "one original capture expected" in
    check json "overrides cannot rewrite a captured host request"
      (Lane_addon_exact.request_to_json original) (Lane_addon_exact.request_to_json (Capture.request restored |> get));
    let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
    let inventory=io (fun () -> Parts.discover ~store:fixture.store ~owner
      |> get) in
    let refuse name expected request=
      let restored=io (fun () ->
        let store=Store.create ~root:(Filename.concat fixture.base_path name) in
        Owner.retain ~store ~scope:record.scope ~request_id:record.request_id
          ~installation_id:record.installation_id ~package_id:record.package_id
          ~tool:record.tool ~summary:record.summary ~request |> owned;
        let retained=match Owner.load ~store ~scope:record.scope ~request_id:record.request_id |> owned with
          | Some retained -> retained | None -> fail "the malformed capture was not retained" in
        Capture.restore ~owner ~load_parent:(Parts.load_parent inventory) retained) in
      match restored with
      | Error detail -> check string "an absent policy is never reconstructed from current defaults" expected detail
      | Ok _ -> fail "an invalid original policy capture was restored" in
    let fields=Yojson.Safe.Util.to_assoc record.request in
    let prepared_fields=Yojson.Safe.Util.to_assoc prepared in
    refuse "capture-without-admission-policy" "Original Librarian capture has unknown, missing or repeated fields"
      (`Assoc (("preparation",`Assoc (List.remove_assoc "admission_prompt" prepared_fields))::
      List.remove_assoc "preparation" fields));
    refuse "capture-without-retirement-field" "Original Librarian capture has unknown, missing or repeated fields"
      (`Assoc (("preparation",`Assoc (List.remove_assoc "retirement_prompt" prepared_fields))::
      List.remove_assoc "preparation" fields));
    refuse "capture-with-malformed-unused-policy"
      "Original Librarian capture: prompt resolution has unknown, duplicate or missing members"
      (`Assoc (("preparation",`Assoc (("retirement_prompt",`Assoc [])::
        List.remove_assoc "retirement_prompt" prepared_fields))::List.remove_assoc "preparation" fields));
    refuse "capture-with-old-schema" "Unknown original Librarian execution schema/kind"
      (`Assoc (("schema",`Int 1)::List.remove_assoc "schema" fields))))

let test_missing_admission_policy_refuses_before_capture ()=with_fixture (fun ~sw:_ fixture ->
  with_missing_librarian_fragment "admission_policy" (fun () ->
    let posts=F.post_count fixture.server in
    run_worker fixture |> assert_unavailable;
    check int "missing policy sends no provider request" posts (F.post_count fixture.server);
    check int "missing policy retains no original execution capture" 0 (List.length (observed_originals fixture));
    check int "every pending candidate remains available" 2 (io (fun () -> List.length (pending_rows fixture.keepers_dir)))))

let retire_fixture_fact (fixture:fixture) (original:Types.fact) =
  memory_action fixture (fun () -> io (fun () ->
    Current.replace ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name ~expected_revision:None
      ~now:100. ~source:{Current.kind=Current.Explicit_write;trace_id="retirement-policy-fixture"}
      ~facts:[original] () |> get |> ignore;
    match Current.retract_fact ~pass:Keeper_memory_commit_pass.Keeper_delete ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name ~now:200.
      ~source:{Current.kind=Current.Explicit_retract;trace_id="retirement-policy-fixture"}
      ~memory_id:(Types.memory_id original) ~reason:"Retained original retirement reason" () with
    | Ok _ -> () | Error _ -> fail "the retirement fixture could not retract its source"))

let test_unused_retirement_policy_does_not_block_admission ()=
  List.iter (fun (empty,unrelated_archive) -> with_fixture (fun ~sw:_ fixture ->
    if unrelated_archive then retire_fixture_fact fixture (fact "An unrelated historical identity.");
    with_retirement_guidance_gap ~empty (fun () ->
      let _,capture,_=retained_answer_before_gate fixture in
      check json "no matching retirement captures explicit policy absence" `Null
        (member "retirement_prompt" (member "preparation" (Capture.to_json capture)));
      if unrelated_archive then (
        let archive=io (fun () -> Current.read_dropped ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name
          ~current_facts:[]) |> get in
        check int "the no-match archive is genuinely nonempty" 1 (List.length archive);
        check bool "nonempty unrelated history needs no policy" false
          (Keeper_memory_admission_judgment.retirement_prompt_needed ~batch:(Capture.batch capture)
            (Keeper_memory_admission_judgment.Available archive)));
      let original=Capture.request capture |> get in
      let restored=match observed_originals fixture with [_,restored] -> restored | _ -> fail "one original expected" in
      check json "missing current policy cannot alter the captured request"
        (Lane_addon_exact.request_to_json original) (Lane_addon_exact.request_to_json (Capture.request restored |> get));
      drive_until fixture settled |> assert_settled;
      check int "the same original provider answer settles admission" 1 (F.post_count fixture.server);
      check int "durable no-suffix replay ACKs both candidates" 0
        (io (fun () -> List.length (pending_rows fixture.keepers_dir))))))
    [false,false;true,false;false,true;true,true]

let retirement_record (original:Types.fact) : Current.archived_fact =
  {original;removal={Current.removed_in_revision=2;removed_at=200.;
    removed_by={Current.kind=Current.Explicit_retract;trace_id="retirement-policy-fixture"};
    removed_origin=Types.Authored;drop_reason=Some "Original retirement reason"}}

let test_retirement_policy_is_required_only_for_its_suffix ()=with_fixture (fun ~sw:_ fixture ->
  let _,capture,_=retained_answer_before_gate fixture in
  let batch=Capture.batch capture and input=Capture.input capture in
  let matching=retirement_record ((List.hd (Queue.candidates batch)).fact)
  and unrelated=retirement_record (fact "An unrelated archived identity.") in
  List.iter (fun empty -> with_retirement_guidance_gap ~empty (fun () ->
    List.iter (fun (retirement,needed) ->
      match Keeper_librarian_runtime.prepare_admission ~source_lines:[] ~batch ~retirement input with
      | Error detail ->
        check bool "only a needed retirement suffix refuses missing policy" true needed;
        check bool "the error names the retirement policy" true
          (String_util.contains_substring detail Prompt_names.librarian_retirement_policy)
      | Ok preparation ->
        check bool "unused retirement policy is not resolved" false needed;
        check bool "unused policy has typed absence" true (preparation.retirement_prompt=None);
        Keeper_librarian_runtime.validate_admission_preparation ~batch ~retirement ~input preparation |> get)
      [Keeper_memory_admission_judgment.Available [],false;
       Keeper_memory_admission_judgment.Available [unrelated],false;
       Keeper_memory_admission_judgment.Available [matching],true;
       Keeper_memory_admission_judgment.Unavailable "original archive read failed",true])) [false;true];
  check int "preparation never dispatches another provider request" 1 (F.post_count fixture.server))

let test_used_retirement_policy_survives_current_policy_changes ()=with_fixture (fun ~sw:_ fixture ->
  let candidate=io (fun () -> (List.hd (pending_rows fixture.keepers_dir)).fact) in
  retire_fixture_fact fixture candidate;
  let key=Prompt_names.librarian_retirement_policy in
  with_policy_overrides [key] (fun () ->
    Prompt_registry.set_override key "Original captured retirement policy" |> get;
    let record,capture,_=retained_answer_before_gate fixture in
    let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
    let batch=Capture.batch capture and input=Capture.input capture in
    let retirement=Keeper_memory_admission_judgment.Unavailable "original archive read failed" in
    let preparation=Keeper_librarian_runtime.prepare_admission ~source_lines:[] ~batch ~retirement input |> get in
    let unavailable=Capture.create ~request_id:(Capture.fresh_request_id owner)
      ~parent_part_id:(Capture.parent_part_id capture) ~owner ~destination:(Capture.destination capture)
      ~batch ~input ~expected_revision:(Capture.expected_revision capture) ~now:(Capture.now capture)
      ~retirement ~preparation |> get in
    let inventory=io (fun () -> Parts.discover ~store:fixture.store ~owner
      |> get) in
    let restore name original request=io (fun () ->
      let store=Store.create ~root:(Filename.concat fixture.base_path name) in
      let scope=Capture.scope owner and request_id=Capture.request_id original in
      Owner.retain ~store ~scope ~request_id ~installation_id:record.installation_id
        ~package_id:record.package_id ~tool:record.tool ~summary:`Null ~request |> owned;
      let retained=Owner.load ~store ~scope ~request_id |> owned |> Option.get in
      Capture.restore ~owner ~load_parent:(Parts.load_parent inventory) retained) in
    Prompt_registry.set_override key "Changed current retirement policy" |> get;
    List.iter (fun (name,original) ->
      let captured=Capture.to_json original in
      let expected=Capture.request original |> get |> Lane_addon_exact.request_to_json in
      let prepared=member "preparation" captured in
      check json "a used retirement policy is captured" (`String "Original captured retirement policy")
        (member "effective" (member "retirement_prompt" prepared));
      let unchanged=restore (name ^ "-changed-policy") original captured |> get in
      check json "override changes cannot alter the frozen used policy" expected
        (Capture.request unchanged |> get |> Lane_addon_exact.request_to_json);
      List.iter (fun empty -> with_retirement_guidance_gap ~empty (fun () ->
        let restored=restore (name ^ "-missing-policy") original captured |> get in
        check json "required policy replays without any current asset" expected
          (Capture.request restored |> get |> Lane_addon_exact.request_to_json))) [false;true];
      let prepared_fields=Yojson.Safe.Util.to_assoc prepared in
      let missing=`Assoc (("preparation",`Assoc (("retirement_prompt",`Null)::
        List.remove_assoc "retirement_prompt" prepared_fields))::
        List.remove_assoc "preparation" (Yojson.Safe.Util.to_assoc captured)) in
      check (result unit string) "needed retirement policy cannot decode as null"
        (Error "Original admission requires captured retirement policy")
        (restore (name ^ "-null-policy") original missing |> Result.map (fun _ -> ())))
      ["matched-retirement",capture;"unavailable-retirement",unavailable];
    check int "durable policy replay makes no new provider request" 1 (F.post_count fixture.server)))

let test_missing_absorb_policy_refuses_before_preparation ()=List.iter (fun empty ->
  with_fixture (fun ~sw:_ fixture ->
  let record,capture,final=retained_absorbing_answer_before_gate fixture in
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let record=memory_action fixture (fun () -> retain_judgment fixture record final) in
  with_absorb_gate_policy ~enabled:true ~excluded:false (fun () ->
  let original_authority=Keeper_librarian_absorb_gate.resolve ~keeper_id:keeper_name in
  let intent=io (fun () -> Gate.prepare_root ~store:fixture.store ~owner ~capture ~parent:record
    ~proposal:(match final with Lane_addon_exact.Call_final (Answered {output;_}) -> Lane_addon_exact.checked_json output
      | _ -> fail "the fixture requires its original answer")
    ~request_id:(Random_id.uuid_v7 ())
    ~authority:original_authority |> get) in
  with_absorb_guidance_gap ~empty (fun () ->
    let authority=Keeper_librarian_absorb_gate.resolve ~keeper_id:keeper_name in
    let missing_policy=match Keeper_librarian_absorb_gate.guidance_of_authority authority with
      | Error detail -> detail | Ok _ -> fail "missing policy must stay an explicit setup error" in
    let posts=F.post_count fixture.server in
    check (result unit string) "missing policy cannot publish the first gate intent" (Error missing_policy)
      (memory_action fixture (fun () -> Commit.begin_gate ~store:fixture.store ~owner ~capture ~record
        ~gate_root_id:(Random_id.uuid_v7 ()) ~authority |> Result.map (fun _ -> ())));
    check (result unit string) "nonempty admission retention requires guidance" (Error missing_policy)
      (io (fun () -> Gate.retain ~store:fixture.store ~owner ~capture ~parent:record
        ~proposal:(member "proposal" intent.request) ~request_id:intent.request_id ~authority ~predecessor:None)
       |> Result.map (fun _ -> ()));
    let parent=io (fun () -> Owner.load ~store:fixture.store ~scope:record.scope ~request_id:record.request_id |> owned) in
    let parent=Option.to_result ~none:"original parent missing" parent |> get in
    check bool "the parent still has no gate preparation" true (Progress.preparation parent.progress=None);
    check int "missing policy publishes no child request" 0
      (io (fun () -> Owner.load_scope ~store:fixture.store ~scope:(Gate.scope owner) |> owned |> List.length));
    let gate=Keeper_librarian_absorb_gate.run_captured authority ~clock:fixture.clock ~cited_observations:[]
      ~facts:[] ~new_claims:[] ~superseding:[]
      ~absorbed:[{Types.absorbed="source";into="target"}]
      ~before_evaluate:(fun ~direction:_ ~destinations:_ ~state:_ ~questions:_ -> fail "missing policy must not dispatch") () in
    check bool "missing guidance cannot be reported as a disabled gate" true
      (match gate with
       | Keeper_librarian_absorb_gate.Evaluated {outcome=Keeper_librarian_absorb_gate.Failed _;_} -> true
       | Keeper_librarian_absorb_gate.Evaluated {outcome=Keeper_librarian_absorb_gate.Judged _;_}
       | Keeper_librarian_absorb_gate.Skipped _ -> false);
    let request=`Assoc (("guidance",`Null)::List.remove_assoc "guidance" (Yojson.Safe.Util.to_assoc intent.request)) in
    let forged=retain_gate_payload fixture ~owner ~parent:record ~request_id:intent.request_id ~request in
    let rejected=io (fun () -> Gate.validate_payload ~owner ~capture ~parent:record ~record:forged
      ~read:(fun ~scope:_ ~request_id:_ -> fail "missing guidance must refuse before ancestry lookup")
      ~read_body:(fun ~scope:_ ~request_digest:_ -> fail "missing guidance must refuse before body lookup")) in
    check (result unit string) "an enabled nonempty proposal cannot decode null guidance"
      (Error "Available absorption gate has no captured guidance") rejected;
    check int "the already answered parent is never sent again" posts (F.post_count fixture.server))))) [false;true]

let check_unused_absorb_policy ~empty ~excluded ~no_absorptions =
  with_fixture (fun ~sw:_ fixture ->
    let record,capture,final=(if no_absorptions then retained_answer_before_gate
      else retained_absorbing_answer_before_gate) fixture in
    let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
    let record=memory_action fixture (fun () -> retain_judgment fixture record final) in
    with_absorb_gate_policy ~enabled:(excluded || no_absorptions) ~excluded (fun () ->
    with_absorb_guidance_gap ~empty (fun () ->
      let authority=Keeper_librarian_absorb_gate.resolve ~keeper_id:keeper_name in
      check bool "unused guidance retains its original availability" true
        (if no_absorptions then Keeper_librarian_absorb_gate.guidance_of_authority authority |> Result.is_error
         else Keeper_librarian_absorb_gate.guidance_of_authority authority=Ok None);
      let parent=memory_action fixture (fun () ->
        match Commit.begin_gate ~store:fixture.store ~owner ~capture ~record
          ~gate_root_id:(Random_id.uuid_v7 ()) ~authority |> get with
        | Prepared parent -> parent | Reload_original -> fail "new preparation expected") in
      let intended=match Progress.preparation parent.progress with
        | Some (Preparation_pending intended) -> intended
        | None | Some (Preparation_confirmed _) -> fail "pending gate preparation expected" in
      check json "absence is explicit in the durable preparation" `Null (member "guidance" intended.request);
      if no_absorptions then (
        let request=`Assoc (("guidance",`Assoc [])::List.remove_assoc "guidance" (Yojson.Safe.Util.to_assoc intended.request)) in
        let malformed=retain_gate_payload fixture ~owner ~parent ~request_id:intended.request_id ~request in
        check bool "an empty proposal still rejects malformed non-null guidance" true
          (io (fun () -> Gate.validate_payload ~owner ~capture ~parent ~record:malformed
            ~read:(fun ~scope:_ ~request_id:_ -> fail "malformed guidance must refuse before ancestry lookup")
            ~read_body:(fun ~scope:_ ~request_digest:_ -> fail "malformed guidance must refuse before body lookup")) |> Result.is_error));
      let parent=memory_action fixture (fun () -> Gate.recover_root ~store:fixture.store ~owner ~capture |> get) in
      let gate=memory_action fixture (fun () -> Gate.retain ~store:fixture.store ~owner ~capture ~parent
        ~proposal:(member "proposal" intended.request) ~request_id:intended.request_id
        ~authority ~predecessor:None |> get) in
      let complete=memory_action fixture (fun () ->
        match Gate.resume ~store:fixture.store ~owner ~capture ~record:gate ~live_authority:None
          ~request_clock:(fun () -> fail "unused guidance acquired a request clock")
          ~before_dispatch:(fun () -> fail "unused guidance cannot dispatch") |> get with
        | Complete (result,_) -> result | Pending _ -> fail "unavailable gate must complete locally") in
      check int "the original no-evaluation disposition is preserved" (if no_absorptions then 0 else 1)
        (List.length (Keeper_librarian_absorb_gate.absorbed_of_run complete));
      if no_absorptions then check bool "the result names the validated empty proposal" true
        (match complete with Keeper_librarian_absorb_gate.Skipped {reason=No_absorptions;absorbed=[]} -> true
         | Skipped _ | Evaluated _ -> false);
      let replayed=io (fun () -> Gate.restore_latest_result ~store:fixture.store ~owner
        ~parent_execution:capture ~gate_request_id:gate.request_id |> get) in
      check json "unavailable policy survives strict durable replay"
        (Keeper_librarian_absorb_gate.run_result_to_yojson complete)
        (Keeper_librarian_absorb_gate.run_result_to_yojson replayed);
      check int "the original provider answer is never sent again" 1 (F.post_count fixture.server))))

let test_unused_absorb_policy_is_captured_and_replayed ()=
  List.iter (fun (empty,excluded) -> check_unused_absorb_policy ~empty ~excluded ~no_absorptions:false)
    [false,false;true,false;false,true;true,true]

let test_enabled_empty_absorptions_need_no_guidance ()=
  List.iter (fun empty -> check_unused_absorb_policy ~empty ~excluded:false ~no_absorptions:true) [false;true]

let test_absorbing_admission_captures_both_context_policies ()=
  List.iter (fun forward_verdict -> with_fixture (fun ~sw fixture ->
    let module Absorb=Keeper_librarian_absorb_gate in
    let module T=Typesafeai_types in
    let record,capture,final=retained_absorbing_answer_before_gate fixture in
    let proposal=match final with Lane_addon_exact.Call_final (Answered {output;_}) -> Lane_addon_exact.checked_json output
      | _ -> fail "the fixture requires its actual host answer" in
    let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
    let record=memory_action fixture (fun () -> retain_judgment fixture record final) in
    let net=Eio_context.get_net_opt () |> Option.to_result ~none:"fixture network missing" |> get in
    let directions=ref [] in
    let jev=F.start_server ~sw ~net ~clock:fixture.clock (F.Reply_with (fun _ body ->
      let request=Yojson.Safe.from_string body in
      let forward=match member "state" request with
        | `Assoc _ -> true | `String _ -> false | _ -> fail "unexpected evaluation state" in
      directions:= !directions @ [forward];
      let answers=member "questions" request |> Yojson.Safe.Util.to_assoc |> List.map (fun (id,_) ->
        let answer=if forward then T.Choice_answer {choice=forward_verdict;confidence=1.;
          probabilities=List.map (fun label -> label,(if label=forward_verdict then 1. else 0.))
            ["mergeable";"different_context";"loses_knowledge";"uncertain"]}
          else T.Noul_answer {noul=0.} in id,T.answer_to_yojson answer) in
      `OK,Yojson.Safe.to_string (`Assoc ["model",`String "context-fixture";"answers",`Assoc answers]))) in
    Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "context-fixture-key") (fun () ->
    Masc_test_deps.with_typesafeai_policy
      {Runtime_schema.default_typesafeai with lane_enabled=true;absorb_gate=true;
       destinations=({endpoint=jev.base_url;model="context-fixture";api_key_env="TYPESAFEAI_API_KEY"},[])} (fun () ->
        let authority=Absorb.resolve ~keeper_id:keeper_name in
        let intent=io (fun () -> Gate.prepare_root ~store:fixture.store ~owner ~capture ~parent:record
          ~proposal ~request_id:(Random_id.uuid_v7 ()) ~authority |> get) in
        let guidance=member "guidance" intent.request in
        let prompts=Yojson.Safe.Util.(member "prompts" guidance |> to_assoc) in
        check bool "both forward context policies are captured" true
          (List.mem_assoc "pair" prompts && List.mem_assoc "observations" prompts);
        let bad_guidance=`Assoc (("unknown_field",`Bool true)::Yojson.Safe.Util.to_assoc guidance) in
        let request=`Assoc (("guidance",bad_guidance)::List.remove_assoc "guidance" (Yojson.Safe.Util.to_assoc intent.request)) in
        let forged=retain_gate_payload fixture ~owner ~parent:record ~request_id:intent.request_id ~request in
        check (result unit string) "captured guidance with an unknown field is refused"
          (Error "Captured absorption guidance has unknown, duplicate or missing fields")
          (io (fun () -> Gate.validate_payload ~owner ~capture ~parent:record ~record:forged
            ~read:(fun ~scope:_ ~request_id:_ -> fail "a forged guidance must refuse before ancestry")
            ~read_body:(fun ~scope:_ ~request_digest:_ -> fail "a forged guidance must refuse before body lookup")));
        let parent=memory_action fixture (fun () -> match Commit.begin_gate ~store:fixture.store ~owner ~capture
          ~record ~gate_root_id:intent.request_id ~authority |> get with
          | Prepared parent -> parent | Reload_original -> fail "new preparation expected") in
        check json "the captured guidance is the immutable durable preparation" intent.request
          (match Progress.preparation parent.progress with
           | Some (Preparation_pending intended) -> intended.request
           | None | Some (Preparation_confirmed _) -> fail "pending original preparation expected");
        let parent=memory_action fixture (fun () -> Gate.recover_root ~store:fixture.store ~owner ~capture |> get) in
        let gate=io (fun () -> Gate.retain ~store:fixture.store ~owner ~capture ~parent ~proposal
          ~request_id:intent.request_id ~authority ~predecessor:None |> get) in
        let result=memory_action fixture (fun () -> match Gate.resume ~store:fixture.store ~owner ~capture ~record:gate
          ~live_authority:(Some authority) ~request_clock:(fun () -> Ok fixture.clock) ~before_dispatch:(fun () -> Ok ()) |> get with
          | Complete (result,_) -> result | Pending _ -> fail "the actual context evaluation must complete") in
        check int "the observed absorption follows the actual verdict"
          (if forward_verdict="mergeable" then 1 else 0)
          (List.length (Absorb.absorbed_of_run result));
        let verdicts=Absorb.run_result_to_yojson result in
        check (list string) "the pair is asked with the supporting candidate its claim names"
          ["with_cited_observations"]
          (List.concat_map (fun field -> member field verdicts |> Yojson.Safe.Util.to_list
             |> List.map (fun verdict -> member "asked" verdict |> Yojson.Safe.Util.to_string))
             ["conveyed";"left"]);
        let requests=F.post_count jev in
        check (list bool) "only an unapplied claim also needs the original reverse question"
          (if forward_verdict="mergeable" then [true] else [true;false]) !directions;
        let replayed=io (fun () -> Gate.restore_latest_result ~store:fixture.store ~owner
          ~parent_execution:capture ~gate_request_id:gate.request_id |> get) in
        check json "strict original replay returns the same result" (Absorb.run_result_to_yojson result)
          (Absorb.run_result_to_yojson replayed);
        check int "strict replay sends no evaluation" requests (F.post_count jev);
        check int "the original Librarian answer is sent once" 1 (F.post_count fixture.server)))))
    ["mergeable";"loses_knowledge"];
  List.iter (fun (marker,key,empty) -> with_fixture (fun ~sw:_ fixture ->
    let record,capture,final=retained_absorbing_answer_before_gate fixture in
    let proposal=match final with Lane_addon_exact.Call_final (Answered {output;_}) -> Lane_addon_exact.checked_json output
      | _ -> fail "the fixture requires its actual host answer" in
    let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
    let record=memory_action fixture (fun () -> retain_judgment fixture record final) in
    with_absorb_gate_policy ~enabled:true ~excluded:false (fun () ->
    with_policy_overrides [key] (fun () ->
      Prompt_registry.clear_prompt_override key;
      with_missing_librarian_fragment ~empty marker (fun () ->
        let authority=Keeper_librarian_absorb_gate.resolve ~keeper_id:keeper_name in
        let request_id=Random_id.uuid_v7 () in
        let expected=Error (Printf.sprintf "Prompt '%s' is missing" key) in
        check (result unit string) "each context policy is required before preparation" expected
          (io (fun () -> Gate.prepare_root ~store:fixture.store ~owner ~capture ~parent:record
            ~proposal ~request_id ~authority) |> Result.map (fun _ -> ()));
        check (result unit string) "direct retention cannot bypass a context policy" expected
          (io (fun () -> Gate.retain ~store:fixture.store ~owner ~capture ~parent:record
            ~proposal ~request_id ~authority ~predecessor:None) |> Result.map (fun _ -> ()));
        check int "a missing context policy publishes no child" 0
          (io (fun () -> Owner.load_scope ~store:fixture.store ~scope:(Gate.scope owner) |> owned |> List.length));
        check int "a missing context policy never repeats the original answer" 1 (F.post_count fixture.server))))))
    (List.concat_map (fun empty ->
       ["absorb_pair",Prompt_names.librarian_absorb_pair,empty;
        "absorb_observations",Prompt_names.librarian_absorb_observations,empty]) [false;true])

(* RFC-0517 §2.2: a captured judgment counts once, when [resume] stores its
   terminal. A resume of the retained record and a strict replay count nothing. *)
let test_captured_judgment_counts_once_when_its_terminal_is_stored ()=with_fixture (fun ~sw fixture ->
  let module Absorb=Keeper_librarian_absorb_gate in
  let module T=Typesafeai_types in
  let record,capture,final=retained_absorbing_answer_before_gate fixture in
  let proposal=match final with Lane_addon_exact.Call_final (Answered {output;_}) -> Lane_addon_exact.checked_json output
    | _ -> fail "the fixture requires its actual host answer" in
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let record=memory_action fixture (fun () -> retain_judgment fixture record final) in
  let net=Eio_context.get_net_opt () |> Option.to_result ~none:"fixture network missing" |> get in
  let jev=F.start_server ~sw ~net ~clock:fixture.clock (F.Reply_with (fun _ body ->
    let request=Yojson.Safe.from_string body in
    let forward=match member "state" request with
      | `Assoc _ -> true | `String _ -> false | _ -> fail "unexpected evaluation state" in
    let answers=member "questions" request |> Yojson.Safe.Util.to_assoc |> List.map (fun (id,_) ->
      let answer=if forward then T.Choice_answer {choice="loses_knowledge";confidence=1.;
        probabilities=List.map (fun label -> label,(if label="loses_knowledge" then 1. else 0.))
          ["mergeable";"different_context";"loses_knowledge";"uncertain"]}
        else T.Noul_answer {noul=0.} in id,T.answer_to_yojson answer) in
    `OK,Yojson.Safe.to_string (`Assoc ["model",`String "count-fixture";"answers",`Assoc answers]))) in
  (* Other cases in this binary move the same Keeper, so compare every cell before and after. *)
  let cells=List.concat_map (fun outcome -> List.map (fun decision ->
      Keeper_metrics.LibrarianAbsorbSources,outcome ^ "/" ^ decision,["outcome",outcome;"decision",decision])
      ["mergeable";"different_context";"loses_knowledge";"uncertain";"none"])
      ["conveyed";"left";"unjudged";"unjudgeable"]
    @ List.map (fun verdict -> Keeper_metrics.LibrarianAbsorbCopyChecks,verdict,["verdict",verdict])
      ["copy";"carries_new_statement";"not_judged"] in
  let read ()=List.map (fun (metric,_,labels) -> Otel_metric_store.metric_value_or_zero
    (Keeper_metrics.to_string metric) ~labels:(("keeper",keeper_name)::labels) ()) cells in
  let moved before=List.filter_map (fun ((_,cell,_),(earlier,now)) ->
    if Float.equal earlier now then None else Some (Printf.sprintf "%s %+g" cell (now -. earlier)))
    (List.combine cells (List.combine before (read ()))) in
  let one_judgment=["left/loses_knowledge +1";"carries_new_statement +1"] in
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "count-fixture-key") (fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=true;absorb_gate=true;
     destinations=({endpoint=jev.base_url;model="count-fixture";api_key_env="TYPESAFEAI_API_KEY"},[])} (fun () ->
      let authority=Absorb.resolve ~keeper_id:keeper_name in
      let intent=io (fun () -> Gate.prepare_root ~store:fixture.store ~owner ~capture ~parent:record
        ~proposal ~request_id:(Random_id.uuid_v7 ()) ~authority |> get) in
      memory_action fixture (fun () -> match Commit.begin_gate ~store:fixture.store ~owner ~capture
        ~record ~gate_root_id:intent.request_id ~authority |> get with
        | Prepared _ -> () | Reload_original -> fail "new preparation expected");
      let parent=memory_action fixture (fun () -> Gate.recover_root ~store:fixture.store ~owner ~capture |> get) in
      let gate=io (fun () -> Gate.retain ~store:fixture.store ~owner ~capture ~parent ~proposal
        ~request_id:intent.request_id ~authority ~predecessor:None |> get) in
      let resume record=memory_action fixture (fun () -> match Gate.resume ~store:fixture.store ~owner ~capture
        ~record ~live_authority:(Some authority) ~request_clock:(fun () -> Ok fixture.clock)
        ~before_dispatch:(fun () -> Ok ()) |> get with
        | Complete (result,record) -> result,record | Pending _ -> fail "the evaluation must complete") in
      let before=read () in
      let result,retained=resume gate in
      check (list string) "storing the terminal counts the judgment once" one_judgment (moved before);
      let requests=F.post_count jev in
      let again,_=resume retained in
      check json "a resume of the retained record returns its judgment" (Absorb.run_result_to_yojson result)
        (Absorb.run_result_to_yojson again);
      let replayed=io (fun () -> Gate.restore_latest_result ~store:fixture.store ~owner
        ~parent_execution:capture ~gate_request_id:gate.request_id |> get) in
      check json "strict replay returns the same judgment" (Absorb.run_result_to_yojson result)
        (Absorb.run_result_to_yojson replayed);
      check (list string) "a retained terminal is never counted again" one_judgment (moved before);
      check int "neither the resume nor the replay asks again" requests (F.post_count jev))))

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

(* The deploy check reads an original's Exact files as its consumer reads them
   (RFC exact-request-skips-a-slot-that-refused-its-input, section 6, L2b-2). *)
let test_preflight_refuses_a_finished_original_without_its_exact_record ()=with_fixture (fun ~sw:_ fixture ->
  drive_until fixture settled |> assert_settled;
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let capture=match observed_originals fixture with [_,capture] -> capture
    | [] | _::_::_ -> fail "expected one finished original" in
  let record_path,proof_path=exact_files fixture capture in
  let record=io (fun () -> Fs_compat.load_file record_path) in
  let deletes scope (refusal:Lane_addon_store_preflight.refusal)=
    List.mem (scope_directory fixture scope) refusal.delete in
  check int "a finished original passes on the Exact files it reads" 0
    (List.length (closure_preflight fixture).refusals);
  (* The Exact check deletes a record kept under another request's key, so
     the original's consumer finds no record. *)
  io (fun () -> write record_path (Yojson.Safe.to_string
    (with_field "request_id" (`String "another-request") (Yojson.Safe.from_string record))));
  let report=closure_preflight fixture in
  let refusal=exact_refusal fixture (Capture.scope owner) report in
  check bool "the refusal deletes the original's own scope" true (deletes (Capture.scope owner) refusal);
  check bool "and the forest scope of its owner" true (deletes (Parts.scope owner) refusal);
  check bool "and the proof link no record is left to name" true (List.mem proof_path refusal.delete);
  check bool "the record is the Exact check's to delete" false (List.mem record_path refusal.delete);
  check (list string) "the gate follows its parent and deletes the same files" refusal.delete
    (exact_refusal fixture (Gate.scope owner) report).delete;
  io (fun () -> Sys.remove record_path;Sys.remove proof_path);
  let _,manifest=closure_manifest fixture in
  check bool "a Captured closure reads its member, so the refusal deletes the closure scope too" true
    (deletes (Closure.scope owner) (exact_refusal fixture (Capture.scope owner) (closure_preflight fixture)));
  ignore (memory_action fixture (fun () -> io (fun () -> Closure.intend ~store:fixture.store manifest |> get)));
  check int "a Closing closure settles its member without reading Exact files" 0
    (List.length (closure_preflight fixture).refusals))

let test_preflight_reads_a_dispatch_pending_original_as_resume_does ()=with_fixture (fun ~sw:_ fixture ->
  let _,capture,_=retained_answer_before_gate fixture in
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let record_path,proof_path=exact_files fixture capture in
  let record=io (fun () -> Fs_compat.load_file record_path) and proof=io (fun () -> Fs_compat.load_file proof_path) in
  let finished=Yojson.Safe.from_string record in
  let rewrite path value=io (fun () -> write path (Yojson.Safe.to_string value)) in
  let restore ()=io (fun () -> write record_path record;write proof_path proof) in
  let passes reason=check int reason 0 (List.length (closure_preflight fixture).refusals) in
  let refuses reason=check bool reason true (refuses_owner fixture owner (closure_preflight fixture)) in
  passes "resume confirms the finished record it recovers";
  (* A proof link that is not JSON: the Exact check deletes the record with it. *)
  io (fun () -> write proof_path "{");
  refuses "the worker returns the final of a lost finished record, and no record confirms it";
  rewrite record_path (with_field "final" (Lane_addon_exact.final_to_json
    (Lane_addon_exact.Call_final (Input_refused Lane_addon_exact.Request_body_refused))) finished);
  refuses "admission reads the size evidence of a body refusal through the record the Exact check deletes";
  rewrite record_path (with_field "final" `Null finished);
  passes "a lost open record sends resume to the worker";
  restore ();
  rewrite record_path (with_field "final" (`String "unreadable") finished);
  refuses "a record whose shape cannot be read shows no final of the original";
  let request=Capture.request capture |> get in
  let other=Lane_addon_exact.request_of_json (with_field "messages"
      (`List [`Assoc ["role",`String "user";"text",`String "Another request under the same ID"]])
      (Lane_addon_exact.request_to_json request)) |> get in
  rewrite record_path (finished |> with_field "request" (Lane_addon_exact.request_to_json other)
    |> with_field "digest" (`String (Lane_addon_exact.digest other)));
  refuses "another request's record under the original's ID";
  io (fun () -> Sys.remove record_path);
  check bool "a proof link left without its record is deleted with the owner's scopes" true
    (List.mem proof_path (exact_refusal fixture (Capture.scope owner) (closure_preflight fixture)).delete);
  io (fun () -> Sys.remove proof_path);
  passes "with neither file resume asks the worker";
  let proof_json=Yojson.Safe.from_string proof in
  let executions=match member "executions" proof_json with
    | `List entries -> entries
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
      fail "a proof link lists its executions" in
  io (fun () -> write record_path record);
  rewrite proof_path (with_field "executions"
    (`List (List.map (with_field "store_root" (`String "/another/store/root")) executions)) proof_json);
  check bool "a proof naming another store root stops the scan before any refusal" true
    (Result.is_error (preflight_scan fixture));
  restore ())

let test_preflight_takes_a_body_refusal_judgment_without_a_host_record ()=with_fixture (fun ~sw:_ fixture ->
  let record,capture,_=retained_answer_before_gate fixture in
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let record_path,proof_path=exact_files fixture capture in
  memory_action fixture (fun () -> ignore (retain_judgment fixture record
    (Lane_addon_exact.Call_final (Input_refused Lane_addon_exact.Request_body_refused))));
  check bool "a host terminal that answered does not confirm the worker's refusal" true
    (refuses_owner fixture owner (closure_preflight fixture));
  io (fun () -> Sys.remove record_path);
  check int "with only a proof link left, the consumer takes the worker's refusal" 0
    (List.length (closure_preflight fixture).refusals);
  io (fun () -> Sys.remove proof_path);
  check int "and with no Exact file at all" 0 (List.length (closure_preflight fixture).refusals))

let test_preflight_refuses_a_judgment_its_recovered_answer_does_not_match ()=with_fixture (fun ~sw:_ fixture ->
  let record,_,final=retained_answer_before_gate fixture in
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  (* The strict decoder refuses this judgment, so its consumer recovers the
     final from the record's Answered terminal, which delivered other JSON. *)
  let judgment=with_field "output" (`Assoc ["not_an_admission_judgment",`Bool true])
    (Lane_addon_exact.final_to_json final) in
  memory_action fixture (fun () -> ignore (retain_judgment_json fixture record judgment));
  check bool "a judgment its recovered answer does not match stops the consumer" true
    (refuses_owner fixture owner (closure_preflight fixture)))

(* The host ends a request with the body refusal when no slot it called may
   pass again and the body refusal ranks first among the input refusals left;
   here its only slot refuses the body. It keeps the record and proof.
   Admission reads that proof as the size evidence of the part; with one
   candidate the part stays a singleton frontier behind an execution refusal. *)
let test_preflight_refuses_a_body_refusal_whose_size_evidence_goes ()=
  with_fixture ~initial:["a","Durable A"] (fun ~sw:_ fixture ->
    fixture.set_response (fun _ -> `Request_entity_too_large,refusal "invalid_request_error");
    let refused_execution (record,_)=match Progress.phase record.Owner.progress with
      | Progress.Rejected {stage=Progress.Execution;_} -> true
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Rejected {stage=Progress.Before_dispatch;_} | Subdividing _ | Subdivided _ ->
        false in
    ignore (drive_until fixture (fun _ -> List.exists refused_execution (observed_originals fixture)));
    let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
    let capture=match observed_originals fixture with [_,capture] -> capture
      | [] | _::_::_ -> fail "expected the one original the host refused" in
    check bool "the host retains the body refusal of its only slot" true
      (match (latest_execution fixture capture).Lane_addon_exact.outcome with
       | Call_ended (Input_refused Request_body_refused) -> true
       | Call_ended (Answered _ | Invalid_output _ | Output_limit_reached _
           | Input_refused (Input_capacity | Context_overflow | Invalid_request)) | Call_refused _ -> false);
    let record_path,proof_path=exact_files fixture capture in
    check int "the refusal passes while its record and proof are kept" 0
      (List.length (closure_preflight fixture).refusals);
    (* A proof link that is not JSON: the Exact check deletes the record with it. *)
    io (fun () -> write proof_path "{");
    check bool "the size evidence goes with the deleted record, so the owner is refused" true
      (refuses_owner fixture owner (closure_preflight fixture));
    io (fun () -> Sys.remove record_path;Sys.remove proof_path);
    check int "an original with no record loses nothing to the Exact check, and passes" 0
      (List.length (closure_preflight fixture).refusals))

(* A version 1 proof holds the request body. [run] refuses to read it, so
   the Exact check refuses the record that names it, and the Librarian check
   reads what that leaves as the original's consumer reads it
   (RFC exact-request-skips-a-slot-that-refused-its-input, section 6, L2b-3). *)
let version_1_proof fixture capture=
  let _,proof_path=exact_files fixture capture in
  let request=Lane_addon_exact.request_to_json (Capture.request capture |> get) in
  let proof=Yojson.Safe.from_string (io (fun () -> Fs_compat.load_file proof_path)) in
  let executions=match member "executions" proof with
    | `List entries -> entries
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
      fail "a proof link lists its executions" in
  let version_1 execution=match with_field "version" (`Int 1) execution with
    | `Assoc fields -> `Assoc (("request",request)::fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "a proof is an object" in
  io (fun () -> write proof_path
    (Yojson.Safe.to_string (with_field "executions" (`List (List.map version_1 executions)) proof)))

let test_preflight_refuses_a_finished_original_whose_proof_is_version_1 ()=with_fixture (fun ~sw:_ fixture ->
  drive_until fixture settled |> assert_settled;
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let capture=match observed_originals fixture with [_,capture] -> capture
    | [] | _::_::_ -> fail "expected one finished original" in
  check int "a finished original passes on its version 2 proof" 0
    (List.length (closure_preflight fixture).refusals);
  version_1_proof fixture capture;
  let report=closure_preflight fixture in
  check bool "the Exact check deletes the record, so the owner of the finished original is refused" true
    (refuses_owner fixture owner report);
  check bool "with the forest scope of its owner" true
    (List.mem (scope_directory fixture (Parts.scope owner)) (exact_refusal fixture (Capture.scope owner) report).delete))

(* The one original, which waits for its host final: the worker lost the
   final on its way, or the host has not ended the request. *)
let dispatch_pending fixture=match observed_originals fixture with
  | [record,capture] ->
    (match Progress.phase record.Owner.progress with
     | Progress.Dispatch_pending _ -> capture
     | Captured | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
     | Rejected _ | Subdividing _ | Subdivided _ -> fail "expected the original to wait for its host final")
  | [] | _::_::_ -> fail "expected one original"
let exact_scan fixture=io (fun () -> Lane_addon_store_preflight.scan
  Lane_addon_store_preflight.Store.Exact_requests ~base_path:fixture.base_path) |> get
let named (report:Lane_addon_store_preflight.report)=
  List.concat_map (fun (refusal:Lane_addon_store_preflight.refusal) -> refusal.delete) report.refusals
  |> List.sort_uniq String.compare

let test_preflight_refuses_a_lost_answer_whose_proof_is_version_1 ()=with_fixture (fun ~sw:_ fixture ->
  ignore (retained_answer_before_gate fixture);
  let capture=dispatch_pending fixture in
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  check int "with its version 2 proof resume confirms the finished record" 0
    (List.length (closure_preflight fixture).refusals);
  version_1_proof fixture capture;
  check bool "a finished record whose proof is version 1 is lost, and no record confirms the worker's final" true
    (refuses_owner fixture owner (closure_preflight fixture)))

(* The host ends the request with its only slot's body refusal and keeps the
   record and proof; the worker loses that final. *)
let test_preflight_refuses_a_lost_body_refusal_whose_proof_is_version_1 ()=
  with_fixture ~initial:["a","Durable A"] (fun ~sw:_ fixture ->
    fixture.set_response (fun _ -> `Request_entity_too_large,refusal "invalid_request_error");
    fixture.delivery_loss:=true;
    let before= !(fixture.deliveries) in
    ignore (run_worker fixture);
    await_delivery fixture ~after:before;
    let capture=dispatch_pending fixture in
    let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
    check bool "the host retains the body refusal of its only slot" true
      (match (latest_execution fixture capture).Lane_addon_exact.outcome with
       | Call_ended (Input_refused Request_body_refused) -> true
       | Call_ended (Answered _ | Invalid_output _ | Output_limit_reached _
           | Input_refused (Input_capacity | Context_overflow | Invalid_request)) | Call_refused _ -> false);
    check int "with its version 2 proof resume confirms the body refusal" 0
      (List.length (closure_preflight fixture).refusals);
    version_1_proof fixture capture;
    check bool "admission reads the size evidence of the body refusal through the record the Exact check deletes" true
      (refuses_owner fixture owner (closure_preflight fixture)))

(* The host keeps the record open behind its only slot's refused call. *)
let test_preflight_passes_an_open_record_whose_proof_is_version_1 ()=with_fixture (fun ~sw:_ fixture ->
  fixture.set_response (fun _ -> `Too_many_requests,refusal "rate_limit_error");
  ignore (run_worker fixture);
  F.await_first_request fixture.server;
  await_host_cycle fixture;
  let capture=dispatch_pending fixture in
  let record_path,proof_path=exact_files fixture capture in
  check bool "the host keeps the record open" true
    (match member "final" (Yojson.Safe.from_string (io (fun () -> Fs_compat.load_file record_path))) with
     | `Null -> true
     | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ -> false);
  check (pair int int) "with its version 2 proof both checks keep the open record" (0,0)
    (List.length (closure_preflight fixture).refusals,List.length (exact_scan fixture).refusals);
  version_1_proof fixture capture;
  check bool "the Exact check deletes the open record with its version 1 proof" true
    (let deleted=named (exact_scan fixture) in List.for_all (fun path -> List.mem path deleted) [record_path;proof_path]);
  check int "resume then asks the worker, so the Librarian check passes" 0
    (List.length (closure_preflight fixture).refusals))

(* Each partition compares its evidence with the latest proof of the
   execution that refused the whole input. One check names every scope of
   that owner; with those and the Exact check's files deleted, both pass. *)
let test_preflight_names_a_split_owner_whose_source_proof_is_version_1 ()=with_fixture (fun ~sw:_ fixture ->
  fixture.set_response (fun capture ->
    if List.length (Queue.candidates (Capture.batch capture))>1
    then `Request_entity_too_large,refusal "invalid_request_error"
    else `OK,F.openai_response (answer (fun _ -> true) capture));
  ignore (drive_until fixture (fun _ -> io (fun () -> pending_rows fixture.keepers_dir=[])));
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let split=match List.filter (fun (_,capture) -> List.length (Queue.candidates (Capture.batch capture))>1)
      (observed_originals fixture) with
    | [_,capture] -> capture
    | [] | _::_::_ -> fail "expected the one original that refused its whole input" in
  ignore (closure_manifest fixture);
  check (pair int int) "the split owner passes on its version 2 proofs" (0,0)
    (List.length (closure_preflight fixture).refusals,List.length (exact_scan fixture).refusals);
  version_1_proof fixture split;
  let librarian=named (closure_preflight fixture) in
  List.iter (fun (name,scope) ->
      check bool ("one check names the owner's " ^ name) true (List.mem (scope_directory fixture scope) librarian))
    ["execution",Capture.scope owner;"parts",Parts.scope owner;"partitions",Parts.partition_scope owner;
     "gate",Gate.scope owner;"closure",Closure.scope owner];
  let _,proof_path=exact_files fixture split in
  let exact=named (exact_scan fixture) in
  check bool "the Exact check names the version 1 proof" true (List.mem proof_path exact);
  io (fun () -> List.iter Fs_compat.remove_tree (librarian @ exact));
  check (pair int int) "with the named files deleted both checks pass" (0,0)
    (List.length (closure_preflight fixture).refusals,List.length (exact_scan fixture).refusals))

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
    (match run_worker fixture with Worker.Awaiting_worker _ -> ()
     | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Addon_unattached _ | Unavailable _ ->
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
    (match run_worker fixture with Worker.Awaiting_worker _ -> ()
     | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Addon_unattached _ | Unavailable _ -> fail "first actual provider must be pending");
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
      | Pending _ | Awaiting_worker _ | Recheck_new_input -> await_delivery fixture ~after:before;drive_second ()
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
   | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ | Awaiting_worker _ | Unavailable _ ->
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
  match snd (Masc_test_deps.waitpid_nointr pid) with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED 124 -> Alcotest.fail "scenario exceeded the process hang guard"
  | Unix.WEXITED code -> Alcotest.fail (Printf.sprintf "scenario exited %d" code)
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
    Alcotest.fail (Printf.sprintf "scenario ended with signal %d" signal)

let () =
  if Sys.getenv_opt "MASC_TEST_46252_WAKE" = Some "1" then (
    test_configuration_wake_completes_before_concurrent_settle (); exit 0);
  run "Actual Addon Librarian explicit-candidate owner" ["production",[
  test_case "foreign closure IDs are refused before publication" `Quick test_foreign_closure_id_is_refused_before_publication;
  test_case "preflight observes closures published after its empty observation" `Quick
    test_preflight_rechecks_a_closure_created_after_an_empty_observation;
  test_case "the owner recovers after moving a gate" `Quick (test_owner_recovers_a_partial_closure 1);
  test_case "the owner recovers after an execution record moved before body cleanup" `Quick
    (test_owner_recovers_a_partial_closure 2);
  test_case "the owner recovers after moving the final source" `Quick (test_owner_recovers_a_partial_closure 3);
  test_case "a closure cannot consume pending ACKs" `Quick test_closure_recovery_refuses_pending_ack;
  test_case "closure preflight and sweep preserve each partial movement" `Quick test_closure_projection_preserves_each_partial_move;
  test_case "a Captured closure cannot explain a missing member" `Quick test_captured_closure_cannot_explain_a_missing_member;
  test_case "a closing manifest cannot hide changed live metadata" `Quick
    (test_closing_manifest_does_not_hide_changed_or_missing_evidence false);
  test_case "a closing manifest cannot hide a missing archive marker" `Quick
    (test_closing_manifest_does_not_hide_changed_or_missing_evidence true);
  test_case "captured admission and retirement policy survive override changes" `Quick test_admission_capture_keeps_original_policy;
  test_case "unused retirement policy cannot block capture or ACK" `Quick test_unused_retirement_policy_does_not_block_admission;
  test_case "retirement policy is required only for its actual suffix" `Quick test_retirement_policy_is_required_only_for_its_suffix;
  test_case "used retirement policy stays frozen across current policy changes" `Quick test_used_retirement_policy_survives_current_policy_changes;
  test_case "missing admission policy refuses before capture or dispatch" `Quick test_missing_admission_policy_refuses_before_capture;
  test_case "missing absorb policy refuses before root publication" `Quick test_missing_absorb_policy_refuses_before_preparation;
  test_case "off and excluded gates capture and replay without unused policy" `Quick test_unused_absorb_policy_is_captured_and_replayed;
  test_case "enabled empty absorption captures and replays without unused policy" `Quick test_enabled_empty_absorptions_need_no_guidance;
  test_case "absorbing admission captures both context policies" `Quick test_absorbing_admission_captures_both_context_policies;
  test_case "a captured judgment counts once when its terminal is stored" `Quick
    test_captured_judgment_counts_once_when_its_terminal_is_stored;
  test_case "actual Memory lane, worker, HTTP, domain validation and receipt-backed ACK" `Quick test_actual_happy_path;
  test_case "a pass with no new input after the commit is Idle" `Quick test_pass_without_new_input_after_commit_is_idle;
  test_case "the production lane closes a completed Keeper without another external event" `Quick
    test_production_lane_closes_without_another_external_event;
  test_case "a distinct new tail survives closing its predecessor forest" `Quick
    test_a_new_tail_survives_closing_the_finished_forest;
  test_case "unchanged semantic deferral preserves the same original" `Quick test_unchanged_deferred_does_not_remint;
  test_case "new tail rejudges the complete old sparse gap against current Memory" `Quick test_gap_and_new_tail_are_rejudged_together;
  test_case "an absent destination ends the original once and its candidate is judged again" `Quick
    test_absent_destination_ends_the_original_and_is_judged_again;
  test_case "original host answer recovers locally while Addon is Off" `Quick test_retained_host_terminal_commits_off;
  test_case "actual output limit followed by HTTP 413 retains mixed diagnosis" `Quick
    test_actual_output_limit_then_capacity_keeps_both_causes;
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
  test_case "an original a stopped server interrupted settles and its part is judged again" `Quick test_interrupted_original_is_prepared_again;
  test_case "an original this process cut keeps its part waiting with no new provider call" `Quick test_cut_original_keeps_its_part_waiting;
  test_case "forged worker Finished cannot commit without original host execution proof" `Quick test_forged_worker_finished_cannot_commit_without_host_proof;
  test_case "mismatched retained final cannot borrow real original host proof" `Quick test_mismatched_retained_judgment_cannot_borrow_host_proof;
  test_case "admission confirms a final the host never retained" `Quick test_admission_confirms_a_final_the_host_never_retained;
  test_case "the deploy check refuses a finished original without its Exact record" `Quick
    test_preflight_refuses_a_finished_original_without_its_exact_record;
  test_case "the deploy check reads a Dispatch_pending original as resume does" `Quick
    test_preflight_reads_a_dispatch_pending_original_as_resume_does;
  test_case "the deploy check takes a body refusal judgment without a host record" `Quick
    test_preflight_takes_a_body_refusal_judgment_without_a_host_record;
  test_case "the deploy check refuses a judgment its recovered answer does not match" `Quick
    test_preflight_refuses_a_judgment_its_recovered_answer_does_not_match;
  test_case "the deploy check refuses a body refusal whose size evidence goes" `Quick
    test_preflight_refuses_a_body_refusal_whose_size_evidence_goes;
  test_case "the deploy check refuses a finished original whose proof is version 1" `Quick
    test_preflight_refuses_a_finished_original_whose_proof_is_version_1;
  test_case "the deploy check refuses a lost answer whose proof is version 1" `Quick
    test_preflight_refuses_a_lost_answer_whose_proof_is_version_1;
  test_case "the deploy check refuses a lost body refusal whose proof is version 1" `Quick
    test_preflight_refuses_a_lost_body_refusal_whose_proof_is_version_1;
  test_case "the Librarian check passes an open record whose proof is version 1" `Quick
    test_preflight_passes_an_open_record_whose_proof_is_version_1;
  test_case "the deploy check names a split owner whose source proof is version 1" `Quick
    test_preflight_names_a_split_owner_whose_source_proof_is_version_1;
  test_case "pending first gate intent recovers the same absent child while Off" `Quick (test_original_gate_root_publication_recovery Before_child);
  test_case "published first gate before ACK recovers the same child while Off" `Quick (test_original_gate_root_publication_recovery Child_before_ack);
  test_case "acknowledged missing first gate refuses without replacement" `Quick (test_original_gate_root_publication_recovery Acknowledged_then_missing);
  test_case "production refresh quiesces with a new tail while its provider remains pending" `Quick test_production_refresh_new_tail_quiesces_while_provider_pending;
  test_case "a purged pending original cannot block another Keeper in the same shared worker" `Quick test_purged_original_does_not_block_another_keeper;
  test_case "attachment wakes a persisted history owner without queue or original" `Quick test_attach_wakes_persisted_keeper_without_queue_or_original;
  test_case "no attached Add-on reports explicit admission off and keeps every candidate" `Quick test_unattached_addon_reports_off_and_keeps_candidates]]
