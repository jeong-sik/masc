(* Fusion — 패널 fan-out (구현).
   계약/문서: fusion_panel.mli, docs/rfc/RFC-0249 §7.1

   OAS 범용 함수만 소비: Fusion_oas.build_agent → Async_agent.all(병렬).
   fusion 개념은 OAS에 노출하지 않는다. *)

let outcome_of_result (model : string)
    (res : (Agent_sdk.Types.api_response, Agent_sdk.Error.sdk_error) result)
  : Fusion_types.panel_outcome
  =
  match res with
  | Ok resp ->
    let answer = Fusion_oas.answer_text resp in
    if String.length (String.trim answer) = 0 then
      Fusion_types.Failed { failed_model = model; reason = Fusion_types.Empty_response }
    else
      Fusion_types.Answered
        { model; answer; confidence = None; usage = Fusion_oas.usage_of resp }
  | Error e ->
    Fusion_types.Failed
      { failed_model = model
      ; reason = Fusion_types.Provider_error (Agent_sdk.Error.to_string e)
      }

let run ~sw ~net ~max_fibers ~timeout_s ~models ~system_prompt ~prompt ()
  : Fusion_types.panel_outcome list
  =
  (* 1. 각 모델을 에이전트로 빌드. 빌드 실패는 격리. *)
  let built, build_failures =
    List.fold_left
      (fun (oks, fails) model ->
        match Fusion_oas.build_agent ~sw ~net ~system_prompt model with
        | Ok agent -> ((agent, model) :: oks, fails)
        | Error reason ->
          (oks, Fusion_types.Failed { failed_model = model; reason } :: fails))
      ([], [])
      models
  in
  let built = List.rev built in
  let build_failures = List.rev build_failures in
  (* 2. 병렬 실행. 전체는 run_safe로 구조적 타임아웃 강제. Async_agent.all이
        돌려주는 name = 에이전트 카드명 = 우리가 준 model. *)
  let answered =
    match
      Masc_oas_bridge.run_safe ~caller:"fusion_panel" ~timeout_s (fun () ->
        Ok
          (Agent_sdk.Async_agent.all ~sw ~max_fibers
             (List.map (fun (agent, _model) -> (agent, prompt)) built)))
    with
    | Ok run_results ->
      List.map (fun (name, res) -> outcome_of_result name res) run_results
    | Error _ ->
      (* 구조적 타임아웃/취소: 빌드된 모델 전부 Timeout 처리. *)
      List.map
        (fun (_agent, model) ->
          Fusion_types.Failed { failed_model = model; reason = Fusion_types.Timeout })
        built
  in
  build_failures @ answered
