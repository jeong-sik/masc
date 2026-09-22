(* Fusion — 패널 fan-out (구현).
   계약/문서: fusion_panel.mli, docs/rfc/RFC-0252 §7.1, docs/rfc/RFC-fusion-seat-routes.md

   panel 한 명이 한 자리다. 자리들은 동시에 돌고, 한 자리 안에서는 경로의 후보를
   차례로 시도한다(Fusion_seat). 후보 하나를 시도하는 방법은 두 가지다:
   Agent_core 런타임은 Fusion_agent_core.build_agent → Async_agent.all, 공식
   클라이언트 런타임은 Fusion_official_client.run_panelist. fusion 개념은
   AGENT_CORE에 노출하지 않는다. *)

(* [panelist] = 패널 정체성 (RFC-0278, Fusion_policy.panelist_id) — 라벨 + 적힌 경로.
   panel_answer.model / panel_error.failed_model에 이 정체성을 담는다(심판·sink가
   같은 식별자로 패널을 지칭).
   [model] = 이번 시도의 후보 런타임 id. provider 에러 attribution(`Provider '...'`
   슬롯)에는 이 값만 쓴다 — panelist(예 "skeptic (claude)")는 실제 provider id가
   아니므로 그 슬롯에 새면 provider 집계/로그 디버깅이 오염된다 (RFC-0278 §2.4). *)
(* 패널 답변 계약 = free text. 패널 답변은 의미상 단일 문자열이므로 {"answer": string}
   JSON envelope(#22768)는 정보 이득 0에 실패 클래스만 추가했다: envelope 파싱은
   provider-native schema 강제(response_format json_schema)에 100% 의존했고 프롬프트에는
   JSON 지시가 전혀 없었는데, ollama.com cloud는 json_schema를 에러 없이 무시한다
   (2026-07-02 실측: deepseek-v4-pro/kimi-k2.6/devstral-small-2 모두 /v1 response_format과
   native /api/chat format 양쪽에서 prose 반환). 결과: 모델은 prose를 반환, strict 파서가
   패널 전멸 — 2026-07-01 사고(8 run 전부 "0 of 3 panels answered",
   invalid_structured_response 17건). free text에는 이 실패 모드 자체가 없다.
   thinking 오염 분리는 AGENT_CORE 소관이며 이미 동작한다(reasoning은 별도 채널,
   [Fusion_agent_core.answer_text]는 visible text만 투영 — #22854).

   빈 답도 usage 를 싣는다: 응답은 받았으므로 토큰은 이미 쓰였다. 다음 후보가 답하면
   그 자리의 usage 에 더해진다. *)
let attempt_of_result ~(model : string)
    (res : (Agent_core.Types.api_response, Agent_core.Error.t) result)
  : (string * Fusion_types.usage, Fusion_types.panel_failure * Fusion_types.usage) result
  =
  match res with
  | Ok resp ->
    let answer = String.trim (Fusion_agent_core.answer_text resp) in
    let usage = Fusion_agent_core.usage_of resp in
    if String.length answer = 0 then
      Error (Fusion_types.Empty_response (Fusion_agent_core.empty_response_detail resp), usage)
    else Ok (answer, usage)
  | Error (Agent_core.Error.Api (Agent_core.Retry.Timeout _)) ->
    (* per-agent HTTP 타임아웃을 typed [Timeout]으로. [Fusion_judge.failure_of_core_error]
       와 대칭. *)
    Error (Fusion_types.Timeout, Fusion_types.zero_usage)
  | Error (Agent_core.Error.Provider (Llm_provider.Error.Timeout _)) ->
    (* provider-level 타임아웃. 비스트리밍 sync 경로의 connect_timeout(기본 60s)이
       응답 본문 전체를 바운드해 발생하며 detail은 "timeout phase=http_operation"으로
       렌더된다. [Api (Retry.Timeout _)] 외곽 래퍼와 다른 variant 이지만 같은
       타임아웃이다 (CLAUDE.md §Unknown→Permissive/catch-all 회피). *)
    Error (Fusion_types.Timeout, Fusion_types.zero_usage)
  | Error e ->
    Error
      ( Fusion_types.Provider_error
          (Fusion_agent_core.provider_error_detail ~runtime_id:model
             (Agent_core.Error.to_string e))
      , Fusion_types.zero_usage )

let bridge_failure_of_error (error : Agent_core.Error.t) : Fusion_types.panel_failure =
  match error with
  | Agent_core.Error.Api (Agent_core.Retry.Timeout _)
  | Agent_core.Error.Provider (Llm_provider.Error.Timeout _) -> Fusion_types.Timeout
  | _ -> Fusion_types.Bridge_error (Agent_core.Error.to_string error)

let panel_failure_of_route_failure : Fusion_seat.route_failure -> Fusion_types.panel_failure
  = function
  | Fusion_seat.Unknown_route route -> Fusion_types.Unknown_route route
  | Fusion_seat.Route_unavailable detail -> Fusion_types.Route_unavailable detail

let official_gap_trace ~panelist =
  { Fusion_types.empty_tool_trace with
    gaps =
      [ { Fusion_types.actor = Fusion_types.Panel_actor panelist
        ; reason = Fusion_types.Official_client_uninstrumented
        }
      ]
  }

type seat_result =
  { outcome : Fusion_types.panel_outcome
  ; traces : Fusion_types.tool_trace list  (** 시도 순서대로 *)
  ; route : Fusion_types.seat_route
  }

let run_seat ~base_dir ~sw ~net ~prompt ~observe_tools (g : Fusion_policy.panel_group)
    route : seat_result
  =
  (* 정체성은 그룹 라벨 + 적힌 경로로 derive 한다 (RFC-0278). 경로가 lane 이면 lane
     이름이 정체성이고, 실제로 답한 후보는 seat_route 가 따로 기록한다. *)
  let panelist = Fusion_policy.panelist_id ~label:g.label ~model:route in
  let seat = Fusion_types.Panel_seat panelist in
  match Fusion_seat.resolve route with
  | Error failure ->
    { outcome =
        Fusion_types.Failed
          { failed_model = panelist; reason = panel_failure_of_route_failure failure }
    ; traces = []
    ; route = Fusion_seat.unresolved_seat_route ~seat ~route
    }
  | Ok candidates ->
    let tools = if g.web_tools then Fusion_agent_core.web_tool_bundle () else [] in
    let traces = ref [] in
    let attempt_agent_core model =
      let observer =
        if observe_tools
        then
          Some
            (Fusion_agent_core.create_tool_observer
               ~actor:(Fusion_types.Panel_actor panelist))
        else None
      in
      let event_bus = Option.map Fusion_agent_core.tool_observer_event_bus observer in
      let finish () =
        Option.iter
          (fun observer ->
             traces := Fusion_agent_core.finish_tool_observer observer :: !traces)
          observer
      in
      let result =
        match
          Fusion_agent_core.build_agent ~sw ~net ~system_prompt:g.system_prompt
            ?event_bus ~tools
            ?max_tokens:g.max_output_tokens
            ?timeout_s:g.timeout_s
            ~name:panelist model
        with
        | Error reason -> Error (reason, Fusion_types.zero_usage)
        | Ok agent ->
          (* [run_safe]는 예외/취소 관측 경계이며, timeout은 agent의 AGENT_CORE
             Provider transport가 소유한다. *)
          (match
             Masc_agent_core_bridge.run_safe ~caller:Masc_agent_core_bridge.Fusion_panel
               (fun () ->
                  Ok
                    (Agent_core.Async_agent.all ~sw
                       ?clock:(Fusion_agent_core.deadline_clock ())
                       [ agent, prompt ]))
           with
           | Ok [ (_name, res) ] -> attempt_of_result ~model res
           | Ok results ->
             Error
               ( Fusion_types.Bridge_error
                   (Printf.sprintf "Async_agent.all returned %d results for one agent"
                      (List.length results))
               , Fusion_types.zero_usage )
           | Error error -> Error (bridge_failure_of_error error, Fusion_types.zero_usage))
      in
      finish ();
      result
    in
    (* official-client 후보. 데드라인은 그룹의 [timeout_s] 가 있으면 그것이, 없으면
       어댑터가 소유한 turn timeout 이 쓰인다 — Agent_core 축이 [body_timeout_s] 를
       override 하는 것과 같은 규약이다. usage 는 [zero_usage] 다: 공식 클라이언트는
       토큰 회계를 돌려주지 않으므로 추정치를 지어내지 않는다. *)
    let attempt_official model =
      if observe_tools then traces := official_gap_trace ~panelist :: !traces;
      match
        Fusion_official_client.run_panelist ~base_dir ~runtime_id:model
          ~system_prompt:g.system_prompt ?timeout_s:g.timeout_s ~prompt ()
      with
      | Error reason -> Error (reason, Fusion_types.zero_usage)
      | Ok text ->
        let answer = String.trim text in
        if String.length answer = 0
        then
          Error
            ( Fusion_types.Empty_response (model ^ ": official client returned no text")
            , Fusion_types.zero_usage )
        else Ok (answer, Fusion_types.zero_usage)
    in
    let attempt model =
      if Fusion_official_client.is_official_client ~runtime_id:model
      then attempt_official model
      else attempt_agent_core model
    in
    let walk = Fusion_seat.walk candidates ~attempt in
    let failed_usage failed =
      List.fold_left
        (fun total (_model, (_reason, usage)) -> Fusion_types.add_usage total usage)
        Fusion_types.zero_usage failed
    in
    let outcome =
      match walk with
      | Fusion_seat.Answered { answer = (answer, usage); failed; runtime = _ } ->
        Fusion_types.Answered
          { model = panelist
          ; answer
          ; usage = Fusion_types.add_usage usage (failed_usage failed)
          }
      | Fusion_seat.Exhausted { last = (reason, _usage); failed = _ } ->
        Fusion_types.Failed { failed_model = panelist; reason }
    in
    { outcome
    ; traces = List.rev !traces
    ; route =
        Fusion_seat.seat_route ~seat ~route
          ~to_attempt_failure:(fun (reason, _usage) ->
            Fusion_types.Panel_attempt_failed reason)
          walk
    }

let run ~base_dir ~sw ~net ~groups ~prompt ?on_tool_trace ?on_seat_routes () =
  (* 그룹순 × 그룹내 경로순. 이 순서가 반환 순서이자 seat_route 순서다. *)
  let seats =
    List.concat_map
      (fun (g : Fusion_policy.panel_group) -> List.map (fun route -> g, route) g.models)
      groups
  in
  let results =
    Eio.Fiber.List.map
      (fun (g, route) ->
         run_seat ~base_dir ~sw ~net ~prompt
           ~observe_tools:(Option.is_some on_tool_trace) g route)
      seats
  in
  Option.iter
    (fun send ->
       send (Fusion_types.merge_tool_traces (List.concat_map (fun r -> r.traces) results)))
    on_tool_trace;
  Option.iter (fun send -> send (List.map (fun r -> r.route) results)) on_seat_routes;
  List.map (fun r -> r.outcome) results

module For_testing = struct
  let attempt_of_result = attempt_of_result
end
