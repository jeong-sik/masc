(** The grid of the Keepers views' axis row (RFC-0515 §2.4.1 – §2.4.3, E23).

    Every view but the list draws a Keeper row on the same columns:

    {v ▌ ● name ……  ◂ pulse ┃ ● now ┃ ▹ strip  due  right v}

    The columns are fixed from the right edge and the name takes what is
    left, so the [┃] lines stand in the same column on every row. The view
    picks what each column draws. Pure: no clock of its own, no terminal. *)

(** {1 Columns} *)

type t =
  { name_cells : int  (** 0 when the list is too narrow for a name. *)
  ; side_cells : int
        (** The pulse column, and the strip's half hours after its now slot.
            0 draws neither column. *)
  ; mem_cells : int  (** The right column; 0 on a list narrower than 96 cells. *)
  }

val layout : cols:int -> t
(** The mock's [layout(cols)]. [cols] is the width the Keepers list draws in,
    not the terminal's. At 171, 120 and 80 cells the name gets 85, 34 and 18
    cells and the pulse 24, 24 and 16. *)

val gutter_cells : int
(** [▌], a space, the row mark and a space. *)

val now_cells : int
(** The cell between the two [┃] lines. *)

val due_cells : int

val strip_cells : t -> int
(** The now slot and the half hours after it; 0 when {!t.side_cells} is. *)

val window_label : slots:int -> string
(** How long [slots] half hours last, as the column headers write it: [12h],
    [8h], [7h30m]. *)

val slot_label : string
(** How long one half-hour slot lasts: [30m]. *)

val hour_window_label : hours:int -> string
(** How long [hours] drawn hour cells last, as the G1a column headers write
    it: [12h], [8h]. G1a draws whole clock hours
    (Masc_tui_keeper_pulse.slots, at most Masc_tui_keeper_mark.pulse_hours);
    G2 draws half-hour cells and switches the headers back to
    {!window_label}. *)

val hour_slot_label : string
(** How long one drawn hour cell lasts: [1h]. G2 replaces it with
    {!slot_label}. *)

(** {1 Verdicts} (§2.4.2) *)

type verdict =
  | Failing of { resting : bool }
      (** The health reading is failing. [resting] is a dispatch path that waits
          out a rest. *)
  | Paused  (** A person paused the Keeper, and it is not failing. *)
  | Recovered
      (** Neither failing nor paused, running or idle, and a half hour of the
          last twelve hours holds a failed or rested turn. *)
  | Sound  (** Neither failing nor paused, running or idle, no failed half hour. *)
  | Other  (** Offline, or a Keeper the roster did not read. *)

val recovery_slots : int
(** How many half hours back a failure makes a Keeper recovered: 24. *)

val verdict : now:float -> Masc.Tui_decode.keeper_runtime option -> verdict
(** A failing health reading comes first, then the pause. A half hour counts
    as failed when it holds a failed or a rested turn: the decision log writes
    a rest as a failure (§2.1). The last {!recovery_slots} half hours are the
    one that holds [now] and those before it; a slot stamped after [now] (the
    two clocks disagree) counts as the newest. No pulse is no failed half
    hour. *)

val mark : Masc_tui_keeper_list_model.view -> verdict -> string
(** The row mark: [!] failing, [○] paused, [●] otherwise. The cause view marks
    a recovered Keeper [✓]. *)

(** {1 Values} *)

val level_glyph : peak:int -> int -> string
(** One of [▁▂▃▄▅▆▇█] for [value] against [peak], the mock's [levelChar]. A
    value of 0 or less is the lowest. A [peak] below [value] is read as
    [value], so the glyph never passes the top. *)

val due_text : now:float -> localtime:(float -> Unix.tm) -> Masc_tui_keeper_next_run.t -> string
(** The due column: the next run's clock time within a day, the span to it
    past a day, [late] for a due run that has not started, [held] for a held
    one ([held?] when the hold is known only as of an earlier reading), [>12h]
    for a lower bound past twelve hours, and [?] for a time that is not known:
    a lower bound nearer than that, or no reading. A Keeper with no schedule
    draws nothing. *)

val lag_fill : cells:int -> peak:int -> int -> int
(** How many of [cells] cells the lag bar fills for [lag] unread turns against
    [peak]: [round (lag / peak × cells)], at least one for any lag above 0, and
    none for a lag of 0 or less or a bar of no cells. A [peak] below [lag] is
    read as [lag], so the bar never runs past its cells. *)

val short_span : float -> string
(** A span of seconds in at most five cells, the mock's [dur]: [42s], [17m],
    [3h05m], [27h], [9d]. A negative span reads as [0s]. *)

val dated_clock_text : now:float -> localtime:(float -> Unix.tm) -> float -> string
(** The clock time of [at], [HH:MM], with the date in front, [MM-DD HH:MM],
    from half a day before [now] back: an older time of day reads as today's. *)

val chain_attempts : int
(** How many attempts the failure line draws before it cuts the chain: 4. *)
