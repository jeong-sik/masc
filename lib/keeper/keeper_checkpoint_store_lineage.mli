(** The lineage this process keeps per canonical checkpoint file: the encoding
    memo of its saves and, for a Keeper's own saves and save-bound loads, the
    checkpoint value the file holds. A Keeper has one lineage; keeping a new
    one drops its older one.

    [keep_lineage] records what a save wrote under the identity of the file it
    installed, and [keep_read_lineage] records what a save-bound load read,
    only when the file did not change during the read.
    [reusable_written_value] returns the value as a copy ([handed_out]) while
    the file still has the recorded identity. [lineage_memo] returns the memo
    of a path's lineage. [forget_written_lineages] drops the lineages of a
    Keeper under a session root. [Keeper_checkpoint_store] includes this
    module. *)

open Keeper_checkpoint_store_summary

(** The checkpoint a save wrote and the identity of the file it was written
    to. *)
type written_value =
  { written_identity : canonical_identity
  ; written_checkpoint : Agent_core.Checkpoint.t
  }

(* The Keeper a lineage belongs to: the session root its traces live under, as
   resolved, and its registry name. *)
type lineage_owner =
  { owner_session_root : string
  ; owner_keeper : string
  }

(** The lineage of one canonical file: its owner, the encoding memo, and the
    value the file holds when one is known. *)
type written_lineage =
  { lineage_owner : lineage_owner
  ; lineage_memo : Agent_core.Checkpoint_objects.memo
  ; lineage_written : written_value option
  }

val lineage_memo : canonical_path:string -> Agent_core.Checkpoint_objects.memo

val keep_lineage :
  canonical_path:string ->
  identity:canonical_identity ->
  memo:Agent_core.Checkpoint_objects.memo ->
  keeper_name:string -> Agent_core.Checkpoint.t option -> unit

val forget_written_lineages :
  session_root:string -> keeper_name:string -> unit

val handed_out : Agent_core.Checkpoint.t -> Agent_core.Checkpoint.t

val reusable_written_value :
  canonical_path:string ->
  identity:canonical_identity ->
  Agent_core.Checkpoint.t option

val keep_read_lineage :
  canonical_path:string ->
  identity_before:canonical_identity
                  option ->
  memo:Agent_core.Checkpoint_objects.memo -> keeper_name:string -> Agent_core.Checkpoint.t -> unit
