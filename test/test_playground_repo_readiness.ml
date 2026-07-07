(** Playground_repo_readiness tests. *)

open Alcotest

module Keeper_types = Keeper_types

(* #20708: read [Masc.Otel_metric_store] directly — the deleted
   [otel_metric_test_store] shim owned a private store production never wrote
   to, so [metric_total] read a permanent 0 and the "projection records no
   decision metrics" assertion below could not observe a real regression. *)

(* [Keeper_sandbox_control] lives inside the wrapped [masc] library.  The
   alias lets call sites keep the existing qualified form, and the open
   brings the status constructors into scope for pattern/expression use. *)
module Keeper_sandbox_control = Masc.Keeper_sandbox_control
open Keeper_sandbox_control

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

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let json_bool key json =
  Yojson.Safe.Util.(json |> member key |> to_bool)

let json_string key json =
  Yojson.Safe.Util.(json |> member key |> to_string)

let json_string_opt key json =
  Yojson.Safe.Util.(json |> member key |> to_string_option)

let repo_mapping_decision_metric_total () =
  let metric_total metric =
    Masc.Otel_metric_store.metric_total Keeper_metrics.(to_string metric)
  in
  List.fold_left
    (fun total metric -> total +. metric_total metric)
    0.0
    [ Keeper_metrics.KeeperRepoMappingDefaultScopeAllowed;
      Keeper_metrics.KeeperRepoMappingDeniedUnregistered;
      Keeper_metrics.KeeperRepoMappingLoadError;
      Keeper_metrics.KeeperRepoMappingRepositoryIdentityMismatch;
      Keeper_metrics.KeeperRepoMappingRepositoryStoreError;
    ]

let write_mapping_raw base_path contents =
  let path = Keeper_repo_mapping.mappings_toml_path base_path in
  mkdir_p (Filename.dirname path);
  write_file path contents

let write_mapping base_path keeper_id repo_ids =
  let mapping =
    Repo_manager_types.make_keeper_repo_mapping ~keeper_id
      ~repository_ids:repo_ids
  in
  match Keeper_repo_mapping.save_mapping ~base_path mapping with
  | Ok () -> ()
  | Error msg -> fail ("write_mapping failed: " ^ msg)

let save_repositories base_path repositories =
  match Repo_store.save_all ~base_path repositories with
  | Ok () -> ()
  | Error msg -> fail ("save_repositories failed: " ^ msg)

let repository_fixture ~id ~name ~url ~local_path : Repo_manager_types.repository =
  { id
  ; name
  ; url
  ; local_path
  ; aliases = []
  ; default_branch = "main"
  ; keepers = []
  ; status = Repo_manager_types.Active
  ; auto_sync = false
  ; sync_interval = 0
  ; created_at = 0L
  ; updated_at = 0L
  }

let normalize_path path =
  Masc.Keeper_alerting_path.normalize_path_for_check path
  |> Masc.Keeper_alerting_path.strip_trailing_slashes

let playground_repo_path ~config ~(meta : Masc.Keeper_meta_contract.keeper_meta)
      repo_name =
  let playground =
    Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta |> normalize_path
  in
  Filename.concat playground (Filename.concat "repos" repo_name)

let create_playground_repo_marker ~config ~meta repo_name =
  let repo_path = playground_repo_path ~config ~meta repo_name in
  mkdir_p (Filename.concat repo_path ".git")

let playground_repo_entry ~config ~meta ~repo_name =
  let repos =
    Masc.Keeper_sandbox_control.playground_repos_json ~config ~meta
    |> Yojson.Safe.Util.to_list
  in
  match
    List.find_opt
      (fun json ->
        match json_string_opt "name" json with
        | Some name -> String.equal name repo_name
        | None -> false)
      repos
  with
  | Some json -> json
  | None ->
      fail
        (Printf.sprintf "expected playground repo entry for %s, got: %s"
           repo_name
           (Yojson.Safe.to_string (`List repos)))

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

let test_playground_repos_mark_missing_mapping_default_scope_allowed () =
  let base_path = temp_dir "masc-playground-repo-policy" in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let repo_path = playground_repo_path ~config ~meta "masc-mcp" in
  save_repositories base_path
    [ repository_fixture
        ~id:"masc-mcp"
        ~name:"masc-mcp"
        ~url:"https://github.com/jeong-sik/masc-mcp.git"
        ~local_path:repo_path
    ];
  create_playground_repo_marker ~config ~meta "masc-mcp";
  let json = playground_repo_entry ~config ~meta ~repo_name:"masc-mcp" in
  check bool "policy allows missing mapping default scope" true
    (json_bool "policy_allowed" json);
  check string "policy status"
    (Keeper_sandbox_control.playground_policy_status_to_string Policy_allowed)
    (json_string "policy_status" json);
  check bool "policy marks default scope" true
    (json_bool "policy_default_scope" json);
  check string "policy source"
    Config_dir_resolver.repositories_toml_basename
    (json_string "policy_source" json)

let test_playground_repos_mark_registered_repo_outside_mapping_allowed () =
  let base_path = temp_dir "masc-playground-repo-policy" in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let repo_path = playground_repo_path ~config ~meta "masc" in
  save_repositories base_path
    [ repository_fixture
        ~id:"masc"
        ~name:"masc"
        ~url:"https://github.com/jeong-sik/masc.git"
        ~local_path:repo_path
    ];
  write_mapping base_path meta.name [ "oas" ];
  create_playground_repo_marker ~config ~meta "masc";
  let json = playground_repo_entry ~config ~meta ~repo_name:"masc" in
  check bool "policy allows registered repo outside advisory mapping" true
    (json_bool "policy_allowed" json);
  check string "policy status"
    (Keeper_sandbox_control.playground_policy_status_to_string Policy_allowed)
    (json_string "policy_status" json);
  check string "policy repository id" "masc"
    (json_string "policy_repository_id" json)

let test_playground_repos_mark_wildcard_mapping_allowed () =
  let base_path = temp_dir "masc-playground-repo-policy" in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let repo_path = playground_repo_path ~config ~meta "masc" in
  save_repositories base_path
    [ repository_fixture
        ~id:"masc"
        ~name:"masc"
        ~url:"https://github.com/jeong-sik/masc.git"
        ~local_path:repo_path
    ];
  write_mapping base_path meta.name [ "*" ];
  create_playground_repo_marker ~config ~meta "masc";
  let json = playground_repo_entry ~config ~meta ~repo_name:"masc" in
  check bool "policy allows wildcard mapping" true
    (json_bool "policy_allowed" json);
  check string "policy status"
    (Keeper_sandbox_control.playground_policy_status_to_string Policy_allowed)
    (json_string "policy_status" json)

let test_playground_repos_policy_uses_registered_repository_id () =
  let base_path = temp_dir "masc-playground-repo-policy" in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let repo_path = playground_repo_path ~config ~meta "masc" in
  mkdir_p (Filename.concat repo_path ".git");
  save_repositories base_path
    [ repository_fixture
        ~id:"repo-masc"
        ~name:"masc"
        ~url:"https://github.com/jeong-sik/masc.git"
        ~local_path:repo_path
    ];
  write_mapping base_path meta.name [ "repo-masc" ];
  let json = playground_repo_entry ~config ~meta ~repo_name:"masc" in
  check bool "policy allows registered repository id" true
    (json_bool "policy_allowed" json);
  check string "policy status"
    (Keeper_sandbox_control.playground_policy_status_to_string Policy_allowed)
    (json_string "policy_status" json);
  check string "policy repository id" "repo-masc"
    (json_string "policy_repository_id" json)

let test_playground_repos_mark_repository_identity_mismatch_denied () =
  let base_path = temp_dir "masc-playground-repo-policy" in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let repo_path = playground_repo_path ~config ~meta "masc" in
  mkdir_p (Filename.concat repo_path ".git");
  save_repositories base_path
    [ repository_fixture
        ~id:"masc"
        ~name:"masc"
        ~url:"https://github.com/jeong-sik/secret.git"
        ~local_path:repo_path
    ];
  write_mapping base_path meta.name [ "masc" ];
  let json = playground_repo_entry ~config ~meta ~repo_name:"masc" in
  check bool "policy denies identity mismatch" false
    (json_bool "policy_allowed" json);
  check string "policy status"
    (Keeper_sandbox_control.playground_policy_status_to_string
       Policy_repository_identity_mismatch)
    (json_string "policy_status" json);
  check string "policy repository id" "masc"
    (json_string "policy_repository_id" json);
  check bool "policy error is surfaced" true
    (String.length (json_string "policy_error" json) > 0)

let test_playground_repos_mark_repository_store_error_denied () =
  let base_path = temp_dir "masc-playground-repo-policy" in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let path = Config_dir_resolver.repositories_toml_path ~base_path in
  mkdir_p (Filename.dirname path);
  write_file path "[repository.bad\n";
  write_mapping base_path meta.name [ "masc" ];
  create_playground_repo_marker ~config ~meta "masc";
  let json = playground_repo_entry ~config ~meta ~repo_name:"masc" in
  check bool "policy denies repository store error" false
    (json_bool "policy_allowed" json);
  check string "policy status"
    (Keeper_sandbox_control.playground_policy_status_to_string
       Policy_repository_store_error)
    (json_string "policy_status" json);
  check string "policy repository id" "masc"
    (json_string "policy_repository_id" json);
  check bool "policy error is surfaced" true
    (String.length (json_string "policy_error" json) > 0)

let test_playground_repos_mark_mapping_load_error_allowed_for_registered_repo () =
  let base_path = temp_dir "masc-playground-repo-policy" in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let repo_path = playground_repo_path ~config ~meta "masc" in
  save_repositories base_path
    [ repository_fixture
        ~id:"masc"
        ~name:"masc"
        ~url:"https://github.com/jeong-sik/masc.git"
        ~local_path:repo_path
    ];
  write_mapping_raw base_path
    (Printf.sprintf "[mapping.%s]\nrepositories = 42\n" meta.name);
  create_playground_repo_marker ~config ~meta "masc";
  let json = playground_repo_entry ~config ~meta ~repo_name:"masc" in
  check bool "mapping load error does not deny registered repo" true
    (json_bool "policy_allowed" json);
  check string "policy status"
    (Keeper_sandbox_control.playground_policy_status_to_string Policy_allowed)
    (json_string "policy_status" json);
  check bool "mapping error is surfaced" true
    (String.length (json_string "policy_mapping_error" json) > 0)

let test_playground_repos_projection_does_not_record_policy_metrics () =
  let base_path = temp_dir "masc-playground-repo-policy" in
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "keeper-one" in
  let repo_path = playground_repo_path ~config ~meta "masc" in
  save_repositories base_path
    [ repository_fixture
        ~id:"masc"
        ~name:"masc"
        ~url:"https://github.com/jeong-sik/masc.git"
        ~local_path:repo_path
    ];
  create_playground_repo_marker ~config ~meta "masc";
  let before = repo_mapping_decision_metric_total () in
  let json = playground_repo_entry ~config ~meta ~repo_name:"masc" in
  check bool "policy projection allows missing mapping default scope" true
    (json_bool "policy_allowed" json);
  check (float 0.0) "policy projection does not record decision metrics"
    before
    (repo_mapping_decision_metric_total ())

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
      ~clone_path:cwd
      args
  in
  if result.ok then result.output
  else
    fail
      (Printf.sprintf "git command failed: git -C %s %s\n%s" cwd
         (String.concat " " args)
         result.output)

let path_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false

let assert_worktree_top ~worktree_path =
  let worktree_top =
    git_output ~cwd:worktree_path [ "rev-parse"; "--show-toplevel" ]
  in
  check string "worktree top" (normalize_path worktree_path)
    (normalize_path worktree_top)

let has_quarantined_sibling worktree_path =
  let parent = Filename.dirname worktree_path in
  let base = Filename.basename worktree_path in
  Sys.readdir parent
  |> Array.exists (fun name -> String.starts_with ~prefix:(base ^ ".broken") name)

let write_stale_worktree_gitdir ~worktree_path ~task_name =
  mkdir_p worktree_path;
  write_file
    (Filename.concat worktree_path ".git")
    ("gitdir: ../../.git/worktrees/" ^ task_name ^ "\n")

let test_deleted_tracked_files_restore_hint () =
  let clone_path = temp_dir "masc-repo-readiness-status-hint" in
  git_ok ~cwd:clone_path [ "init"; "-q"; "--initial-branch=main" ];
  git_ok ~cwd:clone_path [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:clone_path [ "config"; "user.name"; "Test" ];
  mkdir_p (Filename.concat clone_path "config");
  mkdir_p (Filename.concat clone_path "test/fixtures");
  write_file (Filename.concat clone_path "config/deleted-one.txt") "tracked one\n";
  write_file
    (Filename.concat clone_path "test/fixtures/deleted-two.txt")
    "tracked two\n";
  git_ok
    ~cwd:clone_path
    [ "add"; "config/deleted-one.txt"; "test/fixtures/deleted-two.txt" ];
  git_ok ~cwd:clone_path [ "commit"; "-q"; "-m"; "init" ];
  Sys.remove (Filename.concat clone_path "config/deleted-one.txt");
  Sys.remove (Filename.concat clone_path "test/fixtures/deleted-two.txt");
  (match Masc.Playground_repo_readiness.deleted_tracked_files_restore_hint ~clone_path with
   | Some hint ->
     check bool "restore command surfaced" true
       (String.equal
          hint
          "Dirty status only contains deleted tracked files: D config/deleted-one.txt; D \
           test/fixtures/deleted-two.txt. Restore them with: git checkout HEAD -- \
           config/deleted-one.txt test/fixtures/deleted-two.txt")
   | None -> fail "expected deleted tracked files restore hint");
  write_file (Filename.concat clone_path "untracked.txt") "untracked\n";
  check (option string) "mixed dirty status has no restore hint" None
    (Masc.Playground_repo_readiness.deleted_tracked_files_restore_hint ~clone_path)

let test_deleted_tracked_files_restore_hint_uses_unquoted_porcelain_paths () =
  let clone_path = temp_dir "masc-repo-readiness-status-hint-spaces" in
  git_ok ~cwd:clone_path [ "init"; "-q"; "--initial-branch=main" ];
  git_ok ~cwd:clone_path [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:clone_path [ "config"; "user.name"; "Test" ];
  write_file (Filename.concat clone_path "a b.txt") "tracked with space\n";
  git_ok ~cwd:clone_path [ "add"; "a b.txt" ];
  git_ok ~cwd:clone_path [ "commit"; "-q"; "-m"; "init" ];
  Sys.remove (Filename.concat clone_path "a b.txt");
  match Masc.Playground_repo_readiness.deleted_tracked_files_restore_hint ~clone_path with
  | Some hint ->
    check bool "restore command uses shell-quoted real path" true
      (String.equal
         hint
         "Dirty status only contains deleted tracked files: D a b.txt. Restore them \
          with: git checkout HEAD -- 'a b.txt'")
  | None -> fail "expected deleted tracked file restore hint for path with spaces"

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
      "playground_policy",
      [
        test_case "filesystem repo without mapping uses default scope" `Quick
          test_playground_repos_mark_missing_mapping_default_scope_allowed;
        test_case "registered filesystem repo outside mapping is marked allowed"
          `Quick
          test_playground_repos_mark_registered_repo_outside_mapping_allowed;
        test_case "filesystem repo under wildcard mapping is marked allowed"
          `Quick test_playground_repos_mark_wildcard_mapping_allowed;
        test_case "filesystem repo policy uses registered repository id"
          `Quick test_playground_repos_policy_uses_registered_repository_id;
        test_case "repository identity mismatch is marked denied" `Quick
          test_playground_repos_mark_repository_identity_mismatch_denied;
        test_case "repository store error is marked denied" `Quick
          test_playground_repos_mark_repository_store_error_denied;
        test_case "mapping load error does not cap registered repo" `Quick
          test_playground_repos_mark_mapping_load_error_allowed_for_registered_repo;
        test_case "policy projection does not record decision metrics" `Quick
          test_playground_repos_projection_does_not_record_policy_metrics;
      ];
      "status_hints",
      [
        test_case "deleted tracked files restore hint" `Quick
          test_deleted_tracked_files_restore_hint;
        test_case "deleted tracked file with spaces restore hint" `Quick
          test_deleted_tracked_files_restore_hint_uses_unquoted_porcelain_paths;
      ];
    ]
