(** test_keeper_error_classify_recoverable — Generic Cascade_exhausted recovery.

    Covers the [recoverable_cascade_failure_reason] expansion that lets
    declarative [fallback_cascade] hints in cascade.toml actually escalate
    when a keeper's cascade exhausts without a more specific reason.

    Receipt-derived data on 2026-04-25 showed 31/39 silent keeper turns
    ended with [(null)] fallback_reason. The previous wildcard arm
    returned [None], which made [degraded_rotation_after_recoverable_error]
    skip declarative hints. *)

open Alcotest
module KEC = Masc_mcp.Keeper_error_classify
module Owne = Masc_mcp.Oas_worker_named
module KT = Masc_mcp.Keeper_types

let make_cascade_exhausted reason =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Cascade_exhausted { cascade_name = "test_cascade"; reason })
;;

let make_no_tool_capable () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.No_tool_capable_provider
       { cascade_name = "test_cascade"; configured_labels = [] })
;;

let make_accept_rejected () =
  Owne.sdk_error_of_masc_internal_error
    (Owne.Accept_rejected { scope = "test"; model = None; reason = "no body" })
;;

let test_other_detail_generic_recoverable () =
  let err = make_cascade_exhausted (KT.Other_detail "transport unavailable") in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check
      string
      "Other_detail (non-quota) -> cascade_exhausted"
      "cascade_exhausted"
      reason
  | None -> fail "Generic Cascade_exhausted with Other_detail should be recoverable"
;;

let test_all_providers_failed_recoverable () =
  let err = make_cascade_exhausted KT.All_providers_failed in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "All_providers_failed -> cascade_exhausted" "cascade_exhausted" reason
  | None -> fail "Cascade_exhausted with All_providers_failed should be recoverable"
;;

let test_no_providers_available_recoverable () =
  let err = make_cascade_exhausted KT.No_providers_available in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check string "No_providers_available -> cascade_exhausted" "cascade_exhausted" reason
  | None -> fail "Cascade_exhausted with No_providers_available should be recoverable"
;;

let test_candidates_filtered_specific_reason () =
  (* Specific reasons must keep their existing labels. *)
  let err = make_cascade_exhausted KT.Candidates_filtered_after_cycles in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    check
      string
      "Candidates_filtered keeps specific label"
      "cascade_candidates_filtered"
      reason
  | None -> fail "Candidates_filtered should be recoverable"
;;

let test_max_turns_specific_reason () =
  let err = make_cascade_exhausted KT.Max_turns_exceeded in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason -> check string "Max_turns keeps specific label" "max_turns" reason
  | None -> fail "Max_turns should be recoverable"
;;

let test_no_tool_capable_non_recoverable () =
  (* Conservative: other arms remain non-recoverable. *)
  let err = make_no_tool_capable () in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason ->
    fail (Printf.sprintf "No_tool_capable_provider should stay None, got %s" reason)
  | None -> ()
;;

let test_accept_rejected_non_recoverable () =
  let err = make_accept_rejected () in
  match KEC.recoverable_cascade_failure_reason err with
  | Some reason -> fail (Printf.sprintf "Accept_rejected should stay None, got %s" reason)
  | None -> ()
;;

let test_catalog_rotation_preserves_order_without_base_injection () =
  let err = make_cascade_exhausted KT.All_providers_failed in
  match
    KEC.degraded_rotation_after_recoverable_error
      ~rotation_cascades:[ "catalog_first"; "base_only" ]
      ~base_cascade:"base_only"
      ~effective_cascade:"tool_use_strict"
      ~tool_requirement:"optional"
      ~attempted_cascades:[ "tool_use_strict" ]
      err
  with
  | Some retry ->
    check string "catalog order wins" "catalog_first" retry.next_cascade;
    check string "fallback reason" "cascade_exhausted" retry.fallback_reason
  | None -> fail "Expected catalog-ordered degraded retry"
;;

let () =
  run
    "keeper_error_classify_recoverable"
    [ ( "recoverable_cascade_failure_reason"
      , [ test_case
            "Other_detail (non-quota) is recoverable"
            `Quick
            test_other_detail_generic_recoverable
        ; test_case
            "All_providers_failed is recoverable"
            `Quick
            test_all_providers_failed_recoverable
        ; test_case
            "No_providers_available is recoverable"
            `Quick
            test_no_providers_available_recoverable
        ; test_case
            "Candidates_filtered keeps specific reason"
            `Quick
            test_candidates_filtered_specific_reason
        ; test_case
            "Max_turns keeps specific reason"
            `Quick
            test_max_turns_specific_reason
        ; test_case
            "No_tool_capable stays non-recoverable"
            `Quick
            test_no_tool_capable_non_recoverable
        ; test_case
            "Accept_rejected stays non-recoverable"
            `Quick
            test_accept_rejected_non_recoverable
        ] )
    ; ( "degraded_rotation_after_recoverable_error"
      , [ test_case
            "catalog order is not prefixed by base cascade"
            `Quick
            test_catalog_rotation_preserves_order_without_base_injection
        ] )
    ]
;;
