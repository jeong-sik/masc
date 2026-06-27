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
  | Fusion_types.Deny reason ->
    Fusion_metrics.record_invocation ~topology `Denied;
    Denied reason
  | Fusion_types.Allow req ->
    (match Fusion_policy.find_preset policy req.Fusion_types.preset with
     | None ->
       (* 게이트가 preset 존재를 이미 검증했으므로 도달 불가. 방어적으로 Denied. *)
       Fusion_metrics.record_invocation ~topology `Denied;
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
              ?max_tokens:preset.Fusion_policy.judge_max_output_tokens
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
                ?max_tokens:preset.Fusion_policy.judge_max_output_tokens
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
              Log.Keeper.warn ~keeper_name:req.Fusion_types.keeper
                "fusion run %s refine judge failed, keeping first synthesis: %s"
                req.Fusion_types.run_id msg;
              ( Ok (s1, Fusion_types.add_usage u1 u2)
              , [ single_node
                ; Fusion_types.Judge_failed
                    { Fusion_types.failed_role = Refine_pass
                    ; error = msg
                    ; usage = u2
                    ; elapsed_s = 0.0
                    ; timed_out = false
                    }
                ] )
          in
          (* Adaptive timeout: wave-wide wall-clock budget and per-judge extension.
             We snapshot t0 before the first-judge wave; each fiber reads the clock
             just before/after its judge call.  Masc_eio_env.clock is optional; tests
             and stdio callers may initialise without one, so we fall back to
             Unix.gettimeofday rather than fail closed. NDT-OK: the wall clock only
             sizes runtime timeout windows for external judge calls. *)
          let env = Masc_eio_env.get () in
          let now () =
            match env.clock with
            | Some c -> Eio.Time.now c
            | None ->
              (* NDT-OK: boundary fallback when no Eio clock is installed. *)
              Unix.gettimeofday ()
          in
          let t0 = now () in
          let str_contains ~needle haystack =
            let nl = String.length needle and hl = String.length haystack in
            if nl = 0
            then true
            else
              let rec scan i =
                if i + nl > hl
                then false
                else if String.equal (String.sub haystack i nl) needle
                then true
                else scan (i + 1)
              in
              scan 0
          in
          let is_timeout_error msg =
            str_contains ~needle:"Execution timed out after" msg
          in
          let is_budget_error msg =
            str_contains ~needle:"wave budget" msg
          in
          let is_timeout_or_budget_error msg =
            is_timeout_error msg || is_budget_error msg
          in
          (* first_judge_run is a tuple (judge_spec, id, result, elapsed_s, timed_out).
             We use a tuple because OCaml does not allow [type] definitions inside
             a [let ... in] expression. *)
          let run_first_judge ~already_timed_out (j : Fusion_policy.judge_spec)
            : Fusion_policy.judge_spec
              * string
              * ( Fusion_types.judge_synthesis * Fusion_types.usage
                , string * Fusion_types.usage )
                result
              * float
              * bool
            =
            let id = Fusion_policy.panelist_id ~label:j.jlabel ~model:j.jmodel in
            let elapsed_s = now () -. t0 in
            match
              Fusion_policy.adjust_judge_timeout
                ~base_s:j.jtimeout_s
                ~max_s:j.jmax_timeout_s
                ~factor:preset.Fusion_policy.adaptive_timeout_factor
                ~wave_budget_s:preset.Fusion_policy.judge_wave_budget_s
                ~elapsed_s
                ~already_timed_out
            with
            | None ->
              let msg =
                if already_timed_out
                then
                  Printf.sprintf
                    "adaptive timeout recovery for judge %s exceeded wave budget" id
                else
                  Printf.sprintf
                    "judge %s skipped: would exceed wave budget (elapsed %.3f, budget %.3f)"
                    id
                    elapsed_s
                    preset.Fusion_policy.judge_wave_budget_s
              in
              (j, id, Error (msg, Fusion_types.zero_usage), elapsed_s, false)
            | Some timeout_s ->
              let result =
                Fusion_judge.run ~sw ~net ~timeout_s
                  ?max_tokens:j.jmax_output_tokens
                  ~judge_system_prompt:j.jsystem_prompt ~judge_model:j.jmodel
                  ~question:req.Fusion_types.prompt ~panel ~web_tools:j.jweb_tools
                  ~max_tool_calls:j.jmax_tool_calls ()
              in
              let elapsed_s = now () -. t0 in
              let timed_out =
                match result with
                | Error (msg, _) -> is_timeout_error msg
                | Ok _ -> false
              in
              (j, id, result, elapsed_s, timed_out)
          in
          let run_first_judges judges  =
            let first_pass =
              Eio.Fiber.List.map
                ~max_fibers:policy.Fusion_policy.max_concurrent_judges
                (run_first_judge ~already_timed_out:false)
                judges
            in
            if preset.Fusion_policy.adaptive_timeout_factor = 1.0
            then first_pass
            else
              Eio.Fiber.List.map
                ~max_fibers:policy.Fusion_policy.max_concurrent_judges
                (fun ((j, _, _, _, timed_out) as run) ->
                   if timed_out
                   then (
                     Fusion_metrics.record_adaptive_timeout ();
                     run_first_judge ~already_timed_out:true j)
                   else run)
                first_pass
          in
          let first_judge_nodes runs =
            List.map
              (fun (_, id, result, elapsed_s, timed_out) ->
                 match result with
                 | Ok (s, u) ->
                   Fusion_types.Synthesized
                     { Fusion_types.role = First id; synthesis = s; usage = u }
                 | Error (msg, u) ->
                   Fusion_types.Judge_failed
                     { Fusion_types.failed_role = First id
                     ; error = msg
                     ; usage = u
                     ; elapsed_s
                     ; timed_out
                     })
              runs
          in
          let successful_syntheses runs =
            List.filter_map
              (fun (_, id, result, _, _) ->
                 match result with
                 | Ok (s, u) -> Some (id, s, u)
                 | Error _ -> None)
              runs
          in
          let successful_pair_syntheses pairs =
            List.filter_map
              (fun (id, r) ->
                 match r with Ok (s, u) -> Some (id, s, u) | Error _ -> None)
              pairs
          in
          let firsts_usage runs =
            Fusion_types.sum_all_usage
              (List.map (fun (_, id, result, _, _) -> (id, result)) runs)
          in
          let all_fail_error_of_runs ~fallback runs =
            Fusion_types.all_fail_error
              ~fallback
              (List.map (fun (_, id, result, _, _) -> (id, result)) runs)
          in
          let remaining_wave_budget () =
            preset.Fusion_policy.judge_wave_budget_s -. (now () -. t0)
          in
          let meta_budget_check () =
            let remaining = remaining_wave_budget () in
            if remaining < preset.Fusion_policy.meta_timeout_s
            then Error ("insufficient remaining budget for meta", Fusion_types.zero_usage)
            else Ok preset.Fusion_policy.meta_timeout_s
          in
          let run_fallback_judge ()  =
            match preset.Fusion_policy.fallback_judge_model with
            | None -> None
            | Some model ->
              let elapsed_s = now () -. t0 in
              let j : Fusion_policy.judge_spec =
                { jmodel = model
                ; jlabel = "fallback"
                ; jsystem_prompt = preset.Fusion_policy.judge_system_prompt
                ; jweb_tools = judge_web_tools
                ; jmax_tool_calls = judge_max_tool_calls
                ; jmax_output_tokens = preset.Fusion_policy.judge_max_output_tokens
                ; jtimeout_s = preset.Fusion_policy.judge_timeout_s
                ; jmax_timeout_s = None
                }
              in
              let id = Fusion_policy.panelist_id ~label:j.jlabel ~model:j.jmodel in
              (match
                 Fusion_policy.adjust_judge_timeout
                   ~base_s:j.jtimeout_s
                   ~max_s:None
                   ~factor:1.0
                   ~wave_budget_s:preset.Fusion_policy.judge_wave_budget_s
                   ~elapsed_s
                   ~already_timed_out:false
               with
               | None ->
                 Some
                   ( j
                   , id
                   , Error
                       ( "fallback judge skipped: insufficient remaining wave budget"
                       , Fusion_types.zero_usage )
                   , elapsed_s
                   , false )
               | Some timeout_s ->
                 let result =
                   Fusion_judge.run ~sw ~net ~timeout_s
                     ?max_tokens:j.jmax_output_tokens
                     ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
                     ~judge_model:model
                     ~question:req.Fusion_types.prompt ~panel ~web_tools:judge_web_tools
                     ~max_tool_calls:judge_max_tool_calls ()
                 in
                 let elapsed_s = now () -. t0 in
                 let timed_out =
                   match result with
                   | Error (msg, _) -> is_timeout_error msg
                   | Ok _ -> false
                 in
                 Some (j, id, result, elapsed_s, timed_out))
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
                  ( "judge_of_judges requires >= 2 judges configured in the preset                      ([[fusion.presets.<name>.judges]])"
                  , Fusion_types.zero_usage )
              , [] )
            | judges ->
              let firsts = run_first_judges judges in
              let ok_priors = successful_syntheses firsts in
              let firsts_with_fallback =
                match ok_priors with
                | _ :: _ -> firsts
                | [] ->
                  (* 전원 실패 시 모든 에러가 타임아웃/예산 에러면 fallback 심판을 한 번
                     시도한다. *)
                  if
                    List.for_all
                      (fun (_, _, result, _, _) ->
                         match result with
                         | Error (msg, _) -> is_timeout_or_budget_error msg
                         | Ok _ -> false)
                      firsts
                  then
                    (match run_fallback_judge () with
                     | Some fb -> firsts @ [ fb ]
                     | None -> firsts)
                  else firsts
              in
              let first_nodes = first_judge_nodes firsts_with_fallback in
              let ok_priors = successful_syntheses firsts_with_fallback in
              (match ok_priors with
               | [] ->
                 let err =
                   all_fail_error_of_runs
                     ~fallback:"judge_of_judges: no judge produced a synthesis"
                     firsts_with_fallback
                 in
                 (Error err, first_nodes)
               | (_, first_s, _) :: _ ->
                 let firsts_usage = firsts_usage firsts_with_fallback in
                 (match meta_budget_check () with
                  | Error (msg, _) ->
                    let elapsed_s = now () -. t0 in
                    ( Ok (first_s, firsts_usage)
                    , first_nodes
                      @ [ Fusion_types.Judge_failed
                            { Fusion_types.failed_role = Meta
                            ; error = msg
                            ; usage = Fusion_types.zero_usage
                            ; elapsed_s
                            ; timed_out = false
                            }
                        ] )
                  | Ok meta_timeout_s ->
                    let priors = List.map (fun (id, s, _) -> (id, s)) ok_priors in
                     (match
                       Fusion_judge.run_meta ~sw ~net
                         ~timeout_s:meta_timeout_s
                         ?max_tokens:preset.Fusion_policy.judge_max_output_tokens
                         ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
                         ~judge_model:preset.Fusion_policy.judge
                         ~question:req.Fusion_types.prompt ~panel ~priors
                         ~web_tools:judge_web_tools ~max_tool_calls:judge_max_tool_calls ()
                     with
                     | Ok (meta_s, meta_u) ->
                       ( Ok (meta_s, Fusion_types.add_usage firsts_usage meta_u)
                       , first_nodes
                         @ [ Fusion_types.Synthesized
                               { Fusion_types.role = Meta
                               ; synthesis = meta_s
                               ; usage = meta_u
                               }
                           ] )
                     | Error (msg, meta_u) ->
                       Log.Keeper.warn ~keeper_name:req.Fusion_types.keeper
                         "fusion run %s meta judge failed, keeping first judge                           synthesis: %s"
                         req.Fusion_types.run_id msg;
                       let elapsed_s = now () -. t0 in
                       let timed_out = is_timeout_error msg in
                       ( Ok (first_s, Fusion_types.add_usage firsts_usage meta_u)
                       , first_nodes
                         @ [ Fusion_types.Judge_failed
                               { Fusion_types.failed_role = Meta
                               ; error = msg
                               ; usage = meta_u
                               ; elapsed_s
                               ; timed_out
                               }
                           ] ))))
          in
          let run_staged_judge_of_judges () =
            let group_size = policy.Fusion_policy.staged_judge_group_size in
            match
              Fusion_policy.staged_judge_groups ~group_size preset.Fusion_policy.judges
            with
            | Error e ->
              ( Error
                  ( Fusion_policy.staged_judge_group_error_message e
                  , Fusion_types.zero_usage )
              , [] )
            | Ok _groups ->
              let firsts = run_first_judges preset.Fusion_policy.judges in
              let rec take n acc rest =
                if n = 0
                then (List.rev acc, rest)
                else
                  match rest with
                  | [] -> (List.rev acc, [])
                  | x :: xs -> take (n - 1) (x :: acc) xs
              in
              let rec chunk_firsts acc rest =
                match rest with
                | [] -> List.rev acc
                | _ ->
                  let group, rest = take group_size [] rest in
                  chunk_firsts (group :: acc) rest
              in
              let first_groups = chunk_firsts [] firsts in
              let run_stage_meta (stage_num, stage_firsts) =
                let stage_id = Printf.sprintf "stage-%d" stage_num in
                let first_nodes = first_judge_nodes stage_firsts in
                let ok_priors = successful_syntheses stage_firsts in
                match ok_priors with
                | [] ->
                  let err =
                    all_fail_error_of_runs
                      ~fallback:
                        (Printf.sprintf
                           "staged_judge_of_judges %s: no judge produced a synthesis"
                           stage_id)
                      stage_firsts
                  in
                  ((stage_id, Error err), first_nodes)
                | (_, first_s, _) :: _ ->
                  let firsts_usage = firsts_usage stage_firsts in
                  let priors = List.map (fun (id, s, _) -> (id, s)) ok_priors in
                  (match meta_budget_check () with
                   | Error (msg, _) ->
                     let elapsed_s = now () -. t0 in
                     ( (stage_id, Ok (first_s, firsts_usage))
                     , first_nodes
                       @ [ Fusion_types.Judge_failed
                             { Fusion_types.failed_role = Stage_meta stage_num
                             ; error = msg
                             ; usage = Fusion_types.zero_usage
                             ; elapsed_s
                             ; timed_out = false
                             }
                         ] )
                   | Ok meta_timeout_s ->
                     (match
                        Fusion_judge.run_meta ~sw ~net
                          ~timeout_s:meta_timeout_s
                          ?max_tokens:preset.Fusion_policy.judge_max_output_tokens
                          ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
                          ~judge_model:preset.Fusion_policy.judge
                          ~question:req.Fusion_types.prompt ~panel ~priors
                          ~web_tools:judge_web_tools ~max_tool_calls:judge_max_tool_calls ()
                      with
                      | Ok (stage_s, stage_u) ->
                        ( ( stage_id
                          , Ok (stage_s, Fusion_types.add_usage firsts_usage stage_u) )
                        , first_nodes
                          @ [ Fusion_types.Synthesized
                                { Fusion_types.role = Stage_meta stage_num
                                ; synthesis = stage_s
                                ; usage = stage_u
                                }
                            ] )
                      | Error (msg, stage_u) ->
                        Log.Keeper.warn ~keeper_name:req.Fusion_types.keeper
                          "fusion run %s staged JOJ %s meta judge failed, keeping first                            judge synthesis: %s"
                          req.Fusion_types.run_id stage_id msg;
                        let elapsed_s = now () -. t0 in
                        let timed_out = is_timeout_error msg in
                        ( ( stage_id
                          , Ok (first_s, Fusion_types.add_usage firsts_usage stage_u) )
                        , first_nodes
                          @ [ Fusion_types.Judge_failed
                                { Fusion_types.failed_role = Stage_meta stage_num
                                ; error = msg
                                ; usage = stage_u
                                ; elapsed_s
                                ; timed_out
                                }
                            ] )))
              in
              let indexed_groups = List.mapi (fun i group -> (i + 1, group)) first_groups in
              let stage_runs =
                Eio.Fiber.List.map
                  ~max_fibers:policy.Fusion_policy.max_concurrent_judges
                  run_stage_meta indexed_groups
              in
              let stage_results = List.map fst stage_runs in
              let stage_nodes = List.concat_map snd stage_runs in
              let ok_stages = successful_pair_syntheses stage_results in
              (match ok_stages with
               | [] ->
                 let err =
                   Fusion_types.all_fail_error
                     ~fallback:
                       "staged_judge_of_judges: no stage produced a synthesis"
                     stage_results
                 in
                 (Error err, stage_nodes)
               | (_, first_stage_s, _) :: _ ->
                 let stage_usage = Fusion_types.sum_all_usage stage_results in
                 let priors = List.map (fun (id, s, _) -> (id, s)) ok_stages in
                 (match meta_budget_check () with
                  | Error (msg, _) ->
                    let elapsed_s = now () -. t0 in
                    ( Ok (first_stage_s, stage_usage)
                    , stage_nodes
                      @ [ Fusion_types.Judge_failed
                            { Fusion_types.failed_role = Final_meta
                            ; error = msg
                            ; usage = Fusion_types.zero_usage
                            ; elapsed_s
                            ; timed_out = false
                            }
                        ] )
                  | Ok meta_timeout_s ->
                    (match
                       Fusion_judge.run_meta ~sw ~net
                         ~timeout_s:meta_timeout_s
                         ?max_tokens:preset.Fusion_policy.judge_max_output_tokens
                         ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
                         ~judge_model:preset.Fusion_policy.judge
                         ~question:req.Fusion_types.prompt ~panel ~priors
                         ~web_tools:judge_web_tools ~max_tool_calls:judge_max_tool_calls ()
                     with
                     | Ok (final_s, final_u) ->
                       ( Ok (final_s, Fusion_types.add_usage stage_usage final_u)
                       , stage_nodes
                         @ [ Fusion_types.Synthesized
                               { Fusion_types.role = Final_meta
                               ; synthesis = final_s
                               ; usage = final_u
                               }
                           ] )
                     | Error (msg, final_u) ->
                       Log.Keeper.warn ~keeper_name:req.Fusion_types.keeper
                         "fusion run %s staged JOJ final meta judge failed, keeping first                           stage synthesis: %s"
                         req.Fusion_types.run_id msg;
                       let elapsed_s = now () -. t0 in
                       let timed_out = is_timeout_error msg in
                       ( Ok (first_stage_s, Fusion_types.add_usage stage_usage final_u)
                       , stage_nodes
                         @ [ Fusion_types.Judge_failed
                               { Fusion_types.failed_role = Final_meta
                               ; error = msg
                               ; usage = final_u
                               ; elapsed_s
                               ; timed_out
                               }
                           ] ))))
          in
          (* 위상별 reduce. Simple은 1차 종합 그대로(현행과 byte-identical — downstream
             judge/judge_usage/emit 동일). Refine는 무조건 refine. Conditional은 1차 판정이
             [Insufficient](애매)일 때만 refine, 그 외엔 1차 종합 그대로(= Simple). JOJ는 N개
             1차 심판 + meta. 1차 심판 실패는 단일-심판 위상에선 그대로 전파(refine할 종합이
             없음 = Simple과 동일 에러 의미). topology·decision 둘 다 닫힌 합 exhaustive match라
             새 변형 추가 시 컴파일 에러로 누락을 강제한다 — catch-all 없음. *)
          (* judge_full = canonical (downstream 종합/usage), judge_nodes = 실행 관측
             ([judge_outcome list], RFC-0284 → sink judges:[]). 각 arm이 둘을 hand-write한다
             — 콤비네이터/plan-tree 없음(닫힌 enum dispatch 유지, staged JOJ도 named arm +
             작은 helper로 표현). 단일-심판 노드는 [Single], 1차 심판 실패는 단일-심판
             위상에선 그대로 전파(Simple과 동일 에러 의미)하고 실패 노드 한 건만 남긴다. *)
          let judge_full, judge_nodes =
            match
              Fusion_types.judge_skip_reason
                ~min_answered:preset.Fusion_policy.min_answered panel
            with
            | Some reason ->
              (* Quorum-not-met — 종합할 답이 preset 기준보다 적다. judge를 얇거나 빈
                 <panel_answers>로 호출하면 근거 부족 종합을 정상처럼 표출한다. judge
                 미실행 + 명시적 실패로 완료한다(기존 judge-error 표시 경로 재사용).
                 judge_nodes=[] — 실행된 심판 없음(RFC-0284). *)
              let reason = Fusion_types.render_skip_reason reason in
              (Error (reason, Fusion_types.zero_usage), [])
            | None ->
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
                       { Fusion_types.failed_role = Single
                       ; error = msg
                       ; usage = u
                       ; elapsed_s = 0.0
                       ; timed_out = false
                       }
                   ] ))
            | Fusion_types.Refine ->
              (match run_single_judge () with
               | Error ((msg, u) as e) ->
                 ( Error e
                 , [ Fusion_types.Judge_failed
                       { Fusion_types.failed_role = Single
                       ; error = msg
                       ; usage = u
                       ; elapsed_s = 0.0
                       ; timed_out = false
                       }
                   ] )
               | Ok pair -> refine_over pair)
            | Fusion_types.Conditional ->
              (match run_single_judge () with
               | Error ((msg, u) as e) ->
                 ( Error e
                 , [ Fusion_types.Judge_failed
                       { Fusion_types.failed_role = Single
                       ; error = msg
                       ; usage = u
                       ; elapsed_s = 0.0
                       ; timed_out = false
                       }
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
            | Fusion_types.Staged_judge_of_judges -> run_staged_judge_of_judges ()
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
          (* RFC-0284 observation record → OTel counters. *)
          List.iter (Fusion_metrics.record_judge_execution ~topology) judge_nodes;
          (match
             Fusion_sink.emit ~base_dir ~keeper:req.Fusion_types.keeper
               ~run_id:req.Fusion_types.run_id ~question:req.Fusion_types.prompt
               ~panel ~judge ~judges:judge_nodes ~judge_usage
           with
           | Ok () ->
             Fusion_metrics.record_invocation ~topology `Completed;
             Completed { panel; judge }
           | Error msg ->
             Fusion_metrics.record_invocation ~topology `Sink_failed;
             Sink_failed msg))
