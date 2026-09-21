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
module EC = Masc.Keeper_error_classify
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
  ; Keeper_internal_error.official_client_recovery_required_kind
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
      Keeper_internal_error.official_client_recovery_required_kind
  then
    R.Disp_operator_action_required, R.Reason_official_client_recovery_required
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
    && (Option.is_some receipt.degraded_retry_applied
        || Option.is_some receipt.degraded_retry_deferred)
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
  else if
    Option.is_some receipt.degraded_retry_applied
    || Option.is_some receipt.degraded_retry_deferred
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
  ; sandbox_kind = Keeper_types_profile_sandbox.Remote_ssh
  ; sandbox_root = None
  ; network_mode = Keeper_types_profile_sandbox.Network_none
  ; runtime_id = "runtime-1"
  ; runtime_selected_model = None
  ; runtime_attempt_count = 1
  ; runtime_lane_attempt_count = 1
  ; runtime_fallback_applied = false
  ; runtime_outcome = R.Runtime_completed
  ; agent_core_internal_runtime_allowed = true
  ; degraded_retry_applied = None
  ; degraded_retry_deferred = None
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
  let official_client_recovery =
    R.operator_disposition
      { base_receipt with
        terminal_reason_code =
          Keeper_internal_error.official_client_recovery_required_kind
      ; runtime_outcome = R.Runtime_not_dispatched
      }
  in
  check
    "official-client recovery requires operator action without a runtime claim"
    (official_client_recovery
     = ( R.Disp_operator_action_required
       , R.Reason_official_client_recovery_required ));
  check
    "official-client recovery emits an operator broadcast"
    (R.needs_operator_broadcast (fst official_client_recovery));
  check
    "official-client recovery reason keeps the canonical producer wire"
    (String.equal
       (R.operator_disposition_reason_to_string (snd official_client_recovery))
       Keeper_internal_error.official_client_recovery_required_kind);
  check
    "official-client recovery wire decodes to its closed terminal variant"
    (match
       Tr.of_wire Keeper_internal_error.official_client_recovery_required_kind
     with
     | Tr.Official_client_recovery_required wire ->
       String.equal wire Keeper_internal_error.official_client_recovery_required_kind
     | _ -> false);
  let fenced_error =
    Keeper_internal_error.Provider_attempt_effect_fenced
      { runtime_id = "antigravity_subscription.gemini-3-6-flash-high"
      ; effect_disposition = Keeper_provider_attempt_effect_core.Effect_attempted
      ; cause =
          Keeper_internal_error.Fenced_core
            (Keeper_request_failure_core.of_core_error
               (Agent_core.Error.Internal
                  "provider response did not prove whether the tool effect settled"))
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
      ; cause =
          Keeper_internal_error.Fenced_core
            (Keeper_request_failure_core.of_core_error
               (Agent_core.Error.Internal
                  "turn died after two corrective tool rejections"))
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

(* The receipt carries the two degraded-retry lanes separately: the one an
   earlier turn took up, and the one it leaves behind. Either puts the turn on
   a degraded-retry disposition, and a turn can hold both -- it took a lane up,
   failed there, and deferred another -- so the axis walks all four. *)
let applied_lane =
  { EC.next_runtime = "runtime-2"; fallback_reason = EC.Rate_limit }
;;

let deferred_lane =
  { EC.next_runtime = "runtime-3"; fallback_reason = EC.Deferred_runtime_lane }
;;

let degraded_lane_label = function
  | `Neither -> "neither"
  | `Applied -> "applied"
  | `Deferred -> "deferred"
  | `Both -> "both"
;;

let degraded_lanes_of_case = function
  | `Neither -> None, None
  | `Applied -> Some applied_lane, None
  | `Deferred -> None, Some deferred_lane
  | `Both -> Some applied_lane, Some deferred_lane
;;

let degraded_cases = [ `Neither; `Applied; `Deferred; `Both ]
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
                                     let degraded_retry_applied, degraded_retry_deferred =
                                       degraded_lanes_of_case degraded
                                     in
                                     let receipt =
                                       { base_receipt with
                                         terminal_reason_code = code
                                       ; error_kind
                                       ; degraded_retry_applied
                                       ; degraded_retry_deferred
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
                                              "disp-mismatch code=%S ek=%s out=%s ro=%s tcr=%s deg=%s fb=%b want=%s got=%s"
                                              code
                                              (match error_kind with
                                               | None -> "none"
                                               | Some k -> R.error_kind_to_string k)
                                              (R.outcome_kind_to_string outcome)
                                              (R.runtime_outcome_to_string
                                                 runtime_outcome)
                                              (R.completion_contract_result_to_string tcr)
                                              (degraded_lane_label degraded)
                                              fallback
                                              (disp_pair_to_string want)
                                              (disp_pair_to_string got))
                                           false))
                                  outcomes)
                             completion_contract_results)
                        runtime_outcomes)
                   fallback_bools)
              degraded_cases)
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
  let run_result
        ?(stop_reason = Runtime_agent.Completed)
        ?(usage = Masc.Inference_utils.zero_usage)
        ?(usage_scope = Runtime_usage_scope.Per_request)
        ?usage_basis
        ()
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
      ; attribution =
          Masc.Keeper_agent_prompt_metrics.Not_measured
            Masc.Keeper_agent_prompt_metrics.Dispatch_not_reached
      }
    in
    let tool_surface : Masc.Keeper_agent_tool_surface.tool_surface_metrics =
      { turn_lane = Masc.Keeper_agent_tool_surface.Lane_tool_optional
      ; config_root = ""
      ; runtime_config_path = None
      }
    in
    let usage_basis =
      Option.value
        ~default:
          (match usage_scope with
           | Runtime_usage_scope.Per_request -> Masc.Keeper_usage_resolution.Per_request
           | Runtime_usage_scope.Turn_total -> Masc.Keeper_usage_resolution.Turn_total
           | Runtime_usage_scope.Conversation_cumulative
           | Runtime_usage_scope.Usage_scope_unavailable ->
             Masc.Keeper_usage_resolution.Unavailable)
        usage_basis
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
    ; cooperative_boundary = None
    ; turn_count = 1
    ; final_agent_core_turn_ordinal = 0
    ; usage
    ; usage_reported = true
    ; usage_scope
    ; usage_basis
    ; tool_calls = []
    ; completion_contract_result = R.Completion_tool_execution_observed
    ; operator_disposition = None
    ; official_client_settlement = None
    ; checkpoint = None
    ; trace_ref = None
    ; run_validation = None
    ; stop_reason
    ; inference_telemetry = None
    ; tool_surface
    }
  in
  let direct_outcome =
    let () =
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      ignore (Masc.Workspace.init config ~agent_name:(Some "test"));
      let runtime_snapshot = Runtime.For_testing.snapshot () in
      Fun.protect ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot) @@ fun () ->
      let runtime_path = Filename.concat workspace_dir "runtime.toml" in
      Fs_compat.save_file runtime_path {|
[runtime]
default = "test_provider.test_model"
[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"
[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true
[test_provider.test_model]
is-default = true
max-concurrent = 1
|};
      (match Runtime.init_default ~config_path:runtime_path with
       | Ok () -> () | Error detail -> failwith detail);
      let meta =
        { meta with runtime =
            { meta.runtime with usage =
                { meta.runtime.usage with total_turns = 1 } } }
      in
      let call tool_name execution_outcome : Masc.Keeper_agent_result.tool_call_detail =
        { tool_name; provider = "test"; execution_outcome; typed_outcome = None
        ; latency_ms = 1.0; task_id = None; route_evidence = None
        ; input_fingerprint = None; output_fingerprint = None }
      in
      let result =
        { (run_result ()) with tool_calls =
            [ call "tool_read_file" Tool_result.Ok
            ; call "tool_read_file" Tool_result.Ok
            ; call "tool_write_file" Tool_result.Error ] }
      in
      let observation = Masc.Keeper_world_observation.observe
        ~pending_board_events:(Some []) ~config ~meta in
      Masc.Keeper_unified_metrics_decision.append_decision_record
        ~config ~meta ~observation ~latency_ms:3 ~outcome:"success"
        ~turn_ctx_cell:(Masc.Keeper_tool_call_log.create_turn_ctx_cell ())
        ~result:(Some result) ();
      let log_path = Masc.Keeper_types_support.keeper_decision_log_path config meta.name in
      let row = Fs_compat.load_file log_path |> String.split_on_char '\n'
        |> List.filter (fun row -> row <> "") |> List.rev |> List.hd
        |> Yojson.Safe.from_string in
      check "decision persists executed call count including failed calls"
        (Yojson.Safe.Util.member "tool_call_count" row = `Int 3);
      check "decision preserves repeated canonical tool names"
        (Yojson.Safe.Util.member "tools_used" row =
         `List [ `String "tool_read_file"; `String "tool_read_file";
                 `String "tool_write_file" ]);
      let aggregate = Model_inference_metrics.compute ~base_path:workspace_dir
        ~window_minutes:60 in
      let total_calls = List.fold_left
        (fun total (stats : Model_inference_metrics.model_stats) ->
           total + stats.total_tool_calls) 0 aggregate.models in
      check "persisted decision reaches dashboard model metrics" (total_calls = 3)
    in
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
  let reactive_success
        ?(prior = meta)
        ?(usage = Masc.Inference_utils.zero_usage)
        ?(usage_scope = Runtime_usage_scope.Per_request)
        ?usage_basis
        ~last_outcome
        ~last_reason
        ()
    =
    let proactive_rt =
      { prior.runtime.proactive_rt with last_outcome; last_reason }
    in
    let prior = { prior with runtime = { prior.runtime with proactive_rt } } in
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
      ; replies_after_own_comment = None
      ; latest_external_author = Some "peer"
      ; latest_external_preview = Some "Continue ordinary work."
      }
    in
    let observation : Masc.Keeper_world_observation.world_observation =
      { pending_messages = []
      ; pending_board_events = [ reactive_event ]
      ; idle_seconds = 0
      ; active_goals = Ok []
      ; unclaimed_task_count = 0
      ; claimable_tasks = []
      ; held_task_skills = []
      ; failed_task_count = 0
      ; scheduled_automation =
          Masc.Keeper_world_observation.empty_scheduled_automation_observation
      ; approval_authority =
          { revision = 1
          ; state = Masc.Keeper_world_observation.Approval_authority_complete
          ; pending = []
          }
      ; backlog_revision = Some 1
      ; running_keeper_fiber_count = 0
      ; connected_surfaces = []
      ; connected_surface_failures = []
      ; own_recent_board_posts = []
      ; fleet_messages = []
      ; own_recent_actions = Ok []
      }
    in
    let result = run_result ~usage ~usage_scope ?usage_basis () in
    let usage_resolution, usage_cursor =
      Masc.Keeper_usage_resolution.resolve
        ~cursor:prior.runtime.usage_cursor
        ~basis:result.usage_basis
        ~observation:(Some (Masc.Keeper_usage_resolution.sample_of_api_usage usage))
        ~observed_at:42.0
    in
    Masc.Keeper_unified_metrics.update_metrics_from_result
      prior
      ~latency_ms:1
      ~observation
      ~usage_resolution
      ~usage_cursor
      ~is_autonomous_turn:false
      result
  in
  let updated =
    reactive_success
      ~last_outcome:KMC.Proactive_error
      ~last_reason:"provider failure detail without a classifier prefix"
      ()
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
      ()
  in
  check
    "reactive success ignores error-like reason text"
    (String.equal updated.runtime.proactive_rt.last_reason error_like_reason);
  let prior_usage =
    { meta.runtime.usage with
      total_input_tokens = 100
    ; total_output_tokens = 20
    ; total_tokens = 120
    ; total_cost_usd = 1.5
    }
  in
  let prior = { meta with runtime = { meta.runtime with usage = prior_usage } } in
  let cumulative_usage =
    { Masc.Inference_utils.zero_usage with
      input_tokens = 9_000
    ; output_tokens = 900
    ; cost_usd = Some 12.0
    }
  in
  let cumulative =
    reactive_success
      ~prior
      ~usage:cumulative_usage
      ~usage_scope:Runtime_usage_scope.Conversation_cumulative
      ~usage_basis:
        (Masc.Keeper_usage_resolution.Conversation_counter
           { runtime_id = "antigravity"
           ; conversation_id = "conversation-1"
           ; position = Masc.Keeper_usage_resolution.Fresh
           })
      ~last_outcome:KMC.Proactive_unknown
      ~last_reason:"cumulative usage"
      ()
  in
  check
    "fresh conversation cumulative input is the first exact delta"
    (cumulative.runtime.usage.total_input_tokens = 9_100);
  check
    "fresh conversation cumulative output is the first exact delta"
    (cumulative.runtime.usage.total_output_tokens = 920);
  check
    "fresh conversation cumulative cost is the first exact delta"
    (Float.equal cumulative.runtime.usage.total_cost_usd 13.5);
  check
    "conversation cumulative raw observation remains visible"
    (cumulative.runtime.usage.last_input_tokens = 9_000
     && cumulative.runtime.usage.last_output_tokens = 900);
  let resumed_usage =
    { cumulative_usage with
      input_tokens = 9_500
    ; output_tokens = 940
    ; cost_usd = Some 12.4
    }
  in
  let resumed =
    reactive_success
      ~prior:cumulative
      ~usage:resumed_usage
      ~usage_scope:Runtime_usage_scope.Conversation_cumulative
      ~usage_basis:
        (Masc.Keeper_usage_resolution.Conversation_counter
           { runtime_id = "antigravity"
           ; conversation_id = "conversation-1"
           ; position = Masc.Keeper_usage_resolution.Resumed
           })
      ~last_outcome:KMC.Proactive_unknown
      ~last_reason:"resumed cumulative usage"
      ()
  in
  check
    "resumed cumulative input adds only the exact delta"
    (resumed.runtime.usage.total_input_tokens = 9_600);
  check
    "resumed cumulative output adds only the exact delta"
    (resumed.runtime.usage.total_output_tokens = 960);
  check
    "resumed cumulative cost adds only the exact delta"
    (Float.abs (resumed.runtime.usage.total_cost_usd -. 13.9) < 0.000_001);
  let resumed_without_baseline, established_cursor =
    Masc.Keeper_usage_resolution.resolve
      ~cursor:None
      ~basis:
        (Masc.Keeper_usage_resolution.Conversation_counter
           { runtime_id = "antigravity"
           ; conversation_id = "conversation-after-restart"
           ; position = Masc.Keeper_usage_resolution.Resumed
           })
      ~observation:
        (Some (Masc.Keeper_usage_resolution.sample_of_api_usage cumulative_usage))
      ~observed_at:43.0
  in
  check
    "resumed cumulative without a durable baseline stays unavailable"
    (resumed_without_baseline.status = Masc.Keeper_usage_resolution.Baseline_missing
     && Option.is_none resumed_without_baseline.delta
     && Option.is_some established_cursor);
  let regressed_usage =
    { cumulative_usage with input_tokens = 8_999 }
    |> Masc.Keeper_usage_resolution.sample_of_api_usage
  in
  let regressed, retained_cursor =
    Masc.Keeper_usage_resolution.resolve
      ~cursor:cumulative.runtime.usage_cursor
      ~basis:
        (Masc.Keeper_usage_resolution.Conversation_counter
           { runtime_id = "antigravity"
           ; conversation_id = "conversation-1"
           ; position = Masc.Keeper_usage_resolution.Resumed
           })
      ~observation:(Some regressed_usage)
      ~observed_at:44.0
  in
  check
    "same-conversation counter regression is not guessed to be a reset"
    (regressed.status = Masc.Keeper_usage_resolution.Counter_regressed
     && Option.is_none regressed.delta
     && retained_cursor = cumulative.runtime.usage_cursor);
  let cost_regressed_usage =
    { resumed_usage with cost_usd = Some 11.0 }
    |> Masc.Keeper_usage_resolution.sample_of_api_usage
  in
  let cost_regressed, _ =
    Masc.Keeper_usage_resolution.resolve
      ~cursor:cumulative.runtime.usage_cursor
      ~basis:
        (Masc.Keeper_usage_resolution.Conversation_counter
           { runtime_id = "antigravity"
           ; conversation_id = "conversation-1"
           ; position = Masc.Keeper_usage_resolution.Resumed
           })
      ~observation:(Some cost_regressed_usage)
      ~observed_at:44.5
  in
  check
    "cost counter regression cannot be labeled exact"
    (cost_regressed.status = Masc.Keeper_usage_resolution.Counter_regressed
     && Option.is_none cost_regressed.delta);
  let switched, switched_cursor =
    Masc.Keeper_usage_resolution.resolve
      ~cursor:cumulative.runtime.usage_cursor
      ~basis:
        (Masc.Keeper_usage_resolution.Conversation_counter
           { runtime_id = "antigravity-next"
           ; conversation_id = "conversation-2"
           ; position = Masc.Keeper_usage_resolution.Fresh
           })
      ~observation:
        (Some (Masc.Keeper_usage_resolution.sample_of_api_usage cumulative_usage))
      ~observed_at:45.0
  in
  check
    "runtime and conversation switch with Fresh replaces the cursor"
    ( switched.delta
      = Some (Masc.Keeper_usage_resolution.sample_of_api_usage cumulative_usage)
      && Option.fold
           ~none:false
           ~some:(fun cursor ->
             String.equal cursor.Masc.Keeper_usage_resolution.runtime_id "antigravity-next"
             && String.equal cursor.conversation_id "conversation-2")
           switched_cursor );
  let per_request_usage =
    { Masc.Inference_utils.zero_usage with
      input_tokens = 40
    ; output_tokens = 2
    ; cost_usd = Some 0.25
    }
  in
  let per_request =
    reactive_success
      ~prior
      ~usage:per_request_usage
      ~usage_scope:Runtime_usage_scope.Per_request
      ~last_outcome:KMC.Proactive_unknown
      ~last_reason:"per-request usage"
      ()
  in
  check
    "per-request input remains additive"
    (per_request.runtime.usage.total_input_tokens = 140);
  check
    "per-request output remains additive"
    (per_request.runtime.usage.total_output_tokens = 22);
  check
    "per-request cost remains additive"
    (Float.equal per_request.runtime.usage.total_cost_usd 1.75);
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
         (entry_after_success.turn_consecutive_failures = 0);
       (* A resolved native session can complete without a Keeper restart.
          Exercise the real store transitions and Completed success owner;
          the completed provider result is synthetic, not a provider call. *)
       let module Session = Masc.Keeper_official_client_session_store in
       let runtime_id = "synthetic-native-recovery" in
       let started =
         Session.claim ~base_path:config.base_path ~keeper_name ~expected:None
           ~client_kind:Session.Codex ~runtime_id
           ~owner_epoch:(Session.process_epoch ())
           ~tool_surface_sha256:(Session.tool_surface_sha256
             ~native_posture:Runtime_native_tools.Native_read []) ~updated_at:1.
         |> Result.get_ok
       in
       let held =
         Session.require_recovery ~base_path:config.base_path ~keeper_name
           ~expected:started ~failure:(Session.Input_rejected Session.Effect_fenced)
           ~detail:"synthetic observed tool activity" ~required_at:2.
         |> Result.get_ok
       in
       let claim_error, recovery_id =
         match Session.plan_claim ~expected:(Some held)
                 ~client_kind:Session.Codex ~runtime_id with
         | Error (Session.Input_recovery_required recovery as error) ->
           error, recovery.recovery_id
         | Error error -> failwith (Session.claim_error_to_string error)
         | Ok _ -> failwith "unresolved native recovery unexpectedly admitted a claim"
       in
       let core_error = Session.core_error_of_claim_error claim_error in
       let raw_error = Agent_core.Error.to_string core_error in
       let terminal = Masc.Keeper_turn_terminal.of_failure ~raw_error core_error in
       let reason =
         Masc.Keeper_unified_turn_types.registry_failure_reason_of_terminal_reason
           ~core_error terminal ~raw_error
       in
       Masc.Keeper_registry.set_failure_reason ~base_path:config.base_path
         keeper_name reason;
       check "native refusal increments failure debt"
         (Masc.Keeper_turn_failure_streak.increment
            ~base_path:config.base_path ~keeper_name = 1);
       let public_before_recovery =
         Option.bind (registered_entry ()).last_failure_reason
           Masc.Keeper_status_bridge.runtime_blocker_surface_of_failure_reason
         |> Option.map (fun surface -> surface.Masc.Keeper_status_bridge.blocker_class)
       in
       check "native refusal appears on the public status before recovery"
         (public_before_recovery = Some "official_client_recovery_required");
       let reopened, application =
         Session.resolve_recovery ~base_path:config.base_path ~keeper_name
           ~expected:held ~recovery_id ~resolution:Session.Restart_fresh
           ~resolved_by:"synthetic-operator" ~resolved_at:3.
         |> Result.get_ok
       in
       check "synthetic recovery resolution applied" (application = Session.Applied);
       check "resolved native session admits the next same-runtime claim"
         (Result.is_ok (Session.plan_claim ~expected:(Some reopened)
            ~client_kind:Session.Codex ~runtime_id));
       UTS.reset_turn_failures_for_stop_reason ~config ~updated_meta:meta (run_result ());
       let entry_after_recovery = registered_entry () in
       check "completed turn after recovery clears current failure"
         (entry_after_recovery.last_failure_reason = None);
       check "completed turn after recovery clears failure count"
         (entry_after_recovery.turn_consecutive_failures = 0);
       Masc.Keeper_heartbeat_loop.refresh_failure_reason_after_turn
         ~registry_entry:entry_after_recovery
         ~turn_fail_count:entry_after_recovery.turn_consecutive_failures;
       check "post-turn heartbeat refresh keeps the successful recovery clear"
         ((registered_entry ()).last_failure_reason = None);
       let public_after_recovery =
         Masc.Keeper_status_bridge.runtime_blocker_fields_json config meta
       in
       check "public current blocker is absent after recovery and completion"
         (List.assoc_opt "runtime_blocker_class" public_after_recovery = Some `Null
          && List.assoc_opt "runtime_blocker_summary" public_after_recovery = Some `Null);
       let check_repeated_yield_preserves_failure_state label stop_reason =
         Masc.Keeper_registry.For_testing.clear ();
         ignore
           (Masc.Keeper_registry.For_testing.register
              ~base_path:config.base_path
              keeper_name
              meta);
         latch_stale_provider_failure ();
         UTS.reset_turn_failures_for_stop_reason
           ~config
           ~updated_meta:meta
           (run_result ~stop_reason ());
         let entry_after_yield = registered_entry () in
         check
           (label ^ " preserves stale provider failure reason")
           (entry_after_yield.last_failure_reason = Some stale_provider_failure);
         check
           (label ^ " preserves turn consecutive failures")
           (entry_after_yield.turn_consecutive_failures = 1)
       in
       check_repeated_yield_preserves_failure_state
         "repeated tool stop"
         (Runtime_agent.Yielded_after_repeated_tool_call
            { turns_used = 3; tool_name = "board_post"; repeated_count = 3 });
       check_repeated_yield_preserves_failure_state
         "repeated assistant stop"
         (Runtime_agent.Yielded_after_repeated_assistant_text
            { turns_used = 3; repeated_count = 3 }))
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
  (* Counts only, matching the durable summary: it states no status and no
     operator_action_required, so the surface below is the only place either is
     decided. *)
  let queue ~count ~oldest_age =
    `Assoc
      [ "counts_complete", `Bool true
      ; "read_error_count", `Int 0
      ; "transition_outbox_count", `Int 0
      ; "runnable_backlog_count", `Int count
      ; "runnable_oldest_source_age_seconds", oldest_age
      ; "recoverable_backlog_count", `Int 0
      ; "retained_disabled_backlog_count", `Int 0
      ; "paused_dead_backlog_count", `Int 0
      ; "shutdown_fenced_backlog_count", `Int 0
      ]
  in
  let old_source =
    Health_fleet.keeper_event_queue_health_dimensions
      ~source_unavailable:false
      (queue ~count:2 ~oldest_age:(`Float 6000.0))
  in
  check
    "old source with healthy storage is backlogged, not a measured stall"
    (String.equal (string_member "status" (member "storage_integrity" old_source)) "ok"
     && String.equal (string_member "state" (member "work_liveness" old_source)) "backlogged");
  check "old source retains warning and exact pending count"
    (String.equal (string_member "status" old_source) "warning"
     && member "runnable_backlog_count" (member "work_liveness" old_source) = `Int 2);
  let residence = member "queue_residence" (member "work_liveness" old_source) in
  check "source age is not silently used as queue residence"
    (member "oldest_age_seconds" residence = `Null
     && string_member "status" residence = "unknown"
     && string_member "reason" residence = "first_admission_not_recorded"
     && member "runnable_oldest_source_age_seconds" (member "work_liveness" old_source) = `Float 6000.0);
  check "old source alone does not demand operator intervention"
    (member "operator_action_required" old_source = `Bool false);
  check "runnable backlog is never backlog-clean"
    (member "backlog_clean" old_source = `Bool false);
  let fresh_backlog =
    Health_fleet.keeper_event_queue_health_dimensions
      ~source_unavailable:false
      (queue ~count:1 ~oldest_age:(`Float 5.0))
  in
  check
    "fresh runnable backlog is explicit warning, not ok"
    (String.equal (string_member "status" fresh_backlog) "warning");
  let recoverable =
    match queue ~count:0 ~oldest_age:`Null with
    | `Assoc fields ->
      `Assoc
        (("recoverable_backlog_count", `Int 2)
         :: List.remove_assoc "recoverable_backlog_count" fields)
    | _ -> assert false
  in
  let recoverable =
    Health_fleet.keeper_event_queue_health_dimensions
      ~source_unavailable:false
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
      ~source_unavailable:false
      projection_pending
  in
  check
    "pending transition projection is never backlog-clean"
    (member "backlog_clean" projection_pending = `Bool false);
  let immediate_backlog =
    Health_fleet.keeper_event_queue_health_dimensions
      ~source_unavailable:false
      (queue ~count:1 ~oldest_age:(`Float 0.0))
  in
  check
    "new source is still pending work"
    (String.equal (string_member "status" immediate_backlog) "warning");
  check
    "new source does not demand operator action solely by age"
    (member "operator_action_required" immediate_backlog = `Bool false);
  let unavailable =
    Health_fleet.keeper_event_queue_health_dimensions
      ~source_unavailable:true
      (`Assoc
         [ "counts_complete", `Bool false
         ; "runnable_backlog_count", `Int 0
         ])
  in
  check
    "unavailable queue never claims backlog clean"
    (member "backlog_clean" unavailable = `Bool false);
  check "unavailable queue explains unknown residence"
    (string_member "reason" (member "queue_residence" unavailable) = "queue_observation_incomplete")
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
  let failed_third_count, failed_third_fallback =
    Agent_run_receipt.lane_attempt_facts
      ~turn_succeeded:false
      ~last_attempt_index:2
  in
  check
    "a failed three-candidate lane retains all routed attempts"
    (failed_third_count = 3);
  check
    "a failed third candidate is not a successful fallback"
    (not failed_third_fallback);
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

(* The shape the old bool and single runtime string could not carry: a turn
   that took up one lane and deferred another. The two used to share the
   runtime and reason slots, with the new deferral winning, so this receipt
   read "retry applied" beside the runtime nothing had run on yet (#37108).
   Each lane now travels with the reason it was deferred for. *)
let () =
  let both =
    { base_receipt with
      degraded_retry_applied = Some applied_lane
    ; degraded_retry_deferred = Some deferred_lane
    }
  in
  let runtime = Yojson.Safe.Util.member "runtime" (R.to_json both) in
  let lane key field =
    Json_util.get_string (Yojson.Safe.Util.member key runtime) field
  in
  check
    "the lane the turn took up names its own runtime"
    (lane "degraded_retry_applied" "runtime" = Some "runtime-2");
  check
    "and its own reason, not the other lane's"
    (lane "degraded_retry_applied" "reason" = Some "rate_limit");
  check
    "the lane the turn leaves behind names the other runtime"
    (lane "degraded_retry_deferred" "runtime" = Some "runtime-3");
  check
    "with the reason that deferred it"
    (lane "degraded_retry_deferred" "reason" = Some "deferred_runtime_lane");
  let neither = R.to_json base_receipt |> Yojson.Safe.Util.member "runtime" in
  check
    "a turn with no degraded retry says so with null, not an empty lane"
    (Yojson.Safe.Util.member "degraded_retry_applied" neither = `Null
     && Yojson.Safe.Util.member "degraded_retry_deferred" neither = `Null)
;;

(* The compact projection the dashboard composite reads. The receipt store has
   no version partition and [latest_json] hands back the newest row whatever
   its shape, so a keeper that has not taken a turn since the deploy is read
   here in its older shape: one bool under [degraded_retry_applied], and no
   [degraded_retry_deferred] at all. [json_member] answers `Null for a key that
   is not there, so reading the two fields on their own would mark the first
   unreadable and report the second as "this turn deferred no lane" -- a claim
   the old row cannot support. One shape verdict covers both fields. *)
let () =
  let compact runtime =
    Server_dashboard_compact_receipt_json.compact_receipt_runtime_json
      (`Assoc [ "runtime", runtime ])
  in
  let field json key name = Json_util.get_string (Yojson.Safe.Util.member key json) name in
  let unreadable json key =
    Yojson.Safe.Util.member "unreadable" (Yojson.Safe.Util.member key json)
  in
  let older_shape =
    compact
      (`Assoc
         [ "name", `String "runtime-1"
         ; "degraded_retry_applied", `Bool true
         ; "degraded_retry_runtime", `String "runtime-2"
         ; "fallback_reason", `String "rate_limit"
         ])
  in
  check
    "a row older than the split says its applied lane is unreadable"
    (unreadable older_shape "degraded_retry_applied" = `Bool true);
  check
    "and says the same of the field that did not exist yet"
    (unreadable older_shape "degraded_retry_deferred" = `Bool true);
  check
    "so the missing sibling never reads as an absent lane"
    (Yojson.Safe.Util.member "degraded_retry_deferred" older_shape <> `Null);
  let split_shape =
    compact
      (`Assoc
         [ "name", `String "runtime-1"
         ; ( "degraded_retry_applied"
           , `Assoc [ "runtime", `String "runtime-2"; "reason", `String "rate_limit" ] )
         ; "degraded_retry_deferred", `Null
         ])
  in
  check
    "a row of this generation reads the lane it took up"
    (field split_shape "degraded_retry_applied" "runtime" = Some "runtime-2"
     && field split_shape "degraded_retry_applied" "reason" = Some "rate_limit");
  check
    "and an absent lane on such a row stays absent"
    (Yojson.Safe.Util.member "degraded_retry_deferred" split_shape = `Null)
;;

(* #29929 gave [Terminal_effect_failed] its own operator disposition, but the
   wire it arrives on carries the call's parameters after the kind, and
   [wire_kind_of_string] compared the whole string. The reason decoded as
   [Unknown], so every such receipt still landed unmapped -- 178 of them on
   2026-09-01 alone. Read the kind, keep the parameters. *)
let () =
  let wire =
    Keeper_internal_error.terminal_effect_failed_kind
    ^ ":tool_use_id=call_a633eabea3a8,effect_disposition=effect_outcome_unknown"
  in
  check
    "a terminal-effect wire carrying parameters decodes to the closed variant"
    (match Tr.of_wire wire with
     | Tr.Terminal_effect_failed decoded -> String.equal decoded wire
     | _ -> false);
  check
    "that wire round-trips byte-identically"
    (String.equal (Tr.to_wire (Tr.of_wire wire)) wire);
  check
    "the bare kind still decodes to the same variant"
    (match Tr.of_wire Keeper_internal_error.terminal_effect_failed_kind with
     | Tr.Terminal_effect_failed _ -> true
     | _ -> false)
;;

(* RFC-0454 D1: a terminal effect failure says what failed as a typed value,
   and its JSON is objects all the way down. Every constructor survives the
   strict codec, and the codec refuses what it does not know instead of
   filling a default. *)
let () =
  let module D = Keeper_terminal_effect_detail in
  let samples =
    [ D.Tool_failed
        { internal_tool_name = "keeper_surface_post"; message = "dashboard append failed" }
    ; D.Composition_failed
        { composition_tool = "keeper_compose_sangokushi-2-end-command"
        ; cause =
            D.Node_failed
              { node_id = "press"
              ; model_tool_name = "masc_msx_press"
              ; message = "no MSX machine is loaded: call masc_msx_load first"
              }
        ; payload =
            `Assoc
              [ "composition_tool", `String "keeper_compose_sangokushi-2-end-command"
              ; "cause", `Assoc [ "kind", `String "tool_did_not_complete" ]
              ]
        }
    ; D.Composition_failed
        { composition_tool = "keeper_compose_plan"
        ; cause =
            D.Node_observation_failed
              { node_id = "read"
              ; model_tool_name = "BrowserRead"
              ; detail = "receipt append failed"
              }
        ; payload = `List [ `String "any JSON value is display payload" ]
        }
    ; D.Composition_failed
        { composition_tool = "keeper_compose_plan"
        ; cause =
            D.Plan_execution_failed
              { node_id = "post"; error = D.Input_validation_failed }
        ; payload = `Null
        }
    ; D.Composition_result_manifest_unpersisted
        { composition_tool = "keeper_compose_plan"; detail = "disk full" }
    ; D.Composition_evidence_unpublished
        { composition_tool = "keeper_compose_plan"; detail = "directory preparation failed" }
    ; D.Terminal_tool_receipt_missing { internal_tool_name = "keeper_surface_post" }
    ; D.Terminal_composition_receipt_missing { composition_tool = "keeper_compose_plan" }
    ; D.Output_artifact_unstored { message = "artifact store unavailable" }
    ; D.Output_over_inline_budget
        { message = "inline tool output exceeds descriptor budget (9 > 8 bytes)" }
    ; D.Result_delivery_failed { model_tool_name = "keeper_surface_post"; message = "image refused" }
    ; D.Boundary_observation_failed
        { model_tool_name = "keeper_surface_post"
        ; cause =
            Keeper_request_failure_core.of_core_error
              (Agent_core.Error.Internal "repetition snapshot invalid")
        }
    ; D.Agent_core_terminal_effect { detail = "terminal tool effect failed" }
    ]
    @ List.map
        (fun rejection ->
           D.Recovery_proposal_rejected
             { model_tool_name = "keeper_recovery_propose"
             ; rejection
             ; message = "atom 3 covered twice"
             })
        [ D.Recovery_store_failed
        ; D.Recovery_source_unavailable
        ; D.Recovery_submission_invalid
        ; D.Recovery_projection_rejected
        ]
    @ List.map
        (fun error ->
           D.Composition_failed
             { composition_tool = "keeper_compose_plan"
             ; cause = D.Plan_execution_failed { node_id = "post"; error }
             ; payload = `Null
             })
        [ D.Unknown_node_id
        ; D.Input_template_resolution_failed
        ; D.Input_validation_failed
        ; D.Output_validation_failed
        ; D.Output_not_composable
        ]
    @ List.map
        (fun deferral ->
           D.Composition_failed
             { composition_tool = "keeper_compose_sangokushi-2-end-command"
             ; cause =
                 D.Node_deferred
                   { node_id = "press"
                   ; model_tool_name = "masc_msx_press"
                   ; deferral
                   }
             ; payload = `Assoc [ "deferred", `Assoc [ "awaiting", `String "approval" ] ]
             })
        [ D.Deferral_unrecorded; D.Generic_deferral; D.External_effect_deferral ]
  in
  (* No wildcard: a new cause, plan error or rejection is a compile error here
     until it has a sample above. *)
  let composition_cause = function
    | D.Node_failed _ -> 0
    | D.Node_deferred _ -> 1
    | D.Node_observation_failed _ -> 2
    | D.Plan_execution_failed _ -> 3
  in
  let node_deferral = function
    | D.Deferral_unrecorded -> 0
    | D.Generic_deferral -> 1
    | D.External_effect_deferral -> 2
  in
  let plan_execution_error = function
    | D.Unknown_node_id -> 0
    | D.Input_template_resolution_failed -> 1
    | D.Input_validation_failed -> 2
    | D.Output_validation_failed -> 3
    | D.Output_not_composable -> 4
  in
  let recovery_rejection = function
    | D.Recovery_store_failed -> 0
    | D.Recovery_source_unavailable -> 1
    | D.Recovery_submission_invalid -> 2
    | D.Recovery_projection_rejected -> 3
  in
  check
    "terminal effect detail samples cover every composition cause"
    (List.sort_uniq
       Int.compare
       (List.filter_map
          (function
            | D.Composition_failed { cause; _ } -> Some (composition_cause cause)
            | _ -> None)
          samples)
     = List.init 4 Fun.id);
  check
    "terminal effect detail samples cover every node deferral"
    (List.sort_uniq
       Int.compare
       (List.filter_map
          (function
            | D.Composition_failed { cause = D.Node_deferred { deferral; _ }; _ } ->
              Some (node_deferral deferral)
            | _ -> None)
          samples)
     = List.init 3 Fun.id);
  check
    "terminal effect detail samples cover every plan execution error"
    (List.sort_uniq
       Int.compare
       (List.filter_map
          (function
            | D.Composition_failed { cause = D.Plan_execution_failed { error; _ }; _ } ->
              Some (plan_execution_error error)
            | _ -> None)
          samples)
     = List.init 5 Fun.id);
  check
    "terminal effect detail samples cover every recovery rejection"
    (List.sort_uniq
       Int.compare
       (List.filter_map
          (function
            | D.Recovery_proposal_rejected { rejection; _ } ->
              Some (recovery_rejection rejection)
            | _ -> None)
          samples)
     = List.init 4 Fun.id);
  (* No wildcard: a new constructor is a compile error here until it has a
     sample above. *)
  let constructor = function
    | D.Tool_failed _ -> 0
    | D.Composition_failed _ -> 1
    | D.Composition_result_manifest_unpersisted _ -> 2
    | D.Composition_evidence_unpublished _ -> 3
    | D.Terminal_tool_receipt_missing _ -> 4
    | D.Terminal_composition_receipt_missing _ -> 5
    | D.Output_artifact_unstored _ -> 6
    | D.Output_over_inline_budget _ -> 7
    | D.Result_delivery_failed _ -> 8
    | D.Boundary_observation_failed _ -> 9
    | D.Recovery_proposal_rejected _ -> 10
    | D.Agent_core_terminal_effect _ -> 11
  in
  check
    "terminal effect detail samples cover every constructor"
    (List.sort_uniq Int.compare (List.map constructor samples)
     = List.init 12 Fun.id);
  List.iter
    (fun detail ->
       let label = D.summary detail in
       check
         ("terminal effect detail round-trips through its codec: " ^ label)
         (D.of_yojson (Yojson.Safe.from_string (Yojson.Safe.to_string (D.to_yojson detail)))
          = Ok detail);
       let internal =
         Keeper_internal_error.Terminal_effect_failed
           { failure_class = Tool_result.Runtime_failure
           ; effect_disposition = Tool_result.Effect_outcome_unknown
           ; detail
           }
       in
       let json = Keeper_internal_error.masc_internal_error_to_json internal in
       check
         ("terminal_effect_failed carries its detail as an object: " ^ label)
         (match json with
          | `Assoc fields ->
            (match List.assoc_opt "detail" fields with
             | Some (`Assoc _) -> true
             | Some _ | None -> false)
          | _ -> false);
       check
         ("terminal_effect_failed round-trips through the internal error codec: " ^ label)
         (Keeper_internal_error.parse_masc_internal_error_json json = Some internal);
       check
         ("terminal_effect_failed has a one-line operator summary: " ^ label)
         (match Keeper_internal_error.summary_of_masc_internal_error internal with
          | Some text -> not (String.contains text '\n' || String.contains text '\r')
          | None -> false))
    samples;
  check
    "the incident composition summary names the failed node"
    (D.summary (List.nth samples 1)
     = "keeper_compose_sangokushi-2-end-command: press (masc_msx_press) failed: \
        no MSX machine is loaded: call masc_msx_load first");
  check
    "a plan failure summary names where and why the plan stopped"
    (D.summary (List.nth samples 3)
     = "keeper_compose_plan: plan stopped at post: input_validation_failed");
  check
    "a summary stays on one line when a leaf message spans lines"
    (D.summary
       (D.Tool_failed { internal_tool_name = "keeper_surface_post"; message = "first\nsecond\rthird" })
     = "keeper_surface_post failed: first second third");
  let rejects label json =
    check label (match D.of_yojson json with Error _ -> true | Ok _ -> false)
  in
  rejects
    "terminal effect detail refuses an unknown kind"
    (`Assoc [ "kind", `String "tool_exploded"; "message", `String "boom" ]);
  rejects
    "terminal effect detail refuses a missing field"
    (`Assoc [ "kind", `String "tool_failed"; "message", `String "boom" ]);
  rejects
    "terminal effect detail refuses a field it does not know"
    (`Assoc
        [ "kind", `String "output_artifact_unstored"
        ; "message", `String "boom"
        ; "severity", `String "high"
        ]);
  rejects
    "terminal effect detail refuses a value that is not an object"
    (`String "tool output artifact storage failed");
  rejects
    "terminal effect detail refuses a composition cause written as a string"
    (`Assoc
        [ "kind", `String "composition_failed"
        ; "composition_tool", `String "keeper_compose_plan"
        ; "cause", `String "node_failed"
        ; "payload", `Assoc []
        ]);
  rejects
    "terminal effect detail refuses a message that is not a string"
    (`Assoc
        [ "kind", `String "tool_failed"
        ; "internal_tool_name", `String "keeper_surface_post"
        ; "message", `Int 7
        ]);
  rejects
    "terminal effect detail refuses an unknown plan execution error"
    (`Assoc
        [ "kind", `String "composition_failed"
        ; "composition_tool", `String "keeper_compose_plan"
        ; ( "cause"
          , `Assoc
              [ "kind", `String "plan_execution_failed"
              ; "node_id", `String "post"
              ; "error", `String "went_sideways"
              ] )
        ; "payload", `Assoc []
        ]);
  rejects
    "terminal effect detail refuses an unknown recovery rejection"
    (`Assoc
        [ "kind", `String "recovery_proposal_rejected"
        ; "model_tool_name", `String "keeper_recovery_propose"
        ; "rejection", `String "somebody_said_no"
        ; "message", `String "boom"
        ]);
  check
    "terminal_effect_failed with an unreadable detail does not decode"
    (Keeper_internal_error.parse_masc_internal_error_json
       (`Assoc
           [ "kind", `String "terminal_effect_failed"
           ; "failure_class", `String "runtime_failure"
           ; "effect_disposition", `String "effect_outcome_unknown"
           ; "detail", `String "tool output artifact storage failed"
           ])
     = None)
;;

(* RFC-0454 D1 (P1b): a fenced provider attempt names what failed it as a
   value. The 2026-09-15 incident nested a MASC error inside a MASC error;
   written as a string that put a JSON document inside a JSON string, and
   every wrap added a layer of backslashes. *)
let () =
  let module D = Keeper_terminal_effect_detail in
  let core_of message =
    Keeper_request_failure_core.of_core_error (Agent_core.Error.Internal message)
  in
  let incident_detail =
    D.Composition_failed
      { composition_tool = "keeper_compose_sangokushi-2-end-command"
      ; cause =
          D.Node_failed
            { node_id = "press"
            ; model_tool_name = "masc_msx_press"
            ; message = "no MSX machine is loaded: call masc_msx_load first"
            }
      ; payload =
          `Assoc
            [ "composition_tool"
            , `String "keeper_compose_sangokushi-2-end-command"
            ; "cause", `Assoc [ "kind", `String "tool_did_not_complete" ]
            ]
      }
  in
  let nested_masc =
    Keeper_internal_error.Terminal_effect_failed
      { failure_class = Tool_result.Runtime_failure
      ; effect_disposition = Tool_result.Effect_outcome_unknown
      ; detail = incident_detail
      }
  in
  let causes =
    [ Keeper_internal_error.Fenced_masc nested_masc
    ; Keeper_internal_error.Fenced_core
        (core_of "Provider 'codex_app_server' unavailable: stdout closed")
    ; Keeper_internal_error.Fenced_core
        (Keeper_request_failure_core.of_core_error
           (Agent_core.Error.Api (Llm_provider.Retry.PaymentRequired
                                    { message = "Insufficient Balance" })))
    ]
  in
  (* No wildcard: a new cause arm is a compile error here until it has a
     sample above. *)
  let cause_index = function
    | Keeper_internal_error.Fenced_masc _ -> 0
    | Keeper_internal_error.Fenced_core _ -> 1
  in
  check
    "fence cause samples cover every arm"
    (List.sort_uniq Int.compare (List.map cause_index causes) = List.init 2 Fun.id);
  let envelopes =
    List.concat_map
      (fun cause ->
         [ Keeper_internal_error.Provider_attempt_effect_fenced
             { runtime_id = "claude_code.claude-sonnet-5"
             ; effect_disposition = Keeper_provider_attempt_effect_core.Effect_attempted
             ; cause
             }
         ; Keeper_internal_error.Tool_correction_lost
             { runtime_id = "claude_code.claude-sonnet-5"
             ; effect_disposition =
                 Keeper_provider_attempt_effect_core.Observation_unavailable
             ; reject_count = 2
             ; cause
             }
         ])
      causes
  in
  List.iter
    (fun envelope ->
       let json = Keeper_internal_error.masc_internal_error_to_json envelope in
       check
         "a fence writes its cause as an object, never a string"
         (match json with
          | `Assoc fields ->
            (match List.assoc_opt "cause" fields with
             | Some (`Assoc _) -> true
             | Some _ | None -> false)
          | _ -> false);
       check
         "a fence round-trips through the internal error codec"
         (Keeper_internal_error.parse_masc_internal_error_json json = Some envelope);
       check
         "a fence survives the carried-error string boundary"
         (Keeper_internal_error.classify_masc_internal_error
            (Keeper_internal_error.core_error_of_masc_internal_error envelope)
          = Some envelope))
    envelopes;
  (* The incident: a fence whose cause is a MASC terminal effect failure with a
     composition payload. Serialized, it must contain no escaped quote --
     that byte pair is what buried the one sentence a person needed. *)
  let incident =
    Keeper_internal_error.Provider_attempt_effect_fenced
      { runtime_id = "claude_code.claude-sonnet-5"
      ; effect_disposition = Keeper_provider_attempt_effect_core.Effect_attempted
      ; cause = Keeper_internal_error.Fenced_masc nested_masc
      }
  in
  let serialized =
    Yojson.Safe.to_string (Keeper_internal_error.masc_internal_error_to_json incident)
  in
  let contains_escaped_quote text =
    let rec loop i =
      if i + 1 >= String.length text then false
      else if text.[i] = '\\' && text.[i + 1] = '"' then true
      else loop (i + 1)
    in
    loop 0
  in
  check
    "the incident fence serializes with no escaped JSON document inside it"
    (not (contains_escaped_quote serialized));
  let contains ~needle text =
    let n = String.length needle and t = String.length text in
    let rec loop i = i + n <= t && (String.sub text i n = needle || loop (i + 1)) in
    n = 0 || loop 0
  in
  check
    "the incident sentence survives as its own leaf"
    (contains ~needle:"no MSX machine is loaded: call masc_msx_load first" serialized);
  check
    "the incident fence round-trips whole"
    (Keeper_internal_error.parse_masc_internal_error_json
       (Yojson.Safe.from_string serialized)
     = Some incident);
  let fence_rejects label cause =
    check
      label
      (Keeper_internal_error.parse_masc_internal_error_json
         (`Assoc
             [ "kind", `String Keeper_internal_error.provider_attempt_effect_fenced_kind
             ; "runtime_id", `String "claude_code.claude-sonnet-5"
             ; "effect_disposition", `String "effect_attempted"
             ; "cause", cause
             ])
       = None)
  in
  fence_rejects
    "a fence refuses a cause written as a string"
    (`String "Provider 'codex_app_server' unavailable: stdout closed");
  fence_rejects
    "a fence refuses a cause of an unknown kind"
    (`Assoc [ "kind", `String "fenced_prose"; "core", `Assoc [] ]);
  fence_rejects
    "a fence refuses a cause with a field it does not know"
    (`Assoc
        [ "kind", `String "fenced_core"
        ; "core", `Assoc [ "category", `String "io"; "message", `String "boom" ]
        ; "severity", `String "high"
        ]);
  fence_rejects
    "a fence refuses a core cause with an unknown category"
    (`Assoc
        [ "kind", `String "fenced_core"
        ; "core"
        , `Assoc [ "category", `String "vibes"; "message", `String "boom" ]
        ]);
  fence_rejects
    "a fence refuses a core cause missing its message"
    (`Assoc [ "kind", `String "fenced_core"; "core", `Assoc [ "category", `String "io" ] ]);
  check
    "a fence refuses a missing cause"
    (Keeper_internal_error.parse_masc_internal_error_json
       (`Assoc
           [ "kind", `String Keeper_internal_error.provider_attempt_effect_fenced_kind
           ; "runtime_id", `String "claude_code.claude-sonnet-5"
           ; "effect_disposition", `String "effect_attempted"
           ])
     = None);
  (* Every agent-core category has a wire spelling this module parses back. *)
  let category_index : Agent_core.Error.category -> int = function
    | Agent_core.Error.Api_category -> 0
    | Agent_core.Error.Provider_category -> 1
    | Agent_core.Error.Agent_category -> 2
    | Agent_core.Error.Mcp_category -> 3
    | Agent_core.Error.Config_category -> 4
    | Agent_core.Error.Serialization_category -> 5
    | Agent_core.Error.Io_category -> 6
    | Agent_core.Error.Orchestration_category -> 7
    | Agent_core.Error.Internal_category -> 8
  in
  let categories =
    [ Agent_core.Error.Api_category
    ; Agent_core.Error.Provider_category
    ; Agent_core.Error.Agent_category
    ; Agent_core.Error.Mcp_category
    ; Agent_core.Error.Config_category
    ; Agent_core.Error.Serialization_category
    ; Agent_core.Error.Io_category
    ; Agent_core.Error.Orchestration_category
    ; Agent_core.Error.Internal_category
    ]
  in
  check
    "the category samples cover every agent-core category"
    (List.sort_uniq Int.compare (List.map category_index categories)
     = List.init 9 Fun.id);
  List.iter
    (fun category ->
       let core = { Keeper_request_failure_core.category; message = "boom" } in
       check
         "a core failure round-trips through its codec"
         (Keeper_request_failure_core.of_yojson
            (Keeper_request_failure_core.to_yojson core)
          = Ok core))
    categories;
  check
    "a core failure summary stays on one line"
    (Keeper_request_failure_core.summary (core_of "first\nsecond\rthird")
     = "internal: first second third");
  (* The category says "internal" once. Agent-core renders an [Internal] error
     as "Internal error: <payload>", so keeping that rendering would say it
     twice. *)
  check
    "an internal failure's message is its payload, not agent-core's rendering"
    ((core_of "snapshot fingerprint invalid").Keeper_request_failure_core.message
     = "snapshot fingerprint invalid");
  (* The other families name the specific failure, which the coarse category
     does not carry, so their rendering is kept whole. *)
  check
    "a rate limit keeps what agent-core wrote"
    ((Keeper_request_failure_core.of_core_error
        (Agent_core.Error.Api
           (Llm_provider.Retry.RateLimited
              { retry_after = None; message = "slow down" })))
       .Keeper_request_failure_core.message
     = "Rate limited: slow down")
;;

let () =
  match !failures with
  | [] -> print_endline "test_keeper_terminal_reason_typed: OK"
  | xs ->
    List.iter (fun n -> print_endline ("FAIL: " ^ n)) (List.rev xs);
    failwith
      (Printf.sprintf "%d terminal-reason-typed assertion(s) failed" (List.length xs))
;;
