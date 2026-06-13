(** Monotonicity tests for Checked_shell_ir proof bundle (P1).

    Verifies:
    1. proof.risk = classify ir          (legacy compatibility)
    2. project_risk(effects) = proof.risk (effect projection)
    3. typed_hit is recorded correctly
    4. to_decided_ir recovers the legacy envelope *)

module Parsed = Masc_exec.Parsed
module Shell_ir = Masc_exec.Shell_ir
module Shell_ir_risk = Masc_exec.Shell_ir_risk
module Exec_effect = Masc_exec.Exec_effect
module Checked = Masc_exec.Checked_shell_ir
module Bash = Masc_exec_bash_parser.Bash

let parse cmd =
  match Bash.parse_string cmd with
  | Parsed.Parsed ir -> ir
  | _ -> failwith (Printf.sprintf "Failed to parse: %s" cmd)
;;

let check_risk_compat cmd =
  let ir = parse cmd in
  let c = Checked.classify_proof ir in
  let legacy = (Shell_ir_risk.classify (Shell_ir_risk.undecided ir)).risk in
  if c.proof.risk <> legacy then
    Alcotest.fail
      (Printf.sprintf
         "risk mismatch for %S: proof.risk=%s, classify=%s"
         cmd
         (Shell_ir_risk.string_of_risk_class c.proof.risk)
         (Shell_ir_risk.string_of_risk_class legacy))
;;

let check_effect_projection cmd =
  let ir = parse cmd in
  let c = Checked.classify_proof ir in
  let projected = Exec_effect.project_risk c.proof.effects in
  if projected <> c.proof.risk then
    Alcotest.fail
      (Printf.sprintf
         "effect projection mismatch for %S: project_risk=%s, proof.risk=%s"
         cmd
         (Shell_ir_risk.string_of_risk_class projected)
         (Shell_ir_risk.string_of_risk_class c.proof.risk))
;;

let check_decided_ir_compat cmd =
  let ir = parse cmd in
  let c = Checked.classify_proof ir in
  let decided = Checked.to_decided_ir c in
  if Shell_ir_risk.risk_class decided <> c.proof.risk then
    Alcotest.fail
      (Printf.sprintf
         "decided_ir mismatch for %S"
         cmd)
;;

let check_golden cmd =
  check_risk_compat cmd;
  check_effect_projection cmd;
  check_decided_ir_compat cmd
;;

(* Full corpus from test_shell_ir_risk.ml *)

let all_commands =
  [ "ls"
  ; "cat file.txt"
  ; "pwd"
  ; "echo hello"
  ; "rg pattern lib/"
  ; "git status"
  ; "git log --oneline -5"
  ; "git branch -a --list '*20083*'"
  ; "git branch --show-current"
  ; "git -C /repo status"
  ; "git -c color.ui=false branch --show-current"
  ; "git rev-parse HEAD"
  ; "git remote -v"
  ; "git config --get remote.origin.url"
  ; "git config --global --get user.email"
  ; "git tag -l"
  ; "env FOO=bar git status"
  ; "gh pr view 123"
  ; "gh --repo owner/repo pr view 123"
  ; "dune build"
  ; "npm run build"
  ; "mv a b"
  ; "cp a b"
  ; "mkdir dir"
  ; "touch file"
  ; "chmod 755 file"
  ; "chown user file"
  ; "chgrp group file"
  ; "git push origin main"
  ; "git commit -m msg"
  ; "git add file.txt"
  ; "git apply patch.diff"
  ; "git -C /repo push origin branch"
  ; "git -c user.name=x commit -m msg"
  ; "git switch feature"
  ; "git restore file.txt"
  ; "git pull --ff-only"
  ; "git fetch origin main"
  ; "git config --global user.email x@example.com"
  ; "git remote set-head origin -a"
  ; "env FOO=bar git push origin branch"
  ; "cat patch.diff | git apply"
  ; "git checkout branch"
  ; "git branch new-branch"
  ; "git branch -d old-branch"
  ; "git branch -m old new"
  ; "dune clean"
  ; "make test"
  ; "make install"
  ; "npm install pkg"
  ; "truncate -s 0 file"
  ; "mktemp"
  ; "tee file.txt"
  ; "curl https://example.com"
  ; "wget https://example.com/file"
  ; "ssh host uptime"
  ; "scp file host:/tmp/file"
  ; "rsync -av src/ host:/tmp/src/"
  ; "env FOO=bar curl https://example.com"
  ; "rm file.txt"
  ; "rmdir dir"
  ; "rm -rf /"
  ; "sh -c 'echo hello'"
  ; "bash -c 'echo hello'"
  ]
;;

let test_full_corpus () =
  List.iter check_golden all_commands
;;

let test_typed_hit_tracking () =
  let check_typed cmd expected =
    let ir = parse cmd in
    let c = Checked.classify_proof ir in
    if c.proof.typed_hit <> expected then
      Alcotest.fail
        (Printf.sprintf
           "typed_hit for %S: expected %b, got %b"
           cmd expected c.proof.typed_hit)
  in
  (* Known commands that should be typed *)
  check_typed "ls" true;
  check_typed "cat file.txt" true;
  check_typed "rm file.txt" true;
  check_typed "git status" true;
  check_typed "git push origin main" true
;;

let () =
  Alcotest.run
    "Checked_shell_ir monotonicity tests"
    [ ( "full corpus golden"
      , [ Alcotest.test_case "all commands" `Quick test_full_corpus ] )
    ; ( "typed hit tracking"
      , [ Alcotest.test_case "known commands" `Quick test_typed_hit_tracking ] )
    ]
;;
