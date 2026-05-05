(** Integration tests for keeper_shell read-side containment.

    RFC-0006 Phase B-1.5: extend the host-FS read guard from B-1
    (handle_keeper_fs_read) to keeper_shell read ops (ls/cat/rg/find/
    head/tail/wc/tree/git_status/git_log/git_diff). Docker keepers are
    always contained to their playground via the same containment
    module. *)

module Coord = Masc_mcp.Coord
module Keeper_exec_shell = Masc_mcp.Keeper_exec_shell
module Keeper_gh_env = Masc_mcp.Keeper_gh_env
module Keeper_id = Masc_mcp.Keeper_id
module Keeper_registry = Masc_mcp.Keeper_registry
module Keeper_sandbox = Masc_mcp.Keeper_sandbox
module Keeper_sandbox_factory = Masc_mcp.Keeper_sandbox_factory
module Keeper_shell_shared = Masc_mcp.Keeper_shell_shared
module Keeper_types = Masc_mcp.Keeper_types
module Keeper_alerting_path = Masc_mcp.Keeper_alerting_path
module Keeper_tool_policy = Masc_mcp.Keeper_tool_policy
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util

(* P0-1 fix: tool_policy.toml must be loaded before keeper_shell op=gh
   can execute.  Previously the policy_config ref started as None and
   git_clone_allowed_orgs/git_clone_denied_repos returned [] (fail-open),
   letting any org through the gh command org check even when a policy
   was configured.  Initialise here so gh tests see the real policy. *)
let () =
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Keeper_tool_policy.init_policy_config ~base_path))

(* ── Helpers ─────────────────────────────────────────────────────── *)

let with_env key value f =
  let prior = try Some (Sys.getenv key) with Not_found -> None in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let temp_dir () =
  let dir = Filename.temp_file "keeper_shell_containment_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let make_config () =
  let tmp = temp_dir () in
  ensure_dir (Filename.concat tmp Common.masc_dirname);
  (tmp, Coord.default_config tmp)

let make_meta ~name ~sandbox =
  (* allowed_paths=["*"] mirrors the production minjae config that lets
     the resolver permit any path under project_root. The B-1.5
     containment fires AFTER the resolver but BEFORE I/O. *)
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "shell containment test");
        ("allowed_paths", `List [ `String "*" ]);
        ( "sandbox_profile",
          `String (Keeper_types.sandbox_profile_to_string sandbox) );
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let setup ~keeper_name ~sandbox f =
  with_eio_fs @@ fun () ->
  let base, config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_meta ~name:keeper_name ~sandbox in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  f ~base ~config ~meta ~playground

let parse_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_string_option

let parse_bool_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_bool_option

let run_cmd argv =
  let quoted = String.concat " " (List.map Filename.quote argv) in
  match Sys.command quoted with
  | 0 -> ()
  | code -> Alcotest.failf "command failed (%d): %s" code quoted

let write_executable path content =
  ignore (Fs_compat.save_file_atomic path content);
  Unix.chmod path 0o755

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let normalize_realpath path =
  try Unix.realpath path with
  | _ -> path

let existing_path () =
  match Sys.getenv_opt "PATH" with
  | Some value -> value
  | None -> "/usr/bin:/bin"

let setup_task_with_worktree
      ~base
      ~config
      ~(meta : Keeper_types.keeper_meta)
      ~git_root
      ~worktree_rel
  =
  ignore (Coord.init config ~agent_name:(Some meta.agent_name));
  ignore
    (Coord.add_task config ~title:"gh binding test" ~priority:1
       ~description:"validate keeper gh context");
  let task =
    match Coord.get_tasks_safe config with
    | [ task ] -> task
    | tasks ->
      Alcotest.failf "expected exactly one task, got %d" (List.length tasks)
  in
  let backlog_file = Filename.concat base ".masc/tasks/backlog.json" in
  let worktree_json =
    `Assoc
      [
        ("branch", `String "keeper-task");
        ("path", `String worktree_rel);
        ("git_root", `String git_root);
        ("repo_name", `String (Filename.basename git_root));
      ]
  in
  let task_json =
    match Yojson.Safe.from_file backlog_file with
    | `Assoc fields -> (
      match List.assoc_opt "tasks" fields with
      | Some (`List tasks) ->
        let update_task json =
          match json with
          | `Assoc task_fields ->
            let task_id_matches =
              match List.assoc_opt "id" task_fields with
              | Some (`String id) -> String.equal id task.id
              | _ -> false
            in
            if task_id_matches
            then
              `Assoc
                (("worktree", worktree_json)
                 :: List.remove_assoc "worktree" task_fields)
            else json
          | _ -> json
        in
        `Assoc (("tasks", `List (List.map update_task tasks)) :: List.remove_assoc "tasks" fields)
      | _ -> Alcotest.fail "backlog.json missing tasks list")
    | _ -> Alcotest.fail "backlog.json root is not an object"
  in
  Yojson.Safe.to_file backlog_file task_json;
  let current_task_id =
    match Keeper_id.Task_id.of_string task.id with
    | Ok task_id -> task_id
    | Error err -> Alcotest.failf "invalid task id %s: %s" task.id err
  in
  { meta with current_task_id = Some current_task_id }, task.id

(* ── Tests ───────────────────────────────────────────────────────── *)

(* Outside-playground but inside-project-root path. The resolver allows
   it (project root scope); only the symmetric_sandbox containment check
   blocks it. This is exactly the leak vector minjae exploited. *)
let outside_in_root ~base name =
  let dir = Filename.concat base "outside_playground" in
  ensure_dir dir;
  let p = Filename.concat dir name in
  ignore (Fs_compat.save_file_atomic p (name ^ " content"));
  p

let blocked_by_symmetric_sandbox raw =
  match parse_field raw "error" with
  | None -> false
  | Some err ->
      let needle = "symmetric_sandbox_blocked" in
      let len = String.length needle in
      String.length err >= len && String.sub err 0 len = needle

(* Docker-keeper boundary enforcement landed in two phases:
   - B-1.5 (early): [symmetric_sandbox_blocked], emitted by
     [Keeper_sandbox_containment.check_read_target] AFTER the resolver
     allowed the host path through.
   - PR-3b (2026-04-28+): the resolver itself rejects out-of-sandbox
     reads with [path_outside_sandbox], so the symmetric check is not
     reached for the canonical "outside playground" case.  Both labels
     observably mean "Docker keeper read blocked by playground
     boundary".  Use this looser predicate for Docker-keeper tests so
     the semantic stays "is it blocked" instead of pinning to the
     1st-stage label.  Legacy [blocked_by_symmetric_sandbox] stays
     strict so [test_legacy_keeper_unaffected] continues to assert
     "this code path didn't fire" rather than the broader "blocked or
     not". *)
let blocked_by_sandbox_boundary raw =
  match parse_field raw "error" with
  | None -> false
  | Some err ->
      let starts_with prefix s =
        let pl = String.length prefix in
        String.length s >= pl && String.sub s 0 pl = prefix
      in
      starts_with "symmetric_sandbox_blocked" err
      || starts_with "path_outside_sandbox" err

let test_legacy_keeper_unaffected () =
  setup ~keeper_name:"alice" ~sandbox:Keeper_types.Local
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside = outside_in_root ~base "secret.txt" in
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String outside) ])
  in
  (* Strict predicate: this test specifically asserts the symmetric
     containment layer doesn't fire for Local keepers.  PR-3b's resolver
     tightening also blocks Local with [path_outside_sandbox], but that
     is the resolver layer, not the symmetric containment layer this
     test was written to characterise. *)
  Alcotest.(check bool) "legacy bypasses symmetric containment" false
    (blocked_by_symmetric_sandbox raw)

let test_docker_keeper_blocks_ls_outside () =
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Docker
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside_dir = Filename.concat base "outside_playground" in
  ensure_dir outside_dir;
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
  @@ fun () ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc [ ("op", `String "ls"); ("path", `String outside_dir) ])
  in
  Alcotest.(check bool) "ls outside playground blocked" true
    (blocked_by_sandbox_boundary raw)

let test_docker_keeper_blocks_cat_outside () =
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Docker
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside = outside_in_root ~base "host_secret.txt" in
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
  @@ fun () ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String outside) ])
  in
  Alcotest.(check bool) "cat outside playground blocked" true
    (blocked_by_sandbox_boundary raw)

let test_docker_keeper_blocks_rg_outside () =
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Docker
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside_dir = Filename.concat base "outside_playground" in
  ensure_dir outside_dir;
  ignore
    (Fs_compat.save_file_atomic
       (Filename.concat outside_dir "leak.txt")
       "secret-token");
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
  @@ fun () ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "rg");
            ("pattern", `String "secret");
            ("path", `String outside_dir);
          ])
  in
  Alcotest.(check bool) "rg outside playground blocked" true
    (blocked_by_sandbox_boundary raw)

let test_docker_keeper_blocks_find_outside () =
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Docker
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside_dir = Filename.concat base "outside_playground" in
  ensure_dir outside_dir;
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
  @@ fun () ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "find");
            ("pattern", `String "*.txt");
            ("path", `String outside_dir);
          ])
  in
  Alcotest.(check bool) "find outside playground blocked" true
    (blocked_by_sandbox_boundary raw)

let test_docker_keeper_allows_inside_playground () =
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  let demo = Filename.concat playground "demo.txt" in
  ignore (Fs_compat.save_file_atomic demo "hello inside playground");
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String demo) ])
  in
  (* Goal: containment did not block. Whether `cat` succeeds depends on
     /bin/cat availability; we only assert the symmetric_sandbox guard
     is silent. *)
  Alcotest.(check bool) "playground-internal cat not blocked" false
    (blocked_by_sandbox_boundary raw)

let test_docker_container_cwd_maps_to_host_worktree () =
  setup ~keeper_name:"executor" ~sandbox:Keeper_types.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  let host_worktree =
    Filename.concat playground "repos/masc-mcp/.worktrees/task-186"
  in
  ensure_dir host_worktree;
  let container_worktree =
    Filename.concat
      (Keeper_sandbox.container_root meta.name)
      "repos/masc-mcp/.worktrees/task-186"
  in
  let args = `Assoc [ ("cwd", `String container_worktree) ] in
  let expect = normalize_realpath host_worktree in
  (match Keeper_shell_shared.resolve_keeper_shell_read_cwd ~config ~meta ~args with
   | Ok cwd ->
     Alcotest.(check string) "read cwd maps to host" expect
       (normalize_realpath cwd)
   | Error e -> Alcotest.fail ("read cwd should map container path: " ^ e));
  match Keeper_shell_shared.resolve_keeper_shell_write_cwd ~config ~meta ~args with
  | Ok cwd ->
    Alcotest.(check string) "write cwd maps to host" expect
      (normalize_realpath cwd)
  | Error e -> Alcotest.fail ("write cwd should map container path: " ^ e)

let test_docker_container_file_path_maps_to_host_worktree () =
  setup ~keeper_name:"executor" ~sandbox:Keeper_types.Docker
  @@ fun ~base:_ ~config ~meta ~playground ->
  let host_file =
    Filename.concat playground
      "repos/masc-mcp/.worktrees/task-186/lib/keeper/keeper_tool_policy.ml"
  in
  ensure_dir (Filename.dirname host_file);
  ignore (Fs_compat.save_file_atomic host_file "let touched = true\n");
  let container_file =
    Filename.concat
      (Keeper_sandbox.container_root meta.name)
      "repos/masc-mcp/.worktrees/task-186/lib/keeper/keeper_tool_policy.ml"
  in
  let args =
    `Assoc [ ("op", `String "head"); ("path", `String container_file) ]
  in
  match Keeper_shell_shared.resolve_keeper_shell_read_path ~config ~meta ~args with
  | Ok path ->
    Alcotest.(check string) "file path maps to host"
      (normalize_realpath host_file) (normalize_realpath path)
  | Error e -> Alcotest.fail ("file path should map container path: " ^ e)

let test_docker_other_container_root_stays_blocked () =
  setup ~keeper_name:"executor" ~sandbox:Keeper_types.Docker
  @@ fun ~base:_ ~config ~meta ~playground:_ ->
  let other_container_cwd =
    Filename.concat
      (Keeper_sandbox.container_root "analyst")
      "repos/masc-mcp"
  in
  let args = `Assoc [ ("cwd", `String other_container_cwd) ] in
  match Keeper_shell_shared.resolve_keeper_shell_read_cwd ~config ~meta ~args with
  | Ok cwd -> Alcotest.fail ("other keeper container cwd should be blocked: " ^ cwd)
  | Error e ->
    Alcotest.(check bool) "outside project root" true
      (String_util.contains_substring e "path_outside_project_root")

let test_docker_git_creds_contained () =
  setup ~keeper_name:"poe" ~sandbox:Keeper_types.Docker
  @@ fun ~base ~config ~meta ~playground:_ ->
  let outside = outside_in_root ~base "git_secret.txt" in
  let factory = Keeper_sandbox_factory.create ~config ~meta () in
  Fun.protect
    ~finally:(fun () -> Keeper_sandbox_factory.cleanup factory)
  @@ fun () ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell
      ~turn_sandbox_factory:(Some factory)
      ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String outside) ])
  in
  Alcotest.(check bool) "docker git-creds also contained" true
    (blocked_by_sandbox_boundary raw)

let test_gh_binds_repo_from_active_task_worktree () =
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Local
  @@ fun ~base ~config ~meta ~playground ->
  let git_root = Filename.concat playground "repos/masc-mcp" in
  let worktree_rel = ".worktrees/task-001" in
  let worktree_cwd = Filename.concat git_root worktree_rel in
  ensure_dir worktree_cwd;
  run_cmd [ "git"; "-C"; git_root; "init"; "--quiet" ];
  run_cmd
    [
      "git";
      "-C";
      git_root;
      "remote";
      "add";
      "origin";
      "https://github.com/jeong-sik/masc-mcp.git";
    ];
  let meta, _task_id =
    setup_task_with_worktree ~base ~config ~meta
      ~git_root ~worktree_rel
  in
  let bin_dir = Filename.concat playground "bin" in
  let gh_args_file = Filename.concat playground "gh-args.txt" in
  let gh_pwd_file = Filename.concat playground "gh-pwd.txt" in
  ensure_dir bin_dir;
  ensure_dir (Keeper_gh_env.root_gh_config_dir config);
  write_executable
    (Filename.concat bin_dir "gh")
    "#!/bin/sh\nprintf '%s' \"$*\" > \"$GH_ARGS_FILE\"\nprintf '%s' \"$PWD\" > \"$GH_PWD_FILE\"\necho fake-gh-ok\n";
  with_env "GH_ARGS_FILE" gh_args_file @@ fun () ->
  with_env "GH_PWD_FILE" gh_pwd_file @@ fun () ->
  with_env "PATH" (bin_dir ^ ":" ^ existing_path ()) @@ fun () ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
      ~args:
        (`Assoc
          [
            ("op", `String "gh");
            ("cmd", `String "pr list --state open");
          ])
  in
  if not (Sys.file_exists gh_args_file) then
    Alcotest.failf "gh did not run: %s" raw;
  let recorded_args = read_file gh_args_file in
  let recorded_pwd = read_file gh_pwd_file in
  Alcotest.(check bool) "repo flag injected"
    true
    (String_util.contains_substring recorded_args
       "--repo jeong-sik/masc-mcp pr list --state open");
  Alcotest.(check string) "gh runs from task worktree cwd"
    (normalize_realpath worktree_cwd)
    (normalize_realpath recorded_pwd);
  Alcotest.(check (option string)) "repo echoed in result"
    (Some "jeong-sik/masc-mcp")
    (parse_field raw "repo")

let test_gh_missing_worktree_returns_typed_error () =
  setup ~keeper_name:"minjae" ~sandbox:Keeper_types.Local
  @@ fun ~base:_ ~config ~meta ~playground:_ ->
  ignore (Coord.init config ~agent_name:(Some meta.agent_name));
  ignore
    (Coord.add_task config ~title:"gh missing worktree" ~priority:1
       ~description:"validate typed gh error");
  let task =
    match Coord.get_tasks_safe config with
    | [ task ] -> task
    | tasks ->
      Alcotest.failf "expected exactly one task, got %d" (List.length tasks)
  in
  let current_task_id =
    match Keeper_id.Task_id.of_string task.id with
    | Ok task_id -> task_id
    | Error err -> Alcotest.failf "invalid task id %s: %s" task.id err
  in
  let meta = { meta with current_task_id = Some current_task_id } in
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~turn_sandbox_factory:None ~exec_cache:None ~config ~meta
      ~args:(`Assoc [ ("op", `String "gh"); ("cmd", `String "pr list") ])
  in
  Alcotest.(check (option string)) "typed gh error"
    (Some "gh_repo_context_missing_worktree")
    (parse_field raw "error");
  Alcotest.(check (option bool)) "structured failure"
    (Some false)
    (parse_bool_field raw "ok")

let () =
  Alcotest.run "Keeper_shell_containment"
    [
      ( "containment",
        [
          Alcotest.test_case "legacy keeper unaffected" `Quick
            test_legacy_keeper_unaffected;
          Alcotest.test_case "docker keeper blocks ls outside" `Quick
            test_docker_keeper_blocks_ls_outside;
          Alcotest.test_case "docker keeper blocks cat outside" `Quick
            test_docker_keeper_blocks_cat_outside;
          Alcotest.test_case "docker keeper blocks rg outside" `Quick
            test_docker_keeper_blocks_rg_outside;
          Alcotest.test_case "docker keeper blocks find outside" `Quick
            test_docker_keeper_blocks_find_outside;
          Alcotest.test_case "docker keeper allows inside playground"
            `Quick test_docker_keeper_allows_inside_playground;
          Alcotest.test_case "docker container cwd maps to host worktree"
            `Quick test_docker_container_cwd_maps_to_host_worktree;
          Alcotest.test_case "docker container file path maps to host worktree"
            `Quick test_docker_container_file_path_maps_to_host_worktree;
          Alcotest.test_case "docker other container root stays blocked"
            `Quick test_docker_other_container_root_stays_blocked;
          Alcotest.test_case "docker git-creds also contained" `Quick
            test_docker_git_creds_contained;
          Alcotest.test_case "gh binds repo from active task worktree" `Quick
            test_gh_binds_repo_from_active_task_worktree;
          Alcotest.test_case "gh missing worktree returns typed error" `Quick
            test_gh_missing_worktree_returns_typed_error;
        ] );
    ]
