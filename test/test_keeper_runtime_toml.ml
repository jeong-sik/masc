(** Tests for [Keeper_runtime_config] — per-base-path keeper runtime
    tuning loaded from [<resolved config root>/keeper_runtime.toml].

    Uses [resolve_overrides] with injected env_lookup to avoid global
    process env dependence. The load_and_apply integration path records
    values in the process-local boot override store. *)

open Alcotest
open Masc_mcp

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_base_path f =
  let dir = Filename.temp_file "keeper-runtime-toml" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Unix.mkdir (Filename.concat dir Common.masc_dirname) 0o755;
  Unix.mkdir (Filename.concat dir ".masc/config") 0o755;
  let oc = open_out (Filename.concat dir ".masc/config/cascade.json") in
  output_string oc "{}\n";
  close_out oc;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_toml base_path content =
  let path = Filename.concat base_path ".masc/config/keeper_runtime.toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc

(* Fake env: always returns None (env is "empty"). *)
let empty_env _name = None

(* Fake env with specific vars set. *)
let env_with vars name = List.assoc_opt name vars

(* Parse TOML content into a doc, or fail the test. *)
let parse_or_fail content =
  match Keeper_toml_loader.parse_toml content with
  | Ok doc -> doc
  | Error msg -> failf "TOML parse failed: %s" msg

let with_clean_boot_overrides f =
  Config_boot_overrides.reset_for_tests ();
  Keeper_runtime_resolved.reset_for_tests ();
  Fun.protect
    ~finally:(fun () ->
      Config_boot_overrides.reset_for_tests ();
      Keeper_runtime_resolved.reset_for_tests ())
    f

(* --- Tests using resolve_overrides (pure, no env side effects) --- *)

let test_missing_file_returns_zero () =
  with_base_path @@ fun base_path ->
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok 0 -> ()
  | Ok n -> failf "expected 0 overrides, got %d" n
  | Error msg -> failf "unexpected error: %s" msg

let test_missing_file_keeps_cost_gate_disabled_by_default () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "unexpected error: %s" msg
  | Ok _ ->
    check (option (float 0.0001)) "cost gate disabled by default"
      None
      (Keeper_config.keeper_tool_cost_max_usd ())

let test_applies_autonomous_max_turns () =
  let doc = parse_or_fail "[autonomous]\nmax_turns_per_call = 7\n" in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied count" 1 count;
  check (option string) "env var mapped"
    (Some "7")
    (List.assoc_opt
       "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS"
       overrides)

let test_applies_multiple_overrides () =
  let doc = parse_or_fail
    "[autonomous]\n\
     max_turns_per_call = 7\n\
     semaphore_wait_timeout_sec = 150\n\
     [reactive]\n\
     max_turns_per_call = 20\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied 3" 3 count;
  check (option string) "autonomous max_turns"
    (Some "7")
    (List.assoc_opt
       "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS"
       overrides);
  check (option string) "semaphore timeout"
    (Some "150")
    (List.assoc_opt "MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC" overrides);
  check (option string) "reactive max_turns"
    (Some "20")
    (List.assoc_opt "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL" overrides)

let test_applies_sleep_and_throttle_overrides () =
  let doc = parse_or_fail
    "[bootstrap]\n\
     autoboot_max = 6\n\
     [autonomous]\n\
     concurrency = 2\n\
     slot_wait_timeout_sec = 45\n\
     fairness_cooldown_sec = 3\n\
     [reactive]\n\
     concurrency = 4\n\
     [heartbeat]\n\
     sleep_chunk_sec = 1.5\n\
     board_debounce_sec = 30\n\
     board_generic_wakeup_limit = 5\n\
     board_wakeup_max = 6\n\
     [turn]\n\
     admission_wait_timeout_sec = 20\n\
     batch_limit = 9\n\
     board_event_limit = 7\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied sleep/throttle overrides" 12 count;
  check (option string) "autoboot max canonical env"
    (Some "6")
    (List.assoc_opt "MASC_KEEPER_AUTOBOOT_MAX" overrides);
  check (option string) "autonomous concurrency"
    (Some "2")
    (List.assoc_opt "MASC_KEEPER_AUTONOMOUS_CONCURRENCY" overrides);
  check (option string) "autonomous slot wait"
    (Some "45")
    (List.assoc_opt "MASC_KEEPER_AUTONOMOUS_SLOT_WAIT_TIMEOUT_SEC" overrides);
  check (option string) "autonomous fairness cooldown"
    (Some "3")
    (List.assoc_opt "MASC_KEEPER_AUTONOMOUS_FAIRNESS_COOLDOWN_SEC" overrides);
  check (option string) "reactive concurrency"
    (Some "4")
    (List.assoc_opt "MASC_KEEPER_REACTIVE_CONCURRENCY" overrides);
  check (option string) "sleep chunk"
    (Some "1.5")
    (List.assoc_opt "MASC_KEEPER_SLEEP_CHUNK_SEC" overrides);
  check (option string) "board debounce"
    (Some "30")
    (List.assoc_opt "MASC_KEEPER_BOARD_DEBOUNCE_SEC" overrides);
  check (option string) "board generic wakeup limit"
    (Some "5")
    (List.assoc_opt "MASC_KEEPER_BOARD_GENERIC_WAKEUP_LIMIT" overrides);
  check (option string) "board wakeup max"
    (Some "6")
    (List.assoc_opt "MASC_KEEPER_BOARD_WAKEUP_MAX" overrides);
  check (option string) "admission wait"
    (Some "20")
    (List.assoc_opt "MASC_KEEPER_ADMISSION_WAIT_TIMEOUT_SEC" overrides);
  check (option string) "batch limit"
    (Some "9")
    (List.assoc_opt "MASC_KEEPER_BATCH_LIMIT" overrides);
  check (option string) "board event limit"
    (Some "7")
    (List.assoc_opt "MASC_KEEPER_BOARD_EVENT_LIMIT" overrides)

let test_applies_turn_execution_overrides () =
  let doc = parse_or_fail
    "[turn]\n\
     tool_cost_max_usd = 1.25\n\
     max_tools_per_turn = 64\n\
     llm_rerank = true\n\
     llm_rerank_cascade = \"tool_rerank_fast\"\n\
     temperature = 0.65\n\
     max_output_tokens = 8192\n\
     stream_idle_timeout_sec = 90\n\
     oas_timeout_budget_strike_limit = 5\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied 8" 8 count;
  check (option string) "tool cost ceiling"
    (Some "1.25")
    (List.assoc_opt "MASC_KEEPER_TOOL_COST_MAX_USD" overrides);
  check (option string) "max tools per turn"
    (Some "64")
    (List.assoc_opt "MASC_KEEPER_MAX_TOOLS_PER_TURN" overrides);
  check (option string) "llm rerank"
    (Some "true")
    (List.assoc_opt "MASC_KEEPER_LLM_RERANK" overrides);
  check (option string) "llm rerank cascade"
    (Some "tool_rerank_fast")
    (List.assoc_opt "MASC_KEEPER_LLM_RERANK_CASCADE" overrides);
  check (option string) "temperature"
    (Some "0.65")
    (List.assoc_opt "MASC_KEEPER_UNIFIED_TEMP" overrides);
  check (option string) "max output tokens"
    (Some "8192")
    (List.assoc_opt "MASC_KEEPER_UNIFIED_MAX_TOKENS" overrides);
  check (option string) "stream idle timeout"
    (Some "90")
    (List.assoc_opt "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" overrides);
  check (option string) "oas timeout budget strike limit"
    (Some "5")
    (List.assoc_opt
       "MASC_KEEPER_OAS_TIMEOUT_BUDGET_STRIKE_LIMIT"
       overrides)

let test_applies_proactive_min_interval_override () =
  let doc = parse_or_fail "[proactive]\nmin_interval_sec = 1234\n" in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied count" 1 count;
  check (option string) "proactive min interval"
    (Some "1234")
    (List.assoc_opt "MASC_KEEPER_PROACTIVE_MIN_INTERVAL_SEC" overrides)

let test_applies_watchdog_overrides () =
  let doc = parse_or_fail
    "[watchdog]\n\
     stale_sec = 600\n\
     poll_sec = 15\n\
     noop_threshold = 4\n\
     grace_sec = 900\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied 4" 4 count;
  check (option string) "watchdog stale threshold"
    (Some "600")
    (List.assoc_opt "MASC_KEEPER_WATCHDOG_STALE_SEC" overrides);
  check (option string) "watchdog poll"
    (Some "15")
    (List.assoc_opt "MASC_KEEPER_WATCHDOG_POLL_SEC" overrides);
  check (option string) "watchdog noop threshold"
    (Some "4")
    (List.assoc_opt "MASC_KEEPER_WATCHDOG_NOOP_THRESHOLD" overrides);
  check (option string) "watchdog grace"
    (Some "900")
    (List.assoc_opt "MASC_KEEPER_WATCHDOG_GRACE_SEC" overrides)

let test_applies_memory_overrides () =
  let doc = parse_or_fail
    "[memory]\n\
     max_notes = 321\n\
     compact_trigger_bytes = 234567\n\
     max_length = 2048\n\
     placeholders = \"custom-empty,custom-none\"\n\
     consensus_pattern = \"CUSTOMBLOCK\"\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied 5" 5 count;
  check (option string) "memory max notes"
    (Some "321")
    (List.assoc_opt "MASC_KEEPER_MEMORY_MAX_NOTES" overrides);
  check (option string) "memory trigger bytes"
    (Some "234567")
    (List.assoc_opt "MASC_KEEPER_MEMORY_COMPACT_TRIGGER_BYTES" overrides);
  check (option string) "memory max length"
    (Some "2048")
    (List.assoc_opt "MASC_KEEPER_MEMORY_MAX_LENGTH" overrides);
  check (option string) "memory placeholders"
    (Some "custom-empty,custom-none")
    (List.assoc_opt "MASC_KEEPER_MEMORY_PLACEHOLDERS" overrides);
  check (option string) "memory consensus pattern"
    (Some "CUSTOMBLOCK")
    (List.assoc_opt "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN" overrides)

let test_memory_bank_reads_boot_override_knobs () =
  let env_names =
    [
      "MASC_KEEPER_MEMORY_MAX_NOTES";
      "MASC_KEEPER_MEMORY_COMPACT_TRIGGER_BYTES";
      "MASC_KEEPER_MEMORY_MAX_LENGTH";
      "MASC_KEEPER_MEMORY_PLACEHOLDERS";
      "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN";
    ]
  in
  if List.exists (fun name -> Sys.getenv_opt name <> None) env_names then
    skip ()
  else
  with_clean_boot_overrides @@ fun () ->
  Config_boot_overrides.set "MASC_KEEPER_MEMORY_MAX_NOTES" "321";
  Config_boot_overrides.set "MASC_KEEPER_MEMORY_COMPACT_TRIGGER_BYTES" "234567";
  Config_boot_overrides.set "MASC_KEEPER_MEMORY_MAX_LENGTH" "2048";
  Config_boot_overrides.set "MASC_KEEPER_MEMORY_PLACEHOLDERS" "custom-empty";
  Config_boot_overrides.set "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN" "CUSTOMBLOCK";
  check int "target notes from boot override"
    321
    (Keeper_memory_bank.memory_compaction_target_notes ());
  check int "trigger bytes from boot override"
    234567
    (Keeper_memory_bank.memory_compaction_trigger_bytes ~target_notes:321);
  check int "max text length from boot override"
    2048
    (Keeper_memory_bank.max_memory_text_length ());
  check bool "placeholder from boot override"
    true
    (List.mem "custom-empty" (Keeper_memory_bank.memory_placeholders ()));
  check string "consensus pattern from boot override"
    "CUSTOMBLOCK"
    (Keeper_memory_bank.consensus_pattern_key ())

let test_caller_env_wins_over_toml () =
  let doc = parse_or_fail "[autonomous]\nmax_turns_per_call = 7\n" in
  let fake_env =
    env_with
      [("MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS", "3")]
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:fake_env doc
  in
  check int "applied 0 (env preempts)" 0 count;
  check int "no overrides" 0 (List.length overrides)

let test_deprecated_autoboot_env_wins_over_toml () =
  let doc = parse_or_fail "[bootstrap]\nautoboot_max = 12\n" in
  let fake_env = env_with [("MASC_KEEPER_AUTOBOT_MAX", "2")] in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:fake_env doc
  in
  check int "applied 0 (deprecated env preempts canonical TOML)" 0 count;
  check int "no overrides" 0 (List.length overrides)

let test_unknown_keys_ignored () =
  let doc = parse_or_fail
    "[autonomous]\n\
     max_turns_per_call = 7\n\
     unknown_field = \"ignored\"\n\
     [future_section]\n\
     some_key = 42\n"
  in
  let count, _ =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "only known keys applied" 1 count

let test_parse_error_returns_error () =
  with_base_path @@ fun base_path ->
  write_toml base_path "this is not valid TOML [[[\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok _ -> fail "expected parse error"
  | Error _ -> ()

let test_load_and_apply_records_boot_override () =
  match Sys.getenv_opt "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD" with
  | Some _ -> ()
  | None ->
    with_clean_boot_overrides @@ fun () ->
    with_base_path @@ fun base_path ->
    write_toml base_path "[budget]\ndaily_usd = 0.42\n";
    match Keeper_runtime_config.load_and_apply ~base_path with
    | Error msg -> failf "unexpected error: %s" msg
    | Ok n ->
      check int "applied count" 1 n;
      check (option string) "boot override stored"
        (Some "0.42")
        (Config_boot_overrides.get_opt "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD");
      check (float 0.0001) "env-backed reader sees boot override"
        0.42
        (Env_config_keeper.KeeperRuntime.deliberation_daily_budget_usd ())

let test_load_and_apply_records_turn_cost_override () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\ntool_cost_max_usd = 1.25\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "unexpected error: %s" msg
  | Ok n ->
    check int "applied count" 1 n;
    check (option string) "boot override stored"
      (Some "1.25")
      (Config_boot_overrides.get_opt "MASC_KEEPER_TOOL_COST_MAX_USD")

let test_load_and_apply_records_disabled_turn_cost_override () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\ntool_cost_max_usd = 0\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "unexpected error: %s" msg
  | Ok n ->
    check int "applied count" 1 n;
    check (option string) "boot override stored"
      (Some "0")
      (Config_boot_overrides.get_opt "MASC_KEEPER_TOOL_COST_MAX_USD");
    check (option (float 0.0001)) "cost gate disabled"
      None
      (Keeper_config.keeper_tool_cost_max_usd ())

let with_env name value f =
  let prev = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let test_explicit_config_dir_wins_over_base_path () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  with_base_path @@ fun override_root ->
  write_toml base_path "[budget]\ndaily_usd = 0.42\n";
  write_toml override_root "[budget]\ndaily_usd = 0.99\n";
  let override_config_dir = Filename.concat override_root ".masc/config" in
  with_env "MASC_CONFIG_DIR" (Some override_config_dir) @@ fun () ->
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "unexpected error: %s" msg
  | Ok n ->
    check int "applied count" 1 n;
    check (option string) "explicit config dir stored"
      (Some "0.99")
      (Config_boot_overrides.get_opt "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD")

let test_float_value_round_trip () =
  let doc = parse_or_fail
    "[autonomous]\nsemaphore_wait_timeout_sec = 120.5\n"
  in
  let _, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check (option string) "float preserved"
    (Some "120.5")
    (List.assoc_opt "MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC" overrides)

let test_resolved_runtime_freezes_toml_values_after_init () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path
    "[turn]\n\
     timeout_sec = 500\n\
     [reactive]\n\
     max_turns_per_call = 12\n";
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" msg
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  Config_boot_overrides.set "MASC_KEEPER_TURN_TIMEOUT_SEC" "900";
  Config_boot_overrides.set "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL" "4";
  let runtime = Keeper_runtime_resolved.current () in
  check (float 0.0001) "turn timeout frozen from toml"
    500.0 runtime.turn_timeout_sec.value;
  check string "turn timeout source"
    "toml"
    (Keeper_runtime_resolved.source_to_string runtime.turn_timeout_sec.source);
  check int "reactive max turns frozen from toml"
    12 runtime.reactive_max_turns_per_call.value

let test_resolved_runtime_accepts_max_turns_ceiling () =
  with_clean_boot_overrides @@ fun () ->
  Config_boot_overrides.set "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL" "100";
  Config_boot_overrides.set
    "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS" "100";
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check int "reactive max turns accepts 100"
    100 runtime.reactive_max_turns_per_call.value;
  check int "autonomous max turns accepts 100"
    100 runtime.autonomous_max_turns_per_call.value

let test_resolved_stream_idle_timeout_defaults_and_clamps_to_total () =
  with_clean_boot_overrides @@ fun () ->
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (float 0.0001) "stream idle timeout default"
    120.0 runtime.stream_idle_timeout_sec.value;
  check string "stream idle timeout default source"
    "default"
    (Keeper_runtime_resolved.source_to_string runtime.stream_idle_timeout_sec.source);
  check (float 0.0001) "stream idle clamps to shorter total"
    60.0
    (Keeper_runtime_resolved.stream_idle_timeout_for_total_timeout
       ~total_timeout_s:60.0);
  check (float 0.0001) "stream idle keeps configured default below total"
    120.0
    (Keeper_runtime_resolved.stream_idle_timeout_for_total_timeout
       ~total_timeout_s:600.0)

let test_resolved_stream_idle_timeout_uses_toml () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nstream_idle_timeout_sec = 75\n";
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" msg
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (float 0.0001) "stream idle timeout from toml"
    75.0 runtime.stream_idle_timeout_sec.value;
  check string "stream idle timeout source"
    "toml"
    (Keeper_runtime_resolved.source_to_string runtime.stream_idle_timeout_sec.source)

let test_resolved_runtime_prefers_env_over_toml () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\ntimeout_sec = 500\n";
  with_env "MASC_KEEPER_TURN_TIMEOUT_SEC" (Some "555") @@ fun () ->
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" msg
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (float 0.0001) "env timeout wins"
    555.0 runtime.turn_timeout_sec.value;
  check string "env source"
    "env"
    (Keeper_runtime_resolved.source_to_string runtime.turn_timeout_sec.source)

let test_resolved_cli_subprocess_idle_default_120s () =
  with_clean_boot_overrides @@ fun () ->
  Keeper_runtime_resolved.init ();
  check (float 0.0001) "cli_subprocess_idle default 120s"
    120.0 (Keeper_runtime_resolved.cli_subprocess_idle_sec ())

let test_resolved_cli_subprocess_idle_clamps_low () =
  with_clean_boot_overrides @@ fun () ->
  with_env "MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC" (Some "1") @@ fun () ->
  Keeper_runtime_resolved.init ();
  check (float 0.0001) "cli_subprocess_idle clamps to 10s floor"
    10.0 (Keeper_runtime_resolved.cli_subprocess_idle_sec ())

let test_resolved_cli_subprocess_idle_clamps_high () =
  with_clean_boot_overrides @@ fun () ->
  with_env "MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC" (Some "9999") @@ fun () ->
  Keeper_runtime_resolved.init ();
  check (float 0.0001) "cli_subprocess_idle clamps to 600s ceiling"
    600.0 (Keeper_runtime_resolved.cli_subprocess_idle_sec ())

let test_resolved_cli_subprocess_idle_from_toml () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\ncli_subprocess_idle_sec = 45\n";
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" msg
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  check (float 0.0001) "cli_subprocess_idle from toml"
    45.0 (Keeper_runtime_resolved.cli_subprocess_idle_sec ())

(* Step 2 (PR #13861 / RFC-0012/0022): the hard ceiling for
   turn_timeout_sec is lifted from 600 s to 900 s so cascades that
   legitimately run 27 B local-LLM turns can opt in via env override.
   The default stays at 600 s so existing remote cascades keep their
   budget unchanged. *)

let test_resolved_turn_timeout_default_stays_600s () =
  with_clean_boot_overrides @@ fun () ->
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (float 0.0001) "turn_timeout default 600s post-lift"
    600.0 runtime.turn_timeout_sec.value

let test_resolved_turn_timeout_accepts_900s_env_override () =
  with_clean_boot_overrides @@ fun () ->
  with_env "MASC_KEEPER_TURN_TIMEOUT_SEC" (Some "900") @@ fun () ->
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (float 0.0001) "env override of 900s passes new ceiling"
    900.0 runtime.turn_timeout_sec.value

let test_resolved_turn_timeout_clamps_above_900s () =
  with_clean_boot_overrides @@ fun () ->
  with_env "MASC_KEEPER_TURN_TIMEOUT_SEC" (Some "1800") @@ fun () ->
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (float 0.0001) "1800s env input clamps to new 900s ceiling"
    900.0 runtime.turn_timeout_sec.value

(* #10388 budget invariant guard: with the lifted 900s ceiling, even
   the maximum permitted turn timeout must still leave room for an
   admission wait (default 180s) plus a minimum useful run (30s). The
   plan-level invariant is
     [turn_timeout - oas_guard >= admission_wait + min_useful_run]
   with [oas_guard = 30] (#10388 origin), [admission_wait = 180] and
   [min_useful_run = 30]. The test fails if a future change shrinks
   the ceiling below 240s (180 + 30 + 30) or expands the admission
   wait default past the budget. *)
let test_budget_invariant_at_minimum_turn_timeout () =
  with_clean_boot_overrides @@ fun () ->
  with_env "MASC_KEEPER_TURN_TIMEOUT_SEC" (Some "240") @@ fun () ->
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  let oas_guard = 30.0 in
  let min_useful_run = 30.0 in
  let admission_wait = runtime.admission_wait_timeout_sec.value in
  let turn_timeout = runtime.turn_timeout_sec.value in
  let budget_remaining =
    turn_timeout -. oas_guard -. admission_wait -. min_useful_run
  in
  check bool "budget invariant holds at 240s lower bound"
    true (budget_remaining >= 0.0)

let () =
  run "keeper_runtime_toml"
    [ ( "resolve_overrides"
      , [ test_case "missing file returns 0 overrides" `Quick test_missing_file_returns_zero
        ; test_case "missing file keeps cost gate disabled by default" `Quick test_missing_file_keeps_cost_gate_disabled_by_default
        ; test_case "applies autonomous max_turns_per_call" `Quick test_applies_autonomous_max_turns
        ; test_case "applies multiple overrides" `Quick test_applies_multiple_overrides
        ; test_case "applies sleep/throttle overrides" `Quick test_applies_sleep_and_throttle_overrides
        ; test_case "applies turn execution overrides" `Quick test_applies_turn_execution_overrides
        ; test_case "applies proactive min interval override" `Quick test_applies_proactive_min_interval_override
        ; test_case "applies watchdog overrides" `Quick test_applies_watchdog_overrides
        ; test_case "applies memory overrides" `Quick test_applies_memory_overrides
        ; test_case "memory bank reads boot override knobs" `Quick test_memory_bank_reads_boot_override_knobs
        ; test_case "caller env wins over TOML" `Quick test_caller_env_wins_over_toml
        ; test_case "deprecated autoboot env wins over TOML" `Quick test_deprecated_autoboot_env_wins_over_toml
        ; test_case "unknown keys ignored" `Quick test_unknown_keys_ignored
        ; test_case "parse error returns Error" `Quick test_parse_error_returns_error
        ; test_case "load_and_apply records boot override" `Quick test_load_and_apply_records_boot_override
        ; test_case "load_and_apply records turn cost override" `Quick test_load_and_apply_records_turn_cost_override
        ; test_case "load_and_apply records disabled turn cost override" `Quick test_load_and_apply_records_disabled_turn_cost_override
        ; test_case "explicit MASC_CONFIG_DIR wins over base path" `Quick test_explicit_config_dir_wins_over_base_path
        ; test_case "float value round trip" `Quick test_float_value_round_trip
        ; test_case "resolved runtime freezes toml values after init" `Quick test_resolved_runtime_freezes_toml_values_after_init
        ; test_case "resolved runtime accepts max_turns ceiling" `Quick test_resolved_runtime_accepts_max_turns_ceiling
        ; test_case "resolved stream idle timeout defaults and clamps to total" `Quick test_resolved_stream_idle_timeout_defaults_and_clamps_to_total
        ; test_case "resolved stream idle timeout uses toml" `Quick test_resolved_stream_idle_timeout_uses_toml
        ; test_case "resolved runtime prefers env over toml" `Quick test_resolved_runtime_prefers_env_over_toml
        ; test_case "cli subprocess idle default 120s" `Quick test_resolved_cli_subprocess_idle_default_120s
        ; test_case "cli subprocess idle from toml" `Quick test_resolved_cli_subprocess_idle_from_toml
        ; test_case "cli subprocess idle clamps to 10s floor" `Quick test_resolved_cli_subprocess_idle_clamps_low
        ; test_case "cli subprocess idle clamps to 600s ceiling" `Quick test_resolved_cli_subprocess_idle_clamps_high
        ; test_case "turn_timeout default stays 600s post-lift" `Quick test_resolved_turn_timeout_default_stays_600s
        ; test_case "turn_timeout accepts 900s env override" `Quick test_resolved_turn_timeout_accepts_900s_env_override
        ; test_case "turn_timeout clamps above 900s ceiling" `Quick test_resolved_turn_timeout_clamps_above_900s
        ; test_case "#10388 budget invariant holds at 240s minimum" `Quick test_budget_invariant_at_minimum_turn_timeout
        ] )
    ]
