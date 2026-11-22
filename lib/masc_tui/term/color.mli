(** Terminal color values, deterministic downscaling, and Oklab contrast helpers. *)

type rgb = Masc_tui_core.Theme.rgb
(** Packed 24-bit RGB [0x00RRGGBB]. *)

type depth =
  | Truecolor
  | Ansi256
  | Ansi16

type t =
  | Default
  | Ansi16 of int   (** [0..15] *)
  | Ansi256 of int  (** [0..255] *)
  | Rgb of rgb

val make_rgb : r:int -> g:int -> b:int -> rgb
val rgb : r:int -> g:int -> b:int -> t
val of_rgb : rgb -> t
val red : rgb -> int
val green : rgb -> int
val blue : rgb -> int

val ansi256_to_rgb : int -> rgb
(** Standard xterm 256-color table RGB estimate for [0..255]. *)

val ansi16_to_rgb : int -> rgb
(** Standard ANSI 16-color table RGB estimate for [0..15]. *)

val rgb_to_ansi256 : rgb -> int
(** Nearest xterm-256 index in [16..255] (6x6x6 cube + 24-step grayscale). *)

val rgb_to_ansi16 : rgb -> int
(** Nearest ANSI-16 index in [0..15]. *)

val downscale : depth:depth -> t -> t
(** Project [t] deterministically to fit [depth]. *)

val contrast_ratio : rgb -> rgb -> float
val oklab_lightness : rgb -> float
val lift_for_contrast : background:rgb -> floor:float -> rgb -> rgb
val lerp_oklab : background:rgb -> floor:float -> t:float -> rgb -> rgb -> rgb

val equal : t -> t -> bool
