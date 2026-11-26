(** Deterministic, lossless 8-bit PNG encoding and header/chunk inspection.
    No filesystem or subprocesses. *)

val signature : string
(** Canonical 8-byte PNG file signature (["\137PNG\r\n\026\n"]). *)

val header_dimensions : string -> (int * int) option
(** Read positive [(width, height)] from a PNG signature + 13-byte IHDR header
    (minimum 29 bytes, without requiring the trailing 4-byte IHDR CRC). *)

val dimensions : string -> (int * int) option
(** Read positive [(width, height)] from a PNG prefix that includes the full
    IHDR chunk and its 4-byte CRC (minimum 33 bytes). *)

val encode : width:int -> height:int -> rgb:string -> (string, string) result
(** Three bytes per pixel, rows top to bottom (colour type 2). *)

val encode_rgba : width:int -> height:int -> rgba:string -> (string, string) result
(** Four bytes per pixel with straight (not premultiplied) alpha, rows top to
    bottom (colour type 6). *)

val has_complete_chunks : string -> bool
(** Checks the PNG signature, chunk lengths and CRCs, an initial IHDR,
    nonempty image data, and a final IEND. *)
