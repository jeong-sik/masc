(** A titled box for a screen that shows several independent readings side by
    side.

    A card is a rectangle of exactly the cells it was given: [height] rows of
    exactly [width] cells. The title sits in the top edge and the body is padded
    one cell from the sides. A body taller than the card is cut and its last row
    says how many rows were left out.

    Cards are laid out as columns of stacks. Each card is as tall as its body,
    and the columns end on the same row: the card at the bottom of a shorter
    column takes the difference, so the grid is one block with a straight
    bottom edge rather than boxes of unrelated heights.

    The card draws no colour of its own. The caller passes the style codes, so
    the same card reads in whatever palette the screen probed. *)

type t =
  { title : string  (** plain text, one line *)
  ; body : cells:int -> string list
        (** the rows for a card whose content is [cells] wide, already styled.
            Asked once the layout has chosen the width, so a body can wrap to
            it. A row wider than [cells] is cut with the shared ["…"] mark. *)
  }

type style =
  { edge : string  (** style code for the border and the ["+N more"] row *)
  ; title_style : string  (** style code for the title *)
  ; reset : string
  }

val min_width : int
(** The narrowest card that still has a cell of content between its sides. *)

val min_height : int
(** The shortest card: top edge, one body row, bottom edge. *)

val content_cells : width:int -> int
(** The width of a card's content for a card [width] cells wide. *)

val render : style:style -> width:int -> height:int -> t -> string list
(** [render ~style ~width ~height card] is [height] rows of [width] cells each,
    the body stretched to the height with blank rows. Below {!min_width} or
    {!min_height} it returns that many blank rows rather than a box with no
    room in it, so a caller that counts rows still counts them. *)

val columns_that_fit :
  inner_width:int -> gap:int -> min_card_width:int -> max_columns:int -> int
(** How many columns of cards at least [min_card_width] wide fit in
    [inner_width] cells with [gap] cells between columns, between [1] and
    [max_columns]. *)

val column_widths : inner_width:int -> gap:int -> columns:int -> int list
(** The width of each column: [inner_width] less the gaps, shared evenly, the
    leftover cells going to the leftmost columns. The widths and the gaps add
    up to [inner_width]. *)

val grid_height : inner_width:int -> gap:int -> row_gap:int -> t list list -> int
(** The rows {!grid} draws: the tallest column's cards at their natural heights
    plus [row_gap] blank rows between stacked cards. A caller compares it with
    the rows it has before drawing. *)

val grid :
  style:style ->
  inner_width:int ->
  gap:int ->
  row_gap:int ->
  t list list ->
  string list
(** Lays out columns of stacked cards, [gap] cells between columns. Every row
    is [inner_width] cells wide and there are {!grid_height} of them. *)
