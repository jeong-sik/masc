open Alcotest

let test_valid_safe_sh () =
  let result = [%safe_sh "ls"] in
  match result with
  | Ok verified ->
      let ir = Typed_capabilities.shell_ir verified in
      let rendered = Format.asprintf "%a" Masc_exec.Shell_ir.pp ir in
      Alcotest.(check string) "preserves checked IR" "safe:ls" rendered
  | Error _ ->
      Alcotest.fail "Expected Ok, got Error"

let parse_or_fail cmd =
  match Exec_policy.parse_string_to_ir ~mode:Exec_policy.Strict cmd with
  | Ok ir -> ir
  | Error br ->
    Alcotest.failf
      "parse %S failed: %s"
      cmd
      (Exec_policy.block_reason_to_string br)
;;

let verify_static_safe cmd =
  cmd
  |> parse_or_fail
  |> Exec_policy.verify_static_safe_ir
;;

(* Risk-based blocking is handled by OAS Hooks, not the policy layer.
   verify_static_safe_ir only validates syntax; non-R0 commands pass
   through as Ok and OAS Hooks enforce risk decisions at runtime. *)

let test_static_safe_allows_git_push () =
  match verify_static_safe "git push --force origin main" with
  | Ok _ -> ()
  | Error reason ->
    Alcotest.failf
      "expected git push to pass syntax validation, got %s"
      (Exec_policy.block_reason_tag reason)
;;

let test_static_safe_allows_dev_mutation () =
  match verify_static_safe "npm install" with
  | Ok _ -> ()
  | Error reason ->
    Alcotest.failf
      "expected npm install to pass syntax validation, got %s"
      (Exec_policy.block_reason_tag reason)
;;

let test_static_safe_allows_network_command () =
  match verify_static_safe "curl https://example.com" with
  | Ok _ -> ()
  | Error reason ->
    Alcotest.failf
      "expected curl to pass syntax validation, got %s"
      (Exec_policy.block_reason_tag reason)
;;

let test_static_safe_allows_shell_interpreter () =
  match verify_static_safe "bash -c 'echo x > /tmp/x'" with
  | Ok _ -> ()
  | Error reason ->
    Alcotest.failf
      "expected bash to pass syntax validation, got %s"
      (Exec_policy.block_reason_tag reason)
;;

let test_static_safe_allows_shell_capable_executable () =
  match verify_static_safe "python3 -c 'open(\"x\", \"w\").write(\"1\")'" with
  | Ok _ -> ()
  | Error reason ->
    Alcotest.failf
      "expected python3 to pass syntax validation, got %s"
      (Exec_policy.block_reason_tag reason)
;;

let expect_static_safe_allows ~label cmd =
  match verify_static_safe cmd with
  | Ok _ -> ()
  | Error reason ->
    Alcotest.failf
      "expected %s to pass syntax validation, got %s"
      label
      (Exec_policy.block_reason_tag reason)
;;

let test_static_safe_allows_env_split_shell () =
  expect_static_safe_allows
    ~label:"env -S shell wrapper"
    "env -S \"sh -c 'touch x'\""
;;

let test_static_safe_allows_opam_exec_shell () =
  expect_static_safe_allows
    ~label:"opam exec shell wrapper"
    "opam exec -- sh -c 'touch x'"
;;

let () =
  run "ppx_safe_shell" [
    "valid", [
      test_case "safe_sh ls" `Quick test_valid_safe_sh;
    ];
    "static_safe_syntax_only", [
      test_case "allows git push" `Quick test_static_safe_allows_git_push;
      test_case "allows dev mutation" `Quick test_static_safe_allows_dev_mutation;
      test_case "allows network command" `Quick test_static_safe_allows_network_command;
      test_case "allows shell interpreter" `Quick test_static_safe_allows_shell_interpreter;
      test_case "allows shell-capable executable" `Quick
        test_static_safe_allows_shell_capable_executable;
      test_case "allows env -S shell wrapper" `Quick
        test_static_safe_allows_env_split_shell;
      test_case "allows opam exec shell wrapper" `Quick
        test_static_safe_allows_opam_exec_shell;
    ];
  ]
