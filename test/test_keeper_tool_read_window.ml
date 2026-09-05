(* Read tool line-window contract (agent.read_file / tool_read_file).

   Locks the fix for the live parrot loop of 2026-07-21: the Read descriptor
   translated [limit] into [max_bytes], so a model asking for 200 LINES
   received max(512, 200) = 512 BYTES with truncated=true, could never read
   past the file head, and re-issued the byte-identical Read for 200+ calls
   inside one turn. The contract now treats [offset]/[limit] as line
   coordinates, keeps [max_bytes] as the byte budget, and reports
   [next_offset] so a follow-up call can make forward progress. *)

module Workspace = Masc.Workspace
module Json = Yojson.Safe.Util
module Keeper_registry = Masc.Keeper_registry
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_tool_filesystem_runtime = Masc.Keeper_tool_filesystem_runtime
module Keeper_tool_descriptor = Masc.Keeper_tool_descriptor

(* [Keeper_tool_filesystem_runtime.handle_read_file] (the bare
   string-returning wrapper) was retired: it had zero production callers
   ([keeper_tool_runtime.ml] calls [handle_read_file_with_outcome]
   directly). This test-local shim reproduces its [.raw_output] projection
   so the assertions below keep exercising the real production entry
   point. *)
let handle_read_file ~turn_sandbox_factory ~config ~meta ~args =
  (Keeper_tool_filesystem_runtime.handle_read_file_with_outcome
     ~turn_sandbox_factory
     ~config
     ~meta
     ~args)
    .raw_output
;;

let temp_dir () =
  let d = Filename.temp_file "keeper-read-window-" "" in
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

let make_meta name =
  let json =
    `Assoc
      (* [sandbox_profile] left JSON meta in 5e151702c4 (TOML=config SSOT,
         JSON=runtime-only) and 28ef484a39 started rejecting fields outside
         the declared schema, so passing it killed this suite in the decoder.
         [agent_name] is omitted for the same reason the other fixtures omit
         it: Masc_test_deps derives the canonical [keeper-<name>-agent]. *)
      [ "name", `String name
      ; "trace_id", `String ("trace-" ^ name)
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
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
    ~cwd_default:Eio.Path.(fs / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect
    ~finally:Process_eio.reset_for_testing
    (fun () -> f ~fs ~sw ())
;;

let allow_repo ~config ~(meta : Masc.Keeper_meta_contract.keeper_meta) repo_id =
  let repo_path =
    Filename.concat
      (Keeper_sandbox.host_root_abs_of_meta ~config meta)
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

let setup f =
  with_eio_fs
  @@ fun ~fs ~sw () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       Keeper_registry.For_testing.clear ();
       let config = Workspace.default_config base in
       let meta = make_meta "reader" in
       let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       ensure_dir playground;
       ignore (Keeper_registry.For_testing.register ~base_path:base meta.name meta);
       allow_repo ~config ~meta "masc";
       Masc_test_deps.with_publication_recovery_registry
         ~sw
         ~fs
         ~registry_root:(Workspace.masc_root_dir config)
       @@ fun _registry -> f ~config ~meta ~playground)
;;

let parse raw = Yojson.Safe.from_string raw

let parse_ok raw =
  parse raw |> Json.member "ok" |> Json.to_bool_option |> Option.value ~default:false
;;

let parse_string key raw = parse raw |> Json.member key |> Json.to_string_option
let parse_int key raw = parse raw |> Json.member key |> Json.to_int_option

let parse_bool key raw =
  parse raw |> Json.member key |> Json.to_bool_option |> Option.value ~default:false
;;

let numbered_lines n =
  let buffer = Buffer.create (n * 9) in
  for i = 1 to n do
    Buffer.add_string buffer (Printf.sprintf "line-%03d\n" i)
  done;
  Buffer.contents buffer
;;

let read ~config ~meta args =
  handle_read_file
    ~turn_sandbox_factory:None
    ~config
    ~meta
    ~args
;;

(* The live regression, end to end through the descriptor wire contract: a
   model sends Read {file_path, limit:200} meaning 200 lines. Before the fix
   the translation produced max_bytes=200 -> clamp 512 bytes. *)
let test_wire_limit_means_lines () =
  setup
  @@ fun ~config ~meta ~playground ->
  write_file (Filename.concat playground "repos/masc/sample.ml") (numbered_lines 300);
  let translated =
    Keeper_tool_descriptor.translate_input
      ~public:"Read"
      (`Assoc
          [ "file_path", `String "repos/masc/sample.ml"; "limit", `Int 200 ])
  in
  let raw = read ~config ~meta translated in
  if not (parse_ok raw) then Alcotest.failf "expected Read ok, got: %s" raw;
  Alcotest.(check (option int)) "returned_lines" (Some 200) (parse_int "returned_lines" raw);
  Alcotest.(check (option int)) "next_offset" (Some 201) (parse_int "next_offset" raw);
  Alcotest.(check bool) "truncated" true (parse_bool "truncated" raw);
  let content = parse_string "content" raw |> Option.value ~default:"" in
  Alcotest.(check int) "content bytes exceed the old 512-byte clamp" 1800 (String.length content);
  Alcotest.(check bool)
    "starts at line 1"
    true
    (String.length content >= 9 && String.sub content 0 9 = "line-001\n")
;;

let test_offset_window_mid_file () =
  setup
  @@ fun ~config ~meta ~playground ->
  write_file (Filename.concat playground "repos/masc/sample.ml") (numbered_lines 300);
  let raw =
    read
      ~config
      ~meta
      (`Assoc
          [ "path", `String "repos/masc/sample.ml"
          ; "offset", `Int 100
          ; "limit", `Int 5
          ])
  in
  if not (parse_ok raw) then Alcotest.failf "expected Read ok, got: %s" raw;
  Alcotest.(check (option string))
    "window content"
    (Some "line-100\nline-101\nline-102\nline-103\nline-104\n")
    (parse_string "content" raw);
  Alcotest.(check (option int)) "next_offset" (Some 105) (parse_int "next_offset" raw)
;;

let test_tail_window_reaches_eof () =
  setup
  @@ fun ~config ~meta ~playground ->
  write_file (Filename.concat playground "repos/masc/sample.ml") (numbered_lines 300);
  let raw =
    read
      ~config
      ~meta
      (`Assoc [ "path", `String "repos/masc/sample.ml"; "offset", `Int 201 ])
  in
  if not (parse_ok raw) then Alcotest.failf "expected Read ok, got: %s" raw;
  Alcotest.(check (option int)) "returned_lines" (Some 100) (parse_int "returned_lines" raw);
  Alcotest.(check bool) "not truncated at EOF" false (parse_bool "truncated" raw);
  Alcotest.(check (option int)) "no next_offset at EOF" None (parse_int "next_offset" raw)
;;

let test_byte_budget_cuts_at_line_boundary () =
  setup
  @@ fun ~config ~meta ~playground ->
  write_file (Filename.concat playground "repos/masc/sample.ml") (numbered_lines 300);
  let raw =
    read
      ~config
      ~meta
      (`Assoc [ "path", `String "repos/masc/sample.ml"; "max_bytes", `Int 512 ])
  in
  if not (parse_ok raw) then Alcotest.failf "expected Read ok, got: %s" raw;
  let content = parse_string "content" raw |> Option.value ~default:"" in
  (* 9-byte lines: 56 lines = 504 bytes fit inside 512. *)
  Alcotest.(check int) "content is whole lines within budget" 504 (String.length content);
  Alcotest.(check bool)
    "ends on a line boundary"
    true
    (content <> "" && content.[String.length content - 1] = '\n');
  Alcotest.(check (option int)) "returned_lines" (Some 56) (parse_int "returned_lines" raw);
  Alcotest.(check (option int)) "next_offset" (Some 57) (parse_int "next_offset" raw);
  Alcotest.(check bool) "truncated" true (parse_bool "truncated" raw);
  Alcotest.(check bool) "no partial line" false (parse_bool "last_line_partial" raw)
;;

let test_single_long_line_stays_partial_but_advances () =
  setup
  @@ fun ~config ~meta ~playground ->
  write_file
    (Filename.concat playground "repos/masc/wide.txt")
    (String.make 2000 'x' ^ "\nline-2\n");
  let raw =
    read
      ~config
      ~meta
      (`Assoc [ "path", `String "repos/masc/wide.txt"; "max_bytes", `Int 512 ])
  in
  if not (parse_ok raw) then Alcotest.failf "expected Read ok, got: %s" raw;
  Alcotest.(check (option int)) "bytes capped" (Some 512) (parse_int "bytes" raw);
  Alcotest.(check bool) "partial line flagged" true (parse_bool "last_line_partial" raw);
  Alcotest.(check (option int))
    "next_offset advances past the partial line"
    (Some 2)
    (parse_int "next_offset" raw)
;;

(* The verification snapshot and the judge's live read cap bytes with two
   independent literals. They agree today only because #29407 moved the
   snapshot cap from 20_000 to 200_000 while the tool ceiling already sat
   there; before that a judge could ask for ten times what the operator would
   later see in the snapshot (#27397). Nothing derives one from the other, and
   a dependency edge from lib/workspace to the tool limits does not exist, so
   pin the relation where both are visible: whatever a live read returns has
   to fit in what the snapshot records. *)
(* The behavioural case above passes whether the two caps are one value or
   two literals that happen to agree. #27397 is about the second shape: the
   doc claimed a shared reader made them inseparable while they were in fact
   independent. They now come from one place, and this says so. *)
let test_read_ceiling_and_snapshot_cap_are_one_value () =
  Alcotest.(check int)
    "the snapshot cap is the Read ceiling"
    Tool_shard_limits.read_file_max_max_bytes
    Workspace_verification_store.verification_evidence_max_bytes;
  Alcotest.(check bool)
    "and the default sits under it"
    true
    (Tool_shard_limits.read_file_default_max_bytes
     <= Tool_shard_limits.read_file_max_max_bytes)
;;

let test_live_read_cannot_outrun_the_evidence_snapshot () =
  setup
  @@ fun ~config ~meta ~playground ->
  let snapshot_cap = Workspace_verification_store.verification_evidence_max_bytes in
  (* 9 bytes a line, so this file is comfortably larger than the cap. *)
  write_file
    (Filename.concat playground "repos/masc/large.ml")
    (numbered_lines ((snapshot_cap / 9) + 5_000));
  let raw =
    read
      ~config
      ~meta
      (`Assoc
         [ "path", `String "repos/masc/large.ml"
         ; "max_bytes", `Int (snapshot_cap * 10)
         ])
  in
  if not (parse_ok raw) then Alcotest.failf "expected Read ok, got: %s" raw;
  let bytes = parse_int "bytes" raw |> Option.value ~default:max_int in
  Alcotest.(check bool)
    (Printf.sprintf
       "a live read of %d bytes has to fit the %d-byte snapshot cap"
       bytes
       snapshot_cap)
    true
    (bytes <= snapshot_cap);
  Alcotest.(check bool) "and the file really was larger" true (parse_bool "truncated" raw)
;;

let test_zero_limit_is_rejected () =
  setup
  @@ fun ~config ~meta ~playground ->
  write_file (Filename.concat playground "repos/masc/sample.ml") (numbered_lines 10);
  let raw =
    read
      ~config
      ~meta
      (`Assoc [ "path", `String "repos/masc/sample.ml"; "limit", `Int 0 ])
  in
  if parse_ok raw then Alcotest.failf "expected Read failure, got ok: %s" raw;
  let message = parse_string "error" raw |> Option.value ~default:"" in
  Alcotest.(check bool)
    "error names the limit contract"
    true
    (Astring.String.is_infix ~affix:"limit" message)
;;

let test_offset_past_eof_returns_empty () =
  setup
  @@ fun ~config ~meta ~playground ->
  write_file (Filename.concat playground "repos/masc/sample.ml") (numbered_lines 10);
  let raw =
    read
      ~config
      ~meta
      (`Assoc [ "path", `String "repos/masc/sample.ml"; "offset", `Int 1000 ])
  in
  if not (parse_ok raw) then Alcotest.failf "expected Read ok, got: %s" raw;
  Alcotest.(check (option string)) "empty content" (Some "") (parse_string "content" raw);
  Alcotest.(check (option int)) "returned_lines" (Some 0) (parse_int "returned_lines" raw);
  Alcotest.(check bool) "not truncated" false (parse_bool "truncated" raw);
  Alcotest.(check (option int)) "no next_offset" None (parse_int "next_offset" raw)
;;

let test_legacy_max_bytes_args_unchanged () =
  setup
  @@ fun ~config ~meta ~playground ->
  write_file (Filename.concat playground "repos/masc/sample.ml") (numbered_lines 10);
  let raw =
    read
      ~config
      ~meta
      (`Assoc [ "path", `String "repos/masc/sample.ml"; "max_bytes", `Int 4096 ])
  in
  if not (parse_ok raw) then Alcotest.failf "expected Read ok, got: %s" raw;
  Alcotest.(check (option string))
    "whole file"
    (Some (numbered_lines 10))
    (parse_string "content" raw);
  Alcotest.(check bool) "not truncated" false (parse_bool "truncated" raw);
  Alcotest.(check (option int)) "returned_lines" (Some 10) (parse_int "returned_lines" raw)
;;

let () =
  Alcotest.run
    "keeper_tool_read_window"
    [ ( "read-line-window"
      , [ Alcotest.test_case "wire limit means lines" `Quick test_wire_limit_means_lines
        ; Alcotest.test_case "offset window mid file" `Quick test_offset_window_mid_file
        ; Alcotest.test_case "tail window reaches EOF" `Quick test_tail_window_reaches_eof
        ; Alcotest.test_case
            "byte budget cuts at line boundary"
            `Quick
            test_byte_budget_cuts_at_line_boundary
        ; Alcotest.test_case
            "single long line stays partial but advances"
            `Quick
            test_single_long_line_stays_partial_but_advances
        ; Alcotest.test_case
            "a live read cannot outrun the evidence snapshot"
            `Quick
            test_live_read_cannot_outrun_the_evidence_snapshot
        ; Alcotest.test_case
            "read ceiling and snapshot cap are one value"
            `Quick
            test_read_ceiling_and_snapshot_cap_are_one_value
        ; Alcotest.test_case "zero limit is rejected" `Quick test_zero_limit_is_rejected
        ; Alcotest.test_case
            "offset past EOF returns empty"
            `Quick
            test_offset_past_eof_returns_empty
        ; Alcotest.test_case
            "legacy max_bytes args unchanged"
            `Quick
            test_legacy_max_bytes_args_unchanged
        ] )
    ]
;;
