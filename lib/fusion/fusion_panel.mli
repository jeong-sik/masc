(** Fusion — 패널 fan-out. 같은 프롬프트를 N개 모델에 병렬로 던져 답을 수집한다.

    AGENT_CORE의 범용 [Async_agent.all]을 소비하며, "패널/fusion" 개념은 AGENT_CORE에 노출하지
    않는다 — AGENT_CORE 입장에선 독립 에이전트 N개일 뿐이다. 각 모델은 MASC의 기존
    runtime→agent 빌더([Runtime_agent_core_runner] → [Runtime_agent])로 만든다.

    [web_tools=true]면 [masc_web_search] / [masc_web_fetch]를 패널 에이전트에
    주입해 OpenRouter Fusion의 패널 web tool semantics를 따른다. 재귀 가드는
    [masc_fusion] 도구가 web tool descriptor에 포함되지 않으므로 자동 충족된다.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §7.1 *)

(** 패널 자리들을 동시에 실행해 결과를 [panel_outcome]으로 반환한다.

    - 자리 하나 = 그룹의 [models] 한 항목. 항목 값은 경로 이름이다 (lane 이름 또는
      런타임 id, {!Fusion_seat.resolve}). 정체성은 그룹 라벨 + 경로 이름이다.
    - 한 자리는 경로의 후보를 차례로 시도하고 처음 비어 있지 않은 답에서 멈춘다.
      Agent_core 후보는 그룹의 [system_prompt]/[web_tools]/출력 예산/[timeout_s]로
      에이전트를 빌드하고, 공식 클라이언트 후보는 한 턴짜리 CLI 실행으로 돈다.
      실패는 종류와 상관없이 다음 후보로 넘어간다.
    - 답한 자리의 usage 는 답한 시도와 그 전에 실패한 시도가 쓴 토큰의 합이다.
    - 경로를 못 풀면 [Failed (Unknown_route _ | Route_unavailable _)]이고 후보를 시도하지
      않는다.
    - 패널 답변 계약은 free text다: 응답의 visible text 전체(trim)가 답변이 된다.
      JSON envelope를 요구하지 않는다 (구현부 주석 참조).
    - Fusion은 fan-out timeout을 합성하지 않는다. provider/runtime timeout은
      typed [Timeout] 관측으로 보존한다.
    - 반환 순서와 [on_seat_routes] 순서는 그룹순 × 그룹내 항목순이다. *)
val run
  :  base_dir:string
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> groups:Fusion_policy.panel_group list
  -> prompt:string
  -> ?on_tool_trace:(Fusion_types.tool_trace -> unit)
       (** Receives actual AGENT_CORE tool events and explicit official-client
           observation gaps after every seat settles, one entry per attempt. *)
  -> ?on_seat_routes:(Fusion_types.seat_route list -> unit)
       (** Receives one seat route per panel seat after every seat settles. *)
  -> unit
  -> Fusion_types.panel_outcome list

module For_testing : sig
  val attempt_of_result
    :  model:string
    -> (Agent_core.Types.api_response, Agent_core.Error.t) result
    -> (string * Fusion_types.usage, Fusion_types.panel_failure * Fusion_types.usage) result
end
