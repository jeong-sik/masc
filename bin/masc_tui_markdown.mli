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
  quote_gutter : string;
  table_header : span;
  table_gutter : string;
  (** Drawn between a table's columns. *)
  (* Styles for fenced code that names a language this module lexes
     (ocaml, bash/sh, json). A fence with no tag, or one naming anything
     else, keeps the single [code] span for the whole body. *)
  code_keyword : span;
  code_string : span;
  code_comment : span;
  code_number : span;
  code_type : span;  (** Also JSON object keys: a field name reads as one. *)
}

val plain_palette : palette
(** A palette whose spans are all empty and whose gutters are ASCII. What the
    reader would see with styling stripped. *)

val render : palette:palette -> width:int -> string -> string list
(** Wrap and style one message body into rows of at most [width] cells.

    Fenced code keeps its own line breaks — wrapping a diff at a word boundary
    destroys the alignment that made it worth fencing — and is hard-split only
    where a line is wider than the row (a row past the width also keeps the
    single code span: alignment outranks colour). Everything else wraps at
    spaces.

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
    ["plain"], ["strong"], ["emphasis"], ["code"], ["link_text"] or
    ["link_target"]. Exposed so the marker handling can be read directly. *)
