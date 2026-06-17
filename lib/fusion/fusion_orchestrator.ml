(* Fusion — out-of-band panel+judge gate 오케스트레이터 (구현).
   계약/문서: fusion_orchestrator.mli, docs/rfc/RFC-0255 §4 *)

type outcome =
  | Denied of Fusion_types.deny_reason
  | Completed of
      { panel : Fusion_types.panel_outcome list
      ; judge : (Fusion_types.judge_synthesis, Fusion_types.judge_error) result
      }

let run ~sw ~net ~base_dir ~policy ~request () : outcome =
  (* 방어적 재판정 — 예산은 호출자(fusion_tool)가 이미 try_incr_if_under로 원자
     소모했으므로 여기서 다시 검사하지 않는다(decide는 budget-free). *)
  match Fusion_policy.decide ~policy request with
  | Fusion_types.Deny reason -> Denied reason
  | Fusion_types.Allow req ->
    (match Fusion_policy.find_preset policy req.Fusion_types.preset with
     | None ->
       (* 게이트가 preset 존재를 이미 검증했으므로 도달 불가. 방어적으로 Denied. *)
       Denied (Fusion_types.Preset_unknown req.Fusion_types.preset)
     | Some preset ->
       (* 프롬프트·타임아웃은 preset(=config)에서. 프롬프트는 config 로드 시
          Missing_prompt로 fail-fast 검증되고, 타임아웃은 preset 생략 시
          Fusion_policy.default_timeout_s(120s)로 falls back한다. *)
       let panel =
         Fusion_panel.run ~sw ~net ~max_fibers:policy.Fusion_policy.max_concurrent_panels
           ~timeout_s:preset.Fusion_policy.panel_timeout_s
           ~models:preset.Fusion_policy.panel
           ~system_prompt:preset.Fusion_policy.panel_system_prompt
           ~prompt:req.Fusion_types.prompt ()
       in
       let judge =
         Fusion_judge.run ~sw ~net
           ~timeout_s:preset.Fusion_policy.judge_timeout_s
           ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
           ~judge_model:preset.Fusion_policy.judge
           ~question:req.Fusion_types.prompt ~panel ()
       in
       Fusion_sink.emit ~base_dir ~keeper:req.Fusion_types.keeper
         ~run_id:req.Fusion_types.run_id ~question:req.Fusion_types.prompt ~panel ~judge;
       Completed { panel; judge })
