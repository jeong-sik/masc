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

let test_attach_usage_on_success () =
  match Fusion_judge.attach_usage (Ok sample_synthesis) sample_usage with
  | Ok (_synthesis, usage) ->
    check usage_t "success carries the consumed usage" sample_usage usage
  | Error _ -> fail "expected Ok with usage"

let test_attach_usage_on_parse_failure () =
  (* 핵심 불변식: 파싱이 실패해도(심판이 응답을 생성하느라 토큰을 이미 태움)
     usage가 버려지지 않고 에러에 동반된다. *)
  match Fusion_judge.attach_usage (Error "bad json") sample_usage with
  | Error (msg, usage) ->
    check string "error message preserved" "bad json" msg;
    check usage_t "parse failure still carries the consumed usage" sample_usage
      usage
  | Ok _ -> fail "expected Error with usage"

let () =
  run "fusion_judge_usage"
    [ ( "attach_usage"
      , [ test_case "success carries usage" `Quick test_attach_usage_on_success
        ; test_case "parse failure carries usage" `Quick
            test_attach_usage_on_parse_failure
        ] )
    ]
