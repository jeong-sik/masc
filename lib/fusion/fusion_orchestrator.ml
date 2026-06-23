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
          (* 단일 심판 thunk — Simple/Refine/Conditional이 쓰는 preset.judge 1회 실행.
             thunk라 JOJ 위상은 이를 호출하지 않는다(JOJ는 자기 judges로 fan-out하므로
             단일 심판 호출이 낭비/오답). 각 분기에서 최대 1회 호출. *)
          let run_single_judge () =
            Fusion_judge.run ~sw ~net
              ~timeout_s:preset.Fusion_policy.judge_timeout_s
              ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
              ~judge_model:preset.Fusion_policy.judge
              ~question:req.Fusion_types.prompt ~panel ~web_tools:judge_web_tools
              ~max_tool_calls:judge_max_tool_calls ()
          in
          (* refine 헬퍼: 1차 종합 (s1,u1)을 2차 심판이 재검토하고 두 usage를 합산한다.
             canonical result와 실행 노드 관측([judge_outcome list], RFC-0284)을 함께
             만든다 — canonical은 downstream(chat 결론/wake/board headline)이 쓰고, 노드는
             대시보드가 무엇이 실행됐나를 렌더한다. 2차 실패면 1차 종합으로 graceful
             degrade(canonical=s1)하되 실패 노드도 관측에 정직히 남긴다(silent 아님: warn).
             Refine(무조건)와 Conditional(Insufficient일 때만)이 공유한다 — 같은 변환을
             두 번 짜지 않는다(N-of-M 회피). *)
          let refine_over (s1, u1) =
            let single_node =
              Fusion_types.Synthesized
                { Fusion_types.role = Single; synthesis = s1; usage = u1 }
            in
            match
              Fusion_judge.run_refine ~sw ~net
                ~timeout_s:preset.Fusion_policy.judge_timeout_s
                ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
                ~judge_model:preset.Fusion_policy.judge
                ~question:req.Fusion_types.prompt ~panel ~prior:s1
                ~web_tools:judge_web_tools ~max_tool_calls:judge_max_tool_calls ()
            with
            | Ok (s2, u2) ->
              ( Ok (s2, Fusion_types.add_usage u1 u2)
              , [ single_node
                ; Fusion_types.Synthesized
                    { Fusion_types.role = Refine_pass; synthesis = s2; usage = u2 }
                ] )
            | Error (msg, u2) ->
              (* 2차 심판이 토큰을 태운 뒤 파싱 실패해도 그 usage(u2)를 버리지 않고
                 1차와 합산한다 — degrade가 비용을 undercount하지 않도록 (적대 리뷰
                 #22087 §1). 실패해도 실행 노드(Judge_failed)는 관측에 정직히 남긴다(RFC-0284). *)
              Log.Keeper.warn ~keeper_name:req.Fusion_types.keeper
                "fusion run %s refine judge failed, keeping first synthesis: %s"
                req.Fusion_types.run_id msg;
              ( Ok (s1, Fusion_types.add_usage u1 u2)
              , [ single_node
                ; Fusion_types.Judge_failed
                    { Fusion_types.failed_role = Refine_pass; error = msg; usage = u2 }
                ] )
          in
          (* JOJ(judge-of-judges, RFC-0283): N개 1차 심판이 같은 패널을 독립 종합 → meta가
             reconcile. preset.judges >= 2 필요(미구성/1개는 단일 심판 위상으로 표현 가능하므로
             런타임 에러 = fail-closed). 1차는 [Eio.Fiber.List.map ~max_fibers]로 병렬(패널
             fan-out과 동일 fault-isolation idiom — Fusion_judge.run이 per-judge 실패를 Error로
             격리하므로 한 심판 실패가 나머지를 안 죽인다). 성공 종합만 meta 입력, 전원 실패면
             첫 에러 전파. usage = 성공 1차 전부 + meta 합산. meta 실패 시 1차 첫 성공으로
             graceful degrade(RFC-0283 §5.1, warn) — meta가 태운 토큰(meta_u)도 합산해
             버리지 않는다(#22087 §1과 동일 원칙). 에러는 (string * usage) 동반: 토큰 소비 전
             구성 실패는 [zero_usage]를 싣는다. *)
          let run_judge_of_judges () =
            match preset.Fusion_policy.judges with
            | [] | [ _ ] ->
              ( Error
                  ( "judge_of_judges requires >= 2 judges configured in the preset \
                     ([[fusion.presets.<name>.judges]])"
                  , Fusion_types.zero_usage )
              , [] )
            | judges ->
              let firsts =
                Eio.Fiber.List.map
                  ~max_fibers:policy.Fusion_policy.max_concurrent_panels
                  (fun (j : Fusion_policy.judge_spec) ->
                    let id = Fusion_policy.panelist_id ~label:j.jlabel ~model:j.jmodel in
                    ( id
                    , Fusion_judge.run ~sw ~net ~timeout_s:j.jtimeout_s
                        ~judge_system_prompt:j.jsystem_prompt ~judge_model:j.jmodel
                        ~question:req.Fusion_types.prompt ~panel ~web_tools:j.jweb_tools
                        ~max_tool_calls:j.jmax_tool_calls () ))
                  judges
              in
              (* 실행된 1차 노드 관측 — 성공/실패 모두(ok_priors가 아닌 firsts 전체).
                 대시보드가 "N명 중 M명 실패"를 패널처럼 정직히 보이게 한다. *)
              let first_nodes =
                List.map
                  (fun (id, r) ->
                    match r with
                    | Ok (s, u) ->
                      Fusion_types.Synthesized
                        { Fusion_types.role = First id; synthesis = s; usage = u }
                    | Error (msg, u) ->
                      Fusion_types.Judge_failed
                        { Fusion_types.failed_role = First id; error = msg; usage = u })
                  firsts
              in
              let ok_priors =
                List.filter_map
                  (fun (id, r) ->
                    match r with Ok (s, u) -> Some (id, s, u) | Error _ -> None)
                  firsts
              in
              (match ok_priors with
               | [] ->
                 (* 전원 실패 — meta할 종합 없음. [all_fail_error]가 회계를 계산한다: 모든
                    1차 심판이 태운 토큰을 합산해 usage에 싣고(undercount 교정, 적대 리뷰
                    #22093 all-fail; ok_priors=[]이면 firsts는 전부 Error라 합산이 모든 실패
                    usage를 모은다), 첫 에러 메시지를 대표로 pick한다. 관측엔 1차 실패 노드만
                    남는다(meta 노드 없음, RFC-0284). observe(#22112)의 (Error err,
                    first_nodes) 관측 구조와 회계 축은 직교 — 헬퍼는 회계 축만 담당해 단위
                    테스트로 검증된다. *)
                 let err =
                   Fusion_types.all_fail_error
                     ~fallback:"judge_of_judges: no judge produced a synthesis"
                     firsts
                 in
                 (Error err, first_nodes)
               | (_, first_s, _) :: _ ->
                 let firsts_usage =
                   List.fold_left
                     (fun acc (_, _, u) -> Fusion_types.add_usage acc u)
                     Fusion_types.zero_usage ok_priors
                 in
                 let priors = List.map (fun (id, s, _) -> (id, s)) ok_priors in
                 (match
                    Fusion_judge.run_meta ~sw ~net
                      ~timeout_s:preset.Fusion_policy.judge_timeout_s
                      ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
                      ~judge_model:preset.Fusion_policy.judge
                      ~question:req.Fusion_types.prompt ~panel ~priors
                      ~web_tools:judge_web_tools ~max_tool_calls:judge_max_tool_calls ()
                  with
                  | Ok (meta_s, meta_u) ->
                    ( Ok (meta_s, Fusion_types.add_usage firsts_usage meta_u)
                    , first_nodes
                      @ [ Fusion_types.Synthesized
                            { Fusion_types.role = Meta; synthesis = meta_s; usage = meta_u }
                        ] )
                  | Error (msg, meta_u) ->
                    Log.Keeper.warn ~keeper_name:req.Fusion_types.keeper
                      "fusion run %s meta judge failed, keeping first judge \
                       synthesis: %s"
                      req.Fusion_types.run_id msg;
                    ( Ok (first_s, Fusion_types.add_usage firsts_usage meta_u)
                    , first_nodes
                      @ [ Fusion_types.Judge_failed
                            { Fusion_types.failed_role = Meta; error = msg; usage = meta_u }
                        ] )))
          in
          (* 위상별 reduce. Simple은 1차 종합 그대로(현행과 byte-identical — downstream
             judge/judge_usage/emit 동일). Refine는 무조건 refine. Conditional은 1차 판정이
             [Insufficient](애매)일 때만 refine, 그 외엔 1차 종합 그대로(= Simple). JOJ는 N개
             1차 심판 + meta. 1차 심판 실패는 단일-심판 위상에선 그대로 전파(refine할 종합이
             없음 = Simple과 동일 에러 의미). topology·decision 둘 다 닫힌 합 exhaustive match라
             새 변형 추가 시 컴파일 에러로 누락을 강제한다 — catch-all 없음. *)
          (* judge_full = canonical (downstream 종합/usage), judge_nodes = 실행 관측
             ([judge_outcome list], RFC-0284 → sink judges:[]). 각 arm이 둘을 hand-write한다
             — 콤비네이터/plan-tree 없음(닫힌 enum dispatch 유지, 추상 추출은 5번째 위상이
             강제할 때까지 defer). 단일-심판 노드는 [Single], 1차 심판 실패는 단일-심판
             위상에선 그대로 전파(Simple과 동일 에러 의미)하고 실패 노드 한 건만 남긴다. *)
          let judge_full, judge_nodes =
            match topology with
            | Fusion_types.Simple ->
              (match run_single_judge () with
               | Ok (s, u) ->
                 ( Ok (s, u)
                 , [ Fusion_types.Synthesized
                       { Fusion_types.role = Single; synthesis = s; usage = u }
                   ] )
               | Error ((msg, u) as e) ->
                 ( Error e
                 , [ Fusion_types.Judge_failed
                       { Fusion_types.failed_role = Single; error = msg; usage = u }
                   ] ))
            | Fusion_types.Refine ->
              (match run_single_judge () with
               | Error ((msg, u) as e) ->
                 ( Error e
                 , [ Fusion_types.Judge_failed
                       { Fusion_types.failed_role = Single; error = msg; usage = u }
                   ] )
               | Ok pair -> refine_over pair)
            | Fusion_types.Conditional ->
              (match run_single_judge () with
               | Error ((msg, u) as e) ->
                 ( Error e
                 , [ Fusion_types.Judge_failed
                       { Fusion_types.failed_role = Single; error = msg; usage = u }
                   ] )
               | Ok ((s1, u1) as pair) ->
                 if Fusion_types.decision_warrants_escalation s1.Fusion_types.decision
                 then refine_over pair
                 else
                   ( Ok (s1, u1)
                   , [ Fusion_types.Synthesized
                         { Fusion_types.role = Single; synthesis = s1; usage = u1 }
                     ] ))
            | Fusion_types.Judge_of_judges -> run_judge_of_judges ()
          in
          (* 심판 종합과 토큰 usage를 분리: outcome.judge는 synthesis만(소비자 호환),
             usage는 sink 비용 회계로(RFC §10 패널N+심판M). 심판 실패 시에도 소비한
             토큰은 회계한다(run_composed가 에러에 usage를 동반 — 응답 받은 뒤 실패면
             소비분, 그 전 실패면 zero). *)
          let judge = judge_full |> Result.map fst |> Result.map_error fst in
          let judge_usage =
            match judge_full with
            | Ok (_, u) -> u
            | Error (_, u) -> u
          in
          (match
             Fusion_sink.emit ~base_dir ~keeper:req.Fusion_types.keeper
               ~run_id:req.Fusion_types.run_id ~question:req.Fusion_types.prompt
               ~panel ~judge ~judges:judge_nodes ~judge_usage
           with
           | Ok () -> Completed { panel; judge }
           | Error msg -> Sink_failed msg))
