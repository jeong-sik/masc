(** Deterministic, lossless 8-bit PNG encoding. No filesystem or subprocesses. *)

val encode : width:int -> height:int -> rgb:string -> (string, string) result
(** Three bytes per pixel, rows top to bottom (colour type 2). *)

val encode_rgba : width:int -> height:int -> rgba:string -> (string, string) result
(** Four bytes per pixel with straight (not premultiplied) alpha, rows top to
    bottom (colour type 6). *)

val has_complete_chunks : string -> bool
(** Checks the PNG signature, chunk lengths and CRCs, an initial IHDR,
    nonempty image data, and a final IEND. *)
