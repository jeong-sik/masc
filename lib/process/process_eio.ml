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

(** Origin at which an [Eio.Time.with_timeout_exn] budget was exhausted:
    [Timeout_origin.Spawn] or [Timeout_origin.Command]. *)

(** Observability hook: invoked when an Eio process call hits its
    [timeout_sec] budget.  Default no-op so the lower [masc_process]
    layer carries no [Otel_metric_store] dependency.  Wired from [lib/workspace.ml]
    at module load to emit [masc_process_timeout_total].

    Cardinality: callers should pass [program = Filename.basename argv0]
    (~10-20 distinct programs fleet-wide); [timeout_sec] is the per-call
    budget (a few discrete values: 15.0, 60.0, ...); [origin] is
    [Spawn] or [Command] — total label cardinality is bounded
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
  with
  | Eio.Cancel.Cancelled _ as e ->
    (* The observer is called from the process fiber; swallowing [Cancelled]
       would report an observer failure and let the fiber continue past a
       cancellation it was told to honour. *)
    Printexc.raise_with_backtrace e (Printexc.get_raw_backtrace ())
  | exn ->
    Log.Misc.warn "[Process_eio] timeout observer failed: %s"
      (Printexc.to_string exn)

type spawn_guard = { run : 'a. (unit -> 'a) -> 'a }

let default_spawn_guard = { run = (fun f -> f ()) }
let spawn_guard : spawn_guard Atomic.t = Atomic.make default_spawn_guard
let set_spawn_guard guard = Atomic.set spawn_guard guard
let reset_spawn_guard_for_testing () = Atomic.set spawn_guard default_spawn_guard
let with_spawn_guard f = (Atomic.get spawn_guard).run f

let init ~cwd_default ~proc_mgr ~clock =
  Atomic.set runtime_state (Some { proc_mgr; clock; cwd_default })

let is_initialized () = Option.is_some (Atomic.get runtime_state)

let reset_for_testing () =
  Atomic.set runtime_state None;
  reset_spawn_guard_for_testing ()

(* Bounded capture for one subprocess stream.

   A subprocess can emit arbitrarily many bytes, and before this the drainers
   copied all of them into an unbounded buffer: a single `rg` over a tree of
   single-line multi-MB JSON retained 590MB in one call.
   [Common.max_tool_result_wire_bytes] does not stop it — that constant is the
   inline-vs-blob threshold, not a ceiling on what the runtime accepts.

   Retention is capped head+tail; the drainer still reads to EOF so the exit
   status and the stream tail (where failures report) stay exact, making peak
   memory O(head + tail) instead of O(output). Elided bytes are reported by
   [Exec_buffer.render]'s truncation marker, never dropped silently. *)
let create_capture () =
  Exec_buffer.create
    ~head_cap:Common.max_process_capture_head_bytes
    ~tail_cap:Common.max_process_capture_tail_bytes

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

(* A child whose output was drained and whose exit was read as the timeout
   passed is a finished run, not a timeout: [Eio.Time.with_timeout_exn]
   keeps whichever arm finished first and would have reported the run as
   timed out with its output in hand. The run's result stands whenever it
   has one; the timeout ends only a run that has not finished. *)
let with_explicit_timeout_exn clock timeout_sec f =
  match timeout_sec with
  | None -> f ()
  | Some timeout_sec ->
    (match
       Watched_work.run
         (fun () -> `Finished (f ()))
         ~watcher:(fun () ->
           Eio.Time.sleep clock timeout_sec;
           `Expired)
     with
     | `Finished result -> result
     | `Expired -> raise (Explicit_process_timeout timeout_sec))

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

let effective_cwd default_cwd = function
  | None -> default_cwd
  | Some dir -> Eio.Path.(default_cwd / dir)

(** ── Unix fallback for tests (when Eio not initialized) ──────────── *)

let default_env = function
  | Some env -> env
  | None -> Unix.environment ()

(* [@@warning "-4"]: scrutinee is [exn] (extensible) — a wildcard arm is
   mandatory because new exception constructors can never be enumerated.
   RFC-0071 §3.4.1 sanctioned open-variant exemption, not a lazy
   catch-all over a closed sum. *)
(* timeout(1)'s convention. Everything that used to write this literal, here
   and in the three modules that had started reading it, goes through the two
   names below. *)
let timeout_exit_code = 124
let timed_out_status = Unix.WEXITED timeout_exit_code

type exit_reason =
  | Completed of int
  | Timed_out
  | Signaled of int
  | Stopped of int

let exit_reason_of_status = function
  | Unix.WEXITED code when code = timeout_exit_code -> Timed_out
  | Unix.WEXITED code -> Completed code
  | Unix.WSIGNALED signal -> Signaled signal
  | Unix.WSTOPPED signal -> Stopped signal
;;

let rec should_retry_unix_fallback = function
  | Unix.Unix_error
      ((Unix.EADDRINUSE | Unix.EADDRNOTAVAIL | Unix.EACCES | Unix.EPERM), "bind", _) ->
      true
  | Eio.Cancel.Cancelled exn -> should_retry_unix_fallback exn
  | _ -> false
[@@warning "-4"]

let close_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> () (* intentional: best-effort cleanup *)

(* Everything the two spawn paths can raise before a child process exists,
   read from the sources rather than guessed:

   Eio path ([Eio.Process.spawn], eio 1.3):
   - [Eio_unix.Process.get_executable] (lib_eio/unix/process.ml:58-66) raises
     [Invalid_argument] for an empty argv and
     [Eio.Io (Process.E (Executable_not_found argv0))] when PATH has no file.
   - [Low_level.pipe] on both backends is [Unix.pipe] (posix low_level.ml:497,
     linux low_level.ml:544) and the fork stub raises [uerror "fork"]
     (eio_posix_stubs.c:416, eio_stubs.c:199): both are [Unix.Unix_error].
   - Fork actions (fchdir, dup2, execve) run in the child after fork and
     report "<action>: <strerror(errno)>" over a pipe
     (lib_eio/unix/fork_action.c, [eio_unix_fork_error]); the parent raises
     [Failure] with that text (posix low_level.ml:585, linux
     low_level.ml:628). The errno is already text there, so
     [Child_setup_failed] carries the text as data and nothing here parses it.
   - A requested cwd is opened before the fork ([spawn_unix], posix
     process.ml:35-40 via [Err.run], linux eio_linux.ml:229-233 via
     [with_dir]); [ENOENT] and [EACCES]/[EPERM] arrive as
     [Eio.Io (Fs.E (Not_found | Permission_denied))] and any other errno as
     [Eio.Io (Exn.X (Eio_unix.Unix_error ...))] (posix err.ml:16-25, linux
     err.ml:10-17). The [Fmt.invalid_arg "cwd is not an OS directory!"] there
     cannot fire: every cwd this module passes derives from [Eio.Stdenv.fs].
   [Eio.Process.Child_error] is raised by [run]/[parse_out] after the child
   exits, never by [spawn].
   Nothing of this module's own runs a [failwith] inside that window: between
   the [try] and the [phase_ref := Command] flip in [Eio_process_capture.spawn_and_drain_both]
   the only calls are [Eio.Process.pipe] twice and [Eio.Process.spawn], so a
   [Failure] seen in the [Spawn] phase is eio's child report and nothing else.

   Unix fallback ([Unix_foreground_process], shared posix_spawn stubs):
   - with [posix_spawnp] (macOS, glibc) every failure is
     [Unix_error (errno, "posix_spawnp", executable)];
     [ENOENT] is the program not found, anything else ([EACCES], [E2BIG],
     [ENOEXEC], [ENOMEM], ...) is [Spawn_failed] with that errno.
   - the pipe and stderr capture file are [Unix.pipe] / [Unix.openfile];
     a [Unix_error] there before the spawn is [Spawn_failed] too.
   Without [posix_spawn] the fallback's child exits 127 (spawn.c:91); no
   target of this repo builds that way. *)
type cwd_error =
  | Native_cwd_error of Unix.error
  | Eio_cwd_error of Eio.Exn.err

type spawn_refusal =
  | Empty_argv
  | Executable_not_found of string
  | Spawn_failed of
      { executable : string
      ; error : Unix.error
      }
  | Child_setup_failed of
      { executable : string
      ; detail : string
      }
  | Cwd_unavailable of
      { cwd : string
      ; error : cwd_error
      }

let spawn_refusal_to_string = function
  | Empty_argv -> "argv is empty"
  | Executable_not_found program ->
      Printf.sprintf "executable %S not found on PATH" program
  | Spawn_failed { executable; error } ->
      Printf.sprintf "spawn of %S failed: %s" executable (Unix.error_message error)
  | Child_setup_failed { executable; detail } ->
      Printf.sprintf "child for %S could not start: %s" executable detail
  | Cwd_unavailable { cwd; error } ->
      Printf.sprintf "cwd %s could not be opened: %s" cwd
        (match error with
         | Native_cwd_error error -> Unix.error_message error
         | Eio_cwd_error error -> Format.asprintf "%a" Eio.Exn.pp_err error)

(* True while the child does not exist yet. [phase_ref] moves to [Command]
   right after [Eio.Process.spawn] returns, so an exception seen in [Spawn]
   came from creating the pipes, forking, or the child's own setup. *)
let in_spawn_phase phase_ref =
  match !phase_ref with
  | Timeout_origin.Spawn -> true
  | Timeout_origin.Command -> false

let empty_argv_exn = Invalid_argument "Process_eio: argv is empty"

(* Raised at the foreground spawn boundary in [with_unix_capture] so the
   handler at its bottom can route the refusal without inspecting the
   [Unix_error] function-name string. The original exception rides along for
   the callers that still render it as text. *)
exception Refused_at_spawn of spawn_refusal * exn

let fallback_cwd cwd =
  match Atomic.get runtime_state with
  | None -> cwd
  | Some runtime ->
      let path = effective_cwd runtime.cwd_default cwd in
      match Eio.Path.with_open_dir path (fun _ -> Eio.Path.native_exn path) with
      | native -> Some native
      | exception (Eio.Io (error, _) as exn) ->
          raise (Refused_at_spawn
            (Cwd_unavailable
               { cwd = Format.asprintf "%a" Eio.Path.pp path
               ; error = Eio_cwd_error error }, exn))

let output_for_status = Process_eio_stderr.output_for_status
let process_error_output = Process_eio_stderr.process_error_output
let reason_of_exn_for_output = Process_eio_stderr.reason_of_exn_for_output
let create_stderr_tempfile = Process_eio_stderr.create_stderr_tempfile
let remove_temp_file_quietly = Process_eio_stderr.remove_temp_file_quietly
let captured_stderr_or_empty = Process_eio_stderr.captured_stderr_or_empty

(* [on_refusal], when given, receives every failure that happens before a
   child exists ({!spawn_refusal}) together with the exception that reported
   it; nothing ran. When absent those cases go through [on_error] rendered as
   text, which is what the tuple-returning runners do. *)
let with_unix_capture ?env ?cwd ?stdin_content ?(capture_stderr = false)
    ?timeout_sec ?on_refusal
    (argv : string list)
    ~(on_error : string -> string -> 'a)
    ~(on_success : Unix.process_status -> string -> string -> 'a) : 'a =
  let timeout_sec = validate_timeout_sec timeout_sec in
  (* Both readings are taken in this process, so the interval between them is
     the interval that elapsed. Off the wall clock it was not: a forward NTP
     step retired this deadline early and killed a running command, and the
     drain that follows was cut with it, so the tool's output came back
     truncated under a timeout it never hit. A backward step withheld the
     deadline and the wait sat. Taken where the wall-clock reading it replaces
     was, so the budget still covers the spawn and not only the run. *)
  let deadline =
    Option.map (fun seconds -> Monotonic_deadline.after ~seconds) timeout_sec
  in
  match argv with
  | [] ->
    (match on_refusal with
     | Some refuse -> refuse Empty_argv empty_argv_exn
     | None -> on_error "empty argv" "")
  | prog :: _ ->
    (* Set once the foreground owner has spawned its child. A [Unix_error]
       before that is a refusal; after it the child is running and the error
       is the capture's. *)
    let spawned = ref false in
    let owner = Unix_foreground_process.create () in
    let stdout_r_ref = ref None in
    let stdout_w_ref = ref None in
    let stderr_fd_ref = ref None in
    let stderr_path_ref = ref None in
    let stdin_r_ref = ref None in
    let stdin_w_ref = ref None in
    let cleanup_files () =
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
    let cleanup () =
      Fun.protect ~finally:cleanup_files (fun () ->
        Unix_foreground_process.close owner)
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
       let () =
         try
           let cwd = fallback_cwd cwd in
           Unix_foreground_process.spawn ?cwd owner prog argv env stdin_fd stdout_w stderr_fd
         with
         | Unix_foreground_process.Directory_unavailable { cwd; error } ->
             raise (Refused_at_spawn
               (Cwd_unavailable { cwd; error = Native_cwd_error error },
                Unix.Unix_error (error, "open process cwd", cwd)))
         | Unix.Unix_error (Unix.ENOENT, _, _) as exn ->
             raise (Refused_at_spawn (Executable_not_found prog, exn))
       in
       spawned := true;
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
            let kill_and_wait status_ref =
              status_ref := Some (Unix_foreground_process.terminate owner)
            in
            let waitpid_nohang () = Unix_foreground_process.poll owner in
            let stdout_buf = create_capture () in
            let chunk = Bytes.create 4096 in
            let read_available () =
              let rec loop () =
                try
                  match Unix.read stdout_r chunk 0 (Bytes.length chunk) with
                  | 0 -> `Eof
                  | n ->
                      Exec_buffer.add_bytes stdout_buf chunk 0 n;
                      loop ()
                with
                | Unix.Unix_error
                    ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
                    `Would_block
                | Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
              in
              loop ()
            in
            let deadline_reached () =
              match deadline with
              | None -> false
              | Some deadline -> Monotonic_deadline.passed deadline
            in
            let select_wait () =
              match deadline with
              | None -> 0.05
              | Some deadline ->
                min 0.05 (Monotonic_deadline.remaining_seconds deadline)
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
              if Option.is_none !status_ref then
                status_ref := waitpid_nohang ();
              if Option.is_some !status_ref then begin
                close_stdin ();
                (* The foreground leader is already gone and its group has
                   been signalled. Preserve bytes it left buffered, then stop
                   waiting for a descendant's inherited descriptor. *)
                (* See group cleanup above: EOF and a remaining inherited pipe both end this drain. *)
                ignore (read_available () : [ `Eof | `Would_block ]);
                stdout_eof := true
              end else if deadline_reached () then begin
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
                       let _ready = Unix.select [] [] [] (select_wait ()) in
                       ()
                     with Unix.Unix_error (Unix.EINTR, _, _) -> ())
            done;
            close_quietly stdout_r;
            stdout_r_ref := None;
            let status =
              if !timed_out then timed_out_status
              else
                match !status_ref with
                | Some status -> status
                | None -> Unix_foreground_process.terminate owner
            in
            let stdout = Exec_buffer.render stdout_buf in
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
                  ~reason:(Printf.sprintf "timeout after %.2fs" timeout_sec)
                  ()
              | Some _ | None -> stderr
            in
            (match timeout_event with
             | Some timeout_sec ->
               (* Spawn returned an owned child; this timeout is reported
                  against that running command. *)
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
     | Refused_at_spawn (refusal, exn) ->
         let stderr = captured_stderr_or_empty !stderr_path_ref in
         cleanup ();
         (match on_refusal with
          | Some refuse -> refuse refusal exn
          | None -> on_error (reason_of_exn_for_output exn) stderr)
     | Unix.Unix_error (error, _, _) as exn when not !spawned ->
         let stderr = captured_stderr_or_empty !stderr_path_ref in
         cleanup ();
         (match on_refusal with
          | Some refuse -> refuse (Spawn_failed { executable = prog; error }) exn
          | None -> on_error (reason_of_exn_for_output exn) stderr)
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

(* Same as [run_unix_argv_with_status_split_fallback] except that a failure
   before the child exists comes back as [Error (refusal, exn)] instead of
   the 127 tuple, and is not logged here: the caller asked for it as a value. *)
let run_unix_argv_with_status_split_fallback_resolving ?timeout_sec ?env ?cwd
    (argv : string list) :
    (Unix.process_status * string * string, spawn_refusal * exn) result =
  let label = String.concat " " (List.map Filename.quote argv) in
  with_unix_capture ?env ?cwd ?timeout_sec ~capture_stderr:true argv
    ~on_refusal:(fun refusal exn -> Error (refusal, exn))
    ~on_error:(fun reason stderr ->
      Log.Misc.error "[Process_eio] Unix fallback error: %s — %s" label reason;
      Ok (Unix.WEXITED 127, "", process_error_output ~label ~reason ~stderr ()))
    ~on_success:(fun status stdout stderr -> Ok (status, stdout, stderr))

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

let child_exit_grace_seconds = Eio_process_capture.child_exit_grace_seconds

type output_destination =
  | Captured
  | Written_to of {
      path : string;
      append : bool;
    }

type input_origin =
  | Inherited
  | From_string of string
  | Read_from of { path : string }

(* [Inherited] / [Captured] mean the stage takes the pipeline's own plumbing:
   the pipe from the stage before it, the pipe to the stage after it, the
   stderr this runtime collects. A file replaces that plumbing for one stream,
   which is how a shell reads `a > f | b` -- b's stdin is still the link, and
   it simply reaches EOF with nothing in it. *)
type pipeline_stage = {
  argv : string list;
  env : string array option;
  cwd : string option;
  stdin : input_origin;
  stdout : output_destination;
  stderr : output_destination;
}

let plumbed_stage ~argv ~env ~cwd =
  { argv; env; cwd; stdin = Inherited; stdout = Captured; stderr = Captured }
;;

(* Opening a stage's file happens deep inside the spawn loop, where a Result
   cannot be threaded out without restructuring the pipe choreography around
   it. The exception is caught at the entry point and becomes the Error the
   caller sees; it never escapes this module. *)
exception Pipeline_redirect_failed of string

let stage_holds_a_file { stdin; stdout; stderr; _ } =
  let source_is_a_file =
    match stdin with
    | Inherited | From_string _ -> false
    | Read_from _ -> true
  in
  let sink_is_a_file = function
    | Captured -> false
    | Written_to _ -> true
  in
  source_is_a_file || sink_is_a_file stdout || sink_is_a_file stderr
;;

(* The single place a caller's [cwd] string becomes a path. [Spawn_registry]
   needs the rule the run/capture paths already use -- an absolute path
   replaces the default, a relative one appends to it -- and a second copy of
   that rule would be a second answer to the same question. *)
let cwd_path cwd =
  match get_cwd_default () with
  | Error _ as error -> error
  | Ok default -> Ok (effective_cwd default cwd)
;;

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
            let buf = create_capture () in
            let label = String.concat " " (List.map Filename.quote argv) in
            let phase_ref = ref Timeout_origin.Spawn in
            try
              Eio.Switch.run (fun sw ->
                  with_explicit_timeout_exn clk timeout_sec (fun () ->
                      let status = Eio_process_capture.spawn_and_drain_stdout ~phase_ref ~sw pm ~cwd ?env ~clock:clk argv buf in
                      output_for_status ~status ~stdout:(Exec_buffer.render buf) ~stderr:""))
            with
            | Explicit_process_timeout timeout_sec ->
                Log.Misc.warn "[Process_eio] Timeout after %.2fs (%s): %s"
                  timeout_sec (Timeout_origin.to_label !phase_ref) label;
                observe_process_timeout argv ~timeout_sec ~origin:!phase_ref;
                process_error_output ~label
                  ~partial_stdout:(Exec_buffer.render buf)
                  ~reason:(Printf.sprintf "timeout after %.2fs" timeout_sec) ()
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
                if should_retry_unix_fallback exn then (
                  Log.Misc.warn
                    "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                    label (Printexc.to_string exn);
                  run_unix_argv_fallback ?timeout_sec ?env argv
                ) else if Eio_process_capture.is_downstream_pipe_closed exn then (
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
            let buf = create_capture () in
            let label = String.concat " " (List.map Filename.quote argv) in
            let stdin_source = Eio.Flow.string_source stdin_content in
            let phase_ref = ref Timeout_origin.Spawn in
            try
              Eio.Switch.run (fun sw ->
                  with_explicit_timeout_exn clk timeout_sec (fun () ->
                      let status =
                        Eio_process_capture.spawn_and_drain_stdout ~phase_ref ~sw pm ~cwd ?env ~stdin_source ~clock:clk argv buf
                      in
                      output_for_status ~status ~stdout:(Exec_buffer.render buf) ~stderr:""))
            with
            | Explicit_process_timeout timeout_sec ->
                Log.Misc.warn "[Process_eio] Timeout after %.2fs (%s): %s"
                  timeout_sec (Timeout_origin.to_label !phase_ref) label;
                observe_process_timeout argv ~timeout_sec ~origin:!phase_ref;
                process_error_output ~label
                  ~partial_stdout:(Exec_buffer.render buf)
                  ~reason:(Printf.sprintf "timeout after %.2fs" timeout_sec) ()
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
                if should_retry_unix_fallback exn then (
                  Log.Misc.warn
                    "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                    label (Printexc.to_string exn);
                  run_unix_argv_with_stdin_fallback ?timeout_sec ?env ~stdin_content argv
                ) else if Eio_process_capture.is_downstream_pipe_closed exn then (
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
    ?output_capture
    ?on_stdout_chunk
    ?on_stderr_chunk
    ~(stdin_content : string)
    (argv : string list) : Unix.process_status * string * string =
  let timeout_sec = validate_timeout_sec timeout_sec in
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_stdin_and_status ~argv ?env ();
  let fallback_with_callbacks () =
    Option.iter
      (fun capture ->
        Process_output_capture.unavailable capture
          ~message:"Unix fallback provides retained output without authoritative pipe EOF")
      output_capture;
    let status, stdout, stderr =
      run_unix_argv_with_stdin_and_status_split_fallback ?timeout_sec ?env
        ?cwd ~stdin_content argv
    in
    Option.iter
      (fun f -> if stdout <> "" then Eio_process_capture.invoke_output_chunk_callback f stdout)
      on_stdout_chunk;
    Option.iter
      (fun f -> if stderr <> "" then Eio_process_capture.invoke_output_chunk_callback f stderr)
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
              effective_cwd default_cwd cwd
            in
            let stdout_buf = create_capture () in
            let stderr_buf = create_capture () in
            let label = String.concat " " (List.map Filename.quote argv) in
            let stdin_source = Eio.Flow.string_source stdin_content in
            let phase_ref = ref Timeout_origin.Spawn in
            try
              Eio.Switch.run (fun sw ->
                  let unix_status =
                    with_explicit_timeout_exn clk timeout_sec (fun () ->
                        Eio_process_capture.spawn_and_drain_both
                          ~phase_ref ?output_capture ?on_stdout_chunk ?on_stderr_chunk
                          ~sw pm ~cwd:effective_cwd ?env ~stdin_source ~clock:clk
                          argv stdout_buf stderr_buf)
                  in
                  ( unix_status,
                    Exec_buffer.render stdout_buf,
                    Exec_buffer.render stderr_buf ))
            with
            | Explicit_process_timeout timeout_sec ->
                Log.Misc.warn "[Process_eio] Timeout after %.2fs (%s): %s"
                  timeout_sec (Timeout_origin.to_label !phase_ref) label;
                observe_process_timeout argv ~timeout_sec ~origin:!phase_ref;
                let timeout_status = timed_out_status in
                let stdout = Exec_buffer.render stdout_buf in
                let stderr = Exec_buffer.render stderr_buf in
                let stderr =
                  if String.trim stdout = "" && String.trim stderr = "" then
                    process_error_output ~label
                      ~reason:(Printf.sprintf "timeout after %.2fs" timeout_sec) ()
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
                ) else if Eio_process_capture.is_downstream_pipe_closed exn then (
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

let run_argv_with_stdin_held_open_and_status_split
    ?timeout_sec
    ?env
    ?cwd
    ?on_stdout_chunk
    ?on_stderr_chunk
    ~(stdin_content : string)
    (argv : string list) : Unix.process_status * string * string =
  let timeout_sec = validate_timeout_sec timeout_sec in
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_stdin_and_status
    ~argv ?env ();
  with_spawn_guard (fun () ->
    match get_proc_mgr (), get_clock (), get_cwd_default () with
    | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
      ( Unix.WEXITED 127
      , ""
      , "Process_eio.run_argv_with_stdin_held_open_and_status_split: initialized Eio runtime required" )
    | Ok pm, Ok clk, Ok default_cwd ->
      let effective_cwd =
        effective_cwd default_cwd cwd
      in
      let stdout_buf = create_capture () in
      let stderr_buf = create_capture () in
      let label = String.concat " " (List.map Filename.quote argv) in
      let phase_ref = ref Timeout_origin.Spawn in
      try
        Eio.Switch.run (fun sw ->
          let unix_status =
            with_explicit_timeout_exn clk timeout_sec (fun () ->
              Eio_process_capture.spawn_and_drain_both_with_stdin_held_open
                ~phase_ref ~sw pm ~cwd:effective_cwd ?env ~stdin_content
                ~clock:clk argv ?on_stdout_chunk ?on_stderr_chunk stdout_buf
                stderr_buf)
          in
          unix_status, Exec_buffer.render stdout_buf, Exec_buffer.render stderr_buf)
      with
      | Explicit_process_timeout timeout_sec ->
        Log.Misc.warn "[Process_eio] Timeout after %.2fs (%s): %s"
          timeout_sec (Timeout_origin.to_label !phase_ref) label;
        observe_process_timeout argv ~timeout_sec ~origin:!phase_ref;
        let stdout = Exec_buffer.render stdout_buf in
        let stderr = Exec_buffer.render stderr_buf in
        let stderr =
          if String.trim stdout = "" && String.trim stderr = ""
          then
            process_error_output ~label
              ~reason:(Printf.sprintf "timeout after %.2fs" timeout_sec) ()
          else stderr
        in
        timed_out_status, stdout, stderr
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn when Eio_process_capture.is_downstream_pipe_closed exn ->
        Log.Misc.debug "[Process_eio] held-open stdin pipe closed by reader: %s — %s"
          label (Printexc.to_string exn);
        ( Unix.WEXITED 127
        , Exec_buffer.render stdout_buf
        , process_error_output ~label ~reason:"pipe closed by reader" () )
      | exn ->
        Log.Misc.error "[Process_eio] held-open stdin argv error: %s — %s"
          label (Printexc.to_string exn);
        ( Unix.WEXITED 127
        , Exec_buffer.render stdout_buf
        , process_error_output ~label ~reason:(reason_of_exn_for_output exn) () ))

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

(* A file redirect is opened before the spawn, the way a shell does it, so a
   path that cannot be opened stops the command instead of letting it run with
   the stream attached somewhere else. *)
let open_sink ~sw ~fs ~path ~append =
  try
    Ok
      (if append
       then Eio.Path.open_out ~sw ~append:true ~create:(`If_missing 0o644) Eio.Path.(fs / path)
       else Eio.Path.open_out ~sw ~create:(`Or_truncate 0o644) Eio.Path.(fs / path))
  with
  | Eio.Io _ as exn -> Error (Printf.sprintf "cannot open %s for writing: %s" path (Printexc.to_string exn))
  | Sys_error message -> Error (Printf.sprintf "cannot open %s for writing: %s" path message)
;;

let open_source ~sw ~fs path =
  try Ok (Eio.Path.open_in ~sw Eio.Path.(fs / path)) with
  | Eio.Io _ as exn -> Error (Printf.sprintf "cannot open %s for reading: %s" path (Printexc.to_string exn))
  | Sys_error message -> Error (Printf.sprintf "cannot open %s for reading: %s" path message)
;;

(* One output stream's plumbing: either a pipe this process drains, or the
   file the child writes into directly. The read end is [None] in the second
   case, which is what tells the caller there is nothing to drain. *)
type closable_sink = [ Eio.Flow.sink_ty | Eio.Resource.close_ty ] Eio.Resource.t
type closable_source = [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Resource.t

type output_plumbing = {
  child_flow : closable_sink;
  drain : (closable_source * Exec_buffer.t) option;
}

let output_plumbing ~sw ~fs pm destination =
  match destination with
  | Captured ->
    let reader, writer = Eio.Process.pipe ~sw pm in
    Ok
      { child_flow = (writer :> closable_sink)
      ; drain = Some ((reader :> closable_source), create_capture ())
      }
  | Written_to { path; append } ->
    Result.map
      (fun sink -> { child_flow = (sink :> closable_sink); drain = None })
      (open_sink ~sw ~fs ~path ~append)
;;

let rendered_output { drain; _ } =
  match drain with
  | None -> ""
  | Some (_, buf) -> Exec_buffer.render buf
;;

let run_argv_with_redirects ?timeout_sec ?env ?cwd ~stdin ~stdout ~stderr
      (argv : string list) : (Unix.process_status * string * string, string) result =
  let timeout_sec = validate_timeout_sec timeout_sec in
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_status ~argv ?env ?cwd ();
  with_spawn_guard (fun () ->
    match get_proc_mgr (), get_clock (), get_cwd_default () with
    | Error message, _, _ | _, Error message, _ | _, _, Error message -> Error message
    | Ok pm, Ok clk, Ok fs ->
      let effective_cwd =
        match cwd with
        | None -> fs
        | Some dir -> Eio.Path.(fs / dir)
      in
      let label = String.concat " " (List.map Filename.quote argv) in
      let phase_ref = ref Timeout_origin.Spawn in
      (try
         Eio.Switch.run (fun sw ->
           let ( let* ) = Result.bind in
           let* stdin_source =
             match stdin with
             | Inherited -> Ok None
             | From_string content ->
               Ok (Some (Eio.Flow.string_source content :> Eio.Flow.source_ty Eio.Resource.t))
             | Read_from { path } ->
               Result.map
                 (fun source -> Some (source :> Eio.Flow.source_ty Eio.Resource.t))
                 (open_source ~sw ~fs path)
           in
           let* out = output_plumbing ~sw ~fs pm stdout in
           let* err = output_plumbing ~sw ~fs pm stderr in
           let run () =
             let proc =
               Eio.Process.spawn ~sw
                 (Posix_spawn_process_mgr.foreground_mgr ~clock:clk
                    ~grace_seconds:child_exit_grace_seconds) ~cwd:effective_cwd ?env
                 ?stdin:stdin_source
                 ~stdout:out.child_flow
                 ~stderr:err.child_flow
                 argv
             in
             phase_ref := Timeout_origin.Command;
             (* The child owns its ends now; keeping them open here would hold
                a pipe from ever reaching EOF. *)
             Eio.Flow.close out.child_flow;
             Eio.Flow.close err.child_flow;
             let status = ref None in
             Fun.protect
               ~finally:(fun () ->
                 Eio_process_capture.finalize_spawned_proc ~sw ~clock:clk proc status ~sinks:[]
                   ~sources:
                     (List.filter_map
                        (fun (name, plumbing) ->
                           Option.map (fun (reader, _) -> name, reader) plumbing.drain)
                        [ "stdout", out; "stderr", err ]))
               (fun () ->
                  Eio.Fiber.both
                    (fun () ->
                       Option.iter
                         (fun (reader, buf) -> Eio_process_capture.drain_to_eof reader buf)
                         out.drain)
                    (fun () ->
                       Option.iter
                         (fun (reader, buf) -> Eio_process_capture.drain_to_eof reader buf)
                         err.drain);
                  let s = Eio.Process.await proc in
                  status := Some s;
                  s)
             |> Eio_process_capture.unix_status_of_eio_status
           in
           let unix_status = with_explicit_timeout_exn clk timeout_sec run in
           Ok (unix_status, rendered_output out, rendered_output err))
       with
       | Explicit_process_timeout timeout_sec ->
         Log.Misc.warn "[Process_eio] Timeout after %.2fs (%s): %s" timeout_sec
           (Timeout_origin.to_label !phase_ref) label;
         observe_process_timeout argv ~timeout_sec ~origin:!phase_ref;
         Ok (timed_out_status, "", process_error_output ~label
               ~reason:(Printf.sprintf "timeout after %.2fs" timeout_sec) ())
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn -> Error (Printf.sprintf "%s: %s" label (Printexc.to_string exn))))
;;

(* Shared body of [run_argv_with_status_split] and
   [run_argv_with_status_split_or_refusal]. [Error (refusal, exn)] is a
   failure that precedes the process ({!spawn_refusal}); the Unix fallback
   reports the same set through [with_unix_capture]. Nothing is logged for it
   here because the two callers disagree on what it is: the tuple runner
   renders it as the 127 status it always has, the typed runner hands it
   back. *)
let run_argv_with_status_split_resolving ?timeout_sec ?env ?cwd
    (argv : string list) :
    (Unix.process_status * string * string, spawn_refusal * exn) result =
  let timeout_sec = validate_timeout_sec timeout_sec in
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_status ~argv ?env ?cwd ();
  with_spawn_guard (fun () ->
      match argv with
      | [] -> Error (Empty_argv, empty_argv_exn)
      | executable :: _ ->
      if not (is_initialized ()) then
        run_unix_argv_with_status_split_fallback_resolving ?timeout_sec ?env ?cwd argv
      else
        match get_proc_mgr (), get_clock (), get_cwd_default () with
        | Error _, _, _ | _, Error _, _ | _, _, Error _ ->
            run_unix_argv_with_status_split_fallback_resolving ?timeout_sec ?env ?cwd
              argv
        | Ok pm, Ok clk, Ok default_cwd ->
            let effective_cwd =
              effective_cwd default_cwd cwd
            in
            let stdout_buf = create_capture () in
            let stderr_buf = create_capture () in
            let label = String.concat " " (List.map Filename.quote argv) in
            let phase_ref = ref Timeout_origin.Spawn in
            try
              Ok
                (Eio.Switch.run (fun sw ->
                     let unix_status =
                       with_explicit_timeout_exn clk timeout_sec (fun () ->
                           Eio_process_capture.spawn_and_drain_both ~phase_ref ~sw pm ~cwd:effective_cwd ?env
                             ~clock:clk argv stdout_buf stderr_buf)
                     in
                     ( unix_status,
                       Exec_buffer.render stdout_buf,
                       Exec_buffer.render stderr_buf )))
            with
            | Explicit_process_timeout timeout_sec ->
                Log.Misc.warn "[Process_eio] Timeout after %.2fs (%s): %s"
                  timeout_sec (Timeout_origin.to_label !phase_ref) label;
                observe_process_timeout argv ~timeout_sec ~origin:!phase_ref;
                let timeout_status = timed_out_status in
                let stdout = Exec_buffer.render stdout_buf in
                let stderr = Exec_buffer.render stderr_buf in
                let stderr =
                  if String.trim stdout = "" && String.trim stderr = "" then
                    process_error_output ~label
                      ~reason:(Printf.sprintf "timeout after %.2fs" timeout_sec) ()
                  else stderr
                in
                Ok (timeout_status, stdout, stderr)
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | Eio.Io (Eio.Process.E (Eio.Process.Executable_not_found program), _) as exn ->
                Error (Executable_not_found program, exn)
            | Failure detail as exn when in_spawn_phase phase_ref ->
                Error (Child_setup_failed { executable; detail }, exn)
            | Unix.Unix_error (error, _, _) as exn
              when in_spawn_phase phase_ref && not (should_retry_unix_fallback exn) ->
                Error (Spawn_failed { executable; error }, exn)
            | Eio.Io (Eio.Fs.E error, _) as exn when in_spawn_phase phase_ref ->
                Error
                  ( Cwd_unavailable
                      { cwd = Format.asprintf "%a" Eio.Path.pp effective_cwd
                      ; error = Eio_cwd_error (Eio.Fs.E error) }
                  , exn )
            | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (error, _, _)), _) as exn
              when in_spawn_phase phase_ref ->
                Error (Spawn_failed { executable; error }, exn)
            | exn ->
                if should_retry_unix_fallback exn then (
                  Log.Misc.warn
                    "[Process_eio] argv bind error, retrying via Unix fallback: %s — %s"
                    label (Printexc.to_string exn);
                  run_unix_argv_with_status_split_fallback_resolving ?timeout_sec ?env
                    ?cwd argv
                ) else if Eio_process_capture.is_downstream_pipe_closed exn then (
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
                  Ok
                    ( Unix.WEXITED 127,
                      "",
                      process_error_output ~label
                        ~reason:"pipe closed by reader" () )
                ) else (
                  Log.Misc.error "[Process_eio] argv error: %s — %s" label
                    (Printexc.to_string exn);
                  Ok
                    ( Unix.WEXITED 127,
                      "",
                      process_error_output ~label
                        ~reason:(reason_of_exn_for_output exn) () )))

let run_argv_with_status_split ?timeout_sec ?env ?cwd
    (argv : string list) : Unix.process_status * string * string =
  match run_argv_with_status_split_resolving ?timeout_sec ?env ?cwd argv with
  | Ok outcome -> outcome
  | Error (_refusal, exn) ->
      let label = String.concat " " (List.map Filename.quote argv) in
      Log.Misc.error "[Process_eio] argv error: %s — %s" label
        (Printexc.to_string exn);
      ( Unix.WEXITED 127,
        "",
        process_error_output ~label ~reason:(reason_of_exn_for_output exn) () )

let run_argv_with_status_split_or_refusal ?timeout_sec ?env ?cwd
    (argv : string list) :
    (Unix.process_status * string * string, spawn_refusal) result =
  Result.map_error
    (fun (refusal, _exn) -> refusal)
    (run_argv_with_status_split_resolving ?timeout_sec ?env ?cwd argv)

let run_argv_with_status_split_streaming
    ?timeout_sec
    ?env
    ?cwd
    ?output_capture
    ~on_stdout_chunk
    ~on_stderr_chunk
    (argv : string list)
    : Unix.process_status * string * string
  =
  let timeout_sec = validate_timeout_sec timeout_sec in
  Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_status ~argv ?env ?cwd ();
  let fallback_with_callbacks () =
    Option.iter
      (fun capture ->
        Process_output_capture.unavailable capture
          ~message:"Unix fallback provides retained output without authoritative pipe EOF")
      output_capture;
    let status, stdout, stderr =
      run_unix_argv_with_status_split_fallback ?timeout_sec ?env ?cwd argv
    in
    if not (String.equal stdout "")
    then Eio_process_capture.invoke_output_chunk_callback on_stdout_chunk stdout;
    if not (String.equal stderr "")
    then Eio_process_capture.invoke_output_chunk_callback on_stderr_chunk stderr;
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
            effective_cwd default_cwd cwd
          in
          let stdout_buf = create_capture () in
          let stderr_buf = create_capture () in
          let label = String.concat " " (List.map Filename.quote argv) in
          let phase_ref = ref Timeout_origin.Spawn in
          try
            Eio.Switch.run (fun sw ->
                let unix_status =
                  with_explicit_timeout_exn clk timeout_sec (fun () ->
                      Eio_process_capture.spawn_and_drain_both
                        ~phase_ref
                        ?output_capture
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
                unix_status, Exec_buffer.render stdout_buf, Exec_buffer.render stderr_buf)
          with
          | Explicit_process_timeout timeout_sec ->
            Log.Misc.warn "[Process_eio] Timeout after %.2fs (%s): %s"
              timeout_sec (Timeout_origin.to_label !phase_ref) label;
            observe_process_timeout argv ~timeout_sec ~origin:!phase_ref;
            let timeout_status = timed_out_status in
            let stdout = Exec_buffer.render stdout_buf in
            let stderr = Exec_buffer.render stderr_buf in
            let stderr =
              if String.trim stdout = "" && String.trim stderr = ""
              then process_error_output ~label
                     ~reason:(Printf.sprintf "timeout after %.2fs" timeout_sec) ()
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
            else if Eio_process_capture.is_downstream_pipe_closed exn
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
    (stages : pipeline_stage list) :
    (Unix.process_status * string * string, string) result =
  let timeout_sec = validate_timeout_sec timeout_sec in
  let fallback_buffered () =
    let rec chain prev_stdout = function
      | [] -> (Unix.WEXITED 0, prev_stdout, "")
      | [ { argv; env; cwd; _ } ] ->
          run_unix_argv_with_stdin_and_status_split_fallback ?timeout_sec ?env
            ?cwd ~stdin_content:prev_stdout argv
      | { argv; env; cwd; _ } :: rest ->
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
      | [ { argv; env; cwd; _ } ] ->
          run_unix_argv_with_status_split_fallback ?timeout_sec ?env ?cwd argv
      | { argv; env; cwd; _ } :: rest ->
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
         Eio_process_capture.invoke_output_chunk_callback f stdout
     | _ -> ());
    (match on_stderr_chunk with
     | Some f when not (String.equal stderr "") ->
         Eio_process_capture.invoke_output_chunk_callback f stderr
     | _ -> ());
    result
  in
  let holds_files = List.exists stage_holds_a_file stages in
  let without_eio () =
    (* The buffered fallback chains stages through strings and has no way to
       hand a child a file. Running it anyway would drop the redirect. *)
    if holds_files
    then
      Error
        "a pipeline stage names a file, which needs the Eio runtime this \
         process has not initialized"
    else Ok (fallback_buffered ())
  in
  with_spawn_guard (fun () ->
      if not (is_initialized ()) then without_eio ()
      else
        match get_proc_mgr (), get_clock (), get_cwd_default () with
        | Error _, _, _ | _, Error _, _ | _, _, Error _ -> without_eio ()
        | Ok pm, Ok clk, Ok default_cwd ->
            let label =
              stages
              |> List.map (fun stage ->
                String.concat " " (List.map Filename.quote stage.argv))
              |> String.concat " | "
            in
            let stdout_buf = create_capture () in
            let stderr_buffers = List.map (fun _ -> create_capture ()) stages in
            let stderr_contents () =
              stderr_buffers
              |> List.map Exec_buffer.render
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
                   (* A file named by a stage replaces the plumbing it would
                      otherwise take. The pipe is still created and still
                      closed below, so the drain choreography does not change:
                      an unused read end simply reaches EOF empty. *)
                   let opened_files = ref [] in
                   let sink_flow ~fallback = function
                     | Captured -> (fallback :> closable_sink)
                     | Written_to { path; append } ->
                       (match open_sink ~sw ~fs:default_cwd ~path ~append with
                        | Ok sink ->
                          let sink = (sink :> closable_sink) in
                          opened_files := sink :: !opened_files;
                          sink
                        | Error message -> raise (Pipeline_redirect_failed message))
                   in
                   let source_flow ~fallback = function
                     | Inherited -> fallback
                     | From_string content ->
                       Some
                         (Eio.Flow.string_source content
                          :> Eio.Flow.source_ty Eio.Resource.t)
                     | Read_from { path } ->
                       (match open_source ~sw ~fs:default_cwd path with
                        | Ok source ->
                          Some (source :> Eio.Flow.source_ty Eio.Resource.t)
                        | Error message -> raise (Pipeline_redirect_failed message))
                   in
                   let procs =
                     stages
                     |> List.mapi (fun idx stage ->
                       Exec_tap.record ~kind:Exec_tap.Process_eio_run_argv_with_status
                         ~argv:stage.argv ?env:stage.env ?cwd:stage.cwd ();
                       let stdin =
                         source_flow
                           ~fallback:
                             (if idx = 0
                              then None
                              else
                                Some
                                  (fst (List.nth links (idx - 1))
                                   :> Eio.Flow.source_ty Eio.Resource.t))
                           stage.stdin
                       in
                       let stdout =
                         sink_flow
                           ~fallback:
                             (if idx = List.length stages - 1
                              then final_stdout_w
                              else snd (List.nth links idx))
                           stage.stdout
                       in
                       let stderr =
                         sink_flow ~fallback:(snd (List.nth stderr_pairs idx)) stage.stderr
                       in
                       let proc =
                         Eio.Process.spawn
                           ~sw
                           (Posix_spawn_process_mgr.foreground_mgr ~clock:clk
                              ~grace_seconds:child_exit_grace_seconds)
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
                   List.iter Eio.Flow.close !opened_files;
                   Eio.Flow.close final_stdout_w;
                   List.iter
                     (fun (r, w) ->
                       Eio.Flow.close r;
                       Eio.Flow.close w)
                     links;
                   List.iter
                     (fun (_r, w) -> Eio.Flow.close w)
                     stderr_pairs;
                   let drain_final_stdout () =
                     Eio_process_capture.drain_to_eof ?on_chunk:on_stdout_chunk
                       final_stdout_r stdout_buf
                   in
                   let drain_stderr idx (r, _w) =
                     let buf = List.nth stderr_buffers idx in
                     Eio_process_capture.drain_to_eof ?on_chunk:on_stderr_chunk r buf
                   in
                   let await_all () =
                     List.map Eio.Process.await procs
                     |> List.map Eio_process_capture.unix_status_of_eio_status
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
                       Ok
                         ( pipeline_status statuses
                         , Exec_buffer.render stdout_buf
                         , stderr ))
                   with Explicit_process_timeout timeout_sec ->
                     List.iter (Eio_process_capture.reap_proc_with_clock ~sw clk) procs;
                     raise (Explicit_process_timeout timeout_sec))
             with
             | Pipeline_redirect_failed message -> Error message
             | Explicit_process_timeout timeout_sec ->
                 Log.Misc.warn "[Process_eio] Timeout after %.2fs (%s): %s"
                   timeout_sec (Timeout_origin.to_label !phase_ref) label;
                 observe_process_timeout
                   (match stages with [] -> [] | stage :: _ -> stage.argv)
                   ~timeout_sec ~origin:!phase_ref;
                 let streamed_stderr = stderr_contents () in
                 let stderr =
                   if String.trim streamed_stderr = "" then
                     process_error_output ~label
                       ~reason:(Printf.sprintf "timeout after %.2fs" timeout_sec)
                       ()
                   else streamed_stderr
                 in
                 Ok (timed_out_status, Exec_buffer.render stdout_buf, stderr)
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn ->
                 if should_retry_unix_fallback exn then (
                   Log.Misc.warn
                     "[Process_eio] pipeline bind error, retrying via Unix fallback: %s — %s"
                     label (Printexc.to_string exn);
                   without_eio ())
                 else (
                   Log.Misc.error "[Process_eio] pipeline error: %s — %s" label
                     (Printexc.to_string exn);
                   Ok
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
