(* Keeper_image_dimensions reads pixels out of headers. The fixtures below
   are the real header bytes of each format, sized by the builder rather
   than pasted, so a change in the expected size changes the bytes too. *)

module D = Masc.Keeper_image_dimensions

let be_byte offset value = Char.chr ((value lsr offset) land 0xff)

let be4 value = String.init 4 (fun i -> be_byte ((3 - i) * 8) value)

let be2 value = String.init 2 (fun i -> be_byte ((1 - i) * 8) value)

let le2 value = String.init 2 (fun i -> be_byte (i * 8) value)

let png_header width height =
  String.concat ""
    [ "\x89PNG\r\n\x1a\n"; "\x00\x00\x00\x0d"; "IHDR"; be4 width; be4 height
    ; "\x08\x06\x00\x00\x00" ]

let jpeg_header width height =
  (* SOI, one length-carrying APP segment, then SOF0. The walk has to hop the
     APP segment by its own length before it can read the frame size, and SOF
     spells height before width. *)
  String.concat ""
    [ "\xff\xd8"; "\xff\xe0"; "\x00\x04"; "AB"; "\xff\xc0"; "\x00\x08"; "\x08"
    ; be2 height; be2 width ]

let gif_header width height = "GIF89a" ^ le2 width ^ le2 height

let () =
  let run = Alcotest.(check (option (pair int int))) in
  run "png IHDR at its fixed offset" (Some (3456, 2168))
    (D.image_dimensions (png_header 3456 2168));
  run "a truncated png header answers None" None
    (D.image_dimensions "\x89PNG");
  run "jpeg first SOF after the APP segment" (Some (12345, 6789))
    (D.image_dimensions (jpeg_header 12345 6789));
  run "a broken jpeg marker stream answers None" None
    (D.image_dimensions ("\xff\xd8" ^ "\x00\x00"));
  run "gif logical screen, little-endian" (Some (800, 600))
    (D.image_dimensions (gif_header 800 600));
  (* Three container layouts spell the canvas three ways; a guess would print
     a confident wrong size, so WebP prints none. *)
  run "webp answers None" None
    (D.image_dimensions ("RIFF\x00\x00\x00\x00WEBPVP8 "))
;;
