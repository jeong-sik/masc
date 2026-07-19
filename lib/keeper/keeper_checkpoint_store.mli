(** Keeper checkpoint store — OAS checkpoint persistence, OAS
    history archive, and SDK error classification. *)

(** Path of the canonical OAS checkpoint file
    [session_dir/<session_id>.json]. *)
val oas_checkpoint_path :
  session_dir:string -> session_id:string -> string

(** [oas-snapshot-] prefix on OAS history archive entries. *)
val oas_history_prefix : string

(** [.json] suffix on OAS history archive entries. *)
val oas_history_suffix : string

(** [true] iff [filename] is an OAS history archive file. *)
val is_oas_history_file : string -> bool

(** Sorted-descending list of OAS history archive filenames in
    [session_dir]. *)
val list_oas_history_files : session_dir:string -> string list

(** Number of OAS history archive entries retained after a save. *)
val max_oas_history_retained : int

(** Path of an OAS history archive entry within [session_dir]. *)
val oas_history_path :
  session_dir:string -> snapshot_id:string -> string

(** Session-scoped context key carrying the keeper generation on a
    checkpoint. Single definition of the wire literal; every writer and
    reader (context core, tests) must reference this value so the key
    cannot drift between sites. *)
val keeper_generation_context_key : string

(** Compose an OAS history archive snapshot id from a checkpoint
    (created_at_ms + keeper_generation suffix). *)
val oas_history_snapshot_id_of_checkpoint :
  Agent_sdk.Checkpoint.t -> string

(** Save [ckpt] to the OAS history archive in [session_dir],
    pruning to [max_oas_history_retained] entries. Logs and
    swallows write failures. *)
val save_oas_history :
  session_dir:string -> Agent_sdk.Checkpoint.t -> unit

(** Delete OAS history archive entries by [snapshot_ids]. Returns
    [(deleted, missing)] in input-order, with [missing] containing
    every snapshot id whose file was absent OR removal failed. An id
    that is not one real path segment (empty / "." / ".." / separator /
    NUL) can never name a history entry and is reported [missing]
    without touching the filesystem. *)
val delete_oas_history_files :
  session_dir:string ->
  snapshot_ids:string list ->
  string list * string list

(** Relation between an incoming checkpoint and the current known high
    watermark for the same canonical OAS checkpoint path. *)
type save_oas_relation = [ `Cold | `Forward | `Equal ]

(** Classified checkpoint save result.

    [Stale_noop] is a successful no-op: the canonical checkpoint was left
    untouched because accepting [incoming_turn_count] would move memory
    behind the known high watermark. It must not be treated as keeper
    turn failure, pause, or stop. *)
type save_oas_outcome =
  | Saved of { relation : save_oas_relation; turn_count : int }
  | Stale_noop of { incoming_turn_count : int; known_turn_count : int }

(** Save [ckpt] in one locked disk-SSOT transaction. A missing [session_dir]
    is created by the durable writer, retaining the public create-first contract.
    [Saved] means payload, rename, and parent-directory fsync succeeded; history
    is observed best effort.

    RFC-0225 §3.2 checkpoint watermark: returns [Ok Stale_noop] when
    [ckpt.turn_count] is older than the canonical checkpoint currently on disk.
    A stale writer must not clobber a conversation the newer writer already
    persisted, but this is not a keeper lifecycle failure. Equal turn_count
    re-saves pass. A corrupt or unreadable existing checkpoint fails closed and
    is never treated as a cold store. *)
val save_oas_classified :
  session_dir:string ->
  Agent_sdk.Checkpoint.t ->
  (save_oas_outcome, string) result

(** Run [f] under the stable checkpoint lock for [session_dir]. The lock inode
    is a sibling of the session subtree, so deleting/recreating that subtree
    cannot replace it. [f] receives the canonical session location used to
    derive the lock, keeping the lock and mutation on one path identity. *)
val with_session_lock :
  session_dir:string -> (string -> 'a) -> ('a, string) result

(** Load failure classification used by callers to distinguish
    cold-start absence from real I/O / parse / SDK errors. *)
type checkpoint_load_error =
  | Not_found
  | Store_error of string
  | Parse_error of string
  | Io_error of string
  | Sdk_other_error of string

(** Project an [Agent_sdk.Error.sdk_error] to [checkpoint_load_error].

    RFC-0089 G4: this no longer classifies [Not_found] from string-matched
    [FileOpFailed.detail]. Cold-start "checkpoint absent" is detected at
    the OS boundary via a typed [Fs_compat.file_exists] check *before* any
    load, so any [sdk_error] reaching this function is a real
    I/O / parse / SDK fault and routes accordingly. *)
val classify_sdk_error :
  Agent_sdk.Error.sdk_error -> checkpoint_load_error

(** Load a single OAS history archive entry. Returns [Not_found]
    when the file does not exist or [snapshot_id] is not one real path
    segment (such an id can never name a history entry); classifies SDK
    errors via [classify_sdk_error]. *)
val load_oas_history_file :
  session_dir:string ->
  snapshot_id:string ->
  (Agent_sdk.Checkpoint.t, checkpoint_load_error) result

(** Load the canonical OAS checkpoint for [session_id]. One read path
    for Eio and non-Eio contexts: presence is a typed
    [Fs_compat.file_exists] check, the read is Eio-native when the fs
    capability is installed, and the JSON decode runs off the calling
    fiber. A [session_id] that is not one real path segment is refused
    as [Store_error] (the same rejection the SDK store applied). *)
val load_oas :
  session_dir:string ->
  session_id:string ->
  (Agent_sdk.Checkpoint.t, checkpoint_load_error) result

type checkpoint_identity_error =
  | Session_id_invalid of string
  | Generation_missing
  | Generation_not_integer
  | Ref_create_failed of Keeper_checkpoint_ref.create_error

type checkpoint_ref_load_error =
  | Ref_not_found
  | Ref_read_failed of checkpoint_load_error
  | Ref_identity_invalid of checkpoint_identity_error
  | Ref_session_mismatch of
      { expected : Keeper_id.Trace_id.t
      ; actual : Keeper_id.Trace_id.t
      }
  | Ref_lock_failed of string

(** Canonical checkpoint value, exact persisted bytes, and their reference
    derived from one immutable byte snapshot. *)
type exact_checkpoint_snapshot

val exact_snapshot_checkpoint :
  exact_checkpoint_snapshot -> Agent_sdk.Checkpoint.t

val exact_snapshot_reference :
  exact_checkpoint_snapshot -> Keeper_checkpoint_ref.t

val exact_snapshot_canonical_bytes : exact_checkpoint_snapshot -> string

(** Strictly decode exact canonical bytes and derive their reference without
    re-encoding. [generation_fallback] recovers identity for a pre-#25046
    checkpoint whose persisted context lacks [keeper_generation]: it is used
    only when the key is absent ([Generation_missing]), never when it is
    present-but-malformed, and never on the save path (#25217). *)
val exact_snapshot_of_canonical_bytes :
  ?generation_fallback:int ->
  expected_session_id:Keeper_id.Trace_id.t ->
  string ->
  (exact_checkpoint_snapshot, checkpoint_ref_load_error) result

(** Load an exact canonical checkpoint snapshot under the session lock.
    See {!exact_snapshot_of_canonical_bytes} for [generation_fallback]. *)
val load_oas_exact_snapshot :
  ?generation_fallback:int ->
  session_dir:string ->
  session_id:string ->
  unit ->
  (exact_checkpoint_snapshot, checkpoint_ref_load_error) result

(** Load one canonical checkpoint and its exact source identity from the same
    locked byte snapshot. No size, mtime, timestamp, or process cache
    participates in the identity. See {!exact_snapshot_of_canonical_bytes}
    for [generation_fallback]. *)
val load_oas_with_ref :
  ?generation_fallback:int ->
  session_dir:string ->
  session_id:string ->
  unit ->
  ( Agent_sdk.Checkpoint.t * Keeper_checkpoint_ref.t
  , checkpoint_ref_load_error )
  result

type checkpoint_cas_error =
  | Source_unavailable of checkpoint_ref_load_error
  | Source_changed of Keeper_checkpoint_ref.t
  | Candidate_identity_invalid of checkpoint_identity_error
  | Candidate_session_mismatch of
      { expected : Keeper_id.Trace_id.t
      ; candidate : Keeper_id.Trace_id.t
      }
  | Candidate_generation_mismatch of
      { expected : int
      ; candidate : int
      }
  | Candidate_turn_regressed of
      { source_turn : int
      ; candidate_turn : int
      }
  | Commit_not_installed of Keeper_fs.durable_write_error
  | Commit_durability_unknown of
      { installed_ref : Keeper_checkpoint_ref.t
      ; error : Keeper_fs.durable_write_error
      }
  | Transaction_outcome_unknown of
      { possible_installed_ref : Keeper_checkpoint_ref.t
      ; error : File_lock_eio.durable_lock_error
      }

(** Conditionally publish [candidate] only when the canonical bytes still
    have exactly [expected_source_ref]. The stable session lock is reacquired,
    current bytes are re-read and hashed, and an equal-turn checkpoint with
    different content is rejected as [Source_changed]. On success the returned
    ref is derived from the exact compact bytes passed to the durable atomic
    JSON writer. A writer error after atomic rename is
    [Commit_durability_unknown], never a retryable not-installed failure. This
    same rule applies when releasing the stable lock fails after the body:
    [Transaction_outcome_unknown] requires reconciliation rather than retry. The
    payload-store commit is not an operation terminal fact; the Keeper operation
    journal owns that authority. *)
val save_oas_if_source :
  ?generation_fallback:int ->
  session_dir:string ->
  expected_source_ref:Keeper_checkpoint_ref.t ->
  Agent_sdk.Checkpoint.t ->
  (Keeper_checkpoint_ref.t, checkpoint_cas_error) result
(** [generation_fallback] is used for the CAS source reread of a pre-#25046
    checkpoint (no [keeper_generation]); it must match the fallback used to
    build [expected_source_ref]. The candidate is always built strictly from
    its own generation, so the write invariant is unchanged (#25217). *)
