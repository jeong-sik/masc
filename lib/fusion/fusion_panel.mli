(** Fusion — 패널 fan-out. 같은 프롬프트를 N개 모델에 병렬로 던져 답을 수집한다.

    OAS의 범용 [Async_agent.all]을 소비하며, "패널/fusion" 개념은 OAS에 노출하지
    않는다 — OAS 입장에선 독립 에이전트 N개일 뿐이다. 각 모델은 MASC의 기존
    runtime→agent 빌더([Runtime_oas_runner] → [Runtime_agent])로 만든다.

    [web_tools=true]면 [masc_web_search] / [masc_web_fetch]를 패널 에이전트에
    주입해 OpenRouter Fusion의 패널 web tool semantics를 따른다. 재귀 가드는
    [masc_fusion] 도구가 web tool descriptor에 포함되지 않으므로 자동 충족된다.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §7.1 *)

(** 이종 패널 그룹들을 하나의 fan-out으로 병렬 실행해 결과를 [panel_outcome]으로 반환.

    - [groups]: 각 그룹은 자기 [system_prompt]/[web_tools]/[timeout_s]로
      모델들을 에이전트로 빌드한다 (그룹마다 다를 수 있음 = 이종). 모든 그룹의
      에이전트를 하나의 [Async_agent.all]에 union으로 던진다.
    - [web_tools]가 true인 그룹은 web_search/web_fetch 도구를 주입한다.
    - 패널 답변 계약은 free text다: 응답의 visible text 전체(trim)가 답변이 된다.
      빈 텍스트만 [Failed Empty_response]. JSON envelope를 요구하지 않는다 —
      단일 문자열에 envelope는 정보 이득 0에 provider가 schema를 무시하면 패널이
      전멸하는 실패 클래스만 추가했다 (2026-07-01 사고, 구현부 주석 참조).
    - [outer_timeout_s]: 전체 fan-out을 감싸는 [Masc_oas_bridge.run_safe] 구조적
      타임아웃. 웨이브 직렬화를 반영해 [Fusion_policy.panel_outer_timeout_of
      ~max_fibers]로 산출한 값을 넘겨야 한다. 타임아웃 시 빌드된 모델은
      [Failed Timeout].
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
end
