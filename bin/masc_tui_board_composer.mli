(** Masc_tui_board_composer — draft parsing, formatting, template management,
    and addressing analysis for the MASC TUI Board compose pane. *)

type addressing_kind =
  | Broadcast_all
  | Mentions of string list
  | Unsupported_broadcast of string list
  | Discoverable_unaddressed

val strip_markdown_title_prefix : string -> string
(** [strip_markdown_title_prefix s] removes leading Markdown header marks
    like [# ], [## ], etc., from [s]. Preserves non-header hashtags like [#tag]. *)

val split_draft : string -> string * string
(** [split_draft raw] splits [raw] into [(title, body)]. Leading blank lines
    are skipped to locate the title line; the title is trimmed and has any
    leading markdown header prefix stripped; the remaining lines form the body. *)

val template_for_new_post : unit -> string
(** Starter Markdown text presented when opening an empty post in an external editor. *)

val is_untouched_template : draft:string -> bool
(** Returns true if [draft] matches the starter template or is whitespace only. *)

val analyze_addressing : string -> addressing_kind
(** Parses the draft with {!Board_addressing} and classifies the addressing disposition. *)

val format_addressing_hint : max_cells:int -> addressing_kind -> string
(** Formats a single-line summary with ANSI styling indicating whether keepers
    will be awakened or if the post is discoverable. *)

val compute_caret_position :
  chrome_top_rows:int ->
  cols:int ->
  visible_lines:string list ->
  int * int
(** [compute_caret_position ~chrome_top_rows ~cols ~visible_lines] returns
    the 1-indexed [(row, col)] coordinate for the terminal cursor at the end of
    the draft text. *)
