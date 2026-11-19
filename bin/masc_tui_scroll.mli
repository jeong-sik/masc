(** How far a list of rows can scroll, and how a keypress moves within it.

    The arithmetic is four lines and it was written out fourteen times, once
    per surface, each naming its own field. Thirteen of those copies lived in
    the drawing, which meant drawing a frame corrected the state it was
    drawing from: the key handler moved the scroll without a bound and the
    renderer clamped it back on the way past.

    A bound belongs where the move happens. {!down} and {!up} normalise before
    they move, so a scroll left stale by a list that shrank answers the next
    keypress with a step from where the reader actually is rather than from a
    position that no longer exists. *)

val maximum : count:int -> height:int -> int
(** The largest scroll that still shows content. *)

val normalize : count:int -> height:int -> int -> int
(** A scroll held inside {!maximum}. Reading is safe on a stale value; it is
    the moving that has to be bounded. *)

module Position : sig
  (** A reading position with an explicit end selection. Normalizing a frame
      preserves that selection; only navigation or a new reading releases it. *)
  type t
  type movement = First | Last | By of int | Page_down | Page_up
  (** The window height is [Page_down]'s and [Page_up]'s share, taken through
      {!page_step}; [By] is only for a line count the caller has decided. *)
  val first : t
  val is_end : t -> bool
  val at : int -> t
  (** An explicit source/search landing. Negative positions start at zero. *)
  val offset : count:int -> height:int -> t -> int
  val clamp : count:int -> height:int -> t -> t
  (** Clamp an absolute offset while retaining an end selection. *)
  val move : count:int -> height:int -> movement -> t -> t
  (** Relative navigation starts at the current bounded position and releases
      the end selection. [First] releases it; [Last] selects it. [Page_down] and
      [Page_up] move by {!page_step}, so a reader never picks its own page. *)
end

val down : count:int -> height:int -> int -> int
val up : count:int -> height:int -> int -> int

val step_uncounted : delta:int -> int -> int
(** A scroll moved by [delta] on a surface no listing counts, held at the
    top. There is no bound below to hold it at, but a negative scroll is not
    a position either: the frame indexes the list with it. The Git-changes
    overlay opened over the Keepers surface was unlisted, and one up-key
    from the top stored -1.

    Forward stops at [max_int]. End stores that value on a reader the frame
    clamps, and until the frame has drawn, an addition would wrap negative
    and throw the reader to the top. *)

val page_step : height:int -> int
(** A page of visible rows with the existing one-row overlap. *)

val page_down : count:int -> height:int -> int -> int
val page_up : count:int -> height:int -> int -> int
(** A whole window, less one row kept from the window being left. Reading a
    long list one page at a time otherwise drops the row the reader stopped on:
    it sits just past the new edge and nothing reports it. Same bound and same
    stale-value rule as {!down} and {!up}. *)

(** The movement a scrolled body makes for a key name. Every sheet that scrolls
    plain text matches the same names, so they are named once here. *)
type key_move = Line_down | Line_up | Page_down | Page_up | To_top | To_end

val move_of_key : string -> key_move option
(** [j] and [Down] are one row down, [k] and [Up] one row up, [PageDown] and
    [PageUp] a page ({!page_down}, {!page_up}), [g] and [Home] the top, [G]
    and [End] the last row that still shows content. [None] for any other
    key, which the caller keeps for itself. *)

val apply_move : count:int -> height:int -> key_move -> int -> int
(** The scroll after [move], bounded as {!down} and {!up} bound it. *)

(** A row cursor over the same list. The cursor names a row, the scroll names
    a window; a keypress moves the cursor and the window follows with
    {!ensure_visible}. The same stale-value rule applies: moving normalises
    first, so a list that shrank answers from its last row, not from a row
    that no longer exists. *)

val cursor_down : count:int -> int -> int
val cursor_up : count:int -> int -> int

val cursor_move : count:int -> delta:int -> int -> int
(** The cursor moved by [delta] rows, clamped to the list. The steppers above
    move one row and are this with [delta] of 1 and -1; a page key passes its
    own size. Before this existed the movers took a delta and used only its
    sign, so a page moved a single row. *)

val cursor_last : count:int -> int
(** The last row a cursor can name, and 0 for an empty list. What End lands
    on. *)

(** A move of a row cursor, one per move key (RFC tui-one-screen-grammar
    §3.1). A page move carries the rows its page counts, so a line or edge
    move has no page to pass and a page move cannot leave its page out. The
    [key_move] above is the same key over a scrolled body, whose page is its
    window. *)
module Cursor_move : sig
  type t =
    | Line_down
    | Line_up
    | Page_down of int  (** the rows one page counts; at least one *)
    | Page_up of int
    | To_top
    | To_end
end

val cursor_apply : count:int -> Cursor_move.t -> int -> int
(** The row [move] puts a cursor on in a list of [count] rows. [Line_down]
    and [Line_up] move one row, [Page_down] and [Page_up] their page (at
    least one row), [To_top] is the first row and [To_end] {!cursor_last}.
    Every landing is held inside the list, and an empty list answers 0.

    A list whose j and k land on more than its data rows, such as group
    headings, counts those places here too, so Home and End reach the same
    first and last place j and k reach. Folding is not a move. *)

val ensure_span_visible : start:int -> stop:int -> height:int -> int -> int
(** Like {!ensure_visible} for a cursor that names a run of lines [start] to
    [stop] (inclusive). A run no taller than the window is shown whole, by
    the smallest move: a run below the window ends it, a run above starts
    it. A taller run is read inside: a window that shows some line of it is
    left where the reader scrolled it, so its body can be walked, and the
    window moves only when the whole run has left it. *)

val ensure_visible : cursor:int -> height:int -> int -> int
(** The smallest move of [scroll] that keeps [cursor] inside the window. *)

val ensure_visible_with_lead : cursor:int -> lead:int -> height:int -> int -> int
(** {!ensure_visible} for a row that brings [lead] rows glued above it, such as
    the heading of the group it opens. The window follows the row, then moves
    up until the lead is on screen too. [lead] is held to at most [cursor] and
    at most [height - 1], so the row stays in the window and a window of one
    row behaves as {!ensure_visible} does. *)

val window_of_heights : heights:int list -> cursor:int -> rows:int -> int -> int * int
(** {!ensure_visible} for items that take different numbers of lines: item [i]
    takes the [i]th of [heights] and the window holds [rows] lines. The first
    item on screen after the smallest move of [scroll] that shows item
    [cursor] whole, held where the last items still fill the window, and the
    number of items from it that fit whole.

    A cursor past either end names the nearest item, and a negative [scroll]
    is the top. When the cursor's item is taller than the window, the window
    starts at that item and draws no item: the count is 0, and the items
    around it are not drawn in its place. [(0, 0)] for an empty list or a
    window of no lines. *)

val items_always_shown : heights:int list -> rows:int -> int
(** The fewest items in a row that a window of [rows] lines holds whole,
    wherever the run starts, at least one: item [i] takes the [i]th of
    [heights]. It is the height a list of such items reports for a page key,
    so from any window a page down lands on an item that fits with every item
    the window showed after the cursor, and nothing is passed unseen when the
    windows ahead hold fewer items than this one. An item taller than the
    window holds no run, so a list with one pages by one item. *)

(** A surface that draws a preview under its list splits the rows it has. The
    split belongs here for the same reason the bound does: the keypress and
    the frame have to work it out the same way. A renderer that shrank its
    own list while the key handler kept moving against the full height is
    what this module was written to stop, and Changes reintroduced it -- the
    list drew ten rows and the keypress stopped at the bound for twenty, so
    the rows past that could not be reached. *)

val preview_height : total:int -> keep:int -> int
(** The preview's rows out of [total], leaving the list at least [keep]. *)

val body_height : total:int -> keep:int -> int
(** The list's rows out of [total] once the preview has taken its share. *)

val content_height
  :  rows:int
  -> chrome:int
  -> count:int
  -> preview_keep:int option
  -> int
(** The list height after fixed chrome and an optional preview have each
    taken their declared rows. No row is kept for a position: it is drawn on
    the title row (RFC tui-one-screen-grammar, section 2). *)
