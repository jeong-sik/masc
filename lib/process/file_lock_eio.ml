(** File_lock_eio — Cooperative per-key locking via Cross_context_mutex + flock.

    Two-layer locking for local filesystem paths:
    1. {!Cross_context_mutex} — serializes Eio fibers, system threads and
       Domains without blocking the Eio scheduler
    2. Unix.lockf F_TLOCK (non-blocking) — preserves cross-process safety

    Layer 1 resolves most contention inside the process. The flock is
    acquired non-blocking after it; if another process holds it, we yield
    and retry.

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
  let new_val, result = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then result
  else begin
    observe_cas_retry ();
    atomic_update_with_result atomic f
  end

type lock_entry = {
  lock : Cross_context_mutex.t;
  active : int;   (** Number of fibers/threads currently holding or waiting on this mutex *)
}

type table_state = {
  version : int;
  entries : lock_entry SMap.t;
}

let table : table_state Atomic.t = Atomic.make { version = 0; entries = SMap.empty }

(* Bump the published version whenever the map shape or active count changes so
   a structural A -> B -> A cycle cannot satisfy a stale CAS with the old snapshot. *)
let publish_entries state entries =
  if entries == state.entries then state
  else { version = state.version + 1; entries }

(* Canonicalize the nearest existing ancestor directory and reattach any
   not-yet-created segments plus the leaf basename. Never call [realpath]
   on the target file itself so nonexistent paths do not fail and symlinked
   parent directories share one entry; leaf symlinks intentionally lock their
   own logical path (<leaf>.lock) rather than dereferencing the link target. *)
let canonical_table_key path =
  let rec strip_trailing_slashes s =
    let len = String.length s in
    if len > 1 && Char.equal s.[len - 1] '/'
    then strip_trailing_slashes (String.sub s 0 (len - 1))
    else s
  in
  let trimmed = strip_trailing_slashes path in
  if String.equal trimmed "" || String.equal trimmed "/"
  then trimmed
  else (
    let rec resolve_dir dir suffix =
      match Unix.realpath dir with
      | real_dir -> List.fold_left Filename.concat real_dir suffix
      | exception Unix.Unix_error _ ->
        let parent = Filename.dirname dir in
        if String.equal parent dir
        then List.fold_left Filename.concat dir suffix
        else resolve_dir parent (Filename.basename dir :: suffix)
    in
    if String.equal trimmed "." || String.equal trimmed ".."
    then resolve_dir trimmed []
    else
      Filename.concat
        (resolve_dir (Filename.dirname trimmed) [])
        (Filename.basename trimmed))

(** Reserve the lock entry for an already-canonicalized [path] via a pure CAS
    increment of [active]. *)
let get_entry_canonical path =
  let lock =
    atomic_update_with_result table (fun state ->
      match SMap.find_opt path state.entries with
      | Some entry ->
        let updated = { entry with active = entry.active + 1 } in
        let entries = SMap.add path updated state.entries in
        (publish_entries state entries, updated.lock)
      | None ->
        let entry =
          { lock = Cross_context_mutex.create ()
          ; active = 1
          }
        in
        let entries = SMap.add path entry state.entries in
        (publish_entries state entries, entry.lock))
  in
  (path, lock)

(** Reserve the lock entry for [raw_path] via a pure CAS increment of [active]. *)
let get_entry raw_path =
  get_entry_canonical (canonical_table_key raw_path)

(** Release a reservation on [path], evicting the entry when [active] reaches 0. *)
let release_entry path =
  atomic_update table (fun state ->
    match SMap.find_opt path state.entries with
    | None -> state
    | Some entry ->
      let entries =
        if entry.active <= 1
        then SMap.remove path state.entries
        else SMap.add path { entry with active = entry.active - 1 } state.entries
      in
      publish_entries state entries)

let run_blocking_lock_op f = Eio_guard.run_in_systhread ~label:"file-lock-op" f

(* Keep contention pacing shared with the existing lock retry helpers. *)
let retry_sleep_sec = 0.01
let wait_after_contention () = Eio_unix.sleep retry_sleep_sec

(** Acquire a non-blocking Unix file lock (F_TLOCK) with retry.
    This is the blocking variant for callers that already run in a systhread
    (for example backend and Hebbian file I/O paths). On success, returns the
    open file descriptor with the lock held. On timeout, closes the fd and
    raises [Flock_timeout]. *)
let acquire_flock_retry ?clock:(_clock = None) ~lock_path ~mode ~perm
    ?(max_attempts = 200) ?(sleep_sec = retry_sleep_sec) ~caller () =
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
  with exn ->  (* re-raises below *)
    (try Unix.close fd with Unix.Unix_error _ -> ());  (* re-raises below *)
    raise exn

let rec openfile_no_eintr path mode perm =
  try Unix.openfile path mode perm with
  | Unix.Unix_error (Unix.EINTR, _, _) -> openfile_no_eintr path mode perm

let rec try_tlock_no_eintr fd =
  try
    Unix.lockf fd Unix.F_TLOCK 0;
    true
  with
  | Unix.Unix_error (Unix.EINTR, _, _) -> try_tlock_no_eintr fd
  | Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) -> false

(** Fiber-friendly wrapper around [acquire_flock_retry].
    Runs non-blocking [F_TLOCK] directly without dispatching to [run_in_systhread]
    while holding an in-process mutex (avoiding systhread-pool starvation).
    Retry sleep yields to the Eio scheduler when a clock is available. *)
let acquire_flock_retry_cooperative ?clock ~lock_path ~mode ~perm
    ?(max_attempts = 200) ?(sleep_sec = retry_sleep_sec) ~caller () =
  let fd = openfile_no_eintr lock_path mode perm in
  let started_at = Time_compat.now () in
  let rec acquire attempts =
    if attempts <= 0 then begin
      observe_lock_attempt ~caller ~retries:max_attempts ~started_at
        ~outcome:"timeout";
      raise (Flock_timeout { caller; path = lock_path; attempts = max_attempts })
    end
    else
      let success = try_tlock_no_eintr fd in
      if success then begin
        observe_lock_attempt ~caller
          ~retries:(max_attempts - attempts) ~started_at ~outcome:"acquired";
        fd
      end
      else begin
        (match clock with
         | Some c -> Eio.Time.sleep c sleep_sec
         | None ->
           (match Eio_guard.execution_context () with
            | Eio_guard.Eio_fiber ->
              (try Eio_unix.sleep sleep_sec with
               | Effect.Unhandled _ -> Eio.Fiber.yield ())
            | Eio_guard.Non_eio -> Unix.sleepf sleep_sec));
        acquire (attempts - 1)
      end
  in
  try acquire max_attempts
  with exn ->  (* re-raises below *)
    let bt = Printexc.get_raw_backtrace () in
    (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
    (try Unix.close fd with Unix.Unix_error _ -> ());
    Printexc.raise_with_backtrace exn bt

let acquire_flock_fd ?clock lock_path =
  acquire_flock_retry_cooperative ?clock ~lock_path
    ~mode:[ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_CLOEXEC ] ~perm:0o644
    ~caller:"File_lock_eio" ()

let release_flock_fd fd =
  (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
  Unix.close fd

let with_mutex_canonical canonical f =
  let key, lock = get_entry_canonical canonical in
  Common.protect ~module_name:"file_lock_eio" ~finally_label:"release_entry"
    ~finally:(fun () -> release_entry key)
    (fun () -> Cross_context_mutex.with_lock lock f)

(** Run [f] while holding only the cross-context per-path mutex.
    Use this for in-memory backends that need single-process fiber
    serialization but do not have a real filesystem artifact to flock. *)
let with_mutex path f =
  with_mutex_canonical (canonical_table_key path) f

let try_with_mutex path f =
  let key, lock = get_entry path in
  Common.protect ~module_name:"file_lock_eio" ~finally_label:"release_entry"
    ~finally:(fun () -> release_entry key)
    (fun () -> Cross_context_mutex.try_with_lock lock (fun () ->
      match Eio_guard.execution_context () with
      | Eio_guard.Eio_fiber -> Eio.Cancel.protect f
      | Eio_guard.Non_eio -> f ()))

let lock_suffix = Fs_compat.lock_suffix
let lock_file_path path = path ^ lock_suffix

(** Run [f] while holding both the per-path {!Cross_context_mutex} and an
    OS-level flock on [path].lock. The flock uses non-blocking F_TLOCK
    retries; sleep/yield stays scheduler-friendly whether or not a clock
    is provided. Max 200 attempts (~2s with sleeps). *)
let with_lock ?clock path f =
  let canonical = canonical_table_key path in
  let run_with_flock () =
    let lock_path = lock_file_path canonical in
    let dir = Filename.dirname lock_path in
    if not (Sys.file_exists dir) then
      (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let fd = acquire_flock_fd ?clock lock_path in
    Fun.protect
      ~finally:(fun () -> release_flock_fd fd)
      f
  in
  with_mutex_canonical canonical (fun () -> run_with_flock ())

let unix_failure (error, operation, argument) =
  { error; operation; argument }

let close_fd_result fd =
  try
    Unix.close fd;
    Ok ()
  with
  | Unix.Unix_error (error, operation, argument) ->
    Error (unix_failure (error, operation, argument))

let release_durable_fd_result fd =
  let unlock =
    try
      Unix.lockf fd Unix.F_ULOCK 0;
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
        (let fd =
           openfile_no_eintr lock_path
             [ Unix.O_CLOEXEC; Unix.O_CREAT; Unix.O_WRONLY ] 0o644
         in
         Atomic.set opened_fd (Some fd);
         fd)
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

(* One non-blocking attempt at the process lock: [Ok false] when another
   process holds it. *)
let rec try_process_lock fd ~process_lock_held =
  try
    Unix.lockf fd Unix.F_TLOCK 0;
    Atomic.set process_lock_held true;
    Ok true
  with
  | Unix.Unix_error (Unix.EINTR, _, _) -> try_process_lock fd ~process_lock_held
  | Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) -> Ok false
  | Unix.Unix_error (error, operation, argument) ->
    Error (unix_failure (error, operation, argument))

let verify_locked_fd_matches_path ~lock_path fd =
  try
    let fd_stat = Unix.fstat fd in
    let path_stat = Unix.lstat lock_path in
    if path_stat.Unix.st_kind = Unix.S_LNK
    then Error (unix_failure (Unix.ELOOP, "lstat", lock_path))
    else if path_stat.Unix.st_kind <> Unix.S_REG
            || fd_stat.Unix.st_kind <> Unix.S_REG
    then Error (unix_failure (Unix.EINVAL, "lstat", lock_path))
    else if fd_stat.Unix.st_dev = path_stat.Unix.st_dev
            && fd_stat.Unix.st_ino = path_stat.Unix.st_ino
            && fd_stat.Unix.st_nlink > 0
    then Ok `Current
    else Ok `Stale_inode
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok `Stale_inode
  | Unix.Unix_error (error, operation, argument) ->
    Error (unix_failure (error, operation, argument))
;;

let acquire_durable_flock ~execution_context lock_path =
  let rec acquire_current_inode () =
    match open_durable_lock_file ~execution_context lock_path with
    | Error cause ->
      Error (durable_lock_error ~lock_path ~phase:Open_lock_file cause)
    | Ok fd ->
      let started_at = Time_compat.now () in
      let process_lock_held = Atomic.make false in
      let rec acquire_eio retries =
        match try_process_lock fd ~process_lock_held with
        | Ok true ->
          Eio.Fiber.check ();
          observe_lock_attempt ~caller:"File_lock_eio.durable" ~retries
            ~started_at ~outcome:"acquired";
          Ok ()
        | Ok false ->
          (* POSIX record locks expose no readiness source to Eio. Pace unbounded
             cancellable F_TLOCK retries with [retry_sleep_sec] on Eio Unix (falling
             back to [Fiber.yield] on non-Unix mock schedulers) so cross-process
             contention never spins a domain at 100% CPU while imposing no attempt
             cap or wall-clock timeout. *)
          (try Eio_unix.sleep retry_sleep_sec with
           | Effect.Unhandled _ -> Eio.Fiber.yield ());
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
       | Ok () ->
         (* Verify the locked descriptor still matches the current directory
            entry at [lock_path]. If another process unlinked the stale lock
            file after our open and before our lock, release this unlinked
            inode and re-open so mutual exclusion converges on one inode. *)
         (match verify_locked_fd_matches_path ~lock_path fd with
          | Ok `Current -> Ok fd
          | Ok `Stale_inode ->
            release_fd_after_exception ~lock_path execution_context fd;
            (match execution_context with
             | Eio_guard.Eio_fiber -> Eio.Fiber.check ()
             | Eio_guard.Non_eio -> ());
            acquire_current_inode ()
          | Error cause ->
            let cleanup_failure =
              match
                protect_cleanup execution_context (fun () -> release_durable_fd_result fd)
              with
              | Ok () -> None
              | Error (failure, _) -> Some failure
            in
            Error
              (durable_lock_error
                 ?cleanup_failure
                 ~lock_path
                 ~phase:Acquire_process_lock
                 cause))
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
  in
  acquire_current_inode ()

type 'a durable_lock_observation =
  | Lock_not_acquired of durable_lock_error
  | Body_completed of
      { value : 'a
      ; release_error : durable_lock_error option
      }

let release_durable_lock_result ~lock_path fd =
  match release_durable_fd_result fd with
  | Ok () -> Ok ()
  | Error (cause, cleanup_failure) ->
    Error
      (durable_lock_error
         ?cleanup_failure
         ~lock_path
         ~phase:Release_process_lock
         cause)
;;

(* Run [f] holding the process lock on [fd], then release it. *)
let run_admitted ~release_fd ~lock_path execution_context fd f =
  let admitted () =
    let body =
      match f () with
      | value -> `Returned value
      | exception exn -> `Raised (exn, Printexc.get_raw_backtrace ()) (* cancel-guard-ok: PROVISIONAL, delete with #37372. The exception is stashed as `Raised and thrown again with its backtrace on both arms that consume it (:501 and :516); the release failure is logged there and never replaces it. *)
    in
    let release = release_fd fd in
    match body, release with
    | `Returned value, Ok () ->
      Body_completed { value; release_error = None }
    | `Returned value, Error error ->
      Body_completed
        { value
        ; release_error = Some error
        }
    | `Raised (exn, backtrace), Ok () ->
      Printexc.raise_with_backtrace exn backtrace
    | `Raised (exn, backtrace), Error error ->
      let release_failure = error.cause in
      Log.Misc.error
        "file_lock_eio: release failed during body exception lock_path=%s operation=%s argument=%s error=%s%s"
        lock_path release_failure.operation release_failure.argument
        (Unix.error_message release_failure.error)
        (match error.cleanup_failure with
         | None -> ""
         | Some cleanup ->
           Printf.sprintf
             " cleanup_operation=%s cleanup_argument=%s cleanup_error=%s"
             cleanup.operation cleanup.argument
             (Unix.error_message cleanup.error));
      Printexc.raise_with_backtrace exn backtrace
  in
  protect_cleanup execution_context admitted

let with_durable_lock_observed_with ~release_fd ~lock_path f =
  with_mutex lock_path (fun () ->
    let execution_context = Eio_guard.execution_context () in
    match acquire_durable_flock ~execution_context lock_path with
    | Error error -> Lock_not_acquired error
    | Ok fd -> run_admitted ~release_fd ~lock_path execution_context fd f)

type 'a durable_lock_attempt =
  | Lock_held_elsewhere
  | Lock_attempted of 'a durable_lock_observation

let try_with_durable_lock_observed ~lock_path f =
  let key, lock = get_entry lock_path in
  Common.protect ~module_name:"file_lock_eio" ~finally_label:"release_entry"
    ~finally:(fun () -> release_entry key)
    (fun () ->
      match Cross_context_mutex.try_with_lock lock (fun () ->
        let execution_context = Eio_guard.execution_context () in
        let rec try_current_inode attempts_left =
          match open_durable_lock_file ~execution_context lock_path with
          | Error cause ->
            Lock_attempted (Lock_not_acquired
              (durable_lock_error ~lock_path ~phase:Open_lock_file cause))
          | Ok fd ->
            let process_lock_held = Atomic.make false in
            let attempt =
              match try_process_lock fd ~process_lock_held with
              | attempt -> attempt
              | exception exn ->
                let backtrace = Printexc.get_raw_backtrace () in
                if Atomic.get process_lock_held
                then release_fd_after_exception ~lock_path execution_context fd
                else close_fd_after_exception ~lock_path execution_context fd;
                Printexc.raise_with_backtrace exn backtrace
            in
            match attempt with
            | Ok true ->
              (match verify_locked_fd_matches_path ~lock_path fd with
               | Ok `Current ->
                 Lock_attempted (run_admitted
                   ~release_fd:(release_durable_lock_result ~lock_path) ~lock_path execution_context fd f)
               | Ok `Stale_inode ->
                 release_fd_after_exception ~lock_path execution_context fd;
                 if attempts_left <= 0
                 then Lock_held_elsewhere
                 else try_current_inode (attempts_left - 1)
               | Error cause ->
                 let cleanup_failure =
                   match protect_cleanup execution_context (fun () -> release_durable_fd_result fd) with
                   | Ok () -> None
                   | Error (failure, _) -> Some failure
                 in
                 Lock_attempted (Lock_not_acquired
                   (durable_lock_error ?cleanup_failure ~lock_path ~phase:Acquire_process_lock cause)))
            | Ok false ->
              close_fd_after_exception ~lock_path execution_context fd;
              Lock_held_elsewhere
            | Error cause ->
              let cleanup_failure =
                match protect_cleanup execution_context (fun () -> close_fd_result fd) with
                | Ok () -> None
                | Error failure -> Some failure
              in
              Lock_attempted (Lock_not_acquired
                (durable_lock_error ?cleanup_failure ~lock_path ~phase:Acquire_process_lock cause))
        in
        try_current_inode 8)
      with
      | Some attempt -> attempt
      | None -> Lock_held_elsewhere)

let with_durable_lock_observed ~lock_path f =
  with_durable_lock_observed_with
    ~release_fd:(release_durable_lock_result ~lock_path)
    ~lock_path
    f
;;

let with_durable_lock ~lock_path f =
  match with_durable_lock_observed ~lock_path f with
  | Lock_not_acquired error -> Error error
  | Body_completed { value; release_error = None } -> Ok value
  | Body_completed { release_error = Some error; _ } -> Error error
;;

type stale_lock_cleanup =
  | Stale_lock_removed
  | Stale_lock_kept_target_present
  | Stale_lock_kept_held
  | Stale_lock_already_absent
  | Stale_lock_cleanup_failed of string

external try_lock_fd_exclusive_all_raw : Unix.file_descr -> bool
  = "masc_try_lock_fd_exclusive_all"
external unlock_fd_all_raw : Unix.file_descr -> unit
  = "masc_unlock_fd_all"

let unlink_if_unheld ~lock_path ~target_absent =
  if not (target_absent ())
  then Stale_lock_kept_target_present
  else (
    let canonical_lock = canonical_table_key lock_path in
    let with_optional_target_mutex f =
      if Filename.check_suffix canonical_lock lock_suffix
      then (
        let target_key = Filename.chop_suffix canonical_lock lock_suffix in
        if String.equal target_key canonical_lock
        then Some (f ())
        else try_with_mutex target_key f)
      else Some (f ())
    in
    let attempt =
      try_with_mutex canonical_lock (fun () ->
        match
          with_optional_target_mutex (fun () ->
            if not (target_absent ())
            then Stale_lock_kept_target_present
            else (
              match Unix.lstat lock_path with
              | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Stale_lock_already_absent
              | exception Unix.Unix_error (error, operation, argument) ->
                Stale_lock_cleanup_failed
                  (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))
              | lstat_before when lstat_before.Unix.st_kind <> Unix.S_REG ->
                Stale_lock_cleanup_failed "lock path is not a regular file"
              | lstat_before ->
                (match
                   openfile_no_eintr lock_path [ Unix.O_WRONLY; Unix.O_CLOEXEC; Unix.O_NONBLOCK ] 0
                 with
                 | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Stale_lock_already_absent
                 | exception Unix.Unix_error (error, operation, argument) ->
                   Stale_lock_cleanup_failed
                     (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))
                 | fd ->
                   let os_lock_held = ref false in
                   Fun.protect
                     ~finally:(fun () ->
                       if !os_lock_held
                       then (try unlock_fd_all_raw fd with Unix.Unix_error _ -> ());
                       try Unix.close fd with Unix.Unix_error _ -> ())
                     (fun () ->
                        match Unix.fstat fd with
                        | exception Unix.Unix_error (error, operation, argument) ->
                          Stale_lock_cleanup_failed
                            (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))
                        | fstat_open
                          when fstat_open.Unix.st_kind <> Unix.S_REG
                               || fstat_open.Unix.st_dev <> lstat_before.Unix.st_dev
                               || fstat_open.Unix.st_ino <> lstat_before.Unix.st_ino ->
                          Stale_lock_cleanup_failed "lock file identity changed before lock check"
                        | _ ->
                          (* Acquire an OS lock that excludes BOTH BSD [flock(2)] (used by
                             liveness/stage locks) AND POSIX [fcntl]/[lockf(3)] holders
                             across macOS/BSD and Linux without self-conflicting on BSD
                             unified vnode lock tables. *)
                          (match try_lock_fd_exclusive_all_raw fd with
                           | exception Unix.Unix_error (error, operation, argument) ->
                             Stale_lock_cleanup_failed
                               (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))
                           | false -> Stale_lock_kept_held
                           | true ->
                             os_lock_held := true;
                             if not (target_absent ())
                             then Stale_lock_kept_target_present
                             else (
                               match Unix.lstat lock_path with
                               | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
                                 Stale_lock_already_absent
                               | exception Unix.Unix_error (error, operation, argument) ->
                                 Stale_lock_cleanup_failed
                                   (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))
                               | lstat_after
                                 when lstat_after.Unix.st_kind <> Unix.S_REG
                                      || lstat_after.Unix.st_dev <> lstat_before.Unix.st_dev
                                      || lstat_after.Unix.st_ino <> lstat_before.Unix.st_ino ->
                                 Stale_lock_cleanup_failed "lock file identity changed before unlink"
                               | _ ->
                                 (match Unix.unlink lock_path with
                                  | () -> Stale_lock_removed
                                  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
                                    Stale_lock_already_absent
                                  | exception Unix.Unix_error (error, operation, argument) ->
                                    Stale_lock_cleanup_failed
                                      (Printf.sprintf
                                         "%s(%s): %s"
                                         operation
                                         argument
                                         (Unix.error_message error)))))))))
        with
        | Some outcome -> outcome
        | None -> Stale_lock_kept_held)
    in
    match attempt with
    | Some outcome -> outcome
    | None -> Stale_lock_kept_held)
;;

module For_testing = struct
  let holders_and_waiters ~lock_path =
    let key = canonical_table_key lock_path in
    match SMap.find_opt key (Atomic.get table).entries with
    | None -> 0
    | Some entry -> entry.active

  let with_durable_lock_observed_with_release_failure
      ~release_failure
      ~lock_path
      f =
    let release_fd fd =
      match release_durable_lock_result ~lock_path fd with
      | Error error -> Error error
      | Ok () -> Error release_failure
    in
    with_durable_lock_observed_with ~release_fd ~lock_path f
  ;;
end

(** Number of tracked lock paths (for diagnostics). *)
let lock_count () = SMap.cardinal (Atomic.get table).entries


external try_open_liveness_raw : string -> Unix.file_descr option
  = "masc_try_open_liveness_lock"
external try_open_shared_liveness_raw : string -> Unix.file_descr option
  = "masc_try_open_shared_liveness_lock"

let try_with_liveness_lock_observed_with ~open_lock ~lock_path f =
  let execution_context = Eio_guard.execution_context () in
  (* Protect descriptor acquisition through publication of its ownership to
     this scope. The caller's body stays cancellable. *)
  let acquire () =
    try
      let fd = run_blocking_lock_op (fun () -> open_lock lock_path) in
      Ok fd
    with Unix.Unix_error (error, operation, argument) ->
      Error (durable_lock_error ~lock_path ~phase:Open_lock_file
        (unix_failure (error, operation, argument))) in
  let acquired = protect_cleanup execution_context acquire in
  match acquired with
  | Error error -> Lock_attempted (Lock_not_acquired error)
  | Ok None -> Lock_held_elsewhere
  | Ok (Some fd) ->
    let body = match f () with
      | value -> `Returned value
      | exception exn -> `Raised (exn, Printexc.get_raw_backtrace ()) in
    let release = protect_cleanup execution_context (fun () ->
      (* Closing this open-file description releases only its own flock. *)
      match close_fd_result fd with
      | Ok () -> None
      | Error cause -> Some (durable_lock_error ~lock_path
          ~phase:Release_process_lock cause)) in
    match body, release with
    | `Returned value, release_error ->
      Lock_attempted (Body_completed {value; release_error})
    | `Raised (exn, backtrace), None -> Printexc.raise_with_backtrace exn backtrace
    | `Raised (exn, backtrace), Some error ->
      Log.Misc.error "liveness lock release failed during owner exception: %s"
        (durable_lock_error_to_string error);
      Printexc.raise_with_backtrace exn backtrace

let try_with_liveness_lock_observed ~lock_path f =
  try_with_liveness_lock_observed_with ~open_lock:try_open_liveness_raw ~lock_path f

let try_with_shared_liveness_lock_observed ~lock_path f =
  try_with_liveness_lock_observed_with ~open_lock:try_open_shared_liveness_raw ~lock_path f

let acquire_liveness_lock ~sw ~lock_path =
  Eio.Cancel.protect (fun () ->
    Eio.Switch.check sw;
    let acquired =
      try Ok (run_blocking_lock_op (fun () -> try_open_liveness_raw lock_path)) with
      | Unix.Unix_error (error, operation, argument) ->
        Error (durable_lock_error ~lock_path ~phase:Open_lock_file
          (unix_failure (error, operation, argument))) in
    match acquired with
    | Error error -> Error error
    | Ok None -> Error (durable_lock_error ~lock_path ~phase:Acquire_process_lock
        (unix_failure (Unix.EAGAIN, "flock", lock_path)))
    | Ok (Some fd) ->
      let descriptor = Atomic.make (Some fd) in
      let release () =
        match Atomic.exchange descriptor None with
        | None -> ()
        | Some fd ->
          (match close_fd_result fd with
           | Ok () -> ()
           | Error cause -> Log.Misc.error "liveness lock release failed: %s"
               (durable_lock_error_to_string
                 (durable_lock_error ~lock_path ~phase:Release_process_lock cause))) in
      match Eio.Switch.on_release sw release with
      | () -> Ok ()
      | exception exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        release ();
        Printexc.raise_with_backtrace exn backtrace)
