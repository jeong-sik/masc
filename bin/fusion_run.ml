(* RFC-0252 standalone fusion harness.

   Runs three arms on the same prompt and prints them side by side so a human
   can judge whether panel+judge deliberation beats the alternatives:

   [1] BASELINE          single model, one call.
   [2] SELF-CONSISTENCY  the same judge model sampled N times + the same judge
                         synthesis. Cost-matched to fusion (same panelist count,
                         same judge call) but homogeneous.
   [3] FUSION            N diverse models + judge synthesis. Heterogeneous.

   Why the self-consistency arm exists: comparing fusion only against a single
   call conflates two effects — spending more compute and using diverse models.
   Self-consistency holds compute fixed and varies only diversity, so [2] vs [3]
   isolates the panel-diversity effect. If fusion only matches self-consistency,
   the apparent win was compute, not heterogeneity (Self-MoA, arXiv:2502.00674).
   The harness cannot force a sampling temperature (fusion exposes none), so the
   N self-consistency samples diverge only if the provider samples stochastically;
   each sample is printed verbatim so a deterministic provider is visible rather
   than silently collapsing [2] into [1].

   It is keeper-independent: it bypasses [Fusion_orchestrator.run] (gate +
   hourly budget + keeper chat-lane sink) and calls [Fusion_panel.run] and
   [Fusion_judge.run] directly. Bypassing the orchestrator avoids the sink
   side effect (which writes a transcript to a keeper chat lane and, for a
   synthetic keeper, can return [Sink_failed] and discard the computed panel
   and judge results) and the shared hourly budget counter.

   The baseline and the self-consistency arm reuse [Fusion_panel.run] so the
   call path is identical to a panel member: the arms differ only in model set
   and judge, not in plumbing.

   Provider bindings (model routing + API keys from env vars named in
   runtime.toml) are materialised once via [Runtime.init_default]; without it
   every panel comes back [Failed (Provider_error ...)].

   Usage: dune exec bin/fusion_run.exe -- [--base PATH] [--preset NAME] <prompt...>
   Base path: --base wins; else MASC_BASE_PATH (via Config_dir_resolver); else
   the run fails. --preset defaults to policy.default_preset. *)

(* runtime.toml absolute path, mirroring Fusion_config_loader.runtime_toml_path
   so the harness resolves the same file the server and the fusion loader do
   (honours MASC_CONFIG_DIR override + <base>/.masc/config/ fallback). *)
let runtime_toml_path ~base_path : string =
  let inputs = Config_dir_resolver.inputs_from_env () in
  let resolution =
    Config_dir_resolver.resolve_with
      { inputs with Config_dir_resolver.env_base_path = Some base_path }
  in
  Filename.concat
    resolution.Config_dir_resolver.config_root.Config_dir_resolver.path
    Config_dir_resolver.runtime_toml_filename

(* ── pretty printers (exhaustive: fusion_types are closed sums by design) ── *)

let rule = String.make 72 '-'
let bar = String.make 72 '='

let string_of_failure (f : Fusion_types.panel_failure) : string =
  match f with
  | Fusion_types.Timeout -> "timeout"
  | Fusion_types.Provider_error msg -> "provider_error: " ^ msg
  | Fusion_types.Empty_response -> "empty_response"

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

(* Run the judge over a panel; returns the synthesis and the judge's own usage. *)
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
    ~web_tools:preset.Fusion_policy.web_tools
    ~max_tool_calls:preset.Fusion_policy.max_tool_calls_per_panel
    ()

(* Print a judge arm and return (resolved_answer, judge_in_tokens, judge_out_tokens). *)
let print_judge_arm ~(tag : string)
    (r : (Fusion_types.judge_synthesis * Fusion_types.usage, string) result)
  : string * int * int =
  match r with
  | Error msg ->
    Printf.printf "  [%s] judge failed: %s\n\n" tag msg;
    (Printf.sprintf "(judge failed: %s)" msg, 0, 0)
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
    ( synthesis.Fusion_types.resolved_answer
    , u.Fusion_types.input_tokens
    , u.Fusion_types.output_tokens )

let run_harness ~sw ~net ~(policy : Fusion_policy.t) ~(preset : Fusion_policy.preset)
    ~(prompt : string) ~(config_path : string) : unit =
  let n = List.length preset.Fusion_policy.panel in
  let max_fibers = max 1 policy.Fusion_policy.max_concurrent_panels in
  Printf.printf
    "%s\nFUSION HARNESS (RFC-0252) — single vs self-consistency vs fusion\n%s\n"
    bar
    bar;
  Printf.printf
    "config: %s\npreset: %s\npanel:  %s\njudge:  %s\nprompt: %s\n\n"
    config_path
    preset.Fusion_policy.name
    (String.concat ", " preset.Fusion_policy.panel)
    preset.Fusion_policy.judge
    prompt;

  let run_panel ~max_fibers ~models =
    Masc.Fusion_panel.run
      ~sw
      ~net
      ~max_fibers
      ~timeout_s:preset.Fusion_policy.panel_timeout_s
      ~models
      ~system_prompt:preset.Fusion_policy.panel_system_prompt
      ~prompt
      ~web_tools:preset.Fusion_policy.web_tools
      ~max_tool_calls_per_panel:preset.Fusion_policy.max_tool_calls_per_panel
      ()
  in

  (* ── [1] BASELINE: judge model alone, one call ── *)
  Printf.printf
    "%s\n[1] BASELINE — single model (%s), 1 call\n%s\n"
    rule
    preset.Fusion_policy.judge
    rule;
  let baseline = run_panel ~max_fibers:1 ~models:[ preset.Fusion_policy.judge ] in
  List.iter (print_outcome ~tag:"baseline") baseline;
  let baseline_answer =
    match first_some answer_of_outcome baseline with
    | Some a -> a
    | None -> "(baseline produced no answer)"
  in
  let baseline_in, baseline_out =
    sum_usage (List.filter_map usage_of_outcome baseline)
  in

  (* ── [2] SELF-CONSISTENCY: same judge model x n + judge (cost-matched) ── *)
  Printf.printf
    "%s\n[2] SELF-CONSISTENCY — %s x %d samples + judge (cost-matched, homogeneous)\n%s\n"
    rule
    preset.Fusion_policy.judge
    n
    rule;
  let sc_models = List.init n (fun _ -> preset.Fusion_policy.judge) in
  let sc_panel = run_panel ~max_fibers ~models:sc_models in
  List.iter (print_outcome ~tag:"self-consistency") sc_panel;
  let sc_answer, sc_judge_in, sc_judge_out =
    print_judge_arm ~tag:"self-consistency" (synthesize ~sw ~net ~preset ~prompt ~panel:sc_panel)
  in
  let sc_panel_in, sc_panel_out =
    sum_usage (List.filter_map usage_of_outcome sc_panel)
  in

  (* ── [3] FUSION: n diverse models + judge (heterogeneous) ── *)
  Printf.printf
    "%s\n[3] FUSION — %d diverse models + judge (heterogeneous)\n%s\n"
    rule
    n
    rule;
  let fusion_panel = run_panel ~max_fibers ~models:preset.Fusion_policy.panel in
  List.iter (print_outcome ~tag:"fusion") fusion_panel;
  let fusion_answer, fusion_judge_in, fusion_judge_out =
    print_judge_arm ~tag:"fusion" (synthesize ~sw ~net ~preset ~prompt ~panel:fusion_panel)
  in
  let fusion_panel_in, fusion_panel_out =
    sum_usage (List.filter_map usage_of_outcome fusion_panel)
  in

  (* ── SIDE-BY-SIDE SUMMARY (3-way) ── *)
  let sc_in = sc_panel_in + sc_judge_in in
  let sc_out = sc_panel_out + sc_judge_out in
  let fusion_in = fusion_panel_in + fusion_judge_in in
  let fusion_out = fusion_panel_out + fusion_judge_out in
  Printf.printf
    "%s\nSUMMARY — single vs self-consistency vs fusion\n%s\n"
    bar
    bar;
  Printf.printf "BASELINE (%s, 1 call):\n%s\n\n" preset.Fusion_policy.judge baseline_answer;
  Printf.printf
    "SELF-CONSISTENCY (%s x %d + judge):\n%s\n\n"
    preset.Fusion_policy.judge
    n
    sc_answer;
  Printf.printf "FUSION (%d diverse + judge):\n%s\n\n" n fusion_answer;
  Printf.printf
    "COST (tokens in/out):\n\
    \  baseline:         %d/%d\n\
    \  self-consistency: %d/%d  (panel %d/%d + judge %d/%d)\n\
    \  fusion:           %d/%d  (panel %d/%d + judge %d/%d)\n"
    baseline_in
    baseline_out
    sc_in
    sc_out
    sc_panel_in
    sc_panel_out
    sc_judge_in
    sc_judge_out
    fusion_in
    fusion_out
    fusion_panel_in
    fusion_panel_out
    fusion_judge_in
    fusion_judge_out

(* ── entry point ── *)
let () =
  let base = ref None in
  let preset_override = ref None in
  let prompt_parts = ref [] in
  let rec parse = function
    | [] -> ()
    | "--base" :: v :: rest ->
      base := Some v;
      parse rest
    | "--preset" :: v :: rest ->
      preset_override := Some v;
      parse rest
    | x :: rest ->
      prompt_parts := x :: !prompt_parts;
      parse rest
  in
  parse (match Array.to_list Sys.argv with _ :: tl -> tl | [] -> []);
  let prompt = String.concat " " (List.rev !prompt_parts) in
  if String.trim prompt = "" then (
    prerr_endline "usage: fusion_run [--base PATH] [--preset NAME] <prompt...>";
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
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  (* Capture the Eio handles the OAS/fusion call path reads via
     [Masc_eio_env.get_opt]. Without this, [Masc_oas_bridge.run_safe] finds no
     clock and runs the panel/judge calls without timeout enforcement. *)
  Masc.Masc_eio_env.init ~sw ~net ~clock:(Eio.Stdenv.clock env) ();
  let config_path = runtime_toml_path ~base_path in
  (match Runtime.init_default ~config_path with
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
     | Some preset -> run_harness ~sw ~net ~policy ~preset ~prompt ~config_path)
