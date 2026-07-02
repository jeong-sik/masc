(* RFC-0252 §10 / 적대 리뷰 #22087 §1 — 심판 usage 회계 불변식.

   [Fusion_judge.attach_usage]는 심판이 토큰을 소비한 뒤의 파싱 결과에 그 usage를
   성공·실패 양 분기 모두에 묶는 단일 지점이다. 회귀 위험은 파싱 실패 시 usage를
   버리는 것 — 그러면 refine degrade 경로(fusion_orchestrator)가 소비 토큰을 0으로
   집계해 비용을 undercount한다. 이 테스트는 Error 분기가 usage를 보존함을 핀한다. *)

open Alcotest
open Masc

let usage_t = testable Fusion_types.pp_usage Fusion_types.equal_usage

let sample_usage : Fusion_types.usage =
  { Fusion_types.input_tokens = 1234; output_tokens = 567 }

let sample_synthesis : Fusion_types.judge_synthesis =
  { Fusion_types.consensus = []
  ; contradictions = []
  ; partial_coverage = []
  ; unique_insights = []
  ; blind_spots = []
  ; resolved_answer = "ok"
  ; decision = Fusion_types.Answer "ok"
  }

let fusion_schema = Keeper_structured_output_schema.fusion_judge_output_schema
let panel_schema = Keeper_structured_output_schema.fusion_panel_answer_output_schema

let restore_model_catalog previous =
  match previous with
  | Some catalog -> Llm_provider.Model_catalog.set_global catalog
  | None -> Llm_provider.Model_catalog.clear_global ()

let with_repo_oas_model_catalog f =
  let previous = Llm_provider.Model_catalog.global () in
  let path = Masc_test_deps.source_path "oas-models.toml" in
  match Llm_provider.Model_catalog.load_file path with
  | Error msg -> fail ("repo oas-models.toml should load: " ^ msg)
  | Ok catalog ->
    Fun.protect
      ~finally:(fun () -> restore_model_catalog previous)
      (fun () ->
         Llm_provider.Model_catalog.set_global catalog;
         f ())

let with_empty_oas_model_catalog f =
  let previous = Llm_provider.Model_catalog.global () in
  Fun.protect
    ~finally:(fun () -> restore_model_catalog previous)
    (fun () ->
       Llm_provider.Model_catalog.set_global [];
       f ())

let provider_cfg ~kind ~model_id ~base_url =
  Llm_provider.Provider_config.make ~kind ~model_id ~base_url ()

let response_with_text text : Agent_sdk.Types.api_response =
  { id = "fusion-panel-test"
  ; model = "fusion-panel-test-model"
  ; stop_reason = Agent_sdk.Types.EndTurn
  ; content = [ Agent_sdk.Types.Text text ]
  ; usage = None
  ; telemetry = None
  }

let test_output_contract_keeps_native_schema_when_supported () =
  let cfg =
    provider_cfg
      ~kind:Llm_provider.Provider_config.Anthropic
      ~model_id:"claude-test"
      ~base_url:"https://api.anthropic.test"
  in
  match Fusion_judge.For_testing.apply_output_contract cfg with
  | Error msg -> fail ("expected native schema config: " ^ msg)
  | Ok configured ->
    check bool "response_format uses JsonSchema" true
      (match configured.response_format with
       | Agent_sdk.Types.JsonSchema schema -> Yojson.Safe.equal fusion_schema schema
       | Agent_sdk.Types.JsonMode | Agent_sdk.Types.Off -> false);
    check bool "output_schema mirrors schema" true
      (match configured.output_schema with
       | Some schema -> Yojson.Safe.equal fusion_schema schema
       | None -> false)

let test_output_contract_fails_loud_when_schema_is_not_native () =
  with_repo_oas_model_catalog @@ fun () ->
  let cfg =
    provider_cfg
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"deepseek-v4-pro"
      ~base_url:"https://api.deepseek.com"
  in
  match Fusion_judge.For_testing.apply_output_contract cfg with
  | Ok _ -> fail "expected schema-native fusion judge to fail loud"
  | Error msg ->
    check bool "schema validation reason is retained" true
      (String.length msg > 0)

let test_output_contract_fails_loud_when_no_output_contract_is_known () =
  with_empty_oas_model_catalog @@ fun () ->
  let cfg =
    provider_cfg
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"unknown-json-contract"
      ~base_url:"https://api.example.invalid/v1"
  in
  match Fusion_judge.For_testing.apply_output_contract cfg with
  | Ok _ -> fail "expected unknown provider/model to fail loud"
  | Error msg ->
    check bool "schema validation reason is retained" true (String.length msg > 0)

let test_panel_output_contract_keeps_native_schema_when_supported () =
  let cfg =
    provider_cfg
      ~kind:Llm_provider.Provider_config.Anthropic
      ~model_id:"claude-test"
      ~base_url:"https://api.anthropic.test"
  in
  match Fusion_panel.For_testing.apply_output_contract cfg with
  | Error msg -> fail ("expected native schema config: " ^ msg)
  | Ok configured ->
    check bool "response_format uses JsonSchema" true
      (match configured.response_format with
       | Agent_sdk.Types.JsonSchema schema -> Yojson.Safe.equal panel_schema schema
       | Agent_sdk.Types.JsonMode | Agent_sdk.Types.Off -> false);
    check bool "output_schema mirrors schema" true
      (match configured.output_schema with
       | Some schema -> Yojson.Safe.equal panel_schema schema
       | None -> false)

let test_panel_outcome_parses_structured_answer () =
  match
    Fusion_panel.For_testing.outcome_of_result ~panelist:"panel-a"
      ~model:"provider.model"
      (Ok (response_with_text {|{"answer":"  hello  "}|}))
  with
  | Fusion_types.Answered { model; answer; usage } ->
    check string "panel identity preserved" "panel-a" model;
    check string "answer is parsed and trimmed" "hello" answer;
    check usage_t "missing provider usage defaults to zero" Fusion_types.zero_usage
      usage
  | Fusion_types.Failed failure ->
    fail ("expected structured answer, got failure: " ^ Fusion_types.show_panel_error failure)

let test_panel_outcome_rejects_invalid_structured_answer () =
  match
    Fusion_panel.For_testing.outcome_of_result ~panelist:"panel-a"
      ~model:"provider.model"
      (Ok (response_with_text "not-json"))
  with
  | Fusion_types.Failed
      { failed_model = "panel-a"
      ; reason = Fusion_types.Invalid_structured_response detail
      } ->
    check bool "invalid JSON detail is retained" true
      (String_util.string_contains_substring ~needle:"not valid JSON" detail)
  | other ->
    fail
      ("expected invalid structured response failure, got: "
       ^ Fusion_types.show_panel_outcome other)

let test_panel_outcome_rejects_free_text_without_contract () =
  match
    Fusion_panel.For_testing.outcome_of_result ~panelist:"panel-a"
      ~model:"provider.model"
      (Ok (response_with_text "plain panel answer"))
  with
  | Fusion_types.Failed
      { failed_model = "panel-a"
      ; reason = Fusion_types.Invalid_structured_response detail
      } ->
    check bool "free text is not an implicit success" true
      (String_util.string_contains_substring ~needle:"not valid JSON" detail)
  | other ->
    fail
      ("expected free text to fail without an explicit contract, got: "
       ^ Fusion_types.show_panel_outcome other)

let test_panel_outcome_rejects_malformed_structured_answer () =
  match
    Fusion_panel.For_testing.outcome_of_result ~panelist:"panel-a"
      ~model:"provider.model"
      (Ok (response_with_text {|{"answer":|}))
  with
  | Fusion_types.Failed
      { failed_model = "panel-a"
      ; reason = Fusion_types.Invalid_structured_response detail
      } ->
    check bool "malformed JSON detail is retained" true
      (String_util.string_contains_substring ~needle:"not valid JSON" detail)
  | other ->
    fail
      ("expected malformed structured response failure, got: "
       ^ Fusion_types.show_panel_outcome other)

let test_panel_outcome_rejects_empty_answer () =
  match
    Fusion_panel.For_testing.outcome_of_result ~panelist:"panel-a"
      ~model:"provider.model"
      (Ok (response_with_text {|{"answer":"   "}|}))
  with
  | Fusion_types.Failed
      { failed_model = "panel-a"; reason = Fusion_types.Empty_response detail } ->
    check bool "empty response detail is retained" true (String.length detail > 0)
  | other ->
    fail
      ("expected empty structured answer failure, got: "
       ^ Fusion_types.show_panel_outcome other)

let test_attach_usage_on_success () =
  match Fusion_judge.attach_usage (Ok sample_synthesis) sample_usage with
  | Ok (_synthesis, usage) ->
    check usage_t "success carries the consumed usage" sample_usage usage
  | Error _ -> fail "expected Ok with usage"

let test_attach_usage_on_parse_failure () =
  (* 핵심 불변식: 파싱이 실패해도(심판이 응답을 생성하느라 토큰을 이미 태움)
     usage가 버려지지 않고 에러에 동반된다. *)
  match Fusion_judge.attach_usage (Error "bad json") sample_usage with
  | Error (failure, usage) ->
    check string "error message preserved" "bad json"
      (Fusion_types.judge_failure_text failure);
    check usage_t "parse failure still carries the consumed usage" sample_usage
      usage
  | Ok _ -> fail "expected Error with usage"

let test_sum_error_usage_folds_all_failures () =
  (* 적대 리뷰 #22093 all-fail: judge-of-judges 전원 실패 시 첫 에러의 usage만 전파하면
     나머지 심판이 (병렬로) 태운 토큰을 잃어 비용을 undercount한다. sum_error_usage는
     모든 Error usage를 합산하고 Ok는 무시함을 핀한다. *)
  let u input_tokens output_tokens : Fusion_types.usage =
    { Fusion_types.input_tokens; output_tokens }
  in
  let results =
    [ ("j1", Error ("boom1", u 100 10))
    ; ("j2", Ok (sample_synthesis, u 999 999)) (* Ok 원소는 무시되어야 함 *)
    ; ("j3", Error ("boom3", u 25 5))
    ]
  in
  check usage_t "sums every failed judge's usage and ignores Ok" (u 125 15)
    (Fusion_types.sum_error_usage results)

let test_sum_error_usage_empty_is_zero () =
  check usage_t "no results -> zero usage" Fusion_types.zero_usage
    (Fusion_types.sum_error_usage [])

let test_all_fail_error_sums_usage_and_first_msg () =
  (* 적대 리뷰 #22099 P2: all_fail_error는 sum_error_usage 합산 + 첫 Error 메시지 pick을
     한 번에 계산. 인라인이던 회계 wiring을 분리해 firsts만으로 검증한다. Ok 원소는
     무시, 첫 Error 메시지가 대표, 모든 실패 usage가 합산됨을 핀. *)
  let u input_tokens output_tokens : Fusion_types.usage =
    { Fusion_types.input_tokens; output_tokens }
  in
  let results =
    [ ("j1", Error ("boom1", u 100 10))
    ; ("j2", Ok (sample_synthesis, u 999 999)) (* Ok 원소는 무시 *)
    ; ("j3", Error ("boom3", u 25 5))
    ]
  in
  let msg, usage =
    Fusion_types.all_fail_error ~fallback:"FALLBACK" results
  in
  check string "first error's message is the representative" "boom1" msg;
  check usage_t "sums every failed judge's usage, ignores Ok" (u 125 15) usage

let test_all_fail_error_no_errors_uses_fallback () =
  (* 도달불가 분기 핀: ok_priors=[]이면 firsts는 전부 Error이므로 실제로는 안 온다.
     [Error]가 하나도 없으면 fallback 메시지 + 합산 usage(빈이면 zero)를 반환. *)
  let msg, usage = Fusion_types.all_fail_error ~fallback:"FALLBACK" [] in
  check string "no errors -> fallback message" "FALLBACK" msg;
  check usage_t "empty results -> zero usage" Fusion_types.zero_usage usage

let test_sum_all_usage_folds_ok_and_error () =
  (* 적대 리뷰 #22134 partial-fail: 1차 일부 성공/일부 실패 시 meta가 성공하면 *모든* 1차
     심판이 태운 토큰(성공분 + 실패분)을 비용에 실어야 한다. sum_all_usage는 Ok와 Error를
     모두 합산함을 핀한다 — sum_error_usage(실패분만, 위 테스트)와 대비된다. *)
  let u input_tokens output_tokens : Fusion_types.usage =
    { Fusion_types.input_tokens; output_tokens }
  in
  let results =
    [ ("j1", Error ("boom1", u 100 10))
    ; ("j2", Ok (sample_synthesis, u 999 999)) (* Ok도 합산되어야 함 *)
    ; ("j3", Error ("boom3", u 25 5))
    ]
  in
  check usage_t "sums every judge's usage, Ok and Error alike" (u 1124 1014)
    (Fusion_types.sum_all_usage results)

let test_sum_all_usage_empty_is_zero () =
  check usage_t "no results -> zero usage" Fusion_types.zero_usage
    (Fusion_types.sum_all_usage [])

let () =
  run "fusion_judge_usage"
    [ ( "output_contract"
      , [ test_case
            "keeps native schema when supported"
            `Quick
            test_output_contract_keeps_native_schema_when_supported
        ; test_case
            "fails loud when native schema is not available"
            `Quick
            test_output_contract_fails_loud_when_schema_is_not_native
        ; test_case
            "fails loud when no JSON output contract is known"
            `Quick
            test_output_contract_fails_loud_when_no_output_contract_is_known
        ; test_case
            "panel keeps native answer schema when supported"
            `Quick
            test_panel_output_contract_keeps_native_schema_when_supported
        ] )
    ; ( "panel_outcome"
      , [ test_case "parses structured answer" `Quick
            test_panel_outcome_parses_structured_answer
        ; test_case "rejects invalid structured answer" `Quick
            test_panel_outcome_rejects_invalid_structured_answer
        ; test_case "rejects free text without contract" `Quick
            test_panel_outcome_rejects_free_text_without_contract
        ; test_case "rejects malformed structured answer" `Quick
            test_panel_outcome_rejects_malformed_structured_answer
        ; test_case "rejects empty answer" `Quick
            test_panel_outcome_rejects_empty_answer
        ] )
    ; ( "attach_usage"
      , [ test_case "success carries usage" `Quick test_attach_usage_on_success
        ; test_case "parse failure carries usage" `Quick
            test_attach_usage_on_parse_failure
        ] )
    ; ( "sum_error_usage"
      , [ test_case "folds all failures, ignores Ok" `Quick
            test_sum_error_usage_folds_all_failures
        ; test_case "empty is zero" `Quick test_sum_error_usage_empty_is_zero
        ] )
    ; ( "all_fail_error"
      , [ test_case "sums usage, picks first error message" `Quick
            test_all_fail_error_sums_usage_and_first_msg
        ; test_case "no errors -> fallback + zero usage" `Quick
            test_all_fail_error_no_errors_uses_fallback
        ] )
    ; ( "sum_all_usage"
      , [ test_case "folds Ok and Error usage alike" `Quick
            test_sum_all_usage_folds_ok_and_error
        ; test_case "empty is zero" `Quick test_sum_all_usage_empty_is_zero
        ] )
    ]
