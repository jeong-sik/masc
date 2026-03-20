(** Test_perpetual — Unit tests for the Perpetual Agent Runtime.

    60 tests across all modules:
    - MODEL Client: provider parsing, message building, cascade
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

(** Compact a working_context via OAS Context_reducer directly. *)
let compact_ctx (ctx : Context_manager.working_context)
    (strategies : Compaction_types.compaction_strategy list)
    : Context_manager.working_context =
  let messages, token_count =
    Context_compact_oas.compact
      ~system_prompt:ctx.system_prompt ~messages:ctx.messages ~strategies
  in
  { ctx with messages; token_count; importance_scores = [] }

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
(* 1. MODEL Client Tests (10)                                        *)
(* ================================================================ *)

let test_model_client () = group "MODEL Client" (fun () ->

  (* 1. Provider string roundtrip *)
  assert_equal "provider_string:llama"
    "llama" (Model_spec.string_of_provider Llama);
  assert_equal "provider_string:claude"
    "claude" (Model_spec.string_of_provider Claude);
  assert_equal "provider_string:openai"
    "openai" (Model_spec.string_of_provider OpenAI);
  assert_equal "provider_string:gemini"
    "gemini" (Model_spec.string_of_provider Gemini);

  (* 2. Model spec parsing *)
  (match Model_spec.model_spec_of_string "llama:qwen3.5-35b-a3b-ud-q8-xl" with
   | Ok m ->
     assert_equal "parse_model:llama_local_id" "qwen3.5-35b-a3b-ud-q8-xl" m.model_id;
     assert_true "parse_model:llama_local_provider"
       (m.provider = Model_spec.Llama)
   | Error _ -> assert_true "parse_model:llama_local" false);

  (match Model_spec.model_spec_of_string "claude:opus" with
   | Ok m ->
     assert_equal "parse_model:claude_id" Masc_mcp.Env_config.Claude.default_model m.model_id;
     assert_true "parse_model:claude_provider"
       (m.provider = Model_spec.Claude);
     (* Verify opus cost tier to distinguish from sonnet routing *)
     assert_true "parse_model:claude_opus_cost"
       (m.cost_per_1k_input > 0.01)
   | Error _ -> assert_true "parse_model:claude" false);

  (match Model_spec.model_spec_of_string "gemini:gemini-2.5-flash" with
   | Ok m ->
     assert_equal "parse_model:gemini_id" "gemini-2.5-flash" m.model_id;
     assert_true "parse_model:gemini_provider"
       (m.provider = Model_spec.Gemini)
   | Error _ -> assert_true "parse_model:gemini" false);

  (match Model_spec.model_spec_of_string "llama:qwen3.5-35b-a3b-ud-q8-xl:latest" with
   | Ok m ->
     assert_equal "parse_model:llama_tagged_id" "qwen3.5-35b-a3b-ud-q8-xl:latest" m.model_id;
     assert_true "parse_model:llama_tagged_provider"
       (m.provider = Model_spec.Llama)
   | Error _ -> assert_true "parse_model:llama_tagged" false);

  (match Model_spec.model_spec_of_string "llama:qwen3.5-coder" with
   | Ok m ->
     assert_equal "parse_model:llama_id" "qwen3.5-coder" m.model_id;
     assert_true "parse_model:llama_provider"
       (m.provider = Model_spec.Llama);
     assert_equal "parse_model:llama_url"
       Masc_mcp.Env_config.Llama.server_url m.api_url
   | Error e -> assert_true ("parse_model:llama_failed: " ^ e) false);

  (match Model_spec.model_spec_of_string "anthropic:sonnet" with
   | Ok m ->
     assert_equal "parse_model:anthropic_alias_id" Masc_mcp.Env_config.Claude.default_model m.model_id;
     assert_true "parse_model:anthropic_alias_provider"
       (m.provider = Model_spec.Claude)
   | Error _ -> assert_true "parse_model:anthropic_alias" false);

  (match Model_spec.model_spec_of_string "google:flash" with
   | Ok m ->
     assert_equal "parse_model:google_alias_id" Masc_mcp.Env_config.Gemini.flash_model m.model_id;
     assert_true "parse_model:google_alias_provider"
       (m.provider = Model_spec.Gemini)
   | Error _ -> assert_true "parse_model:google_alias" false);

  (match Model_spec.model_spec_of_string "claude-api:sonnet" with
   | Ok m ->
     assert_equal "parse_model:claude_api_id" Masc_mcp.Env_config.Claude.default_model m.model_id;
     assert_true "parse_model:claude_api_provider"
       (m.provider = Model_spec.Claude)
   | Error _ -> assert_true "parse_model:claude_api" false);

  (match Model_spec.model_spec_of_string "gemini-api:gemini-2.5-flash" with
   | Ok m ->
     assert_equal "parse_model:gemini_api_id" "gemini-2.5-flash" m.model_id;
     assert_true "parse_model:gemini_api_provider"
       (m.provider = Model_spec.Gemini)
   | Error _ -> assert_true "parse_model:gemini_api" false);

  (match Model_spec.model_spec_of_string "codex-api:gpt-5-mini" with
   | Ok m ->
     assert_equal "parse_model:codex_api_id" "gpt-5-mini" m.model_id;
     assert_true "parse_model:codex_api_provider"
       (m.provider = Model_spec.OpenAI)
   | Error _ -> assert_true "parse_model:codex_api" false);

  (* 3. Invalid model spec *)
  (match Model_spec.model_spec_of_string "invalid" with
   | Error _ -> assert_true "parse_model:invalid" true
   | Ok _ -> assert_true "parse_model:invalid_should_fail" false);

  (match Model_spec.model_spec_of_string "llama:" with
   | Error _ -> assert_true "parse_model:empty_model_rejected" true
   | Ok _ -> assert_true "parse_model:empty_model_should_fail" false);

  (* 3b. MLX provider was removed (PR #799); parsing should fail *)
  (match Model_spec.model_spec_of_string "mlx:qwen3.5-35b" with
   | Error _ -> assert_true "parse_model:mlx_rejected" true
   | Ok _ -> assert_true "parse_model:mlx_should_fail" false);

  (match Model_spec.model_spec_of_string "custom:mymodel@http://localhost:9999" with
   | Ok m ->
     assert_equal "parse_model:custom_with_url_id" "mymodel" m.model_id;
     assert_true "parse_model:custom_with_url_provider"
       (m.provider = Model_spec.Custom "mymodel");
     assert_equal "parse_model:custom_with_url_url" "http://localhost:9999" m.api_url
   | Error e -> assert_true ("parse_model:custom_url_failed: " ^ e) false);

  (match Model_spec.model_spec_of_string "custom:bare-model" with
   | Ok m ->
     assert_equal "parse_model:custom_bare_id" "bare-model" m.model_id;
     assert_true "parse_model:custom_bare_provider"
       (m.provider = Model_spec.Custom "bare-model");
     assert_equal "parse_model:custom_bare_url" "http://127.0.0.1:8080" m.api_url
   | Error e -> assert_true ("parse_model:custom_bare_failed: " ^ e) false);

  (* 4. Message constructors *)
  let msg = Agent_sdk.Types.system_msg "hello" in
  assert_true "msg:system_role" (msg.role = Agent_sdk.Types.System);
  assert_equal "msg:system_content" "hello" (Agent_sdk.Types.text_of_message msg);

  let msg2 = Masc_mcp.Oas_message.tool_result ~tool_use_id:"c1" ~content:"results" () in
  assert_true "msg:tool_role" (msg2.role = Agent_sdk.Types.Tool);
  let has_tool_result = List.exists (function Agent_sdk.Types.ToolResult { tool_use_id = "c1"; _ } -> true | _ -> false) msg2.content in
  assert_true "msg:tool_call_id_in_content" has_tool_result;

  (* 5. Token estimation *)
  let msgs = [Agent_sdk.Types.user_msg "hello world"] in
  let tokens = Inference_utils.estimate_tokens msgs in
  assert_true "token_estimate:positive" (tokens > 0);
  assert_true "token_estimate:reasonable" (tokens < 100);

  (* 6. Built-in model specs *)
  assert_true "builtin:llama_default_context"
    (Model_spec.llama_default.max_context = 128000);
  assert_true "builtin:claude_opus_cost"
    (Model_spec.claude_opus.cost_per_1k_input > 0.0);
  assert_true "builtin:gemini_pro_provider"
    (Model_spec.gemini_pro.provider = Model_spec.Gemini);
  assert_true "builtin:openai_default_provider"
    (Model_spec.openai_default.provider = Model_spec.OpenAI);
  assert_true "builtin:llama_default_provider"
    (Model_spec.llama_default.provider = Model_spec.Llama);
  (* Set env vars so default_local_model_spec resolves llama regardless of CI env *)
  let prev_provider = Sys.getenv_opt "MASC_DEFAULT_PROVIDER" in
  let prev_model = Sys.getenv_opt "MASC_DEFAULT_MODEL" in
  let prev_llama_model = Sys.getenv_opt "LLAMA_DEFAULT_MODEL" in
  Unix.putenv "MASC_DEFAULT_PROVIDER" "llama";
  Unix.putenv "MASC_DEFAULT_MODEL" "default-model";
  Unix.putenv "LLAMA_DEFAULT_MODEL" "default-model";
  let default_local = Model_spec.default_local_model_spec () in
  assert_true "builtin:default_local_provider"
    (default_local.provider = Model_spec.Llama);
  assert_equal "builtin:default_local_model_id"
    "default-model" default_local.model_id;
  (* Restore env vars *)
  (match prev_provider with
   | Some v -> Unix.putenv "MASC_DEFAULT_PROVIDER" v
   | None -> (try Unix.putenv "MASC_DEFAULT_PROVIDER" "" with _ -> ()));
  (match prev_model with
   | Some v -> Unix.putenv "MASC_DEFAULT_MODEL" v
   | None -> (try Unix.putenv "MASC_DEFAULT_MODEL" "" with _ -> ()));
  (match prev_llama_model with
   | Some v -> Unix.putenv "LLAMA_DEFAULT_MODEL" v
   | None -> (try Unix.putenv "LLAMA_DEFAULT_MODEL" "" with _ -> ()));
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
  let msg = Agent_sdk.Types.user_msg "hello" in
  let ctx2 = Context_manager.append ctx msg in
  assert_equal "append:count" 1 (List.length ctx2.messages);
  assert_true "append:tokens_increased" (ctx2.token_count > ctx.token_count);

  (* 3. Append many *)
  let msgs = [Agent_sdk.Types.user_msg "a"; Agent_sdk.Types.assistant_msg "b"] in
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
    Agent_sdk.Types.user_msg "important question";
    Agent_sdk.Types.assistant_msg "answer";
    Agent_sdk.Types.user_msg "follow up";
  ] in
  let scored = Context_manager.score_importance ctx4 in
  assert_true "importance:has_scores"
    (List.length scored.importance_scores = 3);
  (* Last message should score higher due to recency *)
  let score_0 = List.assoc 0 scored.importance_scores in
  let score_2 = List.assoc 2 scored.importance_scores in
  assert_true "importance:recency" (score_2 > score_0);

  (* 7. PruneToolOutputs *)
  let long_tool_msg = { (Masc_mcp.Oas_message.tool_result ~tool_use_id:"c" ~content:(String.make 1000 'x') ())
    with role = Agent_sdk.Types.Tool } in
  let ctx5 = Context_manager.append ctx long_tool_msg in
  let pruned = compact_ctx ctx5 [PruneToolOutputs] in
  let pruned_msg = List.hd pruned.messages in
  assert_true "prune:shorter" (String.length (Agent_sdk.Types.text_of_message pruned_msg) < 1000);
  assert_true "prune:has_truncated" (
    try let _ = Str.search_forward (Str.regexp_string "truncated") (Agent_sdk.Types.text_of_message pruned_msg) 0 in true
    with Not_found -> false);

  (* 8. MergeContiguous *)
  let ctx6 = Context_manager.append_many ctx [
    Agent_sdk.Types.user_msg "part1";
    Agent_sdk.Types.user_msg "part2";
    Agent_sdk.Types.assistant_msg "response";
  ] in
  let merged = compact_ctx ctx6 [MergeContiguous] in
  assert_equal "merge:count" 2 (List.length merged.messages);

  (* 9. SummarizeOld *)
  let many_msgs = List.init 10 (fun i ->
    if i mod 2 = 0 then Agent_sdk.Types.user_msg (sprintf "q%d" i)
    else Agent_sdk.Types.assistant_msg (sprintf "a%d" i)) in
  let ctx7 = Context_manager.append_many ctx many_msgs in
  let summarized = compact_ctx ctx7 [SummarizeOld] in
  assert_true "summarize:fewer_messages"
    (List.length summarized.messages < List.length ctx7.messages);

  (* 10. Full compaction pipeline — use long messages so compaction saves tokens *)
  let long_ctx = Context_manager.append_many ctx
    (List.init 10 (fun i ->
      if i mod 2 = 0
      then Agent_sdk.Types.user_msg (sprintf "detailed question %d with lots of context: %s" i (String.make 200 'x'))
      else Agent_sdk.Types.assistant_msg (sprintf "comprehensive answer %d: %s" i (String.make 300 'y')))) in
  let compacted = compact_ctx long_ctx
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

  (* 12b. Checkpoint restore repairs malformed UTF-8 from legacy storage *)
  let dirty_serialized =
    "{\"system_prompt\":\"test\",\"messages\":[{\"role\":\"user\",\"content\":\"hel\x80lo\"},{\"role\":\"assistant\",\"content\":\"wor\xFFld\"}],\"token_count\":2,\"max_tokens\":1000}"
  in
  let dirty_ckpt = { ckpt with serialized = dirty_serialized } in
  let repaired = Context_manager.restore_checkpoint dirty_ckpt ~max_tokens:1000 in
  assert_equal "restore:utf8_msg_count" 2 (List.length repaired.messages);
  assert_true "restore:utf8_content_valid"
    (List.for_all
       (fun (msg : Agent_sdk.Types.message) ->
         let s = Agent_sdk.Types.text_of_message msg in
         let rec valid_from i =
           if i >= String.length s then true
           else
             let dec = String.get_utf_8_uchar s i in
             let dlen = Uchar.utf_decode_length dec in
             dlen > 0 && Uchar.utf_decode_is_valid dec && valid_from (i + dlen)
         in
         valid_from 0)
       repaired.messages);

  (* 13. DropLowImportance *)
  let ctx8 = Context_manager.append_many
    (Context_manager.create ~system_prompt:"test" ~max_tokens:10000) [
    Agent_sdk.Types.user_msg "important long question about architecture design";
    Agent_sdk.Types.assistant_msg "ok";  (* Short = low importance *)
    Agent_sdk.Types.user_msg "another detailed question with context";
  ] in
  let dropped = compact_ctx ctx8 [DropLowImportance] in
  assert_true "drop:removes_some"
    (List.length dropped.messages <= List.length ctx8.messages);
)

(* ================================================================ *)
(* 3. Verifier Tests (8)                                            *)
(* ================================================================ *)

let test_verifier () = group "Verifier" (fun () ->

  (* 1. Parse PASS *)
  let v = Verifier_oas.parse_verdict "PASS" in
  assert_true "parse:pass" (v = Verifier_oas.Pass);

  (* 2. Parse WARN *)
  let v2 = Verifier_oas.parse_verdict "WARN: might be slow" in
  (match v2 with
   | Verifier_oas.Warn reason ->
     assert_true "parse:warn_reason" (String.length reason > 0)
   | _ -> assert_true "parse:warn" false);

  (* 3. Parse FAIL *)
  let v3 = Verifier_oas.parse_verdict "FAIL: wrong approach" in
  (match v3 with
   | Verifier_oas.Fail reason ->
     assert_true "parse:fail_reason" (String.length reason > 0)
   | _ -> assert_true "parse:fail" false);

  (* 4. Parse with colon *)
  let v4 = Verifier_oas.parse_verdict "WARN: something" in
  (match v4 with
   | Verifier_oas.Warn r -> assert_equal "parse:warn_colon" "something" r
   | _ -> assert_true "parse:warn_colon" false);

  (* 5. Parse unknown → Warn *)
  let v5 = Verifier_oas.parse_verdict "I think this is fine" in
  (match v5 with
   | Verifier_oas.Warn _ -> assert_true "parse:unknown_as_warn" true
   | _ -> assert_true "parse:unknown" false);

  (* 6. Should skip: read operations *)
  assert_true "skip:read" (Verifier_oas.should_skip ~action_description:"Read file.txt");
  assert_true "skip:glob" (Verifier_oas.should_skip ~action_description:"Glob **/*.ml");
  assert_true "skip:grep" (Verifier_oas.should_skip ~action_description:"Grep pattern");

  (* 7. Should not skip: write operations *)
  assert_true "skip:write" (not (Verifier_oas.should_skip ~action_description:"Write file.txt"));
  assert_true "skip:edit" (not (Verifier_oas.should_skip ~action_description:"Edit code"));

  (* 8. Verdict to string *)
  assert_equal "verdict_str:pass" "PASS" (Verifier_oas.verdict_to_string Pass);
  assert_true "verdict_str:warn"
    (String.length (Verifier_oas.verdict_to_string (Warn "x")) > 5);
)

(* ================================================================ *)
(* 4. Succession Tests (12)                                         *)
(* ================================================================ *)

let test_succession () = group "Succession" (fun () ->

  (* 1. Empty metrics *)
  let m = Succession_oas.empty_metrics in
  assert_equal "metrics:empty_turns" 0 m.total_turns;
  assert_float_near "metrics:empty_cost" 0.0 m.total_cost_usd 0.001;

  (* 2. Merge metrics *)
  let m1 = { Succession_oas.empty_metrics with total_turns = 5; total_cost_usd = 1.0 } in
  let m2 = { Succession_oas.empty_metrics with total_turns = 3; total_cost_usd = 0.5 } in
  let merged = Succession_oas.merge_metrics m1 m2 in
  assert_equal "merge:turns" 8 merged.total_turns;
  assert_float_near "merge:cost" 1.5 merged.total_cost_usd 0.001;

  (* 3. DNA to JSON roundtrip *)
  let dna = Succession_oas.{
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
  let json = Succession_oas.dna_to_json dna in
  (match Succession_oas.dna_of_json json with
   | Ok restored ->
     assert_equal "dna_rt:generation" 2 restored.generation;
     assert_equal "dna_rt:trace" "test-trace" restored.trace_id;
     assert_equal "dna_rt:goal" "test goal" restored.goal;
     assert_equal "dna_rt:pending" 1 (List.length restored.pending_actions);
     assert_equal "dna_rt:warnings" 1 (List.length restored.warnings);
   | Error e -> assert_true (sprintf "dna_roundtrip: %s" e) false);

  (* 4. DNA from invalid JSON *)
  (match Succession_oas.dna_of_json (`String "invalid") with
   | Error _ -> assert_true "dna_invalid:error" true
   | Ok _ -> assert_true "dna_invalid:should_fail" false);

  (* 5. Cross-model normalization: Llama *)
  let msgs = [
    Agent_sdk.Types.user_msg "hello";
    Masc_mcp.Oas_message.tool_result ~tool_use_id:"c1" ~content:"results" ();
    Agent_sdk.Types.assistant_msg "done";
  ] in
  let normalized = Succession_oas.normalize_for_model msgs Model_spec.llama_default in
  (* Tool messages should be converted to user messages for local llama runtimes *)
  let tool_msgs = List.filter (fun (m : Agent_sdk.Types.message) ->
    m.role = Agent_sdk.Types.Tool) normalized in
  assert_equal "normalize:llama_no_tool" 0 (List.length tool_msgs);

  (* 6. Cross-model normalization: Claude merges consecutive *)
  let msgs2 = [
    Agent_sdk.Types.user_msg "part1";
    Agent_sdk.Types.user_msg "part2";
    Agent_sdk.Types.assistant_msg "response";
  ] in
  let normalized2 = Succession_oas.normalize_for_model msgs2 Model_spec.claude_opus in
  assert_true "normalize:claude_merged"
    (List.length normalized2 <= List.length msgs2);

  (* 7. Hydrate from DNA *)
  let spec = Succession_oas.{
    model = Model_spec.llama_default;
    inherit_tools = true;
    context_budget = 0.3;
  } in
  let hydrated = Succession_oas.hydrate dna spec in
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
    ~goal:"test" ~models:[Model_spec.llama_default] () in
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
  let status = Perpetual_loop.status ~config state in
  (match status with
   | `Assoc fields ->
     assert_true "status:has_trace"
       (List.mem_assoc "trace_id" fields);
     assert_true "status:has_running"
       (List.mem_assoc "running" fields);
     assert_true "status:has_context_ratio"
       (List.mem_assoc "context_ratio" fields);
   | _ -> assert_true "status:is_object" false);

  (* 5. Stopped state is reflected in status *)
  let fresh_config = Perpetual_loop.default_config
    ~goal:"test" ~models:[Model_spec.llama_default] () in
  let fresh_state = Perpetual_loop.create_state fresh_config in
  Perpetual_loop.stop fresh_state;
  assert_true "stop:running_false" (not fresh_state.running);
  let s = Perpetual_loop.status ~config:fresh_config fresh_state in
  (match s with
   | `Assoc fields ->
     (match List.assoc "running" fields with
      | `Bool b -> assert_true "stop:status_running_false" (not b)
      | _ -> assert_true "stop:running_is_bool" false)
   | _ -> assert_true "stop:is_object" false);

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
       (fun (msg : Agent_sdk.Types.message) ->
         msg.role = Agent_sdk.Types.User &&
         Str.string_match
           (Str.regexp_string (Context_manager.goal_prefix ^ " test"))
           (Agent_sdk.Types.text_of_message msg) 0)
       state2.context.messages);

  (* 8. Cost starts at zero *)
  assert_float_near "cost:initial" 0.0 state2.total_cost 0.001;

  (* 9. Idle turns starts at zero *)
  assert_equal "idle:initial" 0 state2.idle_turns;

  (* 10. Multiple model cascade *)
  let config3 = Perpetual_loop.default_config
    ~goal:"multi"
    ~models:
      [
        Model_spec.llama_default;
        { Model_spec.llama_default with model_id = "qwen3.5-9b" };
      ]
    () in
  assert_equal "cascade:model_count" 2
    (List.length config3.model_cascade);

  (* 11. Default config: coding_mode is false *)
  assert_true "config:coding_mode_default" (not config.coding_mode);

  (* 12. Default config: coding_agent is "claude" *)
  assert_equal "config:coding_agent_default"
    (Masc_mcp.Provider_adapter.default_cli_agent_name ()) config.coding_agent;

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

  (* 17. record_event caps at 200 entries *)
  let ev_state = Perpetual_loop.create_state coding_config in
  for i = 1 to 210 do
    Perpetual_loop.record_event ev_state (Perpetual_loop.TurnStart i)
  done;
  assert_true "record_event:capped_at_200" (List.length ev_state.events <= 200);
)

(* ================================================================ *)
(* 5b. Auto-Claim Tests (6)                                         *)
(* ================================================================ *)

let test_auto_claim () = group "Auto-Claim" (fun () ->

  (* 1. Auto-claim disabled when no room_config *)
  let config = Perpetual_loop.default_config
    ~goal:"test" ~models:[Model_spec.llama_default] () in
  assert_true "auto_claim:disabled_by_default" (config.room_config = None);
  let state = Perpetual_loop.create_state config in
  assert_true "auto_claim:no_current_task" (state.current_task_id = None);
  let before_ts = state.last_claim_attempt_ts in
  let events_captured = ref [] in
  let config_with_events = { config with
    on_event = (fun ev -> events_captured := ev :: !events_captured);
  } in
  ignore config_with_events;
  assert_float_near "auto_claim:ts_unchanged" before_ts state.last_claim_attempt_ts 0.001;
  assert_equal "auto_claim:failure_count_zero" 0 state.claim_failure_count;

  (* 2. Cooldown prevents re-attempt *)
  let state2 = Perpetual_loop.create_state config in
  state2.last_claim_attempt_ts <- Time_compat.now ();
  state2.claim_failure_count <- 0;
  let effective_cd = config.auto_claim_cooldown_s *. (2.0 ** Float.of_int 0) in
  assert_float_near "cooldown:base_is_60s" 60.0 effective_cd 0.01;
  let elapsed = Time_compat.now () -. state2.last_claim_attempt_ts in
  assert_true "cooldown:within_window" (elapsed < effective_cd);

  (* 3. Exponential backoff calculation *)
  let cd0 = config.auto_claim_cooldown_s *. (2.0 ** Float.of_int (min 4 0)) in
  assert_float_near "backoff:count0" 60.0 cd0 0.01;
  let cd1 = config.auto_claim_cooldown_s *. (2.0 ** Float.of_int (min 4 1)) in
  assert_float_near "backoff:count1" 120.0 cd1 0.01;
  let cd2 = config.auto_claim_cooldown_s *. (2.0 ** Float.of_int (min 4 2)) in
  assert_float_near "backoff:count2" 240.0 cd2 0.01;
  let cd4 = config.auto_claim_cooldown_s *. (2.0 ** Float.of_int (min 4 4)) in
  assert_float_near "backoff:count4_cap" 960.0 cd4 0.01;
  let cd10 = config.auto_claim_cooldown_s *. (2.0 ** Float.of_int (min 4 10)) in
  assert_float_near "backoff:count10_still_capped" 960.0 cd10 0.01;

  (* 4. Skip when holding task *)
  let state3 = Perpetual_loop.create_state config in
  state3.current_task_id <- Some "task-001";
  assert_true "skip_holding:has_task" (Option.is_some state3.current_task_id);
  assert_equal "skip_holding:no_failures" 0 state3.claim_failure_count;

  (* 5. Task completion detection pattern *)
  let content_with_done = "I have finished the task.\n[TASK_DONE]\n[STATE]\nGoal: done\n[/STATE]" in
  let has_marker =
    try ignore (Str.search_forward (Str.regexp_string "[TASK_DONE]") content_with_done 0); true
    with Not_found -> false
  in
  assert_true "completion:marker_found" has_marker;
  let content_without = "Still working on it.\n[STATE]\nGoal: wip\n[/STATE]" in
  let marker_found =
    try ignore (Str.search_forward (Str.regexp_string "[TASK_DONE]") content_without 0); true
    with Not_found -> false
  in
  assert_true "completion:no_false_positive" (not marker_found);

  (* 6. Event types exist and serialize *)
  let claimed_ev = Perpetual_loop.TaskClaimed {
    task_id = "task-001"; title = "Fix bug"; priority = 2
  } in
  let completed_ev = Perpetual_loop.TaskCompleted { task_id = "task-001" } in
  let skipped_ev = Perpetual_loop.ClaimSkipped "no_unclaimed_tasks" in
  (match claimed_ev with
   | Perpetual_loop.TaskClaimed { task_id; title; priority } ->
     assert_equal "event:claimed_id" "task-001" task_id;
     assert_equal "event:claimed_title" "Fix bug" title;
     assert_equal "event:claimed_priority" 2 priority
   | _ -> assert_true "event:is_task_claimed" false);
  (match completed_ev with
   | Perpetual_loop.TaskCompleted { task_id } ->
     assert_equal "event:completed_id" "task-001" task_id
   | _ -> assert_true "event:is_task_completed" false);
  (match skipped_ev with
   | Perpetual_loop.ClaimSkipped reason ->
     assert_equal "event:skipped_reason" "no_unclaimed_tasks" reason
   | _ -> assert_true "event:is_claim_skipped" false);

  (* Status JSON includes auto-claim fields *)
  let state4 = Perpetual_loop.create_state config in
  state4.current_task_id <- Some "task-042";
  let status = Perpetual_loop.status ~config state4 in
  (match status with
   | `Assoc fields ->
     assert_true "status:has_current_task_id"
       (List.mem_assoc "current_task_id" fields);
     assert_true "status:has_claim_failure_count"
       (List.mem_assoc "claim_failure_count" fields);
     (match List.assoc "current_task_id" fields with
      | `String id -> assert_equal "status:task_id_value" "task-042" id
      | _ -> assert_true "status:task_id_is_string" false)
   | _ -> assert_true "status:is_object" false);
)

(* ================================================================ *)
(* 6. Integration Tests (5)                                         *)
(* ================================================================ *)

let test_integration () = group "Integration" (fun () ->

  (* 1. Full pipeline: create → checkpoint → restore *)
  let ctx = Context_manager.create ~system_prompt:"test" ~max_tokens:10000 in
  let ctx = Context_manager.append_many ctx [
    Agent_sdk.Types.user_msg "question 1";
    Agent_sdk.Types.assistant_msg "answer 1";
    Agent_sdk.Types.user_msg "question 2";
    Agent_sdk.Types.assistant_msg "answer 2";
  ] in
  let ckpt = Context_manager.create_checkpoint ctx ~generation:0 in
  let restored = Context_manager.restore_checkpoint ckpt ~max_tokens:10000 in
  assert_equal "integration:restore_msgs" 4 (List.length restored.messages);

  (* 2. DNA extraction + hydration pipeline *)
  let session = Context_manager.create_session
    ~session_id:"test-session"
    ~base_dir:(Filename.get_temp_dir_name ()) in
  let dna = Succession_oas.extract_dna
    ~working_ctx:ctx
    ~session_ctx:session
    ~goal:"integration test"
    ~generation:0
    ~trace_id:"test-trace-001"
    ~metrics:Succession_oas.empty_metrics in
  assert_equal "integration:dna_gen" 0 dna.generation;
  assert_equal "integration:dna_goal" "integration test" dna.goal;

  let spec = Succession_oas.{
    model = Model_spec.llama_default;
    inherit_tools = true;
    context_budget = 0.5;
  } in
  let hydrated = Succession_oas.hydrate dna spec in
  assert_true "integration:hydrated_system"
    (String.length hydrated.system_prompt > 0);

  (* 3. Compaction reduces token count — use realistically long messages *)
  let big_ctx = Context_manager.append_many
    (Context_manager.create ~system_prompt:"test" ~max_tokens:100000)
    (List.init 20 (fun i ->
      if i mod 2 = 0
      then Agent_sdk.Types.user_msg (sprintf "detailed question %d with context: %s" i (String.make 200 'x'))
      else Agent_sdk.Types.assistant_msg (sprintf "comprehensive answer %d: %s" i (String.make 300 'y')))) in
  let before = big_ctx.token_count in
  let after_ctx = compact_ctx big_ctx
    [PruneToolOutputs; MergeContiguous; SummarizeOld] in
  assert_true "integration:compact_reduces"
    (after_ctx.token_count < before);

  (* 3b. Context_compact_oas roundtrip preserves role information *)
  let tool_msg_rt = Masc_mcp.Oas_message.tool_result ~tool_use_id:"tc1" ~content:"search results" () in
  let sys_msg_rt = Agent_sdk.Types.system_msg "you are a helper" in
  let user_msg_rt = Agent_sdk.Types.user_msg "hello" in
  let asst_msg_rt = Agent_sdk.Types.assistant_msg "hi there" in
  List.iter (fun (label, orig_msg) ->
    let oas_msg = Context_compact_oas.masc_msg_to_oas orig_msg in
    let back = Context_compact_oas.oas_msg_to_masc oas_msg in
    assert_true (sprintf "roundtrip:%s:role" label) (back.role = orig_msg.role);
    assert_true (sprintf "roundtrip:%s:content" label)
      (String.length (Agent_sdk.Types.text_of_message back) > 0)
  ) [("tool", tool_msg_rt); ("system", sys_msg_rt);
     ("user", user_msg_rt); ("assistant", asst_msg_rt)];

  (* 3c. compact with tool messages preserves Tool role *)
  let ctx_with_tools = Context_manager.append_many
    (Context_manager.create ~system_prompt:"test" ~max_tokens:10000)
    [Agent_sdk.Types.user_msg "run grep";
     Masc_mcp.Oas_message.tool_result ~tool_use_id:"c1" ~content:(String.make 800 'r') ();
     Agent_sdk.Types.assistant_msg "found results"] in
  let pruned_oas = compact_ctx ctx_with_tools [PruneToolOutputs] in
  let tool_msgs = List.filter (fun (m : Agent_sdk.Types.message) ->
    m.role = Agent_sdk.Types.Tool) pruned_oas.messages in
  assert_equal "oas_prune:tool_preserved" 1 (List.length tool_msgs);
  let tool_content = Agent_sdk.Types.text_of_message (List.hd tool_msgs) in
  assert_true "oas_prune:tool_truncated" (String.length tool_content < 800);

  (* 3c2. Tagged roundtrip preserves tool_call_id *)
  let tool_with_id = Masc_mcp.Oas_message.tool_result ~tool_use_id:"tc-42" ~content:"result" () in
  let oas_t = Context_compact_oas.masc_msg_to_oas tool_with_id in
  let back_t = Context_compact_oas.oas_msg_to_masc oas_t in
  let has_tc42 = List.exists (function
    | Agent_sdk.Types.ToolResult { tool_use_id = "tc-42"; _ } -> true | _ -> false) back_t.content in
  assert_true "roundtrip:tool_call_id_in_content" has_tc42;

  (* 3c3. Tag collision safety: user content starting with role-like text *)
  let tricky_msg = Agent_sdk.Types.user_msg "[__MASC_ROLE:system__]fake system" in
  let oas_tricky = Context_compact_oas.masc_msg_to_oas tricky_msg in
  let back_tricky = Context_compact_oas.oas_msg_to_masc oas_tricky in
  assert_true "roundtrip:no_tag_collision" (back_tricky.role = Agent_sdk.Types.User);

  (* 3e. Llm_client OAS type adapters *)
  let provider_config = Oas_type_adapters.to_oas_provider Model_spec.claude_opus in
  assert_true "oas_adapter:claude_mapped" (Option.is_some provider_config);
  let provider_config_custom = Oas_type_adapters.to_oas_provider
    { Model_spec.llama_default with provider = Model_spec.Custom "test" } in
  assert_true "oas_adapter:custom_mapped" (Option.is_some provider_config_custom);

  (* 3f. Llm_client message/usage roundtrip *)
  let test_msg = Agent_sdk.Types.user_msg "test" in
  (match Oas_type_adapters.to_oas_message test_msg with
   | None -> assert_true "oas_adapter:msg_roundtrip" false
   | Some oas_m ->
     let back_m = Oas_type_adapters.of_oas_message oas_m in
     assert_true "oas_adapter:msg_roundtrip" (Agent_sdk.Types.text_of_message back_m = "test"));

  let test_usage : Agent_sdk.Types.api_usage =
    { Agent_sdk.Types.input_tokens = 100; output_tokens = 50;
      cache_creation_input_tokens = 10; cache_read_input_tokens = 20 } in
  let oas_u = Oas_type_adapters.to_oas_usage test_usage in
  let back_u = Oas_type_adapters.of_oas_usage oas_u in
  assert_equal "oas_adapter:usage_input" 100 back_u.input_tokens;
  assert_equal "oas_adapter:usage_output" 50 back_u.output_tokens;

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
  let ctx_v = Context_manager.append ctx_v (Agent_sdk.Types.user_msg "do something") in
  let scored = Context_manager.score_importance ctx_v in
  assert_true "integration:scored"
    (List.length scored.importance_scores > 0);
  let _verdict = Verifier_oas.parse_verdict "PASS" in
  assert_true "integration:verdict_parsed" true;
)

(* ================================================================ *)
(* 7. History Offload Tests                                         *)
(* ================================================================ *)

let test_history_offload () = group "History Offload" (fun () ->

  (* 1. format_message_readable produces role: content format *)
  let user_msg = Agent_sdk.Types.user_msg "hello world" in
  let formatted = Context_manager.format_message_readable user_msg in
  assert_true "format:user" (formatted = "user: hello world");

  let tool_msg = Masc_mcp.Oas_message.tool_result ~tool_use_id:"c1" ~content:"search results" () in
  let formatted_tool = Context_manager.format_message_readable tool_msg in
  assert_true "format:tool_with_name"
    (String.length formatted_tool > 0
     && String.sub formatted_tool 0 4 = "tool");

  (* 2. offload_messages creates file in correct location *)
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (sprintf "masc-offload-test-%d" (int_of_float (Unix.gettimeofday () *. 1000.0))) in
  let messages = [
    Agent_sdk.Types.user_msg "question 1";
    Agent_sdk.Types.assistant_msg "answer 1";
    Agent_sdk.Types.user_msg "question 2";
  ] in
  let result = Context_manager.offload_messages
    ~session_dir:tmp_dir ~compaction_count:0 messages in
  assert_true "offload:returns_some" (Option.is_some result);
  let path = Option.get result in
  assert_true "offload:file_exists" (Sys.file_exists path);
  assert_true "offload:correct_filename"
    (Filename.basename path = "0.md");
  assert_true "offload:in_offloaded_dir"
    (Filename.basename (Filename.dirname path) = "offloaded");

  (* 3. offload file contains readable content *)
  let ic = open_in path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  let content = Bytes.to_string buf in
  assert_true "offload:has_header"
    (let len = String.length "## Compacted at" in
     String.length content >= len
     && String.sub content 0 len = "## Compacted at");
  assert_true "offload:has_user_msg"
    (try let _ = Str.search_forward (Str.regexp_string "user: question 1") content 0 in true
     with Not_found -> false);
  assert_true "offload:has_assistant_msg"
    (try let _ = Str.search_forward (Str.regexp_string "assistant: answer 1") content 0 in true
     with Not_found -> false);

  (* 4. offload with invalid path returns None (fail-safe) *)
  let bad_result = Context_manager.offload_messages
    ~session_dir:"/nonexistent/path/that/cannot/exist" ~compaction_count:0 messages in
  assert_true "offload:failsafe" (Option.is_none bad_result);

  (* 5. compact_with_offload returns both context and offload path *)
  let session = Context_manager.create_session
    ~session_id:"offload-test"
    ~base_dir:(Filename.get_temp_dir_name ()) in
  let ctx = Context_manager.create ~system_prompt:"test" ~max_tokens:100000 in
  let ctx = Context_manager.append_many ctx
    (List.init 20 (fun i ->
      if i mod 2 = 0
      then Agent_sdk.Types.user_msg (sprintf "question %d with detail: %s" i (String.make 200 'x'))
      else Agent_sdk.Types.assistant_msg (sprintf "answer %d: %s" i (String.make 300 'y')))) in
  (* offload + compact separately (compact_with_offload removed) *)
  let offloaded_path = Context_manager.offload_messages
    ~session_dir:session.session_dir ~compaction_count:1 ctx.messages in
  let compacted = compact_ctx ctx [PruneToolOutputs; MergeContiguous; SummarizeOld] in
  assert_true "compact_offload:has_path" (Option.is_some offloaded_path);
  assert_true "compact_offload:context_reduced"
    (compacted.token_count < ctx.token_count);
  assert_true "compact_offload:file_exists"
    (Sys.file_exists (Option.get offloaded_path));

  (* 7. compact still works *)
  let orig = compact_ctx ctx [PruneToolOutputs; SummarizeOld] in
  assert_true "compact:original_unchanged"
    (orig.token_count < ctx.token_count);

  (* Cleanup temp dirs *)
  (try Sys.remove path with _ -> ());
)

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  printf "Perpetual Agent Runtime — Test Suite\n%!";
  printf "====================================\n%!";

  test_model_client ();
  test_context_manager ();
  test_verifier ();
  test_succession ();
  test_perpetual_loop ();
  test_auto_claim ();
  test_integration ();
  test_history_offload ();

  printf "\n====================================\n%!";
  printf "Results: %d/%d passed (%d failed)\n%!"
    !pass_count !test_count !fail_count;

  if !fail_count > 0 then exit 1
  else printf "All tests passed.\n%!"
