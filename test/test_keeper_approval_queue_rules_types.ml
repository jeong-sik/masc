open Alcotest

module Q = Keeper_approval_queue_rules_types

let yojson = testable Yojson.Safe.pretty_print Yojson.Safe.equal

let sample_rule =
  { Q.id = "rule-1"
  ; keeper_name = "keeper"
  ; tool_name = "external-effect"
  ; request_fingerprint = String.make 64 'a'
  ; created_at = 1780587600.0
  ; created_by = "operator"
  ; source_approval_id = "approval-1"
  ; expires_at = None
  }
;;

let test_advisory_judgment_round_trip () =
  List.iter
    (fun judgment ->
       let wire = Q.advisory_judgment_to_string judgment in
       check bool wire true (Q.advisory_judgment_of_string wire = Some judgment))
    [ Q.Approve; Q.Deny; Q.Require_human ];
  check (option reject) "unknown" None (Q.advisory_judgment_of_string "unknown")
;;

let test_summary_json_is_nonhierarchical () =
  let summary : Q.hitl_context_summary =
    { summary_version = 2
    ; generated_at = 1780587600.0
    ; model_run_id = "run-1"
    ; context_summary = "The exact action matches the active task."
    ; key_questions = [ "Is the target current?" ]
    ; judgment = Q.Approve
    ; rationale = "The visible evidence supports this exact request."
    }
  in
  let json = Q.hitl_context_summary_to_yojson summary in
  let member name = Yojson.Safe.Util.member name json in
  check yojson "judgment" (`String "approve") (member "judgment");
  check yojson "rationale" (`String summary.rationale) (member "rationale");
  check yojson "no numeric score" `Null (member "score");
  check yojson "no hierarchy" `Null (member "level");
  match
    Q.summary_status_of_yojson_with_error
      (Q.summary_status_to_yojson (Q.Summary_available summary))
  with
  | Error reason -> fail reason
  | Ok (Q.Summary_available parsed) ->
    check bool "judgment persisted" true (parsed.judgment = Q.Approve)
  | Ok (Q.Summary_not_requested | Q.Summary_pending | Q.Summary_failed _) ->
    fail "available summary did not round trip"
;;

let without_field field = function
  | `Assoc fields -> `Assoc (List.remove_assoc field fields)
  | json -> json
;;

let parse_rule json =
  match Q.approval_rule_of_yojson_with_error json with
  | Ok rule -> rule
  | Error reason -> fail reason
;;

let test_approval_rule_json_round_trip () =
  let parsed = Q.approval_rule_to_yojson sample_rule |> parse_rule in
  check string "id" sample_rule.id parsed.id;
  check string "fingerprint" sample_rule.request_fingerprint parsed.request_fingerprint
;;

let test_approval_rule_expiry_round_trip () =
  let rule = { sample_rule with Q.expires_at = Some 1780591200.0 } in
  let json = Q.approval_rule_to_yojson rule in
  check yojson "expires_at persisted" (`Float 1780591200.0)
    (Yojson.Safe.Util.member "expires_at" json);
  let parsed = parse_rule json in
  check (option (float 0.0)) "expires_at round trip" rule.expires_at parsed.expires_at
;;

let test_approval_rule_without_expiry_round_trip () =
  let json = Q.approval_rule_to_yojson sample_rule in
  check yojson "expires_at serialized as null" `Null
    (Yojson.Safe.Util.member "expires_at" json);
  let parsed = parse_rule json in
  check (option (float 0.0)) "null expires_at is no expiry" None parsed.expires_at
;;

let test_approval_rule_requires_expiry_field () =
  let json = Q.approval_rule_to_yojson sample_rule |> without_field "expires_at" in
  match Q.approval_rule_of_yojson_with_error json with
  | Ok _ -> fail "missing expires_at must be rejected"
  | Error reason -> check string "failure names expires_at" "expires_at is required" reason
;;

let test_rule_parser_rejects_malformed_expiry () =
  let malformed =
    match Q.approval_rule_to_yojson sample_rule with
    | `Assoc fields ->
      `Assoc (("expires_at", `String "soon") :: List.remove_assoc "expires_at" fields)
    | json -> json
  in
  match Q.approval_rule_of_yojson_with_error malformed with
  | Ok _ -> fail "malformed expires_at must not silently become a permanent rule"
  | Error reason ->
    check string "failure names expires_at" "expires_at must be a finite number or null"
      reason
;;

let test_rule_parser_requires_exact_nullable_fields () =
  let valid = Q.approval_rule_to_yojson sample_rule in
  let replace field value =
    match valid with
    | `Assoc fields -> `Assoc ((field, value) :: List.remove_assoc field fields)
    | json -> json
  in
  let cases =
    [ ( "missing created_by"
      , without_field "created_by" valid
      , "created_by is required" )
    ; ( "invalid created_by"
      , replace "created_by" (`Int 1)
      , "created_by must be a non-blank string" )
    ; ( "blank created_by"
      , replace "created_by" (`String " ")
      , "created_by must be a non-blank string" )
    ; ( "missing source_approval_id"
      , without_field "source_approval_id" valid
      , "source_approval_id is required" )
    ; ( "invalid source_approval_id"
      , replace "source_approval_id" (`Bool false)
      , "source_approval_id must be a non-blank string" )
    ; ( "invalid request fingerprint"
      , replace "request_fingerprint" (`String "abc")
      , "request_fingerprint must be a lowercase SHA-256" )
    ; ( "non-finite creation time"
      , replace "created_at" (`Float Float.nan)
      , "created_at must be a finite non-negative number" )
    ; ( "non-finite expiry"
      , replace "expires_at" (`Float Float.infinity)
      , "expires_at must be a finite number or null" )
    ; ( "expiry before creation"
      , replace "expires_at" (`Float (sample_rule.created_at -. 1.0))
      , "expires_at must be later than created_at or null" )
    ; ( "expiry at creation"
      , replace "expires_at" (`Float sample_rule.created_at)
      , "expires_at must be later than created_at or null" )
    ]
  in
  List.iter
    (fun (label, json, expected) ->
       match Q.approval_rule_of_yojson_with_error json with
       | Ok _ -> fail (label ^ " must be rejected")
       | Error reason -> check string label expected reason)
    cases
;;

let test_rule_expired_is_deterministic () =
  let expiring = { sample_rule with Q.expires_at = Some 1000.0 } in
  check bool "no expiry never expires" false (Q.rule_expired ~now:1e12 sample_rule);
  check bool "before expiry is active" false (Q.rule_expired ~now:999.0 expiring);
  check bool "expiry boundary is expired" true (Q.rule_expired ~now:1000.0 expiring);
  check bool "after expiry is expired" true (Q.rule_expired ~now:1000.5 expiring)
;;

let test_rule_parser_is_closed_and_explicit () =
  let valid = Q.approval_rule_to_yojson sample_rule in
  (match Q.approval_rule_of_yojson_with_error (without_field "keeper_name" valid) with
   | Ok _ -> fail "missing identity must be rejected"
   | Error _ -> ());
  let extended =
    match valid with
    | `Assoc fields -> `Assoc (("classification", `String "unsupported") :: fields)
    | json -> json
  in
  match Q.approval_rule_of_yojson_with_error extended with
  | Ok _ -> fail "unsupported persisted fields must require explicit re-approval"
  | Error reason ->
    check
      string
      "failure names unsupported field"
      "approval rule contains unsupported field classification; explicit re-approval is required"
      reason
;;

let test_rule_parser_rejects_duplicate_fields () =
  let duplicated =
    match Q.approval_rule_to_yojson sample_rule with
    | `Assoc fields -> `Assoc (("keeper_name", `String "other") :: fields)
    | json -> json
  in
  match Q.approval_rule_of_yojson_with_error duplicated with
  | Ok _ -> fail "duplicate persisted fields must require explicit re-approval"
  | Error reason ->
    check
      string
      "failure names duplicate field"
      "approval rule contains duplicate field keeper_name; explicit re-approval is required"
      reason
;;

let () =
  run
    "Keeper_approval_queue_rules_types"
    [ ( "judgment"
      , [ test_case "typed judgment round trip" `Quick test_advisory_judgment_round_trip
        ; test_case "summary has no hierarchy" `Quick test_summary_json_is_nonhierarchical
        ] )
    ; ( "exact rule"
      , [ test_case "JSON round trip" `Quick test_approval_rule_json_round_trip
        ; test_case "expiry JSON round trip" `Quick test_approval_rule_expiry_round_trip
        ; test_case
            "null expiry parses as no expiry"
            `Quick
            test_approval_rule_without_expiry_round_trip
        ; test_case
            "expiry field is required"
            `Quick
            test_approval_rule_requires_expiry_field
        ; test_case
            "malformed expiry rejected"
            `Quick
            test_rule_parser_rejects_malformed_expiry
        ; test_case
            "nullable fields and numbers are exact"
            `Quick
            test_rule_parser_requires_exact_nullable_fields
        ; test_case "expiry check is deterministic" `Quick test_rule_expired_is_deterministic
        ; test_case "closed explicit parser" `Quick test_rule_parser_is_closed_and_explicit
        ; test_case
            "duplicate fields rejected"
            `Quick
            test_rule_parser_rejects_duplicate_fields
        ] )
    ]
;;
