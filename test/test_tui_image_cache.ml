(** Test suite for Masc_tui_image_cache: the verdict that decides whether a
    downloaded body may stay in the preview image cache, and the meaning of a
    curl or ffmpeg exit status. Pure: no process runs, no network. The bodies
    here are the ones the audit found cached as images (a rate-limit notice,
    an HTML page) and the formats the link preview admits without a signature
    in the sniffer's table (BMP, AVIF). *)

open Alcotest
module Cache = Masc_tui_image_cache

let verdict_name = function
  | Cache.Known_image { media_type } -> "Known_image " ^ media_type
  | Cache.Unknown_signature -> "Unknown_signature"
  | Cache.Empty -> "Empty"
;;

let verdict = testable (fun fmt v -> Format.pp_print_string fmt (verdict_name v)) ( = )

let fetch_failure =
  testable (fun fmt f -> Format.pp_print_string fmt (Cache.fetch_failure_text f)) ( = )
;;

let decode_failure =
  testable (fun fmt f -> Format.pp_print_string fmt (Cache.decode_failure_text f)) ( = )
;;

let png_header = "\x89PNG\r\n\x1a\n\000\000\000\rIHDR"
let jpeg_header = "\xff\xd8\xff\xe0\000\x10JFIF"
let bmp_header = "BM\x36\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00"
let avif_header = "\000\000\000\x1cftypavif\000\000\000\000avifmif1"
let rate_limit_notice = "Too many requests, please try again later."
let html_page = "<!doctype html><html><head><title>403</title></head><body></body></html>"

(* ---- verdict by bytes ---- *)

let test_a_png_header_is_a_known_image () =
  check verdict "png" (Cache.Known_image { media_type = "image/png" })
    (Cache.verdict_of_bytes png_header)
;;

let test_a_jpeg_header_is_a_known_image () =
  check verdict "jpeg" (Cache.Known_image { media_type = "image/jpeg" })
    (Cache.verdict_of_bytes jpeg_header)
;;

(* BMP and AVIF are admitted by the link preview's extension list but carry no
   signature in the sniffer's table. They must reach the decoder, not be
   refused. *)
let test_a_bmp_header_is_left_to_the_decoder () =
  check verdict "bmp" Cache.Unknown_signature (Cache.verdict_of_bytes bmp_header)
;;

let test_an_avif_header_is_left_to_the_decoder () =
  check verdict "avif" Cache.Unknown_signature (Cache.verdict_of_bytes avif_header)
;;

(* The audit's poisoned bodies: bytes alone do not prove they are not images
   (an SVG is text too), so the decoder gets one look and its refusal is what
   the store keeps. *)
let test_a_rate_limit_notice_is_left_to_the_decoder () =
  check verdict "notice" Cache.Unknown_signature (Cache.verdict_of_bytes rate_limit_notice)
;;

let test_an_html_page_is_left_to_the_decoder () =
  check verdict "html" Cache.Unknown_signature (Cache.verdict_of_bytes html_page)
;;

let test_an_empty_body_is_proven_not_an_image () =
  check verdict "empty" Cache.Empty (Cache.verdict_of_bytes "")
;;

(* ---- curl exit status ---- *)

let test_a_clean_exit_with_a_body_is_not_a_failure () =
  check (option fetch_failure) "exit 0 + body" None
    (Cache.fetch_failure_of_status (Unix.WEXITED 0) ~body_present:true)
;;

let test_a_clean_exit_without_a_body_is_a_failure () =
  check (option fetch_failure) "exit 0, no body" (Some Cache.No_body_written)
    (Cache.fetch_failure_of_status (Unix.WEXITED 0) ~body_present:false)
;;

let test_curl_exit_codes_are_named () =
  let of_code code = Cache.fetch_failure_of_status (Unix.WEXITED code) ~body_present:false in
  check (option fetch_failure) "22 = --fail saw an HTTP error" (Some Cache.Http_error_status)
    (of_code 22);
  check (option fetch_failure) "28 = --max-time" (Some Cache.Operation_timeout) (of_code 28);
  check (option fetch_failure) "6 = no such host" (Some Cache.Could_not_resolve_host)
    (of_code 6);
  check (option fetch_failure) "7 = no connection" (Some Cache.Could_not_connect) (of_code 7);
  check (option fetch_failure) "127 = sh found no curl" (Some Cache.Curl_missing) (of_code 127);
  check (option fetch_failure) "any other code is kept as evidence"
    (Some (Cache.Curl_exit { code = 56 })) (of_code 56)
;;

let test_a_signal_on_curl_is_kept () =
  check (option fetch_failure) "signaled" (Some (Cache.Curl_signaled { signal = 9 }))
    (Cache.fetch_failure_of_status (Unix.WSIGNALED 9) ~body_present:false);
  check (option fetch_failure) "stopped" (Some (Cache.Curl_stopped { signal = 19 }))
    (Cache.fetch_failure_of_status (Unix.WSTOPPED 19) ~body_present:false)
;;

let test_download_error_text_carries_the_reason () =
  let mentions sub text = Option.is_some (Astring.String.find_sub ~sub text) in
  check bool "HTTP error status is said" true
    (mentions "HTTP error status" (Cache.download_error_text (Cache.Fetch_failed Cache.Http_error_status)));
  check bool "an other exit code is said" true
    (mentions "56" (Cache.download_error_text (Cache.Fetch_failed (Cache.Curl_exit { code = 56 }))));
  check bool "an empty body is said" true
    (mentions "empty body" (Cache.download_error_text Cache.Empty_body));
  check bool "an unreadable cache file carries the detail" true
    (mentions "EACCES" (Cache.download_error_text (Cache.Cache_unreadable { detail = "EACCES" })))
;;

(* ---- ffmpeg exit status ---- *)

let test_a_clean_decode_with_a_frame_is_not_a_failure () =
  check (option decode_failure) "exit 0 + frame" None
    (Cache.decode_failure_of_status (Unix.WEXITED 0) ~output_present:true)
;;

let test_a_clean_decode_without_a_frame_is_a_failure () =
  check (option decode_failure) "exit 0, no frame" (Some Cache.No_frame_written)
    (Cache.decode_failure_of_status (Unix.WEXITED 0) ~output_present:false)
;;

(* A body with a valid signature that ffmpeg cannot read (a truncated PNG)
   exits non-zero: that is the decoder's refusal, and only that discards the
   cached body. *)
let test_a_rejected_body_is_discarded () =
  let failure = Cache.decode_failure_of_status (Unix.WEXITED 1) ~output_present:false in
  check (option decode_failure) "exit 1 = rejected" (Some (Cache.Decoder_rejected { code = 1 }))
    failure;
  check bool "the body is discarded" true
    (Cache.decode_failure_discards_body (Cache.Decoder_rejected { code = 1 }))
;;

let test_a_missing_decoder_keeps_the_body () =
  check (option decode_failure) "127 = sh found no ffmpeg" (Some Cache.Decoder_missing)
    (Cache.decode_failure_of_status (Unix.WEXITED 127) ~output_present:false);
  check bool "the body is kept" false (Cache.decode_failure_discards_body Cache.Decoder_missing)
;;

let test_an_interrupted_or_frameless_decoder_keeps_the_body () =
  List.iter
    (fun failure ->
      check bool (Cache.decode_failure_text failure ^ " keeps the body") false
        (Cache.decode_failure_discards_body failure))
    [ Cache.Decoder_signaled { signal = 9 }
    ; Cache.Decoder_stopped { signal = 19 }
    ; Cache.No_frame_written
    ; Cache.Frame_unreadable { detail = "ENOENT" }
    ]
;;

let test_decode_failure_text_carries_the_reason () =
  let mentions sub text = Option.is_some (Astring.String.find_sub ~sub text) in
  check bool "exit code is said" true
    (mentions "exit 1" (Cache.decode_failure_text (Cache.Decoder_rejected { code = 1 })));
  check bool "missing ffmpeg is said" true
    (mentions "ffmpeg" (Cache.decode_failure_text Cache.Decoder_missing));
  check bool "read detail is said" true
    (mentions "ENOENT" (Cache.decode_failure_text (Cache.Frame_unreadable { detail = "ENOENT" })))
;;

let () =
  run "tui image cache"
    [ ( "verdict"
      , [ test_case "a PNG header is a known image" `Quick test_a_png_header_is_a_known_image
        ; test_case "a JPEG header is a known image" `Quick test_a_jpeg_header_is_a_known_image
        ; test_case "a BMP header is left to the decoder" `Quick
            test_a_bmp_header_is_left_to_the_decoder
        ; test_case "an AVIF header is left to the decoder" `Quick
            test_an_avif_header_is_left_to_the_decoder
        ; test_case "a rate-limit notice is left to the decoder" `Quick
            test_a_rate_limit_notice_is_left_to_the_decoder
        ; test_case "an HTML page is left to the decoder" `Quick
            test_an_html_page_is_left_to_the_decoder
        ; test_case "an empty body is proven not an image" `Quick
            test_an_empty_body_is_proven_not_an_image
        ] )
    ; ( "fetch"
      , [ test_case "a clean exit with a body is not a failure" `Quick
            test_a_clean_exit_with_a_body_is_not_a_failure
        ; test_case "a clean exit without a body is a failure" `Quick
            test_a_clean_exit_without_a_body_is_a_failure
        ; test_case "curl exit codes are named" `Quick test_curl_exit_codes_are_named
        ; test_case "a signal on curl is kept" `Quick test_a_signal_on_curl_is_kept
        ; test_case "download error text carries the reason" `Quick
            test_download_error_text_carries_the_reason
        ] )
    ; ( "decode"
      , [ test_case "a clean decode with a frame is not a failure" `Quick
            test_a_clean_decode_with_a_frame_is_not_a_failure
        ; test_case "a clean decode without a frame is a failure" `Quick
            test_a_clean_decode_without_a_frame_is_a_failure
        ; test_case "a rejected body is discarded" `Quick test_a_rejected_body_is_discarded
        ; test_case "a missing decoder keeps the body" `Quick
            test_a_missing_decoder_keeps_the_body
        ; test_case "an interrupted or frameless decoder keeps the body" `Quick
            test_an_interrupted_or_frameless_decoder_keeps_the_body
        ; test_case "decode failure text carries the reason" `Quick
            test_decode_failure_text_carries_the_reason
        ] )
    ]
;;
