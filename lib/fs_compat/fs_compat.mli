(** Filesystem Compatibility Layer - Eio-native I/O with fallback

    @since 2026-02 - Keeper Emergent Identity v2.0
*)

module Atomic_orphan_size_class = Atomic_orphan_size_class

(** #9921: raised by mutating [Fs_compat] entry points
    ([append_file], [save_file], [mkdir_p]) when the target path falls
    under [HOME] and the process is a test executable. Defense in depth
    behind [Env_config_core.base_path_prod_guard]. Bypass with
    [MASC_TEST_ALLOW_HOME_BASE_PATH=1]. *)
exception Test_isolation_breach of string

(** Set global Eio filesystem. Call at server startup. *)
val set_fs : Eio.Fs.dir_ty Eio.Path.t -> unit

(** Clear global fs (testing/shutdown). *)
val clear_fs : unit -> unit

(** Get the global Eio filesystem if available. *)
val get_fs_opt : unit -> Eio.Fs.dir_ty Eio.Path.t option

(** Check if Eio fs is available. *)
val has_fs : unit -> bool

type exact_path_kind =
  | Exact_missing
  | Exact_kind of Unix.file_kind
  | Exact_unknown

(** Eio-native exact path classification. Unlike {!path_kind}, this preserves
    regular files, symbolic links, FIFOs, sockets, and devices as distinct
    [Unix.file_kind] values. Classification followed by a separate path-based
    I/O operation is not atomic; owned-file readers must use
    {!load_owned_regular_file}. *)
val exact_path_kind : ?follow:bool -> string -> exact_path_kind

type path_kind =
  | Missing
  | Directory
  | Other

(** Coarse projection of {!exact_path_kind}. [follow=false] classifies a
    symbolic link as [Other] instead of classifying its target. Non-missing
    I/O failures remain explicit. *)
val path_kind : ?follow:bool -> string -> path_kind

type owned_directory_chain_rejection = Owned_directory_chain.rejection =
  | Owned_path_outside_root of
      { ownership_root : string
      ; path : string
      }
  | Owned_path_non_directory of
      { path : string
      ; kind : Unix.file_kind
      }

type owned_directory_chain_observation = Owned_directory_chain.observation =
  | Owned_directory_missing
  | Owned_directory of Unix.stats

val inspect_owned_directory_chain
  :  ownership_root:string
  -> string
  -> (owned_directory_chain_observation, owned_directory_chain_rejection) result
(** Shared no-follow ownership-boundary inspection. *)

val owned_directory_chain_rejection_to_string
  :  owned_directory_chain_rejection
  -> string

val owned_directory_paths
  :  ownership_root:string
  -> string
  -> (string list, owned_directory_chain_rejection) result
(** Lexical ordered descendant paths for ownership-aware directory creation. *)

type owned_regular_file_read_operation =
  | Inspect_parent
  | Inspect_path
  | Open_path
  | Inspect_descriptor
  | Read_contents
  | Close_descriptor

type owned_regular_file_read_failure =
  | Ownership_boundary_rejected of
      { path : string
      ; rejection : owned_directory_chain_rejection
      }
  | Path_is_not_regular_file of
      { path : string
      ; kind : Unix.file_kind
      }
  | Filesystem_identity_changed of { path : string }
  | Owned_file_operation_failed of
      { path : string
      ; operation : owned_regular_file_read_operation
      ; cause : exn
      }

type owned_regular_file_read_error =
  { failure : owned_regular_file_read_failure
  ; close_failure : exn option
  }

(** Read one process-owned regular file without accepting symbolic links or a
    changed parent chain. [Ok None] means that the owned directory or file is
    absent. OCaml 5.4 does not expose [O_NOFOLLOW], so the implementation
    validates [lstat]/[fstat] identity before reading and revalidates the
    no-follow parent and leaf boundary after the read. Blocking Unix operations
    run in a system thread when the Eio filesystem is active. A simultaneous
    read and descriptor-close failure preserves both causes. *)
val load_owned_regular_file
  :  ownership_root:string
  -> string
  -> (string option, owned_regular_file_read_error) result

val owned_regular_file_read_error_to_string
  :  owned_regular_file_read_error
  -> string

(** Eio-native, deterministically sorted directory inventory. *)
val read_dir : string -> string list

(** Load entire file as string. *)
val load_file : string -> string

(** Load entire file as string, or [None] when the file is missing.
    Option-returning sibling of {!load_file} (which raises on a missing
    path). Other I/O failures of an existing file propagate as
    [Sys_error]. *)
val load_file_opt : string -> string option

(** Save string to file (overwrite). *)
val save_file : string -> string -> unit

(** Write content to path via temp file + rename.
    Returns [Error msg] on I/O failure instead of raising. *)
val save_file_atomic : string -> string -> (unit, string) Result.t

(** [open_atomic_temp_file ~temp_dir ()] creates and opens a fresh
    temp file in [temp_dir] using the canonical [.atomic_*.tmp]
    filename shape. The caller owns the returned channel and file. *)
val open_atomic_temp_file : temp_dir:string -> unit -> string * out_channel

(** [true] exactly for one non-empty lexical child component. This is the
    shared path-effect and mutation-lease validation boundary. *)
val is_capability_leaf : string -> bool

type capability_append_operation_failure =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type capability_append_failure =
  | Capability_append_posix_descriptor_unavailable
  | Capability_append_mutation_contended
  | Capability_append_operation_failed of capability_append_operation_failure

type capability_append_target_binding =
  | Capability_append_target_not_checked
  | Capability_append_target_verified
  | Capability_append_target_changed
  | Capability_append_target_check_failed of capability_append_operation_failure

type capability_append_outcome =
  { requested_bytes : int
  ; bytes_written : int
  ; write_failure : capability_append_failure option
  ; sync_failure : capability_append_operation_failure option
  ; target_binding : capability_append_target_binding
  }

val capability_append_failure_to_string : capability_append_failure -> string

type capability_append_open_error =
  | Capability_append_open_invalid_leaf of string
  | Capability_append_open_missing
  | Capability_append_open_failed of capability_append_operation_failure

type capability_append_file

val capability_append_open_error_to_string : capability_append_open_error -> string

(** Open an opaque append capability. The resource is always opened by this
    module with kernel append semantics; callers cannot construct a capability
    from an arbitrary file resource. Its lifetime belongs to [sw]. *)
val open_capability_append_file
  :  sw:Eio.Switch.t
  -> parent:Eio.Fs.dir_ty Eio.Path.t
  -> leaf:string
  -> (capability_append_file, capability_append_open_error) result

val capability_append_file_stat : capability_append_file -> Eio.File.Stat.t

(** Append through an opaque append capability without destructive rollback.
    Cooperative same-process mutations of the same opened target identity use
    one shared non-blocking lease without lexical-name normalization. An active
    absent-target publication under the same parent also excludes the append,
    covering the transition from an absent name to a visible inode. The
    leaf-to-open-file identity is checked before and after the write, so an
    external rename is reported rather than misclassified as a visible append.
    External processes are an observation boundary, not an exclusion
    guarantee. Partial bytes and their fsync result remain explicit. The caller
    owns the next cancellation checkpoint. *)
val append_capability_observed
  :  capability_append_file
  -> string
  -> capability_append_outcome

type capability_append_io_for_testing =
  { write_substring : Unix.file_descr -> string -> int -> int -> int
  ; fsync : Unix.file_descr -> unit
  }

module Capability_append_for_testing : sig
  val append_capability_observed
    :  after_write:(unit -> unit)
    -> capability_append_file
    -> string
    -> capability_append_outcome

  val append_fd_observed
    :  io:capability_append_io_for_testing
    -> fd:Unix.file_descr
    -> string
    -> capability_append_outcome
end

type atomic_replace_recovery_target
type atomic_replace_recovery_target_error

module Publication_recovery : module type of Publication_recovery_access
type publication_recovery_access = Publication_recovery.t
type publication_recovery_registry = Publication_recovery.registry
type publication_recovery_registry_error = Capability_recovery_obligation.transition_error
type publication_recovery_lane_open_error = Publication_recovery.lane_open_error
type publication_recovery_reconciliation_report = Capability_recovery_reconciler.report
type publication_recovery_owner = Publication_recovery.owner

type publication_recovery_lane_open_error_kind =
  | Publication_recovery_invalid_owner
  | Publication_recovery_reconciliation_blocked
  | Publication_recovery_store_failed

type publication_recovery_record_area =
  | Publication_recovery_active
  | Publication_recovery_owned
  | Publication_recovery_forensic

type publication_recovery_source_state =
  | Publication_recovery_prepared_source
  | Publication_recovery_bound_source

type publication_recovery_prepared_outcome_kind =
  | Publication_recovery_prepared_unmaterialized
  | Publication_recovery_prepared_allowed_root_mismatch
  | Publication_recovery_prepared_parent_mismatch
  | Publication_recovery_prepared_unbound_stage_preserved

type publication_recovery_bound_outcome_kind =
  | Publication_recovery_bound_stage_absent
  | Publication_recovery_bound_allowed_root_mismatch
  | Publication_recovery_bound_parent_mismatch
  | Publication_recovery_bound_stage_mismatch
  | Publication_recovery_bound_stage_preserved

type publication_recovery_reconciliation_row_kind =
  | Publication_recovery_unexpected_lane_entry
  | Publication_recovery_missing_lane_entry
  | Publication_recovery_lane_entry_unavailable
  | Publication_recovery_area_inventory_unavailable
  | Publication_recovery_source_transition_capabilities_unavailable
  | Publication_recovery_prepared_reconciled of
      publication_recovery_prepared_outcome_kind
  | Publication_recovery_bound_reconciled of
      publication_recovery_bound_outcome_kind
  | Publication_recovery_existing_forensic_record of
      publication_recovery_source_state
  | Publication_recovery_conflicting_source_records
  | Publication_recovery_invalid_record_name
  | Publication_recovery_unexpected_record_kind
  | Publication_recovery_missing_record_entry
  | Publication_recovery_record_entry_unavailable
  | Publication_recovery_corrupt_record_preserved
  | Publication_recovery_record_observation_failed
  | Publication_recovery_record_transition_failed
  | Publication_recovery_record_scope_release_failed
  | Publication_recovery_owner_store_release_failed
  | Publication_recovery_owner_store_unavailable
  | Publication_recovery_owner_inventory_unavailable

(** Open the process-lifetime publication recovery registry below a
    caller-owned MASC root capability. The registry remains valid for exactly
    the lifetime of [sw]. *)
val open_publication_recovery_registry
  :  sw:Eio.Switch.t
  -> fs:Eio.Fs.dir_ty Eio.Path.t
  -> registry_root:Eio.Fs.dir_ty Eio.Path.t
  -> (publication_recovery_registry, publication_recovery_registry_error) result

val publication_recovery_registry_error_to_string
  :  publication_recovery_registry_error
  -> string

val publication_recovery_reconciliation_report_owner
  :  publication_recovery_reconciliation_report
  -> string

val publication_recovery_reconciliation_report_is_ready
  :  publication_recovery_reconciliation_report
  -> bool

val publication_recovery_reconciliation_report_row_kinds
  :  publication_recovery_reconciliation_report
  -> publication_recovery_reconciliation_row_kind list

val publication_recovery_reconciliation_report_to_string
  :  publication_recovery_reconciliation_report
  -> string

(** Constructor-directed structured report projection. Callers can observe row
    identity and nested evidence without parsing diagnostic strings. *)
val publication_recovery_reconciliation_report_to_yojson
  :  publication_recovery_reconciliation_report
  -> Yojson.Safe.t

(** Pin one Keeper-owned publication recovery lane for the whole callback.
    Publications borrow its store through the opaque access value. Closing
    rejects new borrows and drains every already-started borrow without a
    timeout or retry budget. *)
val with_publication_recovery_lane
  :  registry:publication_recovery_registry
  -> owner:string
  -> (publication_recovery_access -> 'a)
  -> ('a Publication_recovery.lane_outcome,
      publication_recovery_lane_open_error)
       result

val publication_recovery_lane_open_error_to_string
  :  publication_recovery_lane_open_error
  -> string

(** Constructor-directed public classification. The category never contains
    owner names, recovery records, paths, operation IDs, or exception text. *)
val publication_recovery_lane_open_error_kind
  :  publication_recovery_lane_open_error
  -> publication_recovery_lane_open_error_kind

(** Build the immutable recovery locator projection used by
    {!replace_capability_file}. *)
val atomic_replace_recovery_target
  :  allowed_root_path:string
  -> allowed_root_device:int64
  -> allowed_root_inode:int64
  -> parent_components:string list
  -> target_leaf:string
  -> permissions:int
  -> (atomic_replace_recovery_target, atomic_replace_recovery_target_error) result

val atomic_replace_recovery_target_error_to_string
  :  atomic_replace_recovery_target_error
  -> string

type capability_write_operation =
  | Atomic_replace_operation
  | Create_exclusive_operation

type capability_write_stage =
  | Validate_leaf
  | Acquire_mutation_lease
  | Acquire_publication_lease
  | Inspect_target_entry
  | Verify_target_binding
  | Prepare_recovery_obligation
  | Create_staging_directory
  | Inspect_staging_directory
  | Acquire_staging_directory
  | Apply_staging_directory_permissions
  | Verify_staging_directory_identity
  | Preserve_unbound_recovery_obligation
  | Bind_recovery_obligation
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
  | Discharge_prepared_recovery_obligation
  | Discharge_bound_recovery_obligation
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
  | Invalid_recovery_target of atomic_replace_recovery_target_error
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

type capability_recovery_phase =
  | Recovery_validate_owner
  | Recovery_open_registry
  | Recovery_open_store
  | Recovery_prepare
  | Recovery_preserve_unbound
  | Recovery_bind
  | Recovery_discharge_prepared
  | Recovery_discharge_bound

type capability_recovery_removal_transition =
  | Recovery_discharge_active
  | Recovery_discharge_owned
  | Recovery_active_to_owned
  | Recovery_active_to_forensic
  | Recovery_owned_to_forensic

type capability_recovery_effect =
  | Recovery_no_record_change
  | Recovery_layout_may_be_incomplete
  | Recovery_layout_ready
  | Recovery_active_record_state_unknown
  | Recovery_active_record_durable
  | Recovery_active_record_discharged
  | Recovery_owned_record_state_unknown_with_active
  | Recovery_owned_record_durable_with_active
  | Recovery_owned_record_durable
  | Recovery_owned_record_discharged
  | Recovery_forensic_record_state_unknown_with_source
  | Recovery_forensic_record_durable_with_source
  | Recovery_forensic_record_durable
  | Recovery_source_removal_durability_unknown of
      capability_recovery_removal_transition

type capability_recovery_failure

val capability_recovery_phase_to_string : capability_recovery_phase -> string
val capability_recovery_effect_to_string : capability_recovery_effect -> string

val capability_recovery_failure_phase
  :  capability_recovery_failure
  -> capability_recovery_phase

val capability_recovery_failure_effect
  :  capability_recovery_failure
  -> capability_recovery_effect

val capability_recovery_failure_to_string
  :  capability_recovery_failure
  -> string

type capability_recovery_access_failure = Recovery_access_not_available

type capability_write_primary_failure =
  | Write_primary_failure of capability_write_failure
  | Recovery_primary_failure of capability_recovery_failure
  | Recovery_access_primary_failure of capability_recovery_access_failure

type capability_write_cleanup_failure =
  | Write_cleanup_failure of capability_write_failure
  | Recovery_cleanup_failure of capability_recovery_failure

type capability_write_error =
  { operation : capability_write_operation
  ; target_effect : capability_write_target_effect
  ; primary_failure : capability_write_primary_failure
  ; cleanup_failures : capability_write_cleanup_failure list
  }

type capability_directory_sync_error =
  { failure : capability_write_failure
  ; cleanup_failures : capability_write_failure list
  }

type publication_recovery_fixture_error

val publication_recovery_fixture_error_to_string
  :  publication_recovery_fixture_error
  -> string

type capability_write_cancellation =
  { operation : capability_write_operation
  ; target_effect : capability_write_target_effect
  ; interrupted_primary_failure : capability_write_primary_failure option
  ; interrupted_recovery : capability_recovery_failure option
  ; cleanup_failures : capability_write_cleanup_failure list
  }

exception Capability_write_cancelled of exn * capability_write_cancellation

(** Durable replacement below an already-open target-parent capability.
    Recovery access and the immutable target projection are mandatory. *)
val replace_capability_file
  :  recovery:publication_recovery_access
  -> parent:Eio.Fs.dir_ty Eio.Path.t
  -> target:atomic_replace_recovery_target
  -> string
  -> (unit, capability_write_error) result

(** Exclusive creation is physically separate from replacement and has no
    recovery-obligation argument. Once the public leaf is created it is never
    unlinked by failure cleanup. *)
val create_capability_file_exclusive
  :  parent:Eio.Fs.dir_ty Eio.Path.t
  -> leaf:string
  -> permissions:int
  -> string
  -> (unit, capability_write_error) result

val capability_write_error_to_string : capability_write_error -> string
val capability_write_operation_to_string : capability_write_operation -> string
val capability_write_stage_to_string : capability_write_stage -> string

val capability_write_target_effect_to_string
  :  capability_write_target_effect
  -> string

val capability_write_cause_to_string : capability_write_cause -> string
val capability_write_failure_to_string : capability_write_failure -> string

val sync_directory_capability
  :  _ Eio.Path.t
  -> (unit, capability_directory_sync_error) result

val capability_directory_sync_error_to_string
  :  capability_directory_sync_error
  -> string

module Capability_write_for_testing : sig
  type resource_scope_callback =
    | Return_completed_rows of string list
    | Cancel_callback of exn

  type resource_scope_evidence =
    | Returned_rows of
        { completed_rows : string list
        ; release_failure : exn option
        }
    | Cancelled_callback of
        { reason : exn
        ; release_failure : exn option
        }
    | Raised_callback of
        { exception_ : exn
        ; release_failure : exn option
        }

  type cleanup_body =
    | Return_cleanup_value of string
    | Raise_cleanup_body of exn
    | Cancel_cleanup_body of exn

  type observed_cleanup_failure =
    { exception_ : exn
    ; backtrace : Printexc.raw_backtrace
    }

  type cleanup_evidence =
    | Cleanup_returned of string
    | Cleanup_failed_without_cancellation of
        { body : observed_cleanup_failure option
        ; cleanup : observed_cleanup_failure
        }
    | Cancellation_primary_with_cleanup_failure of
        { body : observed_cleanup_failure option
        ; cancellation : observed_cleanup_failure
        ; cleanup : observed_cleanup_failure
        }
    | Body_failure_during_cancellation of
        { body : observed_cleanup_failure
        ; cancellation : observed_cleanup_failure
        }
    | Cancellation_primary of observed_cleanup_failure
    | Cleanup_boundary_raised of observed_cleanup_failure

  type single_borrow_evidence =
    | Single_borrow_balance of
        { during_borrow : int
        ; after_release : int
        ; close_completed : bool
        }
    | Single_borrow_rejected
    | Single_borrow_invariant of invariant_violation
    | Single_borrow_raised of observed_cleanup_failure

  and invariant_violation =
    | Borrow_count_underflow
    | Borrow_count_overflow
    | Closing_without_active_borrows
    | Closed_with_active_borrows of int
    | Closed_without_drain_signal
    | Drain_signal_already_resolved
    | Discovery_settled_twice
    | Discovery_finished_outside_running
    | Owner_inventory_owner_not_running of string
    | Reconciliation_owner_not_running of string
    | Owner_generation_settled_twice of string
    | Owner_generation_settled_before_terminal of string
    | Health_counter_underflow
    | Health_counter_overflow
    | Cleanup_body_outcome_lost

  val run_publication_recovery_resource_scope
    :  callback:resource_scope_callback
    -> release_failure:exn option
    -> resource_scope_evidence

  val run_publication_recovery_cleanup_boundary
    :  body:cleanup_body
    -> cleanup_failure:exn option
    -> cleanup_evidence

  val single_publication_recovery_borrow_balance
    :  registry:publication_recovery_registry
    -> owner:string
    -> (single_borrow_evidence, publication_recovery_lane_open_error) result

  val publication_recovery_stage_name : Uuidm.t -> string

  val replace_capability_file
    :  before_stage:(capability_write_stage -> unit)
    -> recovery:publication_recovery_access
    -> parent:Eio.Fs.dir_ty Eio.Path.t
    -> target:atomic_replace_recovery_target
    -> string
    -> (unit, capability_write_error) result

  val create_capability_file_exclusive
    :  before_stage:(capability_write_stage -> unit)
    -> parent:Eio.Fs.dir_ty Eio.Path.t
    -> leaf:string
    -> permissions:int
    -> string
    -> (unit, capability_write_error) result

  val seed_prepared_publication_recovery
    :  registry:publication_recovery_registry
    -> owner:string
    -> operation_id:Uuidm.t
    -> allowed_root_path:string
    -> allowed_root_device:int64
    -> allowed_root_inode:int64
    -> parent_components:string list
    -> parent_device:int64
    -> parent_inode:int64
    -> target_leaf:string
    -> permissions:int
    -> (unit, publication_recovery_fixture_error) result

  val seed_bound_publication_recovery
    :  registry:publication_recovery_registry
    -> owner:string
    -> operation_id:Uuidm.t
    -> allowed_root_path:string
    -> allowed_root_device:int64
    -> allowed_root_inode:int64
    -> parent_components:string list
    -> parent_device:int64
    -> parent_inode:int64
    -> target_leaf:string
    -> permissions:int
    -> stage_device:int64
    -> stage_inode:int64
    -> (unit, publication_recovery_fixture_error) result

  val write_raw_publication_recovery_record
    :  registry:publication_recovery_registry
    -> owner:string
    -> area:publication_recovery_record_area
    -> record_name:string
    -> raw:string
    -> (unit, publication_recovery_fixture_error) result

  val sync_directory_capability
    :  before_stage:(capability_write_stage -> unit)
    -> _ Eio.Path.t
    -> (unit, capability_directory_sync_error) result
end

(** [true] iff [name] matches the canonical [.atomic_*.tmp] pattern produced by
    this module. Exposed for tests and recovery sweeps. *)
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

(** No-follow orphan cleanup. [Directory_only] is bounded by the named
    staging inventory. The broader scope also scans real immediate child
    directories. Every failed mutation or unexpected orphan-shaped entry is
    returned in the typed report. The caller must own stable directory
    identities and quiesce the matching temp namespace; see
    {!Atomic_write.cleanup_atomic_orphans} for the OCaml 5.4 dirfd
    limitation. *)
val cleanup_atomic_orphans
  :  ownership_root:string
  -> base_path:string
  -> scope:atomic_orphan_cleanup_scope
  -> unit
  -> atomic_orphan_cleanup_report

(** Append string to file. *)
val append_file : string -> string -> unit

(** Check if file exists. *)
val file_exists : string -> bool

(** Return file size or None *)
val file_size : string -> int option

(** Return file mtime or None *)
val file_mtime : string -> float option

(** Rename file. *)
val rename : string -> string -> unit

(** [rename_if_exists ~src ~dst] renames [src] to [dst], returning [true]
    on success and [false] if [src] did not exist. Other I/O errors
    propagate as [Sys_error] (Eio.Io is normalized internally, matching
    {!rename}). Both runtime paths recognize the missing-source case
    via typed catches ([Eio.Fs.Not_found] / verified [Sys.file_exists])
    rather than substring matching on the libc message. *)
val rename_if_exists : src:string -> dst:string -> bool

(** Remove directory. *)
val rmdir : string -> unit

(** Remove a file, symlink, or directory tree without invoking a shell.
    Missing paths are ignored.  Symlinks are unlinked, not followed. *)
val remove_tree : string -> unit

(** Get realpath. *)
val realpath : string -> string

(** Create directory recursively. *)
val mkdir_p : string -> unit

(** [mkdir_p_memoized path] is [mkdir_p] but skips the stat/mkdir
    syscalls on every call after the first for the same [path].
    Use on hot append paths (jsonl writers, ledger appends) where the
    same dir is touched many times per second. RFC-0162 §3.1.

    The cache caches only the *fact* of dir existence; no fd is held.
    External processes that delete the dir after first call will see
    silent skip — acceptable for [.masc/] (self-owned). *)
val mkdir_p_memoized : string -> unit

(** Reset the [mkdir_p_memoized] cache. Test-only — production code
    relies on process-lifetime persistence. *)
val reset_mkdir_memo_for_testing : unit -> unit

(** Load JSONL file as list of JSON values.
    Malformed lines are logged and dropped. *)
val load_jsonl : string -> Yojson.Safe.t list

(** Load JSONL file, returning parsed values and count of malformed lines.
    Logs each malformed line with the provided source label. Use when the caller needs
    to surface degraded state (e.g. dashboard malformed_lines field). *)
val load_jsonl_diagnostics : string -> Yojson.Safe.t list * int

(** Parse pre-read string lines as JSONL, returning parsed values and
    malformed count.  [source] is used in log messages.
    Use when lines come from tail-readers or non-file sources. *)
val parse_jsonl_lines : source:string -> string list -> Yojson.Safe.t list * int

(** Stream JSONL line-by-line via [Eio.Buf_read.lines] when the global
    fs is registered, falling back to a raw-line iterator over the
    Stdlib channel otherwise (both branches share the same [line_no]
    counting).  [line_no] is the 1-based index of {b non-blank}
    JSONL rows — blank lines are skipped, malformed lines emit a
    stderr warning and are skipped but {i still consume} the index
    so the counter tracks the printed JSONL row number rather than
    the count of successfully parsed values.  Use when the file may
    be too large to materialize as a list, e.g. audit/metrics JSONL
    on HTTP hot paths.

    Returns [init] when [path] is missing (consistent with
    {!load_jsonl}); raises [Sys_error] on read failures of an
    existing file. *)
val fold_jsonl_lines
  :  init:'acc
  -> f:('acc -> line_no:int -> Yojson.Safe.t -> 'acc)
  -> string
  -> 'acc

(** [fold_appended_lines ~path ~from ~init ~f] folds [f] over the raw
    non-blank, newline-terminated lines whose bytes start at offset
    [from], returning [(acc, boundary)] where [boundary] is the offset
    just past the last ['\n'] consumed.

    Contract for incremental readers over append-only JSONL stores:
    cache [(boundary, acc)] per path and pass the cached [boundary] as
    [from] on the next call — only the appended delta is re-read.
    Bytes after the last ['\n'] (a partially flushed line) are neither
    folded nor included in [boundary], so they are re-read once the
    writer completes the line. A [from] outside [0, file_size] (file
    truncated or rotated) restarts the scan from byte 0. Returns
    [(init, 0)] when [path] does not exist. Lines are raw strings;
    callers parse (and decide how to surface malformed rows). *)
(** [read_slice ~path ~from ~len] returns the byte slice
    [[from, from+len)] of the file, clamped to its current size.
    Missing file or empty clamped range returns [""]. Callers bound
    [len], so one call never scales with file size (RFC-0228 P1). *)
val read_slice : path:string -> from:int -> len:int -> string

val fold_appended_lines
  :  path:string
  -> from:int
  -> init:'acc
  -> f:('acc -> string -> 'acc)
  -> 'acc * int

type durable_append_operation =
  | Write
  | Append_fsync
  | Rollback_truncate
  | Rollback_fsync

type durable_append_failure =
  | Unix_error of
      { operation : durable_append_operation
      ; error : Unix.error
      ; function_name : string
      ; argument : string
      }
  | No_write_progress

type durable_append_error =
  { append_failure : durable_append_failure
  ; rollback_failures : durable_append_failure list
  }

val durable_append_failure_to_string : durable_append_failure -> string

(** Render a structured durable-append failure without discarding the original
    [Unix.error] or rollback failures. *)
val durable_append_error_to_string : durable_append_error -> string

(** [update_private_file_durable_locked_result path decide] serializes in-process
    callers with the shared per-path append mutex, takes a cross-process file
    lock, reads the exact existing bytes, and calls [decide]. [Some suffix]
    appends the complete suffix and fsyncs it before returning [Ok]; [None]
    performs no write. If writing or the append fsync fails, the file is
    truncated to its original length and that rollback is fsynced. [Error]
    preserves the append failure and every rollback failure. Setup, read, and
    [decide] exceptions still propagate. The file is created with mode [0600],
    and every transaction fsyncs its parent directory before touching payload
    bytes so a failed creation can be retried without silently skipping that
    durability boundary. Filesystems that reject directory fsync fail
    explicitly. The shared path mutex serializes this operation with cached
    JSONL writers without closing their already-flushed descriptors. When the
    Eio filesystem is active, the transaction and [decide] run in a system
    thread so a contended file cannot stop unrelated fibers; [decide] therefore
    must not perform Eio effects. *)
val update_private_file_durable_locked_result :
  string -> (string -> string option * 'a) -> ('a, durable_append_error) result

type private_jsonl_append_error =
  | Incomplete_jsonl_tail
  | Invalid_jsonl_suffix
  | Durable_jsonl_append_failed of durable_append_error

(** Append one or more complete JSONL rows without reading the existing file.
    The operation holds the same in-process and cross-process path locks as
    {!update_private_file_durable_locked_result}, verifies only that an existing
    file ends at a newline boundary, then appends and fsyncs with rollback on
    failure. Every transaction also fsyncs the parent directory. Runtime cost
    is proportional to [suffix], not to historical file size. When the Eio
    filesystem is active, the entire blocking lock/write/fsync transaction runs
    in a system thread so one contended file cannot stop unrelated fibers. *)
val append_private_jsonl_durable_locked_result :
  string -> string -> (unit, private_jsonl_append_error) result

val private_jsonl_append_error_to_string : private_jsonl_append_error -> string

type durable_append_io_for_testing =
  { write : Unix.file_descr -> bytes -> int -> int -> int
  ; ftruncate : Unix.file_descr -> int -> unit
  ; fsync : Unix.file_descr -> unit
  }

(** Direct fd-level seam for deterministic partial-write and rollback tests.
    Production code uses the same implementation with [Unix] operations. *)
val append_fd_durable_for_testing :
  io:durable_append_io_for_testing ->
  fd:Unix.file_descr ->
  original_length:int ->
  string ->
  (unit, durable_append_error) result

(** Append JSON value as line to JSONL file.

    Backed by a process-local per-path fd cache (RFC-0162 §3.4).
    Each path keeps one cached [out_channel] reused across appends;
    cross-domain serialization is provided by the same per-path
    mutex registry as [append_file_unix], preserving RFC-0108 §3.2's
    Record-interleave-0 guarantee. The cache is bounded by
    [fd_cache_max=32] with LRU eviction; [close_all_cached_writers]
    is registered at [at_exit]. *)
val append_jsonl : string -> Yojson.Safe.t -> unit

(** [append_jsonl_batch path jsons] writes multiple JSON entries to [path]
    in a single lock+flush cycle. More efficient than calling [append_jsonl]
    repeatedly when batching pending entries. No-op if [jsons] is empty. *)
val append_jsonl_batch : string -> Yojson.Safe.t list -> unit

(** Flush and close every cached [out_channel] held by
    [append_jsonl]. Safe to call concurrently with active appends;
    a subsequent [append_jsonl] re-opens fresh. Intended for
    shutdown sequencing and rare administrative refresh.
    RFC-0162 §3.4. *)
val close_all_cached_writers : unit -> unit

(** [invalidate_cached_writer path] drops the cached [append_jsonl]
    writer for [path] (a no-op if none is cached). Call it after
    replacing the inode at [path] with [save_file_atomic]: the cached
    [O_APPEND] channel still points at the pre-rename inode, so without
    this a later [append_jsonl] would write to the orphaned file.
    Serialization with concurrent [append_jsonl] calls is handled by the
    same per-path append mutex used by the append path. *)
val invalidate_cached_writer : string -> unit

(** Drop and close every cached writer. Test-only — production
    relies on process-lifetime persistence and [at_exit] drain. *)
val reset_fd_cache_for_testing : unit -> unit

(** Lease the cached writer directly. Test-only — production callers
    should use {!append_jsonl} / {!append_jsonl_batch} so directory
    creation, HOME guards, and per-path write serialization stay composed
    at the public append boundary. *)
val with_cached_writer_for_testing : string -> (out_channel -> 'a) -> 'a
