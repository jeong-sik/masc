external posix_spawn
  :  string
  -> string array
  -> string array
  -> (string option * bool)
  -> (int * Unix.file_descr) list
  -> int
  = "masc_posix_spawn"

type t = { pid : int; exited : Unix.process_status option Eio.Promise.t }

let rec reaped pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> None
  | _, status -> Some (Some status)
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> reaped pid
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> Some None

let standard fd = fd = Unix.stdin || fd = Unix.stdout || fd = Unix.stderr

(* posix_spawn applies the descriptor actions in order, so a source that is
   itself 0, 1 or 2 would be overwritten by an earlier action before it is
   copied. A process whose standard descriptors are closed gets one of those
   numbers for the next file it opens. Every descriptor this opens or copies
   goes into [opened], which the caller closes once. *)
let above_standard ~opened fd =
  let rec lift fd =
    if standard fd then begin
      let copy = Unix.dup ~cloexec:true fd in
      opened := copy :: !opened;
      lift copy
    end
    else fd
  in
  lift fd

let spawn_with ~opened ~executable ~argv ~env ~output =
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  opened := devnull :: !opened;
  let devnull = above_standard ~opened devnull in
  let output = above_standard ~opened output in
  posix_spawn executable (Array.of_list argv) env (None, true) [ 0, devnull; 1, output; 2, output ]

let spawn ~sw ~argv ~env ~output =
  match argv with
  | [] -> Error "posix_spawn: empty argv"
  | executable :: _ ->
    (* Only a backend that installs a SIGCHLD handler broadcasts the
       condition [reaped] waits on (see Posix_spawn_process_mgr). *)
    Eio_unix.Process.install_sigchld_handler ();
    let opened = ref [] in
    let started =
      Fun.protect
        ~finally:(fun () ->
          List.iter (fun fd -> try Unix.close fd with Unix.Unix_error _ -> ()) !opened)
        (fun () ->
          match spawn_with ~opened ~executable ~argv ~env ~output with
          | pid -> Ok pid
          | exception Unix.Unix_error (code, call, target) ->
            (* [target] is what [call] failed on: "/dev/null" for openfile,
               the executable for posix_spawn, nothing for dup. *)
            let call = if String.equal target "" then call else Printf.sprintf "%s %s" call target in
            Error (Printf.sprintf "%s: %s" call (Unix.error_message code)))
    in
    Result.map
      (fun pid ->
        let exited, set_exited = Eio.Promise.create () in
        Eio.Fiber.fork_daemon ~sw (fun () ->
          Eio.Promise.resolve set_exited
            (Eio.Condition.loop_no_mutex Eio_unix.Process.sigchld (fun () -> reaped pid));
          `Stop_daemon);
        { pid; exited })
      started

(* kill(2) reads 0 as the caller's own group and -1 as every process the
   caller may signal, so neither is a group here. *)
let group_id_has_members group =
  group > 1
  &&
  match Unix.kill (-group) 0 with
  | () -> true
  | exception Unix.Unix_error ((Unix.ESRCH | Unix.EPERM), _, _) -> false

let group_has_members t = group_id_has_members t.pid

let signal_group_id group signal =
  if group_id_has_members group then
    match Unix.kill (-group) signal with
    | () -> ()
    (* It emptied between the two calls. *)
    | exception Unix.Unix_error ((Unix.ESRCH | Unix.EPERM), _, _) -> ()

let signal_group t signal = signal_group_id t.pid signal

type stopped = Ended_on_term | Killed_after_grace

let group_poll_s = 0.1

(* SIGKILL ends a process once it returns to user space; one in an
   uninterruptible wait ends later. *)
let kill_settle_s = 1.

let await_empty ~clock ~seconds group =
  let deadline = Monotonic_deadline.after ~seconds in
  let rec wait () =
    if group_id_has_members group && not (Monotonic_deadline.passed deadline) then (
      Eio.Time.sleep clock group_poll_s;
      wait ())
  in
  wait ()

let stop_group_id ~clock ~grace_s group =
  signal_group_id group Sys.sigterm;
  let deadline = Monotonic_deadline.after ~seconds:grace_s in
  let rec wait () =
    if not (group_id_has_members group) then Ended_on_term
    else if Monotonic_deadline.passed deadline then (
      signal_group_id group Sys.sigkill;
      await_empty ~clock ~seconds:kill_settle_s group;
      Killed_after_grace)
    else (
      Eio.Time.sleep clock group_poll_s;
      wait ())
  in
  wait ()

let stop_group ~clock ~grace_s t = stop_group_id ~clock ~grace_s t.pid

external process_group_of : int -> int = "masc_process_group_of"

let group_of_pid pid =
  match process_group_of pid with
  | group -> Ok group
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
