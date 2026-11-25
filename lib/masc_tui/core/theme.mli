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
val default : t
(** [of_preset Midnight]. *)

val tier_fg : t -> typography_tier -> rgb
(** Foreground RGB ink for the given 4-tier typographic role. *)

val status_color : t -> status_token -> rgb
val gradient_lut : t -> gradient_kind -> rgb array
val gradient_sample : t -> gradient_kind -> float -> rgb
(** Sample the 64-entry precomputed LUT for normalized [t] in [[0.0, 1.0]]. *)
