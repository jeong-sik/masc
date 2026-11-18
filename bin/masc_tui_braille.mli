(** Braille cells and Braille graphs for the MASC TUI (RFC
    tui-one-screen-grammar section 5.6).

    A cell is two dots wide and four tall, so it holds two times, oldest on the
    left. Graphs carry no colour: a caller colours the rows only for an
    anomaly (section 7.3).

    Pure by construction: no terminal I/O, no mutation, no unhandled
    exceptions. *)

(** {1 Cells} *)

val braille_cell : mask:int -> string
(** Encodes a Braille pattern (0x2800 + mask) to UTF-8. *)

val braille_pair : left:int -> right:int -> string
(** One 2x4 Braille cell pairing two bottom-up dot heights ([0..4]) into the
    left and right subcolumns (e.g. ["⠀"], ["⢀"], ["⣀"], ["⣠"], ["⣤"], ["⣴"],
    ["⣶"], ["⣾"], ["⣿"]). *)

val braille_bar_mark : level:int -> string
(** Symmetric two-dot-wide Braille column at height [level] ([0..4]):
    ["⠀"], ["⣀"], ["⣤"], ["⣶"], ["⣿"]. Level [1], ["⣀"], is the baseline a
    measured zero draws. *)

(** {1 Samples} *)

type positive = private int
(** A count above zero. *)

val positive : int -> positive option
(** [Some] for a count above zero, [None] otherwise. *)

(** What a graph knows about one time. *)
type sample =
  | Unread
      (** Not read yet. A graph in which nothing has been read draws no dots. *)
  | Absent
      (** No sample at this time, or its read failed: a blank. The failure is
          for the notice area to tell. *)
  | Zero  (** A measured zero: the baseline dots ([⣀] for two zeros). *)
  | Value of positive
      (** A measured value above zero. It draws at least one dot above the
          baseline. *)

val of_count : int -> sample
(** A measured count: [0] is [Zero] and a count above zero a [Value]. A count
    below zero is no reading, so it is [Absent], the blank a failed read
    draws. *)

(** {1 Graphs} *)

(** What a graph draws. *)
type graph =
  | Never_read
      (** No sample has been read: the caller writes the unread mark [◌]
          ([Masc_tui_value.Unknown.Unread]) alone at the graph's left. *)
  | Too_narrow
      (** Fewer than {!graph_min_cells} cells are left for dots: the caller
          writes the number instead of the graph. *)
  | Drawn of string list
      (** The rows, top first, each [width] cells: the axis text in its own
          column on the top row, then the dots, newest time at the right. *)

val graph_min_cells : int
(** [4]: a graph needs this many cells of dots or it is replaced by its
    number. *)

val graph_maximum : sample list -> int
(** The largest [Value], or [0] when there is none: the top of an axis scaled
    to its samples. *)

val braille_level : dots:int -> maximum:int -> sample -> int
(** How many dots a sample fills in a column [dots] dots tall (four per text
    row), on an axis whose top is [maximum]. [Unread] and [Absent] are [0],
    a blank. [Zero] is [1], the baseline. A [Value] is between [2] and
    [dots]: at least one dot above the baseline however small it is, and
    [dots] at or past [maximum]. *)

val braille_graph :
  width:int -> rows:int -> axis:string -> maximum:int -> sample list -> graph
(** A graph [width] cells wide and [rows] text rows tall, growing up from its
    baseline. [maximum] is the top of the axis: the largest sample
    ({!graph_maximum}) or a declared limit. [axis] is that top written with its
    unit ([123K]), placed at the graph's top-left. The newest [2 * cells]
    samples are drawn; a time before the first sample is blank. *)

val braille_mirror :
  width:int ->
  half_rows:int ->
  axis:string ->
  maximum:int ->
  up:sample list ->
  down:sample list ->
  graph
(** Two paired readings on one shared axis (calls and failures, receive and
    send): [up] grows up from the middle in [half_rows] rows, [down] grows
    down from it in as many. Both sides scale to the same [maximum], and each
    follows {!braille_level}, so a smaller side above zero still shows a dot
    past its baseline. The lower half's baseline is its top row of dots
    ([⠉] for two zeros). [Never_read] only when neither side has been read. *)
