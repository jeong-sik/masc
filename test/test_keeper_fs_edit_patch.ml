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
        ("goal", `String "patch test");
        ("allowed_paths", `List [ `String "*" ]);
        ( "sandbox_profile",
          `String (Keeper_types_profile_sandbox.sandbox_profile_to_string sandbox) );
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> Alcotest.fail e

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()

let setup ?(sandbox = Keeper_types_profile_sandbox.Local) f =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.clear ();
  let config = Workspace.default_config base in
  let meta = make_meta ~sandbox "tester" in
  let playground =
    Filename.concat base
      (Keeper_alerting_path.playground_path_of_keeper meta.name)
  in
  ensure_dir playground;
  ignore (Keeper_registry.register ~base_path:base meta.name meta);
  f ~config ~meta ~playground

let parse raw = Yojson.Safe.from_string raw

let parse_ok raw =
  parse raw |> Json.member "ok" |> Json.to_bool_option
  |> Option.value ~default:false

let parse_error raw =
  parse raw |> Json.member "error" |> Json.to_string_option

let parse_int raw field =
  parse raw |> Json.member field |> Json.to_int_option

let parse_write_region_observation_error raw =
  parse raw
  |> Json.member "ide_observation"
  |> Json.member "write_region"
  |> Json.member "error"
  |> Json.to_string_option

let public_fs_edit_call ~public ~config ~(meta : Keeper_meta_contract.keeper_meta) args =
  let args = Keeper_tool_alias.translate_input ~public args in
  Keeper_tool_filesystem_runtime.handle_file_write
    ~turn_sandbox_factory:None
    ~config
    ~keeper_name:meta.name
    ~args

let seed_single_playground_repo ~config ~(meta : Keeper_meta_contract.keeper_meta) playground =
  let repo = Filename.concat playground "repos/masc" in
  ensure_dir (Filename.concat repo ".git");
  let mapping : Repo_manager_types.keeper_repo_mapping =
    (Repo_manager_types.make_keeper_repo_mapping ~keeper_id:meta.name
       ~repository_ids:[ "masc" ])
  in
  (match Keeper_repo_mapping.save_mapping ~base_path:config.Workspace.base_path mapping with
   | Ok () -> ()
   | Error msg -> Alcotest.failf "seed keeper repo mapping: %s" msg);
  repo

(* ── Tests ───────────────────────────────────────────────────────── *)

let test_patch_unique_match () =
  setup @@ fun ~config ~meta ~playground ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\nlet y = 2\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write ~turn_sandbox_factory:None ~config ~keeper_name:meta.name
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "let x = 1");
            ("new_string", `String "let x = 42");
          ])
  in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check (option int)) "occurrences=1" (Some 1)
    (parse_int raw "occurrences");
  let after = Fs_compat.load_file path in
  Alcotest.(check string) "file content updated"
    "let x = 42\nlet y = 2\n" after

let test_patch_no_match_errors () =
  setup @@ fun ~config ~meta ~playground ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write ~turn_sandbox_factory:None ~config ~keeper_name:meta.name
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "let z = 99");
            ("new_string", `String "let z = 100");
          ])
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
  setup @@ fun ~config ~meta ~playground ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "x = 1\nx = 1\nx = 1\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write ~turn_sandbox_factory:None ~config ~keeper_name:meta.name
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "x = 1");
            ("new_string", `String "x = 2");
          ])
  in
  Alcotest.(check bool) "ok=false" false (parse_ok raw);
  let after = Fs_compat.load_file path in
  Alcotest.(check string) "file unchanged on rejection"
    "x = 1\nx = 1\nx = 1\n" after

let test_patch_replace_all () =
  setup @@ fun ~config ~meta ~playground ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "x = 1\nx = 1\nx = 1\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write ~turn_sandbox_factory:None ~config ~keeper_name:meta.name
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "x = 1");
            ("new_string", `String "x = 2");
            ("replace_all", `Bool true);
          ])
  in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check (option int)) "occurrences=3" (Some 3)
    (parse_int raw "occurrences");
  Alcotest.(check string) "all replaced"
    "x = 2\nx = 2\nx = 2\n" (Fs_compat.load_file path)

let test_patch_empty_old_string_errors () =
  setup @@ fun ~config ~meta ~playground ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write ~turn_sandbox_factory:None ~config ~keeper_name:meta.name
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "");
            ("new_string", `String "anything");
          ])
  in
  Alcotest.(check bool) "ok=false" false (parse_ok raw);
  Alcotest.(check bool) "error message present" true
    (Option.is_some (parse_error raw))

let test_patch_missing_file_errors () =
  setup @@ fun ~config ~meta ~playground ->
  let path = Filename.concat playground "ghost.ml" in
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write ~turn_sandbox_factory:None ~config ~keeper_name:meta.name
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "x");
            ("new_string", `String "y");
          ])
  in
  Alcotest.(check bool) "ok=false" false (parse_ok raw)

let test_patch_delete_via_empty_new_string () =
  setup @@ fun ~config ~meta ~playground ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "keep me\nDELETE_ME\nkeep me too\n";
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write ~turn_sandbox_factory:None ~config ~keeper_name:meta.name
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "patch");
            ("old_string", `String "DELETE_ME\n");
            ("new_string", `String "");
          ])
  in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check string) "deletion landed"
    "keep me\nkeep me too\n" (Fs_compat.load_file path)

let test_overwrite_unchanged_by_patch_addition () =
  (* Regression: introducing Patch must not break existing overwrite. *)
  setup @@ fun ~config ~meta ~playground ->
  let path = Filename.concat playground "new.txt" in
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write ~turn_sandbox_factory:None ~config ~keeper_name:meta.name
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String "overwrite");
            ("content", `String "fresh");
          ])
  in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check string) "overwrite wrote bytes"
    "fresh" (Fs_compat.load_file path)

let check_invalid_mode_is_rejected ~label ~mode ~expected_error =
  setup @@ fun ~config ~meta ~playground ->
  let path = Filename.concat playground (label ^ ".txt") in
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write ~turn_sandbox_factory:None ~config
      ~keeper_name:meta.name
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", `String mode);
            ("content", `String "fresh");
          ])
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

let test_public_edit_file_maps_top_relative_single_repo_path () =
  setup @@ fun ~config ~meta ~playground ->
  let repo = seed_single_playground_repo ~config ~meta playground in
  let path = Filename.concat repo "lib/src.ml" in
  ensure_dir (Filename.dirname path);
  Fs_compat.save_file path "let x = 1\n";
  let raw =
    public_fs_edit_call
      ~public:"Edit"
      ~config
      ~meta
      (`Assoc
        [
          ("file_path", `String "lib/src.ml");
          ("old_string", `String "let x = 1");
          ("new_string", `String "let x = 2");
        ])
  in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check string) "file edited through single repo rewrite"
    "let x = 2\n" (Fs_compat.load_file path)

let test_public_write_file_maps_top_relative_single_repo_path () =
  setup @@ fun ~config ~meta ~playground ->
  let repo = seed_single_playground_repo ~config ~meta playground in
  let path = Filename.concat repo "lib/generated.ml" in
  let raw =
    public_fs_edit_call
      ~public:"Write"
      ~config
      ~meta
      (`Assoc
        [
          ("file_path", `String "lib/generated.ml");
          ("content", `String "let generated = true\n");
        ])
  in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check string) "file written through single repo rewrite"
    "let generated = true\n" (Fs_compat.load_file path)

let test_write_file_surfaces_missing_ide_observation_sink () =
  setup @@ fun ~config ~meta ~playground ->
  Agent_observation.reset_for_testing ();
  let path = Filename.concat playground "observed.ml" in
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~keeper_name:meta.name
      ~args:
        (`Assoc
          [ "path", `String path
          ; "mode", `String "overwrite"
          ; "content", `String "let observed = true\n"
          ])
  in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check string) "file written despite observation failure"
    "let observed = true\n" (Fs_compat.load_file path);
  Alcotest.(check (option string))
    "write-region observation failure is surfaced"
    (Some "write_region sink is not installed")
    (parse_write_region_observation_error raw)

let test_write_file_sanitizes_ide_observation_sink_failure () =
  setup @@ fun ~config ~meta ~playground ->
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
           ~keeper_name:meta.name
           ~args:
             (`Assoc
               [ "path", `String path
               ; "mode", `String "overwrite"
               ; "content", `String "let observed = true\n"
               ])
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
          Alcotest.test_case "empty mode rejected" `Quick
            test_empty_mode_is_rejected;
          Alcotest.test_case "spaces-only mode rejected" `Quick
            test_spaces_only_mode_is_rejected;
          Alcotest.test_case "tab-only mode rejected" `Quick
            test_tab_only_mode_is_rejected;
          Alcotest.test_case "public Edit maps top-relative single repo path" `Quick
            test_public_edit_file_maps_top_relative_single_repo_path;
          Alcotest.test_case "public Write maps top-relative single repo path" `Quick
            test_public_write_file_maps_top_relative_single_repo_path;
          Alcotest.test_case "write_file surfaces missing IDE observation sink" `Quick
            test_write_file_surfaces_missing_ide_observation_sink;
          Alcotest.test_case "write_file sanitizes IDE observation sink failure" `Quick
            test_write_file_sanitizes_ide_observation_sink_failure;
        ] );
    ]
