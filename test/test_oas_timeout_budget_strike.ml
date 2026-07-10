open Masc

module KH = Keeper_heartbeat_loop
module KFP = Keeper_failure_policy
module KK = Keeper_turn_holders
module KCB = Keeper_turn_runtime_budget
module KTD = Keeper_turn_driver
module EC = Keeper_error_classify

let with_reset keeper f =
  KK.reset_budget_exhaustion ~keeper_name:keeper;
  Fun.protect
    ~finally:(fun () -> KK.reset_budget_exhaustion ~keeper_name:keeper)
    f

let test_seeded_bump_increments_from_prior () =
  with_reset "seeded" (fun () ->
    let strikes =
      KK.bump_budget_exhaustion_seeded
        ~keeper_name:"seeded"
        ~prior_strikes:2
    in
    Alcotest.(check int) "bump increments from 2 to 3" 3 strikes;
    Alcotest.(check int) "peek sees persisted in-process count" 3
      (KK.peek_budget_exhaustion_for_test ~keeper_name:"seeded"))

let test_in_process_bump_accumulates () =
  with_reset "in-process" (fun () ->
    Alcotest.(check int) "first" 1
      (KK.bump_budget_exhaustion ~keeper_name:"in-process");
    Alcotest.(check int) "second" 2
      (KK.bump_budget_exhaustion ~keeper_name:"in-process"))

let test_seeded_bump_uses_higher_persisted_count () =
  with_reset "seed-max" (fun () ->
    KK.set_budget_exhaustion_for_test ~keeper_name:"seed-max" ~strikes:1;
    let strikes =
      KK.bump_budget_exhaustion_seeded
        ~keeper_name:"seed-max"
        ~prior_strikes:4
    in
    Alcotest.(check int) "seed catches up to persisted count" 5 strikes)

let test_reset_clears () =
  KK.set_budget_exhaustion_for_test ~keeper_name:"reset" ~strikes:2;
  KK.reset_budget_exhaustion ~keeper_name:"reset";
  Alcotest.(check int) "reset clears" 0
    (KK.peek_budget_exhaustion_for_test ~keeper_name:"reset")

let test_strike_limit_is_soft_backoff () =
  (match KK.classify_provider_timeout_strike ~strikes:1 with
   | KK.Provider_timeout_warn -> ()
   | KK.Provider_timeout_soft_backoff -> failwith "strike 1 should warn");
  (match
     KK.classify_provider_timeout_strike
       ~strikes:KK.provider_timeout_strike_limit
   with
   | KK.Provider_timeout_soft_backoff -> ()
   | KK.Provider_timeout_warn ->
     failwith "strike limit should soft-backoff, not crash")

let provider_timeout_error ~phase =
  KTD.sdk_error_of_masc_internal_error
    (KTD.Provider_timeout
       { budget_sec = 90.0
       ; keeper_turn_timeout_sec = 1200.0
       ; estimated_input_tokens = 10_000
       ; source = "test"
       ; remaining_turn_budget_sec = Some 42.0
       ; min_required_sec = 15.0
       ; phase
       })

let raw_provider_timeout_error ~phase =
  Agent_sdk.Error.Provider
    (Llm_provider.Error.Timeout
       { provider = "test_provider"
       ; timeout_phase = phase
       ; detail = "provider timeout"
       })

let raw_api_timeout_error () =
  Agent_sdk.Error.Api
    (Llm_provider.Retry.Timeout
       { message = "Per-provider timeout after 90.0s"; phase = None })

let turn_timeout_error () =
  KTD.sdk_error_of_masc_internal_error (KTD.Turn_timeout { elapsed_sec = 600.0 })

let ambiguous_post_commit_error () =
  KTD.sdk_error_of_masc_internal_error
    (KTD.Ambiguous_post_commit
       { is_timeout = true
       ; tools = [ "keeper_board_post" ]
       ; original_error = "provider timeout after board post"
       })

let legacy_ambiguous_internal_error () =
  Agent_sdk.Error.Internal
    "turn outcome ambiguous after committed mutating tool call(s): []; \
     original_error=provider_timeout"

let tls_handshake_internal_error () =
  KTD.sdk_error_of_masc_internal_error
    (KTD.Internal_unhandled_exception
       { site = KTD.runtime_runner_execute_site
       ; exn_repr = "TLS alert from peer: handshake failure"
       ; transport_error_kind = Some Llm_provider.Http_client.Tls_error
       })


let test_cycle_failed_log_level_is_policy_aware () =
  Alcotest.(check bool)
    "provider timeout cycle failure is warn"
    true
    (EC.should_warn_keeper_cycle_failed
       (provider_timeout_error ~phase:"runtime_attempt_watchdog"));
  Alcotest.(check bool)
    "turn timeout remains error"
    false
    (EC.should_warn_keeper_cycle_failed (turn_timeout_error ()))

let test_raw_oas_provider_timeout_uses_same_policy () =
  let err =
    raw_provider_timeout_error
      ~phase:
        (Some
           (Llm_provider.Http_client.Stream_idle
              Llm_provider.Http_client.Streaming_thinking))
  in
  Alcotest.(check bool)
    "raw provider timeout is a provider timeout"
    true
    (EC.is_provider_timeout_error err);
  Alcotest.(check bool)
    "raw provider timeout cycle failure is warn"
    true
    (EC.should_warn_keeper_cycle_failed err);
  match
    KH.provider_timeout_policy_decision
      ~strikes:KK.provider_timeout_strike_limit
      err
  with
  | None -> Alcotest.fail "expected provider timeout policy decision"
  | Some decision ->
    Alcotest.(check string)
      "reason preserves OAS timeout phase"
      "provider_timeout_loop:stream_idle:streaming_thinking"
      decision.reason

let test_raw_oas_api_timeout_uses_same_policy () =
  let err = raw_api_timeout_error () in
  Alcotest.(check bool)
    "raw API timeout is a provider timeout"
    true
    (EC.is_provider_timeout_error err);
  match KH.provider_timeout_policy_decision ~strikes:1 err with
  | None -> Alcotest.fail "expected provider timeout policy decision"
  | Some decision ->
    Alcotest.(check string)
      "phase-free API timeout keeps generic reason"
      "provider_timeout"
      decision.reason

let test_tls_handshake_internal_error_is_transient () =
  let err = tls_handshake_internal_error () in
  Alcotest.(check bool)
    "runtime_runner TLS handshake failure is a transient runner error"
    true
    (EC.is_transient_internal_runner_error err);
  Alcotest.(check bool)
    "runtime_runner TLS handshake failure enters transient network retry"
    true
    (EC.is_transient_network_error err);
  Alcotest.(check bool)
    "runtime_runner TLS handshake failure is auto-recoverable at turn level"
    true
    (EC.is_auto_recoverable_turn_error err)

let test_retry_timeout_budget_ignores_expired_outer_turn_budget () =
  let budget =
    KCB.resolve_bounded_provider_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:false
      ~is_retry:true
      ~estimated_input_tokens:10_000
      ~remaining_turn_budget_s:0.0
  in
  Alcotest.(check string)
    "retry source"
    "retry_adaptive_timeout"
    budget.source;
  Alcotest.(check bool)
    "retry keeps an actionable provider timeout"
    true
    (budget.effective_timeout_sec >= KCB.min_provider_timeout_budget_sec);
  Alcotest.(check (float 0.001))
    "remaining turn budget is telemetry only"
    0.0
    budget.remaining_turn_budget_sec

let test_first_attempt_timeout_ignores_expired_outer_turn_budget () =
  let budget =
    KCB.resolve_bounded_provider_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:false
      ~is_retry:false
      ~estimated_input_tokens:10_000
      ~remaining_turn_budget_s:0.0
  in
  Alcotest.(check string)
    "first attempt source"
    "first_attempt_adaptive_timeout"
    budget.source;
  Alcotest.(check bool)
    "first attempt keeps an actionable provider timeout"
    true
    (budget.effective_timeout_sec >= KCB.min_provider_timeout_budget_sec);
  Alcotest.(check (float 0.001))
    "remaining turn budget is telemetry only"
    0.0
    budget.remaining_turn_budget_sec

let test_provider_timeout_is_not_ambiguous_side_effect () =
  Alcotest.(check bool)
    "provider timeout is not ambiguous without committed tools"
    false
    (EC.is_ambiguous_side_effect_error
       (provider_timeout_error ~phase:"runtime_attempt_watchdog"))

let test_ambiguous_gate_requires_committed_tool_evidence () =
  Alcotest.(check bool)
    "provider timeout has no ambiguous commit evidence"
    false
    (EC.has_ambiguous_side_effect_commit
       ~tool_names:[]
       (provider_timeout_error ~phase:"runtime_attempt_watchdog"));
  Alcotest.(check bool)
    "legacy ambiguous string without committed tools has no gate evidence"
    false
    (EC.has_ambiguous_side_effect_commit
       ~tool_names:[]
       (legacy_ambiguous_internal_error ()));
  Alcotest.(check (list string))
    "structured ambiguous error carries mutating tool evidence"
    [ "keeper_board_post" ]
    (EC.ambiguous_side_effect_commit_tools
       ~tool_names:[]
       (ambiguous_post_commit_error ()))

let test_turn_timeout_is_not_ambiguous_side_effect () =
  Alcotest.(check bool)
    "turn timeout is not ambiguous without committed tools"
    false
    (EC.is_ambiguous_side_effect_error (turn_timeout_error ()))

let test_strike_limit_routes_through_policy_without_keeper_death () =
  let err = provider_timeout_error ~phase:"stream_idle:streaming_thinking" in
  match
    KH.provider_timeout_policy_decision
      ~strikes:KK.provider_timeout_strike_limit
      err
  with
  | None -> Alcotest.fail "expected provider timeout policy decision"
  | Some decision ->
    Alcotest.(check bool) "keeper death denied" false decision.keeper_death_allowed;
    Alcotest.(check string)
      "lifecycle"
      "pause_current_work"
      (KFP.lifecycle_effect_to_label decision.lifecycle_effect);
    Alcotest.(check string)
      "circuit"
      "provider_cooldown"
      (KFP.circuit_effect_to_label decision.circuit_effect);
    Alcotest.(check string)
      "reason preserves streaming thinking"
      "provider_timeout_loop:stream_idle:streaming_thinking"
      decision.reason

let test_capacity_phase_routes_to_provider_tuning () =
  let err = provider_timeout_error ~phase:"capacity_backpressure" in
  match KH.provider_timeout_policy_decision ~strikes:1 err with
  | None -> Alcotest.fail "expected provider timeout policy decision"
  | Some decision ->
    Alcotest.(check bool) "keeper death denied" false decision.keeper_death_allowed;
    Alcotest.(check string)
      "lifecycle"
      "soft_fail_turn"
      (KFP.lifecycle_effect_to_label decision.lifecycle_effect);
    Alcotest.(check string)
      "circuit"
      "provider_cooldown"
      (KFP.circuit_effect_to_label decision.circuit_effect);
    Alcotest.(check string)
      "operator action"
      "reroute_or_tune_provider"
      (KFP.operator_action_to_label decision.operator_action);
    Alcotest.(check string)
      "reason preserves capacity phase"
      "provider_timeout:capacity_backpressure"
      decision.reason

let test_concurrent_bumps_do_not_lose_updates () =
  let keeper = "parallel-bumps" in
  with_reset keeper (fun () ->
    let workers = 4 in
    let bumps_per_worker = 25 in
    let domains =
      List.init workers (fun _ ->
        Domain.spawn (fun () ->
          for _ = 1 to bumps_per_worker do
            ignore (KK.bump_budget_exhaustion ~keeper_name:keeper : int)
          done))
    in
    List.iter Domain.join domains;
    Alcotest.(check int) "all bumps accounted"
      (workers * bumps_per_worker)
      (KK.peek_budget_exhaustion_for_test ~keeper_name:keeper))

let source_path path =
  if Filename.is_relative path then
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> Filename.concat root path
    | None -> path
  else path

let read_file path = In_channel.with_open_text (source_path path) In_channel.input_all

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if needle_len = 0 then true
    else if index + needle_len > haystack_len then false
    else if String.sub haystack index needle_len = needle then true
    else loop (index + 1)
  in
  loop 0

let test_keeper_turn_has_no_total_wall_clock_kill () =
  let source = read_file "lib/keeper/keeper_unified_turn_execution.ml" in
  Alcotest.(check bool)
    "no cumulative keeper turn with_timeout"
    false
    (contains_substring source "Eio.Time.with_timeout_exn clock timeout_sec")

let test_keeper_oas_path_has_no_bridge_total_timeout () =
  let source = read_file "lib/keeper/keeper_agent_run.ml" in
  Alcotest.(check bool)
    "keeper run_named path is not bridge-timeout wrapped"
    false
    (contains_substring source "Keeper_llm_bridge.run_with_timeout_and_fallback")

let test_runtime_provider_path_has_no_cumulative_run_timeout () =
  let source = read_file "lib/keeper/keeper_turn_driver_try_provider.ml" in
  Alcotest.(check bool)
    "runtime provider path does not timeout Runtime_agent.run"
    false
    (contains_substring source "Eio.Time.with_timeout_exn clock t run_fn")

let test_runtime_provider_path_does_not_forward_execution_idle_timeout () =
  let source = read_file "lib/keeper/keeper_turn_driver_try_provider.ml" in
  Alcotest.(check bool)
    "runtime provider path does not forward execution idle timeout"
    false
    (contains_substring source "execution_idle_timeout_s = ctx.execution_idle_timeout_s")

let test_preflight_context_window_allows_exact_budget () =
  match
    Keeper_run_prompt.preflight_context_window
      ~estimated_input_tokens:131_072
      ~max_context:131_072
  with
  | Ok () -> ()
  | Error err ->
    Alcotest.fail
      ("expected exact-budget context preflight to pass, got "
       ^ Agent_sdk.Error.to_string err)

let test_preflight_context_window_reports_overflow_signal () =
  match
    Keeper_run_prompt.preflight_context_window
      ~estimated_input_tokens:131_073
      ~max_context:131_072
  with
  | Ok () -> Alcotest.fail "expected oversized context preflight to report overflow"
  | Error
      (Agent_sdk.Error.Api
         (Llm_provider.Retry.ContextOverflow { message; limit })) ->
    Alcotest.(check (option int)) "overflow limit" (Some 131_072) limit;
    Alcotest.(check bool)
      "overflow message marks pre-dispatch source"
      true
      (contains_substring
         message
         "pre-dispatch input estimate exceeds context window")
  | Error err ->
    Alcotest.fail
      ("expected pre-dispatch ContextOverflow, got "
       ^ Agent_sdk.Error.to_string err)

let test_preflight_context_window_rejects_nonpositive_max_context () =
  match
    Keeper_run_prompt.preflight_context_window
      ~estimated_input_tokens:1
      ~max_context:0
  with
  | Ok () -> Alcotest.fail "expected non-positive max_context to fail closed"
  | Error
      (Agent_sdk.Error.Config
         (Agent_sdk.Error.InvalidConfig { field = "max_context"; detail })) ->
    Alcotest.(check bool)
      "invalid config detail names non-positive context window"
      true
      (contains_substring detail "must be positive")
  | Error err ->
    Alcotest.fail
      ("expected invalid max_context config error, got "
       ^ Agent_sdk.Error.to_string err)

let make_tool name description : Agent_sdk.Tool.t =
  Agent_sdk.Tool.create ~name ~description ~parameters:[]
    (fun _input -> Ok { Agent_sdk.Types.content = "ok"; _meta = None })

let test_tool_schema_estimate_adds_provider_payload () =
  let tool = make_tool "large_schema_probe" (String.make 2048 'd') in
  let estimate =
    Keeper_run_prompt.estimate_tool_schema_context
      ~estimated_input_tokens:10
      ~tools:[ tool ]
  in
  Alcotest.(check int) "tool count" 1 estimate.tool_count;
  Alcotest.(check bool)
    "tool schema contributes tokens"
    true
    (estimate.tool_schema_tokens > 0);
  Alcotest.(check int)
    "tool-inclusive estimate is prompt estimate plus schema"
    (10 + estimate.tool_schema_tokens)
    estimate.estimated_input_tokens_with_tools;
  match
    Keeper_run_prompt.preflight_context_window
      ~estimated_input_tokens:estimate.estimated_input_tokens_with_tools
      ~max_context:(estimate.estimated_input_tokens_with_tools - 1)
  with
  | Error
      (Agent_sdk.Error.Api
         (Llm_provider.Retry.ContextOverflow { limit = Some _; _ })) ->
    ()
  | Ok () ->
    Alcotest.fail "expected tool-inclusive over-budget request to fail"
  | Error err ->
    Alcotest.fail
      ("expected tool-inclusive ContextOverflow, got "
       ^ Agent_sdk.Error.to_string err)

let test_hook_context_estimate_skips_base_prompt_layers () =
  let dynamic = String.make 400 'd' in
  let temporal = String.make 400 't' in
  let retry = String.make 400 'r' in
  let user_model = String.make 400 'u' in
  let expected =
    Agent_sdk.Context_reducer.estimate_char_tokens retry
    + Agent_sdk.Context_reducer.estimate_char_tokens user_model
  in
  Alcotest.(check int)
    "only hook-only blocks are added to the post-hook estimate"
    expected
    (Keeper_run_prompt.estimate_unaccounted_extra_system_context_tokens
       ~preflight_accounted_blocks:
         [ Prompt_block_id.Dynamic_context; Prompt_block_id.Temporal_summary ]
       [ Prompt_block_id.Dynamic_context, dynamic
       ; Prompt_block_id.Temporal_summary, temporal
       ; Prompt_block_id.Retry_nudge, retry
       ; Prompt_block_id.User_model, user_model
       ])

let test_extra_system_context_budget_skips_over_window_hook_blocks () =
  let budget =
    Keeper_run_prompt.budget_extra_system_context
      ~estimated_input_tokens_with_tools:90
      ~max_context:100
      ~existing_extra_system_context:None
      ~preflight_accounted_blocks:[ Prompt_block_id.Dynamic_context ]
      ~blocks:
        [ Prompt_block_id.Dynamic_context, String.make 400 'd'
        ; Prompt_block_id.Retry_nudge, String.make 400 'r'
        ; Prompt_block_id.User_model, "short user model"
        ]
  in
  Alcotest.(check bool)
    "dynamic context remains because preflight already accounted it"
    true
    (List.exists
       (fun (block, _) ->
          Prompt_block_id.equal block Prompt_block_id.Dynamic_context)
       budget.included_blocks);
  Alcotest.(check bool)
    "oversized hook-only retry nudge is skipped"
    true
    (List.exists
       (Prompt_block_id.equal Prompt_block_id.Retry_nudge)
       budget.skipped_blocks);
  Alcotest.(check bool)
    "later hook-only block can still fit"
    true
    (List.exists
       (fun (block, _) -> Prompt_block_id.equal block Prompt_block_id.User_model)
       budget.included_blocks);
  Alcotest.(check bool)
    "post-hook estimate stays within context window"
    true
    (budget.post_hook_estimated_input_tokens <= 100)

let test_extra_system_context_budget_accounts_assembled_overhead () =
  let dynamic = String.make 40 'd' in
  let hook_only = String.make 40 'u' in
  let budget =
    Keeper_run_prompt.budget_extra_system_context
      ~estimated_input_tokens_with_tools:10
      ~max_context:1_000
      ~existing_extra_system_context:None
      ~preflight_accounted_blocks:[ Prompt_block_id.Dynamic_context ]
      ~blocks:
        [ Prompt_block_id.Dynamic_context, dynamic
        ; Prompt_block_id.User_model, hook_only
        ]
  in
  let assembled =
    match budget.extra_system_context with
    | Some text -> text
    | None -> Alcotest.fail "expected assembled extra_system_context"
  in
  let assembled_tokens =
    Agent_sdk.Context_reducer.estimate_char_tokens assembled
  in
  let preflight_accounted_tokens =
    Agent_sdk.Context_reducer.estimate_char_tokens dynamic
  in
  Alcotest.(check int)
    "post-hook estimate accounts assembled context minus preflight-accounted blocks"
    (10 + max 0 (assembled_tokens - preflight_accounted_tokens))
    budget.post_hook_estimated_input_tokens

let test_keeper_preflight_wires_tool_inclusive_estimate () =
  let agent_run_source = read_file "lib/keeper/keeper_agent_run.ml" in
  let setup_source = read_file "lib/keeper/keeper_run_tools_setup.ml" in
  Alcotest.(check bool)
    "keeper computes tool schema context estimate"
    true
    (contains_substring setup_source "estimate_tool_schema_context");
  Alcotest.(check bool)
    "keeper preflight uses tool-inclusive estimate"
    true
    (contains_substring agent_run_source "estimated_input_tokens_with_tools");
  Alcotest.(check bool)
    "keeper writes context preflight manifest"
    true
    (contains_substring agent_run_source "context_preflight")

let test_context_window_budget_reports_remaining_and_overage () =
  let within =
    Keeper_run_prompt.context_window_budget
      ~estimated_input_tokens:100
      ~max_context:128
  in
  Alcotest.(check int) "remaining under window" 28 within.remaining_context_tokens;
  Alcotest.(check int) "overage under window" 0 within.over_context_tokens;
  Alcotest.(check (float 0.0001))
    "ratio under window"
    (100.0 /. 128.0)
    within.context_usage_ratio;
  let over =
    Keeper_run_prompt.context_window_budget
      ~estimated_input_tokens:140
      ~max_context:128
  in
  Alcotest.(check int) "remaining over window" 0 over.remaining_context_tokens;
  Alcotest.(check int) "overage over window" 12 over.over_context_tokens;
  Alcotest.(check (float 0.0001))
    "ratio over window"
    (140.0 /. 128.0)
    over.context_usage_ratio

let test_context_layer_budget_records_decisions () =
  let kept =
    Keeper_run_prompt.estimate_context_layer_budget
      ~layer_name:"pending_mentions"
      ~priority:"high"
      ~cap_tokens:64
      ~text:"short mention"
  in
  Alcotest.(check string) "kept layer name" "pending_mentions"
    kept.context_layer_name;
  Alcotest.(check string) "kept priority" "high" kept.context_layer_priority;
  Alcotest.(check bool) "kept decision" true
    (kept.context_layer_decision = Keeper_run_prompt.Within_cap);
  let over_cap =
    Keeper_run_prompt.estimate_context_layer_budget
      ~layer_name:"board_activity"
      ~priority:"normal"
      ~cap_tokens:1
      ~text:(String.make 200 'b')
  in
  Alcotest.(check bool) "over-cap decision" true
    (over_cap.context_layer_decision = Keeper_run_prompt.Over_cap_observed);
  Alcotest.(check int) "over-cap would-fit tokens equals cap" 1
    over_cap.context_layer_would_fit_tokens;
  let empty =
    Keeper_run_prompt.estimate_context_layer_budget
      ~layer_name:"continuity_summary"
      ~priority:"required"
      ~cap_tokens:64
      ~text:""
  in
  Alcotest.(check bool) "empty layer decision" true
    (empty.context_layer_decision = Keeper_run_prompt.Empty);
  (match Keeper_run_prompt.context_layer_budget_to_json over_cap with
   | `Assoc fields ->
     Alcotest.(check bool)
       "json carries decision"
       true
       (List.assoc_opt "decision" fields = Some (`String "over_cap_observed"));
     Alcotest.(check bool)
       "json marks diagnostic semantics"
       true
       (List.assoc_opt "semantics" fields = Some (`String "diagnostic_only"));
     Alcotest.(check bool)
       "json carries would-fit tokens, not kept/truncated claim"
       true
       (List.assoc_opt "would_fit_tokens" fields = Some (`Int 1)
        && List.assoc_opt "budgeted_tokens" fields = None
        && List.assoc_opt "kept_tokens" fields = None)
   | _ -> Alcotest.fail "expected context layer budget JSON object")

let test_context_layer_policy_caps_are_typed () =
  let budget policy text =
    Keeper_run_prompt.estimate_context_layer_policy_budget
      ~max_context:160
      ~policy
      ~text
  in
  let dynamic =
    budget Keeper_run_prompt.world_dynamic_context_layer_policy "dynamic"
  in
  Alcotest.(check string)
    "dynamic policy name"
    "world_dynamic_context"
    dynamic.context_layer_name;
  Alcotest.(check string) "dynamic priority" "high" dynamic.context_layer_priority;
  Alcotest.(check int) "dynamic cap" 40 dynamic.context_layer_cap_tokens;
  let memory = budget Keeper_run_prompt.memory_context_layer_policy "memory" in
  Alcotest.(check int) "memory cap" 20 memory.context_layer_cap_tokens;
  let temporal =
    budget Keeper_run_prompt.temporal_context_layer_policy "temporal"
  in
  Alcotest.(check int) "temporal cap" 10 temporal.context_layer_cap_tokens;
  let user =
    budget Keeper_run_prompt.user_message_context_layer_policy "user"
  in
  Alcotest.(check int) "user cap" 160 user.context_layer_cap_tokens

let test_context_preflight_manifest_records_budget_delta () =
  let source = read_file "lib/keeper/keeper_agent_run.ml" in
  Alcotest.(check bool)
    "context preflight records remaining tokens"
    true
    (contains_substring source "remaining_context_tokens");
  Alcotest.(check bool)
    "context preflight records overage tokens"
    true
    (contains_substring source "over_context_tokens");
  Alcotest.(check bool)
    "context preflight records usage ratio"
    true
    (contains_substring source "context_usage_ratio");
  Alcotest.(check bool)
    "context preflight records context layer budgets"
    true
    (contains_substring source "context_layers")

let test_context_injection_hook_records_post_tool_ledger () =
  let agent_run_source = read_file "lib/keeper/keeper_agent_run.ml" in
  Alcotest.(check bool)
    "agent run passes runtime manifest append into hooks"
    true
    (contains_substring agent_run_source "context_injection_hook");
  let hook_source = read_file "lib/keeper/keeper_run_tools_hooks.ml" in
  Alcotest.(check bool)
    "hook emits context injected manifest"
    true
    (contains_substring hook_source "Keeper_runtime_manifest.Context_injected");
  Alcotest.(check bool)
    "hook distinguishes post-tool context injection"
    true
    (contains_substring hook_source "post_tool_context_injection");
  Alcotest.(check bool)
    "hook records last tool result count"
    true
    (contains_substring hook_source "last_tool_result_count");
  Alcotest.(check bool)
    "hook records extra system context token estimate"
    true
    (contains_substring hook_source "extra_system_context_estimated_tokens");
  Alcotest.(check bool)
    "hook gates post-hook context against context window"
    true
    (contains_substring hook_source "post_hook_estimated_input_tokens");
  Alcotest.(check bool)
    "hook budgets extra context before params are adjusted"
    true
    (contains_substring hook_source "budget_extra_system_context"
     && contains_substring hook_source "Agent_sdk.Hooks.AdjustParams");
  Alcotest.(check bool)
    "hook records skipped context blocks instead of silently dropping them"
    true
    (contains_substring hook_source "skipped_extra_system_context_blocks"
     && contains_substring hook_source
          "skipped_extra_system_context_estimated_tokens");
  Alcotest.(check bool)
    "hook does not use an out-of-band overflow ref"
    false
    (contains_substring hook_source "post_hook_context_window_error_ref"
     || contains_substring agent_run_source "post_hook_context_window_error_ref")

let test_keeper_preflight_reuses_setup_tool_estimate () =
  let agent_run_source = read_file "lib/keeper/keeper_agent_run.ml" in
  Alcotest.(check bool)
    "keeper run reads setup tool estimate"
    true
    (contains_substring agent_run_source "s.Keeper_run_tools.tool_context_estimate");
  Alcotest.(check bool)
    "keeper run does not recompute tool schemas"
    false
    (contains_substring agent_run_source "estimate_tool_schema_context")

let test_keeper_budget_estimates_use_context_facade () =
  let prompt_source = read_file "lib/keeper/keeper_run_prompt.ml" in
  let hook_source = read_file "lib/keeper/keeper_run_tools_hooks.ml" in
  Alcotest.(check bool)
    "budgeting uses keeper estimation facade"
    true
    (contains_substring prompt_source
       "Keeper_context_core_accessors.estimate_char_tokens"
     && contains_substring hook_source
          "Keeper_context_core_accessors.estimate_char_tokens");
  Alcotest.(check bool)
    "budgeting avoids direct OAS estimator calls"
    false
    (contains_substring prompt_source
       "Agent_sdk.Context_reducer.estimate_char_tokens"
     || contains_substring hook_source
          "Agent_sdk.Context_reducer.estimate_char_tokens")

let checkpoint_hygiene_meta () =
  match
    Keeper_meta_json_parse.meta_of_json
      (`Assoc
        [ "name", `String "checkpoint-hygiene"
        ; "agent_name", `String "checkpoint-hygiene"
        ; "trace_id", `String "trace-checkpoint-hygiene"
        ; "last_model_used", `String "ollama_cloud.stalecontext"
        ; "tool_access", `List []
        ])
  with
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)
  | Ok meta ->
    { meta with
      compaction =
        { meta.compaction with
          ratio_gate = 0.5
        ; message_gate = 999
        ; token_gate = 0
        ; cooldown_sec = 999
        ; max_checkpoint_messages = 32
        }
    }

let text_message ?(role = Agent_sdk.Types.User) text : Agent_sdk.Types.message =
  { role; content = [ Agent_sdk.Types.text_block text ]; name = None; tool_call_id = None; metadata = [] }

let checkpoint_context ~max_context =
  Keeper_context_runtime.create ~eio:false ~system_prompt:"checkpoint hygiene test"
    ~max_tokens:max_context
  |> fun ctx ->
  Keeper_context_runtime.append
    ctx
    (text_message (String.make 320_000 'x'))

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

let runtime_fixture =
  {|
[runtime]
default = "ollama_cloud.stalecontext"

[providers.ollama_cloud]
display-name = "Ollama Cloud"
protocol = "openai-compatible-http"
endpoint = "https://ollama.example/v1"

[models.stalecontext]
api-name = "qwen36-35b-a3b-mtp"
max-context = 524288
tools-support = true
thinking-support = true
streaming = true

[ollama_cloud.stalecontext]
max-concurrent = 1
|}

let with_runtime_fixture f =
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "checkpoint-hygiene-runtime" ".toml" in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      try Sys.remove path with
      | _ -> ())
    (fun () ->
      write_file path runtime_fixture;
      match Runtime.init_default ~config_path:path with
      | Error msg -> Alcotest.fail ("Runtime.init_default failed: " ^ msg)
      | Ok () -> f ())

let run_checkpoint_hygiene ~save_called ~meta ctx =
  Keeper_agent_checkpoint_hygiene.prepare_resume_checkpoint_for_dispatch
    ~meta
    ~now_ts:1_000.0
    ~loaded_checkpoint_present:true
    ~save_checkpoint:(fun compacted_ctx ->
      save_called := true;
      Ok
        (Keeper_context_runtime.resume_checkpoint_of_context
           ~max_checkpoint_messages:meta.Keeper_meta_contract.compaction.max_checkpoint_messages
           compacted_ctx))
    ctx

let test_pre_dispatch_rebudgets_checkpoint_against_smaller_window () =
  with_runtime_fixture @@ fun () ->
  let meta = checkpoint_hygiene_meta () in
  let large_save_called = ref false in
  let large_ctx = checkpoint_context ~max_context:524_288 in
  let large =
    run_checkpoint_hygiene ~save_called:large_save_called ~meta large_ctx
  in
  Alcotest.(check bool)
    "same checkpoint stays below large-window ratio"
    false
    large.Keeper_agent_checkpoint_hygiene.applied;
  Alcotest.(check bool)
    "large-window skip does not persist a compacted checkpoint"
    false
    !large_save_called;
  let small_save_called = ref false in
  let small_ctx = Keeper_context_runtime.with_max_tokens large_ctx 131_072 in
  let small =
    run_checkpoint_hygiene ~save_called:small_save_called ~meta small_ctx
  in
  Alcotest.(check bool)
    "same checkpoint compacts after smaller-window rebudget"
    true
    small.Keeper_agent_checkpoint_hygiene.applied;
  Alcotest.(check bool)
    "small-window compaction persists the compacted checkpoint"
    true
    !small_save_called;
  Alcotest.(check bool)
    "small-window hygiene records over-budget starting point"
    true
    (small.before_tokens > (131_072 / 2));
  Alcotest.(check int)
    "compacted context keeps smaller provider window"
    131_072
    (Keeper_context_runtime.max_tokens_of_context small.context)

let test_keeper_passes_context_window_to_oas_thresholds () =
  let source = read_file "lib/keeper/keeper_agent_run.ml" in
  Alcotest.(check bool)
    "keeper run_named receives effective max_context as context window"
    true
    (contains_substring source "~context_window_tokens:max_context")

let test_oas_thresholds_do_not_use_output_max_tokens_as_context_window () =
  let source = read_file "lib/runtime/runtime_agent_context.ml" in
  Alcotest.(check bool)
    "thresholds use explicit context_window_tokens"
    true
    (contains_substring source "match config.context_window_tokens with");
  Alcotest.(check bool)
    "output max_tokens is not reused as context window"
    false
    (contains_substring source "~context_window_tokens:config.max_tokens")

let () =
  Alcotest.run "provider_timeout_strike"
  [
    ( "strike ledger",
      [
        Alcotest.test_case "seeded bump increments" `Quick
          test_seeded_bump_increments_from_prior;
        Alcotest.test_case "in-process bump accumulates" `Quick
          test_in_process_bump_accumulates;
        Alcotest.test_case "seeded bump uses higher persisted count" `Quick
          test_seeded_bump_uses_higher_persisted_count;
        Alcotest.test_case "reset clears" `Quick test_reset_clears;
        Alcotest.test_case "strike limit soft-backoffs without crash" `Quick
          test_strike_limit_is_soft_backoff;
        Alcotest.test_case "cycle failure log level is policy-aware" `Quick
          test_cycle_failed_log_level_is_policy_aware;
        Alcotest.test_case "raw OAS provider timeout uses same policy" `Quick
          test_raw_oas_provider_timeout_uses_same_policy;
        Alcotest.test_case "raw OAS API timeout uses same policy" `Quick
          test_raw_oas_api_timeout_uses_same_policy;
        Alcotest.test_case "TLS handshake internal error is transient" `Quick
          test_tls_handshake_internal_error_is_transient;
        Alcotest.test_case
          "retry timeout budget ignores expired outer turn budget"
          `Quick
          test_retry_timeout_budget_ignores_expired_outer_turn_budget;
        Alcotest.test_case
          "first attempt timeout ignores expired outer turn budget"
          `Quick
          test_first_attempt_timeout_ignores_expired_outer_turn_budget;
        Alcotest.test_case
          "provider timeout is not ambiguous partial commit"
          `Quick
          test_provider_timeout_is_not_ambiguous_side_effect;
        Alcotest.test_case
          "ambiguous gate requires committed tool evidence"
          `Quick
          test_ambiguous_gate_requires_committed_tool_evidence;
        Alcotest.test_case
          "turn timeout is not ambiguous partial commit"
          `Quick
          test_turn_timeout_is_not_ambiguous_side_effect;
        Alcotest.test_case "strike limit uses policy, not keeper death" `Quick
          test_strike_limit_routes_through_policy_without_keeper_death;
        Alcotest.test_case "capacity phase routes to provider tuning" `Quick
          test_capacity_phase_routes_to_provider_tuning;
        Alcotest.test_case "concurrent bumps do not lose updates" `Quick
          test_concurrent_bumps_do_not_lose_updates;
        Alcotest.test_case "keeper turn has no total wall-clock kill" `Quick
          test_keeper_turn_has_no_total_wall_clock_kill;
        Alcotest.test_case "keeper OAS path has no bridge total timeout" `Quick
          test_keeper_oas_path_has_no_bridge_total_timeout;
        Alcotest.test_case "runtime provider path has no cumulative timeout" `Quick
          test_runtime_provider_path_has_no_cumulative_run_timeout;
        Alcotest.test_case "runtime provider path does not forward idle timeout" `Quick
          test_runtime_provider_path_does_not_forward_execution_idle_timeout;
        Alcotest.test_case "preflight context window allows exact budget" `Quick
          test_preflight_context_window_allows_exact_budget;
        Alcotest.test_case "preflight context window reports overflow signal" `Quick
          test_preflight_context_window_reports_overflow_signal;
        Alcotest.test_case "preflight context window rejects invalid max" `Quick
          test_preflight_context_window_rejects_nonpositive_max_context;
        Alcotest.test_case "tool schema estimate adds provider payload" `Quick
          test_tool_schema_estimate_adds_provider_payload;
        Alcotest.test_case
          "hook context estimate skips base prompt layers"
          `Quick
          test_hook_context_estimate_skips_base_prompt_layers;
        Alcotest.test_case "extra system context budget skips overflow blocks" `Quick
          test_extra_system_context_budget_skips_over_window_hook_blocks;
        Alcotest.test_case
          "extra system context budget accounts assembled overhead"
          `Quick
          test_extra_system_context_budget_accounts_assembled_overhead;
        Alcotest.test_case "keeper preflight wires tool-inclusive estimate" `Quick
          test_keeper_preflight_wires_tool_inclusive_estimate;
        Alcotest.test_case "context window budget reports remaining and overage" `Quick
          test_context_window_budget_reports_remaining_and_overage;
        Alcotest.test_case "context layer budget records decisions" `Quick
          test_context_layer_budget_records_decisions;
        Alcotest.test_case "context layer policy caps are typed" `Quick
          test_context_layer_policy_caps_are_typed;
        Alcotest.test_case "context preflight manifest records budget delta" `Quick
          test_context_preflight_manifest_records_budget_delta;
        Alcotest.test_case "context injection hook records post-tool ledger" `Quick
          test_context_injection_hook_records_post_tool_ledger;
        Alcotest.test_case "keeper preflight reuses setup tool estimate" `Quick
          test_keeper_preflight_reuses_setup_tool_estimate;
        Alcotest.test_case "keeper budget estimates use context facade" `Quick
          test_keeper_budget_estimates_use_context_facade;
        Alcotest.test_case
          "pre-dispatch hygiene rebudgets checkpoint against smaller window"
          `Quick
          test_pre_dispatch_rebudgets_checkpoint_against_smaller_window;
        Alcotest.test_case "keeper passes context window to OAS thresholds" `Quick
          test_keeper_passes_context_window_to_oas_thresholds;
        Alcotest.test_case "OAS thresholds keep output max_tokens separate" `Quick
          test_oas_thresholds_do_not_use_output_max_tokens_as_context_window;
      ] );
  ]
