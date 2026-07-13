open Alcotest
open Masc

module Contract = Keeper_failure_judgment_contract

let require_ok = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let expect_error label json =
  match Contract.of_yojson json with
  | Error _ -> ()
  | Ok _ -> failf "%s unexpectedly decoded" label
;;

let test_resume_with_guidance () =
  let verdict =
    Contract.of_yojson
      (`Assoc
        [ "decision", `String "resume_with_guidance"
        ; "guidance", `String "Inspect the typed failure and choose different work."
        ; "rationale", `String "The lane can act without external mutation."
        ])
    |> require_ok
  in
  match verdict with
  | Contract.Resume_with_guidance { guidance; rationale } ->
    check
      string
      "guidance preserved"
      "Inspect the typed failure and choose different work."
      guidance;
    check
      string
      "rationale preserved"
      "The lane can act without external mutation."
      rationale
  | Contract.Await_external_input _ -> fail "resume verdict changed variant"
;;

let test_await_external_input () =
  let verdict =
    Contract.of_yojson
      (`Assoc
        [ "decision", `String "await_external_input"
        ; "guidance", `Null
        ; "rationale", `String "Required external input is unavailable."
        ])
    |> require_ok
  in
  match verdict with
  | Contract.Await_external_input { rationale } ->
    check
      string
      "rationale preserved"
      "Required external input is unavailable."
      rationale
  | Contract.Resume_with_guidance _ -> fail "external-input verdict changed variant"
;;

let test_invalid_shapes_fail_closed () =
  expect_error
    "unknown decision"
    (`Assoc
      [ "decision", `String "retry"
      ; "guidance", `Null
      ; "rationale", `String "unsupported"
      ]);
  expect_error
    "extra field"
    (`Assoc
      [ "decision", `String "await_external_input"
      ; "guidance", `Null
      ; "rationale", `String "external input required"
      ; "score", `Float 0.9
      ]);
  expect_error
    "duplicate field"
    (`Assoc
      [ "decision", `String "await_external_input"
      ; "decision", `String "resume_with_guidance"
      ; "guidance", `Null
      ; "rationale", `String "ambiguous"
      ]);
  expect_error
    "resume without guidance"
    (`Assoc
      [ "decision", `String "resume_with_guidance"
      ; "guidance", `Null
      ; "rationale", `String "missing instruction"
      ]);
  expect_error
    "external-input verdict with guidance"
    (`Assoc
      [ "decision", `String "await_external_input"
      ; "guidance", `String "keep going"
      ; "rationale", `String "contradictory payload"
      ]);
  expect_error
    "empty rationale"
    (`Assoc
      [ "decision", `String "await_external_input"
      ; "guidance", `Null
      ; "rationale", `String "  "
      ])
;;

let test_canonical_roundtrip () =
  let original =
    Contract.Resume_with_guidance
      { guidance = "Move to a different actionable task."
      ; rationale = "The Keeper has enough evidence for another action."
      }
  in
  let parsed = Contract.to_yojson original |> Contract.of_yojson |> require_ok in
  check bool "canonical verdict round-trips" true (parsed = original)
;;

let test_typed_judge_error_disposition () =
  let check_disposition label error =
    check
      bool
      label
      true
      (Keeper_failure_judge.error_disposition error
       = Keeper_failure_judge.Escalate_judge_failure)
  in
  check_disposition
    "OAS retryable error terminates at the single judge boundary"
    (Keeper_failure_judge.Oas_error
       { runtime_id = "structured-judge"
       ; error =
           Agent_sdk.Error.Api
             (Llm_provider.Retry.RateLimited
                { retry_after = None; message = "slow down" })
       });
  check_disposition
    "OAS credential error cannot rotate a single judge runtime"
    (Keeper_failure_judge.Oas_error
       { runtime_id = "structured-judge"
       ; error =
           Agent_sdk.Error.Api
             (Llm_provider.Retry.AuthError { message = "401" })
       });
  check_disposition
    "deterministic OAS error escalates"
    (Keeper_failure_judge.Oas_error
       { runtime_id = "structured-judge"
       ; error =
           Agent_sdk.Error.Api
             (Llm_provider.Retry.InvalidRequest
                { message = "bad request"
                ; reason = Llm_provider.Retry.Unknown_invalid_request
                })
       });
  check_disposition
    "judge idle loop terminates instead of requeueing itself"
    (Keeper_failure_judge.Oas_error
       { runtime_id = "structured-judge"
       ; error =
           Agent_sdk.Error.Agent
             (Agent_sdk.Error.IdleDetected { consecutive_idle_turns = 15 })
       });
  check_disposition
    "response contract error escalates"
    (Keeper_failure_judge.Response_contract_error
       { runtime_id = "structured-judge"; detail = "invalid JSON" })
;;

let failure_event post_id : Keeper_world_observation.pending_board_event =
  { event_kind = Keeper_world_observation.Failure_judgment
  ; post_id
  ; author = "keeper-a"
  ; title = "original failure"
  ; preview = "original detail"
  ; hearth = None
  ; post_kind = Board.System_post
  ; updated_at = 1.0
  ; explicit_mention = false
  ; matched_targets = []
  ; self_commented = false
  ; new_external_since = 1
  ; latest_external_author = None
  ; latest_external_preview = None
  ; provenance = Keeper_world_observation.Self_narrative
  }
;;

let test_guidance_binds_exact_observation () =
  let post_id = "failure-judgment:runtime:contract_violation:oas_agent_error" in
  let guidance = "Inspect the failed contract and choose independent useful work." in
  let events =
    Keeper_world_observation.apply_failure_judgment_guidance
      ~post_id
      ~judge_runtime_id:"structured-judge"
      ~guidance
      ~rationale:"The Keeper has enough evidence for another action."
      [ failure_event post_id ]
    |> require_ok
  in
  let event =
    match events with
    | [ event ] -> event
    | _ -> fail "guidance changed event cardinality"
  in
  let open Yojson.Safe.Util in
  let preview = Yojson.Safe.from_string event.preview in
  check
    string
    "judge runtime remains opaque"
    "structured-judge"
    (preview |> member "judge_runtime_id" |> to_string);
  let verdict =
    preview
    |> member "verdict"
    |> Contract.of_yojson
    |> require_ok
  in
  (match verdict with
   | Contract.Resume_with_guidance { guidance = actual; _ } ->
     check string "full guidance preserved" guidance actual
   | Contract.Await_external_input _ -> fail "guidance changed verdict");
  match
    Keeper_world_observation.apply_failure_judgment_guidance
      ~post_id:"missing"
      ~judge_runtime_id:"structured-judge"
      ~guidance
      ~rationale:"evidence"
      [ failure_event post_id ]
  with
  | Error _ -> ()
  | Ok _ -> fail "missing observation was silently accepted"
;;

let () =
  run
    "keeper_failure_judgment_contract"
    [ ( "decode"
      , [ test_case "resume with guidance" `Quick test_resume_with_guidance
        ; test_case "await external input" `Quick test_await_external_input
        ; test_case "invalid shapes fail closed" `Quick test_invalid_shapes_fail_closed
        ; test_case "canonical roundtrip" `Quick test_canonical_roundtrip
        ; test_case
            "typed judge error disposition"
            `Quick
            test_typed_judge_error_disposition
        ; test_case
            "guidance binds exact observation"
            `Quick
            test_guidance_binds_exact_observation
        ] )
    ]
;;
