open Masc
module Runtime = Keeper_librarian_runtime
module Fixture = Exact_output_fixture
module Runs = Exact_lane_run_registry

let served_slot =
  Alcotest.testable
    (fun fmt -> function
       | Runtime.Api_slot id -> Format.fprintf fmt "Api_slot %s" id
       | Runtime.Cli_slot id -> Format.fprintf fmt "Cli_slot %s" id)
    ( = )

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
     withheld=[]; execution_basis=Some "pending-execution"} in
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
    { provider_binding = None;version=Agent_core.Checkpoint.checkpoint_version; session_id=trace_id;
     agent_name=keeper_id; model="fixture"; system_prompt=None; messages=canonical;
     usage=Agent_core.Types.empty_usage; turn_count=4; created_at=1000.;
     tools=[];tool_choice=None;disable_parallel_tool_use=false;temperature=None;
     top_p=None;top_k=None;min_p=None;reasoning_effort=None;enable_thinking=None;
     preserve_thinking=None;response_format=Agent_core.Types.Off;cache_system_prompt=false;
     context=Agent_core.Context.create_sync ();pending_input = None; working_context=None} in
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
  (match C.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes ~session_dir ~history_retained:0 checkpoint with
   | Ok (C.Saved _) -> () | Ok (C.Stale_noop _) -> Alcotest.fail "stale fixture"
   | Error detail -> Alcotest.fail detail);
  B.append ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id
    {B.recorded_at=1000.; event=B.Turn_ended { task_context = Masc.Keeper_turn_task_context.No_task;
      turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
      history_at_start=B.Fresh_history; position=B.position_of_messages source |> get}}
    |> Result.map_error B.append_error_to_string |> get;
  let resolver = Fixture.resolver_snapshot ~source:"prefit-cli-only" [] in
  ignore (Fixture.publish_registry ~lane_id:"librarian_exact" ~slot_ids:[]
    ~cli_slot_ids:[Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime] resolver);
  let prepare () = P.prepare ~config ~keeper_name:keeper_id ~trace_id () |> get |> some in
  let input prepared : Keeper_librarian.input =
    let current = Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> get in
    {turn_ref=P.turn_ref prepared; historical_task_contexts = []; goal_context =Keeper_librarian.No_task;
     keeper_id=Masc_test_deps.keeper_id_fixture keeper_id;
     keeper_instructions="Preserve evidence.";
     current=Option.map (fun (s : Current.t) -> {Keeper_librarian.facts=s.facts}) current;
     working_context; messages=P.messages prepared;
     tool_observations=[];counterpart_observations=[]} in
  (* Independently measure the exact prompt contract to derive the fixture's
     server limit, including template, current facts, continuity and schema. *)
  let rendered prepared input =
    let variables =
      Keeper_librarian_runtime.librarian_prompt_variables ~source_lines:[] ~continuity:prepared input |> get in
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
  let invalid_runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema ~prompt:_ =
    check_working_state_schema ~continuity:true output_schema;
    invalid_calls := !invalid_calls @ [runtime_id];
    Ok (Yojson.Safe.to_string
      (if runtime_id = Fixture.cli_primary_runtime then null_state else missing_state)) in
  let invalid_committed = ref false in
  let invalid_size_verdict = ref None in
  Runtime.run_best_effort ~write_scope:(Runtime.Context_and_memory Keeper_memory_commit_pass.Continuity) ~continuity:half
    ~durable_range_id:(P.memory_range_id ~config ~keeper_name:keeper_id half |> get)
    ~cli_runner:invalid_runner ~on_memory_committed:(fun () -> invalid_committed := true)
    ~on_not_committed:(fun reason -> invalid_size_verdict := Some reason.Runtime.walk_shows_size)
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:None (input half);
  Alcotest.(check (list string)) "missing working states advance through declared slots once"
    [Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime] !invalid_calls;
  Alcotest.(check (option bool)) "schema failure stops partition traversal" (Some false)
    !invalid_size_verdict;
  Alcotest.(check bool) "missing working state never publishes Memory" false !invalid_committed;
  Alcotest.(check bool) "missing working state leaves no Memory snapshot" true
    (Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> get |> Option.is_none);
  Alcotest.(check bool) "missing working state leaves no range receipt" false
    (P.memory_committed ~config ~keeper_name:keeper_id half |> get);
  Alcotest.(check bool) "missing working state leaves no continuity frontier" true
    (P.read ~config ~keeper_name:keeper_id |> get |> Option.is_none);
  (* An ordinary Memory pass never reads the working state, so a blank one
     the current schema allows refuses nothing, as null never did. *)
  List.iter (fun (label, working_state) ->
    let answer = match missing_state with
      | `Assoc fields -> `Assoc (("working_state", working_state) :: fields)
      | _ -> Alcotest.fail "expected fixture object" in
    let ordinary_runner ~runtime:_ ~system_prompt:_ ~output_schema ~prompt:_ =
      check_working_state_schema ~continuity:false output_schema;
      Ok (Yojson.Safe.to_string answer) in
    match Runtime.For_testing.execute_exact_output_classified ~continuity:None
      ~cli_runner:ordinary_runner ~clock:env#clock ~net:env#net ~base_path ~keeper_id
      ~selected_input:{(input half) with working_context=Context.empty} ~messages:[Llm_provider.Types.user_msg "ordinary Memory"] () with
    | Ok (({ Runtime.continuity_answer; _ }, _), _) ->
      Alcotest.(check bool)
        ("ordinary Memory accepts a " ^ label ^ " working state and carries no continuity answer")
        true
        (match continuity_answer with
         | Runtime.Memory_only -> true
         | Runtime.Continuity _ -> false)
    | Error error -> Alcotest.fail (Runtime.For_testing.classified_error_detail error))
    [ "null", `Null; "blank", `String "" ];
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
     ~messages:[Llm_provider.Types.user_msg "synthesize completed source"] () with
   | Ok (({ Runtime.continuity_answer; _ }, _), slot) ->
     Alcotest.check served_slot "API validation advances to declared successor"
       (Runtime.Api_slot "valid-state") slot;
     Alcotest.(check (option string)) "API successor supplies working state"
       (Some "API saved state.")
       (match continuity_answer with
        | Runtime.Continuity { working_state; _ } -> Some working_state
        | Runtime.Memory_only -> None)
   | Error error -> Alcotest.fail (Runtime.For_testing.classified_error_detail error));
  Alcotest.(check int) "null-state API candidate ran exactly once" 1 (Fixture.post_count invalid_api);
  Alcotest.(check int) "valid API successor ran exactly once" 1 (Fixture.post_count valid_api);
  ignore (Fixture.publish_registry ~lane_id:"librarian_exact" ~slot_ids:[]
    ~cli_slot_ids:[Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime] resolver);
  let calls = ref [] in
  let execute prepared state =
    let input = input prepared in
    let expected = rendered prepared input in
    let answered_by = ref None in
    let runner ~runtime:{Runtime_instance.id=runtime_id;_} ~system_prompt:_ ~output_schema ~prompt =
      check_working_state_schema ~continuity:true output_schema;
      calls := prompt :: !calls;
      answered_by := Some runtime_id;
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
    let served_by = ref None in
    let current = Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> get in
    Runtime.run_best_effort ~write_scope:(Runtime.Context_and_memory Keeper_memory_commit_pass.Continuity) ~continuity:prepared
      ~durable_range_id:(P.memory_range_id ~config ~keeper_name:keeper_id prepared |> get)
      ~cli_runner:runner
      ~on_continuity_committed:(fun ~served_by:slot _ ->
        served_by := Some slot; committed:=true)
      ~on_memory_committed:(fun () -> memory_committed:=true)
      ~base_path ~keepers_dir ~keeper_id
      ~expected_revision:(Option.map (fun (s : Current.t) -> s.revision) current) input;
    Alcotest.(check bool) "actual Memory publication completed" true !memory_committed;
    Alcotest.(check bool) "actual continuity publication completed" true !committed;
    Alcotest.(check (option served_slot)) "the commit names the CLI runtime that answered"
      (Option.map (fun id -> Runtime.Cli_slot id) !answered_by) !served_by;
    let saved = P.read ~config ~keeper_name:keeper_id |> get |> some in
    Alcotest.(check int) "stored frontier advances to the selected atom group"
      (P.end_atom prepared) saved.end_atom;
    Alcotest.(check bool) "stored Memory receipt covers the selected atom group" true
      (P.memory_committed ~config ~keeper_name:keeper_id prepared |> get);
    Alcotest.(check string) "continuity leaves pending context bytes unchanged"
      context_before (Fs_compat.load_file_opt context_path |> some) in
  let fit prepared = Runtime.fit_continuity ~source_lines:[] ~capacity
      ~input_for:(fun candidate -> Ok (input candidate)) prepared |> get |> some in
  let first = fit full in
  Alcotest.(check int) "measured bound selects first two whole atoms" 2 (P.end_atom first);
  execute first ("Saved state " ^ String.make 200 's');
  let fact = Keeper_memory_os_types.observed ~claim:("New fact " ^ String.make 200 'f')
    ~category:Keeper_memory_os_types.Fact ~now:1001.
    ~origin:{kind=Keeper_memory_os_types.Authored;trace_id} in
  ignore (Current.apply_disposition ~pass:Keeper_memory_commit_pass.Durable ~revisions:[] ~keepers_dir ~keeper_id ~now:1001.
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
  let after = match C.load_agent_core_exact_snapshot ~session_dir ~session_id:trace_id with
    | Ok value -> C.exact_snapshot_messages value
    | Error _ -> Alcotest.fail "source checkpoint disappeared" in
  Alcotest.(check bool) "source checkpoint is unchanged" true
    (List.equal Agent_core.Types.Message_value.equal canonical after)

(* A continuity pass owns nothing but its snapshot. Memory has committed
   nothing for this range, so the store refuses the snapshot after the model
   answered. The run must be recorded as failed: recorded as succeeded, 728 live
   runs hid a refusal that stopped every Codex Keeper's continuity. *)
let test_continuity_only_run_fails_when_the_snapshot_is_refused ~base_path ~registry () =
  let module P = Keeper_librarian_continuity in
  let module B = Keeper_turn_boundaries in
  let module C = Keeper_checkpoint_store in
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let some = function Some value -> value | None -> Alcotest.fail "missing continuity source" in
  Fixture.with_official_client_runtimes @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs env#fs;
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  let keeper_id = "continuity-only-refused" and trace_id = "continuity-only-source" in
  let config = Workspace.default_config base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let source = List.init 4 (fun index -> Agent_core.Types.user_msg
    (string_of_int index ^ String.make 200 'a')) in
  let pending = [Agent_core.Types.user_msg "Do not publish before explicit approval."] in
  let canonical = source @ pending in
  let checkpoint : Agent_core.Checkpoint.t =
    { provider_binding = None;version=Agent_core.Checkpoint.checkpoint_version; session_id=trace_id;
     agent_name=keeper_id; model="fixture"; system_prompt=None; messages=canonical;
     usage=Agent_core.Types.empty_usage; turn_count=4; created_at=1000.;
     tools=[];tool_choice=None;disable_parallel_tool_use=false;temperature=None;
     top_p=None;top_k=None;min_p=None;reasoning_effort=None;enable_thinking=None;
     preserve_thinking=None;response_format=Agent_core.Types.Off;cache_system_prompt=false;
     context=Agent_core.Context.create_sync ();pending_input = None; working_context=None} in
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
  (match C.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes ~session_dir ~history_retained:0 checkpoint with
   | Ok (C.Saved _) -> () | Ok (C.Stale_noop _) -> Alcotest.fail "stale fixture"
   | Error detail -> Alcotest.fail detail);
  B.append ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id
    {B.recorded_at=1000.; event=B.Turn_ended { task_context = Masc.Keeper_turn_task_context.No_task;
      turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
      history_at_start=B.Fresh_history; position=B.position_of_messages source |> get}}
    |> Result.map_error B.append_error_to_string |> get;
  let resolver = Fixture.resolver_snapshot ~source:"continuity-only-cli-only" [] in
  ignore (Fixture.publish_registry ~lane_id:"librarian_exact" ~slot_ids:[]
    ~cli_slot_ids:[Fixture.cli_primary_runtime; Fixture.cli_secondary_runtime] resolver);
  let prepared = P.prepare ~config ~keeper_name:keeper_id ~trace_id () |> get |> some in
  let input : Keeper_librarian.input =
    {turn_ref=P.turn_ref prepared; historical_task_contexts = []; goal_context =Keeper_librarian.No_task;
     keeper_id=Masc_test_deps.keeper_id_fixture keeper_id;
     keeper_instructions="Preserve evidence."; current=None;
     working_context=Keeper_librarian_context.empty; messages=P.messages prepared;
     tool_observations=[];counterpart_observations=[]} in
  let runner ~runtime:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    Ok (Yojson.Safe.to_string
          (`Assoc ["working_state", `String "State the refused snapshot must not keep."])) in
  let committed = ref false and refusals = ref [] in
  Runtime.run_best_effort ~write_scope:Runtime.Context_only ~continuity:prepared
    ~cli_runner:runner
    ~on_continuity_committed:(fun ~served_by:_ _ -> committed := true)
    ~on_not_committed:(fun refused -> refusals := refused.Runtime.detail :: !refusals)
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:None input;
  let reason = "continuity state not committed: Memory has not committed this continuity source" in
  Alcotest.(check bool) "no snapshot was committed" false !committed;
  Alcotest.(check (list string)) "the caller is told once, with the store's reason" [reason] !refusals;
  Alcotest.(check bool) "no snapshot file exists" true
    (Option.is_none (P.read ~config ~keeper_name:keeper_id |> get));
  let runs = Runs.list_runs registry |> List.filter
    (fun (run : Runs.run) -> String.equal run.actor keeper_id) in
  match runs with
  | [{Runs.status = Runs.Completed {outcome = Runs.Failed {code; detail}; _}; _}] ->
    Alcotest.(check string) "the run names the failure" "continuity_not_committed" code;
    Alcotest.(check string) "and carries the reason the log line carries" reason detail
  | [run] -> Alcotest.failf "the run was recorded as %s, not failed" (Runs.status_label run.status)
  | _ -> Alcotest.fail "expected one recorded Librarian run"

let test_durable_runtime_returns_refusal_reports ~base_path () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs env#fs;
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let start status = Fixture.start_server ~sw ~net:env#net ~clock:env#clock
    (Fixture.Reply_with (fun _ _ -> status,
      {|{"error":{"message":"fixture refusal","type":"invalid_request_error"}}|})) in
  let size = start `Request_entity_too_large and quota = start `Too_many_requests in
  ignore (Fixture.publish_registry ~lane_id:"librarian_exact"
    ~slot_ids:["durable-size";"durable-quota"]
    (Fixture.resolver_snapshot ~source:"durable-refusal-report"
      [{Fixture.id="durable-size";base_url=size.base_url};
       {Fixture.id="durable-quota";base_url=quota.base_url}]));
  let keeper_id = "durable-refusal-report" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let input : Keeper_librarian.input =
    {turn_ref=Ids.Turn_ref.make ~trace_id:keeper_id ~absolute_turn:1;
     historical_task_contexts=[];goal_context=Keeper_librarian.No_task;
     keeper_id=Masc_test_deps.keeper_id_fixture keeper_id;
     keeper_instructions="Preserve evidence.";current=None;
     working_context=Keeper_librarian_context.empty;
     messages=[Agent_core.Types.user_msg "Unread conversation."];
     tool_observations=[];counterpart_observations=[]} in
  let config = Workspace.default_config base_path in
  Masc_test_deps.declare_fixture_keeper ~sandbox_image:"base" ~base_path
    ~sandbox_profile:(Some Keeper_types_profile.Docker) keeper_id;
  Keeper_types_profile.invalidate_keeper_profile_snapshots ();
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name", `String keeper_id; "trace_id", `String keeper_id])
    |> function
    | Ok value -> value | Error detail -> Alcotest.fail detail in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> () | Error detail -> Alcotest.fail detail);
  let baseline = [Agent_core.Types.user_msg "Already read baseline."] in
  let messages = baseline @ input.messages in
  let checkpoint : Agent_core.Checkpoint.t =
    { provider_binding = None;version=Agent_core.Checkpoint.checkpoint_version;session_id=keeper_id;
     agent_name=keeper_id;model="fixture";system_prompt=None;messages;
     usage=Agent_core.Types.empty_usage;turn_count=2;created_at=1000.;tools=[];
     tool_choice=None;disable_parallel_tool_use=false;temperature=None;top_p=None;
     top_k=None;min_p=None;reasoning_effort=None;enable_thinking=None;
     preserve_thinking=None;response_format=Agent_core.Types.Off;cache_system_prompt=false;
     context=Agent_core.Context.create_sync ();pending_input=None;working_context=None} in
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) keeper_id in
  (match Keeper_checkpoint_store.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes ~session_dir ~history_retained:0 checkpoint with
   | Ok (Keeper_checkpoint_store.Saved _) -> ()
   | Ok (Stale_noop _) -> Alcotest.fail "stale durable refusal fixture"
   | Error detail -> Alcotest.fail detail);
  let append turn history_at_start messages =
    let position = match Keeper_turn_boundaries.position_of_messages messages with
      | Ok position -> position | Error detail -> Alcotest.fail detail in
    match Keeper_turn_boundaries.append ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id
      {recorded_at=Float.of_int turn;event=Turn_ended {
        task_context=Keeper_turn_task_context.No_task;
        turn_ref=Ids.Turn_ref.make ~trace_id:keeper_id ~absolute_turn:turn;
        history_at_start;position}} with
    | Ok () -> () | Error error -> Alcotest.fail (Keeper_turn_boundaries.append_error_to_string error) in
  (* This fixture starts after an already-read turn. A Fresh_history boundary
     means restart and correctly dispatches from atom zero instead of merely
     establishing the first read position. *)
  append 1 Keeper_turn_boundaries.Continued_history baseline;
  append 2 Keeper_turn_boundaries.Continued_history messages;
  let consume commit = match Keeper_librarian_durable_consumer.consume_one ~config ~keeper_name:keeper_id ~commit with
    | Ok outcome -> outcome
    | Error error -> Alcotest.fail (Keeper_librarian_durable_consumer.error_to_string error) in
  (match consume (fun _ -> Alcotest.fail "baseline dispatched a provider") with
   | Keeper_librarian_durable_consumer.Baseline_advanced _ -> ()
   | Nothing_to_read | Pending _ | Memory_not_committed _ | Progress_advanced _ | Official_advanced _ ->
     Alcotest.fail "the durable refusal fixture did not establish its baseline");
  let result = ref None in
  ignore (consume (fun original ->
    let value = Keeper_librarian_durable_consumer.commit_with_runtime
      ~base_path ~keepers_dir ~keeper_id original in
    result := Some value; value));
  (match (match !result with Some value -> value | None -> Alcotest.fail "actual selector skipped commit") with
   | Keeper_librarian_durable_consumer.Memory_committed ->
     Alcotest.fail "the failed walk claimed Memory committed"
   | Memory_pending _ ->
     Alcotest.fail "the synchronous failed walk claimed an unfinished owner commit"
   | Memory_replaced _ ->
     Alcotest.fail "the synchronous failed walk claimed a declaration replacement"
   | Memory_refused reports ->
     Alcotest.(check bool) "the adapter retains classified reports" true (reports <> []);
     Alcotest.(check bool) "provider size refusal and later quota both reach the durable edge" true
       (List.exists (fun (report : Runtime.not_committed) ->
         report.provider_input_refusals = [Keeper_librarian_input_refusal.Request_body_refused]
         && report.smaller_range_meets_same_failure) reports));
  Alcotest.(check int) "body-refusing provider called once" 1 (Fixture.post_count size);
  Alcotest.(check int) "quota provider called once" 1 (Fixture.post_count quota);
  (match Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "failed walk published Memory"
   | Error detail -> Alcotest.fail detail);
  (* Exercise the actual message-floor inference producer too. Its unread
     authority is deliberately separate from recursive admission partitioning. *)
  (match Runtime.infer_memory_step ~base_path ~keepers_dir ~keeper_id
    ~previous_state:None ~unread_messages:[] input with
   | Runtime.Memory_inferred _ -> Alcotest.fail "a failed original walk became a Memory step"
   | Memory_not_inferred failure ->
     Alcotest.(check bool) "actual API-only exhaustion retains named source-refusal authority" true
       (failure.exhausted_input_refusals=Some [Keeper_librarian_input_refusal.Request_body_refused]);
     let classified=List.filter (fun (report : Runtime.not_committed) ->
       report.provider_input_refusals<>[]) failure.reports in
     Alcotest.(check bool) "actual inference retains a classified mixed walk" true (classified<>[]);
     List.iter (fun report -> match Keeper_memory_admission_worker.For_testing.judgment_of_not_committed report with
       | Keeper_memory_admission_worker.Deferred _ -> ()
       | Input_size_refused _ | Committed | Awaiting_evidence ->
         Alcotest.fail "the actual mixed quota/input walk recursively partitioned admission") classified);
  Alcotest.(check int) "the inference producer made its own original body-refused call" 2 (Fixture.post_count size);
  Alcotest.(check int) "the inference producer made its own original quota call" 2 (Fixture.post_count quota)

let () =
  let base_path = Filename.temp_dir "librarian-capacity-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let registry = Runs.create ~path:(Filename.concat base_path Runs.storage_filename) () in
  (match Runs.install_global registry with
   | Ok () -> () | Error Runs.Already_installed -> Alcotest.fail "registry already installed");
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Prompt_defaults.init ();
  Alcotest.run "Librarian capacity callbacks: continuity and durable runtime"
    ["continuity prefit", [Alcotest.test_case "atom groups commit and produce the next request" `Quick
       (test_prefit_real_continuity ~base_path);
       Alcotest.test_case "a continuity-only run whose snapshot is refused is failed" `Quick
         (test_continuity_only_run_fails_when_the_snapshot_is_refused ~base_path ~registry)];
     "actual HTTP outcomes", [
      Alcotest.test_case "durable runtime preserves refusal reports without publishing Memory" `Quick
        (test_durable_runtime_returns_refusal_reports ~base_path)]]
