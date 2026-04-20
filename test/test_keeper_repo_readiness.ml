(** Keeper_repo_readiness tests. *)

open Alcotest

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
  let json =
    Masc_mcp.Keeper_repo_readiness.inspect ~config
      ~keeper_name:"keeper-one" ~repo:"jeong-sik/masc-mcp" ()
  in
  check bool "not ok" false (json_bool "ok" json);
  check string "state" "missing_clone" (json_string "state" json);
  check string "repo_name" "masc-mcp" (json_string "repo_name" json);
  check bool "exists" false (json_bool "exists" json)

let test_non_git_clone () =
  let base_path = temp_dir "masc-repo-readiness" in
  let config = Masc_mcp.Coord.default_config base_path in
  let clone_path =
    Masc_mcp.Keeper_repo_readiness.clone_path ~config
      ~keeper_name:"keeper-one" ~repo_name:"masc-mcp"
  in
  mkdir_p clone_path;
  let json =
    Masc_mcp.Keeper_repo_readiness.inspect ~config
      ~keeper_name:"keeper-one" ~repo:"jeong-sik/masc-mcp" ()
  in
  check bool "not ok" false (json_bool "ok" json);
  check string "state" "not_git_repo" (json_string "state" json);
  check bool "exists" true (json_bool "exists" json);
  check bool "is_git_repo" false (json_bool "is_git_repo" json)

let test_invalid_repo_name () =
  let base_path = temp_dir "masc-repo-readiness" in
  let config = Masc_mcp.Coord.default_config base_path in
  let json =
    Masc_mcp.Keeper_repo_readiness.inspect ~config
      ~keeper_name:"keeper-one" ~repo_name:"../escape" ()
  in
  check bool "not ok" false (json_bool "ok" json);
  check string "state" "invalid_repo_name" (json_string "state" json)

let () =
  Random.self_init ();
  run "Keeper_repo_readiness"
    [
      "inspect",
      [
        test_case "missing clone" `Quick test_missing_clone;
        test_case "non-git clone" `Quick test_non_git_clone;
        test_case "invalid repo_name" `Quick test_invalid_repo_name;
      ];
    ]
