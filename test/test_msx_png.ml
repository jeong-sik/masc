(* The encoder has to survive providers that decode strictly: a wrong CRC,
   a zlib stream a decoder rejects, or an IHDR that lies about the buffer
   all pass naive "bytes came out" checks. So the cases pin the checksums
   against published vectors and the container against the spec's fixed
   fields rather than trusting our own writer. *)

open Alcotest

(* The encoder lives inside the msx_lane library; reach it through the
   re-exported submodule rather than a private link. *)
module Msx_png = Msx_lane.Msx_png

let hex4 v = Printf.sprintf "%08lx" (Int32.of_int (v land 0xFFFFFFFF))

let be4 s off =
  (Char.code s.[off] lsl 24)
  lor (Char.code s.[off + 1] lsl 16)
  lor (Char.code s.[off + 2] lsl 8)
  lor Char.code s.[off + 3]

let chunk_at png off =
  let len = be4 png off in
  (String.sub png (off + 4) 4, len, off + 8 + len + 4)

(* Every chunk after the previous one's CRC; stops at IEND. *)
let chunks png =
  let rec go off acc =
    if off + 8 > String.length png then List.rev acc
    else
      let typ, len, next = chunk_at png off in
      go next ((typ, String.sub png (off + 8) len) :: acc)
  in
  go 8 []

let () =
  run "msx_png"
    [ ( "checksums"
      , [ test_case "crc32 matches the published vector" `Quick (fun () ->
            check string "crc32(123456789)" "cbf43926"
              (hex4 (Int32.to_int (Msx_png.crc32 "123456789"))))
        ; test_case "crc32 of the empty input is the init value" `Quick (fun () ->
            check string "crc32(empty)" "00000000"
              (hex4 (Int32.to_int (Msx_png.crc32 ""))))
        ; test_case "adler32 matches the published vector" `Quick (fun () ->
            check string "adler32(Wikipedia)" "11e60398"
              (hex4 (Int32.to_int (Msx_png.adler32 "Wikipedia"))))
        ; test_case "adler32 of the empty input is 1" `Quick (fun () ->
            check string "adler32(empty)" "00000001"
              (hex4 (Int32.to_int (Msx_png.adler32 "")))) ] )
    ; ( "container"
      , [ test_case "a frame encodes as an 8-bit truecolour PNG" `Quick (fun () ->
            let w = 4 and h = 2 in
            let rgb = String.make (w * h * 3) '\xA5' in
            let png = Msx_png.encode ~width:w ~height:h ~rgb in
            check bool "starts with the PNG signature" true
              (String.length png > 8
               && String.sub png 0 8 = "\x89PNG\r\n\x1a\n");
            let types = List.map fst (chunks png) in
            check (list string) "the chunk order is IHDR, IDAT, IEND"
              [ "IHDR"; "IDAT"; "IEND" ] types)
        ; test_case "IHDR carries the dimensions and colour type" `Quick (fun () ->
            let w = 512 and h = 212 in
            let rgb = String.make (w * h * 3) '\x00' in
            let png = Msx_png.encode ~width:w ~height:h ~rgb in
            match chunks png with
            | ("IHDR", ihdr) :: _ ->
              check int "width" w (be4 ihdr 0);
              check int "height" h (be4 ihdr 4);
              check int "bit depth" 8 (Char.code ihdr.[8]);
              check int "colour type RGB" 2 (Char.code ihdr.[9]);
              check int "compression" 0 (Char.code ihdr.[10]);
              check int "filter" 0 (Char.code ihdr.[11]);
              check int "interlace" 0 (Char.code ihdr.[12])
            | _ -> failf "no IHDR chunk")
        ; test_case "IDAT is a stored-deflate zlib stream of the scanlines" `Quick
            (fun () ->
              (* Two pixels of known colour: red, green. *)
              let rgb = "\255\000\000\000\255\000" in
              let png = Msx_png.encode ~width:2 ~height:1 ~rgb in
              match chunks png with
              | [ ("IHDR", _); ("IDAT", idat); ("IEND", _) ] ->
                check string "zlib header (CMF, FLG)" "\x78\x01"
                  (String.sub idat 0 2);
                (* Scanline = filter byte 0 + the two pixels; a stored block
                   carries it verbatim after its 5-byte header. *)
                let want = "\x00" ^ rgb in
                let take = String.length want in
                let block =
                  String.sub idat 7 take
                in
                check string "the scanline rides uncompressed" want block;
                check int "stored LEN says the payload size" take
                  (Char.code idat.[3] lor (Char.code idat.[4] lsl 8))
              | _ -> failf "unexpected chunk layout")
        ; test_case "a mismatched buffer is rejected" `Quick (fun () ->
            (* The message carries the sizes, so match the constructor
               rather than one exact string. *)
            try
              ignore (Msx_png.encode ~width:4 ~height:2 ~rgb:"\000");
              failf "a short buffer encoded instead of raising"
            with Invalid_argument _ -> ())
        ; test_case "zero dimensions are rejected" `Quick (fun () ->
            try
              ignore (Msx_png.encode ~width:0 ~height:2 ~rgb:"");
              failf "zero width encoded instead of raising"
            with Invalid_argument _ -> ()) ] )
    ]
