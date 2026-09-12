(** Test suite for Masc_tui_image_cache: the verdict that decides whether a
    downloaded body may stay in the preview image cache. The bodies here are
    the ones the audit found cached as images: a rate-limit notice and an HTML
    page. *)

open Alcotest
module Cache = Masc_tui_image_cache

let verdict_name = function
  | Cache.Cached_image { media_type } -> "Cached_image " ^ media_type
  | Cache.Not_an_image _ -> "Not_an_image"
;;

let png_header = "\x89PNG\r\n\x1a\n\000\000\000\rIHDR"
let rate_limit_notice = "Too many requests, please try again later."
let html_page = "<!doctype html><html><head><title>403</title></head><body></body></html>"

let test_a_png_header_is_a_cached_image () =
  match Cache.verdict_of_bytes png_header with
  | Cache.Cached_image { media_type } -> check string "media type" "image/png" media_type
  | Cache.Not_an_image { reason } -> fail ("a PNG header was refused: " ^ reason)
;;

let test_a_rate_limit_notice_is_not_an_image () =
  check string "verdict" "Not_an_image" (verdict_name (Cache.verdict_of_bytes rate_limit_notice))
;;

let test_an_html_page_is_not_an_image () =
  check string "verdict" "Not_an_image" (verdict_name (Cache.verdict_of_bytes html_page))
;;

let test_an_empty_body_is_not_an_image () =
  check string "verdict" "Not_an_image" (verdict_name (Cache.verdict_of_bytes ""))
;;

let test_a_refused_body_names_why () =
  match Cache.verdict_of_bytes html_page with
  | Cache.Not_an_image { reason } -> check bool "reason is not empty" true (String.length reason > 0)
  | Cache.Cached_image _ -> fail "an HTML page was cached as an image"
;;

let test_download_error_text_carries_the_reason () =
  let text = Cache.download_error_text (Cache.Body_not_an_image { reason = "no signature" }) in
  check bool "mentions the reason" true
    (Option.is_some (Astring.String.find_sub ~sub:"no signature" text));
  check string "transport failure text is passed through" "curl exit 22"
    (Cache.download_error_text (Cache.Download_failed "curl exit 22"))
;;

let () =
  run "tui image cache"
    [ ( "verdict"
      , [ test_case "a PNG header is a cached image" `Quick test_a_png_header_is_a_cached_image
        ; test_case "a rate-limit notice is not an image" `Quick
            test_a_rate_limit_notice_is_not_an_image
        ; test_case "an HTML page is not an image" `Quick test_an_html_page_is_not_an_image
        ; test_case "an empty body is not an image" `Quick test_an_empty_body_is_not_an_image
        ; test_case "a refused body names why" `Quick test_a_refused_body_names_why
        ] )
    ; ( "error text"
      , [ test_case "carries the reason" `Quick test_download_error_text_carries_the_reason ] )
    ]
;;
