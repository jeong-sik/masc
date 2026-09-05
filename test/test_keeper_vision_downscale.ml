open Alcotest

module Vd = Masc.Keeper_vision_downscale

let be_byte offset value = Char.chr ((value lsr offset) land 0xff)
let be4 value = String.init 4 (fun i -> be_byte ((3 - i) * 8) value)
let be2 value = String.init 2 (fun i -> be_byte ((1 - i) * 8) value)
let le2 value = String.init 2 (fun i -> be_byte (i * 8) value)

let le4 value =
  String.init 4 (fun i -> Char.chr ((value lsr (i * 8)) land 0xff))
;;

let png_header width height =
  String.concat ""
    [ "\x89PNG\r\n\x1a\n"
    ; "\x00\x00\x00\x0d"
    ; "IHDR"
    ; be4 width
    ; be4 height
    ; "\x08\x06\x00\x00\x00"
    ]
;;

let jpeg_header width height =
  String.concat ""
    [ "\xff\xd8"
    ; "\xff\xe0"
    ; "\x00\x04"
    ; "AB"
    ; "\xff\xc0"
    ; "\x00\x08"
    ; "\x08"
    ; be2 height
    ; be2 width
    ]
;;

let gif_header width height = "GIF89a" ^ le2 width ^ le2 height

let webp_vp8_header width height =
  let tag = "\x00\x00\x00" in
  let code = "\x9d\x01\x2a" in
  let dims = le2 (width land 0x3fff) ^ le2 (height land 0x3fff) in
  let payload = tag ^ code ^ dims in
  "RIFF" ^ le4 (String.length payload + 12) ^ "WEBPVP8 " ^ le4 (String.length payload) ^ payload
;;

let webp_vp8l_header width height =
  let packed =
    ((width - 1) land 0x3fff) lor (((height - 1) land 0x3fff) lsl 14)
  in
  let payload = "\x2f" ^ le4 packed in
  "RIFF" ^ le4 (String.length payload + 12) ^ "WEBPVP8L" ^ le4 (String.length payload) ^ payload
;;

let webp_vp8x_header width height =
  let w_bytes = String.sub (le4 (width - 1)) 0 3 in
  let h_bytes = String.sub (le4 (height - 1)) 0 3 in
  let payload = "\x00\x00\x00\x00" ^ w_bytes ^ h_bytes in
  "RIFF" ^ le4 (String.length payload + 12) ^ "WEBPVP8X" ^ le4 10 ^ payload
;;

let test_detect_dimensions_png () =
  let res = Vd.detect_dimensions (png_header 3456 2168) in
  check (option (pair int int)) "png dimensions" (Some (3456, 2168))
    (Option.map (fun (d : Vd.dimensions) -> (d.width, d.height)) res);
  check (option (pair int int)) "truncated png" None
    (Option.map (fun (d : Vd.dimensions) -> (d.width, d.height))
       (Vd.detect_dimensions "\x89PNG"))
;;

let test_detect_dimensions_jpeg () =
  let res = Vd.detect_dimensions (jpeg_header 12345 6789) in
  check (option (pair int int)) "jpeg dimensions" (Some (12345, 6789))
    (Option.map (fun (d : Vd.dimensions) -> (d.width, d.height)) res);
  check (option (pair int int)) "broken jpeg" None
    (Option.map (fun (d : Vd.dimensions) -> (d.width, d.height))
       (Vd.detect_dimensions "\xff\xd8\x00\x00"))
;;

let test_detect_dimensions_gif () =
  let res = Vd.detect_dimensions (gif_header 800 600) in
  check (option (pair int int)) "gif dimensions" (Some (800, 600))
    (Option.map (fun (d : Vd.dimensions) -> (d.width, d.height)) res)
;;

let test_detect_dimensions_webp () =
  let res_vp8 = Vd.detect_dimensions (webp_vp8_header 2500 1200) in
  check (option (pair int int)) "webp vp8 dimensions" (Some (2500, 1200))
    (Option.map (fun (d : Vd.dimensions) -> (d.width, d.height)) res_vp8);

  let res_vp8l = Vd.detect_dimensions (webp_vp8l_header 3100 1800) in
  check (option (pair int int)) "webp vp8l dimensions" (Some (3100, 1800))
    (Option.map (fun (d : Vd.dimensions) -> (d.width, d.height)) res_vp8l);

  let res_vp8x = Vd.detect_dimensions (webp_vp8x_header 2048 1536) in
  check (option (pair int int)) "webp vp8x dimensions" (Some (2048, 1536))
    (Option.map (fun (d : Vd.dimensions) -> (d.width, d.height)) res_vp8x);

  check (option (pair int int)) "truncated webp" None
    (Option.map (fun (d : Vd.dimensions) -> (d.width, d.height))
       (Vd.detect_dimensions "RIFF\x00\x00\x00\x00WEBPVP8 "))
;;

let test_needs_downscale () =
  check bool "within bounds (1000, 800) with max 1568" false
    (Vd.needs_downscale ~max_dimension:1568 (png_header 1000 800));
  check bool "exact bounds (1568, 1568) with max 1568" false
    (Vd.needs_downscale ~max_dimension:1568 (png_header 1568 1568));
  check bool "exceeding width (2000, 1000) with max 1568" true
    (Vd.needs_downscale ~max_dimension:1568 (png_header 2000 1000));
  check bool "exceeding height (1000, 2000) with max 1568" true
    (Vd.needs_downscale ~max_dimension:1568 (png_header 1000 2000));
  check bool "unknown format returns false" false
    (Vd.needs_downscale ~max_dimension:1568 "not-an-image")
;;

let test_downscale_with_status_within_bounds () =
  let bytes = gif_header 800 600 in
  let (out_mt, out_bytes), status =
    Vd.downscale_with_status ~max_dimension:1568 ~media_type:"image/gif" ~bytes
  in
  check string "same media type" "image/gif" out_mt;
  check string "identical bytes" bytes out_bytes;
  match status with
  | Vd.Unchanged_within_bounds { width = 800; height = 600 } -> ()
  | _ -> fail "expected Unchanged_within_bounds"
;;

let test_downscale_with_status_unknown () =
  let bytes = "random_unparseable_bytes" in
  let (out_mt, out_bytes), status =
    Vd.downscale_with_status ~max_dimension:1568 ~media_type:"image/png" ~bytes
  in
  check string "same media type" "image/png" out_mt;
  check string "identical bytes" bytes out_bytes;
  match status with
  | Vd.Unchanged_unknown_dimensions -> ()
  | _ -> fail "expected Unchanged_unknown_dimensions"
;;

(* Valid 1-bit 2000x1000 PNG base64 fixture *)
let valid_2000x1000_png_b64 =
  "iVBORw0KGgoAAAANSUhEUgAAB9AAAAPoAQAAAACuJVgHAAAD5klEQVR42u3PAQEAAAgCIOv/5xoi"
  ^ "PGAurTbq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq"
  ^ "6hUehaYIz0sqNDUAAAAASUVORK5CYII="
;;

let test_downscale_oversized_png_live () =
  let bytes =
    match Base64.decode valid_2000x1000_png_b64 with
    | Ok b -> b
    | Error (`Msg msg) -> failwith ("fixture b64 decode failed: " ^ msg)
  in
  let (out_mt, out_bytes), status =
    Vd.downscale_with_status ~max_dimension:1568 ~media_type:"image/png" ~bytes
  in
  match status with
  | Vd.Downscaled { original_dims; scaled_dims; scaler = _ } ->
    check string "downscaled media type" "image/png" out_mt;
    check int "orig width" 2000 original_dims.width;
    check int "orig height" 1000 original_dims.height;
    (match scaled_dims with
     | Some dims ->
       check bool "scaled width <= 1568" true (dims.width <= 1568);
       check bool "scaled height <= 1568" true (dims.height <= 1568)
     | None -> fail "expected scaled_dims to be detected")
  | Vd.Downscale_fallback_error Vd.Scalers_exhausted ->
    (* On minimal container environments without any scalers installed *)
    check string "fallback media type" "image/png" out_mt;
    check string "fallback original bytes" bytes out_bytes
  | Vd.Downscale_fallback_error (Vd.Scaler_exception msg) ->
    fail ("unexpected downscaling exception: " ^ msg)
  | _ -> fail "expected Downscaled or Scalers_exhausted status"
;;

let test_closed_sum_printers () =
  check string "sips to string" "sips" (Vd.scaler_to_string Vd.Sips);
  check string "magick to string" "magick" (Vd.scaler_to_string Vd.Magick);
  check string "convert to string" "convert" (Vd.scaler_to_string Vd.Convert);
  check string "exhausted to string" "scalers_exhausted"
    (Vd.failure_reason_to_string Vd.Scalers_exhausted);
  check string "exception to string" "exception:test"
    (Vd.failure_reason_to_string (Vd.Scaler_exception "test"))
;;

let () =
  run "Keeper_vision_downscale"
    [ ( "dimensions"
      , [ test_case "png header" `Quick test_detect_dimensions_png
        ; test_case "jpeg header" `Quick test_detect_dimensions_jpeg
        ; test_case "gif header" `Quick test_detect_dimensions_gif
        ; test_case "webp headers (vp8, vp8l, vp8x)" `Quick
            test_detect_dimensions_webp
        ] )
    ; ( "decision"
      , [ test_case "needs_downscale bounds logic" `Quick test_needs_downscale ] )
    ; ( "downscale"
      , [ test_case "within bounds is unchanged" `Quick
            test_downscale_with_status_within_bounds
        ; test_case "unknown format is unchanged" `Quick
            test_downscale_with_status_unknown
        ; test_case "oversized png live downscale" `Quick
            test_downscale_oversized_png_live
        ; test_case "closed sum printers" `Quick
            test_closed_sum_printers
        ] )
    ]
;;
