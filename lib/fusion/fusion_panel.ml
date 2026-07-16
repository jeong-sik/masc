(* Fusion — 패널 fan-out (구현).
   계약/문서: fusion_panel.mli, docs/rfc/RFC-0252 §7.1

   OAS 범용 함수만 소비: Fusion_oas.build_agent → Async_agent.all(병렬).
   fusion 개념은 OAS에 노출하지 않는다. *)

(* [panelist] = 패널 정체성 (RFC-0278, Fusion_policy.panelist_id) — 라벨 없으면 model
   그대로. panel_answer.model / panel_error.failed_model에 이 정체성을 담는다(심판·sink가
   같은 식별자로 패널을 지칭).
   [model] = routable provider model id. 정체성과 분리해 다룬다: provider 에러
   attribution(`Provider '...'` 슬롯)에는 raw [model]만 쓴다 — panelist(예
   "skeptic (claude)")는 실제 provider id가 아니므로 그 슬롯에 새면 provider 집계/로그
   디버깅이 오염된다 (RFC-0278 §2.4, 정체성·routable model 비압축 원칙). *)
(* 패널 답변 계약 = free text. 패널 답변은 의미상 단일 문자열이므로 {"answer": string}
   JSON envelope(#22768)는 정보 이득 0에 실패 클래스만 추가했다: envelope 파싱은
   provider-native schema 강제(response_format json_schema)에 100% 의존했고 프롬프트에는
   JSON 지시가 전혀 없었는데, ollama.com cloud는 json_schema를 에러 없이 무시한다
   (2026-07-02 실측: deepseek-v4-pro/kimi-k2.6/devstral-small-2 모두 /v1 response_format과
   native /api/chat format 양쪽에서 prose 반환). 결과: 모델은 prose를 반환, strict 파서가
   패널 전멸 — 2026-07-01 사고(8 run 전부 "0 of 3 panels answered",
   invalid_structured_response 17건). free text에는 이 실패 모드 자체가 없다.
   thinking 오염 분리는 OAS 소관이며 이미 동작한다(reasoning은 별도 채널,
   [Fusion_oas.answer_text]는 visible text만 투영 — #22854). *)
let outcome_of_result ~(panelist : string) ~(model : string)
    (res : (Agent_sdk.Types.api_response, Agent_sdk.Error.sdk_error) result)
  : Fusion_types.panel_outcome
  =
  match res with
  | Ok resp ->
    let answer = String.trim (Fusion_oas.answer_text resp) in
    if String.length answer = 0 then
      Fusion_types.Failed
        { failed_model = panelist
        ; reason = Fusion_types.Empty_response (Fusion_oas.empty_response_detail resp)
        }
    else
      Fusion_types.Answered
        { model = panelist; answer; usage = Fusion_oas.usage_of resp }
  | Error (Agent_sdk.Error.Api (Agent_sdk.Retry.Timeout _)) ->
    (* runtime이 반환한 per-agent HTTP 타임아웃을 typed [Timeout]으로 보존한다.
       Fusion은 별도 deadline을 합성하지 않는다. *)
    Fusion_types.Failed { failed_model = panelist; reason = Fusion_types.Timeout }
  | Error (Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _)) ->
    (* provider-level 타임아웃. 비스트리밍 sync 경로의 connect_timeout(기본 60s)이
       응답 본문 전체를 바운드해 발생하며 detail은 "timeout phase=http_operation"으로
       렌더된다. [Api (Retry.Timeout _)] 외곽 래퍼와 다른 variant라 위 arm이 잡지
       못하고, 이전에는 [Error e] catch-all에서 [Provider_error]로 오귀속됐다 — 개별
       provider 타임아웃이 provider 실패(연결 거부/5xx 등)와 board 증거에서 구분되지
       않았다. 타임아웃은 타임아웃으로 분류한다 (CLAUDE.md §Unknown→Permissive/
       catch-all 회피). *)
    Fusion_types.Failed { failed_model = panelist; reason = Fusion_types.Timeout }
  | Error ((Agent_sdk.Error.Api _ | Agent_sdk.Error.Provider _) as e) ->
    Fusion_types.Failed
      { failed_model = panelist
      ; reason =
          Fusion_types.Provider_error
            (Fusion_oas.provider_error_detail ~runtime_id:model
               (Agent_sdk.Error.to_string e))
      }
  | Error
      ( ( Agent_sdk.Error.Agent _
        | Agent_sdk.Error.Mcp _
        | Agent_sdk.Error.Config _
        | Agent_sdk.Error.Serialization _
        | Agent_sdk.Error.Io _
        | Agent_sdk.Error.Orchestration _
        | Agent_sdk.Error.Internal _ ) as e ) ->
    Fusion_types.Failed
      { failed_model = panelist
      ; reason = Fusion_types.Bridge_error (Agent_sdk.Error.to_string e)
      }

let run ~sw ~net ~groups ~prompt ()
  : Fusion_types.panel_outcome list
  =
  (* 1. 각 그룹의 모델을 그 그룹 설정(system_prompt/tools)으로
        에이전트 빌드. 빌드 실패는 격리. 그룹순 × 그룹내 모델순으로 평탄화 —
        순서 보존(단일 그룹이면 원 모델 순서 = 오늘과 동일). *)
  let built, build_failures =
    List.fold_left
      (fun acc (g : Fusion_policy.panel_group) ->
        let tools = if g.web_tools then Fusion_oas.web_tool_bundle () else [] in
        List.fold_left
          (fun (oks, fails) model ->
            (* 정체성은 그룹 라벨 + model로 derive. 카드명(=정체성)으로 빌드하되 provider
               라우팅은 build_agent 내부에서 원 model로 한다 (RFC-0278). *)
            let panelist = Fusion_policy.panelist_id ~label:g.label ~model in
            match
              Fusion_oas.build_agent ~sw ~net ~system_prompt:g.system_prompt ~tools
                ~name:panelist model
            with
            | Ok agent -> ((agent, panelist, model) :: oks, fails)
            | Error reason ->
              (oks, Fusion_types.Failed { failed_model = panelist; reason } :: fails))
          acc g.models)
      ([], [])
      groups
  in
  let built = List.rev built in
  let build_failures = List.rev build_failures in
  (* 2. 모든 그룹을 하나의 Async_agent.all에 union으로 던진다 — 이종 설정은 이미 각
        agent에 baked되어 있으므로 단일 fan-out으로 충분. Fusion은 fan-out timeout을
        합성하지 않는다. [Async_agent.all]은 agent 실행의 ordinary exception과 provider
        실패를 각 SDK result로 격리하고 parent cancellation만 전파한다. 결과는 입력
        순서대로 돌아온다.
        그래서 반환 name(=카드명=정체성)에 의존하지 않고 [built]와 위치로 짝지어
        (panelist, model) 둘 다 확보한다 — provider 에러 attribution에 정체성이 아닌
        raw model을 쓰기 위함 (RFC-0278). *)
  let run_results =
    Agent_sdk.Async_agent.all ~sw
      (List.map (fun (agent, _panelist, _model) -> agent, prompt) built)
  in
  let answered =
    List.map2
      (fun (_agent, panelist, model) (_name, res) ->
        outcome_of_result ~panelist ~model res)
      built run_results
  in
  build_failures @ answered

module For_testing = struct
  let outcome_of_result = outcome_of_result
end
