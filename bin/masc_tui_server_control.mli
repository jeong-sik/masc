(** Starting the MASC server from the TUI.

    The TUI does not parent the server. [start-masc.sh] backgrounds the process
    itself and owns the PID lock, so a TUI that exits leaves the server running;
    a monitor that takes its subject down with it is not what an operator wants
    from a status screen. *)

type outcome =
  | Started of string  (** absolute path of the script that was run *)
  | Script_missing of string list  (** every path that was searched *)
  | Spawn_failed of string

val start : base_path:string -> port:int -> outcome
(** Run the start script for [base_path] on [port]. Returns as soon as the
    script is spawned; the connection badge reports when the server answers. *)

val describe : outcome -> string
(** One operator sentence for the event log. *)
