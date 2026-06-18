(* RFC-0252 standalone fusion harness.

   Runs an on-demand panel+judge deliberation and a single-model baseline on
   the same prompt and prints both side by side, so a human can judge whether
   the panel+judge deliberation produces a better answer than one model.

   It is keeper-independent: it bypasses [Fusion_orchestrator.run] (gate +
   hourly budget + keeper chat-lane sink) and calls [Fusion_panel.run] and
   [Fusion_judge.run] directly. Bypassing the orchestrator avoids the sink
   side effect (which writes a transcript to a keeper chat lane and, for a
   synthetic keeper, can return [Sink_failed] and discard the computed panel
   and judge results) and the shared hourly budget counter.

   The baseline reuses [Fusion_panel.run] with a single model so the call path
   is identical to a panel member: the comparison differs only in
   N-models + judge, not in plumbing.

   Provider bindings (model routing + API keys from env vars named in
   runtime.toml) are materialised once via [Runtime.init_default]; without it
   every panel comes back [Failed (Provider_error ...)].

   Usage: dune exec bin/fusion_run.exe -- [--base PATH] [--preset NAME] <prompt...>
   Defaults: --base /Users/dancer/me, --preset = policy.default_preset. *)

let default_base = "/Users/dancer/me"

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

let run_harness ~sw ~net ~(policy : Fusion_policy.t) ~(preset : Fusion_policy.preset)
    ~(prompt : string) ~(config_path : string) : unit =
  Printf.printf "%s\nFUSION HARNESS (RFC-0252) — panel+judge vs single model\n%s\n" bar bar;
  Printf.printf
    "config: %s\npreset: %s\npanel:  %s\njudge:  %s\nprompt: %s\n\n"
    config_path
    preset.Fusion_policy.name
    (String.concat ", " preset.Fusion_policy.panel)
    preset.Fusion_policy.judge
    prompt;

  (* ── [1] BASELINE: judge model alone, via the same panel call path ── *)
  Printf.printf
    "%s\n[1] BASELINE — single model (%s) answering alone\n%s\n"
    rule
    preset.Fusion_policy.judge
    rule;
  let baseline =
    Masc.Fusion_panel.run
      ~sw
      ~net
      ~max_fibers:1
      ~timeout_s:preset.Fusion_policy.panel_timeout_s
      ~models:[ preset.Fusion_policy.judge ]
      ~system_prompt:preset.Fusion_policy.panel_system_prompt
      ~prompt
      ~web_tools:preset.Fusion_policy.web_tools
      ~max_tool_calls_per_panel:preset.Fusion_policy.max_tool_calls_per_panel
      ()
  in
  List.iter (print_outcome ~tag:"baseline") baseline;
  let baseline_answer =
    match first_some answer_of_outcome baseline with
    | Some a -> a
    | None -> "(baseline produced no answer)"
  in
  let baseline_in, baseline_out =
    sum_usage (List.filter_map usage_of_outcome baseline)
  in

  (* ── [2] FUSION PANEL: full model list, run independently ── *)
  Printf.printf
    "%s\n[2] FUSION PANEL — %d models (independent answers)\n%s\n"
    rule
    (List.length preset.Fusion_policy.panel)
    rule;
  let panel =
    Masc.Fusion_panel.run
      ~sw
      ~net
      ~max_fibers:(max 1 policy.Fusion_policy.max_concurrent_panels)
      ~timeout_s:preset.Fusion_policy.panel_timeout_s
      ~models:preset.Fusion_policy.panel
      ~system_prompt:preset.Fusion_policy.panel_system_prompt
      ~prompt
      ~web_tools:preset.Fusion_policy.web_tools
      ~max_tool_calls_per_panel:preset.Fusion_policy.max_tool_calls_per_panel
      ()
  in
  List.iter (print_outcome ~tag:"panel") panel;
  let panel_in, panel_out = sum_usage (List.filter_map usage_of_outcome panel) in

  (* ── [3] FUSION JUDGE: synthesise the panel ── *)
  Printf.printf
    "%s\n[3] FUSION JUDGE — %s synthesises the panel\n%s\n"
    rule
    preset.Fusion_policy.judge
    rule;
  match
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
  with
  | Error msg -> Printf.printf "  judge failed: %s\n\n" msg
  | Ok (synthesis, judge_usage) ->
    Printf.printf
      "  decision: %s\n\n  RESOLVED ANSWER:\n%s\n\n"
      (string_of_decision synthesis.Fusion_types.decision)
      synthesis.Fusion_types.resolved_answer;
    Printf.printf
      "  full synthesis (consensus / contradictions / unique_insights / blind_spots):\n%s\n\n"
      (Yojson.Safe.pretty_to_string
         (Fusion_types.judge_synthesis_to_yojson synthesis));

    (* ── SIDE-BY-SIDE SUMMARY ── *)
    let fusion_in = panel_in + judge_usage.Fusion_types.input_tokens in
    let fusion_out = panel_out + judge_usage.Fusion_types.output_tokens in
    Printf.printf "%s\nSUMMARY — single model vs fusion\n%s\n" bar bar;
    Printf.printf
      "BASELINE (%s):\n%s\n\n"
      preset.Fusion_policy.judge
      baseline_answer;
    Printf.printf
      "FUSION (%d-model panel + judge):\n%s\n\n"
      (List.length preset.Fusion_policy.panel)
      synthesis.Fusion_types.resolved_answer;
    Printf.printf
      "COST (tokens in/out) — baseline: %d/%d | fusion: %d/%d (panel %d/%d + judge %d/%d)\n"
      baseline_in
      baseline_out
      fusion_in
      fusion_out
      panel_in
      panel_out
      judge_usage.Fusion_types.input_tokens
      judge_usage.Fusion_types.output_tokens

(* ── entry point ── *)
let () =
  let base = ref default_base in
  let preset_override = ref None in
  let prompt_parts = ref [] in
  let rec parse = function
    | [] -> ()
    | "--base" :: v :: rest ->
      base := v;
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
    prerr_endline
      "usage: fusion_run [--base PATH] [--preset NAME] <prompt...>";
    exit 2);
  let base_path = !base in
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
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
