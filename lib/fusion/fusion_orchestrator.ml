(* Fusion — out-of-band 심의 오케스트레이터 (구현).
   계약/문서: fusion_orchestrator.mli, docs/rfc/RFC-0252 §4 *)

type outcome =
  | Denied of Fusion_types.deny_reason
  | Sink_failed of string
  | Completed of
      { panel : Fusion_types.panel_outcome list
      ; judge : (Fusion_types.judge_synthesis, Fusion_types.judge_failure) result
      }

let run ~sw ~net ~base_dir ~policy ~topology ~request () : outcome =
  match Fusion_policy.decide ~policy request with
  | Fusion_types.Deny reason ->
    Fusion_metrics.record_invocation ~topology `Denied;
    Denied reason
  | Fusion_types.Allow req ->
    (match Fusion_policy.find_preset policy req.Fusion_types.preset with
     | None ->
       Fusion_metrics.record_invocation ~topology `Denied;
       Denied (Fusion_types.Preset_unknown req.Fusion_types.preset)
     | Some vp ->
          let preset = Fusion_policy.Validated_preset.preset vp in
          let groups = preset.Fusion_policy.panels in
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
              ~outer_timeout_s:(Fusion_policy.panel_outer_timeout_of groups)
              ~groups:effective_groups ~prompt:req.Fusion_types.prompt ()
          in
          let judge_web_tools =
            Fusion_policy.judge_web_tools_of ~req_web_tools:req.Fusion_types.web_tools
              groups
          in
          let run_single_judge () =
            Fusion_judge.run ~sw ~net
              ~timeout_s:preset.Fusion_policy.judge_timeout_s
              ?max_tokens:preset.Fusion_policy.judge_max_output_tokens
              ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
              ~judge_model:preset.Fusion_policy.judge
              ~question:req.Fusion_types.prompt ~panel ~web_tools:judge_web_tools ()
          in
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
                ~web_tools:judge_web_tools ()
            with
            | Ok (s2, u2) ->
              ( Ok (s2, Fusion_types.add_usage u1 u2)
              , [ single_node
                ; Fusion_types.Synthesized
                    { Fusion_types.role = Refine_pass; synthesis = s2; usage = u2 }
                ] )
            | Error (failure, u2) ->
              Log.Keeper.warn ~keeper_name:req.Fusion_types.keeper
                "fusion run %s refine judge failed, keeping first synthesis: %s"
                req.Fusion_types.run_id
                (Fusion_types.judge_failure_text failure);
              ( Ok (s1, Fusion_types.add_usage u1 u2)
              , [ single_node
                ; Fusion_types.Judge_failed
                    { Fusion_types.failed_role = Refine_pass
                    ; failure
                    ; usage = u2
                    ; elapsed_s = 0.0
                    }
                ] )
          in
          let clock = Fusion_orchestrator_judge_wave.make_runtime_clock () in
          let elapsed_since_t0 () =
            Fusion_orchestrator_judge_wave.elapsed_since_t0 clock
          in
          let run_first_judges judges =
            Fusion_orchestrator_judge_wave.run_first_judges
              ~sw
              ~net
              ~preset
              ~panel
              ~question:req.Fusion_types.prompt
              ~clock
              ~judge_web_tools
              judges
          in
          let first_judge_nodes =
            Fusion_orchestrator_judge_wave.first_judge_nodes
          in
          let successful_syntheses =
            Fusion_orchestrator_judge_wave.successful_syntheses
          in
          let successful_pair_syntheses =
            Fusion_orchestrator_judge_wave.successful_pair_syntheses
          in
          let firsts_usage = Fusion_orchestrator_judge_wave.firsts_usage in
          let all_fail_error_of_runs =
            Fusion_orchestrator_judge_wave.all_fail_error_of_runs
          in
          let with_timeout_budget_fallback =
            Fusion_orchestrator_judge_wave.with_timeout_budget_fallback
          in
          let run_fallback_judge () =
            Fusion_orchestrator_judge_wave.run_fallback_judge
              ~sw
              ~net
              ~preset
              ~panel
              ~question:req.Fusion_types.prompt
              ~clock
              ~judge_web_tools
              ()
          in
          let run_judge_of_judges () =
            match preset.Fusion_policy.judges with
            | [] | [ _ ] ->
              ( Error
                  ( Fusion_types.Internal_error
                      "judge_of_judges requires >= 2 judges configured in the preset ([[fusion.presets.<name>.judges]])"
                  , Fusion_types.zero_usage )
              , [] )
            | judges ->
              let firsts = run_first_judges judges in
              let firsts_with_fallback =
                with_timeout_budget_fallback ~run_fallback_judge firsts
              in
              let first_nodes = first_judge_nodes firsts_with_fallback in
              let ok_priors = successful_syntheses firsts_with_fallback in
              (match ok_priors with
               | [] ->
                 let err =
                   all_fail_error_of_runs
                     ~fallback:
                       (Fusion_types.Internal_error "judge_of_judges: no judge produced a synthesis")
                     firsts_with_fallback
                 in
                 (Error err, first_nodes)
               | (_, first_s, _) :: _ ->
                 let firsts_usage = firsts_usage firsts_with_fallback in
                 let priors = List.map (fun (id, s, _) -> (id, s)) ok_priors in
                 (match
                       Fusion_judge.run_meta ~sw ~net
                         ~timeout_s:preset.Fusion_policy.meta_timeout_s
                         ?max_tokens:preset.Fusion_policy.judge_max_output_tokens
                         ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
                         ~judge_model:preset.Fusion_policy.judge
                         ~question:req.Fusion_types.prompt ~panel ~priors
                         ~web_tools:judge_web_tools ()
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
                     | Error (failure, meta_u) ->
                       Log.Keeper.warn ~keeper_name:req.Fusion_types.keeper
                         "fusion run %s meta judge failed, keeping first judge \
                          synthesis: %s"
                         req.Fusion_types.run_id
                         (Fusion_types.judge_failure_text failure);
                       let elapsed_s = elapsed_since_t0 () in
                       ( Ok (first_s, Fusion_types.add_usage firsts_usage meta_u)
                       , first_nodes
                         @ [ Fusion_types.Judge_failed
                               { Fusion_types.failed_role = Meta
                               ; failure
                               ; usage = meta_u
                               ; elapsed_s
                               }
                           ] )))
          in
          let run_staged_judge_of_judges () =
            let group_size = policy.Fusion_policy.staged_judge_group_size in
            match
              Fusion_policy.staged_judge_groups ~group_size preset.Fusion_policy.judges
            with
            | Error e ->
              ( Error
                  ( Fusion_types.Internal_error (Fusion_policy.staged_judge_group_error_message e)
                  , Fusion_types.zero_usage )
              , [] )
            | Ok _groups ->
              let firsts =
                run_first_judges preset.Fusion_policy.judges
                |> with_timeout_budget_fallback ~run_fallback_judge
              in
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
                        (Fusion_types.Internal_error
                           (Printf.sprintf
                              "staged_judge_of_judges %s: no judge produced a synthesis"
                              stage_id))
                      stage_firsts
                  in
                  ((stage_id, Error err), first_nodes)
                | (_, first_s, _) :: _ ->
                  let firsts_usage = firsts_usage stage_firsts in
                  let priors = List.map (fun (id, s, _) -> (id, s)) ok_priors in
                  (match
                        Fusion_judge.run_meta ~sw ~net
                          ~timeout_s:preset.Fusion_policy.meta_timeout_s
                          ?max_tokens:preset.Fusion_policy.judge_max_output_tokens
                          ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
                          ~judge_model:preset.Fusion_policy.judge
                          ~question:req.Fusion_types.prompt ~panel ~priors
                          ~web_tools:judge_web_tools ()
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
                      | Error (failure, stage_u) ->
                        Log.Keeper.warn ~keeper_name:req.Fusion_types.keeper
                          "fusion run %s staged JOJ %s meta judge failed, keeping first judge synthesis: %s"
                          req.Fusion_types.run_id stage_id
                          (Fusion_types.judge_failure_text failure);
                        let elapsed_s = elapsed_since_t0 () in
                        ( ( stage_id
                          , Ok (first_s, Fusion_types.add_usage firsts_usage stage_u) )
                        , first_nodes
                          @ [ Fusion_types.Judge_failed
                                { Fusion_types.failed_role = Stage_meta stage_num
                                ; failure
                                ; usage = stage_u
                                ; elapsed_s
                                }
                            ] ))
              in
              let indexed_groups = List.mapi (fun i group -> (i + 1, group)) first_groups in
              let stage_runs =
                Eio.Fiber.List.map
                  ~max_fibers:(max 1 (List.length indexed_groups))
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
                       (Fusion_types.Internal_error "staged_judge_of_judges: no stage produced a synthesis")
                     stage_results
                 in
                 (Error err, stage_nodes)
               | (_, first_stage_s, _) :: _ ->
                 let stage_usage = Fusion_types.sum_all_usage stage_results in
                 let priors = List.map (fun (id, s, _) -> (id, s)) ok_stages in
                 (match
                       Fusion_judge.run_meta ~sw ~net
                         ~timeout_s:preset.Fusion_policy.meta_timeout_s
                         ?max_tokens:preset.Fusion_policy.judge_max_output_tokens
                         ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
                         ~judge_model:preset.Fusion_policy.judge
                         ~question:req.Fusion_types.prompt ~panel ~priors
                         ~web_tools:judge_web_tools ()
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
                     | Error (failure, final_u) ->
                       Log.Keeper.warn ~keeper_name:req.Fusion_types.keeper
                         "fusion run %s staged JOJ final meta judge failed, keeping first stage synthesis: %s"
                         req.Fusion_types.run_id
                         (Fusion_types.judge_failure_text failure);
                       let elapsed_s = elapsed_since_t0 () in
                       ( Ok (first_stage_s, Fusion_types.add_usage stage_usage final_u)
                       , stage_nodes
                         @ [ Fusion_types.Judge_failed
                               { Fusion_types.failed_role = Final_meta
                               ; failure
                               ; usage = final_u
                               ; elapsed_s
                               }
                           ] )))
          in
          let judge_full, judge_nodes =
            match Fusion_types.answered_of panel with
            | [] ->
              let reason = Fusion_types.No_panel_answers { total = List.length panel } in
              (* typed 그대로 propagate — 문자열로 렌더해 [Internal_error]에 압축하면
                 패널 전멸이 "judge failed"/failure_code=internal_error로 오귀속된다
                 (2026-07-01 사고: 8 run 전부 이 경로였는데 keeper 표면은 judge
                 메커니즘 고장으로 보고했다). 렌더는 sink/텍스트 경계에서 한다. *)
              (Error (Fusion_types.Panels_unavailable reason, Fusion_types.zero_usage), [])
            | _ :: _ ->
            match topology with
            | Fusion_types.Simple ->
              (match run_single_judge () with
               | Ok (s, u) ->
                 ( Ok (s, u)
                 , [ Fusion_types.Synthesized
                       { Fusion_types.role = Single; synthesis = s; usage = u }
                   ] )
               | Error ((failure, u) as e) ->
                 ( Error e
                 , [ Fusion_types.Judge_failed
                       { Fusion_types.failed_role = Single
                       ; failure
                       ; usage = u
                       ; elapsed_s = 0.0
                       }
                   ] ))
            | Fusion_types.Refine ->
              (match run_single_judge () with
               | Error ((failure, u) as e) ->
                 ( Error e
                 , [ Fusion_types.Judge_failed
                       { Fusion_types.failed_role = Single
                       ; failure
                       ; usage = u
                       ; elapsed_s = 0.0
                       }
                   ] )
               | Ok pair -> refine_over pair)
            | Fusion_types.Conditional ->
              (match run_single_judge () with
               | Error ((failure, u) as e) ->
                 ( Error e
                 , [ Fusion_types.Judge_failed
                       { Fusion_types.failed_role = Single
                       ; failure
                       ; usage = u
                       ; elapsed_s = 0.0
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
          let judge = judge_full |> Result.map fst |> Result.map_error fst in
          let judge_usage =
            match judge_full with
            | Ok (_, u) -> u
            | Error (_, u) -> u
          in
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
