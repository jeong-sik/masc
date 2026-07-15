type judge_run =
  Fusion_policy.judge_spec
  * string
  * ( Fusion_types.judge_synthesis * Fusion_types.usage
    , Fusion_types.judge_failure * Fusion_types.usage )
    result
  * float
  * bool

type clock =
  { now_opt : unit -> float option
  ; t0 : float option
  ; missing_clock_failure : Fusion_types.judge_failure
  }

let make_clock ~now_opt ~missing_clock_failure =
  let t0 = now_opt () in
  { now_opt; t0; missing_clock_failure }
;;

let make_runtime_clock ~missing_clock_failure =
  let now_opt () =
    match Masc_eio_env.get_opt () with
    | Some { Masc_eio_env.clock; _ } -> Some (Eio.Time.now clock)
    | None -> None
  in
  make_clock ~now_opt ~missing_clock_failure
;;

let elapsed_since_t0 clock =
  match clock.now_opt (), clock.t0 with
  | Some now, Some t0 -> now -. t0
  | _ -> 0.0
;;

let missing_clock_result clock =
  Error (clock.missing_clock_failure, Fusion_types.zero_usage)
;;

let clock_available clock = Option.is_some (clock.now_opt ())

let run_first_judge
      ~sw
      ~net
      ~preset
      ~panel
      ~question
      ~clock
      ~judge_web_tools
      ~judge_max_tool_calls
      ~already_timed_out
      (j : Fusion_policy.judge_spec)
  : judge_run
  =
  let id = Fusion_policy.panelist_id ~label:j.jlabel ~model:j.jmodel in
  let _ = preset, judge_web_tools, judge_max_tool_calls, already_timed_out in
  let result =
    Fusion_judge.run
      ~sw
      ~net
      ~timeout_s:j.jtimeout_s
      ~judge_system_prompt:j.jsystem_prompt
      ~judge_model:j.jmodel
      ~question
      ~panel
      ~web_tools:j.jweb_tools
      ()
  in
  let elapsed_s = elapsed_since_t0 clock in
  let timed_out =
    match result with
    | Error (f, _) -> Fusion_types.judge_failure_is_timeout f
    | Ok _ -> false
  in
  j, id, result, elapsed_s, timed_out
;;

let run_first_judges
      ~sw
      ~net
      ~max_concurrent_judges
      ~preset
      ~panel
      ~question
      ~clock
      ~judge_web_tools
      ~judge_max_tool_calls
      judges
  =
  let run_first_judge =
    run_first_judge
      ~sw
      ~net
      ~preset
      ~panel
      ~question
      ~clock
      ~judge_web_tools
      ~judge_max_tool_calls
  in
  let _ = max_concurrent_judges in
  Eio.Fiber.List.map
    ~max_fibers:(max 1 (List.length judges))
    (run_first_judge ~already_timed_out:false)
    judges
;;

let first_judge_nodes runs =
  List.map
    (fun (_, id, result, elapsed_s, _timed_out) ->
       match result with
       | Ok (s, u) ->
         Fusion_types.Synthesized { Fusion_types.role = First id; synthesis = s; usage = u }
       | Error (failure, u) ->
         Fusion_types.Judge_failed
           { Fusion_types.failed_role = First id; failure; usage = u; elapsed_s })
    runs
;;

let successful_syntheses runs =
  List.filter_map
    (fun (_, id, result, _, _) ->
       match result with
       | Ok (s, u) -> Some (id, s, u)
       | Error _ -> None)
    runs
;;

let successful_pair_syntheses pairs =
  List.filter_map
    (fun (id, r) ->
       match r with
       | Ok (s, u) -> Some (id, s, u)
       | Error _ -> None)
    pairs
;;

let firsts_usage runs =
  Fusion_types.sum_all_usage (List.map (fun (_, id, result, _, _) -> id, result) runs)
;;

let all_fail_error_of_runs ~fallback runs =
  Fusion_types.all_fail_error
    ~fallback
    (List.map (fun (_, id, result, _, _) -> id, result) runs)
;;

let failed_timeout_or_budget (_, _, result, _, _) =
  match result with
  | Error (failure, _) -> Fusion_types.judge_failure_is_timeout_or_budget failure
  | Ok _ -> false
;;

let with_timeout_budget_fallback ~run_fallback_judge runs =
  if runs <> [] && List.for_all failed_timeout_or_budget runs
  then (
    match run_fallback_judge () with
    | Some fallback -> runs @ [ fallback ]
    | None -> runs)
  else runs
;;

let remaining_wave_budget ~preset clock =
  preset.Fusion_policy.judge_wave_budget_s -. elapsed_since_t0 clock
;;

let meta_budget_check ~preset clock =
  if not (clock_available clock)
  then missing_clock_result clock
  else if
    not
      (Fusion_policy.judge_wave_budget_enabled
         ~wave_budget_s:preset.Fusion_policy.judge_wave_budget_s)
  then Ok preset.Fusion_policy.meta_timeout_s
  else if remaining_wave_budget ~preset clock < preset.Fusion_policy.meta_timeout_s
  then
    Error
      ( Fusion_types.Budget_exceeded "insufficient remaining budget for meta"
      , Fusion_types.zero_usage )
  else Ok preset.Fusion_policy.meta_timeout_s
;;

let run_fallback_judge
      ~sw
      ~net
      ~preset
      ~panel
      ~question
      ~clock
      ~judge_web_tools
      ~judge_max_tool_calls
      ()
  =
  match preset.Fusion_policy.fallback_judge_model with
  | None -> None
  | Some model ->
    let elapsed_s = elapsed_since_t0 clock in
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
    if not (clock_available clock)
    then Some (j, id, missing_clock_result clock, elapsed_s, false)
    else (
      match
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
              ( Fusion_types.Budget_exceeded
                  "fallback judge skipped: insufficient remaining wave budget"
              , Fusion_types.zero_usage )
          , elapsed_s
          , false )
      | Some timeout_s ->
        let result =
          Fusion_judge.run
            ~sw
            ~net
            ~timeout_s
            ?max_tokens:j.jmax_output_tokens
            ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
            ~judge_model:model
            ~question
            ~panel
            ~web_tools:judge_web_tools
            ()
        in
        let elapsed_s = elapsed_since_t0 clock in
        let timed_out =
          match result with
          | Error (f, _) -> Fusion_types.judge_failure_is_timeout f
          | Ok _ -> false
        in
        Some (j, id, result, elapsed_s, timed_out))
;;
