(** Tests for [Keeper_runtime_config] — per-base-path keeper runtime
    tuning loaded from [<base_path>/.masc/config/keeper_runtime.toml]. *)

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

(* Cleanup helper: env vars we touch must not leak between tests. *)
let env_keys =
  [ "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS"
  ; "MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC"
  ; "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL"
  ]

let unset_all_keys () =
  (* CI may set these env vars globally; we must truly unset (not set to "")
     because [Sys.getenv_opt] treats "" as Some "", which our skip-if-set
     logic interprets as "caller provided it". *)
  List.iter (fun k -> try Unix.unsetenv k with _ -> ()) env_keys

let test_missing_file_returns_zero () =
  unset_all_keys ();
  with_base_path @@ fun base_path ->
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok 0 -> ()
  | Ok n -> failf "expected 0 overrides, got %d" n
  | Error msg -> failf "unexpected error: %s" msg

let test_applies_autonomous_max_turns () =
  unset_all_keys ();
  with_base_path @@ fun base_path ->
  write_toml base_path "[autonomous]\nmax_turns_per_call = 7\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "load failed: %s" msg
  | Ok n ->
    check int "applied count" 1 n;
    let actual =
      Sys.getenv_opt
        "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS"
    in
    check (option string) "env var set" (Some "7") actual

let test_applies_multiple_overrides () =
  unset_all_keys ();
  with_base_path @@ fun base_path ->
  write_toml base_path
    "[autonomous]\n\
     max_turns_per_call = 7\n\
     semaphore_wait_timeout_sec = 150\n\
     [reactive]\n\
     max_turns_per_call = 20\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "load failed: %s" msg
  | Ok n ->
    check int "applied 3" 3 n;
    check (option string) "autonomous max_turns"
      (Some "7")
      (Sys.getenv_opt "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS");
    check (option string) "semaphore timeout"
      (Some "150")
      (Sys.getenv_opt "MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC");
    check (option string) "reactive max_turns"
      (Some "20")
      (Sys.getenv_opt "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL")

let test_caller_env_wins_over_toml () =
  unset_all_keys ();
  with_base_path @@ fun base_path ->
  Unix.putenv "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS" "3";
  write_toml base_path "[autonomous]\nmax_turns_per_call = 7\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "load failed: %s" msg
  | Ok n ->
    check int "applied 0 (env preempts)" 0 n;
    check (option string) "env unchanged"
      (Some "3")
      (Sys.getenv_opt "MASC_KEEPER_OAS_MAX_TURNS_PER_CALL_SCHEDULED_AUTONOMOUS")

let test_unknown_keys_ignored () =
  unset_all_keys ();
  with_base_path @@ fun base_path ->
  write_toml base_path
    "[autonomous]\n\
     max_turns_per_call = 7\n\
     unknown_field = \"ignored\"\n\
     [future_section]\n\
     some_key = 42\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Error msg -> failf "load failed: %s" msg
  | Ok n -> check int "only known keys applied" 1 n

let test_parse_error_returns_error () =
  unset_all_keys ();
  with_base_path @@ fun base_path ->
  write_toml base_path "this is not valid TOML [[[\n";
  match Keeper_runtime_config.load_and_apply ~base_path with
  | Ok _ -> fail "expected parse error"
  | Error _ -> ()

let () =
  run "keeper_runtime_toml"
    [ ( "load_and_apply"
      , [ test_case "missing file returns 0 overrides" `Quick test_missing_file_returns_zero
        ; test_case "applies autonomous max_turns_per_call" `Quick test_applies_autonomous_max_turns
        ; test_case "applies multiple overrides" `Quick test_applies_multiple_overrides
        ; test_case "caller env wins over TOML" `Quick test_caller_env_wins_over_toml
        ; test_case "unknown keys ignored" `Quick test_unknown_keys_ignored
        ; test_case "parse error returns Error" `Quick test_parse_error_returns_error
        ] )
    ]
