(* Fusion — out-of-band 심의 오케스트레이터 (구현).
   계약/문서: fusion_orchestrator.mli, docs/rfc/RFC-0252 §4 *)

type outcome =
  | Denied of Fusion_types.deny_reason
  | Sink_failed of string
  | Completed of
      { panel : Fusion_types.panel_outcome list
      ; judge : (Fusion_types.judge_synthesis, string) result
      }

let run ~sw ~net ~base_dir ~policy ~topology ~request () : outcome =
  match Fusion_policy.decide ~policy request with
  | Fusion_types.Deny reason -> Denied reason
  | Fusion_types.Allow req ->
    (match Fusion_policy.find_preset policy req.Fusion_types.preset with
     | None ->
       (* 게이트가 preset 존재를 이미 검증했으므로 도달 불가. 방어적으로 Denied. *)
       Denied (Fusion_types.Preset_unknown req.Fusion_types.preset)
     | Some vp ->
          (* RFC-0280: find_preset가 검증된 preset을 돌려준다 — invariant 재검증 불필요.
             raw preset으로 coerce해 필드를 읽는다(read-only). *)
          let preset = Fusion_policy.Validated_preset.preset vp in
          (* 프롬프트·타임아웃은 preset(=config)에서. 코드 default 없음 — config 로드
             시 Missing_prompt로 fail-fast 검증됨. *)
          let groups = preset.Fusion_policy.panels in
          (* req.web_tools를 각 그룹에 fold-in: effective group web_tools = req || group.
             Fusion_panel.run은 순수하게 그룹 설정만 신뢰한다. *)
          let effective_groups =
            List.map
              (fun (g : Fusion_policy.panel_group) ->
                { g with
                  Fusion_policy.web_tools = req.Fusion_types.web_tools || g.web_tools
                })
              groups
          in
          let panel =
            Fusion_panel.run ~sw ~net
              ~max_fibers:policy.Fusion_policy.max_concurrent_panels
              ~outer_timeout_s:(Fusion_policy.panel_outer_timeout_of groups)
              ~groups:effective_groups ~prompt:req.Fusion_types.prompt ()
          in
          (* 심판은 preset당 1개이므로 web_tools/max_tool_calls를 그룹들에서 derive한다 —
             단일 그룹(legacy desugar)이면 오늘과 byte-identical(req||group, 그룹 값). *)
          let judge_web_tools =
            Fusion_policy.judge_web_tools_of ~req_web_tools:req.Fusion_types.web_tools
              groups
          in
          let judge_max_tool_calls = Fusion_policy.judge_tool_budget_of groups in
          (* 1차 심판 — 모든 위상 공통. *)
          let first_judge_full =
            Fusion_judge.run ~sw ~net
              ~timeout_s:preset.Fusion_policy.judge_timeout_s
              ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
              ~judge_model:preset.Fusion_policy.judge
              ~question:req.Fusion_types.prompt ~panel ~web_tools:judge_web_tools
              ~max_tool_calls:judge_max_tool_calls ()
          in
          (* refine 헬퍼: 1차 종합 (s1,u1)을 2차 심판이 재검토하고 두 usage를 합산한다.
             2차 실패면 1차 종합으로 graceful degrade(Simple보다 절대 나빠지지 않음 —
             단 silent 아님: warn 로깅). Refine(무조건)와 Conditional(Insufficient일 때만)이
             공유한다 — 같은 변환을 두 번 짜지 않는다(N-of-M 회피). *)
          let refine_over (s1, u1) =
            match
              Fusion_judge.run_refine ~sw ~net
                ~timeout_s:preset.Fusion_policy.judge_timeout_s
                ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
                ~judge_model:preset.Fusion_policy.judge
                ~question:req.Fusion_types.prompt ~panel ~prior:s1
                ~web_tools:judge_web_tools ~max_tool_calls:judge_max_tool_calls ()
            with
            | Ok (s2, u2) -> Ok (s2, Fusion_types.add_usage u1 u2)
            | Error msg ->
              Log.Keeper.warn ~keeper_name:req.Fusion_types.keeper
                "fusion run %s refine judge failed, keeping first synthesis: %s"
                req.Fusion_types.run_id msg;
              Ok (s1, u1)
          in
          (* 위상별 reduce. Simple은 1차 종합 그대로(현행과 byte-identical — downstream
             judge/judge_usage/emit 동일). Refine는 무조건 refine. Conditional은 1차 판정이
             [Insufficient](애매)일 때만 refine, 그 외엔 1차 종합 그대로(= Simple). 1차 심판
             실패는 어느 위상이든 그대로 전파(refine할 종합이 없음 = Simple과 동일 에러 의미).
             topology·decision 둘 다 닫힌 합 exhaustive match라 새 변형 추가 시 컴파일 에러로
             누락(위상 dispatch / escalate 정책)을 강제한다 — catch-all 없음. *)
          let judge_full =
            match topology with
            | Fusion_types.Simple -> first_judge_full
            | Fusion_types.Refine ->
              (match first_judge_full with
               | Error _ as e -> e
               | Ok pair -> refine_over pair)
            | Fusion_types.Conditional ->
              (match first_judge_full with
               | Error _ as e -> e
               | Ok ((s1, _) as pair) ->
                 if Fusion_types.decision_warrants_escalation s1.Fusion_types.decision
                 then refine_over pair
                 else Ok pair)
          in
          (* 심판 종합과 토큰 usage를 분리: outcome.judge는 synthesis만(소비자 호환),
             usage는 sink 비용 회계로(RFC §10 패널N+심판M). 실패한 심판은 0(패널 Failed와 대칭). *)
          let judge = Result.map fst judge_full in
          let judge_usage =
            match judge_full with
            | Ok (_, u) -> u
            | Error _ -> Fusion_types.zero_usage
          in
          (match
             Fusion_sink.emit ~base_dir ~keeper:req.Fusion_types.keeper
               ~run_id:req.Fusion_types.run_id ~question:req.Fusion_types.prompt
               ~panel ~judge ~judge_usage
           with
           | Ok () -> Completed { panel; judge }
           | Error msg -> Sink_failed msg))
