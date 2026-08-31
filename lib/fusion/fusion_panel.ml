(* Fusion — 패널 fan-out (구현).
   계약/문서: fusion_panel.mli, docs/rfc/RFC-0252 §7.1

   AGENT_CORE 범용 함수만 소비: Fusion_agent_core.build_agent → Async_agent.all(병렬).
   fusion 개념은 AGENT_CORE에 노출하지 않는다. *)

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
   thinking 오염 분리는 AGENT_CORE 소관이며 이미 동작한다(reasoning은 별도 채널,
   [Fusion_agent_core.answer_text]는 visible text만 투영 — #22854). *)
let outcome_of_result ~(panelist : string) ~(model : string)
    (res : (Agent_core.Types.api_response, Agent_core.Error.t) result)
  : Fusion_types.panel_outcome
  =
  match res with
  | Ok resp ->
    let answer = String.trim (Fusion_agent_core.answer_text resp) in
    if String.length answer = 0 then
      Fusion_types.Failed
        { failed_model = panelist
        ; reason = Fusion_types.Empty_response (Fusion_agent_core.empty_response_detail resp)
        }
    else
      Fusion_types.Answered
        { model = panelist; answer; usage = Fusion_agent_core.usage_of resp }
  | Error (Agent_core.Error.Api (Agent_core.Retry.Timeout _)) ->
    (* per-agent HTTP 타임아웃을 typed [Timeout]으로. 이전에는 to_string 직렬화로
       [Provider_error]에 뭉개져, 외곽 붕괴(전 패널 동시 [Timeout])와 개별 HTTP
       타임아웃을 board 증거에서 구분할 수 없었다. [bridge_failure_of_error]·
       [Fusion_judge.failure_of_core_error]와 대칭. *)
    Fusion_types.Failed { failed_model = panelist; reason = Fusion_types.Timeout }
  | Error (Agent_core.Error.Provider (Llm_provider.Error.Timeout _)) ->
    (* provider-level 타임아웃. 비스트리밍 sync 경로의 connect_timeout(기본 60s)이
       응답 본문 전체를 바운드해 발생하며 detail은 "timeout phase=http_operation"으로
       렌더된다. [Api (Retry.Timeout _)] 외곽 래퍼와 다른 variant라 위 arm이 잡지
       못하고, 이전에는 [Error e] catch-all에서 [Provider_error]로 오귀속됐다 — 개별
       provider 타임아웃이 provider 실패(연결 거부/5xx 등)와 board 증거에서 구분되지
       않았다. 타임아웃은 타임아웃으로 분류한다 (CLAUDE.md §Unknown→Permissive/
       catch-all 회피). *)
    Fusion_types.Failed { failed_model = panelist; reason = Fusion_types.Timeout }
  | Error e ->
    Fusion_types.Failed
      { failed_model = panelist
      ; reason =
          Fusion_types.Provider_error
            (Fusion_agent_core.provider_error_detail ~runtime_id:model
               (Agent_core.Error.to_string e))
      }

let bridge_failure_of_error (error : Agent_core.Error.t) : Fusion_types.panel_failure =
  match error with
  | Agent_core.Error.Api (Agent_core.Retry.Timeout _)
  | Agent_core.Error.Provider (Llm_provider.Error.Timeout _) -> Fusion_types.Timeout
  | _ -> Fusion_types.Bridge_error (Agent_core.Error.to_string error)

let run ~base_dir ~sw ~net ~groups ~prompt ?on_tool_trace ()
  : Fusion_types.panel_outcome list
  =
  let traces = ref [] in
  let record_observer = function
    | Some observer ->
      traces := Fusion_agent_core.finish_tool_observer observer :: !traces
    | None -> ()
  in
  (* 1. 각 그룹의 모델을 그 그룹 설정(system_prompt/tools/timeout)으로
        에이전트 빌드. 빌드 실패는 격리. 그룹순 × 그룹내 모델순으로 평탄화 —
        순서 보존(단일 그룹이면 원 모델 순서 = 오늘과 동일). *)
  let built, official, build_failures =
    List.fold_left
      (fun acc (g : Fusion_policy.panel_group) ->
        let tools = if g.web_tools then Fusion_agent_core.web_tool_bundle () else [] in
        List.fold_left
          (fun (oks, officials, fails) model ->
            (* 정체성은 그룹 라벨 + model로 derive. 카드명(=정체성)으로 빌드하되 provider
               라우팅은 build_agent 내부에서 원 model로 한다 (RFC-0278). *)
            let panelist = Fusion_policy.panelist_id ~label:g.label ~model in
            (* official-client 런타임은 spawn 프로세스라 Agent_core agent 가 될 수
               없다. [build_agent] 는 이들에서 provider 해석 단계에 실패하므로,
               이전에는 패널리스트가 답을 낼 기회 자체가 없었다 — 전원이 그쪽이면
               [Panels_unavailable], 섞이면 정족수로 완료되면서 그 자리는 조용히
               비었다. 여기서 갈라 별도 실행 경로로 보낸다. *)
            if Fusion_official_client.is_official_client ~runtime_id:model
            then (oks, (panelist, model, g.system_prompt, g.timeout_s) :: officials, fails)
            else (
              let observer =
                Option.map
                  (fun _ ->
                     Fusion_agent_core.create_tool_observer
                       ~actor:(Fusion_types.Panel_actor panelist))
                  on_tool_trace
              in
              let event_bus =
                Option.map Fusion_agent_core.tool_observer_event_bus observer
              in
              match
                Fusion_agent_core.build_agent ~sw ~net ~system_prompt:g.system_prompt
                  ?event_bus ~tools
                  ?max_tokens:g.max_output_tokens
                  ?timeout_s:g.timeout_s
                  ~name:panelist model
              with
              | Ok agent ->
                ((agent, panelist, model, observer) :: oks, officials, fails)
              | Error reason ->
                record_observer observer;
                ( oks
                , officials
                , Fusion_types.Failed { failed_model = panelist; reason } :: fails )))
          acc g.models)
      ([], [], [])
      groups
  in
  let built = List.rev built in
  let official = List.rev official in
  let build_failures = List.rev build_failures in
  (* 2. 모든 그룹을 하나의 Async_agent.all에 union으로 던진다 — 이종 설정은 이미 각
        agent에 baked되어 있으므로 단일 fan-out으로 충분. [run_safe]는 예외/취소
        관측 경계이며, timeout은 각 agent의 AGENT_CORE Provider transport가 소유한다.
        [Async_agent.all]은 [Eio.Fiber.List.map] 기반이라 결과를 입력 순서대로 돌려준다.
        그래서 반환 name(=카드명=정체성)에 의존하지 않고 [built]와 위치로 짝지어
        (panelist, model) 둘 다 확보한다 — provider 에러 attribution에 정체성이 아닌
        raw model을 쓰기 위함 (RFC-0278). *)
  let answered =
    match
      Masc_agent_core_bridge.run_safe ~caller:Masc_agent_core_bridge.Fusion_panel (fun () ->
        Ok
          (Agent_core.Async_agent.all ~sw
             ?clock:(Fusion_agent_core.deadline_clock ())
             (List.map
                (fun (agent, _panelist, _model, _observer) -> agent, prompt)
                built)))
    with
    | Ok run_results ->
      List.map2
        (fun (_agent, panelist, model, observer) (_name, res) ->
          record_observer observer;
          outcome_of_result ~panelist ~model res)
        built run_results
    | Error error ->
      (* 구조적 타임아웃은 패널 전체 Timeout. 다른 bridge/bootstrap 오류는
         Timeout으로 오분류하지 않는다. *)
      let reason = bridge_failure_of_error error in
      List.map
        (fun (_agent, panelist, _model, observer) ->
          record_observer observer;
          Fusion_types.Failed { failed_model = panelist; reason })
        built
  in
  (* official-client 패널리스트는 Agent_core fan-out 과 동시에 돈다. 데드라인은
     그룹의 [timeout_s] 가 있으면 그것이, 없으면 어댑터가 소유한 turn timeout 이
     쓰인다 — Agent_core 축이 [body_timeout_s] 를 override 하는 것과 같은 규약이며,
     두 축 모두 preset 이 선언하지 않으면 런타임 설정이 유일한 값으로 남는다.

     usage 는 [zero_usage] 다. 공식 클라이언트는 토큰 회계를 돌려주지 않으므로,
     추정치를 지어내는 대신 "측정하지 않음" 을 0 으로 남긴다. *)
  let official_answered =
    Eio.Fiber.List.map
      (fun (panelist, model, system_prompt, timeout_s) ->
        match
          Fusion_official_client.run_panelist ~base_dir ~runtime_id:model ~system_prompt
            ?timeout_s ~prompt ()
        with
        | Error reason -> Fusion_types.Failed { failed_model = panelist; reason }
        | Ok text ->
          let answer = String.trim text in
          if String.length answer = 0
          then
            Fusion_types.Failed
              { failed_model = panelist
              ; reason =
                  Fusion_types.Empty_response
                    (model ^ ": official client returned no text")
              }
          else
            Fusion_types.Answered
              { model = panelist; answer; usage = Fusion_types.zero_usage })
      official
  in
  Option.iter
    (fun send ->
       let official_gaps =
         List.map
           (fun (panelist, _model, _system_prompt, _timeout_s) ->
              { Fusion_types.actor = Fusion_types.Panel_actor panelist
              ; reason = Fusion_types.Official_client_uninstrumented
              })
           official
       in
       let trace =
         Fusion_types.merge_tool_traces
           (List.rev !traces
            @ [ { Fusion_types.empty_tool_trace with gaps = official_gaps } ])
       in
       send trace)
    on_tool_trace;
  build_failures @ answered @ official_answered

module For_testing = struct
  let outcome_of_result = outcome_of_result
end
