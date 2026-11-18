(** A local carrier reaches the real shim through the real host stdio port.
    This does not exercise an SSH network or a VM. Scripted probe/receipt
    refusals are separate from the real-shim cases. *)
open Alcotest
open Masc
module Remote = Keeper_sandbox_remote
module Request = Remote.Stdio_request
module Stdio = Keeper_sandbox_remote_stdio
module Mcp = Agent_core.Mcp

let self = ref ""
let shim = ref ""
exception Callback_failed
exception Receipt_failed
type decline = Declined

let save path text = Out_channel.with_open_bin path (fun out -> output_string out text)
let load path = In_channel.with_open_bin path In_channel.input_all

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let running pid =
  match Unix.openfile (Printf.sprintf "/proc/%d/stat" pid) [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 with
  | fd ->
    let input = Unix.in_channel_of_descr fd in
    let text = Fun.protect ~finally:(fun () -> close_in input) (fun () -> In_channel.input_all input) in
    text.[String.rindex text ')' + 2] <> 'Z'
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false

let carrier dir mode binary args =
  let probe = args = ["--probe"] in
  let log = open_out_gen [Open_wronly; Open_creat; Open_append] 0o600
      (Filename.concat dir "carrier.log") in
  output_string log (if probe then "probe\n" else "request\n"); close_out log;
  if not probe then (
    save (Filename.concat dir "carrier.pid") (string_of_int (Unix.getpid ()));
    save (Filename.concat dir "carrier.cwd") (Sys.getcwd ()));
  if probe && List.mem mode ["disabled"; "v2"; "broken"] then (
    print_endline (match mode with
      | "disabled" -> {|{"name":"masc-exec-shim","version":"3.0.0","capabilities":[]}|}
      | "v2" -> {|{"name":"masc-exec-shim","version":"2.4.1","capabilities":["interactive_stdin"]}|}
      | _ -> "not a probe"); exit 0);
  if not probe && List.mem mode ["wrong-major"; "wrong-mode"] then (
    let header = really_input_string stdin 8 in
    let size = Int64.to_int (String.get_int64_be header 0) in
    let frame = header ^ really_input_string stdin size in
    let request = match Exec_ssh_protocol.decode_request frame with
      | Ok (request, _) -> request | Error detail -> failwith detail in
    if request.acceptance_frame then output_string stderr (Exec_ssh_protocol.render_acceptance_frame request.v);
    let trailer : Exec_ssh_protocol.trailer =
      { v = (if mode = "wrong-major" then V2 else V3); exit = Some 0; signal = None;
        timed_out = false; shim_error = None; observed_syscalls = [] } in
    let execution_receipt : Exec_ssh_protocol.execution_receipt =
      { mode = (if mode = "wrong-mode" then Observe else Effect); boundary = Sandbox_applied } in
    output_string stderr (Exec_ssh_protocol.render_trailer ~execution_receipt trailer);
    flush stderr; exit 0);
  Unix.putenv Exec_ssh_protocol.shim_config_env_var (Filename.concat dir "shim.conf");
  Unix.execv binary (Array.of_list (binary :: args))

type fixture = { dir : string; root : string; endpoint : Remote.t }

let with_fixture ?(mode = "real") f =
  let dir = Unix.realpath (Filename.temp_dir "remote-stdio-" "") in
  let base_path = Filename.concat dir "host" and remote_root = Filename.concat dir "remote" in
  Unix.mkdir base_path 0o700; Unix.mkdir remote_root 0o700;
  let config = Filename.concat dir "shim.conf" in
  save config (Printf.sprintf "remote_root=%s\nscratch_root=%s\nenv_allowlist=CAPTURED\n"
    remote_root remote_root);
  Unix.chmod config 0o644;
  let endpoint = Remote.of_container_exec ~base_path ~keeper_name:"stdio-fixture"
      ~remote_root ~gh_config_dir:(Filename.concat remote_root "gh") ~injected_env:[]
      ~env_allowlist:["CAPTURED"] ~connect_timeout_sec:1 ~max_concurrent_sessions:1
      { prefix = [!self; "--carrier"; dir; mode]; probe_prefix = None;
        container_name = Filename.basename dir; shim_path = !shim } in
  let root = Remote.workspace_root endpoint in
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () ->
    (* A local carrier dying does not prove that a remote payload died. This
       fixture owns the PID its real local payload wrote, and cleans it itself. *)
    let pid_file = Filename.concat root "payload.pid" in
    if Sys.file_exists pid_file then (
      let pid = int_of_string (load pid_file) in
      try Unix.kill (-pid) Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
    remove_tree dir) (fun () -> f {dir; root; endpoint})

let with_runtime f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:Posix_spawn_process_mgr.mgr ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 25.0 (fun () -> f (Eio.Stdenv.clock env)))

let prepare ?(env = [||]) fixture argv =
  match Request.prepare ~timeout_sec:15.0 fixture.endpoint ~argv ~env ~cwd:None with
  | Ok prepared -> prepared | Error _ -> fail "valid fixture request was refused"

let log fixture =
  let path = Filename.concat fixture.dir "carrier.log" in
  if Sys.file_exists path then String.split_on_char '\n' (String.trim (load path)) else []

let read_exact input count =
  let bytes = Cstruct.create count in Eio.Flow.read_exact input bytes; Cstruct.to_string bytes

let invoke ?(on_dispatch = fun () -> Ok ()) ?(on_receipt = ignore)
    ?(on_stderr_chunk = ignore) ?(on_stdout_tail = ignore) prepared use =
  Stdio.with_stdio prepared ~on_dispatch ~on_receipt ~on_stderr_chunk ~on_stdout_tail use

let observed completion =
  match completion.Request.execution with
  | Remote.Execution_observed (receipt, trailer) -> receipt, trailer
  | Remote.Execution_unavailable _ -> fail "the real shim's completed receipt was lost"

let assert_runtime_unavailable fixture prepared =
  let receipts = ref [] and dispatches = ref 0 in
  let result = invoke prepared
      ~on_dispatch:(fun () -> incr dispatches; Ok ())
      ~on_receipt:(fun receipt -> receipts := receipt :: !receipts)
      (fun ~input:_ ~output:_ -> fail "unavailable runtime lent process streams") in
  (match result with
   | Error (Stdio.Runtime_unavailable _) -> ()
   | Error (Stdio.Process_unavailable _
       | Stdio.Refused _ | Stdio.Dispatch_declined _ | Stdio.Guest_unavailable _ | Stdio.Host_timeout)
   | Ok _ -> fail "unavailable runtime lost its typed refusal");
  check bool "one unsent receipt" true
    (!receipts = [Remote.Execution_unavailable Remote.Request_not_sent]);
  check int "no dispatch callback" 0 !dispatches;
  check (list string) "no probe or carrier without runtime" [] (log fixture)

let test_prepare_refusals_do_not_probe () =
  with_fixture @@ fun fixture ->
  List.iter (fun timeout_sec ->
    match Request.prepare ~timeout_sec fixture.endpoint ~argv:["/bin/true"] ~env:[||] ~cwd:None with
    | Error (Request.Invalid_request _) -> ()
    | Error (Request.Docker_unavailable
        | Request.Mode_unavailable _ | Request.Probe_unavailable _
        | Request.Interactive_unavailable _) | Ok _ ->
      fail "invalid timeout was not refused before effects")
    [0.0; -1.0; infinity; nan];
  let guest = Remote.of_agent_socket ~base_path:fixture.dir ~keeper_name:"guest"
      ~remote_root:fixture.root ~gh_config_dir:fixture.root ~injected_env:[] ~env_allowlist:[]
      ~connect_timeout_sec:1 ~max_concurrent_sessions:1 ~container_name:"never-connect"
      ~shim_path:!shim ~host_socket:(Filename.concat fixture.dir "absent.sock")
      ~expected:{Keeper_guest_socket.uid=Unix.getuid (); gid=Unix.getgid ()} in
  let docker = Remote.of_docker_exec ~base_path:fixture.dir ~keeper_name:"docker"
      ~remote_root:fixture.root ~gh_config_dir:fixture.root ~injected_env:[] ~env_allowlist:[]
      ~connect_timeout_sec:1 ~max_concurrent_sessions:1
      {prefix=[!self;"--carrier";fixture.dir;"real"];probe_prefix=None;
       container_name="never-dispatch";shim_path= !shim} in
  (match Request.prepare ~timeout_sec:1.0 guest ~argv:["/bin/true"] ~env:[||] ~cwd:None with
   | Ok _ -> ()
   | Error _ -> fail "guest-agent request must prepare without connecting");
  check bool "Docker refused purely" true
    (Request.prepare ~timeout_sec:1.0 docker ~argv:["/bin/true"] ~env:[||] ~cwd:None
     = Error Request.Docker_unavailable);
  check (list string) "pure refusal launched no carrier" [] (log fixture);
  let prepared = prepare fixture ["/bin/true"] in
  Process_eio.reset_for_testing ();
  assert_runtime_unavailable fixture prepared;
  (* An active fiber is not a process owner. The finite probe helper has a
     Unix fallback, so preflight must refuse before that helper is reached. *)
  Eio_main.run (fun _ -> assert_runtime_unavailable fixture prepared);
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
    (* An initialized but ended runtime must not permit a later non-Eio call
       to acquire an endpoint lease or run a probe. *)
    Eio_main.run (fun env ->
      Process_eio.init ~cwd_default:(Eio.Stdenv.fs env)
        ~proc_mgr:Posix_spawn_process_mgr.mgr ~clock:(Eio.Stdenv.clock env));
    assert_runtime_unavailable fixture prepared)

let test_probe_refusals_precede_dispatch () =
  List.iter (fun mode -> with_fixture ~mode @@ fun fixture -> with_runtime @@ fun _ ->
    let prepared = prepare fixture ["/bin/true"] in
    let dispatches = ref 0 and receipts = ref [] in
    let result = invoke prepared ~on_dispatch:(fun () -> incr dispatches; Ok ())
        ~on_receipt:(fun receipt -> receipts := receipt :: !receipts)
        (fun ~input:_ ~output:_ -> fail "incapable peer reached duplex callback") in
    (match result with
     | Error (Stdio.Refused (Request.Interactive_unavailable _ | Request.Probe_unavailable _)) -> ()
     | Error (Stdio.Refused (Request.Docker_unavailable
          | Request.Mode_unavailable _ | Request.Invalid_request _)
         | Stdio.Dispatch_declined _ | Stdio.Process_unavailable _ | Stdio.Runtime_unavailable _
         | Stdio.Guest_unavailable _ | Stdio.Host_timeout)
     | Ok _ -> fail "peer capability/probe refusal was lost");
    check int "dispatch hook did not run" 0 !dispatches;
    check (list string) "only the probe ran" ["probe"] (log fixture);
    check bool "one unsent observation" true
      (!receipts = [Remote.Execution_unavailable Remote.Request_not_sent]))
    ["disabled"; "v2"; "broken"]

let test_dispatch_decline_sends_no_request () =
  with_fixture @@ fun fixture -> with_runtime @@ fun _ ->
  let prepared = prepare fixture ["/bin/true"] in
  let result = invoke prepared ~on_dispatch:(fun () -> Error Declined)
      (fun ~input:_ ~output:_ -> fail "declined dispatch started payload") in
  check bool "typed caller decline is unchanged" true (result = Error (Stdio.Dispatch_declined Declined));
  check (list string) "probe is separate from request dispatch" ["probe"] (log fixture)

let test_dispatch_hook_cannot_redirect_carrier_cwd () =
  (* The scripted mismatch intentionally supplies no successful sandbox
     receipt. The assertion is the real host carrier's working directory. *)
  with_fixture ~mode:"wrong-major" @@ fun fixture ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let initialize cwd =
    Process_eio.init ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / cwd)
      ~proc_mgr:Posix_spawn_process_mgr.mgr ~clock:(Eio.Stdenv.clock env)
  in
  initialize fixture.dir;
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
    let prepared = prepare fixture ["/bin/true"] in
    let dispatches = ref 0 and receipts = ref [] in
    let result = Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 25.0 (fun () ->
      invoke prepared
        ~on_dispatch:(fun () -> incr dispatches; initialize fixture.root; Ok ())
        ~on_receipt:(fun receipt -> receipts := receipt :: !receipts)
        (fun ~input:_ ~output:_ -> ())) in
    (match result with
     | Ok ((), completion) ->
       (match completion.Request.dispatch with
        | Remote.Dispatch_failed {failure=Remote.Trailer_disagreement;_} -> ()
        | Remote.Dispatch_failed
            {failure=Remote.Local_timeout | Remote.Remote_timeout | Remote.Transport_failed
              | Remote.Shim_refused;_}
        | Remote.Payload_finished _ -> fail "scripted mismatch acquired a successful receipt");
       check bool "one final observation" true (!receipts = [completion.execution])
     | Error _ -> fail "host carrier did not complete the scripted request");
    check int "one dispatch admission" 1 !dispatches;
    check string "the carrier uses the runtime captured before admission" fixture.dir
      (load (Filename.concat fixture.dir "carrier.cwd")))

let server = {|import json, os, signal, sys
open("payload.pid", "w").write(str(os.getpid()))
signal.signal(signal.SIGTERM, signal.SIG_DFL)
sys.stderr.buffer.write(b"payload-stderr\x00"); sys.stderr.buffer.flush()
calls = 0
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        result = {"protocolVersion":request["params"]["protocolVersion"],
                  "capabilities":{"tools":{}}, "serverInfo":{"name":"real-shim-fixture","version":"1"}}
    elif method == "tools/call":
        calls += 1
        args = request["params"]["arguments"]
        result = {"content":[{"type":"text","text":args["value"]},
                             {"type":"image","mimeType":"image/png","data":"AAEC"}],
                  "isError":args["error"], "structuredContent":{"arguments":args,
                  "declaration":os.getenv("CAPTURED"), "cwd":os.getcwd()}, "_meta":{"retained":True}}
    else:
        continue
    print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
    if calls == 2:
        while True: signal.pause()
|}

let mcp input output =
  let channel = match Mcp.Channel.create ~input ~output () with
    | Ok channel -> channel | Error detail -> fail detail in
  (match Mcp.Channel.initialize channel ~client_version:"host-stdio-test" with
   | Ok () -> () | Error error -> fail (Agent_core.Error.to_string error));
  channel

let test_actual_shim_mcp_retains_full_results () =
  with_fixture @@ fun fixture -> with_runtime @@ fun _ ->
  let env = [|"CAPTURED=before"|] in
  let prepared = prepare ~env fixture ["python3";"-c";server] in
  env.(0) <- "CAPTURED=after";
  let receipts = ref [] and stderr = Buffer.create 32 in
  let result = invoke prepared ~on_receipt:(fun value -> receipts := value :: !receipts)
      ~on_stderr_chunk:(Buffer.add_string stderr) (fun ~input ~output ->
        let channel = mcp input output in
        List.iter (fun is_error ->
          let value = fixture.root ^ "/original\000bytes" in
          let arguments = `Assoc ["value",`String value;"error",`Bool is_error] in
          match Mcp.Channel.call_tool_full channel ~name:"echo" ~arguments with
          | Error error -> fail (Agent_core.Error.to_string error)
          | Ok result ->
            let expected_content = Agent_core_protocol.Mcp_schema.Sdk_types.
              [TextContent {type_="text";text=value;annotations=None};
               ImageContent {type_="image";data="AAEC";mime_type="image/png";annotations=None}] in
            check bool "all content blocks preserved" true (result.content = expected_content);
            check (option bool) "isError remains data" (Some is_error) result.is_error;
            check bool "structured result binds original arguments and frozen declaration" true
              (result.structured_content = Some (`Assoc ["arguments",arguments;
                "declaration",`String "before";"cwd",`String fixture.root]));
            check bool "SDK metadata survives" true (result._meta = Some (`Assoc ["retained",`Bool true])))
          [false;true];
        Mcp.Channel.close channel;
        2) in
  (match result with
   | Error _ -> fail "actual shim session failed"
   | Ok (calls, completion) ->
     check int "callback value counts calls, not process success" 2 calls;
     let receipt, trailer = observed completion in
     check bool "real child acknowledged its boundary" true
       (receipt = Exec_ssh_protocol.{mode=Effect;boundary=Sandbox_applied});
     check (option int) "normal channel close cancels the still-running payload" (Some 15) trailer.signal;
     check bool "the one final callback matches completion" true (!receipts=[completion.execution]));
  check string "control frames excluded and payload stderr unchanged"
    "payload-stderr\000" (Buffer.contents stderr)

let test_binary_output_is_neither_capped_nor_rewritten () =
  with_fixture @@ fun fixture -> with_runtime @@ fun _ ->
  let size = Common.max_process_capture_head_bytes + Common.max_process_capture_tail_bytes + 17 in
  let prefix = fixture.root ^ "/unchanged\000" in
  let expected = prefix ^ String.init size (fun i -> Char.chr (i mod 256)) in
  let script = {|import os,signal,sys
open("payload.pid","w").write(str(os.getpid()))
size=int(sys.argv[1]); data=sys.argv[2].encode()+b"/unchanged\x00"+bytes(range(256))*(size//256)+bytes(range(size%256))
sys.stdout.buffer.write(data+b"tail\x00raw"); sys.stdout.buffer.flush()
while True: signal.pause()
|} in
  let tail = Buffer.create 32 in
  let result = invoke (prepare fixture ["python3";"-c";script;string_of_int size;fixture.root])
      ~on_stdout_tail:(Buffer.add_string tail)
      (fun ~input ~output:_ -> read_exact input (String.length expected)) in
  (match result with Ok (bytes, _) ->
     check int "raw output exceeds the capture ceiling without losing length"
       (String.length expected) (String.length bytes);
     check bool "every raw byte reaches the callback without path rewriting" true
       (String.equal expected bytes)
   | Error _ -> fail "raw stdio session failed");
  check string "unread tail is also exact" "tail\000raw" (Buffer.contents tail)

let test_lease_lasts_through_carrier_cleanup () =
  with_fixture @@ fun fixture -> with_runtime @@ fun _ ->
  let prepared = prepare fixture ["python3";"-c";server] in
  let first_ready, start_second = Eio.Promise.create () in
  let second_attempted, announce_attempt = Eio.Promise.create () in
  let second_dispatched = ref false in
  Eio.Fiber.both
    (fun () -> ignore (invoke prepared (fun ~input ~output ->
       let channel = mcp input output in
       Eio.Promise.resolve start_second ();
       Eio.Promise.await second_attempted;
       Eio.Fiber.yield ();
       check bool "second call cannot dispatch during the first session" false !second_dispatched;
       Mcp.Channel.close channel)))
    (fun () ->
      Eio.Promise.await first_ready;
      Eio.Promise.resolve announce_attempt ();
      match invoke prepared ~on_dispatch:(fun () ->
        let old_pid = int_of_string (load (Filename.concat fixture.dir "carrier.pid")) in
        check bool "first carrier is stopped before the lease is reused" false (running old_pid);
        second_dispatched := true; Ok ()) (fun ~input ~output ->
          let channel = mcp input output in Mcp.Channel.close channel) with
      | Ok _ -> () | Error _ -> fail "the endpoint lease was not reusable after cleanup");
  check bool "the second real invocation completed" true !second_dispatched

let test_primary_exception_survives_receipt_failure () =
  List.iter (fun primary -> with_fixture @@ fun fixture -> with_runtime @@ fun _ ->
    let seen = ref [] in
    (match invoke (prepare fixture ["python3";"-c";server])
       ~on_receipt:(fun receipt -> seen := receipt :: !seen; raise Receipt_failed)
       (fun ~input ~output -> let channel = mcp input output in
         Mcp.Channel.close channel; raise primary) with
     | Ok _ | Error _ -> fail "callback exception became a result"
     | exception observed -> check bool "primary exception identity survives secondary receipt failure"
         true (observed == primary));
    check int "one receipt notification on failure" 1 (List.length !seen);
    (match !seen with
     | [Remote.Execution_unavailable (Remote.Transport_unavailable _)] -> ()
     | [Remote.Execution_observed _]
     | [Remote.Execution_unavailable (Remote.Request_not_sent | Remote.Peer_receipt_missing
          | Remote.Invalid_receipt _ | Remote.Shim_refused_without_receipt)]
     | [] | _ :: _ :: _ -> fail "interrupted remote execution was claimed settled");
    let old_pid = int_of_string (load (Filename.concat fixture.dir "carrier.pid")) in
    check bool "the owned local carrier was cleaned" false (running old_pid))
    [Callback_failed; Eio.Cancel.Cancelled Callback_failed]

let test_receipt_failure_on_normal_return_propagates () =
  with_fixture @@ fun fixture -> with_runtime @@ fun _ ->
  match invoke (prepare fixture ["/bin/true"])
    ~on_receipt:(fun _ -> raise Receipt_failed) (fun ~input:_ ~output:_ -> ()) with
  | Ok _ | Error _ -> fail "receipt callback failure was swallowed"
  | exception Receipt_failed -> ()

let test_mismatched_peer_receipts_are_not_authoritative () =
  List.iter (fun mode -> with_fixture ~mode @@ fun fixture -> with_runtime @@ fun _ ->
    match invoke (prepare fixture ["/bin/true"]) (fun ~input:_ ~output:_ -> ()) with
    | Error _ -> fail "fixture carrier did not reach completion classification"
    | Ok ((), completion) ->
      (match completion.dispatch with
       | Remote.Dispatch_failed {failure=Remote.Trailer_disagreement;_} -> ()
       | Remote.Payload_finished _
       | Remote.Dispatch_failed {failure=(Remote.Local_timeout | Remote.Remote_timeout
           | Remote.Transport_failed | Remote.Shim_refused);_} ->
         fail "mismatched result was accepted");
      (match completion.execution with
       | Remote.Execution_unavailable (Remote.Invalid_receipt _) -> ()
       | Remote.Execution_observed _
       | Remote.Execution_unavailable (Remote.Request_not_sent | Remote.Transport_unavailable _
           | Remote.Peer_receipt_missing | Remote.Shim_refused_without_receipt) ->
         fail "mismatched version or mode granted execution evidence"))
    ["wrong-major";"wrong-mode"]

(* Scripted guest peer: exercises the real host/MCP ownership path without
   claiming that this local listener enforced a VM sandbox. *)
let test_guest_mcp_uses_socket_without_process_runtime () =
  let module Relay = Exec_ssh_protocol.Relay in
  with_fixture @@ fun fixture ->
  Process_eio.reset_for_testing ();
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  let socket = Filename.concat fixture.dir "guest.sock" in
  let expected = Keeper_guest_socket.{uid=502;gid=20} in
  let endpoint = Remote.of_agent_socket ~base_path:fixture.dir ~keeper_name:"guest-stdio"
      ~remote_root:fixture.root ~gh_config_dir:fixture.root ~injected_env:[] ~env_allowlist:[]
      ~connect_timeout_sec:1 ~max_concurrent_sessions:1 ~container_name:"scripted-guest"
      ~shim_path:!shim ~host_socket:socket ~expected in
  let prepared = match Request.prepare ~timeout_sec:10. endpoint
      ~argv:["declared-mcp-service"] ~env:[||] ~cwd:None with
    | Ok prepared -> prepared | Error _ -> fail "guest preparation failed" in
  let admitted = ref false and half_closed = ref false and probes = ref 0 and calls = ref 0 in
  let listening = Eio.Net.listen ~sw ~backlog:4 net (`Unix socket) in
  let answer peer =
    let send chunk = Eio.Flow.copy_string (Relay.encode chunk) peer in
    send (Relay.Hello {relay_version=Relay.version;
      source_identity=Source_identity.current;root_read_only=true;
      uid=expected.uid;gid=expected.gid;no_new_privs=true});
    match Relay.request_kind_of_byte (read_exact peer 1).[0] with
    | Some Relay.Probe ->
      incr probes;
      send (Relay.Stdout {|{"name":"masc-exec-shim","version":"3.0.0","capabilities":["interactive_stdin","request_acceptance_frame"]}|});
      send (Relay.Exit (Relay.Exited 0))
    | Some Relay.Interactive_run ->
      check bool "owner admitted before payload frame" true !admitted;
      let header = read_exact peer 8 in
      let frame = header ^ read_exact peer (Int64.to_int (String.get_int64_be header 0)) in
      let request = match Exec_ssh_protocol.decode_request frame with
        | Ok (request, "") -> request
        | Ok _ | Error _ -> fail "invalid interactive frame" in
      check bool "typed interactive contract" true (request.stdin = Exec_ssh_protocol.Interactive);
      send (Relay.Stderr (Exec_ssh_protocol.render_acceptance_frame request.v));
      let lines = Eio.Buf_read.of_flow ~max_size:65536 peer in
      let rec rpc () =
        if !calls < 2 then (
          let json = Yojson.Safe.from_string (Eio.Buf_read.line lines) in
          let member name = Yojson.Safe.Util.member name json in
          match member "id" with
          | `Null -> rpc ()
          | (`Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
              | `Assoc _ | `List _) as id ->
            let result = match member "method" with
              | `String "initialize" ->
                `Assoc ["protocolVersion",Yojson.Safe.Util.member "protocolVersion" (member "params");
                  "capabilities",`Assoc ["tools",`Assoc []];
                  "serverInfo",`Assoc ["name",`String "scripted-guest";"version",`String "1"]]
              | `String "tools/call" ->
                incr calls;
                let arguments = Yojson.Safe.Util.member "arguments" (member "params") in
                `Assoc ["content",`List [`Assoc ["type",`String "text";"text",`String "full reply"];
                  `Assoc ["type",`String "image";"mimeType",`String "image/png";"data",`String "AAEC"]];
                  "isError",`Bool (!calls=2);"structuredContent",arguments;
                  "_meta",`Assoc ["retained",`Bool true]]
              | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _
              | `Assoc _ | `List _ -> fail "unexpected fixture RPC" in
            send (Relay.Stdout (Yojson.Safe.to_string (`Assoc ["jsonrpc",`String "2.0";"id",id;"result",result]) ^ "\n"));
            rpc ())
      in
      rpc ();
      (match Eio.Buf_read.line lines with
       | _ -> fail "callback returned without closing input"
       | exception End_of_file -> half_closed := true);
      send (Relay.Stdout "tail\000");
      let trailer : Exec_ssh_protocol.trailer =
        {v=request.v;exit=Some 7;signal=None;timed_out=false;shim_error=None;observed_syscalls=[]} in
      let execution_receipt : Exec_ssh_protocol.execution_receipt =
        {mode=request.mode;boundary=Sandbox_applied} in
      send (Relay.Stderr (Exec_ssh_protocol.render_trailer ~execution_receipt trailer));
      send (Relay.Exit (Relay.Exited 0))
    | Some Relay.Run | None -> fail "guest stdio used the finite request path"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec serve () =
      Eio.Net.accept_fork ~sw listening ~on_error:raise (fun peer _ -> answer peer);
      serve () in serve ());
  let receipts = ref [] and tail = Buffer.create 16 in
  let result = Eio.Time.with_timeout_exn clock 12. (fun () ->
    invoke prepared ~on_dispatch:(fun () -> admitted := true; Ok ())
      ~on_stdout_tail:(Buffer.add_string tail)
      ~on_receipt:(fun receipt -> receipts := receipt :: !receipts)
      (fun ~input ~output ->
        let channel = mcp input output in
        List.iter (fun is_error ->
          let arguments = `Assoc ["original",`String "guest\000bytes"] in
          match Mcp.Channel.call_tool_full channel ~name:"echo" ~arguments with
          | Error error -> fail (Agent_core.Error.to_string error)
          | Ok reply ->
            check int "both content blocks survive" 2 (List.length reply.content);
            check (option bool) "isError survives" (Some is_error) reply.is_error;
            check bool "complete structured response" true (reply.structured_content=Some arguments);
            check bool "metadata survives" true (reply._meta=Some (`Assoc ["retained",`Bool true])))
          [false;true];
        Mcp.Channel.close channel;
        2)) in
  (match result with
   | Error _ -> fail "guest socket did not finish"
   | Ok (value, completion) ->
     check int "callback result" 2 value;
     (match completion.dispatch with
      | Remote.Payload_finished {status;_} ->
        check bool "actual guest payload exit" true (status=Unix.WEXITED 7)
      | Remote.Dispatch_failed _ -> fail "guest terminal lost");
     check bool "one settled receipt" true (!receipts=[completion.execution]));
  check int "one control probe" 1 !probes;
  check int "two dependent calls" 2 !calls;
  check bool "input closed before final result" true !half_closed;
  check string "unread tail retained" "tail\000" (Buffer.contents tail);
  check (list string) "no local carrier process" [] (log fixture)

let () =
  match Array.to_list Sys.argv with
  | _ :: "--carrier" :: dir :: mode :: binary :: args -> carrier dir mode binary args
  | [program; shim_path] ->
    self := Unix.realpath program; shim := Unix.realpath shim_path;
    Alcotest.run ~argv:[|program|] "remote owned stdio"
      ["session",
       [test_case "pure preparation refuses before probe" `Quick test_prepare_refusals_do_not_probe;
        test_case "probe and capability refusals precede dispatch" `Quick test_probe_refusals_precede_dispatch;
        test_case "typed dispatch decline sends no request" `Quick test_dispatch_decline_sends_no_request;
        test_case "dispatch hook cannot redirect carrier cwd" `Quick test_dispatch_hook_cannot_redirect_carrier_cwd;
        test_case "actual shim MCP preserves two full results" `Quick test_actual_shim_mcp_retains_full_results;
        test_case "guest MCP uses socket without process runtime" `Quick test_guest_mcp_uses_socket_without_process_runtime;
        test_case "raw stdout exceeds capture bounds without rewrite" `Quick test_binary_output_is_neither_capped_nor_rewritten;
        test_case "endpoint lease lasts through session cleanup" `Quick test_lease_lasts_through_carrier_cleanup;
        test_case "primary exception survives receipt callback failure" `Quick test_primary_exception_survives_receipt_failure;
        test_case "normal receipt callback failure propagates" `Quick test_receipt_failure_on_normal_return_propagates;
        test_case "peer version and mode mismatch are rejected" `Quick test_mismatched_peer_receipts_are_not_authoritative]]
  | _ -> failwith "expected real masc_exec_shim binary path"
