(** The operator evidence section's binary artifacts: what each one is to the
    reader, the PNG the terminal is given for an image, how many cells the
    picture gets and where it lands.

    The server sends a binary artifact with a [preview] that is the image's
    bytes or the reason they are missing ({!Masc.Tui_decode.evidence_preview}).
    {!prepare} runs once, off the render loop, and turns each into a
    {!picture}; the functions after it are pure and decide, per frame, what
    the renderer reserves and requests. *)

(** Why an image the operator should see is not shown. *)
type cause =
  | Withheld of Masc.Tui_decode.evidence_withheld
      (** the server did not send the bytes: too large, not stored, over the
          response's image budget *)
  | Defective of Masc.Tui_decode.evidence_preview_defect
      (** the server sent bytes that disagree with the item's own record *)
  | Conversion_failed of string
      (** the image is not a PNG and the converters could not make one; the
          string is their one-line report *)
  | Not_png_after_conversion
      (** a converter succeeded and its output is not a PNG, which a terminal
          would drop without saying so *)
  | Too_many_pixels of { width : int; height : int }
      (** a small file that describes a picture beyond {!max_picture_pixels},
          which the terminal would have to decode in full *)
  | Empty_dimensions  (** the header says the picture has no width or no height *)
  | Png_incomplete
      (** the header parses and the file stops before its last chunk, so the
          terminal would drop it without saying so *)
  | Unknown_size  (** the PNG's header carries no readable dimensions *)
  | No_free_slot
      (** more pictures than {!Masc_tui_graphics.evidence_images} has slots;
          this one is listed by its caption only *)

type reading =
  | Image of Masc.Keeper_vision_downscale.media_type
      (** verified bytes of this format are in hand *)
  | Not_an_image
      (** a PDF, audio, video or archive: there is nothing to draw *)
  | Unreadable of cause  (** an image the operator cannot see, and why *)

val reading : Masc.Tui_decode.evidence_preview -> reading
(** The server's preview, read. No bytes are converted or measured. *)

val cause_text : cause -> string
(** The cause in a sentence, with the numbers it was decided on. *)

val short_sha_length : int
(** Hex digits of the SHA-256 a line shows; the evidence identity lines use
    the same length. *)

val max_picture_pixels : int
(** Width times height beyond which a picture is not handed to the terminal.
    Compared without forming the product, so a header that claims 2^31 by 2^31
    is over the limit and not wrapped under it. *)

(** An image ready for the terminal. Built only by {!prepare}, which gives it
    sides of at least one pixel and a PNG that ends with its last chunk. *)
type pixels = private {
  media : Masc.Keeper_vision_downscale.media_type;  (** what the artifact was *)
  png : string;  (** the same picture as a PNG file, which is what Kitty takes *)
  key : string;  (** SHA-256 of [png]; equal keys are equal bytes *)
  pixel_width : int;
  pixel_height : int;
  slot : Masc_tui_graphics.image;  (** the terminal image this picture owns *)
}

type picture =
  | Drawable of pixels
  | Undrawn_image of Masc.Keeper_vision_downscale.media_type
      (** an image on a terminal that draws no pixels: nothing was converted,
          and the caption is all of it *)
  | Binary_only  (** not an image: one line says what it is *)
  | Unshown of cause

type item =
  | Text_item of Masc.Tui_decode.verification_evidence_item
      (** a note, source, text artifact or unreadable artifact *)
  | Source_item of { source : Masc.Tui_decode.verification_evidence_item; body : string }
      (** Readable Board body prepared off the render loop. [source] remains
          the original immutable snapshot, including its links and digest. *)
  | Binary_item of {
      reference : string;
      bytes : int;
      sha256 : string;
      format : string;  (** the file extension *)
      picture : picture;
    }

type evidence =
  | Items of item list
  | Access_unavailable of string

type layout = Together | One_at_a_time
(** Simultaneous images need distinct slots. A reader showing one selected
    item reuses the first slot for each prepared image. *)

val prepare :
  layout:layout ->
  display:Masc_tui_portrait_view.display ->
  convert:(string -> (string, string) result) ->
  Masc.Tui_decode.verification_evidence ->
  evidence
(** [convert bytes] is a PNG file made from image bytes, or the converter's
    one-line failure. It is called only for an image that is not already a
    PNG, and blocks on external programs, so call [prepare] off the render
    loop. [Together] takes {!Masc_tui_graphics.evidence_images} slots in the
    order the evidence lists them; one past the last slot is
    [Unshown No_free_slot]. [One_at_a_time] gives every drawable image the first
    slot, so later selections remain available. Dimensions are read before any conversion where
    the format allows it, so a picture over {!max_picture_pixels} is never
    handed to a converter. When [display] does not draw pixels no picture is
    converted or given a slot: every image is {!Undrawn_image}. *)

val caption :
  reference:string ->
  bytes:int ->
  sha256:string ->
  format:string ->
  picture ->
  string
(** One line for one binary artifact: what it is (an image with its media
    type, a binary artifact with its extension, or an image not shown with the
    cause), its size, the first {!short_sha_length} digits of its SHA-256 and
    its reference. The only thing a terminal that draws no pixels shows. *)

val caption_of_preview :
  reference:string ->
  bytes:int ->
  sha256:string ->
  format:string ->
  Masc.Tui_decode.evidence_preview ->
  string
(** {!caption} for a preview that has not been prepared: the image is named
    as an image and nothing is said about converting it. *)

(** {2 Layout} *)

(** The cells a picture takes. *)
type box = { cols : int; rows : int }

type block =
  | Caption_only  (** one line, no picture *)
  | Picture of box
      (** the caption, then [rows] blank rows the picture is placed over *)

val picture_max_rows : int
val picture_indent_cols : int
(** Cells between the content edge and the picture's left edge. *)

val block :
  Masc_tui_portrait_view.display ->
  picture ->
  width:int ->
  caption_rows:int ->
  content_height:int ->
  block
(** What the section reserves for one binary artifact. Only a {!Drawable}
    picture on a terminal that draws pixels
    ({!Masc_tui_portrait_view.Pixels}, which needs the Kitty graphics answer, a
    reported cell size and colour) gets a picture; on iTerm2, on a Kitty
    terminal that reported no cell size, and under NO_COLOR it is
    [Caption_only]. The box is the aspect-preserving fit of the picture into
    the width left of {!picture_indent_cols} and into the rows the content
    area has under the caption, at most {!picture_max_rows}. With fewer than
    {!Masc_tui_portrait_view.min_pixel_rows} rows to give it is
    [Caption_only]: a smudge is not a picture. A picture wider than the pane
    at one row (a banner) is [Caption_only] too: the terminal draws no fewer
    than one row, and would draw it past the pane's edge. *)

(** Where a reserved area sits among the content rows. *)
type slot = { first : int; box : box }

type placement_plan =
  | Place of { row : int; column : int; cut_top : int; shown_rows : int }
      (** [row] and [column] are the 0-based frame cell of the top-left corner
          of the part that shows; [cut_top] rows of the area are above the
          window and [shown_rows] are inside it *)
  | Hidden  (** no row of the area is inside the window *)

val plan :
  slot -> scroll:int -> content_height:int -> content_origin:int * int -> placement_plan
(** [content_origin] is the frame (row, column) of the first content row's
    first cell. The part of the area inside the window is placed and the rest
    is cropped from the picture, so a picture is there at every scroll
    offset that shows one of its rows. *)

val png_placement :
  pixels -> box -> row:int -> column:int -> cut_top:int -> shown_rows:int ->
  Masc_tui_portrait_view.png_placement
(** The picture cropped to the rows of its area that [plan] left inside the
    window. The crop is cut from the same proportion at both ends: the parts
    of one picture scrolled past a window edge tile exactly. *)
