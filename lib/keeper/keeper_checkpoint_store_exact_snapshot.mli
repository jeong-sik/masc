(** Loading the canonical checkpoint as an exact snapshot: the checkpoint
    paired with the reference that names its content.

    [exact_checkpoint_snapshot] holds a checkpoint and the
    [Keeper_checkpoint_ref.t] whose digest is the content digest of the head
    the checkpoint was read from. [load_agent_core_exact_snapshot] reads it
    under the session lock, and [with_agent_core_exact_snapshot] runs a
    function on it before the lock is released.
    [load_agent_core_exact_snapshot_with_boundary] also counts the closed and
    open messages of the head. [exact_snapshot_of_value] and
    [exact_snapshot_of_head_bytes] build a snapshot from a checkpoint value or
    from head bytes already read. [Keeper_checkpoint_store] includes this
    module. *)

open Keeper_checkpoint_store_ref_errors

type exact_checkpoint_snapshot =
  { checkpoint : Agent_core.Checkpoint.t
  ; reference : Keeper_checkpoint_ref.t
  }

val exact_snapshot_checkpoint :
  exact_checkpoint_snapshot -> Agent_core.Checkpoint.t

val exact_snapshot_reference :
  exact_checkpoint_snapshot -> Keeper_checkpoint_ref.t

val exact_snapshot_messages :
  exact_checkpoint_snapshot -> Agent_core_base.Types.message list

val checkpoint_ref_of_content :
  Agent_core.Checkpoint_objects.digest ->
  Agent_core.Checkpoint.t ->
  (Keeper_checkpoint_ref.t,
   checkpoint_identity_error)
  result

val exact_snapshot_of_value :
  expected_session_id:Keeper_id.Trace_id.t ->
  Agent_core.Checkpoint.t ->
  (exact_checkpoint_snapshot,
   checkpoint_ref_load_error)
  result

val exact_snapshot_of_head_bytes :
  session_dir:string ->
  expected_session_id:Keeper_id.Trace_id.t ->
  string ->
  (exact_checkpoint_snapshot,
   checkpoint_ref_load_error)
  result

val with_agent_core_exact_snapshot :
  session_dir:string ->
  session_id:string ->
  (exact_checkpoint_snapshot -> 'a) ->
  ('a, checkpoint_ref_load_error)
  result

val load_agent_core_exact_snapshot :
  session_dir:string ->
  session_id:string ->
  (exact_checkpoint_snapshot,
   checkpoint_ref_load_error)
  result

type canonical_history_boundary =
  { closed_messages : int
  ; open_messages : int
  }

val load_agent_core_exact_snapshot_with_boundary :
  session_dir:string ->
  session_id:string ->
  (exact_checkpoint_snapshot * canonical_history_boundary,
   checkpoint_ref_load_error)
  result

val load_agent_core_with_ref :
  session_dir:string ->
  session_id:string ->
  (Agent_core.Checkpoint.t * Keeper_checkpoint_ref.t,
   checkpoint_ref_load_error)
  result

(** [find_last_agent_core_message ~session_dir ~session_id find] is the first
    [Some] that [find] gives for the canonical's messages, or [None] when it
    gives none for any of them. [find] is asked each message once, from the
    last to the first ({!Agent_core.Checkpoint_objects.find_last}). It reads
    the head under the session lock and then only the objects on the way to
    the message that answered: an open message by itself, a turn's bundle
    whole, and the segments that list the turns before the head's. Each is
    checked against its digest, and nothing is said about the messages before
    the one that answered. A canonical that cannot be read whole can
    therefore answer here. A missing file is [Ref_not_found]; a head of
    another session is [Ref_session_mismatch].

    [find] runs where the objects are read and decoded, which is a pool domain
    when the caller is an Eio fiber and the pool exists. It must not perform
    Eio effects. *)
val find_last_agent_core_message :
  session_dir:string ->
  session_id:string ->
  (Agent_core.Types.message -> 'a option) ->
  ('a option, checkpoint_ref_load_error) result
