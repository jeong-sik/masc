type skill_tone =
  | Skill_live
  | Skill_used
  | Skill_attention
  | Skill_failure

type style =
  | User  (** The operator of this workspace -- what you sent. *)
  | Inbound
      (** A line addressed to this Keeper by anyone else: another agent's
          broadcast, a connector, a second operator. Apart from {!User}
          because the two are different facts and the pane drew them alike --
          same mark, same colour, same ambient background -- with only the
          name text between them. On one live transcript that was 31 rows
          from six senders wearing the reader's own colours. *)
  | Keeper
  | Status
      (** What the server says happened to a turn. *)
  | Local
      (** The pane answering a command typed at it. Never left this machine,
          and belongs to no turn. *)
  | Journal
      (** Auxiliary Memory/Librarian lane. It has its own mark and rail so a
          recorded memory pass never reads as part of ordinary conversation. *)
  | Error
  | Tool
  | Skill of skill_tone
  | Thinking

val all_styles : style list
(** Every style, listed beside the type so a new variant is added in sight of
    it. The mark-distinctness check walks this; nothing in the language forces
    a variant to appear here. *)

type turn_rail =
  | Rail_opens  (** The turn's first row. *)
  | Rail_says
      (** The turn talking: the Keeper's reply, the operator's prompt, the
          error it ended on. *)
  | Rail_does
      (** What the turn did to get there -- reasoning, tool calls, a skill.
          Drawn as a branch off the trunk, because a turn's work is
          subordinate to the turn and was reading as a sibling of it. *)
  | Rail_closes  (** The last row of a turn that has finished. *)
  | Rail_none
      (** Nothing to hang: a row belonging to no turn, or a turn of one row.
          A single-row turn has no hierarchy to draw, so ordinary chatter
          carries no rail and the mark appears only where there is structure
          to read. *)
(** Where a row sits in the bracket its turn draws down the left margin.

    A turn interleaves with broadcasts, journal commits and other keepers'
    turns on one clock, and nothing said which rows were one turn's. The
    bracket answers that without a heading row: rows inside it are this turn,
    rows beside it are not.

    An open bracket is also how a running turn reads. A turn still streaming
    emits no {!Rail_closes}, so the rail stays open until the turn ends -- the
    fact is structural rather than a second spinner. *)

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

type timeline_bucket = {
  tb_year : int;
  tb_month : int;
  tb_day : int;
  tb_hour : int;
  tb_is_dst : bool;
}
(** One local civil hour on the conversation timeline. Calendar fields, rather
    than a formatted label, are the grouping authority. [tb_is_dst] keeps the
    repeated hour at a daylight-saving transition from being merged with the
    hour that preceded it and marks the daylight occurrence in its label. *)

type entry = {
  style : style;
  timestamp : string;
  timeline_bucket : timeline_bucket option;
      (** The civil-hour rail this entry belongs under. [None] is reserved for
          rows without a trustworthy observation time; they do not invent a
          timeline heading from display text. *)
  role_label : string;
  role_label_mark_cells : int;
      (** Cells the speaker mark occupies at the head of {!role_label}, from
          {!role_label_mark_cells}. Zero when the column was too narrow to keep
          the mark. Carried on the entry because the caller is what chose the
          column, and read back by the renderer to style the mark and the
          label differently: colour says status, the label only says kind. *)
  request_label : string;
  body : string;
  markdown_source : markdown_source;
  turn_rail : turn_rail;
      (** Which piece of its turn's bracket this entry draws. Carried on the
          entry because only the caller knows the turn's extent: the layout
          sees one entry at a time. *)
}

type metadata =
  | Timeline_break of timeline_bucket
      (** The first entry in a different civil hour. It is structural metadata
          so scrolling and search measure the same row the renderer paints. *)
  | Origin of {
      timestamp : string;
      role_label : string;
      request_label : string;
    }
  | Continued_at of { timestamp : string }
(** A new origin carries every field the renderer needs for its badge. A later
    row from the same origin carries only its new timestamp, so callers never
    have to parse display text to decide what should be highlighted. *)

type shade =
  | Shade_none
      (** Prose a person reads. Most of the pane, so no background at all is
          the default rather than one of several tints. *)
  | Shade_quoted
      (** Text the Keeper did not write: a diff, a tool's output, a memory
          recalled. Drawn one step off the background with a left rail, so a
          reader can see where the quoted block ends without reading it. *)
(** How much a row belongs to what is around it.

    Colour says status and indentation says depth; this says belonging, and it
    is deliberately a closed sum with no room to grow. A fourth tint is not a
    fourth kind of belonging — three steps is already the most a terminal
    background can separate before the eye stops reading them as an order. If
    something needs to be set apart further, that is depth, and indentation is
    what carries depth.

    Keeping it closed is the point: a variant cannot be added without every
    renderer answering for it. *)

type row_kind =
  | Metadata of metadata
  | Body
  | Viewport_gap of { hidden_rows : int }
      (** A synthetic row marking content omitted from an oversized newest
          entry at the live edge, including an explicitly collapsed run of
          identical wrapped rows. It is not part of transcript row counts;
          ordinary scrollback still reads the original physical rows. *)

type origin_display =
  | Origin_row  (** The origin keeps a row of its own, above the body. *)
  | Origin_inline
      (** The origin folds into the body's left margin, clock included. *)
  | Origin_bare  (** The same margin without the clock. *)
(** Where a message's origin is drawn. [Origin_bare] is the chat default.
    [Origin_inline] adds its clock; [Origin_row] adds a full timestamp and
    request-id heading. Folding headings into the gutter hands their rows back
    to the conversation: eight speakers taking turns otherwise spend eight
    rows of a forty-row pane on headings.

    Every layout and scroll function takes this, and passing it to one but not
    another would measure the pane against a height it does not draw. *)

type row = {
  style : style;
  kind : row_kind;
  shade : shade;
      (** Which belonging layer this row sits in. See {!shade}. *)
  text : string;
  gutter_rail_cells : int;
      (** Cells at the head of {!gutter} holding the turn rail and the space
          after it. Zero where no rail is drawn at all, so a pane that never
          shows one pays nothing for it. The renderer draws these cells in the
          quiet tone: the rail is structure, and colour on this row is already
          spent saying status. *)
  gutter_label_at : int;
      (** Cells of {!gutter} that belong to the rail, the clock and the speaker
          mark. The
          rest is the kind label. The renderer colours what comes before this
          by status and lets the label recede; without the offset it would have
          to find the mark by measuring the glyph a second time. Zero on rows
          whose gutter is blank. *)
  gutter : string;
      (** What to draw left of the body's rule. Empty under {!Origin_row};
          under the other two it holds the origin on a message's first row and
          the same width in blanks on the rest, so a wrapped body lines up
          under where it started. *)
}

val turn_rail_glyph : turn_rail -> string
(** The one cell this rail piece draws, or a blank for {!Rail_none}. Box
    drawing so the bracket survives NO_COLOR as a shape. *)

val turn_rail_cells : int
(** Cells the rail column costs every row: the glyph and the space after it.
    Spent uniformly whether or not a rail is drawn, because a margin that
    changed width per row would re-wrap every body below it. *)

val utf8_scalar_byte_length : char -> int option
(** Expected byte length for one well-formed UTF-8 lead byte. Invalid leads and
    isolated continuation bytes return [None]. *)

val is_printable_utf8_scalar : string -> bool
(** Whether the text is exactly one valid scalar outside C0, DEL, and C1
    control ranges. *)

val drop_last_utf8_scalar : string -> string
(** Remove one complete scalar from valid UTF-8 text. Empty or invalid text is
    preserved rather than truncated into a different malformed value. *)

val drop_last_utf8_word : string -> string
(** Remove trailing blanks and the word run before them -- Ctrl-W and
    Alt+Backspace in a chat draft. The separator before the word stays, so two
    presses walk two words. Empty or invalid text is preserved. *)

val display_width : string -> int
(** Approximate xterm Unicode-11 display cells while preserving extended
    grapheme clusters as indivisible layout pieces. Renderer-owned ANSI CSI,
    combining marks, variation selectors, and joiners have zero width. *)

val split_at_cells : string -> int -> string * string
(** The longest prefix fitting in the given cells without cutting a grapheme,
    and the rest. For wrapping, where nothing may be lost: a wide grapheme
    that straddles the boundary moves to the tail whole, rather than being
    given up and padded the way {!take_cells} gives it up to hold a column. *)

val take_cells : string -> int -> string
(** Keep the first [cells] display cells, the counterpart to [drop_cells]: the
    two halves of a cut add up to the whole, and a zero-cell head is empty.
    Not [split_cells], which wraps and so always takes one piece -- as a
    prefix that invents a cell the caller never asked for. *)

val drop_cells : string -> int -> string
(** Drop the first [cells] display cells, keeping every ANSI sequence crossed
    so the remainder opens under the styles the cut passed through. A wide
    grapheme straddling the boundary is padded with spaces so the columns to
    its right stay aligned. The horizontal-scroll counterpart of
    [fit_width]'s right-edge cut. *)

val bare_urls : string -> string list
(** The bare [http]/[https] URLs in this text, in the order they appear and cut
    at the same place {!dress_bare_links} stops underlining them. One rule, so
    a caller naming what a link points at reads exactly the text the pane
    draws as the link. *)

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

val fit_middle : int -> string -> string

val role_label_mark_cells : ?column:int -> style:style -> unit -> int
(** Cells {!align_role_label} spends on the speaker mark and its separator at
    the given column, or zero when the column is too narrow to keep the mark.

    The single reader of that arithmetic. A renderer that styles the mark apart
    from the label asks here rather than measuring the glyph again, so the two
    cannot drift. *)

(** [fit_middle column label] keeps both ends of [label] in [column] cells,
    dropping the middle and marking the cut with ["…"].

    Use this for identifiers. {!fit_width} keeps the head and loses the tail
    that tells two Keepers apart; a tail-only cut keeps the tail and loses the
    head that says which family they share. The tail takes two thirds of the
    budget, so a narrow column degrades toward the tail rather than into
    {!fit_width}'s shape.

    The chat pane's role label used a tail-only cut until it met a family that
    shares its tail instead of its head: a broadcast reads
    [<agent> · broadcast], and cutting it to ["…broadcast"] kept the word every
    row on the screen already had and dropped the only part that named who
    spoke.

    Left-aligned and padded to [column]. *)
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

val message_history_height : terminal_rows:int -> status_rows:int -> int
(** Physical transcript rows left after fixed chrome and variable status rows.
    This is both the renderer height and the PgUp/PgDn distance. *)

val chat_title_row :
  inner_cells:int -> title:string -> mode_suffix:string -> string
(** Fit a chat navigation title while reserving the complete projection-mode
    suffix first. The opaque title yields width before semantic display state. *)

val chat_role_label_width : pane_cells:int -> int
(** The badge budget for a pane this wide. It does not read the labels: body
    width is taken from what the badge leaves, so measuring the loaded
    messages made every body re-wrap whenever a differently-named speaker
    posted. The bounded 10--14 cell result keeps the built-in activity names
    whole without turning their alignment padding into a wide empty gutter. *)

val speaker_mark : style -> string
(** One glyph per speaker. Colour says the same thing more legibly, and
    NO_COLOR removes colour, so this is what still answers "who said this"
    when there is none. *)

val continued_mark : style -> string
(** Glyph drawn in the speaker mark position on rows that continue the same
    speaker. While the turn opens with {!speaker_mark}, continuing rows draw
    a quiet vertical connection line ("│") rather than repeating the mark
    over a wide empty gutter. Reasoning keeps its own dot. *)

val split_aligned_role_label :
  style:style -> string -> string * string * string
(** An {!align_role_label} result taken back apart into its mark, the
    name, and its trailing column padding. The padding is layout and the name
    is content: a renderer that reverses the whole label paints empty cells as
    though they were the badge. The mark is empty for a label
    narrow enough that {!align_role_label} dropped it. *)

val align_role_label : ?column:int -> style:style -> string -> string
(** Left-align a role label in [column] cells, defaulting to
    {!chat_role_label_column}; pass the budget {!chat_role_label_width}
    answered for the pane. A label that does not fit loses its head, not its
    tail: these read [agent · surface] and share long prefixes, so the end is
    what tells two of them apart. Remaining column cells follow the name. *)

val chat_min_terminal_cols : int
(** The narrowest terminal the keeper chat pane renders at, derived from a
    row's fixed chrome -- frame border and padding (4), body indent (2),
    {!turn_rail_cells}, and the {!chat_role_label_column} floor -- plus
    {!chat_readable_body_cells}. Below it the pane draws the resize notice
    instead of shredding prose. *)

val message_viewport_supported :
  terminal_rows:int -> terminal_cols:int -> status_rows:int -> bool
(** Whether the full chat frame plus its final newline fits without terminal
    scrolling. Unsupported viewports render a compact resize gate and suppress
    message editing. The width gate admits the pane only at
    {!chat_min_terminal_cols} or wider, where the body column keeps
    {!chat_readable_body_cells} beside the label column, rail, indent, and
    frame. *)

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
  ?origin:origin_display ->
  inner_width:int ->
  height:int ->
  entry list ->
  row list
(** Render chat entries into cell-bounded, UTF-8-safe physical rows and retain
    the newest rows. In a supported viewport, an oversized newest entry keeps
    its first row and latest rows with a typed viewport-gap row between them.
    A smaller caller receives the best bounded fallback: first row, then latest
    row when two rows of height are available.
    An optional hour rail yields first when it would hide the newest entry's
    origin or body; the typed gap counts it, and scrollback still reaches it.

    [markdown] renders one entry into rows already wrapped to the width it is
    given. The whole entry is supplied so a caller can distinguish stable
    history from a growing live source without parsing display text. Supplied
    by the caller so this module keeps no terminal vocabulary; omitted, a body
    is wrapped as the plain text it always was. Every scroll function takes the
    same argument, and passing it to one but not another would measure the pane
    against a different height than it draws. *)

val total_rows :
  ?markdown:(entry:entry -> width:int -> string list) ->
  ?origin:origin_display ->
  ?previous:entry ->
  inner_width:int ->
  entry list ->
  int
(** How many physical rows [entries] render to at this width — what a scroll
    position is measured against. [previous] supplies the entry immediately
    before a suffix, so the suffix does not invent a duplicate hour rail. *)

val scrolled_rows :
  ?markdown:(entry:entry -> width:int -> string list) ->
  ?origin:origin_display ->
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
  ?origin:origin_display ->
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
  ?origin:origin_display ->
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
  ?origin:origin_display ->
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

val span_text : float -> string
(** A span of seconds in the largest unit that still carries a remainder:
    [42s], [2m14s], [11h39m], [8d15h]. At most seven cells, so a column sized
    for the longest reading holds every shorter one. A negative span reads as
    [0s]; a caller that would rather say nothing checks first.

    One ladder. Two callers used to keep their own, with different ceilings,
    and the one that stopped at minutes drew [12045m] for a nine-day-old
    Fusion run. *)

val age_text : now:float -> since:float -> string option
(** How long something has been outstanding, as {!span_text}.

    An age, not a countdown: it says how long a thing has been going so a
    reader can tell slow from stuck. Rendered from a clock the caller passes
    rather than one read here, so a test can state the instant and two rows in
    one frame can share a single read. A clock that moved backwards says
    nothing rather than a negative age. *)
