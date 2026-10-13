module Decode = Masc.Tui_decode
module View = Masc_tui_portrait_view
module Media = Masc.Keeper_vision_downscale

let single_line = Masc.Tui_terminal_text.sanitize_terminal_text

(* A PNG is decoded to four bytes a pixel by the terminal, and a 200 KB file
   can describe far more than a screen holds. 16 million pixels is 4000 x 4000
   and 64 MB decoded: a 5K display's screenshot (5120 x 2880) is under it. *)
let max_picture_pixels = 16_000_000

type cause =
  | Withheld of Decode.evidence_withheld
  | Defective of Decode.evidence_preview_defect
  | Conversion_failed of string
  | Not_png_after_conversion
  | Too_many_pixels of { width : int; height : int }
  | Unknown_size
  | No_free_slot

type reading =
  | Image of Media.media_type
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
  | Conversion_failed detail -> "could not convert it to PNG: " ^ single_line detail
  | Not_png_after_conversion -> "the converter's output is not a PNG"
  | Too_many_pixels { width; height } ->
      Printf.sprintf "%dx%d pixels is over the %d pixels shown" width height max_picture_pixels
  | Unknown_size -> "the PNG header has no readable size"
  | No_free_slot ->
      Printf.sprintf "only the first %d pictures of a task are drawn"
        (List.length Masc_tui_graphics.evidence_images)

let short_sha_length = 12

let short_sha sha256 = String.sub sha256 0 (min short_sha_length (String.length sha256))

type pixels = {
  media : Media.media_type;
  png : string;
  key : string;
  pixel_width : int;
  pixel_height : int;
  slot : Masc_tui_graphics.image;
}

type picture =
  | Drawable of pixels
  | Binary_only
  | Unshown of cause

type item =
  | Text_item of Decode.verification_evidence_item
  | Binary_item of {
      reference : string;
      bytes : int;
      sha256 : string;
      format : string;
      picture : picture;
    }

type evidence =
  | Items of item list
  | Access_unavailable of string

let png_media_type = Media.media_type_to_string Media.Png

let is_png bytes =
  match Masc.Keeper_vision_tool.sniff_image_media_type bytes with
  | Ok media -> String.equal media png_media_type
  | Error _ -> false

let over_pixel_limit (width, height) = width * height > max_picture_pixels

(* One image's route to a drawable PNG. The size is read from the original
   first where its format carries one, so a small file that describes a huge
   picture never reaches a converter; WebP carries none this module reads, so
   it is measured after conversion only. *)
let drawable ~convert ~slot ~media data =
  let original = Masc.Keeper_image_dimensions.image_dimensions data in
  match original with
  | Some ((width, height) as size) when over_pixel_limit size ->
      Unshown (Too_many_pixels { width; height })
  | Some _ | None -> (
      let png =
        match media with
        | Media.Png -> Ok data
        | Media.Jpeg | Media.Gif | Media.Webp -> convert data
      in
      match png with
      | Error detail -> Unshown (Conversion_failed detail)
      | Ok png when not (is_png png) -> Unshown Not_png_after_conversion
      | Ok png -> (
          match Masc.Keeper_image_dimensions.image_dimensions png with
          | None -> Unshown Unknown_size
          | Some (width, height) when over_pixel_limit (width, height) ->
              Unshown (Too_many_pixels { width; height })
          | Some (pixel_width, pixel_height) ->
              Drawable
                { media; png
                ; key = Digestif.SHA256.(digest_string png |> to_hex)
                ; pixel_width; pixel_height; slot }))

(* Pictures take slots in the order the evidence lists them. A picture that
   does not become drawable leaves its slot for the next one. *)
let prepare_preview ~convert ~free_slots preview =
  match preview with
  | Decode.Preview_image { ev_media; ev_data } -> (
      match free_slots with
      | [] -> Unshown No_free_slot, free_slots
      | slot :: rest -> (
          match drawable ~convert ~slot ~media:ev_media ev_data with
          | Drawable _ as picture -> picture, rest
          | (Binary_only | Unshown _) as picture -> picture, free_slots))
  | Decode.Preview_withheld Decode.Withheld_not_image_format -> Binary_only, free_slots
  | Decode.Preview_withheld
      ((Decode.Withheld_body_not_filed | Decode.Withheld_body_unreadable
       | Decode.Withheld_over_delivery_ceiling _
       | Decode.Withheld_over_response_budget) as withheld) ->
      Unshown (Withheld withheld), free_slots
  | Decode.Preview_defective defect -> Unshown (Defective defect), free_slots

let prepare ~convert = function
  | Decode.Evidence_access_unavailable reason -> Access_unavailable reason
  | Decode.Evidence_items items ->
      let _free, rev =
        List.fold_left
          (fun (free_slots, acc) (item : Decode.verification_evidence_item) ->
            match item with
            | Decode.Ev_binary
                { ev_b_reference; ev_b_bytes; ev_b_sha256; ev_b_format; ev_b_preview } ->
                let picture, free_slots =
                  prepare_preview ~convert ~free_slots ev_b_preview
                in
                ( free_slots
                , Binary_item
                    { reference = ev_b_reference; bytes = ev_b_bytes; sha256 = ev_b_sha256
                    ; format = ev_b_format; picture }
                  :: acc )
            | Decode.Ev_collaboration _ | Decode.Ev_note _ | Decode.Ev_artifact _
            | Decode.Ev_artifact_unreadable _ ->
                free_slots, Text_item item :: acc)
          (Masc_tui_graphics.evidence_images, [])
          items
      in
      Items (List.rev rev)

let caption_line ~reference ~bytes ~sha256 ~format = function
  | `Image media ->
      let identity detail =
        Printf.sprintf "%s (%s, %dB, sha256 %s)" (single_line reference) detail bytes
          (short_sha sha256)
      in
      "image " ^ identity (Media.media_type_to_string media)
  | `Binary ->
      Printf.sprintf "binary artifact %s (%s, %dB, sha256 %s)" (single_line reference)
        (single_line format) bytes (short_sha sha256)
  | `Unshown cause ->
      Printf.sprintf "image not shown: %s (%s, %dB, sha256 %s): %s" (single_line reference)
        (single_line format) bytes (short_sha sha256) (cause_text cause)

let caption ~reference ~bytes ~sha256 ~format picture =
  caption_line ~reference ~bytes ~sha256 ~format
    (match picture with
     | Drawable { media; _ } -> `Image media
     | Binary_only -> `Binary
     | Unshown cause -> `Unshown cause)

let caption_of_preview ~reference ~bytes ~sha256 ~format preview =
  caption_line ~reference ~bytes ~sha256 ~format
    (match reading preview with
     | Image media -> `Image media
     | Not_an_image -> `Binary
     | Unreadable cause -> `Unshown cause)

type box = { cols : int; rows : int }

type block =
  | Caption_only
  | Picture of box

(* Rows a picture may take. A pane shows about 30 content rows; 20 leaves the
   caption and some text beside a full-height picture. *)
let picture_max_rows = 20

(* Under "    - ": the picture starts where the item's text does. *)
let picture_indent_cols = 6

let block display picture ~width ~caption_rows ~content_height =
  match display, picture with
  | View.Pixels { cell_width; cell_height }, Drawable pixels ->
      let max_cols = width - picture_indent_cols in
      let max_rows = min picture_max_rows (content_height - caption_rows) in
      if max_cols < 1 || max_rows < View.min_pixel_rows then Caption_only
      else
        let rows =
          Masc_tui_graphics.fit_rows
            ~cell_pixels:(Some (cell_width, cell_height))
            ~image_pixels:(Some (pixels.pixel_width, pixels.pixel_height))
            ~columns:max_cols ~rows:max_rows
        in
        (* The width the picture takes at that many rows, rounded up so the
           box never claims fewer cells than the picture covers. *)
        let covered_pixels = rows * cell_height * pixels.pixel_width in
        let cols = (covered_pixels + (pixels.pixel_height * cell_width) - 1)
                   / (pixels.pixel_height * cell_width) in
        Picture { cols = max 1 (min max_cols cols); rows }
  | View.Pixels _, (Binary_only | Unshown _)
  | (View.Mosaic | View.No_picture), (Drawable _ | Binary_only | Unshown _) ->
      Caption_only

type slot = { first : int; box : box }

type placement_plan =
  | Place of { row : int; column : int }
  | Hidden

let plan slot ~scroll ~content_height ~content_origin:(origin_row, origin_column) =
  if slot.first >= scroll && slot.first + slot.box.rows <= scroll + content_height
  then Place { row = origin_row + (slot.first - scroll); column = origin_column + picture_indent_cols }
  else Hidden

let png_placement pixels box ~row ~column =
  { View.png_image_id = Masc_tui_graphics.image_id pixels.slot
  ; png_row = row
  ; png_column = column
  ; png_cols = box.cols
  ; png_rows = box.rows
  ; png_key = pixels.key
  ; png_data = pixels.png
  }
