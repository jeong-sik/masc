(** Keeper_repo_readiness tests. *)

open Alcotest

module Keeper_types = Masc_mcp.Keeper_types

let make_meta ?(sandbox = Keeper_types.Docker) name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "repo readiness test");
        ( "sandbox_profile",
          `String (Keeper_types.sandbox_profile_to_string sandbox) );
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

let write_tool_policy ~base_path =
  let config_dir = Filename.concat base_path "config" in
  mkdir_p config_dir;
  let path = Filename.concat config_dir "tool_policy.toml" in
  let oc = open_out path in
  output_string oc
    "[git_clone]\nallowed_orgs = [\"jeong-sik\"]\ndepth = 1\ndenied_repos = [\"jeong-sik/me\"]\n";
  close_out oc;
  Masc_mcp.Tool_code_write.reset_policy_config_cache ()

let json_bool key json =
  Yojson.Safe.Util.(json |> member key |> to_bool)

let json_string key json =
  Yojson.Safe.Util.(json |> member key |> to_string)

let test_missing_clone () =
  let base_path = temp_dir "masc-repo-readiness" in
  let config = Masc_mcp.Coord.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc_mcp.Keeper_repo_readiness.inspect ~config
      ~meta ~repo:"jeong-sik/masc-mcp" ()
  in
  check bool "not ok" false (json_bool "ok" json);
  check string "state" "missing_clone" (json_string "state" json);
  check string "repo_name" "masc-mcp" (json_string "repo_name" json);
  check bool "exists" false (json_bool "exists" json)

let test_non_git_clone () =
  let base_path = temp_dir "masc-repo-readiness" in
  let config = Masc_mcp.Coord.default_config base_path in
  let meta = make_meta "keeper-one" in
  let clone_path =
    Masc_mcp.Keeper_repo_readiness.clone_path ~config
      ~meta ~repo_name:"masc-mcp"
  in
  mkdir_p clone_path;
  let json =
    Masc_mcp.Keeper_repo_readiness.inspect ~config
      ~meta ~repo:"jeong-sik/masc-mcp" ()
  in
  check bool "not ok" false (json_bool "ok" json);
  check string "state" "not_git_repo" (json_string "state" json);
  check bool "exists" true (json_bool "exists" json);
  check bool "is_git_repo" false (json_bool "is_git_repo" json)

let test_invalid_repo_name () =
  let base_path = temp_dir "masc-repo-readiness" in
  let config = Masc_mcp.Coord.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc_mcp.Keeper_repo_readiness.inspect ~config
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
      "https://github.com/jeong-sik/masc-mcp.git";
    ]

let test_auto_provisionable_workspace_repo () =
  let base_path = temp_dir "masc-repo-readiness" in
  write_tool_policy ~base_path;
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  let remote = Filename.concat base_path ".remote-masc-mcp.git" in
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
  let config = Masc_mcp.Coord.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc_mcp.Keeper_repo_readiness.inspect ~config
      ~meta ~repo_name:"masc-mcp" ()
  in
  check bool "ok" true (json_bool "ok" json);
  check string "state" "auto_provisionable" (json_string "state" json);
  check string "workspace repo match" repo
    Yojson.Safe.Util.(json |> member "workspace_repo_match" |> to_string);
  check string "workspace repo origin"
    "jeong-sik/masc-mcp"
    Yojson.Safe.Util.(
      json |> member "workspace_repo_origin" |> to_string
      |> fun url ->
      Masc_mcp.Tool_code_write.extract_github_org_repo url
      |> Option.value ~default:"")

let test_missing_clone_skips_workspace_discovery () =
  let base_path = temp_dir "masc-repo-readiness" in
  write_tool_policy ~base_path;
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  let remote = Filename.concat base_path ".remote-masc-mcp.git" in
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
  let config = Masc_mcp.Coord.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc_mcp.Keeper_repo_readiness.inspect ~config ~meta
      ~repo_name:"masc-mcp" ~workspace_discovery:false ()
  in
  check bool "not ok" false (json_bool "ok" json);
  check string "state" "missing_clone" (json_string "state" json);
  check string "workspace discovery" "skipped"
    Yojson.Safe.Util.(json |> member "workspace_discovery" |> to_string);
  check bool "auto provision disabled" false
    Yojson.Safe.Util.(
      json |> member "auto_provision_on_worktree_create" |> to_bool)

let test_auto_provisionable_workspace_repo_after_file_storm () =
  let base_path = temp_dir "masc-repo-readiness" in
  write_tool_policy ~base_path;
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  let remote = Filename.concat base_path ".remote-masc-mcp.git" in
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
  let config = Masc_mcp.Coord.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc_mcp.Keeper_repo_readiness.inspect ~config
      ~meta ~repo_name:"masc-mcp" ()
  in
  check bool "ok" true (json_bool "ok" json);
  check string "state" "auto_provisionable" (json_string "state" json);
  check string "workspace repo match" repo
    Yojson.Safe.Util.(json |> member "workspace_repo_match" |> to_string)

let test_auto_provisionable_workspace_repo_before_hidden_dir_storm () =
  let base_path = temp_dir "masc-repo-readiness" in
  write_tool_policy ~base_path;
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  let remote = Filename.concat base_path ".remote-masc-mcp.git" in
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
  let config = Masc_mcp.Coord.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc_mcp.Keeper_repo_readiness.inspect ~config
      ~meta ~repo_name:"masc-mcp" ()
  in
  check bool "ok" true (json_bool "ok" json);
  check string "state" "auto_provisionable" (json_string "state" json);
  check string "workspace repo match" repo
    Yojson.Safe.Util.(json |> member "workspace_repo_match" |> to_string)

let test_auto_provisionable_workspace_repo_before_wide_workspace_storm () =
  let base_path = temp_dir "masc-repo-readiness" in
  write_tool_policy ~base_path;
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  let remote = Filename.concat base_path ".remote-masc-mcp.git" in
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
  let config = Masc_mcp.Coord.default_config base_path in
  let meta = make_meta "keeper-one" in
  let json =
    Masc_mcp.Keeper_repo_readiness.inspect ~config
      ~meta ~repo_name:"masc-mcp" ()
  in
  check bool "ok" true (json_bool "ok" json);
  check string "state" "auto_provisionable" (json_string "state" json);
  check string "workspace repo match" repo
    Yojson.Safe.Util.(json |> member "workspace_repo_match" |> to_string)

let test_workspace_repo_matches_skips_git_clone_internals () =
  let base_path = temp_dir "masc-repo-match-budget" in
  let adjacent_repo = Filename.concat base_path "workspace/aaa-repo" in
  let target_repo = Filename.concat base_path "workspace/z-team/target" in
  init_git_repo adjacent_repo;
  for i = 0 to 20 do
    Unix.mkdir (Filename.concat adjacent_repo (Printf.sprintf "aa-%02d" i)) 0o755
  done;
  init_git_repo target_repo;
  check (list string) "matches target without scanning adjacent repo internals"
    [ target_repo ]
    (Coord_worktree.workspace_repo_matches ~max_entries:8
       ~search_root:base_path ~repo_name:"target" ())

let () =
  Random.self_init ();
  run "Keeper_repo_readiness"
    [
      "inspect",
      [
        test_case "missing clone" `Quick test_missing_clone;
        test_case "non-git clone" `Quick test_non_git_clone;
        test_case "invalid repo_name" `Quick test_invalid_repo_name;
        test_case "auto provisionable workspace repo" `Quick
          test_auto_provisionable_workspace_repo;
        test_case "missing clone skips workspace discovery" `Quick
          test_missing_clone_skips_workspace_discovery;
        test_case "auto provisionable workspace repo after file storm" `Quick
          test_auto_provisionable_workspace_repo_after_file_storm;
        test_case "auto provisionable workspace repo before hidden dir storm"
          `Quick test_auto_provisionable_workspace_repo_before_hidden_dir_storm;
        test_case "auto provisionable workspace repo before wide workspace storm"
          `Quick test_auto_provisionable_workspace_repo_before_wide_workspace_storm;
        test_case "workspace repo scan skips git clone internals" `Quick
          test_workspace_repo_matches_skips_git_clone_internals;
      ];
    ]
