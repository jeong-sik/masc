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
           (* Successful setsid establishes this child as session/group leader.
              The parent already owns its PID; it needs only the ready signal. *)
           let _session_id = resume_syscall Unix.setsid in
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

(* Wires the fork child's standard descriptors. dup2 runs one call at a time,
   so a source numbered 0, 1 or 2 -- what a process whose standard descriptors
   were closed gets for its next pipe or file -- would be overwritten by an
   earlier call before it is read, and a source already at its own target
   would keep its close-on-exec flag and vanish at exec (#47475). Each such
   source is first copied above the standard range, so the three calls are
   independent of their order. The child has one thread: dup(2) taking the
   lowest free number races with nothing here, and a copy left on a standard
   number is overwritten by the dup2 for that number.

   The sources are not closed afterwards. One numbered 0, 1 or 2 now names
   the child's standard stream, and every descriptor this module opens is
   close-on-exec. *)
let connect_standard ~stdin ~stdout ~stderr =
  let rec above_standard fd =
    if fd = Unix.stdin || fd = Unix.stdout || fd = Unix.stderr
    then above_standard (resume_syscall (fun () -> Unix.dup ~cloexec:true fd))
    else fd
  in
  let stdin = above_standard stdin in
  let stdout = above_standard stdout in
  let stderr = above_standard stderr in
  resume_syscall (fun () -> Unix.dup2 stdin Unix.stdin);
  resume_syscall (fun () -> Unix.dup2 stdout Unix.stdout);
  resume_syscall (fun () -> Unix.dup2 stderr Unix.stderr)

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
             connect_standard ~stdin:devnull ~stdout:out_w ~stderr:err_w)
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
       | exn -> (* cancel-guard-ok: Unix fork and exec perform no Eio operation *)
           cleanup_setup_fds ();
           Error
             (Printf.sprintf "spawn_detached %s: %s" bin
                (Printexc.to_string exn)))

(* Where a pipe-less child's stdout and stderr go. Its stdin reads
   /dev/null either way. *)
type quiet_output =
  | Discard
  | Write_to of Unix.file_descr

let spawn_detached_quiet ~label ~argv ~env ~cwd ~output =
  match argv with
  | [] -> Error (label ^ ": empty argv")
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
         let out = match output with Discard -> devnull | Write_to fd -> fd in
         let pid = fork_session_ready
           ~child_setup:(fun () ->
             if cwd <> "" then resume_syscall (fun () -> Unix.chdir cwd);
             connect_standard ~stdin:devnull ~stdout:out ~stderr:out)
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
             (Printf.sprintf "%s %s: %s (%s %s)"
                label bin (Unix.error_message err) fn arg)
       | exn -> (* cancel-guard-ok: Unix fork and exec perform no Eio operation *)
           cleanup_setup_fds ();
           Error
             (Printf.sprintf "%s %s: %s" label bin
                (Printexc.to_string exn)))

let spawn_detached_devnull ~argv ~env ~cwd =
  spawn_detached_quiet ~label:"spawn_detached_devnull" ~argv ~env ~cwd
    ~output:Discard

let spawn_detached_writing_to ~argv ~env ~cwd ~output =
  spawn_detached_quiet ~label:"spawn_detached_writing_to" ~argv ~env ~cwd
    ~output:(Write_to output)

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
  | _ -> false (* cancel-guard-ok: Unix.kill performs no Eio operation *)

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
