(** File_lock_eio — Cooperative per-key locking via Eio.Mutex + flock.

    Two-layer locking for local filesystem paths:
    1. Eio.Mutex (cooperative) — prevents blocking the Eio fiber scheduler
    2. Unix.lockf F_TLOCK (non-blocking) — preserves cross-process safety

    The Eio.Mutex serializes fibers within the process so most contention
    is resolved cooperatively.  The flock is acquired non-blocking after
    the Eio.Mutex; if another process holds it, we yield and retry.

    Distributed backend paths (Some key in workspace_utils_ops.ml) are not
    affected — this only replaces the local filesystem lock path. *)

module SMap = Set_util.StringMap

exception Flock_timeout of { caller : string; path : string; attempts : int }

type durable_lock_phase =
  | Open_lock_file
  | Acquire_process_lock
  | Release_process_lock

type unix_failure =
  { error : Unix.error
  ; operation : string
  ; argument : string
  }

type durable_lock_error =
  { lock_path : string
  ; phase : durable_lock_phase
  ; cause : unix_failure
  ; cleanup_failure : unix_failure option
  }

let durable_lock_phase_to_string = function
  | Open_lock_file -> "open_lock_file"
  | Acquire_process_lock -> "acquire_process_lock"
  | Release_process_lock -> "release_process_lock"

let durable_lock_error_to_string error =
  let failure_to_string failure =
    Printf.sprintf "%s(%s): %s"
      failure.operation
      failure.argument
      (Unix.error_message failure.error)
  in
  Printf.sprintf "lock_path=%s phase=%s cause=%s%s"
    error.lock_path
    (durable_lock_phase_to_string error.phase)
    (failure_to_string error.cause)
    (match error.cleanup_failure with
     | None -> ""
     | Some failure -> " cleanup=" ^ failure_to_string failure)

(** Observability hook fired after each [acquire_flock_retry*] attempt
    sequence completes — once on success, once on timeout.  Wired at
    startup ([lib/workspace.ml]) to a Otel_metric_store counter + histogram so
    lock-contention spikes become visible without scraping logs.

    [retries] is the number of failed [F_TLOCK] attempts before the
    final outcome (0 means the first attempt succeeded).  [elapsed_s]
    is the wall-clock time spent inside [acquire_flock_retry*]
    excluding [openfile].  [outcome] is ["acquired"] or ["timeout"].

    Default no-op; [masc_process] cannot depend on [Otel_metric_store]
    (sub-library boundary, would be a cycle), so emission is wired
    from the [masc] root via this Atomic ref. *)
let on_lock_attempt_fn :
    (caller:string -> retries:int -> elapsed_s:float -> outcome:string -> unit)
      Atomic.t =
  Atomic.make (fun ~caller:_ ~retries:_ ~elapsed_s:_ ~outcome:_ -> ())

let observe_lock_attempt ~caller ~retries ~started_at ~outcome =
  let elapsed_s = max 0.0 (Time_compat.now () -. started_at) in
  try (Atomic.get on_lock_attempt_fn) ~caller ~retries ~elapsed_s ~outcome
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ()

(** Observability hook fired on every CAS retry inside [atomic_update*].
    The lock table is a single shared [Atomic.t]; under high fiber
    contention (many fibers concurrently calling [prune_stale_entries]
    / [get_entry] for different paths) the retry rate is the precise
    contention signal but was previously invisible.

    Default no-op; [masc_process] cannot depend on [Otel_metric_store]
    (sub-library boundary), so emission is wired from the [masc]
    root via this Atomic ref (mirrors [on_lock_attempt_fn] pattern). *)
let on_cas_retry_fn : (unit -> unit) Atomic.t =
  Atomic.make (fun () -> ())

let observe_cas_retry () =
  try (Atomic.get on_cas_retry_fn) ()
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ()

let rec atomic_update atomic f =
  let old_val = Atomic.get atomic in
  let new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then ()
  else begin
    observe_cas_retry ();
    atomic_update atomic f
  end

let rec atomic_update_with_result atomic f =
  let old_val = Atomic.get atomic in
  let new_val, result, rollback = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then result
  else begin
    rollback ();
    observe_cas_retry ();
    atomic_update_with_result atomic f
  end

type lock_entry = {
  mu : Eio.Mutex.t;
  cross_context_mu : Stdlib.Mutex.t;
  last_used : float Atomic.t;
  active : int Atomic.t;   (** Number of fibers currently holding or waiting on this mutex *)
}

type table_state = {
  version : int;
  entries : lock_entry SMap.t;
}

let max_lock_entries = 512
let stale_lock_seconds = 600.0

let table : table_state Atomic.t = Atomic.make { version = 0; entries = SMap.empty }

(* Bump the published version whenever the map shape changes so a structural
   A -> B -> A cycle cannot satisfy a stale CAS with the old snapshot. *)
let publish_entries state entries =
  if entries == state.entries then state
  else { version = state.version + 1; entries }

(** Remove entries unused for [stale_lock_seconds] when table exceeds
    [max_lock_entries]. *)
let prune_stale_entries () =
  atomic_update table (fun state ->
    if SMap.cardinal state.entries > max_lock_entries then
      let now = Time_compat.now () in
      let entries = SMap.filter (fun _path entry ->
        Atomic.get entry.active > 0
        || now -. Atomic.get entry.last_used <= stale_lock_seconds
      ) state.entries in
      publish_entries state entries
    else state
  )

(** Get or create a lock entry for the given file path.
    Increments [active] to prevent prune_stale_entries from removing
    in-use entries (see TLA+ FileLockStarvation spec). *)
let get_entry path =
  prune_stale_entries ();
  let entry =
    atomic_update_with_result table (fun state ->
      match SMap.find_opt path state.entries with
      | Some entry ->
        (* Publish a new version so a stale prune CAS cannot erase this reservation. *)
        Atomic.set entry.last_used (Time_compat.now ());
        Atomic.incr entry.active;
        ( { state with version = state.version + 1 }
        , entry
        , fun () -> ignore (Atomic.fetch_and_add entry.active (-1)) )
      | None ->
        let entry =
          { mu = Eio.Mutex.create ()
          ; cross_context_mu = Stdlib.Mutex.create ()
          ; last_used = Atomic.make (Time_compat.now ())
          ; active = Atomic.make 1
          }
        in
        let entries = SMap.add path entry state.entries in
        (publish_entries state entries, entry, Fun.id))
  in
  entry

let release_entry entry =
  ignore (Atomic.fetch_and_add entry.active (-1))

let run_blocking_lock_op f = Eio_guard.run_in_systhread f

(** Acquire a non-blocking Unix file lock (F_TLOCK) with retry.
    This is the blocking variant for callers that already run in a systhread
    (for example backend and Hebbian file I/O paths). On success, returns the
    open file descriptor with the lock held. On timeout, closes the fd and
    raises [Flock_timeout]. *)
let acquire_flock_retry ?clock:(_clock = None) ~lock_path ~mode ~perm
    ?(max_attempts = 200) ?(sleep_sec = 0.01) ~caller () =
  let fd = Unix.openfile lock_path mode perm in
  let started_at = Time_compat.now () in
  let rec acquire attempts =
    if attempts <= 0 then begin
      observe_lock_attempt ~caller ~retries:max_attempts ~started_at
        ~outcome:"timeout";
      raise (Flock_timeout { caller; path = lock_path; attempts = max_attempts })
    end
    else
      let success =
        try
          Unix.lockf fd Unix.F_TLOCK 0;
          true
        with
        | Unix.Unix_error (Unix.EAGAIN, _, _)
        | Unix.Unix_error (Unix.EACCES, _, _) -> false
      in
      if success then begin
        observe_lock_attempt ~caller
          ~retries:(max_attempts - attempts) ~started_at ~outcome:"acquired";
        fd
      end
      else begin
        Unix.sleepf sleep_sec;
        acquire (attempts - 1)
      end
  in
  try acquire max_attempts
  with exn ->
    (try Unix.close fd with Unix.Unix_error _ -> ());
    raise exn

(** Fiber-friendly wrapper around [acquire_flock_retry].
    Opening/closing the descriptor uses a systhread, and the F_TLOCK attempt
    also runs in a systhread to avoid blocking the Eio domain on filesystems
    that do not honor the non-blocking contract reliably. Retry sleep yields
    to the Eio scheduler when a clock is available and otherwise sleeps in a
    systhread so the calling fiber does not block the domain. *)
let acquire_flock_retry_cooperative ?clock ~lock_path ~mode ~perm
    ?(max_attempts = 200) ?(sleep_sec = 0.01) ~caller () =
  let fd = run_blocking_lock_op (fun () -> Unix.openfile lock_path mode perm) in
  let started_at = Time_compat.now () in
  let rec acquire attempts =
    if attempts <= 0 then begin
      observe_lock_attempt ~caller ~retries:max_attempts ~started_at
        ~outcome:"timeout";
      raise (Flock_timeout { caller; path = lock_path; attempts = max_attempts })
    end
    else
      let success =
        run_blocking_lock_op (fun () ->
            try
              Unix.lockf fd Unix.F_TLOCK 0;
              true
            with
            | Unix.Unix_error (Unix.EAGAIN, _, _)
            | Unix.Unix_error (Unix.EACCES, _, _) -> false)
      in
      if success then begin
        observe_lock_attempt ~caller
          ~retries:(max_attempts - attempts) ~started_at ~outcome:"acquired";
        fd
      end
      else begin
        (match clock with
         | Some c -> Eio.Time.sleep c sleep_sec
         | None -> run_blocking_lock_op (fun () -> Unix.sleepf sleep_sec));
        acquire (attempts - 1)
      end
  in
  try acquire max_attempts
  with exn ->
    run_blocking_lock_op (fun () -> try Unix.close fd with Unix.Unix_error _ -> ());
    raise exn

let acquire_flock_fd ?clock lock_path =
  acquire_flock_retry_cooperative ?clock ~lock_path
    ~mode:[ Unix.O_CREAT; Unix.O_WRONLY ] ~perm:0o644
    ~caller:"File_lock_eio" ()

let release_flock_fd fd =
  run_blocking_lock_op (fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
      Unix.close fd)

let rec lock_cross_context_cooperatively mutex =
  if Stdlib.Mutex.try_lock mutex
  then ()
  else (
    Eio.Fiber.yield ();
    lock_cross_context_cooperatively mutex)

let with_entry_lock entry f =
  match Eio_guard.execution_context () with
  | Eio_guard.Non_eio -> Stdlib.Mutex.protect entry.cross_context_mu f
  | Eio_guard.Eio_fiber ->
    Eio.Mutex.use_ro entry.mu (fun () ->
      lock_cross_context_cooperatively entry.cross_context_mu;
      Fun.protect
        ~finally:(fun () -> Stdlib.Mutex.unlock entry.cross_context_mu)
        f)

(** Run [f] while holding only the cross-context per-path mutex.
    Use this for in-memory backends that need single-process fiber
    serialization but do not have a real filesystem artifact to flock. *)
let with_mutex path f =
  let entry = get_entry path in
  Common.protect ~module_name:"file_lock_eio" ~finally_label:"release_entry"
    ~finally:(fun () -> release_entry entry)
    (fun () -> with_entry_lock entry f)

(** Run [f] while holding both the cooperative Eio.Mutex and an
    OS-level flock on [path].lock. The flock uses non-blocking F_TLOCK
    retries; sleep/yield stays scheduler-friendly whether or not a clock
    is provided. Max 200 attempts (~2s with sleeps). *)
let with_lock ?clock path f =
  let run_with_flock () =
    let lock_path = path ^ ".lock" in
    let dir = Filename.dirname lock_path in
    if not (Sys.file_exists dir) then
      (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let fd = acquire_flock_fd ?clock lock_path in
    Common.protect ~module_name:"file_lock_eio" ~finally_label:"finalizer"
      ~finally:(fun () -> release_flock_fd fd)
      f
  in
  with_mutex path (fun () -> run_with_flock ())

let unix_failure (error, operation, argument) =
  { error; operation; argument }

let close_fd_result fd =
  try
    run_blocking_lock_op (fun () -> Unix.close fd);
    Ok ()
  with
  | Unix.Unix_error (error, operation, argument) ->
    Error (unix_failure (error, operation, argument))

let release_durable_fd_result fd =
  let unlock =
    try
      run_blocking_lock_op (fun () -> Unix.lockf fd Unix.F_ULOCK 0);
      Ok ()
    with
    | Unix.Unix_error (error, operation, argument) ->
      Error (unix_failure (error, operation, argument))
  in
  let close = close_fd_result fd in
  match unlock, close with
  | Ok (), Ok () -> Ok ()
  | Error cause, Ok ()
  | Ok (), Error cause -> Error (cause, None)
  | Error cause, Error cleanup_failure -> Error (cause, Some cleanup_failure)

let protect_cleanup execution_context f =
  match execution_context with
  | Eio_guard.Eio_fiber -> Eio.Cancel.protect f
  | Eio_guard.Non_eio -> f ()

let close_fd_after_exception ~lock_path execution_context fd =
  match protect_cleanup execution_context (fun () -> close_fd_result fd) with
  | Ok () -> ()
  | Error failure ->
    Log.Misc.error
      "file_lock_eio: fd cleanup failed lock_path=%s operation=%s argument=%s error=%s"
      lock_path failure.operation failure.argument
      (Unix.error_message failure.error)

let release_fd_after_exception ~lock_path execution_context fd =
  match
    protect_cleanup execution_context (fun () -> release_durable_fd_result fd)
  with
  | Ok () -> ()
  | Error (failure, cleanup_failure) ->
    Log.Misc.error
      "file_lock_eio: lock cleanup failed lock_path=%s operation=%s argument=%s error=%s%s"
      lock_path failure.operation failure.argument
      (Unix.error_message failure.error)
      (match cleanup_failure with
       | None -> ""
       | Some cleanup ->
         Printf.sprintf " cleanup_operation=%s cleanup_argument=%s cleanup_error=%s"
           cleanup.operation cleanup.argument
           (Unix.error_message cleanup.error))

let durable_lock_error ?cleanup_failure ~lock_path ~phase cause =
  { lock_path; phase; cause; cleanup_failure }

let open_durable_lock_file ~execution_context lock_path =
  let opened_fd = Atomic.make None in
  let result =
    try
      Ok
        (run_blocking_lock_op (fun () ->
           let fd =
             Unix.openfile lock_path
               [ Unix.O_CLOEXEC; Unix.O_CREAT; Unix.O_WRONLY ] 0o644
           in
           Atomic.set opened_fd (Some fd);
           fd))
    with
    | Unix.Unix_error (error, operation, argument) ->
      Error (unix_failure (error, operation, argument))
    | exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      Option.iter
        (close_fd_after_exception ~lock_path execution_context)
        (Atomic.exchange opened_fd None);
      Printexc.raise_with_backtrace exn backtrace
  in
  Atomic.set opened_fd None;
  result

let acquire_durable_flock ~execution_context lock_path =
  match open_durable_lock_file ~execution_context lock_path with
  | Error cause ->
    Error (durable_lock_error ~lock_path ~phase:Open_lock_file cause)
  | Ok fd ->
    let started_at = Time_compat.now () in
    let process_lock_held = Atomic.make false in
    let rec acquire_eio retries =
      match
        try
          run_blocking_lock_op (fun () -> Unix.lockf fd Unix.F_TLOCK 0);
          Atomic.set process_lock_held true;
          Ok true
        with
        | Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) -> Ok false
        | Unix.Unix_error (error, operation, argument) ->
          Error (unix_failure (error, operation, argument))
      with
      | Ok true ->
        Eio.Fiber.check ();
        observe_lock_attempt ~caller:"File_lock_eio.durable" ~retries
          ~started_at ~outcome:"acquired";
        Ok ()
      | Ok false ->
        (* POSIX record locks expose no readiness source to Eio. An unbounded
           F_TLOCK/yield loop is the portable cancellable admission: no
           timeout, attempt cap, sleep, or backoff policy is invented. *)
        Eio.Fiber.yield ();
        acquire_eio (retries + 1)
      | Error _ as error -> error
    in
    let acquire () =
      match execution_context with
      | Eio_guard.Eio_fiber ->
        Eio.Fiber.check ();
        acquire_eio 0
      | Eio_guard.Non_eio ->
        (try
           Unix.lockf fd Unix.F_LOCK 0;
           Atomic.set process_lock_held true;
           Ok ()
         with
         | Unix.Unix_error (error, operation, argument) ->
           Error (unix_failure (error, operation, argument)))
    in
    let acquired =
      match acquire () with
      | result -> result
      | exception exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        if Atomic.get process_lock_held
        then release_fd_after_exception ~lock_path execution_context fd
        else close_fd_after_exception ~lock_path execution_context fd;
        Printexc.raise_with_backtrace exn backtrace
    in
    (match acquired with
     | Ok () -> Ok fd
     | Error cause ->
       let cleanup_failure =
         match
           protect_cleanup execution_context (fun () -> close_fd_result fd)
         with
         | Ok () -> None
         | Error failure -> Some failure
       in
       Error
         (durable_lock_error
            ?cleanup_failure
            ~lock_path
            ~phase:Acquire_process_lock
            cause))

let with_durable_lock ~lock_path f =
  with_mutex lock_path (fun () ->
    let execution_context = Eio_guard.execution_context () in
    match acquire_durable_flock ~execution_context lock_path with
    | Error _ as error -> error
    | Ok fd ->
      let admitted () =
        let body =
          match f () with
          | value -> `Returned value
          | exception exn -> `Raised (exn, Printexc.get_raw_backtrace ())
        in
        let release = release_durable_fd_result fd in
        match body, release with
        | `Returned value, Ok () -> Ok value
        | `Returned _, Error (cause, cleanup_failure) ->
          Error
            (durable_lock_error
               ?cleanup_failure
               ~lock_path
               ~phase:Release_process_lock
               cause)
        | `Raised (exn, backtrace), Ok () ->
          Printexc.raise_with_backtrace exn backtrace
        | `Raised (exn, backtrace), Error (release_failure, cleanup_failure) ->
          Log.Misc.error
            "file_lock_eio: release failed during body exception lock_path=%s operation=%s argument=%s error=%s%s"
            lock_path release_failure.operation release_failure.argument
            (Unix.error_message release_failure.error)
            (match cleanup_failure with
             | None -> ""
             | Some cleanup ->
               Printf.sprintf
                 " cleanup_operation=%s cleanup_argument=%s cleanup_error=%s"
                 cleanup.operation cleanup.argument
                 (Unix.error_message cleanup.error));
          Printexc.raise_with_backtrace exn backtrace
      in
      protect_cleanup execution_context admitted)

(** Number of tracked lock paths (for diagnostics). *)
let lock_count () = SMap.cardinal (Atomic.get table).entries
