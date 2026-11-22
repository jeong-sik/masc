(** The lineage this process keeps per canonical checkpoint file: the encoding
    memo of its saves and, for a Keeper's own saves and save-bound loads, the
    checkpoint value the file holds. A Keeper has at most one lineage (keeping
    a new one drops its older one). The process retains the most recently
    active Keepers under a combined canonical-head and memo-entry encoded
    byte budget, without a production entry-count cap. This logical weight
    excludes decoded OCaml records and is not a process heap limit.

    [keep_lineage] records what a save wrote under the identity of the file it
    installed, and [keep_read_lineage] records what a save-bound load read,
    only when the file did not change during the read.
    [reusable_written_value] returns the value as a copy ([handed_out]) while
    the file still has the recorded identity. [lineage_memo] returns the memo
    of a path's lineage. [forget_written_lineages] drops the lineages of a
    Keeper under a session root. [Keeper_checkpoint_store] includes this
    module. *)

open Keeper_checkpoint_store_summary

val default_max_retained_lineage_bytes : int

val default_max_retained_lineage_bytes_per_keeper : int
(** Per-Keeper isolated byte ceiling so one bloated Keeper sheds its own
    lineage cache instead of evicting innocent sibling Keepers. *)

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

(** The lineage of one canonical file: its owner, the encoding memo, the value
    the file holds when one is known, its retained byte weight, and its
    monotonic LRU access sequence. *)
type written_lineage =
  { lineage_owner : lineage_owner
  ; lineage_memo : Agent_core.Checkpoint_objects.memo
  ; lineage_written : written_value option
  ; lineage_retained_bytes : int
  ; lineage_access_seq : int
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

val written_lineage_is_reusable :
  canonical_path:string -> identity:canonical_identity -> bool
(** The same eligibility and access update as [reusable_written_value],
    without copying or handing out the checkpoint's mutable context. *)

val keep_read_lineage :
  canonical_path:string ->
  identity_before:canonical_identity
                  option ->
  memo:Agent_core.Checkpoint_objects.memo -> keeper_name:string -> Agent_core.Checkpoint.t -> unit

val with_active_lineage : canonical_path:string -> (unit -> 'a) -> 'a

val has_active_lineage_for_session : session_id:string -> bool
(** True when any in-flight checkpoint save is currently pinning a canonical
    file belonging to [session_id]. Used by periodic object sweep to avoid
    racing live checkpoint writes. *)

val with_written_lineage_limits :
  max_entries:int -> max_bytes:int -> (unit -> 'a) -> 'a

val with_per_keeper_lineage_limit :
  max_bytes_per_keeper:int -> max_bytes:int -> (unit -> 'a) -> 'a
(** Temporarily override per-Keeper isolated and fleet-wide byte ceilings for
    deterministic isolation testing. *)
