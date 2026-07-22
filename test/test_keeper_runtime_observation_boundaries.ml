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

(* A provider parse rejection stays a parse rejection, but it must not be
   exempt from the crash threshold: the exemption skips [increment_turn_failures]
   entirely, so a provider emitting a persistently malformed stream retried
   forever with [consecutive] pinned at 0. *)
let test_provider_parse_rejection_counts_toward_crash () =
  let err =
    Agent_sdk.Error.Provider
      (Llm_provider.Error.ParseError
         { detail = "sse: SSE parse failed: malformed_delta_tool_call" })
  in
  Alcotest.(check bool)
    "provider parse rejection is still classified as a server parse rejection"
    true
    (EC.is_server_rejected_parse_error err);
  Alcotest.(check bool)
    "provider parse rejection is not exempt from the crash threshold"
    false
    (EC.is_auto_recoverable_turn_error err)

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
        Alcotest.test_case "provider parse rejection counts toward crash" `Quick
          test_provider_parse_rejection_counts_toward_crash;
        Alcotest.test_case "extra system context preserves typed blocks" `Quick
          test_extra_system_context_preserves_typed_blocks;
      ] );
  ]
