(** One question of the durable message floor, run through the actual configured
    Runtime, the Python worker and the common host Exact HTTP. Only container
    launch/cleanup and the provider's HTTP server are substituted. A step is
    retained before dispatch, runs at most once, and ends at its answer or its
    refusal. These tests do not claim Docker, real paid providers or visible UI. *)
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
module Failure = Keeper_exact_walk_failure
module Refusal = Keeper_librarian_input_refusal
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
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

let input : Keeper_librarian.input =
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

let machine () =
  let read =
    Machine.read ~keeper_name ~sources:(List.mapi source_of messages) ~unread_messages:[] ~previous_state:None
      input |> get in
  let plan =
    Plan.create ~keeper_id:input.keeper_id ~turn_ref ~snapshot:None |> Result.map_error Plan.error_to_string |> get in
  Machine.start ~transaction_id:"floor-step-owner-test" ~plan read |> get

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
  Step.create ~request_id:(Step.fresh_request_id owner) ~owner ~destination ~range ~previous ~question ~step ()
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

let test_a_step_runs_once_and_keeps_its_answer () = with_fixture (fun fixture ->
  fixture.respond := (fun _ -> `OK, F.openai_response (answer ~claim:"claim of the first step" ~state:"state of the first step"));
  let owner = owner fixture and range = range_link (owner fixture) in
  let question = ask (machine ()) in
  let step = new_step fixture ~owner ~range ~previous:None question in
  let record = retain fixture step in
  check string "a retained step has made no call" "captured" (phase_name record);
  check int "and the provider has seen nothing" 0 (F.post_count fixture.server);
  let answered_record = match run_step fixture record step with
    | Step_owner.Answered (proposal, record) ->
      check string "the step's working state is the provider's answer" "state of the first step" proposal.working_state;
      check bool "its new claim is the provider's" true
        (List.map (fun (fact : Keeper_memory_os_types.fact) -> fact.claim) proposal.proposal.absorption.new_claims
         = [ "claim of the first step" ]);
      record
    | Step_owner.Pending _ -> fail "the step was still pending after its worker delivered"
    | Step_owner.Refused (final, _) ->
      failf "the provider's answer was refused: %s" (Yojson.Safe.to_string (Exact.final_to_json final)) in
  check string "the answer is the judgment of a judged record" "judged" (phase_name answered_record);
  check int "the provider was called once" 1 (F.post_count fixture.server);
  (* The answer survives a restart: the record alone, with the question the
     floor asks again, restores it and no worker is asked a second time. *)
  let restored = Step.restore ~owner answered_record |> get in
  Step.matches_question question restored |> get;
  check bool "the restored step is the created one" true
    (Yojson.Safe.equal (Step.to_json restored) (Step.to_json step));
  (match resume fixture answered_record restored with
   | Step_owner.Answered (proposal, _) ->
     check string "the second resume reads the same answer" "state of the first step" proposal.working_state
   | Step_owner.Pending _ | Step_owner.Refused _ -> fail "the retained answer was not read back");
  check int "and calls no provider again" 1 (F.post_count fixture.server))

let test_a_size_refused_step_is_refused_with_its_evidence () = with_fixture (fun fixture ->
  fixture.respond := (fun _ -> size_refusal);
  let owner = owner fixture and range = range_link (owner fixture) in
  let question = ask (machine ()) in
  let step = new_step fixture ~owner ~range ~previous:None question in
  let record = retain fixture step in
  let refused_record, final = match run_step fixture record step with
    | Step_owner.Refused (final, record) -> record, final
    | Step_owner.Answered _ -> fail "a refused request was answered"
    | Step_owner.Pending _ -> fail "the step was still pending after its worker delivered" in
  check string "a refused step is a rejected record" "rejected" (phase_name refused_record);
  let calls = F.post_count fixture.server in
  check bool "the provider was asked" true (calls >= 1);
  let evidence = io (fun () -> Step.refusal_evidence ~store:fixture.store step final) |> get in
  check bool "the refusal shows the input was too large" true (Failure.shows_range_size evidence);
  check bool "and names the refusal" true (evidence.provider_input_refusals <> []);
  (match resume fixture refused_record step with
   | Step_owner.Refused (_, record) -> check string "the refusal is read back" "rejected" (phase_name record)
   | Step_owner.Answered _ | Step_owner.Pending _ -> fail "the retained refusal was not read back");
  check int "and no provider is asked again" calls (F.post_count fixture.server))

(* The floor's first message was unreadable: it becomes a hole and the floor
   asks about the second. *)
let skip machine =
  let question = ask machine in
  let reasons = [ Refusal.Request_body_refused ] in
  let hole = match question.sources with
    | [ Unread.Official_turn { turn_ref; boundary_line; message_in_turn; _ } ] ->
      Unread.for_official_turn ~turn_ref ~boundary_line ~message_in_turn ~messages ~reasons |> get
    | [] | [ Unread.Atom _ ] | _ :: _ :: _ -> fail "the fixture reads one official-turn message per question" in
  Machine.unreadable machine ~reasons ~hole |> get

let discover fixture ~owner =
  Step_owner.discover ~store:fixture.store ~owner |> Result.map_error Step_owner.error_to_string |> get

let test_a_chain_is_found_by_the_headers_of_its_steps () = with_fixture (fun fixture ->
  let owner = owner fixture and range = range_link (owner fixture) in
  check int "no step is retained yet" 0 (List.length (discover fixture ~owner));
  let machine = machine () in
  let first_question = ask machine in
  let first = new_step fixture ~owner ~range ~previous:None first_question in
  let first_record = retain fixture first in
  let second_question = ask (skip machine) in
  let previous =
    Some { Step.request_id = first_record.request_id; request_digest = first_record.request_digest } in
  let second = new_step fixture ~owner ~range ~previous second_question in
  let second_record = retain fixture second in
  let found = discover fixture ~owner in
  let header_of (record : Owner.retained) =
    match List.find_opt (fun ((found : Owner.retained), _) -> found.request_id = record.request_id) found with
    | Some (_, header) -> header
    | None -> fail "a retained step was not found" in
  check int "both steps are found" 2 (List.length found);
  let first_header = header_of first_record and second_header = header_of second_record in
  check bool "the first step is at position 0 with no previous step" true
    (first_header.position = 0 && first_header.previous = None && first_header.range = range
     && first_header.sources = first_question.sources);
  check bool "the second is at position 1 and names the first by ID and digest" true
    (second_header.position = 1 && second_header.previous = previous && second_header.range = range
     && second_header.sources = second_question.sources);
  check bool "a header carries the destination its request names" true
    (first_header.destination = Step.destination first);
  (* Retaining a step again is the same step and keeps what it has recorded. *)
  let again = retain fixture first in
  check bool "retaining the same step again finds the same record" true
    (again.request_digest = first_record.request_digest))

(* The host checks a model's answer against the step's own input before it takes
   the answer as final. This answer fits the output schema but names a memory the
   step never saw: it is invalid output, not an answer. *)
let test_the_host_does_not_take_an_answer_the_step_cannot_use () = with_fixture (fun fixture ->
  let unknown_memory = `Assoc [ "claim", `String "a claim"; "category", `String "fact"; "board_post_id", `Null;
    "board_comment_id", `Null; "supersedes", `String "m404"; "absorbs", `List [] ] in
  fixture.respond := (fun _ -> `OK, F.openai_response
    (`Assoc [ "new_claims", `List [ unknown_memory ]; "dropped", `List []; "working_contexts", `List [];
              "working_state", `String "a working state" ]));
  let owner = owner fixture and range = range_link (owner fixture) in
  let question = ask (machine ()) in
  let step = new_step fixture ~owner ~range ~previous:None question in
  let record = retain fixture step in
  match run_step fixture record step with
  | Step_owner.Refused (Exact.Call_final (Exact.Invalid_output _ as final), refused_record) ->
    check string "a refused step is a rejected record" "rejected" (phase_name refused_record);
    let evidence = io (fun () -> Step.refusal_evidence ~store:fixture.store step (Exact.Call_final final)) |> get in
    check bool "invalid output shows nothing about reading less" true
      (not (Failure.shows_range_size evidence) && evidence.provider_input_refusals = [])
  | Step_owner.Refused (final, _) ->
    failf "the refusal was not invalid output: %s" (Yojson.Safe.to_string (Exact.final_to_json final))
  | Step_owner.Answered _ -> fail "an answer that names an unknown memory was taken"
  | Step_owner.Pending _ -> fail "the step was still pending after its worker delivered")

(* The worker's word is no proof. A reply that says the request finished with
   an answer, while the host holds no terminal record of one, is not an answer. *)
let test_a_worker_reply_the_host_has_no_record_of_is_not_an_answer () = with_fixture (fun fixture ->
  let arrived, signal = Eio.Promise.create () and release, unblock = Eio.Promise.create () in
  fixture.respond := (fun _ ->
    ignore (Eio.Promise.try_resolve signal ());
    Eio.Promise.await release;
    `OK, F.openai_response (answer ~claim:"claim of the first step" ~state:"state of the first step"));
  Fun.protect ~finally:(fun () ->
    fixture.transform_reply := (fun _ response -> response);
    ignore (Eio.Promise.try_resolve unblock ())) (fun () ->
    let owner = owner fixture and range = range_link (owner fixture) in
    let step = new_step fixture ~owner ~range ~previous:None (ask (machine ())) in
    let record = retain fixture step in
    (match resume fixture record step with
     | Step_owner.Pending (_, _) -> ()
     | Step_owner.Answered _ | Step_owner.Refused _ -> fail "the provider had not answered yet");
    Eio.Promise.await arrived;
    let forged = `Assoc [ "status", `String "answered"; "slot", `String "forged-worker-slot";
                          "output", answer ~claim:"a claim the host never saw" ~state:"a forged state" ] in
    let forged_reads = ref 0 in
    fixture.transform_reply := (fun arguments response ->
      match Yojson.Safe.Util.member "kind" arguments with
      | `String "read" ->
        incr forged_reads;
        { response with Mcp_protocol.Mcp_types.structured_content = Some (`Assoc [
            "request_id", `String record.request_id; "state", `String "finished"; "result", forged ]);
          is_error = Some false }
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> response);
    (match Step_owner.resume ~store:fixture.store ~config:fixture.config ~reserved:(Edge.reserved ())
             ~original:record ~step ~call:(Edge.call ~config:fixture.config ~reserved:(Edge.reserved ())) with
     | Ok (Step_owner.Answered _) -> fail "a worker reply with no host record was taken as an answer"
     | Ok (Step_owner.Pending _ | Step_owner.Refused _) | Error _ -> ());
    check bool "the untrusted reply reached the step owner" true (!forged_reads > 0);
    let fresh = Owner.load ~store:fixture.store ~scope:record.scope ~request_id:record.request_id in
    check bool "and the step is still not judged" true
      (match fresh with
       | Ok (Some { Owner.progress; _ }) -> (match Progress.phase progress with Progress.Judged _ -> false | _ -> true)
       | Ok None | Error _ -> false)))

(* A destructive Memory epoch reset after the step was retained: the owner the
   step names is no longer the live one, so the step is not run. *)
let test_a_step_of_a_reset_memory_epoch_is_not_run () = with_fixture (fun fixture ->
  let owner = owner fixture and range = range_link (owner fixture) in
  let step = new_step fixture ~owner ~range ~previous:None (ask (machine ())) in
  let record = retain fixture step in
  let epoch_path = Memory.epoch_path ~keepers_dir:fixture.keepers_dir ~keeper_id:keeper_name in
  io (fun () -> write epoch_path {|{"schema_version":1,"epoch":"a-memory-epoch-after-a-reset"}|});
  let reserved = Edge.reserved () in
  (match Step_owner.resume ~store:fixture.store ~config:fixture.config ~reserved ~original:record ~step
           ~call:(Edge.call ~config:fixture.config ~reserved) with
   | Error (Step_owner.Rejected detail) ->
     check bool "the step is refused for its changed owner" true (contains detail "changed")
   | Error (Step_owner.Unavailable _ | Step_owner.Uncertain _) -> fail "a reset epoch is a refusal, not an outage"
   | Ok _ -> fail "a step of a reset Memory epoch was run");
  check int "no provider was asked" 0 (F.post_count fixture.server);
  let fresh = Owner.load ~store:fixture.store ~scope:record.scope ~request_id:record.request_id in
  check bool "and the step was never dispatched" true
    (match fresh with
     | Ok (Some { Owner.progress; _ }) -> (match Progress.phase progress with Progress.Captured -> true | _ -> false)
     | Ok None | Error _ -> false))

let discover_wake fixture ~event =
  Server_librarian_addon_wake.For_testing.discover ~config:fixture.config ~store:fixture.store
    ~after_inventory:(fun () -> ()) ~on_original:(fun _ -> ()) ~event

(* A step's result must wake its Keeper like a history original's does, and the
   wake restores nothing of the step's input to do it. *)
let test_the_wake_recognizes_a_step () = with_fixture (fun fixture ->
  let owner = owner fixture and range = range_link (owner fixture) in
  let step = new_step fixture ~owner ~range ~previous:None (ask (machine ())) in
  let record = retain fixture step in
  let installation_id = (Step.destination step).installation_id in
  let keepers, refusals, original_keepers =
    discover_wake fixture ~event:Addon_runtime.Configuration_observed |> get in
  check (list string) "a configuration scan finds the step's Keeper among the originals" [ keeper_name ] original_keepers;
  check bool "and wakes it" true (List.mem keeper_name keepers);
  check (list string) "without refusing the step" [] refusals;
  let hinted =
    Addon_runtime.Exact_result_delivered { installation_id; instance_id = "fixture-instance"; request_id = record.request_id } in
  let keepers, refusals, original_keepers = discover_wake fixture ~event:hinted |> get in
  check (list string) "a result hint for the step wakes its Keeper only" [ keeper_name ] keepers;
  check (list string) "as the original's Keeper" [ keeper_name ] original_keepers;
  check (list string) "with nothing refused" [] refusals;
  (match discover_wake fixture
           ~event:(Addon_runtime.Exact_result_delivered
                     { installation_id = installation_id ^ "-other"; instance_id = "fixture-instance";
                       request_id = record.request_id }) with
   | Error detail -> check bool "a hint from another installation is refused" true (contains detail "different original installation")
   | Ok _ -> fail "a result hint from another installation was accepted"))

let () =
  run "keeper_librarian_floor_step_owner"
    [ ( "step owner"
      , [ test_case "a step runs once and keeps its answer" `Slow test_a_step_runs_once_and_keeps_its_answer
        ; test_case "a size-refused step is refused with its evidence" `Slow
            test_a_size_refused_step_is_refused_with_its_evidence
        ; test_case "the host does not take an answer the step cannot use" `Slow
            test_the_host_does_not_take_an_answer_the_step_cannot_use
        ; test_case "a worker reply the host has no record of is not an answer" `Slow
            test_a_worker_reply_the_host_has_no_record_of_is_not_an_answer
        ; test_case "a step of a reset Memory epoch is not run" `Slow test_a_step_of_a_reset_memory_epoch_is_not_run
        ; test_case "a chain is found by the headers of its steps" `Slow
            test_a_chain_is_found_by_the_headers_of_its_steps
        ; test_case "the wake recognizes a step" `Slow test_the_wake_recognizes_a_step
        ] )
    ]
