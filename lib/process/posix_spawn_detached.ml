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

let group_has_members t =
  match Unix.kill (-t.pid) 0 with
  | () -> true
  | exception Unix.Unix_error ((Unix.ESRCH | Unix.EPERM), _, _) -> false

let signal_group t signal = try Unix.kill (-t.pid) signal with Unix.Unix_error _ -> ()

(* A graceful stop asks the whole group to end, then escalates once
   [grace_s] has passed without the group emptying. Both signals go to the
   group only, so a pre-existing process outside it is untouched; a group
   that already ended, or a pid the OS gave to another process, answers
   ESRCH or EPERM and counts as stopped. *)
let stop_group ~clock ?(grace_s = 5.0) t =
  signal_group t Sys.sigterm;
  if group_has_members t then begin
    let deadline = Monotonic_deadline.after ~seconds:grace_s in
    while group_has_members t && not (Monotonic_deadline.passed deadline) do
      Eio.Time.sleep clock 0.2
    done;
    if group_has_members t then signal_group t Sys.sigkill
  end

