(** Detached background spawn primitives for Execute process tasks.

    Extracted from [process_eio.ml] during godfile decomposition.
    Provides posix_spawn-based process group spawning with tree-kill
    lifecycle.

    @since God file decomposition *)

let close_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()

type detached_handle = {
  pid : int;
  pgid : int;
  stdout_fd : Unix.file_descr;
  stderr_fd : Unix.file_descr;
  started_at : float;
}

type detached_devnull_handle = {
  devnull_pid : int;
  devnull_pgid : int;
  devnull_started_at : float;
}

(* [posix_spawn] with POSIX_SPAWN_SETPGROUP establishes the child's process
   group atomically during spawn — before the child runs any user code.  This
   removes the fork/setpgrp signal-race window that the previous fork()+setsid()
   implementation left open (a signal delivered to the parent group between
   fork and setpgrp could reach the child).  POSIX_SPAWN_SETSID is also set so
   the child becomes a new session leader, preserving the "detach from the
   parent's controlling terminal" semantics of the old setsid() call.

   The C stub (posix_spawn_detached_stubs.c) wires stdin/stdout/stderr via
   file actions and chdir via posix_spawn_file_actions_addchdir_np. *)
external posix_spawn_detached :
  string array -> string array -> string -> Unix.file_descr array -> int
  = "caml_masc_process_posix_spawn_detached"

let spawn_detached ~argv ~env ~cwd =
  match argv with
  | [] -> Error "spawn_detached: empty argv"
  | _ ->
      let out_r_ref = ref None in
      let out_w_ref = ref None in
      let err_r_ref = ref None in
      let err_w_ref = ref None in
      let devnull_ref = ref None in
      let remember slot fd =
        slot := Some fd;
        fd
      in
      let close_registered slot =
        match !slot with
        | None -> ()
        | Some fd ->
            close_quietly fd;
            slot := None
      in
      let cleanup_setup_fds () =
        List.iter close_registered
          [ out_r_ref; out_w_ref; err_r_ref; err_w_ref; devnull_ref ]
      in
      (try
         let out_r, out_w = Unix.pipe ~cloexec:true () in
         let out_r = remember out_r_ref out_r in
         let out_w = remember out_w_ref out_w in
         let err_r, err_w = Unix.pipe ~cloexec:true () in
         let err_r = remember err_r_ref err_r in
         let err_w = remember err_w_ref err_w in
         let devnull =
           remember devnull_ref
             (Unix.openfile "/dev/null" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0)
         in
         let pid =
           posix_spawn_detached
             (Array.of_list argv)
             env
             cwd
             [| devnull; out_w; err_w |]
         in
         (* --- PARENT --- *)
         close_registered out_w_ref;
         close_registered err_w_ref;
         close_registered devnull_ref;
         out_r_ref := None;
         err_r_ref := None;
         Ok
           {
             pid;
             pgid = pid;
             stdout_fd = out_r;
             stderr_fd = err_r;
             started_at = Unix.gettimeofday ();
           }
       with
       | Unix.Unix_error (err, fn, arg) ->
           cleanup_setup_fds ();
           Error
             (Printf.sprintf "spawn_detached %s: %s (%s %s)"
                (List.hd argv) (Unix.error_message err) fn arg)
       | exn ->
           cleanup_setup_fds ();
           Error
             (Printf.sprintf "spawn_detached %s: %s" (List.hd argv)
                (Printexc.to_string exn)))

let spawn_detached_devnull ~argv ~env ~cwd =
  match argv with
  | [] -> Error "spawn_detached_devnull: empty argv"
  | _ ->
      let devnull_ref = ref None in
      let cleanup_setup_fds () =
        match !devnull_ref with
        | None -> ()
        | Some fd ->
            close_quietly fd;
            devnull_ref := None
      in
      (try
         let devnull =
           Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0
         in
         devnull_ref := Some devnull;
         let pid =
           posix_spawn_detached
             (Array.of_list argv)
             env
             cwd
             [| devnull; devnull; devnull |]
         in
         cleanup_setup_fds ();
         Ok
           {
             devnull_pid = pid;
             devnull_pgid = pid;
             (* NDT-OK: detached process lifecycle telemetry records wall-clock
                start time; command behavior remains process-boundary driven. *)
             devnull_started_at = Unix.gettimeofday ();
           }
       with
       | Unix.Unix_error (err, fn, arg) ->
           cleanup_setup_fds ();
           Error
             (Printf.sprintf "spawn_detached_devnull %s: %s (%s %s)"
                (List.hd argv) (Unix.error_message err) fn arg)
       | exn ->
           cleanup_setup_fds ();
           Error
             (Printf.sprintf "spawn_detached_devnull %s: %s" (List.hd argv)
                (Printexc.to_string exn)))

let is_pgid_alive ~pgid =
  try
    Unix.kill (-pgid) 0;
    true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) ->
      (* EPERM means the process exists but we can't signal it —
         conservative "alive" answer. *)
      true
  | _ -> false

let tree_kill ~pgid ~signal ~grace_sec =
  let safe_kill s =
    try Unix.kill (-pgid) s
    with
    | Unix.Unix_error (Unix.ESRCH, _, _) -> ()
    | Unix.Unix_error (Unix.EPERM, _, _) ->
        (* macOS can return EPERM after all processes in the group
           have exited but the session object lingers. Treat as
           "already gone". *)
        ()
  in
  safe_kill signal;
  if grace_sec > 0.0 then begin
    let deadline = Unix.gettimeofday () +. grace_sec in
    let step = min 0.1 (grace_sec /. 10.0) in
    let rec wait_loop () =
      if not (is_pgid_alive ~pgid) then ()
      else if Unix.gettimeofday () >= deadline then
        safe_kill Sys.sigkill
      else begin
        Safe_ops.protect ~default:() (fun () -> ignore (Unix.select [] [] [] step));
        wait_loop ()
      end
    in
    wait_loop ()
  end
