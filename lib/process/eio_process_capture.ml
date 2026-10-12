(** Foreground Eio pipe capture and child cleanup. Caller policy and runtime
    state stay in Process_eio; all effects here receive their dependencies. *)

let close_flow_best_effort label flow =
  try Eio.Flow.close flow with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Misc.debug
      "[Process_eio] ignored %s close error: %s"
      label
      (Printexc.to_string exn)
;;

(* Typed Eio [Connection_reset] match.  This fires when a downstream reader
   (e.g. [head -20], [grep -m 1], [tail -n 5]) closes its stdin after
   consuming enough bytes — the kernel returns [EPIPE] / [SIGPIPE] on the
   next [writev] from the upstream pipe writer, and Eio surfaces it as
   [Eio.Net.E (Connection_reset _)] wrapped in [Eio.Io].  Operationally
   this is the *normal* termination of a piped command, not a failure;
   the spawned process completed its work and exited cleanly while we
   were still flushing.  Live measurement on 5/21: 39+ events/day of
   plain [head -20] / [head -30] invocations logging this at ERROR.

   Returns [true] for the downstream-closed-pipe case so callers can demote
   the log severity.  Does not match Connection_failure (genuine reach
   failure) or other [Eio.Net.error] variants. *)
let is_downstream_pipe_closed = function
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) -> true
  | Unix.Unix_error (Unix.EPIPE, _, _) -> true
  | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (Unix.EPIPE, _, _)), _) -> true
  | Sys_error msg
    when String_util.contains_substring (String.lowercase_ascii msg) "broken pipe" ->
    true
  | _ -> false
[@@warning "-4"]

let unix_status_of_eio_status = function
  | `Exited n -> Unix.WEXITED n
  | `Signaled n -> Unix.WSIGNALED n

(** How long a child has between SIGTERM and SIGKILL, on both reap paths:
    the ordinary reap in {!reap_proc_with_clock} and the cancellation path
    in {!finalize_spawned_proc}. One number, so that a child stopped by a
    timeout and a child stopped by a cancelled switch get the same chance to
    close what they were writing. *)
let child_exit_grace_seconds = 2.0

(** Reap a child process deterministically.

    The Eio spawn helper registers the handle with a switch, but relying solely
    on switch finalizers leaves a window where the child keeps running after a
    timeout/cancel.  This helper sends [SIGTERM], waits
    {!child_exit_grace_seconds}, then escalates to [SIGKILL].  It is safe to
    call on an already-exited process.

    What follows the [SIGKILL] depends on [sw], read again once the grace has
    run out. [Eio.Process.await] is resolved by the foreground manager's
    reap daemon in the switch the child was spawned in. When that
    switch is cancelled while this reap is waiting -- a keeper turn aborted,
    or a shutdown, arriving during the grace -- the daemon is gone and the
    await would never return, while the switch's release hook, which sends
    the non-cancellable [SIGKILL] and [waitpid]s the child
    ([Posix_spawn_process_mgr.Impl.T.spawn_unix]), runs only once every fiber of the switch has
    returned, this one included. So a switch that is off after the grace gets
    the [SIGKILL] and no wait: its release hook is the authority for the last
    reap. A switch that is still on gets the await, bounded by the same grace:
    a child that has not died that long after a [SIGKILL] is in a state no
    wait here can change, and the release hook reaps it all the same. *)
let reap_proc_with_clock ~sw clock proc =
  let signal_best_effort sig_ =
    try Eio.Process.signal proc sig_ with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Log.Misc.warn
        "[Process_eio] failed to signal child with signal=%d: %s"
        sig_
        (Printexc.to_string exn)
  in
  let await_within_grace () =
    Watched_work.run
      (fun () ->
        match Eio.Process.await proc with
        | `Exited _ | `Signaled _ -> `Exited)
      ~watcher:(fun () ->
        Eio.Time.sleep clock child_exit_grace_seconds;
        `Still_running)
  in
  let escalate_to_sigkill () =
    signal_best_effort Sys.sigkill;
    match Eio.Switch.get_error sw with
    | Some (_ : exn) ->
      Log.Misc.debug
        "[Process_eio] owning switch went off during the %.1fs grace; SIGKILL sent, its release hook reaps the child"
        child_exit_grace_seconds
    | None ->
      (match await_within_grace () with
       | `Exited -> ()
       | `Still_running ->
         Log.Misc.warn
           "[Process_eio] child not reaped %.1fs after SIGKILL; leaving it to the switch release hook"
           child_exit_grace_seconds)
  in
  signal_best_effort Sys.sigterm;
  match await_within_grace () with
  | `Exited -> ()
  | `Still_running -> escalate_to_sigkill ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Log.Misc.warn
      "[Process_eio] graceful child reap failed; escalating to SIGKILL: %s"
      (Printexc.to_string exn);
    escalate_to_sigkill ()

let drain_chunk_size = 4096

(* Read [r] to EOF and drop the bytes. The cancellation path reads for one
   reason only: to notice the child letting go of the pipe. Nothing it says
   from here on is returned to anyone. *)
let rec discard_to_eof r chunk =
  match
    try Eio.Flow.single_read r chunk with
    | End_of_file -> 0
  with
  | 0 -> ()
  | _ -> discard_to_eof r chunk

(* Cancellation has stopped the owning switch's reap daemon. Neither EOF
   nor absence of capture pipes proves the child exited: it may close its
   streams before finishing a TERM handler. Keep the existing TERM grace
   independently of pipe lifetime, without awaiting the cancelled daemon or
   reaping the PID owned by the switch release hook. Only this cancellation
   path pays the full grace; an observed successful exit never enters it. *)
let wait_for_child_to_let_go ~clock sources =
  let chunk = Cstruct.create drain_chunk_size in
  match
    Eio.Time.with_timeout clock child_exit_grace_seconds (fun () ->
      List.iter
        (fun (label, r) ->
           try discard_to_eof r chunk with
           | Eio.Io _ | Invalid_argument _ ->
             Log.Misc.debug
               "[Process_eio] %s unavailable during cancellation grace"
               label)
        sources;
      (* EOF releases a stream, not ownership of the child. *)
      Eio.Fiber.await_cancel ())
  with
  | Error `Timeout -> ()
  | Ok () -> assert false

(* Runs in the [Fun.protect] finalizer of every spawn helper, so it sees three
   states: the child exited and [status] is set; the body raised and the child
   may still be running; or the owning switch was cancelled.

   [sinks] are this side's write ends (stdin) and close first, so a child
   blocked on its input sees EOF before it is asked to stop. [sources] are the
   read ends; on the cancellation path they are what the grace is waited out
   on while preserving the full grace, so they close last there. *)
let finalize_spawned_proc ~sw ~clock proc status ~sinks ~sources =
  (* Two ways to get here with no status. This fiber was cancelled while [sw]
     lives on: the caller's explicit timeout race, where the
     daemon that resolves [await] is a fiber of [sw] and still running, so
     the child is reaped the ordinary way. Or [sw] itself is off: a stop
     request, where that daemon is gone, awaiting it would deadlock the switch
     before its release hook can reap the child, and pipe closure cannot establish that the child exited. Reading this fiber's own
     cancellation as the switch's sent every exec timeout down the second
     path, and a 0.2s budget returned when the child's orphaned grandchild
     closed the pipe two seconds later (#33182). Record the switch's state
     before entering the protected cleanup context. A switch that is on here
     can still be cancelled while the ordinary reap waits out its grace, and
     that reap reads the state again before deciding what to wait on. *)
  let owning_switch_cancelled = Option.is_some (Eio.Switch.get_error sw) in
  let close_all flows =
    List.iter (fun (label, flow) -> close_flow_best_effort label flow) flows
  in
  Eio.Cancel.protect (fun () ->
    close_all sinks;
    match !status, owning_switch_cancelled with
    | Some _, _ -> close_all sources
    | None, false ->
      close_all sources;
      reap_proc_with_clock ~sw clock proc
    | None, true ->
      (* The owning Eio switch release hook performs the non-cancellable
         SIGKILL/waitpid before [Switch.run] re-raises the cancellation. It
         does not wait first: until the grace below existed, the child had the
         time between two consecutive lines of code to act on SIGTERM.
         Measured 2026-09-04 on the voice recorder, that was a quarter second
         of audio lost from the end of every stopped capture. *)
      (try Eio.Process.signal proc Sys.sigterm with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Misc.warn
           "[Process_eio] failed to request child termination during switch cancellation: %s"
           (Printexc.to_string exn));
      wait_for_child_to_let_go ~clock sources;
      close_all sources)

let invoke_output_chunk_callback f s =
  try f s with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Log.Misc.warn
        "[Process_eio] output chunk callback error, continuing: %s"
        (Printexc.to_string exn)

(* Read [r] to EOF into the bounded [acc], invoking [on_chunk] per read.

   Reading continues past the retention ceiling on purpose: stopping early
   would SIGPIPE a child that is still doing legitimate work and would lose
   both the exit status and the stream tail. [Exec_buffer] discards the
   middle instead, so this loop is O(bytes) in time and O(caps) in space. *)
let rec drain_into ?file_capture r acc ~on_chunk chunk =
  match
    try Eio.Flow.single_read r chunk with
    | End_of_file -> 0
  with
  | 0 ->
      Option.iter
        (fun (capture, stream) ->
          Process_output_capture.end_of_stream capture ~stream)
        file_capture;
      Eio.Flow.close r
  | n ->
      let s = Cstruct.to_string (Cstruct.sub chunk 0 n) in
      Option.iter
        (fun (capture, stream) -> Process_output_capture.append capture ~stream s)
        file_capture;
      invoke_output_chunk_callback on_chunk s;
      Exec_buffer.add_string acc s;
      drain_into ?file_capture r acc ~on_chunk chunk

let ignore_chunk (_ : string) = ()

let drain_to_eof ?file_capture ?(on_chunk = ignore_chunk) r acc =
  drain_into ?file_capture r acc ~on_chunk (Cstruct.create drain_chunk_size)

(** Spawn a process with explicit pipes and drain stdout into [stdout_buf]
    before returning.  Draining inline (rather than handing the pipe to a
    background copier) avoids a race where [Eio.Process.await] returns —
    process exited — while data still sits unread in the pipe, which
    surfaced as truncated or empty output.

    The shape mirrors [Eio.Process.parse_out]: create pipes, close write ends
    after spawn, read to EOF, then await the exit status. *)
let spawn_and_drain_stdout ?phase_ref ~sw pm ~cwd ?env ?stdin_source ~clock argv stdout_buf =
  let stdout_r, stdout_w = Eio.Process.pipe ~sw pm in
  let proc =
    Eio.Process.spawn ~sw
      (Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:child_exit_grace_seconds) ~cwd ?env
      ?stdin:stdin_source
      ~stdout:stdout_w
      argv
  in
  (* spawn returned — any further timeout is attributable to the
     child, not to process creation.  Callers thread [phase_ref] so the
     timeout branches can label the metric accordingly. *)
  Option.iter (fun r -> r := Timeout_origin.Command) phase_ref;
  Eio.Flow.close stdout_w;
  let status = ref None in
  (* The finalizer closes pipe FDs and cancellation-protects the complete
     cleanup. On ordinary exceptions it reaps directly; on switch cancellation
     the owning Eio process hook performs the protected reap. *)
  Fun.protect
    ~finally:(fun () ->
      finalize_spawned_proc ~sw ~clock proc status ~sinks:[] ~sources:[ "stdout", stdout_r ])
    (fun () ->
      drain_to_eof stdout_r stdout_buf ~on_chunk:ignore_chunk;
      let s = Eio.Process.await proc in
      status := Some s;
      s)
  |> unix_status_of_eio_status

let spawn_and_drain_both ?phase_ref ?output_capture ~sw pm ~cwd ?env ?stdin_source ~clock argv
    ?(on_stdout_chunk = ignore_chunk) ?(on_stderr_chunk = ignore_chunk) stdout_buf stderr_buf =
  let stdout_r, stdout_w = Eio.Process.pipe ~sw pm in
  let stderr_r, stderr_w = Eio.Process.pipe ~sw pm in
  let proc =
    Eio.Process.spawn ~sw
      (Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:child_exit_grace_seconds) ~cwd ?env
      ?stdin:stdin_source
      ~stdout:stdout_w
      ~stderr:stderr_w
      argv
  in
  Option.iter (fun r -> r := Timeout_origin.Command) phase_ref;
  Eio.Flow.close stdout_w;
  Eio.Flow.close stderr_w;
  let status = ref None in
  (* Cancellation-protected yielding cleanup; see [spawn_and_drain_stdout]. *)
  Fun.protect
    ~finally:(fun () ->
      finalize_spawned_proc ~sw ~clock proc status ~sinks:[]
        ~sources:[ "stdout", stdout_r; "stderr", stderr_r ])
    (fun () ->
      Eio.Fiber.both
        (fun () ->
          drain_to_eof
            ?file_capture:(Option.map (fun c -> c, Process_output_capture.Stdout) output_capture)
            stdout_r stdout_buf ~on_chunk:on_stdout_chunk)
        (fun () ->
          drain_to_eof
            ?file_capture:(Option.map (fun c -> c, Process_output_capture.Stderr) output_capture)
            stderr_r stderr_buf ~on_chunk:on_stderr_chunk);
      let s = Eio.Process.await proc in
      status := Some s;
      s)
  |> unix_status_of_eio_status

(** Write one request to child stdin, then keep the pipe open while stdout and
    stderr drain. Some framed protocols use stdin EOF as an out-of-band cancel
    signal, so [Eio.Flow.string_source] is not correct for them: it closes as
    soon as the request bytes have been copied. The owning switch closes
    [stdin_w] on cancellation, which preserves the same deterministic child
    reap path as the other spawn helpers. *)
let spawn_and_drain_both_with_stdin_held_open
    ?phase_ref
    ~sw
    pm
    ~cwd
    ?env
    ~stdin_content
    ~clock
    argv
    ?(on_stdout_chunk = ignore_chunk)
    ?(on_stderr_chunk = ignore_chunk)
    stdout_buf
    stderr_buf
  =
  let stdin_r, stdin_w = Eio.Process.pipe ~sw pm in
  let stdout_r, stdout_w = Eio.Process.pipe ~sw pm in
  let stderr_r, stderr_w = Eio.Process.pipe ~sw pm in
  let proc =
    Eio.Process.spawn ~sw
      (Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds:child_exit_grace_seconds) ~cwd ?env ~stdin:stdin_r ~stdout:stdout_w
      ~stderr:stderr_w argv
  in
  Option.iter (fun r -> r := Timeout_origin.Command) phase_ref;
  Eio.Flow.close stdin_r;
  Eio.Flow.close stdout_w;
  Eio.Flow.close stderr_w;
  let status = ref None in
  Fun.protect
    ~finally:(fun () ->
      finalize_spawned_proc ~sw ~clock proc status
        ~sinks:[ "stdin", stdin_w ]
        ~sources:[ "stdout", stdout_r; "stderr", stderr_r ])
    (fun () ->
      (try Eio.Flow.copy_string stdin_content stdin_w with
       | exn when is_downstream_pipe_closed exn -> ());
      Eio.Fiber.both
        (fun () -> drain_to_eof stdout_r stdout_buf ~on_chunk:on_stdout_chunk)
        (fun () -> drain_to_eof stderr_r stderr_buf ~on_chunk:on_stderr_chunk);
      let s = Eio.Process.await proc in
      status := Some s;
      s)
  |> unix_status_of_eio_status
