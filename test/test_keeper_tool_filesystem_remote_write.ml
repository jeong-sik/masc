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
  (* An OpenSSH endpoint probes the shim before its first request. *)
  if Array.exists (String.equal "masc-exec-shim --probe") Sys.argv
  then (
    write_all Unix.stdout
      (Exec_ssh_protocol.render_probe
         { name = "masc-exec-shim"
         ; version = string_of_int Exec_ssh_protocol.protocol_version ^ ".0.0"
         ; capabilities = []
         ; release = None
         });
    exit 0);
  let header = read_exact Unix.stdin 8 in
  let body_len = Bytes.get_int64_be (Bytes.unsafe_of_string header) 0 |> Int64.to_int in
  let frame = header ^ read_exact Unix.stdin body_len in
  let trailer ?exit ?shim_error () =
    Exec_ssh_protocol.render_trailer
      { v = Exec_ssh_protocol.newest; exit; signal = None; timed_out = false; shim_error
      ; observed_syscalls = [] }
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
      | "escape" ->
        write_all Unix.stderr
          (trailer ~exit:Keeper_tool_filesystem_remote_write.declared_root_escape_exit ());
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
  Keeper_tool_filesystem_remote_write.handle_with_endpoint
    ~declared_root_writes:Keeper_tool_filesystem_remote_write.Refuse_declared_roots
    ~endpoint:f.endpoint ~config:f.config ~meta:f.meta ~args:(`Assoc args)
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

let test_remote_patch_arguments_recover_but_write_failure_stays_runtime () =
  with_eio @@ fun () ->
  List.iter (fun mode ->
    let f = fixture ~mode in
    save (f.frame_path ^ ".source") "let x = 1\n";
    let edit old_string = handle f
        [ "path", `String "src/a.ml"; "mode", `String "patch"
        ; "old_string", `String old_string; "new_string", `String "let x = 2" ] in
    check bool "stale patch is workflow rejection" true
      (failed_as Tool_result.Workflow_rejection (edit "stale"));
    check bool "rejection does not write" false (Sys.file_exists (f.frame_path ^ ".write"));
    let corrected = edit "let x = 1" in
    check bool "corrected input reaches the write boundary" true
      (Sys.file_exists (f.frame_path ^ ".write"));
    match mode with
    | "ok" -> check bool "corrected patch succeeds" true (completed corrected)
    | _ -> check bool "actual write failure remains runtime" true
        (failed_as Tool_result.Runtime_failure corrected)) ["ok"; "fail"]
;;

let test_identical_remote_patch_does_not_write () =
  with_eio @@ fun () ->
  let f = fixture ~mode:"ok" in
  save (f.frame_path ^ ".source") "let x = 1\n";
  let result = handle f
      [ "path", `String "src/a.ml"; "mode", `String "patch"
      ; "old_string", `String "let x = 1"; "new_string", `String "let x = 1" ] in
  check bool "completed without change" true (completed result);
  check bool "changed false" true (member "changed" result = `Bool false);
  check bool "zero bytes" true (member "bytes_written" result = `Int 0);
  check bool "no write dispatch" false (Sys.file_exists (f.frame_path ^ ".write"));
  check bool "no change evidence" true (Option.is_none result.file_change_evidence)
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

(* #38593: a path the keeper's tree refuses may be under the endpoint's
   declared roots ([allowed_paths]). *)
let endpoint_config ~host =
  Exec_ssh_endpoint.
    { name = "build-box"
    ; host
    ; user = "masc"
    ; port = default_port
    ; identity_file = default_identity_file ~name:"build-box"
    ; known_hosts_file = default_known_hosts_file ~name:"build-box"
    ; remote_root = "/srv/masc/playground"
    ; connect_timeout_sec = 1
    ; max_concurrent_sessions = 2
    ; env_allowlist = []
    ; capabilities = []
    ; private_home = false
    ; allowed_paths = [ "/app" ]
    }
;;

(* The keeper's endpoint is an OpenSSH one declaring /app, reached through the
   same stub as the guest fixture. *)
let declared_fixture ~mode =
  let f = fixture ~mode in
  let base = f.config.Workspace.base_path in
  let control_path_dir = Filename.concat base "ssh-control" in
  Unix.mkdir control_path_dir 0o700;
  let endpoint =
    Keeper_sandbox_remote.of_openssh ~base_path:base ~keeper_name:"keeper-a"
      { endpoint = endpoint_config ~host:"host-a.invalid"
      ; ssh_bin = Filename.concat base ("cli-" ^ mode)
      ; identity_file = Filename.concat base "id"
      ; known_hosts_file = Filename.concat base "known_hosts"
      ; control_path_dir
      }
  in
  { f with endpoint }
;;

(* Runs the handler with a Gate that answers [decision] and records what it
   was asked: endpoint, target, mode, bytes, and whether it was a patch. *)
let handle_declared f ~decision args =
  let asked = ref [] in
  let authorize ~endpoint ~requested_target ~mode ~content_source:_ ~content ~patch =
    asked :=
      ( endpoint.Exec_ssh_endpoint.host
      , requested_target
      , Keeper_tool_write_mode.to_string mode
      , content
      , Option.is_some patch )
      :: !asked;
    decision
  in
  let result =
    Keeper_tool_filesystem_remote_write.handle_with_endpoint
      ~declared_root_writes:
        (Keeper_tool_filesystem_remote_write.Authorize_declared_roots authorize)
      ~endpoint:f.endpoint ~config:f.config ~meta:f.meta ~args:(`Assoc args)
  in
  result, List.rev !asked
;;

let allow =
  Keeper_gate.Allow { Keeper_gate.source = Keeper_gate.Keeper_always_allow; audit_receipts = [] }
;;

let asked_testable = Alcotest.(list (pair (pair string string) (pair string (pair string bool))))

let asked_as_pairs asked =
  List.map
    (fun (endpoint, target, mode, content, patched) ->
      (endpoint, target), (mode, (content, patched)))
    asked
;;

let nothing_written f = not (Sys.file_exists (f.frame_path ^ ".write"))

let test_declared_root_write_lands_when_the_gate_allows () =
  with_eio @@ fun () ->
  let f = declared_fixture ~mode:"ok" in
  let result, asked =
    handle_declared f ~decision:allow
      [ "path", `String "/app/out.txt"; "mode", `String "overwrite"; "content", `String "done\n" ]
  in
  check bool "completed" true (completed result);
  check bool "the path is the endpoint's" true (member "path" result = `String "/app/out.txt");
  check bool "the authorization travels with the result" true (Option.is_some result.metadata);
  check asked_testable "the Gate was asked once, with the endpoint path and bytes"
    [ ("host-a.invalid", "/app/out.txt"), ("overwrite", ("done\n", false)) ]
    (asked_as_pairs asked);
  let request, stdin = write_frame f in
  check (list string) "written at the endpoint path as itself"
    (Keeper_tool_filesystem_remote_write.declared_root_write_argv ~mode:Replace_whole
       ~endpoint_path:"/app/out.txt" ~roots:[ "/app" ])
    request.argv;
  check string "content" "done\n" stdin
;;

let test_declared_root_write_waits_when_the_gate_defers () =
  with_eio @@ fun () ->
  let f = declared_fixture ~mode:"ok" in
  let deferred =
    Keeper_gate.Deferred
      { operation = Keeper_gate.filesystem_write_gate_operation
      ; approval_id = "approval-1"
      ; reason = Keeper_gate.Human_requested
      ; audit_receipts = []
      }
  in
  let result, asked =
    handle_declared f ~decision:deferred
      [ "path", `String "/app/out.txt"; "mode", `String "overwrite"; "content", `String "done\n" ]
  in
  check bool "deferred" true
    (match result.disposition with
     | Tool_result.Deferred () -> true
     | Tool_result.Completed () | Tool_result.Failed _ -> false);
  check int "asked once" 1 (List.length asked);
  check bool "nothing written" true (nothing_written f)
;;

let test_undeclared_path_is_refused_without_asking () =
  with_eio @@ fun () ->
  let f = declared_fixture ~mode:"ok" in
  let result, asked =
    handle_declared f ~decision:allow
      [ "path", `String "/etc/cron.d/x"; "mode", `String "overwrite"; "content", `String "x" ]
  in
  check bool "the caller's path is refused" true (failed_as Tool_result.Policy_rejection result);
  check int "the Gate is not asked" 0 (List.length asked);
  check bool "nothing written" true (nothing_written f)
;;

let test_refused_declared_roots_keep_the_playground_jail () =
  with_eio @@ fun () ->
  let f = declared_fixture ~mode:"ok" in
  let result =
    handle f [ "path", `String "/app/out.txt"; "mode", `String "overwrite"; "content", `String "x" ]
  in
  check bool "refused" true (failed_as Tool_result.Policy_rejection result);
  check bool "nothing written" true (nothing_written f)
;;

let test_declared_root_patch_asks_with_the_patched_body () =
  with_eio @@ fun () ->
  let f = declared_fixture ~mode:"ok" in
  save (f.frame_path ^ ".source") "a = 1\nb = 1\n";
  let result, asked =
    handle_declared f ~decision:allow
      [ "path", `String "/app/conf.py"; "mode", `String "patch"
      ; "old_string", `String "a = 1"; "new_string", `String "a = 2" ]
  in
  check bool "completed" true (completed result);
  check asked_testable "the Gate sees the patched file"
    [ ("host-a.invalid", "/app/conf.py"), ("patch", ("a = 2\nb = 1\n", true)) ]
    (asked_as_pairs asked);
  let request, stdin = write_frame f in
  check (list string) "replaced at the endpoint path"
    (Keeper_tool_filesystem_remote_write.declared_root_write_argv ~mode:Replace_whole
       ~endpoint_path:"/app/conf.py" ~roots:[ "/app" ])
    request.argv;
  check string "patched body" "a = 2\nb = 1\n" stdin
;;

(* Only the endpoint the write runs on can declare a root. A runtime.toml that
   declares /app does not make a guest endpoint's refused path writable. *)
let test_a_guest_endpoint_declares_no_roots () =
  with_eio @@ fun () ->
  let f = fixture ~mode:"ok" in
  save
    (Filename.concat f.config.Workspace.base_path ".masc/config/runtime.toml")
    (Exec_ssh_endpoint.to_toml (endpoint_config ~host:"host-a.invalid"));
  let result, asked =
    handle_declared f ~decision:allow
      [ "path", `String "/app/out.txt"; "mode", `String "overwrite"; "content", `String "x" ]
  in
  check bool "refused" true (failed_as Tool_result.Policy_rejection result);
  check int "the Gate is not asked" 0 (List.length asked);
  check bool "nothing written" true (nothing_written f)
;;

(* An approval is spent only on the Gate input it was given. Replay rebuilds
   the input from the endpoint configuration current then, so the same name
   pointing at another host is another input and needs its own approval. *)
let test_declared_root_escape_is_refused_as_the_callers () =
  with_eio @@ fun () ->
  let f = declared_fixture ~mode:"escape" in
  let result, asked =
    handle_declared f ~decision:allow
      [ "path", `String "/app/linkdir/out.txt"; "mode", `String "overwrite"; "content", `String "x" ]
  in
  check int "the Gate was asked for the lexical path" 1 (List.length asked);
  check bool "a path that leads out through a link is the caller's" true
    (failed_as Tool_result.Policy_rejection result);
  check bool "the refusal says what happened" true
    (let raw = result.raw_output and needle = "path_outside_declared_root" in
     let n = String.length needle in
     let rec from i = i + n <= String.length raw && (String.sub raw i n = needle || from (i + 1)) in
     from 0)
;;

(* The declared-root payloads, run here as the endpoint would run them,
   against real symbolic links. *)
let run_payload ~stdin argv =
  match argv with
  | "sh" :: rest ->
    let stdin_path = Filename.temp_file "masc-declared-" ".stdin" in
    save stdin_path stdin;
    let fd = Unix.openfile stdin_path [ Unix.O_RDONLY ] 0 in
    let pid = Unix.create_process "sh" (Array.of_list ("sh" :: rest)) fd Unix.stdout Unix.stderr in
    Unix.close fd;
    let _, status = Unix.waitpid [] pid in
    Sys.remove stdin_path;
    status
  | _ -> fail "the payload is not an sh command"
;;

let test_declared_payload_does_not_follow_a_link_out_of_the_root () =
  let root = temp_dir () in
  let app = Filename.concat root "app" in
  let outside = Filename.concat root "outside" in
  Unix.mkdir app 0o700;
  Unix.mkdir outside 0o700;
  let victim = Filename.concat outside "out.txt" in
  save victim "original";
  Unix.symlink outside (Filename.concat app "linkdir");
  Unix.symlink victim (Filename.concat app "link.txt");
  let payload mode path content =
    run_payload ~stdin:content
      (Keeper_tool_filesystem_remote_write.declared_root_write_argv ~mode
         ~endpoint_path:(Filename.concat app path) ~roots:[ app ])
  in
  let escaped = Unix.WEXITED Keeper_tool_filesystem_remote_write.declared_root_escape_exit in
  let overwrite = Keeper_tool_filesystem_remote_write.Replace_whole in
  let append = Keeper_tool_filesystem_remote_write.Append_tail in
  check bool "overwrite through a linked directory" true
    (payload overwrite "linkdir/out.txt" "x" = escaped);
  check bool "append through a linked directory" true
    (payload append "linkdir/out.txt" "x" = escaped);
  check bool "append to a linked file" true (payload append "link.txt" "x" = escaped);
  check bool "a new directory behind a link" true
    (payload overwrite "linkdir/new/deep.txt" "x" = escaped);
  check string "the file outside the root is untouched" "original" (read_file victim);
  check bool "no directory was made behind the link" false
    (Sys.file_exists (Filename.concat outside "new"));
  check bool "a path inside the root is written" true
    (payload overwrite "sub/ok.txt" "hello" = Unix.WEXITED 0);
  check string "with the bytes" "hello" (read_file (Filename.concat app "sub/ok.txt"));
  check bool "and appended to" true (payload append "sub/ok.txt" "+more" = Unix.WEXITED 0);
  check string "in place" "hello+more" (read_file (Filename.concat app "sub/ok.txt"))
;;

let test_another_host_behind_the_name_is_another_gate_input () =
  let input host =
    Keeper_tool_filesystem_runtime.declared_root_write_gate_input
      ~endpoint:(endpoint_config ~host)
      ~requested_target:"/app/out.txt"
      ~mode:Keeper_tool_write_mode.Overwrite
      ~content_source:(Keeper_write_content.Text "x")
      ~content:"x"
      ~patch:None
  in
  check bool "the same endpoint gives the same input" true
    (Yojson.Safe.equal (input "host-a.invalid") (input "host-a.invalid"));
  check bool "another host gives another input" false
    (Yojson.Safe.equal (input "host-a.invalid") (input "host-b.invalid"));
  let repinned =
    Keeper_tool_filesystem_runtime.declared_root_write_gate_input
      ~endpoint:
        { (endpoint_config ~host:"host-a.invalid") with
          Exec_ssh_endpoint.known_hosts_file = "/etc/masc/ssh/another_known_hosts"
        }
      ~requested_target:"/app/out.txt"
      ~mode:Keeper_tool_write_mode.Overwrite
      ~content_source:(Keeper_write_content.Text "x")
      ~content:"x"
      ~patch:None
  in
  check bool "another pinned host key gives another input" false
    (Yojson.Safe.equal (input "host-a.invalid") repinned);
  match Keeper_tool_filesystem_runtime.approved_write_of_gate_input (input "host-a.invalid") with
  | Error error -> fail error
  | Ok approved ->
    check string "replays the endpoint path" "/app/out.txt"
      approved.Keeper_tool_filesystem_runtime.target;
    check bool "replays the mode" true
      (approved.Keeper_tool_filesystem_runtime.mode = Keeper_tool_write_mode.Overwrite)
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
          ; test_case "patch arguments recover and I/O stays runtime" `Quick test_remote_patch_arguments_recover_but_write_failure_stays_runtime
          ; test_case "identical remote patch does not write" `Quick test_identical_remote_patch_does_not_write
          ; test_case "patch reads then replaces" `Quick test_patch_reads_then_replaces
          ; test_case "declared root write lands when the Gate allows" `Quick
              test_declared_root_write_lands_when_the_gate_allows
          ; test_case "declared root write waits when the Gate defers" `Quick
              test_declared_root_write_waits_when_the_gate_defers
          ; test_case "undeclared path is refused without asking" `Quick
              test_undeclared_path_is_refused_without_asking
          ; test_case "refused declared roots keep the playground jail" `Quick
              test_refused_declared_roots_keep_the_playground_jail
          ; test_case "declared root patch asks with the patched body" `Quick
              test_declared_root_patch_asks_with_the_patched_body
          ; test_case "a guest endpoint declares no roots" `Quick
              test_a_guest_endpoint_declares_no_roots
          ; test_case "another host behind the name is another Gate input" `Quick
              test_another_host_behind_the_name_is_another_gate_input
          ; test_case "a declared root escape is refused as the caller's" `Quick
              test_declared_root_escape_is_refused_as_the_callers
          ; test_case "the declared payload does not follow a link out of the root" `Quick
              test_declared_payload_does_not_follow_a_link_out_of_the_root
          ; test_case "patch without a source is a workflow rejection" `Quick
              test_patch_without_a_source_is_a_workflow_rejection
          ; test_case "endpoint failure is a runtime failure" `Quick
              test_endpoint_failure_is_a_runtime_failure
          ; test_case "jail and mode are enforced before any payload" `Quick
              test_jail_and_mode_are_enforced_before_any_payload
          ] )
      ]
