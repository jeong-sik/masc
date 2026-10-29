(** The durable message floor's fixture: the actual configured Runtime, the Python
    worker and the common host Exact HTTP, with only container launch/cleanup and
    the provider's HTTP server substituted. These tests do not claim Docker, real
    paid providers or visible UI. *)
open Alcotest
open Masc
module Step = Keeper_librarian_floor_step_request
module Step_owner = Keeper_librarian_floor_step_owner
module Edge = Keeper_librarian_durable_edge
module Durable = Keeper_librarian_durable_request
module Machine = Keeper_librarian_message_floor.Machine
module Unread = Keeper_librarian_unread
module Plan = Keeper_librarian_memory_plan
module Memory_runtime = Keeper_librarian_runtime
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Store = Lane_addon_store
module Addon_runtime = Lane_addon_runtime
module Protocol = Lane_addon_worker_protocol
module Memory = Keeper_memory_os_current
module F = Exact_output_fixture

let get = function Ok value -> value | Error detail -> fail detail
let keeper_name = "floor-step-owner-fixture"
let () = Mirage_crypto_rng_unix.use_default ()
let io f = Eio_unix.run_in_systhread f
let contains haystack needle = Astring.String.is_infix ~affix:needle haystack
let write path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> output_string channel bytes)

let install_keeper ~config ~name ~trace_id =
  io (fun () ->
    Masc_test_deps.declare_fixture_keeper ~sandbox_image:"base" ~base_path:config.Workspace.base_path
      ~sandbox_profile:(Some Keeper_types_profile.Docker) name;
    Keeper_types_profile.invalidate_keeper_profile_snapshots ());
  let meta =
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "instructions", `String (name ^ " fixture instructions");
                "trace_id", `String trace_id ]) |> get in
  Keeper_meta_store.replace_snapshot config meta |> get

let protocol_error = function
  | Protocol.Invalid_contract s | Protocol.Protocol_failed s | Protocol.Invalid_observation s -> s
  | Host_refusal (Lane_addon_call_context.Rejected s | Unavailable s | Activity_disabled s | Activity_unobserved s) -> s
  | Stopped -> "worker protocol stopped"

let invocation_error = function
  | Protocol.Host_refusal refusal -> Lane_addon_call_context.Host_refusal refusal
  | (Protocol.Invalid_contract _ | Protocol_failed _ | Invalid_observation _ | Stopped) as error ->
    Lane_addon_call_context.Transport_error (protocol_error error)

let publish_routes base_path urls =
  let slots = List.mapi (fun i url -> { F.id = "floor-step-candidate-" ^ string_of_int i; base_url = url }) urls in
  ignore (F.publish_registry ~lane_id:"librarian/durable"
    ~slot_ids:(List.map (fun (slot : F.target_fixture) -> slot.id) slots)
    (F.resolver_snapshot ~source:base_path slots) : Runtime_exact_output_registry.t)

(* The worker is the real Python process; the host side of its requests, the
   store and the Exact HTTP flow are the production ones. *)
let backend env base_path delivery_observed transform_reply : Addon_runtime.For_testing.backend = {
  start = (fun ~sw ~state_owner ~instance_id ~installation_id:_ ~package ~binding:_ ~on_authority
             ~is_live_instance:_ ~on_created ->
    let state_owner = match state_owner with Some owner -> owner | None -> fail "persistent worker has no state owner" in
    let state = Filename.concat base_path ("worker-state-" ^ Store.digest (Lane_addon_worker_state.identity state_owner)) in
    Fs_compat.mkdir_p state;
    let contract = Protocol.contract_of_package package |> Result.map_error protocol_error |> get in
    let protocol = Protocol.create ~instance_id ~contract () in
    get (on_authority (Lane_addon_lifecycle.Container_authority
      { runtime = Lane_addon_types.Docker; engine = Lane_addon_lifecycle.Docker_engine "fixture-resource-launch" }));
    let client = Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env) ~command:"python3"
      ~args:[ Filename.concat package.directory "server.py"; "--state"; state ]
      ~max_response_bytes:contract.max_reply_bytes () |> Result.map_error Agent_core.Error.to_string |> get in
    Protocol.initialize protocol client |> Result.map_error protocol_error |> get;
    let connection : Addon_runtime.For_testing.connection = {
      browser = None;
      resource = Lane_addon_lifecycle.Container_resource instance_id;
      await_exit = (fun () -> Format.asprintf "%a" Eio.Process.pp_status (Agent_core.Mcp.await_exit client));
      resolved_image = Some (Lane_addon_engine.image_of_inspect Lane_addon_types.Docker ("sha256:" ^ String.make 64 'a') |> get);
      observe = (fun ~binding ~sources -> Protocol.observe protocol ~binding ~sources |> Result.map_error protocol_error);
      exported_tools = (fun () -> Protocol.exported_tools protocol);
      call_exported_tool = (fun ~companion:_ ~on_result ~on_dispatch ~authorize ~principal ~name ~arguments ->
        Protocol.call_exported_tool ~on_result ~on_dispatch ?authorize ~principal protocol ~name ~arguments
        |> Result.map_error invocation_error
        |> Result.map (transform_reply arguments));
      operator_schema = (fun () -> None);
      companion_tools = (fun () -> []);
      observation_effect = (fun _ -> Lane_addon_call_context.May_change);
      call_operator = (fun ~admit:_ ~arguments:_ -> Error Masc.Lane_addon_worker_protocol.Operator_unavailable);
      action_schema = (fun () -> Protocol.action_schema protocol);
      act = (fun ~arguments -> Protocol.act protocol ~arguments |> Result.map_error protocol_error);
      stop = (fun () -> Protocol.close protocol;
        Ok (Lane_addon_lifecycle.Released
          { engine = Lane_addon_lifecycle.Docker_engine "fixture-resource-launch"; container_id = Some instance_id }));
      host = Some { await_change = None;
        list_requests = (fun () -> Protocol.host_requests protocol |> Result.map_error protocol_error);
        deliver = (fun ~arguments ->
          let result = Protocol.host_result protocol ~arguments |> Result.map_error protocol_error in
          delivery_observed ();
          result) } } in
    on_created connection;
    Ok connection);
  package_ready = (fun ~package:_ -> Ok ());
  acquire = (fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_
               ~read_browser_document:_ ~binding:_ -> Ok (`List []));
  recover_stop = (fun ~state_owner:_ ~instance_id:_ ~authority ~resource -> match authority, resource with
    | Lane_addon_lifecycle.Container_authority { engine; _ }, Some (Lane_addon_lifecycle.Container_resource id) ->
      Ok (Lane_addon_lifecycle.Released { engine; container_id = Some id })
    | Lane_addon_lifecycle.Container_authority { engine; _ }, None ->
      Ok (Lane_addon_lifecycle.Released { engine; container_id = None })
    | Lane_addon_lifecycle.Container_authority _, Some (Lane_addon_lifecycle.Native_resource _)
    | Lane_addon_lifecycle.Native_admission _, (None | Some _) ->
      Error (Lane_addon_lifecycle.Cleanup_unconfirmed "fixture owns container lifecycle only"));
  condition_met = (fun ~runtime:_ _ -> true);
  sweep = (fun ~runtime:_ ~is_live_instance:_ -> Ok []) }

type fixture = {
  base_path : string;
  config : Workspace.config;
  keepers_dir : string;
  store : Store.t;
  source : string;
  declaration : bool -> string;
  server : F.test_server;
  respond : (string -> Cohttp.Code.status_code * string) ref;
  transform_reply : (Yojson.Safe.t -> Mcp_protocol.Mcp_types.tool_result -> Mcp_protocol.Mcp_types.tool_result) ref;
  deliveries : int ref;
  delivery_changed : Eio.Condition.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
}

let reconcile fixture =
  Addon_runtime.reconcile_configuration ~config:fixture.config
    ~directory:(Addon_runtime.configuration_directory fixture.config) |> get |> ignore

let set_enabled fixture enabled =
  io (fun () -> write fixture.source (fixture.declaration enabled));
  reconcile fixture

let await_delivery fixture ~after =
  Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () ->
    Eio.Condition.loop_no_mutex fixture.delivery_changed (fun () ->
      if !(fixture.deliveries) > after then Some () else None))

let trace_id = "floor-step-owner"

let with_fixture f =
  let base_path = Filename.temp_dir "librarian-floor-step-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path ".masc/config")) (fun () ->
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.librarian_env_key (Some "true") (fun () ->
  F.with_official_client_runtimes (fun () -> Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Eio_guard.enable ();
    Eio.Switch.on_release sw Eio_guard.disable;
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Masc_test_deps.init_eio_clock env;
    Process_eio.init ~cwd_default:(Eio.Stdenv.cwd env) ~proc_mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env);
    Fun.protect ~finally:(fun () ->
      Process_eio.reset_for_testing (); Fs_compat.clear_fs (); Config_dir_resolver.reset ()) (fun () ->
    Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
      Config_dir_resolver.reset ();
      Addon_runtime.For_testing.reset ();
      Prompt_registry.set_markdown_dir "../config/prompts";
      Prompt_defaults.init ();
      Prompt_registry.clear_prompt_override Prompt_names.librarian;
      Prompt_registry.clear_prompt_override Prompt_names.librarian_working_contexts_rule;
      let original_policy = Runtime_typesafeai_policy.current () in
      Runtime_typesafeai_policy.publish { original_policy with absorb_gate = false };
      Fun.protect ~finally:(fun () -> Runtime_typesafeai_policy.publish original_policy) (fun () ->
      let config = Workspace.default_config base_path in
      let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
      let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
      install_keeper ~config ~name:keeper_name ~trace_id;
      Memory.ensure_epoch ~keepers_dir ~keeper_id:keeper_name |> get |> ignore;
      let package = Lane_addon_manifest.load ~path:"../addons/keeper-librarian/lane.toml"
        |> Result.map_error Lane_addon_manifest.error_to_string |> get in
      let source = Filename.concat (Addon_runtime.configuration_directory config) "librarian.toml" in
      let declaration enabled =
        Printf.sprintf "id=\"librarian\"\nenabled=%b\nrun_id=\"librarian-floor-step\"\nmanifest_path=%s\n[binding]\nsources=[]\n"
          enabled (Yojson.Safe.to_string (`String (Filename.concat package.directory "lane.toml"))) in
      io (fun () -> write source (declaration true));
      let respond = ref (fun _ -> `OK, F.openai_response (`Assoc [])) in
      let server = F.start_server ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
        (F.Reply_with (fun _ body -> !respond body)) in
      publish_routes base_path [ server.base_url ];
      Addon_runtime.register_exact_runner
        ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path)
        (Server_lane_addon_exact.runner ~base_path);
      let deliveries = ref 0 and delivery_changed = Eio.Condition.create () in
      let delivery_observed () = incr deliveries; Eio.Condition.broadcast delivery_changed in
      let transform_reply = ref (fun _ response -> response) in
      let fixture = { base_path; config; keepers_dir; store; source; declaration; server; respond;
                      transform_reply; deliveries; delivery_changed; clock = Eio.Stdenv.clock env } in
      Addon_runtime.For_testing.with_backend
        (backend env base_path delivery_observed (fun arguments response -> !transform_reply arguments response))
        (fun () ->
        let exported, ready = Eio.Promise.create () in
        let stop = Addon_runtime.subscribe_owner_events ~config ~package_id:Durable.package_id (function
          | Addon_runtime.Export_inventory_changed -> ignore (Eio.Promise.try_resolve ready ())
          | Configuration_observed | Exact_result_delivered _ -> ()) in
        Fun.protect ~finally:stop (fun () ->
          reconcile fixture;
          Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> Eio.Promise.await exported));
        (* The export event precedes publication of the stable Runtime metadata.
           Reconcile once after that actual event before dispatching original work. *)
        reconcile fixture;
        Eio.Time.with_timeout_exn fixture.clock F.fixture_wait_seconds (fun () -> f fixture);
        set_enabled fixture false)))))))))))

(* A turn of two messages, and the question the floor asks about each. *)
let turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:4
let message text = Agent_core.Types.make_message ~role:Agent_core.Types.User [ Agent_core.Types.Text text ]
let first_text = "the first message of the floor turn"
let second_text = "the second message of the floor turn"
let messages = [ message first_text; message second_text ]

let source_of index message =
  Unread.Official_turn
    { turn_ref; boundary_line = 1; message_in_turn = index; message_sha256 = Unread.message_digest message }

let input_over messages : Keeper_librarian.input =
  { turn_ref
  ; historical_task_contexts = []
  ; goal_context = Keeper_librarian.No_task
  ; keeper_id = Masc_test_deps.keeper_id_fixture keeper_name
  ; keeper_instructions = "You are the floor-step keeper."
  ; current = None
  ; messages
  ; tool_observations = []
  ; working_context = Keeper_librarian_context.empty
  ; counterpart_observations = []
  }
let sources_of messages = List.mapi source_of messages
let machine_over messages =
  let read =
    Machine.read ~keeper_name ~sources:(sources_of messages) ~unread_messages:[] ~previous_state:None
      (input_over messages) |> get in
  let plan =
    Plan.create_over ~keeper_id:(input_over messages).keeper_id ~turn_ref ~current:None
    |> Result.map_error Plan.error_to_string |> get in
  Machine.start ~transaction_id:"floor-step-owner-test" ~plan read |> get
let machine () = machine_over messages

let ask machine = match Machine.next machine |> get with
  | Machine.Ask question -> question
  | Machine.Finished _ -> fail "the machine finished where a question was expected"

let owner fixture =
  Durable.observe_owner ~base_path:fixture.base_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name |> get

let range_link owner : Step.link =
  { request_id = Durable.fresh_request_id owner; request_digest = String.make 64 'a' }

let new_step fixture ~owner ~range ~previous (question : Machine.question) =
  let step =
    Memory_runtime.prepare_durable_step ~now:(Time_compat.now ())
      ~context:{ Memory_runtime.previous_state = question.previous_state; unread_messages = question.unread_messages }
      question.input |> get in
  let destination =
    Edge.with_destination ~config:fixture.config ~reserved:(Edge.reserved ()) (fun destination -> Ok destination)
    |> get in
  Step.create ~request_id:(Step.fresh_request_id owner) ~owner ~destination ~transaction_id:"floor-step-owner-test" ~range
    ~previous ~question ~step ()
  |> get

let retain fixture step = Step_owner.retain ~store:fixture.store step |> Result.map_error Step_owner.error_to_string |> get

let resume fixture record step =
  let reserved = Edge.reserved () in
  Step_owner.resume ~store:fixture.store ~config:fixture.config ~reserved ~original:record ~step
    ~call:(Edge.call ~config:fixture.config ~reserved)
  |> Result.map_error Step_owner.error_to_string |> get

(* Run the step until the worker has delivered its result, as the consumer's
   wakes do: a pending request is resumed after the delivery, never submitted again. *)
let run_step fixture record step =
  let before = !(fixture.deliveries) in
  match resume fixture record step with
  | Step_owner.Pending (_, record) ->
    await_delivery fixture ~after:before;
    resume fixture record step
  | (Step_owner.Answered _ | Step_owner.Refused _) as outcome -> outcome

let claim_of text = `Assoc [ "claim", `String text; "category", `String "fact"; "board_post_id", `Null;
                              "board_comment_id", `Null; "supersedes", `Null; "absorbs", `List [] ]

let answer ~claim ~state = `Assoc
  [ "new_claims", `List [ claim_of claim ]; "dropped", `List []; "working_contexts", `List [];
    "working_state", `String state ]

let size_refusal = `Request_entity_too_large, {|{"error":{"message":"fixture refusal","type":"invalid_request_error"}}|}

let phase_name (record : Owner.retained) = match Progress.phase record.progress with
  | Progress.Judged _ -> "judged"
  | Rejected _ -> "rejected"
  | Captured -> "captured"
  | Admission_wait _ | Dispatch_pending _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
  | Subdividing _ | Subdivided _ -> "other"

