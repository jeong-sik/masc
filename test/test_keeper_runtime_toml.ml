(** Tests for [Keeper_runtime_config] — per-base-path keeper runtime
    tuning loaded from [<resolved config root>/keeper_runtime.toml].

    Uses [resolve_overrides] with injected env_lookup to avoid global
    process env dependence. The load_and_apply integration path records
    values in the process-local boot override store. *)

open Alcotest
open Masc_mcp

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

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
;;

let write_toml base_path content =
  let path = Filename.concat base_path ".masc/config/keeper_runtime.toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

(* Fake env: always returns None (env is "empty"). *)
let empty_env _name = None

(* Fake env with specific vars set. *)
let env_with vars name = List.assoc_opt name vars

(* Parse TOML content into a doc, or fail the test. *)
let parse_or_fail content =
  match Keeper_toml_loader.parse_toml content with
  | Ok doc -> doc
  | Error msg -> failf "TOML parse failed: %s" msg
;;

let with_clean_boot_overrides f =
  Config_boot_overrides.reset_for_tests ();
  Keeper_runtime_resolved.reset_for_tests ();
  Fun.protect
    ~finally:(fun () ->
      Config_boot_overrides.reset_for_tests ();
      Keeper_runtime_resolved.reset_for_tests ())
    f
;;

(* --- Tests using resolve_overrides (pure, no env side effects) --- *)

let test_missing_file_returns_zero () =
  with_base_path
  @@ fun base_path ->
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok 0 -> ()
  | Ok n -> failf "expected 0 overrides, got %d" n
  | Error msg -> failf "unexpected error: %s" msg
;;

let test_missing_file_keeps_cost_gate_disabled_by_default () =
  with_clean_boot_overrides
  @@ fun () ->
  with_base_path
  @@ fun base_path ->
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "unexpected error: %s" msg
  | Ok _ ->
    check
      (option (float 0.0001))
      "cost gate disabled by default"
      None
      (Keeper_config.keeper_tool_cost_max_usd ())
;;

let test_applies_autonomous_max_turns () =
  let doc = parse_or_fail "[autonomous]\nmax_turns_per_call = 7\n" in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied count" 1 count;
  check
    (option string)
    "env var mapped"
    (Some "7")
    (List.assoc_opt "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS" overrides)
;;

let test_applies_multiple_overrides () =
  let doc =
    parse_or_fail
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
  check
    (option string)
    "autonomous max_turns"
    (Some "7")
    (List.assoc_opt "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS" overrides);
  check
    (option string)
    "semaphore timeout"
    (Some "150")
    (List.assoc_opt "MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC" overrides);
  check
    (option string)
    "reactive max_turns"
    (Some "20")
    (List.assoc_opt "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL" overrides)
;;

let test_applies_turn_execution_overrides () =
  let doc =
    parse_or_fail
      "[turn]\n\
       tool_cost_max_usd = 1.25\n\
       max_tools_per_turn = 64\n\
       llm_rerank = true\n\
       llm_rerank_cascade = \"tool_rerank_fast\"\n\
       temperature = 0.65\n\
       max_output_tokens = 8192\n"
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc
  in
  check int "applied 6" 6 count;
  check
    (option string)
    "tool cost ceiling"
    (Some "1.25")
    (List.assoc_opt "MASC_KEEPER_TOOL_COST_MAX_USD" overrides);
  check
    (option string)
    "max tools per turn"
    (Some "64")
    (List.assoc_opt "MASC_KEEPER_MAX_TOOLS_PER_TURN" overrides);
  check
    (option string)
    "llm rerank"
    (Some "true")
    (List.assoc_opt "MASC_KEEPER_LLM_RERANK" overrides);
  check
    (option string)
    "llm rerank cascade"
    (Some "tool_rerank_fast")
    (List.assoc_opt "MASC_KEEPER_LLM_RERANK_CASCADE" overrides);
  check
    (option string)
    "temperature"
    (Some "0.65")
    (List.assoc_opt "MASC_KEEPER_UNIFIED_TEMP" overrides);
  check
    (option string)
    "max output tokens"
    (Some "8192")
    (List.assoc_opt "MASC_KEEPER_UNIFIED_MAX_TOKENS" overrides)
;;

let test_caller_env_wins_over_toml () =
  let doc = parse_or_fail "[autonomous]\nmax_turns_per_call = 7\n" in
  let fake_env =
    env_with [ "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS", "3" ]
  in
  let count, overrides =
    Keeper_runtime_config.resolve_overrides ~env_lookup:fake_env doc
  in
  check int "applied 0 (env preempts)" 0 count;
  check int "no overrides" 0 (List.length overrides)
;;

let test_unknown_keys_ignored () =
  let doc =
    parse_or_fail
      "[autonomous]\n\
       max_turns_per_call = 7\n\
       unknown_field = \"ignored\"\n\
       [future_section]\n\
       some_key = 42\n"
  in
  let count, _ = Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc in
  check int "only known keys applied" 1 count
;;

let test_parse_error_returns_error () =
  with_base_path
  @@ fun base_path ->
  write_toml base_path "this is not valid TOML [[[\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok _ -> fail "expected parse error"
  | Error _ -> ()
;;

let test_load_and_apply_records_boot_override () =
  match Sys.getenv_opt "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD" with
  | Some _ -> ()
  | None ->
    with_clean_boot_overrides
    @@ fun () ->
    with_base_path
    @@ fun base_path ->
    write_toml base_path "[budget]\ndaily_usd = 0.42\n";
    (match Keeper_runtime_config.load_and_apply ~base_path with
     | Error msg -> failf "unexpected error: %s" msg
     | Ok n ->
       check int "applied count" 1 n;
       check
         (option string)
         "boot override stored"
         (Some "0.42")
         (Config_boot_overrides.get_opt "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD");
       check
         (float 0.0001)
         "env-backed reader sees boot override"
         0.42
         (Env_config_keeper.KeeperRuntime.deliberation_daily_budget_usd ()))
;;

let test_load_and_apply_records_turn_cost_override () =
  with_clean_boot_overrides
  @@ fun () ->
  with_base_path
  @@ fun base_path ->
  write_toml base_path "[turn]\ntool_cost_max_usd = 1.25\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "unexpected error: %s" msg
  | Ok n ->
    check int "applied count" 1 n;
    check
      (option string)
      "boot override stored"
      (Some "1.25")
      (Config_boot_overrides.get_opt "MASC_KEEPER_TOOL_COST_MAX_USD")
;;

let test_load_and_apply_records_disabled_turn_cost_override () =
  with_clean_boot_overrides
  @@ fun () ->
  with_base_path
  @@ fun base_path ->
  write_toml base_path "[turn]\ntool_cost_max_usd = 0\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "unexpected error: %s" msg
  | Ok n ->
    check int "applied count" 1 n;
    check
      (option string)
      "boot override stored"
      (Some "0")
      (Config_boot_overrides.get_opt "MASC_KEEPER_TOOL_COST_MAX_USD");
    check
      (option (float 0.0001))
      "cost gate disabled"
      None
      (Keeper_config.keeper_tool_cost_max_usd ())
;;

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
;;

let test_explicit_config_dir_wins_over_base_path () =
  with_clean_boot_overrides
  @@ fun () ->
  with_base_path
  @@ fun base_path ->
  with_base_path
  @@ fun override_root ->
  write_toml base_path "[budget]\ndaily_usd = 0.42\n";
  write_toml override_root "[budget]\ndaily_usd = 0.99\n";
  let override_config_dir = Filename.concat override_root ".masc/config" in
  with_env "MASC_CONFIG_DIR" (Some override_config_dir)
  @@ fun () ->
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "unexpected error: %s" msg
  | Ok n ->
    check int "applied count" 1 n;
    check
      (option string)
      "explicit config dir stored"
      (Some "0.99")
      (Config_boot_overrides.get_opt "MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD")
;;

let test_float_value_round_trip () =
  let doc = parse_or_fail "[autonomous]\nsemaphore_wait_timeout_sec = 120.5\n" in
  let _, overrides = Keeper_runtime_config.resolve_overrides ~env_lookup:empty_env doc in
  check
    (option string)
    "float preserved"
    (Some "120.5")
    (List.assoc_opt "MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC" overrides)
;;

let test_resolved_runtime_freezes_toml_values_after_init () =
  with_clean_boot_overrides
  @@ fun () ->
  with_base_path
  @@ fun base_path ->
  write_toml base_path "[turn]\ntimeout_sec = 1500\n[reactive]\nmax_turns_per_call = 12\n";
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" msg
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  Config_boot_overrides.set "MASC_KEEPER_TURN_TIMEOUT_SEC" "900";
  Config_boot_overrides.set "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL" "4";
  let runtime = Keeper_runtime_resolved.current () in
  check
    (float 0.0001)
    "turn timeout frozen from toml"
    1500.0
    runtime.turn_timeout_sec.value;
  check
    string
    "turn timeout source"
    "toml"
    (Keeper_runtime_resolved.source_to_string runtime.turn_timeout_sec.source);
  check
    int
    "reactive max turns frozen from toml"
    12
    runtime.reactive_max_turns_per_call.value
;;

let test_resolved_runtime_accepts_max_turns_ceiling () =
  with_clean_boot_overrides
  @@ fun () ->
  Config_boot_overrides.set "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL" "100";
  Config_boot_overrides.set
    "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS"
    "100";
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check int "reactive max turns accepts 100" 100 runtime.reactive_max_turns_per_call.value;
  check
    int
    "autonomous max turns accepts 100"
    100
    runtime.autonomous_max_turns_per_call.value
;;

let test_resolved_runtime_prefers_env_over_toml () =
  with_clean_boot_overrides
  @@ fun () ->
  with_base_path
  @@ fun base_path ->
  write_toml base_path "[turn]\ntimeout_sec = 1500\n";
  with_env "MASC_KEEPER_TURN_TIMEOUT_SEC" (Some "777")
  @@ fun () ->
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Error msg -> failf "unexpected error: %s" msg
   | Ok _ -> ());
  Keeper_runtime_resolved.init ();
  let runtime = Keeper_runtime_resolved.current () in
  check (float 0.0001) "env timeout wins" 777.0 runtime.turn_timeout_sec.value;
  check
    string
    "env source"
    "env"
    (Keeper_runtime_resolved.source_to_string runtime.turn_timeout_sec.source)
;;

let () =
  run
    "keeper_runtime_toml"
    [ ( "resolve_overrides"
      , [ test_case
            "missing file returns 0 overrides"
            `Quick
            test_missing_file_returns_zero
        ; test_case
            "missing file keeps cost gate disabled by default"
            `Quick
            test_missing_file_keeps_cost_gate_disabled_by_default
        ; test_case
            "applies autonomous max_turns_per_call"
            `Quick
            test_applies_autonomous_max_turns
        ; test_case "applies multiple overrides" `Quick test_applies_multiple_overrides
        ; test_case
            "applies turn execution overrides"
            `Quick
            test_applies_turn_execution_overrides
        ; test_case "caller env wins over TOML" `Quick test_caller_env_wins_over_toml
        ; test_case "unknown keys ignored" `Quick test_unknown_keys_ignored
        ; test_case "parse error returns Error" `Quick test_parse_error_returns_error
        ; test_case
            "load_and_apply records boot override"
            `Quick
            test_load_and_apply_records_boot_override
        ; test_case
            "load_and_apply records turn cost override"
            `Quick
            test_load_and_apply_records_turn_cost_override
        ; test_case
            "load_and_apply records disabled turn cost override"
            `Quick
            test_load_and_apply_records_disabled_turn_cost_override
        ; test_case
            "explicit MASC_CONFIG_DIR wins over base path"
            `Quick
            test_explicit_config_dir_wins_over_base_path
        ; test_case "float value round trip" `Quick test_float_value_round_trip
        ; test_case
            "resolved runtime freezes toml values after init"
            `Quick
            test_resolved_runtime_freezes_toml_values_after_init
        ; test_case
            "resolved runtime accepts max_turns ceiling"
            `Quick
            test_resolved_runtime_accepts_max_turns_ceiling
        ; test_case
            "resolved runtime prefers env over toml"
            `Quick
            test_resolved_runtime_prefers_env_over_toml
        ] )
    ]
;;
