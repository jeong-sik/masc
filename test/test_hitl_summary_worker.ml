(** Tests for HITL context-summary worker.

    Fast, deterministic unit tests that exercise JSON serialization,
    parsing, context-bundle construction, and the no-provider-config
    failure path without making real LLM calls. *)

open Alcotest

(* ── Aliases ──────────────────────────────────── *)

module Q = Keeper_approval_queue_rules_types
module H = Masc.Hitl_summary_worker

let yojson_t = testable (Yojson.Safe.pretty_print ~std:false) ( = )
let with_eio f () = Eio_main.run (fun _env -> f ())

(* ── Sample data ──────────────────────────────── *)

let sample_summary : Q.hitl_context_summary =
  { summary_version = 1
  ; generated_at = 1780587600.0
  ; model_run_id = "run-abc"
  ; context_summary = "A keeper tool approval is pending."
  ; key_questions = [ "Is this safe?"; "Who is affected?" ]
  ; suggested_options =
      [ { Q.label = "approve"; rationale = "Low risk"; estimated_risk_delta = Some Q.Low }
      ; { Q.label = "reject"; rationale = "High risk"; estimated_risk_delta = Some Q.High }
      ]
  ; risk_rationale = Some "minimal risk"
  ; uncertainty = 0.12
  }
;;

let valid_summary_json =
  `Assoc
    [ "context_summary", `String "A tool request is pending."
    ; "key_questions", `List [ `String "Is this safe?" ]
    ; "suggested_options"
    , `List
        [ `Assoc
            [ "label", `String "approve"
            ; "rationale", `String "looks safe"
            ; "estimated_risk_delta", `String "low"
            ]
        ]
    ; "risk_rationale", `String "minimal risk"
    ; "uncertainty", `Float 0.25
    ]
;;

let dummy_pending_approval
    ?(task_id = "task-1")
    ?(goal_id = "goal-1")
    ?(turn_id = 42)
    ()
    : Q.pending_approval
  =
  { id = "approval-1"
  ; keeper_name = "test-keeper"
  ; tool_name = "test_tool"
  ; action_key = "test_action"
  ; input_hash = "hash"
  ; sandbox_target = "local"
  ; sandbox_profile = None
  ; backend = None
  ; input = `Assoc [ "arg", `String "value" ]
  ; risk_level = Q.Medium
  ; requested_at = 1780587600.0
  ; turn_id = Some turn_id
  ; task_id = Some task_id
  ; goal_id = Some goal_id
  ; goal_ids = []
  ; runtime_contract = None
  ; selected_model = None
  ; disposition = None
  ; disposition_reason = None
  ; phase = Q.Awaiting_operator
  ; audit_base_path = ""
  ; resolver = None
  ; on_resolution = None
  ; context_summary = None
  ; summary_status = Q.Summary_not_requested
  }
;;

(* ── JSON round-trip / encoding tests ───────────── *)

let test_hitl_context_summary_json_round_trip () =
  let json = Q.hitl_context_summary_to_yojson sample_summary in
  check yojson_t "context_summary field" (`String sample_summary.context_summary)
    (Yojson.Safe.Util.member "context_summary" json);
  check yojson_t "model_run_id field" (`String sample_summary.model_run_id)
    (Yojson.Safe.Util.member "model_run_id" json);
  check yojson_t "uncertainty field" (`Float sample_summary.uncertainty)
    (Yojson.Safe.Util.member "uncertainty" json)
;;

let test_summary_status_json_encoding () =
  check yojson_t "Summary_not_requested"
    (`String "not_requested")
    (Q.summary_status_to_yojson Q.Summary_not_requested);
  let available = Q.summary_status_to_yojson (Q.Summary_available sample_summary) in
  check yojson_t "Summary_available status" (`String "available")
    (Yojson.Safe.Util.member "status" available);
  check bool "Summary_available has summary" true
    (Yojson.Safe.Util.member "summary" available <> `Null);
  let failed =
    Q.summary_status_to_yojson (Q.Summary_failed { reason = "boom"; retryable = true })
  in
  check yojson_t "Summary_failed status" (`String "failed")
    (Yojson.Safe.Util.member "status" failed);
  check yojson_t "Summary_failed reason" (`String "boom")
    (Yojson.Safe.Util.member "reason" failed);
  check yojson_t "Summary_failed retryable" (`Bool true)
    (Yojson.Safe.Util.member "retryable" failed)
;;

(* ── parse_summary tests ────────────────────────── *)

let test_parse_summary_success () =
  let parsed = H.For_testing.parse_summary ~model_run_id:"run-test" valid_summary_json in
  check string "model_run_id" "run-test" parsed.model_run_id;
  check string "context_summary" "A tool request is pending." parsed.context_summary;
  check (list string) "key_questions" [ "Is this safe?" ] parsed.key_questions;
  check (option string) "risk_rationale" (Some "minimal risk") parsed.risk_rationale;
  check (float 0.0001) "uncertainty" 0.25 parsed.uncertainty;
  check int "suggested_options length" 1 (List.length parsed.suggested_options);
  let opt = List.hd parsed.suggested_options in
  check string "option label" "approve" opt.Q.label;
  check bool "option risk delta" true (opt.Q.estimated_risk_delta = Some Q.Low)
;;

let test_parse_summary_failure () =
  let malformed = `Assoc [ "context_summary", `String "missing other fields" ] in
  let response : Agent_sdk.Types.api_response =
    { id = "run-test"
    ; model = "test-model"
    ; stop_reason = Agent_sdk.Types.EndTurn
    ; content = [ Agent_sdk.Types.Text (Yojson.Safe.to_string malformed) ]
    ; usage = None
    ; telemetry = None
    }
  in
  match H.For_testing.summary_of_response response with
  | Ok _ -> fail "expected summary_of_response to return Error"
  | Error reason -> check bool "error reason non-empty" true (String.length reason > 0)
;;

(* ── spawn / bundle tests ───────────────────────── *)

let test_spawn_no_provider_config_calls_on_failure () =
  Eio.Switch.run (fun sw ->
    let called = ref false in
    let reason_ref = ref "" in
    let on_summary _ = fail "on_summary should not be called" in
    let on_failure ~reason ~retryable =
      called := true;
      reason_ref := reason;
      ignore retryable
    in
    H.spawn ~sw ~entry:(dummy_pending_approval ()) ?provider_config:None
      ~on_summary ~on_failure ();
    check bool "on_failure called" true !called;
    check bool "reason mentions no provider config" true
      (Astring.String.is_infix ~affix:"no provider config" !reason_ref))
;;

let test_build_context_bundle_includes_ids_and_partial_context () =
  let bundle = H.For_testing.build_context_bundle ~entry:(dummy_pending_approval ()) in
  let member = Yojson.Safe.Util.member in
  check yojson_t "task_id" (`String "task-1") (member "task_id" bundle);
  check yojson_t "goal_id" (`String "goal-1") (member "goal_id" bundle);
  check yojson_t "turn_id" (`Int 42) (member "turn_id" bundle);
  check yojson_t "partial_context" (`Bool true) (member "partial_context" bundle)
;;

(* ── Runner ───────────────────────────────────── *)

let () =
  run "HITL summary worker"
    [ ( "json"
      , [ test_case "hitl_context_summary JSON round-trip" `Quick
            test_hitl_context_summary_json_round_trip
        ; test_case "summary_status JSON encoding" `Quick test_summary_status_json_encoding
        ] )
    ; ( "parse_summary"
      , [ test_case "success" `Quick test_parse_summary_success
        ; test_case "failure" `Quick test_parse_summary_failure
        ] )
    ; ( "worker"
      , [ test_case "spawn with no provider config calls on_failure" `Quick
            (with_eio test_spawn_no_provider_config_calls_on_failure)
        ; test_case "build_context_bundle includes IDs and partial_context" `Quick
            test_build_context_bundle_includes_ids_and_partial_context
        ] )
    ]
;;
