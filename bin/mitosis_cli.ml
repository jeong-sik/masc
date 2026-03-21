(** Mitosis CLI — Standalone testing and debugging tool for the mitosis system.

    Subcommands:
    - validate: Validate DNA content quality
    - simulate: Simulate state machine lifecycle
    - config:   Show current mitosis configuration

    Usage:
      masc-mitosis-cli validate --dna "context text..."
      masc-mitosis-cli validate --file dna.txt
      masc-mitosis-cli simulate --generations 3
      masc-mitosis-cli config

    @since 0.5.0 *)

open Cmdliner
open Masc_mcp

(* ================================================================ *)
(* Validate subcommand                                              *)
(* ================================================================ *)

let count_char pred s =
  String.fold_left (fun acc c -> if pred c then acc + 1 else acc) 0 s

let is_whitespace c = c = ' ' || c = '\t' || c = '\n' || c = '\r'

let count_marker_occurrences ~haystack ~needle =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let ln = String.length n in
  let lh = String.length h in
  if ln = 0 || ln > lh then 0
  else
    let count = ref 0 in
    for i = 0 to lh - ln do
      if String.sub h i ln = n then incr count
    done;
    !count

let print_dna_stats dna =
  let len = String.length dna in
  let ws_count = count_char is_whitespace dna in
  let ws_ratio = if len > 0 then Float.of_int ws_count /. Float.of_int len else 0.0 in
  let newline_count = count_char (fun c -> c = '\n') dna in
  let structure_markers =
    [ ("newline", newline_count);
      ("bullet (- )", count_marker_occurrences ~haystack:dna ~needle:"- ");
      ("colon (: )", count_marker_occurrences ~haystack:dna ~needle:": ");
      ("star (* )", count_marker_occurrences ~haystack:dna ~needle:"* ") ]
  in
  let goal_markers =
    [ "goal"; "task"; "objective"; "context" ]
    |> List.map (fun m -> (m, count_marker_occurrences ~haystack:dna ~needle:m))
  in
  Printf.printf "=== DNA Stats ===\n";
  Printf.printf "  Length:           %d chars\n" len;
  Printf.printf "  Whitespace:       %d chars (%.1f%%)\n" ws_count (ws_ratio *. 100.0);
  Printf.printf "  Lines:            %d\n" (newline_count + 1);
  Printf.printf "\n  Structure markers:\n";
  List.iter (fun (name, count) ->
    if count > 0 then Printf.printf "    %-16s %d\n" name count
  ) structure_markers;
  Printf.printf "\n  Goal markers:\n";
  List.iter (fun (name, count) ->
    let status = if count > 0 then "found" else "missing" in
    Printf.printf "    %-16s %s (%d)\n" name status count
  ) goal_markers

let run_validate dna_str file_path =
  let dna = match dna_str, file_path with
    | Some s, _ -> s
    | None, Some path ->
      (try
        let ic = open_in path in
        let n = in_channel_length ic in
        let s = Bytes.create n in
        really_input ic s 0 n;
        close_in ic;
        Bytes.to_string s
      with
      | Sys_error msg ->
        Printf.eprintf "Error reading file: %s\n" msg;
        exit 1)
    | None, None ->
      Printf.eprintf "Error: provide --dna <text> or --file <path>\n";
      exit 1
  in
  Printf.printf "Validating DNA (%d chars)...\n\n" (String.length dna);
  print_dna_stats dna;
  Printf.printf "\n=== Validation Result ===\n";
  match Tool_mitosis_utils.validate_dna dna with
  | Ok _ ->
    Printf.printf "  Status: OK (valid DNA)\n";
    `Ok ()
  | Error msg ->
    Printf.printf "  Status: ERROR\n";
    Printf.printf "  Reason: %s\n" msg;
    `Ok ()

(* ================================================================ *)
(* Simulate subcommand                                              *)
(* ================================================================ *)

let run_simulate generations prepare_threshold handoff_threshold =
  Printf.printf "=== Mitosis Lifecycle Simulation ===\n";
  Printf.printf "  Generations:        %d\n" generations;
  Printf.printf "  Prepare threshold:  %.0f%%\n" (prepare_threshold *. 100.0);
  Printf.printf "  Handoff threshold:  %.0f%%\n" (handoff_threshold *. 100.0);
  Printf.printf "\n";

  let config = { Mitosis.default_config with
    prepare_threshold;
    handoff_threshold;
  } in

  let pool = ref (Mitosis.init_pool ~config) in
  let current_cell = ref (Mitosis.create_stem_cell ~generation:0) in
  let start_time = Unix.gettimeofday () in

  for gen = 0 to generations - 1 do
    Printf.printf "--- Generation %d ---\n" gen;

    (* Stem -> Active *)
    let cell = { !current_cell with
      Mitosis.state = Mitosis.Active;
      phase = Mitosis.Idle;
      generation = gen;
      task_count = 0;
      tool_call_count = 0;
    } in
    Printf.printf "  [%s -> %s] Cell %s activated\n"
      (Mitosis.state_to_string Mitosis.Stem)
      (Mitosis.state_to_string Mitosis.Active)
      cell.Mitosis.id;

    (* Simulate work: increment tasks and tool calls *)
    let cell = ref cell in
    for _i = 1 to 10 do
      cell := Mitosis.record_activity ~cell:!cell ~task_done:true ~tool_called:true
    done;
    Printf.printf "  [work] %d tasks, %d tool calls\n"
      (!cell).Mitosis.task_count (!cell).Mitosis.tool_call_count;

    (* Simulate reaching prepare threshold *)
    let context_ratio = prepare_threshold +. 0.01 in
    let should_prep = Mitosis.should_prepare ~config ~cell:!cell ~context_ratio in
    Printf.printf "  [check] should_prepare at %.0f%%: %b\n"
      (context_ratio *. 100.0) should_prep;

    if should_prep then begin
      let sample_context = Printf.sprintf
        "Goal: Complete generation %d tasks.\nContext: Agent migration and testing.\nCurrent task: Simulate mitosis lifecycle.\n- Finding 1: State transitions work correctly\n- Finding 2: DNA extraction preserves key context\n- Finding 3: Compression ratio tuning needed\n"
        gen
      in
      let prepared = Mitosis.prepare_for_division ~config ~cell:!cell ~full_context:sample_context in
      cell := prepared;
      Printf.printf "  [%s -> %s] DNA extracted (%d chars prepared)\n"
        (Mitosis.state_to_string Mitosis.Active)
        (Mitosis.state_to_string Mitosis.Prepared)
        (String.length (Option.value ~default:"" prepared.Mitosis.prepared_dna))
    end;

    (* Simulate reaching handoff threshold *)
    let context_ratio = handoff_threshold +. 0.01 in
    let should_hand = Mitosis.should_handoff ~config ~cell:!cell ~context_ratio in
    Printf.printf "  [check] should_handoff at %.0f%%: %b\n"
      (context_ratio *. 100.0) should_hand;

    if should_hand then begin
      let full_context = Printf.sprintf
        "Goal: Complete generation %d tasks.\nContext: Agent migration and testing.\nCurrent task: Simulate mitosis lifecycle.\n- Finding 1: State transitions work correctly\n- Finding 2: DNA extraction preserves key context\n- Finding 3: Compression ratio tuning needed\nAdditional work since prepare:\n- Delta item A: New discovery\n- Delta item B: Configuration validated\n"
        gen
      in
      (* perform_mitosis without spawn *)
      let dna = match (!cell).Mitosis.phase with
        | Mitosis.ReadyForHandoff prepared_dna ->
          let delta = Mitosis.extract_delta ~config ~full_context ~since_len:(!cell).Mitosis.prepare_context_len in
          Mitosis.merge_dna_with_delta ~prepared_dna ~delta
        | Mitosis.Idle ->
          Mitosis.bounded_handoff_dna ~config ~parent_cell:!cell ~full_context
      in
      let dying = Mitosis.begin_apoptosis !cell in
      Printf.printf "  [%s -> %s] Division complete\n"
        (Mitosis.state_to_string Mitosis.Prepared)
        (Mitosis.state_to_string Mitosis.Dividing);

      let (child, new_pool) = Mitosis.activate_stem ~pool:!pool ~dna in
      let child = { child with Mitosis.generation = gen + 1 } in
      let new_stem = Mitosis.create_stem_cell ~generation:(gen + 2) in
      pool := { new_pool with cells = new_stem :: new_pool.cells };

      Printf.printf "  [%s -> %s] Parent %s entering apoptosis\n"
        (Mitosis.state_to_string Mitosis.Dividing)
        (Mitosis.state_to_string Mitosis.Apoptotic)
        dying.Mitosis.id;

      let _ = Mitosis.complete_apoptosis dying in
      Printf.printf "  [apoptosis] Parent %s completed shutdown\n" dying.Mitosis.id;
      Printf.printf "  [activated] Child %s (gen %d) with %d chars DNA\n"
        child.Mitosis.id child.Mitosis.generation (String.length dna);

      current_cell := child
    end;

    Printf.printf "\n"
  done;

  let elapsed = Unix.gettimeofday () -. start_time in

  Printf.printf "=== Simulation Summary ===\n";
  Printf.printf "  Generations simulated: %d\n" generations;
  Printf.printf "  Elapsed time:          %.3f ms\n" (elapsed *. 1000.0);
  Printf.printf "  Final cell:            %s (gen %d)\n"
    (!current_cell).Mitosis.id (!current_cell).Mitosis.generation;
  Printf.printf "  Stem pool size:        %d cells\n"
    (List.length (!pool).Mitosis.cells);
  Printf.printf "\n  Prometheus metrics (registered):\n";
  Printf.printf "    mitosis_handoff_total\n";
  Printf.printf "    mitosis_prepare_total\n";
  Printf.printf "    mitosis_error_total\n";
  Printf.printf "    mitosis_current_generation\n";
  Printf.printf "    mitosis_cooldown_remaining_seconds\n";
  Printf.printf "    mitosis_handoff_duration_seconds\n";
  Printf.printf "\n  (Note: Prometheus counters are not incremented in simulation mode.\n";
  Printf.printf "   Use the MCP server for live metric tracking.)\n";
  `Ok ()

(* ================================================================ *)
(* Config subcommand                                                *)
(* ================================================================ *)

let run_config () =
  let open Mitosis in
  Printf.printf "=== Mitosis Configuration ===\n\n";

  Printf.printf "  Defaults (compiled):\n";
  Printf.printf "    %-32s %.0f s\n" "time_trigger_seconds" Defaults.time_trigger_seconds;
  Printf.printf "    %-32s %d\n" "task_trigger_count" Defaults.task_trigger_count;
  Printf.printf "    %-32s %d\n" "tool_call_trigger_count" Defaults.tool_call_trigger_count;
  Printf.printf "    %-32s %d\n" "stem_pool_size" Defaults.stem_pool_size;
  Printf.printf "    %-32s %d\n" "max_generation" Defaults.max_generation;
  Printf.printf "    %-32s %.2f\n" "dna_compression_ratio" Defaults.dna_compression_ratio;
  Printf.printf "    %-32s %.1f s\n" "apoptosis_delay_seconds" Defaults.apoptosis_delay_seconds;
  Printf.printf "    %-32s %.2f (%.0f%%)\n" "prepare_threshold" Defaults.prepare_threshold (Defaults.prepare_threshold *. 100.0);
  Printf.printf "    %-32s %.2f (%.0f%%)\n" "handoff_threshold" Defaults.handoff_threshold (Defaults.handoff_threshold *. 100.0);
  Printf.printf "    %-32s %d chars\n" "min_context_for_delta" Defaults.min_context_for_delta;
  Printf.printf "    %-32s %d chars\n" "min_delta_len" Defaults.min_delta_len;
  Printf.printf "    %-32s %.0f\n" "tool_calls_per_full_context" Defaults.tool_calls_per_full_context;
  Printf.printf "    %-32s %d\n" "emergency_generation" Defaults.emergency_generation;
  Printf.printf "    %-32s %d s\n" "spawn_timeout_seconds" Defaults.spawn_timeout_seconds;
  Printf.printf "\n";

  Printf.printf "  Env var overrides (Env_config.Mitosis):\n";
  let env_interval = Env_config.Mitosis.trigger_interval_seconds in
  let env_cooldown = Env_config.Mitosis.handoff_cooldown_seconds in
  let env_experiment = Env_config.Mitosis.experiment_enabled in

  let diff_marker default_val env_val =
    if Float.abs (default_val -. env_val) > 0.001 then " [OVERRIDDEN]" else ""
  in

  Printf.printf "    %-40s %.0f s%s\n" "MASC_MITOSIS_INTERVAL_SEC" env_interval (diff_marker 300.0 env_interval);
  Printf.printf "    %-40s %.0f s%s\n" "MASC_MITOSIS_HANDOFF_COOLDOWN_SEC" env_cooldown (diff_marker 60.0 env_cooldown);
  Printf.printf "    %-40s %b%s\n" "MASC_MITOSIS_EXPERIMENT_ENABLED" env_experiment (if env_experiment then " [OVERRIDDEN]" else "");
  Printf.printf "\n";

  Printf.printf "  Active config (default_config):\n";
  Printf.printf "    triggers:             %d configured\n" (List.length default_config.triggers);
  List.iter (fun t ->
    Printf.printf "      - %s\n" (Yojson.Safe.to_string (trigger_to_json t))
  ) default_config.triggers;
  Printf.printf "    stem_pool_size:       %d\n" default_config.stem_pool_size;
  Printf.printf "    max_generation:       %d\n" default_config.max_generation;
  Printf.printf "    dna_compression_ratio: %.2f\n" default_config.dna_compression_ratio;
  Printf.printf "    apoptosis_delay:      %.1f s\n" default_config.apoptosis_delay;
  Printf.printf "    prepare_threshold:    %.2f (%.0f%%)\n" default_config.prepare_threshold (default_config.prepare_threshold *. 100.0);
  Printf.printf "    handoff_threshold:    %.2f (%.0f%%)\n" default_config.handoff_threshold (default_config.handoff_threshold *. 100.0);
  Printf.printf "    min_context_for_delta: %d chars\n" default_config.min_context_for_delta;
  Printf.printf "    min_delta_len:        %d chars\n" default_config.min_delta_len;
  `Ok ()

(* ================================================================ *)
(* Cmdliner terms                                                   *)
(* ================================================================ *)

(* -- validate -- *)
let dna_arg =
  let doc = "DNA content string to validate." in
  Arg.(value & opt (some string) None & info ["dna"] ~docv:"TEXT" ~doc)

let file_arg =
  let doc = "Path to file containing DNA content." in
  Arg.(value & opt (some string) None & info ["file"; "f"] ~docv:"PATH" ~doc)

let validate_term = Term.(ret (const run_validate $ dna_arg $ file_arg))

let validate_info =
  let doc = "Validate DNA content quality." in
  let man = [
    `S Manpage.s_description;
    `P "Run DNA quality validation with detailed stats.";
    `P "Provide DNA via --dna <text> or --file <path>.";
  ] in
  Cmd.info "validate" ~doc ~man

let validate_cmd = Cmd.v validate_info validate_term

(* -- simulate -- *)
let generations_arg =
  let doc = "Number of generations to simulate." in
  Arg.(value & opt int 3 & info ["generations"; "g"] ~docv:"N" ~doc)

let prepare_threshold_arg =
  let doc = "Context ratio to trigger DNA preparation (0.0-1.0)." in
  Arg.(value & opt float 0.5 & info ["prepare-threshold"] ~docv:"FLOAT" ~doc)

let handoff_threshold_arg =
  let doc = "Context ratio to trigger handoff (0.0-1.0)." in
  Arg.(value & opt float 0.8 & info ["handoff-threshold"] ~docv:"FLOAT" ~doc)

let simulate_term =
  Term.(ret (const run_simulate $ generations_arg $ prepare_threshold_arg $ handoff_threshold_arg))

let simulate_info =
  let doc = "Simulate mitosis state machine lifecycle." in
  let man = [
    `S Manpage.s_description;
    `P "Walk through the full mitosis lifecycle for N generations:";
    `P "Stem -> Active -> Prepared -> Dividing -> Apoptotic";
  ] in
  Cmd.info "simulate" ~doc ~man

let simulate_cmd = Cmd.v simulate_info simulate_term

(* -- config -- *)
let config_term = Term.(ret (const run_config $ const ()))

let config_info =
  let doc = "Show current mitosis configuration." in
  let man = [
    `S Manpage.s_description;
    `P "Display all Defaults values, env var overrides, and active config.";
  ] in
  Cmd.info "config" ~doc ~man

let config_cmd = Cmd.v config_info config_term

(* -- main -- *)
let main_info =
  let doc = "Mitosis testing and debugging CLI." in
  let man = [
    `S Manpage.s_description;
    `P "Standalone tool for testing and debugging the MASC mitosis system.";
    `P "The mitosis system handles agent cell division with states:";
    `P "Stem -> Active -> Prepared -> Dividing -> Apoptotic";
  ] in
  Cmd.info "masc-mitosis-cli" ~version:"0.5.0" ~doc ~man

let () =
  let main_cmd = Cmd.group main_info [validate_cmd; simulate_cmd; config_cmd] in
  exit (Cmd.eval main_cmd)
