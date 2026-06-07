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

let test_static_safe_rejects_git_push () =
  match verify_static_safe "git push --force origin main" with
  | Error (Exec_policy.Command_not_allowed "git") -> ()
  | Error reason ->
    Alcotest.failf
      "expected git push to fail static R0 verification, got %s"
      (Exec_policy.block_reason_tag reason)
  | Ok _ -> Alcotest.fail "expected git push to be rejected"
;;

let test_static_safe_rejects_dev_mutation () =
  match verify_static_safe "npm install" with
  | Error (Exec_policy.Command_not_allowed "npm") -> ()
  | Error reason ->
    Alcotest.failf
      "expected npm install to fail static R0 verification, got %s"
      (Exec_policy.block_reason_tag reason)
  | Ok _ -> Alcotest.fail "expected npm install to be rejected"
;;

let test_static_safe_rejects_network_command () =
  match verify_static_safe "curl https://example.com" with
  | Error (Exec_policy.Command_not_allowed "curl") -> ()
  | Error reason ->
    Alcotest.failf
      "expected curl to fail static safe capability verification, got %s"
      (Exec_policy.block_reason_tag reason)
  | Ok _ -> Alcotest.fail "expected curl to be rejected"
;;

let test_static_safe_rejects_shell_interpreter () =
  match verify_static_safe "bash -c 'echo x > /tmp/x'" with
  | Error (Exec_policy.Command_not_allowed "bash") -> ()
  | Error reason ->
    Alcotest.failf
      "expected bash to fail static safe capability verification, got %s"
      (Exec_policy.block_reason_tag reason)
  | Ok _ -> Alcotest.fail "expected bash to be rejected"
;;

let () =
  run "ppx_safe_shell" [
    "valid", [
      test_case "safe_sh ls" `Quick test_valid_safe_sh;
    ];
    "static_safe", [
      test_case "rejects git push" `Quick test_static_safe_rejects_git_push;
      test_case "rejects dev mutation" `Quick test_static_safe_rejects_dev_mutation;
      test_case "rejects network command" `Quick test_static_safe_rejects_network_command;
      test_case "rejects shell interpreter" `Quick test_static_safe_rejects_shell_interpreter;
    ];
  ]
