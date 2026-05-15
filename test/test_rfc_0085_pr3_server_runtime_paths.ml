open Alcotest

(** RFC-0085 PR-3 — server runtime path 박멸.

    Verifies:
    - lib/server/server_startup_takeover.ml: "/tmp/masc-" literal = 0
      (PID lock now via host.run_dir).
    - lib/server/server_runtime_bootstrap.ml: Gemini admin-policy literals = 0
      (MASC bootstrap must not encode provider-specific OAS CLI policy).
    - server_startup_takeover invokes Host_config.host >= 1.

    AST-based via Ast_grep, so docstring references do not false-positive. *)

let test_no_tmp_masc_in_takeover () =
  let path = "lib/server/server_startup_takeover.ml" in
  let n = Ast_grep.count_string_literals ~module_path:path ~needle:"/tmp/masc-" in
  check int "/tmp/masc- literals in takeover" 0 n
;;

let test_no_tmp_gemini_in_bootstrap () =
  let path = "lib/server/server_runtime_bootstrap.ml" in
  let n = Ast_grep.count_string_literals ~module_path:path ~needle:"/tmp/gemini" in
  check int "/tmp/gemini literals in runtime_bootstrap" 0 n
;;

let test_no_gemini_specific_policy_wiring () =
  let path = "lib/server/server_runtime_bootstrap.ml" in
  let headless =
    Ast_grep.count_string_literals
      ~module_path:path
      ~needle:"gemini_headless_admin"
  in
  let admin_env =
    Ast_grep.count_string_literals
      ~module_path:path
      ~needle:"OAS_GEMINI_ADMIN_POLICY"
  in
  check int "gemini_headless_admin literals in runtime_bootstrap" 0 headless;
  check int "OAS_GEMINI_ADMIN_POLICY literals in runtime_bootstrap" 0 admin_env
;;

let test_takeover_uses_host_config () =
  let path = "lib/server/server_startup_takeover.ml" in
  let n = Ast_grep.count_calls ~module_path:path ~callee:"Host_config.host" in
  if n < 1 then failf "takeover must call Host_config.host >= 1, got %d" n
;;

let () =
  run
    "rfc-0085-pr-3-server-runtime-paths"
    [ ( "literal purge"
      , [ test_case "no /tmp/masc- in takeover" `Quick test_no_tmp_masc_in_takeover
        ; test_case "no /tmp/gemini in bootstrap" `Quick test_no_tmp_gemini_in_bootstrap
        ; test_case
            "no Gemini-specific admin-policy wiring"
            `Quick
            test_no_gemini_specific_policy_wiring
        ] )
    ; ( "host_config usage"
      , [ test_case "takeover uses Host_config.host" `Quick test_takeover_uses_host_config
        ] )
    ]
;;
