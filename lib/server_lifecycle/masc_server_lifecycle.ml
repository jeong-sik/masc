(* On-demand background server startup. The server outlives its caller. *)

(* What a completed refresh found at the port, in the vocabulary this
   decision is made in. The client reads it off the status the refresh left
   behind rather than off which message carried it: a refused connection is
   a handled per-surface error, so it arrives as a completed refresh whose
   every surface failed, not as a thrown one. Keeping the vocabulary here
   and the status in the caller is what lets the rule run under a test with no
   TTY and no render state. *)
type contact =
  | Nothing_answered
  | Server_reached
  | Undecided
      (** Still connecting, booting or reconnecting: the port has not
          answered the question yet either way. *)

let start_due ~contact ~already_attempted =
  match contact with
  | Nothing_answered -> not already_attempted
  | Server_reached | Undecided -> false

type discovery =
  | Sibling of string
  | On_path of string
  | Not_found of { manual_command : string }

(* The server and the TUI ship as siblings (scripts/install.sh installs
   [masc] and [masc-tui] into the same prefix), so this is the basename to
   look for beside the running client binary and on the PATH. *)
let server_binary_basename = "masc"

let manual_start_command ~base_path ~host ~port =
  Printf.sprintf "masc start --base-path %s --host %s --port %d" base_path host port

let discover_server_binary ~tui_exe ~file_exists ~path_lookup ~base_path ~host
    ~port =
  let sibling =
    Filename.concat (Filename.dirname tui_exe) server_binary_basename
  in
  if file_exists sibling then Sibling sibling
  else
    match path_lookup server_binary_basename with
    | Some path -> On_path path
    | None ->
        Not_found { manual_command = manual_start_command ~base_path ~host ~port }

let server_argv ~masc_bin ~flags ~base_path ~host ~port =
  (masc_bin :: "start" :: flags)
  @ [ "--base-path"; base_path; "--host"; host; "--port"; string_of_int port ]

type 'exit health_outcome =
  | Ready
  | Server_exited of 'exit
  | Timed_out of int

let wait_healthy ~health_ok ~child_exit ~attempts ~sleep =
  let rec loop n =
    if health_ok () then Ready
    else
      match child_exit () with
      | Some exit -> Server_exited exit
      | None ->
        if n >= attempts then Timed_out n
        else (
          sleep ();
          loop (n + 1))
  in
  if attempts <= 0 then Timed_out 0 else loop 1

(* Where the child's stdout and stderr go. The server writes its own logs
   under .masc/logs once it is running, but a server that refuses to start
   -- another process holds the base path, the port stays taken -- says why
   on stderr and exits, some of it before that log exists. Sending stderr to
   /dev/null left the operator "exited before it was ready" and nothing
   else. The file is emptied on every start, one per port. A server that
   does start keeps its console mirror going into it: about 13 KB booting,
   then 5-35 KB an hour with one keeper, measured over three 18-44 minute runs. *)
type startup_output =
  | Written_to of string
  | Not_kept of { path : string; reason : string }

let startup_output_file ~port =
  Filename.concat
    (Filename.concat Common.masc_dirname "logs")
    (Printf.sprintf "masc-server-%d.log" port)

let startup_output_path ~base_path ~port =
  Filename.concat base_path (startup_output_file ~port)

type exit_observation =
  | Still_running
  | Exited_with of Unix.process_status
  | Reaped_elsewhere

type owned_server = {
  pgid : int;
  output : startup_output;
  observed : exit_observation Atomic.t;
}

let owned_pgid t = t.pgid
let startup_output t = t.output

(* waitpid hands a status to one caller only. The first answer is kept, so a
   second observer -- the readiness waiter and the next start both look --
   reads the same exit instead of ECHILD. *)
let observe_exit t =
  match Atomic.get t.observed with
  | (Exited_with _ | Reaped_elsewhere) as settled -> settled
  | Still_running ->
    let settle observation =
      if Atomic.compare_and_set t.observed Still_running observation then
        observation
      else Atomic.get t.observed
    in
    (match Unix.waitpid [ Unix.WNOHANG ] t.pgid with
     | 0, _ -> Still_running
     | _, status -> settle (Exited_with status)
     | exception Unix.Unix_error (Unix.ECHILD, _, _) -> settle Reaped_elsewhere
     | exception Unix.Unix_error (Unix.EINTR, _, _) -> Still_running)

let is_running t =
  match observe_exit t with
  | Still_running -> true
  | Exited_with _ | Reaped_elsewhere -> false

type last_line =
  | Said of string
  | Said_nothing
  | Unreadable of string

let last_line_of_text text =
  match
    String.split_on_char '\n' text
    |> List.rev_map String.trim
    |> List.find_opt (fun line -> not (String.equal line ""))
  with
  | Some line -> Said line
  | None -> Said_nothing

let describe_last_line = function
  | Said line -> line
  | Said_nothing -> "it wrote nothing before exiting"
  | Unreadable reason -> "its output could not be read: " ^ reason

(* A refusal is the last thing a server writes, so the tail is enough, and
   bounding the read keeps a server that ran for days before dying from
   being loaded whole. The cut can land inside a line; that fragment is
   dropped unless it is the only line there is. *)
let output_tail_bytes = 65_536

let read_last_line path =
  match
    In_channel.with_open_bin path (fun ic ->
      let length = In_channel.length ic in
      let from = Int64.max 0L (Int64.sub length (Int64.of_int output_tail_bytes)) in
      In_channel.seek ic from;
      (from, In_channel.input_all ic))
  with
  | exception Sys_error reason -> Unreadable reason
  | from, text ->
    let whole_lines =
      match String.index_opt text '\n' with
      | Some newline when Int64.compare from 0L > 0 ->
        String.sub text (newline + 1) (String.length text - newline - 1)
      | Some _ | None -> text
    in
    last_line_of_text whole_lines

type exit_report = {
  status : string;
  last_line : last_line;
  output : startup_output;
}

let status_text = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "killed by OCaml signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped by OCaml signal %d" signal

let exit_report (t : owned_server) =
  let report status =
    let last_line =
      match t.output with
      | Written_to path -> read_last_line path
      | Not_kept _ -> Said_nothing
    in
    Some { status; last_line; output = t.output }
  in
  match observe_exit t with
  | Still_running -> None
  | Exited_with status -> report (status_text status)
  | Reaped_elsewhere -> report "exit status already collected elsewhere"

let describe_output = function
  | Written_to path -> "full output: " ^ path
  | Not_kept { path; reason } ->
    Printf.sprintf "output was not kept (%s): %s" reason path

(* The file is opened before the spawn so a failure to open it is known
   before there is a child to explain. It does not stop the start: the log
   is how a failure is explained, and refusing a server over it would make
   the explanation the failure. *)
let open_startup_output ~base_path ~port =
  let path = startup_output_path ~base_path ~port in
  match
    Fs_compat.mkdir_p (Filename.dirname path);
    Unix.openfile path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_APPEND; Unix.O_CLOEXEC ]
      0o644
  with
  | fd -> (Written_to path, Some fd)
  | exception Unix.Unix_error (error, _, _) ->
    (Not_kept { path; reason = Unix.error_message error }, None)
  | exception Sys_error reason -> (Not_kept { path; reason }, None)

let start ~masc_bin ~flags ~base_path ~host ~port ~env =
  let argv = server_argv ~masc_bin ~flags ~base_path ~host ~port in
  let output, fd = open_startup_output ~base_path ~port in
  let spawned =
    match fd with
    | Some output_fd ->
      let spawned =
        Process_eio_detached.spawn_detached_writing_to ~argv ~env ~cwd:base_path
          ~output:output_fd
      in
      (try Unix.close output_fd with Unix.Unix_error _ -> ());
      spawned
    | None -> Process_eio_detached.spawn_detached_devnull ~argv ~env ~cwd:base_path
  in
  match spawned with
  | Ok handle ->
      Ok
        {
          pgid = handle.Process_eio_detached.devnull_pgid;
          output;
          observed = Atomic.make Still_running;
        }
  | Error msg -> Error msg

let stop t ~grace_sec =
  Process_eio_detached.tree_kill ~pgid:t.pgid ~signal:Sys.sigterm ~grace_sec

(* RFC-0470 §4.2: the supervisor of a server started from a terminal. *)

type terminal =
  | Controlling_terminal
  | No_controlling_terminal

let terminal_device = "/dev/tty"

(* open(2) is not one of the calls that stop a background job; only reading
   the terminal, or writing it under [stty tostop], is. *)
let rec controlling_terminal () =
  match
    Unix.openfile terminal_device [ Unix.O_RDONLY; Unix.O_NOCTTY; Unix.O_CLOEXEC ] 0
  with
  | fd ->
    (try Unix.close fd with Unix.Unix_error _ -> ());
    Controlling_terminal
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> controlling_terminal ()
  | exception Unix.Unix_error ((_ : Unix.error), _, _) -> No_controlling_terminal

type ended =
  | Ended of Unix.process_status
  | Ended_unobserved

(* The signals a terminal sends its foreground job (^C, ^\, hangup) and the
   one a shell or [kill] sends by default. RFC-0470 §4.2 turns each into a
   SIGTERM to the server, which shuts down as it does on its own SIGTERM. *)
let forwarded_signals = [ Sys.sigint; Sys.sigterm; Sys.sighup; Sys.sigquit ]

(* The handler runs before [start] returns the group as well: a ^C pressed
   while the server is being spawned is kept in [requested] and sent once the
   group is known. *)
type forwarding = {
  group : int option Atomic.t;
  requested : bool Atomic.t;
}

(* ESRCH: the group is gone. EPERM: Darwin's answer for a group whose members
   are all exiting or zombies. Either way nothing is left to stop. *)
let terminate_group pgid =
  try Unix.kill (-pgid) Sys.sigterm
  with Unix.Unix_error ((Unix.ESRCH | Unix.EPERM), _, _) -> ()

let forward_signals forwarding =
  let forward (_ : int) =
    Atomic.set forwarding.requested true;
    Option.iter terminate_group (Atomic.get forwarding.group)
  in
  List.iter
    (fun signal ->
      match Sys.signal signal (Sys.Signal_handle forward) with
      | Sys.Signal_ignore -> Sys.set_signal signal Sys.Signal_ignore
      | Sys.Signal_default | Sys.Signal_handle _ -> ())
    forwarded_signals

let forward_to forwarding pgid =
  Atomic.set forwarding.group (Some pgid);
  if Atomic.get forwarding.requested then terminate_group pgid

let rec write_all fd buffer offset length =
  if length > 0 then
    match Unix.single_write fd buffer offset length with
    | written -> write_all fd buffer (offset + written) (length - written)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> write_all fd buffer offset length
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
      (* A terminal is shared: another program may have made it
         non-blocking. Wait until it takes more instead of dropping output. *)
      (match Unix.select [] [ fd ] [] (-1.0) with
       | (_ : Unix.file_descr list * Unix.file_descr list * Unix.file_descr list) -> ()
       | exception Unix.Unix_error (Unix.EINTR, _, _) -> ());
      write_all fd buffer offset length

(* A notice goes to a terminal that may already be gone; there is nobody
   left to tell that it could not be written. *)
let notice fd text =
  let line = Bytes.of_string ("masc start: " ^ text ^ "\n") in
  try write_all fd line 0 (Bytes.length line) with Unix.Unix_error _ -> ()

(* How long the follower waits before it looks for more output and for the
   server's end again. It bounds how late a line or the exit shows; the
   server never waits on it. *)
let follow_interval_s = 0.2

let follow_chunk_bytes = 65_536

type copy =
  | Copying of Unix.file_descr
      (** The startup output file, read up to where the last copy stopped. *)
  | Not_copying

let open_output_copy ~notices = function
  | Written_to path -> (
    match Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
    | fd -> Copying fd
    | exception Unix.Unix_error (error, _, _) ->
      notice notices
        (Printf.sprintf "the server's output is not shown here (%s): %s"
           (Unix.error_message error) path);
      Not_copying)
  | Not_kept _ as output ->
    notice notices ("the server's output is not shown here; " ^ describe_output output);
    Not_copying

let stop_copying fd =
  (try Unix.close fd with Unix.Unix_error _ -> ());
  Not_copying

(* Copies what the file holds past the last read, up to its current end. *)
let rec copy_available ~into ~notices buffer = function
  | Not_copying -> Not_copying
  | Copying source as copying -> (
    match Unix.read source buffer 0 (Bytes.length buffer) with
    | 0 -> copying
    | count -> (
      match write_all into buffer 0 count with
      | () -> copy_available ~into ~notices buffer copying
      | exception Unix.Unix_error ((_ : Unix.error), _, _) ->
        (* The terminal or pipe this copied to is gone. The server keeps
           writing its file; only the copy ends. *)
        stop_copying source)
    | exception Unix.Unix_error (Unix.EINTR, _, _) ->
      copy_available ~into ~notices buffer copying
    | exception Unix.Unix_error (error, _, _) ->
      notice notices
        ("stopped showing the server's output: " ^ Unix.error_message error);
      stop_copying source)

let rec follow (t : owned_server) ~into ~notices buffer copying =
  let copying = copy_available ~into ~notices buffer copying in
  let finish ended =
    (match copy_available ~into ~notices buffer copying with
     | Copying source -> ignore (stop_copying source : copy)
     | Not_copying -> ());
    ended
  in
  match observe_exit t with
  | Still_running ->
    Unix.sleepf follow_interval_s;
    follow t ~into ~notices buffer copying
  | Exited_with (Unix.WEXITED _ as status) -> finish (Ended status)
  | Exited_with ((Unix.WSIGNALED _ | Unix.WSTOPPED _) as status) ->
    let ended = finish (Ended status) in
    notice notices
      (Printf.sprintf "the server (pid %d) %s" t.pgid (Process_exit_text.of_status status));
    ended
  | Reaped_elsewhere ->
    let ended = finish Ended_unobserved in
    notice notices
      (Printf.sprintf "the server (pid %d) ended; its exit status was collected elsewhere"
         t.pgid);
    ended

let supervise ~masc_bin ~flags ~base_path ~host ~port ~env ~into ~notices =
  let forwarding = { group = Atomic.make None; requested = Atomic.make false } in
  forward_signals forwarding;
  match start ~masc_bin ~flags ~base_path ~host ~port ~env with
  | Error _ as error -> error
  | Ok (server : owned_server) ->
    forward_to forwarding server.pgid;
    let copying = open_output_copy ~notices server.output in
    Ok (follow server ~into ~notices (Bytes.create follow_chunk_bytes) copying)

(* [observe_exit] waits without WUNTRACED, so a stop is never reported; it
   shares the signal arm only because [Unix.process_status] carries it. *)
let exit_code = function
  | Ended (Unix.WEXITED code) -> code
  | Ended (Unix.WSIGNALED signal | Unix.WSTOPPED signal) -> 128 + Sys.signal_to_int signal
  | Ended_unobserved -> 1

type settled_start = {
  server : owned_server;
  host : string;
  port : int;
  outcome : exit_report health_outcome;
}

(* Newest first; [take_settled] turns it round. The waiter is a fiber of the
   loop's own switch, but nothing here relies on that. *)
type settled_starts = settled_start list Atomic.t

let create_settled_starts () = Atomic.make []

let rec keep starts settled =
  let held = Atomic.get starts in
  if not (Atomic.compare_and_set starts held (settled :: held)) then keep starts settled

let await_start starts server ~host ~port ~health_ok ~attempts ~sleep ~on_settled =
  let outcome =
    wait_healthy ~health_ok ~child_exit:(fun () -> exit_report server) ~attempts ~sleep
  in
  keep starts { server; host; port; outcome };
  on_settled ()

let take_settled starts = List.rev (Atomic.exchange starts [])
