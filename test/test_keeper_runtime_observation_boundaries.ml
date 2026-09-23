open Masc

module KPB = Keeper_provider_runtime_boundary
module KTD = Keeper_turn_driver
module EC = Keeper_error_classify
module KUF = Keeper_unified_turn_failure
module R = Keeper_registry
module KSM = Keeper_state_machine
module KHL = Keeper_heartbeat_loop

let with_temp_dir prefix f =
  let dir = Filename.temp_dir prefix "" in
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)
;;

let make_meta name =
  let json =
    `Assoc [ ("name", `String name); ("trace_id", `String ("trace-" ^ name)) ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)
;;

let raw_provider_timeout_error ~phase =
  Agent_core.Error.Provider
    (Llm_provider.Error.Timeout
       { provider = "test_provider"
       ; timeout_phase = phase
       ; detail = "provider timeout"
       })

let raw_api_timeout_error () =
  Agent_core.Error.Api
    (Llm_provider.Retry.Timeout
       { message = "Per-provider timeout after 90.0s"; phase = None })

let tls_handshake_internal_error () =
  KTD.core_error_of_masc_internal_error
    (KTD.Internal_unhandled_exception
       { site = KTD.runtime_runner_execute_site
       ; exn_repr = "TLS alert from peer: handshake failure"
       ; transport_error_kind = Some Llm_provider.Http_client.Tls_error
       })


let test_raw_agent_core_provider_timeout_preserves_typed_observation () =
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
  match KPB.classify_core_error err with
  | KPB.Provider_timeout
      { source = KPB.Agent_core_provider
      ; phase = Some (KPB.Stream_idle KPB.Streaming_thinking)
      } -> ()
  | _ -> Alcotest.fail "expected typed AGENT_CORE streaming-thinking timeout observation"

let test_raw_agent_core_api_timeout_preserves_typed_observation () =
  let err = raw_api_timeout_error () in
  Alcotest.(check bool)
    "raw API timeout is a provider timeout"
    true
    (EC.is_provider_timeout_error err);
  match KPB.classify_core_error err with
  | KPB.Provider_timeout { source = KPB.Agent_core_api; phase = None } -> ()
  | _ -> Alcotest.fail "expected typed phase-free AGENT_CORE API timeout observation"

let check_registry_observation terminal ~core_error ~expected ~expected_timeout_prefix =
  with_temp_dir "timeout-observation" @@ fun base_path ->
  let meta = make_meta "timeout-observation" in
  let raw_error = "synthetic observation" in
  let reason =
    Keeper_unified_turn_types.registry_failure_reason_of_terminal_reason
      ?core_error terminal ~raw_error
  in
  Fun.protect ~finally:R.For_testing.clear (fun () ->
    ignore (R.For_testing.register ~base_path meta.name meta);
    R.set_failure_reason ~base_path meta.name reason;
    let registry_entry =
      match R.get ~base_path meta.name with
      | Some entry -> entry
      | None -> Alcotest.fail "registered keeper disappeared before refresh"
    in
    KHL.refresh_failure_reason_after_turn
      ~registry_entry
      ~turn_fail_count:1;
    let stored =
      match R.get ~base_path meta.name with
      | Some { last_failure_reason = Some reason; _ } -> reason
      | _ -> Alcotest.fail "terminal cause was not stored in the registry"
    in
    let code, observed =
      match stored with
      | R.Provider_runtime_error { code; detail; agent_core_timeout; _ } ->
        let expected_presence =
          match core_error, expected with
          | Some _, KPB.Provider_timeout _ -> true
          | None, _ | Some _, KPB.No_timeout_observed -> false
        in
        Alcotest.(check bool) "typed timeout evidence survives post-turn refresh"
          expected_presence (Option.is_some agent_core_timeout);
        code,
        KPB.classify_provider_runtime_error_record
          ?agent_core_timeout ~code ~detail ()
      | _ -> Alcotest.fail "expected the actual provider error registry record"
    in
    Alcotest.(check bool) "registry retains the timeout source and phase"
      true (observed = expected);
    let expected_summary =
      match expected_timeout_prefix with
      | Some prefix ->
        Printf.sprintf
          "%s (%s): %s; keeper can soft-fail and retry with provider cooldown."
          prefix code raw_error
      | None ->
        Printf.sprintf "Provider runtime error (%s): %s" code raw_error
    in
    match (Keeper_status_bridge.runtime_blocker_surface_of_failure_reason
        ~latest_receipt:(fun () -> Masc.Keeper_execution_receipt.No_receipt)) stored with
    | Some surface ->
      Alcotest.(check string) "public status describes the observed failure"
        expected_summary surface.summary
    | None -> Alcotest.fail "registry cause was missing from public status")

let check_error_observation err expected expected_timeout_prefix () =
  Alcotest.(check bool) "raw error retains the timeout source and phase"
    true (KPB.classify_core_error err = expected);
  let terminal = Keeper_turn_terminal.of_failure ~raw_error:"synthetic observation" err in
  check_registry_observation terminal ~core_error:(Some err) ~expected
    ~expected_timeout_prefix

let timeout_observation_cases =
  let api phase =
    Agent_core.Error.Api
      (Llm_provider.Retry.Timeout { message = "synthetic timeout"; phase })
  in
  let network kind timeout_phase =
    Agent_core.Error.Provider
      (Llm_provider.Error.NetworkError
         { provider = "fixture"; kind; timeout_phase; detail = "synthetic timeout" })
  in
  [ "API timeout without phase", api None,
      KPB.Provider_timeout { source = KPB.Agent_core_api; phase = None },
      Some "API timeout"
  ; "API timeout with phase", api (Some Llm_provider.Http_client.Non_streaming_body),
      KPB.Provider_timeout
        { source = KPB.Agent_core_api; phase = Some KPB.Non_streaming_body },
      Some "API timeout during non_streaming_body"
  ; "API stream idle timeout",
      api (Some (Llm_provider.Http_client.Stream_idle Llm_provider.Http_client.Streaming_thinking)),
      KPB.Provider_timeout
        { source = KPB.Agent_core_api; phase = Some (KPB.Stream_idle KPB.Streaming_thinking) },
      Some "API timeout during stream_idle:streaming_thinking"
  ; "API explicit unknown phase", api (Some Llm_provider.Http_client.Unknown_timeout),
      KPB.Provider_timeout
        { source = KPB.Agent_core_api; phase = Some KPB.Unknown_timeout },
      Some "API timeout during unknown_timeout"
  ; "Provider timeout without phase", raw_provider_timeout_error ~phase:None,
      KPB.Provider_timeout { source = KPB.Agent_core_provider; phase = None },
      Some "Provider timeout"
  ; "Provider timeout with phase",
      raw_provider_timeout_error ~phase:(Some Llm_provider.Http_client.First_token),
      KPB.Provider_timeout
        { source = KPB.Agent_core_provider; phase = Some KPB.First_token },
      Some "Provider timeout during first_token"
  ; "Provider network timeout with phase",
      network Llm_provider.Http_client.Timeout
        (Some Llm_provider.Http_client.Http_operation),
      KPB.Provider_timeout
        { source = KPB.Agent_core_provider; phase = Some KPB.Http_operation },
      Some "Provider timeout during http_operation"
  ; "Provider network error without timeout evidence",
      network Llm_provider.Http_client.Dns_failure None,
      KPB.No_timeout_observed, None
  ]

let test_wire_only_api_timeout_does_not_invent_evidence () =
  let terminal =
    Keeper_turn_terminal.of_disposition
      (Keeper_turn_disposition.Provider_error
         (Keeper_turn_terminal_code.of_core_error_wire "api_error_timeout"))
  in
  check_registry_observation terminal ~core_error:None
    ~expected:KPB.No_timeout_observed
    ~expected_timeout_prefix:None

let test_wire_only_provider_timeout_keeps_its_known_phase () =
  let terminal =
    Keeper_turn_terminal.of_disposition
      (Keeper_turn_disposition.Provider_error
         (Keeper_turn_terminal_code.of_core_error_wire "provider_error_timeout:queue"))
  in
  check_registry_observation terminal ~core_error:None
    ~expected:
      (KPB.Provider_timeout { source = KPB.Agent_core_provider; phase = Some KPB.Queue })
    ~expected_timeout_prefix:(Some "Provider timeout during queue")

let test_api_specific_bridge_preserves_timeout_phase () =
  let error =
    Llm_provider.Retry.Timeout
      { message = "synthetic timeout"; phase = Some Llm_provider.Http_client.Queue }
  in
  let terminal =
    Keeper_turn_terminal.of_disposition
      (Keeper_turn_disposition.Provider_error
         (Keeper_agent_error.api_error_terminal_reason_code_typed error))
  in
  check_registry_observation terminal
    ~core_error:(Some (Agent_core.Error.Api error))
    ~expected:
      (KPB.Provider_timeout { source = KPB.Agent_core_api; phase = Some KPB.Queue })
    ~expected_timeout_prefix:(Some "API timeout during queue")

let test_provider_network_timeout_without_phase_reaches_registry () =
  let error =
    Agent_core.Error.Provider
      (Llm_provider.Error.NetworkError
         { provider = "fixture"
         ; kind = Llm_provider.Http_client.Timeout
         ; timeout_phase = None
         ; detail = "synthetic timeout"
         })
  in
  let terminal = Keeper_turn_terminal.of_failure ~raw_error:"synthetic observation" error in
  check_registry_observation terminal ~core_error:(Some error)
    ~expected:(KPB.Provider_timeout { source = KPB.Agent_core_provider; phase = None })
    ~expected_timeout_prefix:(Some "Provider timeout")

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
    Agent_core.Error.Provider
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

let test_provider_wire_error_is_not_rate_limit_or_request_parse () =
  let err =
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderWireError
         { provider = "glm"
         ; format = Llm_provider.Http_client.Sse
         ; kind = Llm_provider.Http_client.Malformed_payload
         ; detail = "SSE parse failed: malformed JSON"
         })
  in
  Alcotest.(check bool) "wire error is preserved" true (EC.is_provider_wire_error err);
  Alcotest.(check bool)
    "wire error is not request-body parse rejection"
    false
    (EC.is_provider_rejected_parse_error err);
  Alcotest.(check bool)
    "wire error is not server parse rejection"
    false
    (EC.is_server_rejected_parse_error err);
  Alcotest.(check bool)
    "wire error remains crash-accounted"
    false
    (EC.is_auto_recoverable_turn_error err)

(* A 0-byte empty completion with a modeled non-overflow stop_reason (AGENT_CORE
   [Retry.Empty_attributed]) surfaces as [EmptyCompletion] with the reason
   still typed, and is auto-recoverable: retry/failover can make progress on
   a broken backend model answering with an empty assistant turn. *)
let test_attributed_empty_completion_is_auto_recoverable () =
  let err =
    Agent_core.Error.Provider
      (Llm_provider.Error.EmptyCompletion
         { provider = "ollama-cloud"
         ; stop_reason = Llm_provider.Types.EndTurn
         ; detail = "provider returned an empty assistant turn"
         })
  in
  Alcotest.(check bool)
    "attributed empty completion is an empty completion error"
    true
    (EC.is_empty_completion_error err);
  Alcotest.(check bool)
    "attributed empty completion is auto-recoverable"
    true
    (EC.is_auto_recoverable_turn_error err);
  Alcotest.(check bool)
    "attributed empty completion is not a server parse rejection"
    false
    (EC.is_server_rejected_parse_error err)

(* The pinning test for a ParseError-carried empty completion was removed
   with the guard it pinned: no production producer of that shape exists at
   the pinned Agent Core, and locking a message substring in place is the
   drift-guard anti-pattern RFC-0371 §5.4 removes. *)

(* AGENT_CORE surfaces an empty completion with an unmodeled stop_reason as a
   non-retryable [InvalidRequest].  This shape must stay classified as an
   invalid request, not as an empty completion: the classes drive telemetry
   and failure routing, and conflating them hides which boundary produced
   the empty turn. *)
let test_unmodeled_stop_reason_invalid_request_is_not_empty_completion () =
  let err =
    Agent_core.Error.Api
      (Llm_provider.Retry.InvalidRequest
         { message =
             "empty completion with unmodeled stop_reason=\"glmtoken\": \
              provider returned an empty assistant turn"
         ; reason = Llm_provider.Retry.Unknown_invalid_request
         })
  in
  Alcotest.(check bool)
    "unmodeled stop_reason empty completion is not an empty completion error"
    false
    (EC.is_empty_completion_error err);
  Alcotest.(check bool)
    "unmodeled stop_reason shape is classified as invalid request"
    true
    (EC.is_invalid_request_error err)

(* A generic 400 [InvalidRequest] is not an empty completion either: the
   classes stay distinct for telemetry and failure routing. Both count
   toward the crash-accounting streak identically (RFC
   turn-failure-visible-stop, #32105) — no class carries its own budget. *)
let test_generic_invalid_request_is_not_empty_completion () =
  let err =
    Agent_core.Error.Api
      (Llm_provider.Retry.InvalidRequest
         { message = "invalid request body"
         ; reason = Llm_provider.Retry.Unknown_invalid_request
         })
  in
  Alcotest.(check bool)
    "generic InvalidRequest is not an empty completion error"
    false
    (EC.is_empty_completion_error err)

(* #31958 regression pin: a transient network failure must advance the crash
   streak. Before RFC turn-failure-visible-stop (#32105) the network class had
   no budget term, so such failures were exempt: the streak stayed 0 and the
   heartbeat mapped the zero count to Turn_succeeded — a dead transport
   retried forever with fleet health ok. Every step here is the production
   chain: record_failure_observation → registry count → turn_status_event →
   dispatched phase. *)
let test_transient_network_failure_advances_crash_streak () =
  with_temp_dir "network-crash-streak" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let meta = make_meta "network-crash-streak" in
  let err = tls_handshake_internal_error () in
  Alcotest.(check bool)
    "network failure is still classified auto-recoverable (class unchanged)"
    true
    (EC.is_auto_recoverable_turn_error err);
  Fun.protect
    ~finally:(fun () -> R.For_testing.clear ())
    (fun () ->
       ignore (R.For_testing.register ~base_path meta.name meta);
       KUF.record_failure_observation ~config ~meta ~err
         ~terminal_reason:(Keeper_turn_terminal.of_failure ~raw_error:"TLS handshake" err)
         ~error_text:"TLS handshake";
       Alcotest.(check int)
         "first network failure counts toward the streak"
         1
         (R.get_turn_failures ~base_path meta.name);
       KUF.record_failure_observation ~config ~meta ~err
         ~terminal_reason:(Keeper_turn_terminal.of_failure ~raw_error:"TLS handshake" err)
         ~error_text:"TLS handshake";
       let count = R.get_turn_failures ~base_path meta.name in
       Alcotest.(check int) "second network failure compounds the streak" 2 count;
       let event = KHL.turn_status_event ~turn_fail_count:count in
       (match event with
        | KSM.Turn_failed { consecutive } ->
          Alcotest.(check int) "Turn_failed carries the streak" 2 consecutive
        | _ -> Alcotest.fail "expected Turn_failed for network failure");
       ignore (R.dispatch_event ~base_path meta.name event);
       (match R.get_phase ~base_path meta.name with
        | Some phase ->
          Alcotest.(check string)
            "network failure moves the state machine to failing"
            "failing"
            (KSM.phase_to_string phase)
        | None -> Alcotest.fail "expected registered keeper phase"))

(* Exercise the failure producer, the production heartbeat cause refresh and
   public blocker surface, including a later failure and successful reset.
   The live loop's event dispatch and late-event filtering are not run here. *)
let record_failed_turn ~config ~meta err =
  let error_text = Agent_core.Error.to_string err in
  let terminal_reason = Keeper_turn_terminal.of_failure ~raw_error:error_text err in
  KUF.record_failure_observation ~config ~meta ~terminal_reason ~err ~error_text

let refresh_failure_reason ~base_path ~keeper_name =
  let registry_entry =
    match R.get ~base_path keeper_name with
    | Some entry -> entry
    | None -> Alcotest.fail "registered keeper disappeared before refresh"
  in
  KHL.refresh_failure_reason_after_turn ~registry_entry
    ~turn_fail_count:(R.get_turn_failures ~base_path keeper_name)

let failure_reason ~base_path ~keeper_name =
  match Option.bind (R.get ~base_path keeper_name) (fun entry -> entry.R.last_failure_reason) with
  | Some reason -> reason
  | None -> Alcotest.fail "expected current failure reason"

let test_failed_ticks_preserve_current_runtime_cause () =
  with_temp_dir "failure-cause-ticks" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let meta = make_meta "failure-cause-ticks" in
  Fun.protect ~finally:(fun () -> R.For_testing.clear ()) (fun () ->
    ignore (R.For_testing.register ~base_path meta.name meta);
    let exhausted =
      KTD.core_error_of_masc_internal_error
        (KTD.Runtime_exhausted
           { runtime_id = "runtime.test"; reason = KTD.No_providers_available })
    in
    record_failed_turn ~config ~meta exhausted;
    refresh_failure_reason ~base_path ~keeper_name:meta.name;
    (match failure_reason ~base_path ~keeper_name:meta.name with
     | R.Provider_runtime_error { reason = Some Keeper_meta_contract.No_providers_available; _ } -> ()
     | reason -> Alcotest.failf "exhaustion cause lost: %s" (R.failure_reason_to_string reason));
    (match (Keeper_status_bridge.runtime_blocker_surface_of_failure_reason
        ~latest_receipt:(fun () -> Masc.Keeper_execution_receipt.No_receipt))
             (failure_reason ~base_path ~keeper_name:meta.name) with
     | Some surface -> Alcotest.(check string) "public blocker" "runtime_exhausted" surface.blocker_class
     | None -> Alcotest.fail "missing public blocker");
    record_failed_turn ~config ~meta
      (raw_provider_timeout_error
         ~phase:(Some (Llm_provider.Http_client.Stream_idle
                        Llm_provider.Http_client.Streaming_thinking)));
    refresh_failure_reason ~base_path ~keeper_name:meta.name;
    Alcotest.(check int) "both failures counted" 2 (R.get_turn_failures ~base_path meta.name);
    (match failure_reason ~base_path ~keeper_name:meta.name with
     | R.Provider_runtime_error { reason = None; code; detail; agent_core_timeout; _ } ->
       (match KPB.classify_provider_runtime_error_record ?agent_core_timeout ~code ~detail () with
        | KPB.Provider_timeout _ -> ()
        | KPB.No_timeout_observed -> Alcotest.fail "new cause is not a timeout")
     | reason -> Alcotest.failf "new timeout cause lost: %s" (R.failure_reason_to_string reason));
    Alcotest.(check bool) "successful turn resets" true
      (Keeper_turn_failure_streak.reset ~base_path ~keeper_name:meta.name);
    Alcotest.(check int) "success clears count" 0 (R.get_turn_failures ~base_path meta.name);
    Alcotest.(check bool) "success clears cause" true
      (Option.bind (R.get ~base_path meta.name) (fun entry -> entry.R.last_failure_reason) = None))

let test_crashed_tick_replaces_previous_configuration_cause () =
  with_temp_dir "failure-cause-crash" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let meta = make_meta "failure-cause-crash" in
  Fun.protect ~finally:(fun () -> R.For_testing.clear ()) (fun () ->
    let registry_entry = R.For_testing.register ~base_path meta.name meta in
    record_failed_turn ~config ~meta
      (Agent_core.Error.Config (MissingEnvVar { var_name = "TEST_PROVIDER_KEY" }));
    refresh_failure_reason ~base_path ~keeper_name:meta.name;
    KHL.record_crashed_cycle_failure
      ~registry_entry
      (Failure "synthetic cycle crash");
    refresh_failure_reason ~base_path ~keeper_name:meta.name;
    Alcotest.(check int) "both failures counted" 2 (R.get_turn_failures ~base_path meta.name);
    match failure_reason ~base_path ~keeper_name:meta.name with
    | R.Exception _ -> ()
    | reason -> Alcotest.failf "previous cause survived new crash: %s" (R.failure_reason_to_string reason))

let test_extra_system_context_preserves_typed_blocks () =
  let blocks =
    [ Prompt_block_id.Dynamic_context, "dynamic"
    ; Prompt_block_id.Temporal_summary, "summary"
    ; Prompt_block_id.Memory_os_recall, "memory"
    ]
  in
  let assembly =
    Keeper_run_prompt.assemble_extra_system_context
      ~existing_extra_system_context:(Some "existing")
      ~blocks
  in
  Alcotest.(check bool) "typed blocks unchanged" true (assembly.blocks = blocks);
  Alcotest.(check (option string))
    "complete source order reaches AGENT_CORE"
    (Some "existing\n\ndynamic\n\nsummary\n\nmemory")
    assembly.extra_system_context

let () =
  Alcotest.run "keeper_runtime_observation_boundaries"
  [
    ( "terminal to registry to status",
      List.map
        (fun (name, error, expected, expected_timeout_prefix) ->
          Alcotest.test_case name `Quick
            (check_error_observation error expected expected_timeout_prefix))
        timeout_observation_cases
      @ [ Alcotest.test_case "wire-only API timeout retains missing evidence" `Quick
            test_wire_only_api_timeout_does_not_invent_evidence
        ; Alcotest.test_case "API-specific producer retains phase" `Quick
            test_api_specific_bridge_preserves_timeout_phase
        ; Alcotest.test_case "wire-only Provider timeout keeps its known phase" `Quick
            test_wire_only_provider_timeout_keeps_its_known_phase
        ; Alcotest.test_case "Provider network timeout without phase reaches registry" `Quick
            test_provider_network_timeout_without_phase_reaches_registry
        ] );
    ( "typed observations",
      [
        Alcotest.test_case "raw AGENT_CORE provider timeout remains typed" `Quick
          test_raw_agent_core_provider_timeout_preserves_typed_observation;
        Alcotest.test_case "raw AGENT_CORE API timeout remains typed" `Quick
          test_raw_agent_core_api_timeout_preserves_typed_observation;
        Alcotest.test_case "TLS handshake internal error is transient" `Quick
          test_tls_handshake_internal_error_is_transient;
        Alcotest.test_case "provider parse rejection counts toward crash" `Quick
          test_provider_parse_rejection_counts_toward_crash;
        Alcotest.test_case
          "provider wire error stays distinct and crash-accounted" `Quick
          test_provider_wire_error_is_not_rate_limit_or_request_parse;
        Alcotest.test_case "attributed empty completion is auto-recoverable" `Quick
          test_attributed_empty_completion_is_auto_recoverable;
        Alcotest.test_case
          "unmodeled stop_reason InvalidRequest is not empty completion" `Quick
          test_unmodeled_stop_reason_invalid_request_is_not_empty_completion;
        Alcotest.test_case
          "generic InvalidRequest is not empty completion" `Quick
          test_generic_invalid_request_is_not_empty_completion;
        Alcotest.test_case "failed ticks preserve current runtime cause" `Quick
          test_failed_ticks_preserve_current_runtime_cause;
        Alcotest.test_case "crashed tick replaces previous configuration cause" `Quick
          test_crashed_tick_replaces_previous_configuration_cause;
        Alcotest.test_case "extra system context preserves typed blocks" `Quick
          test_extra_system_context_preserves_typed_blocks;
        Alcotest.test_case
          "transient network failure advances the crash streak" `Quick
          test_transient_network_failure_advances_crash_streak;
      ] );
  ]
