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

let promote cmd =
  cmd
  |> parse_or_fail
  |> Exec_policy.promote_to_safe
       ~allowed_commands:Exec_policy.readonly_allowed_commands
;;

let test_promote_accepts_git_push () =
  match promote "git push --force origin main" with
  | Ok verified ->
    let ir = Typed_capabilities.shell_ir verified in
    let rendered = Format.asprintf "%a" Masc_exec.Shell_ir.pp ir in
    Alcotest.(check string) "preserves checked IR" "git:push --force origin main" rendered
  | Error reason ->
    Alcotest.failf
      "expected git push to be allowed, got %s"
      (Exec_policy.block_reason_tag reason)
;;

let test_promote_rejects_dev_mutation () =
  match promote "npm install" with
  | Error (Exec_policy.Command_not_allowed "npm") -> ()
  | Error reason ->
    Alcotest.failf
      "expected npm to miss readonly allowlist, got %s"
      (Exec_policy.block_reason_tag reason)
  | Ok _ -> Alcotest.fail "expected npm install to be rejected"
;;

let () =
  run "ppx_safe_shell" [
    "valid", [
      test_case "safe_sh ls" `Quick test_valid_safe_sh;
    ];
    "promotion", [
      test_case "accepts git push" `Quick test_promote_accepts_git_push;
      test_case "rejects dev mutation" `Quick test_promote_rejects_dev_mutation;
    ];
  ]
