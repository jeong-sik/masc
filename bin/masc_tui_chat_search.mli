type body_identity
(** The identity of an entry's presented body text. *)

val body_identity : string -> body_identity

(** Every position names the text it indexes as well as its place: a body by
    its identity, a generated label, preview field or journal field by its
    value. A place can hold another version of its text under the same
    anchor: a recorded reply stands where the streamed text was, the
    OpenGraph fetch replaces a synthesized title or description, a diagnostic
    label is regenerated for the current width. An offset into the old
    version names no byte of the new one, so the same offset in the new
    version is a different position. *)
type position =
  | Body_byte of { body : body_identity; offset : int; expansion : int }
  | Body_label of { body : body_identity; block_start : int; field : Masc_tui_markdown.generated_field;
      value : string; byte : int }
  | Thinking_summary_byte of { body : body_identity; offset : int }
  | Thinking_summary_label of { body : body_identity; field : Masc_tui_markdown.generated_field;
      value : string; byte : int }
  | Projected_byte of { body : body_identity; projection : Masc_tui_message_layout.projected_body;
      offset : int; expansion : int }
  | Projected_label of { body : body_identity; projection : Masc_tui_message_layout.projected_body;
      block_start : int; field : Masc_tui_markdown.generated_field; value : string; byte : int }
  | Preview_byte of { url : string; index : int; field : Masc_tui_link_preview.card_field; order : Masc_tui_link_preview.card_order;
      value : string; byte : int; expansion : int }
  | Journal_byte of { line : int; field : Masc_tui_message_layout.journal_field; value : string; byte : int }
  | Request_byte of { request : string; byte : int }
      (** A byte of a request id the entry was submitted or executed under.
          The id is not drawn text; a match on it lands on the entry's first
          body row. *)

val compare_position : position -> position -> int
(** Request id positions precede every drawn position, so a repeat walks an
    entry's drawn text before its request ids. Original source positions
    precede generated thinking-summary positions,
    which precede projected-body positions, which precede preview and journal
    fields. Positions of different versions of one text order by the text
    identity before the offset. Projected positions order by projection
    before offset. Reflow or a
    view stance can replace one body presentation with another, but
    strict-before traversal never resets or cycles between their distinct
    occurrences. This is source order; {!find} ranks the labels of a drawn
    Mermaid diagram by their drawn row instead. *)

val presentation_of_position : position -> Masc_tui_message_layout.body_presentation option
(** The body presentation whose text a position indexes. [None] for preview
    fields, journal fields and request ids, which do not index the body text. *)

type run = {
  text : string;
  positions : position option array;
  visible_rows : (int * Masc_tui_markdown.source_range list) list;
  joins_previous : bool;
  reading : Masc_tui_markdown.reading_order;
}

val of_document : presentation:Masc_tui_message_layout.body_presentation -> body:body_identity ->
  body_length:int -> origins:position option array -> Masc_tui_markdown.document_render -> run list * bool
(** Compose a document's original ranges through the exact enriched-input
    position map. Generated labels of the body take [body] as their identity.
    The bool reports incomplete provenance: drawn labels the
    document could not map, or generated labels introduced outside the
    original body without a stable field map. The runs are the completely
    mapped ones; a run holding an unmapped generated label is left out rather
    than searched with a gap where its label was. *)

type matched = { body_row : int; position : position; ending_position : position }

val find : needle:string -> before:position option -> body_rows:int -> run list -> matched option
(** Search canonical semantic text case-insensitively, requiring every non-space
    byte to remain visible. Case-insensitive is Unicode default caseless
    matching: the query and the text are both folded with the full
    Case_Folding property, and a match that covers part of a folded scalar
    reports that whole source scalar. Canonical equivalence (a precomposed
    letter against a base letter and a combining mark) is not normalized.
    Only marked logical-line boundaries may be skipped
    or consume a query space/newline; ordinary word spaces remain significant.
    A repeated search compares stable source positions even if its previous
    occurrence has become clipped or absent. Occurrences are ranked in source
    order, except that the labels of one drawn Mermaid diagram are ranked by
    the last row each label is drawn on, then by source position, and the
    drawing sits among other positions at its earliest label. When a width
    change switches a diagram between its drawing and its source fallback,
    the two rankings can differ, so a repeat that crosses the switch can
    revisit or pass over a label of that diagram. A repeat whose previous
    occurrence indexes a version of a body, label, preview field or journal
    field that the same place no longer holds treats every position of that
    place as older, so the replaced text is searched whole. [body_rows] is the actual layout's
    surviving body prefix after trailing empty-row removal. Ordinary semantic
    groups use linear substring matching, including overlapping occurrences.
    Queries without spaces/newlines also use that path after exact skipping
    of marked optional boundaries. Other optional logical-line groups retain a query-prefix frontier
    in O(text * query) time and O(query) memory; neither path imposes a length
    limit or replays recursive branches. *)
