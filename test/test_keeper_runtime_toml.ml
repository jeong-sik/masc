(** Tests for [Keeper_runtime_config] — per-base-path keeper runtime
    tuning loaded from [<base_path>/.masc/config/keeper_runtime.toml].

    Uses [resolve_overrides] with injected env_lookup to avoid global
    process env pollution. The load_and_apply integration path (which
    calls Unix.putenv) is tested via missing-file and parse-error paths
    only, since those don't depend on env state. *)

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
  Unix.mkdir (Filename.concat dir ".masc") 0o755;
  Unix.mkdir (Filename.concat dir ".masc/config") 0o755;
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

(* --- Tests using resolve_overrides (pure, no env side effects) --- *)

let test_missing_file_returns_zero () =
  with_base_path @@ fun base_path ->
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok 0 -> ()
  | Ok n -> failf "expected 0 overrides, got %d" n
  | Error msg -> failf "unexpected error: %s" msg

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

let () =
  run "keeper_runtime_toml"
    [ ( "resolve_overrides"
      , [ test_case "missing file returns 0 overrides" `Quick test_missing_file_returns_zero
        ; test_case "applies autonomous max_turns_per_call" `Quick test_applies_autonomous_max_turns
        ; test_case "applies multiple overrides" `Quick test_applies_multiple_overrides
        ; test_case "caller env wins over TOML" `Quick test_caller_env_wins_over_toml
        ; test_case "unknown keys ignored" `Quick test_unknown_keys_ignored
        ; test_case "parse error returns Error" `Quick test_parse_error_returns_error
        ; test_case "float value round trip" `Quick test_float_value_round_trip
        ] )
    ]
