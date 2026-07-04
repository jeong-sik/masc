open Alcotest
open Repo_manager_types

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path
;;

let with_temp_base_path f =
  let dir = Filename.temp_file "keeper-run-tools-hooks-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Unix.mkdir (Filename.concat dir ".masc") 0o755;
  Unix.mkdir (Filename.concat (Filename.concat dir ".masc") "config") 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let sample_repo =
  { id = "masc"
  ; name = "masc"
  ; url = "https://github.com/jeong-sik/masc.git"
  ; local_path = "repos/masc"
  ; aliases = []
  ; default_branch = "main"
  ; keepers = []
  ; status = Active
  ; auto_sync = false
  ; sync_interval = 300
  ; created_at = 1L
  ; updated_at = 1L
  }
;;

let observed_path fields =
  Masc.Keeper_run_tools_hooks.observation_file_path_from_tool_input
    ~base_path:"/tmp/masc-base"
    (`Assoc fields)
;;

let test_explicit_cwd_scopes_relative_file_path () =
  check
    string
    "cwd/file_path"
    "repos/masc/lib/foo.ml"
    (observed_path
       [ "file_path", `String "lib/foo.ml"; "cwd", `String "repos/masc" ])
;;

let test_sandbox_rooted_file_path_ignores_cwd () =
  check
    string
    "sandbox-rooted"
    "repos/masc/lib/foo.ml"
    (observed_path
       [ "file_path", `String "repos/masc/lib/foo.ml"
       ; "cwd", `String "repos/other"
       ])
;;

let test_absolute_path_ignores_cwd () =
  check
    string
    "absolute"
    "/workspace/masc/lib/foo.ml"
    (observed_path
       [ "path", `String "/workspace/masc/lib/foo.ml"
       ; "cwd", `String "repos/other"
       ])
;;

let test_blank_path_falls_back_to_file_path () =
  check
    string
    "blank path fallback"
    "repos/masc/lib/foo.ml"
    (observed_path
       [ "path", `String " "
       ; "file_path", `String "repos/masc/lib/foo.ml"
       ])
;;

let test_path_priority_matches_ide_helper () =
  check
    string
    "path wins"
    "repos/masc/lib/from-path.ml"
    (observed_path
       [ "path", `String "repos/masc/lib/from-path.ml"
       ; "file_path", `String "repos/masc/lib/from-file-path.ml"
       ])
;;

let test_missing_path_falls_back_to_base_path () =
  check string "base fallback" "/tmp/masc-base" (observed_path [])
;;

let test_partition_resolution_uses_project_root_for_masc_base_path () =
  with_temp_base_path (fun base_path ->
    (match Repo_store.save_all ~base_path [ sample_repo ] with
     | Ok () -> ()
     | Error msg -> fail ("repo save failed: " ^ msg));
    let config = Masc.Workspace.default_config (Filename.concat base_path ".masc") in
    let partition, rel_path =
      Masc.Keeper_run_tools_hooks.observation_partition_for_tool_input
        ~config
        ~kind:"tool_event"
        (`Assoc
          [ "cwd", `String "repos/masc"; "path", `String "lib/foo.ml" ])
    in
    check string "repo-relative path" "lib/foo.ml" rel_path;
    match partition with
    | Agent_observation.By_url slug ->
      check string "slug" "github.com_jeong-sik_masc" slug
    | Agent_observation.No_canonical_url
    | Agent_observation.Unmatched
    | Agent_observation.Base_unresolved
    | Agent_observation.Legacy_default ->
      fail "expected By_url partition")
;;

let () =
  run
    "keeper_run_tools_hooks"
    [ ( "observation_file_path"
      , [ test_case
            "explicit cwd scopes relative file_path"
            `Quick
            test_explicit_cwd_scopes_relative_file_path
        ; test_case
            "sandbox-rooted file_path ignores cwd"
            `Quick
            test_sandbox_rooted_file_path_ignores_cwd
        ; test_case "absolute path ignores cwd" `Quick test_absolute_path_ignores_cwd
        ; test_case "blank path falls back to file_path" `Quick
            test_blank_path_falls_back_to_file_path
        ; test_case "path priority matches IDE helper" `Quick
            test_path_priority_matches_ide_helper
        ; test_case "missing path falls back to base_path" `Quick
            test_missing_path_falls_back_to_base_path
        ] )
    ; ( "observation_partition"
      , [ test_case
            "uses project root when config base is .masc"
            `Quick
            test_partition_resolution_uses_project_root_for_masc_base_path
        ] )
    ]
;;
