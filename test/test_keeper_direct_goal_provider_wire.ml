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

let scheduled_admission_fixture_ref =
  Ids.Turn_ref.make ~trace_id:"trace-admission-fixture" ~absolute_turn:1

let contains ~needle text = Astring.String.is_infix ~affix:needle text
let owner_request = "Create a Task for the remaining result and inspect its evidence."
let reported_value = "1/2 independently inspected results"
let model_id = "direct-goal-wire-fixture"

let prepare config =
  Direct.prepare
    ~turn_ref:scheduled_admission_fixture_ref
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
      "[[models]]\nmodel_id = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n"
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
  | Ok receipt -> receipt.measurement
  | Error error -> fail (Goal_measurement.error_to_string error)

let run_case source () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  install_catalog ~sw;
  let base_path = Filename.temp_dir "direct-goal-wire-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:None);
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
  (* An interleaved preparation cannot replace an already captured turn. *)
  (match measurement with
   | Some observation -> check bool "original preparation retains its own observed value" true
       (contains ~needle:observation.id (Direct.project original ~workspace_memory_access:None))
   | None -> ());
  let partition = Direct.project_partition prepared ~workspace_memory_access:None in
  let dynamic = Keeper_context_layers.text partition in
  let base_system_prompt = "Respond to the owner using current workspace observations." in
  let assembled = Keeper_run_prompt.assemble_request_context ~base_system_prompt
      ~post_tool_round:false ~previous_assembly:None
      ~dynamic_context_partition:(Some partition) ~existing_extra_system_context:None
      ~blocks:[Prompt_block_id.Dynamic_context, dynamic] in
  let hooks = { Agent_core.Hooks.empty with before_turn_params = Some (function
    | Agent_core.Hooks.BeforeTurnParams {current_params; _} ->
      AdjustParams {current_params with extra_system_context = assembled.extra_system_context;
        system_prompt_override = Keeper_context_assembly.system_prompt_override
          ~previous:current_params.system_prompt_override assembled}
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
  let runtime = Runtime_agent.default_config ~media_store:(Agent_core.History.Memory_store.create ()) ~name:"direct-goal-wire"
      ~provider_cfg ~system_prompt:base_system_prompt
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
  let context = match List.filter (fun message -> Json.member "role" message = `String "system") messages with
    | [message] -> Json.member "content" message |> Json.to_string
    | _ -> fail "one effective leading system prompt required" in
  check bool "Goal data never appears in the extra User carrier" false
    (List.exists (fun text -> contains ~needle:"[system context]" text &&
       contains ~needle:"Active Goals" text) content);
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
   | Empty, None, None ->
     let physical = match assembled.Keeper_context_assembly.system_prompt with
       | Some issued -> issued | None -> fail "empty Goal System receipt missing" in
     check string "empty Goal issuer matches the actual receiver bytes" physical.text context;
     let goal_text = match List.filter (fun (span : Keeper_context_assembly.span) ->
         span.kind = Keeper_context_assembly.Block Prompt_block_id.Active_goals)
         physical.partition.spans with
       | [span] -> String.sub context span.offset span.bytes
       | _ -> fail "one exact Goal partition required for the empty observation" in
     check bool "receiver sees the authoritative empty Goal snapshot" true
       (contains ~needle:"### Active Goals (0)" goal_text);
     List.iter (fun needle ->
       check bool "empty Goal snapshot invents no row, criterion or read failure" false
         (contains ~needle goal_text))
       [ "\n- "; "  Success criterion (stored values;"; "goal_store_unavailable:" ]
   | (Current | Revised | Measurement_unavailable | Goal_unavailable | Empty), _, _ ->
     fail "invalid fixture state");
  (* OpenAI-compatible requests use an ephemeral carrier; the agent's returned
     durable-checkpoint candidate must contain the owner and answer only. *)
  let checkpoint = match result.checkpoint with Some value -> value | None -> fail "checkpoint missing" in
  check (option string) "Goal suffix leaves the durable base instructions unchanged"
    (Some base_system_prompt) checkpoint.system_prompt;
  List.iter (fun (message : Agent_core.Types.message) ->
    List.iter (function
      | Agent_core.Types.Text text ->
        check bool "world context stays out of durable messages" false
          (contains ~needle:"[system context]" text);
        (match goal with Some goal -> check bool "Goal projection is not persisted as conversation" false
           (contains ~needle:goal.id text) | None -> ())
      | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
      | ToolResult _ | Image _ | Document _ | Audio _ -> ()) message.content) checkpoint.messages

let test_goal_survives_read_then_task_creation () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  install_catalog ~sw;
  let base_path = Filename.temp_dir "goal-tool-loop-wire-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let config = Workspace.default_config base_path in
  (* The real bundled Task writer requires the same initialized workspace as
     a Keeper turn; creating only [.masc] leaves no state or backlog. *)
  ignore (Workspace.init config ~agent_name:(Some "goal-loop-wire"));
  install_prompts base_path;
  let goal = create_goal config in
  let measurement = observe config goal in
  let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-goal-loop-wire" ~absolute_turn:1 in
  let prepared = Direct.prepare
      ~turn_ref
      ~active_goal_summaries:(Prompt.active_goal_summaries ~config ~keeper_name:"goal-loop-wire")
      ~current_task:Keeper_world_observation_inputs.No_current_task ~held_task_skills:[]
      ~task_skill_surfaces:[] ~workspace_memory:Workspace_memory_ledger.Missing
      ~wiki_contents:Keeper_wiki_contents.Off ~lane_updates:(Ok (`List []))
      ~approval_authority_text:"INITIAL_GATE_SNAPSHOT"
      ~recent_direct_conversation_text:"INITIAL_OWNER_CONVERSATION"
      ~worktree_text:"INITIAL_WORKTREE_SNAPSHOT" ~telemetry_feedback_text:""
      ~turn_instructions_text:"INITIAL_TURN_INSTRUCTIONS" () in
  let partition = Direct.project_partition prepared ~workspace_memory_access:None in
  let dynamic = Keeper_context_layers.text partition in
  let existing_override = "EXISTING_BASE_OVERRIDE" in
  let previous = ref None in
  let hooks = { Agent_core.Hooks.empty with before_turn_params = Some (function
    | Agent_core.Hooks.BeforeTurnParams {current_params; messages; _} ->
      let post_tool_round = Keeper_run_prompt.is_later_round_of_this_turn
          ~injected_this_turn:(Option.is_some !previous) messages in
      let current_params = {current_params with system_prompt_override=Some existing_override} in
      let issued = Keeper_run_prompt.assemble_request_context
          ~base_system_prompt:(Option.get current_params.system_prompt_override) ~post_tool_round
          ~previous_assembly:!previous ~dynamic_context_partition:(Some partition)
          ~existing_extra_system_context:current_params.extra_system_context
          ~blocks:[Prompt_block_id.Dynamic_context, dynamic;
                   Prompt_block_id.Temporal_summary, "INITIAL_CLOCK"] in
      previous := Some issued;
      Keeper_prompt_capture.write ~config ~keeper:"goal-loop-wire" ~trace_id:"trace-goal-loop-wire"
        ~absolute_turn:1 ~blocks:((Prompt_block_id.Keeper_instructions, existing_override)
          :: Keeper_context_assembly.logical_blocks issued)
        ~assembled:issued.extra_system_context ~system_prompt:issued.system_prompt;
      AdjustParams {current_params with extra_system_context = issued.extra_system_context;
        system_prompt_override = Keeper_context_assembly.system_prompt_override
          ~previous:current_params.system_prompt_override issued}
    | BeforeTurn _ | AfterTurn _ | PreToolUse _ | PostToolUse _
    | PostToolUseFailure _ | OnStop _ | OnError _ | OnToolError _ -> Continue) } in
  let meta = match Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String "goal-loop-wire"; "trace_id", `String "trace-goal-loop-wire"]) with
    | Ok meta -> meta | Error detail -> fail detail in
  let bundle = Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle ~config ~meta
      ~publication_recovery:{provider=Keeper_publication_recovery_availability.non_runtime_provider;
                             keeper_name=meta.name}
      ~ctx_snapshot:(Keeper_context_runtime.create ~eio:false ~system_prompt:"") () in
  Fun.protect ~finally:bundle.cleanup @@ fun () ->
  let create_tool = match List.find_opt (fun (tool : Agent_core.Tool.t) ->
      tool.schema.name = "keeper_task_create") bundle.tools with
    | Some tool -> tool | None -> fail "actual Task creation tool is unavailable" in
  let metric_path = Filename.concat base_path "metric.json" in
  Fs_compat.save_file metric_path {|{"inspected":1,"required":2}|};
  let read_tool = Agent_core.Tool.create ~name:"Read" ~description:"Read the fixture metric"
      ~parameters:[] (fun _ -> Ok {Agent_core.Types.content=Fs_compat.load_file metric_path;
                                  content_blocks=None; _meta=None}) in
  let answer message finish = Yojson.Safe.to_string (`Assoc ["id",`String "goal-loop";
    "model",`String model_id; "choices",`List [`Assoc ["index",`Int 0;
      "message",message;"finish_reason",`String finish]];
    "usage",`Assoc ["prompt_tokens",`Int 1;"completion_tokens",`Int 1;"total_tokens",`Int 2]]) in
  let call id name args = answer (`Assoc ["role",`String "assistant";"content",`Null;
    "tool_calls",`List [`Assoc ["id",`String id;"type",`String "function";
      "function",`Assoc ["name",`String name;"arguments",`String (Yojson.Safe.to_string args)]]]]) "tool_calls" in
  let responses = [|
    call "read-metric" "Read" (`Assoc []);
    call "create-linked-task" "keeper_task_create" (`Assoc ["title",`String "Inspect the remaining result";
      "description",`String "Inspect the remaining declared Goal result and retain its persisted evidence.";
      "goal_id",`String goal.id]);
    answer (`Assoc ["role",`String "assistant";"content",`String "Task recorded."]) "stop" |] in
  let received = ref [] in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun index body ->
         received := body :: !received;
         if index < Array.length responses then `OK,responses.(index)
         else `Bad_request,"unexpected provider request")) in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture" ~model_id
      ~base_url:server.base_url ~request_path:"/v1/chat/completions" ~tool_stream:false () in
  let runtime = Runtime_agent.default_config ~media_store:(Agent_core.History.Memory_store.create ()) ~name:"goal-loop-wire" ~provider_cfg
      ~system_prompt:"Read the metric, then record the remaining work as a Task."
      ~tools:[read_tool;create_tool] in
  let result = match Runtime_agent.run ~sw ~net:env#net ~config:{runtime with hooks=Some hooks}
      owner_request with
    | Ok ({stop_reason=Runtime_agent.Completed _;_} as result) -> result
    | Ok _ -> fail "tool-loop fixture did not complete"
    | Error error -> fail (Agent_core.Error.to_string error) in
  let bodies = List.rev !received in
  check int "Read and actual Task creation traverse three provider requests" 3 (List.length bodies);
  List.iteri (fun index body ->
    let messages = Json.member "messages" (Yojson.Safe.from_string body) |> Json.to_list in
    let contexts = List.filter_map (fun message -> match Json.member "content" message with
      | `String text when contains ~needle:"[system context]" text -> Some text
      | `String _ | `Null | `List _ | `Assoc _ | `Int _ | `Intlit _ | `Float _ | `Bool _ -> None) messages in
    let context = match List.filter (fun message -> Json.member "role" message = `String "system") messages with
      | [message] -> Json.member "content" message |> Json.to_string
      | _ -> fail "one effective leading system prompt required" in
    check bool "the prior system override survives the Goal suffix" true
      (String.starts_with ~prefix:existing_override context);
    let issued = match !previous with Some issued -> issued | None -> fail "issued assembly missing" in
    let physical = match issued.system_prompt with Some value -> value | None -> fail "system receipt missing" in
    check string "physical system receipt matches receiver bytes" physical.text context;
    check int "physical system receipt covers the exact UTF8 bytes" (String.length context) physical.partition.bytes;
    List.iter (fun (span : Keeper_context_assembly.span) ->
      let bytes = String.sub context span.offset span.bytes in
      check string "every issued physical span matches received bytes" span.sha256
        Agent_core_sha256.(digest_string bytes |> to_hex)) physical.partition.spans;
    List.iter (fun needle -> check bool "every receiver request retains the exact Goal snapshot" true
      (contains ~needle context)) [goal.id;goal.criterion_revision;measurement.id;reported_value];
    check bool "Goal is not duplicated in the extra User carrier" false
      (List.exists (contains ~needle:goal.criterion_revision) contexts);
    let extra = String.concat "" contexts in
    List.iter (fun needle -> check bool "other world context stays first-request only" (index=0)
      (contains ~needle extra)) ["INITIAL_GATE_SNAPSHOT";"INITIAL_OWNER_CONVERSATION";
        "INITIAL_WORKTREE_SNAPSHOT";"INITIAL_TURN_INSTRUCTIONS";"INITIAL_CLOCK"];
    if index > 0 then check bool "tool feedback remains the newest message" true
      (Json.member "role" (List.hd (List.rev messages)) = `String "tool")) bodies;
  let checkpoint = match result.checkpoint with Some checkpoint -> checkpoint | None -> fail "checkpoint missing" in
  let task_results = List.concat_map (fun (message : Agent_core.Types.message) ->
      List.filter_map (function
        | Agent_core.Types.ToolResult {tool_use_id; content; outcome; _}
          when String.equal tool_use_id "create-linked-task" -> Some (content, outcome)
        | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
        | ToolResult _ | Image _ | Document _ | Audio _ -> None) message.content)
      checkpoint.messages in
  let task_result, task_outcome = match task_results with
    | [result] -> result
    | _ -> fail "one actual create-linked-task result required in the runtime checkpoint" in
  Printf.printf "actual keeper_task_create callback: %s\n%!" task_result;
  check bool "actual bundled Task creation reports success" false
    (Agent_core.Types.tool_result_outcome_is_error task_outcome);
  let task_payload = match Yojson.Safe.from_string task_result with
    | payload -> payload
    | exception Yojson.Json_error detail ->
      failf "Task creation returned invalid JSON: %s; actual callback: %s" detail task_result in
  check bool "Task creation payload confirms success" true (Json.member "ok" task_payload = `Bool true);
  check bool "Task creation payload confirms the explicit requested Goal" true
    (Json.member "goal_id" task_payload = `String goal.id);
  let links = match Workspace_goal_index.read_goal_task_links_authoritative_r config with
    | Ok links -> links | Error detail -> fail detail in
  check bool "real Task creation persisted its explicit Goal association" true
    (match List.assoc_opt goal.id links with Some [_] -> true | None | Some [] | Some (_::_::_) -> false);
  check (option string) "the per-request override is not written into the checkpoint"
    (Some "Read the metric, then record the remaining work as a Task.") checkpoint.system_prompt;
  let capture = match Keeper_prompt_capture.read ~config ~keeper:"goal-loop-wire" with
    | Ok capture -> capture | Error error -> fail (Keeper_prompt_capture.read_error_to_string error) in
  check int "capture contains exactly the three stable producers" 3 (List.length capture.blocks);
  List.iter (fun id -> check int ("capture attributes " ^ Prompt_block_id.to_string id ^ " exactly once") 1
      (List.length (List.filter (fun (block : Keeper_prompt_capture.block) ->
        Prompt_block_id.equal block.id id) capture.blocks)))
    [Prompt_block_id.Keeper_instructions; Active_goals; Admitted_scheduled_input];
  let admission = List.find (fun (block : Keeper_prompt_capture.block) ->
      Prompt_block_id.equal block.id Admitted_scheduled_input) capture.blocks in
  let physical = match Option.bind !previous (fun issued -> issued.Keeper_context_assembly.system_prompt) with
    | Some issued -> issued | None -> fail "captured System issuer missing" in
  (match List.filter (fun (span : Keeper_context_assembly.span) ->
      span.kind = Keeper_context_assembly.Block Admitted_scheduled_input) physical.partition.spans with
   | [span] -> check string "captured admission is the exact issued System span"
       admission.text (String.sub physical.text span.offset span.bytes)
   | _ -> fail "one exact issued admission span required");
  let captured_turn = Ids.Turn_ref.make ~trace_id:capture.trace_id ~absolute_turn:capture.absolute_turn in
  check bool "capture and direct preparation identify the same actual fixture turn" true
    (Ids.Turn_ref.equal turn_ref captured_turn);
  check bool "captured direct admission is explicitly Unknown for the actual captured turn" true
    (contains ~needle:"availability=\"unknown\"" admission.text
     && contains ~needle:(Ids.Turn_ref.to_string captured_turn) admission.text);
  check (option string) "post-tool capture has no fabricated extra carrier" None capture.assembled;
  check (option string) "capture records the physical stable system value"
    (Option.map (fun (issued : Keeper_context_assembly.system_prompt) -> issued.text)
      (Option.bind !previous (fun issued -> issued.Keeper_context_assembly.system_prompt))) capture.system_prompt;
  check bool "Goal snapshot carrier stays out of returned durable conversation" false
    (List.exists (fun (message : Agent_core.Types.message) ->
      List.exists (function Agent_core.Types.Text text -> contains ~needle:measurement.id text
        | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
        | ToolResult _ | Image _ | Document _ | Audio _ -> false) message.content) checkpoint.messages)

let test_completion_observation_survives_tool_reply approved () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  install_catalog ~sw;
  Masc_test_deps.init_unified_tool_registry ();
  let base_path = Filename.temp_dir "authority-tool-loop-wire-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  install_prompts base_path;
  let meta = match Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String "authority-wire"; "trace_id", `String "trace-authority-wire"]) with
    | Ok meta -> meta | Error detail -> fail detail in
  let authority = Masc_domain.Human_operator {operator_id="fixture-operator"} in
  let task_id = "task-authority-wire" and verification_id = "vrf-authority-wire" in
  let payload, post_id =
    if approved then
      let outcome : Keeper_event_queue.task_outcome =
        {to_task_id=task_id;to_verification_id=verification_id;to_producer=meta.name;to_authority=authority} in
      Keeper_event_queue.Task_outcome outcome, Keeper_event_queue.task_outcome_post_id outcome
    else
      let rejection : Keeper_event_queue.completion_authority_rejection =
        {car_task_id=task_id;car_verification_id=verification_id;
         car_authority=authority;car_reason="required artifact was absent"} in
      Keeper_event_queue.Completion_authority_rejected rejection,
      Keeper_event_queue.completion_authority_rejection_post_id rejection in
  let stimulus : Keeper_event_queue.stimulus =
    {post_id;urgency=Immediate;arrived_at=42.;payload} in
  let pending = Keeper_event_queue.enqueue Keeper_event_queue.empty stimulus in
  let before = Keeper_event_queue.queue_to_yojson pending in
  let event = match Keeper_world_observation.pending_board_event_of_stimulus ~base_path ~meta stimulus with
    | Ok (Some event) -> event | Ok None | Error _ -> fail "authority event was not projected" in
  let observation : Keeper_world_observation.world_observation =
    {pending_messages=[];pending_board_events=[event];idle_seconds=0;active_goals=Ok [];
     unclaimed_task_count=0;claimable_tasks=[];held_task_skills=[];failed_task_count=0;
     scheduled_automation=Keeper_world_observation.empty_scheduled_automation_observation;
     approval_authority={revision=1;state=Approval_authority_complete;pending=[]};
     backlog_revision=Some 1;running_keeper_fiber_count=0;connected_surfaces=[];
     connected_surface_failures=[];own_recent_board_posts=[];fleet_messages=[];own_recent_actions=Ok []} in
  let turn_decision = Keeper_world_observation.keeper_cycle_decision ~meta observation in
  let rendered = Prompt.build_prompt ~turn_ref:scheduled_admission_fixture_ref ~admission:Masc.Keeper_unified_prompt_event_fields.Unknown ~turn_decision
      ~current_task:Keeper_world_observation_inputs.No_current_task ~observation () in
  let previous = ref None in
  let issued_requests = ref [] in
  let hooks = {Agent_core.Hooks.empty with before_turn_params=Some (function
    | Agent_core.Hooks.BeforeTurnParams {current_params;messages;_} ->
      let issued = Keeper_run_prompt.assemble_request_context ~base_system_prompt:"BASE_AUTHORITY_WIRE"
          ~post_tool_round:(Keeper_run_prompt.is_later_round_of_this_turn
            ~injected_this_turn:(Option.is_some !previous) messages)
          ~previous_assembly:!previous ~dynamic_context_partition:(Some rendered.world_partition)
          ~existing_extra_system_context:current_params.extra_system_context
          ~blocks:[Prompt_block_id.Dynamic_context,rendered.world_state;
                   Prompt_block_id.Temporal_summary,"INITIAL_CLOCK"] in
      previous := Some issued;
      issued_requests := issued :: !issued_requests;
      AdjustParams {current_params with extra_system_context=issued.extra_system_context;
        system_prompt_override=Keeper_context_assembly.system_prompt_override
          ~previous:current_params.system_prompt_override issued}
    | BeforeTurn _ | AfterTurn _ | PreToolUse _ | PostToolUse _ | PostToolUseFailure _
    | OnStop _ | OnError _ | OnToolError _ -> Continue)} in
  let reply message finish = Yojson.Safe.to_string (`Assoc ["id",`String "authority-wire";
    "model",`String model_id;"choices",`List [`Assoc ["index",`Int 0;"message",message;
      "finish_reason",`String finish]]]) in
  let responses = [|
    reply (`Assoc ["role",`String "assistant";"content",`Null;"tool_calls",`List [`Assoc [
      "id",`String "read-after-verdict";"type",`String "function";"function",`Assoc [
        "name",`String "Read";"arguments",`String "{}"]]]]) "tool_calls";
    reply (`Assoc ["role",`String "assistant";"content",`String "Observed."]) "stop" |] in
  let received = ref [] in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun index body ->
        received := body :: !received;
        if index < Array.length responses then `OK,responses.(index)
        else `Bad_request,"unexpected provider request")) in
  let provider_cfg = Llm_provider.Provider_config.make ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" ~tool_stream:false () in
  let read_tool = Agent_core.Tool.create ~name:"Read" ~description:"Fixture artifact read"
      ~parameters:[] (fun _ -> Ok {Agent_core.Types.content="artifact read after verdict";
                                  content_blocks=None;_meta=None}) in
  let runtime = Runtime_agent.default_config ~media_store:(Agent_core.History.Memory_store.create ()) ~name:meta.name ~provider_cfg
      ~system_prompt:"BASE_AUTHORITY_WIRE" ~tools:[read_tool] in
  let result = match Runtime_agent.run ~sw ~net:env#net ~config:{runtime with hooks=Some hooks}
      "Inspect the next artifact." with
    | Ok ({stop_reason=Runtime_agent.Completed _;_} as result) -> result
    | Ok _ -> fail "authority fixture did not complete"
    | Error error -> fail (Agent_core.Error.to_string error) in
  let requests = List.rev !received and assemblies = List.rev !issued_requests in
  check int "verdict followed by a tool result reaches two real HTTP requests" 2 (List.length requests);
  List.iteri (fun index (body, issued) ->
    let messages = Json.member "messages" (Yojson.Safe.from_string body) |> Json.to_list in
    let system = match List.filter (fun message -> Json.member "role" message = `String "system") messages with
      | [message] -> Json.member "content" message |> Json.to_string
      | _ -> fail "one System carrier required" in
    List.iter (fun marker -> check bool "every request retains exact authority correlation" true
      (contains ~needle:marker system)) [task_id;verification_id;post_id;"fixture-operator";"human_operator"];
    check bool "the verdict kind is preserved" true
      (contains ~needle:(if approved then "Approved Task Outcomes" else "Completion Authority Decisions") system);
    let issued = match issued.Keeper_context_assembly.system_prompt with
      | Some issued -> issued | None -> fail "physical System receipt missing" in
    check string "physical issuer bytes match the received System carrier" issued.text system;
    check int "exactly one completion-authority source span" 1
      (List.length (List.filter (fun (span : Keeper_context_assembly.span) ->
        span.kind = Keeper_context_assembly.Block Prompt_block_id.Completion_authority) issued.partition.spans));
    if index > 0 then (
      check bool "tool feedback remains the newest message" true
        (Json.member "role" (List.hd (List.rev messages)) = `String "tool");
      check bool "clock is not rebroadcast" false (contains ~needle:"INITIAL_CLOCK" body)))
    (List.combine requests assemblies);
  check bool "projection does not acknowledge or rewrite pending events" true
    (Keeper_event_queue.queue_to_yojson pending = before);
  let checkpoint = match result.checkpoint with Some value -> value | None -> fail "checkpoint missing" in
  List.iter (fun (message : Agent_core.Types.message) -> List.iter (function
    | Agent_core.Types.Text text -> check bool "authority observation is absent from durable history" false
        (contains ~needle:verification_id text)
    | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | ToolResult _
    | Image _ | Document _ | Audio _ -> ()) message.content) checkpoint.messages

let () = run "direct Goal context on actual provider wire"
  ["direct owner requests",[
    test_case "current criterion and measurement reach HTTP receiver" `Quick (run_case Current);
    test_case "changed criterion never receives a stale measurement" `Quick (run_case Revised);
    test_case "measurement failure is explicit and does not hide Goal" `Quick (run_case Measurement_unavailable);
    test_case "Goal primary failure never borrows recovery context" `Quick (run_case Goal_unavailable);
    test_case "independent work needs no synthetic Goal" `Quick (run_case Empty);
    test_case "Goal survives Read and actual Task creation without other world replay" `Quick
      test_goal_survives_read_then_task_creation;
    test_case "Task approval survives the following tool reply" `Quick
      (test_completion_observation_survives_tool_reply true);
    test_case "Task rejection survives the following tool reply" `Quick
      (test_completion_observation_survives_tool_reply false)]]
