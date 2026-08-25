type style =
  | User
  | Keeper
  | Status
  | Error
  | Tool
  | Thinking

type markdown_source =
  | Markdown_stable of {
      keeper_name : string;
      request_id : string;
      observed_at : float;
      entry_index : int;
          (** Position in the current ordered history. It distinguishes two
              rows whose timestamp and request fields are equal. *)
    }
  | Markdown_growing of {
      keeper_name : string;
      request_id : string;
      entry_index : int;
          (** Position in the current live trail. Together with the full
              request identity it distinguishes interleaved reply stretches. *)
    }
  | Markdown_streaming
(** Whether a chat entry's Markdown source can be reused. Completed history
    rows carry their source facts and position in the current ordered history.
    A growing reply keeps only its closed top-level blocks. Other live rows can
    change non-append-only facts and continue to bypass every render cache. *)

type entry = {
  style : style;
  timestamp : string;
  role_label : string;
  request_label : string;
  body : string;
  markdown_source : markdown_source;
}

type metadata =
  | Origin of {
      timestamp : string;
      role_label : string;
      request_label : string;
    }
  | Continued_at of { timestamp : string }
(** A new origin carries every field the renderer needs for its badge. A later
    row from the same origin carries only its new timestamp, so callers never
    have to parse display text to decide what should be highlighted. *)

type row_kind =
  | Metadata of metadata
  | Body

type row = {
  style : style;
  kind : row_kind;
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

val dress_bare_links :
  open_style:string -> close_style:string -> string -> string
(** Style every bare [http://]/[https://] run in [text].

    For the URL pasted as plain text — a markdown link already carries its
    own spans. The URL token ends at whitespace, a control byte (so a
    styling escape already in the row is never swallowed), or a closing
    quote/bracket, which is how prose most often ends one. Rows are styled
    after wrapping, so a URL split across rows gets each fragment dressed.
    [close_style] is the caller's row-restoring sequence, not a bare reset:
    a reset alone would strip the row's own dress from everything after the
    link. *)

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

val scroll_hint : scrolled_back:int -> older_exist:bool -> string
(** The footer's scrolling hint: which keys move the pane, how far back it
    sits, and whether anything older is left to fetch.

    The count used to be a row of its own above the composer. That row was
    drawn from the clamped position and counted from the unclamped one, so the
    pane came out a row short whenever they disagreed -- an [up] press on a
    conversation that already fits does it. The count says the same thing here
    without a row whose presence the pane's own height depends on. *)

val input_cursor_column : terminal_cols:int -> input:string -> int
(** One-based cursor column after the visible input, clamped to the spacer
    immediately before the right border. Measured from the prefix the pane
    renders ([chat_input_prompt_prefix]), so the caret lands where the typed
    text ends. *)

val chat_input_prompt_prefix : string
(** The chat pane's composer prefix. The pane renders it and the caret is
    measured from it; both sites share this constant so they cannot drift. *)

val chat_input_prompt_cells : int

val chat_role_label_width : pane_cells:int -> string list -> int
(** The badge width for a pane showing these labels: the widest one, floored
    at {!chat_role_label_column} so a narrow terminal is unchanged and capped
    at a quarter of the pane so one long name cannot crowd out the messages. *)

val align_role_label : ?column:int -> string -> string
(** Pad or truncate to [column], defaulting to {!chat_role_label_column}. Pass
    the width {!chat_role_label_width} answered for the pane. *)
(** Pad (or ellipsis-truncate) a metadata role label to one fixed cell column,
    so [timestamp] [From] origin badges align down the pane. *)

val message_viewport_supported :
  terminal_rows:int -> terminal_cols:int -> status_rows:int -> bool
(** Whether the full chat frame plus its final newline fits without terminal
    scrolling. Unsupported viewports render a compact resize gate and suppress
    message editing. *)

val wrap_words : max_cells:int -> string -> string list
(** Wrap a plain single-line string at spaces using a terminal-cell budget.
    Words wider than the budget are split between complete UTF-8 scalars. *)

val wrap_body :
  ?markdown:(width:int -> string -> string list) ->
  max_cells:int ->
  sanitize:(string -> string) ->
  string ->
  string list
(** Wrap a multi-line body, applying [sanitize] to each line rather than to the
    whole text. A sanitiser that escapes control bytes escapes a newline too,
    so sanitising a document whole collapses it into one run with the escape
    printed at every break. Blank lines are kept as blank rows: a paragraph
    break is not an absence. [sanitize] is the caller's so this module keeps no
    terminal vocabulary of its own, and so is [markdown]: given one, it renders
    the escaped text and owns the wrapping, because fenced code keeps breaks a
    word wrap would ruin. *)

val visible_rows :
  ?markdown:(entry:entry -> width:int -> string list) ->
  inner_width:int ->
  height:int ->
  entry list ->
  row list
(** Render chat entries into cell-bounded, UTF-8-safe physical rows and retain
    the newest rows. The newest entry always keeps its metadata row.

    [markdown] renders one entry into rows already wrapped to the width it is
    given. The whole entry is supplied so a caller can distinguish stable
    history from a growing live source without parsing display text. Supplied
    by the caller so this module keeps no terminal vocabulary; omitted, a body
    is wrapped as the plain text it always was. Every scroll function takes the
    same argument, and passing it to one but not another would measure the pane
    against a different height than it draws. *)

val total_rows :
  ?markdown:(entry:entry -> width:int -> string list) ->
  inner_width:int ->
  entry list ->
  int
(** How many physical rows [entries] render to at this width — what a scroll
    position is measured against. *)

val scrolled_rows :
  ?markdown:(entry:entry -> width:int -> string list) ->
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
  ?markdown:(entry:entry -> width:int -> string list) ->
  inner_width:int ->
  height:int ->
  int ->
  entry list ->
  int
(** [clamp_scroll ~height requested entries] is [requested] held within what
    the transcript can scroll, the same answer as [min requested (max_scroll
    ...)]. It reads only as far back as the answer depends on, so a pane that
    is not scrolled does not pay for the whole conversation on every frame. *)

val clamped_scrolled_rows :
  ?markdown:(entry:entry -> width:int -> string list) ->
  inner_width:int ->
  height:int ->
  requested:int ->
  entry list ->
  int * row list
(** Clamp [requested] and return that window together.

    A positive scroll position is measured and sliced from one newest-to-oldest
    layout pass. Calling {!clamp_scroll} and then {!scrolled_rows} separately
    is still available to independent callers, but a frame that needs both
    should use this function so the same entry is not rendered twice. *)

val max_scroll :
  ?markdown:(entry:entry -> width:int -> string list) ->
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

val age_text : now:float -> since:float -> string option
(** How long something has been outstanding, as [12s] or [3m07s].

    An age, not a countdown: it says how long a thing has been going so a
    reader can tell slow from stuck. Rendered from a clock the caller passes
    rather than one read here, so a test can state the instant and two rows in
    one frame can share a single read. A clock that moved backwards says
    nothing rather than a negative age. *)
