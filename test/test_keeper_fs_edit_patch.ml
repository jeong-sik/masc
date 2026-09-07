(** Tests for [handle_file_write] mode=patch.

    RFC-0006 Phase A.4 — string-replace edit mode added so the
    Provider_a Code [Edit] cognate can be wired through AGENT_CORE dual
    registration. *)

module Workspace = Masc.Workspace
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_tool_filesystem_runtime = Masc.Keeper_tool_filesystem_runtime
module Keeper_file_change_evidence = Masc.Keeper_file_change_evidence
module Keeper_tool_execution = Masc.Keeper_tool_execution
module Keeper_registry = Masc.Keeper_registry
module Keeper_tool_descriptor = Masc.Keeper_tool_descriptor
module Keeper_types = Keeper_types
module Keeper_alerting_path = Masc.Keeper_alerting_path
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util

(* The mode=patch guidance this suite asserts moved out of the .ml sources
   into config/prompts/keeper.tool_filesystem.md, rendered through the
   prompt registry at result-construction time. *)
let () =
  Masc.Prompt_defaults.init ()
;;

(* The bare string-returning wrapper handle_file_write (formerly exported
   from [Keeper_tool_filesystem_runtime]) was retired: it had zero
   production callers
   ([keeper_tool_runtime.ml] calls [handle_file_write_with_outcome]
   directly). This test-local shim reproduces its [.raw_output] projection
   so the assertions below keep exercising the real production entry
   point. *)
let handle_file_write_with_outcome
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
  Keeper_tool_filesystem_runtime.handle_file_write_with_outcome
    ~turn_sandbox_factory
    ~config
    ~meta
    ~publication_recovery
    ?continuation_channel
    ?gate_context
    ?gate_grant
    ~args
    ()
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
  (handle_file_write_with_outcome
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

let make_meta ?(sandbox = Keeper_types_profile_sandbox.Docker) name =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("always_allow", `Bool true);
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m ->
    { m with Masc.Keeper_meta_contract.sandbox_profile = sandbox }
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

let setup ?(sandbox = Keeper_types_profile_sandbox.Docker) f =
  with_eio_fs @@ fun ~fs ~sw () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.For_testing.clear ();
  let config = Workspace.default_config base in
  let meta = make_meta ~sandbox "tester" in
  let playground = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
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
  f ~config ~meta ~playground ~publication_recovery

let parse raw = Yojson.Safe.from_string raw

let parse_ok raw =
  parse raw |> Json.member "ok" |> Json.to_bool_option
  |> Option.value ~default:false

let parse_error raw =
  parse raw |> Json.member "error" |> Json.to_string_option

let parse_int raw field =
  parse raw |> Json.member field |> Json.to_int_option

let check_line_range label ~start_line ~end_line
      (range : Keeper_file_change_evidence.line_range) =
  Alcotest.(check int) (label ^ " start") start_line range.start_line;
  Alcotest.(check int) (label ^ " end") end_line range.end_line

let file_change_evidence (execution : Keeper_tool_execution.t) =
  match execution.file_change_evidence with
  | Some evidence -> evidence
  | None -> Alcotest.fail "expected producer-owned file change evidence"

let parse_string raw field =
  parse raw |> Json.member field |> Json.to_string_option

let permissions path = (Unix.lstat path).Unix.st_perm

let public_fs_edit_call
      ~public
      ~config
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~publication_recovery
      args
  =
  let args = Keeper_tool_descriptor.translate_input ~public args in
  handle_file_write
    ~turn_sandbox_factory:None
    ~config
    ~meta
    ~publication_recovery
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
  repo

let with_turn_sandbox_factory ~enabled ~config ~meta f =
  if not enabled
  then f None
  else
    let factory =
      Masc.Keeper_sandbox_factory.create ~config ~meta ()
    in
    Fun.protect
      ~finally:(fun () -> Masc.Keeper_sandbox_factory.cleanup factory)
      (fun () -> f (Some factory))

(* ── Tests ───────────────────────────────────────────────────────── *)

let test_patch_unique_match () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\nlet y = 2\n";
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
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

let test_patch_multiline_line_evidence () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "multiline.ml" in
  Fs_compat.save_file path "before\nold a\nold b\nafter\n";
  let execution =
    handle_file_write_with_outcome
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
      ~args:
        (`Assoc
          [ "path", `String path
          ; "mode", `String "patch"
          ; "old_string", `String "old a\nold b"
          ; "new_string", `String "new a\nnew b\nnew c"
          ])
      ()
  in
  match file_change_evidence execution with
  | Keeper_file_change_evidence.Edited
      { occurrence_count = 1
      ; occurrences = Some [ { old_range; new_range = Some new_range } ]
      } ->
    check_line_range "old" ~start_line:2 ~end_line:3 old_range;
    check_line_range "new" ~start_line:2 ~end_line:4 new_range
  | _ -> Alcotest.fail "expected one multiline Edit occurrence"

let test_file_change_evidence_crosses_handler_and_hook_on_exact_invocation () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_execution_join.For_testing.clear ();
      Masc.Keeper_tool_call_log.reset_for_testing ())
    (fun () ->
       Masc.Keeper_tool_call_log.reset_for_testing ();
       Masc.Keeper_tool_call_log.init ~base_path:config.Workspace.base_path ();
       let path = Filename.concat playground "handler-hook.ml" in
       Fs_compat.save_file path "before\nold a\nold b\nafter\n";
       let descriptor =
         match Keeper_tool_descriptor.find_id "agent.edit_file" with
         | Some descriptor -> descriptor
         | None -> Alcotest.fail "agent.edit_file descriptor is absent"
       in
       let invocation =
         Agent_core.Tool_contract.Invocation.create
           ~tool_use_id:"file-change-exact-invocation"
           ~turn:1
           ~completion:Agent_core.Tool_contract.Continue_after_success
           ~schedule:
             { planned_index = 0
             ; batch_index = 0
             ; batch_size = 1
             ; execution_mode = Agent_core.Tool_contract.Serial
             }
       in
       let input =
         `Assoc
           [ "file_path", `String "handler-hook.ml"
           ; "old_string", `String "old a\nold b"
           ; "new_string", `String "new a\nnew b\nnew c"
           ]
       in
       let handler =
         Masc.Keeper_tools_agent_core_handler.make_keeper_tool_handler_from_meta
           ~name:descriptor.internal_name
           ~descriptor
           ~model_name:descriptor.public_name
           ~input_schema:descriptor.input_schema
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:
             (Masc.Keeper_context_runtime.create
                ~eio:false
                ~system_prompt:"test")
           ()
       in
       let result = handler ~agent_core_invocation:invocation input in
       let output =
         match result with
         | Tool_result.Completed _ ->
           Ok
             { Agent_core.Types.content = Tool_result.message result
             ; _meta = None
             }
         | Tool_result.Deferred _ -> Alcotest.fail "Edit unexpectedly deferred"
         | Tool_result.Failed { message; _ } ->
           Alcotest.failf "Edit failed: %s" message
       in
       let turn_ctx_cell = Masc.Keeper_tool_call_log.create_turn_ctx_cell () in
       let hooks =
         Masc.Keeper_hooks_agent_core.make_hooks
           ~config
           ~meta_ref:(ref meta)
           ~turn_ctx_cell
           ~trace_id:"file-change-exact-trace"
           ~keeper_turn_id:1
           ~on_after_turn_ordinal:ignore
           ()
       in
       let post_tool_use =
         match hooks.Agent_core.Hooks.post_tool_use with
         | Some hook -> hook
         | None -> Alcotest.fail "production Keeper hooks omitted post_tool_use"
       in
       (match
          post_tool_use
            (Agent_core.Hooks.PostToolUse
               { invocation
               ; tool_name = descriptor.public_name
               ; input
               ; output
               ; result_bytes = String.length (Tool_result.message result)
               ; duration_ms = 1.0
               })
        with
        | Agent_core.Hooks.Continue -> ()
        | _ -> Alcotest.fail "production post-tool hook did not continue");
       match
         Masc.Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:1 ()
       with
       | [ row ] ->
         let expected =
           Keeper_file_change_evidence.edited
             [ Keeper_file_change_evidence.edit_occurrence
                 ~old_start_line:2
                 ~new_start_line:2
                 ~old_string:"old a\nold b"
                 ~new_string:"new a\nnew b\nnew c"
             ]
           |> Keeper_file_change_evidence.to_yojson
           |> Yojson.Safe.to_string
         in
         let actual =
           Json.member "file_change_evidence" row |> Yojson.Safe.to_string
         in
         Alcotest.(check string)
           "producer evidence reaches the exact durable row"
           expected
           actual;
         Alcotest.(check bool)
           "same row has a canonical execution id"
           true
           (Option.is_some (Safe_ops.json_string_opt "execution_id" row));
         Alcotest.(check int)
           "commit acknowledgement consumes exact-invocation evidence"
           0
           (Masc.Keeper_tool_call_log.pending_file_change_evidence_count_for_testing
              ())
       | rows ->
         Alcotest.failf "expected one exact file-change row, got %d" (List.length rows))

let test_patch_no_match_errors () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\n";
  let execution =
    handle_file_write_with_outcome
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
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
  let raw = execution.raw_output in
  Alcotest.(check bool) "ok=false" false (parse_ok raw);
  Alcotest.(check bool)
    "failed patch does not claim completed change evidence"
    true
    (Option.is_none execution.file_change_evidence);
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
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "x = 1\nx = 1\nx = 1\n";
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
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
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "x = 1\nx = 1\nx = 1\n";
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
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

let test_patch_replace_all_line_evidence_tracks_new_file_shifts () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "shifted.txt" in
  Fs_compat.save_file path "before\nx\nmiddle\nx\nafter\n";
  let execution =
    handle_file_write_with_outcome
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
      ~args:
        (`Assoc
          [ "path", `String path
          ; "mode", `String "patch"
          ; "old_string", `String "x"
          ; "new_string", `String "x\nextra"
          ; "replace_all", `Bool true
          ])
      ()
  in
  match file_change_evidence execution with
  | Keeper_file_change_evidence.Edited
      { occurrence_count = 2
      ; occurrences =
          Some
            [ { old_range = old_first; new_range = Some new_first }
            ; { old_range = old_second; new_range = Some new_second }
            ]
      } ->
    check_line_range "first old" ~start_line:2 ~end_line:2 old_first;
    check_line_range "first new" ~start_line:2 ~end_line:3 new_first;
    check_line_range "second old" ~start_line:4 ~end_line:4 old_second;
    check_line_range "second new" ~start_line:5 ~end_line:6 new_second
  | _ -> Alcotest.fail "expected two ordered Edit occurrences"

let test_patch_large_replace_all_omits_ranges_but_keeps_exact_count () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "bounded.txt" in
  let occurrence_count =
    Keeper_file_change_evidence.max_recorded_edit_occurrences + 1
  in
  Fs_compat.save_file path (String.make occurrence_count 'x');
  let execution =
    handle_file_write_with_outcome
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
      ~args:
        (`Assoc
          [ "path", `String path
          ; "mode", `String "patch"
          ; "old_string", `String "x"
          ; "new_string", `String "y"
          ; "replace_all", `Bool true
          ])
      ()
  in
  match file_change_evidence execution with
  | Keeper_file_change_evidence.Edited
      { occurrence_count = actual; occurrences = None } ->
    Alcotest.(check int) "exact occurrence count survives" occurrence_count actual;
    let json =
      Keeper_file_change_evidence.to_yojson
        (file_change_evidence execution)
    in
    Alcotest.(check bool)
      "durable range list is explicitly null"
      true
      (Json.member "occurrences" json = `Null)
  | _ -> Alcotest.fail "expected explicitly omitted oversized range evidence"

let test_patch_empty_old_string_errors () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\n";
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
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
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "ghost.ml" in
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
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
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "keep me\nDELETE_ME\nkeep me too\n";
  let execution =
    handle_file_write_with_outcome
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
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
  let raw = execution.raw_output in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check string) "deletion landed"
    "keep me\nkeep me too\n" (Fs_compat.load_file path);
  match file_change_evidence execution with
  | Keeper_file_change_evidence.Edited
      { occurrence_count = 1
      ; occurrences = Some [ { old_range; new_range = None } ]
      } ->
    check_line_range "deleted old" ~start_line:2 ~end_line:2 old_range
  | _ -> Alcotest.fail "expected deletion evidence with an explicit absent new range"

let test_overwrite_unchanged_by_patch_addition () =
  (* Regression: introducing Patch must not break existing overwrite. *)
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "new.txt" in
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
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

let test_overwrite_and_append_line_evidence () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "write.txt" in
  let overwrite =
    handle_file_write_with_outcome
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
      ~args:
        (`Assoc
          [ "path", `String path
          ; "mode", `String "overwrite"
          ; "content", `String "one\ntwo\n"
          ])
      ()
  in
  (match file_change_evidence overwrite with
   | Keeper_file_change_evidence.Written { new_range = Some range } ->
     check_line_range "overwrite" ~start_line:1 ~end_line:2 range
   | _ -> Alcotest.fail "expected full-body Write evidence");
  let append =
    handle_file_write_with_outcome
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
      ~args:
        (`Assoc
          [ "path", `String path
          ; "mode", `String "append"
          ; "content", `String "three\n"
          ])
      ()
  in
  Alcotest.(check bool)
    "append does not claim a whole-file range"
    true
    (Option.is_none append.file_change_evidence)

let test_empty_overwrite_has_typed_absent_range () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "empty.txt" in
  let execution =
    handle_file_write_with_outcome
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
      ~args:
        (`Assoc
          [ "path", `String path
          ; "mode", `String "overwrite"
          ; "content", `String ""
          ])
      ()
  in
  match file_change_evidence execution with
  | Keeper_file_change_evidence.Written { new_range = None } -> ()
  | _ -> Alcotest.fail "expected Write evidence with an explicit absent range"

let test_atomic_writes_preserve_existing_executable_permissions () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let run ~label ~initial ~args ~expected =
    let path = Filename.concat playground (label ^ ".sh") in
    Fs_compat.save_file path initial;
    Unix.chmod path 0o751;
    let raw =
      handle_file_write
        ~turn_sandbox_factory:None
        ~config
        ~meta
        ~publication_recovery
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
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
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
         handle_file_write
           ~turn_sandbox_factory:None
           ~config
           ~meta
           ~publication_recovery
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
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let referent = Filename.concat playground "patch-referent.txt" in
  let leaf = Filename.concat playground "patch-link.txt" in
  Fs_compat.save_file referent "value=before\n";
  Unix.chmod referent 0o751;
  Unix.symlink referent leaf;
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
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
  @@ fun ~config ~meta ~playground ~publication_recovery ->
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
      handle_file_write
        ~turn_sandbox_factory
        ~config
        ~meta
        ~publication_recovery
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
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let referent_dir = Filename.concat playground "append-referent" in
  let lexical_dir = Filename.concat playground "append-link" in
  ensure_dir referent_dir;
  ensure_dir lexical_dir;
  let referent = Filename.concat referent_dir "target.txt" in
  let lexical = Filename.concat lexical_dir "target.txt" in
  Fs_compat.save_file referent "before\n";
  Unix.symlink referent lexical;
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
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
  @@ fun ~config ~meta ~playground ~publication_recovery ->
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
      handle_file_write
        ~turn_sandbox_factory
        ~config
        ~meta
        ~publication_recovery
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
  @@ fun ~config ~meta ~playground ~publication_recovery ->
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
    handle_file_write
      ~turn_sandbox_factory
      ~config
      ~meta
      ~publication_recovery
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
  @@ fun ~config ~meta ~playground ~publication_recovery ->
  with_turn_sandbox_factory ~enabled:true ~config ~meta
  @@ fun turn_sandbox_factory ->
  let outside = Filename.concat config.Workspace.base_path "leaf-swap-outside" in
  ensure_dir outside;
  let run_existing_case
        ~expected_success
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
      handle_file_write
        ~turn_sandbox_factory
        ~config
        ~meta
        ~publication_recovery
        ~gate_context
        ~args:(`Assoc (("path", `String target) :: args))
        ()
    in
    Alcotest.(check bool) (label ^ " success contract") expected_success (parse_ok raw);
    if expected_success
    then
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
    ~expected_success:true
    ~label:"overwrite"
    ~initial:"inside-overwrite"
    ~args:[ "mode", `String "overwrite"; "content", `String "replacement" ]
    ~expected_moved:"inside-overwrite"
    ~expected_leaf:"replacement"
    ~expected_leaf_kind:`Regular;
  run_existing_case
    ~expected_success:true
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
    ~expected_success:false
    ~label:"append"
    ~initial:"inside-append\n"
    ~args:[ "mode", `String "append"; "content", `String "pinned-append\n" ]
    ~expected_moved:"inside-append\n"
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
    handle_file_write
      ~turn_sandbox_factory
      ~config
      ~meta
      ~publication_recovery
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

let check_invalid_mode_json_is_rejected ~label ~mode_json ~expected_error =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground (label ^ ".txt") in
  let raw =
    handle_file_write ~turn_sandbox_factory:None ~config
      ~meta
      ~publication_recovery
      ~args:
        (`Assoc
          [
            ("path", `String path);
            ("mode", mode_json);
            ("content", `String "fresh");
          ])
      ()
  in
  Alcotest.(check bool) "ok=false" false (parse_ok raw);
  Alcotest.(check (option string)) (label ^ " rejected")
    (Some expected_error)
    (parse_error raw);
  Alcotest.(check bool) "file not written" false (Fs_compat.file_exists path)

let check_invalid_mode_is_rejected ~label ~mode ~expected_error =
  check_invalid_mode_json_is_rejected ~label ~mode_json:(`String mode)
    ~expected_error

(* A mode that is not a string used to miss the rejection above entirely:
   [Safe_ops.json_string] returned its "overwrite" default for every non-string
   member, so {"mode": ["append"]} wrote in Overwrite while the misspelled
   {"mode": "apend"} was refused. These pin the type-wrong value onto the same
   path as the value-wrong one. *)
let expected_mode_error value =
  Printf.sprintf "mode must be one of [overwrite, append, patch], got %S."
    (Yojson.Safe.to_string value)

let test_list_mode_is_rejected () =
  let value = `List [ `String "append" ] in
  check_invalid_mode_json_is_rejected ~label:"list-mode" ~mode_json:value
    ~expected_error:(expected_mode_error value)

let test_int_mode_is_rejected () =
  let value = `Int 42 in
  check_invalid_mode_json_is_rejected ~label:"int-mode" ~mode_json:value
    ~expected_error:(expected_mode_error value)

(* The other half of the contract (masc#31573): absence used to take a silent
   Overwrite default — the destructive mode — while every explicit-but-wrong
   mode was rejected. Translators and Gate replay always inject a mode, so
   only a translation-bypassing internal-name call ever omitted one; it now
   follows the same rejection path. A present null is not absence; the schema
   permits only a string when [mode] is present, so it follows the rejection
   path above. *)
let test_absent_mode_is_rejected () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "absent-mode.txt" in
  let raw =
    handle_file_write ~turn_sandbox_factory:None ~config
      ~meta
      ~publication_recovery
      ~args:(`Assoc [ ("path", `String path); ("content", `String "fresh") ])
      ()
  in
  Alcotest.(check bool) "ok=false" false (parse_ok raw);
  Alcotest.(check (option string)) "absent mode rejected"
    (Some "mode must be one of [overwrite, append, patch], got \"(absent)\".")
    (parse_error raw);
  Alcotest.(check bool) "file not written" false (Fs_compat.file_exists path)

let test_null_mode_is_rejected () =
  check_invalid_mode_json_is_rejected ~label:"null-mode" ~mode_json:`Null
    ~expected_error:(expected_mode_error `Null)

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
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let repo = seed_single_playground_repo ~config ~meta playground in
  let path = Filename.concat repo "lib/src.ml" in
  ensure_dir (Filename.dirname path);
  Fs_compat.save_file path "let x = 1\n";
  let raw =
    public_fs_edit_call
      ~public:"Edit"
      ~config
      ~meta
      ~publication_recovery
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

(* masc#31573: an undeclared 'content' key used to flip a public Edit call into
   mode=overwrite through translator inference, replacing the whole file with
   content. Edit translation now pins mode=patch, so the same call fails on the
   patch contract and the file keeps its bytes. *)
let test_public_edit_with_content_key_never_overwrites () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let repo = seed_single_playground_repo ~config ~meta playground in
  let path = Filename.concat repo "lib/src.ml" in
  ensure_dir (Filename.dirname path);
  Fs_compat.save_file path "let x = 1\n";
  let raw =
    public_fs_edit_call
      ~public:"Edit"
      ~config
      ~meta
      ~publication_recovery
      (`Assoc
        [
          ("file_path", `String "repos/masc/lib/src.ml");
          ("content", `String "let clobbered = true\n");
        ])
  in
  Alcotest.(check bool) "ok=false" false (parse_ok raw);
  Alcotest.(check (option string)) "patch contract error"
    (Some "mode=patch requires non-empty old_string. Good: old_string='let x = 1'.")
    (parse_error raw);
  Alcotest.(check string) "file bytes unchanged"
    "let x = 1\n" (Fs_compat.load_file path)

let test_edit_translation_pins_patch_even_with_content () =
  let translated =
    Keeper_tool_descriptor.translate_input
      ~public:"Edit"
      (`Assoc
        [ ("file_path", `String "lib/src.ml"); ("content", `String "body") ])
  in
  match translated with
  | `Assoc fields ->
    Alcotest.(check (option string)) "mode pinned to patch"
      (Some "patch")
      (match List.assoc_opt "mode" fields with
       | Some (`String s) -> Some s
       | _ -> None);
    Alcotest.(check bool) "content dropped by the closed translation" false
      (List.mem_assoc "content" fields)
  | _ -> Alcotest.fail "expected translated args to stay an object"

let test_public_write_file_uses_explicit_repo_path () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let repo = seed_single_playground_repo ~config ~meta playground in
  let path = Filename.concat repo "lib/generated.ml" in
  let raw =
    public_fs_edit_call
      ~public:"Write"
      ~config
      ~meta
      ~publication_recovery
      (`Assoc
        [
          ("file_path", `String "repos/masc/lib/generated.ml");
          ("content", `String "let generated = true\n");
        ])
  in
  if not (parse_ok raw) then Alcotest.failf "public Write failed: %s" raw;
  Alcotest.(check string) "file written through explicit repo path"
    "let generated = true\n" (Fs_compat.load_file path)


(* ── Insert above a line ─────────────────────────────────────────── *)

let insert_args ~path ~line ~text =
  `Assoc
    [ ("path", `String path)
    ; ("mode", `String "patch")
    ; ("insert_before_line", `Int line)
    ; ("insert_text", `String text)
    ]

let test_insert_takes_the_lines_indentation () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\n  let y = 2\nlet z = 3\n";
  let execution =
    handle_file_write_with_outcome
      ~turn_sandbox_factory:None ~config ~meta ~publication_recovery
      ~args:(insert_args ~path ~line:2 ~text:"(* masc(alpha): why two *)")
      ()
  in
  let raw = execution.Keeper_tool_execution.raw_output in
  Alcotest.(check bool) "ok" true (parse_ok raw);
  Alcotest.(check (option int)) "the line it went above" (Some 2)
    (parse_int raw "insert_before_line");
  Alcotest.(check (option int)) "one occurrence" (Some 1) (parse_int raw "occurrences");
  Alcotest.(check string) "the line sits above, indented like its neighbour"
    "let x = 1\n  (* masc(alpha): why two *)\n  let y = 2\nlet z = 3\n"
    (Fs_compat.load_file path);
  match file_change_evidence execution with
  | Keeper_file_change_evidence.Edited { occurrence_count; occurrences = Some [ occurrence ] } ->
    Alcotest.(check int) "evidence counts one" 1 occurrence_count;
    check_line_range "old range is the line it went above" ~start_line:2 ~end_line:2
      occurrence.Keeper_file_change_evidence.old_range;
    (match occurrence.Keeper_file_change_evidence.new_range with
     | Some range ->
       check_line_range "new range covers the memo and that line" ~start_line:2 ~end_line:3 range
     | None -> Alcotest.fail "an insert has a new range")
  | Keeper_file_change_evidence.Edited _ -> Alcotest.fail "expected exactly one recorded occurrence"
  | Keeper_file_change_evidence.Written _ -> Alcotest.fail "an insert is edit evidence, not write evidence"

let test_insert_beyond_the_last_line_is_refused () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\nlet y = 2\n";
  let raw =
    handle_file_write ~turn_sandbox_factory:None ~config ~meta ~publication_recovery
      ~args:(insert_args ~path ~line:3 ~text:"# memo") ()
  in
  Alcotest.(check bool) "refused" false (parse_ok raw);
  (match parse_error raw with
   | Some message ->
     Alcotest.(check bool) ("names the missing line: " ^ message) true
       (String_util.contains_substring message "line 3 does not exist")
   | None -> Alcotest.fail "no error text");
  Alcotest.(check string) "the file is untouched" "let x = 1\nlet y = 2\n"
    (Fs_compat.load_file path)

let test_patch_with_neither_replace_nor_insert_is_refused () =
  setup @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "src.ml" in
  Fs_compat.save_file path "let x = 1\n";
  let raw =
    handle_file_write ~turn_sandbox_factory:None ~config ~meta ~publication_recovery
      ~args:(`Assoc [ ("path", `String path); ("mode", `String "patch"); ("insert_text", `String "x") ])
      ()
  in
  Alcotest.(check bool) "refused" false (parse_ok raw);
  Alcotest.(check string) "untouched" "let x = 1\n" (Fs_compat.load_file path)

(* An approval recorded for an insert replays as the same insert: the
   fields the Gate input carries are the ones the handler reads. *)
let test_replay_carries_the_insert () =
  let input =
    `Assoc
      [ ("requested_target", `String "/tmp/memo/src.ml")
      ; ( "effect"
        , `Assoc
            [ ( "operation"
              , `String
                  (Keeper_alerting_path.path_effect_operation_to_string
                     Keeper_alerting_path.Patch_then_atomic_replace_entry) )
            ] )
      ; ("content", `String "updated bytes")
      ; ("insert_before_line", `Int 2)
      ; ("insert_text", `String "# masc(alpha): why")
      ]
  in
  match Keeper_tool_filesystem_runtime.replay_args_of_gate_input input with
  | Ok (`Assoc fields) ->
    Alcotest.(check (option string)) "mode" (Some "patch")
      (Option.bind (List.assoc_opt "mode" fields) Yojson.Safe.Util.to_string_option);
    Alcotest.(check (option int)) "line" (Some 2)
      (Option.bind (List.assoc_opt "insert_before_line" fields) Yojson.Safe.Util.to_int_option);
    Alcotest.(check (option string)) "text" (Some "# masc(alpha): why")
      (Option.bind (List.assoc_opt "insert_text" fields) Yojson.Safe.Util.to_string_option)
  | Ok other -> Alcotest.failf "replay args are not an object: %s" (Yojson.Safe.to_string other)
  | Error message -> Alcotest.fail message

let pure_insert ~line ~text content =
  Masc.Keeper_tool_patch.apply (Masc.Keeper_tool_patch.Insert_before_line { line; text }) content

let test_insert_step_edges () =
  (match pure_insert ~line:1 ~text:"# m" "" with
   | Error message -> Alcotest.(check bool) "an empty file has no line" true
                        (String_util.contains_substring message "empty")
   | Ok _ -> Alcotest.fail "an empty file took an insert");
  (match pure_insert ~line:2 ~text:"# m" "a\n\nb\n" with
   | Ok application -> Alcotest.(check string) "a blank line takes it" "a\n# m\n\nb\n" application.Masc.Keeper_tool_patch.updated
   | Error message -> Alcotest.fail message);
  (match pure_insert ~line:2 ~text:"# m" "a\nb" with
   | Ok application -> Alcotest.(check string) "the last line without a break" "a\n# m\nb" application.Masc.Keeper_tool_patch.updated
   | Error message -> Alcotest.fail message);
  (match pure_insert ~line:2 ~text:"one\ntwo" "a\nb\n" with
   | Error message -> Alcotest.(check bool) "two lines refused" true
                        (String_util.contains_substring message "one line")
   | Ok _ -> Alcotest.fail "a two-line text was inserted");
  (match pure_insert ~line:3 ~text:"# m" "a\nb\n" with
   | Error message -> Alcotest.(check string) "the count names the file's lines"
                        "the file has 2 lines; line 3 does not exist." message
   | Ok _ -> Alcotest.fail "a line past the end took an insert")

let () =
  Alcotest.run "Keeper_fs_edit_patch"
    [
      ( "patch-mode",
        [
          Alcotest.test_case "unique match replaces" `Quick
            test_patch_unique_match;
          Alcotest.test_case "multiline match records old and new ranges" `Quick
            test_patch_multiline_line_evidence;
          Alcotest.test_case "exact invocation carries evidence through handler and hook"
            `Quick
            test_file_change_evidence_crosses_handler_and_hook_on_exact_invocation;
          Alcotest.test_case "no match returns error" `Quick
            test_patch_no_match_errors;
          Alcotest.test_case "multi match without replace_all rejected"
            `Quick test_patch_multiple_matches_without_replace_all_errors;
          Alcotest.test_case "replace_all applies to every occurrence"
            `Quick test_patch_replace_all;
          Alcotest.test_case "replace_all ranges track output line shifts" `Quick
            test_patch_replace_all_line_evidence_tracks_new_file_shifts;
          Alcotest.test_case "large replace_all keeps count and omits ranges" `Quick
            test_patch_large_replace_all_omits_ranges_but_keeps_exact_count;
          Alcotest.test_case "empty old_string rejected" `Quick
            test_patch_empty_old_string_errors;
          Alcotest.test_case "missing file rejected" `Quick
            test_patch_missing_file_errors;
          Alcotest.test_case "empty new_string deletes substring" `Quick
            test_patch_delete_via_empty_new_string;
          Alcotest.test_case "overwrite mode regression" `Quick
            test_overwrite_unchanged_by_patch_addition;
          Alcotest.test_case "overwrite records ranges but append does not" `Quick
            test_overwrite_and_append_line_evidence;
          Alcotest.test_case "empty overwrite records an absent range" `Quick
            test_empty_overwrite_has_typed_absent_range;
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
          (* These three exercise the host capability write path without a
             runtime. They used Remote_ssh as the stand-in for the removed
             Local profile; a Remote_ssh keeper's writes now go over the
             remote lane, so the shared-mount profile without a runtime is
             the path they mean. *)
          Alcotest.test_case
            "shared-mount outside-referent endpoint semantics are operation-specific (no runtime)"
            `Quick
            (test_outside_referent_endpoint_semantics
               ~sandbox:Keeper_types_profile_sandbox.Docker
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
            "shared-mount symlink component swap cannot escape allowed root (no runtime)"
            `Quick
            (test_symlink_component_swap_cannot_escape_allowed_root
               ~sandbox:Keeper_types_profile_sandbox.Docker
               ~with_runtime:false);
          Alcotest.test_case
            "shared-mount sandbox root swap keeps pinned capability (no runtime)"
            `Quick
            (test_sandbox_root_swap_after_open_keeps_pinned_capability
               ~sandbox:Keeper_types_profile_sandbox.Docker
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
          Alcotest.test_case "list mode rejected" `Quick
            test_list_mode_is_rejected;
          Alcotest.test_case "int mode rejected" `Quick
            test_int_mode_is_rejected;
          Alcotest.test_case "absent mode rejected" `Quick
            test_absent_mode_is_rejected;
          Alcotest.test_case "null mode rejected" `Quick
            test_null_mode_is_rejected;
          Alcotest.test_case "public Edit uses explicit repo path" `Quick
            test_public_edit_file_uses_explicit_repo_path;
          Alcotest.test_case "public Edit content key never overwrites" `Quick
            test_public_edit_with_content_key_never_overwrites;
          Alcotest.test_case "Edit translation pins patch mode" `Quick
            test_edit_translation_pins_patch_even_with_content;
          Alcotest.test_case "public Write uses explicit repo path" `Quick
            test_public_write_file_uses_explicit_repo_path;
        ] );
      ( "insert_before_line",
        [
          Alcotest.test_case "the line goes above, indented like its neighbour" `Quick
            test_insert_takes_the_lines_indentation;
          Alcotest.test_case "a line past the end is refused" `Quick
            test_insert_beyond_the_last_line_is_refused;
          Alcotest.test_case "neither replace nor insert is refused" `Quick
            test_patch_with_neither_replace_nor_insert_is_refused;
          Alcotest.test_case "the pure step's edges" `Quick test_insert_step_edges;
          Alcotest.test_case "an approval replays as the same insert" `Quick
            test_replay_carries_the_insert;
        ] );
    ]
