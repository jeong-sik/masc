(** Says that a Keeper's native task journal or child content journal took a
    new record.

    {!Keeper_native_task_journal.observe} and {!Keeper_child_content_journal.observe},
    the one function each journal adds records through, call it when the record
    was appended, not when it replayed one already there. The event carries the
    Keeper name only; a reader that shows the records reads
    [/api/v1/keepers/:name/native-tasks/] or [/child-content/] again.

    Exceptions from [Sse.broadcast] are counted on the
    [keeper_sse_broadcast_failures] counter and logged at WARN.
    {!Eio.Cancel.Cancelled} propagates. *)

val native_tasks_appended_event : string
val child_content_appended_event : string

val native_tasks_appended : keeper_name:string -> unit
(** [keeper_native_tasks_appended]. *)

val child_content_appended : keeper_name:string -> unit
(** [keeper_child_content_appended]. *)
