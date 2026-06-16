(* Fusion — out-of-band 심의 오케스트레이터 (구현).
   계약/문서: fusion_orchestrator.mli, docs/rfc/RFC-0249 §4 *)

type outcome =
  | Denied of Fusion_types.deny_reason
  | Completed of
      { panel : Fusion_types.panel_outcome list
      ; judge : (Fusion_types.judge_synthesis, string) result
      }

let default_panel_prompt =
  "You are an expert panelist. Answer the user's question directly and \
   concisely with your best independent analysis. Do not defer to other \
   models; give your own view."

let run ~sw ~net ~base_dir ~policy ~hourly_count ?(estimated_cost_usd = 0.0)
    ?(panel_system_prompt = default_panel_prompt) ~request () : outcome =
  match Fusion_policy.decide ~policy ~hourly_count ~estimated_cost_usd request with
  | Fusion_types.Deny reason -> Denied reason
  | Fusion_types.Allow req ->
    (match Fusion_policy.find_preset policy req.Fusion_types.preset with
     | None ->
       (* 게이트가 preset 존재를 이미 검증했으므로 도달 불가. 방어적으로 Denied. *)
       Denied (Fusion_types.Preset_unknown req.Fusion_types.preset)
     | Some preset ->
       let panel =
         Fusion_panel.run ~sw ~net ~max_fibers:policy.Fusion_policy.max_concurrent_panels
           ~models:preset.Fusion_policy.panel ~system_prompt:panel_system_prompt
           ~prompt:req.Fusion_types.prompt ()
       in
       let judge =
         Fusion_judge.run ~sw ~net ~judge_model:preset.Fusion_policy.judge
           ~question:req.Fusion_types.prompt ~panel ()
       in
       Fusion_sink.emit ~base_dir ~keeper:req.Fusion_types.keeper
         ~run_id:req.Fusion_types.run_id ~question:req.Fusion_types.prompt ~panel ~judge;
       Completed { panel; judge })
