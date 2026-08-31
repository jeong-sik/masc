(** Production rejected-dispatch stream finalization.

    PR #28237 follow-up: the previous regression suite called
    [For_testing.close_rejected_execute_stream] directly, so it did not
    prove that [handle_tool_execute_typed] invokes the stream finalizer in
    the [Gate_reject], [Cannot_parse], [Too_complex], and [Path_reject]
    branches. This suite drives the real production dispatch wiring through
    a controlled [Execute_shell_ir] result (via the
    [For_testing.dispatch_override] seam) and asserts that
    [record_execute_stream_end] fires for every rejected branch. *)

open Alcotest
open Masc

module Keeper_tool_execute_runtime = Masc.Keeper_tool_execute_runtime
module Keeper_keepalive_signal = Masc.Keeper_keepalive_signal
module Keeper_identity = Masc.Keeper_identity
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_registry = Masc.Keeper_registry
module Keeper_types_profile_sandbox = Keeper_types_profile_sandbox
module Json = Yojson.Safe.Util

(* ── Helpers (mirror test_keeper_sandbox_docker_route.ml) ────────── *)

let temp_dir () =
  let dir = Filename.temp_file "keeper_tool_execute_stream_close_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let rec cleanup_dir path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter
      (fun name -> cleanup_dir (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing f

let make_meta ~name () =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("trace_id", `String ("trace-" ^ name))
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
    { meta with
      sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh
    ; always_allow = Some true
    }
  | Error e -> Alcotest.fail e

let setup f =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  let config_dir =
    Filename.concat (Filename.concat base Common.masc_dirname) "config"
  in
  ensure_dir config_dir;
  let config = Workspace.default_config base in
  ensure_dir (Workspace.keepers_runtime_dir config);
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.For_testing.clear ();
  let meta = make_meta ~name:"stream-close-keeper" () in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  ensure_dir playground;
  let repos_toml = Filename.concat config_dir "repositories.toml" in
  write_file repos_toml
    (Printf.sprintf
       "[repository.masc]\n\
        name = \"masc\"\n\
        url = \"%s\"\n\
        local_path = \"repos/masc\"\n\
        aliases = []\n\
        default_branch = \"main\"\n\
        status = \"Active\"\n\
        keepers = [\"stream-close-keeper\"]\n\
        auto_sync = false\n\
        sync_interval = 300\n\
        created_at = 0\n\
        updated_at = 0\n"
       playground);
  f ~config ~meta ~playground

let typed_exec_args ~cwd =
  `Assoc
    [ ("argv", `List [ `String "echo"; `String "hello" ])
    ; ("cwd", `String cwd)
    ; ("timeout_sec", `Float 5.0)
    ]

let parse_bool_field raw field =
  Yojson.Safe.from_string raw |> Json.member field |> Json.to_bool_option

(* ── The four rejected-dispatch branches ─────────────────────────── *)

let rejected_cases =
  [ ( "gate_reject"
    , `String "gate_reject"
    , (fun () ->
        Error
          (Keeper_tooling.Execute_shell_ir.Gate_reject
             "gate denied by policy")) )
  ; ( "cannot_parse"
    , `String "cannot_parse"
    , (fun () ->
        Error
          (Keeper_tooling.Execute_shell_ir.Cannot_parse
             Masc_exec_command_gate.Shell_command_gate.Parse_error)) )
  ; ( "too_complex"
    , `String "too_complex"
    , (fun () ->
        Error
          (Keeper_tooling.Execute_shell_ir.Too_complex
             Masc_exec_command_gate.Shell_command_gate.Unsupported_nested_pipeline)) )
  ; ( "path_reject"
    , `String "path_reject"
    , (fun () ->
        Error
          (Keeper_tooling.Execute_shell_ir.Path_reject
             "path outside allowed scope")) )
  ]

let test_rejected_branch_finalizes_stream (name, _expected_status, dispatch) () =
  setup @@ fun ~config ~meta ~playground ->
  let stream_end_status = ref None in
  Keeper_keepalive_signal.register_record_execute_stream_end
    (fun ~keeper_name:_ ~task_id:_ ~status -> stream_end_status := Some status);
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_execute_runtime.For_testing.dispatch_override := None;
      Keeper_keepalive_signal.register_record_execute_stream_end
        (fun ~keeper_name:_ ~task_id:_ ~status:_ -> ()))
    (fun () ->
      Keeper_tool_execute_runtime.For_testing.dispatch_override := Some dispatch;
      let raw =
        Keeper_tool_execute_runtime.handle_tool_execute
          ~turn_sandbox_factory:None
          ~config
          ~meta
          ~args:(typed_exec_args ~cwd:playground)
          ()
      in
      (match parse_bool_field raw "ok" with
       | Some true -> Alcotest.failf "%s: rejected response unexpectedly ok: %s" name raw
       | Some false | None -> ());
      match !stream_end_status with
      | None ->
        Alcotest.failf "%s: record_execute_stream_end was NOT invoked" name
      | Some status ->
        let rejected =
          match Yojson.Safe.Util.member "rejected" status with
          | `String s -> s
          | _ -> Alcotest.failf "%s: stream end status missing rejected" name
        in
        check string (name ^ ": stream end status rejected tag") name rejected)

let () =
  Alcotest.run
    "keeper-tool-execute-stream-close"
    [ ( "rejected-dispatch-finalization"
      , List.map
          (fun (name, _, dispatch) ->
            test_case
              (name ^ " finalizes the execute stream")
              `Quick
              (test_rejected_branch_finalizes_stream (name, `String name, dispatch)))
          rejected_cases )
    ]
;;
