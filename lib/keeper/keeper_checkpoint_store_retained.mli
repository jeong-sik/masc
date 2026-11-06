(** Retained checkpoints: the heads kept in the session directory for as long
    as a semantic execution names them.

    [retain_exact_snapshot] writes the head of an exact snapshot, and the
    objects it names, under the checkpoint lock; [retain_exact_snapshot_with]
    takes the head writer as an argument. [find_exact_snapshot_for_retention]
    finds the snapshot a reference names, in the retained copy first and then
    in the canonical and the history files. [load_retained_exact_snapshot]
    and [load_retained_snapshot] read a retained head under the session lock;
    the second also returns a head written under an earlier
    [checkpoint_version] as [Retained_superseded]. [release_retained] removes
    a retained head once a journal commit no longer names it.
    [Keeper_checkpoint_store] includes this module. *)

open Keeper_checkpoint_store_installation
open Keeper_checkpoint_store_exact_snapshot

val retained_dirname : string

val load_retained_exact_snapshot :
  session_dir:string ->
  reference:Keeper_checkpoint_ref.t ->
  (exact_checkpoint_snapshot,
   checkpoint_cas_error)
  result

type retained_snapshot =
  | Retained_current of exact_checkpoint_snapshot
  | Retained_superseded of
      { reference : Keeper_checkpoint_ref.t
      ; expected_version : int
      ; got_version : int
      ; pending_input : Agent_core.Agent_input_request.pending option
      }

val load_retained_snapshot :
  session_dir:string ->
  reference:Keeper_checkpoint_ref.t ->
  (retained_snapshot,
   checkpoint_cas_error)
  result

val find_exact_snapshot_for_retention :
  session_dir:string ->
  reference:Keeper_checkpoint_ref.t ->
  (exact_checkpoint_snapshot,
   checkpoint_cas_error)
  result

val retain_exact_snapshot_with :
  write_checkpoint_bytes:(on_durable_commit:(unit -> unit) ->
                          ownership_root:string ->
                          path:string ->
                          bytes:string ->
                          (Keeper_fs.durable_commit_outcome,
                           Keeper_fs.durable_write_error)
                          result) ->
  session_dir:string ->
  exact_checkpoint_snapshot ->
  checkpoint_installation

val retain_exact_snapshot :
  session_dir:string ->
  exact_checkpoint_snapshot ->
  checkpoint_installation

type release_failure =
  | Lock_held_elsewhere
  | Release_failed of string

val release_retained :
  session_root:string ->
  Keeper_chat_operation_store.released_checkpoint ->
  (unit, release_failure) result
