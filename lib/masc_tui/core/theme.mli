(** Semantic color themes with Oklab perceptual math and guaranteed WCAG 2.1 AA
    (>= 4.5:1) contrast across all 4 elevation surfaces ([surface_0],
    [surface_1], [surface_2], and [selection_bg]).

    SGR dim is intentionally absent from this model: low-emphasis hierarchy is
    expressed purely via calibrated foreground RGB ink and [Attr.italic]. *)

type rgb = int
(** Packed 24-bit RGB [0x00RRGGBB] (immediate unboxed int in OCaml 5). *)

type oklab = {
  l : float;
  a : float;
  b : float;
}

type preset =
  | Midnight
  | Arcade_hi
  | Paper_light
  | Mono
  | Muted
  | Muted_warm
  | Muted_green
  | Muted_dusk
  | Muted_graphite
  | Solarized_dark
  | Nord
  | Dracula
  | Gruvbox_dark
  | Catppuccin_mocha

type status_token =
  | Status_ok
  | Status_active
  | Status_attention
  | Status_critical
  | Status_ai
  | Status_historical

type gradient_kind =
  | Thermal
  | Cool_flow
  | Warm_flow
  | Efficiency
  | Ai_flow

type typography_tier =
  | Tier_anchor     (** Tier 1: [text_bright] + Bold (hero KPIs, focused titles, active selection) *)
  | Tier_primary    (** Tier 2: [text_primary] + Regular (body prose, table values, chat) *)
  | Tier_structure  (** Tier 3: [text_secondary] + Regular/Bold (headers, labels, inactive tabs) *)
  | Tier_whisper    (** Tier 4: [text_muted] + Italic (timestamps, empty states, Thinking, hints) *)

type t = {
  preset : preset;
  (* 4-level surface elevation *)
  surface_0 : rgb;
  surface_1 : rgb;
  surface_2 : rgb;
  (* 3-level structural borders *)
  border_subtle : rgb;
  border_inactive : rgb;
  border_focused : rgb;
  (* 4-tier typographic ink hierarchy — all guaranteed >= 4.5:1 across surface_0..2 & selection_bg *)
  text_bright : rgb;
  text_primary : rgb;
  text_secondary : rgb;
  text_muted : rgb;
  (* 5 semantic + historical status tokens — all guaranteed >= 4.5:1 across surface_0..2 & selection_bg *)
  status_ok : rgb;
  status_active : rgb;
  status_attention : rgb;
  status_critical : rgb;
  status_ai : rgb;
  status_historical : rgb;
  (* Accent and calm selection *)
  accent : rgb;
  selection_bg : rgb;
  selection_fg : rgb;
  (* Precomputed 64-entry Oklab perceptual chart gradients (0 float allocs in paint) *)
  gradient_thermal : rgb array;
  gradient_cool_flow : rgb array;
  gradient_warm_flow : rgb array;
  gradient_efficiency : rgb array;
  gradient_ai_flow : rgb array;
}

val make_rgb : r:int -> g:int -> b:int -> rgb
(** Clamp each channel to [0..255] and pack as [0x00RRGGBB]. *)

val red : rgb -> int
val green : rgb -> int
val blue : rgb -> int

val relative_luminance : rgb -> float
val contrast_ratio : rgb -> rgb -> float
(** WCAG 2 contrast ratio in [[1.0, 21.0]]. *)

val to_oklab : rgb -> oklab
val of_oklab : oklab -> rgb
val oklab_lightness : rgb -> float
val with_oklab_lightness : rgb -> float -> rgb
val is_light : rgb -> bool

val lift_for_contrast : background:rgb -> floor:float -> rgb -> rgb
(** Move [rgb] along Oklab lightness away from [background] until
    [contrast_ratio result background >= floor] (or the gamut boundary). *)

val lerp_oklab : background:rgb -> floor:float -> t:float -> rgb -> rgb -> rgb

val min_text_contrast : float
(** Hard WCAG AA floor: [4.5]. *)

type text_floors = {
  bright : float;  (** [text_bright] *)
  primary : float;  (** [text_primary] *)
  secondary : float;  (** [text_secondary] *)
  muted : float;  (** [text_muted] *)
  selection : float;  (** [selection_fg], measured on every surface *)
}

val text_floors : preset -> text_floors
(** The contrast ratio each text color of [preset] keeps against every one of
    its surfaces, the selection background included. [of_preset] lifts a color
    that falls short up to its floor, so a floor is also the dimmest the text
    of that preset can be. *)

val all_presets : preset list
val all_status_tokens : status_token list
val all_gradients : gradient_kind list
val preset_name : preset -> string
val preset_label : preset -> Say.t
val preset_of_name : string -> preset option
val equal_preset : preset -> preset -> bool

val of_preset : preset -> t
(** The theme of [preset]: built from its TOML override palette when one is
    installed and from [builtin_palette] otherwise. The theme is built when
    the overrides change, so a call returns a stored value and does no color
    math. *)

val default : t
(** Built-in Midnight, ignoring overrides. Live rendering must use
    [of_preset] so a TOML override applies. *)

module Palette : sig
  type t = {
    surface_0 : rgb;
    surface_1 : rgb;
    surface_2 : rgb;
    border_subtle : rgb;
    border_inactive : rgb;
    border_focused : rgb;
    text_bright : rgb;
    text_primary : rgb;
    text_secondary : rgb;
    text_muted : rgb;
    status_ok : rgb;
    status_active : rgb;
    status_attention : rgb;
    status_critical : rgb;
    status_ai : rgb;
    status_historical : rgb;
    accent : rgb;
    selection_bg : rgb;
    selection_fg : rgb;
    cool_stops : rgb * rgb * rgb;
    warm_stops : rgb * rgb * rgb;
    ai_stops : rgb * rgb * rgb;
  }
end
(** The raw palette of one preset before Oklab lifting. The field names are
    the TOML key names in [config/themes/<preset>.toml]; a present key
    overrides the built-in color, a missing key keeps it. The type lives in
    its own module because [t] above has fields with the same names: declared
    next to [t], these fields would hide the labels of [t]. *)

val rgb_of_hex : string -> (rgb, string) result
(** Parse ["#RRGGBB"] or ["RRGGBB"] (case-insensitive, surrounding blanks
    ignored) into packed RGB. Anything else is [Error] with a reason; never
    a default color. *)

val rgb_to_hex : rgb -> string
(** Uppercase ["#RRGGBB"] for [rgb]. *)

val builtin_palette : preset -> Palette.t
(** The compiled-in palette for [preset]. The seed files in
    [config/themes/] carry the same values in TOML form; the file is the
    editable copy and this value is the fallback when the file is absent. *)

val of_palette : preset -> Palette.t -> t
(** Build a theme from an explicit [palette], lifting text, status and
    accent colors to the preset's WCAG floors ([text_floors]) exactly as
    [of_preset] does for the built-in palette. *)

val equal_palette : Palette.t -> Palette.t -> bool

val set_palette_overrides : (preset * Palette.t) list -> unit
(** Replace the TOML override registry with [overrides] and build the theme
    of each overridden preset. A later entry for the same preset replaces an
    earlier one. Call it after loading theme files; [of_preset] returns the
    built theme from then on. An [of_preset] call that runs at the same time
    returns the theme from before this call or from after it. *)

val palette_override : preset -> Palette.t option
(** The override currently installed for [preset], if any. *)

val clear_palette_overrides : unit -> unit
(** Empty the registry; [of_preset] returns to [builtin_palette] for every
    preset. Intended for tests. *)

val tier_fg : t -> typography_tier -> rgb
(** Foreground RGB ink for the given 4-tier typographic role. *)

val status_color : t -> status_token -> rgb
val gradient_lut : t -> gradient_kind -> rgb array
val gradient_sample : t -> gradient_kind -> float -> rgb
(** Sample the 64-entry precomputed LUT for normalized [t] in [[0.0, 1.0]]. *)
