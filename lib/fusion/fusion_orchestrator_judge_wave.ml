type judge_run =
  Fusion_policy.judge_spec
  * string
  * ( Fusion_types.judge_synthesis * Fusion_types.usage
    , Fusion_types.judge_failure * Fusion_types.usage )
    result
  * float option

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
  | Some now, Some t0 -> Some (now -. t0)
  | _ -> None
;;

(* 1차 심판의 출력 토큰 예산. per-judge [max_output_tokens]가 있으면 그것이,
   없으면 preset의 [judge_max_output_tokens]가 적용된다 — meta/refine 심판이 쓰는
   예산과 같은 값으로 폴백한다. 이전에는 둘 다 전달되지 않아 1차 심판만 런타임
   기본값으로 돌았고, [judge_spec.jmax_output_tokens]는 파싱·검증·직렬화까지 되면서
   실행 경로 소비자가 없는 미배선 필드였다. *)
let first_judge_max_tokens ~(preset : Fusion_policy.preset) (j : Fusion_policy.judge_spec) =
  match j.jmax_output_tokens with
  | Some _ as budget -> budget
  | None -> preset.judge_max_output_tokens
;;

(* 1차 심판의 web tool 주입 여부. [judge_web_tools]는 요청의 web_tools와 패널 그룹
   설정에서 derive된 값([Fusion_policy.judge_web_tools_of])이고 [jweb_tools]는 이
   1차 심판 고유 설정이다. 합집합이 옳은 이유: single/refine/meta 심판은 전부
   [judge_web_tools]를 받으므로, 1차 심판만 그것을 무시하면 같은 요청 안에서
   심판 축마다 도구 표면이 달라진다. 순수 — 테스트 가능. *)
let first_judge_web_tools ~judge_web_tools (j : Fusion_policy.judge_spec) =
  judge_web_tools || j.jweb_tools
;;

(* 1차 심판의 응답 데드라인. [jmax_output_tokens]와 같은 우선순위 규칙이다:
   자기 선언이 있으면 그것, 없으면 preset의 심판 데드라인. 1차 심판들은 서로 다른
   모델일 수 있어(lens마다 다른 런타임) 속도 분포도 다르므로 per-judge 축이 있다. *)
let first_judge_timeout_s ~(preset : Fusion_policy.preset) (j : Fusion_policy.judge_spec) =
  match j.jtimeout_s with
  | Some _ as deadline -> deadline
  | None -> preset.judge_timeout_s
;;

let run_first_judge
      ~sw
      ~net
      ~preset
      ~panel
      ~question
      ~clock
      ~judge_web_tools
      ~on_tool_trace
      (j : Fusion_policy.judge_spec)
  : judge_run
  =
  let id = Fusion_policy.panelist_id ~label:j.jlabel ~model:j.jmodel in
  let tool_actor =
    Fusion_types.Judge_actor { role = Fusion_types.First id; identity = id }
  in
  let result =
    Fusion_judge.run
      ~sw
      ~net
      ?max_tokens:(first_judge_max_tokens ~preset j)
      ?timeout_s:(first_judge_timeout_s ~preset j)
      ~judge_system_prompt:j.jsystem_prompt
      ~judge_model:j.jmodel
      ~question
      ~panel
      ~web_tools:(first_judge_web_tools ~judge_web_tools j)
      ~tool_trace:(tool_actor, on_tool_trace)
      ()
  in
  let elapsed_s = elapsed_since_t0 clock in
  j, id, result, elapsed_s
;;

let run_first_judges
      ~sw
      ~net
      ~preset
      ~panel
      ~question
      ~clock
      ~judge_web_tools
      ~on_tool_trace
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
      ~on_tool_trace
  in
  Eio.Fiber.List.map run_first_judge judges
;;

let first_judge_nodes runs =
  List.map
    (fun (_, id, result, elapsed_s) ->
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
    (fun (_, id, result, _) ->
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
  Fusion_types.sum_all_usage (List.map (fun (_, id, result, _) -> id, result) runs)
;;

let all_fail_error_of_runs ~fallback runs =
  Fusion_types.all_fail_error
    ~fallback
    (List.map (fun (_, id, result, _) -> id, result) runs)
;;
