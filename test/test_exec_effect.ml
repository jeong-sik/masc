(** Golden tests for Exec_effect P0 invariant:

        project_risk (extract ir) = classify ir

    for every command in the Shell_ir_risk test corpus.

    This ensures the effect decomposition is at least as precise
    as the existing scalar classifier. *)

module Parsed = Masc_exec.Parsed
module Shell_ir = Masc_exec.Shell_ir
module Shell_ir_risk = Masc_exec.Shell_ir_risk
module Exec_effect = Masc_exec.Exec_effect
module Bash = Masc_exec_bash_parser.Bash

let classify_cmd cmd =
  match Bash.parse_string cmd with
  | Parsed.Parsed ir ->
    let envelope = Shell_ir_risk.classify (Shell_ir_risk.undecided ir) in
    Shell_ir_risk.risk_class envelope
  | Parsed.Parse_error _ | Parsed.Parse_aborted _ | Parsed.Too_complex _ ->
    failwith (Printf.sprintf "Failed to parse: %s" cmd)
;;

let extract_risk cmd =
  match Bash.parse_string cmd with
  | Parsed.Parsed ir ->
    let es = Exec_effect.extract ir in
    Exec_effect.project_risk es
  | Parsed.Parse_error _ | Parsed.Parse_aborted _ | Parsed.Too_complex _ ->
    failwith (Printf.sprintf "Failed to parse: %s" cmd)
;;

let check_golden cmd =
  let expected = classify_cmd cmd in
  let actual = extract_risk cmd in
  if actual <> expected then
    Alcotest.fail
      (Printf.sprintf
         "golden mismatch for %S: classify=%s, project_risk(extract)=%s"
         cmd
         (Shell_ir_risk.string_of_risk_class expected)
         (Shell_ir_risk.string_of_risk_class actual))
;;

(* --- R0 corpus ------------------------------------------------------ *)

let test_r0_corpus () =
  List.iter check_golden
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
    ]
;;

(* --- R1 corpus ------------------------------------------------------ *)

let test_r1_corpus () =
  List.iter check_golden
    [ "mv a b"
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
    ]
;;

(* --- R2 corpus ------------------------------------------------------ *)

let test_r2_corpus () =
  List.iter check_golden
    [ "rm file.txt"
    ; "rmdir dir"
    ]
;;

(* --- Destructive corpus --------------------------------------------- *)

let test_destructive_corpus () =
  List.iter check_golden
    [ "rm -rf /"
    ; "sh -c 'echo hello'"
    ; "bash -c 'echo hello'"
    ]
;;

(* --- Test suite ----------------------------------------------------- *)

let () =
  Alcotest.run
    "Exec_effect golden tests"
    [ ( "R0 corpus golden"
      , [ Alcotest.test_case "classify = project_risk(extract)" `Quick test_r0_corpus ] )
    ; ( "R1 corpus golden"
      , [ Alcotest.test_case "classify = project_risk(extract)" `Quick test_r1_corpus ] )
    ; ( "R2 corpus golden"
      , [ Alcotest.test_case "classify = project_risk(extract)" `Quick test_r2_corpus ] )
    ; ( "Destructive corpus golden"
      , [ Alcotest.test_case "classify = project_risk(extract)" `Quick test_destructive_corpus ] )
    ]
;;
