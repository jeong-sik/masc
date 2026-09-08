open Eio.Std

external posix_spawn
  :  string
  -> string array
  -> string array
  -> (string option * bool)
  -> (int * Unix.file_descr) list
  -> int
  = "masc_posix_spawn"

external exited_without_reaping : int -> bool = "masc_process_exited_without_reaping"

type group_phase = Running | Terminating of Monotonic_deadline.t | Killed

type group_owner = {
  sleep : float -> unit;
  grace_seconds : float;
  mutable phase : group_phase;
}

type t =
  { pid : int
  ; exit_status : Unix.process_status Promise.t
  ; lock : Stdlib.Mutex.t
  ; group : group_owner option
  }

(* [lock] orders signalling against reaping: once the child is reaped its pid
   may be reused, so [signal] checks [exit_status] under the lock. *)
let locked t f =
  Stdlib.Mutex.lock t.lock;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock t.lock) f
;;

let kill_group t signal =
  try Unix.kill (-t.pid) signal with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> ()
;;

let signal t signal =
  locked t (fun () ->
    if not (Promise.is_resolved t.exit_status) then
      match t.group with
      | None -> Unix.kill t.pid signal
      | Some owner ->
        kill_group t signal;
        if signal = Sys.sigkill then owner.phase <- Killed
        else if signal = Sys.sigterm then
          match owner.phase with
          | Running -> owner.phase <- Terminating
              (Monotonic_deadline.after ~seconds:owner.grace_seconds)
          | Terminating _ | Killed -> ());
  (* A termination request must wake a daemon waiting for SIGCHLD even
     when the leader ignores TERM. The deadline belongs to the owner. *)
  Eio.Condition.broadcast Eio_unix.Process.sigchld
;;

let reap t set_exit_status =
  Eio.Condition.loop_no_mutex Eio_unix.Process.sigchld (fun () ->
    Stdlib.Mutex.lock t.lock;
    match Unix.waitpid [ WNOHANG ] t.pid with
    | 0, _ ->
      Stdlib.Mutex.unlock t.lock;
      None
    | reaped, status ->
      assert (reaped = t.pid);
      Promise.resolve set_exit_status status;
      Stdlib.Mutex.unlock t.lock;
      Some ())
;;

(* WNOWAIT holds the leader's PID until the last group signal. No numeric
   PGID escapes this owner. Normal completion kills remaining foreground
   descendants before reaping immediately; detached work uses another API. *)
let rec reap_group t owner set_exit_status =
  let next = Eio.Condition.loop_no_mutex Eio_unix.Process.sigchld (fun () ->
    locked t (fun () ->
      if Promise.is_resolved t.exit_status then Some `Done
      else
        let delay = match owner.phase with
          | Terminating deadline -> Monotonic_deadline.remaining_seconds deadline
          | Running | Killed -> 0. in
        if delay > 0. then Some (`Sleep delay)
        else (
          (match owner.phase with
           | Terminating _ -> kill_group t Sys.sigkill; owner.phase <- Killed
           | Running | Killed -> ());
          if not (exited_without_reaping t.pid) then None
          else (
            kill_group t Sys.sigkill;
            let reaped, status = Unix.waitpid [ WNOHANG ] t.pid in
            assert (reaped = t.pid);
            Promise.resolve set_exit_status status;
            Some `Done)))) in
  match next with
  | `Done -> ()
  | `Sleep seconds -> owner.sleep seconds; reap_group t owner set_exit_status
;;

let reap_owned t set_exit_status =
  match t.group with
  | None -> reap t set_exit_status
  | Some owner -> reap_group t owner set_exit_status
;;

module Process_impl = struct
  type nonrec t = t
  type tag = [ `Generic | `Unix ]

  let pid t = t.pid

  let await t =
    match Promise.await t.exit_status with
    | Unix.WEXITED code -> `Exited code
    | Unix.WSIGNALED signal -> `Signaled signal
    | Unix.WSTOPPED _ -> assert false
  ;;

  let signal = signal
end

let process =
  let handler = Eio.Process.Pi.process (module Process_impl) in
  fun proc -> Eio.Resource.T (proc, handler)
;;

(* The blocking mode eio's fork action would set in the child is set here on
   the parent's descriptor: a dup2'd descriptor shares its open file
   description, so the child-side fcntl changed the same flags. *)
let apply_blocking (fd : Unix.file_descr) (mode : Eio_unix.Private.Fork_action.blocking) =
  match mode with
  | `Blocking -> Unix.clear_nonblock fd
  | `Nonblocking -> Unix.set_nonblock fd
  | `Preserve_blocking -> ()
;;

module Impl = struct
  module T = struct
    type t = unit -> group_owner option

    let spawn_unix make_group ~sw ?cwd ~env ~fds ~executable args =
      let group = make_group () in
      let cwd = Option.map Eio.Path.native_exn cwd in
      Switch.check sw;
      (* [reap] below waits on [Eio_unix.Process.sigchld], and only a backend
         that installs a SIGCHLD handler ever broadcasts it. eio_posix does;
         eio_linux reaps through process descriptors and installs none, so on
         Linux the wait never ends and the child stays defunct -- four suites
         sat that way for over an hour in the 2026-09-06 nightly (#33807).
         Installed here rather than once at startup because that is the point
         a child can first exit, and set every spawn rather than behind a flag
         because [Sys.set_signal] is idempotent and a flag would let a second
         domain spawn while the first is still installing. *)
      Eio_unix.Process.install_sigchld_handler ();
      let exit_status, set_exit_status = Promise.create () in
      let child_fds = List.map (fun (child_fd, _, _) -> child_fd) fds in
      let modes = List.map (fun (_, _, mode) -> mode) fds in
      let pid =
        Eio_unix.Fd.use_exn_list "posix_spawn" (List.map (fun (_, fd, _) -> fd) fds)
        @@ fun unix_fds ->
        List.iter2 apply_blocking unix_fds modes;
        Eio.Private.Trace.with_span "spawn" (fun () ->
          posix_spawn executable (Array.of_list args) env (cwd, Option.is_some group) (List.combine child_fds unix_fds))
      in
      let t = { pid; exit_status; lock = Stdlib.Mutex.create (); group } in
      let hook =
        Switch.on_release_cancellable sw (fun () ->
          signal t (match t.group with None -> Sys.sigkill | Some _ -> Sys.sigterm);
          if not (Promise.is_resolved t.exit_status) then reap_owned t set_exit_status)
      in
      Fiber.fork_daemon ~sw (fun () ->
        reap_owned t set_exit_status;
        Switch.remove_hook hook;
        `Stop_daemon);
      process t
    ;;
  end

  include Eio_unix.Process.Make_mgr (T)
end

let mgr : Eio_unix.Process.mgr_ty Eio.Resource.t =
  let handler = Eio_unix.Process.Pi.mgr_unix (module Impl) in
  Eio.Resource.T ((fun () -> None), handler)
;;

let foreground_mgr ~clock ~grace_seconds =
  let handler = Eio_unix.Process.Pi.mgr_unix (module Impl) in
  Eio.Resource.T
    ((fun () -> Some { sleep = Eio.Time.sleep clock; grace_seconds; phase = Running }), handler)
;;
