(** Says that the preview a Keeper's turns answer shows was written
    (RFC-0481 §3.5).

    {!Keeper_turn_preview} calls {!changed} after a write to the writer the
    turns answer reads for that Keeper: a new writer installed by [reset], a
    note that changed the entry, and a preparation scope that started or
    finished. A write to an older writer changes nothing the answer shows and
    says nothing.

    The observer runs on the writer's fiber, after the write and outside the
    preview lock. It must be short, must not yield and must not raise; the
    server installs one that only records the Keeper and wakes its own fiber,
    which sends [keeper_turn_preview_changed]. *)

val changed_event : string

val install : (base_path:string -> keeper_name:string -> unit) -> unit
val changed : base_path:string -> keeper_name:string -> unit
