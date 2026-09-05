(* Write and Edit over the remote lane (RFC-0400 C0).

   A stub stands in for the endpoint's CLI: it decodes the framed request,
   answers a patch-source read from a file beside itself, records a write
   frame, and reports the exit the mode says. The handler must send the
   right payload with the content on stdin, at the translated path, and
   must type its failures by the exit codes the scripts choose. *)

open Alcotest
open Masc

let write_all fd content =
  let bytes = Bytes.unsafe_of_string content in
  let rec loop offset =
    if offset < Bytes.length bytes
    then
      let wrote = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      loop (offset + wrote)
  in
  loop 0
;;

let read_exact fd length =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset < length
    then
      let got = Unix.read fd bytes offset (length - offset) in
      if got = 0 then failwith "remote write stub: truncated frame" else loop (offset + got)
  in
  loop 0;
  Bytes.unsafe_to_string bytes
;;

let save path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let read_script =
  match Keeper_tool_filesystem_remote_write.read_source_argv ~remote_path:"x" with
  | _ :: _ :: script :: _ -> script
  | _ -> failwith "read_source_argv has no script"
;;

let stub_main () =
  let frame_path = Sys.argv.(2) in
  let mode = Sys.argv.(3) in
  let header = read_exact Unix.stdin 8 in
  let body_len = Bytes.get_int64_be (Bytes.unsafe_of_string header) 0 |> Int64.to_int in
  let frame = header ^ read_exact Unix.stdin body_len in
  let trailer ?exit ?shim_error () =
    Exec_ssh_protocol.render_trailer
      { v = Exec_ssh_protocol.newest; exit; signal = None; timed_out = false; shim_error }
  in
  match Exec_ssh_protocol.decode_request frame with
  | Error error ->
    write_all Unix.stderr (trailer ~shim_error:error ());
    exit 1
  | Ok (request, _stdin) ->
    let is_source_read =
      match request.argv with
      | _ :: _ :: script :: _ -> String.equal script read_script
      | _ -> false
    in
    if is_source_read
    then (
      let source = frame_path ^ ".source" in
      if Sys.file_exists source
      then (
        write_all Unix.stdout (read_file source);
        write_all Unix.stderr (trailer ~exit:0 ());
        exit 0)
      else (
        write_all Unix.stderr
          (trailer ~exit:Keeper_tool_filesystem_remote_write.patch_source_missing_exit ());
        exit 0))
    else (
      save (frame_path ^ ".write") frame;
      match mode with
      | "ok" ->
        write_all Unix.stderr (trailer ~exit:0 ());
        exit 0
      | "fail" ->
        write_all Unix.stderr ("mv: cannot move: No space left on device\n" ^ trailer ~exit:1 ());
        exit 0
      | other -> failwith ("unknown remote write stub mode: " ^ other))
;;

let shell_quote s = "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let temp_dir () =
  let path = Filename.temp_file "masc-remote-write-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path
;;

let make_stub ~dir ~mode =
  let frame_path = Filename.concat dir ("frame-" ^ mode) in
  let script_path = Filename.concat dir ("cli-" ^ mode) in
  save script_path
    (Printf.sprintf "#!/bin/sh\nexec %s --remote-write-stub %s %s \"$@\"\n"
       (shell_quote Sys.executable_name)
       (shell_quote frame_path)
       (shell_quote mode));
  Unix.chmod script_path 0o755;
  script_path, frame_path
;;

let with_eio f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing f
;;

type fixture =
  { config : Workspace.config
  ; meta : Keeper_meta_contract.keeper_meta
  ; endpoint : Keeper_sandbox_remote.t
  ; frame_path : string
  }

let fixture ~mode =
  let base = temp_dir () in
  Fs_compat.mkdir_p (Filename.concat base ".masc/playground/keeper-a");
  let keepers_dir = Filename.concat base ".masc/config/keepers" in
  Fs_compat.mkdir_p keepers_dir;
  save (Filename.concat keepers_dir "keeper-a.toml")
    {|[keeper]
instructions = "remote write test keeper"
sandbox_profile = "remote_ssh"
remote_endpoint = "build-box"
|};
  let config = Workspace.default_config base in
  let meta =
    match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String "keeper-a" ]) with
    | Error error -> fail error
    | Ok meta ->
      { meta with
        Keeper_meta_contract.sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh
      }
  in
  let cli, frame_path = make_stub ~dir:base ~mode in
  let endpoint =
    Keeper_sandbox_remote.of_container_exec ~base_path:base ~keeper_name:"keeper-a"
      ~remote_root:"/masc-work" ~gh_config_dir:"/identity/gh" ~injected_env:[]
      ~env_allowlist:[]
      ~connect_timeout_sec:1 ~max_concurrent_sessions:2
      { prefix =
          [ cli; "exec"; "-i"; "--user"; "501:20"; "-w"; "/masc-work"
          ; "--env"
          ; "MASC_EXEC_SHIM_CONFIG=/opt/masc-exec-shim/masc-exec-shim.conf"
          ; "masc-keeper-vm-keeper-a"
          ]
      ; probe_prefix = None
      ; container_name = "masc-keeper-vm-keeper-a"
      ; shim_path = "/opt/masc-exec-shim/masc-exec-shim"
      }
  in
  { config; meta; endpoint; frame_path }
;;

let handle f args =
  Keeper_tool_filesystem_remote_write.handle_with_endpoint ~endpoint:f.endpoint
    ~config:f.config ~meta:f.meta ~args:(`Assoc args)
;;

let write_frame f =
  match Exec_ssh_protocol.decode_request (read_file (f.frame_path ^ ".write")) with
  | Ok decoded -> decoded
  | Error error -> fail error
;;

let completed (result : Keeper_tool_execution.t) =
  match result.disposition with
  | Tool_result.Completed () -> true
  | Tool_result.Deferred () | Tool_result.Failed _ -> false
;;

let failed_as class_ (result : Keeper_tool_execution.t) =
  match result.disposition with
  | Tool_result.Failed actual -> actual = class_
  | Tool_result.Completed () | Tool_result.Deferred () -> false
;;

let member key (result : Keeper_tool_execution.t) =
  Yojson.Safe.Util.member key (Yojson.Safe.from_string result.raw_output)
;;

let remote_target = "/masc-work/keeper-a/src/a.ml"

let test_overwrite_sends_content_on_stdin () =
  with_eio @@ fun () ->
  let f = fixture ~mode:"ok" in
  let result =
    handle f
      [ "path", `String "src/a.ml"; "mode", `String "overwrite"; "content", `String "hello\n" ]
  in
  check bool "completed" true (completed result);
  check bool "ok" true (member "ok" result = `Bool true);
  check bool "mode" true (member "mode" result = `String "overwrite");
  check bool "via names the profile" true (member "via" result = `String "remote_ssh");
  check bool "evidence records the write" true
    (Option.is_some result.file_change_evidence);
  let request, stdin = write_frame f in
  check (list string) "atomic replace payload at the translated path"
    (Keeper_tool_filesystem_remote_write.write_argv ~mode:Replace_whole ~remote_path:remote_target)
    request.argv;
  check string "content travels on stdin" "hello\n" stdin;
  check string "runs from the keeper root" "/masc-work/keeper-a" request.cwd
;;

let test_append_uses_the_append_payload () =
  with_eio @@ fun () ->
  let f = fixture ~mode:"ok" in
  let result =
    handle f [ "path", `String "src/a.ml"; "mode", `String "append"; "content", `String "tail\n" ]
  in
  check bool "completed" true (completed result);
  check bool "append records no whole-file evidence" true
    (Option.is_none result.file_change_evidence);
  let request, stdin = write_frame f in
  check (list string) "append payload"
    (Keeper_tool_filesystem_remote_write.write_argv ~mode:Append_tail ~remote_path:remote_target)
    request.argv;
  check string "content" "tail\n" stdin
;;

let test_patch_reads_then_replaces () =
  with_eio @@ fun () ->
  let f = fixture ~mode:"ok" in
  save (f.frame_path ^ ".source") "let x = 1\nlet y = 1\n";
  let result =
    handle f
      [ "path", `String "src/a.ml"; "mode", `String "patch"
      ; "old_string", `String "let x = 1"; "new_string", `String "let x = 2" ]
  in
  check bool "completed" true (completed result);
  check bool "mode" true (member "mode" result = `String "patch");
  check bool "edit evidence" true (Option.is_some result.file_change_evidence);
  let request, stdin = write_frame f in
  check (list string) "patched content is written back as a whole-file replace"
    (Keeper_tool_filesystem_remote_write.write_argv ~mode:Replace_whole ~remote_path:remote_target)
    request.argv;
  check string "patched body" "let x = 2\nlet y = 1\n" stdin
;;

let test_patch_without_a_source_is_a_workflow_rejection () =
  with_eio @@ fun () ->
  let f = fixture ~mode:"ok" in
  let result =
    handle f
      [ "path", `String "src/missing.ml"; "mode", `String "patch"
      ; "old_string", `String "a"; "new_string", `String "b" ]
  in
  check bool "workflow rejection" true (failed_as Tool_result.Workflow_rejection result);
  check bool "names the fix" true
    (Astring.String.is_infix ~affix:"mode=overwrite to create it" result.raw_output);
  check bool "nothing was written" false (Sys.file_exists (f.frame_path ^ ".write"))
;;

let test_endpoint_failure_is_a_runtime_failure () =
  with_eio @@ fun () ->
  let f = fixture ~mode:"fail" in
  let result =
    handle f [ "path", `String "src/a.ml"; "mode", `String "overwrite"; "content", `String "x" ]
  in
  check bool "runtime failure" true (failed_as Tool_result.Runtime_failure result);
  check bool "carries the endpoint's stderr" true
    (Astring.String.is_infix ~affix:"No space left" result.raw_output)
;;

let test_jail_and_mode_are_enforced_before_any_payload () =
  with_eio @@ fun () ->
  let f = fixture ~mode:"ok" in
  let escape =
    handle f [ "path", `String "../keeper-b/x"; "mode", `String "overwrite"; "content", `String "x" ]
  in
  check bool "escape is refused" false (completed escape);
  let no_mode = handle f [ "path", `String "src/a.ml"; "content", `String "x" ] in
  check bool "absent mode is a policy rejection" true
    (failed_as Tool_result.Policy_rejection no_mode);
  check bool "no payload was sent" false (Sys.file_exists (f.frame_path ^ ".write"))
;;

let () =
  if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--remote-write-stub"
  then stub_main ()
  else
    run "keeper_tool_filesystem_remote_write"
      [ ( "remote write"
        , [ test_case "overwrite sends content on stdin" `Quick
              test_overwrite_sends_content_on_stdin
          ; test_case "append uses the append payload" `Quick
              test_append_uses_the_append_payload
          ; test_case "patch reads then replaces" `Quick test_patch_reads_then_replaces
          ; test_case "patch without a source is a workflow rejection" `Quick
              test_patch_without_a_source_is_a_workflow_rejection
          ; test_case "endpoint failure is a runtime failure" `Quick
              test_endpoint_failure_is_a_runtime_failure
          ; test_case "jail and mode are enforced before any payload" `Quick
              test_jail_and_mode_are_enforced_before_any_payload
          ] )
      ]
