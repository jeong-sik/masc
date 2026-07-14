(** Durable atomic write + crash-recovery orphan sweep.

    Owns the durability boundary that protects against partial
    writes, torn renames, and SIGKILL-during-write data loss. The
    contract is [tmp → fsync(tmp) → rename → fsync(parent dir)],
    so a crash between rename and the kernel's dirty-page flush
    cannot leave the target truncated or zero-length. Observed on
    [backlog.json] after an abrupt shutdown on 2026-04-18.

    Crash recovery is provided by [cleanup_atomic_orphans], a boot-time sweep
    for canonical [.atomic_*.tmp] files left behind when the owning process was
    SIGKILL'd or temp-file creation itself raised ENFILE/EMFILE before the
    with-handler could register.

    The [save_file] primitive is injected so this module stays free of
    [Fs_compat]'s Eio bridge. Recovery uses only typed [Unix] operations and
    returns every failure to the caller. *)

(** [save_file_atomic ~save_file path content] writes [content] to
    a temp file in [path]'s directory, fsyncs the tmp, renames it
    over [path], and best-effort fsyncs the parent directory.

    Returns [Ok ()] on success or [Error msg] when the write or
    rename fails (the tmp is cleaned up). Re-raises
    [Eio.Cancel.Cancelled] after cleaning up the tmp — cancellation
    must not be swallowed (RFC-0143). *)
val save_file_atomic
  :  save_file:(string -> string -> unit)
  -> string
  -> string
  -> (unit, string) Result.t

(** [open_atomic_temp_file ~temp_dir ()] creates and opens a fresh
    temp file in [temp_dir] using the canonical [.atomic_*.tmp]
    filename shape. The caller owns the returned channel and file. *)
val open_atomic_temp_file : temp_dir:string -> unit -> string * out_channel

type capability_write_intent =
  | Atomic_replace
  | Create_exclusive

type capability_write_stage =
  | Validate_leaf
  | Acquire_mutation_lease
  | Create_staging_directory
  | Inspect_staging_directory
  | Acquire_staging_directory
  | Apply_staging_directory_permissions
  | Verify_staging_directory_identity
  | Create_staging_entry
  | Create_target_entry
  | Inspect_open_resource
  | Write_payload
  | Apply_permissions
  | Sync_payload
  | Close_payload
  | Verify_entry_identity
  | Publish_replace
  | Sync_staging_directory
  | Sync_parent
  | Remove_staging_directory
  | Close_staging_directory
  | Cleanup_close
  | Cleanup_verify_identity
  | Cleanup_unlink
  | Cleanup_sync_staging_directory
  | Cleanup_verify_staging_directory_identity
  | Cleanup_remove_staging_directory
  | Cleanup_close_staging_directory
  | Cleanup_sync_parent

type capability_write_target_effect =
  | Target_unchanged
  | Target_created
  | Target_created_incomplete
  | Target_replaced
  | Target_state_unknown

type capability_write_operation_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type capability_write_payload_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  ; bytes_written : int
  }

type capability_write_cause =
  | Invalid_leaf of string
  | Mutation_contended
  | Posix_descriptor_unavailable
  | Unexpected_resource_kind of Eio.File.Stat.kind
  | Resource_identity_unavailable
  | Resource_identity_changed
  | Payload_write_failed of capability_write_payload_failure
  | Operation_failed of capability_write_operation_failure

type capability_write_failure =
  { stage : capability_write_stage
  ; cause : capability_write_cause
  }

type capability_write_error =
  { intent : capability_write_intent
  ; target_effect : capability_write_target_effect
  ; failure : capability_write_failure
  ; cleanup_failures : capability_write_failure list
  }

type capability_directory_sync_error =
  { failure : capability_write_failure
  ; cleanup_failures : capability_write_failure list
  }

type capability_write_cancellation =
  { intent : capability_write_intent
  ; target_effect : capability_write_target_effect
  ; cleanup_failures : capability_write_failure list
  }

exception Capability_write_cancelled of exn * capability_write_cancellation

(** Publish [content] below an already-open, caller-validated directory
    capability. No path is reopened from a process-global root.

    [Atomic_replace] creates a unique 0700 staging directory below [parent],
    pins it as a directory capability, and creates a fixed private payload
    inside that capability. It applies [permissions], fsyncs and closes the
    payload, then cancellation-protects rename, source-directory fsync,
    staging-directory removal, and parent fsync. The parent is synced once,
    after removal, so that one durability barrier covers both the target rename
    and removal of the staging entry.
    [Create_exclusive] opens the final leaf exclusively, so the entry is
    visible before its payload is complete. A failure before payload sync,
    close, and identity verification completes leaves the public leaf in place
    and reports [Target_created_incomplete]. Once those steps complete,
    parent-sync failure reports [Target_created] while the failure stage keeps
    the missing durability acknowledgement explicit.

    Parent-fsync and cleanup failures are never downgraded to success. A
    cancellation is re-raised after cleanup or after the protected commit; if
    cancellation cleanup itself fails, the typed failures are preserved in
    [Capability_write_cancelled]. Exclusive-create failures never unlink the
    public leaf: OCaml 5.4/Eio has no conditional unlink primitive, so an
    identity check followed by unlink would still have a swap race.

    The unique directory and pinned source capability prevent cooperative MASC
    writers from sharing a staging namespace. Its 0700 mode excludes other OS
    users; it is not a security boundary against a hostile process running as
    the same OS user. No legacy [.atomic_*.tmp] pathname is used by this API. *)
val publish_capability_file
  :  parent:Eio.Fs.dir_ty Eio.Path.t
  -> leaf:string
  -> intent:capability_write_intent
  -> permissions:int
  -> string
  -> (unit, capability_write_error) result

val capability_write_error_to_string : capability_write_error -> string
val capability_write_intent_to_string : capability_write_intent -> string
val capability_write_stage_to_string : capability_write_stage -> string

val capability_write_target_effect_to_string
  :  capability_write_target_effect
  -> string

val capability_write_cause_to_string : capability_write_cause -> string
val capability_write_failure_to_string : capability_write_failure -> string

val sync_directory_capability
  :  _ Eio.Path.t
  -> (unit, capability_directory_sync_error) result
(** Fsync an already-open directory capability. Descriptor acquisition,
    fsync, and explicit close failures are preserved; cancellation propagates
    after the system-thread operation is observed. *)

val capability_directory_sync_error_to_string
  :  capability_directory_sync_error
  -> string

module Capability_write_for_testing : sig
  val publish_capability_file
    :  before_stage:(capability_write_stage -> unit)
    -> parent:Eio.Fs.dir_ty Eio.Path.t
    -> leaf:string
    -> intent:capability_write_intent
    -> permissions:int
    -> string
    -> (unit, capability_write_error) result

  val sync_directory_capability
    :  before_stage:(capability_write_stage -> unit)
    -> _ Eio.Path.t
    -> (unit, capability_directory_sync_error) result
end

(** [true] iff [name] matches the canonical [.atomic_*.tmp] shape produced by
    this module. Exposed so recovery sweeps do not re-derive the filename
    contract — #10205 finding 2. *)
val is_atomic_orphan_name : string -> bool

type atomic_orphan_cleanup_scope =
  | Directory_only
  | Directory_and_immediate_subdirectories

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

    [Directory_only] scans exactly [base_path].
    [Directory_and_immediate_subdirectories] additionally scans only real
    immediate child directories; symbolic links are never followed.

    [ownership_root] is the canonical process-owned ancestor of [base_path].
    Every existing component from that root through [base_path] is inspected
    with [lstat] and must be a real directory. A symbolic-link ancestor, a
    non-directory component, or a lexical path outside [ownership_root]
    produces a typed failure before the inventory is read.

    The caller must keep every scanned directory identity process-owned and
    stable, and must ensure no writer creates a matching atomic-temp name
    concurrently. Unrelated entries may change. OCaml 5.4's portable [Unix]
    API has no dirfd-relative [openat]/[unlinkat] operations, so the
    implementation validates inode identity immediately before each mutation
    but cannot make concurrent replacement of an intermediate path component
    atomic. Server startup and the dedicated Keeper staging lifecycle provide
    this ownership boundary.

    Zero-byte regular files are unlinked. Non-empty regular files are
    preserved without overwrite under
    [<base_path>/.recovered/{root,children/<child>}/]. The preservation path
    retains source provenance, uses a hard-link-then-unlink protocol, and
    fsyncs both directory sides. Orphan-shaped non-regular entries and every
    filesystem failure remain in [report.failures]; cancellation is re-raised.
    A missing [base_path] is an empty inventory, not a failure. *)
val cleanup_atomic_orphans
  :  ownership_root:string
  -> base_path:string
  -> scope:atomic_orphan_cleanup_scope
  -> unit
  -> atomic_orphan_cleanup_report
