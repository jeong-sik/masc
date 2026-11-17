(** The TUI's one way to its terminal. Bytes keep the order they were
    written in, and a system thread does the blocking [write(2)], so a
    terminal that stops reading holds that thread and not the UI. *)

val write : string -> unit
(** Queue bytes for the terminal. Never blocks on the terminal. *)

val flush : unit -> unit
(** Hand what is queued to the writer thread. *)

val behind : unit -> bool
(** Whether bytes are queued or being written. The render loop holds new
    frames back while this is true, so a stalled terminal accumulates no
    frames, only the last one presented. *)

val drain : unit -> unit
(** Wait until every queued byte is written. Call before the terminal goes
    to anyone else: raw mode is put back, a child process takes it, or the
    process exits. *)
