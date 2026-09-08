(** Minimal PNG encoder: 8-bit truecolour, filter 0, deflate "stored"
    blocks. Runtime providers take an image block as PNG, not raw RGB, so
    the lane encodes its frame buffers here. Stored blocks keep this free
    of a compression dependency -- a 512x212 frame lands at ~332 KB, and
    the provider re-encodes on its side anyway. *)

val crc32 : string -> int32
(** PNG chunk checksum. crc32 "123456789" = 0xCBF43926 (published vector). *)

val adler32 : string -> int32
(** zlib stream checksum. adler32 "Wikipedia" = 0x11E60398 (published
    vector). *)

val encode : width:int -> height:int -> rgb:string -> string
(** Encode a [width * height] RGB buffer (3 bytes per pixel, row-major) as
    a PNG byte string. Raises [Invalid_argument] when the dimensions are
    not positive or the buffer length does not match them. *)
