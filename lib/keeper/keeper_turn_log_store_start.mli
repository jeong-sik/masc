(** The turn log's step of a Keeper's store start
    (RFC librarian-call-only-proposes §8.6, §5.2).

    A Keeper's Memory writer runs it before every boot of its store: when the
    writer is made and at a [Resume] of a stopped store. A log with no
    complete line gets its [Log_started] ({!Keeper_turn_log_recorder.record_start}),
    so a Keeper whose first pulse comes before its first turn opens its
    store. A log whose first line is there is left as it is and nothing else
    is read: not its last line, not the Keeper's metadata, not its stores. An
    open turn is not closed.

    [Error] is a first line that was needed and was not written, with its
    text. The writer stops the store as [Store_unwritable] and logs it. A
    first line that could not be read is not this step's to judge: it is
    logged, and the boot reads the log as it always does. *)
val run : Workspace.config -> string -> (unit, string) result
