(** Real Keeper deferred loading -> Runtime -> Candle Python MCP. Only the
    container resource launcher is substituted; no provider, payout, Docker,
    installed binary or visible UI is exercised. *)
open Alcotest
open Masc
module R = Lane_addon_runtime
module P = Lane_addon_worker_protocol
module Json = Yojson.Safe.Util
let get = function Ok value -> value | Error detail -> fail detail
let io f = Eio_unix.run_in_systhread f
let keeper = "deferred-addon-fixture"
let tool_name = "candle_appraise"
let json = testable Yojson.Safe.pp Yojson.Safe.equal
let () = Mirage_crypto_rng_unix.use_default ()
let write path text =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun output -> output_string output text)
let protocol_error = function
  | P.Invalid_contract detail | Protocol_failed detail | Invalid_observation detail -> detail
  | Host_refusal (Lane_addon_call_context.Rejected detail | Unavailable detail
      | Activity_disabled detail | Activity_unobserved detail) -> detail
  | Stopped -> "actual MCP worker stopped"
let invocation_error = function
  | P.Host_refusal refusal -> Lane_addon_call_context.Host_refusal refusal
  | (P.Invalid_contract _ | Protocol_failed _ | Invalid_observation _ | Stopped) as error ->
      Lane_addon_call_context.Transport_error (protocol_error error)

type call = { instance : string; arguments : Yojson.Safe.t; result : Mcp_protocol.Mcp_types.tool_result }
let backend env base_path calls : R.For_testing.backend = {
  start = (fun ~sw ~state_owner ~instance_id ~installation_id:_ ~package ~binding:_
      ~on_authority ~is_live_instance:_ ~on_created ->
    let owner = Option.to_result ~none:"actual package requires persistent state" state_owner |> get in
    let state = Filename.concat base_path
      ("worker-state-" ^ Lane_addon_store.digest (Lane_addon_worker_state.identity owner)) in
    Fs_compat.mkdir_p state;
    let contract = P.contract_of_package package |> Result.map_error protocol_error |> get in
    let protocol = P.create ~instance_id ~contract () in
    get (on_authority (Lane_addon_lifecycle.Container_authority {
      runtime=Lane_addon_types.Docker;engine=Lane_addon_lifecycle.Docker_engine "python-process-fixture"}));
    let client = Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env)
      ~command:"python3" ~args:[Filename.concat package.directory "server.py";"--state";state]
      ~max_response_bytes:contract.max_reply_bytes ()
      |> Result.map_error Agent_core.Error.to_string |> get in
    P.initialize protocol client |> Result.map_error protocol_error |> get;
    let connection : R.For_testing.connection = {
      browser=None;resource=Lane_addon_lifecycle.Container_resource instance_id;
      await_exit=(fun () -> Format.asprintf "%a" Eio.Process.pp_status (Agent_core.Mcp.await_exit client));
      resolved_image=Some (Lane_addon_engine.image_of_inspect Lane_addon_types.Docker
        ("sha256:" ^ String.make 64 'a') |> get);
      observe=(fun ~binding ~sources -> P.observe protocol ~binding ~sources |> Result.map_error protocol_error);
      exported_tools=(fun () -> P.exported_tools protocol);
      call_exported_tool=(fun ~companion:_ ~on_result ~on_dispatch ~authorize ~principal ~name ~arguments ->
        let result = P.call_exported_tool ~on_result ~on_dispatch ?authorize ~principal protocol ~name ~arguments
          |> Result.map_error invocation_error in
        (match result with
         | Ok result -> calls := {instance=instance_id;arguments;result} :: !calls
         | Error _ -> ());
        result);
      operator_schema=(fun () -> None);
      companion_tools=(fun () -> []);
      observation_effect=(fun _ -> Lane_addon_call_context.May_change);
      call_operator=(fun ~admit:_ ~arguments:_ -> Error Masc.Lane_addon_worker_protocol.Operator_unavailable);
      action_schema=(fun () -> P.action_schema protocol);
      act=(fun ~arguments -> P.act protocol ~arguments |> Result.map_error protocol_error);
      stop=(fun () -> P.close protocol;Ok (Lane_addon_lifecycle.Released {
        engine=Lane_addon_lifecycle.Docker_engine "python-process-fixture";container_id=Some instance_id}));
      host=Some {await_change=None;
        list_requests=(fun () -> P.host_requests protocol |> Result.map_error protocol_error);
        deliver=(fun ~arguments -> P.host_result protocol ~arguments |> Result.map_error protocol_error)}} in
    on_created connection;Ok connection);
  package_ready=(fun ~package:_ -> Ok ());
  acquire=(fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_
    ~read_browser_document:_ ~binding:_ -> Ok (`List []));
  recover_stop=(fun ~state_owner:_ ~instance_id:_ ~authority ~resource -> match authority,resource with
    | Lane_addon_lifecycle.Container_authority {engine;_},Some (Lane_addon_lifecycle.Container_resource id) ->
        Ok (Lane_addon_lifecycle.Released {engine;container_id=Some id})
    | Lane_addon_lifecycle.Container_authority {engine;_},None ->
        Ok (Lane_addon_lifecycle.Released {engine;container_id=None})
    | Lane_addon_lifecycle.Container_authority _,Some (Lane_addon_lifecycle.Native_resource _)
    | Lane_addon_lifecycle.Native_admission _,(None|Some _) ->
        Error (Lane_addon_lifecycle.Cleanup_unconfirmed "fixture owns no native admission"));
  condition_met=(fun ~runtime:_ _ -> true);
  sweep=(fun ~runtime:_ ~is_live_instance:_ -> Ok []);
}

let exports config = Keeper_lane_addon_runtime.snapshot ~config ~keeper_name:keeper
let find_export config =
  let snapshot = exports config in
  match List.filter (fun (export:R.tool_export) -> export.tool.name=tool_name) snapshot.exports with
  | [] -> None | [export] -> Some export | _::_::_ -> fail "the actual tool export is ambiguous"
let await clock predicate = Eio.Time.with_timeout_exn clock 15. (fun () ->
  let rec loop () = match predicate () with
    | Some value -> value | None -> Eio.Time.sleep clock 0.005;loop () in
  loop ())
let invocation id (tool:Agent_core.Tool.t) = Agent_core.Tool_contract.Invocation.create
  ~tool_use_id:id ~turn:0
  ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Agent_core.Tool_contract.Serial}
  ~completion:(Agent_core.Tool.completion tool)
let execute id tool input = Agent_core.Tool.execute ~invocation:(invocation id tool) tool input
let successful id tool input = match execute id tool input with
  | Ok output -> output
  | Error error -> fail error.Agent_core.Types.message
let agent_tool agent name = match Agent_core.Tool_set.find name (Agent_core.Agent.tools agent) with
  | Some tool -> tool | None -> fail ("tool not callable in the actual Agent: " ^ name)

let with_bundle ~config ~meta ~net ~export ~deny f =
  let skill_config = match Skill_source_config.parse_text "" with
    | Ok config -> config | Error _ -> fail "empty Skill configuration is invalid" in
  let snapshot = match Skill_catalog_snapshot.configured ~config:skill_config [] with
    | Ok snapshot -> snapshot | Error _ -> fail "empty frozen Skill snapshot is invalid" in
  let surface = Keeper_capability_surface.create_with_descriptors
    ~tool_descriptors:[Keeper_lane_addon_descriptor.create export]
    ~tool_deny:deny ~sandbox_profile:Keeper_types_profile.Docker ~skill_names:None
    ~global_skill_catalog:Keeper_skill_catalog.empty
    ~skill_inventory:(Keeper_skill_inventory.of_snapshot snapshot) ~task_skills:[] in
  let context = Keeper_context_runtime.create ~eio:false ~system_prompt:"Actual deferred Addon fixture" in
  let receipt_context = Keeper_context_core.agent_core_context_of_context context in
  let receipts = Keeper_tool_load_receipts.restore ~source:receipt_context ~target:receipt_context
    |> Result.map_error Keeper_tool_load_receipts.error_to_string |> get in
  let cell = ref None in
  let bundle = Keeper_tools_agent_core_bundle.make_tool_bundle_for_capability_surface
    ~config ~meta ~ctx_snapshot:context ~capability_surface:surface
    ~publication_recovery:{Keeper_publication_recovery_availability.provider=
      Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper}
    ~identity_surface:{Keeper_tools_agent_core.offered=[];agent_cell=cell;history=[];
      load_receipts=receipts;keeper_turn_id=1} () in
  Fun.protect ~finally:bundle.cleanup (fun () ->
    let agent = Agent_core.Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~config:(Agent_core.Types.default_config ~model:"fixture-model")
      ~net ~tools:bundle.agent_core_tools () in
    cell := Some agent;f bundle agent)
let load agent =
  let loader = agent_tool agent Keeper_identity_tool_search.tool_name in
  ignore (successful "load-actual-addon" loader (`Assoc ["names",`List [`String tool_name]]));
  agent_tool agent tool_name
let latest calls = match !calls with call::_ -> call | [] -> fail "no actual exported worker RPC"
let payload calls =
  let result = (latest calls).result in
  check bool "actual worker returned no MCP error" false (result.is_error=Some true);
  Option.to_result ~none:"actual worker returned no structured content" result.structured_content |> get

let test_actual_deferred_worker_lifecycle () =
  let base_path = Filename.temp_dir "keeper-deferred-addon-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path ".masc/config")) (fun () ->
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Eio_guard.enable ();Eio.Switch.on_release sw Eio_guard.disable;
    Fs_compat.set_fs (Eio.Stdenv.fs env);Masc_test_deps.init_eio_clock env;
    Fun.protect ~finally:(fun () -> Fs_compat.clear_fs ();Config_dir_resolver.reset ()) (fun () ->
    Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
    (* This separate executable has one test and registers no Exact runner.
       [For_testing.reset] clears managers, not that module-global runner.
       The real host cycle therefore records [No_exact_runner] and leaves
       the original pending request intact; it cannot fabricate a terminal. *)
    Config_dir_resolver.reset ();R.For_testing.reset ();
    ignore (Masc_test_deps.init_unified_tool_registry ());
    let config = Workspace.default_config base_path in
    io (fun () -> Masc_test_deps.declare_fixture_keeper ~sandbox_image:"base" ~base_path
      ~sandbox_profile:(Some Keeper_types_profile.Docker) keeper);
    let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper;
      "instructions",`String (keeper ^ " fixture instructions");
      "trace_id",`String "actual-deferred-addon-trace"]) |> get in
    Keeper_meta_store.replace_snapshot config meta |> get;
    (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None
      ~on_turn_slot_released:None config with
     | Ok count -> check int "loader has one real current metadata owner" 1 count
     | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
    let package = Lane_addon_manifest.load ~path:"../addons/candle-appraiser/lane.toml"
      |> Result.map_error Lane_addon_manifest.error_to_string |> get in
    let directory = R.configuration_directory config in
    let source = Filename.concat directory "actual-deferred.toml" in
    let declaration enabled = Printf.sprintf {|id = "actual-deferred"
enabled = %b
run_id = "actual-deferred"
manifest_path = %S
[binding]
sources = []
|} enabled (Filename.concat package.directory "lane.toml") in
    let reconcile () = R.reconcile_configuration ~config ~directory |> get |> ignore in
    let enabled value = io (fun () -> write source (declaration value));reconcile () in
    let calls = ref [] in
    R.For_testing.with_backend (backend env base_path calls) (fun () ->
      enabled true;
      let original = await (Eio.Stdenv.clock env) (fun () -> reconcile ();find_export config) in
      let grade = match Candle_grade.of_string "medium" with Some grade -> grade
        | None -> fail "fixture Grade is not valid" in
      let intent = Candle_appraisal_intent.make
        ~identity:{Candle_appraisal.goal_id="deferred-goal";request_id="deferred-payout";
          verification_run_id="deferred-proof"}
        ~prompt:"Judge the immutable deferred-tool fixture only."
        (Candle_appraisal.Grade {goal={title="Deferred tool fixture";metric=None;target_value=None};
          grades=[grade,"Observed execution"]}) |> get in
      let submit = Candle_appraisal_intent.submit_arguments intent in
      let read = Candle_appraisal_intent.read_arguments intent in
      with_bundle ~config ~meta ~net:(Eio.Stdenv.net env) ~export:original ~deny:[] (fun _bundle agent ->
        check bool "unrequested schema is not yet callable" false
          (Agent_core.Tool_set.mem tool_name (Agent_core.Agent.tools agent));
        let loaded = load agent in
        check bool "loader installs the exact actual worker schema" true
          (loaded.schema.input_schema=Some original.tool.input_schema);
        (match execute "keeper-cannot-submit" loaded submit with
         | Error _ -> () | Ok _ -> fail "Keeper impersonated the host-only submission authority");
        check int "actual Keeper refusal reached worker once" 1 (List.length !calls);
        check bool "actual worker refuses Keeper submission" true ((latest calls).result.is_error=Some true);
        let submitted = Machine_addon_host.call_shared ~principal:Lane_addon_call_context.Operator
          ~config ~name:tool_name ~arguments:submit |> Result.map_error (function
            | R.Unavailable detail | Outcome_unknown detail -> detail
            | Host_refusal (Lane_addon_call_context.Rejected detail | Unavailable detail
                | Activity_disabled detail | Activity_unobserved detail) -> detail) |> get in
        check bool "actual admitted host stores pending work" false (submitted.is_error=Some true);
        check int "host admission makes one actual submission RPC" 2 (List.length !calls);
        check json "actual worker receives unchanged submitted input" submit (latest calls).arguments;
        check string "actual host submit reaches original instance" original.instance_id (latest calls).instance;
        check json "actual host submit retains original pending request" (`String "pending") (Json.member "state" (payload calls));
        let read_output = successful "actual-read" loaded read in
        check int "same Agent invocation reaches actual worker once" 3 (List.length !calls);
        check json "the same Agent consumes the actual worker structured result"
          (Mcp_protocol.Mcp_types.tool_result_to_yojson (latest calls).result)
          (Yojson.Safe.from_string read_output.content);
        check json "same Agent reads the same retained request" (`String (Candle_appraisal_intent.request_id intent))
          (Json.member "request_id" (payload calls));
        let count = List.length !calls in
        enabled false;
        check bool "Off immediately withdraws live tool discovery" true (Option.is_none (find_export config));
        (match execute "old-handler-off" loaded read with
         | Error _ -> () | Ok _ -> fail "old loaded handler executed while Off");
        check int "Off refusal sends no worker RPC" count (List.length !calls);
        ignore (await (Eio.Stdenv.clock env) (fun () ->
          reconcile ();
          let inventory = R.inventory ~config in
          if List.exists (fun (item:R.inventory_instance) -> item.instance_id=original.instance_id
            && item.presence=R.Retained && item.phase=Lane_addon_types.Detached) inventory.instances
          then Some () else None));
        enabled true;
        let replacement = await (Eio.Stdenv.clock env) (fun () -> reconcile ();find_export config) in
        check bool "reattach publishes a new actual instance" true (replacement.instance_id<>original.instance_id);
        check bool "reattach publishes a distinct export authority" false
          (Lane_addon_tool_export.equal_owner original.owner replacement.owner);
        (match execute "old-handler-replacement" loaded read with
         | Error _ -> () | Ok _ -> fail "old Agent handler followed replacement");
        check int "stale export refusal does not reach the new worker" count (List.length !calls);
        with_bundle ~config ~meta ~net:(Eio.Stdenv.net env) ~export:replacement ~deny:["addon:" ^ tool_name]
          (fun denied_bundle denied_agent ->
            (* Denying this export does not remove unrelated composition
               controls, including recovery of retained work. Exercise the
               loader's exact denied name instead of assuming it has no
               other admitted tools to offer. *)
            check bool "denied export is absent from deferred discovery" false
              (List.mem tool_name denied_bundle.on_demand_tool_names);
            let loader = agent_tool denied_agent Keeper_identity_tool_search.tool_name in
            (match execute "load-denied-addon" loader
                (`Assoc ["names",`List [`String tool_name]]) with
             | Error _ -> ()
             | Ok _ -> fail "loader accepted a denied Addon export");
            check bool "denied actual export is never installed" false
              (Agent_core.Tool_set.mem tool_name (Agent_core.Agent.tools denied_agent));
            let recovery = Keeper_tool_composition_catalog.cancel_tool_name in
            ignore (successful "load-admitted-recovery-control" loader
              (`Assoc ["names",`List [`String recovery;`String tool_name]]));
            check bool "unrelated admitted recovery control remains loadable" true
              (Agent_core.Tool_set.mem recovery (Agent_core.Agent.tools denied_agent));
            check bool "mixed load cannot install the denied export" false
              (Agent_core.Tool_set.mem tool_name (Agent_core.Agent.tools denied_agent));
            check int "deny causes no actual worker RPC" count (List.length !calls));
        with_bundle ~config ~meta ~net:(Eio.Stdenv.net env) ~export:replacement ~deny:[]
          (fun _ fresh_agent ->
            let fresh = load fresh_agent in
            ignore (successful "replacement-original-read" fresh read);
            check string "new Agent dispatches only to replacement" replacement.instance_id (latest calls).instance;
            check json "replacement reopens the original pending journal" (`String "pending")
              (Json.member "state" (payload calls));
            check json "replacement retains the same original request identity"
              (`String (Candle_appraisal_intent.request_id intent)) (Json.member "request_id" (payload calls))));
      enabled false;
      ignore (await (Eio.Stdenv.clock env) (fun () -> reconcile ();
        if List.exists (fun (item:R.inventory_instance) -> item.presence=R.Live)
          (R.inventory ~config).instances then None else Some ()))))))))))

let () = run "Keeper actual deferred Addon worker"
  ["deferred-runtime",[test_case "load, call, withdraw and reconnect original Python worker" `Quick
      test_actual_deferred_worker_lifecycle]]
