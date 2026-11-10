(** Loading the canonical checkpoint as an exact snapshot: the checkpoint
    paired with the reference that names its content.

    [exact_checkpoint_snapshot] holds a checkpoint and the
    [Keeper_checkpoint_ref.t] whose digest is the content digest of the head
    the checkpoint was read from. [load_agent_core_exact_snapshot] reads it
    under the session lock, and [with_agent_core_exact_snapshot] runs a
    function on it before the lock is released.
    [load_agent_core_exact_snapshot_with_boundary] also counts the closed and
    open messages of the head. [with_agent_core_exact_snapshot_since] compares
    the head on disk with a known source and decodes the checkpoint only when
    its digest differs; [read_agent_core_exact_bytes_since] does the
    comparison alone and [decode_changed_bytes] decodes the head it found
    changed. [exact_snapshot_of_value] and [exact_snapshot_of_head_bytes]
    build a snapshot from a checkpoint value or from head bytes already read.
    [Keeper_checkpoint_store] includes this module. *)

open Keeper_checkpoint_store_ref_errors
open Keeper_checkpoint_store_summary

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

(* Only an exact snapshot names its source. Its digest is the content digest
   of the head it read; its value, trace and turn are the load of that head,
   or a Keeper lineage's value for it under the identity rule [load_ref_locked]
   uses. Equal digests mean the canonical still holds that content, so the
   value the caller already holds is still the one a snapshot of the file
   would hand out. The comparison is the digest alone. *)
type exact_source = Keeper_checkpoint_ref.t

val exact_snapshot_source : exact_checkpoint_snapshot -> exact_source

type exact_snapshot_since =
  | Unchanged_source
  | Changed_source of exact_checkpoint_snapshot

(* A head read under the session lock whose content digest differs from a
   known source, kept with that digest so its load does not compute it
   again. *)
type changed_bytes =
  { changed_path : string
  ; changed_session_dir : string
  ; changed_identity_before : canonical_identity
  ; changed_session_id : Keeper_id.Trace_id.t
  ; changed_head : Agent_core.Checkpoint_objects.head
  ; changed_content : Agent_core.Checkpoint_objects.digest
  }

type exact_bytes_since =
  | Unchanged_bytes
  | Changed_bytes of changed_bytes

val decode_changed_bytes :
  changed_bytes ->
  (exact_checkpoint_snapshot,
   checkpoint_ref_load_error)
  result

val read_agent_core_exact_bytes_since :
  session_dir:string ->
  known:exact_source ->
  (exact_bytes_since,
   checkpoint_ref_load_error)
  result

val with_agent_core_exact_snapshot_since :
  session_dir:string ->
  known:exact_source ->
  (exact_snapshot_since -> 'a) ->
  ('a, checkpoint_ref_load_error)
  result

val load_agent_core_with_ref :
  session_dir:string ->
  session_id:string ->
  (Agent_core.Checkpoint.t * exact_source,
   checkpoint_ref_load_error)
  result

(** [find_last_agent_core_message ~session_dir ~session_id find] is the first
    [Some] that [find] gives for the canonical's messages, last message first,
    or [None] when it gives none for any of them. It reads the head under the
    session lock and then only the objects that hold the messages [find] is
    asked ({!Agent_core.Checkpoint_objects.find_last}): each is checked
    against its digest, and nothing is said about the messages before the one
    that answered. A canonical that cannot be read whole can therefore answer
    here. A missing file is [Ref_not_found]; a head of another session is
    [Ref_session_mismatch].

    [find] runs where the objects are read and decoded, which is a pool domain
    when the caller is an Eio fiber and the pool exists. It must not perform
    Eio effects. *)
val find_last_agent_core_message :
  session_dir:string ->
  session_id:string ->
  (Agent_core.Types.message -> 'a option) ->
  ('a option, checkpoint_ref_load_error) result
