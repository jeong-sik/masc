(** Fusion — 심판. 패널 답들을 judge 모델에 넘겨 구조화 종합({!Fusion_types.judge_synthesis})을 받는다.

    v1: native structured-output([Structured.extract]) 대신 일반 에이전트 실행 +
    {!Fusion_judge_parse}(LLM-facing JSON 파서)를 쓴다. 이유: [Structured.extract]는
    미지원 provider에서 fail-fast인데, MASC 기본 모델(RunPod qwen3.6 등 로컬계열)이
    native structured output을 보장하지 않는다. 일반 실행 + tolerant 파서는 모든
    provider에서 작동한다.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §7.2 *)

(** 질문 + 패널 답들로 심판 프롬프트를 구성한다
    ({!Fusion_judge_parse.expected_json_doc} 지시 포함). 순수 — 테스트 가능. *)
val compose_prompt : question:string -> panel:Fusion_types.panel_outcome list -> string

(** 심판 모델을 실행해 구조화 종합을 받는다.

    [judge_model]: runtime_id("provider.model"). [question]/[panel]로 프롬프트를
    구성해 실행하고, 응답 텍스트를 {!Fusion_judge_parse.of_string}으로 파싱한다.
    빌드/실행/빈응답/파싱 실패는 [Error msg]. 전체는 [Masc_oas_bridge.run_safe]로 감싼다. *)
val run
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> timeout_s:float
  -> judge_system_prompt:string
  -> judge_model:string
  -> question:string
  -> panel:Fusion_types.panel_outcome list
  -> unit
  -> (Fusion_types.judge_synthesis, string) result
