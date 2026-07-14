open Masc

module KPB = Keeper_provider_runtime_boundary
module KTD = Keeper_turn_driver
module EC = Keeper_error_classify

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

let tls_handshake_internal_error () =
  KTD.sdk_error_of_masc_internal_error
    (KTD.Internal_unhandled_exception
       { site = KTD.runtime_runner_execute_site
       ; exn_repr = "TLS alert from peer: handshake failure"
       ; transport_error_kind = Some Llm_provider.Http_client.Tls_error
       })


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

let test_extra_system_context_preserves_typed_blocks () =
  let blocks =
    [ Prompt_block_id.Dynamic_context, "dynamic"
    ; Prompt_block_id.Retry_nudge, "retry"
    ; Prompt_block_id.Connected_surface, "surface"
    ]
  in
  let assembly =
    Keeper_run_prompt.assemble_extra_system_context
      ~existing_extra_system_context:(Some "existing")
      ~blocks
  in
  Alcotest.(check bool) "typed blocks unchanged" true (assembly.blocks = blocks);
  Alcotest.(check (option string))
    "complete source order reaches OAS"
    (Some "existing\n\ndynamic\n\nretry\n\nsurface")
    assembly.extra_system_context

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

let () =
  Alcotest.run "keeper_runtime_observation_boundaries"
  [
    ( "typed observations",
      [
        Alcotest.test_case "raw OAS provider timeout remains typed" `Quick
          test_raw_oas_provider_timeout_preserves_typed_observation;
        Alcotest.test_case "raw OAS API timeout remains typed" `Quick
          test_raw_oas_api_timeout_preserves_typed_observation;
        Alcotest.test_case "TLS handshake internal error is transient" `Quick
          test_tls_handshake_internal_error_is_transient;
        Alcotest.test_case "keeper turn has no total wall-clock kill" `Quick
          test_keeper_turn_has_no_total_wall_clock_kill;
        Alcotest.test_case "keeper OAS path has no bridge total timeout" `Quick
          test_keeper_oas_path_has_no_bridge_total_timeout;
        Alcotest.test_case "runtime provider path has no cumulative timeout" `Quick
          test_runtime_provider_path_has_no_cumulative_run_timeout;
        Alcotest.test_case "extra system context preserves typed blocks" `Quick
          test_extra_system_context_preserves_typed_blocks;
        Alcotest.test_case "context injection hook records post-tool ledger" `Quick
          test_context_injection_hook_records_post_tool_ledger;
      ] );
  ]
