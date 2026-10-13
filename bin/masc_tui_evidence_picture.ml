module Decode = Masc.Tui_decode

let single_line = Masc.Tui_terminal_text.sanitize_terminal_text

type cause =
  | Withheld of Decode.evidence_withheld
  | Defective of Decode.evidence_preview_defect

type reading =
  | Image of Masc.Keeper_vision_downscale.media_type
  | Not_an_image
  | Unreadable of cause

let reading = function
  | Decode.Preview_image { ev_media; _ } -> Image ev_media
  | Decode.Preview_withheld Decode.Withheld_not_image_format -> Not_an_image
  | Decode.Preview_withheld
      ((Decode.Withheld_body_not_filed | Decode.Withheld_body_unreadable
       | Decode.Withheld_over_delivery_ceiling _
       | Decode.Withheld_over_response_budget) as withheld) ->
      Unreadable (Withheld withheld)
  | Decode.Preview_defective defect -> Unreadable (Defective defect)

let cause_text = function
  | Withheld Decode.Withheld_not_image_format -> "not an image"
  | Withheld Decode.Withheld_body_not_filed -> "the server holds no copy of the bytes"
  | Withheld Decode.Withheld_body_unreadable -> "the server could not read its copy of the bytes"
  | Withheld (Decode.Withheld_over_delivery_ceiling { bytes; ceiling }) ->
      Printf.sprintf "%dB is over the %dB the server sends" bytes ceiling
  | Withheld Decode.Withheld_over_response_budget ->
      "earlier images already used this response's image budget"
  | Defective Decode.Defect_bad_base64 -> "the bytes did not decode"
  | Defective (Decode.Defect_length_mismatch { declared; actual }) ->
      Printf.sprintf "received %dB but the item records %dB" actual declared
  | Defective Decode.Defect_digest_mismatch -> "the bytes do not match the recorded sha256"
  | Defective Decode.Defect_not_an_image -> "the bytes are not a PNG, JPEG, GIF or WebP image"

let short_sha_length = 12

let short_sha sha256 = String.sub sha256 0 (min short_sha_length (String.length sha256))

let caption ~reference ~bytes ~sha256 ~format preview =
  let reference = single_line reference in
  let identity detail =
    Printf.sprintf "%s (%s, %dB, sha256 %s)" reference detail bytes (short_sha sha256)
  in
  match reading preview with
  | Image media ->
      "image " ^ identity (Masc.Keeper_vision_downscale.media_type_to_string media)
  | Not_an_image -> "binary artifact " ^ identity (single_line format)
  | Unreadable cause ->
      Printf.sprintf "image not shown: %s: %s"
        (identity (single_line format))
        (cause_text cause)
