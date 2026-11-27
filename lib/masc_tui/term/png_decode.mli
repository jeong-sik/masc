(** Pure-OCaml raster image dimension parser (PNG, JPEG, WebP, GIF) and
    8-bit/16-bit non-interlaced PNG RGBA decoder using [decompress.zl].

    Zero external binaries, zero filesystem I/O, strict pixel-count cap before
    output buffer allocation. *)

type rgba_image = {
  width : int;
  height : int;
  rgba : bytes;
      (** Row-major top-to-bottom straight RGBA, length [width * height * 4]. *)
}

val default_max_pixels : int
(** Default pixel cap (4,194,304 pixels, i.e. 2048x2048). *)

val image_dimensions : string -> (int * int) option
(** Fast header-only dimension inspection supporting PNG, JPEG (SOF0..SOF15),
    GIF87a/GIF89a, and WebP (VP8 / VP8L / VP8X). *)

val decode_rgba :
  ?max_pixels:int -> string -> (rgba_image, string) result
(** Decode a non-interlaced PNG (color types 0 Grayscale, 2 RGB, 3 Indexed +
    optional tRNS, 4 Gray+Alpha, 6 RGBA; bit depths 8 and 16; all 5 PNG
    scanline filters) into straight 8-bit RGBA pixels. *)
