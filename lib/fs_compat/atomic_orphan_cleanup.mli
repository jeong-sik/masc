(** Blocking orphan recovery for a stable, process-owned staging directory.
    Uses [Atomic_temp_name] for the writer's filename grammar. Callers own
    lifecycle sequencing and recording the returned report. *)

type atomic_orphan_cleanup_operation =
  | Inspect_cleanup_root
  | Read_cleanup_directory
  | Inspect_orphan
  | Create_recovery_directory
  | Sync_recovery_parent
  | Link_preserved_orphan
  | Verify_preserved_orphan
  | Sync_preserved_orphan
  | Sync_recovery_directory
  | Delete_empty_orphan
  | Delete_preserved_source
  | Sync_source_directory
  | Close_cleanup_descriptor

type atomic_orphan_cleanup_cause =
  | Unix_failure of Unix.error * string * string
  | Sys_failure of string
  | Unexpected_file_kind of Unix.file_kind
  | Outside_ownership_root of { ownership_root : string }
  | Identity_changed
  | Other_failure of exn

type atomic_orphan_cleanup_failure =
  { operation : atomic_orphan_cleanup_operation
  ; path : string
  ; cause : atomic_orphan_cleanup_cause
  }

type atomic_orphan_cleanup_report =
  { inspected : int
  ; deleted : int
  ; preserved : int
  ; failures : atomic_orphan_cleanup_failure list
  }

val atomic_orphan_cleanup_failure_to_string
  :  atomic_orphan_cleanup_failure
  -> string

(** #10130: no-follow boot-time cleanup for canonical [.atomic_*.tmp] orphans.

    The sweep scans exactly [base_path]; symbolic links are never followed.

    [ownership_root] is the canonical process-owned ancestor of [base_path].
    Every existing component from that root through [base_path] is inspected
    with [lstat] and must be a real directory. A symbolic-link ancestor, a
    non-directory component, or a lexical path outside [ownership_root]
    produces a typed failure before the inventory is read.

    The caller must keep the scanned directory identity process-owned and
    stable, and must ensure no writer creates a matching atomic-temp name
    concurrently. Unrelated entries may change. The portable [Unix]
    API has no dirfd-relative [openat]/[unlinkat] operations, so the
    implementation validates inode identity immediately before each mutation
    but cannot make concurrent replacement of an intermediate path component
    atomic. Server startup and the dedicated Keeper staging lifecycle provide
    this ownership boundary.

    Zero-byte regular files are unlinked. Non-empty regular files are
    preserved without overwrite under [<base_path>/.recovered/root/]. The
    preservation path uses a hard-link-then-unlink protocol and fsyncs both
    directory sides. Orphan-shaped non-regular entries and every
    filesystem failure remain in [report.failures]; cancellation is re-raised.
    A missing [base_path] is an empty inventory, not a failure. *)
val cleanup_atomic_orphans
  :  ownership_root:string
  -> base_path:string
  -> unit
  -> atomic_orphan_cleanup_report
