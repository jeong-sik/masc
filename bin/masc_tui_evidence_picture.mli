(** What the TUI knows about one binary artifact of the operator evidence
    bundle, and the one line it says about it when it draws no pixels.

    The server sends a binary artifact with a [preview] that is the image's
    bytes or the reason they are missing ({!Masc.Tui_decode.evidence_preview}).
    This module reads that into the three things a reader can be told. *)

(** Why an image the operator should see is not shown. *)
type cause =
  | Withheld of Masc.Tui_decode.evidence_withheld
      (** the server did not send the bytes: too large, not stored, over the
          response's image budget *)
  | Defective of Masc.Tui_decode.evidence_preview_defect
      (** the server sent bytes that disagree with the item's own record *)

type reading =
  | Image of Masc.Keeper_vision_downscale.media_type
      (** verified bytes of this format are in hand *)
  | Not_an_image
      (** a PDF, audio, video or archive: there is nothing to draw *)
  | Unreadable of cause  (** an image the operator cannot see, and why *)

val reading : Masc.Tui_decode.evidence_preview -> reading

val cause_text : cause -> string
(** The cause in a sentence, with the numbers the server and the item stated. *)

val short_sha_length : int
(** Hex digits of the SHA-256 a line shows; the evidence identity lines use
    the same length. *)

val caption :
  reference:string ->
  bytes:int ->
  sha256:string ->
  format:string ->
  Masc.Tui_decode.evidence_preview ->
  string
(** One line for one binary artifact: what it is (an image with its media
    type, a binary artifact with its extension, or an unreadable image with
    the cause), its size, the first {!short_sha_length} digits of its SHA-256
    and its reference. The only thing a terminal that draws no pixels shows. *)
