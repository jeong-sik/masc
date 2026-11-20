(** Whether the screen says it is waiting on the server, and for how long
    (RFC tui-one-screen-grammar §8).

    One value owns every read in flight, the screen each was started for, and
    what the slot at the right end of zone 2 draws. A pane does not draw its
    own "refreshing" sentence: it starts a read here and the slot answers.

    The slot counts only reads older than the display bar. A read inside the
    bar draws nothing, changes no length and delays no turning off. The slot
    stays on for one more bar after the last such read succeeds, so reads that
    follow one another do not turn it off between them. A failed read cancels
    that wait.

    Nothing here performs I/O or reads a clock. The caller passes [now], an
    instant on the main loop's clock ({!Masc_tui_wake.Mono}). {!step} notes
    when its answer next changes ({!Masc_tui_wake.reached_mono}), so the main
    loop wakes then; it does not poll. The value only decides what is drawn.
    It never delays or blocks a read. *)

type 'scope t
(** The reads in flight, each tagged with the ['scope] (the screen) it was
    started for, and the slot's own decision. Immutable. *)

type id
(** One read in flight. *)

type outcome =
  | Succeeded
  | Failed
      (** The read did not succeed: it answered with an error, was withdrawn,
          or never ran. *)

val display_bar_ns : int64
(** One second. A read shorter than this is not drawn, and the slot waits this
    long after the last read past it succeeds. *)

val width_cells : int
(** The cells {!text} fills: the mark, a space and three cells of length. *)

val empty : 'scope t

val started :
  'scope t -> scope:'scope -> now:Masc_tui_wake.Mono.t -> 'scope t * id
(** A read began for [scope]. *)

val finished : 'scope t -> id -> outcome:outcome -> 'scope t
(** The read ended. An id that is not in flight (ended before, or never
    started here) leaves the value unchanged, so a read that reports its end
    on two paths counts once. *)

type length =
  | Growing of { began : Masc_tui_wake.Mono.t }
      (** The oldest read past the bar began at [began]; its age is the
          length. *)
  | Frozen of { age_s : float }
      (** No read is past the bar and the slot waits; the length is the last
          one drawn. *)

type shown =
  | Hidden
  | Showing of length

val step : 'scope t -> scope:'scope -> now:Masc_tui_wake.Mono.t -> 'scope t * shown
(** What the slot draws for [scope] at [now], and the value to keep for the
    next call. Called once per main loop pass.

    Reads started for another screen are not counted. A [scope] that differs
    from the previous call's starts the decision over; its reads keep their
    age.

    A read that started while the slot waited keeps the slot on when the wait
    ends, until it ends or passes the bar. A read that started after the wait
    ended is not waited for, so a screen that reads fast and often turns the
    slot off. *)

val text : now:Masc_tui_wake.Mono.t -> wall_now:float -> shown -> string
(** The slot's {!width_cells} cells, unstyled: blanks, or the mark, a space and
    the length right-aligned in three cells. Lengths use the one-unit ladder
    of RFC tui-one-screen-grammar §6.2; 100 days and more read [99d] so the
    width holds. A growing length notes when it next reads differently
    ({!Masc_tui_value.Redraw.note_change_at}), counting from the wall-clock
    [wall_now]. *)
