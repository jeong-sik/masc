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
  match Keeper_types.meta_of_json json with
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

let run_ok ~cwd cmd =
  let wrapped =
    Printf.sprintf "cd %s && %s > /dev/null 2>&1" (Filename.quote cwd) cmd
  in
  let code = Sys.command wrapped in
  if code <> 0 then fail (Printf.sprintf "command failed (%d): %s" code cmd)

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

let test_auto_provisionable_workspace_repo () =
  let base_path = temp_dir "masc-repo-readiness" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  let remote = Filename.concat base_path ".remote-masc-mcp.git" in
  mkdir_p (Filename.dirname repo);
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
  output_string oc "# readiness\n";
  close_out oc;
  run_ok ~cwd:repo "git add README.md";
  run_ok ~cwd:repo "git commit -q -m init";
  run_ok ~cwd:repo "git push -q origin main";
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

let test_auto_provisionable_workspace_repo_after_file_storm () =
  let base_path = temp_dir "masc-repo-readiness" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  let remote = Filename.concat base_path ".remote-masc-mcp.git" in
  create_file_storm ~base_path ~count:4005;
  mkdir_p (Filename.dirname repo);
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
  output_string oc "# readiness\n";
  close_out oc;
  run_ok ~cwd:repo "git add README.md";
  run_ok ~cwd:repo "git commit -q -m init";
  run_ok ~cwd:repo "git push -q origin main";
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
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  let remote = Filename.concat base_path ".remote-masc-mcp.git" in
  create_hidden_dir_storm ~base_path ~count:4005;
  mkdir_p (Filename.dirname repo);
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
  output_string oc "# readiness\n";
  close_out oc;
  run_ok ~cwd:repo "git add README.md";
  run_ok ~cwd:repo "git commit -q -m init";
  run_ok ~cwd:repo "git push -q origin main";
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
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  let remote = Filename.concat base_path ".remote-masc-mcp.git" in
  create_wide_workspace_storm ~base_path ~count:4005;
  mkdir_p (Filename.dirname repo);
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
  output_string oc "# readiness\n";
  close_out oc;
  run_ok ~cwd:repo "git add README.md";
  run_ok ~cwd:repo "git commit -q -m init";
  run_ok ~cwd:repo "git push -q origin main";
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
        test_case "auto provisionable workspace repo after file storm" `Quick
          test_auto_provisionable_workspace_repo_after_file_storm;
        test_case "auto provisionable workspace repo before hidden dir storm"
          `Quick test_auto_provisionable_workspace_repo_before_hidden_dir_storm;
        test_case "auto provisionable workspace repo before wide workspace storm"
          `Quick test_auto_provisionable_workspace_repo_before_wide_workspace_storm;
      ];
    ]
