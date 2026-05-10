(** IDE annotation storage — CRUD backed by [.masc-ide/annotations.jsonl].

    Each project base maintains its own annotation store under
    [base_dir/.masc-ide/].  The JSONL format is append-only with
    in-memory compaction on read: deleted annotations are filtered out
    and the file is rewritten when the tombstone ratio exceeds a threshold.

    Thread-safety is provided by {!Dated_jsonl} mutex per [base_dir]. *)

open Ide_annotation_types

val store_path : base_dir:string -> string
(** [store_path ~base_dir] returns [base_dir/.masc-ide/]. *)

val ensure_store : base_dir:string -> unit
(** Create [.masc-ide/] directory if absent. Idempotent. *)

val create :
  base_dir:string ->
  keeper_id:string ->
  file_path:string ->
  line_start:int ->
  line_end:int ->
  kind:annotation_kind ->
  content:string ->
  ?goal_id:string ->
  ?task_id:string ->
  unit ->
  (annotation, string) result
(** Append a new annotation. Returns the created record with a fresh UUID [id]
    and [created_at_ms] = [updated_at_ms] = current time. *)

val list :
  base_dir:string -> filter:annotation_filter -> annotation list
(** Read all annotations for the given filter. Tombstoned entries are excluded.
    Results are sorted by [created_at_ms] descending (newest first). *)

val delete :
  base_dir:string -> id:string -> keeper_id:string -> (unit, string) result
(** Soft-delete: append a tombstone record. Only the original [keeper_id] may
    delete its own annotation. *)

val compact : base_dir:string -> unit
(** Rewrite the annotation file excluding tombstones. Called automatically
    when the tombstone ratio exceeds [COMPACT_THRESHOLD]. *)

val annotation_kind_of_string : string -> annotation_kind option
(** Parse kind string, returning [None] for unknown values. *)
