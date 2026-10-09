type position =
  | Body_byte of { offset : int; expansion : int }
  | Body_label of { block_start : int; field : Masc_tui_markdown.generated_field; byte : int }
  | Thinking_summary_byte of int
  | Thinking_summary_label of { field : Masc_tui_markdown.generated_field; byte : int }
  | Preview_byte of { url : string; index : int; field : Masc_tui_link_preview.card_field; order : Masc_tui_link_preview.card_order; byte : int; expansion : int }
  | Journal_byte of { line : int; field : Masc_tui_message_layout.journal_field; byte : int }

val compare_position : position -> position -> int
(** Original source positions precede generated thinking-summary positions,
    which precede preview and journal fields. Reflow can hide either body
    presentation, but strict-before traversal never resets or cycles between
    their distinct occurrences. *)

type run = {
  text : string;
  positions : position option array;
  visible_rows : (int * Masc_tui_markdown.source_range list) list;
  joins_previous : bool;
}

val of_document : presentation:Masc_tui_message_layout.body_presentation -> body_length:int -> origins:position option array ->
  Masc_tui_markdown.document_render -> run list * bool
(** Compose a document's original ranges through the exact enriched-input
    position map. The bool reports incomplete provenance, including generated
    labels introduced outside the original body without a stable field map. *)

type matched = { body_row : int; position : position; ending_position : position }

val find : needle:string -> before:position option -> body_rows:int -> run list -> matched option
(** Search canonical semantic text case-insensitively, requiring every non-space
    byte to remain visible. Only marked logical-line boundaries may be skipped
    or consume a query space/newline; ordinary word spaces remain significant.
    A repeated search compares stable source positions even if its previous
    occurrence has become clipped or absent. [body_rows] is the actual layout's
    surviving body prefix after trailing empty-row removal. Ordinary semantic
    groups use linear substring matching, including overlapping occurrences.
    Queries without spaces/newlines also use that path after exact skipping
    of marked optional boundaries. Other optional logical-line groups retain a query-prefix frontier
    in O(text * query) time and O(query) memory; neither path imposes a length
    limit or replays recursive branches. *)
