(** Fusion — OAS 호출 공유 글루 (panel + judge가 함께 쓴다).

    runtime_id → OAS [Agent.t] 빌드, [api_response] → 텍스트/usage 추출.
    MASC의 기존 runtime→agent 빌더([Runtime_oas_runner] → [Runtime_agent])만
    감싼다; "fusion" 개념은 OAS에 노출하지 않는다.

    설계 SSOT: docs/rfc/RFC-0249-fusion-panel-judge-deliberation.md §7 *)

(** runtime_id("provider.model")로 OAS 에이전트를 빌드한다. v1: 도구 없음([tools=[]]),
    read-only 분석/심판용. 미존재 runtime·빌드 실패는 [panel_failure]로. *)
val build_agent
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> system_prompt:string
  -> string
  -> (Agent_sdk.Agent.t, Fusion_types.panel_failure) result

(** api_response의 [Text] 블록만 모아 답 텍스트로 (Thinking/ToolUse 제외). *)
val answer_text : Agent_sdk.Types.api_response -> string

(** api_response의 토큰 사용량 → [Fusion_types.usage] (없으면 0). *)
val usage_of : Agent_sdk.Types.api_response -> Fusion_types.usage
