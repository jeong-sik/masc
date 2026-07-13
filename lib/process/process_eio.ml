(** Async process execution helpers for Eio

    - argv-only APIs (no shell)
    - Global proc_mgr/clock initialized once from main_eio.ml

    This module is used by tool handlers where we want:
    - Non-blocking execution (Eio fibers)
    - Injection safety (no `sh -c`)
    - Consistent output capture (stdout; status APIs also surface stderr on failures)
*)

(** ── Global state (initialized once from main_eio.ml) ──────────── *)

type runtime = {
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  cwd_default : Eio.Fs.dir_ty Eio.Path.t;
}

(** [Atomic.t] rather than a plain [ref] because subprocess spawns from
    Executor_pool workers (distinct OCaml 5 domains) read this state;
    without a memory barrier a worker domain can observe [None] even
    after [init] has published the runtime on the main domain. *)
let runtime_state : runtime option Atomic.t = Atomic.make None

(** Origin at which an [Eio.Time.with_timeout_exn] budget was exhausted.

    The vocabulary is centralized in [Timeout_origin].  [Process_eio] only
    emits [Slot_wait], [Spawn], and [Command] origins. *)

(** Observability hook: invoked when an Eio process call hits its
    [timeout_sec] budget.  Default no-op so the lower [masc_process]
    layer carries no [Otel_metric_store] dependency.  Wired from [lib/workspace.ml]
    at module load to emit [masc_process_timeout_total].

    Cardinality: callers should pass [program = Filename.basename argv0]
    (~10-20 distinct programs fleet-wide); [timeout_sec] is the per-call
    budget (a few discrete values: 15.0, 60.0, ...); [origin] is restricted
    to [Timeout_origin.process_origins] — total label cardinality is bounded
    by [program × bucket × origin]. *)
let process_timeout_observer_fn :
    (program:string -> timeout_sec:float -> origin:Timeout_origin.t -> unit) Atomic.t =
  Atomic.make (fun ~program:_ ~timeout_sec:_ ~origin:_ -> ())

let argv_program = function
  | [] -> "<empty>"
  | prog :: _ -> Filename.basename prog

let observe_process_timeout argv ~timeout_sec ~origin =
  try
    (Atomic.get process_timeout_observer_fn)
      ~program:(argv_program argv) ~timeout_sec ~origin
  with exn ->
    Log.Misc.warn "[Process_eio] timeout observer failed: %s"
      (Printexc.to_string exn)

type spawn_guard = { run : 'a. (unit -> 'a) -> 'a }

let default_spawn_guard = { run = (fun f -> f ()) }
let spawn_guard : spawn_guard Atomic.t = Atomic.make default_spawn_guard
let set_spawn_guard guard = Atomic.set spawn_guard guard
let reset_spawn_guard_for_testing () = Atomic.set spawn_guard default_spawn_guard
let with_spawn_guard f = (Atomic.get spawn_guard).run f

let close_flow_best_effort label flow =
  try Eio.Flow.close flow with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Misc.debug
      "[Process_eio] ignored %s close error: %s"
      label
      (Printexc.to_string exn)
;;

let init ~cwd_default ~proc_mgr ~clock =
  Atomic.set runtime_state (Some { proc_mgr; clock; cwd_default })

let is_initialized () = Option.is_some (Atomic.get runtime_state)

let reset_for_testing () =
  Atomic.set runtime_state None;
  reset_spawn_guard_for_testing ()

let default_buffer_size = 1024

exception Explicit_process_timeout of float

let validate_timeout_sec = function
  | None -> None
  | Some timeout_sec
    when Float.is_finite timeout_sec && Float.compare timeout_sec 0.0 > 0 ->
    Some timeout_sec
  | Some timeout_sec ->
    invalid_arg
      (Printf.sprintf
         "Process_eio: explicit timeout_sec must be finite and greater than zero (got %g)"
         timeout_sec)

let with_explicit_timeout_exn clock timeout_sec f =
  match timeout_sec with
  | None -> f ()
  | Some timeout_sec ->
    (try Eio.Time.with_timeout_exn clock timeout_sec f with
     | Eio.Time.Timeout -> raise (Explicit_process_timeout timeout_sec))

let get_proc_mgr () =
  match Atomic.get runtime_state with
  | Some runtime -> Ok runtime.proc_mgr
  | None -> Error "Process_eio.get_proc_mgr: init not called"

let get_clock () =
  match Atomic.get runtime_state with
  | Some runtime -> Ok runtime.clock
  | None -> Error "Process_eio.get_clock: init not called"

let get_cwd_default () =
  match Atomic.get runtime_state with
  | Some runtime -> Ok runtime.cwd_default
  | None -> Error "Process_eio.get_cwd_default: init not called"

(** ── Unix fallback for tests (when Eio not initialized) ──────────── *)

let default_env = function
  | Some env -> env
  | None -> Unix.environment ()

(* [@@warning "-4"]: scrutinee is [exn] (extensible) — a wildcard arm is
   mandatory because new exception constructors can never be enumerated.
   RFC-0071 §3.4.1 sanctioned open-variant exemption, not a lazy
   catch-all over a closed sum. *)
let rec should_retry_unix_fallback = function
  | Unix.Unix_error
      ((Unix.EADDRINUSE | Unix.EADDRNOTAVAIL | Unix.EACCES | Unix.EPERM), "bind", _) ->
      true
  | Eio.Cancel.Cancelled exn -> should_retry_unix_fallback exn
  | _ -> false
[@@warning "-4"]

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
  | _ -> false
[@@warning "-4"]

let close_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> () (* intentional: best-effort cleanup *)

let create_process_env prog argv env stdin_fd stdout_fd stderr_fd =
  (** [Unix.create_process_env] does not accept a child working directory, and
      we no longer mutate the parent process CWD with [Sys.chdir].  The public
      [run_argv*] [?cwd] parameter is documented as ignored on the Unix
      fallback path; on the Eio path the spawn helper handles CWD correctly in
      the child via its [~cwd] argument.  This removes the process-wide
      [Sys.chdir] race documented in the adversarial audit (P0). *)
  Unix.create_process_env prog (Array.of_list argv) env stdin_fd stdout_fd stderr_fd

let output_for_status = Process_eio_stderr.output_for_status
let process_error_output = Process_eio_stderr.process_error_output
let reason_of_exn_for_output = Process_eio_stderr.reason_of_exn_for_output
let create_stderr_tempfile = Process_eio_stderr.create_stderr_tempfile
let remove_temp_file_quietly = Process_eio_stderr.remove_temp_file_quietly
let read_stderr_capture = Process_eio_stderr.read_stderr_capture
let captured_stderr_or_empty = Process_eio_stderr.captured_stderr_or_empty

let with_unix_capture ?env ?cwd ?stdin_content ?(capture_stderr = false)
    ?timeout_sec
    (argv : string list)
    ~(on_error : string -> string -> 'a)
    ~(on_success : Unix.process_status -> string -> string -> 'a) : 'a =
  let timeout_sec = validate_timeout_sec timeout_sec in
  let started_at = Unix.gettimeofday () in
  match argv with
  | [] -> on_error "empty argv" ""
  | prog :: _ ->
    let stdout_r_ref = ref None in
    let stdout_w_ref = ref None in
    let stderr_fd_ref = ref None in
    let stderr_path_ref = ref None in
    let stdin_r_ref = ref None in
    let stdin_w_ref = ref None in
    let cleanup () =
      Option.iter close_quietly !stdin_r_ref;
      stdin_r_ref := None;
      Option.iter close_quietly !stdin_w_ref;
      stdin_w_ref := None;
      Option.iter close_quietly !stdout_r_ref;
      stdout_r_ref := None;
      Option.iter close_quietly !stdout_w_ref;
      stdout_w_ref := None;
      Option.iter close_quietly !stderr_fd_ref;
      stderr_fd_ref := None;
      Option.iter
        remove_temp_file_quietly
        !stderr_path_ref;
      stderr_path_ref := None
    in
    (try
       let env = default_env env in
       let stdout_r, stdout_w = Unix.pipe ~cloexec:true () in
       stdout_r_ref := Some stdout_r;
       stdout_w_ref := Some stdout_w;
       (* stderr is captured into a temp file and read back after [waitpid]
          completes so the parent never blocks the child on an unread stderr
          pipe in Unix fallback mode. *)
       let stderr_fd =
         if capture_stderr
         then (
           let path, fd = create_stderr_tempfile () in
           stderr_path_ref := Some path;
           stderr_fd_ref := Some fd;
           fd)
         else
           Unix.stderr
       in
       let stdin_r_opt, stdin_w_opt =
         match stdin_content with
         | None -> (None, None)
         | Some _ ->
             let r, w = Unix.pipe ~cloexec:true () in
             (Some r, Some w)
       in
       stdin_r_ref := stdin_r_opt;
       stdin_w_ref := stdin_w_opt;
       let stdin_fd =
         match !stdin_r_ref with
         | Some fd -> fd
         | None -> Unix.stdin
       in
       let pid =
         create_process_env prog argv env stdin_fd stdout_w stderr_fd
       in
       Option.iter close_quietly !stdin_r_ref;
       stdin_r_ref := None;
       Option.iter close_quietly !stdout_w_ref;
       stdout_w_ref := None;
       (* The child inherited the descriptor during spawn; the parent no longer
          needs its copy once the process exits. *)
       Option.iter close_quietly !stderr_fd_ref;
       stderr_fd_ref := None;
       (match !stdout_r_ref with
        | None ->
            (* stdout pipe already consumed — treat as error *)
            cleanup ();
            on_error "stdout pipe unavailable during Unix fallback capture" ""
        | Some stdout_r ->
            (* Do NOT null [stdout_r_ref] here. read/select below can raise
               exceptions outside the narrow EAGAIN/EWOULDBLOCK/EINTR catch
               (EBADF on racing close, ENFILE under host fd pressure, etc.);
               the [exn] arm at the bottom of the [try] calls [cleanup ()]
               which relies on [stdout_r_ref] still being [Some] to close
               the pipe. Nulling here orphans the fd → host ENFILE storm
               trigger (2026-05-19 01:26Z, 13:01Z). The ref is nulled on
               the success path AFTER [close_quietly] below; [close_quietly]
               is idempotent so double-close from cleanup is harmless. *)
            let rec waitpid_blocking () =
              try Unix.waitpid [] pid
              with
              | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_blocking ()
              | Unix.Unix_error (Unix.ECHILD, _, _) -> (pid, Unix.WEXITED 127)
            in
            let kill_and_wait status_ref =
              (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
              if Option.is_none !status_ref then
                let (_pid, status) = waitpid_blocking () in
                status_ref := Some status
            in
            let waitpid_nohang () =
              try
                match Unix.waitpid [ Unix.WNOHANG ] pid with
                | 0, _ -> None
                | _, status -> Some status
              with
              | Unix.Unix_error (Unix.EINTR, _, _) -> None
              | Unix.Unix_error (Unix.ECHILD, _, _) -> Some (Unix.WEXITED 127)
            in
            let stdout_buf = Buffer.create default_buffer_size in
            let chunk = Bytes.create 4096 in
            let read_available () =
              let rec loop () =
                try
                  match Unix.read stdout_r chunk 0 (Bytes.length chunk) with
                  | 0 -> `Eof
                  | n ->
                      Buffer.add_subbytes stdout_buf chunk 0 n;
                      loop ()
                with
                | Unix.Unix_error
                    ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
                    `Would_block
                | Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
              in
              loop ()
            in
            let deadline =
              Option.map (fun seconds -> started_at +. seconds) timeout_sec
            in
            let deadline_reached () =
              match deadline with
              | None -> false
              | Some deadline -> Unix.gettimeofday () >= deadline
            in
            let select_wait () =
              match deadline with
              | None -> 0.05
              | Some deadline ->
                min 0.05 (max 0.0 (deadline -. Unix.gettimeofday ()))
            in
            let timed_out = ref false in
            let status_ref = ref None in
            let stdout_eof = ref false in
            let stdin_offset = ref 0 in
            let stdin_closed = ref (Option.is_none !stdin_w_ref) in
            let close_stdin () =
              Option.iter close_quietly !stdin_w_ref;
              stdin_w_ref := None;
              stdin_closed := true
            in
            let write_stdin_available stdin_w content =
              try
                let remaining = String.length content - !stdin_offset in
                if remaining = 0
                then close_stdin ()
                else (
                  let written =
                    Unix.write_substring stdin_w content !stdin_offset remaining
                  in
                  stdin_offset := !stdin_offset + written;
                  if !stdin_offset = String.length content then close_stdin ())
              with
              | Unix.Unix_error
                  ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) ->
                ()
              | Unix.Unix_error ((Unix.EPIPE | Unix.ECONNRESET), _, _) ->
                close_stdin ()
            in
            Unix.set_nonblock stdout_r;
            Option.iter Unix.set_nonblock !stdin_w_ref;
            (match stdin_content, !stdin_w_ref with
             | Some "", Some _ -> close_stdin ()
             | Some _, Some _ | None, None -> ()
             | None, Some _ | Some _, None -> close_stdin ());
            while (not (!stdout_eof && !stdin_closed)) && not !timed_out do
              if deadline_reached () then begin
                timed_out := true;
                close_stdin ();
                kill_and_wait status_ref;
                ignore (read_available () : [ `Eof | `Would_block ])
              end else begin
                let read_fds = if !stdout_eof then [] else [ stdout_r ] in
                let write_fds =
                  match !stdin_w_ref with
                  | Some stdin_w -> [ stdin_w ]
                  | None -> []
                in
                let readable, writable =
                  try
                    let ready_read, ready_write, _ =
                      Unix.select read_fds write_fds [] (select_wait ())
                    in
                    ready_read <> [], ready_write
                  with Unix.Unix_error (Unix.EINTR, _, _) -> false, []
                in
                if readable then (
                  match read_available () with
                  | `Eof -> stdout_eof := true
                  | `Would_block -> ());
                (match stdin_content, writable with
                 | Some content, stdin_w :: _ ->
                   write_stdin_available stdin_w content
                 | Some _, [] | None, _ -> ())
              end
            done;
            while (not !timed_out) && Option.is_none !status_ref do
              match waitpid_nohang () with
              | Some status -> status_ref := Some status
              | None ->
                  if deadline_reached () then begin
                    timed_out := true;
                    kill_and_wait status_ref
                  end else
                    (try
                       ignore (Unix.select [] [] [] (select_wait ()))
                     with Unix.Unix_error (Unix.EINTR, _, _) -> ())
            done;
            close_quietly stdout_r;
            stdout_r_ref := None;
            let status =
              if !timed_out then Unix.WEXITED 124
              else
                match !status_ref with
                | Some status -> status
                | None ->
                    let (_pid, status) = waitpid_blocking () in
                    status
            in
            let stdout = Buffer.contents stdout_buf in
            let stderr = captured_stderr_or_empty !stderr_path_ref in
            let timeout_event =
              if !timed_out then timeout_sec else None
            in
            let stderr =
              match timeout_event with
              | Some timeout_sec
                when String.trim stdout = "" && String.trim stderr = "" ->
                process_error_output
                  ~label:(String.concat " " (List.map Filename.quote argv))
                  ~reason:(Printf.sprintf "timeout after %.0fs" timeout_sec)
                  ()
              | Some _ | None -> stderr
            in
            (match timeout_event with
             | Some timeout_sec ->
               (* Unix fallback starts the timeout clock after
                  [create_process_env] returns, so this timeout is always
                  attributable to the running child. *)
               observe_process_timeout argv
                 ~timeout_sec
                 ~origin:Timeout_origin.Command
             | None -> ());
            cleanup ();
            on_success status stdout stderr)
     with
     | Eio.Cancel.Cancelled _ as exn ->
         cleanup ();
         raise exn
     | exn ->
         let stderr = captured_stderr_or_empty !stderr_path_ref in
         cleanup ();
         on_error (reason_of_exn_for_output exn) stderr)

let run_unix_argv_fallback ?timeout_sec ?env (argv : string list) : string =
  let label = String.concat " " (List.map Filename.quote argv) in
  with_unix_capture ?env ?timeout_sec argv
    ~on_error:(fun reason stderr ->
      Log.Misc.error "[Process_eio] Unix fallback error: %s — %s" label reason;
      process_error_output ~label ~reason ~stderr ())
    ~on_success:(fun status stdout stderr ->
      output_for_status ~status ~stdout ~stderr)

let run_unix_argv_with_status_split_fallback ?timeout_sec ?env ?cwd (argv : string list) :
    Unix.process_status * string * string =
  let label = String.concat " " (List.map Filename.quote argv) in
  with_unix_capture ?env ?cwd ?timeout_sec ~capture_stderr:true argv
    ~on_error:(fun reason stderr ->
      Log.Misc.error "[Process_eio] Unix fallback error: %s — %s" label reason;
      (Unix.WEXITED 127, "", process_error_output ~label ~reason ~stderr ()))
    ~on_success:(fun status stdout stderr ->
      (status, stdout, stderr))

let run_unix_argv_with_stdin_fallback ?timeout_sec ?env ~(stdin_content : string)
    (argv : string list) : string =
  let label = String.concat " " (List.map Filename.quote argv) in
  with_unix_capture ?env ?timeout_sec ~stdin_content argv
    ~on_error:(fun reason stderr ->
      Log.Misc.error "[Process_eio] Unix fallback error: %s — %s" label reason;
      process_error_output ~label ~reason ~stderr ())
    ~on_success:(fun status stdout stderr ->
      output_for_status ~status ~stdout ~stderr)

let run_unix_argv_with_stdin_and_status_split_fallback
    ?timeout_sec
    ?env
    ?cwd
    ~(stdin_content : string)
    (argv : string list) : Unix.process_status * string * string =
  let label = String.concat " " (List.map Filename.quote argv) in
  with_unix_capture ?env ?cwd ?timeout_sec ~stdin_content ~capture_stderr:true argv
    ~on_error:(fun reason stderr ->
      Log.Misc.error "[Process_eio] Unix fallback error: %s — %s" label reason;
      (Unix.WEXITED 127, "", process_error_output ~label ~reason ~stderr ()))
    ~on_success:(fun status stdout stderr ->
      (status, stdout, stderr))

(** ── Eio-native process execution (global refs) ─────────────────── *)

let unix_status_of_eio_status = function
  | `Exited n -> Unix.WEXITED n
  | `Signaled n -> Unix.WSIGNALED n

(** Reap a child process deterministically.

    The Eio spawn helper registers the handle with a switch, but relying solely
    on switch finalizers leaves a window where the child keeps running after a
    timeout/cancel.  This helper sends [SIGTERM], waits a short grace period,
    then escalates to [SIGKILL] and awaits the final status.  It is safe to call
    on an already-exited process. *)
let reap_proc_with_clock clock proc =
  let signal_and_await sig_ =
    try
      Eio.Process.signal proc sig_;
      Eio.Process.await proc |> ignore
    with _ -> ()
  in
  try
    Eio.Process.signal proc Sys.sigterm;
    (try
       Eio.Time.with_timeout_exn clock 2.0 (fun () ->
         Eio.Process.await proc |> ignore)
     with Eio.Time.Timeout -> signal_and_await Sys.sigkill)
  with _ -> signal_and_await Sys.sigkill

(** Spawn a process with explicit pipes and drain stdout/stderr into buffers
    before returning.  This avoids a race where [Eio.Process.await] returns
    (process exited) but the internal copy-fiber that moves pipe data into
    [buffer_sink] has not finished yet, resulting in truncated/empty output.

    The fix mirrors [Eio.Process.parse_out]: create pipes, close write ends
    after spawn, read to EOF in parallel fibers, then await the exit status. *)
let spawn_and_drain_stdout ?phase_ref ~sw pm ~cwd ?env ?stdin_source ~clock argv stdout_buf =
  let stdout_r, stdout_w = Eio.Process.pipe ~sw pm in
  let proc =
    Eio.Process.spawn ~sw pm ~cwd ?env
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
  (* fun-protect-finally-ok: finalizer only closes pipe FDs and reaps an
     already-spawned Eio.Process handle bound to [sw]; it does not acquire new
     Eio resources or yield to the scheduler. *)
  Fun.protect
    ~finally:(fun () ->
      if Option.is_none !status then (
        close_flow_best_effort "stdout" stdout_r;
        reap_proc_with_clock clock proc
      ) else
        Eio.Flow.close stdout_r)
    (fun () ->
      Eio.Flow.copy stdout_r (Eio.Flow.buffer_sink stdout_buf);
      Eio.Flow.close stdout_r;
      let s = Eio.Process.await proc in
      status := Some s;
      s)
  |> unix_status_of_eio_status

(** Like [spawn_and_drain_stdout] but captures both stdout and stderr into
    separate buffers and returns the process exit status.
    Drain happens in parallel via [Fiber.both]; [await] is called after
    both pipes reach EOF, so buffers are guaranteed complete. *)
let spawn_and_drain_both ?phase_ref ~sw pm ~cwd ?env ?stdin_source ~clock argv stdout_buf
    stderr_buf =
  let stdout_r, stdout_w = Eio.Process.pipe ~sw pm in
  let stderr_r, stderr_w = Eio.Process.pipe ~sw pm in
  let proc =
    Eio.Process.spawn ~sw pm ~cwd ?env
      ?stdin:stdin_source
      ~stdout:stdout_w
      ~stderr:stderr_w
      argv
  in
  Option.iter (fun r -> r := Timeout_origin.Command) phase_ref;
  Eio.Flow.close stdout_w;
  Eio.Flow.close stderr_w;
  let status = ref None in
  (* fun-protect-finally-ok: finalizer only closes pipe FDs and reaps an
     already-spawned Eio.Process handle bound to [sw]; it does not acquire new
     Eio resources or yield to the scheduler. *)
  Fun.protect
    ~finally:(fun () ->
      if Option.is_none !status then (
        close_flow_best_effort "stdout" stdout_r;
        close_flow_best_effort "stderr" stderr_r;
        reap_proc_with_clock clock proc
      ) else (
        Eio.Flow.close stdout_r;
        Eio.Flow.close stderr_r
      ))
    (fun () ->
      Eio.Fiber.both
        (fun () ->
          Eio.Flow.copy stdout_r (Eio.Flow.buffer_sink stdout_buf);
          Eio.Flow.close stdout_r)
        (fun () ->
          Eio.Flow.copy stderr_r (Eio.Flow.buffer_sink stderr_buf);
          Eio.Flow.close stderr_r);
      let s = Eio.Process.await proc in
      status := Some s;
      s)
  |> unix_status_of_eio_status

let invoke_output_chunk_callback f s =
  try f s with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Log.Misc.warn
        "[Process_eio] output chunk callback error, continuing: %s"
        (Printexc.to_string exn)

let spawn_and_drain_both_streaming ?phase_ref ~sw pm ~cwd ?env ?stdin_source ~clock argv
    ~on_stdout_chunk ~on_stderr_chunk stdout_buf stderr_buf =
  let stdout_r, stdout_w = Eio.Process.pipe ~sw pm in
  let stderr_r, stderr_w = Eio.Process.pipe ~sw pm in
  let proc =
    Eio.Process.spawn ~sw pm ~cwd ?env
      ?stdin:stdin_source
      ~stdout:stdout_w
      ~stderr:stderr_w
      argv
  in
  Option.iter (fun r -> r := Timeout_origin.Command) phase_ref;
  Eio.Flow.close stdout_w;
  Eio.Flow.close stderr_w;
  let chunk_size = 4096 in
  let rec drain r buf ~on_chunk chunk =
    match
      try Eio.Flow.single_read r chunk with
      | End_of_file -> 0
    with
    | 0 -> Eio.Flow.close r
    | n ->
      let s = Cstruct.to_string (Cstruct.sub chunk 0 n) in
      invoke_output_chunk_callback on_chunk s;
      Buffer.add_string buf s;
      drain r buf ~on_chunk chunk
  in
  let status = ref None in
  (* fun-protect-finally-ok: finalizer only closes pipe FDs and reaps an
     already-spawned Eio.Process handle bound to [sw]; it does not acquire new
     Eio resources or yield to the scheduler. *)
  Fun.protect
    ~finally:(fun () ->
      if Option.is_none !status then (
        close_flow_best_effort "stdout" stdout_r;
        close_flow_best_effort "stderr" stderr_r;
        reap_proc_with_clock clock proc
      ) else (
        Eio.Flow.close stdout_r;
        Eio.Flow.close stderr_r
      ))
    (fun () ->
      Eio.Fiber.both
        (fun () ->
          let chunk = Cstruct.create chunk_size in
          drain stdout_r stdout_buf ~on_chunk:on_stdout_chunk chunk)
        (fun () ->
          let chunk = Cstruct.create chunk_size in
          drain stderr_r stderr_buf ~on_chunk:on_stderr_chunk chunk);
      let s = Eio.Process.await proc in
      status := Some s;
      s)
  |> unix_status_of_eio_status

type pipeline_stage = {
  argv : string list;
  env : string array option;
  cwd : string option;
}

let effective_cwd default_cwd = function
  | None -> default_cwd
  | Some dir -> Eio.Path.(default_cwd / dir)

let pipeline_status statuses =
  List.fold_left
    (fun acc status ->
      match status with
      | Unix.WEXITED 0 -> acc
      | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> status)
    (Unix.WEXITED 0)
    statuses

let run_argv ?timeout_sec ?env (argv : string list) : string =
  let timeout_sec = validate_timeout_sec timeout_sec in
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv ~argv ?env ();
  with_spawn_guard (fun () ->
      if not (is_initialized ()) then
        run_unix_argv_fallback ?timeout_sec ?env argv
      else
        match get_proc_mgr (), get_clock (), get_cwd_default () with
        | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
            run_unix_argv_fallback ?timeout_sec ?env argv
        | Ok pm, Ok clk, Ok cwd ->
            let buf = Buffer.create default_buffer_size in
            let label = String.concat " " (List.map Filename.quote argv) in
            let phase_ref = ref Timeout_origin.Spawn in
            try
              with_explicit_timeout_exn clk timeout_sec (fun () ->
                  Eio.Switch.run (fun sw ->
                      let status = spawn_and_drain_stdout ~phase_ref ~sw pm ~cwd ?env ~clock:clk argv buf in
                      output_for_status ~status ~stdout:(Buffer.contents buf) ~stderr:""))
            with
            | Explicit_process_timeout timeout_sec ->
                Log.Misc.warn "[Process_eio] Timeout after %.0fs (%s): %s"
                  timeout_sec (Timeout_origin.to_label !phase_ref) label;
                observe_process_timeout argv ~timeout_sec ~origin:!phase_ref;
                process_error_output ~label
                  ~reason:(Printf.sprintf "timeout after %.0fs" timeout_sec) ()
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
                if should_retry_unix_fallback exn then (
                  Log.Misc.warn
                    "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                    label (Printexc.to_string exn);
                  run_unix_argv_fallback ?timeout_sec ?env argv
                ) else if is_downstream_pipe_closed exn then (
                  (* Downstream reader closed the pipe (head/tail/grep -m
                     finished reading and exited).  Kernel returns EPIPE on
                     the next write; Eio surfaces it as Net.Connection_reset.
                     This is the normal termination of a piped command, not
                     a failure — log at DEBUG so the operator-facing ERROR
                     stream stays quiet. *)
                  Log.Misc.debug
                    "[Process_eio] argv pipe closed by reader: %s — %s"
                    label (Printexc.to_string exn);
                  process_error_output ~label
                    ~reason:"pipe closed by reader" ()
                ) else (
                  Log.Misc.error "[Process_eio] argv error: %s — %s" label
                    (Printexc.to_string exn);
                  process_error_output ~label ~reason:(reason_of_exn_for_output exn) ()))

let run_argv_with_stdin ?timeout_sec ?env ~(stdin_content : string) (argv : string list) : string =
  let timeout_sec = validate_timeout_sec timeout_sec in
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_stdin ~argv ?env ();
  with_spawn_guard (fun () ->
      if not (is_initialized ()) then
        run_unix_argv_with_stdin_fallback ?timeout_sec ?env ~stdin_content argv
      else
        match get_proc_mgr (), get_clock (), get_cwd_default () with
        | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
            run_unix_argv_with_stdin_fallback ?timeout_sec ?env ~stdin_content argv
        | Ok pm, Ok clk, Ok cwd ->
            let buf = Buffer.create default_buffer_size in
            let label = String.concat " " (List.map Filename.quote argv) in
            let stdin_source = Eio.Flow.string_source stdin_content in
            let phase_ref = ref Timeout_origin.Spawn in
            try
              with_explicit_timeout_exn clk timeout_sec (fun () ->
                  Eio.Switch.run (fun sw ->
                      let status =
                        spawn_and_drain_stdout ~phase_ref ~sw pm ~cwd ?env ~stdin_source ~clock:clk argv buf
                      in
                      output_for_status ~status ~stdout:(Buffer.contents buf) ~stderr:""))
            with
            | Explicit_process_timeout timeout_sec ->
                Log.Misc.warn "[Process_eio] Timeout after %.0fs (%s): %s"
                  timeout_sec (Timeout_origin.to_label !phase_ref) label;
                observe_process_timeout argv ~timeout_sec ~origin:!phase_ref;
                process_error_output ~label
                  ~reason:(Printf.sprintf "timeout after %.0fs" timeout_sec) ()
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
                if should_retry_unix_fallback exn then (
                  Log.Misc.warn
                    "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                    label (Printexc.to_string exn);
                  run_unix_argv_with_stdin_fallback ?timeout_sec ?env ~stdin_content argv
                ) else if is_downstream_pipe_closed exn then (
                  (* Downstream reader closed the pipe (head/tail/grep -m
                     finished reading and exited).  Kernel returns EPIPE on
                     the next write; Eio surfaces it as Net.Connection_reset.
                     This is the normal termination of a piped command, not
                     a failure — log at DEBUG so the operator-facing ERROR
                     stream stays quiet. *)
                  Log.Misc.debug
                    "[Process_eio] argv pipe closed by reader: %s — %s"
                    label (Printexc.to_string exn);
                  process_error_output ~label
                    ~reason:"pipe closed by reader" ()
                ) else (
                  Log.Misc.error "[Process_eio] argv error: %s — %s" label
                    (Printexc.to_string exn);
                  process_error_output ~label ~reason:(reason_of_exn_for_output exn) ()))

let run_argv_with_stdin_and_status_split
    ?timeout_sec
    ?env
    ?cwd
    ?on_stdout_chunk
    ?on_stderr_chunk
    ~(stdin_content : string)
    (argv : string list) : Unix.process_status * string * string =
  let timeout_sec = validate_timeout_sec timeout_sec in
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_stdin_and_status ~argv ?env ();
  let fallback_with_callbacks () =
    let status, stdout, stderr =
      run_unix_argv_with_stdin_and_status_split_fallback ?timeout_sec ?env
        ?cwd ~stdin_content argv
    in
    Option.iter
      (fun f -> if stdout <> "" then invoke_output_chunk_callback f stdout)
      on_stdout_chunk;
    Option.iter
      (fun f -> if stderr <> "" then invoke_output_chunk_callback f stderr)
      on_stderr_chunk;
    status, stdout, stderr
  in
  with_spawn_guard (fun () ->
      if not (is_initialized ()) then
        fallback_with_callbacks ()
      else
        match get_proc_mgr (), get_clock (), get_cwd_default () with
        | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
            fallback_with_callbacks ()
        | Ok pm, Ok clk, Ok default_cwd ->
            let effective_cwd =
              match cwd with
              | None -> default_cwd
              | Some dir -> Eio.Path.(default_cwd / dir)
            in
            let stdout_buf = Buffer.create default_buffer_size in
            let stderr_buf = Buffer.create default_buffer_size in
            let label = String.concat " " (List.map Filename.quote argv) in
            let stdin_source = Eio.Flow.string_source stdin_content in
            let phase_ref = ref Timeout_origin.Spawn in
            try
              with_explicit_timeout_exn clk timeout_sec (fun () ->
                  let unix_status =
                    Eio.Switch.run (fun sw ->
                        match on_stdout_chunk, on_stderr_chunk with
                        | None, None ->
                            spawn_and_drain_both ~phase_ref ~sw pm
                              ~cwd:effective_cwd ?env ~stdin_source ~clock:clk argv
                              stdout_buf stderr_buf
                        | _ ->
                            let on_stdout_chunk =
                              match on_stdout_chunk with
                              | Some f -> f
                              | None -> fun _ -> ()
                            in
                            let on_stderr_chunk =
                              match on_stderr_chunk with
                              | Some f -> f
                              | None -> fun _ -> ()
                            in
                            spawn_and_drain_both_streaming
                              ~phase_ref
                              ~sw
                              pm
                              ~cwd:effective_cwd
                              ?env
                              ~stdin_source
                              ~clock:clk
                              argv
                              ~on_stdout_chunk
                              ~on_stderr_chunk
                              stdout_buf
                              stderr_buf)
                  in
                  ( unix_status,
                    Buffer.contents stdout_buf,
                    Buffer.contents stderr_buf ))
            with
            | Explicit_process_timeout timeout_sec ->
                Log.Misc.warn "[Process_eio] Timeout after %.0fs (%s): %s"
                  timeout_sec (Timeout_origin.to_label !phase_ref) label;
                observe_process_timeout argv ~timeout_sec ~origin:!phase_ref;
                let timeout_status = Unix.WEXITED 124 in
                let stdout = Buffer.contents stdout_buf in
                let stderr = Buffer.contents stderr_buf in
                let stderr =
                  if String.trim stdout = "" && String.trim stderr = "" then
                    process_error_output ~label
                      ~reason:(Printf.sprintf "timeout after %.0fs" timeout_sec) ()
                  else stderr
                in
                (timeout_status, stdout, stderr)
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
                if should_retry_unix_fallback exn then (
                  Log.Misc.warn
                    "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                    label (Printexc.to_string exn);
                  fallback_with_callbacks ()
                ) else if is_downstream_pipe_closed exn then (
                  (* Downstream reader closed the pipe (head/tail/grep -m
                     finished reading and exited).  Kernel returns EPIPE on
                     the next write; Eio surfaces it as Net.Connection_reset.
                     This is the normal termination of a piped command, not
                     a failure — log at DEBUG so the operator-facing ERROR
                     stream stays quiet.  We keep the same exit-code shape
                     (Unix.WEXITED 127) and [process_error_output] reason
                     as the catch-all branch so caller-side decisions are
                     unchanged; this is a logging-severity change only. *)
                  Log.Misc.debug
                    "[Process_eio] argv pipe closed by reader: %s — %s"
                    label (Printexc.to_string exn);
                  ( Unix.WEXITED 127,
                    "",
                    process_error_output ~label
                      ~reason:"pipe closed by reader" () )
                ) else (
                  Log.Misc.error "[Process_eio] argv error: %s — %s" label
                    (Printexc.to_string exn);
                  ( Unix.WEXITED 127,
                    "",
                    process_error_output ~label
                      ~reason:(reason_of_exn_for_output exn) () )))

let run_argv_with_stdin_and_status
    ?timeout_sec
    ?env
    ?cwd
    ~(stdin_content : string)
    (argv : string list) : Unix.process_status * string =
  let status, stdout, stderr =
    run_argv_with_stdin_and_status_split ?timeout_sec ?env ?cwd ~stdin_content
      argv
  in
  (status, output_for_status ~status ~stdout ~stderr)

let run_argv_with_status_split ?timeout_sec ?env ?cwd
    (argv : string list) : Unix.process_status * string * string =
  let timeout_sec = validate_timeout_sec timeout_sec in
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_status ~argv ?env ?cwd ();
  with_spawn_guard (fun () ->
      if not (is_initialized ()) then
        run_unix_argv_with_status_split_fallback ?timeout_sec ?env ?cwd argv
      else
        match get_proc_mgr (), get_clock (), get_cwd_default () with
        | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
            run_unix_argv_with_status_split_fallback ?timeout_sec ?env ?cwd
              argv
        | Ok pm, Ok clk, Ok default_cwd ->
            let effective_cwd =
              match cwd with
              | None -> default_cwd
              | Some dir -> Eio.Path.(default_cwd / dir)
            in
            let stdout_buf = Buffer.create default_buffer_size in
            let stderr_buf = Buffer.create 256 in
            let label = String.concat " " (List.map Filename.quote argv) in
            let phase_ref = ref Timeout_origin.Spawn in
            try
              with_explicit_timeout_exn clk timeout_sec (fun () ->
                  let unix_status =
                    Eio.Switch.run (fun sw ->
                        spawn_and_drain_both ~phase_ref ~sw pm ~cwd:effective_cwd ?env
                          ~clock:clk argv stdout_buf stderr_buf)
                  in
                  ( unix_status,
                    Buffer.contents stdout_buf,
                    Buffer.contents stderr_buf ))
            with
            | Explicit_process_timeout timeout_sec ->
                Log.Misc.warn "[Process_eio] Timeout after %.0fs (%s): %s"
                  timeout_sec (Timeout_origin.to_label !phase_ref) label;
                observe_process_timeout argv ~timeout_sec ~origin:!phase_ref;
                let timeout_status = Unix.WEXITED 124 in
                let stdout = Buffer.contents stdout_buf in
                let stderr = Buffer.contents stderr_buf in
                let stderr =
                  if String.trim stdout = "" && String.trim stderr = "" then
                    process_error_output ~label
                      ~reason:(Printf.sprintf "timeout after %.0fs" timeout_sec) ()
                  else stderr
                in
                (timeout_status, stdout, stderr)
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
                if should_retry_unix_fallback exn then (
                  Log.Misc.warn
                    "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                    label (Printexc.to_string exn);
                  run_unix_argv_with_status_split_fallback ?timeout_sec ?env
                    ?cwd argv
                ) else if is_downstream_pipe_closed exn then (
                  (* Downstream reader closed the pipe (head/tail/grep -m
                     finished reading and exited).  Kernel returns EPIPE on
                     the next write; Eio surfaces it as Net.Connection_reset.
                     This is the normal termination of a piped command, not
                     a failure — log at DEBUG so the operator-facing ERROR
                     stream stays quiet.  We keep the same exit-code shape
                     (Unix.WEXITED 127) and [process_error_output] reason
                     as the catch-all branch so caller-side decisions are
                     unchanged; this is a logging-severity change only. *)
                  Log.Misc.debug
                    "[Process_eio] argv pipe closed by reader: %s — %s"
                    label (Printexc.to_string exn);
                  ( Unix.WEXITED 127,
                    "",
                    process_error_output ~label
                      ~reason:"pipe closed by reader" () )
                ) else (
                  Log.Misc.error "[Process_eio] argv error: %s — %s" label
                    (Printexc.to_string exn);
                  ( Unix.WEXITED 127,
                    "",
                    process_error_output ~label
                      ~reason:(reason_of_exn_for_output exn) () )))

let run_argv_with_status_split_streaming
    ?timeout_sec
    ?env
    ?cwd
    ~on_stdout_chunk
    ~on_stderr_chunk
    (argv : string list)
    : Unix.process_status * string * string
  =
  let timeout_sec = validate_timeout_sec timeout_sec in
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_status ~argv ?env ?cwd ();
  let fallback_with_callbacks () =
    let status, stdout, stderr =
      run_unix_argv_with_status_split_fallback ?timeout_sec ?env ?cwd argv
    in
    if not (String.equal stdout "")
    then invoke_output_chunk_callback on_stdout_chunk stdout;
    if not (String.equal stderr "")
    then invoke_output_chunk_callback on_stderr_chunk stderr;
    status, stdout, stderr
  in
  with_spawn_guard (fun () ->
      if not (is_initialized ())
      then fallback_with_callbacks ()
      else (
        match get_proc_mgr (), get_clock (), get_cwd_default () with
        | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
          fallback_with_callbacks ()
        | Ok pm, Ok clk, Ok default_cwd ->
          let effective_cwd =
            match cwd with
            | None -> default_cwd
            | Some dir -> Eio.Path.(default_cwd / dir)
          in
          let stdout_buf = Buffer.create default_buffer_size in
          let stderr_buf = Buffer.create 256 in
          let label = String.concat " " (List.map Filename.quote argv) in
          let phase_ref = ref Timeout_origin.Spawn in
          try
            with_explicit_timeout_exn clk timeout_sec (fun () ->
                let unix_status =
                  Eio.Switch.run (fun sw ->
                      spawn_and_drain_both_streaming
                        ~phase_ref
                        ~sw
                        pm
                        ~cwd:effective_cwd
                        ?env
                        ~clock:clk
                        ~on_stdout_chunk
                        ~on_stderr_chunk
                        argv
                        stdout_buf
                        stderr_buf)
                in
                unix_status, Buffer.contents stdout_buf, Buffer.contents stderr_buf)
          with
          | Explicit_process_timeout timeout_sec ->
            Log.Misc.warn "[Process_eio] Timeout after %.0fs (%s): %s"
              timeout_sec (Timeout_origin.to_label !phase_ref) label;
            observe_process_timeout argv ~timeout_sec ~origin:!phase_ref;
            let timeout_status = Unix.WEXITED 124 in
            let stdout = Buffer.contents stdout_buf in
            let stderr = Buffer.contents stderr_buf in
            let stderr =
              if String.trim stdout = "" && String.trim stderr = ""
              then process_error_output ~label
                     ~reason:(Printf.sprintf "timeout after %.0fs" timeout_sec) ()
              else stderr
            in
            timeout_status, stdout, stderr
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
            if should_retry_unix_fallback exn
            then (
              Log.Misc.warn
                "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                label (Printexc.to_string exn);
              fallback_with_callbacks ())
            else if is_downstream_pipe_closed exn
            then (
              Log.Misc.debug
                "[Process_eio] argv pipe closed by reader: %s — %s"
                label (Printexc.to_string exn);
              ( Unix.WEXITED 127,
                "",
                process_error_output ~label ~reason:"pipe closed by reader" () ))
            else (
              Log.Misc.error "[Process_eio] argv error: %s — %s" label
                (Printexc.to_string exn);
              ( Unix.WEXITED 127,
                "",
                process_error_output ~label ~reason:(reason_of_exn_for_output exn) () ))))

let run_argv_pipeline_with_status_split ?timeout_sec
    ?on_stdout_chunk ?on_stderr_chunk
    (stages : pipeline_stage list) : Unix.process_status * string * string =
  let timeout_sec = validate_timeout_sec timeout_sec in
  let fallback_buffered () =
    let rec chain prev_stdout = function
      | [] -> (Unix.WEXITED 0, prev_stdout, "")
      | [ { argv; env; cwd } ] ->
          run_unix_argv_with_stdin_and_status_split_fallback ?timeout_sec ?env
            ?cwd ~stdin_content:prev_stdout argv
      | { argv; env; cwd } :: rest ->
          let status, stdout, stderr =
            run_unix_argv_with_stdin_and_status_split_fallback ?timeout_sec
              ?env ?cwd ~stdin_content:prev_stdout argv
          in
          let result_status, result_stdout, result_stderr = chain stdout rest in
          let final_status = pipeline_status [ status; result_status ] in
          (final_status, result_stdout, stderr ^ result_stderr)
    in
    let result =
      match stages with
      | [] -> (Unix.WEXITED 0, "", "")
      | [ { argv; env; cwd } ] ->
          run_unix_argv_with_status_split_fallback ?timeout_sec ?env ?cwd argv
      | { argv; env; cwd } :: rest ->
          let status, stdout, stderr =
            run_unix_argv_with_status_split_fallback ?timeout_sec ?env ?cwd argv
          in
          let result_status, result_stdout, result_stderr = chain stdout rest in
          let final_status = pipeline_status [ status; result_status ] in
          (final_status, result_stdout, stderr ^ result_stderr)
    in
    let _status, stdout, stderr = result in
    (match on_stdout_chunk with
     | Some f when not (String.equal stdout "") ->
         invoke_output_chunk_callback f stdout
     | _ -> ());
    (match on_stderr_chunk with
     | Some f when not (String.equal stderr "") ->
         invoke_output_chunk_callback f stderr
     | _ -> ());
    result
  in
  with_spawn_guard (fun () ->
      if not (is_initialized ()) then fallback_buffered ()
      else
        match get_proc_mgr (), get_clock (), get_cwd_default () with
        | Error _, _, _ | _, Error _, _ | _, _, Error _ -> fallback_buffered ()
        | Ok pm, Ok clk, Ok default_cwd ->
            let label =
              stages
              |> List.map (fun stage ->
                String.concat " " (List.map Filename.quote stage.argv))
              |> String.concat " | "
            in
            let stdout_buf = Buffer.create default_buffer_size in
            let stderr_buffers =
              List.map
                (fun _ -> Buffer.create 256)
                stages
            in
            let stderr_contents () =
              stderr_buffers
              |> List.map Buffer.contents
              |> String.concat ""
            in
            let phase_ref = ref Timeout_origin.Spawn in
            (try
               Eio.Switch.run (fun sw ->
                   let final_stdout_r, final_stdout_w =
                     Eio.Process.pipe ~sw pm
                   in
                   let links =
                     List.init
                       (max 0 (List.length stages - 1))
                       (fun _ -> Eio.Process.pipe ~sw pm)
                   in
                   let stderr_pairs =
                     List.map
                       (fun _ -> Eio.Process.pipe ~sw pm)
                       stages
                   in
                   let procs =
                     stages
                     |> List.mapi (fun idx stage ->
                       Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_status
                         ~argv:stage.argv ?env:stage.env ?cwd:stage.cwd ();
                       let stdin =
                         if idx = 0 then None
                         else Some (fst (List.nth links (idx - 1)))
                       in
                       let stdout =
                         if idx = List.length stages - 1
                         then final_stdout_w
                         else snd (List.nth links idx)
                       in
                       let stderr = snd (List.nth stderr_pairs idx) in
                       let proc =
                         Eio.Process.spawn
                           ~sw
                           pm
                           ~cwd:(effective_cwd default_cwd stage.cwd)
                           ?env:stage.env
                           ?stdin
                           ~stdout
                           ~stderr
                           stage.argv
                       in
                       phase_ref := Timeout_origin.Command;
                       proc)
                   in
                   Eio.Flow.close final_stdout_w;
                   List.iter
                     (fun (r, w) ->
                       Eio.Flow.close r;
                       Eio.Flow.close w)
                     links;
                   List.iter
                     (fun (_r, w) -> Eio.Flow.close w)
                     stderr_pairs;
                   let drain_flow_to_buffer ?on_chunk r buf =
                     let chunk = Cstruct.create 4096 in
                     let rec loop () =
                       match
                         try Eio.Flow.single_read r chunk
                         with End_of_file -> 0
                       with
                       | 0 -> Eio.Flow.close r
                       | n ->
                           let s =
                             Cstruct.to_string (Cstruct.sub chunk 0 n)
                           in
                           Option.iter
                             (fun f -> invoke_output_chunk_callback f s)
                             on_chunk;
                           Buffer.add_string buf s;
                           loop ()
                     in
                     loop ()
                   in
                   let drain_final_stdout () =
                     drain_flow_to_buffer ?on_chunk:on_stdout_chunk
                       final_stdout_r stdout_buf
                   in
                   let drain_stderr idx (r, _w) =
                     let buf = List.nth stderr_buffers idx in
                     drain_flow_to_buffer ?on_chunk:on_stderr_chunk r buf
                   in
                   let await_all () =
                     List.map Eio.Process.await procs
                     |> List.map unix_status_of_eio_status
                   in
                   let drain_all () =
                     Eio.Fiber.all
                       (drain_final_stdout
                        :: List.mapi
                             (fun idx pair -> fun () ->
                               drain_stderr idx pair)
                             stderr_pairs)
                   in
                   try
                     with_explicit_timeout_exn clk timeout_sec (fun () ->
                       let statuses, () = Eio.Fiber.pair await_all drain_all in
                       let stderr = stderr_contents () in
                       (pipeline_status statuses, Buffer.contents stdout_buf, stderr))
                   with Explicit_process_timeout timeout_sec ->
                     List.iter (reap_proc_with_clock clk) procs;
                     raise (Explicit_process_timeout timeout_sec))
             with
             | Explicit_process_timeout timeout_sec ->
                 Log.Misc.warn "[Process_eio] Timeout after %.0fs (%s): %s"
                   timeout_sec (Timeout_origin.to_label !phase_ref) label;
                 observe_process_timeout
                   (match stages with [] -> [] | stage :: _ -> stage.argv)
                   ~timeout_sec ~origin:!phase_ref;
                 let streamed_stderr = stderr_contents () in
                 let stderr =
                   if String.trim streamed_stderr = "" then
                     process_error_output ~label
                       ~reason:(Printf.sprintf "timeout after %.0fs" timeout_sec)
                       ()
                   else streamed_stderr
                 in
                 (Unix.WEXITED 124, Buffer.contents stdout_buf, stderr)
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn ->
                 if should_retry_unix_fallback exn then (
                   Log.Misc.warn
                     "[Process_eio] pipeline bind error, retrying via Unix fallback: %s — %s"
                     label (Printexc.to_string exn);
                   fallback_buffered ())
                 else (
                   Log.Misc.error "[Process_eio] pipeline error: %s — %s" label
                     (Printexc.to_string exn);
                   ( Unix.WEXITED 127,
                     "",
                     process_error_output ~label
                       ~reason:(reason_of_exn_for_output exn) () ))))

let run_argv_with_status ?timeout_sec ?env ?cwd
    (argv : string list) : Unix.process_status * string =
  let status, stdout, stderr =
    run_argv_with_status_split ?timeout_sec ?env ?cwd argv
  in
  (status, output_for_status ~status ~stdout ~stderr)

include Process_eio_detached
