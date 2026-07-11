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

exception Lock_file_cleanup_failed of
  { primary : exn
  ; primary_backtrace : Printexc.raw_backtrace
  ; close_error : exn
  }

exception Flock_release_failed of
  { unlock_error : exn option
  ; close_error : exn option
  }

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
  mu : Eio.Mutex.t;
  pre_eio_mu : Stdlib.Mutex.t;
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

(** Get or create a process-local lock entry for the given file identity.
    Increments [active] to prevent prune_stale_entries from removing
    in-use entries (see TLA+ FileLockStarvation spec). *)
let get_entry path =
  prune_stale_entries ();
  let entry =
    atomic_update_with_result table (fun state ->
      match SMap.find_opt path state.entries with
      | Some entry ->
        Atomic.set entry.last_used (Time_compat.now ());
        (state, entry)
      | None ->
        let entry =
          { mu = Eio.Mutex.create ()
          ; pre_eio_mu = Stdlib.Mutex.create ()
          ; last_used = Atomic.make (Time_compat.now ())
          ; active = Atomic.make 0
          }
        in
        let entries = SMap.add path entry state.entries in
        (publish_entries state entries, entry))
  in
  Atomic.incr entry.active;
  entry

let release_entry entry =
  ignore (Atomic.fetch_and_add entry.active (-1))

let protect_from_cancel f =
  if Eio_guard.is_ready () then Eio.Cancel.protect f else f ()
;;

let require_eio_context () =
  if Eio_guard.is_ready ()
  then
    try Eio.Cancel.protect (fun () -> ()) with
    | Effect.Unhandled _ as exn ->
      raise
        (Failure
           (Printf.sprintf
              "File_lock_eio requires an Eio fiber after runtime startup: %s"
              (Printexc.to_string exn)))
;;

let with_eio_entry entry f =
  (* A pre-Eio caller holds [pre_eio_mu] for its full critical section.
     Taking and immediately releasing it here is a transition barrier: once
     [Eio_guard.enable] is visible, no later pre-Eio caller can enter without
     rechecking the guard while holding the same mutex. Normal Eio operation
     sees an uncontended constant-time gate and waits only on [entry.mu]. *)
  require_eio_context ();
  Stdlib.Mutex.protect entry.pre_eio_mu (fun () -> ());
  Eio.Mutex.use_ro entry.mu f
;;

let rec with_cooperative_entry entry f =
  if Eio_guard.is_ready ()
  then with_eio_entry entry f
  else
    match
      Stdlib.Mutex.protect entry.pre_eio_mu (fun () ->
        if Eio_guard.is_ready () then None else Some (f ()))
    with
    | Some value -> value
    | None -> with_cooperative_entry entry f
;;

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
    let primary_backtrace = Printexc.get_raw_backtrace () in
    (match Unix.close fd with
     | () -> Printexc.raise_with_backtrace exn primary_backtrace
     | exception close_error ->
       raise
         (Lock_file_cleanup_failed
            { primary = exn; primary_backtrace; close_error }))

(** Fiber-friendly wrapper around [acquire_flock_retry].
    Opening/closing the descriptor uses a systhread, and the F_TLOCK attempt
    also runs in a systhread to avoid blocking the Eio domain on filesystems
    that do not honor the non-blocking contract reliably. Retry sleep yields
    to the Eio scheduler when a clock is available and otherwise sleeps in a
    systhread so the calling fiber does not block the domain. *)
let acquire_flock_on_fd_cooperative
      ?clock
      ~fd
      ~lock_path
      ?(max_attempts = 200)
      ?(sleep_sec = 0.01)
      ~caller
      ()
  =
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
  acquire max_attempts
;;

let acquire_flock_retry_cooperative ?clock ~lock_path ~mode ~perm
    ?(max_attempts = 200) ?(sleep_sec = 0.01) ~caller () =
  require_eio_context ();
  let fd =
    protect_from_cancel (fun () ->
      run_blocking_lock_op (fun () -> Unix.openfile lock_path mode perm))
  in
  try
    acquire_flock_on_fd_cooperative
      ?clock
      ~fd
      ~lock_path
      ~max_attempts
      ~sleep_sec
      ~caller
      ()
  with exn ->
    let primary_backtrace = Printexc.get_raw_backtrace () in
    protect_from_cancel (fun () ->
      match run_blocking_lock_op (fun () -> Unix.close fd) with
      | () -> Printexc.raise_with_backtrace exn primary_backtrace
      | exception close_error ->
        raise
          (Lock_file_cleanup_failed
             { primary = exn; primary_backtrace; close_error }))

let acquire_flock_fd ?clock lock_path =
  acquire_flock_retry_cooperative ?clock ~lock_path
    ~mode:[ Unix.O_CREAT; Unix.O_WRONLY ] ~perm:0o644
    ~caller:"File_lock_eio" ()

let release_flock_fd fd =
  run_blocking_lock_op (fun () ->
      let unlock_error =
        match Unix.lockf fd Unix.F_ULOCK 0 with
        | () -> None
        | exception exn -> Some exn
      in
      let close_error =
        match Unix.close fd with
        | () -> None
        | exception exn -> Some exn
      in
      match unlock_error, close_error with
      | None, None -> ()
      | _ -> raise (Flock_release_failed { unlock_error; close_error }))

(** Run [f] while holding only the cooperative per-path mutex.
    Use this for in-memory backends that need single-process fiber
    serialization but do not have a real filesystem artifact to flock. *)
let with_mutex path f =
  let entry = get_entry path in
  Common.protect ~module_name:"file_lock_eio" ~finally_label:"release_entry"
    ~finally:(fun () -> release_entry entry)
    (fun () -> with_cooperative_entry entry f)

(** Run [f] while holding both the cooperative Eio.Mutex and an
    OS-level flock on [path].lock. The flock uses non-blocking F_TLOCK
    retries; sleep/yield stays scheduler-friendly whether or not a clock
    is provided. Max 200 attempts (~2s with sleeps). *)
let with_lock ?clock path f =
  let run_with_flock () =
    let lock_path = path ^ ".lock" in
    let dir = Filename.dirname lock_path in
    run_blocking_lock_op (fun () ->
      if not (Sys.file_exists dir) then
        (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()));
    let fd = acquire_flock_fd ?clock lock_path in
    Common.protect ~module_name:"file_lock_eio" ~finally_label:"finalizer"
      ~finally:(fun () ->
        protect_from_cancel (fun () -> release_flock_fd fd))
      f
  in
  with_mutex path (fun () -> run_with_flock ())

let file_registry_key ~device ~inode =
  Printf.sprintf "descriptor-inode:%Lx:%Lx" device inode
;;

type close_state =
  | Open
  | Close_attempted
  | Closed

let with_anchored_file_lock
      ?clock
      ~path
      ~directory
      ~name
      ~perm
      f
  =
  require_eio_context ();
  let module Dir = Fs_compat.Anchored_dir in
  let file =
    protect_from_cancel (fun () ->
      Dir.open_lock_file directory ~name ~perm)
  in
  let close_state = ref Open in
  let close_once () =
    match !close_state with
    | Closed | Close_attempted -> ()
    | Open ->
      close_state := Close_attempted;
      protect_from_cancel (fun () ->
        Dir.close_lock_file file;
        close_state := Closed)
  in
  let finish outcome =
    let close_outcome =
      try
        close_once ();
        Ok ()
      with
      | exn -> Error exn
    in
    match outcome, close_outcome with
    | Ok value, Ok () -> value
    | Error (exn, backtrace), Ok () -> Printexc.raise_with_backtrace exn backtrace
    | Ok _, Error close_error -> raise close_error
    | Error (primary, primary_backtrace), Error close_error ->
      raise
        (Lock_file_cleanup_failed
           { primary; primary_backtrace; close_error })
  in
  let run_scoped () =
    let device, inode = Dir.lock_file_identity file in
    let entry = get_entry (file_registry_key ~device ~inode) in
    let run () =
      let outcome =
        try
          ignore
            (acquire_flock_on_fd_cooperative
               ?clock
               ~fd:(Dir.lock_file_descriptor file)
               ~lock_path:path
               ~caller:"File_lock_eio"
               ()
             : Unix.file_descr);
          Ok (f ())
        with
        | exn -> Error (exn, Printexc.get_raw_backtrace ())
      in
      finish outcome
    in
    Common.protect ~module_name:"file_lock_eio" ~finally_label:"release_entry"
      ~finally:(fun () -> release_entry entry)
      (fun () -> with_cooperative_entry entry run)
  in
  try
    run_scoped ()
  with
  | exn ->
    if !close_state <> Open
    then raise exn
    else finish (Error (exn, Printexc.get_raw_backtrace ()))

(** Number of tracked lock paths (for diagnostics). *)
let lock_count () = SMap.cardinal (Atomic.get table).entries
