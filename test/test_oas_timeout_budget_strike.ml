open Masc

module KPB = Keeper_provider_runtime_boundary
module KCB = Keeper_turn_runtime_budget
module KTD = Keeper_turn_driver
module EC = Keeper_error_classify

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


let test_cycle_failed_log_level_uses_typed_error () =
  Alcotest.(check bool)
    "provider timeout cycle failure is warn"
    true
    (EC.should_warn_keeper_cycle_failed
       (provider_timeout_error ~phase:"runtime_attempt_watchdog"));
  Alcotest.(check bool)
    "turn timeout remains error"
    false
    (EC.should_warn_keeper_cycle_failed (turn_timeout_error ()))

let test_raw_oas_provider_timeout_preserves_typed_observation () =
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
  match KPB.classify_sdk_error err with
  | KPB.Provider_timeout
      { source = KPB.Oas_provider
      ; phase = Some (KPB.Stream_idle KPB.Streaming_thinking)
      } -> ()
  | _ -> Alcotest.fail "expected typed OAS streaming-thinking timeout observation"

let test_raw_oas_api_timeout_preserves_typed_observation () =
  let err = raw_api_timeout_error () in
  Alcotest.(check bool)
    "raw API timeout is a provider timeout"
    true
    (EC.is_provider_timeout_error err);
  match KPB.classify_sdk_error err with
  | KPB.Provider_timeout { source = KPB.Oas_api; phase = None } -> ()
  | _ -> Alcotest.fail "expected typed phase-free OAS API timeout observation"

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
    KCB.resolve_provider_timeout_budget
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
    KCB.resolve_provider_timeout_budget
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

let test_internal_timeout_preserves_typed_stream_phase () =
  let err = provider_timeout_error ~phase:"stream_idle:streaming_thinking" in
  match KPB.classify_sdk_error err with
  | KPB.Provider_timeout
      { source = KPB.Masc_internal
      ; phase = Some (KPB.Stream_idle KPB.Streaming_thinking)
      } -> ()
  | _ -> Alcotest.fail "expected typed internal streaming-thinking observation"

let test_capacity_phase_is_a_typed_observation () =
  let err = provider_timeout_error ~phase:"capacity_backpressure" in
  match KPB.classify_sdk_error err with
  | KPB.Provider_timeout
      { source = KPB.Masc_internal; phase = Some KPB.Capacity_backpressure } -> ()
  | _ -> Alcotest.fail "expected typed capacity observation"

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
    estimate.estimated_input_tokens_with_tools

let test_hook_context_estimate_skips_base_prompt_layers () =
  let dynamic = String.make 400 'd' in
  let temporal = String.make 400 't' in
  let retry = String.make 400 'r' in
  let connected_surface = String.make 400 'u' in
  let expected =
    Agent_sdk.Context_reducer.estimate_char_tokens retry
    + Agent_sdk.Context_reducer.estimate_char_tokens connected_surface
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
       ; Prompt_block_id.Connected_surface, connected_surface
       ])

let test_extra_system_context_assembly_preserves_over_window_blocks () =
  let assembly =
    Keeper_run_prompt.assemble_extra_system_context
      ~estimated_input_tokens_with_tools:90
      ~max_context:100
      ~existing_extra_system_context:None
      ~preflight_accounted_blocks:[ Prompt_block_id.Dynamic_context ]
      ~blocks:
        [ Prompt_block_id.Dynamic_context, String.make 400 'd'
        ; Prompt_block_id.Retry_nudge, String.make 400 'r'
        ; Prompt_block_id.Connected_surface, "short connected surface"
        ]
  in
  Alcotest.(check bool)
    "dynamic context remains because preflight already accounted it"
    true
    (List.exists
       (fun (block, _) ->
          Prompt_block_id.equal block Prompt_block_id.Dynamic_context)
       assembly.blocks);
  Alcotest.(check bool)
    "oversized hook-only retry nudge is preserved"
    true
    (List.exists
       (fun (block, _) -> Prompt_block_id.equal block Prompt_block_id.Retry_nudge)
       assembly.blocks);
  Alcotest.(check bool)
    "later hook-only block can still fit"
    true
    (List.exists
       (fun (block, _) -> Prompt_block_id.equal block Prompt_block_id.Connected_surface)
       assembly.blocks);
  Alcotest.(check int) "every complete block reaches OAS" 3
    (List.length assembly.blocks);
  let assembled =
    match assembly.extra_system_context with
    | Some text -> text
    | None -> Alcotest.fail "expected complete extra_system_context"
  in
  Alcotest.(check string)
    "complete block text and source order reach OAS"
    (String.make 400 'd'
     ^ "\n\n"
     ^ String.make 400 'r'
     ^ "\n\nshort connected surface")
    assembled;
  Alcotest.(check bool)
    "over-window estimate remains observational"
    true
    (assembly.post_hook_context_window_observation
       .observed_over_context_tokens
     > 0)

let test_extra_system_context_assembly_accounts_assembled_overhead () =
  let dynamic = String.make 40 'd' in
  let hook_only = String.make 40 'u' in
  let assembly =
    Keeper_run_prompt.assemble_extra_system_context
      ~estimated_input_tokens_with_tools:10
      ~max_context:1_000
      ~existing_extra_system_context:None
      ~preflight_accounted_blocks:[ Prompt_block_id.Dynamic_context ]
      ~blocks:
        [ Prompt_block_id.Dynamic_context, dynamic
        ; Prompt_block_id.Connected_surface, hook_only
        ]
  in
  let assembled =
    match assembly.extra_system_context with
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
    assembly.post_hook_estimated_input_tokens

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

let test_context_window_observation_reports_remaining_and_overage () =
  let within =
    Keeper_run_prompt.observe_context_window
      ~estimated_input_tokens:100
      ~max_context:128
  in
  Alcotest.(check int) "remaining under window" 28
    within.observed_remaining_context_tokens;
  Alcotest.(check int) "overage under window" 0
    within.observed_over_context_tokens;
  Alcotest.(check (float 0.0001))
    "ratio under window"
    (100.0 /. 128.0)
    within.observed_context_usage_ratio;
  let over =
    Keeper_run_prompt.observe_context_window
      ~estimated_input_tokens:140
      ~max_context:128
  in
  Alcotest.(check int) "remaining over window" 0
    over.observed_remaining_context_tokens;
  Alcotest.(check int) "overage over window" 12
    over.observed_over_context_tokens;
  Alcotest.(check (float 0.0001))
    "ratio over window"
    (140.0 /. 128.0)
    over.observed_context_usage_ratio

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
    "context preflight has no layer priority or fractional cap policy"
    false
    (contains_substring source "context_layers"
     || contains_substring source "context_layer_policy")

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
    "hook observes post-hook context against context window"
    true
    (contains_substring hook_source "post_hook_estimated_input_tokens");
  Alcotest.(check bool)
    "hook assembles all extra context before params are adjusted"
    true
    (contains_substring hook_source "assemble_extra_system_context"
     && contains_substring hook_source "Agent_sdk.Hooks.AdjustParams");
  Alcotest.(check bool)
    "hook has no skipped-block authority"
    false
    (contains_substring hook_source "skipped_extra_system_context_blocks"
     || contains_substring hook_source "skipped_blocks");
  Alcotest.(check bool)
    "MASC reducer does not prune Keeper context by local numeric policy"
    false
    (contains_substring hook_source "Context_reducer.drop_thinking"
     || contains_substring hook_source "Context_reducer.stub_tool_results"
     || contains_substring hook_source "Context_reducer.prune_tool_outputs"
     || contains_substring hook_source "Context_reducer.cap_message_tokens");
  Alcotest.(check bool)
    "hook does not rewrite thinking budget or inject retry advice heuristics"
    false
    (contains_substring hook_source "adaptive_thinking_budget"
     || contains_substring hook_source "[RETRY]");
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
  Alcotest.run "provider_timeout_observation"
  [
    ( "strike ledger",
      [
        Alcotest.test_case "cycle failure log level uses typed error" `Quick
          test_cycle_failed_log_level_uses_typed_error;
        Alcotest.test_case "raw OAS provider timeout remains typed" `Quick
          test_raw_oas_provider_timeout_preserves_typed_observation;
        Alcotest.test_case "raw OAS API timeout remains typed" `Quick
          test_raw_oas_api_timeout_preserves_typed_observation;
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
        Alcotest.test_case "internal timeout stream phase remains typed" `Quick
          test_internal_timeout_preserves_typed_stream_phase;
        Alcotest.test_case "capacity phase remains a typed observation" `Quick
          test_capacity_phase_is_a_typed_observation;
        Alcotest.test_case "keeper turn has no total wall-clock kill" `Quick
          test_keeper_turn_has_no_total_wall_clock_kill;
        Alcotest.test_case "keeper OAS path has no bridge total timeout" `Quick
          test_keeper_oas_path_has_no_bridge_total_timeout;
        Alcotest.test_case "runtime provider path has no cumulative timeout" `Quick
          test_runtime_provider_path_has_no_cumulative_run_timeout;
        Alcotest.test_case "runtime provider path does not forward idle timeout" `Quick
          test_runtime_provider_path_does_not_forward_execution_idle_timeout;
        Alcotest.test_case "tool schema estimate adds provider payload" `Quick
          test_tool_schema_estimate_adds_provider_payload;
        Alcotest.test_case
          "hook context estimate skips base prompt layers"
          `Quick
          test_hook_context_estimate_skips_base_prompt_layers;
        Alcotest.test_case "extra system context preserves overflow blocks" `Quick
          test_extra_system_context_assembly_preserves_over_window_blocks;
        Alcotest.test_case
          "extra system context assembly accounts overhead"
          `Quick
          test_extra_system_context_assembly_accounts_assembled_overhead;
        Alcotest.test_case "keeper preflight wires tool-inclusive estimate" `Quick
          test_keeper_preflight_wires_tool_inclusive_estimate;
        Alcotest.test_case
          "context window observation reports remaining and overage"
          `Quick
          test_context_window_observation_reports_remaining_and_overage;
        Alcotest.test_case "context preflight manifest records budget delta" `Quick
          test_context_preflight_manifest_records_budget_delta;
        Alcotest.test_case "context injection hook records post-tool ledger" `Quick
          test_context_injection_hook_records_post_tool_ledger;
        Alcotest.test_case "keeper preflight reuses setup tool estimate" `Quick
          test_keeper_preflight_reuses_setup_tool_estimate;
        Alcotest.test_case "keeper budget estimates use context facade" `Quick
          test_keeper_budget_estimates_use_context_facade;
        Alcotest.test_case "keeper passes context window to OAS thresholds" `Quick
          test_keeper_passes_context_window_to_oas_thresholds;
        Alcotest.test_case "OAS thresholds keep output max_tokens separate" `Quick
          test_oas_thresholds_do_not_use_output_max_tokens_as_context_window;
      ] );
  ]
