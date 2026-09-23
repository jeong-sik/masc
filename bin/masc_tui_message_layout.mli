(** What the mark beside a Skill row says about the row, which is not the same
    question as what the row's words say. The words carry the state -- read,
    delivered, used, and the three that are not steps of that life -- and the
    mark carries how far the reader should trust it: still moving, finished,
    finished without the evidence it should have, or failed.

    [Skill_settled] covers every state a skill's life ends in, whether or not
    a tool followed. That difference is the row's to spell; a mark saying it
    would need a fifth shape for a distinction the line already makes in
    words, and the tone that used to be named for one of the two states read
    as a claim the mark does not make. *)
type skill_tone =
  | Skill_live
  | Skill_settled
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

(** What arrived from outside this conversation and landed between its turns.

    Only what the types already know. A line this pane wrote in answer to
    something typed at it ([Message_local]) is not an arrival. Neither is
    [Sent_by_operator] from another surface: that one is an arrival in fact,
    but the surface lives in the label's text and not in the constructor, and
    a distinction cut out of a string is the type pretending to know. *)
type siding =
  | Siding_journal  (** A Memory OS journal commit. *)
  | Siding_arrival
      (** Another agent's broadcast, a connector, a second operator. *)

type turn_rail =
  | Rail_opens  (** The turn's first row. *)
  | Rail_says
      (** The turn talking: the Keeper's reply, the operator's prompt, the
          error it ended on. *)
  | Rail_does
      (** What the turn did to get there -- reasoning, tool calls, a skill.
          Drawn as a branch off the trunk, because a turn's work is
          subordinate to the turn and was reading as a sibling of it. *)
  | Rail_stands
      (** A turn of one row that did work: it opens and closes on that line,
          so it branches off nothing. Apart from {!Rail_does} because a run of
          them is a run of turns, and drawn as a branch they read as one
          turn's several branches -- the boundary between them disappeared. *)
  | Rail_closes  (** The last row of a turn that has finished. *)
  | Rail_joins of siding
      (** Belongs to no turn and landed while one was running. It joins the
          conversation's line from the left rather than breaking it: the turn
          it arrived inside neither produced it nor read it, and drawing it as
          one of that turn's rows would say both. *)
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

(** What a press on a row opens. A variant rather than a bool because the
    input layer must not recover the answer from the glyphs the row drew:
    changing that text would kill the click with nothing to report. *)
type row_action =
  | Action_none
  | Action_unfold_argument

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

(** Which way a fact moved in one Memory journal revision. *)
type journal_sign = Journal_added | Journal_removed

(** What a fact's category asks of a reader, which is all its colour says.
    Read off the producer's closed category sum at decode, so a category this
    build does not know reads as a fact rather than borrowing a colour that
    would say something about it. *)
type journal_tone =
  | Tone_code_change
  | Tone_learning  (** A lesson or a validated approach. *)
  | Tone_intent  (** A preference, goal or constraint. *)
  | Tone_blocker
  | Tone_fact

(** One line of a Memory journal revision as decoded: a fact it added or
    removed, or a memory it let go and why. They arrive typed because the
    pane draws them in columns -- sign and category at the left, the claim
    wrapped under itself -- and text would have to be read back to find
    where one column ends. *)
type journal_line =
  | Journal_fact of
      { sign : journal_sign; category : string; tone : journal_tone; claim : string }
  | Journal_drop of { memory_id : string; reason : string }

(** What a row says about the Librarian's pass over the journal. A run of
    failed passes is one state the chat header names while it lasts, not a
    row between every pair of turns. *)
type memory_pass =
  | Pass_committed  (** The pass committed a revision. *)
  | Pass_failed of { kind : string }
      (** The pass failed; [kind] is the server's word for how. *)
  | No_pass
      (** Every row that reports no pass: a journal entry that could not be
          read, a neutral system row sharing the Memory lane, and every row
          outside it. *)

type entry = {
  style : style;
  timestamp : string;
  timeline_bucket : timeline_bucket option;
      (** The civil-hour rail this entry belongs under. [None] is reserved for
          rows without a trustworthy observation time; they do not invent a
          timeline heading from display text. *)
  span_clock : string option;
      (** The pane-level span clock for a turn block's head row
          ([Rail_opens]). Folded into the body text *before* wrapping, so it
          consumes body budget like any other word and no row exceeds the
          block's wrap width. [None] on every other row; nothing shifts when
          a turn has no span to say. *)
  speaker : string;
      (** The label {!role_label} was aligned from, whole. The gutter cuts a
          long name to its column; the origin heading under {!Origin_row}
          has the pane's width and draws this instead. *)
  role_label : string;
  role_label_mark_cells : int;
      (** Cells the speaker mark occupies at the head of {!role_label}, from
          {!role_label_mark_cells}. Zero when the column was too narrow to keep
          the mark. Carried on the entry because the caller is what chose the
          column, and read back by the renderer to style the mark and the
          label differently: colour says status, the label only says kind. *)
  request_label : string;
      (** The turn this entry belongs to, for grouping: rows of one request
          share a heading. Never drawn -- the grouping is what a reader sees. *)
  body : string;
  journal : journal_line list;
      (** A Memory journal revision's lines, drawn under {!body} in columns
          ({!journal_rows}). Empty for every other entry, and for a journal
          row drawn as its one-line summary. A markdown renderer passed to
          {!rows_of_entry} draws them with the body; without one they are
          drawn plain. *)
  markdown_source : markdown_source;
  turn_rail : turn_rail;
      (** Which piece of its turn's bracket this entry draws. Carried on the
          entry because only the caller knows the turn's extent: the layout
          sees one entry at a time. *)
  action : row_action;
      (** What a press on this entry's first row opens. Carried on the entry
          because the entry is where the folding was decided; the rows below
          it are continuations of one decision, not decisions of their own. *)
}

(** The sign column's glyph: [+] for an added fact, [−] (U+2212) for a
    removed one. *)
val journal_sign_text : journal_sign -> string

(** What a piece of a {!journal_rows} row is, for the renderer to colour.
    A category carries its tone, which is what its colour follows. *)
type journal_piece =
  | Journal_piece_sign of journal_sign
  | Journal_piece_category of journal_tone
  | Journal_piece_claim
  | Journal_piece_drop
  | Journal_piece_space

(** A revision's lines in two columns at [width] cells: the sign and
    category at the left, padded to the widest category among [lines], and
    the claim wrapped under itself, with a blank row between lines. Where the
    claim's column would be narrower than the lead beside it, the claim wraps
    at the full width under its lead. Each row is its pieces in order. *)
val journal_rows : width:int -> journal_line list -> (string * journal_piece) list list

type metadata =
  | Timeline_break of timeline_bucket
      (** The first entry in a different civil hour. It is structural metadata
          so scrolling and search measure the same row the renderer paints. *)
  | Origin of {
      clock : string option;
          (** The entry's timestamp where the entry has a trustworthy time
              ([timeline_bucket] is [Some]); [None] where it does not, so the
              heading draws no clock rather than the placeholder text. *)
      speaker : string;
      role_label : string;
    }
  | Continued_at of { clock : string }
      (** Only emitted where the entry has a trustworthy time: a continuation
          that cannot say when it moved has nothing to draw. *)
(** A new origin carries every field the renderer needs for its heading. A
    later row from the same origin carries only its new clock, so callers
    never have to parse display text to decide what should be highlighted. *)

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
(** Where a message's origin is drawn. [Origin_inline] is the chat default
    (see [Masc_tui_types.create_state]); its clock is drawn only on the rows
    where the minute moved. [Origin_bare] drops that clock, and [Origin_row]
    gives each turn a heading row with the speaker and the full timestamp. Folding headings into the
    gutter hands their rows back to the conversation: eight speakers taking
    turns otherwise spend eight rows of a forty-row pane on headings.

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
          after it, and the blank run a line someone else wrote steps in by
          ({!inbound_indent}). Zero where neither is drawn, so a
          pane that never shows one pays nothing for it. The renderer draws
          these cells in the quiet tone: the rail is structure, and colour on
          this row is already spent saying status. *)
  gutter_clock_cells : int;
      (** Cells of {!gutter} between the rail's end and the mark's start that
          the renderer paints as the receded clock column, trailing space
          included. A full inline row holds six -- five for the clock, one
          for the space after it -- with blank digits where the minute
          repeated, since the column is part of the margin's width even where
          there is nothing to read. A narrow pane caps the count: the label's
          cells are paid for first, and a partial clock is context rather
          than an identifier.

          Zero where the gutter has no separately paintable clock boundary.
          {!Origin_bare} draws no clock; metadata rows and wrapped
          continuations hold no gutter content of their own; and a
          continued-speaker row does draw a clock, but its whole span past
          the rail is receded as one piece, so no boundary is exported for
          it. The mark after these cells keeps the row's one colour. *)
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
          under where it started. A line someone else wrote carries its
          {!inbound_indent} here in every mode; on a heading row that blank run
          is all the gutter holds, and the heading starts after it. *)
  action : row_action;
      (** What a press on this row opens, {!Action_none} on every row but the
          first of an entry that carries one. The fold marker sits at the end
          of the first row, so that is the row a press lands on. *)
}

val siding_lead_cells : int

val turn_rail_gutter : turn_rail -> string
(** The whole margin for one row, {!turn_rail_cells} wide, siding run
    included. Concatenate this rather than {!turn_rail_glyph}: a caller that
    drew the glyph and padded the rest itself would put the line in a
    different column on the rows that have a siding. *)

val rail_for_style : work:turn_rail -> speech:turn_rail -> style -> turn_rail
(** Which of two rail pieces a row of this style takes: [work] for reasoning,
    tool calls and skills, [speech] for everything the turn says. Asked by
    both the running turn and the turn of a single row, because what a row is
    does not depend on how many rows came with it. *)

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
(** Approximate the display cells of a terminal that draws extended grapheme
    clusters as indivisible layout pieces. Renderer-owned ANSI CSI and
    combining marks have zero width. A cluster that opens with an emoji
    scalar and holds VS16, a zero width joiner, a skin tone, or a tag flag
    takes two cells whatever its scalars add up to; one holding VS15 takes
    one. A cluster opening with any other scalar sums its parts, so a joiner
    inside a Devanagari conjunct changes nothing. *)

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

val count_noun : ?plural:string -> int -> string -> string
(** [count_noun 1 "line"] is ["1 line"], [count_noun 2 "line"] is ["2 lines"].
    [?plural] names an irregular plural: [count_noun ~plural:"entries" 3 "entry"]. *)

val cut_mark : string
(** What a cut leaves behind in place of the text it dropped.

    Exported because the marquee in {!Masc_tui_roster_pane} is a cut this
    module does not make: it holds a window open and moves the name behind it,
    marking whichever end still has text. Spelling the glyph there again is how
    one cut site gets left behind when the mark changes. *)

val cut_mark_cells : int
(** Cells {!cut_mark} spends, so a caller budgeting around one mark -- or, in
    the marquee's case, around two -- takes the number from the mark rather
    than writing it. *)

val fit_width : string -> int -> string
(** [fit_width text width] pads [text] to [width] cells, or cuts its tail to
    fit and marks the cut with ["…"] -- the same mark {!fit_middle} uses, so
    a frame drawing both cuts spells the one fact one way.

    For a fixed column whose head carries the meaning. Where both ends carry
    -- an identifier, an address -- use {!fit_middle}. *)

val pad_left : string -> int -> string
(** [pad_left text width] right-aligns [text] in [width] cells, cutting it
    with {!fit_width} when it does not fit. Printf's ["%*s"] counts bytes,
    which leaves a cell holding a multi-byte mark short of its column. *)

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
(** Keep the complete input when it fits. Overflow uses a leading […] and the
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

val fit_speaker :
  ?column:int -> speaker:string -> surface:string option -> unit -> string
(** The label for a row someone else put here. Names the speaker, and adds the
    surface they came in by only when both fit the column: cut as one string
    the pair keeps the surface and loses the name, and an arrival's siding
    already says the row came from outside. *)

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

val clause_separator : string
(** What a header row puts between two clauses: [" · "]. *)

val pack_clauses : max_cells:int -> string list -> string list
(** Join [clauses] with {!clause_separator} into rows of at most [max_cells],
    so a row ends where a clause ends.
    A clause carries its own qualifier -- "0 failures since server start" says
    the count restarts with the server, and a row ending at "0 failures" says a
    running total -- so an arbitrary break inside one changes what the row
    claims. A clause too wide for a row on its own is wrapped by
    {!wrap_words}; nothing is dropped and nothing is cut. *)

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

val inbound_indent_cells : int
(** How far a line someone else wrote steps in: two cells. *)

val inbound_indent : entry -> int
(** Cells a line someone else wrote ({!Inbound}) steps in from the
    conversation (RFC chat-turn-rail-and-side-lanes §4.6); the renderer draws
    a bar in the sender's colour down that block's left edge. Zero for every
    other style. *)

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
    [42s], [2m14s], [11h39m], [8d15h], and from a hundred days the days alone,
    [255d]. At most six cells below a hundred thousand days, so a column sized
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
