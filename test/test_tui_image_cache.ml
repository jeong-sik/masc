(** Test suite for Masc_tui_image_cache: the verdict that decides whether a
    downloaded body may stay in the preview image cache, and the meaning of a
    curl or ffmpeg exit status. File workflow tests use real shell fixtures
    and temporary cache files; no network or installed converter is required. The bodies
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

(* Bytes alone do not prove these are not images (an SVG is text too).
   They reach the decoder, whose failure still cannot diagnose the input. *)
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

let test_a_nonzero_exit_does_not_diagnose_the_body () =
  let failure = Cache.decode_failure_of_status (Unix.WEXITED 1) ~output_present:false in
  check (option decode_failure) "exit 1 stays ambiguous" (Some (Cache.Decoder_exit { code = 1 }))
    failure
;;

let test_a_missing_decoder_keeps_the_body () =
  check (option decode_failure) "127 = sh found no ffmpeg" (Some Cache.Decoder_missing)
    (Cache.decode_failure_of_status (Unix.WEXITED 127) ~output_present:false)
;;

let test_decode_failure_text_carries_the_reason () =
  let mentions sub text = Option.is_some (Astring.String.find_sub ~sub text) in
  check bool "exit code is said" true
    (mentions "exited 1" (Cache.decode_failure_text (Cache.Decoder_exit { code = 1 })));
  check bool "missing executable is said" true
    (mentions "not found" (Cache.decode_failure_text Cache.Decoder_missing));
  check bool "read detail is said" true
    (mentions "ENOENT" (Cache.decode_failure_text (Cache.Frame_unreadable { detail = "ENOENT" })))
;;

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel bytes)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let executable dir name body =
  let path = Filename.concat dir name in
  write_file path ("#!/bin/sh\n" ^ body ^ "\n");
  Unix.chmod path 0o700

let with_cache f =
  let dir = Filename.temp_file "tui-image-workflow-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun name -> Sys.remove (Filename.concat dir name)) (Sys.readdir dir);
      Unix.rmdir dir)
    (fun () ->
      let run command = Unix.system ("PATH=" ^ Filename.quote dir ^ " " ^ command) in
      f dir run)

let shell_bytes bytes =
  String.to_seq bytes |> List.of_seq
  |> List.map (fun byte -> Printf.sprintf "\\0%03o" (Char.code byte))
  |> String.concat "" |> Filename.quote

let serve dir bytes =
  executable dir "curl"
    (Printf.sprintf "printf x >> %s\nprintf %%b %s > \"$7\""
       (Filename.quote (Filename.concat dir "fetches")) (shell_bytes bytes))

let converter_succeeds dir name bytes =
  executable dir name
    (Printf.sprintf "for output do :; done\nprintf %%b %s > \"$output\""
       (shell_bytes bytes))

let unwrap = function Ok value -> value | Error _ -> fail "unexpected workflow failure"

let test_mosaic_failure_retains_input_and_can_recover () =
  List.iter (fun code -> with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/preview.png" in
    serve cache_dir png_header;
    executable cache_dir "ffmpeg" (Printf.sprintf "exit %d" code);
    let input = unwrap (Cache.download ~run ~cache_dir url) in
    let output_path = Filename.concat cache_dir "frame.raw" in
    let command = Printf.sprintf "ffmpeg -i %s %s"
      (Filename.quote input) (Filename.quote output_path) in
    (* A failed command must not accept a frame left by an earlier attempt. *)
    write_file output_path "stale";
    check bool "decode fails" true
      (Result.is_error (Cache.run_decoder ~run ~output_path command));
    check string "original bytes retained" png_header (read_file input);
    check bool "failed output discarded" false (Sys.file_exists output_path);
    converter_succeeds cache_dir "ffmpeg" "rgbRGB";
    ignore (unwrap (Cache.download ~run ~cache_dir url));
    ignore (unwrap (Cache.run_decoder ~run ~output_path command));
    check string "recovered frame" "rgbRGB" (read_file output_path);
    check string "retained source avoids another fetch" "x"
      (read_file (Filename.concat cache_dir "fetches"))))
    [ 1; 126; 127 ]

let test_v_missing_converters_retains_input () =
  with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/preview.jpg" in
    serve cache_dir jpeg_header;
    List.iter (fun name -> executable cache_dir name "exit 127")
      [ "sips"; "convert"; "ffmpeg" ];
    check bool "PNG preparation reports failure" true
      (Result.is_error (Cache.prepare_png ~run ~cache_dir url));
    let input = unwrap (Cache.download ~run ~cache_dir url) in
    check string "JPEG still cached" jpeg_header (read_file input);
    converter_succeeds cache_dir "sips" png_header;
    check string "next explicit view can convert" png_header
      (unwrap (Cache.prepare_png ~run ~cache_dir url));
    check string "no second download" "x"
      (read_file (Filename.concat cache_dir "fetches")))

let test_explicit_retry_recovers_without_background_loop () =
  with_cache (fun cache_dir run ->
    let module Preview = Masc_tui_link_preview in
    let url = "https://fixture.invalid/retry.png" in
    Preview.clear_cache ();
    let attempts = ref 0 in
    let compute () =
      incr attempts;
      match Cache.download ~run ~cache_dir url with
        | Error failure ->
          Preview.Refused (Preview.Fetch_failed { detail = Cache.download_error_text failure })
        | Ok input ->
          let output_path = Filename.concat cache_dir "retry.raw" in
          let command = Printf.sprintf "ffmpeg -i %s %s"
            (Filename.quote input) (Filename.quote output_path) in
          match Cache.run_decoder ~run ~output_path command with
          | Error failure ->
            Preview.Refused (Preview.Decode_failed { detail = Cache.decode_failure_text failure })
          | Ok path ->
            Preview.Mosaic (Masc_tui_image_mosaic.render ~cols:1 ~rows:2 (read_file path))
    in
    executable cache_dir "curl" "exit 28";
    Preview.load_mosaic url ~compute;
    ignore (Preview.mosaic_lookup url);
    ignore (Preview.mosaic_lookup url);
    check int "reads do not retry a timeout" 1 !attempts;
    serve cache_dir png_header;
    converter_succeeds cache_dir "ffmpeg" "rgbRGB";
    let retry () =
      Cache.invalidate_download ~cache_dir url;
      compute ()
    in
    Preview.retry_mosaic ~retry url;
    (match Preview.mosaic_lookup url with
     | Some (Preview.Mosaic (_ :: _)) -> ()
     | Some (Preview.Mosaic [] | Preview.Refused _) | None -> fail "retry produced no mosaic");
    check int "one explicit retry" 2 !attempts;
    Preview.retry_mosaic ~retry url;
    check int "no extra attempt" 2 !attempts;
    Preview.clear_cache ())

let test_overlapping_load_and_retry_share_one_claim () =
  let module Preview = Masc_tui_link_preview in
  Preview.clear_cache ();
  let url = "https://fixture.invalid/overlap.png" in
  let unexpected_compute () = fail "a pending URL was computed twice" in
  Preview.load_mosaic url ~compute:(fun () ->
    Preview.load_mosaic url ~compute:unexpected_compute;
    Preview.retry_mosaic url ~retry:unexpected_compute;
    Preview.Refused Preview.Empty_body);
  Preview.retry_mosaic url ~retry:(fun () ->
    Preview.load_mosaic url ~compute:unexpected_compute;
    Preview.retry_mosaic url ~retry:unexpected_compute;
    Preview.Mosaic [ "recovered" ]);
  Preview.load_mosaic url ~compute:unexpected_compute;
  Preview.retry_mosaic url ~retry:unexpected_compute;
  (match Preview.mosaic_lookup url with
   | Some (Preview.Mosaic [ "recovered" ]) -> ()
   | _ -> fail "retry outcome was not retained");
  Preview.clear_cache ()

exception Compute_interrupted

let test_failed_computation_releases_claim () =
  let module Preview = Masc_tui_link_preview in
  Preview.clear_cache ();
  let url = "https://fixture.invalid/interrupted.png" in
  let interrupted () = raise Compute_interrupted in
  check_raises "initial exception propagates" Compute_interrupted (fun () ->
    Preview.load_mosaic url ~compute:interrupted);
  Preview.load_mosaic url ~compute:(fun () -> Preview.Refused Preview.Empty_body);
  check_raises "retry exception propagates" Compute_interrupted (fun () ->
    Preview.retry_mosaic url ~retry:interrupted);
  (match Preview.mosaic_lookup url with
   | Some (Preview.Refused Preview.Empty_body) -> ()
   | _ -> fail "interrupted retry lost its refusal");
  Preview.retry_mosaic url ~retry:(fun () -> Preview.Mosaic [ "recovered" ]);
  (match Preview.mosaic_lookup url with
   | Some (Preview.Mosaic [ "recovered" ]) -> ()
   | _ -> fail "interrupted claim was not released");
  Preview.clear_cache ()

let test_clear_pending_keeps_claim_and_discards_completion () =
  let module Preview = Masc_tui_link_preview in
  List.iter (fun fail_compute ->
    Preview.clear_cache ();
    let url = "https://fixture.invalid/cleared.png" in
    let unexpected_compute () = fail "clear released an active worker" in
    Preview.load_mosaic url ~compute:(fun () -> Preview.Refused Preview.Empty_body);
    let retry () =
      Preview.clear_cache ();
      Preview.load_mosaic url ~compute:unexpected_compute;
      Preview.retry_mosaic url ~retry:unexpected_compute;
      if fail_compute then raise Compute_interrupted;
      Preview.Mosaic [ "stale" ]
    in
    if fail_compute then
      check_raises "cleared retry exception propagates" Compute_interrupted
        (fun () -> Preview.retry_mosaic url ~retry)
    else Preview.retry_mosaic url ~retry;
    check bool "cleared callback cannot restore an old outcome" true
      (Option.is_none (Preview.mosaic_lookup url));
    Preview.load_mosaic url ~compute:(fun () -> Preview.Mosaic [ "fresh" ]);
    (match Preview.mosaic_lookup url with
     | Some (Preview.Mosaic [ "fresh" ]) -> ()
     | _ -> fail "completed cleared worker left a reservation");
    Preview.clear_cache ()) [ false; true ]

let test_partial_converter_failure_uses_next_converter () =
  with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/fallback.jpg" in
    serve cache_dir jpeg_header;
    executable cache_dir "sips"
      "for output do :; done\nprintf partial > \"$output\"\nexit 1";
    converter_succeeds cache_dir "convert" png_header;
    check string "partial failed output is replaced by next converter" png_header
      (unwrap (Cache.prepare_png ~run ~cache_dir url));
    check string "fallback retains source without refetch" "x"
      (read_file (Filename.concat cache_dir "fetches")))

let test_explicit_refresh_replaces_a_refused_body () =
  with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/transient.png" in
    serve cache_dir html_page;
    List.iter (fun name -> executable cache_dir name "exit 1")
      [ "sips"; "convert"; "ffmpeg" ];
    check bool "notice cannot be converted" true
      (Result.is_error (Cache.prepare_png ~run ~cache_dir url));
    let input = unwrap (Cache.download ~run ~cache_dir url) in
    check string "ambiguous decode does not discard bytes" html_page (read_file input);
    serve cache_dir png_header;
    Cache.invalidate_download ~cache_dir url;
    check string "explicit refresh gets new source" png_header
      (unwrap (Cache.prepare_png ~run ~cache_dir url));
    check string "one initial and one explicit fetch" "xx"
      (read_file (Filename.concat cache_dir "fetches")))

(* Two workers on one URL name the same cache file, because the name is derived
   from the URL. The [r] retry deletes that file while a [v] render may be
   downloading or converting into it, and two downloads would otherwise curl into
   one path. These two cases delete the shared path from inside the fetch and the
   conversion -- which is what a concurrent retry does -- and check that the work
   still lands whole. Writing in place fails both: the delete takes the attempt's
   own half-written output with it. *)
let test_a_delete_during_the_fetch_does_not_take_the_download () =
  with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/raced.png" in
    let shared = Cache.input_path ~cache_dir url in
    executable cache_dir "curl"
      (Printf.sprintf
         "printf %%b %s > \"$7\"\n/bin/rm -f %s\nprintf %%b %s >> \"$7\""
         (shell_bytes (String.sub png_header 0 4))
         (Filename.quote shared)
         (shell_bytes (String.sub png_header 4 (String.length png_header - 4))));
    let path = unwrap (Cache.download ~run ~cache_dir url) in
    check string "the published file is the whole body" png_header (read_file path);
    check string "and it is the shared path the readers look at" shared path)

let test_a_delete_during_the_conversion_does_not_take_the_frame () =
  with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/raced.bmp" in
    serve cache_dir bmp_header;
    let input = unwrap (Cache.download ~run ~cache_dir url) in
    let shared = Cache.png_path ~cache_dir input in
    executable cache_dir "sips"
      (Printf.sprintf
         "for output do :; done\nprintf %%b %s > \"$output\"\n/bin/rm -f %s\nprintf %%b %s >> \"$output\""
         (shell_bytes (String.sub png_header 0 4))
         (Filename.quote shared)
         (shell_bytes (String.sub png_header 4 (String.length png_header - 4))));
    match Cache.convert_to_png ~run ~cache_dir input with
    | Error failures -> failf "conversion failed: %s" (Cache.conversion_failure_text failures)
    | Ok path ->
      check string "the published frame is whole" png_header (read_file path);
      check string "and it is the shared path" shared path)

(* A body the sniffer refuses must not be left in the cache for the next reader
   to find and discard: it is never published in the first place. *)
let test_a_refused_body_never_reaches_the_cache_path () =
  with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/notice.txt" in
    serve cache_dir "";
    let shared = Cache.input_path ~cache_dir url in
    (match Cache.download ~run ~cache_dir url with
     | Ok _ -> fail "an empty body must be refused"
     | Error _ -> ());
    check bool "nothing was left at the shared path" false (Sys.file_exists shared))

let () =
  run "tui image cache"
    [ ( "workflows"
      , [ test_case "a delete during the fetch does not take the download" `Quick
            test_a_delete_during_the_fetch_does_not_take_the_download
        ; test_case "a delete during the conversion does not take the frame" `Quick
            test_a_delete_during_the_conversion_does_not_take_the_frame
        ; test_case "a refused body never reaches the cache path" `Quick
            test_a_refused_body_never_reaches_the_cache_path
        ; test_case "mosaic failure retains input and can recover" `Quick
            test_mosaic_failure_retains_input_and_can_recover
        ; test_case "view retains input when all converters are missing" `Quick
            test_v_missing_converters_retains_input
        ; test_case "explicit retry recovers without background loop" `Quick
            test_explicit_retry_recovers_without_background_loop
        ; test_case "overlapping initial load and retry share one claim" `Quick
            test_overlapping_load_and_retry_share_one_claim
        ; test_case "failed computation releases its claim" `Quick
            test_failed_computation_releases_claim
        ; test_case "clear retains pending ownership and discards completion" `Quick
            test_clear_pending_keeps_claim_and_discards_completion
        ; test_case "partial converter failure uses next converter" `Quick
            test_partial_converter_failure_uses_next_converter
        ; test_case "explicit refresh replaces refused body" `Quick
            test_explicit_refresh_replaces_a_refused_body
        ] )
    ; ( "verdict"
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
        ; test_case "a nonzero exit does not diagnose the body" `Quick
            test_a_nonzero_exit_does_not_diagnose_the_body
        ; test_case "a missing decoder keeps the body" `Quick
            test_a_missing_decoder_keeps_the_body
        ; test_case "decode failure text carries the reason" `Quick
            test_decode_failure_text_carries_the_reason
        ] )
    ]
;;
