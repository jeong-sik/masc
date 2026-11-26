(** Shared pure drawing, formatting, and layout helpers for the Domain &
    Telemetry screens ([Knowledge], [Runtime], [Infra]).

    v2.5 Visual Craft:
    - Zero global mutable state, zero Eio/network imports, zero SGR dim.
    - Delegates 4-tier typography to {!Masc_tui_ui.Typography} (including active
      Tier-4 [Attr.italic] whispers), structural primitives to {!Masc_tui_ui.Card}
      ([border_subtle] hairlines, [Left_rail] accent bars, [surface_2] bands),
      and responsive spacing to {!Masc_tui_ui.Layout}.
    - Strictly width-1 geometric glyphs from {!Masc_tui_core.Glyph}. *)

open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

type pill = {
  label : string;
  active : bool;
  tone : Theme.status_token option;
  glyph : Glyph.t option;
}

val default_caps : Presenter.capabilities
val is_wide_split : Rect.t -> bool
val layout_bp : model:Model.t -> rect:Rect.t -> Layout.breakpoint
val body_rect : bp:Layout.breakpoint -> Rect.t -> Rect.t
val pad_content : bp:Layout.breakpoint -> ?pad_y:int -> Rect.t -> Rect.t
val clamp_index : int -> int -> int
val safe_take : int -> 'a list -> 'a list

(** {1 v2.5 4-Tier Typography & Surface Styles} *)

val anchor_style :
  theme:Theme.t -> ?bg:Theme.rgb -> ?underline:bool -> unit -> Style.t

val text_style :
  theme:Theme.t -> ?bg:Theme.rgb -> ?attrs:Attr.t -> unit -> Style.t

val secondary_style :
  theme:Theme.t -> ?bg:Theme.rgb -> ?attrs:Attr.t -> unit -> Style.t

val muted_style :
  theme:Theme.t -> ?bg:Theme.rgb -> ?attrs:Attr.t -> unit -> Style.t

val whisper_style :
  theme:Theme.t -> ?bg:Theme.rgb -> ?italic:bool -> unit -> Style.t

val accent_style :
  theme:Theme.t -> ?bg:Theme.rgb -> ?attrs:Attr.t -> unit -> Style.t

val ai_style :
  theme:Theme.t -> ?bg:Theme.rgb -> ?bold:bool -> ?italic:bool -> unit -> Style.t

val status_style :
  theme:Theme.t ->
  ?bg:Theme.rgb ->
  ?attrs:Attr.t ->
  Theme.status_token ->
  Style.t

val selection_style : theme:Theme.t -> ?attrs:Attr.t -> unit -> Style.t

val row_text_style :
  theme:Theme.t ->
  selected:bool ->
  focused:bool ->
  bg:Theme.rgb ->
  Style.t
(** Primary text style for selectable list rows: bold {!anchor_style} only when
    [selected && focused], and calm {!text_style} (on [surface_2] when blurred,
    or [surface_1] when unselected) otherwise. *)

val make_badge :
  ?glyph:Glyph.t -> ?tone:Theme.status_token -> string -> Card.badge

val card_spec :
  ?subtitle:string ->
  ?badge:Card.badge ->
  ?hotkey:string ->
  ?footer_hint:string ->
  ?focused:bool ->
  ?elevated:bool ->
  string ->
  Card.spec

val sanitize_single_line : string -> string

val put_clipped :
  grid:Cell_grid.t ->
  clip:Rect.t ->
  x:int ->
  y:int ->
  max_w:int ->
  style:Style.t ->
  string ->
  int

val put_right :
  grid:Cell_grid.t ->
  clip:Rect.t ->
  right_x:int ->
  y:int ->
  max_w:int ->
  style:Style.t ->
  string ->
  int

val put_link :
  grid:Cell_grid.t ->
  clip:Rect.t ->
  x:int ->
  y:int ->
  max_w:int ->
  style:Style.t ->
  uri:string ->
  string ->
  int

val put_kv :
  grid:Cell_grid.t ->
  clip:Rect.t ->
  x:int ->
  y:int ->
  max_w:int ->
  theme:Theme.t ->
  ?bg:Theme.rgb ->
  ?key_w:int ->
  key:string ->
  ?value_style:Style.t ->
  string ->
  unit

val selected_row_bg : theme:Theme.t -> focused:bool -> Theme.rgb
(** Background RGB for a selected row: [selection_bg] when the owning pane
    has keyboard focus, else muted [surface_2]. *)

val paint_selected_row_bg :
  grid:Cell_grid.t ->
  clip:Rect.t ->
  row_rect:Rect.t ->
  theme:Theme.t ->
  ?focused:bool ->
  ?tone:Theme.status_token ->
  unit ->
  unit
(** Fill [row_rect] with calm [selection_bg] and a 1-cell {!Glyph.Left_rail}
    ([▎]) when [focused = true] (default), or muted [surface_2] without an
    accent rail when [focused = false]. *)

val draw_pills :
  grid:Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  ?bg:Theme.rgb ->
  ?right_hint:string ->
  pill list ->
  int

val draw_divider :
  grid:Cell_grid.t ->
  rect:Rect.t ->
  y:int ->
  theme:Theme.t ->
  ?bg:Theme.rgb ->
  ?pad_x:int ->
  ?label:string ->
  unit ->
  unit

val draw_empty_notice :
  grid:Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  ?bg:Theme.rgb ->
  ?hint:string ->
  string ->
  unit
(** Render a calm Tier-4 italic centered empty-state message (plus optional
    second-line hint) inside [rect]. *)

val draw_observed_placeholder :
  grid:Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  lang:Say.lang ->
  ?bg:Theme.rgb ->
  ?filter_query:string ->
  ?empty_msg:Say.t ->
  'a Observed.t ->
  unit

val format_age : now_unix:float -> float -> string
val format_countdown : now_unix:float -> float -> string
val extract_hhmmss : string -> string
val format_local_hhmmss : tz_offset_sec:int -> string -> string
val format_local_datetime : tz_offset_sec:int -> string -> string
val wrap_lines : max_width:int -> string -> string list
val short_hash : ?len:int -> string -> string
val human_account_alias : Wire_runtime.account_usage -> string
val json_kv_summary : Yojson.Safe.t -> (string * string) list
val contains_ci : needle:string -> string -> bool
val extract_embedded_json : string -> (string * Yojson.Safe.t) option
val redact_secrets_in_text : string -> string
