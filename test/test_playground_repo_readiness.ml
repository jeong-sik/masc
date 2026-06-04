(** Playground_repo_readiness tests. *)

open Alcotest

module Keeper_types = Masc.Keeper_types
module Keeper_types_profile_sandbox = Masc.Keeper_types_profile_sandbox

let make_meta ?(sandbox = Keeper_types_profile_sandbox.Docker) name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "repo readiness test");
        ( "sandbox_profile",
          `String (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox) );
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let temp_dir prefix =
  let base = Filename.get_temp_dir_name () in
  let rec loop n =
    let path =
      Filename.concat base
        (Printf.sprintf "%s-%d-%06d" prefix (Unix.getpid ()) n)
    in
    if Sys.file_exists path then loop (n + 1)
    else (
      Unix.mkdir path 0o755;
      path)
  in
  loop (Random.int 1_000_000)

let mkdir_p path =
  let rec ensure dir =
    if dir = "" || dir = "." || Sys.file_exists dir then ()
    else (
      ensure (Filename.dirname dir);
      Unix.mkdir dir 0o755)
  in
  ensure path

let read_file_trim path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len |> String.trim)

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let json_bool key json =
  Yojson.Safe.Util.(json |> member key |> to_bool)

let json_string key json =
  Yojson.Safe.Util.(json |> member key |> to_string)

let normalize_path path =
  Masc.Keeper_alerting_path.normalize_path_for_check path
  |> Masc.Keeper_alerting_path.strip_trailing_slashes

let test_missing_clone () =
  let base_path = temp_dir "masc-repo-readiness" in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc.Playground_repo_readiness.inspect ~config
      ~meta ~repo:"jeong-sik/masc" ()
  in
  check bool "not ok" false (json_bool "ok" json);
  check string "state" "missing_clone" (json_string "state" json);
  check string "repo_name" "masc" (json_string "repo_name" json);
  check bool "exists" false (json_bool "exists" json)

let test_non_git_clone () =
  let base_path = temp_dir "masc-repo-readiness" in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let clone_path =
    Masc.Playground_repo_readiness.clone_path ~config
      ~meta ~repo_name:"masc"
  in
  mkdir_p clone_path;
  let json =
    Masc.Playground_repo_readiness.inspect ~config
      ~meta ~repo:"jeong-sik/masc" ()
  in
  check bool "not ok" false (json_bool "ok" json);
  check string "state" "not_git_repo" (json_string "state" json);
  check bool "exists" true (json_bool "exists" json);
  check bool "is_git_repo" false (json_bool "is_git_repo" json)

let test_invalid_repo_name () =
  let base_path = temp_dir "masc-repo-readiness" in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc.Playground_repo_readiness.inspect ~config
      ~meta ~repo_name:"../escape" ()
  in
  check bool "not ok" false (json_bool "ok" json);
  check string "state" "invalid_repo_name" (json_string "state" json)

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let run_process ~cwd prog argv =
  let out = Filename.temp_file "keeper-repo-readiness-out" ".txt" in
  let err = Filename.temp_file "keeper-repo-readiness-err" ".txt" in
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
        Unix.create_process prog argv Unix.stdin out_fd err_fd)
  in
  let _, status = Unix.waitpid [] pid in
  let code =
    match status with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255
  in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (code, stdout, stderr)

let run_process_ok ~cwd prog argv =
  let code, stdout, stderr = run_process ~cwd prog argv in
  if code <> 0 then
    fail
      (Printf.sprintf "command failed (%d): %s\nstdout:\n%s\nstderr:\n%s" code
         prog stdout stderr)

let git_ok ~cwd args =
  run_process_ok ~cwd "git" (Array.of_list ("git" :: args))

let git_output ~cwd args =
  let result =
    Masc.Playground_repo_readiness.run_git
      ~timeout_sec:Masc.Playground_repo_readiness.read_only_probe_timeout_sec
      ~clone_path:cwd
      args
  in
  if result.ok then result.output
  else
    fail
      (Printf.sprintf "git command failed: git -C %s %s\n%s" cwd
         (String.concat " " args)
         result.output)

let test_parent_git_checkout_does_not_count_as_clone () =
  let base_path = temp_dir "masc-repo-readiness" in
  git_ok ~cwd:base_path [ "init"; "-q"; "--initial-branch=main" ];
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let clone_path =
    Masc.Playground_repo_readiness.clone_path ~config
      ~meta ~repo_name:"masc"
  in
  mkdir_p clone_path;
  let json =
    Masc.Playground_repo_readiness.inspect ~config
      ~meta ~repo:"jeong-sik/masc" ()
  in
  check bool "not ok" false (json_bool "ok" json);
  check string "state" "not_git_repo" (json_string "state" json);
  check bool "exists" true (json_bool "exists" json);
  check bool "is_git_repo" false (json_bool "is_git_repo" json);
  check string "parent top-level surfaced" (normalize_path base_path)
    Yojson.Safe.Util.(json |> member "git_toplevel" |> to_string |> normalize_path)

let create_file_storm ~base_path ~count =
  for i = 0 to count - 1 do
    let path = Filename.concat base_path (Printf.sprintf "aa-%04d.tmp" i) in
    let oc = open_out path in
    output_string oc "x\n";
    close_out oc
  done

let create_hidden_dir_storm ~base_path ~count =
  let root = Filename.concat base_path ".venvs/storm" in
  mkdir_p root;
  for i = 0 to count - 1 do
    Unix.mkdir (Filename.concat root (Printf.sprintf "aa-%04d" i)) 0o755
  done

let create_wide_workspace_storm ~base_path ~count =
  let root = Filename.concat base_path "workspace/aaa-big" in
  mkdir_p root;
  for i = 0 to count - 1 do
    Unix.mkdir (Filename.concat root (Printf.sprintf "aa-%04d" i)) 0o755
  done

let init_git_repo path =
  mkdir_p path;
  git_ok ~cwd:path [ "init"; "-q"; "--initial-branch=main" ]

let set_workspace_origin_to_github ~repo =
  git_ok ~cwd:repo
    [
      "remote";
      "set-url";
      "origin";
      "https://github.com/jeong-sik/masc.git";
    ]

let test_auto_provisionable_workspace_repo () =
  let base_path = temp_dir "masc-repo-readiness" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc" in
  let remote = Filename.concat base_path ".remote-masc.git" in
  mkdir_p (Filename.dirname repo);
  git_ok ~cwd:base_path [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; repo ];
  git_ok ~cwd:repo [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:repo [ "config"; "user.name"; "Test" ];
  let readme = Filename.concat repo "README.md" in
  let oc = open_out readme in
  output_string oc "# readiness\n";
  close_out oc;
  git_ok ~cwd:repo [ "add"; "README.md" ];
  git_ok ~cwd:repo [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:repo [ "push"; "-q"; "origin"; "main" ];
  set_workspace_origin_to_github ~repo;
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc.Playground_repo_readiness.inspect ~config
      ~meta ~repo_name:"masc" ()
  in
  check bool "ok" true (json_bool "ok" json);
  check string "state" "auto_provisionable" (json_string "state" json);
  check string "workspace repo match" repo
    Yojson.Safe.Util.(json |> member "workspace_repo_match" |> to_string);
  check string "workspace repo origin"
    "jeong-sik/masc"
    Yojson.Safe.Util.(
      json |> member "workspace_repo_origin" |> to_string
      |> fun url ->
      url)

let test_missing_clone_skips_workspace_discovery () =
  let base_path = temp_dir "masc-repo-readiness" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc" in
  let remote = Filename.concat base_path ".remote-masc.git" in
  mkdir_p (Filename.dirname repo);
  git_ok ~cwd:base_path [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; repo ];
  git_ok ~cwd:repo [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:repo [ "config"; "user.name"; "Test" ];
  let readme = Filename.concat repo "README.md" in
  let oc = open_out readme in
  output_string oc "# readiness\n";
  close_out oc;
  git_ok ~cwd:repo [ "add"; "README.md" ];
  git_ok ~cwd:repo [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:repo [ "push"; "-q"; "origin"; "main" ];
  set_workspace_origin_to_github ~repo;
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc.Playground_repo_readiness.inspect ~config ~meta
      ~repo_name:"masc" ()
  in
  check bool "not ok" false (json_bool "ok" json);
  check string "state" "missing_clone" (json_string "state" json)

let test_auto_provisionable_workspace_repo_after_file_storm () =
  let base_path = temp_dir "masc-repo-readiness" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc" in
  let remote = Filename.concat base_path ".remote-masc.git" in
  create_file_storm ~base_path ~count:4005;
  mkdir_p (Filename.dirname repo);
  git_ok ~cwd:base_path [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; repo ];
  git_ok ~cwd:repo [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:repo [ "config"; "user.name"; "Test" ];
  let readme = Filename.concat repo "README.md" in
  let oc = open_out readme in
  output_string oc "# readiness\n";
  close_out oc;
  git_ok ~cwd:repo [ "add"; "README.md" ];
  git_ok ~cwd:repo [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:repo [ "push"; "-q"; "origin"; "main" ];
  set_workspace_origin_to_github ~repo;
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc.Playground_repo_readiness.inspect ~config
      ~meta ~repo_name:"masc" ()
  in
  check bool "ok" true (json_bool "ok" json);
  check string "state" "auto_provisionable" (json_string "state" json);
  check string "workspace repo match" repo
    Yojson.Safe.Util.(json |> member "workspace_repo_match" |> to_string)

let test_auto_provisionable_workspace_repo_before_hidden_dir_storm () =
  let base_path = temp_dir "masc-repo-readiness" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc" in
  let remote = Filename.concat base_path ".remote-masc.git" in
  create_hidden_dir_storm ~base_path ~count:4005;
  mkdir_p (Filename.dirname repo);
  git_ok ~cwd:base_path [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; repo ];
  git_ok ~cwd:repo [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:repo [ "config"; "user.name"; "Test" ];
  let readme = Filename.concat repo "README.md" in
  let oc = open_out readme in
  output_string oc "# readiness\n";
  close_out oc;
  git_ok ~cwd:repo [ "add"; "README.md" ];
  git_ok ~cwd:repo [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:repo [ "push"; "-q"; "origin"; "main" ];
  set_workspace_origin_to_github ~repo;
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc.Playground_repo_readiness.inspect ~config
      ~meta ~repo_name:"masc" ()
  in
  check bool "ok" true (json_bool "ok" json);
  check string "state" "auto_provisionable" (json_string "state" json);
  check string "workspace repo match" repo
    Yojson.Safe.Util.(json |> member "workspace_repo_match" |> to_string)

let test_auto_provisionable_workspace_repo_before_wide_workspace_storm () =
  let base_path = temp_dir "masc-repo-readiness" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc" in
  let remote = Filename.concat base_path ".remote-masc.git" in
  create_wide_workspace_storm ~base_path ~count:4005;
  mkdir_p (Filename.dirname repo);
  git_ok ~cwd:base_path [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; repo ];
  git_ok ~cwd:repo [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:repo [ "config"; "user.name"; "Test" ];
  let readme = Filename.concat repo "README.md" in
  let oc = open_out readme in
  output_string oc "# readiness\n";
  close_out oc;
  git_ok ~cwd:repo [ "add"; "README.md" ];
  git_ok ~cwd:repo [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:repo [ "push"; "-q"; "origin"; "main" ];
  set_workspace_origin_to_github ~repo;
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc.Playground_repo_readiness.inspect ~config
      ~meta ~repo_name:"masc" ()
  in
  check bool "ok" true (json_bool "ok" json);
  check string "state" "auto_provisionable" (json_string "state" json);
  check string "workspace repo match" repo
    Yojson.Safe.Util.(json |> member "workspace_repo_match" |> to_string)


let test_ensure_worktree_ready_creates_worktree () =
  let base_path = temp_dir "masc-worktree-ready" in
  let remote = Filename.concat base_path ".remote-masc.git" in
  (* Create a bare remote repo *)
  git_ok ~cwd:base_path [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  (* Clone into the sandbox path *)
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let clone_path =
    Masc.Playground_repo_readiness.clone_path ~config ~meta ~repo_name:"masc"
  in
  mkdir_p (Filename.dirname clone_path);
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; clone_path ];
  git_ok ~cwd:clone_path [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:clone_path [ "config"; "user.name"; "Test" ];
  let readme = Filename.concat clone_path "README.md" in
  let oc = open_out readme in
  output_string oc "# test\n";
  close_out oc;
  git_ok ~cwd:clone_path [ "add"; "README.md" ];
  git_ok ~cwd:clone_path [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:clone_path [ "push"; "-q"; "origin"; "main" ];
  (* Worktree path *)
  let worktree_path =
    Filename.concat clone_path ".worktrees/task-575-test"
  in
  (* Call ensure_worktree_ready *)
  let result =
    Masc.Playground_repo_readiness.ensure_worktree_ready
      ~config ~meta ~repo_name:"masc" ~task_name:"task-575-test"
      ~worktree_path ()
  in
  (match result with
   | Ok () -> ()
   | Error msg -> fail ("ensure_worktree_ready failed: " ^ msg));
  (* Verify worktree exists and is a valid git checkout *)
  check bool "worktree dir exists" true (Sys.file_exists worktree_path);
  check bool "worktree is directory" true (Sys.is_directory worktree_path);
  let probe =
    Masc.Playground_repo_readiness.run_git
      ~timeout_sec:Masc.Playground_repo_readiness.read_only_probe_timeout_sec
      ~clone_path:worktree_path
      [ "rev-parse"; "--show-toplevel" ]
  in
  check bool "worktree is valid git checkout" true probe.ok

let test_ensure_worktree_ready_idempotent () =
  let base_path = temp_dir "masc-worktree-ready" in
  let remote = Filename.concat base_path ".remote-masc.git" in
  git_ok ~cwd:base_path [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let clone_path =
    Masc.Playground_repo_readiness.clone_path ~config ~meta ~repo_name:"masc"
  in
  mkdir_p (Filename.dirname clone_path);
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; clone_path ];
  git_ok ~cwd:clone_path [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:clone_path [ "config"; "user.name"; "Test" ];
  let readme = Filename.concat clone_path "README.md" in
  let oc = open_out readme in
  output_string oc "# test\n";
  close_out oc;
  git_ok ~cwd:clone_path [ "add"; "README.md" ];
  git_ok ~cwd:clone_path [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:clone_path [ "push"; "-q"; "origin"; "main" ];
  let worktree_path =
    Filename.concat clone_path ".worktrees/task-idem-test"
  in
  (* First call creates the worktree *)
  let r1 =
    Masc.Playground_repo_readiness.ensure_worktree_ready
      ~config ~meta ~repo_name:"masc" ~task_name:"task-idem-test"
      ~worktree_path ()
  in
  (match r1 with Ok () -> () | Error msg -> fail ("first call failed: " ^ msg));
  (* Second call should succeed without error (idempotent) *)
  let r2 =
    Masc.Playground_repo_readiness.ensure_worktree_ready
      ~config ~meta ~repo_name:"masc" ~task_name:"task-idem-test"
      ~worktree_path ()
  in
  match r2 with
  | Ok () -> ()
  | Error msg -> fail ("second call failed: " ^ msg)

let test_ensure_worktree_ready_normalizes_gitdir_pointer () =
  let base_path = temp_dir "masc-worktree-ready-gitdir" in
  let remote = Filename.concat base_path ".remote-masc.git" in
  git_ok ~cwd:base_path [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let clone_path =
    Masc.Playground_repo_readiness.clone_path ~config ~meta ~repo_name:"masc"
  in
  mkdir_p (Filename.dirname clone_path);
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; clone_path ];
  git_ok ~cwd:clone_path [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:clone_path [ "config"; "user.name"; "Test" ];
  let readme = Filename.concat clone_path "README.md" in
  write_file readme "# test\n";
  git_ok ~cwd:clone_path [ "add"; "README.md" ];
  git_ok ~cwd:clone_path [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:clone_path [ "push"; "-q"; "origin"; "main" ];
  let task_name = "task-relative-gitdir-test" in
  let worktree_path = Filename.concat clone_path (".worktrees/" ^ task_name) in
  let r1 =
    Masc.Playground_repo_readiness.ensure_worktree_ready
      ~config ~meta ~repo_name:"masc" ~task_name ~worktree_path ()
  in
  (match r1 with
   | Ok () -> ()
   | Error msg -> fail ("first call failed: " ^ msg));
  let git_file = Filename.concat worktree_path ".git" in
  let absolute_gitdir =
    Filename.concat
      (Filename.concat (Filename.concat clone_path ".git") "worktrees")
      task_name
  in
  write_file git_file ("gitdir: " ^ absolute_gitdir ^ "\n");
  let r2 =
    Masc.Playground_repo_readiness.ensure_worktree_ready
      ~config ~meta ~repo_name:"masc" ~task_name ~worktree_path ()
  in
  (match r2 with
   | Ok () -> ()
   | Error msg -> fail ("second call failed: " ^ msg));
  check string "worktree gitdir is container-safe relative"
    ("gitdir: ../../.git/worktrees/" ^ task_name)
    (read_file_trim git_file);
  let status =
    Masc.Playground_repo_readiness.run_git
      ~timeout_sec:Masc.Playground_repo_readiness.read_only_probe_timeout_sec
      ~clone_path:worktree_path
      [ "status"; "--short" ]
  in
  check bool "relative gitdir remains host-git usable" true status.ok

let test_ensure_worktree_ready_rejects_nested_plain_directory () =
  let base_path = temp_dir "masc-worktree-ready-nested" in
  let remote = Filename.concat base_path ".remote-masc.git" in
  git_ok ~cwd:base_path [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let clone_path =
    Masc.Playground_repo_readiness.clone_path ~config ~meta ~repo_name:"masc"
  in
  mkdir_p (Filename.dirname clone_path);
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; clone_path ];
  git_ok ~cwd:clone_path [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:clone_path [ "config"; "user.name"; "Test" ];
  let readme = Filename.concat clone_path "README.md" in
  let oc = open_out readme in
  output_string oc "# test\n";
  close_out oc;
  git_ok ~cwd:clone_path [ "add"; "README.md" ];
  git_ok ~cwd:clone_path [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:clone_path [ "push"; "-q"; "origin"; "main" ];
  let worktree_path =
    Filename.concat clone_path ".worktrees/task-nested-plain-dir"
  in
  mkdir_p worktree_path;
  let result =
    Masc.Playground_repo_readiness.ensure_worktree_ready
      ~config ~meta ~repo_name:"masc" ~task_name:"task-nested-plain-dir"
      ~worktree_path ()
  in
  (match result with
   | Ok () -> fail "plain nested directory was accepted as a worktree"
   | Error _ -> ());
  let probe =
    Masc.Playground_repo_readiness.run_git
      ~timeout_sec:Masc.Playground_repo_readiness.read_only_probe_timeout_sec
      ~clone_path:worktree_path
      [ "rev-parse"; "--show-toplevel" ]
  in
  check bool "nested dir still resolves through parent git" true probe.ok;
  check string "nested dir toplevel is parent clone" (normalize_path clone_path)
    (normalize_path probe.output)

let test_provision_worktrees_creates_worktrees () =
  (* Set up a docker playground with a repo *)
  let base_path = temp_dir "masc-provision" in
  let remote = Filename.concat base_path ".remote-masc.git" in
  git_ok ~cwd:base_path [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  let config = Masc.Workspace.default_config base_path in
  let agent_name = "keeper-provision-test" in
  let safe_name = Playground_paths.sanitize_keeper_name agent_name in
  let repo_dir =
    Filename.concat base_path
      (Printf.sprintf ".masc/playground/docker/%s/repos/test-repo" safe_name)
  in
  mkdir_p (Filename.dirname repo_dir);
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; repo_dir ];
  git_ok ~cwd:repo_dir [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:repo_dir [ "config"; "user.name"; "Test" ];
  let readme = Filename.concat repo_dir "README.md" in
  let oc = open_out readme in
  output_string oc "# test\n";
  close_out oc;
  git_ok ~cwd:repo_dir [ "add"; "README.md" ];
  git_ok ~cwd:repo_dir [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:repo_dir [ "push"; "-q"; "origin"; "main" ];
  (* Call provision *)
  let task_id = "task-provision-001" in
  Masc.Playground_repo_readiness.provision_worktrees_for_task
    ~config ~agent_name ~task_id ();
  (* Verify worktree was created *)
  let worktree_path =
    Filename.concat repo_dir (Printf.sprintf ".worktrees/%s" task_id)
  in
  check bool "worktree dir exists" true (Sys.file_exists worktree_path);
  check bool "worktree is directory" true (Sys.is_directory worktree_path);
  let probe =
    Masc.Playground_repo_readiness.run_git
      ~timeout_sec:Masc.Playground_repo_readiness.read_only_probe_timeout_sec
      ~clone_path:worktree_path
      [ "rev-parse"; "--show-toplevel" ]
  in
  check bool "worktree is valid git checkout" true probe.ok

let test_provision_worktrees_uses_origin_base_with_dirty_parent () =
  let base_path = temp_dir "masc-provision-dirty-parent" in
  let remote = Filename.concat base_path ".remote-masc.git" in
  git_ok ~cwd:base_path [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  let config = Masc.Workspace.default_config base_path in
  let agent_name = "keeper-provision-dirty-parent" in
  let safe_name = Playground_paths.sanitize_keeper_name agent_name in
  let repo_dir =
    Filename.concat base_path
      (Printf.sprintf ".masc/playground/docker/%s/repos/test-repo" safe_name)
  in
  mkdir_p (Filename.dirname repo_dir);
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; repo_dir ];
  git_ok ~cwd:repo_dir [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:repo_dir [ "config"; "user.name"; "Test" ];
  let readme = Filename.concat repo_dir "README.md" in
  let oc = open_out readme in
  output_string oc "# test\n";
  close_out oc;
  git_ok ~cwd:repo_dir [ "add"; "README.md" ];
  git_ok ~cwd:repo_dir [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:repo_dir [ "push"; "-q"; "origin"; "main" ];
  git_ok ~cwd:repo_dir [ "checkout"; "-q"; "-b"; "task-575-existing-work" ];
  let oc = open_out readme in
  output_string oc "# dirty parent\n";
  close_out oc;
  let parent_branch = git_output ~cwd:repo_dir [ "branch"; "--show-current" ] in
  let parent_status = git_output ~cwd:repo_dir [ "status"; "--porcelain" ] in
  check string "parent branch" "task-575-existing-work" parent_branch;
  check bool "parent is dirty before" true (String.trim parent_status <> "");
  let origin_main = git_output ~cwd:repo_dir [ "rev-parse"; "origin/main" ] in
  let task_id = "task-635-new-work" in
  Masc.Playground_repo_readiness.provision_worktrees_for_task
    ~config ~agent_name ~task_id ();
  let worktree_path =
    Filename.concat repo_dir (Printf.sprintf ".worktrees/%s" task_id)
  in
  let parent_branch_after =
    git_output ~cwd:repo_dir [ "branch"; "--show-current" ]
  in
  let parent_status_after =
    git_output ~cwd:repo_dir [ "status"; "--porcelain" ]
  in
  check string "parent branch preserved" parent_branch parent_branch_after;
  check bool "parent dirtiness preserved" true
    (String.trim parent_status_after <> "");
  check bool "worktree dir exists" true (Sys.file_exists worktree_path);
  let worktree_top =
    git_output ~cwd:worktree_path [ "rev-parse"; "--show-toplevel" ]
  in
  check string "worktree top" (normalize_path worktree_path)
    (normalize_path worktree_top);
  let worktree_head = git_output ~cwd:worktree_path [ "rev-parse"; "HEAD" ] in
  check string "worktree starts from origin/main" origin_main worktree_head

let test_ensure_worktree_ready_allows_dirty_parent_clone () =
  let base_path = temp_dir "masc-worktree-ready-dirty-parent" in
  let remote = Filename.concat base_path ".remote-masc.git" in
  git_ok ~cwd:base_path [ "init"; "--bare"; "-q"; "--initial-branch=main"; remote ];
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let clone_path =
    Masc.Playground_repo_readiness.clone_path ~config ~meta ~repo_name:"masc"
  in
  mkdir_p (Filename.dirname clone_path);
  git_ok ~cwd:base_path [ "clone"; "-q"; remote; clone_path ];
  git_ok ~cwd:clone_path [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:clone_path [ "config"; "user.name"; "Test" ];
  let readme = Filename.concat clone_path "README.md" in
  let oc = open_out readme in
  output_string oc "# test\n";
  close_out oc;
  git_ok ~cwd:clone_path [ "add"; "README.md" ];
  git_ok ~cwd:clone_path [ "commit"; "-q"; "-m"; "init" ];
  git_ok ~cwd:clone_path [ "push"; "-q"; "origin"; "main" ];
  git_ok ~cwd:clone_path [ "checkout"; "-q"; "-b"; "task-575-existing-work" ];
  let oc = open_out readme in
  output_string oc "# dirty parent\n";
  close_out oc;
  let parent_branch = git_output ~cwd:clone_path [ "branch"; "--show-current" ] in
  let parent_status = git_output ~cwd:clone_path [ "status"; "--porcelain" ] in
  check string "parent branch" "task-575-existing-work" parent_branch;
  check bool "parent is dirty before" true (String.trim parent_status <> "");
  let origin_main = git_output ~cwd:clone_path [ "rev-parse"; "origin/main" ] in
  let worktree_path =
    Filename.concat clone_path ".worktrees/task-635-new-work"
  in
  let result =
    Masc.Playground_repo_readiness.ensure_worktree_ready
      ~config ~meta ~repo_name:"masc" ~task_name:"task-635-new-work"
      ~worktree_path ()
  in
  (match result with
   | Ok () -> ()
   | Error msg -> fail ("ensure_worktree_ready failed: " ^ msg));
  let parent_branch_after =
    git_output ~cwd:clone_path [ "branch"; "--show-current" ]
  in
  let parent_status_after =
    git_output ~cwd:clone_path [ "status"; "--porcelain" ]
  in
  check string "parent branch preserved" parent_branch parent_branch_after;
  check bool "parent dirtiness preserved" true
    (String.trim parent_status_after <> "");
  check bool "worktree dir exists" true (Sys.file_exists worktree_path);
  let worktree_top =
    git_output ~cwd:worktree_path [ "rev-parse"; "--show-toplevel" ]
  in
  check string "worktree top" (normalize_path worktree_path)
    (normalize_path worktree_top);
  let worktree_head = git_output ~cwd:worktree_path [ "rev-parse"; "HEAD" ] in
  check string "worktree starts from origin/main" origin_main worktree_head

let () =
  Random.self_init ();
  run "Playground_repo_readiness"
    [
      "inspect",
      [
        test_case "missing clone" `Quick test_missing_clone;
        test_case "non-git clone" `Quick test_non_git_clone;
        test_case "parent git checkout is not clone" `Quick
          test_parent_git_checkout_does_not_count_as_clone;
        test_case "invalid repo_name" `Quick test_invalid_repo_name;
        test_case "missing clone skips workspace discovery" `Quick
          test_missing_clone_skips_workspace_discovery;
      ];
      "ensure_worktree_ready",
      [
        test_case "creates worktree" `Quick
          test_ensure_worktree_ready_creates_worktree;
        test_case "idempotent" `Quick
          test_ensure_worktree_ready_idempotent;
        test_case "normalizes worktree gitdir pointer" `Quick
          test_ensure_worktree_ready_normalizes_gitdir_pointer;
        test_case "rejects nested plain directory" `Quick
          test_ensure_worktree_ready_rejects_nested_plain_directory;
        test_case "creates worktree from dirty parent clone" `Quick
          test_ensure_worktree_ready_allows_dirty_parent_clone;
      ];
      "provision_worktrees_for_task",
      [
        test_case "creates worktrees at claim time" `Quick
          test_provision_worktrees_creates_worktrees;
        test_case "creates worktree from origin with dirty parent" `Quick
          test_provision_worktrees_uses_origin_base_with_dirty_parent;
      ];
    ]
