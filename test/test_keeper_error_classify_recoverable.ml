(** test_keeper_error_classify_recoverable — Generic Cascade_exhausted recovery
    and status-code-aware cascade rotation.

    Covers the [recoverable_cascade_failure_reason] expansion that lets
    declarative [fallback_cascade] hints in cascade.toml actually escalate
    when a keeper's cascade exhausts without a more specific reason.

    Receipt-derived data on 2026-04-25 showed 31/39 silent keeper turns
    ended with [(null)] fallback_reason. The previous wildcard arm
    returned [None], which made [degraded_rotation_after_recoverable_error]
    skip declarative hints.

    Also covers status-code-aware rotation (P1: cascade exhaustion issue):
    raw 429 rate-limit, 5xx server errors, and 401/403 auth errors now
    trigger cascade rotation so a different provider/cascade can be tried
    instead of immediately failing the turn. *)

open Alcotest
module KEC = Masc_mcp.Keeper_error_classify
module Keeper_meta_contract = Masc_mcp.Keeper_meta_contract
module Owne = Masc_mcp.Keeper_turn_driver
module KT = Masc_mcp.Keeper_types
module Retry = Llm_provider.Retry

(* #19327 cascade purge: Cascade_name is now a plain string alias. *)
let cascade_name raw = Cascade_name.of_string_exn (String.trim raw)
;;

let test_cascade = cascade_name "cascade.test_cascade"

let make_runtime_exhausted reason =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Cascade_exhausted
       { cascade_name = test_cascade; reason })

let make_capacity_backpressure ?(source = Owne.Client_capacity)
    ?(detail = "client capacity key provider_k is full") () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Capacity_backpressure
       {
         cascade_name = test_cascade;
         source;
         detail;
         retry_after = Masc_mcp.Keeper_meta_contract.No_retry_hint;
       })

let make_no_tool_capable () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Cascade_exhausted
       { cascade_name = test_cascade
       ; reason = Keeper_meta_contract.No_tool_capable (Some
           { configured_labels = []
           ; required_tool_names = []
           ; provider_rejections = []
           })
       })

let make_accept_rejected () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Accept_rejected
       { scope = "test"; model = None; reason = "no body" })

let test_other_detail_generic_recoverable () =
  let err = make_runtime_exhausted (Keeper_meta_contract.Other_detail "transport unavailable") in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "Other_detail (non-quota) -> runtime_exhausted"
      "runtime_exhausted"
      (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "Generic Cascade_exhausted with Other_detail should be recoverable"

let test_slot_full_other_detail_maps_to_capacity_backpressure () =
  let err =
    make_runtime_exhausted
      (Keeper_meta_contract.Other_detail "slot full, cascading to next provider")
  in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    (* "slot full" matches capacity_backpressure via substring classification
       in recoverable_cascade_failure_reason. *)
    check string "slot full -> capacity_backpressure" "capacity_backpressure"
      (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "slot full should be capacity-backpressure recoverable"

let test_typed_capacity_backpressure_is_not_runtime_exhausted () =
  let err = make_capacity_backpressure () in
  check bool "typed capacity is auto-recoverable" true
    (KEC.is_auto_recoverable_turn_error err);
  check bool "typed capacity is not runtime_exhausted" false
    (KEC.is_runtime_exhausted_error err);
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "typed capacity -> capacity_backpressure" "capacity_backpressure"
      (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "typed capacity backpressure should be recoverable as capacity"

let test_provider_capacity_backpressure_is_capacity_backpressure () =
  let err =
    Agent_sdk.Error.Provider
      (Llm_provider.Error.CapacityExhausted
         {
           scope = Llm_provider.Error.CapacityProvider;
           affected = [ "runtime" ];
           retry_after = None;
           detail = "capacity exhausted";
         })
  in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "Provider CapacityExhausted -> capacity_backpressure"
      "capacity_backpressure"
      (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "Provider CapacityExhausted should be recoverable as capacity"

let test_all_providers_failed_recoverable () =
  let err = make_runtime_exhausted Keeper_meta_contract.All_providers_failed in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "All_providers_failed -> runtime_exhausted"
      "runtime_exhausted"
      (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "Cascade_exhausted with All_providers_failed should be recoverable"

let test_no_providers_available_recoverable () =
  let err = make_runtime_exhausted Keeper_meta_contract.No_providers_available in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "No_providers_available -> runtime_exhausted"
      "runtime_exhausted"
      (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "Cascade_exhausted with No_providers_available should be recoverable"

let test_candidates_filtered_specific_reason () =
  (* Specific reasons must keep their existing labels. *)
  let err = make_runtime_exhausted Keeper_meta_contract.Candidates_filtered_after_cycles in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "Candidates_filtered keeps specific label"
      "cascade_candidates_filtered"
      (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "Candidates_filtered should be recoverable"

let test_max_turns_specific_reason () =
  let err = make_runtime_exhausted Keeper_meta_contract.Max_turns_exceeded in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "Max_turns keeps specific label" "max_turns" (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "Max_turns should be recoverable"

let test_no_tool_capable_non_recoverable () =
  (* Conservative: other arms remain non-recoverable. *)
  let err = make_no_tool_capable () in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    fail
      (Printf.sprintf "No_tool_capable (inside Cascade_exhausted) should stay None, got %s"
         (KEC.degraded_retry_reason_to_string reason))
  | None -> ()

let test_accept_rejected_non_recoverable () =
  let err = make_accept_rejected () in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    fail
      (Printf.sprintf "Accept_rejected should stay None, got %s"
         (KEC.degraded_retry_reason_to_string reason))
  | None -> ()

(* Regression: auto-recoverable cascade exhaustion must still be
   classified as runtime_exhausted so that the unified turn loop's
   [counts_toward_crash] condition correctly increments the failure
   counter.  If is_auto_recoverable but NOT is_runtime_exhausted,
   the keeper loops forever without auto-pause. *)
let test_auto_recoverable_runtime_exhausted_is_still_runtime_exhausted () =
  let cases =
    [ (Keeper_meta_contract.Candidates_filtered_after_cycles, "Candidates_filtered_after_cycles")
    ; (Keeper_meta_contract.Max_turns_exceeded, "Max_turns_exceeded")
    ]
  in
  List.iter (fun (reason, label) ->
      let err = make_runtime_exhausted reason in
      (* These are auto-recoverable *)
      check bool (label ^ " is auto-recoverable") true
        (KEC.is_auto_recoverable_turn_error err);
      (* But they MUST also be runtime_exhausted *)
      check bool (label ^ " is runtime_exhausted") true
        (KEC.is_runtime_exhausted_error err)
    ) cases

let test_catalog_rotation_preserves_order_without_base_injection () =
  let err = make_runtime_exhausted Keeper_meta_contract.All_providers_failed in
  match
    KEC.degraded_rotation_after_recoverable_error
      ~base_runtime_id:"base_only"
      ~effective_runtime_id:"tool_use_strict"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_runtime_ids:[ "tool_use_strict" ]
      err
  with
  | Some retry ->
    check string "catalog order wins" "catalog_first" retry.next_runtime_id;
    check string "fallback reason" "runtime_exhausted"
      (KEC.degraded_retry_reason_to_string retry.fallback_reason)
  | None -> fail "Expected catalog-ordered degraded retry"

let test_rotation_skips_direct_tier_after_attempted_cascade () =
  let err = make_runtime_exhausted Keeper_meta_contract.Candidates_filtered_after_cycles in
  match
    KEC.degraded_rotation_after_recoverable_error
      ~base_runtime_id:"cascade.strict_tool_candidates"
      ~effective_runtime_id:"cascade.strict_tool_candidates"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_runtime_ids:[ "cascade.strict_tool_candidates" ]
      err
  with
  | Some retry ->
    check
      string
      "skip direct cascade duplicate"
      "cascade.provider_k-coding-with-spark"
      retry.next_runtime_id
  | None -> fail "Expected rotation to skip duplicate direct cascade candidate"

let test_required_tool_rotation_prioritizes_tool_route_before_fallback_hint () =
  let err =
    Owne.sdk_error_of_masc_internal_error
      (Owne.Resumable_cli_session
         {
           cascade_name = cascade_name "cascade.strict_tool_candidates";
           detail =
             "CLI JSON-stream transport reported a resumable session (exit 75). \
              Resumable session available via -r.";
           exit_code = Some 75;
         })
  in
  match
    KEC.degraded_rotation_after_recoverable_error
      ~fallback_hint:"ollama_cloud_stable"
      ~base_runtime_id:"strict_tool_candidates"
      ~effective_runtime_id:"strict_tool_candidates"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
      ~attempted_runtime_ids:[ "strict_tool_candidates" ]
      err
  with
  | Some retry ->
    check string "tool-required route wins" "provider_k-coding-with-spark"
      retry.next_runtime_id;
    check string "reason is resumable_cli_session" "resumable_cli_session"
      (KEC.degraded_retry_reason_to_string retry.fallback_reason)
  | None -> fail "Required-tool resumable session should use tool route"

let test_required_tool_rotation_uses_fallback_hint_after_tool_route_attempted () =
  let err =
    Owne.sdk_error_of_masc_internal_error
      (Owne.Resumable_cli_session
         {
           cascade_name = cascade_name "cascade.strict_tool_candidates";
           detail =
             "CLI JSON-stream transport reported a resumable session (exit 75). \
              Resumable session available via -r.";
           exit_code = Some 75;
         })
  in
  match
    KEC.degraded_rotation_after_recoverable_error
      ~fallback_hint:"ollama_cloud_stable"
      ~base_runtime_id:"strict_tool_candidates"
      ~effective_runtime_id:"strict_tool_candidates"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
      ~attempted_runtime_ids:[ "strict_tool_candidates"; "provider_k-coding-with-spark" ]
      err
  with
  | Some retry ->
    check string "explicit fallback hint remains terminal fallback"
      "ollama_cloud_stable" retry.next_runtime_id;
    check string "reason is resumable_cli_session" "resumable_cli_session"
      (KEC.degraded_retry_reason_to_string retry.fallback_reason)
  | None -> fail "Required-tool resumable session should use terminal fallback"

(* ---- Status-code-aware rotation tests ----------------------------------- *)

let test_soft_rate_limit_is_recoverable () =
  (* Non-hard-quota 429 with retry_after: should trigger cascade rotation so
     a different cascade/provider can be tried instead of burning turn budget
     retrying the rate-limited provider. *)
  let err =
    Agent_sdk.Error.Api
      (Retry.RateLimited { retry_after = Some 3.0; message = "too many requests" })
  in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "soft 429 -> rate_limit" "rate_limit" (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "Soft rate-limit should be recoverable (trigger cascade rotation)"

let test_soft_rate_limit_no_retry_after_is_recoverable () =
  (* Rate-limit without retry_after that is NOT a hard quota. *)
  let err =
    Agent_sdk.Error.Api
      (Retry.RateLimited { retry_after = None; message = "slow down" })
  in
  (* Pin the precondition explicitly so a classifier change cannot turn
     this assertion into a silent no-op. *)
  check bool "rate-limit fixture is not hard-quota" false
    (Owne.sdk_error_is_hard_quota err);
  (match KEC.recoverable_cascade_failure_reason err with
   | Some reason ->
     check string "no-retry_after rate_limit -> rate_limit" "rate_limit" (KEC.degraded_retry_reason_to_string reason)
   | None ->
     fail "Non-hard-quota RateLimited without retry_after should be recoverable")

let test_server_error_500_is_recoverable () =
  let err =
    Agent_sdk.Error.Api
      (Retry.ServerError { status = 500; message = "internal server error" })
  in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "500 -> server_error" "server_error" (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "ServerError 500 should be recoverable (trigger cascade rotation)"

let test_server_error_503_is_recoverable () =
  let err =
    Agent_sdk.Error.Api
      (Retry.ServerError { status = 503; message = "service unavailable" })
  in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "503 -> server_error" "server_error" (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "ServerError 503 should be recoverable (trigger cascade rotation)"

let test_server_error_502_is_recoverable () =
  let err =
    Agent_sdk.Error.Api
      (Retry.ServerError { status = 502; message = "bad gateway" })
  in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "502 -> server_error" "server_error" (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "ServerError 502 should be recoverable (trigger cascade rotation)"

let test_server_error_524_is_transient_network_error_and_cascade_rotation () =
  let err =
    Agent_sdk.Error.Api
      (Retry.ServerError { status = 524; message = "a timeout occurred" })
  in
  (* 524 is transient: a different provider may succeed where one origin
     timed out, so the cascade should advance. *)
  check bool "524 is transient network error" true (KEC.is_transient_network_error err);
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "524 -> capacity_backpressure" "capacity_backpressure"
      (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "ServerError 524 should be recoverable as capacity backpressure"

let test_wrapped_524_is_capacity_backpressure () =
  let err =
    make_runtime_exhausted
      (Keeper_meta_contract.Other_detail
         "all tiers failed (last runtime=runtime, error=Server error 524: error \
          code: 524)")
  in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "wrapped 524 -> capacity_backpressure" "capacity_backpressure"
      (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "Wrapped ServerError 524 should be recoverable as capacity backpressure"
let test_auth_error_is_recoverable () =
  (* 401/403 auth errors: the current cascade's credentials are invalid.
     A different cascade with different credentials may succeed. *)
  let err =
    Agent_sdk.Error.Api
      (Retry.AuthError { message = "invalid API key" })
  in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "auth error -> auth_error" "auth_error" (KEC.degraded_retry_reason_to_string reason)
  | None ->
    fail "AuthError should be recoverable (trigger cascade rotation)"

let test_hard_quota_not_reclassified_as_rate_limit () =
  (* Hard-quota RateLimited should still map to "hard_quota", not "rate_limit".
     The hard_quota check fires first in recoverable_cascade_failure_reason. *)
  let err =
    Agent_sdk.Error.Api
      (Retry.RateLimited { retry_after = None; message = "resource exhausted" })
  in
  check bool "hard-quota fixture is hard-quota" true
    (Owne.sdk_error_is_hard_quota err);
  (match KEC.recoverable_cascade_failure_reason err with
   | Some reason ->
     check string "hard quota keeps hard_quota label" "hard_quota" (KEC.degraded_retry_reason_to_string reason)
   | None ->
     fail "Hard quota should be recoverable with hard_quota label")

let test_server_error_400_not_recoverable_by_new_arm () =
  (* 4xx client errors below 500 should NOT be recovered by the server_error
     arm (only 5xx). A 400 bad request may recur on any provider. *)
  let err =
    Agent_sdk.Error.Api
      (Retry.ServerError { status = 400; message = "bad request" })
  in
  (* Should return None (not recoverable via server_error) unless some other
     arm catches it first — here it falls through to None. *)
  (match KEC.recoverable_cascade_failure_reason err with
   | Some KEC.Server_error ->
     fail "400 should NOT be classified as server_error by rotation arm"
   | _ -> ())

let test_rotation_finds_next_runtime_id_for_rate_limit () =
  (* End-to-end: soft rate limit on primary cascade should rotate to the
     next available candidate. *)
  let err =
    Agent_sdk.Error.Api
      (Retry.RateLimited { retry_after = Some 5.0; message = "throttled" })
  in
  match
    KEC.degraded_rotation_after_recoverable_error
      ~base_runtime_id:"primary"
      ~effective_runtime_id:"primary"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_runtime_ids:[ "primary" ]
      err
  with
  | Some retry ->
    check string "rotation goes to fallback" "fallback_cascade" retry.next_runtime_id;
    check string "reason is rate_limit" "rate_limit" (KEC.degraded_retry_reason_to_string retry.fallback_reason)
  | None ->
    fail "Soft rate-limit should trigger rotation to next cascade"

let test_rotation_finds_next_runtime_id_for_auth_error () =
  let err =
    Agent_sdk.Error.Api
      (Retry.AuthError { message = "unauthorized" })
  in
  match
    KEC.degraded_rotation_after_recoverable_error
      ~base_runtime_id:"primary"
      ~effective_runtime_id:"primary"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_runtime_ids:[ "primary" ]
      err
  with
  | Some retry ->
    check string "auth rotation goes to fallback" "fallback_cascade" retry.next_runtime_id;
    check string "reason is auth_error" "auth_error" (KEC.degraded_retry_reason_to_string retry.fallback_reason)
  | None ->
    fail "AuthError should trigger rotation to next cascade"

(* ---- Bare-name requalification tests (cascade-name-prefix-mismatch fix) ---- *)

(* #19327 cascade purge: test_normalized_runtime_id_requalifies_bare_tier_name
   removed.  It asserted bare "strict_tool_candidates" was rewritten to
   "cascade.strict_tool_candidates" using the prefix canonical form, which is
   no longer the semantics of [normalized_runtime_id]. *)

let test_normalized_runtime_id_passes_through_already_qualified () =
  let catalog_names = [ "strict_tool_candidates"; "primary" ] in
  let result =
    KEC.normalized_runtime_id ~catalog_names "cascade.strict_tool_candidates"
  in
  check string "already-qualified passes through"
    "cascade.strict_tool_candidates" result

let test_normalized_runtime_id_preserves_config_special_names () =
  let catalog_names = [] in
  let result =
    KEC.normalized_runtime_id ~catalog_names
      (Masc_mcp.Keeper_config.default_runtime_id ())
  in
  check string "phase_buffer preserved as-is"
    (Masc_mcp.Keeper_config.default_runtime_id ()) result

let test_normalized_runtime_id_falls_through_to_declared_name () =
  let catalog_names = [ "primary" ] in
  let result =
    KEC.normalized_runtime_id ~catalog_names "nonexistent_cascade"
  in
  check string "unknown name falls through" "nonexistent_cascade" result

let () =
  run "keeper_error_classify_recoverable"
    [
      ( "recoverable_cascade_failure_reason",
        [
          test_case "auto-recoverable cascade is still runtime_exhausted" `Quick
            test_auto_recoverable_runtime_exhausted_is_still_runtime_exhausted;
          test_case "Other_detail (non-quota) is recoverable" `Quick
            test_other_detail_generic_recoverable;
          test_case "slot full Other_detail maps to capacity backpressure" `Quick
            test_slot_full_other_detail_maps_to_capacity_backpressure;
          test_case "typed capacity backpressure is not cascade exhausted" `Quick
            test_typed_capacity_backpressure_is_not_runtime_exhausted;
          test_case "provider CapacityExhausted is capacity backpressure" `Quick
            test_provider_capacity_backpressure_is_capacity_backpressure;
          test_case "All_providers_failed is recoverable" `Quick
            test_all_providers_failed_recoverable;
          test_case "No_providers_available is recoverable" `Quick
            test_no_providers_available_recoverable;
          test_case "Candidates_filtered keeps specific reason" `Quick
            test_candidates_filtered_specific_reason;
          test_case "Max_turns keeps specific reason" `Quick
            test_max_turns_specific_reason;
          test_case "No_tool_capable stays non-recoverable" `Quick
            test_no_tool_capable_non_recoverable;
          test_case "Accept_rejected stays non-recoverable" `Quick
            test_accept_rejected_non_recoverable;
          test_case "soft 429 rate-limit is recoverable" `Quick
            test_soft_rate_limit_is_recoverable;
          test_case "rate-limit without retry_after (non-hard-quota) is recoverable" `Quick
            test_soft_rate_limit_no_retry_after_is_recoverable;
          test_case "ServerError 500 is recoverable" `Quick
            test_server_error_500_is_recoverable;
          test_case "ServerError 503 is recoverable" `Quick
            test_server_error_503_is_recoverable;
          test_case "ServerError 502 is recoverable" `Quick
            test_server_error_502_is_recoverable;
          test_case
            "ServerError 524 is transient network error and cascade rotation"
            `Quick
            test_server_error_524_is_transient_network_error_and_cascade_rotation;
          test_case "wrapped ServerError 524 is capacity backpressure" `Quick
            test_wrapped_524_is_capacity_backpressure;
          test_case "AuthError is recoverable" `Quick
            test_auth_error_is_recoverable;
          test_case "hard quota keeps hard_quota label" `Quick
            test_hard_quota_not_reclassified_as_rate_limit;
          test_case "ServerError 400 not classified as server_error" `Quick
            test_server_error_400_not_recoverable_by_new_arm;
        ] );
      ( "degraded_rotation_after_recoverable_error",
        [
          test_case "catalog order is not prefixed by base cascade" `Quick
            test_catalog_rotation_preserves_order_without_base_injection;
          test_case "skips direct cascade after attempted cascade" `Quick
            test_rotation_skips_direct_tier_after_attempted_cascade;
          test_case "required-tool rotation prefers tool route before fallback hint" `Quick
            test_required_tool_rotation_prioritizes_tool_route_before_fallback_hint;
          test_case "required-tool rotation keeps fallback hint after tool route" `Quick
            test_required_tool_rotation_uses_fallback_hint_after_tool_route_attempted;
          test_case "soft rate-limit rotates to next cascade" `Quick
            test_rotation_finds_next_runtime_id_for_rate_limit;
          test_case "auth error rotates to next cascade" `Quick
            test_rotation_finds_next_runtime_id_for_auth_error;
        ] );
      ( "normalized_runtime_id_bare_requalify",
        [
          (* #19327: "bare cascade name requalified with prefix" test removed. *)
          test_case "already-qualified name passes through" `Quick
            test_normalized_runtime_id_passes_through_already_qualified;
          test_case "config special names preserved" `Quick
            test_normalized_runtime_id_preserves_config_special_names;
          test_case "unknown name falls through to declared name" `Quick
            test_normalized_runtime_id_falls_through_to_declared_name;
        ] );
    ]
