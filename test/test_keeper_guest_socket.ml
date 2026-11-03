(* Keeper_guest_socket against the real agent relay and the real shim, and
   against small listeners that act out what a VM runtime does before the
   agent listens: end the connection at once, or accept it and say nothing
   (docs/evidence/2026-11-03-microvm-request-transport, agent-boot-results).

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

let version_only (hello : Relay.hello) =
  if hello.Relay.relay_version = Relay.version
  then None
  else Some (Guest.Other_relay_version { agent = hello.Relay.relay_version })

let frame ~root argv =
  match
    Exec_ssh_protocol.encode_request
      { Exec_ssh_protocol.v = Exec_ssh_protocol.V3
      ; argv
      ; env = []
      ; cwd = root
      ; remote_root = root
      ; timeout_sec = budget_sec
      ; stdin_len = 0L
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
  | Guest.Exited { code; _ } -> Printf.sprintf "exited %d" code
  | Guest.Timed_out _ -> "timed out"
  | Guest.Broken { reason; _ } -> "broken: " ^ reason

let hello ?(relay_version = Relay.version) ?(root_read_only = true) ?(uid = 502)
      ?(gid = 20) ?(no_new_privs = true) () : Relay.hello =
  { Relay.relay_version; root_read_only; uid; gid; no_new_privs }

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
    [ "another relay version", hello ~relay_version:(Relay.version + 1) (),
      Guest.Other_relay_version { agent = Relay.version + 1 }
    ; "a writable root", hello ~root_read_only:false (), Guest.Root_writable
    ; "another uid", hello ~uid:501 (), Guest.Other_owner { uid = 501; gid = 20 }
    ; "another gid", hello ~gid:0 (), Guest.Other_owner { uid = 502; gid = 0 }
    ; "no no_new_privs", hello ~no_new_privs:false (), Guest.New_privileges_allowed
    ; "the version is read first",
      hello ~relay_version:0 ~root_read_only:false ~uid:0 ~no_new_privs:false (),
      Guest.Other_relay_version { agent = 0 } ]

let test_run_reaches_the_real_shim () =
  let { socket; root } = the_agent () in
  let streamed_out = Buffer.create 64 and streamed_err = Buffer.create 64 in
  with_eio @@ fun ~net ~clock ->
  match
    Guest.run ~net ~clock ~on_stdout_chunk:(Buffer.add_string streamed_out)
      ~on_stderr_chunk:(Buffer.add_string streamed_err) ~accept:version_only ~socket
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
    Guest.run ~net ~clock ~accept:version_only ~socket ~connect_budget_sec ~budget_sec
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
     Guest.run ~net ~clock ~accept:version_only ~socket ~connect_budget_sec ~budget_sec:3.0
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
    Guest.run ~net ~clock ~accept:version_only ~socket:(Filename.concat dir "absent.sock")
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
       Guest.run ~net ~clock ~accept:version_only ~socket ~connect_budget_sec:2.5 ~budget_sec
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
       Guest.run ~net ~clock ~accept:version_only ~socket ~connect_budget_sec ~budget_sec
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
    Guest.run ~net ~clock ~accept:version_only ~socket ~connect_budget_sec ~budget_sec
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
        Guest.run ~net ~clock ~accept:version_only ~socket:(Filename.concat dir "absent.sock")
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
     Guest.run ~net ~clock ~accept:version_only ~socket ~connect_budget_sec ~budget_sec
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
  Guest.run ~net ~clock ~accept:version_only ~socket ~connect_budget_sec ~budget_sec
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
    Guest.run ~net ~clock ~accept:version_only ~socket ~connect_budget_sec ~budget_sec
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
      ~accept:version_only ~socket ~connect_budget_sec ~budget_sec
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
    Guest.run ~net ~clock ~accept:version_only ~socket:(Filename.concat dir "any.sock")
      ~connect_budget_sec ~budget_sec:Float.nan (Guest.Run { frame = "unused" })
  with
  | Guest.Not_sent (Guest.Unreachable { attempts = 0; _ }) -> ()
  | outcome -> fail (describe outcome)

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
    ; ( "real shim"
      , [ test_case "a request reaches the shim" `Quick test_run_reaches_the_real_shim
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
