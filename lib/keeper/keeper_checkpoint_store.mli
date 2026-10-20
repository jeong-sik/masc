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

(** One input-ordered result from an explicit history deletion request. *)
type history_delete_result =
  | History_deleted of string
  | History_missing of string
  | History_refused of string
  | History_removal_failed of string

(** Delete AGENT_CORE history archive entries by [snapshot_ids]. The result
    keeps an absent file, a filename outside the exact producer contract, and
    a failed removal distinct. *)
val delete_agent_core_history_files :
  session_dir:string ->
  snapshot_ids:string list ->
  history_delete_result list

(** Relation between an incoming checkpoint and the current known high
    watermark for the same canonical AGENT_CORE checkpoint path. *)
type save_agent_core_relation = [ `Cold | `Forward | `Equal ]

(** Classified checkpoint save result.

    [Stale_noop] is a successful no-op: the canonical checkpoint was left
    untouched because accepting [incoming_turn_count] would move memory
    behind the known high watermark. It must not be treated as keeper
    turn failure, pause, or stop. *)
type save_agent_core_outcome =
  | Saved of
      { relation : save_agent_core_relation
      ; turn_count : int
      ; canonical_bytes : int
      }
  | Stale_noop of { incoming_turn_count : int; known_turn_count : int }

(** Save [ckpt] in one locked disk-SSOT transaction. A missing [session_dir]
    is created by the durable writer, retaining the public create-first contract.
    [Saved] means payload, rename, and parent-directory fsync succeeded; history
    is observed best effort. [canonical_bytes] is the size of the file the save
    wrote, from that file's descriptor.

    [history_retained] is how many past checkpoints to leave beside the
    canonical one; zero writes no history at all. The caller reads it from
    [Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained] on
    its own fiber -- this store is also reachable from a raw Domain, where
    taking the settings mutex raises, so it never reads the setting itself.

    RFC-0225 §3.2 checkpoint watermark: returns [Ok Stale_noop] when
    [ckpt.turn_count] is older than the canonical checkpoint currently on disk.
    A stale writer must not clobber a conversation the newer writer already
    persisted, but this is not a keeper lifecycle failure. Equal turn_count
    re-saves pass. A corrupt or unreadable existing checkpoint fails closed and
    is never treated as a cold store.

    This save keeps nothing for the next one: it encodes the whole checkpoint.
    A Keeper's own saves use {!save_agent_core_for_keeper}. *)
val save_agent_core_classified :
  session_dir:string ->
  history_retained:int ->
  Agent_core.Checkpoint.t ->
  (save_agent_core_outcome, string) result

(** {!save_agent_core_classified} for a save of [keeper_name]'s own
    checkpoint. Saves of one canonical file share the store's encoding memo for
    it, so a save encodes only the messages that no earlier save in this
    process wrote and no {!load_agent_core_for_save} read
    ({!Agent_core.Checkpoint.to_pieces_with_encoding_memo}). After the save, a
    load answers from the decode of the written bytes while the file keeps the
    identity sampled after the write. The Keeper is named here because a
    checkpoint's [agent_name] names the runtime its turn ran on. *)
val save_agent_core_for_keeper :
  keeper_name:string ->
  session_dir:string ->
  history_retained:int ->
  Agent_core.Checkpoint.t ->
  (save_agent_core_outcome, string) result

(** Run [f] under the stable checkpoint lock for [session_dir]. The lock inode
    is a sibling of the session subtree, so deleting/recreating that subtree
    cannot replace it. [f] receives the canonical session location used to
    derive the lock, keeping the lock and mutation on one path identity. *)
val with_session_lock :
  session_dir:string -> (string -> 'a) -> ('a, string) result

(** Why reading the bytes failed, when the failure says nothing about what
    the file holds. *)
type checkpoint_read_failure =
  | Os_error of Unix.error  (** An open, stat or read syscall failed. *)
  | Changed_while_read  (** The file or its directory changed during the read. *)
  | Read_raised  (** The read or decode raised an exception. *)

(** Load failure classification used by callers to distinguish
    cold-start absence from real I/O / parse / agent-core errors. *)
type checkpoint_load_error =
  | Not_found
  | Store_error of string
  | Parse_error of string
  (** A canonical this binary recognises as an earlier [checkpoint_version].
      Apart from [Parse_error] because the two need opposite answers: a
      superseded canonical is replaceable, a corrupt one is not. *)
  | Superseded_version of { expected : int; got : int }
  (** A canonical a later [checkpoint_version] wrote: an older binary is
      reading a newer workspace. Nothing here replaces or deletes it, because
      the newer binary can still read it. The codec checks the version before
      it decodes anything else, so a later build's file lands here whenever
      that build bumped [checkpoint_version]. A codec change shipped without
      a bump reads as [Parse_error] instead, and the clear deletes it
      (#38680). *)
  | Newer_version of { expected : int; got : int }
  | Io_error of string
      (** From {!load_agent_core}: the path is not a regular file, or lies
          outside the owned directory chain, so nothing was read. Elsewhere it
          also carries OS read failures: the canonical read under a save or a
          retained-reference lookup, an exception in
          {!load_agent_core_history_file}, and {!classify_core_error} of an
          agent-core [FileOpFailed]. Only from {!load_agent_core} does it mean
          the path, not the read, is at fault. *)
  | Read_failed of { cause : checkpoint_read_failure; detail : string }
      (** The owned-file read behind {!load_agent_core} and
          {!load_agent_core_history_file} failed itself; the same bytes may
          read fine next time. The other readers report this as [Io_error]. *)
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

(** Load the canonical AGENT_CORE checkpoint for [session_id]. While the file
    has the (device, inode, size, mtime) it had when {!save_agent_core_for_keeper}
    in this process wrote it, or when {!load_agent_core_for_save} read it, the
    answer is the value kept then and the file is not read; the [context] is a
    fresh copy. Such an answer
    also skips the owner and mode checks of the read: a chmod, chown or hard
    link leaves the identity as it was, and the value is what this process
    wrote or read, not what the file holds now. Otherwise one read path for Eio
    and non-Eio contexts: the owned-file read distinguishes an absent file from
    a read failure, and the read and JSON decode run off the calling fiber when
    the Eio capability is installed. A [session_id] that is not one real path
    segment is refused as [Store_error] (the same rejection agent core store
    applied). *)
val load_agent_core :
  session_dir:string ->
  session_id:string ->
  (Agent_core.Checkpoint.t, checkpoint_load_error) result

(** {!load_agent_core} for [keeper_name]'s turn, which saves this lineage next
    with {!save_agent_core_for_keeper}. When it reads the file it also keeps
    what it read, with an encoding memo the read filled
    ({!Agent_core.Checkpoint.of_string_with_encoding_memo}), so that save writes
    only the new messages and the next load answers without a read. A read
    during which the file changed keeps nothing. *)
val load_agent_core_for_save :
  keeper_name:string ->
  session_dir:string ->
  session_id:string ->
  (Agent_core.Checkpoint.t, checkpoint_load_error) result

(** Drops what the store keeps for [keeper_name]'s checkpoints under
    [session_root], or for every Keeper of that name when [session_root] no
    longer resolves. A save still running keeps its value again afterwards:
    the decode of the bytes it wrote, handed out only while the file keeps
    that identity (#43575). *)
val forget_written_lineages : session_root:string -> keeper_name:string -> unit

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

(** How far the read and decode {!load_agent_core} takes got on the
    canonical, one step at a time. *)
type canonical_judgement =
  | Judged_absent
  | Judged_decoded of Agent_core.Checkpoint.t
  | Judged_superseded of { expected : int; got : int }
      (** An earlier version wrote it; a turn replaces it. *)
  | Judged_newer of { expected : int; got : int }
      (** A build that bumped [checkpoint_version] wrote it; that build can
          still read it. A later build that changed the codec without a bump
          is [Judged_undecodable] instead (#38680). *)
  | Judged_undecodable of checkpoint_load_error
      (** The bytes were read and the decoder rejected their content
          ([Parse_error] or [Store_error]). *)
  | Judged_inconclusive of checkpoint_load_error
      (** No bytes were judged: the session id is not a path segment, the read
          returned no bytes or raised, or the decoder failed for a reason that
          is not the content. *)

(** Judge the canonical without a lock. {!remove_undecodable_canonical}
    judges again under the session lock before it deletes anything. *)
val judge_canonical : session_dir:string -> session_id:string -> canonical_judgement

(** What {!remove_undecodable_canonical} found under the session lock. *)
type undecodable_removal_outcome =
  | Removed of { undecodable : checkpoint_load_error }
      (** The canonical was [Judged_undecodable] and was deleted.
          [undecodable] is the decoder's error. *)
  | Canonical_absent
  | Canonical_loadable
      (** The canonical decodes, or was written by an earlier version: a
          turn can start from it, so nothing was removed. *)

type undecodable_removal_error =
  | Removal_refused of checkpoint_load_error
      (** The canonical was [Judged_newer] (carried as [Newer_version]) or
          [Judged_inconclusive]; it stays. *)
  | Removal_failed of string
      (** The lock or the unlink failed; the canonical stays. *)
  | Removal_durability_unknown of string
      (** The unlink happened, but the directory sync that makes it durable
          failed. *)

val undecodable_removal_error_to_string : undecodable_removal_error -> string

(** Delete a canonical checkpoint that {!judge_canonical} finds
    [Judged_undecodable], for the operator's [masc_keeper_clear]. The
    judgement and the unlink run under the session lock the writers take;
    nothing else is deleted.

    A copy of the bytes survives only as far as the history window keeps
    one: a save hardlinks the canonical it installs into the window, so with
    [keeper.checkpoint_history_retained] above 0 the entries still in the
    window share the canonical's inode (and so any change made to it in
    place); with 0 nothing is kept, and bytes no save installed were never
    linked. *)
val remove_undecodable_canonical :
  session_dir:string ->
  session_id:string ->
  (undecodable_removal_outcome, undecodable_removal_error) result

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

val checkpoint_ref_create_error_to_string : Keeper_checkpoint_ref.create_error -> string
val checkpoint_identity_error_to_string : checkpoint_identity_error -> string
val checkpoint_ref_load_error_to_string : checkpoint_ref_load_error -> string

(** Canonical checkpoint value, exact persisted bytes, and their reference
    derived from one immutable byte snapshot. *)
type exact_checkpoint_snapshot

val exact_snapshot_checkpoint : exact_checkpoint_snapshot -> Agent_core.Checkpoint.t

val exact_snapshot_reference :
  exact_checkpoint_snapshot -> Keeper_checkpoint_ref.t

val exact_snapshot_canonical_bytes : exact_checkpoint_snapshot -> string

(** Immutable message values decoded from these same canonical bytes. No second
    file read or re-encoding participates in their source identity. *)
val exact_snapshot_messages : exact_checkpoint_snapshot -> Agent_core.Types.message list

(** Strictly decode exact canonical bytes and derive their reference without
    re-encoding. *)
val exact_snapshot_of_value :
  expected_session_id:Keeper_id.Trace_id.t -> Agent_core.Checkpoint.t ->
  (exact_checkpoint_snapshot, checkpoint_ref_load_error) result
(** Capture a producer-returned checkpoint once, using the canonical encoder. *)

val exact_snapshot_of_canonical_bytes :
  expected_session_id:Keeper_id.Trace_id.t ->
  string ->
  (exact_checkpoint_snapshot, checkpoint_ref_load_error) result

(** Read an exact canonical snapshot and run [f] while retaining the same
    stable session lock used by checkpoint writers and session removal.
    A source-read or lock-acquisition failure does not run [f]. Callback results
    are preserved; exceptions, including Eio cancellation, propagate after
    lock cleanup.

    [f] must not re-enter checkpoint operations that acquire this session's
    lock. Perform model inference before this call. A callback that acquires
    Memory locks must acquire them inside this source lock and must retain
    the existing source-before-Memory lock order. The outer error can report
    lock-release failure after [f] completed, so an effectful callback must
    track its own committed outcome rather than infer it from [Error]. *)
val with_agent_core_exact_snapshot :
  session_dir:string ->
  session_id:string ->
  (exact_checkpoint_snapshot -> 'a) ->
  ('a, checkpoint_ref_load_error) result

(** Load an exact canonical checkpoint snapshot under the session lock. *)
val load_agent_core_exact_snapshot :
  session_dir:string ->
  session_id:string ->
  (exact_checkpoint_snapshot, checkpoint_ref_load_error) result

(** The bytes one exact snapshot was decoded from, named by their digest. It
    is made only from an exact snapshot, never from a stored record. *)
type exact_source

val exact_snapshot_source : exact_checkpoint_snapshot -> exact_source

type exact_snapshot_since =
  | Unchanged_source
      (** The file holds exactly the known bytes; their decoded value is the
          one the caller already holds. Nothing was decoded. *)
  | Changed_source of exact_checkpoint_snapshot
      (** The file holds other bytes, decoded once. *)

(** {!with_agent_core_exact_snapshot} for a caller that already holds one
    exact snapshot of this session: under the same session lock the file is
    hashed, and decoded only when its bytes differ from [known]. A missing
    file is [Ref_not_found]. *)
val with_agent_core_exact_snapshot_since :
  session_dir:string ->
  known:exact_source ->
  (exact_snapshot_since -> 'a) ->
  ('a, checkpoint_ref_load_error) result

(** Bytes read under the session lock that differ from a known source. *)
type changed_bytes

type exact_bytes_since =
  | Unchanged_bytes
      (** The file holds exactly the known bytes. Nothing was decoded. *)
  | Changed_bytes of changed_bytes
      (** Other bytes, read and hashed but not decoded yet. *)

(** Read and hash the file under the session lock and release the lock
    without decoding. A caller that holds the known snapshot's decoded value
    can drop it before {!decode_changed_bytes} builds the new one, so the two
    are not alive together. A missing file is [Ref_not_found]. *)
val read_agent_core_exact_bytes_since :
  session_dir:string ->
  known:exact_source ->
  (exact_bytes_since, checkpoint_ref_load_error) result

(** Decode bytes {!read_agent_core_exact_bytes_since} found changed, with the
    digest it already took. *)
val decode_changed_bytes :
  changed_bytes -> (exact_checkpoint_snapshot, checkpoint_ref_load_error) result

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
    Observer, release-lock, and unwind failures after durable commit remain
    typed [auxiliary] facts beside the exact installed reference; they
    never become install failures or retry signals. An exception before commit
    is re-raised with its original raw backtrace. *)
val save_agent_core_if_source :
  session_dir:string ->
  expected_source_ref:Keeper_checkpoint_ref.t ->
  Agent_core.Checkpoint.t ->
  checkpoint_installation

(** Install only if no canonical checkpoint exists, under the same stable
    session lock as source CAS. A concurrently created checkpoint produces
    [Source_changed]; corrupt/unreadable existing bytes are never overwritten.
    Installation and durability semantics match [save_agent_core_if_source]. *)
val save_agent_core_if_absent : session_dir:string -> Agent_core.Checkpoint.t ->
  checkpoint_installation

(** Retain an accepted immutable checkpoint outside rolling history. The path
    is derived internally from its reference, under [session_dir]. Existing
    bytes must validate against that exact reference before any write; corrupt
    evidence is never repaired. An identical retry durably rewrites the same
    bytes to reconfirm fsync after an earlier uncertain publication.

    [Installed] describes the retained artifact, not the latest canonical file.
    Only an installation without durability uncertainty permits a journal to
    reference it. Persist these bytes before the journal Suspend CAS; a failed
    CAS may leave an unreferenced artifact; this API never removes it, and
    [Keeper_retained_checkpoint_sweep] does at the next server startup. These bytes are accepted evidence, not authority to roll the shared
    canonical conversation back: cooperative A continuation must preserve B's
    newer shared history and use an explicit settled boundary and original
    admitted input. Exact runtime recovery remains a separate contract.

    Whole-session cleanup (including shutdown [remove_session_dir]) can remove
    this directory. Runtime journal lifecycle integration must settle or protect
    owned continuations before that cleanup. Owner/native callers, those cleanup
    guards are not wired by this primitive. *)
val retain_exact_snapshot :
  session_dir:string -> exact_checkpoint_snapshot -> checkpoint_installation

(** The session subdirectory holding retained artifacts, each named
    [<sha256>.json] after its reference. *)
val retained_dirname : string

type release_failure =
  | Lock_held_elsewhere
      (** The session's checkpoint lock was held at the attempt. Nothing
          waited and the file stays; it is unnamed, so the startup sweep
          removes it. *)
  | Release_failed of string

val release_retained :
  session_root:string -> Keeper_chat_operation_store.released_checkpoint ->
  (unit, release_failure) result
(** Remove the retained artifact a confirmed journal commit released, under
    [session_root], holding the same session lock that retention and exact
    reads take. The lock is tried once and never waited for. An absent
    artifact or retained directory is already released. A path outside the
    owned, symlink-free directory chain, or one that is not a regular file, is
    refused and left in place. The removal is not fsynced: an artifact a crash
    restores is unnamed, and [Keeper_retained_checkpoint_sweep] removes it at
    the next startup. *)

(** Read only the artifact addressed by the complete accepted reference, under
    the stable session lock. Validates immutable bytes, trace and turn count;
    returns their snapshot or a typed error. Never falls back to the latest
    canonical checkpoint, rolling history, or an empty context. A caller must
    load and validate the bytes before a Resume CAS: possession of a reference
    alone proves no checkpoint availability. Reload after an uncertain write
    establishes byte identity, not fsync; successful retention must reconfirm
    durability before a new journal reference is committed. *)
val load_retained_exact_snapshot :
  session_dir:string -> reference:Keeper_checkpoint_ref.t ->
  (exact_checkpoint_snapshot, checkpoint_cas_error) result

val find_exact_snapshot_for_retention : session_dir:string -> reference:Keeper_checkpoint_ref.t ->
  (exact_checkpoint_snapshot, checkpoint_cas_error) result
(** Find the already identified bytes in retained storage, canonical state, or
    rolling history under the original session lock. No re-encoding, newest-file
    selection, or changed-checkpoint substitution is permitted. I/O failure
    remains an error; the caller must confirm retention before resuming. *)


module For_testing : sig
  val with_before_history_link : (unit -> unit) -> (unit -> 'a) -> 'a
  (** Pause the accepted history-link syscall job. The hook must not perform
      Eio effects; the caller retains its checkpoint transaction until the
      syscall job completes. *)

  val retain_exact_snapshot_with_writer :
    write_checkpoint_bytes:
      (on_durable_commit:(unit -> unit) -> ownership_root:string ->
       path:string -> bytes:string ->
       (Keeper_fs.durable_commit_outcome, Keeper_fs.durable_write_error) result) ->
    session_dir:string -> exact_checkpoint_snapshot -> checkpoint_installation

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

  val save_agent_core_for_keeper_with_before_stage :
    before_stage:(Keeper_fs.durable_write_stage -> unit) ->
    keeper_name:string ->
    session_dir:string ->
    history_retained:int ->
    Agent_core.Checkpoint.t ->
    (save_agent_core_outcome, string) result
  (** {!save_agent_core_for_keeper} with [before_stage] run just before each
      filesystem step of the canonical write. *)
end
