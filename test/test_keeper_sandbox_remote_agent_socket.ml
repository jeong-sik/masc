(* Keeper_sandbox_remote's Agent_socket delivery: the runner and the probe
   reach the real agent relay and the real shim through the guest agent
   socket (RFC microvm-guest-agent-over-socket).

   The agent here runs without root, so the hello it sends reports this test
   host's facts and the production check refuses it. One case relies on that
   refusal. The others put a proxy in front of the agent that replaces only the
   hello with one that has every fact the check wants; every byte after the
   hello is the real agent and the real shim. *)

open Alcotest
open Masc
module Relay = Exec_ssh_protocol.Relay
module Remote = Keeper_sandbox_remote

let shim_binary = ref ""
let keeper = "keeper-a"
let guest_name = "guest-a"
let expected = { Keeper_guest_socket.uid = 502; gid = 20 }
let connect_timeout_sec = 5
let timeout_sec = 20.0

type agent =
  { socket : string
  ; root : string
  }

let agent = ref None

let the_agent () =
  match !agent with
  | Some agent -> agent
  | None -> fail "the agent was not started"

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_temp_dir f =
  let dir = Filename.temp_dir "masc-agent-socket-" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

(* Before any Eio loop: the agent is a forked process. *)
let start_agent dir =
  let root = Filename.concat dir "root" in
  Unix.mkdir root 0o755;
  Unix.mkdir (Filename.concat root keeper) 0o755;
  let config = Filename.concat dir "shim.conf" in
  Out_channel.with_open_bin config (fun channel ->
    Out_channel.output_string channel
      (Printf.sprintf "remote_root=%s\nscratch_root=%s\n" root root));
  Unix.chmod config 0o644;
  Unix.putenv Exec_ssh_protocol.shim_config_env_var config;
  let socket = Filename.concat dir "agent.sock" in
  let listener = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_UNIX socket);
  Unix.listen listener 16;
  match Unix.fork () with
  | 0 ->
    (match
       Shim_agent.serve ~listener ~program:!shim_binary
         ~host_signal_number:Exec_shim.host_signal_number
     with
     | _ -> Unix._exit 3
     | exception _ -> Unix._exit 3)
  | pid ->
    Unix.close listener;
    agent := Some { socket; root };
    pid

let forged_hello () : Relay.hello =
  { Relay.relay_version = Relay.version
  ; root_read_only = true
  ; uid = expected.Keeper_guest_socket.uid
  ; gid = expected.Keeper_guest_socket.gid
  ; no_new_privs = true
  }

let read_exact flow count =
  let buffer = Cstruct.create count in
  Eio.Flow.read_exact flow buffer;
  Cstruct.to_string buffer

(* Replaces the agent's hello and relays everything else. *)
let forging_proxy ~sw ~net ~agent_socket socket =
  let listening = Eio.Net.listen ~sw ~backlog:8 net (`Unix socket) in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      let client, _ = Eio.Net.accept ~sw listening in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Switch.run (fun connection ->
          let upstream = Eio.Net.connect ~sw:connection net (`Unix agent_socket) in
          let header = read_exact upstream 5 in
          ignore (read_exact upstream (Int32.to_int (String.get_int32_be header 1)) : string);
          Eio.Flow.copy_string (Relay.encode (Relay.Hello (forged_hello ()))) client;
          Eio.Fiber.both
            (fun () -> try Eio.Flow.copy client upstream with Eio.Io _ | End_of_file -> ())
            (fun () ->
              (try Eio.Flow.copy upstream client with Eio.Io _ | End_of_file -> ());
              Eio.Flow.close client)));
      loop ()
    in
    loop ())

let endpoint ~host_socket =
  let { root; _ } = the_agent () in
  Remote.of_agent_socket ~base_path:root ~keeper_name:keeper ~remote_root:root
    ~gh_config_dir:(Filename.concat (Filename.concat root keeper) ".config/gh")
    ~injected_env:[] ~env_allowlist:[] ~connect_timeout_sec ~max_concurrent_sessions:2
    ~container_name:guest_name ~shim_path:"/opt/masc-exec-shim/masc-exec-shim" ~host_socket
    ~expected

let with_eio f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
    (fun () -> f ~sw ~net:(Eio.Stdenv.net env))

let run_request ?(timeout_sec = timeout_sec) endpoint argv =
  let observed = ref None in
  let run =
    Remote.runner ~on_receipt:(fun observation -> observed := Some observation) ~timeout_sec
      endpoint
  in
  let outcome =
    run ~on_stdout_chunk:None ~on_stderr_chunk:None ~stdin_content:None ~argv ~env:[||]
      ~cwd:None
  in
  outcome, !observed

let describe = function
  | Masc_exec.Sandbox_target.Ran { status; stdout; stderr; _ } ->
    Printf.sprintf "ran (%s) stdout=%S stderr=%S"
      (match status with
       | Unix.WEXITED code -> Printf.sprintf "exit %d" code
       | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
       | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal)
      stdout stderr
  | Masc_exec.Sandbox_target.Transport_failed { reason; _ } -> "transport failed: " ^ reason

let with_proxy f =
  let { socket = agent_socket; _ } = the_agent () in
  with_temp_dir @@ fun dir ->
  let host_socket = Filename.concat dir "proxy.sock" in
  with_eio @@ fun ~sw ~net ->
  forging_proxy ~sw ~net ~agent_socket host_socket;
  f (endpoint ~host_socket)

let test_a_request_runs_through_the_agent () =
  with_proxy @@ fun endpoint ->
  match run_request endpoint [ "sh"; "-c"; "echo out; echo err >&2; exit 3" ] with
  | Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 3; stdout; stderr; _ }, observed ->
    check string "stdout" "out\n" stdout;
    check string "stderr, without the acceptance frame and the trailer" "err\n" stderr;
    (match observed with
     | Some (Remote.Execution_observed _) -> ()
     | Some (Remote.Execution_unavailable _) | None ->
       fail "the shim's receipt was not observed")
  | outcome, _ -> fail (describe outcome)

let test_a_probe_reads_the_shim_through_the_agent () =
  with_proxy @@ fun endpoint ->
  match Remote.For_testing.run_probe endpoint with
  | Ok major -> check int "the shim's major" Exec_ssh_protocol.protocol_version
                  (Exec_ssh_protocol.int_of_major major)
  | Error detail -> fail detail

(* The shim stops the payload at the request's own budget. *)
let test_the_payload_budget_is_the_shims () =
  with_proxy @@ fun endpoint ->
  match run_request ~timeout_sec:1.0 endpoint [ "sleep"; "30" ] with
  | Masc_exec.Sandbox_target.Transport_failed
      { failure = Masc_exec.Sandbox_target.Payload_timed_out; _ }, _ -> ()
  | outcome, _ -> fail (describe outcome)

(* The real agent's hello (no root here) is refused, and no request reaches
   it. *)
let test_a_refused_agent_gets_no_request () =
  let { socket; root } = the_agent () in
  let marker = Filename.concat root "refused-ran" in
  with_eio @@ fun ~sw:_ ~net:_ ->
  (match run_request (endpoint ~host_socket:socket) [ "touch"; marker ] with
   | ( Masc_exec.Sandbox_target.Transport_failed
         { failure = Masc_exec.Sandbox_target.Lane_unavailable; reason; _ }
     , Some (Remote.Execution_unavailable Remote.Request_not_sent) ) ->
     check bool "the reason says the agent was refused" true
       (let needle = "refused" in
        let rec at index =
          index + String.length needle <= String.length reason
          && (String.sub reason index (String.length needle) = needle || at (index + 1))
        in
        at 0)
   | outcome, _ -> fail (describe outcome));
  check bool "the request never ran" false (Sys.file_exists marker)

let test_an_unreachable_agent_gets_no_request () =
  with_temp_dir @@ fun dir ->
  with_eio @@ fun ~sw:_ ~net:_ ->
  let endpoint =
    Remote.of_agent_socket ~base_path:dir ~keeper_name:keeper ~remote_root:dir
      ~gh_config_dir:dir ~injected_env:[] ~env_allowlist:[] ~connect_timeout_sec:1
      ~max_concurrent_sessions:1 ~container_name:guest_name
      ~shim_path:"/opt/masc-exec-shim/masc-exec-shim"
      ~host_socket:(Filename.concat dir "absent.sock") ~expected
  in
  match run_request endpoint [ "true" ] with
  | ( Masc_exec.Sandbox_target.Transport_failed
        { failure = Masc_exec.Sandbox_target.Lane_unavailable; _ }
    , Some (Remote.Execution_unavailable Remote.Request_not_sent) ) -> ()
  | outcome, _ -> fail (describe outcome)

let test_an_agent_socket_guest_has_no_process_argv () =
  let endpoint = endpoint ~host_socket:"/nonexistent/guest.sock" in
  check (option (list string)) "no transport argv" None (Remote.transport_argv endpoint);
  check (option (list string)) "no probe argv" None (Remote.probe_argv endpoint);
  check string "the lane" "microvm_remote" (Remote.lane_prefix (Remote.transport endpoint));
  check string "named by its guest" guest_name (Remote.name endpoint)

let () =
  if Array.length Sys.argv <> 2 then failwith "expected the masc-exec-shim binary path";
  shim_binary := Unix.realpath Sys.argv.(1);
  (* The shim's main ignores SIGPIPE before it dispatches; the forked agent
     has to see the same, or a closed connection kills it. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let dir = Filename.temp_dir "masc-agent-socket-agent-" "" in
  let pid = start_agent dir in
  at_exit (fun () ->
    (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
    (try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ());
    remove_tree dir);
  run ~argv:[| Sys.argv.(0) |] "keeper sandbox remote agent socket"
    [ ( "agent socket"
      , [ test_case "a request runs through the agent" `Quick
            test_a_request_runs_through_the_agent
        ; test_case "a probe reads the shim through the agent" `Quick
            test_a_probe_reads_the_shim_through_the_agent
        ; test_case "the payload budget is the shim's" `Quick
            test_the_payload_budget_is_the_shims
        ; test_case "a refused agent gets no request" `Quick
            test_a_refused_agent_gets_no_request
        ; test_case "an unreachable agent gets no request" `Quick
            test_an_unreachable_agent_gets_no_request
        ; test_case "an agent socket guest has no process argv" `Quick
            test_an_agent_socket_guest_has_no_process_argv
        ] )
    ]
