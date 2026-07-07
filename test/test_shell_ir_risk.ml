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
  check "git branch -a --list '*20083*'" Shell_ir_risk.R0_Read;
  check "git branch --show-current" Shell_ir_risk.R0_Read;
  check "git -C /repo status" Shell_ir_risk.R0_Read;
  check "git -c color.ui=false branch --show-current" Shell_ir_risk.R0_Read;
  check "git rev-parse HEAD" Shell_ir_risk.R0_Read;
  check "git remote -v" Shell_ir_risk.R0_Read;
  check "git config --get remote.origin.url" Shell_ir_risk.R0_Read;
  check "git config --global --get user.email" Shell_ir_risk.R0_Read;
  check "git tag -l" Shell_ir_risk.R0_Read;
  check "env FOO=bar git status" Shell_ir_risk.R0_Read;
  check "gh pr view 123" Shell_ir_risk.R0_Read;
  check "gh --repo owner/repo pr view 123" Shell_ir_risk.R0_Read;
  check "dune build" Shell_ir_risk.R0_Read;
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
  check "git add file.txt" Shell_ir_risk.R1_Reversible_mutation;
  check "git apply patch.diff" Shell_ir_risk.R1_Reversible_mutation;
  check "git -C /repo push origin branch" Shell_ir_risk.R1_Reversible_mutation;
  check "git -c user.name=x commit -m msg" Shell_ir_risk.R1_Reversible_mutation;
  check "git switch feature" Shell_ir_risk.R1_Reversible_mutation;
  check "git restore file.txt" Shell_ir_risk.R1_Reversible_mutation;
  check "git pull --ff-only" Shell_ir_risk.R1_Reversible_mutation;
  check "git fetch origin main" Shell_ir_risk.R1_Reversible_mutation;
  check "git config --global user.email x@example.com" Shell_ir_risk.R1_Reversible_mutation;
  check "git remote set-head origin -a" Shell_ir_risk.R1_Reversible_mutation;
  check "env FOO=bar git push origin branch" Shell_ir_risk.R1_Reversible_mutation;
  check "cat patch.diff | git apply" Shell_ir_risk.R1_Reversible_mutation;
  check "git checkout branch" Shell_ir_risk.R1_Reversible_mutation;
  check "git branch new-branch" Shell_ir_risk.R1_Reversible_mutation;
  check "git branch -d old-branch" Shell_ir_risk.R1_Reversible_mutation;
  check "git branch -m old new" Shell_ir_risk.R1_Reversible_mutation;
  check "dune clean" Shell_ir_risk.R1_Reversible_mutation;
  check "make test" Shell_ir_risk.R1_Reversible_mutation;
  check "make install" Shell_ir_risk.R1_Reversible_mutation;
  check "npm install pkg" Shell_ir_risk.R1_Reversible_mutation;
  check "truncate -s 0 file" Shell_ir_risk.R1_Reversible_mutation;
  check "mktemp" Shell_ir_risk.R1_Reversible_mutation;
  check "tee file.txt" Shell_ir_risk.R1_Reversible_mutation;
  check "curl https://example.com" Shell_ir_risk.R1_Reversible_mutation;
  check "wget https://example.com/file" Shell_ir_risk.R1_Reversible_mutation;
  check "ssh host uptime" Shell_ir_risk.R1_Reversible_mutation;
  check "scp file host:/tmp/file" Shell_ir_risk.R1_Reversible_mutation;
  check "rsync -av src/ host:/tmp/src/" Shell_ir_risk.R1_Reversible_mutation;
  check "env FOO=bar curl https://example.com" Shell_ir_risk.R1_Reversible_mutation
;;

let test_r2_irreversible_commands () =
  check "rm file.txt" Shell_ir_risk.R2_Irreversible;
  check "rmdir dir" Shell_ir_risk.R2_Irreversible;
  check "ln -s a b" Shell_ir_risk.R2_Irreversible;
  check "unlink file" Shell_ir_risk.R2_Irreversible;
  check "install file dest" Shell_ir_risk.R2_Irreversible;
  check "dd if=/dev/zero of=disk" Shell_ir_risk.R2_Irreversible;
  check "git reset --hard HEAD" Shell_ir_risk.R2_Irreversible;
  check "git -C /repo reset --hard HEAD" Shell_ir_risk.R2_Irreversible;
  check "git clean -fd" Shell_ir_risk.R2_Irreversible;
  check "env git reset --hard HEAD" Shell_ir_risk.R2_Irreversible;
  check "gh pr merge 123" Shell_ir_risk.R2_Irreversible;
  check "gh --repo owner/repo pr merge 123" Shell_ir_risk.R2_Irreversible;
  check "gh repo delete owner/repo" Shell_ir_risk.R2_Irreversible;
  check "shred -u file.txt" Shell_ir_risk.R2_Irreversible
;;

let test_destructive_commands () =
  check "rm -rf /" Shell_ir_risk.Destructive_protected;
  check "git push --force origin main" Shell_ir_risk.Destructive_protected;
  check "git push -f origin main" Shell_ir_risk.Destructive_protected;
  check "git -C /repo push --force origin main" Shell_ir_risk.Destructive_protected;
  check "env git push --force origin main" Shell_ir_risk.Destructive_protected;
  check "cat ref | git push --force origin main" Shell_ir_risk.Destructive_protected;
  check "bash -c 'echo x > /tmp/x'" Shell_ir_risk.Destructive_protected;
  check "sh -c 'echo x > /tmp/x'" Shell_ir_risk.Destructive_protected;
  check "python -c 'open(\"x\", \"w\").write(\"1\")'" Shell_ir_risk.Destructive_protected;
  check "python3 -c 'open(\"x\", \"w\").write(\"1\")'" Shell_ir_risk.Destructive_protected;
  check "node -e 'require(\"fs\").writeFileSync(\"x\", \"1\")'"
    Shell_ir_risk.Destructive_protected;
  check "pip install pkg" Shell_ir_risk.Destructive_protected;
  check "npx some-tool" Shell_ir_risk.Destructive_protected;
  check "env -S \"sh -c 'touch x'\"" Shell_ir_risk.Destructive_protected;
  check "env --split-string=\"sh -c 'touch x'\"" Shell_ir_risk.Destructive_protected;
  check "opam exec -- sh -c 'touch x'" Shell_ir_risk.Destructive_protected
;;

let test_typed_execute_shell_capable_executable_is_destructive () =
  let input =
    `Assoc
      [ "executable", `String "python3"
      ; "argv", `List [ `String "-c"; `String "open('x', 'w').write('1')" ]
      ]
  in
  match Masc.Keeper_tool_execute_typed_input.of_json input with
  | Error msg -> Alcotest.failf "typed Execute parse failed: %s" msg
  | Ok typed_input ->
    (match Masc.Keeper_tool_execute_typed_input.to_shell_ir typed_input with
     | Error err ->
       Alcotest.failf
         "typed Execute validation failed: %a"
         Masc.Keeper_tool_execute_typed_input.pp_validation_error
         err
     | Ok ir ->
       let envelope = Shell_ir_risk.classify (Shell_ir_risk.undecided ir) in
       Alcotest.(check bool)
         "typed Execute python3 is blocked before dispatch"
         true
         (Shell_ir_risk.is_destructive envelope))
;;

let test_typed_execute_env_split_shell_wrapper_is_destructive () =
  let input =
    `Assoc
      [ "executable", `String "env"
      ; "argv", `List [ `String "-S"; `String "sh -c 'touch x'" ]
      ]
  in
  match Masc.Keeper_tool_execute_typed_input.of_json input with
  | Error msg -> Alcotest.failf "typed Execute parse failed: %s" msg
  | Ok typed_input ->
    (match Masc.Keeper_tool_execute_typed_input.to_shell_ir typed_input with
     | Error err ->
       Alcotest.failf
         "typed Execute validation failed: %a"
         Masc.Keeper_tool_execute_typed_input.pp_validation_error
         err
     | Ok ir ->
       let envelope = Shell_ir_risk.classify (Shell_ir_risk.undecided ir) in
       Alcotest.(check bool)
         "typed Execute env -S shell wrapper is blocked before dispatch"
         true
         (Shell_ir_risk.is_destructive envelope))
;;

let test_typed_execute_opam_exec_shell_wrapper_is_destructive () =
  let input =
    `Assoc
      [ "executable", `String "opam"
      ; "argv"
        , `List
            [ `String "exec"
            ; `String "--"
            ; `String "sh"
            ; `String "-c"
            ; `String "touch x"
            ]
      ]
  in
  match Masc.Keeper_tool_execute_typed_input.of_json input with
  | Error msg -> Alcotest.failf "typed Execute parse failed: %s" msg
  | Ok typed_input ->
    (match Masc.Keeper_tool_execute_typed_input.to_shell_ir typed_input with
     | Error err ->
       Alcotest.failf
         "typed Execute validation failed: %a"
         Masc.Keeper_tool_execute_typed_input.pp_validation_error
         err
     | Ok ir ->
       let envelope = Shell_ir_risk.classify (Shell_ir_risk.undecided ir) in
       Alcotest.(check bool)
         "typed Execute opam exec shell wrapper is blocked before dispatch"
         true
         (Shell_ir_risk.is_destructive envelope))
;;

let test_gh_r0_read () =
  check "gh pr view 123" Shell_ir_risk.R0_Read;
  check "gh issue list" Shell_ir_risk.R0_Read;
  check "gh repo view owner/repo" Shell_ir_risk.R0_Read;
  check "gh release list" Shell_ir_risk.R0_Read;
  check "gh run list" Shell_ir_risk.R0_Read;
  check "gh api repos/owner/repo" Shell_ir_risk.R0_Read
;;

let test_gh_r1_reversible () =
  check "gh pr create" Shell_ir_risk.R1_Reversible_mutation;
  check "gh pr close 123" Shell_ir_risk.R1_Reversible_mutation;
  check "gh --repo owner/repo pr close 123" Shell_ir_risk.R1_Reversible_mutation;
  check "gh pr checkout 123" Shell_ir_risk.R1_Reversible_mutation;
  check "gh pr reopen 123" Shell_ir_risk.R1_Reversible_mutation;
  check "gh issue create" Shell_ir_risk.R1_Reversible_mutation;
  check "gh issue edit 123" Shell_ir_risk.R1_Reversible_mutation;
  (* RFC-0309 W4/G-9: repo create/fork and discussion mutations are reversible
     (R1). The "keeper may not do this unsupervised" decision lives on the
     capability axis (Requires_approval), not the risk floor. *)
  check "gh repo create repo-name" Shell_ir_risk.R1_Reversible_mutation;
  check "gh repo fork owner/repo" Shell_ir_risk.R1_Reversible_mutation;
  check "gh discussion create --repo owner/repo --title T --body B"
    Shell_ir_risk.R1_Reversible_mutation;
  check "gh discussion comment 123 --body B" Shell_ir_risk.R1_Reversible_mutation;
  check "gh api graphql -f 'query=mutation{createRepository}'"
    Shell_ir_risk.R1_Reversible_mutation;
  check "gh api graphql -f 'query=mutation{createDiscussion}'"
    Shell_ir_risk.R1_Reversible_mutation;
  check "gh api graphql -f 'query=mutation{addDiscussionComment}'"
    Shell_ir_risk.R1_Reversible_mutation;
  check "gh release create v1.0.0" Shell_ir_risk.R1_Reversible_mutation;
  check "gh release upload v1.0.0 file.tgz" Shell_ir_risk.R1_Reversible_mutation;
  check "gh run cancel 123" Shell_ir_risk.R1_Reversible_mutation;
  check "gh run rerun 123" Shell_ir_risk.R1_Reversible_mutation;
  check "gh workflow enable workflow.yml" Shell_ir_risk.R1_Reversible_mutation;
  check "gh workflow run workflow.yml" Shell_ir_risk.R1_Reversible_mutation;
  check "gh label create bug" Shell_ir_risk.R1_Reversible_mutation;
  check "gh project create title" Shell_ir_risk.R1_Reversible_mutation;
  check "gh gist create file.txt" Shell_ir_risk.R1_Reversible_mutation;
  check "gh ruleset create" Shell_ir_risk.R1_Reversible_mutation;
  check "gh api repos/owner/repo/issues -X POST" Shell_ir_risk.R1_Reversible_mutation;
  check "gh api repos/owner/repo/issues --method POST" Shell_ir_risk.R1_Reversible_mutation;
  check "gh api repos/owner/repo/issues -X PUT" Shell_ir_risk.R1_Reversible_mutation;
  check "gh api repos/owner/repo/issues -X PATCH" Shell_ir_risk.R1_Reversible_mutation;
  check "printf data | gh api -X PATCH repos/owner/repo" Shell_ir_risk.R1_Reversible_mutation;
  check "env GH_TOKEN=x gh pr close 123" Shell_ir_risk.R1_Reversible_mutation;
  check "gh api graphql" Shell_ir_risk.R1_Reversible_mutation;
  check "gh api repos/owner/repo --field name=value" Shell_ir_risk.R1_Reversible_mutation;
  check "gh api repos/owner/repo --raw-field name=value" Shell_ir_risk.R1_Reversible_mutation
;;

let test_gh_r2_irreversible () =
  check "gh pr merge 123" Shell_ir_risk.R2_Irreversible;
  check "gh pr ready 123" Shell_ir_risk.R2_Irreversible;
  check "gh repo delete owner/repo" Shell_ir_risk.R2_Irreversible;
  check "gh repo archive owner/repo" Shell_ir_risk.R2_Irreversible;
  check "gh repo transfer owner/repo" Shell_ir_risk.R2_Irreversible;
  check "gh discussion delete 123" Shell_ir_risk.R2_Irreversible;
  check "gh release delete v1.0.0" Shell_ir_risk.R2_Irreversible;
  check "gh secret delete SECRET" Shell_ir_risk.R2_Irreversible;
  check "gh secret remove SECRET" Shell_ir_risk.R2_Irreversible;
  check "gh ssh-key delete 123" Shell_ir_risk.R2_Irreversible;
  check "gh workflow disable workflow.yml" Shell_ir_risk.R2_Irreversible;
  check "gh auth logout" Shell_ir_risk.R2_Irreversible;
  check "gh auth token" Shell_ir_risk.R2_Irreversible;
  check "gh gist delete 123" Shell_ir_risk.R2_Irreversible;
  check "gh ruleset delete 123" Shell_ir_risk.R2_Irreversible;
  check "gh api repos/owner/repo -X DELETE" Shell_ir_risk.R2_Irreversible;
  check "gh api repos/owner/repo --method DELETE" Shell_ir_risk.R2_Irreversible;
  check "gh api graphql -f 'query=mutation{deleteDiscussion}'"
    Shell_ir_risk.R2_Irreversible
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
      , [ Alcotest.test_case "destructive commands" `Quick test_destructive_commands
        ; Alcotest.test_case
            "typed Execute shell-capable executable"
            `Quick
            test_typed_execute_shell_capable_executable_is_destructive
        ; Alcotest.test_case
            "typed Execute env -S shell wrapper"
            `Quick
            test_typed_execute_env_split_shell_wrapper_is_destructive
        ; Alcotest.test_case
            "typed Execute opam exec shell wrapper"
            `Quick
            test_typed_execute_opam_exec_shell_wrapper_is_destructive
        ] )
    ; ( "gh R0 read"
      , [ Alcotest.test_case "gh read commands" `Quick test_gh_r0_read ] )
    ; ( "gh R1 reversible"
      , [ Alcotest.test_case "gh mutation commands" `Quick test_gh_r1_reversible ] )
    ; ( "gh R2 irreversible"
      , [ Alcotest.test_case "gh destructive commands" `Quick test_gh_r2_irreversible ] )
    ]
;;
