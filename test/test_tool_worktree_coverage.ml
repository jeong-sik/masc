module Types = Masc_domain

(** Tool_worktree Module Coverage Tests *)

module Tool_args = Masc_mcp.Tool_args
open Alcotest

let () = Random.self_init ()

module Tool_worktree = Masc_mcp.Tool_worktree

(* ============================================================
   Argument Helper Tests
   ============================================================ *)

let test_get_string_exists () =
  let args = `Assoc [("task_id", `String "task-001")] in
  check string "extracts string" "task-001" (Tool_args.get_string args "task_id" "default")

let test_get_string_missing () =
  let args = `Assoc [] in
  check string "uses default" "default" (Tool_args.get_string args "task_id" "default")

let test_get_string_base_branch () =
  let args = `Assoc [("base_branch", `String "main")] in
  check string "extracts branch" "main"
    (Tool_args.get_string args "base_branch" Tool_worktree.default_base_branch)

let test_get_string_base_branch_default () =
  let args = `Assoc [] in
  check string "uses auto default" "auto"
    (Tool_args.get_string args "base_branch" Tool_worktree.default_base_branch)

(* ============================================================
   Context Creation Tests
   ============================================================ *)

let test_context_creation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Masc_mcp.Coord.default_config "/tmp/test" in
  let ctx : Tool_worktree.context = { config; agent_name = "test-agent" } in
  check string "agent_name" "test-agent" ctx.agent_name

(* ============================================================
   Dispatch Tests
   ============================================================ *)

let make_ctx () : Tool_worktree.context =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Masc_mcp.Coord.default_config "/tmp/test-worktree" in
  ({ config; agent_name = "test-agent" } : Tool_worktree.context)

let temp_dir () =
  let dir = Filename.temp_file "tool_worktree_coverage_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let rec rm_path path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> rm_path (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path)
    else
      Unix.unlink path

let clear_checkout_but_keep_git_dir repo =
  Array.iter
    (fun name ->
       if name <> ".git" then rm_path (Filename.concat repo name))
    (Sys.readdir repo)

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let write_file path content =
  ensure_dir (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content

let write_keeper_toml ~base_path ~name ~sandbox_profile =
  let path =
    Filename.concat base_path
      (Printf.sprintf ".masc/config/keepers/%s.toml" name)
  in
  write_file path
    (Printf.sprintf
       "[keeper]\npersona_name = %S\nsandbox_profile = %S\n"
       name sandbox_profile)

let write_git_clone_policy_toml ~base_path =
  write_file
    (Filename.concat base_path ".masc/config/tool_policy.toml")
    "[git_clone]\nallowed_orgs = []\ndenied_repos = []\n"

let run_ok ~cwd cmd =
  let wrapped = Printf.sprintf "cd %s && %s > /dev/null 2>&1" (Filename.quote cwd) cmd in
  let code = Sys.command wrapped in
  if code <> 0 then fail (Printf.sprintf "command failed (%d): %s" code cmd)

let init_process_eio env =
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let cwd = Eio.Stdenv.cwd env in
  Process_eio.init ~cwd_default:cwd ~proc_mgr ~clock

let setup_nested_repo_with_remote ~base_path ~repo_rel =
  write_git_clone_policy_toml ~base_path;
  let remote = Filename.concat base_path ".remote-masc-mcp.git" in
  let repo = Filename.concat base_path repo_rel in
  ensure_dir (Filename.dirname repo);
  run_ok ~cwd:base_path
    (Printf.sprintf "git init --bare -q --initial-branch=main %s"
       (Filename.quote remote));
  run_ok ~cwd:base_path
    (Printf.sprintf "git clone -q %s %s"
       (Filename.quote remote) (Filename.quote repo));
  run_ok ~cwd:repo "git config user.email test@example.com";
  run_ok ~cwd:repo "git config user.name Test";
  let readme = Filename.concat repo "README.md" in
  let oc = open_out readme in
  output_string oc "# sandbox auto-provision test\n";
  close_out oc;
  run_ok ~cwd:repo "git add README.md";
  run_ok ~cwd:repo "git commit -q -m init";
  run_ok ~cwd:repo "git push -q origin main";
  repo

let create_file_storm ~base_path ~count =
  for i = 0 to count - 1 do
    let path = Filename.concat base_path (Printf.sprintf "aa-%04d.tmp" i) in
    let oc = open_out path in
    output_string oc "x\n";
    close_out oc
  done

let create_hidden_dir_storm ~base_path ~count =
  let root = Filename.concat base_path ".venvs/storm" in
  ensure_dir root;
  for i = 0 to count - 1 do
    Unix.mkdir (Filename.concat root (Printf.sprintf "aa-%04d" i)) 0o755
  done

let create_wide_workspace_storm ~base_path ~count =
  let root = Filename.concat base_path "workspace/aaa-big" in
  ensure_dir root;
  for i = 0 to count - 1 do
    Unix.mkdir (Filename.concat root (Printf.sprintf "aa-%04d" i)) 0o755
  done

let test_dispatch_worktree_create () =
  let ctx = make_ctx () in
  let args = `Assoc [("task_id", `String "task-001"); ("base_branch", `String "main")] in
  try
    match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
    | Some _ -> ()
    | None -> fail "expected Some"
  with _ -> ()

let test_dispatch_worktree_remove () =
  let ctx = make_ctx () in
  let args = `Assoc [("task_id", `String "task-001")] in
  try
    match Tool_worktree.dispatch ctx ~name:"masc_worktree_remove" ~args with
    | Some _ -> ()
    | None -> fail "expected Some"
  with _ -> ()

let test_dispatch_worktree_list () =
  let ctx = make_ctx () in
  try
    match Tool_worktree.dispatch ctx ~name:"masc_worktree_list" ~args:(`Assoc []) with
    | Some _ -> ()
    | None -> fail "expected Some"
  with _ -> ()

let test_dispatch_unknown_tool () =
  let ctx = make_ctx () in
  match Tool_worktree.dispatch ctx ~name:"masc_unknown" ~args:(`Assoc []) with
  | None -> ()
  | Some _ -> fail "expected None for unknown tool"

let test_remove_schema_requires_only_task_id () =
  let schema =
    Tool_worktree.schemas
    |> List.find (fun (s : Masc_domain.tool_schema) ->
         String.equal s.name "masc_worktree_remove")
  in
  let open Yojson.Safe.Util in
  let required =
    schema.input_schema
    |> member "required"
    |> to_list
    |> List.map to_string
  in
  check (list string) "remove required fields" [ "task_id" ] required

(* ============================================================
   Iter-7 (#6527) — agent_name spoof rejection
   ============================================================
   handle_worktree_create used to trust the `agent_name` MCP arg
   verbatim, so agent-A could call
       masc_worktree_create agent_name=agent-B task_id=foo
   and land a worktree inside agent-B's playground. PR #6617 fixed
   the dispatcher to reject any arg value that does not equal
   ctx.agent_name. These cases lock the three-branch decision down
   so a future refactor cannot silently re-introduce the leak. *)

let contains needle haystack =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  if nlen = 0 then true
  else
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

let check_contains label needle haystack =
  check bool label true (contains needle haystack)

let test_dispatch_worktree_create_spoofed_agent_blocked () =
  let ctx = make_ctx () in
  let args = `Assoc [
    ("agent_name", `String "other-agent");
    ("task_id", `String "task-spoof");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (true, _) -> fail "spoofed agent_name should have been rejected"
  | Some (false, msg) ->
    check bool "error mentions agent_name mismatch" true
      (contains "agent_name mismatch" msg);
    check bool "error mentions the caller ctx agent" true
      (contains "test-agent" msg);
    check bool "error mentions the spoofed arg value" true
      (contains "other-agent" msg);
    check bool "error explains cross-agent is blocked" true
      (contains "Cross-agent" msg)

let test_dispatch_worktree_create_matching_agent_passes_check () =
  (* When the arg matches ctx.agent_name, the spoof gate must not
     fire. The downstream Coord.worktree_create_r call may still fail
     because the fixture base_path is not a real git repository, so
     we only assert that any error returned is NOT the spoof error. *)
  let ctx = make_ctx () in
  let args = `Assoc [
    ("agent_name", `String "test-agent");
    ("task_id", `String "task-match");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (_ok, msg) ->
    check bool "matching agent_name does not trip spoof gate" false
      (contains "agent_name mismatch" msg)

let test_dispatch_worktree_create_empty_agent_falls_back () =
  (* The 9B fallback: empty/missing agent_name arg uses ctx.agent_name
     instead of rejecting. Same assertion shape as the matching case —
     we only prove that the spoof branch is not taken. *)
  let ctx = make_ctx () in
  let args = `Assoc [
    ("task_id", `String "task-empty-fallback");
    ("base_branch", `String "main");
    ("repo_name", `String "test-repo");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (_ok, msg) ->
    check bool "empty agent_name arg does not trip spoof gate" false
      (contains "agent_name mismatch" msg)

let test_dispatch_worktree_create_whitespace_agent_trimmed () =
  (* Trailing/leading whitespace must be trimmed before the spoof
     check so a 9B model that sends " " by mistake still gets the
     empty-fallback path, not a mismatch rejection. *)
  let ctx = make_ctx () in
  let args = `Assoc [
    ("agent_name", `String "   ");
    ("task_id", `String "task-ws");
    ("base_branch", `String "main");
    ("repo_name", `String "test-repo");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (_ok, msg) ->
    check bool "whitespace agent_name trimmed to fallback" false
      (contains "agent_name mismatch" msg)

let test_dispatch_worktree_create_reports_missing_sandbox_clone () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run_ok ~cwd:base_path "git init -q -b main";
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_worktree.context = { config; agent_name = "test-agent" } in
  let args = `Assoc [
    ("task_id", `String "task-missing-clone");
    ("repo_name", `String "masc-mcp");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (true, msg) ->
    fail ("expected missing_sandbox_clone error, got success: " ^ msg)
  | Some (false, msg) ->
    if not (contains "missing_sandbox_clone:" msg) then
      fail (Printf.sprintf "expected missing_sandbox_clone in: %s" msg);
    if not (contains "keeper_shell op=git_clone" msg) then
      fail (Printf.sprintf "expected keeper_shell git_clone hint in: %s" msg)

let test_dispatch_worktree_create_auto_provisions_workspace_repo () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  init_process_eio env;
  run_ok ~cwd:base_path "git init -q -b main";
  ignore
    (setup_nested_repo_with_remote ~base_path
       ~repo_rel:"workspace/yousleepwhen/masc-mcp");
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_worktree.context = { config; agent_name = "test-agent" } in
  let task_id = "task-auto-clone" in
  let args = `Assoc [
    ("task_id", `String task_id);
    ("repo_name", `String "masc-mcp");
    ("base_branch", `String "main");
  ] in
  let sandbox_clone =
    Filename.concat base_path ".masc/playground/test-agent/repos/masc-mcp"
  in
  let worktree_path =
    Filename.concat sandbox_clone
      (Filename.concat ".worktrees"
         (Playground_paths.worktree_dir_name "test-agent" task_id))
  in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (false, msg) ->
      fail (Printf.sprintf "expected auto-provision success, got error: %s" msg)
  | Some (true, msg) ->
      check bool "message mentions auto-provision" true
        (contains "auto-provisioned" msg);
      check bool "sandbox clone created" true (Sys.file_exists sandbox_clone);
      check bool "worktree created" true (Sys.file_exists worktree_path)

let test_dispatch_worktree_create_auto_provisions_after_file_storm () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  init_process_eio env;
  run_ok ~cwd:base_path "git init -q -b main";
  create_file_storm ~base_path ~count:4005;
  ignore
    (setup_nested_repo_with_remote ~base_path
       ~repo_rel:"workspace/yousleepwhen/masc-mcp");
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_worktree.context = { config; agent_name = "test-agent" } in
  let task_id = "task-auto-clone-files" in
  let args = `Assoc [
    ("task_id", `String task_id);
    ("repo_name", `String "masc-mcp");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (false, msg) ->
      fail (Printf.sprintf "expected auto-provision success after file storm, got error: %s" msg)
  | Some (true, msg) ->
      check bool "message mentions auto-provision" true
        (contains "auto-provisioned" msg)

let test_dispatch_worktree_create_auto_provisions_before_hidden_dir_storm () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  init_process_eio env;
  run_ok ~cwd:base_path "git init -q -b main";
  create_hidden_dir_storm ~base_path ~count:4005;
  ignore
    (setup_nested_repo_with_remote ~base_path
       ~repo_rel:"workspace/yousleepwhen/masc-mcp");
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_worktree.context = { config; agent_name = "test-agent" } in
  let task_id = "task-auto-clone-hidden-dirs" in
  let args = `Assoc [
    ("task_id", `String task_id);
    ("repo_name", `String "masc-mcp");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (false, msg) ->
      fail
        (Printf.sprintf
           "expected auto-provision success before hidden dir storm, got error: %s"
           msg)
  | Some (true, msg) ->
      check bool "message mentions auto-provision" true
        (contains "auto-provisioned" msg)

let test_dispatch_worktree_create_auto_provisions_before_wide_workspace_storm ()
    =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  init_process_eio env;
  run_ok ~cwd:base_path "git init -q -b main";
  create_wide_workspace_storm ~base_path ~count:4005;
  ignore
    (setup_nested_repo_with_remote ~base_path
       ~repo_rel:"workspace/yousleepwhen/masc-mcp");
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_worktree.context = { config; agent_name = "test-agent" } in
  let task_id = "task-auto-clone-bfs" in
  let args = `Assoc [
    ("task_id", `String task_id);
    ("repo_name", `String "masc-mcp");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (false, msg) ->
      fail
        (Printf.sprintf
           "expected auto-provision success before wide workspace storm, got error: %s"
           msg)
  | Some (true, msg) ->
      check bool "message mentions auto-provision" true
        (contains "auto-provisioned" msg)

let test_dispatch_worktree_create_and_remove_use_docker_keeper_lane () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  init_process_eio env;
  run_ok ~cwd:base_path "git init -q -b main";
  ignore
    (setup_nested_repo_with_remote ~base_path
       ~repo_rel:"workspace/yousleepwhen/masc-mcp");
  write_keeper_toml ~base_path ~name:"sangsu" ~sandbox_profile:"docker";
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "sangsu"));
  let ctx : Tool_worktree.context = { config; agent_name = "sangsu" } in
  let task_id = "task-auto-clone-docker" in
  let create_args = `Assoc [
    ("task_id", `String task_id);
    ("repo_name", `String "masc-mcp");
    ("base_branch", `String "main");
  ] in
  let docker_clone =
    Filename.concat base_path ".masc/playground/docker/sangsu/repos/masc-mcp"
  in
  let docker_worktree =
    Filename.concat docker_clone
      (Filename.concat ".worktrees"
         (Playground_paths.worktree_dir_name "sangsu" task_id))
  in
  let docker_visible_worktree =
    Filename.concat
      (Filename.concat
         (Filename.concat
            (Filename.concat
               Env_config_keeper.DockerPlayground.container_playground_root
               "sangsu")
            "repos")
         "masc-mcp")
      (Filename.concat ".worktrees"
         (Playground_paths.worktree_dir_name "sangsu" task_id))
  in
  let legacy_worktree =
    Filename.concat base_path
      (Filename.concat ".masc/playground/sangsu/repos/masc-mcp/.worktrees"
         (Playground_paths.worktree_dir_name "sangsu" task_id))
  in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args:create_args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (false, msg) ->
      fail
        (Printf.sprintf
           "expected docker keeper auto-provision success, got error: %s"
           msg)
  | Some (true, msg) ->
      check bool "message mentions auto-provision" true
        (contains "auto-provisioned" msg);
      check bool "message contains docker-visible worktree path" true
        (contains docker_visible_worktree msg);
      check bool "message hides host docker worktree path" false
        (contains docker_worktree msg);
      check bool "message tells keeper to pass cwd to keeper_bash" true
        (contains "keeper_bash cwd=" msg);
      check bool "docker sandbox clone created" true
        (Sys.file_exists docker_clone);
      check bool "docker worktree created" true
        (Sys.file_exists docker_worktree);
      check bool "legacy worktree untouched" false
        (Sys.file_exists legacy_worktree);
      let remove_args = `Assoc [ ("task_id", `String task_id) ] in
      match Tool_worktree.dispatch ctx ~name:"masc_worktree_remove" ~args:remove_args with
      | None -> fail "dispatch returned None for masc_worktree_remove"
      | Some (false, remove_msg) ->
          fail
            (Printf.sprintf
               "expected docker keeper remove success, got error: %s"
               remove_msg)
      | Some (true, _remove_msg) ->
          check bool "docker worktree removed" false
            (Sys.file_exists docker_worktree)

let test_dispatch_worktree_create_repairs_existing_sandbox_clone_checkout () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  init_process_eio env;
  run_ok ~cwd:base_path "git init -q -b main";
  let source_repo =
    setup_nested_repo_with_remote ~base_path
      ~repo_rel:"workspace/yousleepwhen/masc-mcp"
  in
  write_keeper_toml ~base_path ~name:"sangsu" ~sandbox_profile:"docker";
  let sandbox_repos =
    Filename.concat base_path ".masc/playground/docker/sangsu/repos"
  in
  ensure_dir sandbox_repos;
  let sandbox_clone = Filename.concat sandbox_repos "masc-mcp" in
  run_ok ~cwd:base_path
    (Printf.sprintf "git clone -q %s %s"
       (Filename.quote source_repo) (Filename.quote sandbox_clone));
  clear_checkout_but_keep_git_dir sandbox_clone;
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "sangsu"));
  let ctx : Tool_worktree.context = { config; agent_name = "sangsu" } in
  let task_id = "task-restore-clone" in
  let args = `Assoc [
    ("task_id", `String task_id);
    ("repo_name", `String "masc-mcp");
    ("base_branch", `String "main");
  ] in
  let restored_readme = Filename.concat sandbox_clone "README.md" in
  let docker_worktree =
    Filename.concat sandbox_clone
      (Filename.concat ".worktrees"
         (Playground_paths.worktree_dir_name "sangsu" task_id))
  in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (false, msg) ->
      fail
        (Printf.sprintf
           "expected broken sandbox clone checkout to be repaired, got error: %s"
           msg)
  | Some (true, msg) ->
      check bool "message mentions checkout restore" true
        (contains "restored from HEAD" msg);
      check bool "sandbox clone checkout restored" true
        (Sys.file_exists restored_readme);
      check bool "docker worktree created after repair" true
        (Sys.file_exists docker_worktree)

let test_dispatch_worktree_create_cleans_failed_auto_clone () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  init_process_eio env;
  run_ok ~cwd:base_path "git init -q -b main";
  let broken_source =
    Filename.concat base_path "workspace/yousleepwhen/masc-mcp"
  in
  ensure_dir (Filename.concat broken_source ".git");
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_worktree.context = { config; agent_name = "test-agent" } in
  let args = `Assoc [
    ("task_id", `String "task-clone-fail");
    ("repo_name", `String "masc-mcp");
    ("base_branch", `String "main");
  ] in
  let sandbox_clone =
    Filename.concat base_path ".masc/playground/test-agent/repos/masc-mcp"
  in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (true, msg) ->
      fail
        (Printf.sprintf
           "expected auto-provision clone failure, got success: %s"
           msg)
  | Some (false, msg) ->
      check_contains "message mentions auto-provision failure"
        "auto_provision_clone_failed" msg;
      check bool "partial sandbox clone was cleaned" false
        (Sys.file_exists sandbox_clone)

let test_dispatch_worktree_create_rejects_invalid_sandbox_clone () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  init_process_eio env;
  run_ok ~cwd:base_path "git init -q -b main";
  let sandbox_clone =
    Filename.concat base_path ".masc/playground/test-agent/repos/masc-mcp"
  in
  ensure_dir (Filename.concat sandbox_clone ".git");
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_worktree.context = { config; agent_name = "test-agent" } in
  let args = `Assoc [
    ("task_id", `String "task-invalid-clone");
    ("repo_name", `String "masc-mcp");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (true, msg) ->
      fail
        (Printf.sprintf
           "expected invalid sandbox clone failure, got success: %s"
           msg)
  | Some (false, msg) ->
      check_contains "message mentions invalid sandbox clone"
        "sandbox_clone_invalid" msg;
      check bool "invalid sandbox clone was preserved" true
        (Sys.file_exists sandbox_clone)

let test_worktree_path_rejects_traversal_name () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let root = Filename.concat base_path "repo" in
  ensure_dir root;
  match Masc_mcp.Coord.ensure_worktree_path root "../escape" with
  | Ok (worktree_path, _) ->
      fail ("expected invalid worktree path, got: " ^ worktree_path)
  | Error (Masc_domain.System (Masc_domain.System_error.IoError msg)) ->
      check_contains "message mentions invalid worktree path"
        "Invalid worktree path" msg
  | Error err ->
      fail ("expected IoError, got: " ^ Masc_domain.masc_error_to_string err)

let test_worktree_create_rejects_existing_non_git_worktree_path () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  init_process_eio env;
  run_ok ~cwd:base_path "git init -q -b main";
  let source_repo =
    setup_nested_repo_with_remote ~base_path
      ~repo_rel:"workspace/yousleepwhen/masc-mcp"
  in
  let sandbox_repos =
    Filename.concat base_path ".masc/playground/test-agent/repos"
  in
  ensure_dir sandbox_repos;
  let sandbox_clone = Filename.concat sandbox_repos "masc-mcp" in
  run_ok ~cwd:base_path
    (Printf.sprintf "git clone -q %s %s"
       (Filename.quote source_repo) (Filename.quote sandbox_clone));
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_worktree.context = { config; agent_name = "test-agent" } in
  let task_id = "task-plain-dir-conflict" in
  let worktree_path =
    Filename.concat sandbox_clone
      (Filename.concat ".worktrees"
         (Playground_paths.worktree_dir_name "test-agent" task_id))
  in
  ensure_dir worktree_path;
  let args = `Assoc [
    ("task_id", `String task_id);
    ("repo_name", `String "masc-mcp");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (true, msg) ->
      fail
        (Printf.sprintf
           "expected existing non-git worktree path failure, got success: %s"
           msg)
  | Some (false, msg) ->
      check_contains "message mentions worktree path conflict"
        "worktree_path_conflict" msg;
      check bool "plain directory conflict was preserved" true
        (Sys.file_exists worktree_path)

let test_worktree_create_concurrent_same_name_converges () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  init_process_eio env;
  run_ok ~cwd:base_path "git init -q -b main";
  let source_repo =
    setup_nested_repo_with_remote ~base_path
      ~repo_rel:"workspace/yousleepwhen/masc-mcp"
  in
  let sandbox_repos =
    Filename.concat base_path ".masc/playground/race-agent/repos"
  in
  ensure_dir sandbox_repos;
  let sandbox_clone = Filename.concat sandbox_repos "masc-mcp" in
  run_ok ~cwd:base_path
    (Printf.sprintf "git clone -q %s %s"
       (Filename.quote source_repo) (Filename.quote sandbox_clone));
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "race-agent"));
  let task_id = "task-race-create" in
  let create_once () =
    Masc_mcp.Coord.worktree_create_r ~link_task:false ~repo_name:"masc-mcp"
      config ~agent_name:"race-agent" ~task_id ~base_branch:"main"
  in
  let left = ref None in
  let right = ref None in
  Eio.Fiber.both
    (fun () -> left := Some (create_once ()))
    (fun () -> right := Some (create_once ()));
  let unwrap label = function
    | Some (Ok msg) -> msg
    | Some (Error err) ->
        fail
          (Printf.sprintf "%s failed: %s" label
             (Masc_domain.masc_error_to_string err))
    | None -> fail (label ^ " did not run")
  in
  let left_msg = unwrap "left create" !left in
  let right_msg = unwrap "right create" !right in
  let messages = [ left_msg; right_msg ] in
  let count_matching needle =
    List.fold_left
      (fun count msg -> if contains needle msg then count + 1 else count)
      0 messages
  in
  let worktree_path =
    Filename.concat sandbox_clone
      (Filename.concat ".worktrees"
         (Playground_paths.worktree_dir_name "race-agent" task_id))
  in
  check bool "concurrent worktree exists" true
    (Sys.file_exists worktree_path);
  check int "one create wins" 1 (count_matching "Worktree created");
  check int "one create observes existing" 1
    (count_matching "Worktree already exists")

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Tool_worktree Coverage" [
    "get_string", [
      test_case "exists" `Quick test_get_string_exists;
      test_case "missing" `Quick test_get_string_missing;
      test_case "base_branch" `Quick test_get_string_base_branch;
      test_case "base_branch_default" `Quick test_get_string_base_branch_default;
    ];
    "context", [
      test_case "creation" `Quick test_context_creation;
    ];
    "dispatch", [
      test_case "worktree_create" `Quick test_dispatch_worktree_create;
      test_case "worktree_remove" `Quick test_dispatch_worktree_remove;
      test_case "worktree_list" `Quick test_dispatch_worktree_list;
      test_case "unknown" `Quick test_dispatch_unknown_tool;
      test_case "remove schema requires only task_id" `Quick
        test_remove_schema_requires_only_task_id;
    ];
    "agent_name_spoof", [
      test_case "spoofed agent_name blocked" `Quick
        test_dispatch_worktree_create_spoofed_agent_blocked;
      test_case "matching agent_name passes spoof gate" `Quick
        test_dispatch_worktree_create_matching_agent_passes_check;
      test_case "empty agent_name falls back to ctx" `Quick
        test_dispatch_worktree_create_empty_agent_falls_back;
      test_case "whitespace agent_name trimmed" `Quick
        test_dispatch_worktree_create_whitespace_agent_trimmed;
      test_case "missing sandbox clone is explicit" `Quick
        test_dispatch_worktree_create_reports_missing_sandbox_clone;
      test_case "workspace repo auto-provisions sandbox clone" `Quick
        test_dispatch_worktree_create_auto_provisions_workspace_repo;
      test_case "workspace repo auto-provisions after file storm" `Quick
        test_dispatch_worktree_create_auto_provisions_after_file_storm;
      test_case "workspace repo wins before hidden dir storm" `Quick
        test_dispatch_worktree_create_auto_provisions_before_hidden_dir_storm;
      test_case "workspace repo wins before wide workspace storm" `Quick
        test_dispatch_worktree_create_auto_provisions_before_wide_workspace_storm;
      test_case "docker keeper uses docker lane for create/remove" `Quick
        test_dispatch_worktree_create_and_remove_use_docker_keeper_lane;
      test_case "broken sandbox clone checkout is restored" `Quick
        test_dispatch_worktree_create_repairs_existing_sandbox_clone_checkout;
      test_case "failed auto-provision clone is cleaned" `Quick
        test_dispatch_worktree_create_cleans_failed_auto_clone;
      test_case "invalid sandbox clone is rejected" `Quick
        test_dispatch_worktree_create_rejects_invalid_sandbox_clone;
      test_case "worktree path traversal is rejected" `Quick
        test_worktree_path_rejects_traversal_name;
      test_case "existing non-git worktree path is rejected" `Quick
        test_worktree_create_rejects_existing_non_git_worktree_path;
      test_case "concurrent same-name worktree create converges" `Quick
        test_worktree_create_concurrent_same_name_converges;
    ];
  ]
