(** Frame-time histogram for the TUI, off unless MASC_TUI_FRAME_TIMING names a
    file to append the summary to.

    Percentiles rather than a mean: a frame loop is judged by its bad frames,
    and a p99 of 80 ms is a visible stutter that a 4 ms mean hides. *)

type phase =
  | Build  (** state -> frame *)
  | Present  (** frame -> terminal *)

val enabled : bool
(** Whether the environment asked for timing. False costs one boolean test per
    frame and nothing else. *)

val time : phase -> (unit -> 'a) -> 'a
(** Run [f], recording how long it took when {!enabled}. Returns what [f]
    returns either way. *)

val report : unit -> unit
(** Append the summary to the configured file. Silent when timing is off, and
    on a file that cannot be opened -- a diagnostic must not take the process
    down with it. *)
