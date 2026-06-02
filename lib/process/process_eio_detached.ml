(** Detached background spawn primitives for Execute process tasks.

    Extracted from [process_eio.ml] during godfile decomposition.
    Provides fork-based process group spawning with tree-kill lifecycle.

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

let spawn_detached ~argv ~env ~cwd =
  match argv with
  | [] -> Error "spawn_detached: empty argv"
  | bin :: _ ->
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
         (* Use fork/exec instead of create_process_env so the child
            can [setpgrp] before [execvpe].  OCaml's Unix module does
            not expose [setpgid(pid, pgid)] for the parent to call on
            a child, so the child has to establish its own process
            group authoritatively.  A short window between fork and
            setpgrp still leaves the child in the parent's group — any
            signal delivered to the parent group in that window would
            also reach the child.  Acceptable for background shells;
            signal-race-free semantics would require posix_spawn with
            POSIX_SPAWN_SETPGROUP via Ctypes, a follow-up item. *)
         let pid = Unix.fork () in
         if pid = 0 then begin
           (* --- CHILD --- *)
           (* [Unix.setsid] creates a new session AND a new process
              group with the child as leader.  OCaml's stdlib does not
              expose [setpgid], so [setsid] is the portable way to
              guarantee a new group.  Side effect: the child detaches
              from the parent's controlling terminal, which matches
              the "background shell" semantics we want. *)
           Safe_ops.protect ~default:() (fun () -> ignore (Unix.setsid ()));
           (try
              if cwd <> "" then Unix.chdir cwd
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | _ -> Unix._exit 126);
           Unix.dup2 devnull Unix.stdin;
           Unix.dup2 out_w Unix.stdout;
           Unix.dup2 err_w Unix.stderr;
           Unix.close out_r; Unix.close err_r;
           Unix.close out_w; Unix.close err_w; Unix.close devnull;
           (try Unix.execvpe bin (Array.of_list argv) env
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | _ -> Unix._exit 127)
         end else begin
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
         end
       with
       | Unix.Unix_error (err, fn, arg) ->
           cleanup_setup_fds ();
           Error
             (Printf.sprintf "spawn_detached %s: %s (%s %s)"
                bin (Unix.error_message err) fn arg)
       | exn ->
           cleanup_setup_fds ();
           Error
             (Printf.sprintf "spawn_detached %s: %s" bin
                (Printexc.to_string exn)))

let spawn_detached_devnull ~argv ~env ~cwd =
  match argv with
  | [] -> Error "spawn_detached_devnull: empty argv"
  | bin :: _ ->
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
         let pid = Unix.fork () in
         if pid = 0 then begin
           Safe_ops.protect ~default:() (fun () -> ignore (Unix.setsid ()));
           (try
              if cwd <> "" then Unix.chdir cwd
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | _ -> Unix._exit 126);
           Unix.dup2 devnull Unix.stdin;
           Unix.dup2 devnull Unix.stdout;
           Unix.dup2 devnull Unix.stderr;
           Unix.close devnull;
           (try Unix.execvpe bin (Array.of_list argv) env
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | _ -> Unix._exit 127)
         end else begin
           cleanup_setup_fds ();
           Ok
             {
               devnull_pid = pid;
               devnull_pgid = pid;
               (* NDT-OK: detached process lifecycle telemetry records wall-clock
                  start time; command behavior remains process-boundary driven. *)
               devnull_started_at = Unix.gettimeofday ();
             }
         end
       with
       | Unix.Unix_error (err, fn, arg) ->
           cleanup_setup_fds ();
           Error
             (Printf.sprintf "spawn_detached_devnull %s: %s (%s %s)"
                bin (Unix.error_message err) fn arg)
       | exn ->
           cleanup_setup_fds ();
           Error
             (Printf.sprintf "spawn_detached_devnull %s: %s" bin
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
