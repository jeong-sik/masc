(** The Librarian section of [/health?full=1]: the row the operator reads
    for each Keeper's Memory writer (RFC librarian-call-only-proposes §12.1,
    §12.3).

    Each row is read from what the writer holds ({!Librarian_writers.held})
    when the section is computed. [/health?full=1] answers from the full
    health snapshot, so its rows are as old as that snapshot's last refresh.
    Nothing is written to disk, so a restart shows the boot's rows. The rows
    carry closed tokens and numbers only. A slot is named by its declared id;
    no provider text, claim or answer goes in. The level is
    {!Librarian_level.level}. *)

(** A row for every writer the table holds and for every Keeper the
    registry holds, by Keeper name, with how many are at [error] and at
    [warn]. A row carries the writer's state, the alarms on and their level,
    what is unread, how far reading stands, the last asks, and Memory.

    A registered Keeper whose writer is not made yet has the [booting] row:
    its first turn or the first pulse makes the writer (§8.6), and until
    then what is unread cannot be told (W1). Reading the section makes no
    writer.

    ["writers": "none_in_process"] when this process runs no writer table:
    a CLI or the TUI. *)
val section_json : config:Workspace.config -> Yojson.Safe.t
