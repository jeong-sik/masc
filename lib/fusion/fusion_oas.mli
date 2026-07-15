(** Fusion — OAS 호출 공유 글루 (panel + judge가 함께 쓴다).

    runtime_id → OAS [Agent.t] 빌드, [api_response] → 텍스트/usage 추출.
    MASC의 기존 runtime→agent 빌더([Runtime_oas_runner] → [Runtime_agent])만
    감싼다; "fusion" 개념은 OAS에 노출하지 않는다.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §7 *)

(** runtime_id("provider.model")로 OAS 에이전트를 빌드한다.

    [tools]를 주면 패널/심판이 tool call을 할 수 있다. Fusion은 호출별 출력
    토큰 예산을 합성하지 않고 resolved runtime의 요청 설정을 그대로 보존한다.
    [timeout_s]는 OAS transport idle/body budget에만 매핑한다. Fusion의 구조적
    wall-clock budget은 호출자가 [Masc_oas_bridge.run_safe]로 소유한다.
    [name]은 에이전트 카드명 — [Async_agent.all]이 결과 키로 반환하는 패널 정체성이다
    (RFC-0278: 같은 model을 다른 라벨로 구분). 미지정이면 카드명=[model]. provider
    라우팅은 카드명과 무관하게 [model]로 한다.
    [provider_config_transform]은 panel/judge처럼 provider-native structured-output
    설정이 필요한 호출자가 resolved provider config를 agent build 전에 보강하는
    hook이다.
    미존재 runtime·빌드 실패는 [panel_failure]로. *)
val build_agent
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> system_prompt:string
  -> ?tools:Agent_sdk.Tool.t list
  -> ?timeout_s:float
  -> ?name:string
  -> ?provider_config_transform:
       (Llm_provider.Provider_config.t
        -> (Llm_provider.Provider_config.t, string) result)
  -> string
  -> (Agent_sdk.Agent.t, Fusion_types.panel_failure) result

(** Test seam for Fusion-local OAS runtime config mapping. Production callers
    should use [build_agent], which also resolves runtime providers and builds
    the OAS agent. *)
module For_testing : sig
  val apply_timeout_budget
    :  ?timeout_s:float
    -> Runtime_agent.config
    -> Runtime_agent.config

  val empty_response_detail : Agent_sdk.Types.api_response -> string
end

(** Attach Fusion's runtime id to an OAS provider error string.
    OAS transport errors may surface as ["Provider 'unknown' ..."] because the
    public SDK error type does not carry MASC runtime ids. Fusion owns the
    panel/judge runtime id, so it patches that display boundary locally. *)
val provider_error_detail : runtime_id:string -> string -> string

(** Stable machine-readable panel failure class. *)
val panel_failure_code : Fusion_types.panel_failure -> string

(** Human-readable panel failure detail with runtime attribution when available. *)
val panel_failure_detail : runtime_id:string -> Fusion_types.panel_failure -> string

(** 이미 attribution된 실패를 재-attribution 없이 렌더 (sink 표시용). Provider_error는
    detail 그대로(실패 시점에 raw model로 정규화됨), Timeout/Bridge/Empty는 사람용 문자열.
    panelist 정체성을 [Provider '...'] 슬롯에 다시 입히지 않는다 (RFC-0278). *)
val panel_failure_text : Fusion_types.panel_failure -> string

(** Empty text response diagnostics. This records stop_reason, token usage, and
    content block counts only; it never exposes reasoning/thinking content. *)
val empty_response_detail : Agent_sdk.Types.api_response -> string

(** [masc_web_search] / [masc_web_fetch]를 [Agent_sdk.Tool.t]로 변환한 목록.
    [Keeper_tool_descriptor]에서 descriptor를 찾지 못하면 빈 목록을 반환한다. *)
val web_tool_bundle : unit -> Agent_sdk.Tool.t list

(** api_response의 [Text] 블록만 모아 답 텍스트로 (Thinking/ToolUse 제외). *)
val answer_text : Agent_sdk.Types.api_response -> string

(** api_response의 토큰 사용량 → [Fusion_types.usage] (없으면 0). *)
val usage_of : Agent_sdk.Types.api_response -> Fusion_types.usage
