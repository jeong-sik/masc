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
let animated_gif =
  "\x47\x49\x46\x38\x39\x61\x02\x00\x02\x00\xf0\x00\x00\xff\x00\x00\
   \x00\x00\x00\x21\xff\x0b\x4e\x45\x54\x53\x43\x41\x50\x45\x32\x2e\
   \x30\x03\x01\x00\x00\x00\x21\xf9\x04\x00\x00\x00\x00\x00\x2c\x00\
   \x00\x00\x00\x02\x00\x02\x00\x00\x02\x02\x84\x51\x00\x21\xf9\x04\
   \x00\x00\x00\x00\x00\x2c\x00\x00\x00\x00\x02\x00\x02\x00\x80\x00\
   \x00\xff\x00\x00\x00\x02\x02\x84\x51\x00\x3b"
let offset_gif =
  let bytes = Bytes.of_string animated_gif in
  let descriptor = String.index animated_gif '\x2c' in
  Bytes.set bytes 6 '\004';
  Bytes.set bytes 8 '\004';
  Bytes.set bytes (descriptor + 1) '\001';
  Bytes.set bytes (descriptor + 3) '\001';
  Bytes.to_string bytes
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

let exhausted_runner_failure =
  Cache.{ error = Unix.EMFILE; operation = "open"; argument = "/dev/null" }

let raise_exhausted () = raise (Unix.Unix_error (Unix.EMFILE, "open", "/dev/null"))

let capture_converter_output cache_dir command =
  let captured_path = Filename.concat cache_dir "output-path" in
  let capture = Printf.sprintf
      "set -- %s\nfor output do :; done\nprintf '%%s' \"$output\" > %s"
      command (Filename.quote captured_path) in
  check bool "fixture captured converter path" true (Unix.system capture = Unix.WEXITED 0);
  read_file captured_path

let test_download_reports_runner_failure_and_cleans_attempt () =
  with_cache (fun cache_dir _ ->
    let result = Cache.download ~run:(fun _ -> raise_exhausted ()) ~cache_dir
        "https://fixture.invalid/image" in
    check bool "OS error remains distinct from curl exit" true
      (result = Error (Cache.Fetch_failed (Cache.Curl_runner_failed exhausted_runner_failure)));
    (match result with
     | Error error ->
       check string "error keeps the operation and argument"
         ("could not download the image: could not run curl: " ^
          Unix.error_message Unix.EMFILE ^ " (open: /dev/null)")
         (Cache.download_error_text error)
     | Ok _ -> fail "runner failure succeeded");
    check (list string) "failed download left no attempt" []
      (Sys.readdir cache_dir |> Array.to_list))

let test_decoder_reports_runner_failure_without_removing_shared_output () =
  with_cache (fun cache_dir _ ->
    let output = Filename.concat cache_dir "partial.raw" in
    let run _ = write_file output "partial"; raise_exhausted () in
    let result = Cache.run_decoder ~run ~output_path:output "fixture" in
    check bool "runner failure retains its OS cause" true
      (result = Error (Cache.Decoder_runner_failed exhausted_runner_failure));
    check string "runner failure does not remove another writer's output" "partial"
      (read_file output))

let test_runner_failure_stops_converter_fallback () =
  with_cache (fun cache_dir _ ->
    let source = Filename.concat cache_dir "original.bmp" in
    let calls = ref 0 in
    write_file source bmp_header;
    let run command =
      incr calls;
      if !calls = 1 then Unix.WEXITED 1 else begin
        write_file (capture_converter_output cache_dir command) "partial";
        raise_exhausted ()
      end in
    let result = Cache.convert_to_png ~run ~cache_dir source in
    check bool "previous exit and runner failure stay separate" true
      (result = Error [Cache.Sips, Cache.Decoder_exit {code=1};
                       Cache.Image_magick, Cache.Decoder_runner_failed exhausted_runner_failure]);
    check int "no further converter starts after a runner failure" 2 !calls;
    check string "source remains intact" bmp_header (read_file source);
    check string "runner failure leaves the unowned output path alone" "partial"
      (read_file (read_file (Filename.concat cache_dir "output-path"))))

exception Runner_interrupted

let test_unexpected_runner_exception_preserves_shared_output () =
  with_cache (fun cache_dir _ ->
    let interrupt _ = raise Runner_interrupted in
    check_raises "unexpected download exception propagates" Runner_interrupted (fun () ->
      ignore (Cache.download ~run:interrupt ~cache_dir "https://fixture.invalid/image"));
    check (list string) "interrupted download leaves no attempt" []
      (Sys.readdir cache_dir |> Array.to_list);
    let output = Filename.concat cache_dir "partial.raw" in
    check_raises "unexpected decoder exception propagates" Runner_interrupted (fun () ->
      ignore (Cache.run_decoder ~output_path:output ~run:(fun _ ->
        write_file output "partial"; raise Runner_interrupted) "fixture"));
    check string "interrupted shared decoder path is not removed" "partial" (read_file output);
    Sys.remove output;
    let source = Filename.concat cache_dir "original.bmp" in
    write_file source bmp_header;
    let run command =
      write_file (capture_converter_output cache_dir command) "partial";
      raise Runner_interrupted in
    check_raises "unexpected conversion exception propagates" Runner_interrupted (fun () ->
      ignore (Cache.convert_to_png ~run ~cache_dir source));
    check string "interrupted conversion leaves the unowned output path alone" "partial"
      (read_file (read_file (Filename.concat cache_dir "output-path"))))

let test_local_file_preserves_original () =
  with_cache (fun cache_dir run ->
    let source = Filename.concat cache_dir "original.bmp" in
    write_file source bmp_header;
    converter_succeeds cache_dir "sips" png_header;
    check string "converted captured local bytes" png_header
      (unwrap (Cache.prepare_file ~run ~cache_dir source));
    check string "original source retained" bmp_header (read_file source))

let test_local_file_failure_and_recovery () =
  with_cache (fun cache_dir run ->
    let source = Filename.concat cache_dir "late.png" in
    check bool "missing local file refused" true
      (Result.is_error (Cache.prepare_file ~run ~cache_dir source));
    write_file source "";
    check bool "empty source refused" true
      (Result.is_error (Cache.prepare_file ~run ~cache_dir source));
    write_file source png_header;
    check string "explicit retry reads current source" png_header
      (unwrap (Cache.prepare_file ~run ~cache_dir source));
    check string "original bytes preserved" png_header (read_file source))

let test_character_frame_refuses_unrepresentable_ratio () =
  with_cache (fun cache_dir _run ->
    let be32 n = String.init 4 (fun i -> Char.chr ((n lsr ((3 - i) * 8)) land 255)) in
    let run _ = fail "unrepresentable image must be refused before starting a decoder" in
    List.iter (fun (width, height, columns, rows) ->
      let png = png_header ^ be32 width ^ be32 height in
      let display = Cache.Character_cells {columns;rows} in
      check bool "unrepresentable ratio refused" true
        (Result.is_error (Cache.prepare_presentation ~run ~cache_dir display png));
      check (list string) "refusal creates no temporary files" []
        (Sys.readdir cache_dir |> Array.to_list))
      [400,1,100,20; 1000,10,78,21])

let test_character_frame_protocol_and_cleanup () =
  with_cache (fun cache_dir run ->
    (* The process fixture supplies decoder output; this header supplies its
       declared dimensions. Real PNG/ffmpeg decoding is a separate native
       manual observation, not claimed by this boundary test. *)
    let png = png_header ^ "\000\000\000\002\000\000\000\002" in
    let source = Filename.concat cache_dir "retained-original" in
    write_file source png;
    let rgba = "\025\169\116\255\235\087\087\255\025\169\116\000\235\087\087\128" in
    let display = Cache.Character_cells {columns=2;rows=1} in
    let attempt bytes =
      converter_succeeds cache_dir "ffmpeg" bytes;
      let result = Cache.prepare_presentation ~run ~cache_dir display png in
      check string "original retained" png (read_file source);
      check (list string) "only source and process fixture retained"
        ["ffmpeg";"retained-original"] (Sys.readdir cache_dir |> Array.to_list |> List.sort String.compare);
      result in
    List.iter (fun bytes ->
      check bool "wrong decoder frame length refused" true (Result.is_error (attempt bytes)))
      [String.sub rgba 0 15; rgba ^ "x"];
    (match unwrap (attempt rgba) with
     | Cache.Rgba {columns;pixel_rows;bytes} ->
       check int "RGBA width" 2 columns;
       check int "RGBA height" 2 pixel_rows;
       check string "alpha and pixel bytes preserved" rgba bytes
     | Png _ -> fail "character request returned PNG");
    executable cache_dir "ffmpeg" "exit 127";
    check bool "missing decoder remains a refusal" true
      (Result.is_error (Cache.prepare_presentation ~run ~cache_dir display png));
    check (list string) "failed attempt leaves no temporary files"
      ["ffmpeg";"retained-original"] (Sys.readdir cache_dir |> Array.to_list |> List.sort String.compare))

let test_character_frame_keeps_output_reserved () =
  with_cache (fun cache_dir _ ->
    let png = png_header ^ "\000\000\000\002\000\000\000\002" in
    let display = Cache.Character_cells {columns=2;rows=1} in
    List.iter (fun status ->
      let reserved = ref false in
      let run command =
        let output = capture_converter_output cache_dir command in
        reserved := (match Unix.openfile output [Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY] 0o600 with
          | fd -> Unix.close fd; false
          | exception Unix.Unix_error (Unix.EEXIST, _, _) -> true);
        status in
      check bool "failed or empty decode is refused" true
        (Result.is_error (Cache.prepare_presentation ~run ~cache_dir display png));
      check bool "another attempt cannot reserve the output while decoder runs" true !reserved;
      check (list string) "owned attempt files are cleaned up" ["output-path"]
        (Sys.readdir cache_dir |> Array.to_list |> List.sort String.compare))
      [Unix.WEXITED 1; Unix.WEXITED 0];
    check_raises "unexpected runner exceptions propagate" Runner_interrupted (fun () ->
      ignore (Cache.prepare_presentation ~run:(fun _ -> raise Runner_interrupted)
        ~cache_dir display png));
    check (list string) "exception cleans owned attempt files" ["output-path"]
      (Sys.readdir cache_dir |> Array.to_list |> List.sort String.compare))

let test_mosaic_failure_retains_input_and_can_recover () =
  List.iter (fun code -> with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/preview.png" in
    serve cache_dir png_header;
    executable cache_dir "ffmpeg" (Printf.sprintf "exit %d" code);
    let body = unwrap (Cache.download ~run ~cache_dir url) in
    unwrap (Cache.with_download_snapshot ~cache_dir body (fun input ->
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
      check string "recovered frame" "rgbRGB" (read_file output_path)));
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
    check bool "failed conversion removes its private input" false
      (Sys.readdir cache_dir |> Array.exists (String.starts_with ~prefix:"download_input_"));
    let body = unwrap (Cache.download ~run ~cache_dir url) in
    check string "JPEG still cached" jpeg_header (Cache.download_bytes body);
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
    let compute ?(force_fetch = false) () =
      incr attempts;
      match Cache.download ~force_fetch ~run ~cache_dir url with
        | Error failure ->
          Preview.Refused (Preview.Fetch_failed { detail = Cache.download_error_text failure })
        | Ok body ->
          unwrap (Cache.with_download_snapshot ~cache_dir body (fun input ->
          let output_path = Filename.concat cache_dir "retry.raw" in
          let command = Printf.sprintf "ffmpeg -i %s %s"
            (Filename.quote input) (Filename.quote output_path) in
          match Cache.run_decoder ~run ~output_path command with
          | Error failure ->
            Preview.Refused (Preview.Decode_failed { detail = Cache.decode_failure_text failure })
          | Ok path ->
            Preview.Mosaic (Masc_tui_image_mosaic.render ~cols:1 ~rows:2 (read_file path))))
    in
    executable cache_dir "curl" "exit 28";
    Preview.load_mosaic url ~compute:(fun () -> compute ());
    ignore (Preview.mosaic_lookup url);
    ignore (Preview.mosaic_lookup url);
    check int "reads do not retry a timeout" 1 !attempts;
    serve cache_dir png_header;
    converter_succeeds cache_dir "ffmpeg" "rgbRGB";
    let retry () =
      Cache.invalidate_download ~cache_dir url;
      compute ~force_fetch:true ()
    in
    Preview.retry_mosaic ~retry url;
    (match Preview.mosaic_lookup url with
     | Some (Preview.Mosaic (_ :: _)) -> ()
     | Some (Preview.Mosaic [] | Preview.Refused _) | None -> fail "retry produced no mosaic");
    check int "one explicit retry" 2 !attempts;
    Preview.retry_mosaic ~retry url;
    check int "no extra attempt" 2 !attempts;
    Preview.clear_cache ())

(* A direct image link is never fetched as a page, so nothing computes a mosaic
   for it and there is no refusal for a retry to claim. The retry used to do
   nothing: the body its first view cached stayed, and every later view -- and
   every restart, since it is a file -- reused it. *)
let test_a_direct_image_retry_drops_the_body_its_first_view_cached () =
  with_cache (fun cache_dir run ->
    let module Preview = Masc_tui_link_preview in
    let url = "https://fixture.invalid/direct.png" in
    Preview.clear_cache ();
    serve cache_dir png_header;
    executable cache_dir "ffmpeg" "exit 1";
    ignore (unwrap (Cache.download ~run ~cache_dir url));
    check bool "no mosaic was ever decided for the link" true
      (Preview.mosaic_lookup url = None);
    converter_succeeds cache_dir "ffmpeg" "rgbRGB";
    let attempts = ref 0 in
    let retry () =
      incr attempts;
      Cache.invalidate_download ~cache_dir url;
      let body = unwrap (Cache.download ~force_fetch:true ~run ~cache_dir url) in
      unwrap (Cache.with_download_snapshot ~cache_dir body (fun input ->
      let output_path = Filename.concat cache_dir "direct.raw" in
      let command = Printf.sprintf "ffmpeg -i %s %s"
        (Filename.quote input) (Filename.quote output_path) in
      match Cache.run_decoder ~run ~output_path command with
      | Error failure ->
        Preview.Refused (Preview.Decode_failed { detail = Cache.decode_failure_text failure })
      | Ok path ->
        Preview.Mosaic (Masc_tui_image_mosaic.render ~cols:1 ~rows:2 (read_file path))))
    in
    Preview.retry_mosaic ~retry url;
    check int "the explicit retry ran" 1 !attempts;
    check string "and fetched the body again" "xx"
      (read_file (Filename.concat cache_dir "fetches"));
    (match Preview.mosaic_lookup url with
     | Some (Preview.Mosaic (_ :: _)) -> ()
     | Some (Preview.Mosaic [] | Preview.Refused _) | None -> fail "retry produced no mosaic");
    Preview.retry_mosaic ~retry url;
    check int "a picture that rendered is not retried again" 1 !attempts;
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

let first_frame_ffmpeg cache_dir frame =
  executable cache_dir "ffmpeg" (Printf.sprintf
    "single=0\nprevious=\nfor argument do\n  if [ \"$previous\" = '-frames:v' ] && [ \"$argument\" = 1 ]; then single=1; fi\n  previous=$argument\n  output=$argument\ndone\n[ \"$single\" -eq 1 ] || exit 1\nprintf %%b %s > \"$output\""
    (shell_bytes frame))

let test_multiframe_image_after_imagemagick () =
  with_cache (fun cache_dir run ->
    let source = Filename.concat cache_dir "animated.gif" in
    let full_frame = png_header ^ "\000\000\000\004\000\000\000\004" in
    write_file source offset_gif;
    executable cache_dir "sips" "exit 127";
    executable cache_dir "convert"
      "for output do :; done\nprintf first > \"${output%.png}-0.png\"\nprintf second > \"${output%.png}-1.png\"";
    first_frame_ffmpeg cache_dir full_frame;
    check string "ffmpeg prepares the complete first-frame canvas" full_frame
      (unwrap (Cache.prepare_file ~run ~cache_dir source));
    check string "the original animation remains intact" offset_gif (read_file source))

let test_multiframe_image_with_ffmpeg () =
  with_cache (fun cache_dir run ->
    let source = Filename.concat cache_dir "animated.gif" in
    write_file source animated_gif;
    List.iter (fun name -> executable cache_dir name "exit 127") ["sips";"convert"];
    first_frame_ffmpeg cache_dir png_header;
    check string "ffmpeg prepares one frame" png_header
      (unwrap (Cache.prepare_file ~run ~cache_dir source));
    check string "the original animation remains intact" animated_gif (read_file source))

let test_published_frame_is_a_snapshot () =
  with_cache (fun cache_dir _ ->
    let source = Filename.concat cache_dir "original.bmp" in
    let captured_path = Filename.concat cache_dir "output-path" in
    let open_output = ref None in
    write_file source bmp_header;
    Fun.protect ~finally:(fun () -> Option.iter Unix.close !open_output) (fun () ->
      let run command =
        (* Parse the exact shell-quoted output argument without running a
           converter; keep its descriptor open after returning success. *)
        let capture = Printf.sprintf
            "set -- %s\nfor output do :; done\nprintf '%%s' \"$output\" > %s"
            command (Filename.quote captured_path) in
        check bool "fixture captured the converter path" true
          (Unix.system capture = Unix.WEXITED 0);
        let fd = Unix.openfile (read_file captured_path)
            [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
        open_output := Some fd;
        check int "fixture wrote its first frame" (String.length png_header)
          (Unix.write_substring fd png_header 0 (String.length png_header));
        Unix.WEXITED 0 in
      let path = match Cache.convert_to_png ~run ~cache_dir source with
        | Ok path -> path
        | Error failures -> failf "conversion failed: %s" (Cache.conversion_failure_text failures) in
      let fd = match !open_output with Some fd -> fd | None -> fail "no output handle" in
      ignore (Unix.lseek fd 0 Unix.SEEK_SET);
      check int "fixture wrote after the decoder returned" 4 (Unix.write_substring fd "late" 0 4);
      check string "a late write cannot change the published frame" png_header (read_file path)))

let test_explicit_refresh_replaces_a_refused_body () =
  with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/transient.png" in
    serve cache_dir html_page;
    List.iter (fun name -> executable cache_dir name "exit 1")
      [ "sips"; "convert"; "ffmpeg" ];
    check bool "notice cannot be converted" true
      (Result.is_error (Cache.prepare_png ~run ~cache_dir url));
    let body = unwrap (Cache.download ~run ~cache_dir url) in
    check string "ambiguous decode does not discard bytes" html_page (Cache.download_bytes body);
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
    let body = unwrap (Cache.download ~run ~cache_dir url) in
    check string "the returned body is whole" png_header (Cache.download_bytes body);
    check string "the published file is the whole body" png_header (read_file shared))

let test_a_delete_during_the_conversion_does_not_take_the_frame () =
  with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/raced.bmp" in
    serve cache_dir bmp_header;
    ignore (unwrap (Cache.download ~run ~cache_dir url));
    let input = Cache.input_path ~cache_dir url in
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

let test_download_owns_its_bytes_across_replacement () =
  with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/replaced.png" in
    let first = png_header ^ "first" and second = png_header ^ "second" in
    serve cache_dir first;
    let fetched = unwrap (Cache.download ~run ~cache_dir url) in
    let cached = unwrap (Cache.download ~run ~cache_dir url) in
    Cache.invalidate_download ~cache_dir url;
    serve cache_dir second;
    let newer = unwrap (Cache.download ~run ~cache_dir url) in
    check string "a fetched body remains the first image" first (Cache.download_bytes fetched);
    check string "a cache hit remains the first image" first (Cache.download_bytes cached);
    check string "the new download is the second image" second (Cache.download_bytes newer);
    let path = ref "" in
    unwrap (Cache.with_download_snapshot ~cache_dir fetched (fun input ->
      path := input;
      check string "successful decoder input uses captured bytes" first (read_file input)));
    check bool "snapshot is removed after success" false (Sys.file_exists !path);
    check_raises "snapshot callback exception propagates" Runner_interrupted (fun () ->
      ignore (Cache.with_download_snapshot ~cache_dir fetched (fun input ->
        path := input;
        check string "decoder input uses captured bytes" first (read_file input);
        raise Runner_interrupted)));
    check bool "snapshot is removed after an exception" false (Sys.file_exists !path);
    check string "shared cache still contains the newer body" second
      (read_file (Cache.input_path ~cache_dir url)))

let test_explicit_fetch_bypasses_a_republished_body () =
  with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/republished.png" in
    let old = png_header ^ "old" and fresh = png_header ^ "fresh" in
    serve cache_dir old;
    ignore (unwrap (Cache.download ~run ~cache_dir url));
    Cache.invalidate_download ~cache_dir url;
    (* An older in-flight download published after the invalidation. *)
    write_file (Cache.input_path ~cache_dir url) old;
    serve cache_dir fresh;
    let body = unwrap (Cache.download ~force_fetch:true ~run ~cache_dir url) in
    check string "retry fetched instead of using the republished body"
      fresh (Cache.download_bytes body);
    check string "retry performed another fetch" "xx"
      (read_file (Filename.concat cache_dir "fetches")))

let test_late_conversion_cannot_poison_a_refreshed_body () =
  with_cache (fun cache_dir shell_run ->
    let url = "https://fixture.invalid/concurrent.bmp" in
    let old = bmp_header ^ "old" and fresh = bmp_header ^ "fresh" in
    let old_frame = png_header ^ "old-frame" and fresh_frame = png_header ^ "fresh-frame" in
    let old_path = Filename.concat cache_dir "old-body" in
    let fresh_path = Filename.concat cache_dir "fresh-body" in
    let conversions = Filename.concat cache_dir "conversions" in
    write_file old_path old;
    write_file fresh_path fresh;
    executable cache_dir "sips" (Printf.sprintf
      "printf x >> %s\nif /usr/bin/cmp -s \"$4\" %s; then printf %%b %s > \"$6\";\nelif /usr/bin/cmp -s \"$4\" %s; then printf %%b %s > \"$6\";\nelse exit 1; fi"
      (Filename.quote conversions) (Filename.quote old_path) (shell_bytes old_frame)
      (Filename.quote fresh_path) (shell_bytes fresh_frame));
    serve cache_dir old;
    let interleaved = ref false in
    let refresh_result = ref None in
    let rec run command =
      if String.starts_with ~prefix:"sips " command && not !interleaved then begin
        interleaved := true;
        Cache.invalidate_download ~cache_dir url;
        serve cache_dir fresh;
        refresh_result := Some (unwrap (Cache.prepare_png ~run ~cache_dir url))
      end;
      shell_run command in
    check string "late first conversion returns its own frame" old_frame
      (unwrap (Cache.prepare_png ~run ~cache_dir url));
    check (option string) "refresh returned its own frame" (Some fresh_frame) !refresh_result;
    check string "old frame cannot be reused for the refreshed input" fresh_frame
      (unwrap (Cache.prepare_png ~run ~cache_dir url));
    check string "matching source reuses its frame" fresh_frame
      (unwrap (Cache.prepare_png ~run ~cache_dir url));
    check string "only the mismatch requires another conversion" "xxx" (read_file conversions);
    check string "one original fetch and one refresh" "xx"
      (read_file (Filename.concat cache_dir "fetches")))

let test_invalid_converted_cache_is_not_reused () =
  with_cache (fun cache_dir run ->
    let url = "https://fixture.invalid/damaged.bmp" in
    let conversions = Filename.concat cache_dir "conversions" in
    serve cache_dir bmp_header;
    executable cache_dir "sips" (Printf.sprintf
      "printf x >> %s\nprintf %%b %s > \"$6\""
      (Filename.quote conversions) (shell_bytes png_header));
    let view () = check string "converter frame returned" png_header
        (unwrap (Cache.prepare_png ~run ~cache_dir url)) in
    view ();
    view ();
    let name = Sys.readdir cache_dir |> Array.to_list
      |> List.find_opt (String.ends_with ~suffix:".bound")
      |> Option.value ~default:"" in
    check bool "bound cache was published" true (name <> "");
    let path = Filename.concat cache_dir name in
    let valid = read_file path in
    let header_only = String.sub valid 0 (String.index valid '\n' + 1) in
    List.iter (fun damaged ->
      write_file path damaged;
      view ())
      [""; "legacy png"; header_only; String.sub valid 0 (String.length valid - 1)];
    check string "invalid cache entries are converted again" "xxxxx"
      (read_file conversions);
    check string "invalid frames do not trigger a new download" "x"
      (read_file (Filename.concat cache_dir "fetches"));
    let legacy = Cache.png_path ~cache_dir (Cache.input_path ~cache_dir url) in
    write_file legacy png_header;
    Cache.invalidate_download ~cache_dir url;
    check bool "refresh removes the bound frame" false (Sys.file_exists path);
    check bool "refresh also removes the legacy frame" false (Sys.file_exists legacy))

(* ---- bounded run ---- *)

let status_testable =
  testable
    (fun fmt -> function
       | Unix.WEXITED code -> Format.fprintf fmt "WEXITED %d" code
       | Unix.WSIGNALED signal -> Format.fprintf fmt "WSIGNALED %d" signal
       | Unix.WSTOPPED signal -> Format.fprintf fmt "WSTOPPED %d" signal)
    ( = )
;;

let test_a_bounded_run_reports_the_exit_status () =
  check status_testable "zero" (Unix.WEXITED 0)
    (Cache.run_bounded ~deadline_seconds:5. "true");
  check status_testable "nonzero" (Unix.WEXITED 3)
    (Cache.run_bounded ~deadline_seconds:5. "sh -c 'exit 3'")
;;

let test_a_bounded_run_kills_a_command_past_its_deadline () =
  let started = Unix.gettimeofday () in
  let status = Cache.run_bounded ~deadline_seconds:0.2 "sleep 30" in
  let elapsed = Unix.gettimeofday () -. started in
  check status_testable "killed" (Unix.WSIGNALED Sys.sigkill) status;
  check bool "well before the command would have ended" true (elapsed < 10.)
;;

let test_a_bounded_run_gives_the_command_no_input () =
  (* [cat] with the null device for input ends at once; with the caller's
     terminal it would wait for keys, and this test would be killed. *)
  check status_testable "input is at its end" (Unix.WEXITED 0)
    (Cache.run_bounded ~deadline_seconds:5. "cat >/dev/null")
;;

let test_a_killed_decoder_is_described_as_killed () =
  check string "text"
    "decoder was killed (SIGKILL: out of time or memory)"
    (Cache.decode_failure_text (Cache.Decoder_signaled { signal = Sys.sigkill }))
;;

let () =
  run "tui image cache"
    [ ( "workflows"
      , [ test_case "local conversion preserves original" `Quick test_local_file_preserves_original
        ; test_case "download preserves runner failure and removes attempt" `Quick
            test_download_reports_runner_failure_and_cleans_attempt
        ; test_case "decoder preserves runner failure and shared output" `Quick
            test_decoder_reports_runner_failure_without_removing_shared_output
        ; test_case "runner failure stops converter fallback" `Quick
            test_runner_failure_stops_converter_fallback
        ; test_case "unexpected runner exceptions preserve shared output" `Quick
            test_unexpected_runner_exception_preserves_shared_output
        ; test_case "local refusal and explicit recovery" `Quick test_local_file_failure_and_recovery
        ; test_case "character preview refuses an unrepresentable ratio before decoding" `Quick
            test_character_frame_refuses_unrepresentable_ratio
        ; test_case "character decoder frame protocol and attempt cleanup" `Quick
            test_character_frame_protocol_and_cleanup
        ; test_case "character decoder retains output reservation" `Quick
            test_character_frame_keeps_output_reserved
        ; test_case "a delete during the fetch does not take the download" `Quick
            test_a_delete_during_the_fetch_does_not_take_the_download
        ; test_case "a delete during the conversion does not take the frame" `Quick
            test_a_delete_during_the_conversion_does_not_take_the_frame
        ; test_case "a refused body never reaches the cache path" `Quick
            test_a_refused_body_never_reaches_the_cache_path
        ; test_case "download owns its bytes across replacement" `Quick
            test_download_owns_its_bytes_across_replacement
        ; test_case "explicit fetch bypasses a republished body" `Quick
            test_explicit_fetch_bypasses_a_republished_body
        ; test_case "late conversion cannot poison refreshed input" `Quick
            test_late_conversion_cannot_poison_a_refreshed_body
        ; test_case "invalid converted cache is not reused" `Quick
            test_invalid_converted_cache_is_not_reused
        ; test_case "mosaic failure retains input and can recover" `Quick
            test_mosaic_failure_retains_input_and_can_recover
        ; test_case "view retains input when all converters are missing" `Quick
            test_v_missing_converters_retains_input
        ; test_case "explicit retry recovers without background loop" `Quick
            test_explicit_retry_recovers_without_background_loop
        ; test_case "a direct image retry drops its cached body" `Quick
            test_a_direct_image_retry_drops_the_body_its_first_view_cached
        ; test_case "overlapping initial load and retry share one claim" `Quick
            test_overlapping_load_and_retry_share_one_claim
        ; test_case "failed computation releases its claim" `Quick
            test_failed_computation_releases_claim
        ; test_case "clear retains pending ownership and discards completion" `Quick
            test_clear_pending_keeps_claim_and_discards_completion
        ; test_case "partial converter failure uses next converter" `Quick
            test_partial_converter_failure_uses_next_converter
        ; test_case "a multiframe image falls back after ImageMagick" `Quick
            test_multiframe_image_after_imagemagick
        ; test_case "a multiframe image uses one ffmpeg frame" `Quick
            test_multiframe_image_with_ffmpeg
        ; test_case "the published frame is a snapshot" `Quick
            test_published_frame_is_a_snapshot
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
        ;] )
    ; ( "bounded run"
      , [ test_case "the exit status is reported" `Quick test_a_bounded_run_reports_the_exit_status
        ; test_case "a command past its deadline is killed" `Quick
            test_a_bounded_run_kills_a_command_past_its_deadline
        ; test_case "the command gets no input" `Quick
            test_a_bounded_run_gives_the_command_no_input
        ; test_case "a killed decoder is described as killed" `Quick
            test_a_killed_decoder_is_described_as_killed
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
        ;] )
    ]
;;
