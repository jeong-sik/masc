(* Keeper_sandbox_remote's Agent_socket delivery: the runner and the probe
   reach the real agent relay and the real shim through the guest agent
   socket (RFC microvm-guest-agent-over-socket).

   The agent here runs without root as this test's own uid and gid, and the
   Keeper ids below are ones it cannot have, so the production check refuses
   its hello. One case relies on that refusal. The others put a proxy in
   front of the agent that replaces only the hello with one that has every
   fact the check wants; every byte after the hello is the real agent and the
   real shim, unless the case's proxy mode says it drops or cuts them. *)

open Alcotest
open Masc
module Relay = Exec_ssh_protocol.Relay
module Remote = Keeper_sandbox_remote

let shim_binary = ref ""
let keeper = "keeper-a"
let guest_name = "guest-a"

(* Ids the agent cannot report: it runs as this test's own uid and gid. *)
let expected = { Keeper_guest_socket.uid = Unix.geteuid () + 1; gid = Unix.getegid () + 1 }
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

let contains ~needle text =
  let rec at index =
    index + String.length needle <= String.length text
    && (String.sub text index (String.length needle) = needle || at (index + 1))
  in
  at 0

let forged_hello () : Relay.hello =
  { Relay.relay_version = Relay.version
  ; root_read_only = true
  ; uid = expected.Keeper_guest_socket.uid
  ; gid = expected.Keeper_guest_socket.gid
  ; no_new_privs = true
  }

let quietly f = try f () with Eio.Io _ | End_of_file -> ()

let read_exact flow count =
  let buffer = Cstruct.create count in
  Eio.Flow.read_exact flow buffer;
  Cstruct.to_string buffer

let drain flow =
  quietly (fun () -> Eio.Flow.copy flow (Eio.Flow.buffer_sink (Buffer.create 256)))

(* What the proxy does with one connection. *)
type proxy_mode =
  | Relay_all  (* the forged hello, then every byte both ways *)
  | Drop_answers  (* the request reaches the agent; no answer reaches the host *)
  | Close_after_request  (* no agent: the connection closes once the request starts *)
  | Late_hello of { silent_connections : int }
      (* the first connections get no word at all; the next is [Relay_all] *)

let send_forged_hello client =
  Eio.Flow.copy_string (Relay.encode (Relay.Hello (forged_hello ()))) client

let skip_hello upstream =
  let header = read_exact upstream 5 in
  ignore (read_exact upstream (Int32.to_int (String.get_int32_be header 1)) : string)

(* When the host closes, the agent's end closes too: that is how the agent
   learns the host left. *)
let relay ~net ~agent_socket ~answers client =
  Eio.Switch.run
  @@ fun connection ->
  let upstream = Eio.Net.connect ~sw:connection net (`Unix agent_socket) in
  skip_hello upstream;
  send_forged_hello client;
  Eio.Fiber.both
    (fun () ->
      quietly (fun () -> Eio.Flow.copy client upstream);
      quietly (fun () -> Eio.Flow.shutdown upstream `Send))
    (fun () -> answers upstream client)

let relay_answers upstream client =
  quietly (fun () -> Eio.Flow.copy upstream client);
  quietly (fun () -> Eio.Flow.shutdown client `Send)

let drop_answers upstream _client = drain upstream

let serve ~net ~agent_socket mode index client =
  match mode with
  | Relay_all -> relay ~net ~agent_socket ~answers:relay_answers client
  | Drop_answers -> relay ~net ~agent_socket ~answers:drop_answers client
  | Close_after_request ->
    send_forged_hello client;
    quietly (fun () -> ignore (read_exact client 1 : string))
  | Late_hello { silent_connections } ->
    if index < silent_connections
    then drain client
    else relay ~net ~agent_socket ~answers:relay_answers client

(* Each connection is closed when its handler returns. *)
let proxy ~sw ~net ~agent_socket ~mode socket =
  let listening = Eio.Net.listen ~sw ~backlog:8 net (`Unix socket) in
  let accepted = ref 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      Eio.Net.accept_fork ~sw listening ~on_error:ignore (fun client _ ->
        let index = !accepted in
        incr accepted;
        serve ~net ~agent_socket mode index client);
      loop ()
    in
    loop ());
  fun () -> !accepted

let endpoint ?(connect_timeout_sec = connect_timeout_sec) ?(expected = expected) ~host_socket () =
  let { root; _ } = the_agent () in
  Remote.of_agent_socket ~base_path:root ~keeper_name:keeper ~remote_root:root
    ~gh_config_dir:(Filename.concat (Filename.concat root keeper) ".config/gh")
    ~injected_env:[] ~env_allowlist:[] ~connect_timeout_sec ~max_concurrent_sessions:2
    ~container_name:guest_name ~shim_path:"/opt/masc-exec-shim/masc-exec-shim" ~host_socket
    ~expected

let with_eio f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
    (fun () -> f ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env))

type session =
  { endpoint : Remote.t
  ; now : unit -> float
  ; sleep : float -> unit
  ; connections : unit -> int  (* connections the proxy accepted *)
  }

let with_proxy ?(mode = Relay_all) ?connect_timeout_sec f =
  let { socket = agent_socket; _ } = the_agent () in
  with_temp_dir
  @@ fun dir ->
  let host_socket = Filename.concat dir "proxy.sock" in
  with_eio
  @@ fun ~sw ~net ~clock ->
  let connections = proxy ~sw ~net ~agent_socket ~mode host_socket in
  f
    { endpoint = endpoint ?connect_timeout_sec ~host_socket ()
    ; now = (fun () -> Eio.Time.now clock)
    ; sleep = Eio.Time.sleep clock
    ; connections
    }

let wait_until session ~seconds ready =
  let deadline = session.now () +. seconds in
  let rec loop () =
    ready ()
    || (session.now () < deadline
        &&
        (session.sleep 0.05;
         loop ()))
  in
  loop ()

let alive pid =
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false

let run_request ?(timeout_sec = timeout_sec) ?on_stdout_chunk ?on_stderr_chunk endpoint argv =
  let observed = ref None in
  let run =
    Remote.runner ~on_receipt:(fun observation -> observed := Some observation) ~timeout_sec
      endpoint
  in
  let outcome =
    run ~on_stdout_chunk ~on_stderr_chunk ~stdin_content:None ~argv ~env:[||] ~cwd:None
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

let test_a_request_runs_through_the_agent () =
  with_proxy
  @@ fun session ->
  let streamed_stdout = Buffer.create 16
  and streamed_stderr = Buffer.create 16 in
  match
    run_request ~on_stdout_chunk:(Buffer.add_string streamed_stdout)
      ~on_stderr_chunk:(Buffer.add_string streamed_stderr) session.endpoint
      [ "sh"; "-c"; "echo out; echo err >&2; exit 3" ]
  with
  | Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 3; stdout; stderr; _ }, observed ->
    check string "stdout" "out\n" stdout;
    check string "stderr, without the acceptance frame and the trailer" "err\n" stderr;
    check string "stdout streamed" "out\n" (Buffer.contents streamed_stdout);
    check string "stderr streamed, without the acceptance frame and the trailer" "err\n"
      (Buffer.contents streamed_stderr);
    (match observed with
     | Some (Remote.Execution_observed _) -> ()
     | Some (Remote.Execution_unavailable _) | None ->
       fail "the shim's receipt was not observed")
  | outcome, _ -> fail (describe outcome)

let test_a_probe_reads_the_shim_through_the_agent () =
  with_proxy
  @@ fun session ->
  match Remote.For_testing.run_probe session.endpoint with
  | Ok major ->
    check int "the shim's major" Exec_ssh_protocol.protocol_version
      (Exec_ssh_protocol.int_of_major major)
  | Error detail -> fail detail

(* The shim stops the payload at the request's own budget. *)
let test_the_payload_budget_is_the_shims () =
  with_proxy
  @@ fun session ->
  match run_request ~timeout_sec:1.0 session.endpoint [ "sleep"; "30" ] with
  | ( Masc_exec.Sandbox_target.Transport_failed
        { failure = Masc_exec.Sandbox_target.Payload_timed_out; _ }
    , _ ) -> ()
  | outcome, _ -> fail (describe outcome)

(* Four connections get no hello, so the hello comes about 4.4 s into the
   5 s connect budget. The request still has its own budget and the shim's
   margin after it, so the shim, not the host, stops the payload. *)
let test_a_late_hello_leaves_the_request_its_budget () =
  with_proxy ~mode:(Late_hello { silent_connections = 4 })
  @@ fun session ->
  (match run_request ~timeout_sec:1.0 session.endpoint [ "sleep"; "30" ] with
   | ( Masc_exec.Sandbox_target.Transport_failed
         { failure = Masc_exec.Sandbox_target.Payload_timed_out; _ }
     , _ ) -> ()
   | outcome, _ -> fail (describe outcome));
  check int "the hello came on the fifth connection" 5 (session.connections ())

(* No answer reaches the host, so its own budget (connect + T + 4 s) ends the
   request: a stalled lane, not a payload timeout. *)
let test_a_request_with_no_answer_ends_at_the_host_budget () =
  with_proxy ~mode:Drop_answers ~connect_timeout_sec:1
  @@ fun session ->
  match run_request ~timeout_sec:1.0 session.endpoint [ "true" ] with
  | ( Masc_exec.Sandbox_target.Transport_failed
        { failure = Masc_exec.Sandbox_target.Lane_unavailable; reason; _ }
    , Some (Remote.Execution_unavailable (Remote.Transport_unavailable _)) ) ->
    check bool "the host's own timeout" true (contains ~needle:"local_timeout" reason)
  | outcome, _ -> fail (describe outcome)

(* The connection ends after the request started going out and before an
   exit chunk. The request may have started, so it is not "not sent". *)
let test_a_connection_cut_after_the_request_is_a_transport_failure () =
  with_proxy ~mode:Close_after_request
  @@ fun session ->
  match run_request session.endpoint [ "true" ] with
  | ( Masc_exec.Sandbox_target.Transport_failed
        { failure = Masc_exec.Sandbox_target.Lane_unavailable; reason; _ }
    , Some (Remote.Execution_unavailable (Remote.Transport_unavailable _)) ) ->
    check bool "not the host's timeout" false (contains ~needle:"local_timeout" reason)
  | outcome, _ -> fail (describe outcome)

(* Cancelling the request's fiber closes its connection; the agent closes the
   shim's stdin and the shim stops the payload. *)
let test_a_cancelled_request_stops_its_payload () =
  let { root; _ } = the_agent () in
  let pid_file = Filename.concat (Filename.concat root keeper) "cancelled-payload.pid" in
  with_proxy
  @@ fun session ->
  let payload_pid () =
    match In_channel.with_open_bin pid_file In_channel.input_all with
    | text -> int_of_string_opt (String.trim text)
    | exception Sys_error _ -> None
  in
  Eio.Fiber.first
    (fun () ->
      ignore
        (run_request ~timeout_sec:30.0 session.endpoint
           [ "sh"; "-c"; Printf.sprintf "echo $$ > %s; exec sleep 30" (Filename.quote pid_file) ]))
    (fun () ->
      ignore (wait_until session ~seconds:10.0 (fun () -> Option.is_some (payload_pid ()))));
  match payload_pid () with
  | None -> fail "the payload never wrote its pid"
  | Some pid ->
    check bool "the payload stopped" true
      (wait_until session ~seconds:10.0 (fun () -> not (alive pid)))

(* The real agent's hello is refused, and no request reaches it. *)
let test_a_refused_agent_gets_no_request () =
  let { socket; root } = the_agent () in
  let marker = Filename.concat root "refused-ran" in
  with_eio (fun ~sw:_ ~net:_ ~clock:_ ->
    match run_request (endpoint ~host_socket:socket ()) [ "touch"; marker ] with
    | ( Masc_exec.Sandbox_target.Transport_failed
          { failure = Masc_exec.Sandbox_target.Lane_unavailable; reason; _ }
      , Some (Remote.Execution_unavailable Remote.Request_not_sent) ) ->
      check bool "the reason says the agent was refused" true (contains ~needle:"refused" reason)
    | outcome, _ -> fail (describe outcome));
  check bool "the request never ran" false (Sys.file_exists marker)

let test_an_unreachable_agent_gets_no_request () =
  with_temp_dir
  @@ fun dir ->
  with_eio
  @@ fun ~sw:_ ~net:_ ~clock:_ ->
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

(* Outside Eio there is no network or clock to reach an agent with. *)
let test_a_probe_outside_eio_reaches_no_agent () =
  let { socket; _ } = the_agent () in
  match Remote.For_testing.run_probe (endpoint ~host_socket:socket ()) with
  | Ok _ -> fail "a probe outside Eio reached the agent"
  | Error detail -> check bool "the reason names Eio" true (contains ~needle:"Eio fiber" detail)

let test_an_agent_socket_guest_is_carried_by_its_agent () =
  let endpoint = endpoint ~host_socket:"/nonexistent/guest.sock" () in
  (match Remote.carrier endpoint with
   | Remote.Guest_agent { host_socket; expected = owner } ->
     check string "the host socket" "/nonexistent/guest.sock" host_socket;
     check (pair int int) "the owner its hello must report"
       (expected.Keeper_guest_socket.uid, expected.Keeper_guest_socket.gid)
       (owner.Keeper_guest_socket.uid, owner.Keeper_guest_socket.gid)
   | Remote.Local_process _ -> fail "an agent socket guest has no local process");
  check string "the lane" "microvm_remote" (Remote.lane_prefix (Remote.transport endpoint));
  check string "named by its guest" guest_name (Remote.name endpoint)

(* A route names the agent's socket and owner, so a captured read authority
   does not outlive a change of either. *)
let test_a_route_names_the_agent_socket_and_owner () =
  let route ?expected host_socket =
    Yojson.Safe.to_string
      (Keeper_sandbox_remote_lane.microvm_endpoint_route (endpoint ?expected ~host_socket ()))
  in
  let other_owner =
    { Keeper_guest_socket.uid = expected.Keeper_guest_socket.uid + 1
    ; gid = expected.Keeper_guest_socket.gid
    }
  in
  check bool "another socket is another route" false
    (String.equal (route "/guest-a.sock") (route "/guest-b.sock"));
  check bool "another owner is another route" false
    (String.equal (route "/guest-a.sock") (route ~expected:other_owner "/guest-a.sock"))

let () =
  if Array.length Sys.argv <> 2 then failwith "expected the masc-exec-shim binary path";
  shim_binary := Unix.realpath Sys.argv.(1);
  (* The shim's main ignores SIGPIPE before it dispatches; the forked agent
     and the proxy have to see the same, or a closed connection kills them. *)
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
        ; test_case "a late hello leaves the request its budget" `Quick
            test_a_late_hello_leaves_the_request_its_budget
        ; test_case "a request with no answer ends at the host budget" `Quick
            test_a_request_with_no_answer_ends_at_the_host_budget
        ; test_case "a connection cut after the request is a transport failure" `Quick
            test_a_connection_cut_after_the_request_is_a_transport_failure
        ; test_case "a cancelled request stops its payload" `Quick
            test_a_cancelled_request_stops_its_payload
        ; test_case "a refused agent gets no request" `Quick
            test_a_refused_agent_gets_no_request
        ; test_case "an unreachable agent gets no request" `Quick
            test_an_unreachable_agent_gets_no_request
        ; test_case "a probe outside Eio reaches no agent" `Quick
            test_a_probe_outside_eio_reaches_no_agent
        ; test_case "an agent socket guest is carried by its agent" `Quick
            test_an_agent_socket_guest_is_carried_by_its_agent
        ; test_case "a route names the agent socket and owner" `Quick
            test_a_route_names_the_agent_socket_and_owner
        ] )
    ]
