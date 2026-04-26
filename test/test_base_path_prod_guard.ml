(* test/test_base_path_prod_guard.ml

   #9903: production-path safeguard for test executables.

   The underlying MASC_BASE_PATH override mechanism has a latent
   failure mode in which a test's [Unix.putenv] does not take
   effect by the time [base_path()] resolves (root cause still
   under investigation). When that failure happens, [base_path()]
   silently falls back to HOME, and the test writes fixture data
   to the production ledger at [~/me/.masc/board_votes.jsonl] —
   the exact corruption observed in #9903's evidence record.

   The guard closes the fallback path for test executables: if
   [base_path()] would return a HOME-prefixed string under a
   test binary, raise [Config_error] so the test crashes loud
   instead of clobbering prod. *)

module EC = Env_config_core

(* Ensure no explicit MASC_BASE_PATH is set — we want the fallback
   path to HOME to trigger the guard. *)
let clear_base_path () =
  Unix.putenv "MASC_BASE_PATH" "";
  Unix.putenv "MASC_BASE_PATH_INPUT" ""
;;

let test_guard_raises_on_home_fallback () =
  clear_base_path ();
  Unix.putenv "MASC_TEST_ALLOW_HOME_BASE_PATH" "";
  (* test_base_path_prod_guard executable has basename "test_...",
     so [running_under_test_executable] returns true. Fallback to
     HOME should now raise. *)
  try
    let path = EC.base_path () in
    Alcotest.failf
      "expected Config_error, got path=%S (HOME=%S)"
      path
      (Option.value ~default:"<unset>" (Sys.getenv_opt "HOME"))
  with
  | EC.Config_error msg ->
    let contains_9903 =
      let m = String.lowercase_ascii msg in
      let rec scan i =
        if i + 5 > String.length m
        then false
        else if String.sub m i 5 = "#9903"
        then true
        else scan (i + 1)
      in
      scan 0
      ||
      (* tolerate case where the phrase appears without the # *)
      let rec f i =
        if i + 4 > String.length m
        then false
        else if String.sub m i 4 = "9903"
        then true
        else f (i + 1)
      in
      f 0
    in
    Alcotest.(check bool) "Config_error message references #9903" true contains_9903
;;

let test_guard_honors_explicit_tmp_override () =
  (* A proper test-time override to /tmp must NOT trigger the guard. *)
  Unix.putenv
    "MASC_BASE_PATH"
    (Filename.concat
       (Filename.get_temp_dir_name ())
       (Printf.sprintf "masc-test-base-path-guard-%d" (Unix.getpid ())));
  Unix.putenv "MASC_TEST_ALLOW_HOME_BASE_PATH" "";
  let path = EC.base_path () in
  let is_tmp =
    let tmp = Filename.get_temp_dir_name () in
    String.length path >= String.length tmp && String.sub path 0 (String.length tmp) = tmp
  in
  Alcotest.(check bool) "tmp-override path returned unchanged" true is_tmp
;;

let test_guard_bypass_escape_hatch () =
  clear_base_path ();
  Unix.putenv "MASC_TEST_ALLOW_HOME_BASE_PATH" "1";
  (* With the escape hatch set, HOME fallback is allowed even under
     a test executable. *)
  let path = EC.base_path () in
  Alcotest.(check bool)
    "escape hatch returns a non-empty path"
    true
    (String.length path > 0);
  Unix.putenv "MASC_TEST_ALLOW_HOME_BASE_PATH" ""
;;

let () =
  Alcotest.run
    "base_path_prod_guard"
    [ ( "#9903 safeguard"
      , [ Alcotest.test_case
            "HOME fallback raises Config_error"
            `Quick
            test_guard_raises_on_home_fallback
        ; Alcotest.test_case
            "explicit /tmp override is allowed"
            `Quick
            test_guard_honors_explicit_tmp_override
        ; Alcotest.test_case
            "MASC_TEST_ALLOW_HOME_BASE_PATH=1 bypass"
            `Quick
            test_guard_bypass_escape_hatch
        ] )
    ]
;;
