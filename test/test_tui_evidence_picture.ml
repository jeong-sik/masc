(* What the evidence section tells the reader about a binary artifact is
   decided by [reading], a typed answer. The caption tests assert the facts a
   line must carry (reference, size, a short digest) and that exactly the
   unreadable cases say so, not the wording around them. *)

module Decode = Masc.Tui_decode
module Picture = Masc_tui_evidence_picture

let png = Masc.Keeper_vision_downscale.Png

let reading_testable =
  let pp formatter = function
    | Picture.Image media ->
        Format.fprintf formatter "Image %s"
          (Masc.Keeper_vision_downscale.media_type_to_string media)
    | Picture.Not_an_image -> Format.pp_print_string formatter "Not_an_image"
    | Picture.Unreadable _ -> Format.pp_print_string formatter "Unreadable"
  in
  Alcotest.testable pp ( = )

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
      | Picture.Image _ | Picture.Not_an_image | Picture.Unreadable (Picture.Defective _) ->
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
      | Picture.Image _ | Picture.Not_an_image | Picture.Unreadable (Picture.Withheld _) ->
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

let caption preview =
  Picture.caption ~reference:"artifact:shots/home.png" ~bytes:41230 ~sha256 ~format:"png"
    preview

let test_every_caption_carries_the_identity () =
  List.iter
    (fun preview ->
      let line = caption preview in
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
       (caption (Decode.Preview_image { ev_media = png; ev_data = "" })));
  Alcotest.(check bool) "a PDF names its extension instead" true
    (contains ~needle:"pdf"
       (Picture.caption ~reference:"artifact:r.pdf" ~bytes:90 ~sha256 ~format:"pdf"
          (Decode.Preview_withheld Decode.Withheld_not_image_format)))

let test_only_unreadable_images_say_they_are_not_shown () =
  let says_not_shown preview = contains ~needle:"not shown" (caption preview) in
  Alcotest.(check bool) "a readable image does not" false
    (says_not_shown (Decode.Preview_image { ev_media = png; ev_data = "" }));
  Alcotest.(check bool) "a PDF does not" false
    (says_not_shown (Decode.Preview_withheld Decode.Withheld_not_image_format));
  List.iter
    (fun preview ->
      Alcotest.(check bool) "an unreadable image says so" true (says_not_shown preview))
    [ Decode.Preview_withheld Decode.Withheld_body_not_filed
    ; Decode.Preview_withheld (Decode.Withheld_over_delivery_ceiling { bytes = 9; ceiling = 3 })
    ; Decode.Preview_defective Decode.Defect_bad_base64
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
    (contains ~needle:"10" text && contains ~needle:"7" text)

let test_a_control_sequence_in_the_reference_never_reaches_the_line () =
  let line =
    Picture.caption ~reference:"artifact:a\x1b[2Jb.png" ~bytes:1 ~sha256 ~format:"png"
      (Decode.Preview_withheld Decode.Withheld_not_image_format)
  in
  Alcotest.(check bool) "no escape byte" false (String.contains line '\x1b')

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
        ; Alcotest.test_case "only unreadable images say not shown" `Quick
            test_only_unreadable_images_say_they_are_not_shown
        ; Alcotest.test_case "a cause carries its numbers" `Quick
            test_a_cause_carries_the_numbers_it_was_stated_with
        ; Alcotest.test_case "control sequences are removed" `Quick
            test_a_control_sequence_in_the_reference_never_reaches_the_line
        ] )
    ]
