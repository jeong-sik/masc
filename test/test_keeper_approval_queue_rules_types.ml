open Alcotest

module Q = Keeper_approval_queue_rules_types

let yojson = testable Yojson.Safe.pretty_print Yojson.Safe.equal

let sample_rule =
  { Q.id = "rule-1"
  ; keeper_name = "keeper"
  ; tool_name = "external-effect"
  ; request_fingerprint = "abcdef1234567890"
  ; created_at = 1780587600.0
  ; created_by = Some "operator"
  ; source_approval_id = Some "approval-1"
  ; expires_at = None
  }
;;

(* ── what the box refused (RFC-0422) ─────────────────────────────────── *)

let refusal_testable =
  testable
    (fun fmt (r : Q.observed_refusal) ->
      Format.pp_print_string fmt (Yojson.Safe.to_string (Q.observed_refusal_to_yojson r)))
    ( = )
;;

let test_observed_refusal_json_round_trips () =
  List.iter
    (fun status ->
      let refusal =
        Q.observed_refusal ~max_stderr_bytes:4096 ~status ~stderr:"sh: cannot create w: Permission denied"
      in
      check (result refusal_testable string) "round trip" (Ok refusal)
        (Q.observed_refusal_of_yojson (Q.observed_refusal_to_yojson refusal)))
    [ Q.Observed_exit 2; Q.Observed_signal 15; Q.Observed_stopped 19 ]
;;

(* The tail is kept, the cut lands on a character boundary, and the bytes
   dropped are counted rather than marked inside the text. *)
let test_observed_stderr_is_bounded_to_its_tail () =
  let whole = Q.observed_refusal ~max_stderr_bytes:64 ~status:(Q.Observed_exit 1) ~stderr:"short" in
  check string "under the bound, untouched" "short" whole.observed_stderr;
  check int "nothing dropped" 0 whole.observed_stderr_omitted_bytes;
  let long = String.make 100 'a' ^ "tail" in
  let cut = Q.observed_refusal ~max_stderr_bytes:8 ~status:(Q.Observed_exit 1) ~stderr:long in
  check string "the last bytes survive" "aaaatail" cut.observed_stderr;
  check int "the dropped count is the prefix length" 96 cut.observed_stderr_omitted_bytes;
  (* "가" is three bytes; a bound landing inside it moves forward to the
     next character rather than splitting it. *)
  let korean = "x가나" in
  let boundary = Q.observed_refusal ~max_stderr_bytes:4 ~status:(Q.Observed_exit 1) ~stderr:korean in
  check string "no split character" "나" boundary.observed_stderr;
  check int "the partial character counts as dropped" 4 boundary.observed_stderr_omitted_bytes;
  let none = Q.observed_refusal ~max_stderr_bytes:0 ~status:(Q.Observed_exit 1) ~stderr:"abc" in
  check string "a zero bound keeps nothing" "" none.observed_stderr;
  check int "and drops everything" 3 none.observed_stderr_omitted_bytes
;;

let test_observed_refusal_decoder_is_closed () =
  let rejects label json =
    match Q.observed_refusal_of_yojson json with
    | Ok _ -> failf "%s decoded" label
    | Error _ -> ()
  in
  rejects "unknown kind"
    (`Assoc
       [ "status", `Assoc [ "kind", `String "crashed"; "code", `Int 1 ]
       ; "stderr", `String ""
       ; "stderr_omitted_bytes", `Int 0
       ]);
  rejects "missing stderr"
    (`Assoc [ "status", `Assoc [ "kind", `String "exit"; "code", `Int 1 ]; "stderr_omitted_bytes", `Int 0 ]);
  rejects "negative omitted"
    (`Assoc
       [ "status", `Assoc [ "kind", `String "exit"; "code", `Int 1 ]
       ; "stderr", `String ""
       ; "stderr_omitted_bytes", `Int (-1)
       ]);
  rejects "not an object" (`String "exit 1")
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

let test_approval_rule_json_round_trip () =
  match Q.approval_rule_of_yojson (Q.approval_rule_to_yojson sample_rule) with
  | None -> fail "expected exact approval rule to parse"
  | Some parsed ->
    check string "id" sample_rule.id parsed.id;
    check string "fingerprint" sample_rule.request_fingerprint parsed.request_fingerprint
;;

let test_approval_rule_expiry_round_trip () =
  let rule = { sample_rule with Q.expires_at = Some 1780591200.0 } in
  let json = Q.approval_rule_to_yojson rule in
  check yojson "expires_at persisted" (`Float 1780591200.0)
    (Yojson.Safe.Util.member "expires_at" json);
  match Q.approval_rule_of_yojson json with
  | None -> fail "expected expiring approval rule to parse"
  | Some parsed ->
    check (option (float 0.0)) "expires_at round trip" rule.expires_at parsed.expires_at
;;

let test_approval_rule_without_expiry_round_trip () =
  let json = Q.approval_rule_to_yojson sample_rule in
  check yojson "expires_at serialized as null" `Null
    (Yojson.Safe.Util.member "expires_at" json);
  let legacy = without_field "expires_at" json in
  match Q.approval_rule_of_yojson legacy with
  | None -> fail "pre-expiry persisted rule must still parse"
  | Some parsed ->
    check (option (float 0.0)) "missing expires_at is no expiry" None parsed.expires_at
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
    check string "failure names expires_at" "expires_at must be a number or null"
      reason
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
  check
    (option reject)
    "missing identity"
    None
    (Q.approval_rule_of_yojson (without_field "keeper_name" valid));
  let extended =
    match valid with
    | `Assoc fields -> `Assoc (("classification", `String "legacy") :: fields)
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

let test_summary_failed_has_no_retryable () =
  let failed = Q.Summary_failed { reason = "provider down" } in
  (match Q.summary_status_to_yojson failed with
   | `Assoc fields ->
     check
       (list string)
       "serialized fields"
       [ "status"; "reason" ]
       (List.map fst fields)
   | _ -> fail "Summary_failed must serialize as an object");
  let decode json = Q.summary_status_of_yojson_with_error json in
  (match
     decode (`Assoc [ "status", `String "failed"; "reason", `String "provider down" ])
   with
   | Ok status -> check bool "modern decode" true (status = failed)
   | Error e -> fail e);
  List.iter
    (fun retryable ->
       match
         decode
           (`Assoc
               [ "status", `String "failed"
               ; "reason", `String "provider down"
               ; "retryable", retryable
               ])
       with
       | Ok _ -> fail "removed retryable field must reject"
       | Error reason ->
         check
           string
           "removed field is explicit"
           "summary_status contains unsupported field retryable"
           reason)
    [ `Bool true; `String "yes" ]
;;

let () =
  run
    "Keeper_approval_queue_rules_types"
    [ ( "judgment"
      , [ test_case "typed judgment round trip" `Quick test_advisory_judgment_round_trip
        ; test_case "summary has no hierarchy" `Quick test_summary_json_is_nonhierarchical
        ] )
    ; ( "summary status"
      , [ test_case
            "retryable is rejected by the current contract"
            `Quick
            test_summary_failed_has_no_retryable
        ] )
    ; ( "exact rule"
      , [ test_case "JSON round trip" `Quick test_approval_rule_json_round_trip
        ; test_case "expiry JSON round trip" `Quick test_approval_rule_expiry_round_trip
        ; test_case
            "missing expiry parses as no expiry"
            `Quick
            test_approval_rule_without_expiry_round_trip
        ; test_case
            "malformed expiry rejected"
            `Quick
            test_rule_parser_rejects_malformed_expiry
        ; test_case "expiry check is deterministic" `Quick test_rule_expired_is_deterministic
        ; test_case "closed explicit parser" `Quick test_rule_parser_is_closed_and_explicit
        ; test_case
            "duplicate fields rejected"
            `Quick
            test_rule_parser_rejects_duplicate_fields
        ] )
    ; ( "observed refusal"
      , [ test_case "JSON round trip" `Quick test_observed_refusal_json_round_trips
        ; test_case "stderr is bounded to its tail" `Quick test_observed_stderr_is_bounded_to_its_tail
        ; test_case "decoder is closed" `Quick test_observed_refusal_decoder_is_closed
        ] )
    ]
;;
