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

let make_meta ?(sandbox = Keeper_types_profile_sandbox.Local) name =
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
  | Ok meta -> meta
  | Error e -> Alcotest.fail e
;;

let with_eio_fs f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()
;;

let setup ?sandbox f =
  with_eio_fs
  @@ fun () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       Keeper_registry.clear ();
       let config = Workspace.default_config base in
       let meta = make_meta ?sandbox "tester" in
       let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       ensure_dir playground;
       ignore (Keeper_registry.register ~base_path:base meta.name meta);
       f ~config ~meta ~playground)
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
  match Keeper_repo_mapping.save_mapping_blocking ~base_path:config.Workspace.base_path mapping with
  | Ok () -> ()
  | Error e -> Alcotest.fail ("failed to seed keeper repo mapping: " ^ e)
;;

let test_visible_mind_read_resolves_to_private_storage () =
  setup
  @@ fun ~config ~meta ~playground ->
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

let test_playground_internal_path_now_allowed () =
  (* RFC-0006: the keeper playground (.masc/playground/<keeper>/...) is the
     keeper's own working area — its internal paths (mind/, drafts) are
     reachable. #23843 unblocked the whole arm; this keeps the playground half
     unblocked after re-narrowing the helper to exempt .masc/playground. *)
  setup
  @@ fun ~config ~meta ~playground ->
  let private_raw =
    Masc.Keeper_sandbox.allowed_root_rel_of_meta ~meta ^ "mind/README.md"
  in
  let target = Filename.concat playground "mind/README.md" in
  write_file target "private storage fixture\n";
  (match
     Keeper_tool_shared_runtime.resolve_keeper_read_path
       ~config
       ~meta
       ~raw_path:private_raw
   with
   | Ok path ->
     Alcotest.(check string) "resolved private path" target path
   | Error e -> Alcotest.fail ("playground-internal path should resolve: " ^ e))
;;

let test_masc_internal_state_read_stays_blocked () =
  (* The narrowing is load-bearing: workspace-level internal state
     (.masc/backlog.json, .masc/tasks/) must stay blocked — keepers reach it
     via keeper_tasks_list / keeper_context_status, not by probing the files.
     This is the #23807 traversal/symlink write-bypass defence that #23843
     dropped. *)
  setup
  @@ fun ~config ~meta ~playground:_ ->
  (match
     Keeper_tool_shared_runtime.resolve_keeper_read_path
       ~config
       ~meta
       ~raw_path:".masc/backlog.json"
   with
   | Ok path -> Alcotest.fail (".masc internal state should be blocked: " ^ path)
   | Error e ->
     Alcotest.(check bool)
       "masc internal state blocked"
       true
       (String.starts_with ~prefix:"task_state_file_path_blocked:" e))
;;

let test_read_with_visible_repo_cwd_and_relative_file_path () =
  setup
  @@ fun ~config ~meta ~playground ->
  allow_repo ~config ~meta "masc";
  let target = Filename.concat playground "repos/masc/README.md" in
  write_file target "repo readme\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_read_file
      ~turn_sandbox_factory:None
      ~config
      ~keeper_name:meta.name
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
  @@ fun ~config ~meta ~playground ->
  allow_repo ~config ~meta "masc";
  let target = Filename.concat playground "repos/masc/docs/backlog.json" in
  write_file target {|{"scope":"repository fixture"}|};
  let raw =
    Keeper_tool_filesystem_runtime.handle_read_file
      ~turn_sandbox_factory:None
      ~config
      ~keeper_name:meta.name
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

(* Regression: a repo-prefixed read of a path that does not exist (e.g.
   the masc-mcp->masc rename-drift case, or a hallucinated file) routes
   through resolve_shared. Before the fix, resolve_shared wrapped every
   error as Read_path_error -> bare {error}, so the keeper-facing result
   omitted your_playground / available_repos even though the message text
   says "check your_playground for available files". The fix mirrors
   resolve_projected: a path_not_found_under_allowed_roots rejection
   becomes Missing_file -> rich missing_file_error_json. Assert the rich
   hint reaches the keeper-facing result. *)
let test_repo_prefixed_missing_read_surfaces_playground_hint () =
  setup
  @@ fun ~config ~meta ~playground:_ ->
  allow_repo ~config ~meta "masc";
  let raw =
    Keeper_tool_filesystem_runtime.handle_read_file
      ~turn_sandbox_factory:None
      ~config
      ~keeper_name:meta.name
      ~args:
        (`Assoc
            [ "path", `String "repos/masc/lib/keeper/does_not_exist_xyz.ml"
            ; "max_bytes", `Int 4096
            ])
  in
  if parse_ok raw then Alcotest.failf "expected Read to fail, got ok: %s" raw;
  (* missing_file_error_json carries your_playground + available_repos;
     Read_path_error (the old behaviour) carries neither. *)
  let has_hint =
    let json = parse raw in
    (match Json.member "your_playground" json with `Null -> false | _ -> true)
    || (match Json.member "available_repos" json with `Null -> false | _ -> true)
  in
  Alcotest.(check bool)
    "repo-prefixed not-found surfaces your_playground/available_repos hint"
    true
    has_hint
;;

let test_write_visible_mind_path () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ->
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~keeper_name:meta.name
      ~args:
        (`Assoc
            [ "path", `String "mind/allowed.txt"
            ; "mode", `String "overwrite"
            ; "content", `String "allowed"
            ])
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
            "direct private storage read is allowed"
            `Quick
            test_playground_internal_path_now_allowed
        ; Alcotest.test_case
            "internal masc state read stays blocked"
            `Quick
            test_masc_internal_state_read_stays_blocked
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
            test_repo_prefixed_missing_read_surfaces_playground_hint
        ] )
    ]
;;
