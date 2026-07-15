(** Tests for [Keeper_tool_filesystem_runtime.handle_file_write] mode=patch.

    RFC-0006 Phase A.4 — string-replace edit mode added so the
    Provider_a Code [Edit] cognate can be wired through OAS dual
    registration. *)

module Workspace = Masc.Workspace
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_tool_filesystem_runtime = Masc.Keeper_tool_filesystem_runtime
module Keeper_registry = Masc.Keeper_registry
module Keeper_tool_alias = Masc.Keeper_tool_alias
module Keeper_types = Keeper_types
module Keeper_alerting_path = Masc.Keeper_alerting_path
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util

(* ── Helpers ─────────────────────────────────────────────────────── *)

let temp_dir () =
  let d = Filename.temp_file "tool_edit_file_patch_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let p = Filename.dirname path in
    if p <> path then ensure_dir p;
    Unix.mkdir path 0o755)

let make_meta ?(sandbox = Keeper_types_profile_sandbox.Local) name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("allowed_paths", `List [ `String "*" ]);
        ("always_allow", `Bool true);
        ( "sandbox_profile",
          `String (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox) );
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> Alcotest.fail e

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ~fs ~sw ()

let setup ?(sandbox = Keeper_types_profile_sandbox.Local) f =
  with_eio_fs @@ fun ~fs ~sw () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.clear ();
  let config = Workspace.default_config base in
  let meta = make_meta ~sandbox "tester" in
  let playground = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  ignore (Keeper_registry.register ~base_path:base meta.name meta);
  let registry =
    match
      Fs_compat.open_publication_recovery_registry
        ~sw
        ~fs
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
      (Fs_compat.publication_recovery_lane_open_error_to_string error)

let parse raw = Yojson.Safe.from_string raw

let parse_ok raw =
  parse raw |> Json.member "ok" |> Json.to_bool_option
  |> Option.value ~default:false

let parse_error raw =
  parse raw |> Json.member "error" |> Json.to_string_option

let parse_int raw field =
  parse raw |> Json.member field |> Json.to_int_option

let parse_string raw field =
  parse raw |> Json.member field |> Json.to_string_option

let parse_write_region_observation_error raw =
  parse raw
  |> Json.member "ide_observation"
  |> Json.member "write_region"
  |> Json.member "error"
  |> Json.to_string_option

let permissions path = (Unix.lstat path).Unix.st_perm

let public_fs_edit_call
      ~public
      ~config
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~publication_recovery_access
      args
  =
  let args = Keeper_tool_alias.translate_input ~public args in
  Keeper_tool_filesystem_runtime.handle_file_write
    ~turn_sandbox_factory:None
    ~config
    ~meta
    ~publication_recovery_access
    ~args
    ()

let seed_single_playground_repo ~config ~(meta : Keeper_meta_contract.keeper_meta) playground =
  let repo = Filename.concat playground "repos/masc" in
  ensure_dir (Filename.concat repo ".git");
  let repository : Repo_manager_types.repository =
    { id = "masc"
    ; name = "masc"
    ; url = "https://example.invalid/masc.git"
    ; local_path = repo
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
  (match Repo_store.save_all ~base_path:config.Workspace.base_path [ repository ] with
   | Ok () -> ()
   | Error msg -> Alcotest.failf "seed repository catalog: %s" msg);
  let mapping : Repo_manager_types.keeper_repo_mapping =
    (Repo_manager_types.make_keeper_repo_mapping ~keeper_id:meta.name
       ~repository_ids:[ "masc" ])
  in
  (match Keeper_repo_mapping.save_mapping ~base_path:config.Workspace.base_path mapping with
   | Ok () -> ()
   | Error msg -> Alcotest.failf "seed keeper repo mapping: %s" msg);
  repo

let with_turn_sandbox_factory ~enabled ~config ~meta f =
  if not enabled
  then f None
  else
    let factory =
      Masc.Keeper_sandbox_factory.create ~config ~meta ~turn_id:1 ()
    in
    Fun.protect
      ~finally:(fun () -> Masc.Keeper_sandbox_factory.cleanup factory)
      (fun () -> f (Some factory))

(* ── Tests ───────────────────────────────────────────────────────── *)

let test_patch_unique_match () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\nlet y = 2\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "let x = 1");
            ("new_string", `String "let x = 42");
          ])
      ()
  in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check (option int)) "occurrences=1" (Some 1)
    (parse_int raw "occurrences");
  let after = Fs_compat.load_file path in
  Alcotest.(check string) "file content updated"
    "let x = 42\nlet y = 2\n" after

let test_patch_no_match_errors () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "let z = 99");
            ("new_string", `String "let z = 100");
          ])
      ()
  in
  Alcotest.(check bool) "ok=false" false (parse_ok raw);
  match parse_error raw with
  | None -> Alcotest.fail "expected error message"
  | Some msg ->
      Alcotest.(check bool) "error mentions not found" true
        (let needle = "not found" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

let test_patch_multiple_matches_without_replace_all_errors () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "x = 1\nx = 1\nx = 1\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "x = 1");
            ("new_string", `String "x = 2");
          ])
      ()
  in
  Alcotest.(check bool) "ok=false" false (parse_ok raw);
  let after = Fs_compat.load_file path in
  Alcotest.(check string) "file unchanged on rejection"
    "x = 1\nx = 1\nx = 1\n" after

let test_patch_replace_all () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "x = 1\nx = 1\nx = 1\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "x = 1");
            ("new_string", `String "x = 2");
            ("replace_all", `Bool true);
          ])
      ()
  in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check (option int)) "occurrences=3" (Some 3)
    (parse_int raw "occurrences");
  Alcotest.(check string) "all replaced"
    "x = 2\nx = 2\nx = 2\n" (Fs_compat.load_file path)

let test_patch_empty_old_string_errors () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "");
            ("new_string", `String "anything");
          ])
      ()
  in
  Alcotest.(check bool) "ok=false" false (parse_ok raw);
  Alcotest.(check bool) "error message present" true
    (Option.is_some (parse_error raw))

let test_patch_missing_file_errors () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let path = Filename.concat playground "ghost.ml" in
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "x");
            ("new_string", `String "y");
          ])
      ()
  in
  Alcotest.(check bool) "ok=false" false (parse_ok raw)

let test_patch_delete_via_empty_new_string () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "keep me\nDELETE_ME\nkeep me too\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "DELETE_ME\n");
            ("new_string", `String "");
          ])
      ()
  in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check string) "deletion landed"
    "keep me\nkeep me too\n" (Fs_compat.load_file path)

let test_overwrite_unchanged_by_patch_addition () =
  (* Regression: introducing Patch must not break existing overwrite. *)
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let path = Filename.concat playground "new.txt" in
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "overwrite");
            ("content", `String "fresh");
          ])
      ()
  in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check string) "overwrite wrote bytes"
    "fresh" (Fs_compat.load_file path)

let test_atomic_writes_preserve_existing_executable_permissions () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let run ~label ~initial ~args ~expected =
    let path = Filename.concat playground (label ^ ".sh") in
    Fs_compat.save_file path initial;
    Unix.chmod path 0o751;
    let raw =
      Keeper_tool_filesystem_runtime.handle_file_write
        ~turn_sandbox_factory:None
        ~config
        ~meta
        ~publication_recovery_access
        ~args:(`Assoc (("path", `String path) :: args))
        ()
    in
    Alcotest.(check bool) (label ^ " succeeded") true (parse_ok raw);
    Alcotest.(check int) (label ^ " preserved exact executable mode")
      0o751
      (permissions path);
    Alcotest.(check string) (label ^ " wrote expected content")
      expected
      (Fs_compat.load_file path)
  in
  run
    ~label:"overwrite-executable"
    ~initial:"#!/bin/sh\nexit 1\n"
    ~args:
      [ "mode", `String "overwrite"
      ; "content", `String "#!/bin/sh\nexit 0\n"
      ]
    ~expected:"#!/bin/sh\nexit 0\n";
  run
    ~label:"patch-executable"
    ~initial:"#!/bin/sh\nexit 1\n"
    ~args:
      [ "mode", `String "patch"
      ; "old_string", `String "exit 1"
      ; "new_string", `String "exit 0"
      ]
    ~expected:"#!/bin/sh\nexit 0\n"

let test_created_entries_have_exact_authorized_permissions () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let parent = Filename.concat playground "created-parent" in
  let nested = Filename.concat parent "nested" in
  let path = Filename.concat nested "created.txt" in
  let previous_umask = Unix.umask 0o077 in
  Fun.protect
    ~finally:(fun () ->
      let _replaced_umask = Unix.umask previous_umask in
      ())
    (fun () ->
       let raw =
         Keeper_tool_filesystem_runtime.handle_file_write
           ~turn_sandbox_factory:None
           ~config
           ~meta
           ~publication_recovery_access
           ~args:
             (`Assoc
                [ "path", `String path
                ; "mode", `String "overwrite"
                ; "content", `String "created"
                ])
           ()
       in
       if not (parse_ok raw)
       then Alcotest.failf "nested create failed: %s" raw);
  Alcotest.(check int) "first created parent mode is exact" 0o755 (permissions parent);
  Alcotest.(check int) "nested created parent mode is exact" 0o755 (permissions nested);
  Alcotest.(check int) "created file mode is exact" 0o644 (permissions path)

let test_patch_symlink_result_is_regular_0644 () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let referent = Filename.concat playground "patch-referent.txt" in
  let leaf = Filename.concat playground "patch-link.txt" in
  Fs_compat.save_file referent "value=before\n";
  Unix.chmod referent 0o751;
  Unix.symlink referent leaf;
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
           [ "path", `String leaf
           ; "mode", `String "patch"
           ; "old_string", `String "before"
           ; "new_string", `String "after"
           ])
      ()
  in
  if not (parse_ok raw) then Alcotest.failf "symlink patch failed: %s" raw;
  Alcotest.(check bool) "lexical symlink became a regular file" true
    ((Unix.lstat leaf).Unix.st_kind = Unix.S_REG);
  Alcotest.(check int) "replacement of symlink has exact default mode" 0o644
    (permissions leaf);
  Alcotest.(check string) "replacement content was derived from referent"
    "value=after\n"
    (Fs_compat.load_file leaf);
  Alcotest.(check string) "referent content remains unchanged"
    "value=before\n"
    (Fs_compat.load_file referent);
  Alcotest.(check int) "referent permissions remain unchanged" 0o751
    (permissions referent)

let test_outside_referent_endpoint_semantics ~sandbox ~with_runtime () =
  setup ~sandbox
  @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  with_turn_sandbox_factory ~enabled:with_runtime ~config ~meta
  @@ fun turn_sandbox_factory ->
  let outside_dir = Filename.concat config.Workspace.base_path "outside-referents" in
  ensure_dir outside_dir;
  let run ~label ~args ~expected_ok ~expected_leaf_kind ~expected_leaf_content =
    let outside = Filename.concat outside_dir (label ^ ".txt") in
    let leaf = Filename.concat playground (label ^ ".txt") in
    Fs_compat.save_file outside ("outside-" ^ label);
    Unix.symlink outside leaf;
    let raw =
      Keeper_tool_filesystem_runtime.handle_file_write
        ~turn_sandbox_factory
        ~config
        ~meta
        ~publication_recovery_access
        ~args:(`Assoc (("path", `String leaf) :: args))
        ()
    in
    Alcotest.(check bool) (label ^ " outcome") expected_ok (parse_ok raw);
    Alcotest.(check string) (label ^ " outside referent unchanged")
      ("outside-" ^ label)
      (Fs_compat.load_file outside);
    Alcotest.(check bool) (label ^ " lexical leaf kind") true
      (match (Unix.lstat leaf).Unix.st_kind, expected_leaf_kind with
       | Unix.S_REG, `Regular | Unix.S_LNK, `Symlink -> true
       | _ -> false);
    Alcotest.(check string) (label ^ " lexical leaf content")
      expected_leaf_content
      (Fs_compat.load_file leaf)
  in
  run
    ~label:"overwrite-outside-symlink"
    ~args:[ "mode", `String "overwrite"; "content", `String "replacement" ]
    ~expected_ok:true
    ~expected_leaf_kind:`Regular
    ~expected_leaf_content:"replacement";
  run
    ~label:"patch-outside-symlink"
    ~args:
      [ "mode", `String "patch"
      ; "old_string", `String "outside"
      ; "new_string", `String "changed"
      ]
    ~expected_ok:false
    ~expected_leaf_kind:`Symlink
    ~expected_leaf_content:"outside-patch-outside-symlink";
  run
    ~label:"append-outside-symlink"
    ~args:[ "mode", `String "append"; "content", `String "changed" ]
    ~expected_ok:false
    ~expected_leaf_kind:`Symlink
    ~expected_leaf_content:"outside-append-outside-symlink"

let test_append_inside_symlink_uses_canonical_referent_capability () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let referent_dir = Filename.concat playground "append-referent" in
  let lexical_dir = Filename.concat playground "append-link" in
  ensure_dir referent_dir;
  ensure_dir lexical_dir;
  let referent = Filename.concat referent_dir "target.txt" in
  let lexical = Filename.concat lexical_dir "target.txt" in
  Fs_compat.save_file referent "before\n";
  Unix.symlink referent lexical;
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
           [ "path", `String lexical
           ; "mode", `String "append"
           ; "content", `String "after\n"
           ])
      ()
  in
  if not (parse_ok raw)
  then Alcotest.failf "inside symlink append failed: %s" raw;
  Alcotest.(check string) "canonical referent receives append"
    "before\nafter\n"
    (Fs_compat.load_file referent);
  Alcotest.(check bool) "lexical endpoint remains a symlink" true
    ((Unix.lstat lexical).Unix.st_kind = Unix.S_LNK)

let test_symlink_component_swap_cannot_escape_allowed_root
      ~sandbox
      ~with_runtime
      ()
  =
  setup ~sandbox
  @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  with_turn_sandbox_factory ~enabled:with_runtime ~config ~meta
  @@ fun turn_sandbox_factory ->
  let outside = Filename.concat config.Workspace.base_path "outside-write-targets" in
  ensure_dir outside;
  let run_case
        ~label
        ~inside_content
        ~expected_inside_content
        ~outside_content
        ~args_for
    =
    let component = Filename.concat playground ("swap-" ^ label) in
    let moved_component = component ^ "-original" in
    let case_outside = Filename.concat outside label in
    ensure_dir component;
    ensure_dir case_outside;
    let target = Filename.concat component "target.txt" in
    let moved_target = Filename.concat moved_component "target.txt" in
    let outside_target = Filename.concat case_outside "target.txt" in
    Option.iter (Fs_compat.save_file target) inside_content;
    Option.iter (Fs_compat.save_file outside_target) outside_content;
    let gate_context () =
      Unix.rename component moved_component;
      Unix.symlink case_outside component;
      { Masc.Keeper_gate.turn_id = None
      ; snapshot = `Assoc [ "race", `String "symlink_component_swap" ]
      }
    in
    let raw =
      Keeper_tool_filesystem_runtime.handle_file_write
        ~turn_sandbox_factory
        ~config
        ~meta
        ~publication_recovery_access
        ~gate_context
        ~args:(`Assoc (args_for target))
        ()
    in
    if not (parse_ok raw)
    then Alcotest.failf "%s write did not use pinned parent: %s" label raw;
    if with_runtime
    then
      Alcotest.(check (option string)) (label ^ " used sandbox backend")
        (Some "docker")
        (parse_string raw "via");
    Alcotest.(check (option string)) (label ^ " outside file unchanged")
      outside_content
      (if Fs_compat.file_exists outside_target
       then Some (Fs_compat.load_file outside_target)
       else None);
    Alcotest.(check (option string)) (label ^ " write landed under pinned parent")
      expected_inside_content
      (if Fs_compat.file_exists moved_target
       then Some (Fs_compat.load_file moved_target)
       else None)
  in
  run_case
    ~label:"overwrite"
    ~inside_content:None
    ~expected_inside_content:(Some "must-stay-contained")
    ~outside_content:None
    ~args_for:(fun target ->
      [ "path", `String target
      ; "mode", `String "overwrite"
      ; "content", `String "must-stay-contained"
      ]);
  run_case
    ~label:"append"
    ~inside_content:(Some "inside\n")
    ~expected_inside_content:(Some "inside\nmust-not-append\n")
    ~outside_content:(Some "outside\n")
    ~args_for:(fun target ->
      [ "path", `String target
      ; "mode", `String "append"
      ; "content", `String "must-not-append\n"
      ]);
  run_case
    ~label:"patch"
    ~inside_content:(Some "let value = 1\n")
    ~expected_inside_content:(Some "let value = 2\n")
    ~outside_content:(Some "outside patch sentinel\n")
    ~args_for:(fun target ->
      [ "path", `String target
      ; "mode", `String "patch"
      ; "old_string", `String "let value = 1"
      ; "new_string", `String "let value = 2"
      ])

let test_sandbox_root_swap_after_open_keeps_pinned_capability
      ~sandbox
      ~with_runtime
      ()
  =
  setup ~sandbox
  @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  with_turn_sandbox_factory ~enabled:with_runtime ~config ~meta
  @@ fun turn_sandbox_factory ->
  let playground = Keeper_alerting_path.strip_trailing_slashes playground in
  let moved_playground = playground ^ "-pinned" in
  let outside = Filename.concat config.Workspace.base_path "root-swap-outside" in
  ensure_dir outside;
  let target = Filename.concat playground "root-swap.txt" in
  let outside_target = Filename.concat outside "root-swap.txt" in
  let gate_context () =
    Unix.rename playground moved_playground;
    Unix.symlink outside playground;
    { Masc.Keeper_gate.turn_id = None
    ; snapshot = `Assoc [ "race", `String "sandbox_root_swap" ]
    }
  in
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory
      ~config
      ~meta
      ~publication_recovery_access
      ~gate_context
      ~args:
        (`Assoc
           [ "path", `String target
           ; "mode", `String "overwrite"
           ; "content", `String "pinned-root-write"
           ])
      ()
  in
  Alcotest.(check bool) "write completed through pinned root" true (parse_ok raw);
  if with_runtime
  then
    Alcotest.(check (option string)) "write used sandbox backend"
      (Some "docker")
      (parse_string raw "via");
  Alcotest.(check bool) "swapped-in outside root untouched" false
    (Fs_compat.file_exists outside_target);
  Alcotest.(check string) "write landed in originally authorized root resource"
    "pinned-root-write"
    (Fs_compat.load_file (Filename.concat moved_playground "root-swap.txt"))

let test_docker_runtime_leaf_swap_preserves_exact_effect () =
  setup ~sandbox:Keeper_types_profile_sandbox.Docker
  @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  with_turn_sandbox_factory ~enabled:true ~config ~meta
  @@ fun turn_sandbox_factory ->
  let outside = Filename.concat config.Workspace.base_path "leaf-swap-outside" in
  ensure_dir outside;
  let run_existing_case
        ~label
        ~initial
        ~args
        ~expected_moved
        ~expected_leaf
        ~expected_leaf_kind
    =
    let parent = Filename.concat playground ("leaf-" ^ label) in
    ensure_dir parent;
    let target = Filename.concat parent "target.txt" in
    let moved_target = target ^ "-original" in
    let outside_target = Filename.concat outside (label ^ ".txt") in
    Fs_compat.save_file target initial;
    Fs_compat.save_file outside_target ("outside-" ^ label);
    let gate_context () =
      Unix.rename target moved_target;
      Unix.symlink outside_target target;
      { Masc.Keeper_gate.turn_id = None
      ; snapshot = `Assoc [ "race", `String "leaf_swap" ]
      }
    in
    let raw =
      Keeper_tool_filesystem_runtime.handle_file_write
        ~turn_sandbox_factory
        ~config
        ~meta
        ~publication_recovery_access
        ~gate_context
        ~args:(`Assoc (("path", `String target) :: args))
        ()
    in
    Alcotest.(check bool) (label ^ " succeeded") true (parse_ok raw);
    Alcotest.(check (option string)) (label ^ " used sandbox backend")
      (Some "docker")
      (parse_string raw "via");
    Alcotest.(check string) (label ^ " outside resource unchanged")
      ("outside-" ^ label)
      (Fs_compat.load_file outside_target);
    Alcotest.(check string) (label ^ " original resource result")
      expected_moved
      (Fs_compat.load_file moved_target);
    Alcotest.(check string) (label ^ " lexical leaf result")
      expected_leaf
      (Fs_compat.load_file target);
    Alcotest.(check bool) (label ^ " lexical leaf kind") true
      (match (Unix.lstat target).Unix.st_kind, expected_leaf_kind with
       | Unix.S_REG, `Regular | Unix.S_LNK, `Symlink -> true
       | _ -> false)
  in
  run_existing_case
    ~label:"overwrite"
    ~initial:"inside-overwrite"
    ~args:[ "mode", `String "overwrite"; "content", `String "replacement" ]
    ~expected_moved:"inside-overwrite"
    ~expected_leaf:"replacement"
    ~expected_leaf_kind:`Regular;
  run_existing_case
    ~label:"patch"
    ~initial:"let leaf = 1\n"
    ~args:
      [ "mode", `String "patch"
      ; "old_string", `String "let leaf = 1"
      ; "new_string", `String "let leaf = 2"
      ]
    ~expected_moved:"let leaf = 1\n"
    ~expected_leaf:"let leaf = 2\n"
    ~expected_leaf_kind:`Regular;
  run_existing_case
    ~label:"append"
    ~initial:"inside-append\n"
    ~args:[ "mode", `String "append"; "content", `String "pinned-append\n" ]
    ~expected_moved:"inside-append\npinned-append\n"
    ~expected_leaf:"outside-append"
    ~expected_leaf_kind:`Symlink;
  let parent = Filename.concat playground "leaf-append-missing" in
  ensure_dir parent;
  let target = Filename.concat parent "target.txt" in
  let outside_target = Filename.concat outside "append-missing.txt" in
  Fs_compat.save_file outside_target "outside-append-missing";
  let gate_context () =
    Unix.symlink outside_target target;
    { Masc.Keeper_gate.turn_id = None
    ; snapshot = `Assoc [ "race", `String "missing_leaf_appeared" ]
    }
  in
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory
      ~config
      ~meta
      ~publication_recovery_access
      ~gate_context
      ~args:
        (`Assoc
           [ "path", `String target
           ; "mode", `String "append"
           ; "content", `String "must-not-follow"
           ])
      ()
  in
  Alcotest.(check bool) "missing append race failed closed" false (parse_ok raw);
  Alcotest.(check bool) "missing append race surfaced an error" true
    (Option.is_some (parse_error raw));
  Alcotest.(check string) "missing append outside resource unchanged"
    "outside-append-missing"
    (Fs_compat.load_file outside_target)

let check_invalid_mode_is_rejected ~label ~mode ~expected_error =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let path = Filename.concat playground (label ^ ".txt") in
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write ~turn_sandbox_factory:None ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String mode);
            ("content", `String "fresh");
          ])
      ()
  in
  Alcotest.(check bool) "ok=false" false (parse_ok raw);
  Alcotest.(check (option string)) (label ^ " rejected")
    (Some expected_error)
    (parse_error raw);
  Alcotest.(check bool) "file not written" false (Fs_compat.file_exists path)

let test_empty_mode_is_rejected () =
  check_invalid_mode_is_rejected ~label:"empty-mode" ~mode:""
    ~expected_error:"mode must be one of [overwrite, append, patch], got \"\"."

let test_spaces_only_mode_is_rejected () =
  check_invalid_mode_is_rejected ~label:"spaces-only-mode" ~mode:"   "
    ~expected_error:"mode must be one of [overwrite, append, patch], got \"   \"."

let test_tab_only_mode_is_rejected () =
  check_invalid_mode_is_rejected ~label:"tab-only-mode" ~mode:"\t"
    ~expected_error:"mode must be one of [overwrite, append, patch], got \"\\t\"."

let test_public_edit_file_uses_explicit_repo_path () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let repo = seed_single_playground_repo ~config ~meta playground in
  let path = Filename.concat repo "lib/src.ml" in
  ensure_dir (Filename.dirname path);
  Fs_compat.save_file path "let x = 1\n";
  let raw =
    public_fs_edit_call
      ~public:"Edit"
      ~config
      ~meta
      ~publication_recovery_access
      (`Assoc
        [
          ("file_path", `String "repos/masc/lib/src.ml");
          ("old_string", `String "let x = 1");
          ("new_string", `String "let x = 2");
        ])
  in
  if not (parse_ok raw) then Alcotest.failf "public Edit failed: %s" raw;
  Alcotest.(check string) "file edited through explicit repo path"
    "let x = 2\n" (Fs_compat.load_file path)

let test_public_write_file_uses_explicit_repo_path () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let repo = seed_single_playground_repo ~config ~meta playground in
  let path = Filename.concat repo "lib/generated.ml" in
  let raw =
    public_fs_edit_call
      ~public:"Write"
      ~config
      ~meta
      ~publication_recovery_access
      (`Assoc
        [
          ("file_path", `String "repos/masc/lib/generated.ml");
          ("content", `String "let generated = true\n");
        ])
  in
  if not (parse_ok raw) then Alcotest.failf "public Write failed: %s" raw;
  Alcotest.(check string) "file written through explicit repo path"
    "let generated = true\n" (Fs_compat.load_file path)

let test_write_file_surfaces_missing_ide_observation_sink () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  Agent_observation.reset_for_testing ();
  let path = Filename.concat playground "observed.ml" in
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
          [ "path", `String path
          ; "mode", `String "overwrite"
          ; "content", `String "let observed = true\n"
          ])
      ()
  in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check string) "file written despite observation failure"
    "let observed = true\n" (Fs_compat.load_file path);
  Alcotest.(check (option string))
    "write-region observation failure is surfaced"
    (Some "write_region sink is not installed")
    (parse_write_region_observation_error raw)

let test_write_file_sanitizes_ide_observation_sink_failure () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  Agent_observation.reset_for_testing ();
  Agent_observation.register_write_region_sink (fun _ ->
    Error Agent_observation.Write_region_sink_failed);
  Fun.protect
    ~finally:Agent_observation.reset_for_testing
    (fun () ->
       let path = Filename.concat playground "observed-sink-failure.ml" in
       let raw =
         Keeper_tool_filesystem_runtime.handle_file_write
           ~turn_sandbox_factory:None
           ~config
           ~meta
           ~publication_recovery_access
           ~args:
             (`Assoc
               [ "path", `String path
               ; "mode", `String "overwrite"
               ; "content", `String "let observed = true\n"
               ])
           ()
       in
       Alcotest.(check bool) "ok" true (parse_ok raw);
       Alcotest.(check string) "file written despite observation failure"
         "let observed = true\n" (Fs_compat.load_file path);
       Alcotest.(check (option string))
         "write-region observation failure is sanitized"
         (Some "write_region sink failed")
         (parse_write_region_observation_error raw))

let () =
  Alcotest.run "Keeper_fs_edit_patch"
    [
      ( "patch-mode",
        [
          Alcotest.test_case "unique match replaces" `Quick
            test_patch_unique_match;
          Alcotest.test_case "no match returns error" `Quick
            test_patch_no_match_errors;
          Alcotest.test_case "multi match without replace_all rejected"
            `Quick test_patch_multiple_matches_without_replace_all_errors;
          Alcotest.test_case "replace_all applies to every occurrence"
            `Quick test_patch_replace_all;
          Alcotest.test_case "empty old_string rejected" `Quick
            test_patch_empty_old_string_errors;
          Alcotest.test_case "missing file rejected" `Quick
            test_patch_missing_file_errors;
          Alcotest.test_case "empty new_string deletes substring" `Quick
            test_patch_delete_via_empty_new_string;
          Alcotest.test_case "overwrite mode regression" `Quick
            test_overwrite_unchanged_by_patch_addition;
          Alcotest.test_case
            "atomic writes preserve existing executable permissions"
            `Quick
            test_atomic_writes_preserve_existing_executable_permissions;
          Alcotest.test_case
            "created entries have exact authorized permissions"
            `Quick
            test_created_entries_have_exact_authorized_permissions;
          Alcotest.test_case
            "patching a symlink creates a regular 0644 lexical entry"
            `Quick
            test_patch_symlink_result_is_regular_0644;
          Alcotest.test_case
            "Local outside-referent endpoint semantics are operation-specific"
            `Quick
            (test_outside_referent_endpoint_semantics
               ~sandbox:Keeper_types_profile_sandbox.Local
               ~with_runtime:false);
          Alcotest.test_case
            "Docker outside-referent endpoint semantics are operation-specific"
            `Quick
            (test_outside_referent_endpoint_semantics
               ~sandbox:Keeper_types_profile_sandbox.Docker
               ~with_runtime:true);
          Alcotest.test_case
            "append through an inside symlink uses the canonical referent capability"
            `Quick
            test_append_inside_symlink_uses_canonical_referent_capability;
          Alcotest.test_case
            "local symlink component swap cannot escape allowed root"
            `Quick
            (test_symlink_component_swap_cannot_escape_allowed_root
               ~sandbox:Keeper_types_profile_sandbox.Local
               ~with_runtime:false);
          Alcotest.test_case
            "local sandbox root swap keeps pinned capability"
            `Quick
            (test_sandbox_root_swap_after_open_keeps_pinned_capability
               ~sandbox:Keeper_types_profile_sandbox.Local
               ~with_runtime:false);
          Alcotest.test_case
            "Docker runtime symlink component swap cannot escape allowed root"
            `Quick
            (test_symlink_component_swap_cannot_escape_allowed_root
               ~sandbox:Keeper_types_profile_sandbox.Docker
               ~with_runtime:true);
          Alcotest.test_case
            "Docker runtime sandbox root swap keeps pinned capability"
            `Quick
            (test_sandbox_root_swap_after_open_keeps_pinned_capability
               ~sandbox:Keeper_types_profile_sandbox.Docker
               ~with_runtime:true);
          Alcotest.test_case
            "Docker runtime leaf swaps preserve exact effects"
            `Quick
            test_docker_runtime_leaf_swap_preserves_exact_effect;
          Alcotest.test_case "empty mode rejected" `Quick
            test_empty_mode_is_rejected;
          Alcotest.test_case "spaces-only mode rejected" `Quick
            test_spaces_only_mode_is_rejected;
          Alcotest.test_case "tab-only mode rejected" `Quick
            test_tab_only_mode_is_rejected;
          Alcotest.test_case "public Edit uses explicit repo path" `Quick
            test_public_edit_file_uses_explicit_repo_path;
          Alcotest.test_case "public Write uses explicit repo path" `Quick
            test_public_write_file_uses_explicit_repo_path;
          Alcotest.test_case "write_file surfaces missing IDE observation sink" `Quick
            test_write_file_surfaces_missing_ide_observation_sink;
          Alcotest.test_case "write_file sanitizes IDE observation sink failure" `Quick
            test_write_file_sanitizes_ide_observation_sink_failure;
        ] );
    ]
