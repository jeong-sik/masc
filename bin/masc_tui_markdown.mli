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
