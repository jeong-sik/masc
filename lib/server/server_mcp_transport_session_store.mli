(** Durable, BasePath-scoped state for MCP Streamable HTTP sessions.

    This module is deliberately HTTP-only.  It owns one store handle for one
    server BasePath and must be opened by the HTTP bootstrap switch.  Stdio and
    other transports must not open it: the lifetime file lock rejects a second
    process instead of allowing two writers to share transport state. *)

type t
(** An opaque, BasePath-scoped store.  Its per-session lanes and file lock live until the
    [Eio.Switch.t] supplied to {!open_} is released. *)

type session =
  { session_id : string
  ; protocol_version : string
  ; tool_profile : Server_mcp_transport_http_types.tool_profile
  ; owner : Server_transport_admission.identity
  ; started_at : float
  ; transport_context : Otel_dispatch_hook.transport_context option
  }
(** The complete public transport-session record.  The bearer credential is
    intentionally absent; [owner] is the authenticated identity projection. *)

type tombstone =
  { session_id : string
  ; deleted_at : float
  }

type session_state =
  | Active of session
  | Deleted of tombstone
(** Exact states represented by the versioned per-session JSON format.
    Tombstones are retained so a deleted server-issued id cannot be restored or
    silently reused. *)

type validation_error =
  | Empty_session_id
  | Empty_protocol_version
  | Unsupported_protocol_version of string
  | Empty_owner_agent_name
  | Non_finite_started_at
  | Non_finite_deleted_at

type schema_error =
  | Expected_object of
      { context : string
      }
  | Missing_field of
      { context : string
      ; field : string
      }
  | Duplicate_field of
      { context : string
      ; field : string
      }
  | Unexpected_field of
      { context : string
      ; field : string
      }
  | Invalid_field of
      { context : string
      ; field : string
      ; expected : string
      }
  | Unsupported_schema_version of int
  | Unsupported_state_kind of string
  | Unsupported_tool_profile of string
  | Unsupported_owner_role of string
  | Invalid_session of validation_error
  | Invalid_tombstone of validation_error

type restore_failure =
  | Unexpected_store_entry of
      { entry_name : string
      }
  | Store_entry_not_regular_file of
      { entry_name : string
      }
  | Store_entry_unreadable of
      { path : string
      ; message : string
      }
  | Store_entry_json_invalid of
      { path : string
      ; message : string
      }
  | Store_entry_schema_invalid of
      { path : string
      ; error : schema_error
      }
  | Store_entry_filename_mismatch of
      { path : string
      ; expected_name : string
      ; actual_name : string
      ; session_id : string
      }
  | Duplicate_session_id of
      { session_id : string
      ; path : string
      }
  | Store_temporary_quarantine_failed of
      { path : string
      ; recovery_dir : string
      ; message : string
      }

type open_stage =
  | Create_store_directory
  | Resolve_store_path
  | Validate_store_directory
  | Open_lifetime_lock
  | Acquire_lifetime_lock
  | Validate_lifetime_lock
  | Release_lifetime_lock_after_failure

type open_error =
  | Invalid_base_path
  | Store_locked of
      { lock_path : string
      }
  | Open_filesystem_error of
      { stage : open_stage
      ; path : string
      ; message : string
      }
  | Restore_failed of restore_failure
  | Restore_and_lock_release_failed of
      { restore_failure : restore_failure
      ; lock_path : string
      ; release_message : string
      }

exception Lifetime_lock_release_failed of
  { lock_path : string
  ; message : string
  }
(** Raised from the owning switch's release hook when unlocking or closing the
    lifetime lock fails.  Cleanup failure is never silently discarded. *)

type not_committed_failure =
  { path : string
  ; stage : Fs_compat.Atomic_write.not_committed_stage
  ; message : string
  ; cleanup : Fs_compat.Atomic_write.temporary_cleanup
  }

type durability_unknown_failure =
  { path : string
  ; stage : Fs_compat.Atomic_write.uncertain_commit_stage
  ; message : string
  ; cleanup : Fs_compat.Atomic_write.temporary_cleanup
  }

type mutation_operation =
  | Initialize_session
  | Delete_session
  | Repair_session

type indeterminate_cause =
  | Atomic_commit_unknown of durability_unknown_failure
  | Retry_not_committed of not_committed_failure
  | Recovery_cleanup_failed of
      { temporary_path : string
      ; message : string
      }
  | Unexpected_mutation_failure of
      { message : string
      }

type persistence_indeterminate =
  { session_id : string
  ; operation : mutation_operation
  ; cause : indeterminate_cause
  }
(** A per-session quarantine obligation.  The intended mutation may have
    reached the target namespace but crash durability was not proven, or a
    store-owned temporary artifact could not be cleaned.  Other session lanes
    remain available. *)

type mutation_error =
  | Store_closed
  | Invalid_session_record of validation_error
  | Invalid_delete_request of validation_error
  | Session_already_active of string
  | Session_already_deleted of string
  | Session_unknown of string
  | Session_filename_collision of
      { session_id : string
      ; conflicting_session_id : string
      }
  | Session_lane_unavailable of
      { session_id : string
      ; message : string
      }
  | Persistence_not_committed of not_committed_failure
  | Persistence_indeterminate of persistence_indeterminate
(** [Persistence_not_committed] proves both that namespace replacement was not
    attempted successfully and that no unresolved temporary cleanup obligation
    remains; a fresh DELETE may abort its lifecycle gate.  In contrast,
    [Persistence_indeterminate] keeps only that session quarantined until an
    exact retry or {!repair_pending} reaches durable state. *)

type delete_result =
  | Deleted_now
  | Already_deleted of tombstone

type repair_result =
  | Repaired of session_state
  | Already_stable of session_state

type lookup =
  | Stable_state of session_state
  | Pending_state of
      { intended : session_state
      ; indeterminate : persistence_indeterminate
      }

val open_ :
  sw:Eio.Switch.t -> base_path:string -> (t, open_error) result
(** [open_ ~sw ~base_path] creates/opens the HTTP-only store rooted at the
    explicit [base_path], acquires a non-blocking process-lifetime
    [Unix.lockf Unix.F_TLOCK], and restores every per-session file before
    returning.

    Before restoration, owned [.atomic_*.tmp] artifacts are hard-linked into a
    private, BasePath-derived quarantine directory with both directory fsyncs;
    they are never promoted or silently deleted.  Restoration is then
    all-or-error: unknown files, malformed JSON, unsupported schema values,
    non-regular entries, duplicate ids, or disagreement between a session id
    and its SHA-256 filename reject the whole open.  No partial map is
    published.  Lock contention returns {!Store_locked} immediately;
    there is no retry, environment lookup, or fallback path.

    Cancellation propagates.  Lock cleanup is registered on [sw] immediately
    after acquisition, before restoration begins. *)

val find_active : t -> session_id:string -> session option
(** Lock-free read from the latest immutable Atomic snapshot.  [None] means
    unknown, deleted, or durability-pending; use {!find} for lossless state. *)

val base_path : t -> string
(** The exact explicit BasePath supplied to {!open_}.  Server bootstrap uses
    this accessor to assert that its normalized runtime BasePath and the store
    handle belong to the same boundary. *)

val find : t -> session_id:string -> lookup option
(** Lossless lock-free lookup.  Callers must handle stable and quarantined
    states explicitly; pending state is never projected as active truth. *)

val active_sessions : t -> session list
(** Lock-free, session-id ordered snapshot of active sessions. *)

val pending_sessions : t -> persistence_indeterminate list
(** Ordered snapshot of per-session repair obligations for health and operator
    surfaces. *)

val initialize : t -> session -> (unit, mutation_error) result
(** [initialize t session] validates [session], waits cancellably for the
    session's SHA-keyed Eio lane, then cancellation-protects the exact atomic
    write.  Different sessions never share a mutation lane.  Only a durable
    result publishes active truth; an indeterminate result quarantines the id
    and must not be returned to a client as successful initialization. *)

val delete :
  t -> session_id:string -> deleted_at:float -> (delete_result, mutation_error) result
(** [delete t ~session_id ~deleted_at] runs on that session's lane.  For an
    active id it atomically replaces the per-session file with a durable
    tombstone, then removes the active record from memory and publishes the
    tombstone.  An existing tombstone is idempotent and returned as
    {!Already_deleted}; an unknown id is an explicit error.

    [Persistence_indeterminate] retains the exact intended tombstone and must
    keep that session's lifecycle gate closed without final cleanup.  Retrying
    the same DELETE rewrites that tombstone; only [Deleted_now] permits cleanup.
    [Persistence_not_committed] on a fresh deletion is safe to abort. *)

val repair_pending :
  t -> session_id:string -> (repair_result, mutation_error) result
(** Explicitly retries the exact intended state of a quarantined session,
    including cleanup of store-owned temporary artifacts.  It does not poll,
    schedule itself, or infer a replacement state. *)

val validation_error_to_string : validation_error -> string
val schema_error_to_string : schema_error -> string
val restore_failure_to_string : restore_failure -> string
val open_error_to_string : open_error -> string
val mutation_error_to_string : mutation_error -> string
