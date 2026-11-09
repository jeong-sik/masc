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
