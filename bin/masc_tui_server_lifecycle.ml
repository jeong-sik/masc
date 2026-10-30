(* On-demand background server startup. The server outlives the TUI. *)

(* What a completed refresh found at the port, in the vocabulary this
   decision is made in. The TUI reads it off the status the refresh left
   behind rather than off which message carried it: a refused connection is
   a handled per-surface error, so it arrives as a completed refresh whose
   every surface failed, not as a thrown one. Keeping the vocabulary here
   and the status in the TUI is what lets the rule run under a test with no
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
   look for beside the running TUI binary and on the PATH. *)
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

let server_argv ~masc_bin ~base_path ~host ~port =
  [
    masc_bin;
    "start";
    "--base-path";
    base_path;
    "--host";
    host;
    "--port";
    string_of_int port;
  ]

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

let start ~masc_bin ~base_path ~host ~port ~env =
  let argv = server_argv ~masc_bin ~base_path ~host ~port in
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
