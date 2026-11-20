(* masc-exec-shim --serve: owner
   parsing, the refusal that comes before any root step, one relay against
   small shell programs, and serve against the real shim binary.

   The root steps -- the socket directory, the re-mount of /, the drop to the
   Keeper's uid -- run only as a Linux guest's first process, and the microVM
   canary measures them. A test never runs them: as root they would re-mount
   the test host's /. *)

open Alcotest
module Relay = Exec_ssh_protocol.Relay

let shim_binary = ref ""

(* Long enough for a loaded CI host; every wait below ends as soon as its
   process does. *)
let deadline_sec = 20.0
let poll_interval_sec = 0.02
let base_env = [| "PATH=/usr/bin:/bin" |]

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_temp_dir f =
  let dir = Filename.temp_dir "masc-shim-agent-" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let write_file ~perm path contents =
  Out_channel.with_open_gen
    [ Open_wronly; Open_creat; Open_trunc; Open_binary ]
    perm path
    (fun channel -> Out_channel.output_string channel contents);
  Unix.chmod path perm

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_script dir body =
  let path = Filename.concat dir "program" in
  write_file ~perm:0o755 path ("#!/bin/sh\n" ^ body ^ "\n");
  path

let rec write_all fd text offset =
  if offset < String.length text
  then
    write_all fd text
      (offset + Unix.write_substring fd text offset (String.length text - offset))

let send fd text = write_all fd text 0
let kind_byte kind = String.make 1 (Relay.request_kind_byte kind)

let wait_exit pid =
  let deadline = Unix.gettimeofday () +. deadline_sec in
  let rec poll () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
      if Unix.gettimeofday () > deadline
      then (
        Unix.kill pid Sys.sigkill;
        ignore (Unix.waitpid [] pid);
        failf "process %d did not end within %.0fs" pid deadline_sec)
      else (
        Unix.sleepf poll_interval_sec;
        poll ())
    | _, status -> status
  in
  poll ()

let check_exit_zero ~what pid =
  match wait_exit pid with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code -> failf "%s exited %d" what code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> failf "%s died on signal %d" what signal

(* Every byte until the peer closes. *)
let read_until_eof ?(allow_reset = false) fd =
  let deadline = Unix.gettimeofday () +. deadline_sec in
  let out = Buffer.create 4096 in
  let bytes = Bytes.create 65536 in
  let rec loop () =
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining <= 0.
    then failf "no end of stream within %.0fs; %d bytes read" deadline_sec (Buffer.length out);
    match Unix.select [ fd ] [] [] remaining with
    | [], _, _ -> loop ()
    | _ :: _, _, _ ->
      (match Unix.read fd bytes 0 (Bytes.length bytes) with
       | 0 -> ()
       | read ->
         Buffer.add_subbytes out bytes 0 read;
         loop ()
       | exception Unix.Unix_error (Unix.ECONNRESET, _, _) when allow_reset -> ())
  in
  loop ();
  Buffer.contents out

(* [count] bytes, or a failure when they do not arrive in time: a missing
   hello fails the test rather than hanging it. *)
let read_exact fd count =
  let deadline = Unix.gettimeofday () +. deadline_sec in
  let rec go count =
    if count = 0
    then ""
    else (
      let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0. then failf "%d bytes did not arrive within %.0fs" count deadline_sec;
      match Unix.select [ fd ] [] [] remaining with
      | [], _, _ -> go count
      | _ :: _, _, _ ->
        let bytes = Bytes.create count in
        (match Unix.read fd bytes 0 count with
         | 0 -> fail "the stream ended inside a chunk"
         | read -> Bytes.sub_string bytes 0 read ^ go (count - read)))
  in
  go count

let decode_all bytes =
  let rec go pos acc =
    if pos = String.length bytes
    then List.rev acc
    else
      match Relay.decode bytes ~pos with
      | Ok (Relay.Chunk { chunk; consumed }) -> go (pos + consumed) (chunk :: acc)
      | Ok Relay.Need_more -> failf "the stream stopped inside a chunk at byte %d" pos
      | Error _ -> failf "an undecodable chunk at byte %d" pos
  in
  go 0 []

(* The hello and nothing past it, so a test can act between the hello and
   the rest of the stream. *)
let header_bytes = 5

let read_hello fd =
  let header = read_exact fd header_bytes in
  let length = Int32.to_int (String.get_int32_be header 1) in
  match decode_all (header ^ read_exact fd length) with
  | [ Relay.Hello hello ] -> hello
  | _ -> fail "the first chunk was not a hello"

type outcome =
  { stdout : string
  ; stderr : string
  ; exits : Relay.exit_status list
  ; last_is_exit : bool
  }

let outcome_of chunks =
  let stdout = Buffer.create 256 and stderr = Buffer.create 256 in
  let exits =
    List.filter_map
      (function
        | Relay.Stdout bytes ->
          Buffer.add_string stdout bytes;
          None
        | Relay.Stderr bytes ->
          Buffer.add_string stderr bytes;
          None
        | Relay.Exit status -> Some status
        | Relay.Hello _ -> fail "a second hello")
      chunks
  in
  { stdout = Buffer.contents stdout
  ; stderr = Buffer.contents stderr
  ; exits
  ; last_is_exit =
      (match List.rev chunks with
       | Relay.Exit _ :: _ -> true
       | _ -> false)
  }

let split_hello = function
  | Relay.Hello hello :: rest -> hello, rest
  | _ -> fail "the first chunk was not a hello"

let exit_status =
  testable
    (fun formatter -> function
       | Relay.Exited code -> Format.fprintf formatter "Exited %d" code
       | Relay.Signaled signal -> Format.fprintf formatter "Signaled %d" signal)
    ( = )

(* One relay in a forked child against one end of a socketpair; the test is
   the host on the other end. *)
let start_relay ~program ~env =
  let host, agent = Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  match Unix.fork () with
  | 0 ->
    Unix.close host;
    (match
       Shim_agent.relay ~conn:agent ~program ~env
         ~host_signal_number:Exec_shim.host_signal_number
     with
     | () -> Unix._exit 0
     | exception _ -> Unix._exit 3)
  | pid ->
    Unix.close agent;
    host, pid

let relay_to_end ~program ~env request =
  let host, pid = start_relay ~program ~env in
  send host request;
  let chunks = decode_all (read_until_eof host) in
  Unix.close host;
  check_exit_zero ~what:"the relay" pid;
  chunks

let test_owner_parsing () =
  (match Shim_agent.parse_owner "502:20" with
   | Ok { Shim_agent.uid; gid } ->
     check int "uid" 502 uid;
     check int "gid" 20 gid
   | Error message -> fail message);
  List.iter
    (fun text ->
       match Shim_agent.parse_owner text with
       | Ok _ -> failf "%S was read as an owner" text
       | Error _ -> ())
    [ ""; "502"; "502:"; ":20"; "502:20:1"; "-1:20"; "+502:20"; " 502:20"; "502:2O"
    ; "0x1f6:20"; "4294967295:20"; "99999999999999999999:20"; "0:20"; "502:0"; "0:0" ]

let test_start_refuses_before_touching_anything () =
  let euid = Unix.geteuid () in
  if euid = 0 then skip ();
  with_temp_dir @@ fun dir ->
  let directory = Filename.concat dir "agent" in
  let socket = Filename.concat directory "agent.sock" in
  (match Shim_agent.start ~socket ~owner:{ Shim_agent.uid = 502; gid = 20 } with
   | Error (Shim_agent.Not_root { euid = reported }) ->
     check int "the effective uid it saw" euid reported
   | Error error -> fail (Shim_agent.start_error_to_string error)
   | Ok _ -> fail "started without root");
  check bool "no socket directory was made" false (Sys.file_exists directory)

let run_binary args =
  let stderr_r, stderr_w = Unix.pipe ~cloexec:true () in
  let null = Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
  let pid =
    Unix.create_process !shim_binary (Array.append [| !shim_binary |] args) null null
      stderr_w
  in
  Unix.close stderr_w;
  Unix.close null;
  let stderr = read_until_eof stderr_r in
  Unix.close stderr_r;
  wait_exit pid, stderr

let contains ~needle haystack =
  let needle_length = String.length needle in
  let rec at index =
    index + needle_length <= String.length haystack
    && (String.sub haystack index needle_length = needle || at (index + 1))
  in
  at 0

let check_refused ~what (status, stderr) ~needle =
  (match status with
   | Unix.WEXITED 1 -> ()
   | Unix.WEXITED code -> failf "%s exited %d, stderr %S" what code stderr
   | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
     failf "%s died on signal %d" what signal);
  check bool (what ^ " names the reason") true (contains ~needle stderr)

(* Through the binary, so the [--serve] argv reaches the agent. A root owner
   is refused before any root step, so this one runs as root too. *)
let test_serve_argv_reaches_the_agent () =
  (* As root a refusal the code under test failed to make would re-mount the
     test host's /. *)
  if Unix.geteuid () = 0 then skip ();
  with_temp_dir @@ fun dir ->
  let socket = Filename.concat (Filename.concat dir "agent") "agent.sock" in
  check_refused ~what:"a root owner"
    (run_binary [| "--serve"; socket; "0:0" |])
    ~needle:"names root";
  check_refused ~what:"a start without root"
    (run_binary [| "--serve"; socket; "502:20" |])
    ~needle:"effective uid"

let test_relay_runs_a_request () =
  with_temp_dir @@ fun dir ->
  let program =
    write_script dir
      {|IFS= read -r line
printf 'out:%s' "$line"
printf 'err:%s' "$line" >&2
exit 3|}
  in
  let hello, rest =
    split_hello (relay_to_end ~program ~env:base_env (kind_byte Relay.Run ^ "abc\n"))
  in
  check int "hello version" Relay.version hello.Relay.relay_version;
  check bool "hello names the source this build links" true
    (match Source_identity.current, hello.Relay.source_identity with
     | Some this, Some named -> Source_identity.equal this named
     | None, (Some _ | None) | Some _, None -> false);
  check int "hello uid" (Unix.geteuid ()) hello.Relay.uid;
  check int "hello gid" (Unix.getegid ()) hello.Relay.gid;
  let outcome = outcome_of rest in
  check string "stdout" "out:abc" outcome.stdout;
  check string "stderr" "err:abc" outcome.stderr;
  check (list exit_status) "one exit" [ Relay.Exited 3 ] outcome.exits;
  check bool "the exit comes last" true outcome.last_is_exit

let test_relay_runs_a_probe () =
  with_temp_dir @@ fun dir ->
  let program =
    write_script dir
      {|if [ "$1" = --probe ]; then printf 'probe-out'; exit 0; fi
exit 9|}
  in
  let _, rest = split_hello (relay_to_end ~program ~env:base_env (kind_byte Relay.Probe)) in
  let outcome = outcome_of rest in
  check string "the probe output" "probe-out" outcome.stdout;
  check (list exit_status) "one exit" [ Relay.Exited 0 ] outcome.exits

let test_relay_splits_long_output () =
  with_temp_dir @@ fun dir ->
  let length = (3 * Relay.max_payload_bytes) + 123 in
  let program = write_script dir (Printf.sprintf "head -c %d /dev/zero" length) in
  let _, rest = split_hello (relay_to_end ~program ~env:base_env (kind_byte Relay.Run)) in
  let outcome = outcome_of rest in
  check int "every byte arrives" length (String.length outcome.stdout);
  check bool "unchanged" true (outcome.stdout = String.make length '\000');
  check bool "in more than one chunk" true (List.length rest > 2);
  check (list exit_status) "one exit" [ Relay.Exited 0 ] outcome.exits

let test_relay_reports_a_signal () =
  with_temp_dir @@ fun dir ->
  let program = write_script dir "kill -9 $$" in
  let _, rest = split_hello (relay_to_end ~program ~env:base_env (kind_byte Relay.Run)) in
  check (list exit_status) "the guest signal number" [ Relay.Signaled 9 ]
    (outcome_of rest).exits

let test_relay_refuses_an_unknown_kind () =
  with_temp_dir @@ fun dir ->
  let marker = Filename.concat dir "ran" in
  let program = write_script dir "printf ran > \"$MARKER\"" in
  let env = Array.append base_env [| "MARKER=" ^ marker |] in
  let _, rest = split_hello (relay_to_end ~program ~env "Z") in
  check int "nothing after the hello" 0 (List.length rest);
  check bool "the program never ran" false (Sys.file_exists marker)

let test_relay_without_a_program_sends_no_exit () =
  with_temp_dir @@ fun dir ->
  let program = Filename.concat dir "absent" in
  let _, rest = split_hello (relay_to_end ~program ~env:base_env (kind_byte Relay.Run)) in
  check int "nothing after the hello" 0 (List.length rest)

(* A host that ends its side right after the request: the bytes it sent
   still reach the program, then its stdin closes. *)
let test_bytes_before_the_hosts_end_reach_the_program () =
  with_temp_dir @@ fun dir ->
  let program = write_script dir "exec cat" in
  let host, pid = start_relay ~program ~env:base_env in
  send host (kind_byte Relay.Run ^ "hello\n");
  Unix.shutdown host Unix.SHUTDOWN_SEND;
  let chunks = decode_all (read_until_eof host) in
  Unix.close host;
  check_exit_zero ~what:"the relay" pid;
  let _, rest = split_hello chunks in
  let outcome = outcome_of rest in
  check string "every byte reached the program" "hello\n" outcome.stdout;
  check (list exit_status) "one exit" [ Relay.Exited 0 ] outcome.exits

(* The program holds no socket: the relay's connection is close-on-exec, or a
   payload could write chunks of its own to the host. *)
let test_the_program_inherits_no_socket () =
  if not (Sys.file_exists "/proc/self/fd") then skip ();
  with_temp_dir @@ fun dir ->
  let program = write_script dir "ls -l /proc/$$/fd" in
  let _, rest = split_hello (relay_to_end ~program ~env:base_env (kind_byte Relay.Run)) in
  let outcome = outcome_of rest in
  check bool "the listing ran" true (contains ~needle:"->" outcome.stdout);
  check bool
    ("no socket among the program's descriptors: " ^ outcome.stdout)
    false (contains ~needle:"socket:" outcome.stdout)

(* A descriptor open without close-on-exec before the sweep does not reach a
   program run after it. *)
let test_inherited_descriptors_are_not_passed_on () =
  if not (Sys.file_exists "/proc/self/fd") then skip ();
  with_temp_dir @@ fun dir ->
  let leaked = Filename.concat dir "leaked" in
  let listing = Filename.concat dir "listing" in
  match Unix.fork () with
  | 0 ->
    (try
       let (_ : Unix.file_descr) = Unix.openfile leaked [ Unix.O_CREAT; Unix.O_RDWR ] 0o600 in
       Shim_agent.mark_inherited_descriptors_close_on_exec ();
       Unix.execv "/bin/sh" [| "sh"; "-c"; "ls -l /proc/$$/fd > " ^ Filename.quote listing |]
     with
     | _ -> Unix._exit 3)
  | pid ->
    check_exit_zero ~what:"the swept child" pid;
    let text = read_file listing in
    check bool "the listing ran" true (contains ~needle:"->" text);
    check bool ("the leaked file is not open in the program: " ^ text) false
      (contains ~needle:leaked text)

(* The shim reads its stdin closing as a cancel; a connection that ends must
   reach it that way. *)
let test_closing_the_connection_closes_stdin () =
  with_temp_dir @@ fun dir ->
  let marker = Filename.concat dir "after-eof" in
  let program = write_script dir "cat >/dev/null\nprintf done > \"$MARKER\"" in
  let env = Array.append base_env [| "MARKER=" ^ marker |] in
  let host, pid = start_relay ~program ~env in
  let (_ : Relay.hello) = read_hello host in
  send host (kind_byte Relay.Run);
  Unix.close host;
  check_exit_zero ~what:"the relay" pid;
  check string "the program saw its stdin close" "done" (read_file marker)

(* After the host has gone, the output is still read to the end; otherwise a
   chatty shim blocks on a full pipe and never sees its cancel. *)
let test_output_is_drained_after_the_host_leaves () =
  with_temp_dir @@ fun dir ->
  let marker = Filename.concat dir "finished" in
  let length = 32 * Relay.max_payload_bytes in
  let program =
    write_script dir
      (Printf.sprintf "head -c %d /dev/zero\nprintf done > \"$MARKER\"" length)
  in
  let env = Array.append base_env [| "MARKER=" ^ marker |] in
  let host, pid = start_relay ~program ~env in
  let (_ : Relay.hello) = read_hello host in
  send host (kind_byte Relay.Run);
  Unix.close host;
  check_exit_zero ~what:"the relay" pid;
  check string "the program wrote everything" "done" (read_file marker)

let request ?(stdin = Exec_ssh_protocol.Framed 0L) ~root argv =
  match
    Exec_ssh_protocol.encode_request
      { Exec_ssh_protocol.v = Exec_ssh_protocol.V3
      ; argv
      ; env = []
      ; cwd = root
      ; remote_root = root
      ; timeout_sec = deadline_sec
      ; stdin
      ; mode = Exec_ssh_protocol.Effect
      ; acceptance_frame = true
      }
      ~stdin:""
  with
  | Ok frame -> frame
  | Error message -> fail message

let payload_exit outcome =
  match Exec_ssh_protocol.parse_trailer outcome.stderr with
  | Ok trailer -> trailer.Exec_ssh_protocol.exit
  | Error message -> fail message

let test_real_shim_exchanges_interactive_bytes_through_the_relay () =
  with_temp_dir @@ fun dir ->
  let root = Unix.realpath dir in
  let config = Filename.concat root "shim.conf" in
  write_file ~perm:0o644 config
    (Printf.sprintf "remote_root=%s\nscratch_root=%s\n" root root);
  let env = Array.append base_env
      [| Printf.sprintf "%s=%s" Exec_ssh_protocol.shim_config_env_var config |] in
  let host, pid = start_relay ~program:!shim_binary ~env in
  let closed = ref false and reaped = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !closed then Unix.close host;
      if not !reaped then (
        (try Unix.kill pid Sys.sigkill with
         | Unix.Unix_error (Unix.ESRCH, _, _) -> ());
        (try ignore (Unix.waitpid [] pid) with
         | Unix.Unix_error (Unix.ECHILD, _, _) -> ())))
  @@ fun () ->
  let (_ : Relay.hello) = read_hello host in
  let first = "a\000\255z" and second = "b\030\000\254yz" in
  send host
    (kind_byte Relay.Interactive_run ^ request ~root ~stdin:Exec_ssh_protocol.Interactive
       [ "/bin/sh"; "-c"
       ; "dd bs=1 count=4 2>/dev/null; printf ready; \
          dd bs=1 count=6 2>/dev/null; exit 7" ]);
  send host first;
  let first_stdout = Buffer.create 16 in
  let rec await_first_response chunks =
    if Buffer.length first_stdout >= String.length first + String.length "ready"
    then List.rev chunks
    else
      let header = read_exact host header_bytes in
      let length = Int32.to_int (String.get_int32_be header 1) in
      match decode_all (header ^ read_exact host length) with
      | [ (Relay.Stdout bytes as chunk) ] ->
        Buffer.add_string first_stdout bytes;
        await_first_response (chunk :: chunks)
      | [ (Relay.Stderr _ as chunk) ] -> await_first_response (chunk :: chunks)
      | [ Relay.Exit _ ] -> fail "the shim ended before the second input"
      | [ Relay.Hello _ ] | [] | _ :: _ :: _ -> fail "unexpected relay chunk"
  in
  let initial_chunks = await_first_response [] in
  check string "the first response arrives while stdin remains open"
    (first ^ "ready") (Buffer.contents first_stdout);
  (* The second input does not exist in the framed request and is sent only
     after the first response, as a stdio peer would do. *)
  send host second;
  let outcome = outcome_of (initial_chunks @ decode_all (read_until_eof host)) in
  Unix.close host;
  closed := true;
  let status = wait_exit pid in
  reaped := true;
  check bool "the relay finishes" true (status = Unix.WEXITED 0);
  check string "NUL, record separator and non-UTF8 bytes survive both exchanges"
    (first ^ "ready" ^ second) outcome.stdout;
  check (option int) "the payload's real exit is preserved" (Some 7) (payload_exit outcome);
  check (list exit_status) "the relay reports the shim's own exit"
    [ Relay.Exited 0 ] outcome.exits;
  check bool "the relay exit follows the complete trailer" true outcome.last_is_exit;
  match Exec_ssh_protocol.split_acceptance_head outcome.stderr with
  | Exec_ssh_protocol.Head_frame _ -> ()
  | Exec_ssh_protocol.Head_pending | Exec_ssh_protocol.Head_payload ->
    fail "the real interactive shim did not acknowledge the request"

(* The payload never reads stdin and ignores TERM. Its observer records the
   kernel's actual full pipe(s), without copying the shim/relay queue sizes. *)
let pressure_payload =
  {|import array, fcntl, os, signal, sys, termios, threading, time
marker, output_pressure = sys.argv[1], sys.argv[2] == "output"
signal.signal(signal.SIGTERM, signal.SIG_IGN)
def occupancy(fd):
    size = fcntl.fcntl(fd, fcntl.F_GETPIPE_SZ)
    queued = array.array("i", [0])
    fcntl.ioctl(fd, termios.FIONREAD, queued, True)
    return queued[0], size
def observe():
    while True:
        incoming, capacity = occupancy(0)
        outgoing, out_capacity = occupancy(1) if output_pressure else (0, 0)
        if incoming == capacity and (not output_pressure or outgoing == out_capacity):
            with open(marker + ".tmp", "w") as destination:
                destination.write(f"{incoming} {capacity} {outgoing} {out_capacity}")
            os.rename(marker + ".tmp", marker)
            return
        time.sleep(0.01)
os.write(1, (str(os.getpid()) + "\n").encode())
threading.Thread(target=observe, daemon=True).start()
if output_pressure:
    while True:
        os.write(1, b"\x00\xff" * 32768)
else:
    while True:
        signal.pause()
|}

let complete_prefix bytes =
  let rec loop pos chunks =
    if pos = String.length bytes then List.rev chunks
    else match Relay.decode bytes ~pos with
      | Ok (Relay.Chunk { chunk; consumed }) -> loop (pos + consumed) (chunk :: chunks)
      | Ok Relay.Need_more -> List.rev chunks
      | Error _ -> fail "the incomplete transport contained an invalid complete header"
  in
  loop 0 []

let test_interactive_half_close_cancels_pressure ~output_pressure () =
  if not (Sys.file_exists "/proc/self/fd") then skip ();
  with_temp_dir @@ fun dir ->
  let root = Unix.realpath dir in
  let config = Filename.concat root "shim.conf" in
  let marker = Filename.concat root "pressure" in
  write_file ~perm:0o644 config
    (Printf.sprintf "remote_root=%s\nscratch_root=%s\n" root root);
  let env = Array.append base_env
      [| Printf.sprintf "%s=%s" Exec_ssh_protocol.shim_config_env_var config |] in
  let host, relay_pid = start_relay ~program:!shim_binary ~env in
  let payload_pid = ref None and reaped = ref false in
  Fun.protect ~finally:(fun () ->
    (try Unix.close host with Unix.Unix_error _ -> ());
    (match !payload_pid with
     | None -> ()
     | Some pid ->
       (try Unix.kill pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ()));
    if not !reaped then begin
      (try Unix.kill relay_pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
      (try ignore (Unix.waitpid [] relay_pid) with Unix.Unix_error (Unix.ECHILD, _, _) -> ())
    end) @@ fun () ->
  let hello = read_hello host in
  check int "the real relay advertises the interactive contract" 2 hello.Relay.relay_version;
  send host (kind_byte Relay.Interactive_run
    ^ request ~root ~stdin:Exec_ssh_protocol.Interactive
        [ "python3"; "-c"; pressure_payload; marker
        ; if output_pressure then "output" else "input" ]);
  let initial_stdout = Buffer.create 32 in
  let rec ready chunks =
    if String.contains (Buffer.contents initial_stdout) '\n' then List.rev chunks
    else
      let header = read_exact host header_bytes in
      let length = Int32.to_int (String.get_int32_be header 1) in
      match decode_all (header ^ read_exact host length) with
      | [ (Relay.Stdout bytes as chunk) ] ->
        Buffer.add_string initial_stdout bytes; ready (chunk :: chunks)
      | [ (Relay.Stderr _ as chunk) ] -> ready (chunk :: chunks)
      | [ Relay.Exit _ ] -> fail "payload exited before its pressure handshake"
      | [ Relay.Hello _ ] | [] | _ :: _ :: _ -> fail "unexpected pressure handshake chunk"
  in
  let initial = ready [] in
  let line = List.hd (String.split_on_char '\n' (Buffer.contents initial_stdout)) in
  let payload = match int_of_string_opt line with
    | Some pid -> pid | None -> fail "pressure handshake omitted the actual child pid" in
  payload_pid := Some payload;
  Unix.set_nonblock host;
  let bytes = String.make 65536 '\000' in
  let deadline = Unix.gettimeofday () +. deadline_sec in
  let rec saturate () =
    if Unix.gettimeofday () >= deadline then fail "the input path did not reach kernel backpressure";
    match Unix.single_write_substring host bytes 0 (String.length bytes) with
    | _ -> saturate ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
      if not (Sys.file_exists marker) then begin
        ignore (Unix.select [] [ host ] [] poll_interval_sec); saturate ()
      end
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> saturate ()
  in
  saturate ();
  let incoming, capacity, outgoing, out_capacity =
    Scanf.sscanf (read_file marker) "%d %d %d %d" (fun a b c d -> a, b, c, d) in
  check bool "the real payload input pipe is full" true (capacity > 0 && incoming = capacity);
  if output_pressure then
    check bool "the real payload output pipe is full" true (out_capacity > 0 && outgoing = out_capacity);
  Unix.shutdown host Unix.SHUTDOWN_SEND;
  Unix.clear_nonblock host;
  let chunks =
    if output_pressure then begin
      (* Keep the receive direction unread until the relay itself exits.
         A blocking terminal flush or a missing RDHUP observation cannot pass. *)
      check_exit_zero ~what:"the output-pressured relay" relay_pid;
      reaped := true;
      initial @ complete_prefix (read_until_eof ~allow_reset:true host)
    end else begin
      (* AF_UNIX may reset on close with the deliberately discarded input
         still queued. A reset is no success: the complete Exit and actual
         payload trailer below remain mandatory for this drained case. *)
      let chunks = initial @ decode_all (read_until_eof ~allow_reset:true host) in
      check_exit_zero ~what:"the input-pressured relay" relay_pid;
      reaped := true;
      chunks
    end
  in
  let outcome = outcome_of chunks in
  if output_pressure then
    check (list exit_status) "incomplete output cannot claim a terminal relay Exit" [] outcome.exits
  else begin
    check (list exit_status) "drained cancellation keeps the actual shim exit" [ Relay.Exited 0 ] outcome.exits;
    match Exec_ssh_protocol.parse_trailer outcome.stderr with
    | Error message -> fail message
    | Ok trailer ->
      check (option int) "EOF cancellation killed the TERM-resistant payload" (Some 9) trailer.signal;
      check (option int) "cancellation did not invent an exit" None trailer.exit;
      check bool "EOF was not mislabeled as timeout" false trailer.timed_out;
      check (option string) "drained cancellation has no transport error" None trailer.shim_error
  end;
  let running = try Unix.kill payload 0; true with Unix.Unix_error (Unix.ESRCH, _, _) -> false in
  check bool "the owned actual payload was reaped" false running;
  payload_pid := None

(* The real shim behind serve: two connections at once and a probe. *)
let test_serve_runs_the_real_shim () =
  with_temp_dir @@ fun dir ->
  let root = Filename.concat dir "root" in
  Unix.mkdir root 0o755;
  let config = Filename.concat dir "shim.conf" in
  write_file ~perm:0o644 config
    (Printf.sprintf "remote_root=%s\nscratch_root=%s\n" root root);
  Unix.putenv Exec_ssh_protocol.shim_config_env_var config;
  let socket = Filename.concat dir "agent.sock" in
  let listener = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_UNIX socket);
  Unix.listen listener 8;
  let agent =
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
      pid
  in
  Fun.protect
    ~finally:(fun () ->
      Unix.kill agent Sys.sigkill;
      ignore (Unix.waitpid [] agent))
  @@ fun () ->
  let connect () =
    let fd = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Unix.connect fd (Unix.ADDR_UNIX socket);
    fd
  in
  let finish fd =
    let outcome = outcome_of (decode_all (read_until_eof fd)) in
    Unix.close fd;
    outcome
  in
  (* The slow payload waits on a FIFO the test opens only after the quick
     one has finished, so the two overlap or the test fails on its deadline:
     a serve that took connections one at a time never finishes the quick
     one. *)
  let gate = Filename.concat root "gate" in
  Unix.mkfifo gate 0o600;
  let slow = connect () in
  let (_ : Relay.hello) = read_hello slow in
  send slow
    (kind_byte Relay.Run
     ^ request ~root [ "sh"; "-c"; Printf.sprintf "read line < %s; echo slow" (Filename.quote gate) ]);
  let quick = connect () in
  let hello = read_hello quick in
  check int "hello uid" (Unix.geteuid ()) hello.Relay.uid;
  send quick
    (kind_byte Relay.Run ^ request ~root [ "sh"; "-c"; "echo quick; echo oops >&2; exit 4" ]);
  let quick = finish quick in
  (* Opened without blocking: a FIFO with no reader yet refuses (ENXIO), so a
     slow payload that never opened it fails the test instead of hanging it. *)
  let deadline = Unix.gettimeofday () +. deadline_sec in
  let rec open_gate () =
    match Unix.openfile gate [ Unix.O_WRONLY; Unix.O_NONBLOCK ] 0 with
    | fd -> fd
    | exception Unix.Unix_error (Unix.ENXIO, _, _) when Unix.gettimeofday () < deadline ->
      Unix.sleepf poll_interval_sec;
      open_gate ()
  in
  let opener = open_gate () in
  send opener "go\n";
  Unix.close opener;
  let slow = finish slow in
  check string "the quick payload's stdout" "quick\n" quick.stdout;
  check (option int) "the quick payload's exit, from the trailer" (Some 4)
    (payload_exit quick);
  (match Exec_ssh_protocol.split_acceptance_head quick.stderr with
   | Exec_ssh_protocol.Head_frame { rest; _ } ->
     check bool "the payload's stderr follows the acceptance frame" true
       (String.length rest >= 5 && String.sub rest 0 5 = "oops\n")
   | Exec_ssh_protocol.Head_pending | Exec_ssh_protocol.Head_payload ->
     fail "the shim's acceptance frame did not lead its stderr");
  check (list exit_status) "the shim itself exits 0" [ Relay.Exited 0 ] quick.exits;
  check string "the slow payload's stdout" "slow\n" slow.stdout;
  check (option int) "the slow payload's exit" (Some 0) (payload_exit slow);
  let probe = connect () in
  let (_ : Relay.hello) = read_hello probe in
  send probe (kind_byte Relay.Probe);
  let probe = finish probe in
  (match Exec_ssh_protocol.parse_probe (String.trim probe.stdout) with
   | Ok identity ->
     check string "the probe names the shim" "masc-exec-shim"
       identity.Exec_ssh_protocol.name
   | Error message -> fail message);
  check (list exit_status) "the probe exits 0" [ Relay.Exited 0 ] probe.exits

let () =
  if Array.length Sys.argv <> 2 then failwith "expected the masc-exec-shim binary path";
  shim_binary := Unix.realpath Sys.argv.(1);
  (* The shim's main ignores SIGPIPE before it dispatches; a relay forked
     here has to see the same, or a closed connection kills it. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  run ~argv:[| Sys.argv.(0) |] "shim agent"
    [ ( "start"
      , [ test_case "owner parsing" `Quick test_owner_parsing
        ; test_case "refuses without root before touching anything" `Quick
            test_start_refuses_before_touching_anything
        ; test_case "--serve reaches the agent" `Quick test_serve_argv_reaches_the_agent
        ] )
    ; ( "relay"
      , [ test_case "runs a request" `Quick test_relay_runs_a_request
        ; test_case "runs a probe" `Quick test_relay_runs_a_probe
        ; test_case "splits long output" `Quick test_relay_splits_long_output
        ; test_case "reports a signal" `Quick test_relay_reports_a_signal
        ; test_case "refuses an unknown kind" `Quick test_relay_refuses_an_unknown_kind
        ; test_case "sends no exit without a program" `Quick
            test_relay_without_a_program_sends_no_exit
        ; test_case "bytes before the host's end reach the program" `Quick
            test_bytes_before_the_hosts_end_reach_the_program
        ; test_case "the program inherits no socket" `Quick
            test_the_program_inherits_no_socket
        ; test_case "inherited descriptors are not passed on" `Quick
            test_inherited_descriptors_are_not_passed_on
        ; test_case "a closed connection closes stdin" `Quick
            test_closing_the_connection_closes_stdin
        ; test_case "drains output after the host leaves" `Quick
            test_output_is_drained_after_the_host_leaves
        ] )
    ; ( "serve"
      , [ test_case "runs the real shim" `Quick test_serve_runs_the_real_shim
        ; test_case "real shim exchanges interactive binary input through the relay" `Quick
            test_real_shim_exchanges_interactive_bytes_through_the_relay
        ; test_case "interactive half-close cancels full input" `Quick
            (test_interactive_half_close_cancels_pressure ~output_pressure:false)
        ; test_case "interactive output pressure cannot report a false Exit" `Quick
            (test_interactive_half_close_cancels_pressure ~output_pressure:true) ] )
    ]
