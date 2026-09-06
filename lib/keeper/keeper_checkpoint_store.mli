(** Keeper checkpoint store — AGENT_CORE checkpoint persistence, AGENT_CORE
    history archive, and agent-core error classification. *)

(** Path of the canonical AGENT_CORE checkpoint file
    [session_dir/<session_id>.json]. *)
val agent_core_checkpoint_path :
  session_dir:string -> session_id:string -> string

(** [agent-core-snapshot-] prefix on AGENT_CORE history archive entries. *)
(** [.json] suffix on AGENT_CORE history archive entries. *)
(** [true] iff [filename] is an AGENT_CORE history archive file. *)
(** Sorted-descending list of AGENT_CORE history archive filenames in
    [session_dir]. *)
val list_agent_core_history_files : session_dir:string -> string list

(** Number of AGENT_CORE history archive entries retained after a save. *)
(** Path of an AGENT_CORE history archive entry within [session_dir]. *)
val agent_core_history_path :
  session_dir:string -> snapshot_id:string -> string

(** Compose an AGENT_CORE history archive snapshot id from a checkpoint
    (created_at_ms + keeper_generation suffix). *)
val agent_core_history_snapshot_id_of_checkpoint :
  Agent_core.Checkpoint.t -> string

(** Delete AGENT_CORE history archive entries by [snapshot_ids]. Returns
    [(deleted, missing)] in input-order, with [missing] containing
    every snapshot id whose file was absent OR removal failed. An id
    that is not one real path segment (empty / "." / ".." / separator /
    NUL) can never name a history entry and is reported [missing]
    without touching the filesystem. *)
val delete_agent_core_history_files :
  session_dir:string ->
  snapshot_ids:string list ->
  string list * string list

(** Relation between an incoming checkpoint and the current known high
    watermark for the same canonical AGENT_CORE checkpoint path. *)
type save_agent_core_relation = [ `Cold | `Forward | `Equal ]

(** Classified checkpoint save result.

    [Stale_noop] is a successful no-op: the canonical checkpoint was left
    untouched because accepting [incoming_turn_count] would move memory
    behind the known high watermark. It must not be treated as keeper
    turn failure, pause, or stop. *)
type save_agent_core_outcome =
  | Saved of { relation : save_agent_core_relation; turn_count : int }
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
val save_agent_core_classified :
  session_dir:string ->
  Agent_core.Checkpoint.t ->
  (save_agent_core_outcome, string) result

(** Run [f] under the stable checkpoint lock for [session_dir]. The lock inode
    is a sibling of the session subtree, so deleting/recreating that subtree
    cannot replace it. [f] receives the canonical session location used to
    derive the lock, keeping the lock and mutation on one path identity. *)
val with_session_lock :
  session_dir:string -> (string -> 'a) -> ('a, string) result

(** Load failure classification used by callers to distinguish
    cold-start absence from real I/O / parse / agent-core errors. *)
type checkpoint_load_error =
  | Not_found
  | Store_error of string
  | Parse_error of string
  | Io_error of string
  | Agent_core_error of string

val checkpoint_load_error_to_string : checkpoint_load_error -> string

(** Project an [Agent_core.Error.t] to [checkpoint_load_error].

    RFC-0089 G4: this no longer classifies [Not_found] from string-matched
    [FileOpFailed.detail]. Cold-start "checkpoint absent" is detected at
    the OS boundary via a typed [Fs_compat.file_exists] check *before* any
    load, so any [core_error] reaching this function is a real
    I/O / parse / agent-core fault and routes accordingly. *)
val classify_core_error :
  Agent_core.Error.t -> checkpoint_load_error

(** Load a single AGENT_CORE history archive entry. Returns [Not_found]
    when the file does not exist or [snapshot_id] is not one real path
    segment (such an id can never name a history entry); classifies Agent Core
    errors via [classify_core_error]. *)
val load_agent_core_history_file :
  session_dir:string ->
  snapshot_id:string ->
  (Agent_core.Checkpoint.t, checkpoint_load_error) result

(** Load the canonical AGENT_CORE checkpoint for [session_id]. One read path
    for Eio and non-Eio contexts: presence is a typed
    [Fs_compat.file_exists] check, the read is Eio-native when the fs
    capability is installed, and the JSON decode runs off the calling
    fiber. A [session_id] that is not one real path segment is refused
    as [Store_error] (the same rejection agent core store applied). *)
val load_agent_core :
  session_dir:string ->
  session_id:string ->
  (Agent_core.Checkpoint.t, checkpoint_load_error) result

(** Message count of the canonical checkpoint for [session_id]. Answered
    without reading the file while the file on disk is the one the store's
    canonical summary was taken from (a parse or a write by this process);
    otherwise the checkpoint is loaded and parsed once. [Ok None] when there
    is no checkpoint. *)
val canonical_message_count :
  session_dir:string ->
  session_id:string ->
  (int option, checkpoint_load_error) result

(** Byte length of the canonical checkpoint file for [session_id]: the
    summary's identity while the file on disk is the one this process last
    parsed or wrote, otherwise one [stat]. [Ok None] when there is no
    checkpoint. This is the size of the durable checkpoint, not a token
    estimate and not a provider request size. *)
val canonical_byte_count :
  session_dir:string ->
  session_id:string ->
  (int option, checkpoint_load_error) result

type checkpoint_identity_error =
  | Session_id_invalid of string
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

val exact_snapshot_reference :
  exact_checkpoint_snapshot -> Keeper_checkpoint_ref.t

val exact_snapshot_canonical_bytes : exact_checkpoint_snapshot -> string

(** Strictly decode exact canonical bytes and derive their reference without
    re-encoding. *)
val exact_snapshot_of_canonical_bytes :
  expected_session_id:Keeper_id.Trace_id.t ->
  string ->
  (exact_checkpoint_snapshot, checkpoint_ref_load_error) result

(** Load an exact canonical checkpoint snapshot under the session lock. *)
val load_agent_core_exact_snapshot :
  session_dir:string ->
  session_id:string ->
  (exact_checkpoint_snapshot, checkpoint_ref_load_error) result

(** Load one canonical checkpoint and its exact source identity from the same
    locked byte snapshot. No size, mtime, timestamp, or process cache
    participates in the identity. *)
val load_agent_core_with_ref :
  session_dir:string ->
  session_id:string ->
  ( Agent_core.Checkpoint.t * Keeper_checkpoint_ref.t
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

type checkpoint_installation_auxiliary =
  | Commit_durability_unknown of Keeper_fs.durable_write_error
  | Commit_observer_failed of Eio.Exn.with_bt
  | Release_process_lock_failed of File_lock_eio.durable_lock_error
  | Post_commit_unwind_interrupted of Eio.Exn.with_bt
  | History_write_failed of Eio.Exn.with_bt

type not_installed_checkpoint =
  { cause : checkpoint_cas_error
  ; auxiliary : checkpoint_installation_auxiliary list
  }

type installed_checkpoint =
  { installed_ref : Keeper_checkpoint_ref.t
  ; auxiliary : checkpoint_installation_auxiliary list
  }

type checkpoint_installation =
  | Not_installed of not_installed_checkpoint
  | Installed of installed_checkpoint

(** Conditionally publish [candidate] only when the canonical bytes still
    have exactly [expected_source_ref]. The stable session lock is reacquired,
    current bytes are re-read and hashed, and an equal-turn checkpoint with
    different content is rejected as [Source_changed]. On success the returned
    ref is derived from the exact compact bytes passed to the durable atomic
    JSON writer. A writer error after atomic rename is an [Installed] result
    carrying [Commit_durability_unknown], never a retryable not-installed
    failure. Releasing the stable lock cannot replace the already-computed body
    result: [Not_installed] retains its exact cause and [Installed] retains its
    exact reference, with [Release_process_lock_failed] appended as auxiliary
    evidence in either case.
    The payload-store commit is not an operation terminal fact; the Keeper
    operation journal owns that authority.

    The closed result distinguishes [Not_installed] from [Installed].
    Observer, release-lock, unwind, and history failures after durable commit
    remain typed [auxiliary] facts beside the exact installed reference; they
    never become install failures or retry signals. An exception before commit
    is re-raised with its original raw backtrace. *)
val save_agent_core_if_source :
  session_dir:string ->
  expected_source_ref:Keeper_checkpoint_ref.t ->
  Agent_core.Checkpoint.t ->
  checkpoint_installation

module For_testing : sig
  val save_agent_core_if_source_with_observer :
    on_checkpoint_commit_observer:(Keeper_checkpoint_ref.t -> unit) ->
    session_dir:string ->
    expected_source_ref:Keeper_checkpoint_ref.t ->
    Agent_core.Checkpoint.t ->
    checkpoint_installation

  val save_agent_core_if_source_with_release_failure :
    release_failure:File_lock_eio.durable_lock_error ->
    on_checkpoint_commit_observer:(Keeper_checkpoint_ref.t -> unit) ->
    session_dir:string ->
    expected_source_ref:Keeper_checkpoint_ref.t ->
    Agent_core.Checkpoint.t ->
    checkpoint_installation

  val save_agent_core_if_source_with_acquire_failure :
    acquire_failure:File_lock_eio.durable_lock_error ->
    on_checkpoint_commit_observer:(Keeper_checkpoint_ref.t -> unit) ->
    session_dir:string ->
    expected_source_ref:Keeper_checkpoint_ref.t ->
    Agent_core.Checkpoint.t ->
    checkpoint_installation

  val save_agent_core_if_source_with_writer :
    write_checkpoint_bytes:
      (on_durable_commit:(unit -> unit) ->
       ownership_root:string ->
       path:string ->
       bytes:string ->
       (Keeper_fs.durable_commit_outcome, Keeper_fs.durable_write_error) result) ->
    on_checkpoint_commit_observer:(Keeper_checkpoint_ref.t -> unit) ->
    session_dir:string ->
    expected_source_ref:Keeper_checkpoint_ref.t ->
    Agent_core.Checkpoint.t ->
    checkpoint_installation

  val save_agent_core_if_source_with_post_commit_unwind :
    post_commit_unwind:(unit -> unit) ->
    on_checkpoint_commit_observer:(Keeper_checkpoint_ref.t -> unit) ->
    session_dir:string ->
    expected_source_ref:Keeper_checkpoint_ref.t ->
    Agent_core.Checkpoint.t ->
    checkpoint_installation
end
