(** Fusion — 심판. 패널 답들을 judge 모델에 넘겨 구조화 종합({!Fusion_types.judge_synthesis})을 받는다.

    Judge 출력 계약은 typed 2-tier다 (구현부 [apply_fusion_judge_output_contract]
    주석 참조): OAS capability facts가 native structured output을 허용하면 JsonSchema를
    provider config에 싣고(Native tier), 아니면 schema 없이 프롬프트의
    {!Fusion_judge_parse.expected_json_doc} 지시에 의존한다(Prompt tier — 결정은
    로그로 관측). 어느 tier든 응답은 {!Fusion_judge_parse.of_string}의 strict 파싱을
    통과해야 하며 위반은 [Parse_error]로 fail-loud한다. [JsonMode]로의 silent
    downgrade는 없다.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §7.2 *)

(** 질문 + 패널 답들로 심판 프롬프트를 구성한다
    ({!Fusion_judge_parse.expected_json_doc} 지시 포함). 순수 — 테스트 가능. *)
val compose_prompt : question:string -> panel:Fusion_types.panel_outcome list -> string

(** 심판 모델을 실행해 구조화 종합을 받는다.

    [judge_model]: runtime_id("provider.model"). [question]/[panel]로 프롬프트를
    구성해 실행하고, capability-aware output contract를 적용한 응답 텍스트를
    {!Fusion_judge_parse.of_string}으로 파싱한다.
    [web_tools=true]면 심판 에이전트에 web_search/web_fetch를 주입한다.
    [max_tool_calls]: 0이면 무제한, 양수면 심판의 [max_turns]로 근approximate.
    [max_tokens]는 출력 토큰 예산이다. 생략하면 Runtime_agent 기본값을 보존한다.
    빌드/실행/빈응답/파싱 실패는 [Error (msg, usage)]. 전체는 [Masc_oas_bridge.run_safe]로
    감싼다. 성공 시 종합 + 소비 토큰 [usage]를 반환하고(panel과 대칭, 비용 회계 RFC §10),
    실패 시에도 usage를 동반한다 — 응답을 받은 뒤 실패(빈 응답/파싱 실패)는 소비분을,
    토큰 소비 전 실패(빌드/실행/provider 에러)는 [Fusion_types.zero_usage]를 싣는다. 이로써
    호출자(refine degrade 경로)가 파싱 실패한 심판의 비용을 0으로 버리지 않는다. *)
val run
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> timeout_s:float
  -> ?max_tokens:int
  -> judge_system_prompt:string
  -> judge_model:string
  -> question:string
  -> panel:Fusion_types.panel_outcome list
  -> web_tools:bool
  -> max_tool_calls:int
  -> unit
  -> ( Fusion_types.judge_synthesis * Fusion_types.usage
     , Fusion_types.judge_failure * Fusion_types.usage )
     result

(** REFINE 위상의 2차 심판 프롬프트를 구성한다. [compose_prompt]의 질문+패널 블록에
    더해, 1차 심판 종합 [prior]을 [Fusion_types.render_prior_synthesis]로 lossless 렌더해
    <prior_synthesis> 블록으로 싣고, 2차 심판에게 그것을 패널 증거에 비추어 개선하라 지시한다
    (가짜 panel_answer 날조 없음). 순수 — 테스트 가능. *)
val compose_refine_prompt
  :  question:string
  -> panel:Fusion_types.panel_outcome list
  -> prior:Fusion_types.judge_synthesis
  -> string

(** REFINE 위상의 2차 심판을 실행한다. [run]과 동일한 빌드/실행/usage/파싱 경로이며,
    프롬프트만 [compose_refine_prompt ~prior]로 구성하는 점이 다르다([prior]는 1차
    [run] 성공이 낸 종합). 성공 시 개선된 종합 + 2차 심판 토큰 usage를 반환한다(호출자가
    1차 usage와 [Fusion_types.add_usage]로 합산). 실패는 [run]과 동일하게 [Error (msg,
    usage)] — 파싱 실패 시 소비 토큰을 동반하므로 degrade 경로가 비용을 버리지 않는다. *)
val run_refine
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> timeout_s:float
  -> ?max_tokens:int
  -> judge_system_prompt:string
  -> judge_model:string
  -> question:string
  -> panel:Fusion_types.panel_outcome list
  -> prior:Fusion_types.judge_synthesis
  -> web_tools:bool
  -> max_tool_calls:int
  -> unit
  -> ( Fusion_types.judge_synthesis * Fusion_types.usage
     , Fusion_types.judge_failure * Fusion_types.usage )
     result

(** [attach_usage parsed usage]는 심판 응답 파싱 결과에 그 호출이 소비한 [usage]를 성공·
    실패 양 분기 모두에 묶는다. 파싱 실패 시 usage를 버리면 refine degrade 경로가 비용을
    undercount하므로(적대 리뷰 #22087 §1), 이 부착을 단일 지점으로 강제한다. 순수. *)
val attach_usage
  :  (Fusion_types.judge_synthesis, string) result
  -> Fusion_types.usage
  -> ( Fusion_types.judge_synthesis * Fusion_types.usage
     , Fusion_types.judge_failure * Fusion_types.usage )
     result

(** JOJ(judge-of-judges, RFC-0283) meta 심판 프롬프트를 구성한다. [compose_refine_prompt]와
    동형이되 N개 1차 종합 [priors]((정체성, synthesis) 쌍)를 각각 [<judge id="...">] 블록으로
    lossless 렌더하고, meta 심판에게 패널 증거에 비추어 reconcile하라 지시한다. 순수 — 테스트 가능. *)
val compose_meta_prompt
  :  question:string
  -> panel:Fusion_types.panel_outcome list
  -> priors:(string * Fusion_types.judge_synthesis) list
  -> string

(** JOJ meta 심판을 실행한다(RFC-0283). [run]/[run_refine]와 동일한 빌드/실행/usage/파싱
    경로이며, 프롬프트만 [compose_meta_prompt ~priors]로 구성한다([priors]는 N개 1차 심판이
    낸 (정체성, 종합) 쌍). 성공 시 reconcile된 종합 + meta 심판 usage를 반환한다(호출자가
    1차 심판 usage들과 [Fusion_types.add_usage]로 합산). 실패는 [run]/[run_refine]와 동일하게
    [Error (msg, usage)] — meta 심판이 태운 토큰을 degrade 경로가 버리지 않는다. *)
val run_meta
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> timeout_s:float
  -> ?max_tokens:int
  -> judge_system_prompt:string
  -> judge_model:string
  -> question:string
  -> panel:Fusion_types.panel_outcome list
  -> priors:(string * Fusion_types.judge_synthesis) list
  -> web_tools:bool
  -> max_tool_calls:int
  -> unit
  -> ( Fusion_types.judge_synthesis * Fusion_types.usage
     , Fusion_types.judge_failure * Fusion_types.usage )
     result

module For_testing : sig
  val apply_output_contract
    :  Llm_provider.Provider_config.t
    -> (Llm_provider.Provider_config.t, string) result
end
