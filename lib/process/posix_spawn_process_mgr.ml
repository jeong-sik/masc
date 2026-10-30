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

type group_phase = Running | Terminating of Monotonic_deadline.t | Killed | Reaping

type group_owner = {
  sleep : float -> unit;
  grace_seconds : float;
  waitpid : int -> int * Unix.process_status;
  mutable phase : group_phase;
}

type t =
  { pid : int
  ; started : string option
  ; exit_status : (Unix.process_status, exn) result Promise.t
  ; reaper_failure : exn Promise.t
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
  | Unix.Unix_error (Unix.EPERM, _, _)
    when Process_group_members.group_has_no_live_member t.pid -> ()
;;

let signal t signal =
  locked t (fun () ->
    if not (Promise.is_resolved t.exit_status) then
      match t.group with
      | None -> Unix.kill t.pid signal
      | Some { phase = Reaping; _ } -> ()
      | Some ({ phase = Running | Terminating _ | Killed; _ } as owner) ->
        kill_group t signal;
        if signal = Sys.sigkill then owner.phase <- Killed
        else if signal = Sys.sigterm then
          match owner.phase with
          | Running -> owner.phase <- Terminating
              (Monotonic_deadline.after ~seconds:owner.grace_seconds)
          | Terminating _ | Killed | Reaping -> ());
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
      Promise.resolve_ok set_exit_status status;
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
      else if owner.phase = Reaping then Some `Await
      else
        let delay = match owner.phase with
          | Terminating deadline -> Monotonic_deadline.remaining_seconds deadline
          | Running | Killed | Reaping -> 0. in
        if delay > 0. then Some (`Sleep delay)
        else (
          (match owner.phase with
           | Terminating _ -> kill_group t Sys.sigkill; owner.phase <- Killed
           | Running | Killed | Reaping -> ());
          if not (exited_without_reaping t.pid) then None
          else (
            (* [Killed] records an already successful whole-group SIGKILL.
               Repeating it after exit can fail on Darwin's zombie-only group.
               Normal completion still kills descendants before PID release. *)
            (match owner.phase with
             | Killed | Reaping -> ()
             | Running | Terminating _ ->
               kill_group t Sys.sigkill;
               owner.phase <- Killed);
            Some `Reap)))) in
  match next with
  | `Done -> ()
  | `Await -> ignore (Promise.await_exn t.exit_status : Unix.process_status)
  | `Sleep seconds -> owner.sleep seconds; reap_group t owner set_exit_status
  | `Reap ->
    (* WNOWAIT retains the PID through the final group signal. Finish with a
       blocking wait in a system thread: a WNOHANG zero must neither crash the
       caller nor wait for a second SIGCHLD that may never arrive. *)
    Eio.Cancel.protect (fun () ->
      let claimed = locked t (fun () ->
        if Promise.is_resolved t.exit_status || owner.phase = Reaping then false
        else (owner.phase <- Reaping; true)) in
      if not claimed then ignore (Promise.await_exn t.exit_status : Unix.process_status)
      else
        let rec wait () =
          try owner.waitpid t.pid with
          | Unix.Unix_error (Unix.EINTR, _, _) -> wait () in
        let wait_error = ref None in
        let settle () =
          match Eio_unix.run_in_systhread wait with
          | reaped, status ->
            assert (reaped = t.pid);
            locked t (fun () -> Promise.resolve_ok set_exit_status status)
          | exception exn ->
            (* Preserve the failure for a concurrent cleanup waiter as well. *)
            let bt = Printexc.get_raw_backtrace () in
            locked t (fun () -> Promise.resolve_error set_exit_status exn);
            wait_error := Some (exn,bt)
        in
        (* Claiming [Reaping] commits us to resolving the owner promise.
           A diagnostic writer may propagate cancellation, but cannot skip
           the actual wait or leave cleanup awaiting an unresolved promise. *)
        Fun.protect ~finally:settle (fun () ->
          Exec_tap.record_lifecycle ~pid:t.pid ~stage:Waitpid_started ());
        match !wait_error with
        | Some (exn,bt) -> Printexc.raise_with_backtrace exn bt
        | None ->
          Exec_tap.record_lifecycle ~pid:t.pid ~stage:Waitpid_returned ();
          Exec_tap.record_lifecycle ~pid:t.pid ~stage:Exit_published ())

;;

let reap_owned t set_exit_status =
  match t.group with
  | None -> reap t set_exit_status
  | Some owner -> reap_group t owner set_exit_status
;;

(* A protected caller may already be awaiting this handle when its switch is
   cancelled. The switch cannot run release hooks until that caller finishes,
   so the reaper must settle its original child before leaving cancellation. *)
let stop_owned t set_exit_status =
  signal t (match t.group with None -> Sys.sigkill | Some _ -> Sys.sigterm);
  if not (Promise.is_resolved t.exit_status) then reap_owned t set_exit_status
;;

module Process_impl = struct
  type nonrec t = t
  type tag = [ `Generic | `Unix ]

  let pid t = t.pid

  let await t =
    let observed = Fiber.first
        (fun () -> Promise.await t.exit_status)
        (fun () -> Error (Promise.await t.reaper_failure)) in
    (* A release hook may subsequently finish the original reap after a
       pre-reap failure. Prefer that physical result once it exists. Keep
       errors as data inside [first], whose exception combiner could otherwise
       replace a concurrently completed exit with the old reaper failure. *)
    let status = match Promise.peek t.exit_status with
      | Some status -> status
      | None -> observed in
    match status with
    | Ok (Unix.WEXITED code) -> `Exited code
    | Ok (Unix.WSIGNALED signal) -> `Signaled signal
    | Ok (Unix.WSTOPPED _) -> assert false
    | Error exn -> raise exn
  ;;

  let signal = signal
end

type (_, _, _) Eio.Resource.pi +=
  | Original_start : ('t, 't -> string option, [> `Process ]) Eio.Resource.pi

let original_start (Eio.Resource.T (proc, handler)) =
  match Eio.Resource.get_opt handler Original_start with
  | Some read -> read proc
  | None -> None
;;

let process =
  let handler = Eio.Resource.handler
      (Eio.Resource.H (Original_start, (fun t -> t.started)) ::
       Eio.Resource.bindings (Eio.Process.Pi.process (module Process_impl))) in
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
      let cwd = Option.map
          (fun path ->
             (* Preserve the filesystem refusal before libc can collapse a
                missing cwd into the executable's ENOENT. Close the probe
                immediately; a caller's switch may outlive many commands. *)
             Eio.Path.with_open_dir path (fun _ -> Eio.Path.native_exn path))
          cwd in
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
      let reaper_failure, report_reaper_failure = Promise.create () in
      let child_fds = List.map (fun (child_fd, _, _) -> child_fd) fds in
      let modes = List.map (fun (_, _, mode) -> mode) fds in
      let pid =
        Eio_unix.Fd.use_exn_list "posix_spawn" (List.map (fun (_, fd, _) -> fd) fds)
        @@ fun unix_fds ->
        List.iter2 apply_blocking unix_fds modes;
        Eio.Private.Trace.with_span "spawn" (fun () ->
          posix_spawn executable (Array.of_list args) env (cwd, Option.is_some group) (List.combine child_fds unix_fds))
      in
      (* There is no reaper for this child yet, including if it already exited.
         Retain this observation before hooks, diagnostic writers or fork can
         yield and release the original PID. Never reconstruct it from a PID
         after [spawn] returns. *)
      let started = Posix_spawn_detached.process_start pid in
      let t = { pid; started; exit_status; reaper_failure; lock = Stdlib.Mutex.create (); group } in
      let hook =
        Switch.on_release_cancellable sw (fun () -> stop_owned t set_exit_status)
      in
      Exec_tap.record_lifecycle ~pid ~stage:(Spawned args) ();
      Fiber.fork_daemon ~sw (fun () ->
        let run () = match reap_owned t set_exit_status with
          | () -> ()
          | exception (Eio.Cancel.Cancelled _ as exn) ->
            let bt = Printexc.get_raw_backtrace () in
            Eio.Cancel.protect (fun () -> stop_owned t set_exit_status);
            Printexc.raise_with_backtrace exn bt in
        match run () with
        | () -> Switch.remove_hook hook; `Stop_daemon
        | exception exn ->
          let bt = Printexc.get_raw_backtrace () in
          (* An unsuccessful stop/reap must wake protected waiters too. This
             is not physical exit: keep the original owner and release hook
             so cleanup still runs rather than trusting a failed promise. *)
          if not (Promise.is_resolved exit_status) then
            Promise.resolve report_reaper_failure exn
          else Switch.remove_hook hook;
          Printexc.raise_with_backtrace exn bt);
      process t
    ;;
  end

  include Eio_unix.Process.Make_mgr (T)
end

let mgr : Eio_unix.Process.mgr_ty Eio.Resource.t =
  let handler = Eio_unix.Process.Pi.mgr_unix (module Impl) in
  Eio.Resource.T ((fun () -> None), handler)
;;

let foreground_mgr_with_waitpid ~clock ~grace_seconds ~waitpid =
  let handler = Eio_unix.Process.Pi.mgr_unix (module Impl) in
  Eio.Resource.T
    ((fun () -> Some { sleep = Eio.Time.sleep clock; grace_seconds; waitpid; phase = Running }), handler)
;;

let foreground_mgr ~clock ~grace_seconds =
  foreground_mgr_with_waitpid ~clock ~grace_seconds
    ~waitpid:(Unix.waitpid [])
;;

module For_testing = struct
  let foreground_mgr = foreground_mgr_with_waitpid
end
