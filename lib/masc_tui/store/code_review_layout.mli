(** Display rows of the Code review diff. The screen draws these rows and the
    key handlers move over the same rows, so a hunk jump lands on the row the
    screen shows as that hunk's header. *)

open Masc_tui_protocol

type row =
  | Hunk_header of Wire_infra.git_diff_hunk
  | Single of Wire_infra.git_diff_line
      (** One-column layout: one diff line per row. *)
  | Pair of {
      left : Wire_infra.git_diff_line option;  (** old side *)
      right : Wire_infra.git_diff_line option;  (** new side *)
    }
      (** Side-by-side layout: a context line on both sides, or the [n]th
          deletion of a change block next to its [n]th addition. *)

val side_by_side_min_cols : int
(** Effective diff-pane width (in cells) from which the review diff shows old
    and new side by side. *)

val effective_diff_pane_width :
  ?zoomed:bool ->
  ?viewport_rows:int ->
  viewport_cols:int ->
  sidebar_docked:bool ->
  unit ->
  int
(** Pure geometry SSOT computing the inner width of the right-hand diff pane in
    [Infra > Code > Review] from terminal dimensions, docked-sidebar visibility,
    and zoom state, matching [Chrome.compute_layout] and
    [Screen_infra.render_code]. [viewport_rows] defaults to [40] when omitted so
    width-only tests preserve wide-breakpoint behavior. *)

val side_by_side : cols:int -> bool
(** [true] iff the effective diff-pane width [cols] is at least
    {!side_by_side_min_cols}. *)

val rows : side_by_side:bool -> Wire_infra.git_diff_row list -> row list

val step_hunk : delta:int -> scroll:int -> row list -> int option
(** Index of the nearest hunk header strictly after ([delta > 0]) or strictly
    before ([delta < 0]) [scroll]. [None] when there is none that way. *)

val jump_line : scroll:int -> row list -> int option
(** New-file line of the first row at or after [scroll] that has one: a hunk
    header's start, or a line's new-side number. *)
