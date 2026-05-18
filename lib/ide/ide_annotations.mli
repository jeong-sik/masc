(** IDE annotation storage — CRUD backed by [annotations.jsonl] inside
    one of the {!Ide_paths.partition} directories.

    The JSONL format is append-only with in-memory compaction on read:
    deleted annotations are filtered out and the file is rewritten
    when the tombstone ratio exceeds a threshold.

    RFC-0128 §4.2: callers may select a {!Ide_paths.partition}
    ([Legacy] / [By_url _] / [Orphan]) via the optional [?partition]
    argument on every public function. PR-1b adds the parameter with
    default [Legacy] so existing behaviour is unchanged. PR-1c moves
    the keeper write path and HTTP read path to [By_url _]. *)

open Ide_annotation_types

val store_path : base_dir:string -> string
(** [store_path ~base_dir] returns [base_dir/.masc-ide/] (the legacy
    flat directory). For partition-aware paths see
    {!Ide_paths.partition_store_dir}. *)

val ensure_store : base_dir:string -> ?partition:Ide_paths.partition -> unit -> unit
(** Create the partition's directory if absent. Idempotent. Default
    [partition] is {!Ide_paths.Legacy}. *)

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
    [partition] is {!Ide_paths.Legacy}. *)

val list
  :  base_dir:string
  -> ?partition:Ide_paths.partition
  -> ?merge_legacy:bool
  -> filter:annotation_filter
  -> unit
  -> annotation list
(** Read all annotations for the chosen partition. Tombstoned entries
    are excluded. Sorted by [created_at_ms] descending (newest first).
    Default [partition] is {!Ide_paths.Legacy}.

    RFC-0128 §5 — when [merge_legacy = true] and [partition] is not
    [Legacy], records from the Legacy flat store are merged into the
    result. Conflicts on annotation [id] are resolved in favour of
    the requested partition (the newer write wins). Default [false]
    for forward compatibility; the HTTP read route opts in so the
    cut-over to [By_url] does not appear to drop historical records.
    No-op when [partition = Legacy]. *)

val delete
  :  base_dir:string
  -> ?partition:Ide_paths.partition
  -> id:string
  -> keeper_id:string
  -> unit
  -> (unit, string) result
(** Soft-delete: append a tombstone record. Only the original
    [keeper_id] may delete its own annotation. The [?partition] must
    match the one the annotation was created under. Default
    [partition] is {!Ide_paths.Legacy}. *)

val compact : base_dir:string -> ?partition:Ide_paths.partition -> unit -> unit
(** Rewrite the annotation file excluding tombstones. Called
    automatically when the tombstone ratio exceeds [COMPACT_THRESHOLD].
    Default [partition] is {!Ide_paths.Legacy}. *)

val annotation_kind_of_string : string -> annotation_kind option
(** Parse kind string, returning [None] for unknown values. *)
