(** Tests for [Keeper_runtime_config] — per-base-path keeper runtime
    tuning loaded from [<resolved config root>/runtime.toml].

    Uses [resolve_overrides] with injected env_lookup to avoid global
    process env dependence. The load_and_apply integration path records
    values in the process-local boot override store. *)

open Alcotest
open Masc

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
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_toml base_path content =
  let path =
    Filename.concat
      (Filename.concat base_path ".masc/config")
      Config_dir_resolver.runtime_toml_filename
  in
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


let test_applies_sleep_and_throttle_overrides () =
  let doc = parse_or_fail
    "[bootstrap]\n\
     autoboot_max = 6\n\
     [autonomous]\n\
     fairness_cooldown_sec = 3\n\
     [heartbeat]\n\
     sleep_chunk_sec = 1.5\n\
     board_wakeup_max = 6\n\
     [turn]\n\
     capacity_limit = 3\n\
     batch_limit = 9\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied sleep/throttle overrides" 6 count;
  check (option string) "autoboot max canonical env"
    (Some "6")
    (List.assoc_opt "MASC_KEEPER_AUTOBOOT_MAX" overrides);
  check (option string) "autonomous fairness cooldown"
    (Some "3")
    (List.assoc_opt "MASC_KEEPER_AUTONOMOUS_FAIRNESS_COOLDOWN_SEC" overrides);
  check (option string) "sleep chunk"
    (Some "1.5")
    (List.assoc_opt "MASC_KEEPER_SLEEP_CHUNK_SEC" overrides);
  check (option string) "board wakeup max"
    (Some "6")
    (List.assoc_opt "MASC_KEEPER_BOARD_WAKEUP_MAX" overrides);
  check (option string) "capacity limit"
    (Some "3")
    (List.assoc_opt "MASC_KEEPER_TURN_CAPACITY_LIMIT" overrides);
  check (option string) "batch limit"
    (Some "9")
    (List.assoc_opt "MASC_KEEPER_BATCH_LIMIT" overrides)

let test_applies_turn_execution_overrides () =
  let doc = parse_or_fail
    "[turn]\n\
     temperature = 0.65\n\
     max_output_tokens = 8192\n\
     stream_idle_timeout_sec = 90\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied 3" 3 count;
  check (option string) "temperature"
    (Some "0.65")
    (List.assoc_opt "MASC_KEEPER_UNIFIED_TEMP" overrides);
  check (option string) "max output tokens"
    (Some "8192")
    (List.assoc_opt "MASC_KEEPER_UNIFIED_MAX_TOKENS" overrides);
  check (option string) "stream idle timeout"
    (Some "90")
    (List.assoc_opt "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" overrides)

let test_applies_health_overrides () =
  let doc =
    parse_or_fail
      "[health]\n\
       durable_queue_stale_sec = 45.5\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied health override count" 1 count;
  check (option string) "durable queue stale threshold"
    (Some "45.5")
    (List.assoc_opt "MASC_KEEPER_DURABLE_QUEUE_STALE_SEC" overrides)

(* RFC-0297 P0-1: the three lifecycle kill-switches must map TOML ->
   canonical env instead of being silently dropped. Before the key_to_env
   mappings existed, [reactive]/[proactive]/[autonomous] enabled were never
   visited by load_and_apply and vanished. *)
let test_applies_lifecycle_enabled_overrides () =
  let doc = parse_or_fail
    "[reactive]\n\
     enabled = false\n\
     [proactive]\n\
     enabled = false\n\
     [autonomous]\n\
     enabled = true\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied three lifecycle enabled overrides" 3 count;
  check (option string) "reactive enabled maps to canonical env"
    (Some "false")
    (List.assoc_opt "MASC_KEEPER_REACTIVE_ENABLED" overrides);
  check (option string) "proactive enabled maps to canonical env"
    (Some "false")
    (List.assoc_opt "MASC_KEEPER_PROACTIVE_ENABLED" overrides);
  check (option string) "autonomous enabled maps to canonical env"
    (Some "true")
    (List.assoc_opt "MASC_KEEPER_AUTONOMOUS_ENABLED" overrides)

let test_applies_memory_overrides () =
  let doc = parse_or_fail
    "[memory]\n\
     max_notes = 321\n\
     compact_trigger_bytes = 234567\n\
     max_length = 2048\n\
     placeholders = \"custom-empty,custom-none\"\n\
     consensus_pattern = \"CUSTOMBLOCK\"\n\
     llm_summary = true\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied 6" 6 count;
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
    (List.assoc_opt "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN" overrides);
  check (option string) "memory llm summary"
    (Some "true")
    (List.assoc_opt "MASC_KEEPER_MEMORY_LLM_SUMMARY" overrides)

let test_memory_bank_reads_boot_override_knobs () =
  let env_names =
    [
      "MASC_KEEPER_MEMORY_MAX_NOTES";
      "MASC_KEEPER_MEMORY_COMPACT_TRIGGER_BYTES";
      "MASC_KEEPER_MEMORY_MAX_LENGTH";
      "MASC_KEEPER_MEMORY_PLACEHOLDERS";
      "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN";
      "MASC_KEEPER_MEMORY_LLM_SUMMARY";
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
  Config_boot_overrides.set "MASC_KEEPER_MEMORY_LLM_SUMMARY" "true";
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
    (Keeper_memory_bank.consensus_pattern_key ());
  check bool "llm summary flag from boot override"
    true
    (Keeper_memory_bank.memory_llm_summary_enabled ())

let test_deprecated_autoboot_env_does_not_preempt_toml () =
  let doc = parse_or_fail "[bootstrap]\nautoboot_max = 12\n" in
  let fake_env = env_with [("MASC_KEEPER_AUTOBOT_MAX", "2")] in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:fake_env doc
  in
  check int "applied canonical TOML" 1 count;
  check (option string) "deprecated typo env ignored"
    (Some "12")
    (List.assoc_opt "MASC_KEEPER_AUTOBOOT_MAX" overrides)

let test_parse_error_returns_error () =
  with_base_path @@ fun base_path ->
  write_toml base_path "this is not valid TOML [[[\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok _ -> fail "expected parse error"
  | Error _ -> ()

let test_load_and_apply_records_boot_override () =
  match Sys.getenv_opt "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" with
  | Some _ -> ()
  | None ->
    with_clean_boot_overrides @@ fun () ->
    with_base_path @@ fun base_path ->
    write_toml base_path "[turn]\nstream_idle_timeout_sec = 42\n";
    match Keeper_runtime_config.load_and_apply ~base_path with
    | Error msg -> failf "unexpected error: %s" msg
    | Ok n ->
      check int "applied count" 1 n;
      check (option string) "boot override stored"
        (Some "42")
        (Config_boot_overrides.get_opt "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC");
      Keeper_runtime_resolved.reset_for_tests ();
      check (option (float 0.0001)) "runtime resolver sees boot override"
        (Some 42.0)
        (Keeper_runtime_resolved.stream_idle_timeout_sec ())



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
  write_toml base_path "[turn]\nstream_idle_timeout_sec = 42\n";
  write_toml override_root "[turn]\nstream_idle_timeout_sec = 99\n";
  let override_config_dir = Filename.concat override_root ".masc/config" in
  with_env "MASC_CONFIG_DIR" (Some override_config_dir) @@ fun () ->
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "unexpected error: %s" msg
  | Ok n ->
    check int "applied count" 1 n;
    check (option string) "explicit config dir stored"
      (Some "99")
      (Config_boot_overrides.get_opt "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC")

let test_float_value_round_trip () =
  let doc = parse_or_fail
    "[turn]\nstream_idle_timeout_sec = 120.5\n"
  in
  let _, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check (option string) "float preserved"
    (Some "120.5")
    (List.assoc_opt "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" overrides)

let test_resolved_runtime_freezes_toml_values_after_init () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path
    "[turn]\n\
     stream_idle_timeout_sec = 50\n";
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" msg
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  Config_boot_overrides.set "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" "90";
  let runtime = Keeper_runtime_resolved.current () in
  check (option (float 0.0001)) "stream idle timeout frozen from toml"
    (Some 50.0) runtime.stream_idle_timeout_sec.value;
  check string "stream idle timeout source"
    "toml"
    (Keeper_runtime_resolved.source_to_string runtime.stream_idle_timeout_sec.source)

let test_resolved_stream_idle_timeout_defaults_disabled () =
  with_clean_boot_overrides @@ fun () ->
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (option (float 0.0001)) "stream idle timeout disabled by default"
    None runtime.stream_idle_timeout_sec.value;
  check string "stream idle timeout default source"
    "default"
    (Keeper_runtime_resolved.source_to_string runtime.stream_idle_timeout_sec.source)

let test_resolved_stream_idle_timeout_uses_toml () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nstream_idle_timeout_sec = 75\n";
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" msg
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (option (float 0.0001)) "stream idle timeout from toml"
    (Some 75.0) runtime.stream_idle_timeout_sec.value;
  check string "stream idle timeout source"
    "toml"
    (Keeper_runtime_resolved.source_to_string runtime.stream_idle_timeout_sec.source)

let test_resolved_runtime_prefers_env_over_toml () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nstream_idle_timeout_sec = 50\n";
  with_env "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" (Some "55") @@ fun () ->
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" msg
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (option (float 0.0001)) "env stream idle timeout wins"
    (Some 55.0) runtime.stream_idle_timeout_sec.value;
  check string "env source"
    "env"
    (Keeper_runtime_resolved.source_to_string runtime.stream_idle_timeout_sec.source)

let test_resolved_stream_idle_timeout_does_not_clamp () =
  with_clean_boot_overrides @@ fun () ->
  with_env "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" (Some "3600") @@ fun () ->
  Keeper_runtime_resolved.init ();
  check (option (float 0.0001)) "explicit value is preserved"
    (Some 3600.0)
    (Keeper_runtime_resolved.stream_idle_timeout_sec ())

let expect_stream_idle_timeout_env_config_error raw =
  with_clean_boot_overrides @@ fun () ->
  with_env "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" (Some raw) @@ fun () ->
  match Keeper_runtime_resolved.init () with
  | () -> fail "expected invalid stream idle timeout to fail"
  | exception Env_config_core.Config_error message ->
    check string "diagnostic names the invalid stream idle setting"
      (Printf.sprintf
         "invalid MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC=%S (expected a finite, positive number of seconds)"
         raw)
      message

let test_resolved_stream_idle_timeout_invalid_env_fails_loud () =
  expect_stream_idle_timeout_env_config_error "not-a-timeout"

let test_resolved_stream_idle_timeout_empty_env_fails_loud () =
  expect_stream_idle_timeout_env_config_error ""

let test_resolved_stream_idle_timeout_whitespace_env_fails_loud () =
  expect_stream_idle_timeout_env_config_error "   "

let test_stream_idle_timeout_invalid_toml_returns_error () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nstream_idle_timeout_sec = 0\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok _ -> fail "expected non-positive stream idle timeout to be rejected"
  | Error message ->
    check bool "diagnostic names the TOML key" true
      (String.starts_with ~prefix:"validate " message
       && String.ends_with
            ~suffix:
              "turn.stream_idle_timeout_sec: expected a finite, positive number of seconds"
            message)

let test_stream_idle_timeout_toml_wrong_type_returns_error () =
  with_clean_boot_overrides @@ fun () ->
  with_base_path @@ fun base_path ->
  write_toml base_path "[turn]\nstream_idle_timeout_sec = \"120\"\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok _ -> fail "expected string stream idle timeout to be rejected"
  | Error message ->
    check bool "diagnostic requires a numeric TOML value" true
      (String.ends_with
         ~suffix:
           "turn.stream_idle_timeout_sec: expected a numeric TOML value"
         message)

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

let () =
  run "runtime_toml_overrides"
    [ ( "resolve_overrides"
      , [ test_case "missing file returns 0 overrides" `Quick test_missing_file_returns_zero
        ; test_case "applies sleep/throttle overrides" `Quick test_applies_sleep_and_throttle_overrides
        ; test_case "applies turn execution overrides" `Quick test_applies_turn_execution_overrides
        ; test_case "applies health overrides" `Quick test_applies_health_overrides
        ; test_case "applies lifecycle enabled overrides (RFC-0297 P0-1)" `Quick test_applies_lifecycle_enabled_overrides
        ; test_case "applies memory overrides" `Quick test_applies_memory_overrides
        ; test_case "memory bank reads boot override knobs" `Quick test_memory_bank_reads_boot_override_knobs
        ; test_case
            "deprecated autoboot env does not preempt TOML"
            `Quick
            test_deprecated_autoboot_env_does_not_preempt_toml
        ; test_case "parse error returns Error" `Quick test_parse_error_returns_error
        ; test_case "load_and_apply records boot override" `Quick test_load_and_apply_records_boot_override
        ; test_case "explicit MASC_CONFIG_DIR wins over base path" `Quick test_explicit_config_dir_wins_over_base_path
        ; test_case "float value round trip" `Quick test_float_value_round_trip
        ; test_case "resolved runtime freezes toml values after init" `Quick test_resolved_runtime_freezes_toml_values_after_init
        ; test_case "resolved stream idle timeout defaults disabled" `Quick test_resolved_stream_idle_timeout_defaults_disabled
        ; test_case "resolved stream idle timeout uses toml" `Quick test_resolved_stream_idle_timeout_uses_toml
        ; test_case "invalid stream idle TOML returns Error" `Quick test_stream_idle_timeout_invalid_toml_returns_error
        ; test_case "wrong-type stream idle TOML returns Error" `Quick test_stream_idle_timeout_toml_wrong_type_returns_error
        ; test_case "cli subprocess idle default 120s" `Quick test_resolved_cli_subprocess_idle_default_120s
        ; test_case "cli subprocess idle from toml" `Quick test_resolved_cli_subprocess_idle_from_toml
        ; test_case "cli subprocess idle clamps to 10s floor" `Quick test_resolved_cli_subprocess_idle_clamps_low
        ; test_case "cli subprocess idle clamps to 600s ceiling" `Quick test_resolved_cli_subprocess_idle_clamps_high
        ; test_case "resolved runtime prefers env over toml" `Quick test_resolved_runtime_prefers_env_over_toml
        ; test_case "resolved stream idle timeout does not clamp" `Quick test_resolved_stream_idle_timeout_does_not_clamp
        ; test_case "invalid stream idle env fails loud" `Quick test_resolved_stream_idle_timeout_invalid_env_fails_loud
        ; test_case "empty stream idle env fails loud" `Quick test_resolved_stream_idle_timeout_empty_env_fails_loud
        ; test_case "whitespace stream idle env fails loud" `Quick test_resolved_stream_idle_timeout_whitespace_env_fails_loud
        ] )
    ]
