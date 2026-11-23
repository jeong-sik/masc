open Alcotest
module Graphics = Masc_tui_term.Graphics
module Probe = Masc_tui_term.Probe

let apc = "\x1b_G"
let st = "\x1b\\"
let query_id = Graphics.image_id Graphics.Graphics_query

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
          else if String.equal (String.sub text index (String.length st)) st then
            index
          else find_terminator (index + 1)
        in
        let stop = find_terminator after in
        loop
          (stop + String.length st)
          (String.sub text after (stop - after) :: acc)
  in
  loop 0 []

let keys_and_payload body =
  match String.index_opt body ';' with
  | None -> failf "escape body has no payload separator: %S" body
  | Some cut ->
      ( String.split_on_char ',' (String.sub body 0 cut),
        String.sub body (cut + 1) (String.length body - cut - 1) )

let test_chunked_payload_roundtrip () =
  let data = String.init 9000 (fun index -> Char.chr (index mod 256)) in
  let escapes = Graphics.place ~data ~rows:20 in
  let all = bodies escapes in
  check bool "9kB splits across multiple chunks" true (List.length all >= 3);
  List.iteri
    (fun index body ->
      let keys, _ = keys_and_payload body in
      let last = index = List.length all - 1 in
      let expected = if last then "m=0" else "m=1" in
      check bool (Printf.sprintf "chunk %d has %s" index expected) true
        (List.exists (String.equal expected) keys);
      if index = 0 then
        List.iter
          (fun req ->
            check bool ("first chunk has " ^ req) true
              (List.exists (String.equal req) keys))
          [ "f=100"; "a=T"; "r=20"; "q=2" ]
      else
        List.iter
          (fun key ->
            check bool "continuation carries only m=" true
              (String.starts_with ~prefix:"m=" key))
          keys)
    all;
  let payload =
    all |> List.map (fun b -> snd (keys_and_payload b)) |> String.concat ""
  in
  match Base64.decode payload with
  | Ok decoded -> check string "arrives byte for byte" data decoded
  | Error (`Msg detail) -> failf "payload is not base64: %s" detail

let test_empty_and_media_type () =
  check string "payload media type" "image/png" Graphics.payload_media_type;
  check string "empty place returns empty string" ""
    (Graphics.place ~data:"" ~rows:1);
  check string "empty replace_png returns empty string" ""
    (Graphics.replace_png ~image_id:56 ~placement_id:1 ~data:"" ~rows:4 ~cols:10
       ~crop:None)

let test_fit_rows () =
  (* 10x20 cell pixels, 1000x500 image (2:1 wide), 40 cols x 30 rows:
     40 cols * 10px = 400px wide -> 200px tall -> 200/20 = 10 rows *)
  check int "wide image clamped by width" 10
    (Graphics.fit_rows ~cell_pixels:(Some (10, 20))
       ~image_pixels:(Some (1000, 500)) ~columns:40 ~rows:30);
  (* Tall image clamped by requested rows *)
  check int "tall image clamped by rows" 12
    (Graphics.fit_rows ~cell_pixels:(Some (10, 20))
       ~image_pixels:(Some (400, 2000)) ~columns:40 ~rows:12);
  (* Missing geometry retains requested rows (at least 1) *)
  check int "missing cell_pixels retains rows" 15
    (Graphics.fit_rows ~cell_pixels:None ~image_pixels:(Some (800, 600))
       ~columns:40 ~rows:15);
  check int "non-positive rows clamped to 1" 1
    (Graphics.fit_rows ~cell_pixels:None ~image_pixels:None ~columns:0 ~rows:0)

let test_image_ids_and_query () =
  let ids = List.map Graphics.image_id Graphics.all_of_image in
  check int "every slot has a unique image_id" (List.length ids)
    (List.length (List.sort_uniq Int.compare ids));
  check bool "Memory_diagram has dedicated slot id" true
    (Graphics.image_id Graphics.Memory_diagram > 0
    && Graphics.image_id Graphics.Memory_diagram <> query_id);
  check int "four evidence slots" 4 (List.length Graphics.evidence_images);
  check bool "resource_image_id disjoint from fixed slots" true
    (List.for_all (fun id -> id <> Graphics.resource_image_id 0) ids);
  (match bodies Graphics.query with
   | [ body ] ->
       let keys, _ = keys_and_payload body in
       check bool "query carries query_id" true
         (List.mem (Printf.sprintf "i=%d" query_id) keys);
       check bool "query carries a=q" true (List.mem "a=q" keys);
       check bool "query carries f=100" true (List.mem "f=100" keys)
   | escapes -> failf "expected single query escape, got %d" (List.length escapes));
  check bool "OK reply" true
    (Option.equal Graphics.equal_query_reply
       (Graphics.parse_query_reply (Printf.sprintf "i=%d;OK" query_id))
       (Some Graphics.Supported));
  check bool "refused reply" true
    (Option.equal Graphics.equal_query_reply
       (Graphics.parse_query_reply (Printf.sprintf "i=%d;ENOTSUP" query_id))
       (Some (Graphics.Refused "ENOTSUP")));
  check bool "other image id ignored" true
    (Option.is_none
       (Graphics.parse_query_reply
          (Printf.sprintf "i=%d;OK" (Graphics.image_id Graphics.Memory_diagram))));
  check bool "longer prefix id ignored" true
    (Option.is_none
       (Graphics.parse_query_reply (Printf.sprintf "i=%d0;OK" query_id)))

let test_raw_rgb_rgba_png_and_viewport () =
  let w = 4 and h = 2 in
  let rgb = String.init (w * h * 3) (fun i -> Char.chr (i mod 256)) in
  let keys =
    match
      Graphics.replace_rgb ~image_id:32 ~placement_id:1 ~data:rgb
        ~pixel_width:w ~pixel_height:h ~rows:5
      |> bodies
    with
    | first :: _ -> fst (keys_and_payload first)
    | [] -> fail "expected RGB escape"
  in
  List.iter
    (fun req -> check bool ("rgb has " ^ req) true (List.mem req keys))
    [ "f=24"; "s=4"; "v=2"; "i=32"; "p=1"; "C=1"; "r=5"; "q=2" ];
  check string "rgb rejects mismatched byte count" ""
    (Graphics.replace_rgb ~image_id:32 ~placement_id:1 ~data:"xyz"
       ~pixel_width:4 ~pixel_height:2 ~rows:5);
  check string "rgb rejects overflowing dimensions without int overflow" ""
    (Graphics.replace_rgb ~image_id:32 ~placement_id:1 ~data:"xyz"
       ~pixel_width:(max_int / 2) ~pixel_height:4 ~rows:5);

  let rgba = String.init (w * h * 4) (fun i -> Char.chr (i mod 256)) in
  let rgba_bodies =
    Graphics.replace_rgba ~image_id:42 ~placement_id:1 ~data:rgba
      ~pixel_width:w ~pixel_height:h ~rows:4
    |> bodies
  in
  let rkeys, first_payload = keys_and_payload (List.hd rgba_bodies) in
  check bool "rgba uses PNG f=100" true (List.mem "f=100" rkeys);
  check bool "rgba avoids Kitty o=z" false (List.mem "o=z" rkeys);
  let png =
    String.concat ""
      (first_payload
      :: List.map (fun b -> snd (keys_and_payload b)) (List.tl rgba_bodies))
    |> Base64.decode_exn
  in
  check string "PNG signature" "\137PNG\r\n\026\n" (String.sub png 0 8);
  check int "PNG IHDR width" w (Int32.to_int (String.get_int32_be png 16));
  check int "PNG IHDR height" h (Int32.to_int (String.get_int32_be png 20));
  check int "PNG RGBA color type 6" 6 (Char.code png.[25]);

  let crop = Some { Graphics.top_px = 40; height_px = 120 } in
  let mem_id = Graphics.image_id Graphics.Memory_diagram in
  (match
     Graphics.put_png ~image_id:mem_id ~placement_id:1 ~rows:8 ~cols:40 ~crop
     |> bodies
   with
   | [ body ] ->
       check bool "put_png has no payload" false (String.contains body ';');
       let pkeys = String.split_on_char ',' body in
       List.iter
         (fun req -> check bool ("put_png has " ^ req) true (List.mem req pkeys))
         [ "a=p"; Printf.sprintf "i=%d" mem_id; "p=1"; "r=8"; "c=40"; "y=40"; "h=120"; "q=2" ]
   | _ -> fail "expected single put_png escape");

  let view : Graphics.viewport_window =
    { x = 120; y = 40; width = 320; height = 160; columns = 40; rows = 10 }
  in
  let vp_keys, vp_payload =
    Graphics.place_viewport ~image_id:mem_id ~data:"png-bytes" view
    |> bodies |> List.hd |> keys_and_payload
  in
  List.iter
    (fun req -> check bool ("viewport has " ^ req) true (List.mem req vp_keys))
    [ Printf.sprintf "i=%d" mem_id; "x=120"; "y=40"; "w=320"; "h=160"; "c=40"; "r=10"; "a=T"; "q=2" ];
  check string "viewport payload roundtrips" "png-bytes"
    (Base64.decode_exn vp_payload);
  let put_vp = Graphics.put_viewport ~image_id:mem_id view in
  check bool "put_viewport carries no payload" false (String.contains put_vp ';')

let test_deletes_iterm2_tmux_and_protocol () =
  (match bodies (Graphics.delete_placement ~image_id:56 ~placement_id:1) with
   | [ body ] ->
       let keys = String.split_on_char ',' body in
       List.iter
         (fun req -> check bool ("delete_placement " ^ req) true (List.mem req keys))
         [ "a=d"; "d=i"; "i=56"; "p=1"; "q=2" ];
       check bool "delete_placement does not free pixels" false (List.mem "d=I" keys)
   | _ -> fail "expected single delete_placement escape");
  (match bodies (Graphics.delete_image ~image_id:56) with
   | [ body ] ->
       let keys = String.split_on_char ',' body in
       List.iter
         (fun req -> check bool ("delete_image " ^ req) true (List.mem req keys))
         [ "a=d"; "d=I"; "i=56"; "q=2" ]
   | _ -> fail "expected single delete_image escape");
  check string "delete_all" "\x1b_Ga=d\x1b\\" Graphics.delete_all;

  let it2 =
    Graphics.iterm2_place ~data:"img" { Graphics.columns = 30; rows = 15 }
  in
  check bool "iTerm2 OSC 1337 prefix" true
    (String.starts_with
       ~prefix:"\x1b]1337;File=inline=1;width=30;height=15;preserveAspectRatio=1:"
       it2);
  check bool "iTerm2 BEL terminator" true (String.ends_with ~suffix:"\x07" it2);
  check string "iTerm2 empty returns empty" ""
    (Graphics.iterm2_place ~data:"" { Graphics.columns = 10; rows = 10 });

  let payload = Graphics.query in
  let wrapped = Graphics.tmux_wrapped payload in
  check bool "tmux DCS prefix" true (String.starts_with ~prefix:"\x1bPtmux;" wrapped);
  check bool "tmux ST suffix" true (String.ends_with ~suffix:"\x1b\\" wrapped);
  let inner = String.sub wrapped 7 (String.length wrapped - 9) in
  let undoubled =
    String.concat "\x1b"
      (String.split_on_char '\x1b' inner |> List.filteri (fun i _ -> i mod 2 = 0))
  in
  check string "tmux undoubling roundtrip" payload undoubled;
  check string "tmux_wrapped empty returns empty" "" (Graphics.tmux_wrapped "");
  check int "negative resource_image_id clamps to 0x10000" 0x10000
    (Graphics.resource_image_id (-5));

  check bool "Kitty supported -> Kitty_protocol" true
    (Graphics.equal_graphics_protocol Graphics.Kitty_protocol
       (Graphics.protocol_of_probe ~graphics:(Some Probe.Graphics_supported)
          ~term_program:None));
  check bool "Refused + iTerm.app -> ITerm2_protocol" true
    (Graphics.equal_graphics_protocol Graphics.ITerm2_protocol
       (Graphics.protocol_of_probe
          ~graphics:(Some (Probe.Graphics_refused "NO"))
          ~term_program:(Some "iTerm.app")));
  check bool "Unreported + other -> Unsupported_protocol" true
    (Graphics.equal_graphics_protocol Graphics.Unsupported_protocol
       (Graphics.protocol_of_probe ~graphics:None ~term_program:(Some "xterm")));

  let region : Graphics.image_region =
    { top = 4; left = 1; width_cells = 80.; height_cells = 20. }
  in
  check (option (pair (float 1e-6) (float 1e-6))) "cell center maps cleanly"
    (Some (0.00625, 0.025))
    (Graphics.image_point region ~row:4 ~column:1);
  check bool "outside region returns None" true
    (Option.is_none (Graphics.image_point region ~row:3 ~column:1));
  let neg_region : Graphics.image_region =
    { top = 4; left = 5; width_cells = -10.; height_cells = -10. }
  in
  check bool "non-positive region dimensions return None" true
    (Option.is_none (Graphics.image_point neg_region ~row:1 ~column:1))

let () =
  run "masc_tui_v2_graphics"
    [
      ( "kitty_and_iterm2",
        [
          test_case "chunked PNG roundtrip & m= flags" `Quick
            test_chunked_payload_roundtrip;
          test_case "empty payloads & media type" `Quick test_empty_and_media_type;
          test_case "aspect-preserving fit_rows" `Quick test_fit_rows;
          test_case "unique slot IDs including Memory_diagram & query reply" `Quick
            test_image_ids_and_query;
          test_case "raw RGB, RGBA PNG, cropped PNG, viewport" `Quick
            test_raw_rgb_rgba_png_and_viewport;
          test_case "delete sequences, iTerm2, tmux, protocol_of_probe, pointer" `Quick
            test_deletes_iterm2_tmux_and_protocol;
        ] );
    ]
