open Eio.Std

external posix_spawn
  :  string
  -> string array
  -> string array
  -> string option
  -> (int * Unix.file_descr) list
  -> int
  = "masc_posix_spawn"

type t =
  { pid : int
  ; exit_status : Unix.process_status Promise.t
  ; lock : Stdlib.Mutex.t
  }

(* [lock] orders signalling against reaping: once the child is reaped its pid
   may be reused, so [signal] checks [exit_status] under the lock. *)
let signal t signal =
  Stdlib.Mutex.lock t.lock;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock t.lock)
    (fun () -> if not (Promise.is_resolved t.exit_status) then Unix.kill t.pid signal)
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
    type t = unit

    let spawn_unix () ~sw ?cwd ~env ~fds ~executable args =
      let cwd = Option.map Eio.Path.native_exn cwd in
      Switch.check sw;
      let exit_status, set_exit_status = Promise.create () in
      let child_fds = List.map (fun (child_fd, _, _) -> child_fd) fds in
      let modes = List.map (fun (_, _, mode) -> mode) fds in
      let pid =
        Eio_unix.Fd.use_exn_list "posix_spawn" (List.map (fun (_, fd, _) -> fd) fds)
        @@ fun unix_fds ->
        List.iter2 apply_blocking unix_fds modes;
        Eio.Private.Trace.with_span "spawn" (fun () ->
          posix_spawn executable (Array.of_list args) env cwd (List.combine child_fds unix_fds))
      in
      let t = { pid; exit_status; lock = Stdlib.Mutex.create () } in
      let hook =
        Switch.on_release_cancellable sw (fun () ->
          signal t Sys.sigkill;
          if not (Promise.is_resolved t.exit_status) then reap t set_exit_status)
      in
      Fiber.fork_daemon ~sw (fun () ->
        reap t set_exit_status;
        Switch.remove_hook hook;
        `Stop_daemon);
      process t
    ;;
  end

  include Eio_unix.Process.Make_mgr (T)
end

let mgr : Eio_unix.Process.mgr_ty Eio.Resource.t =
  let handler = Eio_unix.Process.Pi.mgr_unix (module Impl) in
  Eio.Resource.T ((), handler)
;;
