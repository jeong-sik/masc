(** Capability-relative, one-row durable HEAD authority.

    HEAD is the only content authority. The stable lock contains only an
    immutable random fencing epoch and is never rewritten, renamed, or deleted.
    This surface deliberately exposes no append, scan, fallback, repair, delete,
    or migration operation.

    The parent namespace must be private to cooperating callers. Direct unlink
    or replacement outside this surface is out of contract: remembering such a
    deletion would require a second persistent freshness authority, which this
    single-authority API intentionally rejects. The sibling namespace prefix
    [.masc-capability-head-] is reserved for stable locks and publication stages;
    public [leaf] values beginning with it are rejected with [Invalid_leaf]. *)

val max_row_bytes : int

type cursor
type operation =
  | Pin_parent
  | Open_lock
  | Acquire_cross_process_lock
  | Read_lock_marker
  | Initialize_lock_marker
  | Read_head
  | Create_stage
  | Write_stage
  | Sync_stage
  | Close_stage
  | Revalidate
  | Rename_head
  | Sync_parent
  | Verify_publication
  | Cleanup_stage
  | Settle_resources

type diagnostic =
  { operation : operation
  ; detail : string
  }

type settlement_warning =
  | Cleanup_failed of diagnostic
  | Resource_settlement_failed of diagnostic

type snapshot

val snapshot_row : snapshot -> string option
val snapshot_cursor : snapshot -> cursor
val snapshot_settlement_warnings : snapshot -> settlement_warning list

type error =
  | Invalid_leaf of string
  | Invalid_row of string
  | Busy
  | Conflict of snapshot
  | Corrupt_lock of string
  | Corrupt_head of string
  | Unsupported of string
  | Io_error of diagnostic

(** In publication evidence, [intended_sha256] is the 64-character lowercase
    SHA-256 hex digest and [intended_length] is the byte length of the exact
    on-disk HEAD payload [row || 0x0A]. They do not describe [row] before LF
    framing. *)
type publication_evidence =
  { expected_cursor : cursor
  ; intended_sha256 : string
  ; intended_length : int64
  ; published_cursor : cursor
  }

(** [intended_sha256] and [intended_length] have the same wire-payload
    definition as in {!publication_evidence}: lowercase SHA-256 hex and byte
    length over [row || 0x0A]. *)
type publication_indeterminate =
  { expected_cursor : cursor
  ; intended_sha256 : string
  ; intended_length : int64
  ; observed : cursor option
  }

type target_effect =
  | Unchanged
  | Published of publication_evidence
  | Publication_indeterminate of publication_indeterminate

type failure = private
  { error : error
  ; target_effect : target_effect
  ; settlement_warnings : settlement_warning list
  }

type publication

val publication_evidence : publication -> publication_evidence
val publication_settlement_warnings : publication -> settlement_warning list

val read :
  secure_random:Eio.Flow.source_ty Eio.Resource.t ->
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  leaf:string ->
  (snapshot, failure) result

(** Pending caller cancellation is checked before dispatch. Once the protected
    transaction begins, parent cancellation is deferred until one typed
    publication outcome is settled; no cancellation check occurs after
    publication. *)
val compare_and_swap :
  secure_random:Eio.Flow.source_ty Eio.Resource.t ->
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  leaf:string ->
  expected:cursor ->
  row:string ->
  (publication, failure) result

module For_testing : sig
  type hooks

  val hooks :
    ?after_lock_acquired:(unit -> unit) ->
    ?before_rename:(unit -> unit) ->
    ?after_rename:(unit -> unit) ->
    ?after_parent_sync:(unit -> unit) ->
    ?after_verified:(unit -> unit) ->
    ?before_stage_cleanup:(unit -> unit) ->
    ?on_resource_settlement:(unit -> unit) ->
    unit ->
    hooks

  val compare_and_swap :
    hooks ->
    secure_random:Eio.Flow.source_ty Eio.Resource.t ->
    parent:Eio.Fs.dir_ty Eio.Path.t ->
    leaf:string ->
    expected:cursor ->
    row:string ->
    (publication, failure) result
end
