type style =
  | User
  | Keeper
  | Status
  | Error
  | Tool
  | Thinking

type entry = {
  style : style;
  timestamp : string;
  role_label : string;
  request_label : string;
  body : string;
}

type row = {
  style : style;
  text : string;
}

val utf8_scalar_byte_length : char -> int option
(** Expected byte length for one well-formed UTF-8 lead byte. Invalid leads and
    isolated continuation bytes return [None]. *)

val is_printable_utf8_scalar : string -> bool
(** Whether the text is exactly one valid scalar outside C0, DEL, and C1
    control ranges. *)

val drop_last_utf8_scalar : string -> string
(** Remove one complete scalar from valid UTF-8 text. Empty or invalid text is
    preserved rather than truncated into a different malformed value. *)

val display_width : string -> int
(** Approximate xterm Unicode-11 display cells while preserving extended
    grapheme clusters as indivisible layout pieces. Renderer-owned ANSI CSI,
    combining marks, variation selectors, and joiners have zero width. *)

val fit_width : string -> int -> string
(** Fit UTF-8 text to an exact terminal-cell budget without splitting a scalar
    or renderer-owned ANSI CSI sequence. Short text is padded to the budget. *)

val split_cells : max_cells:int -> string -> string list
(** Hard-split text into chunks of at most [max_cells] cells, breaking between
    complete scalars and never inside a renderer-owned ANSI CSI sequence. No
    chunk is padded, and concatenating them returns the input. Use where the
    text has no word boundaries to wrap at -- a fenced code line, an
    identifier longer than the frame. *)

val input_viewport : max_cells:int -> string -> string
(** Keep the complete input when it fits. Overflow uses a leading [~] and the
    newest complete-scalar suffix that fits in the remaining cells. *)

val input_cursor_column : terminal_cols:int -> input:string -> int
(** One-based cursor column after the visible input, clamped to the spacer
    immediately before the right border. Measured from the prefix the pane
    renders ([chat_input_prompt_prefix]), so the caret lands where the typed
    text ends. *)

val chat_input_prompt_prefix : string
(** The chat pane's composer prefix. The pane renders it and the caret is
    measured from it; both sites share this constant so they cannot drift. *)

val chat_input_prompt_cells : int

val align_role_label : string -> string
(** Pad (or ellipsis-truncate) a metadata role label to one fixed cell column,
    so [timestamp] speaker request rows align down the pane. *)

val message_viewport_supported :
  terminal_rows:int -> terminal_cols:int -> status_rows:int -> bool
(** Whether the full chat frame plus its final newline fits without terminal
    scrolling. Unsupported viewports render a compact resize gate and suppress
    message editing. *)

val wrap_words : max_cells:int -> string -> string list
(** Wrap a plain single-line string at spaces using a terminal-cell budget.
    Words wider than the budget are split between complete UTF-8 scalars. *)

val visible_rows :
  ?markdown:(width:int -> string -> string list) ->
  inner_width:int ->
  height:int ->
  entry list ->
  row list
(** Render chat entries into cell-bounded, UTF-8-safe physical rows and retain
    the newest rows. The newest entry always keeps its metadata row.

    [markdown] renders one body into rows already wrapped to the width it is
    given. Supplied by the caller so this module keeps no terminal vocabulary;
    omitted, a body is wrapped as the plain text it always was. Every scroll
    function takes the same argument, and passing it to one but not another
    would measure the pane against a different height than it draws. *)

val total_rows :
  ?markdown:(width:int -> string -> string list) ->
  inner_width:int ->
  entry list ->
  int
(** How many physical rows [entries] render to at this width — what a scroll
    position is measured against. *)

val scrolled_rows :
  ?markdown:(width:int -> string -> string list) ->
  inner_width:int ->
  height:int ->
  from_bottom:int ->
  entry list ->
  row list
(** The window of [height] rows ending [from_bottom] rows above the newest.

    [from_bottom = 0] is {!visible_rows} exactly, so the unscrolled pane keeps
    the metadata-row behaviour that only makes sense at the bottom edge: the
    newest entry holds its metadata row and loses body lines instead. Scrolled
    back, every row is already whole, and the window is a plain slice. *)

val clamp_scroll :
  ?markdown:(width:int -> string -> string list) ->
  inner_width:int ->
  height:int ->
  int ->
  entry list ->
  int
(** [clamp_scroll ~height requested entries] is [requested] held within what
    the transcript can scroll, the same answer as [min requested (max_scroll
    ...)]. It reads only as far back as the answer depends on, so a pane that
    is not scrolled does not pay for the whole conversation on every frame. *)

val max_scroll :
  ?markdown:(width:int -> string -> string list) ->
  inner_width:int ->
  height:int ->
  entry list ->
  int
(** The largest [from_bottom] that still shows a row — how far back the pane
    can go before it would scroll past the oldest entry. *)

val composer_max_rows : int
(** How many lines of the composer the pane shows at once. *)

val composer_lines : max_rows:int -> string -> string list
(** The composer's last [max_rows] newline-separated lines, oldest first, so
    what an operator just typed is on screen.

    Lines are split on newlines and not wrapped, which keeps the count
    independent of the terminal width — the pane's row budget is computed
    before the width is applied, and a count that moved with the width would
    disagree with the drawing. A line wider than the pane is fitted by
    {!input_viewport}, the way the single-line composer already was. *)

val last_page_start : height:int -> int list -> int
(** The smallest index from which items costing the given rows each still fit
    in [height] when drawn from there to the end.

    A scroll bound for a list whose items are not one row apiece. Bounding
    such a list by [count - height] leaves its tail unreachable: when every
    item costs two rows, half of them sit past the end of that bound. An item
    taller than the whole height is still reachable -- it is drawn as far as
    the height allows rather than skipped. *)
