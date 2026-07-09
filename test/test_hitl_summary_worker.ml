(** Tests for HITL context-summary worker.

    Fast, deterministic unit tests that exercise JSON serialization,
    parsing, context-bundle construction, and the no-provider-config
    failure path without making real LLM calls. *)

open Alcotest

(* ── Aliases ──────────────────────────────────── *)

module Q = Keeper_approval_queue_rules_types
module H = Masc.Hitl_summary_worker
module Schema = Masc.Keeper_structured_output_schema
module Workspace = Masc.Workspace
module Goal_store = Goal_store
module Keeper_chat_store = Masc.Keeper_chat_store
module Keeper_config = Masc.Keeper_config
(* Ids is a top-level module from masc_types. *)

let yojson_t = testable (Yojson.Safe.pretty_print ~std:false) ( = )
let with_eio f () = Eio_main.run (fun _env -> f ())
let () = Mirage_crypto_rng_unix.use_default ()

(* ── Sample data ──────────────────────────────── *)

let sample_summary : Q.hitl_context_summary =
  { summary_version = H.For_testing.summary_version
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
    ?(audit_base_path = "")
    ?(input = `Assoc [ "arg", `String "value" ])
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
  ; input
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
  ; continuation_channel = Keeper_continuation_channel.unrouted "test fixture"
  ; audit_base_path
  ; resolver = None
  ; on_resolution = None
  ; context_summary = None
  ; summary_status = Q.Summary_not_requested
  ; channel = None
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
  let parsed =
    H.For_testing.parse_summary ~generated_at:1234567890.0 ~model_run_id:"run-test" valid_summary_json
  in
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
  match
    H.For_testing.summary_of_response
      ~generated_at:1234567890.0
      ~mode:H.For_testing.Native_structured
      response
  with
  | Ok _ -> fail "expected summary_of_response to return Error"
  | Error reason -> check bool "error reason non-empty" true (String.length reason > 0)
;;

let test_parse_summary_rejects_unknown_risk_delta () =
  let malformed =
    `Assoc
      [ "context_summary", `String "A tool request is pending."
      ; "key_questions", `List [ `String "Is this safe?" ]
      ; ( "suggested_options"
        , `List
            [ `Assoc
                [ "label", `String "approve"
                ; "rationale", `String "looks safe"
                ; "estimated_risk_delta", `String "not-a-risk"
                ]
            ] )
      ; "risk_rationale", `Null
      ; "uncertainty", `Float 0.25
      ]
  in
  let response : Agent_sdk.Types.api_response =
    { id = "run-test"
    ; model = "test-model"
    ; stop_reason = Agent_sdk.Types.EndTurn
    ; content = [ Agent_sdk.Types.Text (Yojson.Safe.to_string malformed) ]
    ; usage = None
    ; telemetry = None
    }
  in
  match
    H.For_testing.summary_of_response
      ~generated_at:1234567890.0
      ~mode:H.For_testing.Native_structured
      response
  with
  | Ok _ -> fail "expected unknown risk delta to fail parsing"
  | Error reason ->
    check bool "error names estimated_risk_delta" true
      (Astring.String.is_infix ~affix:"estimated_risk_delta" reason)
;;

let test_hitl_summary_schema_excludes_server_owned_fields () =
  let schema = Schema.hitl_context_summary_schema in
  let open Yojson.Safe.Util in
  let required =
    schema
    |> member "required"
    |> convert_each to_string
    |> List.sort String.compare
  in
  check (list string) "required model-owned fields"
    [ "context_summary"
    ; "key_questions"
    ; "risk_rationale"
    ; "suggested_options"
    ; "uncertainty"
    ]
    required;
  let properties = schema |> member "properties" in
  check yojson_t "summary_version is server-owned" `Null
    (member "summary_version" properties);
  check yojson_t "generated_at is server-owned" `Null
    (member "generated_at" properties);
  check yojson_t "model_run_id is server-owned" `Null
    (member "model_run_id" properties)
;;

(* ── spawn / bundle tests ───────────────────────── *)

let test_spawn_no_provider_config_uses_fallback_summary () =
  Eio.Switch.run (fun sw ->
    let failure_called = ref false in
    let summary_ref = ref None in
    let on_summary summary = summary_ref := Some summary in
    let on_failure ~reason ~retryable =
      failure_called := true;
      ignore reason;
      ignore retryable
    in
    H.spawn ~sw ~entry:(dummy_pending_approval ()) ?provider_config:None
      ~on_summary ~on_failure ();
    check bool "on_failure not called" false !failure_called;
    match !summary_ref with
    | None -> fail "expected fallback summary"
    | Some summary ->
      check string "fallback model_run_id" "deterministic-fallback" summary.model_run_id;
      check bool "context explains missing LLM summary" true
        (Astring.String.is_infix ~affix:"LLM context summary unavailable"
           summary.context_summary);
      check int "fallback questions" 3 (List.length summary.key_questions);
      check int "fallback options" 2 (List.length summary.suggested_options))
;;

let test_build_context_bundle_includes_ids_and_partial_context () =
  let bundle = H.For_testing.build_context_bundle ~entry:(dummy_pending_approval ()) in
  let member = Yojson.Safe.Util.member in
  check yojson_t "task_id" (`String "task-1") (member "task_id" bundle);
  check yojson_t "goal_id" (`String "goal-1") (member "goal_id" bundle);
  check yojson_t "turn_id" (`Int 42) (member "turn_id" bundle);
  check yojson_t "partial_context" (`Bool true) (member "partial_context" bundle)
;;

(* ── Real workspace context collection tests ────── *)

let temp_dir prefix =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s%d_%d" prefix (Unix.getpid ())
       (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir dir 0o755;
  dir
;;

let rm_rf path =
  let rec loop p =
    if Sys.is_directory p then begin
      Array.iter (fun name -> loop (Filename.concat p name)) (Sys.readdir p);
      Unix.rmdir p
    end else
      Sys.remove p
  in
  loop path
;;

let workspace_config base_path =
  Unix.putenv "MASC_BASE_PATH" base_path;
  Workspace.default_config base_path
;;

let test_build_context_bundle_with_real_workspace () =
  let base = temp_dir "hitl_summary_ctx_" in
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () ->
    let config = workspace_config base in
    ignore (Workspace.init config ~agent_name:(Some "test-keeper"));
    ignore (Workspace.add_task config ~title:"HITL context task" ~priority:1 ~description:"");
    let goal, _ =
      match
        Goal_store.upsert_goal config ~id:"goal-ctx-1" ~title:"HITL context goal"
          ~priority:1 ~status:Goal_store.Active ~phase:Goal_phase.Executing ()
      with
      | Ok g -> g
      | Error msg -> Alcotest.failf "upsert_goal failed: %s" msg
    in
    let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:7 in
    Keeper_chat_store.append_turn
      ~base_dir:base
      ~keeper_name:"test-keeper"
      ~user_content:"hello"
      ~user_attachments:[]
      ~turn_ref
      ~assistant_content:"hi"
      ();
    let entry =
      dummy_pending_approval
        ~task_id:"task-001"
        ~goal_id:goal.id
        ~turn_id:7
        ~audit_base_path:base
        ()
    in
    let bundle = H.For_testing.build_context_bundle ~entry in
    let member = Yojson.Safe.Util.member in
    check yojson_t "task_id" (`String "task-001") (member "task_id" bundle);
    check yojson_t "goal_id" (`String "goal-ctx-1") (member "goal_id" bundle);
    check yojson_t "turn_id" (`Int 7) (member "turn_id" bundle);
    check yojson_t "partial_context" (`Bool false) (member "partial_context" bundle);
    let task = member "task" bundle in
    check bool "task found" true (Yojson.Safe.Util.to_bool (member "found" task));
    let goals = member "goals" bundle in
    (match goals with
     | `List [ g ] -> check bool "goal found" true (Yojson.Safe.Util.to_bool (member "found" g))
     | _ -> Alcotest.failf "expected exactly one goal, got %s" (Yojson.Safe.to_string goals));
    let chat = member "chat_messages" bundle in
    check bool "chat has messages" true
      (match chat with
       | `List (_ :: _) -> true
       | _ -> false))
;;

(* ── Provider cost/token guard tests ────────────── *)

let test_provider_config_for_summary_caps_tokens_and_temperature () =
  let provider_cfg : Llm_provider.Provider_config.t =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"test-model"
      ~base_url:"http://localhost"
      ~api_key:"sk-test"
      ~max_tokens:8192
      ~temperature:0.7
      ~tool_choice:Llm_provider.Types.Auto
      ~response_format:Llm_provider.Types.JsonMode
      ()
  in
  let cfg, mode = H.For_testing.provider_config_for_summary provider_cfg in
  check bool "max_tokens capped to policy" true
    (match cfg.max_tokens with
     | Some n -> n <= Keeper_config.hitl_summary_max_tokens ()
     | None -> false);
  check (option (float 0.0001)) "temperature set to policy"
    (Some (Keeper_config.hitl_summary_temperature ())) cfg.temperature;
  check bool "tool_choice cleared" true (Option.is_none cfg.tool_choice);
  check bool "disable_parallel_tool_use true" true cfg.disable_parallel_tool_use;
  (* An undeclared OpenAI-compatible endpoint (http://localhost, no catalog row)
     cannot serve a native json_schema request, so the worker degrades to the
     plain-text path: no [output_schema] is attached and the mode is plain. *)
  check bool "mode is plain for undeclared endpoint" true (mode = H.For_testing.Plain_json_text);
  check bool "output_schema absent on plain path" true (Option.is_none cfg.output_schema)
;;

(* ── Graceful-degradation tests ─────────────────── *)

let test_extract_json_object_variants () =
  let ok label input expected_summary =
    match H.For_testing.extract_json_object input with
    | Ok (`Assoc _ as json) ->
      check string label expected_summary
        (Yojson.Safe.Util.(member "context_summary" json |> to_string))
    | Ok other -> failf "%s: expected object, got %s" label (Yojson.Safe.to_string other)
    | Error e -> failf "%s: expected Ok, got Error %s" label e
  in
  ok "bare json" {|{"context_summary":"bare"}|} "bare";
  ok "fenced json"
    "```json\n{\"context_summary\":\"fenced\"}\n```" "fenced";
  ok "prose-wrapped json"
    "Here is the result:\n{\"context_summary\":\"wrapped\"}\nThanks!" "wrapped";
  (match H.For_testing.extract_json_object "no json here at all" with
   | Error _ -> ()
   | Ok _ -> fail "expected Error for text with no JSON object")
;;

let test_summary_of_response_plain_json_text_parses_prose_wrapped () =
  (* Plain path: a model without native structured output returns JSON embedded
     in prose. [summary_of_response ~mode:Plain_json_text] must still parse it. *)
  let text =
    "Sure, here is the judgment:\n"
    ^ Yojson.Safe.to_string valid_summary_json
    ^ "\nLet me know if you need more."
  in
  let response : Agent_sdk.Types.api_response =
    { id = "run-plain"
    ; model = "test-model"
    ; stop_reason = Agent_sdk.Types.EndTurn
    ; content = [ Agent_sdk.Types.Text text ]
    ; usage = None
    ; telemetry = None
    }
  in
  match
    H.For_testing.summary_of_response
      ~generated_at:1234567890.0
      ~mode:H.For_testing.Plain_json_text
      response
  with
  | Ok summary ->
    check string "context_summary parsed" "A tool request is pending." summary.context_summary;
    check int "suggested_options length" 1 (List.length summary.suggested_options)
  | Error e -> failf "expected plain-path parse to succeed, got %s" e
;;

let test_summary_of_response_native_recovers_prose_wrapped_json () =
  (* Native path over the OpenAI-compatible /v1 transport: a native-schema runtime
     may return the JSON as visible (fenced) prose instead of an enforced structured
     payload. [summary_of_response ~mode:Native_structured] must recover via the
     plain-text extractor rather than degrading to the deterministic fallback. Only
     genuinely empty/non-JSON output should fail. *)
  let text =
    "Here is the structured judgment:\n```json\n"
    ^ Yojson.Safe.to_string valid_summary_json
    ^ "\n```\nDone."
  in
  let response : Agent_sdk.Types.api_response =
    { id = "run-native-recover"
    ; model = "test-model"
    ; stop_reason = Agent_sdk.Types.EndTurn
    ; content = [ Agent_sdk.Types.Text text ]
    ; usage = None
    ; telemetry = None
    }
  in
  match
    H.For_testing.summary_of_response
      ~generated_at:1234567890.0
      ~mode:H.For_testing.Native_structured
      response
  with
  | Ok summary ->
    check string "context_summary parsed" "A tool request is pending." summary.context_summary;
    check int "suggested_options length" 1 (List.length summary.suggested_options)
  | Error e -> failf "expected native-path recovery to succeed, got %s" e
;;

let test_summary_of_response_native_empty_text_still_fails () =
  (* The recovery must not paper over a genuinely empty answer (the reasoning-model
     thinking-budget exhaustion case): with no JSON anywhere, both the structured
     extractor and the plain-text fallback fail, and the worker degrades to the
     deterministic fallback rather than fabricating a summary. *)
  let response : Agent_sdk.Types.api_response =
    { id = "run-native-empty"
    ; model = "test-model"
    ; stop_reason = Agent_sdk.Types.EndTurn
    ; content = [ Agent_sdk.Types.Text "" ]
    ; usage = None
    ; telemetry = None
    }
  in
  match
    H.For_testing.summary_of_response
      ~generated_at:1234567890.0
      ~mode:H.For_testing.Native_structured
      response
  with
  | Ok _ -> fail "expected empty native response to fail, not fabricate a summary"
  | Error reason -> check bool "error reason non-empty" true (String.length reason > 0)
;;

let test_plain_mode_error_outcomes_record_degradation () =
  let provider_error = Agent_sdk.Error.Internal "synthetic provider failure" in
  let timeout_error =
    Agent_sdk.Error.Api
      (Agent_sdk.Retry.Timeout { message = "synthetic timeout"; phase = None })
  in
  check (list string)
    "plain provider error includes degradation then terminal outcome"
    [ "degraded_plain_json"; "provider_error" ]
    (H.For_testing.summary_llm_error_outcomes
       ~mode:H.For_testing.Plain_json_text
       provider_error);
  check (list string)
    "plain timeout includes degradation then terminal outcome"
    [ "degraded_plain_json"; "timeout" ]
    (H.For_testing.summary_llm_error_outcomes
       ~mode:H.For_testing.Plain_json_text
       timeout_error);
  check (list string)
    "native provider error emits terminal outcome only"
    [ "provider_error" ]
    (H.For_testing.summary_llm_error_outcomes
       ~mode:H.For_testing.Native_structured
       provider_error)
;;

let test_fallback_summary_is_redacted_and_uncertain () =
  let entry =
    dummy_pending_approval
      ~input:
        (`Assoc
            [ "api_key", `String "sk-test-secret"
            ; "path", `String "/tmp/example"
            ; "content", `String "write this file"
            ])
      ()
  in
  let summary =
    H.For_testing.fallback_summary
      ~generated_at:1234567890.0
      ~entry
      ~context_bundle:(`Assoc [ "partial_context", `Bool false ])
      ~reason:"Internal error: HTTP 429: rate limit reached"
  in
  check string "fallback model_run_id" "deterministic-fallback" summary.model_run_id;
  check bool "mentions fallback reason" true
    (Astring.String.is_infix ~affix:"HTTP 429" summary.context_summary);
  check bool "redacts raw secret" false
    (Astring.String.is_infix ~affix:"sk-test-secret" summary.context_summary);
  check bool "keeps redaction marker" true
    (Astring.String.is_infix ~affix:"[REDACTED]" summary.context_summary);
  check bool "risk rationale present" true
    (match summary.risk_rationale with
     | Some text -> Astring.String.is_infix ~affix:"does not verify external state" text
     | None -> false);
  check (float 0.0001) "fallback uncertainty" 0.85 summary.uncertainty
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
        ; test_case "unknown risk delta fails" `Quick
            test_parse_summary_rejects_unknown_risk_delta
        ; test_case "schema excludes server-owned fields" `Quick
            test_hitl_summary_schema_excludes_server_owned_fields
        ] )
    ; ( "worker"
      , [ test_case "spawn with no provider config uses fallback summary" `Quick
            (with_eio test_spawn_no_provider_config_uses_fallback_summary)
        ; test_case "build_context_bundle includes IDs and partial_context" `Quick
            test_build_context_bundle_includes_ids_and_partial_context
        ; test_case "build_context_bundle with real workspace is not partial" `Quick
            test_build_context_bundle_with_real_workspace
        ; test_case "provider_config_for_summary caps tokens and temperature" `Quick
            test_provider_config_for_summary_caps_tokens_and_temperature
        ] )
    ; ( "graceful_degradation"
      , [ test_case "extract_json_object handles bare/fenced/prose/invalid" `Quick
            test_extract_json_object_variants
        ; test_case "summary_of_response plain path parses prose-wrapped JSON" `Quick
            test_summary_of_response_plain_json_text_parses_prose_wrapped
        ; test_case "summary_of_response native path recovers prose-wrapped JSON" `Quick
            test_summary_of_response_native_recovers_prose_wrapped_json
        ; test_case "summary_of_response native path still fails on empty text" `Quick
            test_summary_of_response_native_empty_text_still_fails
        ; test_case "plain-mode errors keep degradation observable" `Quick
            test_plain_mode_error_outcomes_record_degradation
        ; test_case "fallback summary is redacted and uncertain" `Quick
            test_fallback_summary_is_redacted_and_uncertain
        ] )
    ]
;;
