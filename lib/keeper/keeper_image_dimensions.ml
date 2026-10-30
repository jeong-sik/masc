(* Pixel dimensions read straight out of an image header.

   Lives beside the chat store rather than the vision tool on purpose: the
   store measures an attachment at the moment its payload is swapped for a
   [masc://] reference, and the vision tool's dependencies would close a
   module cycle through it (measured 2026-09-02 on CI: chat_store ->
   vision_tool -> ... -> approval_queue -> chat_store). This module depends
   on nothing, so both may use it.

   [None] is a normal answer, not a failure: an unparseable or unhandled
   layout shows nothing rather than a guess. *)

let be16 bytes offset =
  (Char.code bytes.[offset] lsl 8) lor Char.code bytes.[offset + 1]

let be32 bytes offset =
  (Char.code bytes.[offset] lsl 24)
  lor (Char.code bytes.[offset + 1] lsl 16)
  lor (Char.code bytes.[offset + 2] lsl 8)
  lor Char.code bytes.[offset + 3]

let le16 bytes offset =
  Char.code bytes.[offset] lor (Char.code bytes.[offset + 1] lsl 8)

(* PNG: the signature is the one the caller matched, and the spec puts IHDR
   first, so width and height are at fixed offsets. A file whose first chunk
   is not IHDR is not a PNG this function wants to speak about. *)
let png_dimensions bytes =
  if String.length bytes >= 24 && String.equal (String.sub bytes 12 4) "IHDR"
  then Some (be32 bytes 16, be32 bytes 20)
  else None

(* JPEG: markers follow SOI in order, every non-standalone segment carries
   its own length, and every SOF carries the frame size. The walk stops at
   the first SOF it meets -- encoders emit one -- and at SOS, which means
   the SOF was never coming. *)
let sof_marker code =
  code >= 0xc0 && code <= 0xcf && code <> 0xc4 && code <> 0xc8 && code <> 0xcc

let rec jpeg_walk bytes offset =
  let length = String.length bytes in
  if offset + 4 > length || Char.code bytes.[offset] <> 0xff then None
  else
    let code = Char.code bytes.[offset + 1] in
    if code = 0x01 || (code >= 0xd0 && code <= 0xd7) then jpeg_walk bytes (offset + 2)
    else if sof_marker code then
      if offset + 9 > length then None
      else Some (be16 bytes (offset + 7), be16 bytes (offset + 5))
    else if code = 0xda then None
    else
      let segment = be16 bytes (offset + 2) in
      (* A segment shorter than its own length word is a broken stream;
         stepping forward by it would loop on the same offset. *)
      if segment <= 1 then None else jpeg_walk bytes (offset + 2 + segment)

let jpeg_dimensions bytes = jpeg_walk bytes 2

(* GIF: the logical screen size sits right after the 6-byte versioned
   header, little-endian. *)
let gif_dimensions bytes =
  if String.length bytes >= 10 then Some (le16 bytes 6, le16 bytes 8) else None

(* WebP: None. The container has three frame layouts (VP8, VP8L, VP8X) and
   each spells the canvas differently; a wrong table here would print a
   confident wrong size, which is worse than printing none. *)
let image_dimensions bytes =
  let starts prefix =
    let prefix_len = String.length prefix in
    String.length bytes >= prefix_len
    && String.equal (String.sub bytes 0 prefix_len) prefix
  in
  if starts "\x89PNG" then png_dimensions bytes
  else if starts "\xff\xd8\xff" then jpeg_dimensions bytes
  else if starts "GIF8" then gif_dimensions bytes
  else None
;;
