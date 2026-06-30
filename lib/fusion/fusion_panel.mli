(** Fusion — 패널 fan-out. 같은 프롬프트를 N개 모델에 병렬로 던져 답을 수집한다.

    OAS의 범용 [Async_agent.all]을 소비하며, "패널/fusion" 개념은 OAS에 노출하지
    않는다 — OAS 입장에선 독립 에이전트 N개일 뿐이다. 각 모델은 MASC의 기존
    runtime→agent 빌더([Runtime_oas_runner] → [Runtime_agent])로 만든다.

    [web_tools=true]면 [masc_web_search] / [masc_web_fetch]를 패널 에이전트에
    주입해 OpenRouter Fusion의 패널 web tool semantics를 따른다. 재귀 가드는
    [masc_fusion] 도구가 web tool descriptor에 포함되지 않으므로 자동 충족된다.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §7.1 *)

(** 이종 패널 그룹들을 하나의 fan-out으로 병렬 실행해 결과를 [panel_outcome]으로 반환.

    - [groups]: 각 그룹은 자기 [system_prompt]/[web_tools]/[max_tool_calls]/[timeout_s]로
      모델들을 에이전트로 빌드한다 (그룹마다 다를 수 있음 = 이종). 모든 그룹의
      에이전트를 하나의 [Async_agent.all]에 union으로 던진다.
    - [web_tools]가 true인 그룹은 web_search/web_fetch 도구를 주입한다.
    - 패널 에이전트는 [fusion.panel.output_schema] provider-native structured output
      contract를 요청한다. 응답은 string [answer] 필드를 가진 JSON object여야 하며,
      free-text/invalid JSON/missing answer는 [Failed]로 격리된다.
    - [max_tool_calls]: 0이면 무제한, 양수면 에이전트 [max_turns]로 근approximate.
    - [outer_timeout_s]: 전체 fan-out을 감싸는 [Masc_oas_bridge.run_safe] 구조적
      타임아웃(보통 그룹 timeout 중 max). 타임아웃 시 빌드된 모델은 [Failed Timeout].
    - 빌드 실패·실행 실패·빈 응답은 [Failed]로 격리되어 다른 패널을 죽이지 않는다.
    - 반환 순서: 빌드 실패분 먼저, 그 다음 실행 결과(그룹순 × 그룹내 모델순). *)
val run
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> max_fibers:int
  -> outer_timeout_s:float
  -> groups:Fusion_policy.panel_group list
  -> prompt:string
  -> unit
  -> Fusion_types.panel_outcome list

module For_testing : sig
  val outcome_of_result
    :  panelist:string
    -> model:string
    -> (Agent_sdk.Types.api_response, Agent_sdk.Error.sdk_error) result
    -> Fusion_types.panel_outcome

  val apply_output_contract
    :  Llm_provider.Provider_config.t
    -> (Llm_provider.Provider_config.t, string) result
end
