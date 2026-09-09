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

let rec resume_syscall operation =
  try operation () with
  | Unix.Unix_error (Unix.EINTR, _, _) -> resume_syscall operation

(* A returned PGID must already name the child's own process group. The
   close-on-exec pipe is private to this fork; EOF before the readiness byte
   means the child failed during session/cwd/descriptor setup. No timer can
   establish this ordering. This is intentionally separate from exec success. *)
let fork_session_ready ~child_setup ~child_exec =
  let ready_r, ready_w = Unix.pipe ~cloexec:true () in
  let reader_open = ref true and writer_open = ref true in
  let close_reader () = if !reader_open then (reader_open := false; close_quietly ready_r) in
  let close_writer () = if !writer_open then (writer_open := false; close_quietly ready_w) in
  let child_pid = ref None in
  let reap_failed_child () =
    match !child_pid with
    | None -> ()
    | Some pid ->
      (* An interrupted parent read may race with successful readiness/exec.
         The unreaped leader reserves its PID, so first kill its possible
         group (including descendants), then the child itself in case setsid
         never established that group. Reap only this owned PID. *)
      let kill_owned target =
        try resume_syscall (fun () -> Unix.kill target Sys.sigkill) with
        | Unix.Unix_error (Unix.ESRCH, _, _) -> ()
      in
      kill_owned (-pid);
      kill_owned pid;
      (try
         (* The rejected handle has no status consumer. Waiting still owns
            the reap; only ECHILD means there is nothing left to collect. *)
         let _reaped_pid, _terminal_status = resume_syscall (fun () -> Unix.waitpid [] pid) in
         ()
       with Unix.Unix_error (Unix.ECHILD, _, _) -> ());
      child_pid := None
  in
  Fun.protect
    ~finally:(fun () -> close_reader (); close_writer ())
    (fun () ->
      match Unix.fork () with
      | 0 ->
        close_reader ();
        (try
           let session_id = resume_syscall Unix.setsid in
           if session_id <> Unix.getpid () then Unix._exit 126;
           child_setup ();
           let ready = Bytes.of_string "R" in
           if resume_syscall (fun () -> Unix.write ready_w ready 0 1) <> 1
           then Unix._exit 126
         with
         (* This is the fork child, not the parent's Eio fiber. Unwinding
            inherited handlers could execute parent cleanup in the child. *)
         | Eio.Cancel.Cancelled _ -> Unix._exit 126
         | _ -> Unix._exit 126);
        close_writer ();
        (try child_exec () with
         | Eio.Cancel.Cancelled _ -> Unix._exit 127
         | _ -> Unix._exit 127)
      | pid ->
        child_pid := Some pid;
        close_writer ();
        (try
           let ready = Bytes.create 1 in
           let count = resume_syscall (fun () -> Unix.read ready_r ready 0 1) in
           if count <> 1 || Bytes.get ready 0 <> 'R'
           then failwith "child exited before detached session setup was ready";
           child_pid := None;
           pid
         with exn ->
           let backtrace = Printexc.get_raw_backtrace () in
           reap_failed_child ();
           Printexc.raise_with_backtrace exn backtrace))

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
         let pid = fork_session_ready
           ~child_setup:(fun () ->
             if cwd <> "" then resume_syscall (fun () -> Unix.chdir cwd);
             resume_syscall (fun () -> Unix.dup2 devnull Unix.stdin);
             resume_syscall (fun () -> Unix.dup2 out_w Unix.stdout);
             resume_syscall (fun () -> Unix.dup2 err_w Unix.stderr);
             close_quietly out_r; close_quietly err_r;
             close_quietly out_w; close_quietly err_w; close_quietly devnull)
           ~child_exec:(fun () -> Unix.execvpe bin (Array.of_list argv) env)
         in
         begin
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
         let pid = fork_session_ready
           ~child_setup:(fun () ->
             if cwd <> "" then resume_syscall (fun () -> Unix.chdir cwd);
             resume_syscall (fun () -> Unix.dup2 devnull Unix.stdin);
             resume_syscall (fun () -> Unix.dup2 devnull Unix.stdout);
             resume_syscall (fun () -> Unix.dup2 devnull Unix.stderr);
             close_quietly devnull)
           ~child_exec:(fun () -> Unix.execvpe bin (Array.of_list argv) env)
         in
         begin
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
    let deadline = Monotonic_deadline.after ~seconds:grace_sec in
    let step = min 0.1 (grace_sec /. 10.0) in
    let rec wait_loop () =
      if not (is_pgid_alive ~pgid) then ()
      else if Monotonic_deadline.passed deadline then
        safe_kill Sys.sigkill
      else begin
        Safe_ops.protect ~default:() (fun () -> ignore (Unix.select [] [] [] step));
        wait_loop ()
      end
    in
    wait_loop ()
  end
