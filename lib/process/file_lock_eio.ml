(** File_lock_eio — Cooperative per-key locking + flock.

    Two-layer locking for local filesystem paths:
    1. Shared atomic ownership — serializes Eio fibers and Domain callers
    2. Unix.lockf F_TLOCK (non-blocking) — preserves cross-process safety

    Eio fibers and blocking Domain callers use separate waiting contracts over
    the same ownership bit. The flock is acquired non-blocking afterwards; if
    another process holds it, the caller uses its selected waiting contract.

    Distributed backend paths (Some key in workspace_utils_ops.ml) are not
    affected — this only replaces the local filesystem lock path. *)

module SMap = Set_util.StringMap
module Blocking_mutex = Stdlib.Mutex
module Blocking_condition = Stdlib.Condition

module Key = struct
  type t = string

  let normalize_absolute path =
    let absolute =
      if Filename.is_relative path
      then Filename.concat (Sys.getcwd ()) path
      else path
    in
    let parent = Filename.dirname absolute in
    let canonical_parent =
      try Unix.realpath parent with
      | Unix.Unix_error _ -> parent
    in
    Filename.concat canonical_parent (Filename.basename absolute)
  ;;

  let of_path path = normalize_absolute path
  let to_path key = key
end

exception Flock_timeout of { caller : string; path : string; attempts : int }

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

type lock_entry = {
  held : bool Atomic.t;
  wait_mu : Blocking_mutex.t;
  wait_condition : Blocking_condition.t;
  last_used : float Atomic.t;
  active : int Atomic.t;
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
    in-use entries (see TLA+ FileLockStarvation spec).
    Falls back to direct Hashtbl access when no Eio context is available
    (e.g. in unit tests that don't use Eio_main.run). *)
let get_entry path =
  prune_stale_entries ();
  let rec acquire_reference () =
    let state = Atomic.get table in
    let entry, updated_state =
      match SMap.find_opt path state.entries with
      | Some entry -> entry, state
      | None ->
        let entry =
          { held = Atomic.make false
          ; wait_mu = Blocking_mutex.create ()
          ; wait_condition = Blocking_condition.create ()
          ; last_used = Atomic.make (Time_compat.now ())
          ; active = Atomic.make 0
          }
        in
        entry, publish_entries state (SMap.add path entry state.entries)
    in
    Atomic.incr entry.active;
    if Atomic.compare_and_set table state updated_state
    then (
      Atomic.set entry.last_used (Time_compat.now ());
      entry)
    else (
      let _previous_active = Atomic.fetch_and_add entry.active (-1) in
      observe_cas_retry ();
      acquire_reference ())
  in
  acquire_reference ()

let release_entry entry =
  let _previous_active = Atomic.fetch_and_add entry.active (-1) in
  ()

let rec acquire_entry_eio entry =
  if Atomic.compare_and_set entry.held false true
  then ()
  else (
    Eio.Fiber.yield ();
    acquire_entry_eio entry)
;;

let acquire_entry_blocking entry =
  Blocking_mutex.lock entry.wait_mu;
  Fun.protect
    ~finally:(fun () -> Blocking_mutex.unlock entry.wait_mu)
    (fun () ->
       while not (Atomic.compare_and_set entry.held false true) do
         Blocking_condition.wait entry.wait_condition entry.wait_mu
       done)
;;

let release_entry_lock entry =
  Atomic.set entry.held false;
  Blocking_mutex.lock entry.wait_mu;
  Blocking_condition.broadcast entry.wait_condition;
  Blocking_mutex.unlock entry.wait_mu
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

(** Run [f] while holding shared per-path process-local ownership using the
    caller-selected waiting contract. *)
let with_entry_lock acquire (key : Key.t) f =
  let entry = get_entry (Key.to_path key) in
  Common.protect ~module_name:"file_lock_eio" ~finally_label:"release_entry"
    ~finally:(fun () -> release_entry entry)
    (fun () ->
       acquire entry;
       Common.protect
         ~module_name:"file_lock_eio"
         ~finally_label:"release_entry_lock"
         ~finally:(fun () -> release_entry_lock entry)
         f)
;;

let with_mutex_eio key f = with_entry_lock acquire_entry_eio key f
let with_mutex_blocking key f = with_entry_lock acquire_entry_blocking key f

let with_mutex path f =
  let key = Key.of_path path in
  if Eio_guard.is_ready ()
  then with_mutex_eio key f
  else with_mutex_blocking key f

(** Run [f] while holding both shared per-path process-local ownership and an
    OS-level flock on [path].lock. The flock uses non-blocking F_TLOCK retries;
    sleep/yield stays scheduler-friendly whether or not a clock is provided.
    Max 200 attempts (~2s with sleeps). *)
let with_lock_mode with_mutex ?clock (key : Key.t) f =
  let run_with_flock () =
    let path = Key.to_path key in
    let lock_path = path ^ ".lock" in
    let dir = Filename.dirname lock_path in
    if not (Sys.file_exists dir) then
      (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let fd = acquire_flock_fd ?clock lock_path in
    Common.protect ~module_name:"file_lock_eio" ~finally_label:"finalizer"
      ~finally:(fun () -> release_flock_fd fd)
      f
  in
  with_mutex key run_with_flock
;;

let with_lock_eio ?clock key f =
  with_lock_mode with_mutex_eio ?clock key f
;;

let with_lock_blocking key f =
  let path = Key.to_path key in
  let run_with_flock () =
    let lock_path = path ^ ".lock" in
    let dir = Filename.dirname lock_path in
    if not (Sys.file_exists dir)
    then (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let fd =
      acquire_flock_retry
        ~lock_path
        ~mode:[ Unix.O_CREAT; Unix.O_WRONLY ]
        ~perm:0o644
        ~caller:"File_lock_eio.blocking"
        ()
    in
    Fun.protect ~finally:(fun () -> release_flock_fd fd) f
  in
  with_mutex_blocking key run_with_flock
;;

let with_lock ?clock path f =
  let key = Key.of_path path in
  if Eio_guard.is_ready ()
  then with_lock_eio ?clock key f
  else with_lock_blocking key f

(** Number of tracked lock paths (for diagnostics). *)
let lock_count () = SMap.cardinal (Atomic.get table).entries
