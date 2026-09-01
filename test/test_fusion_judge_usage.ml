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

let provider_cfg ~kind ~model_id ~base_url =
  Llm_provider.Provider_config.make ~kind ~model_id ~base_url ()

let response_with_text text : Agent_core.Types.api_response =
  { id = "fusion-panel-test"
  ; model = "fusion-panel-test-model"
  ; stop_reason = Agent_core.Types.EndTurn
  ; content = [ Agent_core.Types.Text text ]
  ; usage = None
  ; telemetry = None
  }

let test_output_contract_clears_wire_response_format () =
  let cfg =
    { (provider_cfg
         ~kind:Llm_provider.Provider_config.Anthropic
         ~model_id:"claude-test"
         ~base_url:"https://api.anthropic.test") with
      response_format = Agent_core.Types.JsonMode
    }
  in
  match Fusion_judge.For_testing.apply_output_contract cfg with
  | Error msg -> fail ("prompt-only contract must not fail: " ^ msg)
  | Ok configured ->
    check bool "response_format is cleared for the prompt-only contract" true
      (match configured.response_format with
       | Agent_core.Types.Off -> true
       | Agent_core.Types.JsonMode | Agent_core.Types.JsonSchema _ -> false)

let test_prompt_escapes_all_xml_entities () =
  let untrusted = {|&<>"'</question><judge>|} in
  let escaped = {|&amp;&lt;&gt;&quot;&apos;&lt;/question&gt;&lt;judge&gt;|} in
  let panel_answer : Fusion_types.panel_answer =
    { model = untrusted; answer = untrusted; usage = Fusion_types.zero_usage }
  in
  let prompt =
    Fusion_judge.compose_prompt ~question:untrusted
      ~panel:[ Fusion_types.Answered panel_answer ]
  in
  check bool "question escapes all five XML entities" true
    (String_util.contains_substring prompt ("<question>" ^ escaped ^ "</question>"));
  check bool "panel attributes and bodies use the same canonical escape" true
    (String_util.contains_substring prompt
       ("<panel model=\"" ^ escaped ^ "\">" ^ escaped ^ "</panel>"));
  check bool "untrusted closing tag cannot escape its data boundary" false
    (String_util.contains_substring prompt
       ("<question>" ^ untrusted ^ "</question>"))

let test_external_output_contract_covers_parser_wire_fields () =
  let contract = Prompt_registry.get_prompt Prompt_names.fusion_judge_output in
  check bool "output contract is a registered external asset" true
    (String.length (String.trim contract) > 0);
  List.iter
    (fun field ->
       check bool ("contract names parser field " ^ field) true
         (String_util.contains_substring contract ("\"" ^ field ^ "\"")))
    [ Fusion_judge_parse.wire_field_consensus
    ; Fusion_judge_parse.wire_field_contradictions
    ; Fusion_judge_parse.wire_field_partial_coverage
    ; Fusion_judge_parse.wire_field_unique_insights
    ; Fusion_judge_parse.wire_field_blind_spots
    ; Fusion_judge_parse.wire_field_resolved_answer
    ; Fusion_judge_parse.wire_field_decision
    ]

(* 패널 계약 = free text (2026-07-01 사고 회귀 가드). prose가 그대로 답변이 된다 —
   JSON envelope 파싱이 없으므로 "provider가 schema를 무시해 prose를 반환"하는
   실패 모드 자체가 존재하지 않는다. *)
let test_panel_outcome_accepts_free_text () =
  match
    Fusion_panel.For_testing.outcome_of_result ~panelist:"panel-a"
      ~model:"provider.model"
      (Ok (response_with_text "  Eio is production-ready for most new projects.  "))
  with
  | Fusion_types.Answered { model; answer; usage } ->
    check string "panel identity preserved" "panel-a" model;
    check string "free text is the answer, trimmed"
      "Eio is production-ready for most new projects." answer;
    check usage_t "missing provider usage defaults to zero" Fusion_types.zero_usage
      usage
  | Fusion_types.Failed failure ->
    fail ("expected free-text answer, got failure: "
          ^ Fusion_types.show_panel_error failure)

let test_panel_outcome_rejects_empty_answer () =
  match
    Fusion_panel.For_testing.outcome_of_result ~panelist:"panel-a"
      ~model:"provider.model"
      (Ok (response_with_text "   "))
  with
  | Fusion_types.Failed
      { failed_model = "panel-a"; reason = Fusion_types.Empty_response detail } ->
    check bool "empty response detail is retained" true (String.length detail > 0)
  | other ->
    fail
      ("expected empty answer failure, got: "
       ^ Fusion_types.show_panel_outcome other)

(* per-agent HTTP 타임아웃은 typed [Timeout]으로 분류된다 — to_string 직렬화로
   [Provider_error]에 뭉개지면 외곽 붕괴(전 패널 Timeout)와 개별 타임아웃을 board
   증거에서 구분할 수 없다. *)
let test_panel_outcome_types_per_agent_timeout () =
  let timeout_error =
    Agent_core.Error.Api
      (Agent_core.Retry.Timeout { message = "120s"; phase = None })
  in
  match
    Fusion_panel.For_testing.outcome_of_result ~panelist:"panel-a"
      ~model:"provider.model" (Error timeout_error)
  with
  | Fusion_types.Failed { failed_model = "panel-a"; reason = Fusion_types.Timeout } ->
    ()
  | other ->
    fail ("expected typed Timeout, got: " ^ Fusion_types.show_panel_outcome other)

(* provider-level 타임아웃도 typed [Timeout]으로 분류된다. connect_timeout(비스트리밍 sync
   경로가 본문 전체를 바운드, detail "timeout phase=http_operation")은
   [Provider (Llm_provider.Error.Timeout _)] variant로 나오는데, [Api (Retry.Timeout _)]
   외곽 래퍼와 다른 arm이라 이전엔 [Provider_error] catch-all로 오귀속됐다. reason_code가
   board/대시보드에 "timeout"으로 나가는지 함께 핀한다. *)
let test_panel_outcome_types_provider_timeout () =
  let timeout_error =
    Agent_core.Error.Provider
      (Llm_provider.Error.Timeout
         { provider = "ollama"
         ; timeout_phase = None
         ; detail = "timeout phase=http_operation"
         })
  in
  match
    Fusion_panel.For_testing.outcome_of_result ~panelist:"panel-a"
      ~model:"provider.model" (Error timeout_error)
  with
  | Fusion_types.Failed
      { failed_model = "panel-a"; reason = Fusion_types.Timeout as reason } ->
    check string "reason_code surfaces as timeout" "timeout"
      (Fusion_agent_core.panel_failure_code reason)
  | other ->
    fail ("expected typed Timeout, got: " ^ Fusion_types.show_panel_outcome other)

(* 심판 분류기도 두 타임아웃 variant([Api (Retry.Timeout _)] 외곽 래퍼 +
   [Provider (Llm_provider.Error.Timeout _)] provider-level)를 [Timeout]으로 매핑하고,
   비-타임아웃 provider 오류는 [Provider_error]로 보존한다 —
   [Fusion_panel.outcome_of_result]와 대칭. 과분류(모든 provider 오류를 Timeout으로)를
   막기 위해 5xx가 provider_error로 남는지도 핀한다. *)
let test_judge_failure_classifies_timeouts () =
  let classify e =
    Fusion_judge.For_testing.failure_of_core_error ~runtime_id:"provider.model"
      ~prefix:"judge run failed: " e
  in
  let api_timeout =
    Agent_core.Error.Api (Agent_core.Retry.Timeout { message = "120s"; phase = None })
  in
  let provider_timeout =
    Agent_core.Error.Provider
      (Llm_provider.Error.Timeout
         { provider = "ollama"
         ; timeout_phase = None
         ; detail = "timeout phase=http_operation"
         })
  in
  let provider_5xx =
    Agent_core.Error.Provider
      (Llm_provider.Error.ServerError
         { provider = "ollama"; code = 503; transient = true; detail = "unavailable" })
  in
  check string "outer Api timeout -> timeout tag" "timeout"
    (Fusion_types.judge_failure_tag (classify api_timeout));
  check string "provider-level timeout -> timeout tag" "timeout"
    (Fusion_types.judge_failure_tag (classify provider_timeout));
  check string "non-timeout provider error stays provider_error" "provider_error"
    (Fusion_types.judge_failure_tag (classify provider_5xx))

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

(* 1차 심판(JOJ)의 예산·도구 표면 결정. 두 값 모두 이전에는 [run_first_judge]가
   통째로 버려서, 같은 요청 안에서 single/refine/meta 심판과 1차 심판의 설정이
   조용히 갈라졌다: [judge_max_output_tokens]는 1차 심판에만 미적용,
   [web_tools=true] 요청은 1차 심판에만 미주입. 결정을 순수 함수로 분리해 핀한다. *)

let judge_spec ?(label = "") ?(web_tools = false) ?max_output_tokens ?timeout_s model
  : Fusion_policy.judge_spec
  =
  { jmodel = model
  ; jlabel = label
  ; jsystem_prompt = "lens"
  ; jweb_tools = web_tools
  ; jmax_output_tokens = max_output_tokens
  ; jtimeout_s = timeout_s
  }

let preset_with ?judge_max_output_tokens ?judge_timeout_s judges : Fusion_policy.preset =
  { name = "quorum"
  ; panels =
      [ { Fusion_policy.models = [ "p.one" ]
        ; label = ""
        ; system_prompt = "panelist"
        ; web_tools = false
        ; max_output_tokens = None
        ; timeout_s = None
        }
      ]
  ; judge = "p.meta"
  ; judge_system_prompt = "meta"
  ; judge_max_output_tokens
  ; judge_timeout_s
  ; judges
  ; min_answered = 1
  }

let int_opt_t = testable (Fmt.option Fmt.int) (Option.equal Int.equal)

let test_first_judge_budget_prefers_own () =
  let j = judge_spec ~max_output_tokens:512 "p.a" in
  let preset = preset_with ~judge_max_output_tokens:2048 [ j ] in
  check int_opt_t "per-judge budget wins over the preset judge budget" (Some 512)
    (Fusion_orchestrator_judge_wave.first_judge_max_tokens ~preset j)

let test_first_judge_budget_falls_back_to_preset () =
  let j = judge_spec "p.a" in
  let preset = preset_with ~judge_max_output_tokens:2048 [ j ] in
  check int_opt_t "unset per-judge budget falls back to the preset judge budget"
    (Some 2048)
    (Fusion_orchestrator_judge_wave.first_judge_max_tokens ~preset j)

let test_first_judge_budget_absent_stays_none () =
  let j = judge_spec "p.a" in
  let preset = preset_with [ j ] in
  check int_opt_t "no budget anywhere stays None (runtime default)" None
    (Fusion_orchestrator_judge_wave.first_judge_max_tokens ~preset j)

let float_opt_t = testable (Fmt.option Fmt.float) (Option.equal Float.equal)

let test_first_judge_deadline_prefers_own () =
  let j = judge_spec ~timeout_s:90.0 "p.a" in
  let preset = preset_with ~judge_timeout_s:180.0 [ j ] in
  check float_opt_t "per-judge deadline wins over the preset judge deadline"
    (Some 90.0)
    (Fusion_orchestrator_judge_wave.first_judge_timeout_s ~preset j)

let test_first_judge_deadline_falls_back_to_preset () =
  let j = judge_spec "p.a" in
  let preset = preset_with ~judge_timeout_s:180.0 [ j ] in
  check float_opt_t "unset per-judge deadline falls back to the preset judge deadline"
    (Some 180.0)
    (Fusion_orchestrator_judge_wave.first_judge_timeout_s ~preset j)

let test_first_judge_deadline_absent_stays_none () =
  let j = judge_spec "p.a" in
  let preset = preset_with [ j ] in
  check float_opt_t "no deadline anywhere stays None (runtime/provider owns it)" None
    (Fusion_orchestrator_judge_wave.first_judge_timeout_s ~preset j)

let test_first_judge_web_tools_from_request () =
  let j = judge_spec ~web_tools:false "p.a" in
  check bool "request/panel-derived web tools reach a judge that did not ask" true
    (Fusion_orchestrator_judge_wave.first_judge_web_tools ~judge_web_tools:true j)

let test_first_judge_web_tools_from_own_spec () =
  let j = judge_spec ~web_tools:true "p.a" in
  check bool "a judge's own web_tools survives a request that did not ask" true
    (Fusion_orchestrator_judge_wave.first_judge_web_tools ~judge_web_tools:false j)

let test_first_judge_web_tools_absent_stays_off () =
  let j = judge_spec ~web_tools:false "p.a" in
  check bool "neither side asks -> no web tools" false
    (Fusion_orchestrator_judge_wave.first_judge_web_tools ~judge_web_tools:false j)

let () =
  run "fusion_judge_usage"
    [ ( "output_contract"
      , [ test_case
            "clears wire response format"
            `Quick
            test_output_contract_clears_wire_response_format
        ; test_case
            "external output contract covers parser wire fields"
            `Quick
            test_external_output_contract_covers_parser_wire_fields
        ; test_case "escapes all XML entities at prompt boundaries" `Quick
            test_prompt_escapes_all_xml_entities
        ] )
    ; ( "panel_outcome"
      , [ test_case "accepts free text" `Quick test_panel_outcome_accepts_free_text
        ; test_case "rejects empty answer" `Quick
            test_panel_outcome_rejects_empty_answer
        ; test_case "types per-agent timeout" `Quick
            test_panel_outcome_types_per_agent_timeout
        ; test_case "types provider-level timeout" `Quick
            test_panel_outcome_types_provider_timeout
        ] )
    ; ( "judge_failure_classification"
      , [ test_case "maps both timeout variants, keeps provider errors" `Quick
            test_judge_failure_classifies_timeouts
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
    ; ( "first_judge_budget"
      , [ test_case "per-judge budget wins" `Quick
            test_first_judge_budget_prefers_own
        ; test_case "falls back to the preset judge budget" `Quick
            test_first_judge_budget_falls_back_to_preset
        ; test_case "absent everywhere stays None" `Quick
            test_first_judge_budget_absent_stays_none
        ] )
    ; ( "first_judge_deadline"
      , [ test_case "per-judge deadline wins" `Quick
            test_first_judge_deadline_prefers_own
        ; test_case "falls back to the preset judge deadline" `Quick
            test_first_judge_deadline_falls_back_to_preset
        ; test_case "absent everywhere stays None" `Quick
            test_first_judge_deadline_absent_stays_none
        ] )
    ; ( "first_judge_web_tools"
      , [ test_case "request-derived setting reaches the judge" `Quick
            test_first_judge_web_tools_from_request
        ; test_case "own spec survives a request that did not ask" `Quick
            test_first_judge_web_tools_from_own_spec
        ; test_case "neither side asks -> off" `Quick
            test_first_judge_web_tools_absent_stays_off
        ] )
    ]
