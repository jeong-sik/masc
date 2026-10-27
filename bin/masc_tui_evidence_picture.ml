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
  | Empty_dimensions
  | Png_incomplete
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
       | Decode.Withheld_body_identity_mismatch _
       | Decode.Withheld_over_delivery_ceiling _
       | Decode.Withheld_over_response_budget) as withheld) ->
      Unreadable (Withheld withheld)
  | Decode.Preview_defective defect -> Unreadable (Defective defect)

let cause_text = function
  | Withheld Decode.Withheld_not_image_format -> "not an image"
  | Withheld Decode.Withheld_body_not_filed -> "the server holds no copy of the bytes"
  | Withheld Decode.Withheld_body_unreadable -> "the server could not read its copy of the bytes"
  | Withheld (Decode.Withheld_body_identity_mismatch _) ->
      "the server's copy does not match the submitted size or sha256"
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
  | Empty_dimensions -> "the picture has no width or no height"
  | Png_incomplete -> "the PNG ends before its last chunk"
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
  | Undrawn_image of Media.media_type
  | Binary_only
  | Unshown of cause

type item =
  | Text_item of Decode.verification_evidence_item
  | Source_item of { source : Decode.verification_evidence_item; body : string }
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

(* The size of a picture the terminal is asked to decode. A side of zero is a
   picture with nothing to draw, and the product is never formed: PNG sides
   are 32 bits and the product of two of them wraps a 63-bit int, so "width
   times height is under the limit" is asked as "width is under the limit
   over height". *)
let measure (width, height) =
  if width <= 0 || height <= 0 then Error Empty_dimensions
  else if width > max_picture_pixels / height then Error (Too_many_pixels { width; height })
  else Ok (width, height)

(* The last chunk of every PNG: length 0, "IEND", and its fixed CRC. A file
   that stops short carries a header that parses and pixels that do not, which
   a terminal drops without saying so. *)
let png_end_chunk = "\x00\x00\x00\x00IEND\xaeB\x60\x82"

let png_complete png = String.ends_with ~suffix:png_end_chunk png

(* One image's route to a drawable PNG. The size is read from the original
   first where its format carries one, so a small file that describes a huge
   picture never reaches a converter; WebP carries none this module reads, so
   it is measured after conversion only. *)
let drawable ~convert ~slot ~media data =
  let before =
    match Masc.Keeper_image_dimensions.image_dimensions data with
    | Some size -> Result.map ignore (measure size)
    | None -> Ok ()
  in
  match before with
  | Error cause -> Unshown cause
  | Ok () -> (
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
          | Some size -> (
              match measure size with
              | Error cause -> Unshown cause
              | Ok (pixel_width, pixel_height) ->
                  if not (png_complete png) then Unshown Png_incomplete
                  else
                    Drawable
                      { media; png
                      ; key = Agent_core_sha256.(digest_string png |> to_hex)
                      ; pixel_width; pixel_height; slot })))

(* Simultaneous pictures take slots in evidence order; individual selections
   can reuse one slot. A picture that
   does not become drawable leaves its slot for the next one. A terminal that
   draws no pixels gives no slot and runs no converter: the picture is its
   caption. *)
let prepare_preview ~draws_pixels ~convert ~free_slots preview =
  match preview with
  | Decode.Preview_image { ev_media; _ } when not draws_pixels ->
      Undrawn_image ev_media, free_slots
  | Decode.Preview_image { ev_media; ev_data } -> (
      match free_slots with
      | [] -> Unshown No_free_slot, free_slots
      | slot :: rest -> (
          match drawable ~convert ~slot ~media:ev_media ev_data with
          | Drawable _ as picture -> picture, rest
          | (Undrawn_image _ | Binary_only | Unshown _) as picture -> picture, free_slots))
  | Decode.Preview_withheld Decode.Withheld_not_image_format -> Binary_only, free_slots
  | Decode.Preview_withheld
      ((Decode.Withheld_body_not_filed | Decode.Withheld_body_unreadable
       | Decode.Withheld_body_identity_mismatch _
       | Decode.Withheld_over_delivery_ceiling _
       | Decode.Withheld_over_response_budget) as withheld) ->
      Unshown (Withheld withheld), free_slots
  | Decode.Preview_defective defect -> Unshown (Defective defect), free_slots

let draws_pixels = function
  | View.Pixels _ -> true
  | View.Mosaic | View.No_picture -> false

let board_body content =
  let field name = function `Assoc fields -> List.assoc_opt name fields | _ -> None in
  let text name json = match field name json with Some (`String text) -> Some text | _ -> None in
  let entry ~body_field json = match text "author" json, text body_field json with
    | Some author, Some body -> Some (author ^ "\n" ^ body)
    | _ -> None in
  match Yojson.Safe.from_string content with
  | json ->
    (match field "source" json, field "post" json, field "comments" json with
     | Some (`String "board"), Some post, Some (`List comments) ->
       (match text "title" post, entry ~body_field:"body" post,
              List.map (entry ~body_field:"content") comments with
        | Some title, Some post, comments when List.for_all Option.is_some comments ->
          Some (String.concat "\n\n" (title :: post :: List.filter_map Fun.id comments))
        | _ -> None)
     | _ -> None)
  | exception Yojson.Json_error _ -> None

type layout = Together | One_at_a_time

let prepare ~layout ~display ~convert = function
  | Decode.Evidence_access_unavailable reason -> Access_unavailable reason
  | Decode.Evidence_items items ->
      let draws_pixels = draws_pixels display in
      let _free, rev =
        List.fold_left
          (fun (free_slots, acc) (item : Decode.verification_evidence_item) ->
            match item with
            | Decode.Ev_binary
                { ev_b_reference; ev_b_bytes; ev_b_sha256; ev_b_format; ev_b_preview } ->
                let picture, free_slots =
                  let free_slots = match layout with
                    | Together -> free_slots
                    | One_at_a_time -> Masc_tui_graphics.evidence_images in
                  prepare_preview ~draws_pixels ~convert ~free_slots ev_b_preview
                in
                ( free_slots
                , Binary_item
                    { reference = ev_b_reference; bytes = ev_b_bytes; sha256 = ev_b_sha256
                    ; format = ev_b_format; picture }
                  :: acc )
            | Decode.Ev_collaboration {ev_content; _} ->
                free_slots, (match board_body ev_content with
                  | Some body -> Source_item {source=item;body}
                  | None -> Text_item item) :: acc
            | Decode.Ev_note _ | Decode.Ev_artifact _
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
     | Drawable { media; _ } | Undrawn_image media -> `Image media
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
           box never claims fewer cells than the picture covers. [fit_rows]
           never answers under one row, so a picture wider than the pane by
           more than a row's worth is still wider at one row: the terminal
           would draw it past the pane's edge, so it is a caption. *)
        let covered_pixels = rows * cell_height * pixels.pixel_width in
        let cell_row_pixels = pixels.pixel_height * cell_width in
        let cols = (covered_pixels + cell_row_pixels - 1) / cell_row_pixels in
        if cols > max_cols then Caption_only else Picture { cols = max 1 cols; rows }
  | View.Pixels _, (Undrawn_image _ | Binary_only | Unshown _)
  | (View.Mosaic | View.No_picture), (Drawable _ | Undrawn_image _ | Binary_only | Unshown _) ->
      Caption_only

type slot = { first : int; box : box }

type placement_plan =
  | Place of { row : int; column : int; cut_top : int; shown_rows : int }
  | Hidden

(* The rows of the area that are inside the window, cut off at the top or the
   bottom where the window ends. *)
let plan slot ~scroll ~content_height ~content_origin:(origin_row, origin_column) =
  let area_end = slot.first + slot.box.rows in
  let first_shown = max slot.first scroll in
  let last_shown = min area_end (scroll + content_height) in
  if last_shown <= first_shown then Hidden
  else
    Place
      { row = origin_row + (first_shown - scroll)
      ; column = origin_column + picture_indent_cols
      ; cut_top = first_shown - slot.first
      ; shown_rows = last_shown - first_shown
      }

(* The source rows of the part that shows. Row boundaries are cut from the
   same proportion at both ends, so the pieces of a picture scrolled past a
   window edge tile exactly. *)
let crop_of pixels box ~cut_top ~shown_rows =
  if cut_top = 0 && shown_rows = box.rows then None
  else
    let at rows = rows * pixels.pixel_height / box.rows in
    let top_px = at cut_top in
    Some { Masc_tui_graphics.top_px; height_px = max 1 (at (cut_top + shown_rows) - top_px) }

let png_placement pixels box ~row ~column ~cut_top ~shown_rows =
  { View.png_image_id = Masc_tui_graphics.image_id pixels.slot
  ; png_row = row
  ; png_column = column
  ; png_cols = box.cols
  ; png_rows = shown_rows
  ; png_crop = crop_of pixels box ~cut_top ~shown_rows
  ; png_key = pixels.key
  ; png_data = pixels.png
  }
