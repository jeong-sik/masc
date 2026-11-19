(** The rows a selected row's detail takes beside, above or under its list
    (RFC tui-one-screen-grammar §8): the tallest detail among the loaded
    rows, so moving the selection never moves the detail's edge or the list
    under it.

    Each screen used to size its detail by the selected row alone. The
    Workspace card's and the Features card's bottom edges moved a row with
    j and k, and the Git changes record above its list pushed the list
    header and every row by up to fourteen. A detail beside a list takes
    its lines from {!fit}, which is given every row and cannot size by one. *)

type 'line too_tall =
  | Cut_with of 'line
      (** keep the rows that fit and end with this line; a budget of one
          row keeps the detail's first line *)
  | Fold
      (** a detail that does not fit whole takes no rows, so a part of it
          never reads as the whole of it *)

val default_max_rows : int
(** Default height cap (12 rows) for {!Cut_with} details so a single unusually
    long detail row never forces every other selection to carry dozens of blank
    lines (RFC §8). *)

val fit :
  ?cap:int ->
  budget:int ->
  rows:'row list ->
  detail:('row -> 'line list) ->
  too_tall:'line too_tall ->
  blank:'line ->
  'line list ->
  'line list
(** [shown], the selected row's detail, in exactly the height the tallest
    detail among [rows] and [shown] takes, held to [budget] (and for
    {!Cut_with}, also capped at [cap], which defaults to {!default_max_rows}).
    A shorter detail ends in [blank] lines. With {!Fold}, [default_max_rows]
    is not applied unless [cap] is passed explicitly, so a narrow terminal with
    enough vertical [budget] does not silently fold away whole-or-nothing
    attribution records. The height depends on [rows], [budget], [cap] and the
    length of [shown] only, so it is the same for every selection of one list. *)

val fit_tallest :
  ?cap:int ->
  budget:int ->
  tallest:int ->
  too_tall:'line too_tall ->
  blank:'line ->
  'line list ->
  'line list
(** {!fit} for a list that counts its tallest detail itself, in lines: a
    list of a few hundred rows whose details wrap keeps that count for as
    long as the rows it was counted from are loaded, rather than wrapping
    every row's detail on each frame. A [shown] taller than [tallest] is
    measured as itself. *)
