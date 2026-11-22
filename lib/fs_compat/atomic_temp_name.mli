(** Canonical filename grammar shared by atomic-temp writers and recovery.
    This module performs no filesystem operations. *)

val prefix : string
val suffix : string

val atomic_prep_prefix : string

val private_jsonl_prep_prefix : string
val private_jsonl_prep_suffix : string

val private_jsonl_stage_prefix : string
val private_jsonl_stage_suffix : string

(** [is_atomic_tmp_name name] recognizes the [.atomic_*.tmp] basename shape. *)
val is_atomic_tmp_name : string -> bool

(** [is_atomic_prep_name name] recognizes the [.prep_atomic_*.tmp] pre-lock
    basename used before an open-file-description [flock] is acquired and
    published to [.atomic_*.tmp]. {!is_name} intentionally returns [false] for
    [.prep_atomic_*.tmp] so orphan sweeps never race a newly opened file before
    its lease lock is held. *)
val is_atomic_prep_name : string -> bool

(** [is_private_jsonl_prep_name name] recognizes the [.private_jsonl_prep_*.prep]
    pre-lock basename used before an open-file-description [flock] is acquired
    and linked to [.private_jsonl_*.stage]. {!is_name} intentionally returns
    [false] for [.prep] basenames so orphan sweeps never delete a newly opened
    staging file before its lease lock is held. *)
val is_private_jsonl_prep_name : string -> bool

(** [is_private_jsonl_stage_name name] recognizes the [.private_jsonl_*.stage]
    basename shape produced by private JSONL rewrite staging. *)
val is_private_jsonl_stage_name : string -> bool

(** [is_name name] recognizes canonical unpublished staging basenames
    ([.atomic_*.tmp] and [.private_jsonl_*.stage]), including an empty middle
    component. It does not inspect the entry or establish ownership, age, or
    whether a writer is using it. *)
val is_name : string -> bool

(** [is_unpublished_write_name name] recognizes every unpublished staging or
    pre-lock basename produced by [Fs_compat] ([.atomic_*.tmp],
    [.prep_atomic_*.tmp], [.private_jsonl_*.stage], and
    [.private_jsonl_prep_*.prep]). Use this for read-only scanners and blob
    scopes that must classify or skip in-flight writes without deleting them. *)
val is_unpublished_write_name : string -> bool
