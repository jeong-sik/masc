(** IDE annotation storage — CRUD backed by [annotations.jsonl] inside
    a codebase's store directory ({!Ide_paths.code_store_dir}).

    The JSONL format is append-only. Deleted annotations are filtered
    out on read, and explicit compaction appends begin/end snapshot
    markers instead of rewriting the active file.

    RFC-0378 §5.2: every public function takes the [codebase] slug the
    rows belong to — the store holds addressed code facts only, so
    there is no unaddressed place for a write to land. *)

open Ide_annotation_types

val store_file : base_dir:string -> codebase:string -> unit -> string
(** [store_file ~base_dir ~codebase ()] is the append-only
    [annotations.jsonl] inside the codebase's store directory. Exposed so a
    reader can observe the store's revision (its byte length, since every
    mutation is an append) without restating the file name. *)

val ensure_store : base_dir:string -> codebase:string -> unit -> unit
(** Create the codebase's store directory if absent. Idempotent. *)

val create
  :  base_dir:string
  -> codebase:string
  -> keeper_id:string
  -> file_path:string
  -> line_start:int
  -> line_end:int
  -> kind:annotation_kind
  -> content:string
  -> ?goal_id:string
  -> ?task_id:string
  -> ?references:annotation_reference list
  -> unit
  -> (annotation, string) result
(** Append a new annotation to the codebase's store. *)

val list
  :  base_dir:string
  -> codebase:string
  -> filter:annotation_filter
  -> unit
  -> annotation list
(** Read all annotations for the codebase. Deleted entries
    are excluded. Sorted by [created_at_ms] descending (newest first). *)

val delete
  :  base_dir:string
  -> codebase:string
  -> id:string
  -> keeper_id:string
  -> ?expected_version:int64
  -> unit
  -> (unit, string) result
(** Soft-delete: append a deletion record. Only the original
    [keeper_id] may delete its own annotation. The [codebase] must
    match the one the annotation was created under.

    [?expected_version] enables optimistic concurrency: pass the
    annotation's [updated_at_ms] (its version token, exposed in
    {!Ide_annotation_types.annotation_to_json}) and the delete is refused
    with a ["version mismatch"] error when the stored value differs.
    Omitting it deletes by id alone, without the version check. *)

val compact : base_dir:string -> codebase:string -> unit -> unit
(** Append a compaction snapshot marker that lets readers ignore earlier
    deleted_ids state while replaying records written during the compaction
    window. *)

val annotation_kind_of_string : string -> annotation_kind option
(** Parse kind string, returning [None] for unknown values. *)
