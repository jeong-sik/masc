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

val take_lost : unit -> bool
(** Whether a write failed since the last call, and clear it. The terminal
    then shows less than the presenter recorded, so the caller repaints in
    full. *)

type drained =
  | Drained  (** Every queued byte reached the terminal. *)
  | Abandoned
      (** The terminal took nothing for the whole limit, or has taken
          nothing since the last [Abandoned]. The bytes still queued are
          dropped and the screen is marked lost ({!take_lost}); a write
          already in [write(2)] finishes whenever the terminal reads again. *)

val handoff_limit_s : float
(** How long the terminal may go without reading before it is handed over
    anyway, in seconds. *)

val drain : within_s:float -> drained
(** Wait until every queued byte is written, while the terminal keeps
    reading: [within_s] counts from its last read, not from the call. Call
    before the terminal goes to anyone else: raw mode is put back, a child
    process takes it, or the process exits. A terminal that stopped reading
    would otherwise keep the TUI from exiting at all. *)
