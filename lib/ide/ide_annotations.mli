(** IDE annotation storage — CRUD backed by [annotations.jsonl] inside
    one of the {!Ide_paths.partition} directories.

    The JSONL format is append-only. Deleted annotations are filtered
    out on read, and explicit compaction appends begin/end snapshot
    markers instead of rewriting the active file.

    RFC-0128 §4.2: callers may select a {!Ide_paths.partition}
    ([By_url _] / [Orphan]) via the optional [?partition]
    argument on every public function. The default is [Orphan] so
    unpartitioned writes do not recreate the retired flat store. *)

open Ide_annotation_types

val store_path : base_dir:string -> string
(** [store_path ~base_dir] returns [base_dir/.masc-ide/] (the root
    flat directory). For partition-aware paths see
    {!Ide_paths.partition_store_dir}. *)

val ensure_store : base_dir:string -> ?partition:Ide_paths.partition -> unit -> unit
(** Create the partition's directory if absent. Idempotent. Default
    [partition] is {!Ide_paths.Orphan}. *)

val create
  :  base_dir:string
  -> ?partition:Ide_paths.partition
  -> keeper_id:string
  -> file_path:string
  -> line_start:int
  -> line_end:int
  -> kind:annotation_kind
  -> content:string
  -> ?goal_id:string
  -> ?task_id:string
  -> ?board_post_id:string
  -> ?comment_id:string
  -> ?pr_id:string
  -> ?git_ref:string
  -> ?log_id:string
  -> ?session_id:string
  -> ?operation_id:string
  -> ?worker_run_id:string
  -> unit
  -> (annotation, string) result
(** Append a new annotation to the chosen partition. Default
    [partition] is {!Ide_paths.Orphan}. *)

val list
  :  base_dir:string
  -> ?partition:Ide_paths.partition
  -> filter:annotation_filter
  -> unit
  -> annotation list
(** Read all annotations for the chosen partition. Tombstoned entries
    are excluded. Sorted by [created_at_ms] descending (newest first).
    Default [partition] is {!Ide_paths.Orphan}. *)

val delete
  :  base_dir:string
  -> ?partition:Ide_paths.partition
  -> id:string
  -> keeper_id:string
  -> ?expected_version:int64
  -> unit
  -> (unit, string) result
(** Soft-delete: append a tombstone record. Only the original
    [keeper_id] may delete its own annotation. The [?partition] must
    match the one the annotation was created under. Default
    [partition] is {!Ide_paths.Orphan}.

    [?expected_version] enables optimistic concurrency: pass the
    annotation's [updated_at_ms] (its version token, exposed in
    {!Ide_annotation_types.annotation_to_json}) and the delete is refused
    with a ["version mismatch"] error when the stored value differs.
    Omitting it keeps the legacy delete-by-id contract. *)

val compact : base_dir:string -> ?partition:Ide_paths.partition -> unit -> unit
(** Append a compaction snapshot marker that lets readers ignore earlier
    tombstoned state while replaying records written during the compaction
    window. Default [partition] is {!Ide_paths.Orphan}. *)

val annotation_kind_of_string : string -> annotation_kind option
(** Parse kind string, returning [None] for unknown values. *)
