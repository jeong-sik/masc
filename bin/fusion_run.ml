(* RFC-0252 standalone fusion harness.

   Runs four arms on the same prompt and prints them side by side so a human
   can judge whether panel+judge deliberation beats the alternatives:

   [1] BASELINE          single model, one call.
   [2] SELF-CONSISTENCY  the same judge model sampled N times + majority
                         aggregate. Homogeneous, no judge synthesis.
   [3] SELF-MOA          the same judge model sampled N times + judge
                         synthesis. Cost-matched to fusion (same panelist count,
                         same judge call) but homogeneous.
   [4] FUSION            N diverse models + judge synthesis. Heterogeneous.

   Why the self-consistency arm exists: comparing fusion only against a single
   call conflates two effects — spending more compute and using diverse models.
   Self-MoA holds compute fixed and varies only diversity, so [3] vs [4]
   isolates the panel-diversity effect. If fusion only matches Self-MoA, the
   apparent win was compute, not heterogeneity (Self-MoA, arXiv:2502.00674).
   The harness cannot force a sampling temperature (fusion exposes none), so the
   N self-consistency samples diverge only if the provider samples stochastically;
   each sample is printed verbatim so a deterministic provider is visible rather
   than silently collapsing [2] into [1].

   It is keeper-independent: it bypasses [Fusion_orchestrator.run] (gate +
   keeper chat-lane sink) and calls [Fusion_panel.run] and
   [Fusion_judge.run] directly. Bypassing the orchestrator avoids the sink
   side effect (which writes a transcript to a keeper chat lane and, for a
   synthetic keeper, can return [Sink_failed] and discard the computed panel
   and judge results).

   The baseline and the self-consistency arm reuse [Fusion_panel.run] so the
   call path is identical to a panel member: the arms differ only in model set
   and judge, not in plumbing.

   Provider bindings (model routing + API keys from env vars named in
   runtime.toml) are materialised once via [Runtime.init_default]; without it
   every panel comes back [Failed (Provider_error ...)].

   Usage: dune exec bin/fusion_run.exe -- [--base PATH] [--preset NAME] <prompt...>
   Base path: --base wins; else MASC_BASE_PATH (via Config_dir_resolver); else
   the run fails. --preset defaults to policy.default_preset. *)

(* ── pretty printers (exhaustive: fusion_types are closed sums by design) ── *)

let rule = String.make 72 '-'
let bar = String.make 72 '='

let string_of_failure (f : Fusion_types.panel_failure) : string =
  match f with
  | Fusion_types.Timeout -> "timeout"
  | Fusion_types.Bridge_error msg -> "bridge_error: " ^ msg
  | Fusion_types.Provider_error msg -> "provider_error: " ^ msg
  | Fusion_types.Empty_response detail -> "empty_response: " ^ detail
  | Fusion_types.Invalid_structured_response detail ->
    "invalid_structured_response: " ^ detail

let string_of_decision (d : Fusion_types.judge_decision) : string =
  match d with
  | Fusion_types.Answer _ -> "Answer"
  | Fusion_types.Recommend _ -> "Recommend"
  | Fusion_types.Insufficient _ -> "Insufficient"

let print_outcome ~(tag : string) (o : Fusion_types.panel_outcome) : unit =
  match o with
  | Fusion_types.Answered a ->
    let u = a.Fusion_types.usage in
    Printf.printf
      "  [%s] %s  (tokens in/out: %d/%d)\n%s\n\n"
      tag
      a.Fusion_types.model
      u.Fusion_types.input_tokens
      u.Fusion_types.output_tokens
      a.Fusion_types.answer
  | Fusion_types.Failed e ->
    Printf.printf
      "  [%s] %s  FAILED: %s\n\n"
      tag
      e.Fusion_types.failed_model
      (string_of_failure e.Fusion_types.reason)

let usage_of_outcome (o : Fusion_types.panel_outcome) : Fusion_types.usage option =
  match o with
  | Fusion_types.Answered a -> Some a.Fusion_types.usage
  | Fusion_types.Failed _ -> None

let answer_of_outcome (o : Fusion_types.panel_outcome) : string option =
  match o with
  | Fusion_types.Answered a -> Some a.Fusion_types.answer
  | Fusion_types.Failed _ -> None

let sum_usage (us : Fusion_types.usage list) : int * int =
  List.fold_left
    (fun (i, o) (u : Fusion_types.usage) ->
      (i + u.Fusion_types.input_tokens, o + u.Fusion_types.output_tokens))
    (0, 0)
    us

(* first non-None over a list *)
let first_some (f : 'a -> 'b option) (xs : 'a list) : 'b option =
  List.fold_left
    (fun acc x -> match acc with Some _ -> acc | None -> f x)
    None
    xs

(* Run the judge over a panel; returns the synthesis and the judge's own usage.
   This debug CLI does not account for error-path usage (the orchestrator does),
   so the [Error] usage carried by [Fusion_judge.run] is dropped here, keeping
   the existing [(.. , string) result] contract for the print helpers below. *)
let synthesize ~sw ~net ~(preset : Fusion_policy.preset) ~(prompt : string)
    ~(panel : Fusion_types.panel_outcome list)
  : (Fusion_types.judge_synthesis * Fusion_types.usage, string) result =
  Masc.Fusion_judge.run
    ~sw
    ~net
    ~timeout_s:preset.Fusion_policy.judge_timeout_s
    ~judge_system_prompt:preset.Fusion_policy.judge_system_prompt
    ~judge_model:preset.Fusion_policy.judge
    ~question:prompt
    ~panel
    ~web_tools:
      (Fusion_policy.judge_web_tools_of ~req_web_tools:false
         preset.Fusion_policy.panels)
    ()
  |> Result.map_error (fun (failure, _usage) ->
    Fusion_types.judge_failure_text failure)

(* Print a judge arm and return (resolved_answer, judge_in_tokens, judge_out_tokens). *)
let print_judge_arm ~(tag : string)
    (r : (Fusion_types.judge_synthesis * Fusion_types.usage, string) result)
  : (string * int * int, string) result =
  match r with
  | Error msg ->
    Printf.printf "  [%s] judge failed: %s\n\n" tag msg;
    Error msg
  | Ok (synthesis, u) ->
    Printf.printf
      "  [%s] decision: %s\n\n  RESOLVED ANSWER:\n%s\n\n"
      tag
      (string_of_decision synthesis.Fusion_types.decision)
      synthesis.Fusion_types.resolved_answer;
    Printf.printf
      "  [%s] full synthesis (consensus / contradictions / unique_insights / blind_spots):\n%s\n\n"
      tag
      (Yojson.Safe.pretty_to_string
         (Fusion_types.judge_synthesis_to_yojson synthesis));
    Ok
      ( synthesis.Fusion_types.resolved_answer
      , u.Fusion_types.input_tokens
      , u.Fusion_types.output_tokens )

let run_harness ~sw ~net ~(policy : Fusion_policy.t) ~(preset : Fusion_policy.preset)
    ~(prompt : string) ~(config_path : string) : unit =
  let models_all = Fusion_policy.preset_models preset in
  let n = List.length models_all in
  (* 하네스는 동질 arm 비교 도구다(RFC-0252 §11). 이종 preset이면 첫 그룹의 plumbing
     (system_prompt/web_tools/timeout)을 대표로 써 모든 arm을 같은
     설정으로 돌린다 — arm 차이는 모델 집합·judge이지 plumbing이 아니다(legacy 단일
     그룹이면 그 그룹 값 = 오늘과 동일). *)
  let g0 = List.hd preset.Fusion_policy.panels in
  let incomplete = ref [] in
  let mark_incomplete msg = incomplete := msg :: !incomplete in
  Printf.printf
    "%s\nFUSION HARNESS (RFC-0252) — single vs self-consistency vs Self-MoA vs fusion\n%s\n"
    bar bar;
  Printf.printf
    "config: %s\npreset: %s\npanel:  %s\njudge:  %s\nprompt: %s\n\n"
    config_path
    preset.Fusion_policy.name
    (String.concat ", " models_all)
    preset.Fusion_policy.judge
    prompt;

  let run_panel ~models =
    let groups = [ { g0 with Fusion_policy.models } ] in
    Masc.Fusion_panel.run
      ~sw
      ~net
      ~outer_timeout_s:(Fusion_policy.panel_outer_timeout_of groups)
      ~groups
      ~prompt
      ()
  in

  (* ── [1] BASELINE: judge model alone, one call ── *)
  Printf.printf
    "%s\n[1] BASELINE — single model (%s), 1 call\n%s\n"
    rule
    preset.Fusion_policy.judge
    rule;
  let baseline = run_panel ~models:[ preset.Fusion_policy.judge ] in
  List.iter (print_outcome ~tag:"baseline") baseline;
  let baseline_answer =
    match first_some answer_of_outcome baseline with
    | Some a -> a
    | None ->
      let msg = "baseline produced no answer" in
      Printf.printf "  [baseline] failed: %s\n\n" msg;
      mark_incomplete msg;
      "(baseline produced no answer)"
  in
  let baseline_in, baseline_out =
    sum_usage (List.filter_map usage_of_outcome baseline)
  in

  (* ── [2] SELF-CONSISTENCY: same judge model x n + majority aggregate ── *)
  Printf.printf
    "%s\n[2] SELF-CONSISTENCY — %s x %d samples + majority aggregate\n%s\n"
    rule
    preset.Fusion_policy.judge
    n
    rule;
  let sc_models = List.init n (fun _ -> preset.Fusion_policy.judge) in
  let sc_panel = run_panel ~models:sc_models in
  List.iter (print_outcome ~tag:"self-consistency") sc_panel;
  let sc_answers = List.filter_map answer_of_outcome sc_panel in
  let sc_answer =
    match sc_answers with
    | [] ->
      let msg = "self-consistency majority has no answered samples" in
      Printf.printf "  [self-consistency] majority failed: %s\n\n" msg;
      mark_incomplete msg;
      "(self-consistency majority unavailable)"
    | answers ->
      let answer = Fusion_harness_core.majority_vote answers in
      Printf.printf
        "  [self-consistency] MAJORITY ANSWER (%d samples):\n%s\n\n"
        (List.length answers)
        answer;
      answer
  in
  let sc_panel_in, sc_panel_out =
    sum_usage (List.filter_map usage_of_outcome sc_panel)
  in

  (* ── [3] SELF-MOA: same judge model x n + judge synthesis ── *)
  Printf.printf
    "%s\n[3] SELF-MOA — %s x %d samples + judge synthesis (cost-matched, homogeneous)\n%s\n"
    rule
    preset.Fusion_policy.judge
    n
    rule;
  let self_moa_answer, self_moa_judge_in, self_moa_judge_out =
    match
      print_judge_arm ~tag:"self-moa"
        (synthesize ~sw ~net ~preset ~prompt ~panel:sc_panel)
    with
    | Ok values -> values
    | Error msg ->
      mark_incomplete ("self-moa judge failed: " ^ msg);
      (Printf.sprintf "(self-moa judge failed: %s)" msg, 0, 0)
  in

  (* ── [4] FUSION: n diverse models + judge (heterogeneous) ── *)
  Printf.printf
    "%s\n[4] FUSION — %d diverse models + judge synthesis (heterogeneous)\n%s\n"
    rule
    n
    rule;
  let fusion_panel = run_panel ~models:models_all in
  List.iter (print_outcome ~tag:"fusion") fusion_panel;
  let fusion_answer, fusion_judge_in, fusion_judge_out =
    match
      print_judge_arm ~tag:"fusion"
        (synthesize ~sw ~net ~preset ~prompt ~panel:fusion_panel)
    with
    | Ok values -> values
    | Error msg ->
      mark_incomplete ("fusion judge failed: " ^ msg);
      (Printf.sprintf "(fusion judge failed: %s)" msg, 0, 0)
  in
  let fusion_panel_in, fusion_panel_out =
    sum_usage (List.filter_map usage_of_outcome fusion_panel)
  in

  (* ── SIDE-BY-SIDE SUMMARY (4-way) ── *)
  let self_moa_in = sc_panel_in + self_moa_judge_in in
  let self_moa_out = sc_panel_out + self_moa_judge_out in
  let fusion_in = fusion_panel_in + fusion_judge_in in
  let fusion_out = fusion_panel_out + fusion_judge_out in
  let incomplete = List.rev !incomplete in
  let status = if incomplete = [] then "complete" else "INCOMPLETE" in
  Printf.printf
    "%s\nSUMMARY (%s) — single vs self-consistency vs Self-MoA vs fusion\n%s\n"
    bar
    status
    bar;
  Printf.printf "BASELINE (%s, 1 call):\n%s\n\n" preset.Fusion_policy.judge baseline_answer;
  Printf.printf
    "SELF-CONSISTENCY (%s x %d + majority):\n%s\n\n"
    preset.Fusion_policy.judge
    n
    sc_answer;
  Printf.printf
    "SELF-MOA (%s x %d + judge):\n%s\n\n"
    preset.Fusion_policy.judge
    n
    self_moa_answer;
  Printf.printf "FUSION (%d diverse + judge):\n%s\n\n" n fusion_answer;
  Printf.printf
    "COST (tokens in/out):\n\
    \  baseline:         %d/%d\n\
    \  self-consistency: %d/%d  (panel only; majority aggregate)\n\
    \  self-moa:         %d/%d  (panel %d/%d + judge %d/%d)\n\
    \  fusion:           %d/%d  (panel %d/%d + judge %d/%d)\n"
    baseline_in
    baseline_out
    sc_panel_in
    sc_panel_out
    self_moa_in
    self_moa_out
    sc_panel_in
    sc_panel_out
    self_moa_judge_in
    self_moa_judge_out
    fusion_in
    fusion_out
    fusion_panel_in
    fusion_panel_out
    fusion_judge_in
    fusion_judge_out;
  if incomplete <> [] then (
    Printf.eprintf "\nINCOMPLETE fusion harness run:\n";
    List.iter (Printf.eprintf "  - %s\n") incomplete;
    flush stdout;
    flush stderr;
    exit 1)

(* ── entry point ── *)
let () =
  let base = ref None in
  let preset_override = ref None in
  let prompt_parts = ref [] in
  let rec parse = function
    | [] -> Ok ()
    | "--base" :: v :: rest ->
      base := Some v;
      parse rest
    | [ "--base" ] -> Error "missing value for --base"
    | "--preset" :: v :: rest ->
      preset_override := Some v;
      parse rest
    | [ "--preset" ] -> Error "missing value for --preset"
    | "--" :: rest ->
      prompt_parts := List.rev_append rest !prompt_parts;
      Ok ()
    | x :: _ when String.length x > 0 && x.[0] = '-' ->
      Error ("unknown option: " ^ x)
    | x :: rest ->
      prompt_parts := x :: !prompt_parts;
      parse rest
  in
  (match parse (match Array.to_list Sys.argv with _ :: tl -> tl | [] -> []) with
   | Ok () -> ()
   | Error msg ->
     Printf.eprintf "fusion_run: %s\n" msg;
     prerr_endline "usage: fusion_run [--base PATH] [--preset NAME] [--] <prompt...>";
     exit 2);
  let prompt = String.concat " " (List.rev !prompt_parts) in
  if String.trim prompt = "" then (
    prerr_endline "usage: fusion_run [--base PATH] [--preset NAME] [--] <prompt...>";
    exit 2);
  (* Base path: explicit --base wins; else the workspace base the server uses
     (MASC_BASE_PATH via Host_config, surfaced by Config_dir_resolver). We do
     not invent a default path — an unknown base is an error, not a silent
     fallback to one operator's home directory. *)
  let base_path =
    match !base with
    | Some p -> p
    | None ->
      (match Config_dir_resolver.current_env_base_path_opt () with
       | Some p -> p
       | None ->
         prerr_endline
           "no workspace base path: set MASC_BASE_PATH or pass --base PATH";
         exit 2)
  in
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Time_compat.set_clock (Eio.Stdenv.clock env);
  (* Register the ambient Eio clock the agent runtime resolves via
     [Process_eio.get_clock]. Without this, any runtime config that sets
     [stream_idle_timeout_s] fails closed at agent build time ("no clock
     resolvable ... refusing to run with a silently disarmed stream idle
     timeout") and every panel/judge call aborts before the first request. *)
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.fs env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  (* Capture the Eio handles the OAS/fusion call path reads via
     [Masc_eio_env.get_opt]. Without this, [Masc_oas_bridge.run_safe] fails
     closed before starting panel/judge calls. *)
  Masc.Masc_eio_env.init ~sw ~net ~clock:(Eio.Stdenv.clock env) ();
  let config_path = Masc.Fusion_config_loader.runtime_toml_path ~base_path in
  (match Runtime.init_default_strict ~config_path with
   | Error msg ->
     Printf.eprintf "runtime init failed (%s): %s\n" config_path msg;
     exit 1
   | Ok () -> ());
  match Masc.Fusion_config_loader.load ~base_path with
  | Error msg ->
    Printf.eprintf "fusion config error: %s\n" msg;
    exit 1
  | Ok policy ->
    if not policy.Fusion_policy.enabled then (
      Printf.eprintf
        "fusion disabled in %s ([fusion].enabled=false or no [fusion] section)\n"
        config_path;
      exit 1);
    let preset_name =
      match !preset_override with
      | Some p -> p
      | None -> policy.Fusion_policy.default_preset
    in
    (match Fusion_policy.find_preset policy preset_name with
     | None ->
       Printf.eprintf "preset not found: %s\n" preset_name;
       exit 1
     | Some vp ->
       (* RFC-0280: find_preset가 검증된 preset을 돌려준다. 하네스는 raw preset으로
          coerce해 arm을 구성한다(read-only). *)
       let preset = Fusion_policy.Validated_preset.preset vp in
       run_harness ~sw ~net ~policy ~preset ~prompt ~config_path)
