(** The too-small screen's size line (RFC tui-one-screen-grammar §2): the
    terminal's size now and the rows it needs, from the decision's own
    {!Masc_tui_render_schedule.Viewport.Rows_short} numbers.

    A count cut to its first digit reads as another count, so a narrow
    terminal drops words before numbers. The forms run widest first; the
    first whose text fits the columns is drawn. *)

type form =
  | Full  (** The words, the size now, the rows needed and the key. *)
  | Size_and_need  (** The size now, the rows needed and the key. *)
  | Need  (** The rows needed, in words, and the key. *)
  | Need_count  (** The count of rows needed alone, and the key. *)
  | Key_only
      (** The key that leaves. Chosen when no form with the count fits; the
          frame cuts it if even it is wider than the terminal. *)

val quit : ko:bool -> string
(** The key that leaves, in the screen language. *)

val text :
  ko:bool ->
  have:Masc_tui_render_schedule.Viewport.size ->
  need_rows:int ->
  form ->
  string

val choose :
  ko:bool ->
  cols:int ->
  have:Masc_tui_render_schedule.Viewport.size ->
  need_rows:int ->
  form
(** The widest form whose {!text} is at most [cols] cells, or [Key_only]. *)
