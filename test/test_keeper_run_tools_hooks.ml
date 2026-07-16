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

let make_meta ?(sandbox_profile = Keeper_types_profile_sandbox.Local) name =
  let json =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String ("agent-" ^ name)
      ; "trace_id", `String ("trace-" ^ name)
      ; "allowed_paths", `List [ `String "*" ]
      ; ( "sandbox_profile"
        , `String
            (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox_profile)
        )
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> Alcotest.fail e
;;

(* #23469: relative tool paths anchor at the keeper's playground sandbox
   root, mirroring the file tools' own resolution; absolute paths pass
   through and pathless calls stay at [base_path]. *)
let sandbox_root = "/sandbox/tester"

let observed_path fields =
  Masc.Keeper_run_tools_hooks.observation_file_path_from_tool_input
    ~base_path:"/tmp/masc-base"
    ~sandbox_root
    (`Assoc fields)
;;

let test_explicit_cwd_scopes_relative_file_path () =
  check
    string
    "cwd/file_path"
    "/sandbox/tester/repos/masc/lib/foo.ml"
    (observed_path
       [ "file_path", `String "lib/foo.ml"; "cwd", `String "repos/masc" ])
;;

let test_sandbox_rooted_file_path_ignores_cwd () =
  check
    string
    "sandbox-rooted"
    "/sandbox/tester/repos/masc/lib/foo.ml"
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

let test_absolute_cwd_scopes_relative_file_path () =
  check
    string
    "absolute cwd"
    "/abs/work/lib/foo.ml"
    (observed_path
       [ "file_path", `String "lib/foo.ml"; "cwd", `String "/abs/work" ])
;;

let test_bare_relative_path_anchors_at_sandbox_root () =
  check
    string
    "bare relative"
    "/sandbox/tester/lib/solo.ml"
    (observed_path [ "file_path", `String "lib/solo.ml" ])
;;

let test_blank_path_falls_back_to_file_path () =
  check
    string
    "blank path fallback"
    "/sandbox/tester/repos/masc/lib/foo.ml"
    (observed_path
       [ "path", `String " "
       ; "file_path", `String "repos/masc/lib/foo.ml"
       ])
;;

let test_path_priority_matches_ide_helper () =
  check
    string
    "path wins"
    "/sandbox/tester/repos/masc/lib/from-path.ml"
    (observed_path
       [ "path", `String "repos/masc/lib/from-path.ml"
       ; "file_path", `String "repos/masc/lib/from-file-path.ml"
       ])
;;

let test_nested_arguments_path_is_observed () =
  check
    string
    "nested arguments path"
    "/sandbox/tester/repos/masc/lib/nested.ml"
    (observed_path
       [ ( "arguments"
         , `Assoc [ "path", `String "repos/masc/lib/nested.ml" ] )
       ])
;;

let test_nested_arguments_relative_path_uses_cwd () =
  check
    string
    "nested arguments cwd"
    "/sandbox/tester/repos/masc/lib/nested.ml"
    (observed_path
       [ ( "arguments"
         , `Assoc [ "file_path", `String "lib/nested.ml" ] )
       ; "cwd", `String "repos/masc"
       ])
;;

let test_paths_list_uses_first_string_path () =
  check
    string
    "paths list"
    "/sandbox/tester/repos/masc/lib/a.ml"
    (observed_path
       [ ( "paths"
         , `List
             [ `String "repos/masc/lib/a.ml"
             ; `String "repos/masc/lib/b.ml"
             ] )
       ])
;;

let test_files_list_uses_first_object_file_path () =
  check
    string
    "files object file_path"
    "/sandbox/tester/repos/masc/lib/from-file-object.ml"
    (observed_path
       [ ( "files"
         , `List
             [ `Assoc
                 [ "file_path"
                 , `String "repos/masc/lib/from-file-object.ml"
                 ]
             ] )
       ])
;;

let test_missing_path_falls_back_to_base_path () =
  check string "base fallback" "/tmp/masc-base" (observed_path [])
;;

let with_partition_fixture ?sandbox_profile f =
  with_temp_base_path (fun base_path ->
    (match Repo_store.save_all ~base_path [ sample_repo ] with
     | Ok () -> ()
     | Error msg -> fail ("repo save failed: " ^ msg));
    let config = Masc.Workspace.default_config (Filename.concat base_path ".masc") in
    let meta =
      match sandbox_profile with
      | Some sandbox_profile -> make_meta ~sandbox_profile "tester"
      | None -> make_meta "tester"
    in
    f ~config ~meta)
;;

let resolve_partition ~config ~meta fields =
  Masc.Keeper_run_tools_hooks.observation_partition_for_tool_input
    ~config
    ~meta
    ~kind:"tool_event"
    (`Assoc fields)
;;

(* The keeper's playground clone of a registered repo resolves to the
   repo's [By_url] bucket via the structural playground parse — the
   #23469 regression this case pins: before the sandbox anchor, this
   input re-anchored at the server base path and only matched because
   the same repo happened to be registered at [repos/masc] there. *)
let test_partition_resolution_uses_project_root_for_masc_base_path () =
  with_partition_fixture (fun ~config ~meta ->
    let partition, rel_path =
      resolve_partition
        ~config
        ~meta
        [ "cwd", `String "repos/masc"; "path", `String "lib/foo.ml" ]
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

let test_partition_unregistered_playground_repo_is_unmatched () =
  with_partition_fixture (fun ~config ~meta ->
    let partition, _ =
      resolve_partition
        ~config
        ~meta
        [ "path", `String "repos/ghost/lib/foo.ml" ]
    in
    match partition with
    | Agent_observation.Unmatched -> ()
    | Agent_observation.By_url _
    | Agent_observation.No_canonical_url
    | Agent_observation.Base_unresolved
    | Agent_observation.Legacy_default ->
      fail "expected Unmatched partition for unregistered playground repo")
;;

let test_partition_docker_visible_path_maps_to_playground_repo () =
  with_partition_fixture
    ~sandbox_profile:Keeper_types_profile_sandbox.Docker
    (fun ~config ~meta ->
       let container_repo_path =
         Filename.concat
           (Masc.Keeper_sandbox.container_root meta.name)
           "repos/masc/lib/docker.ml"
       in
       let partition, rel_path =
         resolve_partition ~config ~meta [ "path", `String container_repo_path ]
       in
       check string "repo-relative path" "lib/docker.ml" rel_path;
       match partition with
       | Agent_observation.By_url slug ->
         check string "slug" "github.com_jeong-sik_masc" slug
       | Agent_observation.No_canonical_url
       | Agent_observation.Unmatched
       | Agent_observation.Base_unresolved
       | Agent_observation.Legacy_default ->
         fail "expected Docker visible absolute path to resolve to By_url")
;;

(* A bare relative path outside the [repos/<id>/] lane is a real
   playground-local file, not a repo file — it must degrade to the typed
   orphan partition instead of borrowing whichever repository overlaps
   the server base path. *)
let test_partition_bare_relative_outside_repos_is_base_unresolved () =
  with_partition_fixture (fun ~config ~meta ->
    let partition, _ =
      resolve_partition ~config ~meta [ "path", `String "notes/todo.md" ]
    in
    match partition with
    | Agent_observation.Base_unresolved -> ()
    | Agent_observation.By_url _
    | Agent_observation.No_canonical_url
    | Agent_observation.Unmatched
    | Agent_observation.Legacy_default ->
      fail "expected Base_unresolved partition for playground-local file")
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
        ; test_case
            "absolute cwd scopes relative file_path"
            `Quick
            test_absolute_cwd_scopes_relative_file_path
        ; test_case
            "bare relative path anchors at sandbox root"
            `Quick
            test_bare_relative_path_anchors_at_sandbox_root
        ; test_case "blank path falls back to file_path" `Quick
            test_blank_path_falls_back_to_file_path
        ; test_case "path priority matches IDE helper" `Quick
            test_path_priority_matches_ide_helper
        ; test_case "nested arguments path is observed" `Quick
            test_nested_arguments_path_is_observed
        ; test_case "nested arguments relative path uses cwd" `Quick
            test_nested_arguments_relative_path_uses_cwd
        ; test_case "paths list uses first string path" `Quick
            test_paths_list_uses_first_string_path
        ; test_case "files list uses first object file_path" `Quick
            test_files_list_uses_first_object_file_path
        ; test_case "missing path falls back to base_path" `Quick
            test_missing_path_falls_back_to_base_path
        ] )
    ; ( "observation_partition"
      , [ test_case
            "uses project root when config base is .masc"
            `Quick
            test_partition_resolution_uses_project_root_for_masc_base_path
        ; test_case
            "unregistered playground repo is Unmatched"
            `Quick
            test_partition_unregistered_playground_repo_is_unmatched
        ; test_case
            "Docker visible absolute path maps to playground repo"
            `Quick
            test_partition_docker_visible_path_maps_to_playground_repo
        ; test_case
            "bare relative outside repos lane is Base_unresolved"
            `Quick
            test_partition_bare_relative_outside_repos_is_base_unresolved
        ] )
    ]
;;
