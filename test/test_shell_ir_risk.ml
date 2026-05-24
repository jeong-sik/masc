(** Direct unit tests for Shell_ir_risk classification.

    These tests assert the exact risk_class output for each command,
    providing proof that classification behaves as documented.
    Every command listed in is_write_operation and classify_write_detail
    must have a corresponding test case here. *)

module Parsed = Masc_exec.Parsed
module Shell_ir = Masc_exec.Shell_ir
module Shell_ir_risk = Masc_exec.Shell_ir_risk
module Bash = Masc_exec_bash_parser.Bash

let classify_cmd cmd =
  match Bash.parse_string cmd with
  | Parsed.Parsed ir ->
    let envelope = Shell_ir_risk.classify (Shell_ir_risk.undecided ir) in
    Shell_ir_risk.risk_class envelope
  | Parsed.Parse_error _ | Parsed.Parse_aborted _ | Parsed.Too_complex _ ->
    failwith (Printf.sprintf "Failed to parse: %s" cmd)
;;

let check cmd expected =
  let actual = classify_cmd cmd in
  if actual <> expected then
    Alcotest.fail
      (Printf.sprintf
         "risk_class of %S: expected %s, got %s"
         cmd
         (Shell_ir_risk.string_of_risk_class expected)
         (Shell_ir_risk.string_of_risk_class actual))
;;

let test_r0_read_commands () =
  check "ls" Shell_ir_risk.R0_Read;
  check "cat file.txt" Shell_ir_risk.R0_Read;
  check "pwd" Shell_ir_risk.R0_Read;
  check "echo hello" Shell_ir_risk.R0_Read;
  check "rg pattern lib/" Shell_ir_risk.R0_Read;
  check "git status" Shell_ir_risk.R0_Read;
  check "git log --oneline -5" Shell_ir_risk.R0_Read;
  check "gh pr view 123" Shell_ir_risk.R0_Read;
  check "dune build" Shell_ir_risk.R0_Read;
  check "make test" Shell_ir_risk.R0_Read;
  check "npm run build" Shell_ir_risk.R0_Read
;;

let test_r1_reversible_commands () =
  check "mv a b" Shell_ir_risk.R1_Reversible_mutation;
  check "cp a b" Shell_ir_risk.R1_Reversible_mutation;
  check "mkdir dir" Shell_ir_risk.R1_Reversible_mutation;
  check "touch file" Shell_ir_risk.R1_Reversible_mutation;
  check "chmod 755 file" Shell_ir_risk.R1_Reversible_mutation;
  check "chown user file" Shell_ir_risk.R1_Reversible_mutation;
  check "chgrp group file" Shell_ir_risk.R1_Reversible_mutation;
  check "git push origin main" Shell_ir_risk.R1_Reversible_mutation;
  check "git commit -m msg" Shell_ir_risk.R1_Reversible_mutation;
  check "git checkout branch" Shell_ir_risk.R1_Reversible_mutation;
  check "dune clean" Shell_ir_risk.R1_Reversible_mutation;
  check "make install" Shell_ir_risk.R1_Reversible_mutation;
  check "npm install pkg" Shell_ir_risk.R1_Reversible_mutation;
  check "truncate -s 0 file" Shell_ir_risk.R1_Reversible_mutation;
  check "mktemp" Shell_ir_risk.R1_Reversible_mutation;
  check "tee file.txt" Shell_ir_risk.R1_Reversible_mutation
;;

let test_r2_irreversible_commands () =
  check "rm file.txt" Shell_ir_risk.R2_Irreversible;
  check "rmdir dir" Shell_ir_risk.R2_Irreversible;
  check "ln -s a b" Shell_ir_risk.R2_Irreversible;
  check "unlink file" Shell_ir_risk.R2_Irreversible;
  check "install file dest" Shell_ir_risk.R2_Irreversible;
  check "dd if=/dev/zero of=disk" Shell_ir_risk.R2_Irreversible;
  check "git reset --hard HEAD" Shell_ir_risk.R2_Irreversible;
  check "gh pr merge 123" Shell_ir_risk.R2_Irreversible;
  check "gh repo delete owner/repo" Shell_ir_risk.R2_Irreversible;
  check "shred -u file.txt" Shell_ir_risk.R2_Irreversible
;;

let test_destructive_commands () =
  check "rm -rf /" Shell_ir_risk.Destructive_protected;
  check "git push --force origin main" Shell_ir_risk.Destructive_protected;
  check "git push -f origin main" Shell_ir_risk.Destructive_protected
;;

let () =
  Alcotest.run
    "Shell IR risk classification"
    [ ( "R0 read commands"
      , [ Alcotest.test_case "bare commands" `Quick test_r0_read_commands ] )
    ; ( "R1 reversible mutation"
      , [ Alcotest.test_case "bare commands" `Quick test_r1_reversible_commands ] )
    ; ( "R2 irreversible"
      , [ Alcotest.test_case "bare commands" `Quick test_r2_irreversible_commands ] )
    ; ( "Destructive protected"
      , [ Alcotest.test_case "destructive commands" `Quick test_destructive_commands ] )
    ]
;;
