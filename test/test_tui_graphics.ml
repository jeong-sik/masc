(** The bytes that carry an image to a terminal.

    Every function here is checked against what the protocol says rather than
    against what this implementation happens to emit: a golden string of its
    own output would pass whatever it did. *)

open Alcotest

let apc = "\x1b_G"
let st = "\x1b\\"
let query_id = Masc_tui_graphics.image_id Masc_tui_graphics.Graphics_query

(* Split a run of APC escapes into their bodies. Nothing outside an escape is
   allowed to reach the terminal, so anything between them is a failure the
   caller wants to see. *)
let bodies text =
  let rec loop offset acc =
    match String.index_from_opt text offset '\x1b' with
    | None ->
        if offset < String.length text then
          failf "bytes outside an escape: %S"
            (String.sub text offset (String.length text - offset));
        List.rev acc
    | Some start ->
        if start <> offset then
          failf "bytes before an escape: %S"
            (String.sub text offset (start - offset));
        let after = start + String.length apc in
        if
          String.length text < after
          || not (String.equal (String.sub text start (String.length apc)) apc)
        then failf "escape does not open with APC G: %S" text;
        let rec find_terminator index =
          if index + String.length st > String.length text then
            failf "escape never terminated: %S" text
          else if String.equal (String.sub text index (String.length st)) st
          then index
          else find_terminator (index + 1)
        in
        let stop = find_terminator after in
        loop (stop + String.length st)
          (String.sub text after (stop - after) :: acc)
  in
  loop 0 []
;;

let keys_and_payload body =
  match String.index_opt body ';' with
  | None -> failf "escape body has no payload separator: %S" body
  | Some cut ->
      ( String.split_on_char ',' (String.sub body 0 cut)
      , String.sub body (cut + 1) (String.length body - cut - 1) )
;;

let test_the_payload_is_the_file () =
  let data = String.init 9000 (fun index -> Char.chr (index mod 256)) in
  let escapes =
    Masc_tui_graphics.place ~data ~rows:20
  in
  let payload =
    bodies escapes |> List.map (fun body -> snd (keys_and_payload body))
    |> String.concat ""
  in
  match Base64.decode payload with
  | Ok decoded -> check string "arrives byte for byte" data decoded
  | Error (`Msg detail) -> failf "payload is not base64: %s" detail
;;

(* The protocol splits a payload across escapes, and terminals drop an escape
   past a length of their own. Every chunk but the last says m=1 -- more is
   coming -- and the last says m=0, which is what lets the terminal draw. *)
let test_every_chunk_but_the_last_says_more () =
  let data = String.make 20_000 'z' in
  let bodies =
    Masc_tui_graphics.place ~data ~rows:2
    |> bodies
  in
  if List.length bodies < 2 then
    failf "20 kB was not split: %d escape(s)" (List.length bodies);
  List.iteri
    (fun index body ->
      let keys, _ = keys_and_payload body in
      let last = index = List.length bodies - 1 in
      let expected = if last then "m=0" else "m=1" in
      if not (List.exists (String.equal expected) keys) then
        failf "escape %d of %d does not say %s: %S" (index + 1)
          (List.length bodies) expected body)
    bodies
;;

(* Only the first escape carries the image's keys. A later chunk that repeated
   them would be read as a second image. *)
let test_only_the_first_escape_describes_the_image () =
  let data = String.make 12_000 'q' in
  match
    Masc_tui_graphics.place ~data ~rows:3
    |> bodies
  with
  | [] -> failf "no escapes"
  | first :: rest ->
      let keys, _ = keys_and_payload first in
      List.iter
        (fun expected ->
          if not (List.exists (String.equal expected) keys) then
            failf "the first escape does not say %s: %S" expected first)
        (* q=2 keeps the terminal from answering a placement. Its reply
           would arrive on stdin and be typed into the composer. *)
        [ "f=100"; "a=T"; "r=3"; "q=2" ];
      List.iteri
        (fun index body ->
          let keys, _ = keys_and_payload body in
          List.iter
            (fun key ->
              if not (String.length key > 2 && String.sub key 0 2 = "m=") then
                failf "continuation %d carries %S, not m= alone" (index + 2) key)
            keys)
        rest
;;

(* [f=100] and [payload_media_type] are one fact said twice: the escape says
   it to the terminal and the name says it to a caller holding bytes. A caller
   that checked the name while the escape said something else would admit a
   format the terminal then drops in silence, since [q=2] means it never
   answers. Pinned rather than derived -- which number means PNG is the
   protocol's to say, not ours. *)
let test_the_named_format_is_the_one_the_escape_asks_for () =
  check string "the name says PNG" "image/png"
    Masc_tui_graphics.payload_media_type;
  match
    Masc_tui_graphics.place ~data:"bytes"
      ~rows:2
    |> bodies
  with
  | [] -> failf "no escapes"
  | first :: _ ->
      let keys, _ = keys_and_payload first in
      if not (List.exists (String.equal "f=100") keys) then
        failf "the escape does not ask for PNG: %S" first

let test_an_empty_image_places_nothing () =
  check string "no escape at all" ""
    (Masc_tui_graphics.place ~data:"" ~rows:1)
;;

let test_the_query_asks_without_drawing () =
  match bodies Masc_tui_graphics.query with
  | [ body ] ->
      let keys, _ = keys_and_payload body in
      List.iter
        (fun expected ->
          if not (List.exists (String.equal expected) keys) then
            failf "the query does not say %s: %S" expected body)
        [ Printf.sprintf "i=%d" query_id; "a=q" ]
  | escapes -> failf "the query is %d escapes, not one" (List.length escapes)
;;

let test_a_reply_is_read_for_what_it_answers () =
  let reply status =
    Masc_tui_graphics.parse_query_reply
      (Printf.sprintf "i=%d;%s" query_id status)
  in
  check bool "OK is support" true (reply "OK" = Some Masc_tui_graphics.Supported);
  check bool "anything else is a refusal, with its reason" true
    (reply "ENOTSUPPORTED:whatever"
     = Some (Masc_tui_graphics.Refused "ENOTSUPPORTED:whatever"));
  (* A reply about a different image is not an answer to this question. A
     terminal drawing pictures answers about those too. *)
  check bool "another image's reply is not this answer" true
    (Masc_tui_graphics.parse_query_reply
       (Printf.sprintf "i=%d;OK" (Masc_tui_graphics.image_id Masc_tui_graphics.Mascot))
     = None);
  check bool "a body that is not a reply at all" true
    (Masc_tui_graphics.parse_query_reply "nonsense" = None);
  (* i=310 must not be read as i=31. Matching on a prefix would. *)
  check bool "a longer id is a different id" true
    (Masc_tui_graphics.parse_query_reply
       (Printf.sprintf "i=%d0;OK" query_id)
     = None)
;;

(* Placing a picture under another's id replaces that one, and deleting it
   takes that one down: every picture keeps an id of its own. *)
let test_every_picture_has_its_own_id () =
  let ids = List.map Masc_tui_graphics.image_id Masc_tui_graphics.all_of_image in
  check int "no two pictures share an image id" (List.length ids)
    (List.length (List.sort_uniq Int.compare ids))
;;

(* tmux stops forwarding at the first ESC it sees inside a passthrough, so
   every ESC in the payload has to be doubled. Undoubling has to give back
   exactly what went in. *)
let test_tmux_passthrough_doubles_every_escape () =
  let payload = Masc_tui_graphics.query in
  let wrapped = Masc_tui_graphics.tmux_wrapped payload in
  let prefix = "\x1bPtmux;" in
  if not (String.starts_with ~prefix wrapped) then
    failf "not a tmux passthrough: %S" wrapped;
  if not (String.ends_with ~suffix:"\x1b\\" wrapped) then
    failf "passthrough not terminated: %S" wrapped;
  let inner =
    String.sub wrapped (String.length prefix)
      (String.length wrapped - String.length prefix - 2)
  in
  (* Every ESC in the payload became two, so splitting the wrapped bytes on
     ESC leaves an empty part between each pair. Dropping those and rejoining
     with one ESC is the inverse. *)
  let undoubled =
    String.concat "\x1b"
      (String.split_on_char '\x1b' inner
       |> List.filteri (fun index _ -> index mod 2 = 0))
  in
  check string "survives the round trip" payload undoubled
;;

let test_iterm2_places_inline_image () =
  let data = "test_image_bytes" in
  let escape =
    Masc_tui_graphics.iterm2_place ~data
      { Masc_tui_graphics.columns = 30; rows = 15 }
  in
  check bool "starts with iTerm2 OSC 1337 introducer" true
    (String.starts_with ~prefix:"\x1b]1337;File=inline=1;width=30;height=15;preserveAspectRatio=1:" escape);
  check bool "ends with BEL terminator" true
    (String.ends_with ~suffix:"\x07" escape);
  let empty =
    Masc_tui_graphics.iterm2_place ~data:""
      { Masc_tui_graphics.columns = 10; rows = 10 }
  in
  check string "empty data produces empty escape" "" empty
;;

(* A caller holding a frame sends pixels, not a file. The format carries no
   header, so the escape has to state the dimensions the terminal would
   otherwise read from one. Checked as keys rather than as a substring: the
   protocol is what these have to match. *)
let test_raw_rgb_states_its_pixel_dimensions () =
  let w = 4 and h = 2 in
  let data = String.init (w * h * 3) (fun index -> Char.chr (index mod 256)) in
  let keys =
    match
      Masc_tui_graphics.place_rgb ~data ~pixel_width:w ~pixel_height:h ~rows:5
      |> bodies
    with
    | first :: _ -> fst (keys_and_payload first)
    | [] -> failf "raw RGB placement produced no escape"
  in
  let says key = List.exists (String.equal key) keys in
  check bool "the payload is raw RGB" true (says "f=24");
  check bool "and says how wide it is" true (says "s=4");
  check bool "and how tall" true (says "v=2");
  check bool "the row count is the caller's" true (says "r=5");
  (* No c=. Kitty derives the width from the row count only when one of the
     two is absent; with both it scales into that exact rectangle, which is
     how a 4:3 frame arrived stretched across a wider terminal. *)
  check bool "and the width is left to the terminal" false (says "c=10");
  check bool "the terminal is asked not to answer" true (says "q=2");
  (* A file's key would have the terminal read three-byte pixels as a header,
     decode nothing, and say nothing about it. *)
  check bool "and it is not announced as a file" false (says "f=100")
;;

(* Dimensions the payload cannot support would be drawn as whatever the
   terminal makes of the mismatch. Refusing gives the caller something to
   test; drawing gives it a wrong picture and no way to know. *)
let test_raw_rgb_refuses_a_frame_that_contradicts_itself () =
  check string "three bytes are not a 4x2 frame" ""
    (Masc_tui_graphics.place_rgb ~data:"xyz" ~pixel_width:4 ~pixel_height:2 ~rows:5);
  check string "and neither is nothing" ""
    (Masc_tui_graphics.place_rgb ~data:"" ~pixel_width:4 ~pixel_height:2 ~rows:5)
;;

(* Inflate the PNG IDAT, independently of the encoder. *)
let inflate data =
  let input = De.bigstring_create De.io_buffer_size in
  let output = De.bigstring_create De.io_buffer_size in
  let decoded = Buffer.create (String.length data * 4) in
  let consumed = ref 0 in
  let refill buffer =
    let len = min (Bigstringaf.length buffer) (String.length data - !consumed) in
    Bigstringaf.blit_from_string data ~src_off:!consumed buffer ~dst_off:0 ~len;
    consumed := !consumed + len;
    len
  in
  let flush buffer len = Buffer.add_string decoded (Bigstringaf.substring buffer ~off:0 ~len) in
  match
    Zl.Higher.uncompress ~allocate:(fun bits -> De.make_window ~bits) ~refill ~flush input output
  with
  | Ok () -> Buffer.contents decoded
  | Error (`Msg message) -> failf "the payload is not zlib: %s" message
;;

(* Straight-alpha pixels under a stable identity: the portrait's transparent
   surround is blended by the terminal, and a second transfer under the same
   ids replaces the first rather than stacking. *)
let test_rgba_png_replaces_under_its_identity () =
  let w = 160 and h = 160 in
  let data = String.init (w * h * 4) (fun index -> Char.chr (index mod 256)) in
  let keys, payload =
    match
      Masc_tui_graphics.replace_rgba ~image_id:41 ~placement_id:1 ~data
        ~pixel_width:w ~pixel_height:h ~rows:4
      |> bodies
    with
    | first :: rest ->
        let keys, first_payload = keys_and_payload first in
        (keys, String.concat "" (first_payload :: List.map (fun body -> snd (keys_and_payload body)) rest))
    | [] -> failf "RGBA PNG placement produced no escape"
  in
  let says key = List.exists (String.equal key) keys in
  check bool "no Kitty transport inflater" false (says "o=z");
  check bool "the payload is PNG" true (says "f=100");
  let png = Base64.decode_exn payload in
  check string "PNG signature" "\137PNG\r\n\026\n" (String.sub png 0 8);
  check int "PNG width" w (Int32.to_int (String.get_int32_be png 16));
  check int "PNG height" h (Int32.to_int (String.get_int32_be png 20));
  check int "8-bit channels" 8 (Char.code png.[24]);
  check int "straight alpha RGBA" 6 (Char.code png.[25]);
  let rec idat offset acc =
    let length = Int32.to_int (String.get_int32_be png offset) in
    match String.sub png (offset + 4) 4 with
    | "IEND" -> String.concat "" (List.rev acc)
    | "IDAT" -> idat (offset + length + 12) (String.sub png (offset + 8) length :: acc)
    | _ -> idat (offset + length + 12) acc
  in
  let scanlines = inflate (idat 8 []) in
  check int "one filter byte per row" ((w * 4 + 1) * h) (String.length scanlines);
  for row = 0 to h - 1 do
    let offset = row * (w * 4 + 1) in
    check char "unfiltered row" '\000' scanlines.[offset];
    check string "RGBA arrives losslessly" (String.sub data (row * w * 4) (w * 4))
      (String.sub scanlines (offset + 1) (w * 4))
  done;
  check bool "under the caller's image id" true (says "i=41");
  check bool "and placement id" true (says "p=1");
  check bool "the cursor stays where it was" true (says "C=1");
  check string "three-byte pixels are not an RGBA frame" ""
    (Masc_tui_graphics.replace_rgba ~image_id:41 ~placement_id:1
       ~data:(String.make (w * h * 3) 'x') ~pixel_width:w ~pixel_height:h ~rows:4)
;;

(* A put names pixels the terminal already holds under the id: nothing to
   decode travels, and the same image and placement ids replace that
   placement rather than add a second one. *)
let test_a_put_places_held_pixels_without_sending_them () =
  match bodies (Masc_tui_graphics.put ~image_id:41 ~placement_id:1 ~rows:4) with
  | [ body ] ->
      check bool "no payload" false (String.contains body ';');
      let keys = String.split_on_char ',' body in
      let says key = List.exists (String.equal key) keys in
      check bool "puts" true (says "a=p");
      check bool "under the caller's image id" true (says "i=41");
      check bool "and placement id" true (says "p=1");
      check bool "the cursor stays where it was" true (says "C=1");
      check bool "as many rows as asked" true (says "r=4");
      check bool "and the terminal does not answer" true (says "q=2");
      check bool "no format: there are no pixels to decode" false
        (List.exists (String.starts_with ~prefix:"f=") keys)
  | escapes -> failf "a put is one escape, got %d" (List.length escapes)
;;

let test_image_pointer_geometry () =
  let region : Masc_tui_graphics.image_region =
    {top=4;left=1;width_cells=80.;height_cells=20.} in
  let point = Masc_tui_graphics.image_point region in
  check (option (pair (float 0.000001) (float 0.000001))) "cell center maps to image fraction"
    (Some (0.00625,0.025)) (point ~row:4 ~column:1);
  List.iter (fun (row,column) ->
    check bool "captions and unused margins never target page" true
      (point ~row ~column = None)) [(3,1);(24,1);(4,81);(4,0)]

(* An evidence picture arrives as a PNG file. It travels as it is, under the
   image id of its own slot, so replacing one slot's picture never touches
   another's. *)
let test_a_png_file_replaces_under_its_slots_identity () =
  let slot = Masc_tui_graphics.Evidence_image_2 in
  let id = Masc_tui_graphics.image_id slot in
  let data = String.init 9000 (fun index -> Char.chr ((index * 7) mod 256)) in
  let escapes =
    Masc_tui_graphics.replace_png ~image_id:id ~placement_id:1 ~data ~rows:9 ~cols:30
      ~crop:None
  in
  let all = bodies escapes in
  check bool "chunked like every other placement" true (List.length all > 1);
  let keys, _ = keys_and_payload (List.hd all) in
  let says key = List.exists (String.equal key) keys in
  check bool "a PNG file" true (says "f=100");
  check bool "transmitted and displayed" true (says "a=T");
  check bool "under the slot's image id" true (says (Printf.sprintf "i=%d" id));
  check bool "and one placement" true (says "p=1");
  check bool "as many rows as asked" true (says "r=9");
  check bool "and as many columns" true (says "c=30");
  check bool "the whole picture, no source rectangle" false
    (List.exists (fun key -> String.starts_with ~prefix:"y=" key || String.starts_with ~prefix:"h=" key) keys);
  check bool "the terminal is asked not to answer" true (says "q=2");
  check string "the file's bytes arrive whole" data
    (all
     |> List.map (fun body -> snd (keys_and_payload body))
     |> String.concat ""
     |> Base64.decode_exn);
  check string "no bytes, no escape" ""
    (Masc_tui_graphics.replace_png ~image_id:id ~placement_id:1 ~data:"" ~rows:9 ~cols:30
       ~crop:None)
;;

(* A picture the window cuts is drawn from a source rectangle, over the cells
   its shown rows cover. Both c and r travel, because the terminal derives the
   one that is missing from the whole picture's shape. *)
let test_a_cropped_png_names_its_source_rows_and_its_cells () =
  let crop = Some { Masc_tui_graphics.top_px = 160; height_px = 240 } in
  let keys_of body = fst (keys_and_payload body) in
  let says keys key = List.exists (String.equal key) keys in
  let placed =
    Masc_tui_graphics.replace_png ~image_id:51 ~placement_id:1 ~data:"png" ~rows:6 ~cols:30 ~crop
  in
  (match bodies placed with
   | body :: _ ->
       let keys = keys_of body in
       check bool "from this row of the source" true (says keys "y=160");
       check bool "this many source rows" true (says keys "h=240");
       check bool "over these rows" true (says keys "r=6");
       check bool "and these columns" true (says keys "c=30");
       check bool "across the picture's whole width" false
         (List.exists (String.starts_with ~prefix:"w=") keys)
   | [] -> fail "a placement is at least one escape");
  match bodies (Masc_tui_graphics.put_png ~image_id:51 ~placement_id:1 ~rows:6 ~cols:30 ~crop) with
  | [ body ] ->
      let keys = String.split_on_char ',' body in
      check bool "a put" true (says keys "a=p");
      check bool "of the same rectangle" true (says keys "y=160" && says keys "h=240");
      check bool "over the same cells" true (says keys "r=6" && says keys "c=30");
      check bool "with no payload" false (String.contains body ';')
  | escapes -> failf "a put is one escape, got %d" (List.length escapes)
;;

let test_a_source_rectangle_is_never_empty () =
  let crop = Some { Masc_tui_graphics.top_px = -3; height_px = 0 } in
  match bodies (Masc_tui_graphics.put_png ~image_id:51 ~placement_id:1 ~rows:0 ~cols:0 ~crop) with
  | [ body ] ->
      let keys = String.split_on_char ',' body in
      let says key = List.exists (String.equal key) keys in
      check bool "starts at the top at the least" true (says "y=0");
      check bool "one source row at the least" true (says "h=1");
      check bool "one row at the least" true (says "r=1");
      check bool "one column at the least" true (says "c=1")
  | escapes -> failf "a put is one escape, got %d" (List.length escapes)
;;

(* Lowercase d=i takes the placement and leaves the pixels, which is what lets
   a picture scrolled out of view come back as a put. *)
let test_a_placement_can_go_without_the_pixels () =
  match bodies (Masc_tui_graphics.delete_placement ~image_id:51 ~placement_id:1) with
  | [ body ] ->
      let keys = String.split_on_char ',' body in
      let says key = List.exists (String.equal key) keys in
      check bool "a delete" true (says "a=d");
      check bool "by image id, lowercase: pixels stay" true (says "d=i");
      check bool "of this image" true (says "i=51");
      check bool "and only this placement" true (says "p=1");
      check bool "uppercase would free the pixels" false (says "d=I")
  | escapes -> failf "a delete is one escape, got %d" (List.length escapes)
;;

let test_the_evidence_slots_are_four_distinct_ids () =
  let ids = List.map Masc_tui_graphics.image_id Masc_tui_graphics.evidence_images in
  check int "four slots" 4 (List.length ids);
  check int "each its own id" 4 (List.length (List.sort_uniq Int.compare ids));
  List.iter
    (fun id ->
      check bool "and not one a candle or the probe uses" false
        (List.exists
           (fun other -> other = id)
           (List.filter_map
              (fun image ->
                if List.mem image Masc_tui_graphics.evidence_images then None
                else Some (Masc_tui_graphics.image_id image))
              Masc_tui_graphics.all_of_image)))
    ids
;;

let test_inspection_crop_and_reuse () =
  let view : Masc_tui_image_viewport.window =
    {x=120;y=40;width=320;height=160;columns=40;rows=10} in
  let data = "retained PNG bytes" in
  let sent = Masc_tui_graphics.place_viewport ~data view |> bodies in
  let keys,payload = keys_and_payload (List.hd sent) in
  List.iter (fun key -> check bool ("protocol source crop " ^ key) true (List.mem key keys))
    ["x=120";"y=40";"w=320";"h=160";"c=40";"r=10";"a=T";"q=2"];
  check string "original retained bytes" data (Base64.decode_exn payload);
  let reused = Masc_tui_graphics.put_viewport {view with x=128} in
  check bool "pan uses stored pixels" true (String.contains reused '=');
  check bool "pan carries no image payload" false (String.contains reused ';');
  check bool "pan requests a placement" true
    (List.exists (fun body -> String.starts_with ~prefix:"a=p," body) (bodies reused))

let () =
  run
    "tui_graphics"
    [ ( "place"
      , [ test_case "inspection names source crop and reuses retained pixels" `Quick test_inspection_crop_and_reuse
        ; test_case "screenshot pointer excludes text and padding" `Quick test_image_pointer_geometry
        ; test_case "the payload is the file" `Quick
            test_the_payload_is_the_file
        ; test_case "every chunk but the last says more" `Quick
            test_every_chunk_but_the_last_says_more
        ; test_case "only the first escape describes the image" `Quick
            test_only_the_first_escape_describes_the_image
        ; test_case "the named format is the one the escape asks for" `Quick
            test_the_named_format_is_the_one_the_escape_asks_for
        ; test_case "an empty image places nothing" `Quick
            test_an_empty_image_places_nothing
        ; test_case "iterm2 places inline image" `Quick
            test_iterm2_places_inline_image
        ] )
    ; ( "capability"
      , [ test_case "the query asks without drawing" `Quick
            test_the_query_asks_without_drawing
        ; test_case "a reply is read for what it answers" `Quick
            test_a_reply_is_read_for_what_it_answers
        ; test_case "every picture has its own id" `Quick
            test_every_picture_has_its_own_id
        ] )
    ; ( "raw pixels"
      , [ test_case "raw RGB states its pixel dimensions" `Quick
            test_raw_rgb_states_its_pixel_dimensions
        ; test_case "a frame that contradicts itself is refused" `Quick
            test_raw_rgb_refuses_a_frame_that_contradicts_itself
        ; test_case "raw RGBA replaces under its identity" `Quick
            test_rgba_png_replaces_under_its_identity
        ; test_case "a put places held pixels without sending them" `Quick
            test_a_put_places_held_pixels_without_sending_them
        ; test_case "a PNG file replaces under its slot's identity" `Quick
            test_a_png_file_replaces_under_its_slots_identity
        ; test_case "a cropped PNG names its source rows and its cells" `Quick
            test_a_cropped_png_names_its_source_rows_and_its_cells
        ; test_case "a source rectangle is never empty" `Quick
            test_a_source_rectangle_is_never_empty
        ; test_case "a placement can go without the pixels" `Quick
            test_a_placement_can_go_without_the_pixels
        ; test_case "the evidence slots are four distinct ids" `Quick
            test_the_evidence_slots_are_four_distinct_ids
        ] )
    ; ( "tmux"
      , [ test_case "passthrough doubles every escape" `Quick
            test_tmux_passthrough_doubles_every_escape
        ] )
    ]
;;
