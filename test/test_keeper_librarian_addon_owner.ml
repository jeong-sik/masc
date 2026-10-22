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
let originals base_path keepers_dir store =
  let owner=original_owner base_path keepers_dir in
  let inventory=Parts.discover ~store ~owner ~restore_gate:(Gate.restore_size_evidence ~store ~owner) |> get in
  Owner.discover ~store ~scope:(Capture.scope owner) |> owned |> List.map (fun record ->
    let capture=Capture.restore ~owner ~load_parent:(Parts.load_parent inventory) record |> get in record,capture)
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

let backend env base_path delivery delivery_observed observation_observed after_submit : Runtime.For_testing.backend = {
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
      resolved_image=Some (Lane_addon_engine.image_of_inspect Lane_addon_types.Docker ("sha256:" ^ String.make 64 'a') |> get);
      observe=(fun ~binding ~sources ->
        let result=Protocol.observe protocol ~binding ~sources |> Result.map_error protocol_error in
        observation_observed ();result);
      exported_tools=(fun () -> Protocol.exported_tools protocol);
      call_exported_tool=(fun ~on_result ~authorize ~principal ~name ~arguments ->
        let result=Protocol.call_exported_tool ~on_result ?authorize ~principal protocol ~name ~arguments
          |> Result.map_error invocation_error in
        (match member "kind" arguments with `String "submit" -> after_submit ()
         | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> ());
        result);
      action_schema=(fun () -> Protocol.action_schema protocol);
      act=(fun ~arguments -> Protocol.act protocol ~arguments |> Result.map_error protocol_error);
      stop=(fun () -> Protocol.close protocol;Ok (Lane_addon_lifecycle.Released
        {engine=Lane_addon_lifecycle.Docker_engine "fixture-resource-launch";container_id=Some instance_id}));
      host=Some {await_change=None;
        list_requests=(fun () -> Protocol.host_requests protocol |> Result.map_error protocol_error);
        deliver=(fun ~arguments ->
          let result=if !delivery then Error "controlled reply loss before worker delivery"
            else Protocol.host_result protocol ~arguments |> Result.map_error protocol_error in
          delivery_observed ();result)}} in
    on_created connection;Ok connection);
  package_ready=(fun ~package:_ -> Ok ());
  acquire=(fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
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
}
let observed_originals fixture=io (fun () -> originals fixture.base_path fixture.keepers_dir fixture.store)
let start_worker fixture =
  let completed,resolve=Eio.Promise.create () in
  let outcome=Memory_lane.submit ~base_path:fixture.base_path ~keeper_name (fun () ->
    match Worker.run ~base_path:fixture.base_path ~keeper_name with
    | outcome -> Eio.Promise.resolve resolve (Ok outcome)
    | exception exn ->
      let backtrace=Printexc.get_raw_backtrace () in
      ignore (Eio.Promise.try_resolve resolve (Error exn));
      Printexc.raise_with_backtrace exn backtrace) in
  (match outcome with Memory_lane.Submitted -> ()
   | Coalesced | Ran_inline | Dropped -> fail "actual serialized Memory lane did not own this fixture unit");
  completed
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
      else (await_delivery fixture ~after:before;loop ()) in loop ())
let assert_settled = function Worker.Settled _ -> ()
  | Disabled | Idle | Recheck_new_input | Pending _ | Unavailable _ -> fail "actual original decision did not commit Memory"
let settled = function Worker.Settled _ -> true
  | Disabled | Idle | Recheck_new_input | Pending _ | Unavailable _ -> false
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
      | Ok owner -> (match Owner.discover ~store:fixture.store ~scope:(Capture.scope owner) with
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
      let meta=Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper_name;
        "trace_id",`String "librarian-original-owner"]) |> get in
      io (fun () -> Keeper_meta_store.replace_snapshot config meta |> get;
        List.iter (fun (id,claim) -> ignore (append keepers_dir id claim)) initial);
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
        let messages=Yojson.Safe.from_string body |> member "messages" |> Yojson.Safe.Util.to_list in
        let captures=io (fun () -> originals base_path keepers_dir store) in
        let matches=List.filter (fun (_,capture) ->
          let original=Capture.request capture |> get |> Lane_addon_exact.request_to_json in
          let sent=member "messages" original |> Yojson.Safe.Util.to_list in
          List.length sent=List.length messages && List.for_all2 (fun original sent ->
            member "text" original=member "content" sent && member "role" original=member "role" sent) sent messages) captures in
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
      let fixture={base_path;config;keepers_dir;store;source;declaration;server;
        set_response=(fun callback -> response:=callback);delivery_loss;deliveries;delivery_changed;
        clock=Eio.Stdenv.clock env;observations;observation_changed;response_checkpoint;
        extra_server=start_server;submit_barrier} in
      Runtime.For_testing.with_backend
        (backend env base_path delivery_loss delivery_observed observation_observed (fun () -> !submit_barrier ())) (fun () ->
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
   | Quota -> check bool "actual quota visit vetoes smaller input" true evidence.size_independent_execution_failure
   | Invalid -> check bool "actual schema/domain rejection vetoes smaller input" true evidence.invalid_output);
  check bool "whole-walk production classifier rejects recursive partition" false
    (Keeper_exact_walk_failure.refuses_input_capacity evidence);
  ignore (run_worker fixture);
  let owner=io (fun () -> original_owner fixture.base_path fixture.keepers_dir) in
  let inventory=io (fun () -> Parts.discover ~store:fixture.store ~owner
    ~restore_gate:(Gate.restore_size_evidence ~store:fixture.store ~owner) |> get) in
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
  | Disabled | Idle | Recheck_new_input | Settled _ | Pending _ -> fail "invalid complete original history must refuse before local repair"
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
  let gates=io (fun () -> Owner.discover ~store:fixture.store ~scope:(Gate.scope owner) |> owned) in
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
    (io (fun () -> Owner.discover ~store:fixture.store ~scope:(Gate.scope owner) |> owned |> List.length));
  check string "missing gate leaves the committed Memory unchanged" memory_before
    (io (fun () -> Fs_compat.load_file memory_path));
  check int "missing gate cannot repeat the original model call" posts (F.post_count fixture.server);
  let originals_after=io (fun () -> Owner.discover ~store:fixture.store ~scope:(Capture.scope owner) |> owned)
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
  let records=io (fun () -> Owner.discover ~store:fixture.store ~scope |> owned) in
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
      (io (fun () -> Owner.discover ~store:fixture.store ~scope |> owned |> List.length));
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

let ()=run "Actual Addon Librarian explicit-candidate owner" ["production",[
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
  test_case "actual result bridge resumes only the original serialized Memory lane" `Quick test_actual_result_bridge_resumes_original_memory_lane]]
