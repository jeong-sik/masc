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

let test_approval_rule_rejects_non_object_json () =
  check
    (option reject)
    "list input"
    None
    (Q.approval_rule_of_yojson (`List []));
  check
    (option reject)
    "string input"
    None
    (Q.approval_rule_of_yojson (`String "not-a-rule"))
;;

let test_approval_rule_rejects_malformed_object_json () =
  let without field =
    match Q.approval_rule_to_yojson sample_rule with
    | `Assoc fields -> `Assoc (List.remove_assoc field fields)
    | json -> json
  in
  check
    (option reject)
    "missing id"
    None
    (Q.approval_rule_of_yojson (without "id"));
  check
    (option reject)
    "blank keeper name"
    None
    (Q.approval_rule_of_yojson
       (`Assoc
           [ "id", `String "rule-1"
           ; "keeper_name", `String " "
           ; "tool_name", `String "tool_execute"
           ; "request_fingerprint", `String "abcdef"
           ; "max_risk", `String "high"
           ; "created_at", `Float 1780587600.0
           ; "match_count", `Int 0
           ]));
  check
    (option reject)
    "invalid max risk"
    None
    (Q.approval_rule_of_yojson
       (`Assoc
           [ "id", `String "rule-1"
           ; "keeper_name", `String "keeper"
           ; "tool_name", `String "tool_execute"
           ; "request_fingerprint", `String "abcdef"
           ; "max_risk", `String "god-mode"
           ; "created_at", `Float 1780587600.0
           ; "match_count", `Int 0
           ]));
  check
    (option reject)
    "missing max risk"
    None
    (Q.approval_rule_of_yojson (without "max_risk"));
  check
    (option reject)
    "invalid match count"
    None
    (Q.approval_rule_of_yojson
       (`Assoc
           [ "id", `String "rule-1"
           ; "keeper_name", `String "keeper"
           ; "tool_name", `String "tool_execute"
           ; "request_fingerprint", `String "abcdef"
           ; "max_risk", `String "high"
           ; "created_at", `Float 1780587600.0
           ; "match_count", `String "0"
           ]));
  check
    (option reject)
    "negative match count"
    None
    (Q.approval_rule_of_yojson
       (`Assoc
           [ "id", `String "rule-1"
           ; "keeper_name", `String "keeper"
           ; "tool_name", `String "tool_execute"
           ; "request_fingerprint", `String "abcdef"
           ; "max_risk", `String "high"
           ; "created_at", `Float 1780587600.0
           ; "match_count", `Int (-1)
           ]))
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
        ; test_case
            "approval rule rejects non-object json"
            `Quick
            test_approval_rule_rejects_non_object_json
        ; test_case
            "approval rule rejects malformed object json"
            `Quick
            test_approval_rule_rejects_malformed_object_json
        ; test_case "blank string is none" `Quick test_blank_string_json_is_none
        ] )
    ]
;;
