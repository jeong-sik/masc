(* Keeper_guest_socket against the real agent relay and the real shim, and
   against small listeners that act out what a VM runtime does before the
   agent listens: end the connection at once, or accept it and say nothing.

   The agent here runs without root, so its hello reports this test host's
   facts; the success cases pass an [accept] that checks the relay version
   only, and one case checks that the production check refuses such an agent
   before anything is written. *)

open Alcotest
open Masc
module Relay = Exec_ssh_protocol.Relay
module Guest = Keeper_guest_socket

let shim_binary = ref ""
let budget_sec = 20.0
let connect_budget_sec = 5.0

(* The forked agent relay every real-shim case talks to, made before any Eio
   loop starts. *)
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
  let dir = Filename.temp_dir "masc-guest-socket-" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let start_agent dir =
  let root = Filename.concat dir "root" in
  Unix.mkdir root 0o755;
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

(* The real agent runs as this test's user, so only its source is checked. *)
let source_only (hello : Relay.hello) =
  let refused () =
    Some
      (Guest.Other_source
         { server = Source_identity.current
         ; agent = hello.Relay.source_identity
         ; agent_relay = hello.Relay.relay_version
         }) in
  match Source_identity.current, hello.Relay.source_identity with
  | Some server, Some agent -> if Source_identity.equal server agent then None else refused ()
  | Some _, None | None, (Some _ | None) -> refused ()

(* A source this test build is not: no git object name is all zeros. *)
let other_source = { Source_identity.commit = String.make 40 '0'; state = Source_identity.Clean }

let frame ~root argv =
  match
    Exec_ssh_protocol.encode_request
      { Exec_ssh_protocol.v = Exec_ssh_protocol.V3
      ; argv
      ; env = []
      ; cwd = root
      ; remote_root = root
      ; timeout_sec = budget_sec
      ; stdin = Exec_ssh_protocol.Framed 0L
      ; mode = Exec_ssh_protocol.Effect
      ; acceptance_frame = true
      }
      ~stdin:""
  with
  | Ok frame -> frame
  | Error message -> fail message

let with_eio f =
  Eio_main.run @@ fun env -> f ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)

(* A client that waited for a hello forever would hang its test; this turns
   that into a failure. *)
let within ~clock seconds f =
  match Eio.Time.with_timeout clock seconds (fun () -> Ok (f ())) with
  | Ok value -> value
  | Error `Timeout -> failf "no outcome within %.0fs" seconds

let describe = function
  | Guest.Not_sent (Guest.Unreachable { attempts; last }) ->
    Printf.sprintf "unreachable after %d attempts: %s" attempts last
  | Guest.Not_sent (Guest.Refused refusal) -> "refused: " ^ Guest.refusal_to_string refusal
  | Guest.Not_sent (Guest.Incompatible detail) -> "incompatible: " ^ detail
  | Guest.Not_sent (Guest.Bad_budget { connect_budget_sec; budget_sec }) ->
    Printf.sprintf "bad budget: %g / %g" connect_budget_sec budget_sec
  | Guest.Exited { code; _ } -> Printf.sprintf "exited %d" code
  | Guest.Timed_out _ -> "timed out"
  | Guest.Broken { reason; _ } -> "broken: " ^ reason

let hello ?(source_identity = Source_identity.current) ?(root_read_only = true) ?(uid = 502)
      ?(gid = 20) ?(no_new_privs = true) () : Relay.hello =
  { Relay.relay_version = Relay.version; source_identity; root_read_only; uid; gid; no_new_privs }

let contains ~needle haystack =
  let needle_length = String.length needle in
  let rec at index =
    index + needle_length <= String.length haystack
    && (String.sub haystack index needle_length = needle || at (index + 1))
  in
  at 0

(* /dev/fd is this process's open descriptors on Linux and macOS. *)
let open_descriptors () = Array.length (Sys.readdir "/dev/fd")

(* A fake agent: each connection is served by [serve], and [served] resolves
   when the first one is done. *)
let fake_agent ~sw ~net socket serve =
  let served, resolve = Eio.Promise.create () in
  let listening = Eio.Net.listen ~sw ~backlog:8 net (`Unix socket) in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop first =
      let client, _ = Eio.Net.accept ~sw listening in
      Eio.Fiber.fork ~sw (fun () ->
        (try serve client with Eio.Io _ | End_of_file -> ());
        Eio.Flow.close client;
        if first then Eio.Promise.resolve resolve ());
      loop false
    in
    loop true);
  served

let good_hello () = Relay.encode (Relay.Hello (hello ()))

(* Reads until the client has started its request. *)
let await_request client =
  ignore (Eio.Flow.single_read client (Cstruct.create 64) : int)

let test_refusal_checks_every_fact () =
  let expected = { Guest.uid = 502; gid = 20 } in
  let refusal = Guest.refusal ~expected in
  check bool "a hello with every fact accepted" true (refusal (hello ()) = None);
  List.iter
    (fun (label, hello, want) ->
       check bool label true (refusal hello = Some want))
    [ "another source", hello ~source_identity:(Some other_source) (),
      Guest.Other_source
        { server = Source_identity.current; agent = Some other_source; agent_relay = Relay.version }
    ; "no source", hello ~source_identity:None (),
      Guest.Other_source
        { server = Source_identity.current; agent = None; agent_relay = Relay.version }
    ; "a writable root", hello ~root_read_only:false (), Guest.Root_writable
    ; "another uid", hello ~uid:501 (), Guest.Other_owner { uid = 501; gid = 20 }
    ; "another gid", hello ~gid:0 (), Guest.Other_owner { uid = 502; gid = 0 }
    ; "no no_new_privs", hello ~no_new_privs:false (), Guest.New_privileges_allowed
    ; "the source is read first",
      hello ~source_identity:(Some other_source) ~root_read_only:false ~uid:0
        ~no_new_privs:false (),
      Guest.Other_source
        { server = Source_identity.current; agent = Some other_source; agent_relay = Relay.version } ]

let test_run_reaches_the_real_shim () =
  let { socket; root } = the_agent () in
  let streamed_out = Buffer.create 64 and streamed_err = Buffer.create 64 in
  with_eio @@ fun ~net ~clock ->
  match
    Guest.run ~net ~clock ~on_stdout_chunk:(Buffer.add_string streamed_out)
      ~on_stderr_chunk:(Buffer.add_string streamed_err) ~accept:source_only ~socket
      ~connect_budget_sec ~budget_sec
      (Guest.Run { frame = frame ~root [ "sh"; "-c"; "echo out; echo err >&2; exit 3" ] })
  with
  | Guest.Exited { code; stdout; stderr } ->
    check int "the shim's own exit" 0 code;
    check string "stdout" "out\n" stdout;
    check string "stdout chunks add up to the outcome" stdout (Buffer.contents streamed_out);
    check string "stderr chunks add up to the outcome" stderr (Buffer.contents streamed_err);
    (match Exec_ssh_protocol.split_acceptance_head stderr with
     | Exec_ssh_protocol.Head_frame { rest; _ } ->
       check bool "the payload's stderr follows the acceptance frame" true
         (String.length rest >= 4 && String.sub rest 0 4 = "err\n")
     | Exec_ssh_protocol.Head_pending | Exec_ssh_protocol.Head_payload ->
       fail "no acceptance frame at the front of stderr");
    (match Exec_ssh_protocol.parse_trailer stderr with
     | Ok trailer -> check (option int) "the payload's exit" (Some 3) trailer.Exec_ssh_protocol.exit
     | Error message -> fail message)
  | outcome -> fail (describe outcome)

let test_probe_reaches_the_real_shim () =
  let { socket; _ } = the_agent () in
  with_eio @@ fun ~net ~clock ->
  match
    Guest.run ~net ~clock ~accept:source_only ~socket ~connect_budget_sec ~budget_sec
      Guest.Probe
  with
  | Guest.Exited { code = 0; stdout; _ } ->
    (match Exec_ssh_protocol.parse_probe (String.trim stdout) with
     | Ok probe -> check string "the probe names the shim" "masc-exec-shim" probe.Exec_ssh_protocol.name
     | Error message -> fail message)
  | outcome -> fail (describe outcome)

(* The production check refuses this agent (no root, so no read-only root and
   no no_new_privs), and refuses it before the request is written. *)
let test_a_refused_agent_gets_nothing () =
  let { socket; root } = the_agent () in
  let marker = Filename.concat root "refused-ran" in
  with_eio @@ fun ~net ~clock ->
  (match
     Guest.run ~net ~clock
       ~accept:(Guest.refusal ~expected:{ Guest.uid = Unix.geteuid (); gid = Unix.getegid () })
       ~socket ~connect_budget_sec ~budget_sec
       (Guest.Run { frame = frame ~root [ "sh"; "-c"; "touch " ^ Filename.quote marker ] })
   with
   | Guest.Not_sent (Guest.Refused _) -> ()
   | outcome -> fail (describe outcome));
  Eio.Time.sleep clock 0.5;
  check bool "the request never ran" false (Sys.file_exists marker)

(* The budget closes the connection, and closing it cancels the payload. *)
let test_a_spent_budget_cancels_the_payload () =
  let { socket; root } = the_agent () in
  let pid_file = Filename.concat root "slow-pid" in
  with_eio @@ fun ~net ~clock ->
  let started = Eio.Time.now clock in
  (match
     Guest.run ~net ~clock ~accept:source_only ~socket ~connect_budget_sec ~budget_sec:3.0
       (Guest.Run
          { frame =
              frame ~root
                [ "sh"; "-c"; Printf.sprintf "echo $$ > %s; sleep 30" (Filename.quote pid_file) ]
          })
   with
   | Guest.Timed_out _ -> ()
   | outcome -> fail (describe outcome));
  check bool "the call ends near its budget" true (Eio.Time.now clock -. started < 6.0);
  let pid = int_of_string (String.trim (In_channel.with_open_bin pid_file In_channel.input_all)) in
  (* The shim's cancel is SIGTERM, a 2-second grace, then SIGKILL. *)
  let rec gone tries =
    match Unix.kill pid 0 with
    | () when tries > 0 ->
      Eio.Time.sleep clock 0.25;
      gone (tries - 1)
    | () -> false
    | exception Unix.Unix_error (Unix.ESRCH, _, _) -> true
  in
  check bool "the payload was stopped" true (gone 40)

let test_no_listener_is_unreachable () =
  with_temp_dir @@ fun dir ->
  with_eio @@ fun ~net ~clock ->
  match
    Guest.run ~net ~clock ~accept:source_only ~socket:(Filename.concat dir "absent.sock")
      ~connect_budget_sec:1.0 ~budget_sec
      (Guest.Run { frame = "unused" })
  with
  | Guest.Not_sent (Guest.Unreachable { attempts; _ }) ->
    check bool "it kept trying until the connect budget" true (attempts >= 2)
  | outcome -> fail (describe outcome)

(* A runtime that accepted the connection before the agent listened, and
   never answers. *)
let test_a_silent_connection_is_replaced () =
  with_temp_dir @@ fun dir ->
  let socket = Filename.concat dir "silent.sock" in
  with_eio @@ fun ~net ~clock ->
  Eio.Switch.run @@ fun sw ->
  let listening = Eio.Net.listen ~sw ~backlog:8 net (`Unix socket) in
  let accepted = ref 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec hold () =
      let _flow, _ = Eio.Net.accept ~sw listening in
      incr accepted;
      hold ()
    in
    hold ());
  let started = Eio.Time.now clock in
  (match
     within ~clock 10.0 (fun () ->
       Guest.run ~net ~clock ~accept:source_only ~socket ~connect_budget_sec:2.5 ~budget_sec
         (Guest.Run { frame = "unused" }))
   with
   | Guest.Not_sent (Guest.Unreachable { attempts; _ }) ->
     check bool "a new connection replaced each silent one" true (attempts >= 2)
   | outcome -> fail (describe outcome));
  check bool "it gave up at the connect budget" true (Eio.Time.now clock -. started < 4.0);
  check bool "every attempt reached the listener" true (!accepted >= 2)

(* A runtime that ends the first two connections at once, then reaches the
   agent: the request still goes out, once. *)
let test_ended_connections_are_replaced () =
  let { socket = agent_socket; root } = the_agent () in
  with_temp_dir @@ fun dir ->
  let socket = Filename.concat dir "booting.sock" in
  let counter = Filename.concat root "runs" in
  with_eio @@ fun ~net ~clock ->
  Eio.Switch.run @@ fun sw ->
  let listening = Eio.Net.listen ~sw ~backlog:8 net (`Unix socket) in
  let accepted = ref 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec serve () =
      let client, _ = Eio.Net.accept ~sw listening in
      incr accepted;
      if !accepted <= 2
      then Eio.Flow.close client
      else
        Eio.Fiber.fork ~sw (fun () ->
          let upstream = Eio.Net.connect ~sw net (`Unix agent_socket) in
          Eio.Fiber.both
            (fun () -> try Eio.Flow.copy client upstream with Eio.Io _ -> ())
            (fun () ->
              (try Eio.Flow.copy upstream client with Eio.Io _ -> ());
              Eio.Flow.close client));
      serve ()
    in
    serve ());
  (match
     within ~clock budget_sec (fun () ->
       Guest.run ~net ~clock ~accept:source_only ~socket ~connect_budget_sec ~budget_sec
         (Guest.Run
            { frame = frame ~root [ "sh"; "-c"; "echo ran >> " ^ Filename.quote counter ] }))
   with
   | Guest.Exited { code = 0; _ } -> ()
   | outcome -> fail (describe outcome));
  check int "three connections" 3 !accepted;
  check string "the request ran once" "ran\n" (In_channel.with_open_bin counter In_channel.input_all)

(* An agent that says hello, takes the request and goes away. *)
let test_an_agent_that_leaves_is_broken () =
  with_temp_dir @@ fun dir ->
  let socket = Filename.concat dir "leaving.sock" in
  with_eio @@ fun ~net ~clock ->
  Eio.Switch.run @@ fun sw ->
  let listening = Eio.Net.listen ~sw ~backlog:8 net (`Unix socket) in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let client, _ = Eio.Net.accept ~sw listening in
    Eio.Flow.copy_string (Relay.encode (Relay.Hello (hello ()))) client;
    let buffer = Cstruct.create 16 in
    ignore (Eio.Flow.single_read client buffer : int);
    Eio.Flow.close client;
    `Stop_daemon);
  match
    Guest.run ~net ~clock ~accept:source_only ~socket ~connect_budget_sec ~budget_sec
      (Guest.Run { frame = "a request" })
  with
  | Guest.Broken _ -> ()
  | outcome -> fail (describe outcome)

(* Failed connections are closed as they fail, not when the call ends. *)
let test_failed_connections_hold_no_descriptor () =
  with_temp_dir @@ fun dir ->
  with_eio @@ fun ~net ~clock ->
  let before = open_descriptors () in
  let during = ref before in
  Eio.Fiber.both
    (fun () ->
      match
        Guest.run ~net ~clock ~accept:source_only ~socket:(Filename.concat dir "absent.sock")
          ~connect_budget_sec:1.5 ~budget_sec (Guest.Run { frame = "unused" })
      with
      | Guest.Not_sent (Guest.Unreachable { attempts; _ }) ->
        check bool "it retried" true (attempts >= 5)
      | outcome -> fail (describe outcome))
    (fun () ->
      Eio.Time.sleep clock 1.2;
      during := open_descriptors ());
  check bool
    (Printf.sprintf "descriptors while it retried: %d before, %d during" before !during)
    true (!during <= before + 2)

let test_a_refused_agent_receives_no_byte () =
  with_temp_dir @@ fun dir ->
  let socket = Filename.concat dir "refusing.sock" in
  with_eio @@ fun ~net ~clock ->
  Eio.Switch.run @@ fun sw ->
  let received = Buffer.create 16 in
  let served =
    fake_agent ~sw ~net socket (fun client ->
      Eio.Flow.copy_string (Relay.encode (Relay.Hello (hello ~root_read_only:false ()))) client;
      Eio.Flow.copy client (Eio.Flow.buffer_sink received))
  in
  (match
     Guest.run ~net ~clock ~accept:(Guest.refusal ~expected:{ Guest.uid = 502; gid = 20 })
       ~socket ~connect_budget_sec ~budget_sec (Guest.Run { frame = "a request" })
   with
   | Guest.Not_sent (Guest.Refused Guest.Root_writable) -> ()
   | outcome -> fail (describe outcome));
  Eio.Promise.await served;
  check int "bytes the refused agent received" 0 (Buffer.length received)

let incompatible_first_chunk ~label first_chunk () =
  with_temp_dir @@ fun dir ->
  let socket = Filename.concat dir "odd.sock" in
  with_eio @@ fun ~net ~clock ->
  Eio.Switch.run @@ fun sw ->
  let (_ : unit Eio.Promise.t) =
    fake_agent ~sw ~net socket (fun client ->
      Eio.Flow.copy_string first_chunk client;
      await_request client)
  in
  let started = Eio.Time.now clock in
  (match
     Guest.run ~net ~clock ~accept:source_only ~socket ~connect_budget_sec ~budget_sec
       (Guest.Run { frame = "a request" })
   with
   | Guest.Not_sent (Guest.Incompatible _) -> ()
   | outcome -> fail (label ^ ": " ^ describe outcome));
  check bool (label ^ " is not retried until the connect budget") true
    (Eio.Time.now clock -. started < connect_budget_sec /. 2.)

let test_an_undecodable_hello_is_incompatible =
  incompatible_first_chunk ~label:"an undecodable hello" "\001\000\000\000\002{]"

let test_a_first_chunk_that_is_no_hello_is_incompatible =
  incompatible_first_chunk ~label:"a first chunk that is no hello"
    (Relay.encode (Relay.Stdout "output"))

(* A fake agent that says hello, waits for the request, then sends [rest]. *)
let answered_by ~rest =
  with_temp_dir @@ fun dir ->
  let socket = Filename.concat dir "scripted.sock" in
  with_eio @@ fun ~net ~clock ->
  Eio.Switch.run @@ fun sw ->
  let (_ : unit Eio.Promise.t) =
    fake_agent ~sw ~net socket (fun client ->
      Eio.Flow.copy_string (good_hello ()) client;
      await_request client;
      rest ~clock client)
  in
  Guest.run ~net ~clock ~accept:source_only ~socket ~connect_budget_sec ~budget_sec
    (Guest.Run { frame = "a request" })

let test_a_signalled_shim_is_broken () =
  match
    answered_by ~rest:(fun ~clock:_ client ->
      Eio.Flow.copy_string (Relay.encode (Relay.Exit (Relay.Signaled 9))) client)
  with
  | Guest.Broken { reason; _ } ->
    check bool "the reason names the signal" true (contains ~needle:"signal 9" reason)
  | outcome -> fail (describe outcome)

let test_a_second_hello_is_broken () =
  match
    answered_by ~rest:(fun ~clock:_ client -> Eio.Flow.copy_string (good_hello ()) client)
  with
  | Guest.Broken { reason; _ } -> check string "the reason" "a second hello" reason
  | outcome -> fail (describe outcome)

let test_a_hello_split_across_reads_is_read () =
  with_temp_dir @@ fun dir ->
  let socket = Filename.concat dir "slow.sock" in
  with_eio @@ fun ~net ~clock ->
  Eio.Switch.run @@ fun sw ->
  let (_ : unit Eio.Promise.t) =
    fake_agent ~sw ~net socket (fun client ->
      let hello = good_hello () in
      Eio.Flow.copy_string (String.sub hello 0 3) client;
      Eio.Time.sleep clock 0.2;
      Eio.Flow.copy_string (String.sub hello 3 (String.length hello - 3)) client;
      await_request client;
      Eio.Flow.copy_string (Relay.encode (Relay.Exit (Relay.Exited 0))) client)
  in
  match
    Guest.run ~net ~clock ~accept:source_only ~socket ~connect_budget_sec ~budget_sec
      (Guest.Run { frame = "a request" })
  with
  | Guest.Exited { code = 0; _ } -> ()
  | outcome -> fail (describe outcome)

(* The outcome keeps a local process's bound; the callbacks see every byte. *)
let test_output_is_bounded_and_streamed_whole () =
  let total = Common.max_process_capture_head_bytes + (4 * Common.max_process_capture_tail_bytes) in
  let streamed = ref 0 in
  with_temp_dir @@ fun dir ->
  let socket = Filename.concat dir "chatty.sock" in
  with_eio @@ fun ~net ~clock ->
  Eio.Switch.run @@ fun sw ->
  let (_ : unit Eio.Promise.t) =
    fake_agent ~sw ~net socket (fun client ->
      Eio.Flow.copy_string (good_hello ()) client;
      await_request client;
      let piece = String.make Relay.max_payload_bytes 'x' in
      let rec send left =
        if left > 0
        then (
          let size = min left Relay.max_payload_bytes in
          Eio.Flow.copy_string (Relay.encode (Relay.Stdout (String.sub piece 0 size))) client;
          send (left - size))
      in
      send total;
      Eio.Flow.copy_string (Relay.encode (Relay.Exit (Relay.Exited 0))) client)
  in
  match
    Guest.run ~net ~clock ~on_stdout_chunk:(fun bytes -> streamed := !streamed + String.length bytes)
      ~accept:source_only ~socket ~connect_budget_sec ~budget_sec
      (Guest.Run { frame = "a request" })
  with
  | Guest.Exited { code = 0; stdout; _ } ->
    check int "every byte reached the callback" total !streamed;
    check bool "the outcome is bounded" true
      (String.length stdout
       <= Exec_buffer.max_render_bytes
            ~head_cap:Common.max_process_capture_head_bytes
            ~tail_cap:Common.max_process_capture_tail_bytes);
    check bool "the elided middle is marked" true (contains ~needle:"truncated" stdout)
  | outcome -> fail (describe outcome)

let test_a_budget_that_is_not_a_number_tries_nothing () =
  with_temp_dir @@ fun dir ->
  with_eio @@ fun ~net ~clock ->
  match
    Guest.run ~net ~clock ~accept:source_only ~socket:(Filename.concat dir "any.sock")
      ~connect_budget_sec ~budget_sec:Float.nan (Guest.Run { frame = "unused" })
  with
  | Guest.Not_sent (Guest.Bad_budget _) -> ()
  | outcome -> fail (describe outcome)

(* These peers script hello/exit facts to exercise the host boundary. They
   do not prove a mounted read-only guest or a deployed VM. *)
let interactive_frame () =
  match Exec_ssh_protocol.encode_request
      { Exec_ssh_protocol.v = V3; argv = ["/bin/cat"]; env = [];
        cwd = "/work"; remote_root = "/work"; timeout_sec = 10.;
        stdin = Interactive; mode = Effect; acceptance_frame = false }
      ~stdin:"" with
  | Ok bytes -> bytes
  | Error detail -> fail detail

let stdio_read input length =
  let bytes = Cstruct.create length in
  Eio.Flow.read_exact input bytes;
  Cstruct.to_string bytes

let read_interactive_request flow =
  check string "interactive request kind" "I" (stdio_read flow 1);
  let header = stdio_read flow 8 in
  let bytes = header ^ stdio_read flow (Int64.to_int (String.get_int64_be header 0)) in
  match Exec_ssh_protocol.decode_request bytes with
  | Ok (request, initial) ->
    check bool "version and input mode" true
      (request.v = Exec_ssh_protocol.V3 && request.stdin = Exec_ssh_protocol.Interactive);
    check string "no initial payload" "" initial
  | Error _ -> fail "host sent an invalid frame"

let stdio_call ~net ~clock ~socket ?(on_dispatch = fun () -> Ok ())
    ?(on_request_write = ignore) ?(on_stderr_chunk = ignore)
    ?(on_stdout_tail = ignore) ?(budget_sec = 5.) use =
  Guest.with_stdio ~net ~clock ~expected:{Guest.uid=502;gid=20} ~socket
    ~connect_budget_sec:1. ~budget_sec ~frame:(interactive_frame ())
    ~on_dispatch ~on_request_write ~on_stderr_chunk ~on_stdout_tail use

let test_stdio_checks_actual_hello_before_request () =
  List.iter (fun answer ->
    with_temp_dir @@ fun dir -> with_eio @@ fun ~net ~clock ->
    Eio.Switch.run @@ fun sw ->
    let socket = Filename.concat dir "refused.sock" in
    let got_byte = ref false and dispatched = ref false and wrote = ref false in
    let served = fake_agent ~sw ~net socket (fun peer ->
      Eio.Flow.copy_string (Relay.encode (Relay.Hello answer)) peer;
      match Eio.Flow.single_read peer (Cstruct.create 1) with
      | _ -> got_byte := true
      | exception End_of_file -> ()) in
    let result = stdio_call ~net ~clock ~socket
        ~on_dispatch:(fun () -> dispatched := true; Ok ())
        ~on_request_write:(fun () -> wrote := true)
        (fun ~input:_ ~output:_ -> fail "refused hello lent streams") in
    let refusal = match Guest.refusal ~expected:{Guest.uid=502;gid=20} answer with
      | Some refusal -> refusal
      | None -> fail "fixture hello must be refused" in
    check bool "actual hello refusal retained" true
      (result = Error (Guest.Transport_failed (Guest.Not_connected (Guest.Refused refusal))));
    Eio.Promise.await served;
    check bool "no request byte" false !got_byte;
    check bool "no owner dispatch" false !dispatched;
    check bool "no attempted write" false !wrote)
    [hello ~source_identity:None (); hello ~uid:501 (); hello ~root_read_only:false ()]

let test_stdio_decline_sends_no_request () =
  with_temp_dir @@ fun dir -> with_eio @@ fun ~net ~clock ->
  Eio.Switch.run @@ fun sw ->
  let socket = Filename.concat dir "declined.sock" in
  let wrote = ref false in
  let served = fake_agent ~sw ~net socket (fun peer ->
    Eio.Flow.copy_string (good_hello ()) peer;
    match Eio.Flow.single_read peer (Cstruct.create 1) with
    | _ -> fail "declined owner still sent bytes"
    | exception End_of_file -> ()) in
  let result = stdio_call ~net ~clock ~socket
      ~on_dispatch:(fun () -> Error `Declined)
      ~on_request_write:(fun () -> wrote := true)
      (fun ~input:_ ~output:_ -> fail "declined owner lent streams") in
  check bool "owner error retained" true (result = Error (Guest.Dispatch_declined `Declined));
  Eio.Promise.await served;
  check bool "write boundary was not crossed" false !wrote

let test_stdio_duplex_drains_after_send_shutdown () =
  with_temp_dir @@ fun dir -> with_eio @@ fun ~net ~clock ->
  Eio.Switch.run @@ fun sw ->
  let socket = Filename.concat dir "duplex.sock" in
  let sent = ref false and half_closed = ref false in
  let tail = Buffer.create 32 and stderr = Buffer.create 32 in
  let served = fake_agent ~sw ~net socket (fun peer ->
    let send chunk = Eio.Flow.copy_string (Relay.encode chunk) peer in
    Eio.Flow.copy_string (good_hello ()) peer;
    read_interactive_request peer;
    check bool "owner observed before first request write" true !sent;
    check string "dependent input one" "one\000" (stdio_read peer 4);
    send (Relay.Stdout "first\255");
    check string "dependent input two" "two\000" (stdio_read peer 4);
    send (Relay.Stdout "second");
    (match Eio.Flow.single_read peer (Cstruct.create 1) with
     | _ -> fail "callback returned but input did not end"
     | exception End_of_file -> half_closed := true);
    send (Relay.Stdout "unread\000tail");
    send (Relay.Stderr "stderr\255");
    send (Relay.Exit (Relay.Signaled 15))) in
  let result = stdio_call ~net ~clock ~socket
      ~on_request_write:(fun () -> sent := true)
      ~on_stdout_tail:(Buffer.add_string tail)
      ~on_stderr_chunk:(Buffer.add_string stderr)
      (fun ~input ~output ->
        Eio.Flow.copy_string "one\000" output;
        check string "first answer" "first\255" (stdio_read input 6);
        Eio.Flow.copy_string "two\000" output;
        check string "second answer" "second" (stdio_read input 6);
        2) in
  check bool "real relay status type retained" true
    (result = Ok (2, Relay.Signaled 15));
  Eio.Promise.await served;
  check bool "send side closed while output remained open" true !half_closed;
  check string "unread binary tail" "unread\000tail" (Buffer.contents tail);
  check string "separate stderr" "stderr\255" (Buffer.contents stderr)

let test_stdio_missing_exit_is_incomplete () =
  with_temp_dir @@ fun dir -> with_eio @@ fun ~net ~clock ->
  Eio.Switch.run @@ fun sw ->
  let socket = Filename.concat dir "incomplete.sock" in
  let (_ : unit Eio.Promise.t) = fake_agent ~sw ~net socket (fun peer ->
    Eio.Flow.copy_string (good_hello ()) peer;
    read_interactive_request peer;
    Eio.Flow.copy_string (Relay.encode (Relay.Stdout "ready")) peer;
    match Eio.Flow.single_read peer (Cstruct.create 1) with
    | _ -> fail "input should be closed"
    | exception End_of_file -> ()) in
  let result = stdio_call ~net ~clock ~socket (fun ~input ~output:_ ->
    check string "response before disconnect" "ready" (stdio_read input 5)) in
  check bool "missing Exit remains incomplete" true
    (result = Error (Guest.Transport_failed Guest.Ended_before_exit))

type Eio.Exn.err += Stdio_callback_io_failure
exception Stdio_cancel_requested

let observe_peer_close peer closed =
  match Eio.Flow.single_read peer (Cstruct.create 1) with
  | _ -> fail "unexpected input before the owned connection closed"
  | exception End_of_file -> closed := true
  | exception Eio.Io _ -> closed := true

let test_stdio_user_io_exception_stays_primary () =
  with_temp_dir @@ fun dir -> with_eio @@ fun ~net ~clock ->
  within ~clock 3. @@ fun () -> Eio.Switch.run @@ fun sw ->
  let socket = Filename.concat dir "callback-io.sock" in
  let closed = ref false and connections = ref 0 in
  let served = fake_agent ~sw ~net socket (fun peer ->
    incr connections;
    Eio.Flow.copy_string (good_hello ()) peer;
    read_interactive_request peer;
    Eio.Flow.copy_string (Relay.encode (Relay.Stdout "ready")) peer;
    observe_peer_close peer closed) in
  let primary = Eio.Exn.create Stdio_callback_io_failure in
  (match stdio_call ~net ~clock ~socket (fun ~input ~output:_ ->
      check string "callback entered after real response" "ready" (stdio_read input 5);
      raise primary) with
   | Ok _ | Error _ -> fail "user Eio.Io became a returned transport outcome"
   | exception error -> check bool "same user exception" true (error == primary));
  Eio.Promise.await served;
  check bool "callback failure closed the connection" true !closed;
  check int "callback failure was not replayed" 1 !connections

let test_stdio_cancellation_releases_blocked_decoder () =
  with_temp_dir @@ fun dir -> with_eio @@ fun ~net ~clock ->
  within ~clock 3. @@ fun () -> Eio.Switch.run @@ fun sw ->
  let socket = Filename.concat dir "cancel-decoder.sock" in
  let closed = ref false and cancelled = ref None in
  let offered, resolve_offered = Eio.Promise.create () in
  let waiting, resolve_waiting = Eio.Promise.create () in
  let served = fake_agent ~sw ~net socket (fun peer ->
    Eio.Flow.copy_string (good_hello ()) peer;
    read_interactive_request peer;
    Eio.Flow.copy_string (Relay.encode (Relay.Stdout "ready")) peer;
    check string "callback is deliberately no longer reading" "go" (stdio_read peer 2);
    Eio.Flow.copy_string (Relay.encode (Relay.Stdout "unread rendezvous bytes")) peer;
    Eio.Promise.resolve resolve_offered ();
    observe_peer_close peer closed) in
  (match Eio.Cancel.sub (fun context ->
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.await waiting;
        Eio.Promise.await offered;
        (* Let the decoder deliver the offered chunk to the rendezvous;
           the callback below never consumes it. Cancellation must release
           both the waiting callback and its backpressured decoder. *)
        Eio.Fiber.yield ();
        Eio.Cancel.cancel context Stdio_cancel_requested);
      stdio_call ~net ~clock ~socket (fun ~input ~output ->
        check string "initial response" "ready" (stdio_read input 5);
        Eio.Flow.copy_string "go" output;
        Eio.Promise.resolve resolve_waiting ();
        try Eio.Fiber.await_cancel () with
        | Eio.Cancel.Cancelled _ as error -> cancelled := Some error; raise error)) with
   | Ok _ | Error _ -> fail "explicit cancellation became a normal transport result"
   | exception (Eio.Cancel.Cancelled _ as error) ->
     check bool "callback cancellation remains the primary exception" true
       (match !cancelled with Some original -> original == error | None -> false));
  Eio.Promise.await served;
  check bool "cancelled decoder released the owned connection" true !closed

let test_stdio_budget_after_write_closes_connection () =
  with_temp_dir @@ fun dir -> with_eio @@ fun ~net ~clock ->
  within ~clock 3. @@ fun () -> Eio.Switch.run @@ fun sw ->
  let socket = Filename.concat dir "budget-after-write.sock" in
  let closed = ref false and writes = ref 0 and connections = ref 0 in
  let served = fake_agent ~sw ~net socket (fun peer ->
    incr connections;
    Eio.Flow.copy_string (good_hello ()) peer;
    read_interactive_request peer;
    Eio.Flow.copy_string (Relay.encode (Relay.Stdout "ready")) peer;
    observe_peer_close peer closed) in
  let result = stdio_call ~net ~clock ~socket ~budget_sec:1.
      ~on_request_write:(fun () -> incr writes)
      (fun ~input ~output:_ ->
        check string "request received a response before timeout" "ready" (stdio_read input 5);
        Eio.Fiber.await_cancel ()) in
  check bool "post-write timeout retains typed uncertainty" true
    (result = Error (Guest.Transport_failed Guest.Budget_spent));
  Eio.Promise.await served;
  check int "one actual request write boundary" 1 !writes;
  check int "timed-out request was not replayed" 1 !connections;
  check bool "budget expiry closed the owned connection" true !closed

(* #52968, RFC host-and-shim-share-one-build-identity: the host reads the
   source identity out of the mounted shim's bytes before booting a guest
   with it. The executable dune built from this source carries one
   declaration, and it is the identity this test binary links from the same
   generated module, so host and shim cannot be stamped apart. *)
let test_the_built_shim_declares_this_source () =
  let bytes = In_channel.with_open_bin !shim_binary In_channel.input_all in
  match Source_identity.current, Source_identity.scan bytes with
  | None, _ -> Alcotest.fail "this test build has no source identity"
  | Some this, Source_identity.Declared shim ->
    check string "the built shim declares this build's source"
      (Source_identity.to_string this) (Source_identity.to_string shim)
  | Some _, Source_identity.Undeclared ->
    Alcotest.fail "the built shim carries no source identity declaration"
  | Some _, Source_identity.Several _ ->
    Alcotest.fail "the built shim declares several source identities"

let () =
  if Array.length Sys.argv <> 2 then failwith "expected the masc-exec-shim binary path";
  shim_binary := Unix.realpath Sys.argv.(1);
  (* The shim's main ignores SIGPIPE before it dispatches; the forked agent
     has to see the same, or a closed connection kills it. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let dir = Filename.temp_dir "masc-guest-socket-agent-" "" in
  let pid = start_agent dir in
  at_exit (fun () ->
    (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
    (try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ());
    remove_tree dir);
  run ~argv:[| Sys.argv.(0) |] "keeper guest socket"
    [ ( "hello"
      , [ test_case "the refusal checks every fact" `Quick test_refusal_checks_every_fact ] )
    ; ( "interactive host boundary"
      , [ test_case "actual hello precedes every request" `Quick test_stdio_checks_actual_hello_before_request
        ; test_case "owner decline sends nothing" `Quick test_stdio_decline_sends_no_request
        ; test_case "duplex closes send and drains exact output" `Quick test_stdio_duplex_drains_after_send_shutdown
        ; test_case "missing Exit remains incomplete" `Quick test_stdio_missing_exit_is_incomplete
        ; test_case "user Eio.Io remains primary" `Quick test_stdio_user_io_exception_stays_primary
        ; test_case "cancellation releases backpressured decoder" `Quick test_stdio_cancellation_releases_blocked_decoder
        ; test_case "post-write budget closes without replay" `Quick test_stdio_budget_after_write_closes_connection ] )
    ; ( "real shim"
      , [ test_case "the built shim declares this source" `Quick
            test_the_built_shim_declares_this_source
        ; test_case "a request reaches the shim" `Quick test_run_reaches_the_real_shim
        ; test_case "a probe reaches the shim" `Quick test_probe_reaches_the_real_shim
        ; test_case "a refused agent gets nothing" `Quick test_a_refused_agent_gets_nothing
        ; test_case "a spent budget cancels the payload" `Quick
            test_a_spent_budget_cancels_the_payload
        ] )
    ; ( "before the agent listens"
      , [ test_case "no listener is unreachable" `Quick test_no_listener_is_unreachable
        ; test_case "a silent connection is replaced" `Quick
            test_a_silent_connection_is_replaced
        ; test_case "ended connections are replaced" `Quick
            test_ended_connections_are_replaced
        ; test_case "an agent that leaves is broken" `Quick
            test_an_agent_that_leaves_is_broken
        ; test_case "failed connections hold no descriptor" `Quick
            test_failed_connections_hold_no_descriptor
        ] )
    ; ( "agent answers"
      , [ test_case "a refused agent receives no byte" `Quick
            test_a_refused_agent_receives_no_byte
        ; test_case "an undecodable hello is incompatible" `Quick
            test_an_undecodable_hello_is_incompatible
        ; test_case "a first chunk that is no hello is incompatible" `Quick
            test_a_first_chunk_that_is_no_hello_is_incompatible
        ; test_case "a signalled shim is broken" `Quick test_a_signalled_shim_is_broken
        ; test_case "a second hello is broken" `Quick test_a_second_hello_is_broken
        ; test_case "a hello split across reads is read" `Quick
            test_a_hello_split_across_reads_is_read
        ; test_case "output is bounded and streamed whole" `Quick
            test_output_is_bounded_and_streamed_whole
        ; test_case "a budget that is not a number tries nothing" `Quick
            test_a_budget_that_is_not_a_number_tries_nothing
        ] )
    ]
