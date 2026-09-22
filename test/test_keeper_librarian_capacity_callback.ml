open Masc
module Runtime = Keeper_librarian_runtime
module Fixture = Exact_output_fixture
module Runs = Exact_lane_run_registry

let test_callback ?(cli_errors = []) ~base_path ~registry ~keeper_id ~first_overflow ~status ~expected () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = env#net and clock = env#clock in
  Eio_context.with_test_env ~net ~clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let start_server status =
  let posts = ref 0 in
  let socket = Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port | _ -> Alcotest.fail "missing loopback port" in
  let handler _ _ body =
    ignore (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all));
    incr posts;
    let body = match status with
      | `Request_entity_too_large -> {|{"error":{"message":"fixture body limit","type":"invalid_request_error"}}|}
      | `Too_many_requests -> {|{"error":{"message":"fixture quota","type":"rate_limit_error"}}|}
      | _ -> {|{"error":{"message":"fixture authorization","type":"authentication_error"}}|} in
    Cohttp_eio.Server.respond_string ~status ~body () in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port, posts in
  let first = if first_overflow then Some (start_server `Request_entity_too_large) else None in
  let base_url, posts = start_server status in
  let terminal : Fixture.target_fixture = {id = "capacity-terminal"; base_url} in
  let targets = match first with
    | None -> [terminal]
    | Some (base_url, _) -> [{Fixture.id = "capacity-first"; base_url}; terminal] in
  let resolver = Fixture.resolver_snapshot ~source:"capacity-callback-fixture" targets in
  (match Runtime_exact_output_registry.publish
      ~lanes:[{Runtime_schema.id = "librarian_exact";
        slot_ids = List.map (fun (target : Fixture.target_fixture) -> target.id) targets;
        cli_slot_ids = List.map fst cli_errors}] resolver with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Runtime_exact_output_registry.publication_error_to_string error));
  let input : Keeper_librarian.input =
    {turn_ref = Ids.Turn_ref.make ~trace_id:keeper_id ~absolute_turn:1;
     goal_context = Keeper_librarian.No_task; keeper_instructions = "Preserve evidence.";
     current = None; working_context = Keeper_librarian_context.empty;
     messages = [Agent_core.Types.user_msg "Pending conversation evidence."];
     tool_observations = []; counterpart_observations = []} in
  let cli_calls = ref [] in
  let cli_runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    cli_calls := !cli_calls @ [runtime_id];
    Error (List.assoc runtime_id cli_errors) in
  let refused = ref 0 and committed = ref false in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Runtime.run_best_effort ~cli_runner
    ~on_capacity_refused:(fun _ -> incr refused)
    ~on_memory_committed:(fun () -> committed := true)
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:None input;
  Alcotest.(check int) "only final capacity failure requests narrowing" expected !refused;
  Alcotest.(check (list string)) "CLI candidates ran in order"
    (List.map fst cli_errors) !cli_calls;
  Alcotest.(check int) "terminal provider really received the request" 1 !posts;
  Option.iter (fun (_, count) -> Alcotest.(check int)
    "body-refused first provider really ran" 1 !count) first;
  Alcotest.(check bool) "refused request never commits Memory" false !committed;
  let runs = Runs.list_runs registry |> List.filter
    (fun (run : Runs.run) -> String.equal run.actor keeper_id) in
  match runs with
  | [run] -> Alcotest.(check string) "terminal failure remains observable" "failed"
      (Runs.status_label run.status)
  | _ -> Alcotest.fail "expected one recorded Librarian run"

let test_prefit_real_continuity ~base_path () =
  let module P = Keeper_librarian_continuity in
  let module B = Keeper_turn_boundaries in
  let module C = Keeper_checkpoint_store in
  let module Current = Keeper_memory_os_current in
  let module Context = Keeper_librarian_context in
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let some = function Some value -> value | None -> Alcotest.fail "missing continuity source" in
  Fixture.with_official_client_runtimes @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs env#fs;
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  let keeper_id = "prefit-real-continuity" and trace_id = "prefit-source" in
  let config = Workspace.default_config base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let queued_source : Context.source =
    {reference="pending-chat"; content=`String "Unrelated pending question."} in
  let pocket : Context.pocket =
    {id="pending-pocket"; merge_contexts=[]; sources=[queued_source.reference];
     context="An unresolved question still needs an answer.";
     next_steps=["Answer the original question."]; completeness=Context.Current} in
  let previous_context = Context.commit ~keepers_dir ~keeper_id
      ~expected_version:None ~execution_basis:"pending-execution"
      ~sources:[queued_source] [pocket] |> get in
  let context_path = Context.path ~keepers_dir ~keeper_id in
  let context_before = Fs_compat.load_file_opt context_path |> some in
  let working_context : Context.input =
    {sources=[queued_source]; previous=Some previous_context; unavailable=[];
     execution_basis=Some "pending-execution"} in
  let source = List.init 4 (fun index -> Agent_core.Types.user_msg
    (string_of_int index ^ String.make 2000 'a')) in
  let pending =
    [Agent_core.Types.user_msg "Do not publish before explicit approval.";
     Agent_core.Types.make_message ~role:Agent_core.Types.Assistant
       [Agent_core.Types.ToolUse {id="pending-read";name="read_file";input=`Assoc []}];
     { (Agent_core.Types.make_message ~role:Agent_core.Types.Tool
       [Agent_core.Types.ToolResult {tool_use_id="pending-read";content="Unpublished patch";
         outcome=Agent_core.Types.Tool_succeeded;json=None;content_blocks=None}])
       with tool_call_id=Some "pending-read" }] in
  let canonical = source @ pending in
  let checkpoint : Agent_core.Checkpoint.t =
    {version=Agent_core.Checkpoint.checkpoint_version; session_id=trace_id;
     agent_name=keeper_id; model="fixture"; system_prompt=None; messages=canonical;
     usage=Agent_core.Types.empty_usage; turn_count=4; created_at=1000.;
     tools=[];tool_choice=None;disable_parallel_tool_use=false;temperature=None;
     top_p=None;top_k=None;min_p=None;reasoning_effort=None;enable_thinking=None;
     preserve_thinking=None;response_format=Agent_core.Types.Off;cache_system_prompt=false;
     context=Agent_core.Context.create_sync ();mcp_sessions=[];working_context=None} in
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
  (match C.save_agent_core_classified ~session_dir ~history_retained:0 checkpoint with
   | Ok (C.Saved _) -> () | Ok (C.Stale_noop _) -> Alcotest.fail "stale fixture"
   | Error detail -> Alcotest.fail detail);
  B.append ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id
    {B.recorded_at=1000.; event=B.Turn_ended {
      turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
      history_at_start=B.Fresh_history; position=B.position_of_messages source |> get}}
    |> Result.map_error B.append_error_to_string |> get;
  let resolver = Fixture.resolver_snapshot ~source:"prefit-cli-only" [] in
  ignore (Fixture.publish_registry ~lane_id:"librarian_exact" ~slot_ids:[]
    ~cli_slot_ids:[Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime] resolver);
  let prepare () = P.prepare ~config ~keeper_name:keeper_id ~trace_id () |> get |> some in
  let input prepared : Keeper_librarian.input =
    let current = Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> get in
    {turn_ref=P.turn_ref prepared; goal_context=Keeper_librarian.No_task;
     keeper_instructions="Preserve evidence.";
     current=Option.map (fun (s : Current.t) -> {Keeper_librarian.facts=s.facts}) current;
     working_context; messages=P.messages prepared;
     tool_observations=[];counterpart_observations=[]} in
  (* Independently measure the exact prompt contract to derive the fixture's
     server limit, including template, current facts, continuity and schema. *)
  let rendered prepared input =
    let input = {input with Keeper_librarian.working_context=Context.empty} in
    let variables = ("continuity", Yojson.Safe.to_string (P.prompt_json prepared))
      :: List.remove_assoc "continuity" (Keeper_librarian.prompt_variables input) in
    let _, prompt = Prompt_registry.resolve_and_render_prompt_template
      Prompt_names.librarian variables |> get in
    let requirement = Agent_core.Exact_output.make_output_requirement
      ~schema:Keeper_structured_output_schema.librarian_continuity_output_schema
      ~minimum_guarantee:Agent_core.Exact_output.Json_syntax in
    Keeper_lane_cli_oneshot.prompt_with_schema ~requirement ~prompt in
  let chars text = Runtime_codex_app_server.prompt_char_count text |> get in
  let full = prepare () in
  let half = P.narrow full |> some in
  let max_chars = chars (rendered half (input half)) in
  let capacity : Keeper_lane_cli_oneshot.input_capacity =
    {runtime_id=Fixture.cli_primary_runtime;
     capacity={actual_chars=chars (rendered full (input full));max_chars}} in
  let missing_state = `Assoc ["new_claims", `List []; "dropped", `List [];
    "working_contexts", `List []] in
  let null_state = match missing_state with
    | `Assoc fields -> `Assoc (("working_state", `Null) :: fields)
    | _ -> Alcotest.fail "expected fixture object" in
  let check_working_state_schema ~continuity output_schema =
    let open Yojson.Safe.Util in
    let state = output_schema |> member "properties" |> member "working_state" in
    let expected = if continuity then `String "string"
      else `List [`String "string"; `String "null"] in
    Alcotest.(check string) "CLI schema matches this pass's working-state obligation"
      (Yojson.Safe.to_string expected) (Yojson.Safe.to_string (member "type" state));
    if continuity then Alcotest.(check int) "continuity requires nonempty text" 1
      (state |> member "minLength" |> to_int) in
  let invalid_calls = ref [] in
  let invalid_runner ~runtime_id ~system_prompt:_ ~output_schema ~prompt:_ =
    check_working_state_schema ~continuity:true output_schema;
    invalid_calls := !invalid_calls @ [runtime_id];
    Ok (Yojson.Safe.to_string
      (if runtime_id = Fixture.cli_primary_runtime then null_state else missing_state)) in
  let invalid_committed = ref false in
  Runtime.run_best_effort ~continuity:half
    ~durable_range_id:(P.memory_range_id ~config ~keeper_name:keeper_id half |> get)
    ~cli_runner:invalid_runner ~on_memory_committed:(fun () -> invalid_committed := true)
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:None (input half);
  Alcotest.(check (list string)) "missing working states advance through declared slots once"
    [Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime] !invalid_calls;
  Alcotest.(check bool) "missing working state never publishes Memory" false !invalid_committed;
  Alcotest.(check bool) "missing working state leaves no Memory snapshot" true
    (Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> get |> Option.is_none);
  Alcotest.(check bool) "missing working state leaves no range receipt" false
    (P.memory_committed ~config ~keeper_name:keeper_id half |> get);
  Alcotest.(check bool) "missing working state leaves no continuity frontier" true
    (P.read ~config ~keeper_name:keeper_id |> get |> Option.is_none);
  let ordinary_runner ~runtime_id:_ ~system_prompt:_ ~output_schema ~prompt:_ =
    check_working_state_schema ~continuity:false output_schema;
    Ok (Yojson.Safe.to_string null_state) in
  (match Runtime.For_testing.execute_exact_output_classified ~continuity:None
     ~cli_runner:ordinary_runner ~clock:env#clock ~net:env#net ~base_path ~keeper_id
     ~selected_input:{(input half) with working_context=Context.empty} ~messages:[Agent_core.Types.user_msg "ordinary Memory"] () with
   | Ok ((selection, _), _) ->
     Alcotest.(check bool) "ordinary Memory still accepts null working state" true
       (Option.is_none selection.Keeper_librarian.working_state)
   | Error error -> Alcotest.fail (Runtime.For_testing.classified_error_detail error));
  let api_answer = `Assoc ["new_claims", `List []; "dropped", `List [];
    "working_contexts", `List []; "working_state", `String "API saved state."] in
  let api_server output = Fixture.start_server ~sw ~net:env#net ~clock:env#clock
    (Fixture.Reply (Fixture.openai_response output)) in
  let invalid_api = api_server null_state and valid_api = api_server api_answer in
  ignore (Fixture.publish_registry ~lane_id:"librarian_exact"
    ~slot_ids:["missing-state"; "valid-state"]
    (Fixture.resolver_snapshot ~source:"continuity-api-validation"
      [{Fixture.id="missing-state";base_url=invalid_api.base_url};
       {Fixture.id="valid-state";base_url=valid_api.base_url}]));
  (match Runtime.For_testing.execute_exact_output_classified ~continuity:(Some half)
     ~clock:env#clock ~net:env#net ~base_path ~keeper_id ~selected_input:{(input half) with working_context=Context.empty}
     ~messages:[Agent_core.Types.user_msg "synthesize completed source"] () with
   | Ok ((selection, _), slot) ->
     Alcotest.(check string) "API validation advances to declared successor" "valid-state" slot;
     Alcotest.(check (option string)) "API successor supplies working state"
       (Some "API saved state.") selection.Keeper_librarian.working_state
   | Error error -> Alcotest.fail (Runtime.For_testing.classified_error_detail error));
  Alcotest.(check int) "null-state API candidate ran exactly once" 1 (Fixture.post_count invalid_api);
  Alcotest.(check int) "valid API successor ran exactly once" 1 (Fixture.post_count valid_api);
  ignore (Fixture.publish_registry ~lane_id:"librarian_exact" ~slot_ids:[]
    ~cli_slot_ids:[Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime] resolver);
  let calls = ref [] in
  let execute prepared state =
    let input = input prepared in
    let expected = rendered prepared input in
    let runner ~runtime_id ~system_prompt:_ ~output_schema ~prompt =
      check_working_state_schema ~continuity:true output_schema;
      calls := prompt :: !calls;
      Alcotest.(check string) "prefit and dispatch use identical full text" expected prompt;
      Alcotest.(check bool) "no oversized CLI probe after learning the bound" true
        (chars prompt <= max_chars);
      if List.length !calls = 1 then (
        Alcotest.(check string) "null response belongs to first declared candidate"
          Fixture.cli_primary_runtime runtime_id;
        Ok (Yojson.Safe.to_string null_state))
      else (
      if List.length !calls = 2 then
        Alcotest.(check string) "valid successor handles the same source"
          Fixture.cli_secondary_runtime runtime_id;
      Ok (Yojson.Safe.to_string (`Assoc [
        "new_claims", `List []; "dropped", `List []; "working_contexts", `List [];
        "working_state", `String state]))) in
    let committed = ref false and memory_committed = ref false in
    let current = Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> get in
    Runtime.run_best_effort ~continuity:prepared
      ~durable_range_id:(P.memory_range_id ~config ~keeper_name:keeper_id prepared |> get)
      ~cli_runner:runner ~on_continuity_committed:(fun _ -> committed:=true)
      ~on_memory_committed:(fun () -> memory_committed:=true)
      ~base_path ~keepers_dir ~keeper_id
      ~expected_revision:(Option.map (fun (s : Current.t) -> s.revision) current) input;
    Alcotest.(check bool) "actual Memory publication completed" true !memory_committed;
    Alcotest.(check bool) "actual continuity publication completed" true !committed;
    let saved = P.read ~config ~keeper_name:keeper_id |> get |> some in
    Alcotest.(check int) "stored frontier advances to the selected atom group"
      (P.end_atom prepared) saved.end_atom;
    Alcotest.(check bool) "stored Memory receipt covers the selected atom group" true
      (P.memory_committed ~config ~keeper_name:keeper_id prepared |> get);
    Alcotest.(check string) "continuity leaves pending context bytes unchanged"
      context_before (Fs_compat.load_file_opt context_path |> some) in
  let fit prepared = Runtime.fit_continuity ~capacity ~base_path ~keeper_id
      ~input:(input prepared) prepared |> get |> some in
  let first = fit full in
  Alcotest.(check int) "measured bound selects first two whole atoms" 2 (P.end_atom first);
  execute first ("Saved state " ^ String.make 200 's');
  let fact = Keeper_memory_os_types.observed ~claim:("New fact " ^ String.make 200 'f')
    ~category:Keeper_memory_os_types.Fact ~now:1001.
    ~origin:{kind=Keeper_memory_os_types.Authored;trace_id} in
  ignore (Current.apply_disposition ~keepers_dir ~keeper_id ~now:1001.
    ~source:{kind=Current.Librarian;trace_id} ~absorbed:[] ~new_claims:[fact] () |> get);
  let next = prepare () in
  Alcotest.(check bool) "new state and Memory overhead make former atom count exceed limit"
    true (chars (rendered next (input next)) > max_chars);
  let second = fit next in
  Alcotest.(check int) "second pass accounts for growing overhead" 3 (P.end_atom second);
  execute second "State through the third atom.";
  let last = fit (prepare ()) in
  Alcotest.(check int) "final selected group reaches the completed boundary" 4 (P.end_atom last);
  execute last "Completed history is saved; publication still requires explicit approval.";
  Alcotest.(check int) "three fitted groups plus one rejected candidate were dispatched" 4 (List.length !calls);
  Alcotest.(check bool) "no completed work remains; unfinished work is not selected" true
    (P.prepare ~config ~keeper_name:keeper_id ~trace_id () |> get |> Option.is_none);
  let snapshot = P.read ~config ~keeper_name:keeper_id |> get |> some in
  let lines = B.read ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id |> get in
  let module Driver = Keeper_turn_driver_try_provider in
  let continuity = Driver.prepare_continuity ~trace_id ~lines ~messages:canonical snapshot
    |> Result.map_error Librarian_continuity_snapshot.error_to_string |> get in
  let provider_config = Agent_core.Llm_provider.Provider_config.make
    ~kind:Agent_core.Llm_provider.Provider_config.OpenAI_compat
    ~model_id:"continuity-cycle-fixture" ~base_url:"https://provider.example" () in
  let completed_end =
    Driver.completed_history_end ~trace_id ~lines ~messages:canonical
    |> Result.map_error Librarian_continuity_snapshot.error_to_string |> get in
  let view = Driver.For_testing.request_view
    ~input_policy:Keeper_input_policy.Small ~continuity ~provider_config
    ~measure_message_bytes:(fun message -> String.length
      (Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json message)))
    ~front:None ~history_digest_at:(Runtime_model_input_tail_window.atom_opening_digest canonical)
    ~last_resort:false ~base_path
    ~demote_before:completed_end ~turn_boundary:(Masc.Keeper_carried_front.Turn_boundary { end_atom = completed_end })
    ~materialize:(fun ~pending:_ _ -> Alcotest.fail "unfinished work was demoted") canonical in
  let wire = view.wire
    |> Result.map_error Agent_core.Llm_provider.Reasoning_history_projection.error_to_string |> get in
  let summaries, suffix = List.partition (fun (message : Agent_core.Types.message) ->
    message.metadata = Agent_core.Types.Extra_system_context_provenance.metadata) wire in
  Alcotest.(check int) "next request contains exactly one saved working state" 1 (List.length summaries);
  Alcotest.(check bool) "next request preserves unfinished user and tool exchange exactly" true
    (List.equal Agent_core.Types.Message_value.equal pending suffix);
  let after = match C.load_agent_core_exact_snapshot ~session_dir ~session_id:trace_id with
    | Ok value -> C.exact_snapshot_messages value
    | Error _ -> Alcotest.fail "source checkpoint disappeared" in
  Alcotest.(check bool) "source checkpoint is unchanged" true
    (List.equal Agent_core.Types.Message_value.equal canonical after)

let () =
  let base_path = Filename.temp_dir "librarian-capacity-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let registry = Runs.create ~path:(Filename.concat base_path Runs.storage_filename) () in
  (match Runs.install_global registry with
   | Ok () -> () | Error Runs.Already_installed -> Alcotest.fail "registry already installed");
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Prompt_defaults.init ();
  let case name first_overflow status expected =
    Alcotest.test_case name `Quick
      (test_callback ~base_path ~registry ~keeper_id:name ~first_overflow ~status ~expected) in
  let codex_error data = Fusion_official_client.Codex_failure
    (Runtime_codex_app_server.Rpc_error
      { method_ = "turn/start"; code = Some (-32602);
        message = "Input exceeds the maximum length of 1048576 characters.";
        data }) in
  let capacity = codex_error (Some (`Assoc [
    "input_error_code", `String "input_too_large";
    "actual_chars", `Int 23; "max_chars", `Int 17])) in
  let generic = codex_error None in
  let quota = Fusion_official_client.Setup_failure (Provider_error "quota") in
  let cli_case name cli_errors expected = Alcotest.test_case name `Quick (fun () ->
    Fixture.with_official_client_runtimes @@ fun () ->
    test_callback ~cli_errors ~base_path ~registry ~keeper_id:name
      ~first_overflow:false ~status:`Too_many_requests ~expected ()) in
  Alcotest.run "Librarian capacity callbacks"
    ["continuity prefit", [Alcotest.test_case "atom groups commit and produce the next request" `Quick
       (test_prefit_real_continuity ~base_path)];
     "actual HTTP outcomes", [
      case "capacity-final" false `Request_entity_too_large 1;
      case "quota-final" false `Too_many_requests 0;
      case "capacity-then-quota" true `Too_many_requests 0;
      case "capacity-then-auth" true `Unauthorized 0];
    "HTTP to CLI outcomes", [
      cli_case "quota-then-cli-capacity" [Fixture.cli_primary_runtime, capacity] 1;
      cli_case "quota-then-cli-generic-rpc" [Fixture.cli_primary_runtime, generic] 0;
      cli_case "cli-capacity-then-quota"
        [Fixture.cli_primary_runtime, capacity; Fixture.cli_secondary_runtime, quota] 0;
      cli_case "cli-quota-then-capacity"
        [Fixture.cli_primary_runtime, quota; Fixture.cli_secondary_runtime, capacity] 1]]
