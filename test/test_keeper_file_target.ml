(** The file a Keeper filesystem tool call named, fixed at execution and kept
    on its tool-call row as [file_target].

    The TUI opens [file_target.path] in the Keeper's [Ws_keeper] workspace
    scope, whose base is [Keeper_sandbox.host_root_abs_of_meta]. The first
    group pins that the confined relative path names the same file under that
    base for every sandbox profile. The rest drive a real Edit and Read through
    the production handler and post-tool hook and read the durable row back. *)

module Workspace = Masc.Workspace
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_registry = Masc.Keeper_registry
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_alerting_path = Masc.Keeper_alerting_path
module Keeper_tool_read_window = Masc.Keeper_tool_read_window
module Keeper_tool_shared_runtime = Masc.Keeper_tool_shared_runtime
module Keeper_tool_descriptor = Masc.Keeper_tool_descriptor
module Keeper_file_change_evidence = Masc.Keeper_file_change_evidence
module Keeper_file_target = Masc.Keeper_file_target
module Keeper_tool_call_log = Masc.Keeper_tool_call_log
module Json = Yojson.Safe.Util

let () = Masc.Prompt_defaults.init ()

let temp_dir () =
  let d = Filename.temp_file "keeper_file_target_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d
;;

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
      Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with
  | _ -> ()
;;

let rec ensure_dir path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    let p = Filename.dirname path in
    if p <> path then ensure_dir p;
    Unix.mkdir path 0o755)
;;

let make_meta ~sandbox name =
  let json = `Assoc [ "name", `String name; "always_allow", `Bool true ] in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> { m with Keeper_meta_contract.sandbox_profile = sandbox; sandbox_image = Some "base" }
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

let setup ?(sandbox = Keeper_types_profile_sandbox.Docker) f =
  with_eio_fs
  @@ fun ~fs ~sw () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  Fun.protect ~finally:(fun () -> cleanup_dir base)
  @@ fun () ->
  Keeper_registry.For_testing.clear ();
  let config = Workspace.default_config base in
  Masc_test_deps.write_sandbox_image_catalog
    ~base_path:base
    [ "base", Masc_test_deps.live_sandbox_image_tag ];
  let meta = make_meta ~sandbox "target-keeper" in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  ignore (Keeper_registry.For_testing.register ~base_path:base meta.name meta);
  Masc_test_deps.with_publication_recovery_registry
    ~sw
    ~fs
    ~registry_root:(Workspace.masc_dir config)
  @@ fun registry ->
  let publication_recovery =
    { Masc.Keeper_publication_recovery_availability.provider =
        Masc_test_deps.publication_recovery_provider registry
    ; keeper_name = meta.name
    }
  in
  f ~config ~meta ~playground ~publication_recovery
;;

let confine ~config ~meta raw_path =
  match
    Keeper_tool_shared_runtime.resolve_keeper_confined_write_path
      ~config
      ~meta
      ~endpoint:Keeper_alerting_path.Follow_referent
      ~raw_path
  with
  | Ok confined -> confined
  | Error (refusal : Keeper_alerting_path.path_refusal) ->
    Alcotest.failf "confine %s: %s" raw_path refusal.message
;;

let profile_label = function
  | Keeper_types_profile_sandbox.Docker -> "docker"
  | Micro_vm -> "micro_vm"
  | Remote_ssh -> "remote_ssh"
;;

(* ── Root equivalence ─────────────────────────────────────────────── *)

let check_relative_path_names_file_under_workspace_base sandbox =
  setup ~sandbox
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  let label = profile_label sandbox in
  let file = Filename.concat playground "sub/dir/a.txt" in
  ensure_dir (Filename.dirname file);
  Fs_compat.save_file file "one\n";
  let workspace_base = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let spellings =
    [ "relative", "sub/dir/a.txt"; "host absolute", file ]
    @ (match sandbox with
       | Keeper_types_profile_sandbox.Docker ->
         [ ( "container absolute"
           , Filename.concat (Keeper_sandbox.container_root meta.name) "sub/dir/a.txt" )
         ]
       | Micro_vm | Remote_ssh -> [])
  in
  List.iter
    (fun (spelling, raw_path) ->
       let confined = confine ~config ~meta raw_path in
       let target = Keeper_file_target.changed confined None in
       Alcotest.(check string)
         (Printf.sprintf "%s %s: relative path" label spelling)
         "sub/dir/a.txt"
         target.Keeper_file_target.relative_path;
       Alcotest.(check string)
         (Printf.sprintf "%s %s: same file under the workspace base" label spelling)
         (Unix.realpath file)
         (Unix.realpath (Filename.concat workspace_base target.Keeper_file_target.relative_path)))
    spellings
;;

let test_root_equivalence_docker () =
  check_relative_path_names_file_under_workspace_base Keeper_types_profile_sandbox.Docker
;;

let test_root_equivalence_micro_vm () =
  check_relative_path_names_file_under_workspace_base Keeper_types_profile_sandbox.Micro_vm
;;

let test_root_equivalence_remote_ssh () =
  check_relative_path_names_file_under_workspace_base Keeper_types_profile_sandbox.Remote_ssh
;;

(* ── Line ranges ──────────────────────────────────────────────────── *)

let lines_of (target : Keeper_file_target.t) =
  Option.map
    (fun (range : Keeper_file_change_evidence.line_range) ->
       range.Keeper_file_change_evidence.start_line, range.Keeper_file_change_evidence.end_line)
    target.Keeper_file_target.lines
;;

let range = Alcotest.(option (pair int int))

let test_line_ranges_follow_the_producer_evidence () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery:_ ->
  Fs_compat.save_file (Filename.concat playground "f.txt") "x\n";
  let confined = confine ~config ~meta "f.txt" in
  let changed evidence = lines_of (Keeper_file_target.changed confined evidence) in
  Alcotest.check range "overwrite" (Some (1, 3))
    (changed (Some (Keeper_file_change_evidence.written "a\nb\nc\n")));
  Alcotest.check range "empty overwrite" None
    (changed (Some (Keeper_file_change_evidence.written "")));
  let occurrence ~start ~old_string ~new_string =
    Keeper_file_change_evidence.edit_occurrence
      ~old_start_line:start ~new_start_line:start ~old_string ~new_string
  in
  Alcotest.check range "edit takes its first occurrence" (Some (4, 5))
    (changed
       (Some
          (Keeper_file_change_evidence.edited
             [ occurrence ~start:4 ~old_string:"a" ~new_string:"b\nc"
             ; occurrence ~start:9 ~old_string:"a" ~new_string:"b"
             ])));
  Alcotest.check range "first occurrence deleted its lines" None
    (changed
       (Some
          (Keeper_file_change_evidence.edited
             [ occurrence ~start:4 ~old_string:"a\n" ~new_string:""
             ; occurrence ~start:9 ~old_string:"a" ~new_string:"b"
             ])));
  Alcotest.check range "omitted ranges" None
    (changed
       (Some
          (Keeper_file_change_evidence.edited_ranges_omitted
             ~occurrence_count:
               (Keeper_file_change_evidence.max_recorded_edit_occurrences + 1))));
  Alcotest.check range "append" None (changed None);
  let window offset =
    match Keeper_tool_read_window.of_args (`Assoc [ "offset", `Int offset ]) with
    | Ok w -> w
    | Error _ -> Alcotest.fail "read window"
  in
  Alcotest.check range "read window" (Some (12, 40))
    (lines_of (Keeper_file_target.read confined ~window:(window 12) ~returned_lines:29));
  Alcotest.check range "read returned nothing" None
    (lines_of (Keeper_file_target.read confined ~window:(window 12) ~returned_lines:0));
  Alcotest.(check bool) "a window cannot start below one" true
    (Result.is_error (Keeper_tool_read_window.of_args (`Assoc [ "offset", `Int 0 ])))
;;

(* ── Durable row through the production handler and hook ──────────── *)

let invocation tool_use_id =
  Agent_core.Tool_contract.Invocation.create
    ~tool_use_id
    ~turn:1
    ~completion:Agent_core.Tool_contract.Continue_after_success
    ~schedule:
      { planned_index = 0
      ; batch_index = 0
      ; batch_size = 1
      ; execution_mode = Agent_core.Tool_contract.Serial
      }
;;

let post_tool_use ~config ~meta ~invocation ~tool_name ~input result =
  let output =
    match result with
    | Tool_result.Completed _ ->
      Ok
        { Agent_core.Types.content = Tool_result.message result
        ; content_blocks = None
        ; _meta = None
        }
    | Tool_result.Deferred _ -> Alcotest.fail "tool unexpectedly deferred"
    | Tool_result.Failed { message; _ } -> Alcotest.failf "tool failed: %s" message
  in
  let hooks =
    Masc.Keeper_hooks_agent_core.make_hooks
      ~config
      ~meta_ref:(ref meta)
      ~turn_ctx_cell:(Keeper_tool_call_log.create_turn_ctx_cell ())
      ~trace_id:"file-target-trace"
      ~keeper_turn_id:1
      ()
  in
  let hook =
    match hooks.Agent_core.Hooks.post_tool_use with
    | Some hook -> hook
    | None -> Alcotest.fail "production Keeper hooks omitted post_tool_use"
  in
  match
    hook
      (Agent_core.Hooks.PostToolUse
         { invocation
         ; tool_name
         ; input
         ; output
         ; result_bytes = String.length (Tool_result.message result)
         ; duration_ms = 1.0
         })
  with
  | Agent_core.Hooks.Continue -> ()
  | _ -> Alcotest.fail "production post-tool hook did not continue"
;;

let only_row ~(meta : Keeper_meta_contract.keeper_meta) =
  match Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:1 () with
  | Ok [ row ] -> row
  | Ok rows -> Alcotest.failf "expected one row, got %d" (List.length rows)
  | Error (Keeper_tool_call_log.Index_unavailable detail) ->
    Alcotest.failf "tool-call read index unavailable: %s" detail
;;

let run_descriptor ~config ~meta ~publication_recovery ~id ~tool_use_id input =
  let descriptor =
    match Keeper_tool_descriptor.find_id id with
    | Some descriptor -> descriptor
    | None -> Alcotest.failf "%s descriptor is absent" id
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
      ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"test")
      ~keeper_turn_id:(fun () -> None)
      ()
  in
  let invocation = invocation tool_use_id in
  let result = handler ~agent_core_invocation:invocation input in
  post_tool_use ~config ~meta ~invocation ~tool_name:descriptor.public_name ~input result;
  only_row ~meta
;;

let with_tool_call_log ~config f =
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_execution_join.For_testing.clear ();
      Keeper_tool_call_log.reset_for_testing ())
    (fun () ->
       Keeper_tool_call_log.reset_for_testing ();
       Keeper_tool_call_log.init ~base_path:config.Workspace.base_path ();
       f ())
;;

let file_target_json ~path ~lines =
  `Assoc
    ([ "path", `String path ]
     @ (match lines with
        | Some (start_line, end_line) ->
          [ "lines", `Assoc [ "start_line", `Int start_line; "end_line", `Int end_line ] ]
        | None -> []))
  |> Yojson.Safe.to_string
;;

let test_edit_row_keeps_its_file_target () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery ->
  with_tool_call_log ~config
  @@ fun () ->
  let path = Filename.concat playground "sub/edit.ml" in
  ensure_dir (Filename.dirname path);
  Fs_compat.save_file path "before\nold a\nold b\nafter\n";
  let row =
    run_descriptor ~config ~meta ~publication_recovery ~id:"agent.edit_file"
      ~tool_use_id:"file-target-edit"
      (`Assoc
          [ "file_path", `String "sub/edit.ml"
          ; "old_string", `String "old a\nold b"
          ; "new_string", `String "new a\nnew b\nnew c"
          ])
  in
  Alcotest.(check string)
    "the edit row names the file and the lines it now holds"
    (file_target_json ~path:"sub/edit.ml" ~lines:(Some (2, 4)))
    (Json.member "file_target" row |> Yojson.Safe.to_string)
;;

let test_read_row_keeps_its_file_target () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery ->
  with_tool_call_log ~config
  @@ fun () ->
  let path = Filename.concat playground "sub/read.txt" in
  ensure_dir (Filename.dirname path);
  Fs_compat.save_file path "l1\nl2\nl3\nl4\nl5\n";
  let row =
    run_descriptor ~config ~meta ~publication_recovery ~id:"agent.read_file"
      ~tool_use_id:"file-target-read"
      (`Assoc [ "file_path", `String "sub/read.txt"; "offset", `Int 2; "limit", `Int 3 ])
  in
  Alcotest.(check string)
    "the read row names the file and the lines it returned"
    (file_target_json ~path:"sub/read.txt" ~lines:(Some (2, 4)))
    (Json.member "file_target" row |> Yojson.Safe.to_string)
;;

(* A row the producer gave no target has none, even when its tool name and
   input look like a file read. Nothing at the hook infers one. *)
let test_call_without_producer_target_has_no_field () =
  setup
  @@ fun ~config ~meta ~playground:_ ~publication_recovery:_ ->
  with_tool_call_log ~config
  @@ fun () ->
  let input = `Assoc [ "file_path", `String "sub/read.txt"; "path", `String "sub/read.txt" ] in
  post_tool_use
    ~config
    ~meta
    ~invocation:(invocation "file-target-none")
    ~tool_name:"Read"
    ~input
    (Tool_result.make_ok ~tool_name:"Read" ~start_time:(Tool_timing.start ())
       ~data:(`Assoc [ "ok", `Bool true ]) ());
  match only_row ~meta with
  | `Assoc fields ->
    Alcotest.(check bool) "no file_target field" false (List.mem_assoc "file_target" fields)
  | _ -> Alcotest.fail "row is not an object"
;;

let () =
  Alcotest.run
    "Keeper_file_target"
    [ ( "root"
      , [ Alcotest.test_case "docker path names the file under the workspace base" `Quick
            test_root_equivalence_docker
        ; Alcotest.test_case "micro_vm path names the file under the workspace base" `Quick
            test_root_equivalence_micro_vm
        ; Alcotest.test_case "remote_ssh path names the file under the workspace base" `Quick
            test_root_equivalence_remote_ssh
        ] )
    ; ( "lines"
      , [ Alcotest.test_case "line ranges follow the producer evidence" `Quick
            test_line_ranges_follow_the_producer_evidence
        ] )
    ; ( "row"
      , [ Alcotest.test_case "edit row keeps its file target" `Quick
            test_edit_row_keeps_its_file_target
        ; Alcotest.test_case "read row keeps its file target" `Quick
            test_read_row_keeps_its_file_target
        ; Alcotest.test_case "call without a producer target has no field" `Quick
            test_call_without_producer_target_has_no_field
        ] )
    ]
;;
