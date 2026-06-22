(* Fusion — 패널 fan-out (구현).
   계약/문서: fusion_panel.mli, docs/rfc/RFC-0252 §7.1

   OAS 범용 함수만 소비: Fusion_oas.build_agent → Async_agent.all(병렬).
   fusion 개념은 OAS에 노출하지 않는다. *)

(* [panelist] = 패널 정체성 (RFC-0278, Fusion_policy.panelist_id) — 라벨 없으면 model
   그대로. panel_answer.model / panel_error.failed_model에 이 정체성을 담는다(심판·sink가
   같은 식별자로 패널을 지칭). Async_agent.all이 카드명(=정체성)을 결과 키로 돌려주므로
   여기 들어오는 name이 곧 정체성이다. *)
let outcome_of_result (panelist : string)
    (res : (Agent_sdk.Types.api_response, Agent_sdk.Error.sdk_error) result)
  : Fusion_types.panel_outcome
  =
  match res with
  | Ok resp ->
    let answer = Fusion_oas.answer_text resp in
    if String.length (String.trim answer) = 0 then
      Fusion_types.Failed
        { failed_model = panelist; reason = Fusion_types.Empty_response }
    else
      Fusion_types.Answered
        { model = panelist; answer; usage = Fusion_oas.usage_of resp }
  | Error e ->
    Fusion_types.Failed
      { failed_model = panelist
      ; reason =
          Fusion_types.Provider_error
            (Fusion_oas.provider_error_detail ~runtime_id:panelist
               (Agent_sdk.Error.to_string e))
      }

let run ~sw ~net ~max_fibers ~outer_timeout_s ~groups ~prompt ()
  : Fusion_types.panel_outcome list
  =
  (* 1. 각 그룹의 모델을 그 그룹 설정(system_prompt/tools/max_tool_calls/timeout)으로
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
                ~max_tool_calls:g.max_tool_calls ~timeout_s:g.timeout_s
                ~name:panelist model
            with
            | Ok agent -> ((agent, panelist) :: oks, fails)
            | Error reason ->
              (oks, Fusion_types.Failed { failed_model = panelist; reason } :: fails))
          acc g.models)
      ([], [])
      groups
  in
  let built = List.rev built in
  let build_failures = List.rev build_failures in
  (* 2. 모든 그룹을 하나의 Async_agent.all에 union으로 던진다 — 이종 설정은 이미 각
        agent에 baked되어 있으므로 단일 fan-out으로 충분. 외곽 run_safe는 그룹 timeout
        중 max로 전체 멈춤을 막는 상한. 반환 name = 에이전트 카드명 = 패널 정체성. *)
  let answered =
    match
      Masc_oas_bridge.run_safe ~caller:"fusion_panel" ~timeout_s:outer_timeout_s (fun () ->
        Ok
          (Agent_sdk.Async_agent.all ~sw ~max_fibers
             (List.map (fun (agent, _panelist) -> (agent, prompt)) built)))
    with
    | Ok run_results ->
      List.map (fun (name, res) -> outcome_of_result name res) run_results
    | Error _ ->
      (* 구조적 타임아웃/취소: 빌드된 패널 전부 Timeout 처리. *)
      List.map
        (fun (_agent, panelist) ->
          Fusion_types.Failed
            { failed_model = panelist; reason = Fusion_types.Timeout })
        built
  in
  build_failures @ answered
