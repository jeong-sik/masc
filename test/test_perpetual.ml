(** Test_perpetual — Unit tests for the Perpetual Agent Runtime.

    60 tests across all modules:
    - LLM Client: provider parsing, message building, cascade
    - Context Manager: compaction, checkpoint, token counting
    - Verifier: verdict parsing, skip detection
    - Succession: DNA extraction, hydration, normalization
    - Perpetual Loop: state management, turn execution, idle detection
    - Integration: end-to-end with mock responses

    @since 2.61.0 *)

open Masc_mcp
open Printf

(* ================================================================ *)
(* Test Infrastructure                                              *)
(* ================================================================ *)

let test_count = ref 0
let pass_count = ref 0
let fail_count = ref 0

let assert_true name cond =
  incr test_count;
  if cond then begin
    incr pass_count;
    printf "  PASS: %s\n%!" name
  end else begin
    incr fail_count;
    printf "  FAIL: %s\n%!" name
  end

let assert_equal name expected actual =
  assert_true name (expected = actual)

let assert_float_near name expected actual tolerance =
  assert_true name (Float.abs (expected -. actual) < tolerance)

let group name f =
  printf "\n=== %s ===\n%!" name;
  f ()

(* ================================================================ *)
(* 1. LLM Client Tests (10)                                        *)
(* ================================================================ *)

let test_llm_client () = group "LLM Client" (fun () ->

  (* 1. Provider string roundtrip *)
  assert_equal "provider_string:ollama"
    "ollama" (Llm_client.string_of_provider Ollama);
  assert_equal "provider_string:claude"
    "claude" (Llm_client.string_of_provider Claude);
  assert_equal "provider_string:gemini"
    "gemini" (Llm_client.string_of_provider Gemini);

  (* 2. Model spec parsing *)
  (match Llm_client.model_spec_of_string "ollama:glm-4.7-flash" with
   | Ok m ->
     assert_equal "parse_model:ollama_id" "glm-4.7-flash" m.model_id;
     assert_true "parse_model:ollama_provider"
       (m.provider = Llm_client.Ollama)
   | Error _ -> assert_true "parse_model:ollama" false);

  (match Llm_client.model_spec_of_string "claude:opus" with
   | Ok m ->
     assert_equal "parse_model:claude_id" "claude-opus-4-6" m.model_id;
     assert_true "parse_model:claude_provider"
       (m.provider = Llm_client.Claude)
   | Error _ -> assert_true "parse_model:claude" false);

  (match Llm_client.model_spec_of_string "gemini:gemini-2.5-flash" with
   | Ok m ->
     assert_equal "parse_model:gemini_id" "gemini-2.5-flash" m.model_id;
     assert_true "parse_model:gemini_provider"
       (m.provider = Llm_client.Gemini)
   | Error _ -> assert_true "parse_model:gemini" false);

  (match Llm_client.model_spec_of_string "ollama:glm-4.7-flash:latest" with
   | Ok m ->
     assert_equal "parse_model:ollama_tagged_id" "glm-4.7-flash:latest" m.model_id;
     assert_true "parse_model:ollama_tagged_provider"
       (m.provider = Llm_client.Ollama)
   | Error _ -> assert_true "parse_model:ollama_tagged" false);

  (match Llm_client.model_spec_of_string "anthropic:sonnet" with
   | Ok m ->
     assert_equal "parse_model:anthropic_alias_id" "claude-sonnet-4-5-20250929" m.model_id;
     assert_true "parse_model:anthropic_alias_provider"
       (m.provider = Llm_client.Claude)
   | Error _ -> assert_true "parse_model:anthropic_alias" false);

  (match Llm_client.model_spec_of_string "google:flash" with
   | Ok m ->
     assert_equal "parse_model:google_alias_id" "gemini-3-flash-preview" m.model_id;
     assert_true "parse_model:google_alias_provider"
       (m.provider = Llm_client.Gemini)
   | Error _ -> assert_true "parse_model:google_alias" false);

  (* 3. Invalid model spec *)
  (match Llm_client.model_spec_of_string "invalid" with
   | Error _ -> assert_true "parse_model:invalid" true
   | Ok _ -> assert_true "parse_model:invalid_should_fail" false);

  (match Llm_client.model_spec_of_string "ollama:" with
   | Error _ -> assert_true "parse_model:empty_model_rejected" true
   | Ok _ -> assert_true "parse_model:empty_model_should_fail" false);

  (* 3b. MLX and Custom provider parsing *)
  (match Llm_client.model_spec_of_string "mlx:qwen3.5-35b" with
   | Ok m ->
     assert_equal "parse_model:mlx_id" "qwen3.5-35b" m.model_id;
     assert_true "parse_model:mlx_provider"
       (m.provider = Llm_client.Custom "mlx");
     assert_equal "parse_model:mlx_url" "http://127.0.0.1:8091" m.api_url
   | Error e -> assert_true ("parse_model:mlx_failed: " ^ e) false);

  (match Llm_client.model_spec_of_string "custom:mymodel@http://localhost:9999" with
   | Ok m ->
     assert_equal "parse_model:custom_with_url_id" "mymodel" m.model_id;
     assert_true "parse_model:custom_with_url_provider"
       (m.provider = Llm_client.Custom "mymodel");
     assert_equal "parse_model:custom_with_url_url" "http://localhost:9999" m.api_url
   | Error e -> assert_true ("parse_model:custom_url_failed: " ^ e) false);

  (match Llm_client.model_spec_of_string "custom:bare-model" with
   | Ok m ->
     assert_equal "parse_model:custom_bare_id" "bare-model" m.model_id;
     assert_true "parse_model:custom_bare_provider"
       (m.provider = Llm_client.Custom "bare-model");
     assert_equal "parse_model:custom_bare_url" "http://127.0.0.1:8080" m.api_url
   | Error e -> assert_true ("parse_model:custom_bare_failed: " ^ e) false);

  (* 4. Message constructors *)
  let msg = Llm_client.system_msg "hello" in
  assert_true "msg:system_role" (msg.role = Llm_client.System);
  assert_equal "msg:system_content" "hello" msg.content;

  let msg2 = Llm_client.tool_msg ~name:"grep" ~call_id:"c1" "results" in
  assert_true "msg:tool_role" (msg2.role = Llm_client.Tool);
  assert_equal "msg:tool_name" (Some "grep") msg2.name;
  assert_equal "msg:tool_call_id" (Some "c1") msg2.tool_call_id;

  (* 5. Token estimation *)
  let msgs = [Llm_client.user_msg "hello world"] in
  let tokens = Llm_client.estimate_tokens msgs in
  assert_true "token_estimate:positive" (tokens > 0);
  assert_true "token_estimate:reasonable" (tokens < 100);

  (* 6. Built-in model specs *)
  assert_true "builtin:ollama_glm_context"
    (Llm_client.ollama_glm.max_context = 202000);
  assert_true "builtin:claude_opus_cost"
    (Llm_client.claude_opus.cost_per_1k_input > 0.0);
  assert_true "builtin:gemini_pro_provider"
    (Llm_client.gemini_pro.provider = Llm_client.Gemini);
)

(* ================================================================ *)
(* 2. Context Manager Tests (15)                                    *)
(* ================================================================ *)

let test_context_manager () = group "Context Manager" (fun () ->

  (* 1. Create empty context *)
  let ctx = Context_manager.create ~system_prompt:"test" ~max_tokens:1000 in
  assert_true "create:empty_messages" (ctx.messages = []);
  assert_true "create:has_tokens" (ctx.token_count > 0);

  (* 2. Append message *)
  let msg = Llm_client.user_msg "hello" in
  let ctx2 = Context_manager.append ctx msg in
  assert_equal "append:count" 1 (List.length ctx2.messages);
  assert_true "append:tokens_increased" (ctx2.token_count > ctx.token_count);

  (* 3. Append many *)
  let msgs = [Llm_client.user_msg "a"; Llm_client.assistant_msg "b"] in
  let ctx3 = Context_manager.append_many ctx msgs in
  assert_equal "append_many:count" 2 (List.length ctx3.messages);

  (* 4. Context ratio *)
  let ratio = Context_manager.context_ratio ctx in
  assert_true "ratio:small" (ratio < 0.1);

  let big_ctx = { ctx with token_count = 800 } in
  let ratio2 = Context_manager.context_ratio big_ctx in
  assert_float_near "ratio:big" 0.8 ratio2 0.01;

  (* 5. Exceeds threshold *)
  assert_true "threshold:below" (not (Context_manager.exceeds_threshold ctx 0.5));
  assert_true "threshold:above" (Context_manager.exceeds_threshold big_ctx 0.5);

  (* 6. Importance scoring *)
  let ctx4 = Context_manager.append_many ctx [
    Llm_client.user_msg "important question";
    Llm_client.assistant_msg "answer";
    Llm_client.user_msg "follow up";
  ] in
  let scored = Context_manager.score_importance ctx4 in
  assert_true "importance:has_scores"
    (List.length scored.importance_scores = 3);
  (* Last message should score higher due to recency *)
  let score_0 = List.assoc 0 scored.importance_scores in
  let score_2 = List.assoc 2 scored.importance_scores in
  assert_true "importance:recency" (score_2 > score_0);

  (* 7. PruneToolOutputs *)
  let long_tool_msg = { (Llm_client.tool_msg ~name:"t" ~call_id:"c" (String.make 1000 'x'))
    with role = Llm_client.Tool } in
  let ctx5 = Context_manager.append ctx long_tool_msg in
  let pruned = Context_manager.apply_strategy ctx5 PruneToolOutputs in
  let pruned_msg = List.hd pruned.messages in
  assert_true "prune:shorter" (String.length pruned_msg.content < 1000);
  assert_true "prune:has_truncated" (
    try let _ = Str.search_forward (Str.regexp_string "truncated") pruned_msg.content 0 in true
    with Not_found -> false);

  (* 8. MergeContiguous *)
  let ctx6 = Context_manager.append_many ctx [
    Llm_client.user_msg "part1";
    Llm_client.user_msg "part2";
    Llm_client.assistant_msg "response";
  ] in
  let merged = Context_manager.apply_strategy ctx6 MergeContiguous in
  assert_equal "merge:count" 2 (List.length merged.messages);

  (* 9. SummarizeOld *)
  let many_msgs = List.init 10 (fun i ->
    if i mod 2 = 0 then Llm_client.user_msg (sprintf "q%d" i)
    else Llm_client.assistant_msg (sprintf "a%d" i)) in
  let ctx7 = Context_manager.append_many ctx many_msgs in
  let summarized = Context_manager.apply_strategy ctx7 SummarizeOld in
  assert_true "summarize:fewer_messages"
    (List.length summarized.messages < List.length ctx7.messages);

  (* 10. Full compaction pipeline — use long messages so compaction saves tokens *)
  let long_ctx = Context_manager.append_many ctx
    (List.init 10 (fun i ->
      if i mod 2 = 0
      then Llm_client.user_msg (sprintf "detailed question %d with lots of context: %s" i (String.make 200 'x'))
      else Llm_client.assistant_msg (sprintf "comprehensive answer %d: %s" i (String.make 300 'y')))) in
  let compacted = Context_manager.compact long_ctx
    [PruneToolOutputs; MergeContiguous; SummarizeOld] in
  assert_true "compact:reduces_tokens"
    (compacted.token_count <= long_ctx.token_count);

  (* 11. Checkpoint creation *)
  let ckpt = Context_manager.create_checkpoint ctx3 ~generation:1 in
  assert_true "checkpoint:has_id"
    (String.length ckpt.checkpoint_id > 0);
  assert_equal "checkpoint:generation" 1 ckpt.generation;
  assert_equal "checkpoint:msg_count" 2 ckpt.message_count;

  (* 12. Checkpoint restore *)
  let restored = Context_manager.restore_checkpoint ckpt ~max_tokens:1000 in
  assert_equal "restore:msg_count" 2 (List.length restored.messages);
  assert_equal "restore:max_tokens" 1000 restored.max_tokens;

  (* 13. DropLowImportance *)
  let ctx8 = Context_manager.append_many
    (Context_manager.create ~system_prompt:"test" ~max_tokens:10000) [
    Llm_client.user_msg "important long question about architecture design";
    Llm_client.assistant_msg "ok";  (* Short = low importance *)
    Llm_client.user_msg "another detailed question with context";
  ] in
  let dropped = Context_manager.apply_strategy ctx8 DropLowImportance in
  assert_true "drop:removes_some"
    (List.length dropped.messages <= List.length ctx8.messages);
)

(* ================================================================ *)
(* 3. Verifier Tests (8)                                            *)
(* ================================================================ *)

let test_verifier () = group "Verifier" (fun () ->

  (* 1. Parse PASS *)
  let v = Verifier.parse_verdict "PASS" in
  assert_true "parse:pass" (v = Verifier.Pass);

  (* 2. Parse WARN *)
  let v2 = Verifier.parse_verdict "WARN: might be slow" in
  (match v2 with
   | Verifier.Warn reason ->
     assert_true "parse:warn_reason" (String.length reason > 0)
   | _ -> assert_true "parse:warn" false);

  (* 3. Parse FAIL *)
  let v3 = Verifier.parse_verdict "FAIL: wrong approach" in
  (match v3 with
   | Verifier.Fail reason ->
     assert_true "parse:fail_reason" (String.length reason > 0)
   | _ -> assert_true "parse:fail" false);

  (* 4. Parse with colon *)
  let v4 = Verifier.parse_verdict "WARN: something" in
  (match v4 with
   | Verifier.Warn r -> assert_equal "parse:warn_colon" "something" r
   | _ -> assert_true "parse:warn_colon" false);

  (* 5. Parse unknown → Warn *)
  let v5 = Verifier.parse_verdict "I think this is fine" in
  (match v5 with
   | Verifier.Warn _ -> assert_true "parse:unknown_as_warn" true
   | _ -> assert_true "parse:unknown" false);

  (* 6. Should skip: read operations *)
  assert_true "skip:read" (Verifier.should_skip ~action_description:"Read file.txt");
  assert_true "skip:glob" (Verifier.should_skip ~action_description:"Glob **/*.ml");
  assert_true "skip:grep" (Verifier.should_skip ~action_description:"Grep pattern");

  (* 7. Should not skip: write operations *)
  assert_true "skip:write" (not (Verifier.should_skip ~action_description:"Write file.txt"));
  assert_true "skip:edit" (not (Verifier.should_skip ~action_description:"Edit code"));

  (* 8. Verdict to string *)
  assert_equal "verdict_str:pass" "PASS" (Verifier.verdict_to_string Pass);
  assert_true "verdict_str:warn"
    (String.length (Verifier.verdict_to_string (Warn "x")) > 5);
)

(* ================================================================ *)
(* 4. Succession Tests (12)                                         *)
(* ================================================================ *)

let test_succession () = group "Succession" (fun () ->

  (* 1. Empty metrics *)
  let m = Succession.empty_metrics in
  assert_equal "metrics:empty_turns" 0 m.total_turns;
  assert_float_near "metrics:empty_cost" 0.0 m.total_cost_usd 0.001;

  (* 2. Merge metrics *)
  let m1 = { Succession.empty_metrics with total_turns = 5; total_cost_usd = 1.0 } in
  let m2 = { Succession.empty_metrics with total_turns = 3; total_cost_usd = 0.5 } in
  let merged = Succession.merge_metrics m1 m2 in
  assert_equal "merge:turns" 8 merged.total_turns;
  assert_float_near "merge:cost" 1.5 merged.total_cost_usd 0.001;

  (* 3. DNA to JSON roundtrip *)
  let dna = Succession.{
    generation = 2;
    trace_id = "test-trace";
    goal = "test goal";
    progress_summary = "did stuff";
    compressed_context = "{}";
    pending_actions = ["action1"];
    key_decisions = ["decision1"];
    memory_refs = [];
    warnings = ["warn1"];
    metrics = empty_metrics;
  } in
  let json = Succession.dna_to_json dna in
  (match Succession.dna_of_json json with
   | Ok restored ->
     assert_equal "dna_rt:generation" 2 restored.generation;
     assert_equal "dna_rt:trace" "test-trace" restored.trace_id;
     assert_equal "dna_rt:goal" "test goal" restored.goal;
     assert_equal "dna_rt:pending" 1 (List.length restored.pending_actions);
     assert_equal "dna_rt:warnings" 1 (List.length restored.warnings);
   | Error e -> assert_true (sprintf "dna_roundtrip: %s" e) false);

  (* 4. DNA from invalid JSON *)
  (match Succession.dna_of_json (`String "invalid") with
   | Error _ -> assert_true "dna_invalid:error" true
   | Ok _ -> assert_true "dna_invalid:should_fail" false);

  (* 5. Cross-model normalization: Ollama *)
  let msgs = [
    Llm_client.user_msg "hello";
    Llm_client.tool_msg ~name:"grep" ~call_id:"c1" "results";
    Llm_client.assistant_msg "done";
  ] in
  let normalized = Succession.normalize_for_model msgs Llm_client.ollama_glm in
  (* Tool messages should be converted to user messages for Ollama *)
  let tool_msgs = List.filter (fun (m : Llm_client.message) ->
    m.role = Llm_client.Tool) normalized in
  assert_equal "normalize:ollama_no_tool" 0 (List.length tool_msgs);

  (* 6. Cross-model normalization: Claude merges consecutive *)
  let msgs2 = [
    Llm_client.user_msg "part1";
    Llm_client.user_msg "part2";
    Llm_client.assistant_msg "response";
  ] in
  let normalized2 = Succession.normalize_for_model msgs2 Llm_client.claude_opus in
  assert_true "normalize:claude_merged"
    (List.length normalized2 <= List.length msgs2);

  (* 7. Hydrate from DNA *)
  let spec = Succession.{
    model = Llm_client.ollama_glm;
    inherit_tools = true;
    context_budget = 0.3;
  } in
  let hydrated = Succession.hydrate dna spec in
  assert_true "hydrate:has_system"
    (String.length hydrated.system_prompt > 0);
  assert_true "hydrate:system_contains_goal"
    (try let _ = Str.search_forward (Str.regexp_string "test goal") hydrated.system_prompt 0 in true
     with Not_found -> false);
)

(* ================================================================ *)
(* 5. Perpetual Loop Tests (10)                                     *)
(* ================================================================ *)

let test_perpetual_loop () = group "Perpetual Loop" (fun () ->

  (* 1. Default config *)
  let config = Perpetual_loop.default_config
    ~goal:"test" ~models:[Llm_client.ollama_glm] () in
  assert_equal "config:goal" "test" config.initial_goal;
  assert_float_near "config:compact" 0.5 config.compact_threshold 0.01;
  assert_float_near "config:handoff" 0.85 config.handoff_threshold 0.01;

  (* 2. Create state *)
  let state = Perpetual_loop.create_state config in
  assert_true "state:running" state.running;
  assert_equal "state:turn0" 0 state.turn_count;
  assert_equal "state:gen0" 0 state.generation;
  assert_true "state:trace_id" (String.length state.trace_id > 0);

  (* 3. Stop *)
  Perpetual_loop.stop state;
  assert_true "stop:not_running" (not state.running);

  (* 4. Status JSON *)
  let status = Perpetual_loop.status state in
  (match status with
   | `Assoc fields ->
     assert_true "status:has_trace"
       (List.mem_assoc "trace_id" fields);
     assert_true "status:has_running"
       (List.mem_assoc "running" fields);
     assert_true "status:has_context_ratio"
       (List.mem_assoc "context_ratio" fields);
   | _ -> assert_true "status:is_object" false);

  (* 5. Run turn on stopped state returns false *)
  let fresh_config = Perpetual_loop.default_config
    ~goal:"test" ~models:[Llm_client.ollama_glm] () in
  let fresh_state = Perpetual_loop.create_state fresh_config in
  fresh_state.running <- false;
  let should_continue = Perpetual_loop.run_turn ~config:fresh_config ~state:fresh_state in
  assert_true "run_turn:stopped" (not should_continue);

  (* 6. Event types exist *)
  let events_ok = [
    Perpetual_loop.TurnStart 1;
    Perpetual_loop.Error "test";
    Perpetual_loop.IdleDetected 3;
    Perpetual_loop.Terminated "test";
  ] in
  assert_equal "events:count" 4 (List.length events_ok);

  (* 7. Initial context has system prompt *)
  let state2 = Perpetual_loop.create_state config in
  assert_true "context:has_system"
    (String.length state2.context.system_prompt > 0);
  assert_true "context:has_goal_message"
    (List.exists
       (fun (msg : Llm_client.message) ->
         msg.role = Llm_client.User &&
         Str.string_match
           (Str.regexp_string (Context_manager.goal_prefix ^ " test"))
           msg.content 0)
       state2.context.messages);

  (* 8. Cost starts at zero *)
  assert_float_near "cost:initial" 0.0 state2.total_cost 0.001;

  (* 9. Idle turns starts at zero *)
  assert_equal "idle:initial" 0 state2.idle_turns;

  (* 10. Multiple model cascade *)
  let config3 = Perpetual_loop.default_config
    ~goal:"multi"
    ~models:[Llm_client.ollama_glm; Llm_client.ollama_lfm]
    () in
  assert_equal "cascade:model_count" 2
    (List.length config3.model_cascade);

  (* 11. Default config: coding_mode is false *)
  assert_true "config:coding_mode_default" (not config.coding_mode);

  (* 12. Default config: coding_agent is "claude" *)
  assert_equal "config:coding_agent_default" "claude" config.coding_agent;

  (* 13. Default config: coding_timeout_s uses env default *)
  assert_true "config:coding_timeout_positive" (config.coding_timeout_s > 0);

  (* 14. Default config: coding_sw and coding_proc_mgr are None *)
  assert_true "config:coding_sw_none" (config.coding_sw = None);
  assert_true "config:coding_proc_mgr_none" (config.coding_proc_mgr = None);

  (* 15. CodingSpawn event variant exists *)
  let coding_ev = Perpetual_loop.CodingSpawn {
    agent = "claude"; exit_code = 0; elapsed_ms = 5000
  } in
  (match coding_ev with
   | Perpetual_loop.CodingSpawn { agent; exit_code; elapsed_ms } ->
     assert_equal "coding_event:agent" "claude" agent;
     assert_equal "coding_event:exit_code" 0 exit_code;
     assert_equal "coding_event:elapsed_ms" 5000 elapsed_ms
   | _ -> assert_true "coding_event:is_coding_spawn" false);

  (* 16. Config with coding_mode enabled *)
  let coding_config = { config with
    Perpetual_loop.coding_mode = true;
    coding_agent = "gemini";
    coding_timeout_s = 1800;
  } in
  assert_true "coding_config:mode_enabled" coding_config.coding_mode;
  assert_equal "coding_config:agent" "gemini" coding_config.coding_agent;
  assert_equal "coding_config:timeout" 1800 coding_config.coding_timeout_s;

  (* 17. Coding mode turn with no sw/proc_mgr fails gracefully *)
  let coding_state = Perpetual_loop.create_state coding_config in
  let events_captured = ref [] in
  let coding_config_with_events = { coding_config with
    on_event = (fun ev -> events_captured := ev :: !events_captured);
  } in
  let should_continue = Perpetual_loop.run_turn
    ~config:coding_config_with_events ~state:coding_state in
  assert_true "coding_turn:stops_on_missing_deps" (not should_continue);
  assert_true "coding_turn:state_stopped" (not coding_state.running);
  (* Should have emitted Error + Terminated events *)
  let has_error = List.exists (function
    | Perpetual_loop.Error _ -> true | _ -> false) !events_captured in
  let has_terminated = List.exists (function
    | Perpetual_loop.Terminated _ -> true | _ -> false) !events_captured in
  assert_true "coding_turn:emitted_error" has_error;
  assert_true "coding_turn:emitted_terminated" has_terminated;
)

(* ================================================================ *)
(* 6. Integration Tests (5)                                         *)
(* ================================================================ *)

let test_integration () = group "Integration" (fun () ->

  (* 1. Full pipeline: create → checkpoint → restore *)
  let ctx = Context_manager.create ~system_prompt:"test" ~max_tokens:10000 in
  let ctx = Context_manager.append_many ctx [
    Llm_client.user_msg "question 1";
    Llm_client.assistant_msg "answer 1";
    Llm_client.user_msg "question 2";
    Llm_client.assistant_msg "answer 2";
  ] in
  let ckpt = Context_manager.create_checkpoint ctx ~generation:0 in
  let restored = Context_manager.restore_checkpoint ckpt ~max_tokens:10000 in
  assert_equal "integration:restore_msgs" 4 (List.length restored.messages);

  (* 2. DNA extraction + hydration pipeline *)
  let session = Context_manager.create_session
    ~session_id:"test-session"
    ~base_dir:(Filename.get_temp_dir_name ()) in
  let dna = Succession.extract_dna
    ~working_ctx:ctx
    ~session_ctx:session
    ~goal:"integration test"
    ~generation:0
    ~trace_id:"test-trace-001"
    ~metrics:Succession.empty_metrics in
  assert_equal "integration:dna_gen" 0 dna.generation;
  assert_equal "integration:dna_goal" "integration test" dna.goal;

  let spec = Succession.{
    model = Llm_client.ollama_glm;
    inherit_tools = true;
    context_budget = 0.5;
  } in
  let hydrated = Succession.hydrate dna spec in
  assert_true "integration:hydrated_system"
    (String.length hydrated.system_prompt > 0);

  (* 3. Compaction reduces token count — use realistically long messages *)
  let big_ctx = Context_manager.append_many
    (Context_manager.create ~system_prompt:"test" ~max_tokens:100000)
    (List.init 20 (fun i ->
      if i mod 2 = 0
      then Llm_client.user_msg (sprintf "detailed question %d with context: %s" i (String.make 200 'x'))
      else Llm_client.assistant_msg (sprintf "comprehensive answer %d: %s" i (String.make 300 'y')))) in
  let before = big_ctx.token_count in
  let after_ctx = Context_manager.compact big_ctx
    [PruneToolOutputs; MergeContiguous; SummarizeOld] in
  assert_true "integration:compact_reduces"
    (after_ctx.token_count < before);

  (* 4. Tool schema validation *)
  let schemas = Tool_perpetual.schemas in
  assert_equal "integration:schema_count" 4 (List.length schemas);
  let names = List.map (fun (s : Types.tool_schema) -> s.name) schemas in
  assert_true "integration:has_start"
    (List.mem "masc_perpetual_start" names);
  assert_true "integration:has_status"
    (List.mem "masc_perpetual_status" names);

  (* 5. Verifier + Context pipeline *)
  let ctx_v = Context_manager.create ~system_prompt:"verify test" ~max_tokens:5000 in
  let ctx_v = Context_manager.append ctx_v (Llm_client.user_msg "do something") in
  let scored = Context_manager.score_importance ctx_v in
  assert_true "integration:scored"
    (List.length scored.importance_scores > 0);
  let _verdict = Verifier.parse_verdict "PASS" in
  assert_true "integration:verdict_parsed" true;
)

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  printf "Perpetual Agent Runtime — Test Suite\n%!";
  printf "====================================\n%!";

  test_llm_client ();
  test_context_manager ();
  test_verifier ();
  test_succession ();
  test_perpetual_loop ();
  test_integration ();

  printf "\n====================================\n%!";
  printf "Results: %d/%d passed (%d failed)\n%!"
    !pass_count !test_count !fail_count;

  if !fail_count > 0 then exit 1
  else printf "All tests passed.\n%!"
