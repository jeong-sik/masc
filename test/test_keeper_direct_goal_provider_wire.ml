(** A direct owner request must carry the workspace Goal without an ID hint
    from the owner. The receiver inspects actual serialized HTTP bytes after
    direct preparation, the Keeper context assembler and AGENT_CORE injection.
    This is a deterministic local peer, not an autonomous-Keeper success test. *)
open Alcotest
open Masc

module Prompt = Keeper_unified_prompt
module Direct = Keeper_direct_turn_context
module Json = Yojson.Safe.Util

type source = Current | Revised | Measurement_unavailable | Goal_unavailable | Empty

let contains ~needle text = Astring.String.is_infix ~affix:needle text
let owner_request = "Create a Task for the remaining result and inspect its evidence."
let reported_value = "1/2 independently inspected results"
let model_id = "direct-goal-wire-fixture"

let prepare config =
  Direct.prepare
    ~active_goal_summaries:(Prompt.active_goal_summaries ~config ~keeper_name:"direct-goal-wire")
    ~current_task:Keeper_world_observation_inputs.No_current_task
    ~held_task_skills:[] ~task_skill_surfaces:[]
    ~workspace_memory:Workspace_memory_ledger.Missing
    ~wiki_contents:Keeper_wiki_contents.Off ~lane_updates:(Ok (`List []))
    ~approval_authority_text:""
    ~recent_direct_conversation_text:"Earlier owner context: inspect the persisted results."
    ~worktree_text:"" ~telemetry_feedback_text:"" ~turn_instructions_text:"" ()

let install_prompts base_path =
  let prompts_dir = Filename.concat base_path "prompts" in
  Fs_compat.mkdir_p prompts_dir;
  let synced = Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts
      ~edit_layer:Managed_asset_sync.No_edit_layer ~read:Embedded_config.read
      ~files:Embedded_config.file_list ~dest_dir:prompts_dir () in
  (match synced.failed with [] -> () | _ -> fail "embedded prompt sync failed");
  Prompt_registry.set_markdown_dir prompts_dir;
  Prompt_defaults.init ()

let install_catalog ~sw =
  let previous = Llm_provider.Model_catalog.global () in
  Eio.Switch.on_release sw (fun () -> match previous with
    | Some catalog -> Llm_provider.Model_catalog.set_global catalog
    | None -> Llm_provider.Model_catalog.clear_global ());
  let source = Printf.sprintf
      "[[models]]\nid_prefix = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_native_streaming = false\n"
      model_id in
  match Llm_provider.Model_catalog.of_toml_string ~source:"direct-goal-wire" source with
  | Ok catalog -> Llm_provider.Model_catalog.set_global catalog
  | Error detail -> fail detail

let create_goal config =
  match Goal_store.upsert_goal config ~title:"Inspect both independent results"
      ~metric:"independently inspected persisted results" ~target_value:"2/2" () with
  | Ok (goal, _) -> goal
  | Error error -> fail (Goal_store.write_error_to_string error)

let observe config (goal : Goal_store.goal) =
  match Goal_measurement.record config ~goal_id:goal.id
      ~criterion_revision:goal.criterion_revision ~observed_value:reported_value
      ~evidence:"note:fixture operator inspected the persisted first result"
      ~actor:"fixture-operator" with
  | Ok observation -> observation
  | Error error -> fail (Goal_measurement.error_to_string error)

let run_case source () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  install_catalog ~sw;
  let base_path = Filename.temp_dir "direct-goal-wire-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let config = Workspace.default_config base_path in
  Fs_compat.mkdir_p (Workspace.masc_dir config);
  install_prompts base_path;
  let goal, measurement = match source with
    | Empty -> None, None
    | Current | Revised | Measurement_unavailable | Goal_unavailable ->
      let goal = create_goal config in Some goal, Some (observe config goal) in
  let original = prepare config in
  let goal = match source, goal with
    | Revised, Some goal ->
      (match Goal_store.upsert_goal config ~id:goal.id ~target_value:"3/3" () with
       | Ok (changed, _) -> Some changed
       | Error error -> fail (Goal_store.write_error_to_string error))
    | (Current | Measurement_unavailable | Goal_unavailable | Empty), _ -> goal
    | Revised, None -> fail "revision case requires a Goal" in
  (match source with
   | Measurement_unavailable -> Fs_compat.save_file (Goal_measurement.path config) "invalid JSON"
   | Goal_unavailable -> Fs_compat.save_file (Goal_store.goals_path config) "invalid JSON"
   | Current | Revised | Empty -> ());
  let prepared = prepare config in
  let dynamic = Direct.project prepared ~workspace_memory_access:None in
  (* An interleaved preparation cannot replace an already captured turn. *)
  (match measurement with
   | Some observation -> check bool "original preparation retains its own observed value" true
       (contains ~needle:observation.id (Direct.project original ~workspace_memory_access:None))
   | None -> ());
  let partition = Keeper_context_layers.unattributed Direct_turn dynamic in
  let assembled = Keeper_run_prompt.assemble_extra_system_context
      ~dynamic_context_partition:(Some partition) ~existing_extra_system_context:None
      ~blocks:[Prompt_block_id.Dynamic_context, dynamic] in
  let hooks = { Agent_core.Hooks.empty with before_turn_params = Some (function
    | Agent_core.Hooks.BeforeTurnParams {current_params; _} ->
      AdjustParams {current_params with extra_system_context = assembled.extra_system_context}
    | BeforeTurn _ | AfterTurn _ | PreToolUse _ | PostToolUse _
    | PostToolUseFailure _ | OnStop _ | OnError _ | OnToolError _ -> Continue) } in
  let received = ref [] in
  let response = Printf.sprintf
      "{\"id\":\"direct-goal-wire\",\"model\":%S,\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"fixture answer\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
      model_id in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ body ->
         received := body :: !received; `OK, response)) in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions"
      ~tool_stream:false () in
  let runtime = Runtime_agent.default_config ~name:"direct-goal-wire"
      ~provider_cfg ~system_prompt:"Respond to the owner using current workspace observations."
      ~tools:[] in
  let runtime = {runtime with hooks = Some hooks} in
  let result = match Runtime_agent.run ~sw ~net:env#net ~config:runtime owner_request with
    | Ok ({stop_reason = Runtime_agent.Completed _; _} as result) -> result
    | Ok _ -> fail "direct request did not complete"
    | Error error -> fail (Agent_core.Error.to_string error) in
  let body = match !received with
    | [body] -> Yojson.Safe.from_string body
    | _ -> fail "expected one actual provider request" in
  let messages = Json.member "messages" body |> Json.to_list in
  let content = List.map (fun message -> Json.member "content" message |> Json.to_string) messages in
  check bool "owner request supplies no Goal ID hint" false
    (match goal with Some goal -> contains ~needle:goal.id owner_request | None -> false);
  check bool "actual wire retains the owner request" true (List.mem owner_request content);
  let contexts = List.filter (contains ~needle:"[system context]") content in
  let context = match contexts with [context] -> context | _ -> fail "one fresh context carrier required" in
  (match source, goal, measurement with
   | Current, Some goal, Some observation ->
     List.iter (fun needle -> check bool "receiver sees current Goal provenance" true
       (contains ~needle context)) [goal.id; goal.criterion_revision; observation.id; reported_value;
         "note:fixture operator inspected the persisted first result"]
   | Revised, Some goal, Some observation ->
     List.iter (fun needle -> check bool "receiver sees revised current criterion" true
       (contains ~needle context)) [goal.id; goal.criterion_revision; "3/3"];
     List.iter (fun needle -> check bool "stale measurement never reaches new revision" false
       (contains ~needle context)) [observation.id; observation.criterion_revision; reported_value]
   | Measurement_unavailable, Some goal, Some observation ->
     check bool "Goal survives failed measurement source" true (contains ~needle:goal.id context);
     check bool "measurement failure remains explicit on wire" true
       (contains ~needle:"Measurement source unavailable:" context);
     check bool "failed read borrows no prior measurement" false (contains ~needle:observation.id context)
   | Goal_unavailable, Some goal, _ ->
     check bool "Goal store failure remains explicit on wire" true
       (contains ~needle:"goal_store_unavailable:" context);
     check bool "unreadable primary borrows no mirrored Goal" false (contains ~needle:goal.id context)
   | Empty, None, None -> check bool "independent work invents no Goal layer" false
       (contains ~needle:"Active Goals" context)
   | (Current | Revised | Measurement_unavailable | Goal_unavailable | Empty), _, _ ->
     fail "invalid fixture state");
  (* OpenAI-compatible requests use an ephemeral carrier; the agent's returned
     durable-checkpoint candidate must contain the owner and answer only. *)
  let checkpoint = match result.checkpoint with Some value -> value | None -> fail "checkpoint missing" in
  List.iter (fun (message : Agent_core.Types.message) ->
    List.iter (function
      | Agent_core.Types.Text text ->
        check bool "world context stays out of durable messages" false
          (contains ~needle:"[system context]" text);
        (match goal with Some goal -> check bool "Goal projection is not persisted as conversation" false
           (contains ~needle:goal.id text) | None -> ())
      | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
      | ToolResult _ | Image _ | Document _ | Audio _ -> ()) message.content) checkpoint.messages

let () = run "direct Goal context on actual provider wire"
  ["direct owner requests",[
    test_case "current criterion and measurement reach HTTP receiver" `Quick (run_case Current);
    test_case "changed criterion never receives a stale measurement" `Quick (run_case Revised);
    test_case "measurement failure is explicit and does not hide Goal" `Quick (run_case Measurement_unavailable);
    test_case "Goal primary failure never borrows recovery context" `Quick (run_case Goal_unavailable);
    test_case "independent work needs no synthetic Goal" `Quick (run_case Empty)]]
