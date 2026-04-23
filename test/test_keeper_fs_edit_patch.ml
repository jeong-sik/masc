(** Tests for [Keeper_exec_fs.handle_keeper_fs_edit] mode=patch.

    RFC-0006 Phase A.4 — string-replace edit mode added so the
    Anthropic Code [Edit] cognate can be wired through OAS dual
    registration. *)

module Coord = Masc_mcp.Coord
module Keeper_exec_fs = Masc_mcp.Keeper_exec_fs
module Keeper_registry = Masc_mcp.Keeper_registry
module Keeper_types = Masc_mcp.Keeper_types
module Keeper_alerting_path = Masc_mcp.Keeper_alerting_path
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util

(* ── Helpers ─────────────────────────────────────────────────────── *)

let temp_dir () =
  let d = Filename.temp_file "keeper_fs_edit_patch_" "" in
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

let make_meta ?(sandbox = Keeper_types.Local) name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "patch test");
        ("allowed_paths", `List [ `String "*" ]);
        ( "sandbox_profile",
          `String (Keeper_types.sandbox_profile_to_string sandbox) );
      ]
  in
  match Keeper_types.meta_of_json json with
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

let setup ?(sandbox = Keeper_types.Local) f =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.clear ();
  let config = Coord.default_config base in
  let meta = make_meta ~sandbox "tester" in
  let playground =
    Filename.concat base
      (Keeper_alerting_path.playground_path_of_keeper meta.name)
  in
  ensure_dir playground;
  f ~config ~meta ~playground

let parse raw = Yojson.Safe.from_string raw

let parse_ok raw =
  parse raw |> Json.member "ok" |> Json.to_bool_option
  |> Option.value ~default:false

let parse_error raw =
  parse raw |> Json.member "error" |> Json.to_string_option

let parse_int raw field =
  parse raw |> Json.member field |> Json.to_int_option

(* ── Tests ───────────────────────────────────────────────────────── *)

let test_patch_unique_match () =
  setup @@ fun ~config ~meta ~playground ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\nlet y = 2\n";
  let raw =
    Keeper_exec_fs.handle_keeper_fs_edit ~turn_sandbox_runtime:None ~config ~meta
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
    Keeper_exec_fs.handle_keeper_fs_edit ~turn_sandbox_runtime:None ~config ~meta
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
    Keeper_exec_fs.handle_keeper_fs_edit ~turn_sandbox_runtime:None ~config ~meta
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
    Keeper_exec_fs.handle_keeper_fs_edit ~turn_sandbox_runtime:None ~config ~meta
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
    Keeper_exec_fs.handle_keeper_fs_edit ~turn_sandbox_runtime:None ~config ~meta
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
    Keeper_exec_fs.handle_keeper_fs_edit ~turn_sandbox_runtime:None ~config ~meta
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
    Keeper_exec_fs.handle_keeper_fs_edit ~turn_sandbox_runtime:None ~config ~meta
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
    Keeper_exec_fs.handle_keeper_fs_edit ~turn_sandbox_runtime:None ~config ~meta
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
        ] );
    ]
