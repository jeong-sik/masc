(* The row model of the evidence section: which rows are text, which rows are
   a picture's reserved area, and where that area starts once every earlier
   row has been wrapped. Assertions read rows by position and by the typed
   slots, not by the wording of the captions. *)

module Decode = Masc.Tui_decode
module Picture = Masc_tui_evidence_picture
module Section = Masc_tui_render_evidence
module View = Masc_tui_portrait_view
module Failure = Masc_tui_types.Verification_evidence_read

let contains ~needle text =
  let n = String.length needle and t = String.length text in
  let rec at i = i + n <= t && (String.equal (String.sub text i n) needle || at (i + 1)) in
  at 0

let be32 value =
  String.init 4 (fun index -> Char.chr ((value lsr (8 * (3 - index))) land 0xff))

let png_of ~width ~height =
  "\x89PNG\r\n\x1a\n" ^ be32 13 ^ "IHDR" ^ be32 width ^ be32 height ^ "\x08\x06\x00\x00\x00"
  ^ "crc!" ^ "image data"

let sha256 = String.make 64 'a'

let prepared_png ?(slot = Masc_tui_graphics.Evidence_image_1) ~width ~height () =
  Picture.Drawable
    { media = Masc.Keeper_vision_downscale.Png
    ; png = png_of ~width ~height
    ; key = "k"
    ; pixel_width = width
    ; pixel_height = height
    ; slot
    }

let binary ?(reference = "artifact:shots/home.png") picture =
  Picture.Binary_item { reference; bytes = 41230; sha256; format = "png"; picture }

let note text = Picture.Text_item (Decode.Ev_note text)

let unreadable =
  Picture.Text_item
    (Decode.Ev_artifact_unreadable
       { ev_u_reference = Some "artifact:gone.txt"; ev_u_reason = "missing" })

let evidence items = Some ("task-1", Ok (Picture.Items items))

let kitty = View.Pixels { cell_width = 10; cell_height = 20 }

let section ?(width = 80) ?(content_height = 40) ?(display = kitty) ?(task_id = "task-1")
    evidence =
  Section.section ~evidence ~task_id ~width ~content_height ~display

let texts rows = List.map snd rows

let index_of ~needle rows =
  let rec find index = function
    | [] -> Alcotest.fail ("no row has " ^ needle)
    | (_, text) :: rest -> if contains ~needle text then index else find (index + 1) rest
  in
  find 0 rows

(* The fixture: one image between a note and an unreadable artifact. *)
let fixture ?(note_text = "tests green") () =
  evidence [ note note_text; binary (prepared_png ~width:1000 ~height:500 ()); unreadable ]

let test_a_pictures_area_follows_its_caption_and_precedes_the_next_item () =
  let rows, pictures = section (fixture ()) in
  match pictures with
  | [ (slot, _) ] ->
      let caption = index_of ~needle:"artifact:shots/home.png" rows in
      Alcotest.(check int) "the area starts on the row under the caption" (caption + 1) slot.first;
      List.iteri
        (fun offset row ->
          if offset >= slot.first && offset < slot.first + slot.box.rows then
            Alcotest.(check string) "a reserved row is empty text" "" (snd row))
        rows;
      Alcotest.(check int) "the next item starts right after the area"
        (slot.first + slot.box.rows)
        (index_of ~needle:"artifact:gone.txt" rows)
  | _ -> Alcotest.fail "one image, one picture"

(* A longer note wraps into more rows ahead of the picture. The index follows. *)
let test_the_index_follows_wrapping_of_earlier_rows () =
  let long = String.concat " " (List.init 60 (fun index -> Printf.sprintf "word%d" index)) in
  let short_rows, short_pictures = section (fixture ()) in
  let long_rows, long_pictures = section (fixture ~note_text:long ()) in
  match short_pictures, long_pictures with
  | [ (short_slot, _) ], [ (long_slot, _) ] ->
      Alcotest.(check bool) "the long note took more rows" true
        (List.length long_rows > List.length short_rows);
      Alcotest.(check int) "and the area moved down by exactly that many"
        (List.length long_rows - List.length short_rows)
        (long_slot.first - short_slot.first);
      Alcotest.(check int) "still directly under its caption"
        (index_of ~needle:"artifact:shots/home.png" long_rows + 1) long_slot.first
  | _ -> Alcotest.fail "the picture was lost"

let test_a_terminal_without_pixels_gets_the_caption_alone () =
  let pixel_rows, pixel_pictures = section (fixture ()) in
  List.iter
    (fun (label, display) ->
      let rows, pictures = section ~display (fixture ()) in
      Alcotest.(check int) (label ^ ": nothing to place") 0 (List.length pictures);
      match pixel_pictures with
      | [ (slot, _) ] ->
          Alcotest.(check int) (label ^ ": exactly the reserved area is gone")
            (List.length pixel_rows - slot.box.rows) (List.length rows);
          ignore (index_of ~needle:"artifact:shots/home.png" rows)
      | _ -> Alcotest.fail "no picture to compare")
    [ "mosaic", View.Mosaic; "no picture", View.No_picture ]

let test_an_image_that_is_not_shown_says_so_and_reserves_nothing () =
  let rows, pictures =
    section
      (evidence
         [ binary (Picture.Unshown (Picture.Withheld (Decode.Withheld_over_delivery_ceiling
                                                         { bytes = 512000; ceiling = 200000 }))) ])
  in
  Alcotest.(check int) "no picture" 0 (List.length pictures);
  (* The caption wraps; the item is every row from the one with the reference. *)
  let item =
    String.concat " "
      (texts (List.filteri (fun i _ -> i >= index_of ~needle:"artifact:shots/home.png" rows) rows))
  in
  let cause =
    Picture.Withheld
      (Decode.Withheld_over_delivery_ceiling { bytes = 512000; ceiling = 200000 })
  in
  Alcotest.(check bool) "the rows state the cause, numbers included" true
    (contains ~needle:(Picture.cause_text cause) item)

let test_a_binary_artifact_that_is_not_an_image_is_one_plain_row () =
  let rows, pictures = section (evidence [ binary ~reference:"artifact:r.pdf" Picture.Binary_only ]) in
  Alcotest.(check int) "no picture" 0 (List.length pictures);
  let line = snd (List.nth rows (index_of ~needle:"artifact:r.pdf" rows)) in
  Alcotest.(check bool) "and states no cause, because there is none" false
    (contains ~needle:(Picture.cause_text (Picture.Withheld Decode.Withheld_not_image_format)) line)

let test_a_picture_taller_than_the_pane_leaves_a_caption () =
  let rows, pictures = section ~content_height:View.min_pixel_rows (fixture ()) in
  Alcotest.(check int) "no room, no area" 0 (List.length pictures);
  ignore (index_of ~needle:"artifact:shots/home.png" rows)

let test_pictures_have_ordered_non_overlapping_areas () =
  let rows, pictures =
    section ~content_height:60
      (evidence
         [ binary ~reference:"artifact:one.png" (prepared_png ~width:800 ~height:600 ())
         ; note "between"
         ; binary ~reference:"artifact:two.png"
             (prepared_png ~slot:Masc_tui_graphics.Evidence_image_2 ~width:600 ~height:800 ())
         ])
  in
  match pictures with
  | [ (first, _); (second, _) ] ->
      Alcotest.(check bool) "the second area starts after the first ends" true
        (second.first >= first.first + first.box.rows);
      Alcotest.(check int) "and under its own caption"
        (index_of ~needle:"artifact:two.png" rows + 1) second.first
  | _ -> Alcotest.fail "two images, two pictures"

let test_evidence_for_another_task_is_not_drawn () =
  let rows, pictures = section ~task_id:"task-2" (fixture ()) in
  Alcotest.(check int) "no picture" 0 (List.length pictures);
  Alcotest.(check bool) "the image is not on the rows" false
    (List.exists (fun text -> contains ~needle:"home.png" text) (texts rows))

let test_a_failed_read_has_rows_and_no_picture () =
  List.iter
    (fun failure ->
      let rows, pictures = section (Some ("task-1", Error failure)) in
      Alcotest.(check int) "no picture" 0 (List.length pictures);
      Alcotest.(check bool) "but the cause is on a row" true
        (List.exists (fun text -> contains ~needle:"boom" text) (texts rows)))
    [ Failure.Transport "boom"; Failure.Http_error "boom"; Failure.Invalid_json "boom"
    ; Failure.Invalid_payload "boom"; Failure.Launch_failure "boom" ]

let test_links_follow_the_item_that_carries_them () =
  let rows, _ =
    section
      (evidence [ note "design at https://docs.example/d"; note "no link here" ])
  in
  let note_row = index_of ~needle:"design at" rows in
  let link_row = index_of ~needle:"https://docs.example/d" (List.filteri (fun i _ -> i > note_row) rows) in
  Alcotest.(check int) "the link is on the row after its note" 0 link_row;
  let second = index_of ~needle:"no link here" rows in
  Alcotest.(check bool) "and the next note follows the link" true (second > note_row + 1)

let () =
  Alcotest.run "Tui render evidence"
    [ ( "row model"
      , [ Alcotest.test_case "a picture's area follows its caption" `Quick
            test_a_pictures_area_follows_its_caption_and_precedes_the_next_item
        ; Alcotest.test_case "the index follows wrapping of earlier rows" `Quick
            test_the_index_follows_wrapping_of_earlier_rows
        ; Alcotest.test_case "a terminal without pixels gets the caption alone" `Quick
            test_a_terminal_without_pixels_gets_the_caption_alone
        ; Alcotest.test_case "an image not shown says so and reserves nothing" `Quick
            test_an_image_that_is_not_shown_says_so_and_reserves_nothing
        ; Alcotest.test_case "a non-image binary artifact is one plain row" `Quick
            test_a_binary_artifact_that_is_not_an_image_is_one_plain_row
        ; Alcotest.test_case "a pane too short for a picture leaves a caption" `Quick
            test_a_picture_taller_than_the_pane_leaves_a_caption
        ; Alcotest.test_case "areas are ordered and do not overlap" `Quick
            test_pictures_have_ordered_non_overlapping_areas
        ; Alcotest.test_case "evidence for another task is not drawn" `Quick
            test_evidence_for_another_task_is_not_drawn
        ; Alcotest.test_case "a failed read has rows and no picture" `Quick
            test_a_failed_read_has_rows_and_no_picture
        ; Alcotest.test_case "links follow the item that carries them" `Quick
            test_links_follow_the_item_that_carries_them
        ] )
    ]
