(** Shared typography, section rules, aligned key-value grids, guided prose
    blocks, action callout cards, and docked bottom sheets for MASC TUI.

    Pure by construction: no terminal I/O, no mutation, no unhandled
    exceptions. All external wire text passes through terminal control
    sanitisation before styling or display-width measurement. *)

(** One entry in an aligned key-value grid. *)
type kv_field =
  { label : string
  ; value : string
  ; value_tone : string
  }

val kv : ?tone:string -> string -> string -> kv_field
(** [kv ?tone label value] builds a {!kv_field} with [value_tone] defaulting
    to [""] (terminal default foreground). *)

val section_rule :
  width:int ->
  ?indent:int ->
  ?badge:string ->
  ?badge_tone:string ->
  string ->
  string
(** [section_rule ~width ?indent ?badge ?badge_tone title] draws a full-width
    hairline section header ([── Title ───────────── badge]) bounded strictly
    within [width] display cells. Uses {!Masc_tui_ansi.Theme.border_muted} for
    the rule, {!Masc_tui_ansi.Ansi.bold} and
    {!Masc_tui_ansi.Theme.section_heading} for the title (never [Theme.info]),
    and [badge_tone] (default {!Masc_tui_ansi.Theme.recede}) for [badge]. *)

val hairline : width:int -> ?indent:int -> ?tone:string -> unit -> string
(** [hairline ~width ?indent ?tone ()] renders a calm single-cell horizontal
    divider ([────...]) bounded strictly within [width] display cells using
    {!Masc_tui_ansi.Theme.border_muted} by default. *)

val section_header :
  width:int ->
  ?indent:int ->
  ?subtitle:string ->
  ?right:string ->
  string ->
  string
(** Calm agy-style section heading ([Title · subtitle · right]) rendered with
    bold {!Masc_tui_ansi.Theme.section_heading} for [title] and
    {!Masc_tui_ansi.Theme.recede} for metadata, bounded within [width] cells. *)

val preview_footer_hints :
  width:int ->
  ?indent:int ->
  Masc_tui_card.inline_key list ->
  string
(** Renders a calm single-line inline key hint strip
    ([key label · key label ...]) using
    {!Masc_tui_ansi.Theme.footer_key_style} on keys and
    {!Masc_tui_ansi.Theme.recede} on descriptions, dropping trailing items as
    needed to fit within [width] display cells. *)

val docked_preview :
  width:int ->
  height:int ->
  ?indent:int ->
  ?eyebrow:string ->
  ?title:string ->
  ?meta:string ->
  ?footer_hints:Masc_tui_card.inline_key list ->
  string list ->
  string list
(** Fixed-height calm bottom docked inspector separated by a top hairline rule
    and optional metadata header and inline footer hints. Always returns exact
    [height] lines when [width > 0 && height > 0] so parent list rows stay
    stationary (RFC §8). *)

val kv_rows :
  width:int ->
  ?indent:int ->
  ?label_style:string ->
  ?max_label_cells:int ->
  kv_field list ->
  string list
(** Aligned two-column key-value rows (RFC tui-one-screen-grammar §5.2).
    Labels take [label_style] (default {!Masc_tui_ansi.Theme.recede}) and align
    in display cells across Korean and ASCII text; wrapped continuation lines
    hang-align under the value column. When the value column would have fewer
    than 12 cells, falls back cleanly to stacked label-over-value rows. *)

val split_numbered_paragraphs : string -> string list
(** Splits inline numbered evidence/step clauses (e.g. [(1) ... (2) ... (3) ...])
    at boundary whitespace preceding parenthesised numerals without mutating or
    dropping non-separator characters. Explicitly written newlines are preserved
    ahead of numbered splits. *)

val prose_block :
  width:int ->
  ?indent:int ->
  ?guide_style:string ->
  ?break_numbered:bool ->
  ?tone:string ->
  string ->
  string list
(** Renders multi-paragraph wire prose with a left vertical guide rail ([│ ])
    in [guide_style] (default {!Masc_tui_ansi.Theme.border_muted}), optional
    numbered-paragraph separation ([~break_numbered:true]), and terminal-safe
    word wrapping bounded within [width] display cells. *)

val card_style : unit -> Masc_tui_card.style
(** Shared SSOT {!Masc_tui_card.style} reading {!Masc_tui_ansi.Theme} tokens. *)

val panel_border_accent : Masc_tui_theme.panel_role -> string option
(** Optional btop-style border SGR for [role], or [None] for [Panel_neutral]
    or when the active palette emits an empty accent. *)

val action_callout_card :
  ko:bool ->
  width:int ->
  role:Masc_tui_theme.panel_role ->
  title:string ->
  status:Masc_tui_card.status ->
  next_step:string ->
  summary_clauses:string list ->
  footer_keys:Masc_tui_card.inline_key list ->
  string list
(** Sleek {!Masc_tui_card.render}-backed top status and action banner showing
    the current phase status, next operator instruction, summary clauses, and
    bottom-border inline hotkeys. *)

val bottom_sheet :
  ko:bool ->
  width:int ->
  height:int ->
  role:Masc_tui_theme.panel_role ->
  title:string ->
  ?status:Masc_tui_card.status ->
  ?count:Masc_tui_card.count ->
  ?scrollbar:Masc_tui_card.scrollbar ->
  footer_keys:Masc_tui_card.inline_key list ->
  body:(cells:int -> string list) ->
  unit ->
  string list
(** Fixed-height docked Bottom Sheet backed by {!Masc_tui_card.render}, so
    inspecting a selected row keeps parent list rows stationary (RFC §8). *)
