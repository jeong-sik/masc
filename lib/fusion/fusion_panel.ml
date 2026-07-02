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
let outcome_of_result ~(panelist : string) ~(model : string)
    (res : (Agent_sdk.Types.api_response, Agent_sdk.Error.sdk_error) result)
  : Fusion_types.panel_outcome
  =
  match res with
  | Ok resp ->
    let raw = String.trim (Fusion_oas.answer_text resp) in
    if String.length raw = 0 then
      Fusion_types.Failed
        { failed_model = panelist
        ; reason = Fusion_types.Empty_response (Fusion_oas.empty_response_detail resp)
        }
    else (
      match Yojson.Safe.from_string raw with
      | exception Yojson.Json_error _msg ->
        (* Free-text fallback: ollama_cloud trio panels may return unstructured text.
           The judge wraps panel answers in XML tags, so raw text is acceptable. *)
        Fusion_types.Answered
          { model = panelist
          ; answer = raw
          ; usage = Fusion_oas.usage_of resp
          }
      | `Assoc fields ->
        (match List.assoc_opt "answer" fields with
         | Some (`String answer) ->
           let answer = String.trim answer in
           if String.length answer = 0 then
             Fusion_types.Failed
               { failed_model = panelist
               ; reason =
                   Fusion_types.Empty_response (Fusion_oas.empty_response_detail resp)
               }
           else
             Fusion_types.Answered
               { model = panelist; answer; usage = Fusion_oas.usage_of resp }
         | Some _ ->
           Fusion_types.Failed
             { failed_model = panelist
             ; reason =
                 Fusion_types.Invalid_structured_response
                   "panel response field \"answer\" must be a string"
             }
         | None ->
           Fusion_types.Failed
             { failed_model = panelist
             ; reason =
                 Fusion_types.Invalid_structured_response
                   "panel response missing required field \"answer\""
             })
      | _ ->
        Fusion_types.Failed
          { failed_model = panelist
          ; reason =
              Fusion_types.Invalid_structured_response
                "panel response must be a JSON object"
          })
  | Error e ->
    Fusion_types.Failed
      { failed_model = panelist
      ; reason =
          Fusion_types.Provider_error
            (Fusion_oas.provider_error_detail ~runtime_id:model
               (Agent_sdk.Error.to_string e))
      }

let bridge_failure_of_error (error : Agent_sdk.Error.sdk_error) : Fusion_types.panel_failure =
  match error with
  | Agent_sdk.Error.Api (Agent_sdk.Retry.Timeout _) -> Fusion_types.Timeout
  | _ -> Fusion_types.Bridge_error (Agent_sdk.Error.to_string error)

let apply_fusion_panel_output_contract provider_cfg =
  let schema = Keeper_structured_output_schema.fusion_panel_answer_output_schema in
  let native_schema_provider_cfg =
    Keeper_structured_output_schema.apply_to_provider_config schema provider_cfg
  in
  match
    Llm_provider.Provider_config.validate_output_schema_request
      native_schema_provider_cfg
  with
  | Ok () -> Ok native_schema_provider_cfg
  | Error detail -> Error (Printf.sprintf "fusion.panel.output_schema: %s" detail)

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
                ~provider_config_transform:apply_fusion_panel_output_contract
                ?max_tokens:g.max_output_tokens
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
        agent에 baked되어 있으므로 단일 fan-out으로 충분. 외곽 run_safe는 그룹 timeout
        중 max로 전체 멈춤을 막는 상한.
        [Async_agent.all]은 [Eio.Fiber.List.map] 기반이라 결과를 입력 순서대로 돌려준다.
        그래서 반환 name(=카드명=정체성)에 의존하지 않고 [built]와 위치로 짝지어
        (panelist, model) 둘 다 확보한다 — provider 에러 attribution에 정체성이 아닌
        raw model을 쓰기 위함 (RFC-0278). *)
  let answered =
    match
      Masc_oas_bridge.run_safe ~caller:"fusion_panel" ~timeout_s:outer_timeout_s (fun () ->
        Ok
          (Agent_sdk.Async_agent.all ~sw ~max_fibers
             (List.map (fun (agent, _panelist, _model) -> (agent, prompt)) built)))
    with
    | Ok run_results ->
      List.map2
        (fun (_agent, panelist, model) (_name, res) ->
          outcome_of_result ~panelist ~model res)
        built run_results
    | Error error ->
      (* 구조적 타임아웃은 패널 전체 Timeout. 다른 bridge/bootstrap 오류는
         Timeout으로 오분류하지 않는다. *)
      let reason = bridge_failure_of_error error in
      List.map
        (fun (_agent, panelist, _model) ->
          Fusion_types.Failed { failed_model = panelist; reason })
        built
  in
  build_failures @ answered

module For_testing = struct
  let outcome_of_result = outcome_of_result
  let apply_output_contract = apply_fusion_panel_output_contract
end
