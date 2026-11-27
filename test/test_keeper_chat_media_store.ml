(* Unit tests for the content-addressed workspace media store. *)

module M = Masc.Keeper_chat_media_store

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv key previous
      | None -> Unix.putenv key "")
    (fun () ->
      Unix.putenv key value;
      f ())
;;

let with_temp_base f =
  let base = Filename.temp_dir "media_store_test" "" in
  f base
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let write_file path data =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc data)
;;

let be_u16 n =
  String.init 2 (function
    | 0 -> Char.chr ((n lsr 8) land 0xFF)
    | _ -> Char.chr (n land 0xFF))
;;

let be_u32 n =
  String.init 4 (function
    | 0 -> Char.chr ((n lsr 24) land 0xFF)
    | 1 -> Char.chr ((n lsr 16) land 0xFF)
    | 2 -> Char.chr ((n lsr 8) land 0xFF)
    | _ -> Char.chr (n land 0xFF))
;;

let le_u16 n =
  String.init 2 (function
    | 0 -> Char.chr (n land 0xFF)
    | _ -> Char.chr ((n lsr 8) land 0xFF))
;;

let le_u24 n =
  String.init 3 (function
    | 0 -> Char.chr (n land 0xFF)
    | 1 -> Char.chr ((n lsr 8) land 0xFF)
    | _ -> Char.chr ((n lsr 16) land 0xFF))
;;

let make_png ~width ~height =
  "\x89PNG\r\n\x1a\n"
  ^ be_u32 13
  ^ "IHDR"
  ^ be_u32 width
  ^ be_u32 height
  ^ "\x08\x02\x00\x00\x00\x00\x00\x00\x00"
;;

let make_gif ?(version = "GIF89a") ~width ~height () =
  version ^ le_u16 width ^ le_u16 height ^ "\x00\x00\x00"
;;

let make_jpeg ?(sof_marker = 0xC0) ~width ~height () =
  let app0 = "\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00" in
  (* DHT (0xC4) must be skipped rather than treated as SOF. *)
  let dht = "\xff\xc4\x00\x04\x00\x00" in
  let sof =
    "\xff\xff"
    ^ String.make 1 (Char.chr sof_marker)
    ^ be_u16 11
    ^ "\x08"
    ^ be_u16 height
    ^ be_u16 width
    ^ "\x01\x01\x11\x00"
  in
  "\xff\xd8" ^ app0 ^ dht ^ sof ^ "\xff\xd9"
;;

let make_webp_vp8 ~width ~height =
  "RIFF\x16\x00\x00\x00WEBP"
  ^ "VP8 \x0a\x00\x00\x00"
  ^ "\x00\x00\x00"
  ^ "\x9d\x01\x2a"
  ^ le_u16 (width land 0x3FFF)
  ^ le_u16 (height land 0x3FFF)
;;

let make_webp_vp8l ~width ~height =
  let w1 = width - 1 in
  let h1 = height - 1 in
  let packed =
    String.init 4 (function
      | 0 -> Char.chr (w1 land 0xFF)
      | 1 -> Char.chr (((w1 lsr 8) land 0x3F) lor ((h1 land 0x03) lsl 6))
      | 2 -> Char.chr ((h1 lsr 2) land 0xFF)
      | _ -> Char.chr ((h1 lsr 10) land 0x0F))
  in
  "RIFF\x11\x00\x00\x00WEBP" ^ "VP8L\x05\x00\x00\x00\x2f" ^ packed
;;

let make_webp_vp8x ~width ~height =
  "RIFF\x16\x00\x00\x00WEBP"
  ^ "VP8X\x0a\x00\x00\x00"
  ^ "\x00\x00\x00\x00"
  ^ le_u24 (width - 1)
  ^ le_u24 (height - 1)
;;

let sample_png = make_png ~width:640 ~height:480
let sample_jpeg = make_jpeg ~width:800 ~height:600 ()
let sample_gif = make_gif ~width:320 ~height:240 ()
let sample_webp_vp8 = make_webp_vp8 ~width:1024 ~height:768
let sample_webp_vp8l = make_webp_vp8l ~width:300 ~height:200
let sample_webp_vp8x = make_webp_vp8x ~width:1920 ~height:1080
let sample_mp3_id3 = "ID3\x03\x00\x00\x00\x00\x00\x00audio-bytes"
let sample_mp3_frame = "\xff\xfb\x90\x00raw-mpeg-frame"
let sample_wav = "RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00"
let sample_ogg = "OggS\x00\x02\x00\x00ogg-payload"
let sample_midi = "MThd\x00\x00\x00\x06\x00\x00\x00\x01\x00\x60"
let sample_pdf = "%PDF-1.7\n%%EOF\n"

let expected_sha256 data = Agent_core_sha256.(digest_string data |> to_hex)

let persist_ok ~base_dir ~media_type ~data =
  match M.persist_result ~base_dir ~media_type ~data with
  | Ok stored -> stored
  | Error message -> Alcotest.failf "unexpected persist error: %s" message
;;

let raster_mime_testable =
  Alcotest.testable
    (fun ppf m -> Format.pp_print_string ppf (M.raster_mime_to_string m))
    ( = )
;;

let media_mime_testable =
  Alcotest.testable
    (fun ppf m -> Format.pp_print_string ppf (M.media_mime_to_string m))
    ( = )
;;

let media_category_testable =
  Alcotest.testable
    (fun ppf c ->
       Format.pp_print_string
         ppf
         (match c with
          | M.Image -> "Image"
          | M.Audio -> "Audio"
          | M.Midi -> "Midi"
          | M.Document -> "Document"))
    ( = )
;;

let dimensions_testable =
  Alcotest.testable
    (fun ppf (d : M.dimensions) -> Format.fprintf ppf "%dx%d" d.M.width d.M.height)
    ( = )
;;

let test_persist_round_trip () =
  with_temp_base (fun base_dir ->
    let token, url = persist_ok ~base_dir ~media_type:"image/png" ~data:sample_png in
    Alcotest.(check string) "token is raw payload SHA-256" (expected_sha256 sample_png) token;
    Alcotest.(check string)
      "url is /api/v1/media/<sha256>"
      ("/api/v1/media/" ^ token)
      url;
    Alcotest.(check bool) "token has valid shape" true (M.valid_token token);
    Alcotest.(check int) "token is SHA-256 hex" 64 (String.length token);
    match M.resolve_token ~base_dir ~token with
    | None -> Alcotest.fail "persisted media not found by token"
    | Some (path, mime) ->
      Alcotest.(check string) "round-trip bytes preserved" sample_png (read_file path);
      Alcotest.(check media_mime_testable) "typed MIME preserved" (M.Raster M.Image_png) mime;
      Alcotest.(check (option string))
        "file_path_of_token agrees with resolve_token"
        (Some path)
        (M.file_path_of_token ~base_dir ~token))
;;

let test_content_addressed_dedup () =
  with_temp_base (fun base_dir ->
    let t1, _ = persist_ok ~base_dir ~media_type:"audio/mpeg" ~data:sample_mp3_id3 in
    let t2, _ = persist_ok ~base_dir ~media_type:"audio/mp3" ~data:sample_mp3_id3 in
    Alcotest.(check string) "identical payload dedups to one sha256" t1 t2)
;;

let test_unknown_token_and_symlink_refused () =
  with_temp_base (fun base_dir ->
    Alcotest.(check bool) "malformed token rejected" false (M.valid_token "not a token");
    Alcotest.(check bool)
      "uppercase hex rejected"
      false
      (M.valid_token (String.make 64 'A'));
    Alcotest.(check (option string))
      "absent token resolves to None"
      None
      (M.file_path_of_token ~base_dir ~token:(String.make 64 '0'));
    let media_dir =
      Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) M.media_subdir
    in
    Fs_compat.mkdir_p media_dir;
    let secret = Filename.concat base_dir "outside.png" in
    write_file secret sample_png;
    let sym_token = String.make 64 'e' in
    Unix.symlink secret (Filename.concat media_dir (sym_token ^ ".png"));
    Alcotest.(check (option string))
      "symlinks inside media dir are never resolved"
      None
      (M.file_path_of_token ~base_dir ~token:sym_token);
    let bin_token = String.make 64 'b' in
    write_file (Filename.concat media_dir (bin_token ^ ".bin")) "opaque";
    Alcotest.(check (option string))
      "legacy .bin extension is not resolved"
      None
      (M.file_path_of_token ~base_dir ~token:bin_token))
;;

let test_strict_mime_parsing_and_sniffing () =
  let check_raster = Alcotest.(check (option raster_mime_testable)) in
  let check_media = Alcotest.(check (option media_mime_testable)) in
  check_raster "png with parameter" (Some M.Image_png)
    (M.raster_mime_of_string "IMAGE/PNG; charset=binary");
  check_raster "jpg alias" (Some M.Image_jpeg) (M.raster_mime_of_string "image/jpg");
  check_raster "svg rejected from raster" None (M.raster_mime_of_string "image/svg+xml");
  check_raster "unknown rejected" None (M.raster_mime_of_string "application/x-unknown");
  Alcotest.(check bool) "svg content-type recognized" true
    (M.is_svg_content_type "image/svg+xml; charset=utf-8");
  check_media "sniff png" (Some (M.Raster M.Image_png)) (M.sniff_media_mime sample_png);
  check_media "sniff jpeg" (Some (M.Raster M.Image_jpeg)) (M.sniff_media_mime sample_jpeg);
  check_media "sniff gif" (Some (M.Raster M.Image_gif)) (M.sniff_media_mime sample_gif);
  check_media "sniff webp" (Some (M.Raster M.Image_webp)) (M.sniff_media_mime sample_webp_vp8);
  check_media "sniff mp3 ID3" (Some M.Audio_mpeg) (M.sniff_media_mime sample_mp3_id3);
  check_media "sniff mp3 raw frame" (Some M.Audio_mpeg) (M.sniff_media_mime sample_mp3_frame);
  check_media "reject 0xFFFFFF garbage as mp3" None (M.sniff_media_mime "\xff\xff\xff\xff");
  check_media "sniff wav" (Some M.Audio_wav) (M.sniff_media_mime sample_wav);
  check_media "sniff ogg" (Some M.Audio_ogg) (M.sniff_media_mime sample_ogg);
  check_media "sniff midi" (Some M.Audio_midi) (M.sniff_media_mime sample_midi);
  check_media "sniff pdf" (Some M.Application_pdf) (M.sniff_media_mime sample_pdf);
  check_media "unknown bytes yield None" None (M.sniff_media_mime "plain text payload");
  Alcotest.(check (option media_mime_testable)) "bin ext returns None" None (M.media_mime_of_ext "bin");
  Alcotest.(check (option media_mime_testable)) "jpg ext returns Image_jpeg"
    (Some (M.Raster M.Image_jpeg)) (M.media_mime_of_ext "jpg")
;;

let test_svg_and_polyglot_rejection () =
  with_temp_base (fun base_dir ->
    List.iter
      (fun (label, ct, payload) ->
         match M.persist_raster_upload ~base_dir ~content_type:ct ~data:payload with
         | Error M.Upload_svg_not_allowed -> ()
         | Error err ->
           Alcotest.failf "%s: expected Upload_svg_not_allowed, got %s" label (M.upload_error_to_string err)
         | Ok _ -> Alcotest.failf "%s: SVG payload must never be stored" label)
      [ "declared svg with png bytes", Some "image/svg+xml", sample_png
      ; "raw <svg> with image/png header", Some "image/png", "<svg xmlns='http://www.w3.org/2000/svg'/>"
      ; "xml prolog with image/jpeg header", Some "image/jpeg", "<?xml version='1.0'?><svg/>"
      ; ( "utf8 bom + comment + svg"
        , Some "image/webp"
        , "\xef\xbb\xbf  <!-- lead --><SVG onload=alert(1)>" )
      ; "doctype svg", Some "image/gif", "<!DOCTYPE svg PUBLIC '-//W3C//DTD SVG 1.1//EN'><svg/>"
      ];
    (match M.persist_raster_upload ~base_dir ~content_type:(Some "image/png") ~data:sample_jpeg with
     | Error (M.Upload_mime_mismatch { declared = M.Image_png; sniffed = M.Image_jpeg }) -> ()
     | Error err -> Alcotest.failf "expected Upload_mime_mismatch, got %s" (M.upload_error_to_string err)
     | Ok _ -> Alcotest.fail "mismatched MIME must be rejected");
    (match M.persist_raster_upload ~base_dir ~content_type:(Some "image/jpg") ~data:sample_jpeg with
     | Ok stored ->
       Alcotest.(check raster_mime_testable) "image/jpg canonicalizes to image/jpeg"
         M.Image_jpeg stored.M.mime
     | Error err -> Alcotest.failf "image/jpg with JPEG bytes should succeed: %s" (M.upload_error_to_string err));
    (match M.persist_raster_upload ~base_dir ~content_type:(Some "image/png") ~data:"not-png-bytes" with
     | Error (M.Upload_unsupported_media_type { declared = Some "image/png"; sniffed = None }) -> ()
     | Error err -> Alcotest.failf "expected Upload_unsupported_media_type, got %s" (M.upload_error_to_string err)
     | Ok _ -> Alcotest.fail "unrecognized bytes must be rejected"))
;;

let test_raster_dimension_parsing () =
  let check = Alcotest.(check (option dimensions_testable)) in
  check "PNG IHDR" (Some { M.width = 640; height = 480 })
    (M.parse_raster_dimensions M.Image_png sample_png);
  check "truncated PNG yields None" None
    (M.parse_raster_dimensions M.Image_png "\x89PNG\r\n\x1a\nshort");
  check "zero-dimension PNG yields None" None
    (M.parse_raster_dimensions M.Image_png (make_png ~width:0 ~height:100));
  check "GIF89a LSD" (Some { M.width = 320; height = 240 })
    (M.parse_raster_dimensions M.Image_gif sample_gif);
  check "GIF87a LSD" (Some { M.width = 16; height = 32 })
    (M.parse_raster_dimensions M.Image_gif (make_gif ~version:"GIF87a" ~width:16 ~height:32 ()));
  check "JPEG SOF0 past APP0 + DHT + fill bytes" (Some { M.width = 800; height = 600 })
    (M.parse_raster_dimensions M.Image_jpeg sample_jpeg);
  check "JPEG SOF2 progressive" (Some { M.width = 1280; height = 720 })
    (M.parse_raster_dimensions M.Image_jpeg (make_jpeg ~sof_marker:0xC2 ~width:1280 ~height:720 ()));
  check "WebP VP8 lossy" (Some { M.width = 1024; height = 768 })
    (M.parse_raster_dimensions M.Image_webp sample_webp_vp8);
  check "WebP VP8L lossless" (Some { M.width = 300; height = 200 })
    (M.parse_raster_dimensions M.Image_webp sample_webp_vp8l);
  check "WebP VP8X extended" (Some { M.width = 1920; height = 1080 })
    (M.parse_raster_dimensions M.Image_webp sample_webp_vp8x)
;;

let test_media_category () =
  let check = Alcotest.(check (option media_category_testable)) in
  check "png is Image" (Some M.Image) (M.category_of_media_type "image/png");
  check "jpeg is Image" (Some M.Image) (M.category_of_media_type "image/jpeg");
  check "mp3 is Audio" (Some M.Audio) (M.category_of_media_type "audio/mpeg");
  check "wav is Audio" (Some M.Audio) (M.category_of_media_type "audio/wav");
  check "midi is Midi" (Some M.Midi) (M.category_of_media_type "audio/midi");
  check "pdf is Document" (Some M.Document) (M.category_of_media_type "application/pdf");
  check "unknown is None" None (M.category_of_media_type "application/x-unknown")
;;

let test_base64_source_decoded_before_persist () =
  with_temp_base (fun base_dir ->
    let encoded = Base64.encode_string sample_png in
    match
      M.persist_media_source_result
        ~base_dir
        ~media_type:"image/png"
        ~source:(Llm_provider.Types.Base64 encoded)
    with
    | Error err -> Alcotest.failf "unexpected persist error: %s" (M.persist_error_to_string err)
    | Ok (token, url) ->
      Alcotest.(check string) "token is raw SHA-256" (expected_sha256 sample_png) token;
      Alcotest.(check string) "url" ("/api/v1/media/" ^ token) url;
      (match M.file_path_of_token ~base_dir ~token with
       | None -> Alcotest.fail "persisted decoded media not found"
       | Some path -> Alcotest.(check string) "stored raw bytes" sample_png (read_file path)))
;;

let test_generated_media_cap_rejects_oversize_raw_media () =
  with_env "MASC_KEEPER_GENERATED_MEDIA_MAX_BYTES" "4" (fun () ->
    with_temp_base (fun base_dir ->
      let raw = "12345" in
      (match M.persist_result ~base_dir ~media_type:"image/png" ~data:raw with
       | Ok _ -> Alcotest.fail "oversize raw media must not be persisted"
       | Error msg ->
         Alcotest.(check string)
           "raw persist error"
           "generated media too large: size_bytes=5 max_bytes=4"
           msg);
      match
        M.persist_media_source_result
          ~base_dir
          ~media_type:"image/png"
          ~source:(Llm_provider.Types.Base64 (Base64.encode_string raw))
      with
      | Ok _ -> Alcotest.fail "oversize decoded media must not be persisted"
      | Error (M.Media_too_large { size_bytes; max_bytes }) ->
        Alcotest.(check int) "size bytes" 5 size_bytes;
        Alcotest.(check int) "max bytes" 4 max_bytes
      | Error err ->
        Alcotest.failf "unexpected error: %s" (M.persist_error_to_string err)))
;;

let test_persist_does_not_delete_older_media_by_wall_clock () =
  with_temp_base (fun base_dir ->
    let seed_token, _ = persist_ok ~base_dir ~media_type:"image/png" ~data:sample_png in
    let seed_path =
      match M.file_path_of_token ~base_dir ~token:seed_token with
      | Some path -> path
      | None -> Alcotest.fail "seed media path missing"
    in
    let old_time = Unix.gettimeofday () -. (86400.0 *. 10.0) in
    Unix.utimes seed_path old_time old_time;
    ignore (persist_ok ~base_dir ~media_type:"image/jpeg" ~data:sample_jpeg);
    Alcotest.(check bool)
      "older persisted media survives new writes (no wall-clock death)"
      true
      (Sys.file_exists seed_path))
;;

let test_unsupported_source_type_rejected () =
  with_temp_base (fun base_dir ->
    match
      M.persist_media_source_result
        ~base_dir
        ~media_type:"image/png"
        ~source:(Llm_provider.Types.Url "https://example.invalid/image.png")
    with
    | Ok _ -> Alcotest.fail "url source must not be persisted without resolver"
    | Error (M.Unsupported_source_type Agent_core.Types.Url_kind) -> ()
    | Error err -> Alcotest.failf "unexpected error: %s" (M.persist_error_to_string err))
;;

let () =
  Alcotest.run
    "keeper_chat_media_store"
    [ ( "media_store"
      , [ Alcotest.test_case "persist round-trip" `Quick test_persist_round_trip
        ; Alcotest.test_case "content-addressed dedup" `Quick test_content_addressed_dedup
        ; Alcotest.test_case
            "unknown tokens, symlinks, and .bin rejected"
            `Quick
            test_unknown_token_and_symlink_refused
        ; Alcotest.test_case
            "strict MIME parsing and magic-byte sniffing"
            `Quick
            test_strict_mime_parsing_and_sniffing
        ; Alcotest.test_case "SVG and polyglot rejection" `Quick test_svg_and_polyglot_rejection
        ; Alcotest.test_case "raster dimension parsing" `Quick test_raster_dimension_parsing
        ; Alcotest.test_case "media category" `Quick test_media_category
        ; Alcotest.test_case
            "base64 source decoded"
            `Quick
            test_base64_source_decoded_before_persist
        ; Alcotest.test_case
            "generated media cap rejects oversize raw media"
            `Quick
            test_generated_media_cap_rejects_oversize_raw_media
        ; Alcotest.test_case
            "persist does not delete older media by wall clock"
            `Quick
            test_persist_does_not_delete_older_media_by_wall_clock
        ; Alcotest.test_case
            "unsupported source rejected"
            `Quick
            test_unsupported_source_type_rejected
        ] )
    ]
;;
