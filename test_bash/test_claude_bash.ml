let test_interpret_timeout () =
  let res = Masc_mcp.Keeper_exec_shell.interpret_command_result "sleep 10" (Unix.WEXITED 124) "" in
  Alcotest.(check (option string)) "timeout" (Some "Command timed out.") res

let test_interpret_signal () =
  let res = Masc_mcp.Keeper_exec_shell.interpret_command_result "yes" (Unix.WEXITED 130) "" in
  Alcotest.(check (option string)) "signal" (Some "Command interrupted by signal (e.g. Ctrl+C).") res

let test_interpret_grep_empty () =
  let res = Masc_mcp.Keeper_exec_shell.interpret_command_result "grep foo bar" (Unix.WEXITED 1) "" in
  Alcotest.(check (option string)) "grep no matches" (Some "No matches found.") res

let test_interpret_rg_empty () =
  let res = Masc_mcp.Keeper_exec_shell.interpret_command_result "rg foo bar" (Unix.WEXITED 1) "" in
  Alcotest.(check (option string)) "rg no matches" (Some "No matches found.") res

let test_interpret_ls_not_found () =
  let res = Masc_mcp.Keeper_exec_shell.interpret_command_result "ls -la /nonexistent" (Unix.WEXITED 2) "" in
  Alcotest.(check (option string)) "ls not found" (Some "No such file or directory.") res

let test_interpret_success () =
  let res = Masc_mcp.Keeper_exec_shell.interpret_command_result "ls -la" (Unix.WEXITED 0) "" in
  Alcotest.(check (option string)) "success is None" None res

let test_interpret_unknown_error () =
  let res = Masc_mcp.Keeper_exec_shell.interpret_command_result "some_cmd" (Unix.WEXITED 3) "" in
  Alcotest.(check (option string)) "unknown error is None" None res

let suite =
  [
    "timeout", `Quick, test_interpret_timeout;
    "signal", `Quick, test_interpret_signal;
    "grep_empty", `Quick, test_interpret_grep_empty;
    "rg_empty", `Quick, test_interpret_rg_empty;
    "ls_not_found", `Quick, test_interpret_ls_not_found;
    "success", `Quick, test_interpret_success;
    "unknown_error", `Quick, test_interpret_unknown_error;
  ]

let () = Alcotest.run "Keeper Claude Bash Upgrades" [ "interpret_command_result", suite ]