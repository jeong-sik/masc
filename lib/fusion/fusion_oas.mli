(** Fusion — OAS 호출 공유 글루 (panel + judge가 함께 쓴다).

    runtime_id → OAS [Agent.t] 빌드, [api_response] → 텍스트/usage 추출.
    MASC의 기존 runtime→agent 빌더([Runtime_oas_runner] → [Runtime_agent])만
    감싼다; "fusion" 개념은 OAS에 노출하지 않는다.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §7 *)

(** runtime_id("provider.model")로 OAS 에이전트를 빌드한다.

    [tools]를 주면 패널/심판이 tool call을 할 수 있다.
    [max_tool_calls] > 0이면 에이전트의 [max_turns]를 해당 횟수+1로 제한해
    OpenRouter Fusion의 per-panel tool budget을 근사한다.
    [timeout_s]는 OAS transport idle/body budget에만 매핑한다. Fusion의 구조적
    wall-clock budget은 호출자가 [Masc_oas_bridge.run_safe]로 소유하며, OAS
    [max_execution_time_s]에는 매핑하지 않는다.
    미존재 runtime·빌드 실패는 [panel_failure]로. *)
val build_agent
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> system_prompt:string
  -> ?tools:Agent_sdk.Tool.t list
  -> ?max_tool_calls:int
  -> ?timeout_s:float
  -> string
  -> (Agent_sdk.Agent.t, Fusion_types.panel_failure) result

(** Attach Fusion's runtime id to an OAS provider error string.
    OAS transport errors may surface as ["Provider 'unknown' ..."] because the
    public SDK error type does not carry MASC runtime ids. Fusion owns the
    panel/judge runtime id, so it patches that display boundary locally. *)
val provider_error_detail : runtime_id:string -> string -> string

(** [masc_web_search] / [masc_web_fetch]를 [Agent_sdk.Tool.t]로 변환한 목록.
    [Keeper_tool_descriptor]에서 descriptor를 찾지 못하면 빈 목록을 반환한다. *)
val web_tool_bundle : unit -> Agent_sdk.Tool.t list

(** api_response의 [Text] 블록만 모아 답 텍스트로 (Thinking/ToolUse 제외). *)
val answer_text : Agent_sdk.Types.api_response -> string

(** api_response의 토큰 사용량 → [Fusion_types.usage] (없으면 0). *)
val usage_of : Agent_sdk.Types.api_response -> Fusion_types.usage
