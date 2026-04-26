(** #10341 — pin the [Agent_stress] timeout-class wiring.

    Pre-fix [Agent_stress] had exactly ONE emit site
    ([keeper_keepalive.ml:1141]) recording only [Failure_streak]
    for empty room presence.  Production
    [.masc/agent_stress.jsonl] showed 1 entry / 24h while
    [institution_episodes.jsonl] showed a 35% keeper turn failure
    rate over the same window.  The [stress_kind] variant already
    declared [Timeout] but no caller emitted it.

    [Memory_oas_bridge.store_failed_turn_episode] now fans out one
    [Timeout] stress event when the [error_kind] argument names a
    timeout-class failure from the OAS internal-error vocabulary.
    These tests pin the classifier — the IO side
    ([Agent_stress.record] -> JSONL) is exercised by
    [Agent_stress] tests separately; here we only assert the
    mapping is correct so the wiring itself is reviewable. *)

open Alcotest
module B = Masc_mcp.Memory_oas_bridge

(* --- timeout kinds map to [Some Timeout] ------------------------ *)

let test_oas_timeout_budget_maps () =
  match B.stress_kind_for_error_kind "oas_timeout_budget" with
  | Some Masc_mcp.Agent_stress.Timeout -> ()
  | _ -> failf "oas_timeout_budget should map to Timeout"
;;

let test_turn_timeout_maps () =
  match B.stress_kind_for_error_kind "turn_timeout" with
  | Some Masc_mcp.Agent_stress.Timeout -> ()
  | _ -> failf "turn_timeout should map to Timeout"
;;

let test_admission_queue_timeout_maps () =
  match B.stress_kind_for_error_kind "admission_queue_timeout" with
  | Some Masc_mcp.Agent_stress.Timeout -> ()
  | _ -> failf "admission_queue_timeout should map to Timeout"
;;

(* --- whitespace tolerance --------------------------------------- *)

let test_trims_whitespace () =
  match B.stress_kind_for_error_kind "  oas_timeout_budget  " with
  | Some Masc_mcp.Agent_stress.Timeout -> ()
  | _ -> failf "trimmed timeout kind should still map to Timeout"
;;

(* --- non-timeout kinds map to None (this cycle) ---------------- *)

let test_cascade_exhausted_does_not_map () =
  (* [cascade_exhausted] is semantically a fallback condition but
     the [Fallback_approval] variant has anti-rationalization
     semantics that doesn't fit cleanly here. Leave unmapped this
     cycle — the issue body explicitly defers other kinds to a
     follow-up tick. *)
  check
    (option string)
    "cascade_exhausted intentionally unmapped"
    None
    (B.stress_kind_for_error_kind "cascade_exhausted" |> Option.map (fun _ -> "mapped"))
;;

let test_resumable_cli_session_does_not_map () =
  check
    (option string)
    "resumable_cli_session intentionally unmapped"
    None
    (B.stress_kind_for_error_kind "resumable_cli_session"
     |> Option.map (fun _ -> "mapped"))
;;

let test_accept_rejected_does_not_map () =
  check
    (option string)
    "accept_rejected intentionally unmapped"
    None
    (B.stress_kind_for_error_kind "accept_rejected" |> Option.map (fun _ -> "mapped"))
;;

let test_no_tool_capable_provider_does_not_map () =
  check
    (option string)
    "no_tool_capable_provider intentionally unmapped"
    None
    (B.stress_kind_for_error_kind "no_tool_capable_provider"
     |> Option.map (fun _ -> "mapped"))
;;

let test_unknown_kind_does_not_map () =
  check
    (option string)
    "unknown free-form kind unmapped"
    None
    (B.stress_kind_for_error_kind "totally-novel-error-kind-10341"
     |> Option.map (fun _ -> "mapped"))
;;

let test_empty_kind_does_not_map () =
  check
    (option string)
    "empty kind unmapped (no spurious emit)"
    None
    (B.stress_kind_for_error_kind "" |> Option.map (fun _ -> "mapped"))
;;

(* --- timeout_error_kinds list contract -------------------------- *)

let test_timeout_kinds_list_is_three_items () =
  (* Fixed list pinned: future additions need a deliberate
     code+test change.  Drift would silently re-broaden the
     mapping. *)
  check int "exactly 3 timeout kinds wired" 3 (List.length B.timeout_error_kinds);
  check
    (list string)
    "stable order for log diffs"
    [ "oas_timeout_budget"; "turn_timeout"; "admission_queue_timeout" ]
    B.timeout_error_kinds
;;

let () =
  run
    "agent_stress_timeout_wire_10341"
    [ ( "timeout-kinds-mapped"
      , [ test_case "oas_timeout_budget -> Timeout" `Quick test_oas_timeout_budget_maps
        ; test_case "turn_timeout -> Timeout" `Quick test_turn_timeout_maps
        ; test_case
            "admission_queue_timeout -> Timeout"
            `Quick
            test_admission_queue_timeout_maps
        ] )
    ; "whitespace", [ test_case "trimmed kind still maps" `Quick test_trims_whitespace ]
    ; ( "non-timeout-kinds-unmapped-this-cycle"
      , [ test_case
            "cascade_exhausted unmapped"
            `Quick
            test_cascade_exhausted_does_not_map
        ; test_case
            "resumable_cli_session unmapped"
            `Quick
            test_resumable_cli_session_does_not_map
        ; test_case "accept_rejected unmapped" `Quick test_accept_rejected_does_not_map
        ; test_case
            "no_tool_capable_provider unmapped"
            `Quick
            test_no_tool_capable_provider_does_not_map
        ; test_case "unknown free-form unmapped" `Quick test_unknown_kind_does_not_map
        ; test_case "empty unmapped" `Quick test_empty_kind_does_not_map
        ] )
    ; ( "list-contract"
      , [ test_case
            "exactly 3 timeout kinds, stable order"
            `Quick
            test_timeout_kinds_list_is_three_items
        ] )
    ]
;;
