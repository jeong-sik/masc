(* What the evidence section tells the reader about a binary artifact is
   decided by typed answers: [reading] and [prepare] say what an artifact is,
   [block] says what the section reserves for it, [plan] says whether the
   picture is requested this frame. The caption tests assert the facts a line
   must carry (reference, size, a short digest) and which cases say "not
   shown", not the wording around them. *)

module Decode = Masc.Tui_decode
module Picture = Masc_tui_evidence_picture
module View = Masc_tui_portrait_view
module Media = Masc.Keeper_vision_downscale

let png = Media.Png

(* A PNG header with the dimensions in IHDR; the decoder is the terminal's. *)
let be32 value =
  String.init 4 (fun index -> Char.chr ((value lsr (8 * (3 - index))) land 0xff))

let iend = "\x00\x00\x00\x00IEND\xaeB\x60\x82"

let png_of ~width ~height =
  "\x89PNG\r\n\x1a\n" ^ be32 13 ^ "IHDR" ^ be32 width ^ be32 height ^ "\x08\x06\x00\x00\x00"
  ^ "crc!" ^ "image data" ^ iend

let kitty = View.Pixels { cell_width = 10; cell_height = 20 }

(* SOI, then an SOF0 marker: height and width are the next two words. *)
let jpeg_of ~width ~height =
  let be16 value = String.init 2 (fun index -> Char.chr ((value lsr (8 * (1 - index))) land 0xff)) in
  "\xff\xd8\xff\xc0\x00\x11\x08" ^ be16 height ^ be16 width ^ String.make 8 '\x00'

let reading_name = function
  | Picture.Image media -> "Image " ^ Media.media_type_to_string media
  | Picture.Not_an_image -> "Not_an_image"
  | Picture.Unreadable _ -> "Unreadable"

let reading_testable =
  Alcotest.testable (fun formatter r -> Format.pp_print_string formatter (reading_name r)) ( = )

let test_each_preview_has_one_reading () =
  Alcotest.(check reading_testable) "verified bytes are an image" (Picture.Image png)
    (Picture.reading (Decode.Preview_image { ev_media = png; ev_data = "" }));
  Alcotest.(check reading_testable) "a PDF is not an image, and not a failure"
    Picture.Not_an_image
    (Picture.reading (Decode.Preview_withheld Decode.Withheld_not_image_format));
  List.iter
    (fun withheld ->
      match Picture.reading (Decode.Preview_withheld withheld) with
      | Picture.Unreadable (Picture.Withheld again) ->
          Alcotest.(check bool) "keeps the server's cause" true (again = withheld)
      | Picture.Image _ | Picture.Not_an_image | Picture.Unreadable _ ->
          Alcotest.fail "a withheld image must be unreadable with its cause")
    [ Decode.Withheld_body_not_filed
    ; Decode.Withheld_body_unreadable
    ; Decode.Withheld_over_delivery_ceiling { bytes = 2; ceiling = 1 }
    ; Decode.Withheld_over_response_budget
    ];
  List.iter
    (fun defect ->
      match Picture.reading (Decode.Preview_defective defect) with
      | Picture.Unreadable (Picture.Defective again) ->
          Alcotest.(check bool) "keeps the defect" true (again = defect)
      | Picture.Image _ | Picture.Not_an_image | Picture.Unreadable _ ->
          Alcotest.fail "a defective image must be unreadable with its defect")
    [ Decode.Defect_bad_base64
    ; Decode.Defect_length_mismatch { declared = 1; actual = 2 }
    ; Decode.Defect_digest_mismatch
    ; Decode.Defect_not_an_image
    ]

let contains ~needle text =
  let n = String.length needle and t = String.length text in
  let rec at i = i + n <= t && (String.equal (String.sub text i n) needle || at (i + 1)) in
  at 0

let sha256 = String.init 64 (fun i -> "0123456789abcdef".[i mod 16])

let caption_of preview =
  Picture.caption_of_preview ~reference:"artifact:shots/home.png" ~bytes:41230 ~sha256
    ~format:"png" preview

let test_every_caption_carries_the_identity () =
  List.iter
    (fun preview ->
      let line = caption_of preview in
      Alcotest.(check bool) "reference" true (contains ~needle:"artifact:shots/home.png" line);
      Alcotest.(check bool) "size" true (contains ~needle:"41230B" line);
      Alcotest.(check bool) "short digest" true
        (contains ~needle:(String.sub sha256 0 Picture.short_sha_length) line);
      Alcotest.(check bool) "no more of the digest than the short form" false
        (contains ~needle:(String.sub sha256 0 (Picture.short_sha_length + 1)) line))
    [ Decode.Preview_image { ev_media = png; ev_data = "" }
    ; Decode.Preview_withheld Decode.Withheld_not_image_format
    ; Decode.Preview_withheld Decode.Withheld_body_not_filed
    ; Decode.Preview_defective Decode.Defect_digest_mismatch
    ]

let test_the_caption_names_the_media_type_of_an_image () =
  Alcotest.(check bool) "media type" true
    (contains ~needle:"image/png"
       (caption_of (Decode.Preview_image { ev_media = png; ev_data = "" })));
  Alcotest.(check bool) "a PDF names its extension instead" true
    (contains ~needle:"pdf"
       (Picture.caption_of_preview ~reference:"artifact:r.pdf" ~bytes:90 ~sha256 ~format:"pdf"
          (Decode.Preview_withheld Decode.Withheld_not_image_format)))

(* Which captions carry a cause is decided by the typed reading; the line
   carries the cause's own text, not a fixed phrase the test would copy. *)
let test_only_unreadable_images_carry_a_cause () =
  let causes =
    [ Picture.Withheld Decode.Withheld_body_not_filed
    ; Picture.Withheld (Decode.Withheld_over_delivery_ceiling { bytes = 9; ceiling = 3 })
    ; Picture.Defective Decode.Defect_bad_base64
    ]
  in
  List.iter
    (fun preview ->
      let line = caption_of preview in
      List.iter
        (fun cause ->
          Alcotest.(check bool) "a readable image states no cause" false
            (contains ~needle:(Picture.cause_text cause) line))
        causes)
    [ Decode.Preview_image { ev_media = png; ev_data = "" }
    ; Decode.Preview_withheld Decode.Withheld_not_image_format
    ];
  List.iter
    (fun cause ->
      let preview =
        match cause with
        | Picture.Withheld withheld -> Decode.Preview_withheld withheld
        | Picture.Defective defect -> Decode.Preview_defective defect
        | Picture.Conversion_failed _ | Picture.Not_png_after_conversion
        | Picture.Too_many_pixels _ | Picture.Empty_dimensions | Picture.Png_incomplete
        | Picture.Unknown_size | Picture.No_free_slot ->
            Alcotest.fail "fixture causes come from the server"
      in
      Alcotest.(check bool) "an unreadable image states its cause" true
        (contains ~needle:(Picture.cause_text cause) (caption_of preview)))
    causes;
  (* Causes found while preparing are stated the same way. *)
  List.iter
    (fun cause ->
      Alcotest.(check bool) "a prepared image states its cause" true
        (contains ~needle:(Picture.cause_text cause)
           (Picture.caption ~reference:"artifact:a.png" ~bytes:1 ~sha256 ~format:"png"
              (Picture.Unshown cause))))
    [ Picture.Conversion_failed "sips: exit 1"
    ; Picture.Not_png_after_conversion
    ; Picture.Too_many_pixels { width = 9000; height = 9000 }
    ; Picture.Empty_dimensions
    ; Picture.Png_incomplete
    ; Picture.Unknown_size
    ; Picture.No_free_slot
    ]

let test_a_cause_carries_the_numbers_it_was_stated_with () =
  let text =
    Picture.cause_text
      (Picture.Withheld (Decode.Withheld_over_delivery_ceiling { bytes = 512000; ceiling = 200000 }))
  in
  Alcotest.(check bool) "size" true (contains ~needle:"512000" text);
  Alcotest.(check bool) "limit" true (contains ~needle:"200000" text);
  let text =
    Picture.cause_text
      (Picture.Defective (Decode.Defect_length_mismatch { declared = 10; actual = 7 }))
  in
  Alcotest.(check bool) "both lengths" true
    (contains ~needle:"10" text && contains ~needle:"7" text);
  let text = Picture.cause_text (Picture.Too_many_pixels { width = 9000; height = 9000 }) in
  Alcotest.(check bool) "dimensions" true (contains ~needle:"9000x9000" text);
  Alcotest.(check bool) "and the limit" true
    (contains ~needle:(string_of_int Picture.max_picture_pixels) text)

let test_a_control_sequence_in_the_reference_never_reaches_the_line () =
  let line =
    Picture.caption_of_preview ~reference:"artifact:a\x1b[2Jb.png" ~bytes:1 ~sha256 ~format:"png"
      (Decode.Preview_withheld Decode.Withheld_not_image_format)
  in
  Alcotest.(check bool) "no escape byte" false (String.contains line '\x1b');
  let line =
    Picture.caption ~reference:"artifact:a\x1b[2Jb.png" ~bytes:1 ~sha256 ~format:"p\x1bng"
      (Picture.Unshown (Picture.Conversion_failed "sips: \x1b[31mfailed"))
  in
  Alcotest.(check bool) "nor in a prepared one, or a converter's report" false
    (String.contains line '\x1b')

(* {2 prepare} *)

let never_convert _ = Alcotest.fail "a PNG must not reach a converter"

let binary_item ?(index = 0) preview =
  Decode.Ev_binary
    { ev_b_reference = Printf.sprintf "artifact:shot-%d" index
    ; ev_b_bytes = 10
    ; ev_b_sha256 = sha256
    ; ev_b_format = "png"
    ; ev_b_preview = preview
    }

let image_preview ~media data = Decode.Preview_image { ev_media = media; ev_data = data }

let pictures_of ?(layout=Picture.Together) ~convert items =
  match Picture.prepare ~layout ~display:kitty ~convert (Decode.Evidence_items items) with
  | Picture.Items prepared ->
      List.map
        (function
          | Picture.Binary_item { picture; _ } -> picture
          | Picture.Text_item _ | Picture.Source_item _ -> Alcotest.fail "a binary item came back as text")
        prepared
  | Picture.Access_unavailable _ -> Alcotest.fail "available evidence came back unavailable"

let slot_name slot = string_of_int (Masc_tui_graphics.image_id slot)

let test_a_png_is_drawable_without_a_converter () =
  match pictures_of ~convert:never_convert
          [ binary_item (image_preview ~media:png (png_of ~width:1000 ~height:500)) ] with
  | [ Picture.Drawable pixels ] ->
      Alcotest.(check (pair int int)) "size from the header" (1000, 500)
        (pixels.pixel_width, pixels.pixel_height);
      Alcotest.(check string) "the bytes go to the terminal as they are"
        (png_of ~width:1000 ~height:500) pixels.png;
      Alcotest.(check string) "the key is the digest of those bytes"
        Agent_core_sha256.(digest_string pixels.png |> to_hex) pixels.key;
      Alcotest.(check string) "the first picture owns the first slot"
        (slot_name Masc_tui_graphics.Evidence_image_1) (slot_name pixels.slot)
  | _ -> Alcotest.fail "a PNG was not drawable"

let test_another_format_is_converted_and_measured_after () =
  let converted = png_of ~width:800 ~height:600 in
  let seen = ref [] in
  let convert bytes =
    seen := bytes :: !seen;
    Ok converted
  in
  let jpeg = jpeg_of ~width:800 ~height:600 in
  (match pictures_of ~convert [ binary_item (image_preview ~media:Media.Jpeg jpeg) ] with
   | [ Picture.Drawable pixels ] ->
       Alcotest.(check string) "the terminal gets the converted PNG" converted pixels.png;
       Alcotest.(check string) "and the item keeps the format it was in" "image/jpeg"
         (Media.media_type_to_string pixels.media);
       Alcotest.(check (pair int int)) "measured on the PNG" (800, 600)
         (pixels.pixel_width, pixels.pixel_height)
   | _ -> Alcotest.fail "a JPEG was not drawable");
  Alcotest.(check (list string)) "the converter saw the original bytes once" [ jpeg ] !seen

let test_a_failed_conversion_is_named_and_frees_the_slot () =
  let converted = png_of ~width:10 ~height:10 in
  let convert bytes =
    if String.equal bytes (jpeg_of ~width:5 ~height:5) then Error "sips: exit 1"
    else Ok converted
  in
  match
    pictures_of ~convert
      [ binary_item ~index:0 (image_preview ~media:Media.Jpeg (jpeg_of ~width:5 ~height:5))
      ; binary_item ~index:1 (image_preview ~media:Media.Jpeg (jpeg_of ~width:6 ~height:6))
      ]
  with
  | [ Picture.Unshown (Picture.Conversion_failed detail); Picture.Drawable pixels ] ->
      Alcotest.(check string) "the converter's report is kept" "sips: exit 1" detail;
      Alcotest.(check string) "the next picture takes the first slot"
        (slot_name Masc_tui_graphics.Evidence_image_1) (slot_name pixels.slot)
  | _ -> Alcotest.fail "a failed conversion was not named"

let test_a_converter_that_does_not_make_a_png_is_named () =
  match
    pictures_of ~convert:(fun _ -> Ok "GIF89a not a png")
      [ binary_item (image_preview ~media:Media.Gif "GIF89a\001\000\001\000") ]
  with
  | [ Picture.Unshown Picture.Not_png_after_conversion ] -> ()
  | _ -> Alcotest.fail "a non-PNG conversion output was handed to the terminal"

let test_a_huge_picture_in_a_small_file_is_never_decoded () =
  let side = 5000 in
  Alcotest.(check bool) "fixture is over the limit" true
    (side * side > Picture.max_picture_pixels);
  (match
     pictures_of ~convert:(fun _ -> Alcotest.fail "the converter was handed a huge JPEG")
       [ binary_item (image_preview ~media:Media.Jpeg (jpeg_of ~width:side ~height:side)) ]
   with
   | [ Picture.Unshown (Picture.Too_many_pixels { width; height }) ] ->
       Alcotest.(check (pair int int)) "the dimensions are named" (side, side) (width, height)
   | _ -> Alcotest.fail "a JPEG over the pixel limit was not refused");
  (match
     pictures_of ~convert:never_convert
       [ binary_item (image_preview ~media:png (png_of ~width:side ~height:side)) ]
   with
   | [ Picture.Unshown (Picture.Too_many_pixels _) ] -> ()
   | _ -> Alcotest.fail "a PNG over the pixel limit was not refused");
  (* The limit is on the product, inclusive: a picture of exactly the limit is
     shown. *)
  match
    pictures_of ~convert:never_convert
      [ binary_item
          (image_preview ~media:png
             (png_of ~width:(Picture.max_picture_pixels / 1000) ~height:1000)) ]
  with
  | [ Picture.Drawable _ ] -> ()
  | _ -> Alcotest.fail "a picture of exactly the limit was refused"

let test_a_png_without_a_readable_header_is_named () =
  match
    pictures_of ~convert:never_convert
      [ binary_item (image_preview ~media:png "\x89PNG\r\n\x1a\n") ]
  with
  | [ Picture.Unshown Picture.Unknown_size ] -> ()
  | _ -> Alcotest.fail "a truncated PNG was drawable"

let test_pictures_beyond_the_slots_are_listed_by_caption () =
  let slots = List.length Masc_tui_graphics.evidence_images in
  let items =
    List.init (slots + 1) (fun index ->
      binary_item ~index (image_preview ~media:png (png_of ~width:(10 + index) ~height:10)))
  in
  let pictures = pictures_of ~convert:never_convert items in
  let slot_ids =
    List.filter_map
      (function Picture.Drawable pixels -> Some (Masc_tui_graphics.image_id pixels.slot) | _ -> None)
      pictures
  in
  Alcotest.(check (list int)) "slots in the order the evidence lists the pictures"
    (List.map Masc_tui_graphics.image_id Masc_tui_graphics.evidence_images)
    slot_ids;
  match List.nth pictures slots with
  | Picture.Unshown Picture.No_free_slot -> ()
  | _ -> Alcotest.fail "the picture past the last slot was not named"

let test_individual_images_do_not_exhaust_simultaneous_slots () =
  let count=List.length Masc_tui_graphics.evidence_images + 1 in
  let images=List.init count (fun index ->
    binary_item ~index (image_preview ~media:png (png_of ~width:(10+index) ~height:10))) in
  let pictures=pictures_of ~layout:Picture.One_at_a_time ~convert:never_convert images in
  Alcotest.(check int) "every selected image remains prepared" count (List.length pictures);
  List.iteri (fun index -> function
    | Picture.Drawable pixels ->
      Alcotest.(check string) "selected original image bytes survive preparation"
        (png_of ~width:(10+index) ~height:10) pixels.png;
      Alcotest.(check int) "individual selections reuse the first image slot"
        (Masc_tui_graphics.image_id (List.hd Masc_tui_graphics.evidence_images))
        (Masc_tui_graphics.image_id pixels.slot)
    | Picture.Undrawn_image _ | Binary_only | Unshown _ ->
      Alcotest.fail "a later individual image exhausted simultaneous slots") pictures

let test_other_previews_and_items_keep_their_meaning () =
  let note = Decode.Ev_note "tests green" in
  match
    Picture.prepare ~layout:Picture.Together ~display:kitty ~convert:never_convert
      (Decode.Evidence_items
         [ note
         ; binary_item ~index:0 (Decode.Preview_withheld Decode.Withheld_not_image_format)
         ; binary_item ~index:1 (Decode.Preview_withheld Decode.Withheld_over_response_budget)
         ; binary_item ~index:2 (Decode.Preview_defective Decode.Defect_digest_mismatch)
         ])
  with
  | Picture.Items
      [ Picture.Text_item kept
      ; Picture.Binary_item { picture = Picture.Binary_only; _ }
      ; Picture.Binary_item
          { picture = Picture.Unshown (Picture.Withheld Decode.Withheld_over_response_budget); _ }
      ; Picture.Binary_item
          { picture = Picture.Unshown (Picture.Defective Decode.Defect_digest_mismatch); _ }
      ] ->
      Alcotest.(check bool) "a note stays a note" true (kept = note)
  | _ -> Alcotest.fail "previews changed meaning in preparation"

let test_unavailable_access_passes_through () =
  match
    Picture.prepare ~layout:Picture.Together ~display:kitty ~convert:never_convert
      (Decode.Evidence_access_unavailable "no snapshot")
  with
  | Picture.Access_unavailable "no snapshot" -> ()
  | _ -> Alcotest.fail "the server's reason was lost"

(* {2 block, plan} *)

let drawable ~width ~height =
  match
    pictures_of ~convert:never_convert
      [ binary_item (image_preview ~media:png (png_of ~width ~height)) ]
  with
  | [ (Picture.Drawable _ as picture) ] -> picture
  | _ -> Alcotest.fail "fixture not drawable"

let block_testable =
  let pp formatter = function
    | Picture.Caption_only -> Format.pp_print_string formatter "Caption_only"
    | Picture.Picture { cols; rows } -> Format.fprintf formatter "Picture %dx%d" cols rows
  in
  Alcotest.testable pp ( = )

let test_a_picture_is_fitted_to_the_width_keeping_its_shape () =
  (* 1000 x 500 at 10 x 20 px cells: a cell is twice as tall as wide, so the
     picture is twice as many cells wide as tall. In an 80 cell pane, 74 cells
     are left of the indent: 740 px across is 370 px down, 18.5 rows, rounded
     down to 18; 18 rows are 360 px, which at 2:1 is 72 cells across. *)
  Alcotest.(check block_testable) "bound by the width"
    (Picture.Picture { cols = 72; rows = 18 })
    (Picture.block kitty (drawable ~width:1000 ~height:500) ~width:80 ~caption_rows:1
       ~content_height:40);
  (* In a 200 cell pane the width allows 48 rows; the row cap of 20 binds, and
     20 rows are 400 px, 800 px across, 80 cells. *)
  Alcotest.(check block_testable) "bound by the row cap"
    (Picture.Picture { cols = 80; rows = Picture.picture_max_rows })
    (Picture.block kitty (drawable ~width:1000 ~height:500) ~width:200 ~caption_rows:1
       ~content_height:40)

let test_the_picture_never_claims_more_than_the_space () =
  List.iter
    (fun (width, height, pane_width, content_height) ->
      match
        Picture.block kitty (drawable ~width ~height) ~width:pane_width ~caption_rows:2
          ~content_height
      with
      | Picture.Caption_only -> Alcotest.fail "every fixture has room for a picture"
      | Picture.Picture { cols; rows } ->
          let max_cols = pane_width - Picture.picture_indent_cols in
          Alcotest.(check bool) "columns inside the width left of the indent" true
            (cols >= 1 && cols <= max_cols);
          Alcotest.(check bool) "rows inside the row cap" true
            (rows >= 1 && rows <= Picture.picture_max_rows);
          Alcotest.(check bool) "and under the caption inside the content height" true
            (rows + 2 <= content_height);
          (* 10 x 20 px cells: [rows] rows are rows * 20 px tall, which at the
             picture's shape is this many cells across. *)
          let shape_cols = ((rows * 20 * width) + (height * 10) - 1) / (height * 10) in
          Alcotest.(check int) "the width is the picture's shape, within the space"
            (max 1 (min max_cols shape_cols)) cols)
    [ 1000, 500, 80, 40; 500, 1000, 80, 40; 600, 100, 60, 25; 100, 3000, 120, 50; 1, 1, 40, 12 ]

let test_a_tall_picture_is_bounded_by_the_pane () =
  match
    Picture.block kitty (drawable ~width:500 ~height:2000) ~width:100 ~caption_rows:3
      ~content_height:12
  with
  | Picture.Picture { rows; _ } ->
      Alcotest.(check int) "the rows left under the caption" 9 rows
  | Picture.Caption_only -> Alcotest.fail "nine rows is a picture"

let test_too_little_room_is_a_caption () =
  Alcotest.(check block_testable) "fewer rows than a readable picture"
    Picture.Caption_only
    (Picture.block kitty (drawable ~width:500 ~height:500) ~width:100 ~caption_rows:3
       ~content_height:(3 + View.min_pixel_rows - 1));
  Alcotest.(check bool) "the fewest readable rows is a picture" true
    (match
       Picture.block kitty (drawable ~width:500 ~height:500) ~width:100 ~caption_rows:3
         ~content_height:(3 + View.min_pixel_rows)
     with
     | Picture.Picture _ -> true
     | Picture.Caption_only -> false);
  Alcotest.(check block_testable) "no width left of the indent" Picture.Caption_only
    (Picture.block kitty (drawable ~width:500 ~height:500) ~width:Picture.picture_indent_cols
       ~caption_rows:1 ~content_height:40)

let test_only_a_pixel_terminal_gets_a_picture () =
  let picture = drawable ~width:500 ~height:500 in
  List.iter
    (fun (label, display) ->
      Alcotest.(check block_testable) label Picture.Caption_only
        (Picture.block display picture ~width:100 ~caption_rows:1 ~content_height:40))
    [ "a mosaic terminal (iTerm2, or Kitty without a cell size)", View.Mosaic
    ; "NO_COLOR", View.No_picture
    ];
  List.iter
    (fun (label, picture) ->
      Alcotest.(check block_testable) label Picture.Caption_only
        (Picture.block kitty picture ~width:100 ~caption_rows:1 ~content_height:40))
    [ "an image on a terminal that draws none", Picture.Undrawn_image png
    ; "a binary artifact", Picture.Binary_only
    ; "an unreadable image", Picture.Unshown Picture.Unknown_size
    ]

let plan_testable =
  let pp formatter = function
    | Picture.Hidden -> Format.pp_print_string formatter "Hidden"
    | Picture.Place { row; column; cut_top; shown_rows } ->
        Format.fprintf formatter "Place %d,%d cut %d shows %d" row column cut_top shown_rows
  in
  Alcotest.testable pp ( = )

let test_a_picture_is_placed_for_every_row_of_it_that_is_shown () =
  (* The area is rows 10 to 17 of the content, in a window of 12 rows. *)
  let slot = { Picture.first = 10; box = { Picture.cols = 20; rows = 8 } } in
  let plan ~scroll =
    Picture.plan slot ~scroll ~content_height:12 ~content_origin:(3, 2)
  in
  let column = 2 + Picture.picture_indent_cols in
  let place ~row ~cut_top ~shown_rows =
    Picture.Place { row; column; cut_top; shown_rows }
  in
  Alcotest.(check plan_testable) "inside the window, the row is origin + offset"
    (place ~row:(3 + 2) ~cut_top:0 ~shown_rows:8) (plan ~scroll:8);
  Alcotest.(check plan_testable) "its first row exactly at the top"
    (place ~row:3 ~cut_top:0 ~shown_rows:8) (plan ~scroll:10);
  Alcotest.(check plan_testable) "two rows scrolled off the top are cut, the rest shows"
    (place ~row:3 ~cut_top:2 ~shown_rows:6) (plan ~scroll:12);
  Alcotest.(check plan_testable) "its last row alone at the top"
    (place ~row:3 ~cut_top:7 ~shown_rows:1) (plan ~scroll:17);
  Alcotest.(check plan_testable) "wholly above the window" Picture.Hidden (plan ~scroll:18);
  Alcotest.(check plan_testable) "its last row exactly at the bottom"
    (place ~row:(3 + 4) ~cut_top:0 ~shown_rows:8) (plan ~scroll:6);
  Alcotest.(check plan_testable) "its last two rows below the window are cut"
    (place ~row:(3 + 5) ~cut_top:0 ~shown_rows:7) (plan ~scroll:5);
  Alcotest.(check plan_testable) "only its first two rows inside the window"
    (place ~row:(3 + 10) ~cut_top:0 ~shown_rows:2) (plan ~scroll:0);
  Alcotest.(check plan_testable) "wholly below the window" Picture.Hidden
    (Picture.plan slot ~scroll:0 ~content_height:10 ~content_origin:(3, 2))

(* Every scroll offset, not a few: the operator pages through the pane, so a
   picture that is Hidden at an offset where one of its rows is in the window
   would be a gap with nothing in it. *)
let test_no_scroll_offset_leaves_a_shown_row_without_its_picture () =
  let rows = 9 and first = 14 and content_height = 12 in
  let slot = { Picture.first; box = { Picture.cols = 20; rows } } in
  for scroll = 0 to first + rows do
    let shown_rows =
      List.length
        (List.filter
           (fun row -> row >= scroll && row < scroll + content_height)
           (List.init rows (fun index -> first + index)))
    in
    match Picture.plan slot ~scroll ~content_height ~content_origin:(0, 0) with
    | Picture.Hidden -> Alcotest.(check int) "hidden only when no row shows" 0 shown_rows
    | Picture.Place { shown_rows = placed; cut_top; row; _ } ->
        Alcotest.(check int) "every shown row is placed" shown_rows placed;
        Alcotest.(check int) "the cut is the rows above the window"
          (max 0 (scroll - first)) cut_top;
        Alcotest.(check int) "it starts at the first shown row" (max first scroll - scroll) row
  done

let test_a_placement_carries_the_slot_the_key_and_the_box () =
  match drawable ~width:640 ~height:480 with
  | Picture.Drawable pixels ->
      let placement =
        Picture.png_placement pixels { Picture.cols = 30; rows = 12 } ~row:7 ~column:9
          ~cut_top:0 ~shown_rows:12
      in
      Alcotest.(check int) "the picture's own terminal image"
        (Masc_tui_graphics.image_id pixels.slot) placement.View.png_image_id;
      Alcotest.(check string) "compared by digest" pixels.key placement.View.png_key;
      Alcotest.(check string) "sent as the PNG" pixels.png placement.View.png_data;
      Alcotest.(check (list int)) "where and how big" [ 7; 9; 30; 12 ]
        [ placement.View.png_row; placement.View.png_column; placement.View.png_cols
        ; placement.View.png_rows ];
      Alcotest.(check bool) "all of it shows, so nothing is cropped" true
        (placement.View.png_crop = None)
  | Picture.Undrawn_image _ | Picture.Binary_only | Picture.Unshown _ ->
      Alcotest.fail "fixture not drawable"

let crop_testable =
  let pp formatter = function
    | None -> Format.pp_print_string formatter "whole"
    | Some { Masc_tui_graphics.top_px; height_px } ->
        Format.fprintf formatter "y=%d h=%d" top_px height_px
  in
  Alcotest.testable pp ( = )

let pixels_of ~width ~height =
  match drawable ~width ~height with
  | Picture.Drawable pixels -> pixels
  | Picture.Undrawn_image _ | Picture.Binary_only | Picture.Unshown _ ->
      Alcotest.fail "fixture not drawable"

let crop_of pixels ~rows ~cut_top ~shown_rows =
  (Picture.png_placement pixels { Picture.cols = 30; rows } ~row:0 ~column:0 ~cut_top
     ~shown_rows).View.png_crop

let test_a_cut_picture_is_cropped_to_the_rows_that_show () =
  (* 400 px tall in 10 rows: 40 source pixels a row. *)
  let pixels = pixels_of ~width:300 ~height:400 in
  Alcotest.(check crop_testable) "all rows" None (crop_of pixels ~rows:10 ~cut_top:0 ~shown_rows:10);
  Alcotest.(check crop_testable) "the first three rows"
    (Some { Masc_tui_graphics.top_px = 0; height_px = 120 })
    (crop_of pixels ~rows:10 ~cut_top:0 ~shown_rows:3);
  Alcotest.(check crop_testable) "four rows cut from the top"
    (Some { Masc_tui_graphics.top_px = 160; height_px = 240 })
    (crop_of pixels ~rows:10 ~cut_top:4 ~shown_rows:6)

let test_the_parts_of_a_cut_picture_tile_without_a_gap () =
  (* 7 rows over 100 px does not divide: every cut must still start where the
     one above it ended, and the parts must add up to the picture. *)
  let pixels = pixels_of ~width:50 ~height:100 in
  let rows = 7 in
  for cut = 1 to rows - 1 do
    let above = crop_of pixels ~rows ~cut_top:0 ~shown_rows:cut in
    let below = crop_of pixels ~rows ~cut_top:cut ~shown_rows:(rows - cut) in
    match above, below with
    | Some above, Some below ->
        Alcotest.(check int) "starts where the part above ended"
          (above.Masc_tui_graphics.top_px + above.Masc_tui_graphics.height_px)
          below.Masc_tui_graphics.top_px;
        Alcotest.(check int) "and the two make the picture" 100
          (above.Masc_tui_graphics.height_px + below.Masc_tui_graphics.height_px)
    | _ -> Alcotest.fail "a cut picture must carry a crop"
  done

let test_a_picture_shorter_than_its_rows_keeps_a_pixel_per_part () =
  (* 3 px over 20 rows: a row is under a pixel, and a crop of a pixel is the
     least the terminal is asked for. *)
  let pixels = pixels_of ~width:1 ~height:3 in
  match crop_of pixels ~rows:20 ~cut_top:1 ~shown_rows:1 with
  | Some { Masc_tui_graphics.height_px; _ } ->
      Alcotest.(check bool) "never an empty source rectangle" true (height_px >= 1)
  | None -> Alcotest.fail "a cut picture must carry a crop"

(* A header that parses is not a picture: zero sides and sides whose product
   wraps are the fixtures a hostile artifact author writes. *)
let prepare_one data =
  match pictures_of ~convert:never_convert [ binary_item (image_preview ~media:png data) ] with
  | [ picture ] -> picture
  | _ -> Alcotest.fail "one item, one picture"

let test_a_side_of_zero_is_not_drawable () =
  List.iter
    (fun (width, height) ->
      match prepare_one (png_of ~width ~height) with
      | Picture.Unshown Picture.Empty_dimensions -> ()
      | _ -> Alcotest.failf "%dx%d reached the terminal" width height)
    [ 1, 0; 0, 1; 0, 0; 500, 0 ];
  (* The layout divides by the height. *)
  match prepare_one (png_of ~width:10 ~height:0) with
  | Picture.Unshown _ as picture ->
      Alcotest.(check block_testable) "and lays out as a caption" Picture.Caption_only
        (Picture.block kitty picture ~width:80 ~caption_rows:1 ~content_height:40)
  | _ -> Alcotest.fail "a zero height was drawable"

let test_a_product_that_wraps_the_int_is_over_the_limit () =
  List.iter
    (fun (width, height) ->
      match prepare_one (png_of ~width ~height) with
      | Picture.Unshown (Picture.Too_many_pixels _) -> ()
      | _ -> Alcotest.failf "%dx%d was drawable" width height)
    [ 1 lsl 31, 1 lsl 31; 0xFFFFFFFF, 0xFFFFFFFF; 0xFFFFFFFF, 1; 1, 0xFFFFFFFF ]

let test_the_limit_is_exact_on_both_sides () =
  let limit = Picture.max_picture_pixels in
  (match prepare_one (png_of ~width:limit ~height:1) with
   | Picture.Drawable _ -> ()
   | _ -> Alcotest.fail "exactly the limit, as one row, was refused");
  match prepare_one (png_of ~width:(limit + 1) ~height:1) with
  | Picture.Unshown (Picture.Too_many_pixels _) -> ()
  | _ -> Alcotest.fail "one pixel over the limit was drawable"

let test_a_png_that_stops_before_its_last_chunk_is_named () =
  let whole = png_of ~width:100 ~height:100 in
  let cut = String.sub whole 0 (String.length whole - 1) in
  (match prepare_one cut with
   | Picture.Unshown Picture.Png_incomplete -> ()
   | _ -> Alcotest.fail "a truncated PNG was drawable");
  (* It does not hold a slot: the next picture takes the first. *)
  match
    pictures_of ~convert:never_convert
      [ binary_item ~index:0 (image_preview ~media:png cut)
      ; binary_item ~index:1 (image_preview ~media:png whole) ]
  with
  | [ Picture.Unshown Picture.Png_incomplete; Picture.Drawable pixels ] ->
      Alcotest.(check string) "the slot is free"
        (slot_name Masc_tui_graphics.Evidence_image_1) (slot_name pixels.slot)
  | _ -> Alcotest.fail "a truncated PNG held a slot"

let test_a_converted_picture_is_measured_again () =
  (* WebP carries no size this module reads, so the converter's output is the
     only measure: a bomb that converts to a huge PNG is refused there. *)
  let webp = "RIFF\x00\x00\x00\x00WEBPVP8 " in
  let side = 5000 in
  (match
     pictures_of ~convert:(fun _ -> Ok (png_of ~width:side ~height:side))
       [ binary_item (image_preview ~media:Media.Webp webp) ]
   with
   | [ Picture.Unshown (Picture.Too_many_pixels { width; height }) ] ->
       Alcotest.(check (pair int int)) "the converted size is named" (side, side) (width, height)
   | _ -> Alcotest.fail "an oversized conversion output was drawable");
  match
    pictures_of ~convert:(fun _ -> Ok (png_of ~width:10 ~height:0))
      [ binary_item (image_preview ~media:Media.Webp webp) ]
  with
  | [ Picture.Unshown Picture.Empty_dimensions ] -> ()
  | _ -> Alcotest.fail "an empty conversion output was drawable"

let test_a_terminal_without_pixels_converts_nothing_and_holds_no_slot () =
  let items =
    List.init 6 (fun index ->
      binary_item ~index (image_preview ~media:Media.Jpeg (jpeg_of ~width:10 ~height:10)))
  in
  List.iter
    (fun display ->
      match
        Picture.prepare ~layout:Picture.Together ~display
          ~convert:(fun _ -> Alcotest.fail "a converter ran for a terminal that draws no pixels")
          (Decode.Evidence_items items)
      with
      | Picture.Items prepared ->
          List.iter
            (function
              | Picture.Binary_item { picture = Picture.Undrawn_image media; _ } ->
                  Alcotest.(check string) "the image keeps its format" "image/jpeg"
                    (Media.media_type_to_string media)
              | _ ->
                  Alcotest.fail "every image is its caption alone, past the slot count too")
            prepared
      | Picture.Access_unavailable _ -> Alcotest.fail "available evidence came back unavailable")
    [ View.Mosaic; View.No_picture ];
  Alcotest.(check bool) "its line names an image and no cause" true
    (contains ~needle:"image/jpeg"
       (Picture.caption ~reference:"artifact:a.jpg" ~bytes:1 ~sha256 ~format:"jpg"
          (Picture.Undrawn_image Media.Jpeg)));
  Alcotest.(check bool) "and does not say not shown" false
    (contains ~needle:"not shown"
       (Picture.caption ~reference:"artifact:a.jpg" ~bytes:1 ~sha256 ~format:"jpg"
          (Picture.Undrawn_image Media.Jpeg)))

let test_a_banner_wider_than_the_pane_at_one_row_is_a_caption () =
  (* 4000 x 20 in 94 columns of 10 x 20 px: the pane holds 0.235 of a row of
     it. The terminal draws no fewer than one row, so the picture would run
     across the pane's edge. *)
  Alcotest.(check block_testable) "a caption" Picture.Caption_only
    (Picture.block kitty (drawable ~width:4000 ~height:20) ~width:100 ~caption_rows:1
       ~content_height:40);
  (* The widest picture that fits at one row (94 cells of 10 px across a 20 px
     tall picture at one 20 px row) is still a picture. *)
  Alcotest.(check block_testable) "a banner that fits one row"
    (Picture.Picture { cols = 94; rows = 1 })
    (Picture.block kitty (drawable ~width:940 ~height:20) ~width:100 ~caption_rows:1
       ~content_height:40)

let () =
  Alcotest.run "Tui evidence picture"
    [ ( "reading"
      , [ Alcotest.test_case "each preview has one reading" `Quick
            test_each_preview_has_one_reading ] )
    ; ( "caption"
      , [ Alcotest.test_case "every caption carries the identity" `Quick
            test_every_caption_carries_the_identity
        ; Alcotest.test_case "an image names its media type" `Quick
            test_the_caption_names_the_media_type_of_an_image
        ; Alcotest.test_case "only unreadable images carry a cause" `Quick
            test_only_unreadable_images_carry_a_cause
        ; Alcotest.test_case "a cause carries its numbers" `Quick
            test_a_cause_carries_the_numbers_it_was_stated_with
        ; Alcotest.test_case "control sequences are removed" `Quick
            test_a_control_sequence_in_the_reference_never_reaches_the_line
        ] )
    ; ( "prepare"
      , [ Alcotest.test_case "a PNG is drawable without a converter" `Quick
            test_a_png_is_drawable_without_a_converter
        ; Alcotest.test_case "another format is converted and measured after" `Quick
            test_another_format_is_converted_and_measured_after
        ; Alcotest.test_case "a failed conversion is named and frees the slot" `Quick
            test_a_failed_conversion_is_named_and_frees_the_slot
        ; Alcotest.test_case "a converter that makes no PNG is named" `Quick
            test_a_converter_that_does_not_make_a_png_is_named
        ; Alcotest.test_case "a huge picture in a small file is never decoded" `Quick
            test_a_huge_picture_in_a_small_file_is_never_decoded
        ; Alcotest.test_case "a PNG without a readable header is named" `Quick
            test_a_png_without_a_readable_header_is_named
        ; Alcotest.test_case "pictures beyond the slots are listed by caption" `Quick
            test_pictures_beyond_the_slots_are_listed_by_caption
        ; Alcotest.test_case "individual image selections never exhaust simultaneous slots" `Quick
            test_individual_images_do_not_exhaust_simultaneous_slots
        ; Alcotest.test_case "other previews and items keep their meaning" `Quick
            test_other_previews_and_items_keep_their_meaning
        ; Alcotest.test_case "unavailable access passes through" `Quick
            test_unavailable_access_passes_through
        ; Alcotest.test_case "a side of zero is not drawable" `Quick
            test_a_side_of_zero_is_not_drawable
        ; Alcotest.test_case "a product that wraps the int is over the limit" `Quick
            test_a_product_that_wraps_the_int_is_over_the_limit
        ; Alcotest.test_case "the limit is exact on both sides" `Quick
            test_the_limit_is_exact_on_both_sides
        ; Alcotest.test_case "a PNG that stops before its last chunk is named" `Quick
            test_a_png_that_stops_before_its_last_chunk_is_named
        ; Alcotest.test_case "a converted picture is measured again" `Quick
            test_a_converted_picture_is_measured_again
        ; Alcotest.test_case "a terminal without pixels converts nothing" `Quick
            test_a_terminal_without_pixels_converts_nothing_and_holds_no_slot
        ] )
    ; ( "layout"
      , [ Alcotest.test_case "a picture keeps its shape in the width" `Quick
            test_a_picture_is_fitted_to_the_width_keeping_its_shape
        ; Alcotest.test_case "the picture never claims more than the space" `Quick
            test_the_picture_never_claims_more_than_the_space
        ; Alcotest.test_case "a tall picture is bounded by the pane" `Quick
            test_a_tall_picture_is_bounded_by_the_pane
        ; Alcotest.test_case "too little room is a caption" `Quick
            test_too_little_room_is_a_caption
        ; Alcotest.test_case "only a pixel terminal gets a picture" `Quick
            test_only_a_pixel_terminal_gets_a_picture
        ; Alcotest.test_case "a picture is placed for every row of it that is shown" `Quick
            test_a_picture_is_placed_for_every_row_of_it_that_is_shown
        ; Alcotest.test_case "no scroll offset leaves a shown row without its picture" `Quick
            test_no_scroll_offset_leaves_a_shown_row_without_its_picture
        ; Alcotest.test_case "a cut picture is cropped to the rows that show" `Quick
            test_a_cut_picture_is_cropped_to_the_rows_that_show
        ; Alcotest.test_case "the parts of a cut picture tile without a gap" `Quick
            test_the_parts_of_a_cut_picture_tile_without_a_gap
        ; Alcotest.test_case "a short picture keeps a pixel per part" `Quick
            test_a_picture_shorter_than_its_rows_keeps_a_pixel_per_part
        ; Alcotest.test_case "a banner wider than the pane is a caption" `Quick
            test_a_banner_wider_than_the_pane_at_one_row_is_a_caption
        ; Alcotest.test_case "a placement carries the slot, key and box" `Quick
            test_a_placement_carries_the_slot_the_key_and_the_box
        ] )
    ]
