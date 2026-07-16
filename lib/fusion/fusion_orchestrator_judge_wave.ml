type judge_run =
  string
  * ( Fusion_types.judge_synthesis * Fusion_types.usage
    , Fusion_types.judge_failure * Fusion_types.usage )
    result
  * float

type clock =
  { now_opt : unit -> float option
  ; t0 : float option
  }

let make_clock ~now_opt =
  let t0 = now_opt () in
  { now_opt; t0 }
;;

let make_runtime_clock () =
  let now_opt () =
    match Masc_eio_env.get_opt () with
    | Some { Masc_eio_env.clock; _ } -> Some (Eio.Time.now clock)
    | None -> None
  in
  make_clock ~now_opt
;;

let elapsed_since_t0 clock =
  match clock.now_opt (), clock.t0 with
  | Some now, Some t0 -> now -. t0
  | _ -> 0.0
;;

let run_first_judge
      ~sw
      ~net
      ~preset
      ~panel
      ~question
      ~clock
      ~judge_web_tools
      (j : Fusion_policy.judge_spec)
  : judge_run
  =
  let id = Fusion_policy.panelist_id ~label:j.jlabel ~model:j.jmodel in
  let _ = preset, judge_web_tools in
  let result =
    Fusion_judge.run
      ~sw
      ~net
      ~judge_system_prompt:j.jsystem_prompt
      ~judge_model:j.jmodel
      ~question
      ~panel
      ~web_tools:j.jweb_tools
      ()
  in
  let elapsed_s = elapsed_since_t0 clock in
  id, result, elapsed_s
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
  in
  let _ = max_concurrent_judges in
  Eio.Fiber.List.map
    ~max_fibers:(max 1 (List.length judges))
    run_first_judge
    judges
;;

let first_judge_nodes runs =
  List.map
    (fun (id, result, elapsed_s) ->
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
    (fun (id, result, _) ->
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
  Fusion_types.sum_all_usage (List.map (fun (id, result, _) -> id, result) runs)
;;

let all_fail_error_of_runs ~fallback runs =
  Fusion_types.all_fail_error
    ~fallback
    (List.map (fun (id, result, _) -> id, result) runs)
;;

let failed (_, result, _) =
  match result with
  | Error _ -> true
  | Ok _ -> false
;;

let with_all_error_fallback ~run_fallback_judge runs =
  if runs <> [] && List.for_all failed runs
  then (
    match run_fallback_judge () with
    | Some fallback -> runs @ [ fallback ]
    | None -> runs)
  else runs
;;

let run_fallback_judge
      ~sw
      ~net
      ~preset
      ~panel
      ~question
      ~clock
      ~judge_web_tools
      ()
  =
  match preset.Fusion_policy.fallback_judge_model with
  | None -> None
  | Some model ->
    let id = Fusion_policy.panelist_id ~label:"fallback" ~model in
    let result =
      Fusion_judge.run
        ~sw
        ~net
        ?max_tokens:preset.Fusion_policy.judge_max_output_tokens
        ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
        ~judge_model:model
        ~question
        ~panel
        ~web_tools:judge_web_tools
        ()
    in
    Some (id, result, elapsed_since_t0 clock)
;;
