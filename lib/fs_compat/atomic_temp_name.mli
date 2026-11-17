(** Canonical filename grammar shared by atomic-temp writers and recovery.
    This module performs no filesystem operations. *)

val prefix : string
val suffix : string

val private_jsonl_stage_prefix : string
val private_jsonl_stage_suffix : string

val private_jsonl_holding_prefix : string
val private_jsonl_holding_suffix : string
(** The [.private_jsonl_holding_*.holding] basename shape a private JSONL
    replacement is created under before its lease is held. It matches neither
    [is_atomic_tmp_name] nor [is_private_jsonl_stage_name], so the sweep leaves
    it alone: a stage name in the create-to-lease window would let the
    reclaimer take a file a live writer still owns. *)

(** [is_atomic_tmp_name name] recognizes the [.atomic_*.tmp] basename shape. *)
val is_atomic_tmp_name : string -> bool

(** [is_private_jsonl_stage_name name] recognizes the [.private_jsonl_*.stage]
    basename shape produced by private JSONL rewrite staging. *)
val is_private_jsonl_stage_name : string -> bool

(** [is_name name] recognizes canonical unpublished staging basenames
    ([.atomic_*.tmp] and [.private_jsonl_*.stage]), including an empty middle
    component. It does not inspect the entry or establish ownership, age, or
    whether a writer is using it. *)
val is_name : string -> bool
