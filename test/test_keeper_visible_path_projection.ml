module Workspace = Masc.Workspace
module Json = Yojson.Safe.Util
module Keeper_registry = Masc.Keeper_registry
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_sandbox_control = Masc.Keeper_sandbox_control
module Keeper_tool_filesystem_runtime = Masc.Keeper_tool_filesystem_runtime
module Keeper_tool_shared_runtime = Masc.Keeper_tool_shared_runtime

(* [Keeper_tool_filesystem_runtime.handle_read_file] / [handle_file_write]
   (the bare string-returning wrappers) were retired: they had zero
   production callers ([keeper_tool_runtime.ml] calls the [_with_outcome]
   variants directly). These test-local shims reproduce the [.raw_output]
   projection so the assertions below keep exercising the real production
   entry points. *)
let handle_read_file ~turn_sandbox_factory ~config ~meta ~args =
  (Keeper_tool_filesystem_runtime.handle_read_file_with_outcome
     ~turn_sandbox_factory
     ~config
     ~meta
     ~args)
    .raw_output
;;

let handle_file_write
      ~turn_sandbox_factory
      ~config
      ~meta
      ~publication_recovery
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~args
      ()
  =
  (Keeper_tool_filesystem_runtime.handle_file_write_with_outcome
     ~turn_sandbox_factory
     ~config
     ~meta
     ~publication_recovery
     ?continuation_channel
     ?gate_context
     ?gate_grant
     ~args
     ())
    .raw_output
;;

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
      ?(sandbox = Keeper_types_profile_sandbox.Remote_ssh)
      ?(always_allow = false)
      name
  =
  let json =
    `Assoc
      [ "name", `String name
      ; "trace_id", `String ("trace-" ^ name)
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
       Keeper_registry.For_testing.clear ();
       let config = Workspace.default_config base in
       let meta = make_meta ?sandbox ?always_allow "tester" in
       let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       ensure_dir playground;
       ignore (Keeper_registry.For_testing.register ~base_path:base meta.name meta);
       Masc_test_deps.with_publication_recovery_registry
         ~sw
         ~fs
         ~registry_root:(Workspace.masc_root_dir config)
       @@ fun registry ->
       let publication_recovery =
         { Masc.Keeper_publication_recovery_availability.provider =
             Masc_test_deps.publication_recovery_provider registry
         ; keeper_name = meta.name
         }
       in
       f ~config ~meta ~playground ~publication_recovery)
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
   | Error e -> Alcotest.fail ("failed to seed repository catalog: " ^ e))
;;

let run_git_or_fail ~cwd args =
  match Repo_git.run_git ~cwd args with
  | Ok lines -> lines
  | Error error ->
    Alcotest.failf "git %s failed: %s" (String.concat " " args) error
;;

let test_repository_checkout_projection_reports_typed_freshness () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  allow_repo ~config ~meta "masc";
  let checkout = Filename.concat playground "repos/masc" in
  ensure_dir checkout;
  ignore (run_git_or_fail ~cwd:checkout [ "init"; "-b"; "fixture" ]);
  ignore (run_git_or_fail ~cwd:checkout [ "config"; "user.email"; "test@example.com" ]);
  ignore (run_git_or_fail ~cwd:checkout [ "config"; "user.name"; "Test" ]);
  ignore
    (run_git_or_fail ~cwd:checkout
       [ "remote"; "add"; "origin"; "https://example.invalid/masc.git" ]);
  write_file (Filename.concat checkout "README.md") "first\n";
  ignore (run_git_or_fail ~cwd:checkout [ "add"; "README.md" ]);
  ignore (run_git_or_fail ~cwd:checkout [ "commit"; "-m"; "first" ]);
  ignore
    (run_git_or_fail ~cwd:checkout
       [ "update-ref"; "refs/remotes/origin/main"; "HEAD" ]);
  write_file (Filename.concat checkout "README.md") "second\n";
  ignore (run_git_or_fail ~cwd:checkout [ "add"; "README.md" ]);
  ignore (run_git_or_fail ~cwd:checkout [ "commit"; "-m"; "second" ]);
  write_file (Filename.concat checkout "dirty.txt") "dirty\n";
  let projection =
    Keeper_sandbox_control.repository_checkouts_json ~config ~meta
  in
  let entry =
    projection |> Json.member "entries" |> Json.to_list |> List.hd
  in
  Alcotest.(check string) "checkout" "masc"
    (entry |> Json.member "checkout_name" |> Json.to_string);
  Alcotest.(check string) "catalog state" "registered"
    (entry |> Json.member "catalog" |> Json.member "state" |> Json.to_string);
  Alcotest.(check string) "repository id" "masc"
    (entry |> Json.member "catalog" |> Json.member "repository_id" |> Json.to_string);
  Alcotest.(check string) "branch" "fixture"
    (entry |> Json.member "branch" |> Json.to_string);
  Alcotest.(check bool) "dirty" true
    (entry |> Json.member "dirty" |> Json.to_bool);
  Alcotest.(check string) "freshness" "ahead"
    (entry |> Json.member "freshness" |> Json.member "state" |> Json.to_string);
  Alcotest.(check int) "ahead count" 1
    (entry |> Json.member "freshness" |> Json.member "ahead" |> Json.to_int)
;;

let test_repository_checkout_projection_ignores_symlinked_directory () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  let outside = Filename.concat playground "outside-checkout" in
  ensure_dir outside;
  let repos = Filename.concat playground "repos" in
  ensure_dir repos;
  Unix.symlink outside (Filename.concat repos "linked-checkout");
  let entries =
    Keeper_sandbox_control.repository_checkouts_json ~config ~meta
    |> Json.member "entries"
    |> Json.to_list
  in
  Alcotest.(check int) "symlink checkout excluded" 0 (List.length entries)
;;

let test_repository_checkout_projection_shares_inspection_budget () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  let fake_bin = Filename.concat playground "fake-bin" in
  ensure_dir fake_bin;
  let fake_git = Filename.concat fake_bin "git" in
  write_file fake_git "#!/bin/sh\nexec sleep 30\n";
  Unix.chmod fake_git 0o755;
  List.iter
    (fun name ->
       ensure_dir (Filename.concat playground ("repos/" ^ name ^ "/.git")))
    [ "stalled-a"; "stalled-b" ];
  let old_path = Sys.getenv "PATH" in
  Fun.protect
    ~finally:(fun () -> Unix.putenv "PATH" old_path)
    (fun () ->
       Unix.putenv "PATH" (fake_bin ^ ":" ^ old_path);
       let started_at = Unix.gettimeofday () in
       let projection =
         Keeper_sandbox_control.For_testing.repository_checkouts_json_with_budget
           ~inspection_budget_sec:0.2
           ~config
           ~meta
       in
       let elapsed = Unix.gettimeofday () -. started_at in
       Alcotest.(check string)
         "projection reports the exhausted request budget"
         "inspection_budget_exhausted"
         (projection |> Json.member "state" |> Json.to_string);
       Alcotest.(check int)
         "both checkout identities remain visible"
         2
         (projection |> Json.member "entries" |> Json.to_list |> List.length);
       Alcotest.(check bool)
         "two stalled checkouts share one wall-clock budget"
         true
         (elapsed < 1.0))
;;

let test_repository_checkout_budget_starts_after_discovery () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  let checkout = Filename.concat playground "repos/fast-checkout" in
  ensure_dir checkout;
  ignore (run_git_or_fail ~cwd:checkout [ "init"; "-b"; "main" ]);
  ignore (run_git_or_fail ~cwd:checkout [ "config"; "user.email"; "test@example.com" ]);
  ignore (run_git_or_fail ~cwd:checkout [ "config"; "user.name"; "Test" ]);
  ignore
    (run_git_or_fail ~cwd:checkout [ "commit"; "--allow-empty"; "-m"; "initial" ]);
  ignore
    (run_git_or_fail
       ~cwd:checkout
       [ "remote"; "add"; "origin"; "https://example.invalid/fast-checkout.git" ]);
  let projection =
    Keeper_sandbox_control.For_testing
    .repository_checkouts_json_with_budget_after_discovery
      ~before_git_inspection:(fun () -> Unix.sleepf 0.6)
      ~inspection_budget_sec:0.5
      ~config
      ~meta
  in
  Alcotest.(check string)
    "catalog and filesystem discovery do not spend Git inspection budget"
    "available"
    (projection |> Json.member "state" |> Json.to_string);
  let entry = projection |> Json.member "entries" |> Json.to_list |> List.hd in
  Alcotest.(check string)
    "fast checkout remains inspectable after slow discovery"
    "available"
    (entry |> Json.member "inspection_state" |> Json.to_string)
;;

let test_visible_scratch_read_resolves_to_private_storage () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  let target = Filename.concat playground "scratch/README.md" in
  write_file target "visible scratch\n";
  match
    Keeper_tool_shared_runtime.resolve_keeper_read_path
      ~config
      ~meta
      ~raw_path:"scratch/README.md"
  with
  | Ok path -> Alcotest.(check string) "resolved path" target path
  | Error e -> Alcotest.fail ("visible scratch path should resolve: " ^ e)
;;

let test_absolute_playground_path_is_allowed () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  let target = Filename.concat playground "scratch/README.md" in
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
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  let target = Filename.concat playground "scratch/README.md" in
  match
    Keeper_tool_shared_runtime.resolve_keeper_read_path
      ~config
      ~meta
      ~raw_path:"scratch/README.md"
  with
  | Ok path -> Alcotest.(check string) "relative path stays in playground" target path
  | Error e -> Alcotest.fail ("relative path should resolve in playground: " ^ e)
;;

let test_relative_parent_escape_is_rejected () =
  setup
  @@ fun ~config ~meta ~playground:_ ~publication_recovery:_ ->
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
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  allow_repo ~config ~meta "masc";
  let target = Filename.concat playground "repos/masc/README.md" in
  write_file target "repo readme\n";
  let raw =
    handle_read_file
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
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  allow_repo ~config ~meta "masc";
  let target = Filename.concat playground "repos/masc/docs/backlog.json" in
  write_file target {|{"scope":"repository fixture"}|};
  let raw =
    handle_read_file
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
  @@ fun ~config ~meta ~playground:_ ~publication_recovery:_ ->
  allow_repo ~config ~meta "masc";
  let raw =
    handle_read_file
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

(* A keeper that guesses the host layout and one whose repos were never
   materialized both got "directory does not exist", and the two need opposite
   responses. Live fixture-keeper asked for
   [workspace/yousleepwhen/masc] and retried (#23442).

   The hint enumerates the playground's own [repos/]; it does not infer which
   repo was meant. The last case pins that distinction: the file-path failure
   keeps refusing to volunteer a repository list, which is a separate decision
   this change does not touch. *)
let test_cwd_rejection_names_the_materialized_repos () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  allow_repo ~config ~meta "masc";
  (* The hint enumerates git checkouts measured under the workspace root, not
     every directory under a prescribed [repos/]. A fixture without [.git] is a
     plain directory — still a legal cwd, but not something the system reports
     as a checkout. *)
  write_file (Filename.concat playground "repos/masc/.git/HEAD") "ref: refs/heads/main\n";
  write_file (Filename.concat playground "repos/masc/README.md") "readme\n";
  let raw =
    handle_read_file
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~args:
        (`Assoc
            [ "cwd", `String "workspace/yousleepwhen/masc"
            ; "path", `String "README.md"
            ; "max_bytes", `Int 4096
            ])
  in
  if parse_ok raw then Alcotest.failf "expected Read to fail, got ok: %s" raw;
  let error = Option.value (parse_string "error" raw) ~default:raw in
  let contains needle = String_util.contains_substring error needle in
  Alcotest.(check bool) "names the cwd vocabulary" true (contains "repos/masc");
  Alcotest.(check bool) "still says why it failed" true
    (contains "cwd_not_directory")
;;

let test_cwd_rejection_says_when_nothing_is_materialized () =
  setup
  @@ fun ~config ~meta ~playground:_ ~publication_recovery:_ ->
  allow_repo ~config ~meta "masc";
  let raw =
    handle_read_file
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
  if parse_ok raw then Alcotest.failf "expected Read to fail, got ok: %s" raw;
  let error = Option.value (parse_string "error" raw) ~default:raw in
  Alcotest.(check bool) "distinguishes empty from wrong" true
    (String_util.contains_substring error "no repository is materialized")
;;

let test_valid_repo_cwd_carries_no_hint () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  allow_repo ~config ~meta "masc";
  write_file (Filename.concat playground "repos/masc/README.md") "readme\n";
  let raw =
    handle_read_file
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
  Alcotest.(check bool) "success carries no cwd advice" false
    (String_util.contains_substring raw "available repo cwds")
;;

let test_missing_file_still_volunteers_no_repository_list () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  allow_repo ~config ~meta "masc";
  write_file (Filename.concat playground "repos/masc/README.md") "readme\n";
  let raw =
    handle_read_file
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~args:
        (`Assoc
            [ "path", `String "repos/masc/does_not_exist_xyz.ml"
            ; "max_bytes", `Int 4096
            ])
  in
  if parse_ok raw then Alcotest.failf "expected Read to fail, got ok: %s" raw;
  Alcotest.(check bool) "no inferred repository list" true
    (Json.member "available_repos" (parse raw) = `Null)
;;

let test_write_visible_scratch_path () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker ~always_allow:true
  @@ fun ~config ~meta ~playground ~publication_recovery ->
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
      ~args:
        (`Assoc
            [ "path", `String "scratch/allowed.txt"
            ; "mode", `String "overwrite"
            ; "content", `String "allowed"
            ])
      ()
  in
  if not (parse_ok raw) then Alcotest.failf "expected Write ok, got: %s" raw;
  Alcotest.(check string)
    "content landed"
    "allowed"
    (Fs_compat.load_file (Filename.concat playground "scratch/allowed.txt"))
;;

let () =
  Alcotest.run
    "Keeper_visible_path_projection"
    [ ( "shared_projection"
      , [ Alcotest.test_case
            "visible scratch read resolves to private storage"
            `Quick
            test_visible_scratch_read_resolves_to_private_storage
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
            "Write visible scratch path"
            `Quick
            test_write_visible_scratch_path
        ; Alcotest.test_case
            "repository backlog.json remains readable"
            `Quick
            test_repository_backlog_file_is_readable
        ; Alcotest.test_case
            "repo-prefixed missing read surfaces playground hint"
            `Quick
            test_repo_prefixed_missing_read_preserves_exact_input
        ; Alcotest.test_case
            "cwd rejection names the materialized repos"
            `Quick
            test_cwd_rejection_names_the_materialized_repos
        ; Alcotest.test_case
            "cwd rejection says when nothing is materialized"
            `Quick
            test_cwd_rejection_says_when_nothing_is_materialized
        ; Alcotest.test_case
            "valid repo cwd carries no hint"
            `Quick
            test_valid_repo_cwd_carries_no_hint
        ; Alcotest.test_case
            "missing file still volunteers no repository list"
            `Quick
            test_missing_file_still_volunteers_no_repository_list
        ] )
    ; ( "repository_checkouts"
      , [ Alcotest.test_case
            "reports catalog identity, dirty state, and freshness"
            `Quick
            test_repository_checkout_projection_reports_typed_freshness
        ; Alcotest.test_case
            "ignores symlinked checkout directories"
            `Quick
            test_repository_checkout_projection_ignores_symlinked_directory
        ; Alcotest.test_case
            "shares one inspection budget across checkouts"
            `Quick
            test_repository_checkout_projection_shares_inspection_budget
        ; Alcotest.test_case
            "starts inspection budget after discovery"
            `Quick
            test_repository_checkout_budget_starts_after_discovery
        ] )
    ]
;;
