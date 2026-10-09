(** Markdown as terminal rows, for the keeper chat transcript.

    Keepers write markdown: fenced code, backticked identifiers, bold, lists.
    Drawn as plain text those markers are noise that costs width and hides the
    thing they mark — a backticked commit hash reads as a quotation, and a
    fenced diff reads as a paragraph with three stray backticks in it.

    This turns a message body into rows that are already wrapped to the width
    they will be drawn at and already carry their styling. The caller supplies
    the escape codes, so this module holds no terminal vocabulary and its tests
    read the structure rather than a wall of escapes.

    Only what a chat message actually contains is handled. Anything outside it
    stays visible as the literal text the keeper wrote, because dropping a
    marker this does not understand would silently change what was said. *)

type span = string * string
(** The codes that open and close one styling. *)

type palette = {
  strong : span;
  emphasis : span;
  strike : span;
      (** [~~struck~~]. Two tildes, never one: a single [~] is a home
          directory or an approximation far more often than it is a marker. *)
  code : span;
  heading : int -> span;
      (** The codes for a heading of the given level, 1 for [#] through 6.
          A function rather than one span because the level is the only thing
          that says which heading is inside which, and dropping it drew a
          document's every heading the same. Which levels differ, and how, is
          terminal vocabulary and stays with the caller. *)
  quote : span;
  link_text : span;
  link_target : span;
  rule : span;
  bullet : string;  (** Drawn in place of the source's [-], [*] or [+]. *)
  code_gutter : string;  (** Drawn left of every fenced-code row. *)
  code_header : span;
      (** Style for the width-filling header of a language-tagged fence. *)
  code_border : span;  (** Style for that fence's closing border. *)
  quote_gutter : string;
  table_header : span;
  table_gutter : string;
  (** What joins the rule row between columns, in place of the gutter running
      through it. Must measure the same cells as {!table_gutter} or the rule
      stops lining up with the rows it divides. *)
  table_rule_gutter : string;
  (** Draw the outer box. The columns pay for it -- four cells -- so it is a
      choice rather than the default. *)
  table_frame : bool;
  (** Drawn between a table's columns. *)
  (* Styles for fenced code that names a language this module lexes
     (ocaml, bash/sh, json). A fence with no tag, or one naming anything
     else, keeps the single [code] span for the whole body. *)
  code_keyword : span;
  code_string : span;
  code_comment : span;
  code_number : span;
  code_diff_added : span;
      (** A ["```diff"] fence's added line. Applied to the code gutter,
          source, and padding through the available row width. Every hard-split
          chunk carries the same span. *)
  code_diff_removed : span;  (** The same fence's removed row. *)
  code_type : span;  (** Also JSON object keys: a field name reads as one. *)
}

val plain_palette : palette
(** A palette whose spans are all empty and whose gutters are ASCII. What the
    reader would see with styling stripped. *)

val non_colliding_fence_marker : string list -> string option
(** Choose a Markdown fence marker that none of [lines] can close under this
    renderer's own fence grammar. [None] means both supported markers collide.
    Generated blocks must use this authority rather than reimplementing the
    security-sensitive closing predicate. *)

type streaming_render = private {
  rows : string list;
  mutable_source_start : int;
  mutable_row_start : int;
}
(** One canonical render together with its earliest append-sensitive suffix.

    Bytes before [mutable_source_start] belong to closed blocks. The first
    [mutable_row_start] rows are exactly what those bytes contributed to
    [rows]. Both offsets are zero when the document has no closed block.

    The boundaries come from the same block walk that produced [rows]. They
    are not a second Markdown scanner. The suffix is normally the final block;
    it also includes a table or header candidate before an incomplete terminal
    line that an append can still turn into its delimiter or next row. *)

val render_streaming :
  palette:palette -> width:int -> string -> streaming_render
(** Render one growing message and identify the append-sensitive suffix.

    The returned rows are byte-for-byte the same rows as {!render}. The extra
    offsets let a caller keep closed blocks and render the current block again
    after more source arrives. *)

type source_range = {
  start_byte : int;
  end_byte : int;
}
(** Half-open byte interval in an inline render's [semantic_text]. These are
    UTF-8 byte positions, not terminal columns or indices in styled rows. *)

type mapped_row = {
  text : string;
  source_ranges : source_range list;
}

type inline_render = {
  semantic_text : string;
  source_positions : int option array;
    (** For each semantic byte, its original input byte. Generated inline
        separators are [None]. Code-line positions refer to concatenated lexer
        pieces. This map composes with the caller's source field/block range. *)
  mapped_rows : mapped_row list;
}

val render_inline_with_spans :
  palette:palette -> width:int -> prefix:string -> continuation:string ->
  string -> inline_render
(** Render one inline body through the same token wrapper as ordinary Markdown
    rendering. [semantic_text] is the parsed inline text before physical
    wrapping; styling markers are interpreted by the existing inline parser.
    Each row identifies the exact semantic byte ranges it displays. A space
    omitted at a wrap remains in the canonical semantic stream. ANSI styling
    and generated prefix/continuation text have no source range.

    This is an inline primitive, not a complete document or chat-search map.
    Callers must retain a typed source-block identity outside these ranges. *)

type block_render = {
  block_rows : string list;
  inline_source : inline_render option;
}

val render_block_with_spans : palette:palette -> width:int -> string -> block_render
(** Render one non-fenced, non-table source line through the ordinary block
    dispatcher, retaining its inline source map. Heading, quote and list
    syntax use that dispatcher's existing grammar. Generated rules and empty
    rows have no inline source. [block_rows] includes outer block styling;
    source ranges refer to canonical inline semantic bytes, while
    [inline_source.source_positions] indexes the original line, including the
    offsets removed by heading/list/quote syntax and trimming. A document
    caller supplies the line's stable source identity. *)

type table_cell_source = {
  table_row : int;
  table_column : int;
  rendered_row : int;
  cell_text : string;
  source_positions : int option array;
  rendered_start_cell : int;
  visible_range : source_range;
}
(** Zero-based semantic cell identity (header row is zero) and its exact
    physical row, starting display cell and visible byte prefix. Each semantic
    byte maps through [source_positions] to the complete input table's byte
    offset. Inline delimiters and trimmed cell margins are excluded; spaces
    inserted when overflow columns join have [None]. Borders, padding and cut
    marks have no source range. The caller retains the table's document base.
    [rendered_start_cell] counts terminal cells, not ANSI or UTF-8 bytes. *)

type table_render = {
  table_rows : string list;
  cell_sources : table_cell_source list;
}

val render_table_with_spans : palette:palette -> width:int -> string -> table_render option
(** Render one complete table through the existing table grammar and geometry.
    Return [None] if the text is not exactly one table (apart from a synthetic
    trailing newline). Cell identity and canonical inline text survive width
    changes; a narrower pane may expose only a prefix of a cell. Palette style
    spans must contain only zero-width terminal controls (or be empty), as in
    production; visible debugging tags change cell geometry and are not a
    semantic-to-styled fit map. *)

val render_lexed_line_with_spans :
  palette:palette -> width:int -> (string * string) list -> inline_render
(** Render one lexer-owned code line, retaining exact byte ranges through hard
    wrapping, diff bands and repeated gutters. Input pieces are unstyled text
    paired with lexer kinds, as in the existing fenced-code renderer. Generated
    gutters, styling and band padding have no semantic range. The document
    caller retains the source fence and logical-line identity. *)

type generated_field = Fence_language | Mermaid_diagnostic

type semantic_origin =
  | Original of source_range
  | Generated of { block_start : int; field : generated_field; byte : int }

type semantic_run = {
  joins_previous : bool;
  semantic_text : string;
  origins : semantic_origin option array;
  visible_rows : (int * source_range list) list;
}
(** Width-independent semantic text with an origin per byte and the exact
    semantic ranges surviving on each zero-based output row. A wrap may omit
    whitespace; truncation and canvas overwrites may hide other bytes. Search
    must check visible coverage rather than treating hidden bytes as displayed.
    [None] origins are generated inline/overflow separators; searchable generated
    labels have typed field identities. Runs are not promised in source order:
    diagram layout and parser-owned label order can differ. [joins_previous]
    marks adjacent logical prose/code lines whose source newline remains an
    optional search boundary; independent cells and fields do not join. *)

type document_mapping =
  | Complete_document
  | Incomplete_document of (int * Masc_tui_mermaid.missing_label list) list

type document_render = {
  document_rows : string list;
  semantic_runs : semantic_run list;
  mapping : document_mapping;
}

val render_document_with_spans : palette:palette -> width:int -> string -> document_render
(** Observe semantic text and visibility through the same streaming block,
    table and fence dispatcher used by {!render}. Original ranges index the
    complete input document, including fence/line offsets. Mermaid drawings
    compose parser label ranges into the same original bytes shown by their
    narrow-pane source fallback. [Incomplete_document] requires an explicit
    consumer policy; missing provenance must not be treated as decoration.
    Generated borders, gutters and styling have no semantic run. *)

val render : palette:palette -> width:int -> string -> string list
(** Wrap and style one message body into rows of at most [width] cells.

    Fenced code keeps its own line breaks — wrapping a diff at a word boundary
    destroys the alignment that made it worth fencing — and is hard-split only
    where a line is wider than the row. Every split chunk is a separate terminal
    row; concatenating them recovers the complete source line. Typed added and
    removed diff rows fill each such row, including the code gutter and trailing
    cells, with their whole-line span. A tagged fence also draws a header
    containing its language, and a closed tagged fence draws a closing border.
    Everything else wraps at spaces.

    A fence whose tag names a language this module lexes — [ocaml], [ml],
    [bash] or friends, [json] — has its body tokenised whole: reserved words
    as keywords, string and char literals as strings, OCaml comments (nested,
    multi-row included) as comments, numbers as numbers, and capitalised
    identifiers or JSON object keys as types. Any other tag, or none, keeps
    the single code span for the whole body.

    Styling that spans a wrap is reopened on the next row, so a bold sentence
    stays bold past the break instead of ending at it. *)

val inline_segments : string -> (string * string) list
(** The inline parse alone, as [(text, kind)] pairs where kind is one of
    ["plain"], ["strong"], ["emphasis"], ["strike"], ["code"], ["link_text"] or
    ["link_target"]. A Markdown link keeps its label as ["link_text"] and a
    printable [" (target)"] as ["link_target"], so the two remain distinct in
    copied and NO_COLOR text. Exposed so the marker handling can be read
    directly. *)
