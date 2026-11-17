(** A process-local witness for a successfully read checkpoint. It holds no
    checkpoint, message, body or encoding memo and grants no write authority.

    A cold read records the owned descriptor snapshots of the canonical and
    every transitive object read by the complete checkpoint loader. No witness
    is returned unless that loader's digest, message, count and chain checks
    succeed. Revalidation uses the existing owned-file snapshot contract, not
    just the canonical head's content digest.

    A written-lineage hit retains only the canonical identity; it remains
    reusable only while that same lineage is still eligible. This preserves
    the store's existing written-value trust rule without retaining its value. *)

type t

type revalidation =
  | Unchanged
  | Changed
  | Unavailable of Keeper_checkpoint_store_decode.checkpoint_load_error

val load :
  session_dir:string -> session_id:string ->
  (Agent_core.Checkpoint.t * t,
   Keeper_checkpoint_store_decode.checkpoint_load_error) result

val revalidate : t -> revalidation
(** For a cold-read witness, reopen the canonical and all witnessed objects
    through owned, zero-byte reads. A written-lineage witness checks that
    lineage's continued eligibility. Only [Unchanged] permits reusing a
    derived observation. On [Changed]
    or [Unavailable], discard that observation and perform a complete load to
    observe the current source and its current errors. A file changed after
    an individual check is outside that check, as with the original read.
    Snapshot equality has the filesystem timestamp-resolution limits of
    {!Fs_compat.load_owned_regular_file_with_snapshot}. No file is written. *)

module For_testing : sig
  val load_after_object_read :
    after_object_read:(Agent_core.Checkpoint_objects.digest -> unit) ->
    session_dir:string -> session_id:string ->
    (Agent_core.Checkpoint.t * t,
     Keeper_checkpoint_store_decode.checkpoint_load_error) result
  (** Run the callback after an object's exact bytes and descriptor snapshot
      were read, before the checkpoint loader checks those bytes. *)
end
