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
  code : span;
  heading : span;
  quote : span;
  link_text : span;
  link_target : span;
  rule : span;
  bullet : string;  (** Drawn in place of the source's [-], [*] or [+]. *)
  code_gutter : string;  (** Drawn left of every fenced-code row. *)
  quote_gutter : string;
}

val plain_palette : palette
(** A palette whose spans are all empty and whose gutters are ASCII. What the
    reader would see with styling stripped. *)

val render : palette:palette -> width:int -> string -> string list
(** Wrap and style one message body into rows of at most [width] cells.

    Fenced code keeps its own line breaks — wrapping a diff at a word boundary
    destroys the alignment that made it worth fencing — and is hard-split only
    where a line is wider than the row. Everything else wraps at spaces.

    Styling that spans a wrap is reopened on the next row, so a bold sentence
    stays bold past the break instead of ending at it. *)

val inline_segments : string -> (string * string) list
(** The inline parse alone, as [(text, kind)] pairs where kind is one of
    ["plain"], ["strong"], ["emphasis"], ["code"], ["link_text"] or
    ["link_target"]. Exposed so the marker handling can be read directly. *)
