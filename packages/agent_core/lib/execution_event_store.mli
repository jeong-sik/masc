(** Crash-durable storage for one recursive execution scope.

    The store is an append-only write-ahead log. A candidate batch is framed as
    [begin; event...; commit]; the final frame is a structural footer, not a
    second commit point. The batch becomes visible only after the complete
    frame group is flushed and the checksum-verified commit authority is
    atomically replaced and directory-synced. That authority is the sole
    visibility SSOT and separates proven committed bytes from an uncommitted
    tail without guessing from EOF shape. The store owns the physical cursor
    and execution-scope identity;
    {!Execution_journal} remains the semantic reducer and topology authority.

    The directory is caller-owned and dedicated to one execution scope. The
    implementation acquires an exclusive writer lock for the lifetime of the
    supplied {!Eio.Switch.t}. Store and writer capabilities are switch-bound;
    after release, every operation that depends on live resources returns
    [Store_released] rather than touching a closed descriptor. The injected
    codec service borrows an {!Execution_runtime.t}; that runtime's
    application-owned switch must be outside and outlive every store switch. *)

module Scope_id : sig
  type t

  val fresh : unit -> (t, string) result
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

type cursor

val make_cursor : scope_id:Scope_id.t -> seq:int -> (cursor, string) result
val cursor_scope_id : cursor -> Scope_id.t
val cursor_seq : cursor -> int
val cursor_to_yojson : cursor -> Yojson.Safe.t
val cursor_of_yojson : Yojson.Safe.t -> (cursor, string) result

type recovery_action =
  | Truncated_uncommitted_tail of
      { committed_offset : int64
      ; removed_bytes : int64
      ; last_committed_seq : int
      }
  | Discarded_uncommitted_authority
  | Rebuilt_initial_authority
[@@deriving show]

type recovery =
  | Clean
  | Recovered of recovery_action list
[@@deriving show]

type initialization =
  | Fresh
  | Recovered_uncommitted_initialization
[@@deriving show]

type append_outcome =
  | Stored
  | Already_committed
[@@deriving show]

type error =
  | Invalid_argument of string
  | Identity_failure of string
  | Io_failure of
      { operation : string
      ; detail : string
      }
  | Codec_failure of Execution_codec_executor.failure
  | Writer_already_active
  | Store_already_attached
  | Store_released
  | Store_release_forbidden
  | Resource_cleanup_failed of { operations : string list }
  | Construction_cleanup_failed of
      { primary : error
      ; cleanup : error
      }
  | Store_already_exists
  | Store_not_found
  | Store_initialization_incomplete
  | Store_initialization_conflict
  | Unsupported_store_version of
      { expected : int
      ; actual : int
      }
  | Corrupt_store of
      { offset : int64
      ; detail : string
      }
  | Correlation_mismatch
  | Sequence_conflict of
      { expected_next_seq : int
      ; actual_next_seq : int
      }
  | Committed_content_conflict of
      { first_seq : int
      ; last_seq : int
      }
  | Cursor_scope_mismatch
  | Cursor_ahead of
      { after_seq : int
      ; high_watermark : int
      }
  | Commit_authority_identity_changed
  | Commit_authority_regressed of
      { previous_committed_offset : int64
      ; actual_committed_offset : int64
      ; previous_last_seq : int
      ; actual_last_seq : int
      }
  | Store_poisoned of string
  | Commit_outcome_unknown of string
[@@deriving show]

val error_to_string : error -> string

type t
type writer

type opened = private
  { store : t
  ; recovery : recovery
  ; replay_events : Execution_event.t list
  }

(** One immutable read-only view of the atomic commit authority. It owns no
    writer claim and never repairs, truncates, renames, or syncs store files.
    [appended_events] is decoded only from the exact authority-bound WAL
    prefix. *)
type read_only_snapshot = private
  { scope_id : Scope_id.t
  ; correlation_id : Execution_event.Correlation_id.t
  ; committed_offset : int64
  ; last_seq : int
  ; appended_events : Execution_event.t list
  }

(** Capture the current committed prefix without acquiring writer authority.
    Supplying [previous] avoids rescanning the already validated prefix;
    [appended_events] then contains only the newly committed suffix (and all
    events for the initial snapshot). Authority identity changes or
    regressions are rejected rather than interpreted as a new scope.
    Non-authoritative WAL and authority tails are ignored and never modified. *)
val read_only_snapshot
  :  codec:Execution_codec_executor.t
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> ?previous:read_only_snapshot
  -> unit
  -> (read_only_snapshot, error) result

(** [create ~sw ~codec ~dir ()] creates a new store inside an existing caller-owned
    directory. It never creates the directory, opens an existing WAL, or
    truncates committed data. The initial metadata frame and matching commit
    authority are directory-durable before the function returns. A failure
    after the WAL rename is surfaced as [Commit_outcome_unknown] and is
    reconciled by [open_existing], never by blind create retry. *)
val create
  :  sw:Eio.Switch.t
  -> codec:Execution_codec_executor.t
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> ?correlation_id:Execution_event.Correlation_id.t
  -> unit
  -> (t * initialization, error) result

(** [open_existing ~sw ~codec ~dir] validates the complete authority-bound prefix and
    rebuilds the immutable physical event index before modifying any bytes.
    Bytes beyond the validated authority are truncated and reported through
    [recovery]. An incomplete or corrupt frame inside the authoritative prefix
    is rejected and is never silently truncated. [replay_events] is the exact
    immutable decode artifact from that same validation pass; journal recovery
    consumes it directly rather than decoding the WAL a second time. *)
val open_existing
  :  sw:Eio.Switch.t
  -> codec:Execution_codec_executor.t
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> (opened, error) result

val scope_id : t -> Scope_id.t
val correlation_id : t -> Execution_event.Correlation_id.t
val last_seq : t -> (int, error) result
val beginning_cursor : t -> cursor
val current_cursor : t -> (cursor, error) result

(** Release a store that its construction wrapper failed to publish. This is
    idempotent with the owning switch's later cleanup and exists only so a
    higher-level atomic constructor cannot leak the writer claim on replay or
    semantic initialization failure. Published stores must remain owned by
    their switch. *)
val release_unpublished : t -> (unit, error) result

(** Mint the store's sole semantic append capability. A store can be attached
    to exactly one journal for its lifetime. Read projections continue to use
    [t] and cannot append. *)
val attach : t -> (writer, error) result

(** Append one semantic mutation batch. The first event sequence must equal
    [expected_next_seq], all event sequences must be contiguous, and every
    event must use this store's correlation identity.

    Repeating an already committed, byte-identical batch returns
    [Already_committed]. Any overlap with different canonical event bytes is a
    typed conflict. [Commit_outcome_unknown] forbids blind retry: release this
    store and call [open_existing] to reconcile the authority before deciding
    whether an exact retry is already committed. Once this outcome occurs, the
    live store remains fenced with the same typed reconciliation requirement;
    later calls cannot downgrade it to a generic poisoned-store error.

    Canonical encoding, indexing, and write-fence validation run outside the
    protected phase, with an explicit cancellation check immediately before
    mutation. Once physical WAL mutation starts, recoverable failures produce
    a definite [Stored] result or a typed error; parent cancellation cannot
    split WAL durability, authority replacement, and immutable in-memory
    publication. Reserved runtime exceptions still propagate. If one escapes
    after authority replacement starts, the implementation attempts to fence
    the live store without hiding the exception; callers must release it and
    reopen for explicit reconciliation regardless. *)
val append_batch
  :  writer
  -> expected_next_seq:int
  -> Execution_event.t list
  -> (append_outcome, error) result

type page = private
  { events : Execution_event.t list
  ; next_cursor : cursor
  ; high_watermark : cursor
  ; earliest_available_seq : int option
  ; has_more : bool
  }

(** Read at most [limit] events after [cursor]. Without [through], the call
    captures the current high watermark. Passing a previously returned
    [high_watermark] as [through] freezes every later page to the same snapshot
    while concurrent appends continue beyond it. [limit] controls page size
    only and never execution admission or termination. Physical event offsets
    are indexed at open/append time, so a page does not scan the WAL prefix. *)
val read_page
  :  t
  -> after:cursor
  -> ?through:cursor
  -> limit:int
  -> unit
  -> (page, error) result
