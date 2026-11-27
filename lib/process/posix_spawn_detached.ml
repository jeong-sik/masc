external posix_spawn
  :  string
  -> string array
  -> string array
  -> (string option * bool)
  -> (int * Unix.file_descr) list
  -> int
  = "masc_posix_spawn"

type t = { pid : int; started : string option; exited : Unix.process_status option Eio.Promise.t }

type parent =
  | Parent of int
  | No_process
  | Unreadable

external darwin_start : int -> string option = "masc_process_start_time"

(* [None]: the Darwin process table did not answer, on another platform or
   because the sysctl failed. [Some None]: it answered with no such process. *)
external darwin_parent : int -> int option option = "masc_process_parent_pid"

(* starttime counts from boot, so the boot names it too. *)
let linux_start pid =
  match
    ( Linux_proc_stat.parse (Linux_proc_stat.read pid)
    , In_channel.with_open_bin "/proc/sys/kernel/random/boot_id" In_channel.input_all )
  with
  | exception (Unix.Unix_error (_, _, _) | Sys_error _) -> None
  | Some line, boot -> Some (Printf.sprintf "proc:%s:%s" (String.trim boot) line.Linux_proc_stat.start)
  | None, _ -> None

let process_start pid =
  match darwin_start pid with
  | Some _ as started -> started
  | None -> linux_start pid

(* ENOENT names both a pid /proc does not hold and, on a host without /proc,
   every pid; whether /proc/self is there tells the two apart. *)
let linux_parent pid =
  match Linux_proc_stat.parse (Linux_proc_stat.read pid) with
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ESRCH), _, _) when Sys.file_exists "/proc/self/stat" ->
    No_process
  | exception Unix.Unix_error (_, _, _) -> Unreadable
  | Some line -> Parent line.Linux_proc_stat.parent
  | None -> Unreadable

(* pid_t is a signed 32-bit integer on Darwin and on Linux. A number outside
   it is answered here, so it reads the same on every platform instead of
   reaching /proc or the sysctl. *)
let largest_pid = Int32.to_int Int32.max_int

let parent_pid pid =
  if pid <= 0 || pid > largest_pid
  then No_process
  else
    match darwin_parent pid with
    | Some (Some parent) -> Parent parent
    | Some None -> No_process
    | None -> linux_parent pid

let rec reaped pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> None
  | _, status -> Some (Some status)
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> reaped pid
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> Some None

(* [output] may be numbered 0, 1 or 2 -- a process whose standard descriptors
   are closed gets one of those for the next file it opens. The spawn stub
   reads every source before it writes a target, so it is passed as it is. *)
let spawn_with ~executable ~argv ~env ~output =
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close devnull with Unix.Unix_error _ -> ())
    (fun () ->
      posix_spawn executable (Array.of_list argv) env (None, true) [ 0, devnull; 1, output; 2, output ])

external sigchld_has_handler : unit -> bool = "masc_process_sigchld_has_handler"

let sigchld_install = Mutex.create ()

(* Only a backend that installs a SIGCHLD handler broadcasts the condition a
   reaper waits on. eio_posix installs one when its loop starts; eio_linux
   reaps through process descriptors and installs none, so there the wait
   never ended and the child stayed defunct (#33807).

   The handler is installed when a spawn finds none, not on every spawn:
   [Sys.set_signal] writes the runtime's handler table, which another domain
   reads while it polls for signals (#51395). Whether one is there is read
   from the kernel, so a handler removed since the last spawn is installed
   again. The lock makes a second domain's spawn wait for an installation
   under way instead of installing too. Nothing inside it yields. *)
let ensure_sigchld_handler () =
  Mutex.protect sigchld_install (fun () ->
    if not (sigchld_has_handler ()) then Eio_unix.Process.install_sigchld_handler ())

let spawn ~sw ~argv ~env ~output =
  match argv with
  | [] -> Error "posix_spawn: empty argv"
  | executable :: _ ->
    Eio.Switch.check sw;
    ensure_sigchld_handler ();
    let started =
      match spawn_with ~executable ~argv ~env ~output with
      | pid -> Ok pid
      | exception Unix.Unix_error (code, call, target) ->
        (* [target] is what [call] failed on: "/dev/null" for openfile, the
           executable for posix_spawn. *)
        Error (Printf.sprintf "%s %s: %s" call target (Unix.error_message code))
    in
    Result.map
      (fun pid ->
        (* Read before the reaper below can reap it: until then the number is
           this child's, even if it has already exited. *)
        let start = process_start pid in
        let exited, set_exited = Eio.Promise.create () in
        Eio.Fiber.fork_daemon ~sw (fun () ->
          Eio.Promise.resolve set_exited
            (Eio.Condition.loop_no_mutex Eio_unix.Process.sigchld (fun () -> reaped pid));
          `Stop_daemon);
        { pid; started = start; exited })
      started

(* kill(2) reads 0 as the caller's own group and -1 as every process the
   caller may signal, so neither is a group here. EPERM is either a group of
   another account's processes or, on Darwin, one whose members are all
   exiting or zombies (Process_group_members); the kernel's member snapshot
   tells them apart, and without one the group is taken to be there. *)
let group_id_has_members group =
  group > 1
  &&
  match Unix.kill (-group) 0 with
  | () ->
    (* kill(2) also reaches zombies, which are not processes left running. *)
    (match Process_group_members.proc_live_member_left group with
     | Some false -> false
     | Some true | None -> true)
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | exception Unix.Unix_error (Unix.EPERM, _, _) ->
    Option.value ~default:true (Process_group_members.live_member_left group)
