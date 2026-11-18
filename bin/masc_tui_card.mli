(** A rounded box for one of two or more independent readings in a body
    (RFC tui-one-screen-grammar, section 2).

    The edges say what the card is and the body holds data only. The top edge
    carries the card's name, its status (a mark and a word) and its count. The
    bottom edge carries how many rows the card cut off: [외 3], [3 more]. That
    is a count of rows, not where the reader is.

    A card is a rectangle of exactly the cells it was given: [height] rows of
    exactly [width] cells, the body padded one cell from the sides.

    Cards are laid out as columns of stacks. Each card is as tall as its body,
    and the columns end on the same row: the card at the bottom of a shorter
    column takes the difference, so the grid is one block with a straight
    bottom edge rather than boxes of unrelated heights.

    The caller passes the style codes, so the same card reads in whatever
    palette the screen probed. The one colour the card picks itself is a
    focused card's border, the theme's border.focused token. The corners stay
    rounded either way: RFC section 12 leaves the focused card's border glyphs
    open. *)

type count =
  | Whole of int  (** Every row of the reading is loaded: [12]. *)
  | Partial of { loaded : int; total : int }
      (** Some of them: [50 · 전체 2,000], [50 · of 2,000]. *)

type symbol =
  | Mark of Masc_tui_value.Mark.t
  | Unknown of Masc_tui_value.Unknown.t
      (** The screen has no reading of the state, and the mark says why
          (RFC section 6.4). *)

type status =
  { symbol : symbol
  ; word : string
        (** Plain text, one line. Empty draws the symbol alone, for a state
            with no word, such as an unreported one. *)
  ; tone : string  (** Style code for the symbol and the word. *)
  }

type focus =
  | Focused  (** The card owns the keyboard. *)
  | Unfocused

type edge =
  { name : string  (** Plain text, one line. *)
  ; key : (string * string) option
        (** A key tag and its style drawn ahead of the name ([("p", accent)]).
            RFC section 12 leaves keys on card edges to the layer that moves
            keys. Until then a tag is the first thing a narrow edge gives up,
            so it never costs the name a cell. *)
  ; status : status option
  ; count : count option
        (** A focused card writes no count: zone 2's position already says
            it. *)
  ; focus : focus
  }

type t =
  { edge : edge
  ; body : cells:int -> string list
        (** The rows for a card whose content is [cells] wide, already
            styled. Asked once the layout has chosen the width, so a body can
            wrap to it. A row wider than [cells] is cut with the shared ["…"]
            mark. *)
  }

type style =
  { border : string
        (** Style code for an unfocused border, the count and the cut-off
            rows. *)
  ; title_style : string  (** Style code for the name. *)
  ; reset : string
  }

type name_fit =
  | Whole_name
  | Shortened_name of int
      (** Drawn in this many cells, the last of them the cut mark ["…"]. *)
  | No_name

type top_fit =
  { key_kept : bool
  ; name_kept : name_fit
  ; word_kept : bool
  ; symbol_kept : bool
  ; count_kept : bool
  }
(** What a top edge draws. A part the edge does not have is not kept. *)

val top_fit : ko:bool -> width:int -> edge -> top_fit
(** What the top edge of a card [width] cells wide keeps. Everything, when it
    fits. Otherwise the key tag goes first. Then the name is shortened with
    ["…"], down to its first character. Then the status word goes, and the
    name takes back the room the word left. The status symbol and the count
    stay to the end: the name goes before them. When even those two do not
    fit, the edge is a bare rule. A focused card keeps no count.

    [ko] picks the language of a {!Partial} count, whose width is part of
    the decision. *)

val window : rows:int -> 'a list -> 'a list * int
(** The rows a body shows in [rows] rows -- its head -- and how many it cuts
    off, the number the bottom edge writes. *)

val min_width : int
(** The narrowest card that still has a cell of content between its sides. *)

val min_height : int
(** The shortest card: top edge, one body row, bottom edge. *)

val content_cells : width:int -> int
(** The width of a card's content for a card [width] cells wide. *)

val render :
  ko:bool -> style:style -> width:int -> height:int -> t -> string list
(** [render ~ko ~style ~width ~height card] is [height] rows of [width] cells
    each, the body stretched to the height with blank rows. Below {!min_width}
    or {!min_height} it returns that many blank rows rather than a box with no
    room in it, so a caller that counts rows still counts them. [ko] is the
    language of the count and of the cut-off rows. *)

val columns_that_fit :
  inner_width:int -> gap:int -> min_card_width:int -> max_columns:int -> int
(** How many columns of cards at least [min_card_width] wide fit in
    [inner_width] cells with [gap] cells between columns, between [1] and
    [max_columns]. *)

val column_widths : inner_width:int -> gap:int -> columns:int -> int list
(** The width of each column: [inner_width] less the gaps, shared evenly, the
    leftover cells going to the leftmost columns. The widths and the gaps add
    up to [inner_width]. *)

val grid :
  ko:bool ->
  style:style ->
  inner_width:int ->
  gap:int ->
  row_gap:int ->
  max_rows:int ->
  t list list ->
  string list option
(** Lays out columns of stacked cards, [gap] cells between columns and
    [row_gap] blank rows between stacked cards. Every row is [inner_width]
    cells wide, and the rows are those of the tallest column at its cards'
    natural heights. [None] when that is more than [max_rows], so a caller
    falls back to something shorter before anything is drawn. Each body is
    asked once per card. *)
