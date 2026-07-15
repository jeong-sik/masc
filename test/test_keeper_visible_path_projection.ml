module Workspace = Masc.Workspace
module Json = Yojson.Safe.Util
module Keeper_registry = Masc.Keeper_registry
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_tool_filesystem_runtime = Masc.Keeper_tool_filesystem_runtime
module Keeper_tool_shared_runtime = Masc.Keeper_tool_shared_runtime

let temp_dir () =
  let d = Filename.temp_file "keeper-visible-path-projection-" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d
;;

let rec ensure_dir path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)
;;

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with
  | _ -> ()
;;

let write_file path content =
  ensure_dir (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let make_meta
      ?(sandbox = Keeper_types_profile_sandbox.Local)
      ?(always_allow = false)
      name
  =
  let json =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String ("agent-" ^ name)
      ; "trace_id", `String ("trace-" ^ name)
      ; "goal", `String "visible path projection test"
      ; ( "sandbox_profile"
        , `String (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox) )
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> if always_allow then { meta with always_allow = Some true } else meta
  | Error e -> Alcotest.fail e
;;

let with_eio_fs f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ~fs ~sw ()
;;

let setup ?sandbox ?always_allow f =
  with_eio_fs
  @@ fun ~fs ~sw () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       Keeper_registry.clear ();
       let config = Workspace.default_config base in
       let meta = make_meta ?sandbox ?always_allow "tester" in
       let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       ensure_dir playground;
       ignore (Keeper_registry.register ~base_path:base meta.name meta);
       let registry =
         match
           Fs_compat.open_publication_recovery_registry
             ~sw
             ~registry_root:Eio.Path.(fs / Workspace.masc_root_dir config)
         with
         | Ok registry -> registry
         | Error error ->
           Alcotest.fail
             (Fs_compat.publication_recovery_registry_error_to_string error)
       in
       match
         Fs_compat.with_publication_recovery_lane
           ~registry
           ~owner:meta.name
           (fun publication_recovery_access ->
              f ~config ~meta ~playground ~publication_recovery_access)
       with
       | Ok value -> value
       | Error error ->
         Alcotest.fail
           (Fs_compat.publication_recovery_lane_open_error_to_string error))
;;

let parse raw = Yojson.Safe.from_string raw

let parse_ok raw =
  parse raw |> Json.member "ok" |> Json.to_bool_option |> Option.value ~default:false
;;

let parse_string key raw = parse raw |> Json.member key |> Json.to_string_option

let allow_repo ~config ~(meta : Masc.Keeper_meta_contract.keeper_meta) repo_id =
  let repo_path =
    Filename.concat
      (Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta)
      (Filename.concat "repos" repo_id)
  in
  let repo : Repo_manager_types.repository =
    { id = repo_id
    ; name = repo_id
    ; url = Printf.sprintf "https://example.invalid/%s.git" repo_id
    ; local_path = repo_path
    ; aliases = []
    ; default_branch = "main"
    ; keepers = []
    ; status = Repo_manager_types.Active
    ; auto_sync = false
    ; sync_interval = 0
    ; created_at = Int64.zero
    ; updated_at = Int64.zero
    }
  in
  (match Repo_store.save_all ~base_path:config.Workspace.base_path [ repo ] with
   | Ok () -> ()
   | Error e -> Alcotest.fail ("failed to seed repository catalog: " ^ e));
  let mapping : Repo_manager_types.keeper_repo_mapping =
    (Repo_manager_types.make_keeper_repo_mapping ~keeper_id:meta.name
       ~repository_ids:[ repo_id ])
  in
  match Keeper_repo_mapping.save_mapping ~base_path:config.Workspace.base_path mapping with
  | Ok () -> ()
  | Error e -> Alcotest.fail ("failed to seed keeper repo mapping: " ^ e)
;;

let test_visible_mind_read_resolves_to_private_storage () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery_access:_ ->
  let target = Filename.concat playground "mind/README.md" in
  write_file target "visible mind\n";
  match
    Keeper_tool_shared_runtime.resolve_keeper_read_path
      ~config
      ~meta
      ~raw_path:"mind/README.md"
  with
  | Ok path -> Alcotest.(check string) "resolved path" target path
  | Error e -> Alcotest.fail ("visible mind path should resolve: " ^ e)
;;

let test_absolute_playground_path_is_allowed () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery_access:_ ->
  let target = Filename.concat playground "mind/README.md" in
  write_file target "private storage fixture\n";
  (match
     Keeper_tool_shared_runtime.resolve_keeper_read_path
       ~config
       ~meta
       ~raw_path:target
   with
   | Ok path ->
     Alcotest.(check string) "resolved private path" target path
   | Error e -> Alcotest.fail ("playground-internal path should resolve: " ^ e))
;;

let test_relative_path_does_not_depend_on_project_root_allowlist () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery_access:_ ->
  let target = Filename.concat playground "mind/README.md" in
  let project_root_meta = { meta with allowed_paths = [ "mind" ] } in
  match
    Keeper_tool_shared_runtime.resolve_keeper_read_path
      ~config
      ~meta:project_root_meta
      ~raw_path:"mind/README.md"
  with
  | Ok path -> Alcotest.(check string) "relative path stays in playground" target path
  | Error e -> Alcotest.fail ("relative path should resolve in playground: " ^ e)
;;

let test_relative_parent_escape_is_rejected () =
  setup
  @@ fun ~config ~meta ~playground:_ ~publication_recovery_access:_ ->
  match
    Keeper_tool_shared_runtime.resolve_keeper_read_path
      ~config
      ~meta
      ~raw_path:"../outside.txt"
  with
  | Error _ -> ()
  | Ok path -> Alcotest.failf "relative parent escape resolved unexpectedly: %s" path
;;

let test_read_with_visible_repo_cwd_and_relative_file_path () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery_access:_ ->
  allow_repo ~config ~meta "masc";
  let target = Filename.concat playground "repos/masc/README.md" in
  write_file target "repo readme\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_read_file
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~args:
        (`Assoc
            [ "cwd", `String "repos/masc"
            ; "path", `String "README.md"
            ; "max_bytes", `Int 4096
            ])
  in
  if not (parse_ok raw) then Alcotest.failf "expected Read ok, got: %s" raw;
  Alcotest.(check (option string))
    "content"
    (Some "repo readme\n")
    (parse_string "content" raw)
;;

let test_repository_backlog_file_is_readable () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery_access:_ ->
  allow_repo ~config ~meta "masc";
  let target = Filename.concat playground "repos/masc/docs/backlog.json" in
  write_file target {|{"scope":"repository fixture"}|};
  let raw =
    Keeper_tool_filesystem_runtime.handle_read_file
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~args:
        (`Assoc
            [ "path", `String "repos/masc/docs/backlog.json"
            ; "max_bytes", `Int 4096
            ])
  in
  if not (parse_ok raw) then Alcotest.failf "expected Read ok, got: %s" raw;
  Alcotest.(check (option string))
    "repository backlog content"
    (Some {|{"scope":"repository fixture"}|})
    (parse_string "content" raw)
;;

(* A repo-prefixed missing read preserves producer facts without inventing
   repository or retry advice at the dispatch boundary. *)
let test_repo_prefixed_missing_read_preserves_exact_input () =
  setup
  @@ fun ~config ~meta ~playground:_ ~publication_recovery_access:_ ->
  allow_repo ~config ~meta "masc";
  let raw =
    Keeper_tool_filesystem_runtime.handle_read_file
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~args:
        (`Assoc
            [ "path", `String "repos/masc/lib/keeper/does_not_exist_xyz.ml"
            ; "max_bytes", `Int 4096
            ])
  in
  if parse_ok raw then Alcotest.failf "expected Read to fail, got ok: %s" raw;
  let json = parse raw in
  Alcotest.(check (option string))
    "repo-prefixed input path preserved"
    (Some "repos/masc/lib/keeper/does_not_exist_xyz.ml")
    (Json.member "input_file_path" json |> Json.to_string_option);
  Alcotest.(check bool) "no inferred repository list" true
    (Json.member "available_repos" json = `Null)
;;

let test_write_visible_mind_path () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker ~always_allow:true
  @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
            [ "path", `String "mind/allowed.txt"
            ; "mode", `String "overwrite"
            ; "content", `String "allowed"
            ])
      ()
  in
  if not (parse_ok raw) then Alcotest.failf "expected Write ok, got: %s" raw;
  Alcotest.(check string)
    "content landed"
    "allowed"
    (Fs_compat.load_file (Filename.concat playground "mind/allowed.txt"))
;;

let () =
  Alcotest.run
    "Keeper_visible_path_projection"
    [ ( "shared_projection"
      , [ Alcotest.test_case
            "visible mind read resolves to private storage"
            `Quick
            test_visible_mind_read_resolves_to_private_storage
        ; Alcotest.test_case
            "absolute playground storage read is allowed"
            `Quick
            test_absolute_playground_path_is_allowed
        ; Alcotest.test_case
            "relative path ignores project-root allowlist additions"
            `Quick
            test_relative_path_does_not_depend_on_project_root_allowlist
        ; Alcotest.test_case
            "relative parent escape is rejected"
            `Quick
            test_relative_parent_escape_is_rejected
        ] )
    ; ( "file_tools"
      , [ Alcotest.test_case
            "Read cwd=repos/<repo> plus relative file path"
            `Quick
            test_read_with_visible_repo_cwd_and_relative_file_path
        ; Alcotest.test_case
            "Write visible mind path"
            `Quick
            test_write_visible_mind_path
        ; Alcotest.test_case
            "repository backlog.json remains readable"
            `Quick
            test_repository_backlog_file_is_readable
        ; Alcotest.test_case
            "repo-prefixed missing read surfaces playground hint"
            `Quick
            test_repo_prefixed_missing_read_preserves_exact_input
        ] )
    ]
;;
