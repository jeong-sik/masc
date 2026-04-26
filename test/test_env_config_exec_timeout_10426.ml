(** #10426 P1 — pin the per-caller default table and env override
    behaviour for {!Env_config_exec_timeout}.

    The pattern mirrors {!Env_config_oas_bridge} (#10094); the test
    suite captures three properties:

    1. Hardcoded defaults preserve current literals (regression
       guard against silent budget shifts).
    2. Per-caller env override wins over hardcoded default.
    3. Global env [MASC_EXEC_TIMEOUT_DEFAULT_SEC] only applies to
       [Unknown] callers — not as a global override. *)

open Alcotest

module E = Env_config_exec_timeout

let approx = float 0.001

(* --- 1. Pin per-caller defaults --------------------------- *)

let cases =
  [
    E.Shell, 60.0;
    E.Fs, 30.0;
    E.Preflight, 10.0;
    E.Repo_readiness, 10.0;
    E.Sandbox, 2.0;
    E.Pr_review, 15.0;
    E.Dispatch, 120.0;
    E.Memory_audit, 3.0;
    E.Alerting, 20.0;
    E.Gh_shared, 10.0;
    E.Status_detail, 10.0;
    E.Turn_sandbox, 2.0;
    E.Turn_up, 15.0;
  ]

let test_known_default_pin () =
  List.iter
    (fun (caller, expected) ->
      match E.known_default_sec caller with
      | Some v ->
        check approx
          (Printf.sprintf "%s default" (E.caller_key caller))
          expected v
      | None ->
        failf "expected default for %s, got None" (E.caller_key caller))
    cases

let test_unknown_default_is_none () =
  check (option approx) "Unknown returns None"
    None (E.known_default_sec (E.Unknown "future_caller"))

let test_known_callers_complete () =
  let n_known = List.length (E.known_callers ()) in
  check int "known caller count matches case table"
    (List.length cases) n_known

(* --- 2. Per-caller env override --------------------------- *)

let with_env name value f =
  let prev = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None ->
     (* No portable [unsetenv]; clear by setting empty.
        [trimmed_value_opt] treats "" as unset. *)
     Unix.putenv name "");
  Fun.protect ~finally:(fun () ->
    match prev with
    | Some v -> Unix.putenv name v
    | None -> Unix.putenv name "")
    f

let test_per_caller_env_overrides_default () =
  with_env "MASC_EXEC_TIMEOUT_SHELL_SEC" (Some "7.5") (fun () ->
    check approx "Shell uses env override"
      7.5 (E.timeout_sec ~caller:E.Shell ()));
  (* And the default returns after override is cleared. *)
  check approx "Shell falls back to default"
    60.0 (E.timeout_sec ~caller:E.Shell ())

let test_empty_env_treated_as_unset () =
  with_env "MASC_EXEC_TIMEOUT_FS_SEC" (Some "") (fun () ->
    check approx "Empty env still hits default"
      30.0 (E.timeout_sec ~caller:E.Fs ()))

let test_invalid_env_falls_to_global_default () =
  with_env "MASC_EXEC_TIMEOUT_PREFLIGHT_SEC" (Some "not-a-number") (fun () ->
    (* [float_of_string_with_default] rescues with global default. *)
    check approx "Invalid float -> global_default_sec"
      E.global_default_sec
      (E.timeout_sec ~caller:E.Preflight ()))

(* --- 3. Global env applies only to Unknown ---------------- *)

let test_global_env_only_for_unknown () =
  with_env "MASC_EXEC_TIMEOUT_DEFAULT_SEC" (Some "999.0") (fun () ->
    check approx "Known caller ignores global env"
      60.0 (E.timeout_sec ~caller:E.Shell ());
    check approx "Unknown caller uses global env"
      999.0 (E.timeout_sec ~caller:(E.Unknown "future") ()))

let test_unknown_falls_to_global_default_when_unset () =
  check approx "Unknown without env -> global_default_sec"
    E.global_default_sec
    (E.timeout_sec ~caller:(E.Unknown "another") ())

(* --- 4. Env var name shape -------------------------------- *)

let test_env_var_name_shape () =
  check string "Shell env var name"
    "MASC_EXEC_TIMEOUT_SHELL_SEC"
    (E.per_caller_env_var ~caller:E.Shell);
  check string "Pr_review env var name"
    "MASC_EXEC_TIMEOUT_PR_REVIEW_SEC"
    (E.per_caller_env_var ~caller:E.Pr_review);
  check string "Unknown env var name lowercases"
    "MASC_EXEC_TIMEOUT_FUTURE_X_SEC"
    (E.per_caller_env_var ~caller:(E.Unknown "future-x"))

let () =
  run "env_config_exec_timeout_10426"
    [
      ( "defaults",
        [
          test_case "per-caller defaults pinned" `Quick test_known_default_pin;
          test_case "Unknown default is None" `Quick
            test_unknown_default_is_none;
          test_case "known_callers covers case table" `Quick
            test_known_callers_complete;
        ] );
      ( "env-override",
        [
          test_case "per-caller env wins" `Quick
            test_per_caller_env_overrides_default;
          test_case "empty env treated as unset" `Quick
            test_empty_env_treated_as_unset;
          test_case "invalid env -> global_default_sec" `Quick
            test_invalid_env_falls_to_global_default;
        ] );
      ( "global-env",
        [
          test_case "global env only affects Unknown" `Quick
            test_global_env_only_for_unknown;
          test_case "Unknown without env -> global_default_sec" `Quick
            test_unknown_falls_to_global_default_when_unset;
        ] );
      ( "env-var-name",
        [
          test_case "shape and case" `Quick test_env_var_name_shape;
        ] );
    ]
