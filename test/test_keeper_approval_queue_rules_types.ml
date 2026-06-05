open Alcotest

module Q = Keeper_approval_queue_rules_types

let test_risk_level_conversions () =
  check string "critical string" "critical" (Q.risk_level_to_string Q.Critical);
  check int "medium int" 2 (Q.risk_level_to_int Q.Medium);
  check bool "parse high"
    true
    (match Q.risk_level_of_string "high" with
     | Some Q.High -> true
     | _ -> false)
;;

let sample_rule =
  { Q.id = "rule-1"
  ; keeper_name = "keeper"
  ; tool_name = "tool_execute"
  ; sandbox_profile = Some "local"
  ; backend = Some "sandbox"
  ; request_fingerprint = "abcdef1234567890"
  ; request_fingerprint_preview = "abcdef123456"
  ; max_risk = Q.High
  ; created_at = 1780587600.0
  ; created_by = Some "operator"
  ; last_matched_at = Some 1780587700.0
  ; match_count = 3
  ; source_approval_id = Some "approval-1"
  }
;;

let test_approval_rule_json_round_trip () =
  match Q.approval_rule_of_yojson (Q.approval_rule_to_yojson sample_rule) with
  | None -> fail "expected approval rule to parse"
  | Some parsed ->
    check string "id" sample_rule.id parsed.id;
    check string "fingerprint" sample_rule.request_fingerprint parsed.request_fingerprint;
    check int "match count" sample_rule.match_count parsed.match_count;
    check bool "risk" true (parsed.max_risk = Q.High)
;;

let test_blank_string_json_is_none () =
  check (option string) "blank" None (Q.string_opt_of_json (`String "  "))
;;

let () =
  run
    "Keeper_approval_queue_rules_types"
    [ ( "risk"
      , [ test_case "risk conversions" `Quick test_risk_level_conversions ] )
    ; ( "json"
      , [ test_case "approval rule round trip" `Quick test_approval_rule_json_round_trip
        ; test_case "blank string is none" `Quick test_blank_string_json_is_none
        ] )
    ]
;;
