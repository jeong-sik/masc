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
  ^ "crc!" ^ "image data" ^ "\x00\x00\x00\x00IEND\xaeB\x60\x82"

let sha256 = String.make 64 'a'

let kitty = View.Pixels { cell_width = 10; cell_height = 20 }

(* Drawable pictures come from [prepare] alone, in slot order. *)
let prepared_pngs sizes =
  let item index (width, height) =
    Decode.Ev_binary
      { ev_b_reference = Printf.sprintf "artifact:p%d.png" index
      ; ev_b_bytes = 10
      ; ev_b_sha256 = sha256
      ; ev_b_format = "png"
      ; ev_b_preview =
          Decode.Preview_image
            { ev_media = Masc.Keeper_vision_downscale.Png; ev_data = png_of ~width ~height }
      }
  in
  match
    Picture.prepare ~display:kitty
      ~convert:(fun _ -> Alcotest.fail "a PNG must not reach a converter")
      (Decode.Evidence_items (List.mapi item sizes))
  with
  | Picture.Items prepared ->
      List.map
        (function
          | Picture.Binary_item { picture; _ } -> picture
          | Picture.Text_item _ -> Alcotest.fail "a binary item came back as text")
        prepared
  | Picture.Access_unavailable _ -> Alcotest.fail "available evidence came back unavailable"

let prepared_png ~width ~height () = List.hd (prepared_pngs [ width, height ])

let binary ?(reference = "artifact:shots/home.png") picture =
  Picture.Binary_item { reference; bytes = 41230; sha256; format = "png"; picture }

let note text = Picture.Text_item (Decode.Ev_note text)

let unreadable =
  Picture.Text_item
    (Decode.Ev_artifact_unreadable
       { ev_u_reference = Some "artifact:gone.txt"; ev_u_reason = "missing" })

let evidence items = Some ("task-1", Ok (Picture.Items items))

let section ?(width = 80) ?(content_height = 40) ?(display = kitty) ?(task_id = "task-1")
    evidence =
  let observation = match evidence with
    | Some (id,Ok value) when String.equal id task_id -> Masc_tui_fetched.Ready value
    | Some (id,Error error) when String.equal id task_id -> Masc_tui_fetched.Failed error
    | Some _ | None -> Masc_tui_fetched.Absent in
  Section.section ~evidence:observation ~in_flight:false ~workspace_confirmed:true
    ~width ~content_height ~display

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
  let first_picture, second_picture =
    match prepared_pngs [ 800, 600; 600, 800 ] with
    | [ first; second ] -> first, second
    | _ -> Alcotest.fail "two images, two pictures"
  in
  let rows, pictures =
    section ~content_height:60
      (evidence
         [ binary ~reference:"artifact:one.png" first_picture
         ; note "between"
         ; binary ~reference:"artifact:two.png" second_picture
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

(* The terminal-bound text of every kind of row: a note, a submitted source, a
   text artifact, an unreadable artifact's reference and the link rows built
   from them. Escape, CSI, OSC, C1 and a bidi override must not reach a row
   as bytes. *)
let hostile = "x\x1b[2Jy\x1b]8;;http://evil.example\x07z\xc2\x9bw\xe2\x80\xaeabc"

let test_no_row_carries_a_control_or_bidi_byte_from_the_evidence () =
  let url_text = "see https://x.example/a" ^ hostile in
  let rows, _ =
    section ~width:60
      (evidence
         [ note (hostile ^ " " ^ url_text)
         ; Picture.Text_item
             (Decode.Ev_collaboration
                { ev_reference = "board:" ^ hostile; ev_content = url_text; ev_sha256 = "x" })
         ; Picture.Text_item
             (Decode.Ev_artifact
                { ev_reference = "artifact:" ^ hostile; ev_content = url_text; ev_bytes = 9
                ; ev_truncated = false })
         ; Picture.Text_item
             (Decode.Ev_artifact_unreadable
                { ev_u_reference = Some ("artifact:" ^ hostile); ev_u_reason = hostile })
         ; binary ~reference:("artifact:" ^ hostile) Picture.Binary_only
         ])
  in
  let forbidden =
    [ "escape", "\x1b"; "bell", "\x07"; "C1 control", "\xc2\x9b"; "bidi override", "\xe2\x80\xae" ]
  in
  List.iter
    (fun (row : string * string) ->
      List.iter
        (fun (name, bytes) ->
          Alcotest.(check bool) ("no " ^ name ^ " in a row") false (contains ~needle:bytes (snd row)))
        forbidden)
    (* The row style is an ANSI sequence of ours; only the text is the evidence's. *)
    rows;
  Alcotest.(check bool) "the readable part of the link survives" true
    (List.exists (fun text -> contains ~needle:"https://x.example/a" text) (texts rows))

(* {2 requests: where the pictures go on the frame} *)

let request_testable =
  let pp formatter = function
    | Section.Hold { image_id; _ } -> Format.fprintf formatter "Hold %d" image_id
    | Section.Show p ->
        Format.fprintf formatter "Show %d at %d,%d %d rows%s" p.View.png_image_id p.View.png_row
          p.View.png_column p.View.png_rows
          (if p.View.png_crop = None then "" else " cropped")
  in
  Alcotest.testable pp ( = )

let one_picture () =
  let rows, pictures = section ~content_height:30 (fixture ()) in
  match pictures with
  | [ (slot, pixels) ] -> rows, slot, pixels
  | _ -> Alcotest.fail "one image, one picture"

let requests ?(scroll = 0) ?(content_height = 30) ?(evidence_first = 10)
    ?(content_origin = (4, 2)) pictures =
  Section.requests ~pictures ~evidence_first ~scroll ~content_height ~content_origin

let image_id pixels = Masc_tui_graphics.image_id pixels.Picture.slot

let test_a_picture_lands_at_the_origin_plus_its_row_in_the_pane () =
  let _, slot, pixels = one_picture () in
  (* The pane has [evidence_first] rows ahead of the section, so the area's
     row among all rows is evidence_first + slot.first. *)
  let row_in_pane = 10 + slot.first in
  List.iter
    (fun (label, content_origin, (origin_row, origin_column)) ->
      match requests ~content_origin ~scroll:0 [ slot, pixels ] with
      | [ Section.Show p ] ->
          Alcotest.(check (pair int int)) label
            (origin_row + row_in_pane, origin_column + Picture.picture_indent_cols)
            (p.View.png_row, p.View.png_column);
          Alcotest.(check int) "its own terminal image" (image_id pixels) p.View.png_image_id
      | _ -> Alcotest.fail (label ^ ": the picture is in view"))
    [ "one pane", (4, 2), (4, 2); "two panes, the detail to the right", (4, 41), (4, 41) ];
  (* Scrolling moves the picture up by the rows scrolled. *)
  match requests ~content_origin:(4, 2) ~scroll:3 [ slot, pixels ] with
  | [ Section.Show p ] ->
      Alcotest.(check int) "three rows scrolled, three rows up" (4 + row_in_pane - 3)
        p.View.png_row
  | _ -> Alcotest.fail "the picture is still in view"

let test_a_picture_cut_by_the_window_is_cropped_and_one_outside_it_is_held () =
  let _, slot, pixels = one_picture () in
  let first = 10 + slot.first in
  let rows = slot.box.rows in
  (match requests ~scroll:(first + 2) [ slot, pixels ] with
   | [ Section.Show p ] ->
       Alcotest.(check int) "the rows still in view" (rows - 2) p.View.png_rows;
       Alcotest.(check bool) "cropped" true (p.View.png_crop <> None);
       Alcotest.(check int) "its top edge is the window's" 4 p.View.png_row
   | _ -> Alcotest.fail "a picture with rows in view is shown");
  (match requests ~scroll:(first + rows) [ slot, pixels ] with
   | [ Section.Hold { image_id = held; key } ] ->
       Alcotest.(check int) "held by its terminal image" (image_id pixels) held;
       Alcotest.(check string) "and by its bytes" pixels.key key
   | _ -> Alcotest.fail "a picture wholly above the window is held");
  match requests ~scroll:0 ~content_height:first [ slot, pixels ] with
  | [ Section.Hold _ ] -> ()
  | _ -> Alcotest.fail "a picture wholly below the window is held"

let test_every_scroll_offset_shows_or_holds_every_picture () =
  let _, slot, pixels = one_picture () in
  for scroll = 0 to 10 + slot.first + slot.box.rows + 2 do
    match requests ~scroll [ slot, pixels ] with
    | [ Section.Show _ ] | [ Section.Hold _ ] -> ()
    | other -> Alcotest.failf "scroll %d: %d requests for one picture" scroll (List.length other)
  done

let test_two_pictures_are_requested_under_their_own_images () =
  match prepared_pngs [ 800, 600; 600, 800 ] with
  | [ first; second ] ->
      let _, pictures =
        section ~content_height:60
          (evidence
             [ binary ~reference:"artifact:one.png" first; binary ~reference:"artifact:two.png" second ])
      in
      let ids =
        requests ~content_height:60 pictures
        |> List.map (function
             | Section.Show p -> p.View.png_image_id
             | Section.Hold { image_id; _ } -> image_id)
      in
      Alcotest.(check (list int)) "one request per picture, in order"
        (List.map Masc_tui_graphics.image_id
           [ Masc_tui_graphics.Evidence_image_1; Masc_tui_graphics.Evidence_image_2 ])
        ids
  | _ -> Alcotest.fail "two images, two pictures"

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
        ; Alcotest.test_case "no row carries a control or bidi byte from the evidence" `Quick
            test_no_row_carries_a_control_or_bidi_byte_from_the_evidence
        ] )
    ; ( "requests"
      , [ Alcotest.test_case "a picture lands at the origin plus its row" `Quick
            test_a_picture_lands_at_the_origin_plus_its_row_in_the_pane
        ; Alcotest.test_case "a cut picture is cropped, an outside one held" `Quick
            test_a_picture_cut_by_the_window_is_cropped_and_one_outside_it_is_held
        ; Alcotest.test_case "every scroll offset shows or holds every picture" `Quick
            test_every_scroll_offset_shows_or_holds_every_picture
        ; Alcotest.test_case "two pictures are requested under their own images" `Quick
            test_two_pictures_are_requested_under_their_own_images
        ] )
    ]
