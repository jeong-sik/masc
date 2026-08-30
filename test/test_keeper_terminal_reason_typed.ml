(* RFC-0042 PR-4 behavioural equivalence + wire round-trip test.

   Two properties are pinned:

   1. [to_wire (of_wire s) = s] byte-for-byte for every representative
      producer code string (and a few adversarial ones). This proves the
      typed parse loses no information — every payload-bearing variant
      carries the original bytes.

   2. The NEW [Keeper_execution_receipt.operator_disposition] (which now
      parses [terminal_reason_code] once via [Keeper_terminal_reason.of_wire]
      and exhaustive-matches) returns the same pair as the independent oracle,
      including focused policy updates, over the cartesian product of
      (producer-string corpus) x (the small finite field matrix the
      classifier branches on). The oracle is intentionally NOT refactored to
      share code with production, so a priority-order regression in production
      is caught here. *)

module R = Masc.Keeper_execution_receipt
module C = Masc.Keeper_contract_classifier
module Tr = Keeper_terminal_reason
module UTS = Masc.Keeper_unified_turn_success.For_testing
module KTP = Masc.Keeper_terminal_effect_policy
module KOAR = Masc.Keeper_observability_artifact_registry
module Health_fleet = Server_routes_http_runtime_health_fleet
module KMC = Masc.Keeper_meta_contract
module KMS = Masc.Keeper_meta_store
module Keeper_identity = Masc.Keeper_identity
module Agent_run_receipt = Masc.Keeper_agent_run_receipt.For_testing

let failures = ref []
let check name cond = if not cond then failures := name :: !failures

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let meta_fixture_exn json =
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> failwith ("meta fixture parse failed: " ^ err)
;;

let write_meta_exn config meta =
  match KMS.replace_snapshot config meta with
  | Ok () -> ()
  | Error err -> failwith ("write_meta failed: " ^ err)
;;

let read_meta_exn config keeper_name =
  match KMS.read_meta config keeper_name with
  | Ok (Some meta) -> meta
  | Ok None -> failwith ("missing persisted meta for " ^ keeper_name)
  | Error err -> failwith ("read_meta failed: " ^ err)
;;

let with_owner_inventory config f =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  (match Masc.Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
   | Ok _ -> ()
   | Error error ->
     failwith (Masc.Keeper_owner_registry.install_error_to_string error));
  f ()
;;

(* ------------------------------------------------------------------ *)
(* 1. Wire round-trip corpus: built from the PRODUCER sites, not from  *)
(*    the classifier prefixes. Includes both api_error/provider_error  *)
(*    families, direct producer strings, and one mixed-case input.     *)
(*    mixed-case adversarial input.                                    *)
(* ------------------------------------------------------------------ *)

let roundtrip_corpus =
  [ (* exact-match buckets *)
    "runtime_exhausted"
  ; Keeper_internal_error.capacity_backpressure_kind
  ; Keeper_internal_error.incomplete_tool_transcript_kind
  ; Keeper_internal_error.provider_attempt_effect_fenced_kind
  ; Keeper_internal_error.tool_correction_lost_kind
    (* The rest of what [kind_of_masc_internal_error] emits. The corpus used
       to hold five of its thirteen kinds, so the eight missing ones were
       neither recognised nor deliberately left [Unknown] — they were simply
       never considered, and four of them reached operators as "unmapped
       runtime state" in production (#29929). Spelled out here rather than
       taken from [wire_kind_to_string]: this list is the oracle's, and
       reading it from the producer would remove the check. *)
  ; "accept_rejected"
  ; "terminal_effect_failed"
  ; "internal_unhandled_exception"
  ; "internal_bridge_exception"
  ; "internal_contract_rejected"
  ; "internal_error"
  ; "pre_dispatch_success"
  ; "provider_error"
    (* config/auth preflight (ranked above provider) *)
  ; "config_error"
  ; "api_error_auth"
  ; "provider_error_auth"
  ; "provider_error_auth:legacy-payload"
  ; "provider_error_invalid_config:field_x"
    (* provider family *)
  ; "api_error_rate_limited"
  ; "api_error_overloaded"
  ; "api_error_server:502"
  ; "api_error_timeout"
  ; "api_error_network"
  ; "api_error_context_overflow"
  ; "provider_error_parse"
  ; "provider_error_server:500"
  ; "provider_error_missing_api_key"
  ; "provider_error_hard_quota:openai"
    (* Producer kinds with no policy yet, which is not the same as the
       deliberate Unknowns below. None has ever been observed — zero rows
       across 189 receipt files and every August log — so there is no trace
       to classify them from. [of_wire] names them explicitly and answers
       [Unknown], so the open question is visible in the match instead of
       being an absent arm. *)
  ; "resumable_cli_session"
  ; "receipt_persistence_failed"
  ; "gate_replay_repair_required"
    (* genuine Unknown (preserve-don't-fix) *)
  ; "no_capable_provider"
  ; "mcp_error"
  ; "serialization_error"
  ; "io_error"
  ; "orchestration_error"
  ; "a2a_error"
  ; "agent_error_guardrail_violation:validator=x"
  ; "agent_error_idle_detected:consecutive_idle_turns=3"
  ; "registry_phase_missing"
  ; "supervisor_stop"
    (* adversarial: mixed case must round-trip to the original bytes *)
  ; "Runtime_Exhausted"
  ; "API_ERROR_Auth"
  ; "unrelated authentication failed"
  ; "not_a_config_error"
  ; ""
  ]

let () =
  List.iter
    (fun s ->
       let got = Tr.to_wire (Tr.of_wire s) in
       check
         (Printf.sprintf "roundtrip: %S -> %S" s got)
         (String.equal got s))
    roundtrip_corpus
;;

(* ------------------------------------------------------------------ *)
(* 2. (disposition, reason) equivalence vs an independent strict-wire *)
(*    oracle.                                                           *)
(* ------------------------------------------------------------------ *)

(* Independent copy of the intended canonical-wire policy. DO NOT refactor to
   call production helpers — this is the oracle. *)

let frozen_is_transient_provider_runtime_failure terminal_reason =
  String.equal terminal_reason "api_error_timeout"
  || String.equal terminal_reason "api_error_network"
;;

let frozen_is_config_or_auth_wire = function
  | "config_error"
  | "api_error_auth"
  | "api_error_authorization"
  | "provider_error_auth"
  | "provider_error_authorization" -> true
  | wire -> String.starts_with ~prefix:"provider_error_invalid_config:" wire
;;

let frozen_operator_disposition (receipt : R.t)
  : R.operator_disposition_kind * R.operator_disposition_reason
  =
  let terminal_reason = receipt.terminal_reason_code in
  let provider_runtime_failure =
    String.starts_with ~prefix:"api_error_" terminal_reason
    || String.equal terminal_reason "provider_error"
    || String.starts_with ~prefix:"provider_error_" terminal_reason
  in
  let preflight_config_failure = frozen_is_config_or_auth_wire terminal_reason in
  if String.equal terminal_reason "runtime_exhausted"
  then R.Disp_fail_open_next_runtime, R.Reason_runtime_exhausted
  else if
    String.equal terminal_reason Keeper_internal_error.capacity_backpressure_kind
  then R.Disp_fail_open_next_runtime, R.Reason_capacity_backpressure
  else if
    String.equal terminal_reason Keeper_internal_error.incomplete_tool_transcript_kind
  then R.Disp_unknown, R.Reason_transcript_corruption
  else if
    String.equal
      terminal_reason
      Keeper_internal_error.provider_attempt_effect_fenced_kind
  then R.Disp_unknown, R.Reason_provider_attempt_effect_fenced
  else if
    String.equal terminal_reason Keeper_internal_error.tool_correction_lost_kind
  then R.Disp_unknown, R.Reason_tool_correction_lost
  else if String.equal terminal_reason "terminal_effect_failed"
  then R.Disp_unknown, R.Reason_terminal_effect_failed
  else if preflight_config_failure
  then R.Disp_operator_action_required, R.Reason_preflight_config_error
  else if
    provider_runtime_failure
    && (receipt.degraded_retry_applied || Option.is_some receipt.degraded_retry_runtime)
  then R.Disp_fail_open_next_runtime, R.Reason_degraded_retry
  else if
    provider_runtime_failure
    && (receipt.runtime_fallback_applied
        || receipt.runtime_outcome = R.Runtime_passed_to_next_model)
  then R.Disp_pass_next_model, R.Reason_runtime_fallback
  else if
    provider_runtime_failure
    && frozen_is_transient_provider_runtime_failure terminal_reason
  then R.Disp_retry_later, R.Reason_transient_runtime_retry
  else if provider_runtime_failure
  then R.Disp_retry_later, R.Reason_provider_runtime_error
  else if
    String.equal terminal_reason "internal_error"
    || String.equal terminal_reason "internal_unhandled_exception"
    || String.equal terminal_reason "internal_bridge_exception"
    || String.equal terminal_reason "internal_contract_rejected"
  then R.Disp_fail_open_next_runtime, R.Reason_internal_error
  else if receipt.degraded_retry_applied || Option.is_some receipt.degraded_retry_runtime
  then R.Disp_fail_open_next_runtime, R.Reason_degraded_retry
  else if
    receipt.runtime_fallback_applied
    || receipt.runtime_outcome = R.Runtime_passed_to_next_model
  then R.Disp_pass_next_model, R.Reason_runtime_fallback
  else if
    receipt.outcome = `Ok
    && receipt.runtime_outcome = R.Runtime_not_dispatched
    && String.equal terminal_reason "pre_dispatch_success"
  then R.Disp_pass, R.Reason_healthy
  else (
    match receipt.outcome with
    | `Cancelled -> R.Disp_user_cancelled, R.Reason_cancelled
    | `Skipped -> R.Disp_skipped, R.Reason_phase_skipped
    | `Ok when receipt.runtime_outcome = R.Runtime_completed ->
      R.Disp_pass, R.Reason_healthy
    | `Ok when receipt.runtime_outcome = R.Runtime_not_dispatched ->
      R.Disp_pass, R.Reason_healthy
    | _ when String.equal terminal_reason "accept_rejected" ->
      R.Disp_fail_open_next_runtime, R.Reason_accept_rejected
    | _ -> R.Disp_unknown, R.Reason_unmapped_runtime_state)
;;

(* ------------------------------------------------------------------ *)
(* Base receipt + field-matrix axes.                                   *)
(* ------------------------------------------------------------------ *)

let base_tool_surface : R.tool_surface =
  { turn_lane = Masc.Keeper_agent_tool_surface.Lane_tool_optional }
;;

let base_receipt : R.t =
  { keeper_name = "test-keeper"
  ; trace_id = "trace-1"
  ; turn_count = Some 1
  ; agent_core_turn_count = None
  ; current_task_id = None
  ; outcome = `Error
  ; terminal_reason_code = ""
  ; response_text_present = false
  ; completion_contract_result = R.Completion_observation_unknown
  ; actionable_signal = Some C.No_actionable_signal
  ; tool_surface = base_tool_surface
  ; sandbox_kind = Keeper_types_profile_sandbox.Local
  ; sandbox_root = None
  ; network_mode = Keeper_types_profile_sandbox.Network_none
  ; runtime_id = "runtime-1"
  ; runtime_selected_model = None
  ; runtime_attempt_count = 1
  ; runtime_lane_attempt_count = 1
  ; runtime_fallback_applied = false
  ; runtime_outcome = R.Runtime_completed
  ; agent_core_internal_runtime_allowed = true
  ; degraded_retry_applied = false
  ; degraded_retry_runtime = None
  ; fallback_reason = None
  ; runtime_rotation_attempts = []
  ; stop_reason = None
  ; error_kind = None
  ; error_message = None
  ; started_at = "2026-06-03T00:00:00Z"
  ; ended_at = "2026-06-03T00:00:01Z"
  ; extra_system_context_digest = None
  ; extra_system_context_injected_size = None
  ; extra_system_context_computed_size = None
  }
;;

let () =
  List.iter
    (fun wire ->
       check
         (Printf.sprintf "free-form terminal %S stays typed Unknown" wire)
         (match Tr.of_wire wire with
          | Tr.Unknown original -> String.equal original wire
          | _ -> false);
       check
         (Printf.sprintf "free-form terminal %S round-trips" wire)
         (String.equal (Tr.to_wire (Tr.of_wire wire)) wire);
       let got =
         R.operator_disposition
           { base_receipt with terminal_reason_code = wire }
       in
       check
         (Printf.sprintf "free-form terminal %S uses generic disposition" wire)
         (got = (R.Disp_unknown, R.Reason_unmapped_runtime_state)))
    [ "unrelated authentication failed"
    ; "not_a_config_error"
    ; "API_ERROR_Auth"
    ];
  let canonical =
    R.operator_disposition
      { base_receipt with terminal_reason_code = "config_error" }
  in
  check
    "canonical typed config wire requires operator action"
    (canonical = (R.Disp_operator_action_required, R.Reason_preflight_config_error))
  ;
  check
    "canonical typed config wire emits operator broadcast"
    (R.needs_operator_broadcast (fst canonical));
  let transcript_corruption =
    R.operator_disposition
      { base_receipt with
        terminal_reason_code = Keeper_internal_error.incomplete_tool_transcript_kind
      }
  in
  check
    "transcript corruption stays a typed alert, not a pause"
    (transcript_corruption = (R.Disp_unknown, R.Reason_transcript_corruption));
  check
    "transcript corruption emits operator broadcast"
    (R.needs_operator_broadcast (fst transcript_corruption));
  let fenced_error =
    Keeper_internal_error.Provider_attempt_effect_fenced
      { runtime_id = "antigravity_subscription.gemini-3-6-flash-high"
      ; effect_disposition = Keeper_provider_attempt_effect_core.Effect_attempted
      ; diagnostic = "provider response did not prove whether the tool effect settled"
      }
  in
  let fenced_json = Keeper_internal_error.masc_internal_error_to_json fenced_error in
  check
    "provider-attempt fence codec emits the canonical kind"
    (Json_util.get_string fenced_json "kind"
     = Some Keeper_internal_error.provider_attempt_effect_fenced_kind);
  check
    "provider-attempt fence codec round-trips the typed evidence"
    (Keeper_internal_error.parse_masc_internal_error_json fenced_json
     = Some fenced_error);
  let fenced_wire = Keeper_internal_error.provider_attempt_effect_fenced_kind in
  let producer_wire =
    fenced_error
    |> Keeper_internal_error.core_error_of_masc_internal_error
    |> Masc.Keeper_agent_error.terminal_reason_code_of_core_error
  in
  check
    "provider-attempt fence producer projects the canonical terminal wire"
    (String.equal producer_wire fenced_wire);
  check
    "provider-attempt fence wire decodes to the closed terminal variant"
    (match Tr.of_wire fenced_wire with
     | Tr.Provider_attempt_effect_fenced wire -> String.equal wire fenced_wire
     | _ -> false);
  check
    "provider-attempt fence terminal wire round-trips byte-identically"
    (String.equal (Tr.to_wire (Tr.of_wire fenced_wire)) fenced_wire);
  let lost_error =
    Keeper_internal_error.Tool_correction_lost
      { runtime_id = "antigravity_subscription.gemini-3-6-flash-high"
      ; effect_disposition = Keeper_provider_attempt_effect_core.Effect_attempted
      ; reject_count = 2
      ; diagnostic = "turn died after two corrective tool rejections"
      }
  in
  let lost_json = Keeper_internal_error.masc_internal_error_to_json lost_error in
  check
    "tool-correction-lost codec emits the canonical kind"
    (Json_util.get_string lost_json "kind"
     = Some Keeper_internal_error.tool_correction_lost_kind);
  check
    "tool-correction-lost codec round-trips the typed evidence"
    (Keeper_internal_error.parse_masc_internal_error_json lost_json
     = Some lost_error);
  let lost_wire = Keeper_internal_error.tool_correction_lost_kind in
  check
    "tool-correction-lost wire decodes to the closed terminal variant"
    (match Tr.of_wire lost_wire with
     | Tr.Tool_correction_lost wire -> String.equal wire lost_wire
     | _ -> false);
  check
    "tool-correction-lost terminal wire round-trips byte-identically"
    (String.equal (Tr.to_wire (Tr.of_wire lost_wire)) lost_wire);
  let lost_disposition =
    R.operator_disposition
      { base_receipt with
        terminal_reason_code = lost_wire
      ; error_kind = Some (R.error_kind_of_string "internal")
      ; outcome = `Error
      ; runtime_outcome = R.Runtime_failed
      }
  in
  check
    "tool-correction-lost keeps operator attention with its own typed reason"
    (lost_disposition = (R.Disp_unknown, R.Reason_tool_correction_lost));
  check
    "tool-correction-lost reason has the canonical dashboard wire"
    (String.equal
       (R.operator_disposition_reason_to_string (snd lost_disposition))
       lost_wire);
  let unmapped_metric = Keeper_metrics.(to_string ReceiptUnmappedDisposition) in
  let unmapped_before = Masc.Otel_metric_store.metric_value_or_zero unmapped_metric () in
  let fenced_disposition =
    R.operator_disposition
      { base_receipt with
        terminal_reason_code = fenced_wire
      ; error_kind = Some (R.error_kind_of_string "internal")
      ; outcome = `Error
      ; runtime_outcome = R.Runtime_failed
      }
  in
  let unmapped_after = Masc.Otel_metric_store.metric_value_or_zero unmapped_metric () in
  check
    "provider-attempt fence keeps operator attention with a typed reason"
    (fenced_disposition
     = (R.Disp_unknown, R.Reason_provider_attempt_effect_fenced));
  check
    "provider-attempt fence reason has the canonical dashboard wire"
    (String.equal
       (R.operator_disposition_reason_to_string (snd fenced_disposition))
       fenced_wire);
  check
    "attempted provider effect still forbids same-turn retry"
    (not
       (Keeper_provider_attempt_effect_core.allows_same_turn_retry
          Keeper_provider_attempt_effect_core.Effect_attempted));
  check
    "provider-attempt fence still emits an operator broadcast"
    (R.needs_operator_broadcast (fst fenced_disposition));
  check
    "provider-attempt fence does not increment the unmapped regression metric"
    (Float.equal unmapped_before unmapped_after)
;;

let () =
  let completed_stop = Runtime_agent.Completed in
  let receipt =
    { base_receipt with
      outcome = `Ok
    ; terminal_reason_code =
        R.receipt_terminal_reason_code_of_stop_reason completed_stop
    ; completion_contract_result = R.Completion_tool_execution_observed
    ; runtime_outcome = R.Runtime_completed
    ; stop_reason = Some completed_stop
    }
  in
  let json = R.to_json receipt in
  check
    "one receipt uses canonical terminal success"
    (Json_util.get_string json "terminal_reason_code" = Some "success");
  check
    "the same receipt preserves runtime stop completed"
    (Json_util.get_string json "stop_reason" = Some "completed");
  let no_visible_output =
    { receipt with completion_contract_result = R.Completion_no_visible_output }
  in
  let disposition = fst (R.operator_disposition no_visible_output) in
  check
    "runtime completion ignores missing visible-output observation"
    (disposition = R.Disp_pass)
;;

let () =
  let input_required_receipt =
    { base_receipt with
      outcome = `Ok
    ; terminal_reason_code =
        Masc.Keeper_turn_disposition.to_wire
          Masc.Keeper_turn_disposition.Input_required
    ; completion_contract_result = R.Completion_observation_unknown
    ; runtime_outcome = R.Runtime_completed
    }
  in
  let got = R.operator_disposition input_required_receipt in
  let want = R.Disp_pass, R.Reason_input_required in
  check "input-required receipt stays non-paging and explicitly classified"
    (got = want)
;;

(* Field matrix axes. Kept small but covering the dimensions the
   classifier branches on. *)
let codes = roundtrip_corpus

let error_kinds =
  [ None
  ; Some (R.error_kind_of_string "config")
  ; Some (R.error_kind_of_string "auth")
  ; Some (R.error_kind_of_string "api")
  ; Some (R.error_kind_of_string "mcp")
  ; Some (R.error_kind_of_string "internal")
  ; Some (R.error_kind_of_string "provider")
  ; Some (R.error_kind_of_string "io")
  ]

let degraded_bools = [ false; true ]
let fallback_bools = [ false; true ]

let runtime_outcomes =
  [ R.Runtime_completed
  ; R.Runtime_failed
  ; R.Runtime_passed_to_next_model
  ; R.Runtime_not_observed
  ; R.Runtime_not_dispatched
  ]

let completion_contract_results =
  [ R.Completion_observation_unknown
  ; R.Completion_not_dispatched
  ; R.Completion_no_visible_output
  ; R.Completion_response_observed
  ; R.Completion_tool_execution_observed
  ]

let outcomes = [ `Ok; `Error; `Cancelled; `Skipped ]

let disp_pair_to_string (d, r) =
  Printf.sprintf
    "(%s, %s)"
    (R.operator_disposition_kind_to_string d)
    (R.operator_disposition_reason_to_string r)
;;

let operator_disposition_kinds =
  [ R.Disp_pass
  ; R.Disp_fail_open_next_runtime
  ; R.Disp_retry_later
  ; R.Disp_pass_next_model
  ; R.Disp_operator_action_required
  ; R.Disp_user_cancelled
  ; R.Disp_skipped
  ; R.Disp_unknown
  ]
;;

let () =
  List.iter
    (fun disposition ->
       let label = R.operator_disposition_kind_to_string disposition in
       let parsed =
         R.operator_disposition_kind_of_string label
         |> Option.map R.operator_disposition_kind_to_string
       in
       check
         (Printf.sprintf
            "operator_disposition_kind_of_string round-trips %s"
            label)
         (parsed = Some label))
    operator_disposition_kinds;
  check
    "operator_disposition_kind_of_string rejects legacy blocked_runtime"
    (R.operator_disposition_kind_of_string "blocked_runtime" = None)
;;

(* To keep the product bounded we vary the most behaviour-determining axes
   fully and pin the others to representative values per code, plus a
   focused sub-matrix over the provider/route axes. *)
let () =
  let count = ref 0 in
  let mismatches = ref 0 in
  List.iter
    (fun code ->
       List.iter
         (fun error_kind ->
            List.iter
              (fun degraded ->
                 List.iter
                   (fun fallback ->
                      List.iter
                        (fun runtime_outcome ->
                           List.iter
                             (fun tcr ->
                                List.iter
                                  (fun outcome ->
                                     let receipt =
                                       { base_receipt with
                                         terminal_reason_code = code
                                       ; error_kind
                                       ; degraded_retry_applied = degraded
                                       ; runtime_fallback_applied = fallback
                                       ; runtime_outcome
                                       ; completion_contract_result = tcr
                                       ; outcome
                                       }
                                     in
                                     incr count;
                                     let want =
                                       frozen_operator_disposition receipt
                                     in
                                     let got =
                                       R.operator_disposition receipt
                                     in
                                     if want <> got
                                     then (
                                       incr mismatches;
                                       if !mismatches <= 20
                                       then
                                         check
                                           (Printf.sprintf
                                              "disp-mismatch code=%S ek=%s out=%s ro=%s tcr=%s deg=%b fb=%b want=%s got=%s"
                                              code
                                              (match error_kind with
                                               | None -> "none"
                                               | Some k -> R.error_kind_to_string k)
                                              (R.outcome_kind_to_string outcome)
                                              (R.runtime_outcome_to_string
                                                 runtime_outcome)
                                              (R.completion_contract_result_to_string tcr)
                                              degraded
                                              fallback
                                              (disp_pair_to_string want)
                                              (disp_pair_to_string got))
                                           false))
                                  outcomes)
                             completion_contract_results)
                        runtime_outcomes)
                   fallback_bools)
              degraded_bools)
         error_kinds)
    codes;
  Printf.printf
    "test_keeper_terminal_reason_typed: matrix cases=%d mismatches=%d\n"
    !count
    !mismatches
;;

let () =
  let internal_error =
    Keeper_internal_error.Capacity_backpressure
      { runtime_id = "runtime-capacity"
      ; source = Keeper_internal_error.Provider_capacity
      ; detail = "provider health cooldown active before dispatch"
      ; retry_after = Keeper_internal_error.No_retry_hint
      }
  in
  let code =
    internal_error
    |> Keeper_internal_error.core_error_of_masc_internal_error
    |> Masc.Keeper_agent_error.terminal_reason_code_of_core_error
  in
  check
    "capacity producer uses canonical terminal kind"
    (String.equal code Keeper_internal_error.capacity_backpressure_kind);
  check
    "capacity terminal kind decodes to closed variant"
    (match Tr.of_wire code with
     | Tr.Capacity_backpressure wire -> String.equal wire code
     | _ -> false);
  let receipt =
    { base_receipt with
      terminal_reason_code = code
    ; error_kind = Some (R.error_kind_of_string "internal")
    ; outcome = `Error
    ; runtime_outcome = R.Runtime_not_observed
    }
  in
  let got = R.operator_disposition receipt in
  let want = R.Disp_fail_open_next_runtime, R.Reason_capacity_backpressure in
  check
    (Printf.sprintf
       "capacity disposition want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  check
    "capacity observation does not emit operator broadcast"
    (not (R.needs_operator_broadcast (fst got)));
  let opaque_internal =
    { receipt with terminal_reason_code = code ^ "_unexpected" }
  in
  let got = R.operator_disposition opaque_internal in
  let want = R.Disp_unknown, R.Reason_unmapped_runtime_state in
  check
    (Printf.sprintf
       "capacity lookalike remains opaque internal want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  check
    "opaque capacity lookalike is surfaced as unknown"
    (R.needs_operator_broadcast (fst got));
  let noncanonical_case =
    { receipt with terminal_reason_code = String.uppercase_ascii code }
  in
  let got = R.operator_disposition noncanonical_case in
  let want = R.Disp_unknown, R.Reason_unmapped_runtime_state in
  check
    (Printf.sprintf
       "noncanonical capacity casing stays opaque want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  check
    "noncanonical capacity casing is surfaced as unknown"
    (R.needs_operator_broadcast (fst got))
;;

let () =
  let code = "provider_error_timeout:http_operation" in
  check
    "provider timeout marker is transient"
    (Tr.is_transient_provider_runtime_failure (Tr.of_wire code));
  let receipt =
    { base_receipt with
      terminal_reason_code = code
    ; error_kind = Some (R.error_kind_of_string "provider")
    ; outcome = `Error
    ; runtime_outcome = R.Runtime_failed
    }
  in
  let got = R.operator_disposition receipt in
  let want = R.Disp_retry_later, R.Reason_transient_runtime_retry in
  check
    (Printf.sprintf
       "provider timeout marker disposition want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want)
  ;
  check
    "terminal transient retry-later does not page the operator"
    (not (R.needs_operator_broadcast (fst got)))
;;

let () =
  let code = "provider_error_parse" in
  check
    "provider parse marker is provider runtime failure"
    (match Tr.of_wire code with
     | Tr.Provider_runtime_failure wire -> String.equal wire code
     | _ -> false);
  check
    "provider parse marker is not transient"
    (not (Tr.is_transient_provider_runtime_failure (Tr.of_wire code)));
  let receipt =
    { base_receipt with
      terminal_reason_code = code
    ; error_kind = Some (R.error_kind_of_string "provider")
    ; outcome = `Error
    ; runtime_outcome = R.Runtime_failed
    }
  in
  let got = R.operator_disposition receipt in
  let want = R.Disp_retry_later, R.Reason_provider_runtime_error in
  check
    (Printf.sprintf
       "provider parse marker disposition want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  check
    "terminal provider rejection retry-later does not page the operator"
    (not (R.needs_operator_broadcast (fst got)))
;;

let () =
  let completed_receipt =
    { base_receipt with
      terminal_reason_code = "success"
    ; outcome = `Ok
    ; runtime_outcome = R.Runtime_completed
    ; completion_contract_result = R.Completion_no_visible_output
    }
  in
  let got = R.operator_disposition completed_receipt in
  let want = R.Disp_pass, R.Reason_healthy in
  check
    (Printf.sprintf
       "completed receipt ignores missing visible-output observation want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  let active_receipt = { completed_receipt with current_task_id = Some "TASK-1" } in
  let got = R.operator_disposition active_receipt in
  let want = R.Disp_pass, R.Reason_healthy in
  check
    (Printf.sprintf
       "active-task completion observation does not alter disposition want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  check
    "completion observation does not request an operator broadcast"
    (not (R.needs_operator_broadcast (fst got)))
;;

(* Completion evidence is an observation axis only. Varying work scope and
   world-observation context must not change the terminal disposition. *)
let () =
  let coordination_receipt ?(actionable_signal = Some C.No_actionable_signal) () =
    { base_receipt with
      terminal_reason_code = "success"
    ; outcome = `Ok
    ; runtime_outcome = R.Runtime_completed
    ; completion_contract_result = R.Completion_no_visible_output
    ; actionable_signal
    }
  in
  let got = R.operator_disposition (coordination_receipt ()) in
  let want = R.Disp_pass, R.Reason_healthy in
  check
    (Printf.sprintf
       "coordination keeper with goals + no actionable signal is healthy want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  check
    "healthy idle coordination turn does not need an operator broadcast"
    (not (R.needs_operator_broadcast (fst got)));
  let got =
    R.operator_disposition
      (coordination_receipt ~actionable_signal:(Some C.Has_unclaimed_tasks) ())
  in
  let want = R.Disp_pass, R.Reason_healthy in
  check
    (Printf.sprintf
       "completion observation with unclaimed tasks is still healthy want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  check
    "unclaimed-task completion observation does not request an operator broadcast"
    (not (R.needs_operator_broadcast (fst got)));
  let got = R.operator_disposition (coordination_receipt ~actionable_signal:None ()) in
  let want = R.Disp_pass, R.Reason_healthy in
  check
    (Printf.sprintf
       "completion evidence and world-observation absence remain independent want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want)
;;

let () =
  with_temp_dir "keeper-checkpoint-turn-persist" @@ fun workspace_dir ->
  let keeper_name = "checkpoint-turn-persist" in
  let config = Masc.Workspace.default_config workspace_dir in
  let meta : KMC.keeper_meta =
    meta_fixture_exn
      (`Assoc
        [ "name", `String keeper_name
        ; "trace_id", `String "trace-checkpoint-turn-persist"
        ])
  in
  write_meta_exn config meta;
  let original_meta = read_meta_exn config keeper_name in
  let usage = original_meta.runtime.usage in
  let updated_meta =
    { original_meta with
      runtime =
        { original_meta.runtime with
          usage =
            { usage with
              total_turns = usage.total_turns + 1
            ; last_turn_ts = 12345.0
            }
        }
    }
  in
  let terminal_outcome = UTS.Terminal_checkpoint in
  let returned =
    with_owner_inventory config (fun () ->
      UTS.persist_terminal_turn_meta_for_outcome
        ~config
        ~original_meta
        ~updated_meta
        ~terminal_outcome)
  in
  let persisted = read_meta_exn config keeper_name in
  check "checkpoint returns advanced turn usage"
    (returned.runtime.usage.total_turns = updated_meta.runtime.usage.total_turns);
  check
    "checkpoint persists advanced turn usage"
    (persisted.runtime.usage.total_turns = updated_meta.runtime.usage.total_turns)
;;

let () =
  with_temp_dir "keeper-success-clears-stale-provider-failure" @@ fun workspace_dir ->
  let keeper_name = "success-clears-stale-provider-failure" in
  let config = Masc.Workspace.default_config workspace_dir in
  let meta : KMC.keeper_meta =
    meta_fixture_exn
      (`Assoc
        [ "name", `String keeper_name
        ; "trace_id", `String "trace-success-clears-stale-provider-failure"
        ])
  in
  let run_result ?(stop_reason = Runtime_agent.Completed) ()
    : Masc.Keeper_agent_run.run_result
    =
    let prompt_metrics =
      Masc.Keeper_agent_prompt_metrics.build_prompt_metrics
        ~system_prompt:""
        ~dynamic_context:""
        ~user_message:""
    in
    let ctx_composition : Masc.Keeper_agent_prompt_metrics.ctx_composition_metrics =
      { actual_input_tokens = None
      ; attributed_bytes = 0
      ; segments = []
      }
    in
    let tool_surface : Masc.Keeper_agent_tool_surface.tool_surface_metrics =
      { turn_lane = Masc.Keeper_agent_tool_surface.Lane_tool_optional
      ; config_root = ""
      ; runtime_config_path = None
      }
    in
    { response_text = "completed"
    ; turn_outcome = Masc.Keeper_turn_outcome.Visible_reply
    ; terminal_effect_receipt = None
    ; model_used = "test-model"
    ; runtime_id = "test-runtime"
    ; max_context = 1000
    ; prompt_metrics
    ; ctx_composition
    ; runtime_observation = None
    ; turn_count = 1
    ; final_agent_core_turn_ordinal = 0
    ; usage = Masc.Inference_utils.zero_usage
    ; usage_reported = true
    ; usage_scope = Runtime_usage_scope.Per_request
    ; tool_calls = []
    ; completion_contract_result = R.Completion_tool_execution_observed
    ; operator_disposition = None
    ; checkpoint = None
    ; trace_ref = None
    ; run_validation = None
    ; stop_reason
    ; inference_telemetry = None
    ; tool_surface
    }
  in
  let direct_outcome =
    Masc.Keeper_execution_outcome.create
      ~lane:Masc.Keeper_execution_outcome.Direct
      (run_result ())
  in
  let autonomous_outcome =
    Masc.Keeper_execution_outcome.create
      ~lane:
        (Masc.Keeper_execution_outcome.Autonomous
           Masc.Keeper_world_observation.Reactive)
      (run_result ())
  in
  check
    "direct/autonomous normalize the same response"
    (String.equal
       (Masc.Keeper_execution_outcome.response_text direct_outcome)
       (Masc.Keeper_execution_outcome.response_text autonomous_outcome));
  check
    "direct/autonomous normalize the same terminal class"
    (Masc.Keeper_execution_outcome.terminal direct_outcome
     = Masc.Keeper_execution_outcome.terminal autonomous_outcome);
  check
    "direct projects through reactive metrics channel"
    (Masc.Keeper_execution_outcome.metrics_channel direct_outcome
     = Masc.Keeper_world_observation.Reactive);
  let reactive_success ~last_outcome ~last_reason =
    let proactive_rt =
      { meta.runtime.proactive_rt with last_outcome; last_reason }
    in
    let prior = { meta with runtime = { meta.runtime with proactive_rt } } in
    let reactive_event : Masc.Keeper_world_observation.pending_board_event =
      { event_kind = Masc.Keeper_world_observation.Board_post_created
      ; post_id = "reactive-success"
      ; author = "peer"
      ; title = "Reactive wake"
      ; preview = "Continue ordinary work."
      ; hearth = None
      ; post_kind = Masc.Board.Human_post
      ; updated_at = 0.0
      ; explicit_mention = false
      ; matched_targets = []
      ; self_commented = false
      ; new_external_since = 1
      ; latest_external_author = Some "peer"
      ; latest_external_preview = Some "Continue ordinary work."
      }
    in
    let observation : Masc.Keeper_world_observation.world_observation =
      { pending_messages = []
      ; pending_board_events = [ reactive_event ]
      ; idle_seconds = 0
      ; active_goals = []
      ; unclaimed_task_count = 0
      ; claimable_tasks = []
      ; held_task_skills = []
      ; failed_task_count = 0
      ; scheduled_automation =
          Masc.Keeper_world_observation.empty_scheduled_automation_observation
      ; backlog_revision = Some 1
      ; running_keeper_fiber_count = 0
      ; connected_surfaces = []
      ; connected_surface_failures = []
      ; own_recent_board_posts = []
      ; fleet_messages = []
      ; own_recent_actions = []
      }
    in
    Masc.Keeper_unified_metrics.update_metrics_from_result
      prior
      ~latency_ms:1
      ~observation
      ~is_autonomous_turn:false
      (run_result ())
  in
  let updated =
    reactive_success
      ~last_outcome:KMC.Proactive_error
      ~last_reason:"provider failure detail without a classifier prefix"
  in
  check
    "reactive success clears typed proactive error"
    (String.equal
       updated.runtime.proactive_rt.last_reason
       "unified:reactive_success");
  let error_like_reason = "unified:error:display text is not state" in
  let updated =
    reactive_success
      ~last_outcome:KMC.Proactive_text_response
      ~last_reason:error_like_reason
  in
  check
    "reactive success ignores error-like reason text"
    (String.equal updated.runtime.proactive_rt.last_reason error_like_reason);
  let stale_provider_failure =
    Masc.Keeper_registry.Provider_runtime_error
      { code = "api_error_invalid_request"
      ; detail = "stale quota from a previous runtime"
      ; provider_id = Some "kimi_code"
      ; http_status = None
      ; runtime_id = Some "kimi_code.kimi-for-coding"
      ; agent_core_timeout = None
      ; reason = None
      }
  in
  let registered_entry () =
    match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
    | Some entry -> entry
    | None -> failwith ("missing registered keeper " ^ keeper_name)
  in
  let latch_stale_provider_failure () =
    Masc.Keeper_registry.increment_turn_failures
      ~base_path:config.base_path
      keeper_name;
    Masc.Keeper_registry.set_failure_reason
      ~base_path:config.base_path
      keeper_name
      (Some stale_provider_failure)
  in
  Masc.Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:Masc.Keeper_registry.For_testing.clear
    (fun () ->
       ignore
         (Masc.Keeper_registry.For_testing.register
            ~base_path:config.base_path
            keeper_name
            meta);
       latch_stale_provider_failure ();
       UTS.reset_turn_failures_for_stop_reason ~config ~updated_meta:meta (run_result ());
       let entry_after_success = registered_entry () in
       check
         "successful terminal turn clears stale provider failure reason"
         (entry_after_success.last_failure_reason = None);
       check
         "successful terminal turn clears turn consecutive failures"
         (entry_after_success.turn_consecutive_failures = 0))
;;

let () =
  check
    "checkpoint failure blocks product success"
    (KTP.failure_blocks_product_success KTP.Checkpoint_store);
  check
    "receipt failure blocks product success"
    (KTP.failure_blocks_product_success KTP.Execution_receipt);
  check
    "Owner meta failure blocks product success"
    (KTP.failure_blocks_product_success KTP.Owner_meta);
  check
    "metrics failure cannot rewrite product success"
    (not (KTP.failure_blocks_product_success KTP.Metrics_snapshot));
  let observed = ref 0 in
  KTP.run_best_effort
    ~terminal_effect:KTP.Activity_graph
    ~on_error:(fun _ -> incr observed)
    (fun () -> failwith "injected activity projection failure");
  check "best-effort failure is observed once" (!observed = 1);
  let critical_rejected =
    try
      KTP.run_best_effort
        ~terminal_effect:KTP.Checkpoint_store
        ~on_error:(fun _ -> ())
        (fun () -> ());
      false
    with
    | Invalid_argument _ -> true
  in
  check "critical effect cannot enter best-effort wrapper" critical_rejected
;;

let () =
  check
    "observability artifacts all have consumer and retention owners"
    (KOAR.validate () = []);
  check
    "observability inventory covers the six audited stores"
    (List.length KOAR.entries = 6);
  check
    "observability artifacts never claim command authority"
    (match KOAR.to_yojson () with
     | `Assoc fields -> List.assoc_opt "command_authority" fields = Some (`Bool false)
     | _ -> false)
;;

let () =
  let member name = function
    | `Assoc fields -> Option.value ~default:`Null (List.assoc_opt name fields)
    | _ -> `Null
  in
  let string_member name json =
    match member name json with
    | `String value -> value
    | _ -> ""
  in
  let queue ~count ~oldest_age =
    `Assoc
      [ "status", `String "ok"
      ; "operator_action_required", `Bool false
      ; "counts_complete", `Bool true
      ; "read_error_count", `Int 0
      ; "transition_outbox_count", `Int 0
      ; "runnable_backlog_count", `Int count
      ; "runnable_oldest_age_seconds", oldest_age
      ; "recoverable_backlog_count", `Int 0
      ; "retained_disabled_backlog_count", `Int 0
      ; "paused_dead_backlog_count", `Int 0
      ; "shutdown_fenced_backlog_count", `Int 0
      ]
  in
  let stalled =
    Health_fleet.keeper_event_queue_health_dimensions
      ~stale_after_sec:300.0
      (queue ~count:2 ~oldest_age:(`Float 600.0))
  in
  check
    "healthy storage remains distinct from stalled work"
    (String.equal (string_member "status" (member "storage_integrity" stalled)) "ok"
     && String.equal (string_member "state" (member "work_liveness" stalled)) "stalled");
  check
    "stalled runnable work degrades queue status"
    (String.equal (string_member "status" stalled) "degraded");
  check
    "runnable backlog is never backlog-clean"
    (member "backlog_clean" stalled = `Bool false);
  let fresh_backlog =
    Health_fleet.keeper_event_queue_health_dimensions
      ~stale_after_sec:300.0
      (queue ~count:1 ~oldest_age:(`Float 5.0))
  in
  check
    "fresh runnable backlog is explicit warning, not ok"
    (String.equal (string_member "status" fresh_backlog) "warning");
  let recoverable =
    match queue ~count:0 ~oldest_age:`Null with
    | `Assoc fields ->
      `Assoc
        (("status", `String "degraded")
         :: ("operator_action_required", `Bool true)
         :: ("recoverable_backlog_count", `Int 2)
         :: List.remove_assoc "status"
              (List.remove_assoc "operator_action_required"
                 (List.remove_assoc "recoverable_backlog_count" fields)))
    | _ -> assert false
  in
  let recoverable =
    Health_fleet.keeper_event_queue_health_dimensions
      ~stale_after_sec:300.0
      recoverable
  in
  check
    "non-runnable actionable backlog carries an explicit reason"
    (match member "status_reasons" recoverable with
     (* The fixture above sets recoverable_backlog_count to 2, and the reason
        now carries it so an operator can tell two from two hundred. *)
     | `List reasons -> List.mem (`String "recoverable_backlog=2") reasons
     | _ -> false);
  check
    "non-runnable actionable backlog is never backlog-clean"
    (member "backlog_clean" recoverable = `Bool false);
  check
    "non-runnable actionable backlog reports blocked work"
    (String.equal
       (string_member "state" (member "work_liveness" recoverable))
       "blocked"
     && member "operator_action_required" (member "work_liveness" recoverable)
        = `Bool true);
  let projection_pending =
    match queue ~count:0 ~oldest_age:`Null with
    | `Assoc fields ->
      `Assoc
        (("transition_outbox_count", `Int 1)
         :: List.remove_assoc "transition_outbox_count" fields)
    | _ -> assert false
  in
  let projection_pending =
    Health_fleet.keeper_event_queue_health_dimensions
      ~stale_after_sec:300.0
      projection_pending
  in
  check
    "pending transition projection is never backlog-clean"
    (member "backlog_clean" projection_pending = `Bool false);
  let immediate_backlog =
    Health_fleet.keeper_event_queue_health_dimensions
      ~stale_after_sec:0.0
      (queue ~count:1 ~oldest_age:(`Float 0.0))
  in
  check
    "zero-second threshold degrades runnable backlog immediately"
    (String.equal (string_member "status" immediate_backlog) "degraded");
  check
    "zero-second threshold requires operator action immediately"
    (member "operator_action_required" immediate_backlog = `Bool true);
  let unavailable =
    Health_fleet.keeper_event_queue_health_dimensions
      ~stale_after_sec:300.0
      (`Assoc
         [ "status", `String "unavailable"
         ; "counts_complete", `Bool false
         ; "runnable_backlog_count", `Int 0
         ])
  in
  check
    "unavailable queue never claims backlog clean"
    (member "backlog_clean" unavailable = `Bool false)
;;

(* The shape reported on 2026-08-29: a turn routed to two lane candidates, the
   first failed, the second completed, and the receipt read attempt_count=1
   beside fallback_applied=true. Every one of the 208 failover receipts on disk
   said 1. The two counts answer different questions and both have to survive
   the projection. *)
let () =
  let failed_count, failed_fallback =
    Agent_run_receipt.lane_attempt_facts
      ~turn_succeeded:false
      ~last_attempt_index:1
  in
  check
    "a failed two-candidate lane retains both attempts"
    (failed_count = 2);
  check
    "a failed second candidate is not a successful fallback"
    (not failed_fallback);
  let successful_count, successful_fallback =
    Agent_run_receipt.lane_attempt_facts
      ~turn_succeeded:true
      ~last_attempt_index:1
  in
  check
    "a successful two-candidate lane retains both attempts"
    (successful_count = 2);
  check
    "a successful second candidate remains a fallback"
    successful_fallback;
  let failed_over =
    { base_receipt with
      runtime_attempt_count = 1
    ; runtime_lane_attempt_count = 2
    ; runtime_fallback_applied = true
    }
  in
  let runtime = Yojson.Safe.Util.member "runtime" (R.to_json failed_over) in
  check
    "a failover receipt reports the candidates the lane routed to"
    (Json_util.get_int runtime "lane_attempt_count" = Some 2);
  check
    "and still reports the winning runtime's own calls"
    (Json_util.get_int runtime "attempt_count" = Some 1);
  check
    "fallback stays visible beside them"
    (Yojson.Safe.Util.member "fallback_applied" runtime = `Bool true);
  let single =
    { base_receipt with
      runtime_attempt_count = 1
    ; runtime_lane_attempt_count = 1
    ; runtime_fallback_applied = false
    }
  in
  let single_runtime = Yojson.Safe.Util.member "runtime" (R.to_json single) in
  check
    "a turn that never failed over reports one candidate, not zero"
    (Json_util.get_int single_runtime "lane_attempt_count" = Some 1)
;;

let () =
  match !failures with
  | [] -> print_endline "test_keeper_terminal_reason_typed: OK"
  | xs ->
    List.iter (fun n -> print_endline ("FAIL: " ^ n)) (List.rev xs);
    failwith
      (Printf.sprintf "%d terminal-reason-typed assertion(s) failed" (List.length xs))
;;
