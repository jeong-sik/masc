(** Where a keeper's chat transcript lives, and how a dropped row or a failed
    store operation is reported.

    [chat_path] is the transcript file [<chat_dir base_dir>/<keeper>.jsonl].
    [chat_dir] is the directory [chat_dirname] inside the MASC directory of
    [base_dir], and [sanitize_name] makes the keeper name safe as a file name.
    [ensure_dir_once] creates [chat_dir].
    [report_persistence_read_drop] hands the reason, the path and the detail of
    a row that was dropped while reading to [Safe_ops.report_persistence_read_drop],
    together with a callback that counts the drop in the persistence read-drop
    metric through [record_persistence_read_drop], under the
    [persistence_surface] name.
    [report_store_failure] counts one failed [operation] in
    [masc_keeper_chat_store_failures_total], warns that [what] failed for
    [keeper_name], and returns the text of the exception for a writer that
    answers [Error].
    [Keeper_chat_store] includes this module. *)

val sanitize_name : string -> string

val chat_dirname : string

val chat_dir : string -> string

val chat_path : base_dir:string -> keeper_name:string -> string

val report_persistence_read_drop :
  reason:Read_drop_reason.t -> path:string -> detail:string -> unit

val report_store_failure :
  operation:Keeper_chat_store_operation.t ->
  keeper_name:string ->
  what:string ->
  exn ->
  string

val ensure_dir_once : base_dir:string -> unit
