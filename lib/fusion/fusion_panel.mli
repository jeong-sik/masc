(** Fusion — 패널 fan-out. 같은 프롬프트를 N개 모델에 병렬로 던져 답을 수집한다.

    OAS의 범용 [Async_agent.all]을 소비하며, "패널/fusion" 개념은 OAS에 노출하지
    않는다 — OAS 입장에선 독립 에이전트 N개일 뿐이다. 각 모델은 MASC의 기존
    runtime→agent 빌더([Runtime_oas_runner] → [Runtime_agent])로 만든다.

    v1 단순화: 패널은 도구 없이([tools = []]) read-only 분석만 한다. web 도구 주입은
    keeper 컨텍스트(Workspace.config + keeper_meta) 결합이 필요해 Phase 2b로 미룬다.
    도구가 없으므로 재귀 가드(masc_fusion 도구 배제)는 자동 충족된다.

    설계 SSOT: docs/rfc/RFC-0251-fusion-panel-judge-deliberation.md §7.1 *)

(** 패널을 병렬 실행해 각 모델의 결과를 [panel_outcome]으로 반환한다.

    - [models]: runtime_id("provider.model") 목록. 각자 에이전트로 빌드된다.
    - 빌드 실패(미존재 runtime 등)·실행 실패·빈 응답은 [Failed]로 격리되어 다른
      패널을 죽이지 않는다([Async_agent.all]의 per-agent 격리 + 본 매핑).
    - 전체 호출은 [Masc_oas_bridge.run_safe]로 감싸 구조적 타임아웃을 강제한다;
      타임아웃 시 빌드된 모델들은 [Failed Timeout]이 된다.
    - 반환 순서: 빌드 실패분 먼저, 그 다음 실행 결과(입력 모델 순). *)
val run
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> max_fibers:int
  -> timeout_s:float
  -> models:string list
  -> system_prompt:string
  -> prompt:string
  -> unit
  -> Fusion_types.panel_outcome list
