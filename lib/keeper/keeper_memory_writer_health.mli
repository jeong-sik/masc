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

(** [keeper_rows ~config] reads the writer table once and answers, for a
    Keeper name, the [writer] member of that Keeper's [keeper-memory-health]
    row (§12.3). One of three, told apart by ["kind"]:

    - ["writer"], with the same row {!section_json} carries for the Keeper
      under ["row"]: the writer the table holds, or the [booting] row of a
      registered Keeper whose writer is not made yet.
    - ["no_writer"]: the Keeper is not in the registry, so no writer is
      made for it (§11.1).
    - ["none_in_process"]: this process runs no writer table.

    Reading it makes no writer. The table and the registry are read when
    [keeper_rows ~config] is applied; each row is computed when the Keeper
    is asked for. *)
val keeper_rows : config:Workspace.config -> string -> Yojson.Safe.t
