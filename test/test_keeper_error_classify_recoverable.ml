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
module Owne = Masc_mcp.Oas_worker_named
module KT = Masc_mcp.Keeper_types
module Retry = Llm_provider.Retry

let cascade_name raw = Owne.cascade_name_of_string raw

let make_cascade_exhausted reason =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Cascade_exhausted
       { cascade_name = cascade_name "test_cascade"; reason })

let make_no_tool_capable () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.No_tool_capable_provider
       {
         cascade_name = cascade_name "test_cascade";
         configured_labels = [];
         required_tool_names = [];
         provider_rejections = [];
       })

let make_accept_rejected () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Accept_rejected
       { scope = "test"; model = None; reason = "no body" })

let test_other_detail_generic_recoverable () =
  let err = make_cascade_exhausted (KT.Other_detail "transport unavailable") in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "Other_detail (non-quota) -> cascade_exhausted"
      "cascade_exhausted" reason
  | None ->
    fail "Generic Cascade_exhausted with Other_detail should be recoverable"

let test_all_providers_failed_recoverable () =
  let err = make_cascade_exhausted KT.All_providers_failed in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "All_providers_failed -> cascade_exhausted"
      "cascade_exhausted" reason
  | None ->
    fail "Cascade_exhausted with All_providers_failed should be recoverable"

let test_no_providers_available_recoverable () =
  let err = make_cascade_exhausted KT.No_providers_available in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "No_providers_available -> cascade_exhausted"
      "cascade_exhausted" reason
  | None ->
    fail "Cascade_exhausted with No_providers_available should be recoverable"

let test_candidates_filtered_specific_reason () =
  (* Specific reasons must keep their existing labels. *)
  let err = make_cascade_exhausted KT.Candidates_filtered_after_cycles in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "Candidates_filtered keeps specific label"
      "cascade_candidates_filtered" reason
  | None ->
    fail "Candidates_filtered should be recoverable"

let test_max_turns_specific_reason () =
  let err = make_cascade_exhausted KT.Max_turns_exceeded in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "Max_turns keeps specific label" "max_turns" reason
  | None ->
    fail "Max_turns should be recoverable"

let test_no_tool_capable_non_recoverable () =
  (* Conservative: other arms remain non-recoverable. *)
  let err = make_no_tool_capable () in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    fail
      (Printf.sprintf "No_tool_capable_provider should stay None, got %s"
         reason)
  | None -> ()

let test_accept_rejected_non_recoverable () =
  let err = make_accept_rejected () in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    fail
      (Printf.sprintf "Accept_rejected should stay None, got %s" reason)
  | None -> ()

(* Regression: auto-recoverable cascade exhaustion must still be
   classified as cascade_exhausted so that the unified turn loop's
   [counts_toward_crash] condition correctly increments the failure
   counter.  If is_auto_recoverable but NOT is_cascade_exhausted,
   the keeper loops forever without auto-pause. *)
let test_auto_recoverable_cascade_exhausted_is_still_cascade_exhausted () =
  let cases =
    [ (KT.Candidates_filtered_after_cycles, "Candidates_filtered_after_cycles")
    ; (KT.Max_turns_exceeded, "Max_turns_exceeded")
    ]
  in
  List.iter (fun (reason, label) ->
      let err = make_cascade_exhausted reason in
      (* These are auto-recoverable *)
      check bool (label ^ " is auto-recoverable") true
        (KEC.is_auto_recoverable_turn_error err);
      (* But they MUST also be cascade_exhausted *)
      check bool (label ^ " is cascade_exhausted") true
        (KEC.is_cascade_exhausted_error err)
    ) cases

let test_catalog_rotation_preserves_order_without_base_injection () =
  let err = make_cascade_exhausted KT.All_providers_failed in
  match
    KEC.degraded_rotation_after_recoverable_error
      ~rotation_cascades:[ "catalog_first"; "base_only" ]
      ~base_cascade:"base_only"
      ~effective_cascade:"tool_use_strict"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:[ "tool_use_strict" ]
      err
  with
  | Some retry ->
    check string "catalog order wins" "catalog_first" retry.next_cascade;
    check string "fallback reason" "cascade_exhausted" retry.fallback_reason
  | None -> fail "Expected catalog-ordered degraded retry"

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
    check string "soft 429 -> rate_limit" "rate_limit" reason
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
     check string "no-retry_after rate_limit -> rate_limit" "rate_limit" reason
   | None ->
     fail "Non-hard-quota RateLimited without retry_after should be recoverable")

let test_server_error_500_is_recoverable () =
  let err =
    Agent_sdk.Error.Api
      (Retry.ServerError { status = 500; message = "internal server error" })
  in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "500 -> server_error" "server_error" reason
  | None ->
    fail "ServerError 500 should be recoverable (trigger cascade rotation)"

let test_server_error_503_is_recoverable () =
  let err =
    Agent_sdk.Error.Api
      (Retry.ServerError { status = 503; message = "service unavailable" })
  in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "503 -> server_error" "server_error" reason
  | None ->
    fail "ServerError 503 should be recoverable (trigger cascade rotation)"

let test_server_error_502_is_recoverable () =
  let err =
    Agent_sdk.Error.Api
      (Retry.ServerError { status = 502; message = "bad gateway" })
  in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "502 -> server_error" "server_error" reason
  | None ->
    fail "ServerError 502 should be recoverable (trigger cascade rotation)"

let test_auth_error_is_recoverable () =
  (* 401/403 auth errors: the current cascade's credentials are invalid.
     A different cascade with different credentials may succeed. *)
  let err =
    Agent_sdk.Error.Api
      (Retry.AuthError { message = "invalid API key" })
  in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "auth error -> auth_error" "auth_error" reason
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
     check string "hard quota keeps hard_quota label" "hard_quota" reason
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
   | Some reason when reason = "server_error" ->
     fail "400 should NOT be classified as server_error by rotation arm"
   | _ -> ())

let test_rotation_finds_next_cascade_for_rate_limit () =
  (* End-to-end: soft rate limit on primary cascade should rotate to the
     next available candidate. *)
  let err =
    Agent_sdk.Error.Api
      (Retry.RateLimited { retry_after = Some 5.0; message = "throttled" })
  in
  match
    KEC.degraded_rotation_after_recoverable_error
      ~rotation_cascades:[ "primary"; "fallback_cascade" ]
      ~base_cascade:"primary"
      ~effective_cascade:"primary"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:[ "primary" ]
      err
  with
  | Some retry ->
    check string "rotation goes to fallback" "fallback_cascade" retry.next_cascade;
    check string "reason is rate_limit" "rate_limit" retry.fallback_reason
  | None ->
    fail "Soft rate-limit should trigger rotation to next cascade"

let test_rotation_finds_next_cascade_for_auth_error () =
  let err =
    Agent_sdk.Error.Api
      (Retry.AuthError { message = "unauthorized" })
  in
  match
    KEC.degraded_rotation_after_recoverable_error
      ~rotation_cascades:[ "primary"; "fallback_cascade" ]
      ~base_cascade:"primary"
      ~effective_cascade:"primary"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:[ "primary" ]
      err
  with
  | Some retry ->
    check string "auth rotation goes to fallback" "fallback_cascade" retry.next_cascade;
    check string "reason is auth_error" "auth_error" retry.fallback_reason
  | None ->
    fail "AuthError should trigger rotation to next cascade"

let () =
  run "keeper_error_classify_recoverable"
    [
      ( "recoverable_cascade_failure_reason",
        [
          test_case "auto-recoverable cascade is still cascade_exhausted" `Quick
            test_auto_recoverable_cascade_exhausted_is_still_cascade_exhausted;
          test_case "Other_detail (non-quota) is recoverable" `Quick
            test_other_detail_generic_recoverable;
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
          test_case "soft rate-limit rotates to next cascade" `Quick
            test_rotation_finds_next_cascade_for_rate_limit;
          test_case "auth error rotates to next cascade" `Quick
            test_rotation_finds_next_cascade_for_auth_error;
        ] );
    ]
