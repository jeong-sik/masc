(** v2.5 4-tier typography & surface style builders.

    Encodes the strict MASC TUI v2.5 visual hierarchy without SGR dim:
    - Tier 1 ({!anchor}): [text_bright] + [Attr.bold] (hero KPIs, focused titles,
      active selection primary entity, H1/H2, keycap letters).
    - Tier 2 ({!primary}): [text_primary] + Regular (body prose, cell values, chat).
    - Tier 3 ({!structure}): [text_secondary] + Regular/Bold (headers, field labels,
      section sub-headers, inactive tabs).
    - Tier 4 ({!whisper}): [text_muted] + [Attr.italic] (timestamps, empty states,
      AI Thinking traces, blockquotes, field help, hotkey hints, folded counts). *)

module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style

type surface =
  | Canvas     (** [theme.surface_0] — terminal outer canvas, recessed fenced code *)
  | Card       (** [theme.surface_1] — primary cards, top/composer chrome *)
  | Elevated   (** [theme.surface_2] — table headers, active pills, keycaps, section bands *)
  | Selection  (** [theme.selection_bg] — calm active row tint paired with [▎] left rail *)

val surface_bg : Theme.t -> surface -> Color.t

val anchor : ?bg:Color.t -> ?underline:bool -> Theme.t -> Style.t
(** Tier 1: [text_bright] + [Attr.bold] (default [bg = surface_1]). *)

val primary : ?bg:Color.t -> ?bold:bool -> Theme.t -> Style.t
(** Tier 2: [text_primary] + Regular (default [bg = surface_1]). *)

val structure : ?bg:Color.t -> ?bold:bool -> Theme.t -> Style.t
(** Tier 3: [text_secondary] + Regular or [bold] (default [bg = surface_1]). *)

val whisper : ?bg:Color.t -> ?italic:bool -> Theme.t -> Style.t
(** Tier 4: [text_muted] + [Attr.italic] by default (set [~italic:false] only for
    tight punctuation like [·] or [─]; default [bg = surface_1]). Zero SGR dim. *)

val style_of_tier : ?bg:Color.t -> Theme.t -> Theme.typography_tier -> Style.t
(** Map {!Theme.typography_tier} directly to its canonical {!Style.t}. *)

val status :
  ?bg:Color.t ->
  ?bold:bool ->
  ?italic:bool ->
  Theme.t ->
  Theme.status_token ->
  Style.t
(** Semantic status style guaranteed >= 4.5:1 across all 4 surfaces. *)

val accent : ?bg:Color.t -> ?bold:bool -> ?underline:bool -> Theme.t -> Style.t
(** Accent style ([theme.accent]) for rails, active tabs, and links. *)

val ai : ?bg:Color.t -> ?bold:bool -> ?italic:bool -> Theme.t -> Style.t
(** Violet AI/Thinking/Candle style ([theme.status_ai]). *)

val keycap : Theme.t -> Style.t
(** Elevated keycap badge: [text_bright] Bold on [surface_2]. *)

val keycap_label : ?bg:Color.t -> Theme.t -> Style.t
(** Quiet label beside a keycap: [text_muted] Regular (default [bg = surface_1]). *)

val sep_dot : string
(** Spacious metadata separator [" · "] (space + U+00B7 + space). *)
