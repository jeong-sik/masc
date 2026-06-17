(* Fusion — out-of-band 심의 오케스트레이터 (구현).
   계약/문서: fusion_orchestrator.mli, docs/rfc/RFC-0255 §4 *)

type outcome =
  | Denied of Fusion_types.deny_reason
  | Sink_failed of string
  | Completed of
      { panel : Fusion_types.panel_outcome list
      ; judge : (Fusion_types.judge_synthesis, string) result
      }

let run ~sw ~net ~base_dir ~budget ~hour_bucket ~policy ~request () : outcome =
  match Fusion_policy.decide ~policy request with
  | Fusion_types.Deny reason -> Denied reason
  | Fusion_types.Allow req ->
    (match
       Fusion_budget.try_incr_if_under budget ~hour_bucket
         ~limit:policy.Fusion_policy.per_hour_budget
     with
     | Error () -> Denied Fusion_types.Over_hourly_budget
     | Ok _hourly_count ->
       (match Fusion_policy.find_preset policy req.Fusion_types.preset with
        | None ->
          (* 게이트가 preset 존재를 이미 검증했으므로 도달 불가. 방어적으로 Denied. *)
          Denied (Fusion_types.Preset_unknown req.Fusion_types.preset)
        | Some preset ->
          (* 프롬프트·타임아웃은 preset(=config)에서. 코드 default 없음 — config 로드
             시 Missing_prompt로 fail-fast 검증됨. *)
          let web_tools =
            req.Fusion_types.web_tools || preset.Fusion_policy.web_tools
          in
          let max_tool_calls = preset.Fusion_policy.max_tool_calls_per_panel in
          let start_time_unix = Unix.gettimeofday () in
          let panel =
            Fusion_panel.run ~sw ~net
              ~max_fibers:policy.Fusion_policy.max_concurrent_panels
              ~timeout_s:preset.Fusion_policy.panel_timeout_s
              ~models:preset.Fusion_policy.panel
              ~system_prompt:preset.Fusion_policy.panel_system_prompt
              ~prompt:req.Fusion_types.prompt ~web_tools ~max_tool_calls_per_panel:max_tool_calls
              ()
          in
          let judge =
            Fusion_judge.run ~sw ~net
              ~timeout_s:preset.Fusion_policy.judge_timeout_s
              ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
              ~judge_model:preset.Fusion_policy.judge
              ~question:req.Fusion_types.prompt ~panel ~web_tools
              ~max_tool_calls ()
          in
          (match
             Fusion_sink.emit ~base_dir ~keeper:req.Fusion_types.keeper
               ~run_id:req.Fusion_types.run_id ~preset:preset.Fusion_policy.name
               ~trigger:req.Fusion_types.trigger
               ~question:req.Fusion_types.prompt ~panel ~judge
               ~judge_model:preset.Fusion_policy.judge ~start_time_unix
           with
           | Ok () -> Completed { panel; judge }
           | Error msg -> Sink_failed msg)))
