(** The row the operator reads for each Keeper's Memory writer, and the
    Librarian section of [/health?full=1] (RFC
    librarian-call-only-proposes §12.1, §12.3).

    Each row is read when the answer is written, from what the writer holds
    now ({!Librarian_writers.held}): nothing is cached or stored, so a
    restart shows the boot's rows. The rows carry closed tokens and numbers
    only. A slot is named by its declared id; no provider text, claim or
    answer goes in. The level is {!Librarian_level.level}. *)

(** One Keeper's row: its state, the alarms on and their level, what is
    unread, how far reading stands, the last asks, and Memory. *)
val row : config:Workspace.config -> keeper:string -> Librarian_writer.held -> Yojson.Safe.t

(** [keeper]'s row from the writers this process runs, or [`Null] when it
    runs none or none for [keeper]. *)
val row_for : config:Workspace.config -> keeper:string -> Yojson.Safe.t

(** Every writer's row, with how many are at [error] and at [warn].
    ["writers": "none_in_process"] when this process runs no writer table:
    a CLI or the TUI. *)
val section_json : config:Workspace.config -> Yojson.Safe.t
