(** Durable atomic write + crash-recovery orphan sweep.

    Owns the durability boundary that protects against partial
    writes, torn renames, and SIGKILL-during-write data loss. The
    contract is [tmp → fsync(tmp) → rename → fsync(parent dir)],
    so a crash between rename and the kernel's dirty-page flush
    cannot leave the target truncated or zero-length. Observed on
    [backlog.json] after an abrupt shutdown on 2026-04-18.

    Crash recovery is provided by [cleanup_atomic_orphans], a
    boot-time sweep for [.atomic_*.tmp] files left behind when the
    owning process was SIGKILL'd after the descriptor-owned writer
    created its exclusive temporary entry.

    The writer SSOT is {!Durable_mutation}; this module owns only the
    legacy boot-time recovery traversal until #24083 replaces it with
    schema-owned roots. *)

(** #10130: boot-time sweep for [.atomic_*.tmp] orphans.

    Scans [base_path] and its immediate subdirectories (skipping
    [recovered_subdir] and anything that isn't a directory).
    - Zero-byte orphans are deleted (they lost the rename race
      but never held data).
    - Non-zero orphans are MOVED to
      [<base_path>/<recovered_subdir>/<original-name>.<ts-ms>]
      so operators can forensically inspect data-loss events
      instead of having them silently cleaned up.

    Returns [(deleted, preserved)]:
    - [deleted]: zero-byte orphans removed.
    - [preserved]: non-zero orphans moved to [recovered_subdir]. *)
val cleanup_atomic_orphans
  :  mkdir_p_unix:(string -> unit)
  -> base_path:string
  -> ?recovered_subdir:string
  -> unit
  -> int * int
